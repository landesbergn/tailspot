//
//  ADSBManager.swift
//  Tailspot
//
//  Owns the ADS-B polling loop. Asks the backend source for nearby
//  aircraft on a timer, annotates each with its bearing/elevation/
//  distance from the user's current position, and exposes the
//  resulting list to SwiftUI via @Published.
//
//  Marked @MainActor so all @Published mutations are main-thread by
//  construction — no manual DispatchQueue.main.async hops needed.
//  When we `await client.aircraftInBbox(...)`, the actor suspends and
//  the network call runs on URLSession's pool; on resume we're back on
//  main and can assign `self.observed = …` directly.
//

import Foundation
import Combine
import CoreLocation
import os

/// An Aircraft annotated with its angular position and distance relative
/// to a specific observer location. The geometry is computed once per
/// fetch — not in the view body — so SwiftUI re-renders are cheap.
struct ObservedAircraft: Identifiable, Sendable {
    let aircraft: Aircraft
    let bearingDeg: Double          // 0..360 from true north
    let elevationDeg: Double        // above horizon, can be negative
    let groundDistanceMeters: Double
    let slantDistanceMeters: Double // line-of-sight (3D) distance

    /// Set true when this aircraft was in the visible set on the PREVIOUS
    /// frame. Drives visibility hysteresis (see `isLikelyVisibleToObserver`):
    /// an already-shown plane gets a wider distance cap so it doesn't flicker
    /// in/out when it hovers right at the boundary. Stamped each frame by
    /// `applyVisibilityHysteresis`; defaults false so any path that doesn't
    /// track it (tests, one-off checks) gets the plain non-hysteretic gate.
    var wasShownLastFrame: Bool = false

    /// True when the aircraft reported itself on the ground (taxiing /
    /// parked). Grounded aircraft used to be DROPPED at `annotate`; since the
    /// grounded easter egg (2026-07-09) they are annotated into the hidden
    /// tier instead, so the empty-tap diagnosis can recognize "you pointed at
    /// a parked plane" and answer with a toast. They must NEVER become
    /// visible, catchable, or tap-to-revealable: `visibilityTier` pins them
    /// `.hidden` unconditionally (before any distance/elevation math), which
    /// keeps them out of the ambient overlay, out of `icaosInZone`
    /// catchability, and out of the hysteresis shown set — the field-tuned
    /// visibility curve itself is untouched.
    var grounded: Bool = false

    var id: String { aircraft.icao24 }
}

// MARK: - Catch-time angular-size floor (Lever 3)

extension ObservedAircraft {
    /// The aircraft's apparent angular size (arc-minutes) — its wingspan
    /// subtended at the observer's eye at the current slant distance. The
    /// naked eye resolves ~1′; making out (and aiming at) a plane needs
    /// several. Drives the catch-time size floor below.
    var apparentSizeArcminutes: Double {
        guard slantDistanceMeters > 0 else { return .infinity }
        return aircraft.estimatedWingspanMeters / slantDistanceMeters
            * (180 / .pi) * 60
    }

    /// Whether this aircraft is big/close enough to plausibly resolve by eye
    /// — the catch-time angular-size floor (Lever 3). A small airframe 25 km
    /// out is a sub-resolution speck nobody can identify, so it isn't a real
    /// catch *regardless of occlusion* (which the localized sky gate owns).
    ///
    /// Deliberately DECOUPLED from `isLikelyVisibleToObserver`: labels stay
    /// as generous as ever (a far contrail still shows) — only *catching* a
    /// speck is gated, with a "Catch anyway" override on the block.
    var clearsCatchSizeFloor: Bool {
        apparentSizeArcminutes >= ObservedAircraft.catchSizeFloorArcminutes
    }

    /// Minimum apparent size (arc-minutes) to allow a catch. 2.5′ blocks only
    /// the physically-unresolvable — a ~16 m bizjet beyond ~22 km (John's
    /// 28.7 km Citation reads 1.9′) — while clearing every confirmed field
    /// sighting (the marginal SKW5480 regional at 18 km ≈ 5′, the ANA179
    /// widebody contrail at 19 km ≈ 11′). The far end is owned by the
    /// localized sky gate, not this floor. Tunable; calibrate from telemetry.
    static let catchSizeFloorArcminutes: Double = 2.5
}

/// Apply visibility hysteresis to a freshly-annotated frame: stamp each
/// aircraft's `wasShownLastFrame` from the prior shown set, then return the
/// new shown set (the icao24s now passing the hysteretic visibility gate).
/// Shared by the live path (`ADSBManager.reAnnotate`) and the offline
/// `ReplayAnalyzer` so the two can't drift. Pure aside from stamping flags
/// on the passed-in array. MainActor-isolated (the repo default) because it
/// consults `isLikelyVisibleToObserver`, the MainActor-isolated visibility
/// gate; both callers already run on the MainActor, so this costs nothing.
func applyVisibilityHysteresis(
    _ observed: inout [ObservedAircraft],
    previouslyShown: Set<String>
) -> Set<String> {
    for i in observed.indices {
        observed[i].wasShownLastFrame = previouslyShown.contains(observed[i].aircraft.icao24)
    }
    return Set(observed.filter { $0.isLikelyVisibleToObserver }.map { $0.aircraft.icao24 })
}

extension ObservedAircraft {
    /// Build an `ObservedAircraft` from a raw `Aircraft` + observer
    /// pose at `now`. Forward-extrapolates the aircraft's position
    /// to `now` using its reported track/velocity, then computes
    /// the bearing/elevation/slant from the observer.
    ///
    /// Returns nil if:
    ///   - The last position update is older than `maxPositionAge` —
    ///     stale rows are usually planes that just landed, lost ADS-B
    ///     coverage, or otherwise dropped off radar. They show up as
    ///     "ghost labels" hovering where the plane used to be.
    ///
    /// On-ground aircraft are NOT dropped (they used to be): they annotate
    /// with `grounded = true`, which pins them to the hidden visibility
    /// tier. Keeping them in the observed set lets the empty-tap diagnosis
    /// tell "you tapped a parked plane" apart from "nothing there" — the
    /// grounded easter egg — without ever labeling or catching them.
    ///
    /// Centralized here so the replay analyzer can reuse the exact
    /// same geometry the live path uses.
    static func annotate(
        _ aircraft: Aircraft,
        observer: CLLocation,
        now: Date,
        maxPositionAge: TimeInterval = ObservedAircraft.maxPositionAge
    ) -> ObservedAircraft? {
        if let ts = aircraft.positionTimestamp,
           now.timeIntervalSince(ts) > maxPositionAge {
            return nil
        }
        let pos = aircraft.extrapolatedPosition(at: now)
        let observerLat = observer.coordinate.latitude
        let observerLon = observer.coordinate.longitude
        let observerAlt = observer.altitude
        let ground = Geo.distance(
            fromLat: observerLat, lon: observerLon,
            toLat: pos.lat, lon: pos.lon
        )
        let bearing = Geo.bearing(
            fromLat: observerLat, lon: observerLon,
            toLat: pos.lat, lon: pos.lon
        )
        let elev = Geo.elevation(
            observerAltMeters: observerAlt,
            targetAltMeters: aircraft.altitudeMeters,
            groundDistanceMeters: ground
        )
        let dh = aircraft.altitudeMeters - observerAlt
        let slant = (ground * ground + dh * dh).squareRoot()
        return ObservedAircraft(
            aircraft: aircraft,
            bearingDeg: bearing,
            elevationDeg: elev,
            groundDistanceMeters: ground,
            slantDistanceMeters: slant,
            grounded: aircraft.onGround
        )
    }

    /// Drop aircraft whose last ADS-B position update is older than
    /// this (seconds). In-flight aircraft refresh every few seconds when
    /// a receiver hears them; a stale row usually means the plane landed,
    /// lost coverage, or dropped off radar — a "ghost".
    ///
    /// Raised 60 → 150 on 2026-06-01: a tight floor deleted labels for
    /// genuinely-visible planes whose upstream position was merely slow
    /// to refresh (MLAT contacts especially can lag behind direct ADS-B),
    /// reading in the field as "no planes at all".
    static let maxPositionAge: TimeInterval = 150

    /// Whether this aircraft is plausibly visible to the naked eye
    /// right now. Two filters:
    ///
    ///   1. `elevationDeg > minVisibleElevationDeg` — the plane is
    ///      above the user's visual horizon, with a small buffer for
    ///      terrestrial obstructions (hills, buildings, trees).
    ///   2. `slantDistanceMeters < maxVisibleDistance(forElevationDeg:)`
    ///      — an elevation-DEPENDENT cap: ~12 km near the horizon
    ///      (haze + clutter band) opening to 35 km by 10° (clean-sky
    ///      band). See `maxVisibleDistance` for the field data behind
    ///      the curve.
    ///
    /// Explicitly does NOT account for weather (clouds, haze vary by
    /// day) or atmospheric scattering. The curve encodes a typical Bay
    /// Area day; per-condition adjustment is out of scope for v0.
    var isLikelyVisibleToObserver: Bool { visibilityTier != .hidden }

    /// Visibility is a TIER, not a boolean — the 2026-06-12 doctrine change.
    ///
    /// Three field sessions produced misses with three causes, two of them
    /// the same kind: a hard distance cutoff guessing wrong about what the
    /// eye can see (ANA179: 19.2 km contrail pruned by the 13 km plateau;
    /// SKW5480: CONFIRMED VISIBLE at 18.0 km / 12.1° where the cap said
    /// 7.7 km — directly contradicting the Berkeley ghost dataset that fit
    /// the curve). Visibility is conditions-dependent (haze, sun angle,
    /// contrails, airframe size); no static curve is right on both sides.
    /// And the costs are asymmetric: a ghost label is a shrug, a hidden
    /// visible plane is the product failing at its one job.
    ///
    /// So the curve no longer controls EXISTENCE, only EMPHASIS:
    ///   .full   — inside the confidence curve (unchanged math): normal label.
    ///   .faint  — beyond the curve but within `faintBandFactor`× of it and
    ///             above the horizon floor: dimmed label. A thin margin past
    ///             the confident edge, so a plane hovering at the cap dims
    ///             rather than vanishing frame-to-frame.
    ///   .hidden — below the horizon floor or beyond the faint band:
    ///             not rendered. The floor still owns terrain clutter, the
    ///             band now owns the far/low MLAT firehose.
    ///
    /// Hysteresis applies at BOTH boundaries (full↔faint styling flicker is
    /// merely ugly; faint↔hidden existence flicker breaks lock-on, as the
    /// ASA733 field report showed for the old single boundary).
    enum VisibilityTier: Equatable, Sendable { case full, faint, hidden }

    var visibilityTier: VisibilityTier {
        // Grounded aircraft are hidden UNCONDITIONALLY — before any
        // elevation/distance math, so no curve tuning (and no hysteresis
        // stamp) can ever surface a parked plane. See `grounded`.
        guard !grounded else { return .hidden }
        guard elevationDeg > Self.minVisibleElevationDeg else { return .hidden }
        let h = wasShownLastFrame ? Self.visibilityHysteresisFactor : 1.0
        let fullCap = visibilityCapMeters * h
        if slantDistanceMeters < fullCap { return .full }
        // Faint reaches faintBandFactor× the curve, but never past an absolute
        // sanity ceiling: at low elevation the 2× band is the tighter bound
        // (kills the far/low MLAT firehose), at high elevation the curve is
        // already wide so the ceiling is the tighter bound (a 40 km plane
        // isn't catchable at any elevation — and a 36 km @ 45° contact is
        // 25 km up, physically impossible).
        let faintReach = min(visibilityCapMeters * Self.faintBandFactor,
                             Self.faintCeilingMeters) * h
        if slantDistanceMeters < faintReach { return .faint }
        return .hidden
    }

    /// The faint tier extends from the confident curve out to this multiple
    /// of it — an elevation-aware band, NOT a flat ceiling. The flat 35 km
    /// ceiling this replaces was fine against sparse OpenSky data, but once
    /// the backend's MLAT feed arrived (0.5.0) a single dense Berkeley tick
    /// carried 76 contacts and ~20 of them — far, low, near the horizon —
    /// surfaced as faint labels while exactly ONE plane (FDX350, 4.9 km @
    /// 19°) was actually visible (field recording replay-2026-06-15T001746Z).
    /// Tying the faint band to the (haze-aware) curve instead keeps it tight
    /// where the air is thick and generous where it's clear (high-elevation
    /// contrail traffic still gets a wide band).
    ///
    /// 2.0 is the precision lean Noah chose 2026-06-15: a clean HUD of what
    /// you can see beats catching every marginal far plane. The deliberate
    /// cost is that the old "never hide inside 35 km" field cases — SKW5480
    /// (18 km @ 12°) and N21866 (5.8 km @ ~5°, GA) — no longer auto-label.
    /// Both are genuinely marginal: SKW5480 contradicts the ghost data, and
    /// N21866 was itself a confirmed ghost at 6.3 km on another day. Recall
    /// for that far/marginal class is deferred to a future tap-to-reveal
    /// affordance. Tunable.
    static let faintBandFactor: Double = 2.0

    /// Absolute outer ceiling on the faint tier, applied alongside the
    /// `faintBandFactor`× band (whichever is tighter wins). At high elevation
    /// the curve is already 25 km, so 2× would reach 50 km — past anything
    /// realistically catchable and past physically-possible altitudes. 35 km
    /// is the sanity bound (it still clears every confirmed-visible datum:
    /// ANA179 19.2 km, GTI9648 16.6 km, all full-tier anyway). Tunable.
    static let faintCeilingMeters: Double = 35_000

    /// Tap-to-reveal plausibility bound (2026-07-12, the NYC couch session,
    /// replay-2026-07-12T150351Z): reveal is the explicit-intent escape hatch
    /// for planes the ambient band hides (FDX1268, 10.9 km @ 3.6°), but with
    /// NO bound it turns dense airspace into a catch-anything button — from a
    /// Manhattan couch, 11 consecutive empty taps revealed planes 27–72 km
    /// out at 0.4–9.6° elevation (and caught a Piper at 75.8 km), all
    /// correctly hidden by the band and none remotely visible. The reveal
    /// reach is the faint band relaxed by this factor — generous enough for
    /// every confirmed-visible marginal field case (FDX1268 10.9 km @ 3.6° →
    /// reach ~15.8 km; SKW5480 18 km @ 12.1° → ~23 km; N21866 5.8 km @ 5°
    /// small → ~8.5 km), tight enough to refuse the whole couch session.
    /// Tunable.
    static let revealBandFactor: Double = 1.5

    /// How far out a tap may still reveal THIS aircraft: the faint band
    /// (elevation-aware curve × `faintBandFactor`, capped by the absolute
    /// ceiling) relaxed by `revealBandFactor`. No hysteresis term — reveal is
    /// a one-shot decision, not a per-frame gate that can flicker.
    var revealReachMeters: Double {
        min(visibilityCapMeters * Self.faintBandFactor, Self.faintCeilingMeters)
            * Self.revealBandFactor
    }

    /// Whether an explicit tap may plausibly reveal this aircraft. Strictly
    /// below the horizon is never revealable (behind terrain/buildings by
    /// definition); the 0–1° skyline gray zone stays revealable — the ambient
    /// floor (`minVisibleElevationDeg` = 1°) keeps it unlabeled, but a tap is
    /// explicit intent. Grounded planes are refused earlier (toast path), and
    /// `visibilityTier` pins them hidden regardless.
    var isPlausiblyRevealable: Bool {
        !grounded && elevationDeg > 0 && slantDistanceMeters < revealReachMeters
    }

    /// The effective distance cap for THIS aircraft: the elevation curve,
    /// halved for small airframes. Field data 2026-06-06: N3001B (a GA
    /// single at 4.8 km / 8°) was confirmed invisible while airliners at
    /// 5.8-8.3 km were confirmed visible — a ~10 m airframe subtends a
    /// third of an airliner's visual angle at the same distance, and
    /// geometry alone can't express that. Small is detected by the US
    /// registration callsign pattern (`N` + digit): GA flies under its
    /// tail number, airlines under ICAO prefixes (UAL/DAL/FDX/...).
    var visibilityCapMeters: Double {
        let base = Self.maxVisibleDistance(forElevationDeg: elevationDeg)
        return aircraft.isLikelySmallAirframe
            ? base * Self.smallAirframeVisibilityFactor
            : base
    }

    /// Cap multiplier for GA-sized airframes. 0.5 hides the confirmed
    /// N3001B ghost (4.8 km @ 8° → cap ~3.3 km) while leaving a real
    /// pattern-traffic window inside ~2-3 km. Tunable.
    static let smallAirframeVisibilityFactor: Double = 0.5

    /// Hysteresis band for the visibility distance cap. An already-shown
    /// plane stays shown until it exceeds `visibilityCapMeters * factor`,
    /// so a plane hovering right at the cap doesn't flicker the AR bracket
    /// (and drop the lock) frame-to-frame. Field report 2026-06-08: ASA733
    /// oscillated across the ~9 km cap by ±0.1-1.1 km across consecutive
    /// ticks; 1.2 (a ~20% band) absorbs that swing while still dropping
    /// planes that genuinely recede past the cap. Tunable.
    static let visibilityHysteresisFactor: Double = 1.2

    /// Elevation-dependent distance cap. A flat cap can't separate real
    /// sightings from ghosts: near the horizon (1-4°) you look through
    /// maximum atmosphere, haze, and terrain/building clutter, so only
    /// close planes actually read to the eye; higher up the background
    /// clears and the allowance grows. Linear ramp from
    /// `nearVisibleDistanceMeters` at the elevation floor up to
    /// `maxVisibleDistanceMeters` at `fullVisibilityElevationDeg`.
    ///
    /// Fitted to tap-pin ground truth from four field sessions
    /// (2026-06-04 night → 2026-06-06 day, 19 labeled planes): every
    /// confirmed sighting was ≤ 5.8 km (4.1 km @ 46°, 4.7 km @ 36°,
    /// 5.8 km @ 16°); every confirmed ghost was ≥ 6.3 km — at every
    /// elevation tested (6.3 km @ 4°, 8.1 km @ 12°, 11 km @ 17.4°,
    /// 33 km @ 10.8°). The current constants separate that data 19/19.
    /// Naked-eye spotting is a single-digit-km activity; the 13 km
    /// band above 30° exists for near-overhead cruise traffic
    /// (contrails), which no ghost observation contradicts.
    ///
    /// CONTRAIL SEGMENT added 2026-06-11: the predicted contrail pruning
    /// happened. Field datum (replay-2026-06-11T161754Z + photo, clear
    /// coastal sky at Sea Ranch): ANA179 at 12.1 km altitude, slant
    /// 19.2 km, elevation 39.1° — clearly visible by contrail, bearing/
    /// elevation matching the camera within a few degrees, pruned by the
    /// old 13 km plateau. A contrail against clear sky reads far beyond
    /// the airframe itself. The curve now keeps the haze-bounded ramp
    /// unchanged below 30° (all Berkeley ghost observations live there)
    /// and adds a second ramp 13 km @ 30° → 25 km @ 45°, flat beyond.
    /// ANA179 (39.1°) passes at 20.3 km allowed vs 19.2 km actual.
    static func maxVisibleDistance(forElevationDeg elevationDeg: Double) -> Double {
        if elevationDeg >= contrailVisibilityElevationDeg { return contrailVisibleDistanceMeters }
        if elevationDeg >= fullVisibilityElevationDeg {
            let f = (elevationDeg - fullVisibilityElevationDeg)
                / (contrailVisibilityElevationDeg - fullVisibilityElevationDeg)
            return maxVisibleDistanceMeters
                + f * (contrailVisibleDistanceMeters - maxVisibleDistanceMeters)
        }
        let f = (elevationDeg - minVisibleElevationDeg)
            / (fullVisibilityElevationDeg - minVisibleElevationDeg)
        return nearVisibleDistanceMeters
            + max(0, f) * (maxVisibleDistanceMeters - nearVisibleDistanceMeters)
    }

    /// Elevation at which the contrail ceiling fully applies, and that
    /// ceiling. High-elevation cruise traffic dragging a contrail reads
    /// far beyond airframe visibility; 25 km covers transpacific cruise
    /// passing well off-track. Tunable — grounded in the 2026-06-11
    /// ANA179 observation above.
    static let contrailVisibilityElevationDeg: Double = 45
    static let contrailVisibleDistanceMeters: Double = 25_000

    /// Distance allowed right at the elevation floor (1°). Lowered
    /// 12 → 4.5 km on 2026-06-06: a 381 m-altitude medevac helicopter at
    /// 9.3 km / 1.9° (REH1) was confirmed invisible — low-elevation
    /// aircraft sit below the urban roofline almost immediately. Tunable.
    static let nearVisibleDistanceMeters: Double = 4_500

    /// Elevation at which the full `maxVisibleDistanceMeters` applies.
    /// 30° keeps a path in for near-overhead cruise traffic (the contrail
    /// case: slant 10-12 km nearly straight up) while staying below every
    /// confirmed ghost, all of which sat at ≤ 17.4°. Tunable.
    static let fullVisibilityElevationDeg: Double = 30

    /// Minimum elevation a plane must clear before we surface it in
    /// the AR overlay. A small buffer trims the literal horizon-edge
    /// ghosts (planes hidden behind hills / skyline / trees).
    ///
    /// Lowered 3 → 1 on 2026-06-01: replaying a real Berkeley session
    /// showed 3° was deleting visible approach/departure traffic at
    /// 1-3° elevation (low over the bay is still in plain sight). 1°
    /// keeps sub-horizon ghosts out without pruning visible low traffic.
    static let minVisibleElevationDeg: Double = 1

    /// The FAR end of the distance cap — applies at and above
    /// `fullVisibilityElevationDeg`, where the plane sits against open
    /// sky.
    ///
    /// History: 30 km originally; flat 20 km (2026-05-26); flat 35 km
    /// (2026-06-01); elevation curve with 25 km plateau (2026-06-04/06).
    /// Lowered to 13 km on 2026-06-06 when the pin protocol delivered
    /// decisive ground truth: across 19 labeled planes, every confirmed
    /// sighting was ≤ 5.8 km and every confirmed ghost ≥ 6.3 km — at all
    /// elevations (an 11 km / 17.4° 737 was invisible in daylight).
    /// Naked-eye spotting range is single-digit km; 13 km at the 30°
    /// plateau exists for near-overhead cruise traffic with contrails.
    /// This constant is the curve's upper plateau — see
    /// `maxVisibleDistance(forElevationDeg:)`.
    static let maxVisibleDistanceMeters: Double = 13_000

    /// Project this aircraft into screen coordinates given the phone's
    /// current pose and the camera's FOV. Returns nil if off-screen.
    /// Default FOV values are estimates for the iPhone main wide camera
    /// in portrait orientation; refine when we query AVCaptureDevice for
    /// the real values.
    ///
    /// `cameraElevationDeg` is the angle above the horizon the camera
    /// is pointing (use MotionManager.cameraElevationDeg, NOT raw pitch).
    /// `rollDeg` is camera roll about the bore-sight (0 = upright; see
    /// `Geo.rollDeg(gravityX:gravityY:gravityZ:)`).
    func screenPosition(
        phoneHeadingDeg: Double,
        cameraElevationDeg: Double,
        rollDeg: Double = 0,
        in screenSize: CGSize,
        hfovDeg: Double = 56,
        vfovDeg: Double = 72
    ) -> CGPoint? {
        Geo.screenPosition(
            targetBearingDeg: bearingDeg,
            targetElevationDeg: elevationDeg,
            phoneHeadingDeg: phoneHeadingDeg,
            cameraElevationDeg: cameraElevationDeg,
            rollDeg: rollDeg,
            screenSize: screenSize,
            hfovDeg: hfovDeg,
            vfovDeg: vfovDeg
        )
    }

    /// Project through a precomputed `CameraBasis`. Preferred in per-frame
    /// loops (label placement, lock-on, zone scans): build the basis once
    /// from the current pose, then each aircraft is three dot products.
    func screenPosition(
        basis: Geo.CameraBasis,
        in screenSize: CGSize,
        hfovDeg: Double = 56,
        vfovDeg: Double = 72
    ) -> CGPoint? {
        Geo.screenPosition(
            targetBearingDeg: bearingDeg,
            targetElevationDeg: elevationDeg,
            basis: basis,
            screenSize: screenSize,
            hfovDeg: hfovDeg,
            vfovDeg: vfovDeg
        )
    }
}

/// Per-cycle counts of where aircraft drop out of the AR overlay:
/// `fetched → onGround → stale → belowElevation → tooFar → shown`.
/// Diagnostic instrumentation added 2026-06-01 to localize which filter
/// clause is pruning genuinely-visible traffic. Surfaced on-screen and via
/// os_log so a single field session pinpoints the culprit.
///
/// `belowElevation` and `tooFar` are counted independently — a plane
/// failing both is tallied in each, so the columns localize blame, they
/// don't partition. `shown` is the authoritative "what the user sees".
struct VisibilityDiagnostic: Equatable, Sendable {
    var fetched = 0
    var onGround = 0
    var stale = 0
    var belowElevation = 0
    var tooFar = 0
    var shown = 0
}

@MainActor
final class ADSBManager: ObservableObject {

    @Published var observed: [ObservedAircraft] = []
    /// icao24s that were in the visible set on the previous `reAnnotate`
    /// frame — the state behind visibility hysteresis. Not published; it's
    /// internal bookkeeping consumed only by the next `reAnnotate`.
    private var shownIcaos: Set<String> = []
    /// Latest visibility-funnel counts (see `VisibilityDiagnostic`). Updated
    /// every `reAnnotate` tick; drives the temporary on-screen tracked/shown
    /// readout while we validate the 2026-06-01 visibility re-tune.
    @Published var diagnostic = VisibilityDiagnostic()
    /// Last funnel we emitted to os_log — so the 1 Hz reAnnotate loop only
    /// logs when the counts actually change, not 60× a minute.
    private var lastLoggedDiagnostic: VisibilityDiagnostic?
    @Published var lastError: String?

    /// Consecutive `refresh` failures since the last success. A single
    /// failed poll on flaky cellular (one bar under an approach corridor)
    /// shouldn't flash THE INTERNET CONNECTION APPEARS TO BE OFFLINE while
    /// the 1 Hz re-annotation loop is still gliding happily on
    /// forward-extrapolated positions. With data on hand we tolerate
    /// `fetchFailureGraceCount` misses (~30 s at the 10 s poll cadence)
    /// before surfacing; if we've NEVER fetched successfully (cold start
    /// while offline) the very first failure surfaces immediately — the
    /// user needs to know why the sky is empty.
    private var consecutiveFetchFailures = 0
    static let fetchFailureGraceCount = 3
    @Published var lastFetched: Date?

    /// Search radius around the user, in km. 50 km comfortably covers the
    /// ~30 km visibility cap with margin for planes climbing into view.
    var radiusKm: Double = 50

    /// Network poll interval. `/v1/aircraft` has no rate limit — the
    /// backend absorbs client polling in a per-region tile cache with a
    /// 10 s TTL, so 10 s is the fastest cadence that can actually see
    /// fresh data; polling harder would only re-read the cache. (The
    /// old 20 s value and its 429 backoff dated from the OpenSky era,
    /// whose per-account quota the 2026-06-21 backend cutover removed.)
    var pollInterval: TimeInterval = 10

    /// How often we re-annotate the last-fetched raw aircraft to "now"
    /// — forward-extrapolating positions and recomputing bearings from
    /// the current observer location. Decoupled from `pollInterval` so
    /// boxes glide smoothly between network fetches instead of jumping
    /// whenever new data arrives.
    var reAnnotationInterval: TimeInterval = 1

    /// The one and only ADS-B source: the Tailspot backend proxy
    /// (api.tailspot.app — adsb.lol data WITH MLAT, so GA aircraft and
    /// helicopters appear, plus merged FAA / DOC-8643 metadata). Both the
    /// bbox poll AND `metadata(for:)` route through it. Injectable so tests
    /// can substitute a fixture. There is no failover — a backend outage
    /// surfaces as an error (visible), not a silent degrade to a sparser
    /// source (which used to hide backend problems mid-session).
    private let source: ADSBSource

    /// The last-fetched aircraft list, kept raw (no annotation). The
    /// re-annotation tick reads from here, extrapolates to "now," and
    /// publishes `observed`. We never publish this directly — SwiftUI
    /// renders from `observed` which is the annotated, sorted view.
    private var rawAircraft: [Aircraft] = []

    private var pollTask: Task<Void, Never>?
    private var reAnnotationTask: Task<Void, Never>?
    private var locationProvider: (@MainActor () -> CLLocation?)?
    /// Per-icao24 metadata memoization. Lookups go through here lazily
    /// when AircraftDetailView appears for a given aircraft.
    private let metadataCache = MetadataCache()

    /// Production uses the real backend (`ADSBManager()`); the `source`
    /// parameter exists so tests can inject a fixture instead of hitting
    /// the network. The no-arg default keeps `ContentView`'s
    /// `@StateObject private var adsb = ADSBManager()` working.
    init(source: ADSBSource = TailspotBackendClient()) {
        self.source = source
    }

    /// Start polling. The provider closure is called on each tick to
    /// fetch the latest user location — passing it as a closure (rather
    /// than holding a strong reference to LocationManager) keeps the two
    /// classes loosely coupled.
    func start(locationProvider: @escaping @MainActor () -> CLLocation?) {
        guard pollTask == nil else { return }
        self.locationProvider = locationProvider

        // Network poll: fetches new state from the backend periodically.
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let loc = self?.locationProvider?() {
                    await self?.refresh(around: loc)
                    try? await Task.sleep(for: .seconds(self?.pollInterval ?? 10))
                } else {
                    // Location not yet available — short retry so we
                    // fetch as soon as the first GPS fix arrives.
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }

        // Smoothness loop: every reAnnotationInterval, re-extrapolate
        // the raw aircraft positions to "now" using the current
        // observer location, recompute angular positions, publish.
        // This is what makes the AR boxes glide smoothly with each
        // plane's motion instead of jumping whenever new ADS-B data
        // arrives.
        let tick = reAnnotationInterval
        reAnnotationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let loc = self?.locationProvider?() {
                    self?.reAnnotate(observer: loc, now: Date())
                }
                try? await Task.sleep(for: .seconds(tick))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        reAnnotationTask?.cancel()
        reAnnotationTask = nil
    }

    /// Single fetch + annotate cycle. Errors are surfaced via lastError;
    /// they never throw out of this method, so the polling loop survives
    /// a network blip.
    ///
    /// On success the raw aircraft list is stashed in `rawAircraft` and
    /// also immediately re-annotated so callers (and tests) see the new
    /// data without waiting for the next smoothness tick.
    func refresh(around location: CLLocation) async {
        let observerLat = location.coordinate.latitude
        let observerLon = location.coordinate.longitude

        // Convert km radius → degrees of latitude/longitude.
        // 1° latitude is ~111 km everywhere.
        // 1° longitude shrinks with latitude: 111 km × cos(lat).
        let dLat = radiusKm / 111.0
        let dLon = radiusKm / (111.0 * cos(observerLat * .pi / 180))

        do {
            let raw = try await source.aircraftInBbox(
                lamin: observerLat - dLat,
                lomin: observerLon - dLon,
                lamax: observerLat + dLat,
                lomax: observerLon + dLon
            )
            self.rawAircraft = raw
            // verbose: log per-plane drop reasons once per network poll
            // (not on the 1 Hz smoothness tick) so the field log isn't spammed.
            self.reAnnotate(observer: location, now: Date(), verbose: true)

            self.lastError = nil
            self.consecutiveFetchFailures = 0
            self.lastFetched = Date()
        } catch {
            self.consecutiveFetchFailures += 1
            if self.lastFetched == nil
                || self.consecutiveFetchFailures >= Self.fetchFailureGraceCount {
                self.lastError = error.localizedDescription
            } else {
                // Within grace: log it, keep the HUD quiet, keep extrapolating.
                Log.adsb.notice("Poll failed (\(self.consecutiveFetchFailures, privacy: .public)/\(Self.fetchFailureGraceCount, privacy: .public), banner suppressed): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Resolve metadata for a single icao24, consulting the in-memory
    /// cache first and falling back to the current source on miss.
    /// A successful response (including a 404 / nil) is cached;
    /// transport errors are NOT cached, so a later tap can retry.
    func metadata(for icao24: String) async -> AircraftMetadata? {
        switch await metadataCache.get(icao24: icao24) {
        case .hit(let value):
            return value
        case .notFetched:
            do {
                let fetched = try await source.aircraftMetadata(icao24: icao24)
                await metadataCache.set(icao24: icao24, value: fetched)
                return fetched
            } catch {
                // Transport error — surface via lastError but do NOT
                // cache. The next tap will retry.
                Log.adsb.error("metadata lookup failed for \(icao24, privacy: .public): \(error.localizedDescription, privacy: .public)")
                self.lastError = "Metadata lookup failed: \(error.localizedDescription)"
                return nil
            }
        }
    }

    /// Build `observed` from `rawAircraft` using the given observer
    /// position and "now" timestamp. Run frequently by the smoothness
    /// loop and once per `refresh` immediately after fetch.
    ///
    /// Cheap: no I/O, only geometry. Safe to call at 1 Hz with 50+
    /// aircraft in the bbox. Annotation logic itself lives on
    /// `ObservedAircraft.annotate(_:observer:now:)` so the replay
    /// analyzer can reuse the exact same geometry.
    private func reAnnotate(observer: CLLocation, now: Date, verbose: Bool = false) {
        var annotated = rawAircraft
            .compactMap {
                ObservedAircraft.annotate($0, observer: observer, now: now)
            }
            .sorted { $0.slantDistanceMeters < $1.slantDistanceMeters }
        // Stamp visibility hysteresis from the prior frame's shown set so a
        // plane hovering at the distance cap doesn't flicker the AR bracket.
        shownIcaos = applyVisibilityHysteresis(&annotated, previouslyShown: shownIcaos)
        self.observed = annotated

        updateDiagnostic(now: now, annotated: annotated, verbose: verbose)
    }

    /// Compute the visibility funnel for instrumentation. Does NOT change
    /// what `observed` holds (consumers still apply `isLikelyVisibleToObserver`
    /// themselves) — this is counts + optional per-plane logs only.
    private func updateDiagnostic(now: Date,
                                  annotated: [ObservedAircraft], verbose: Bool) {
        let maxAge = ObservedAircraft.maxPositionAge
        var diag = VisibilityDiagnostic()
        diag.fetched = rawAircraft.count

        // stale is dropped inside annotate(); onGround now annotates into
        // the hidden tier (grounded easter egg) but still counts here as its
        // own funnel stage — grounded planes are never candidates for the
        // overlay, so the belowElevation/tooFar columns below skip them.
        for ac in rawAircraft {
            if ac.onGround { diag.onGround += 1; continue }
            if let ts = ac.positionTimestamp, now.timeIntervalSince(ts) > maxAge {
                diag.stale += 1
                if verbose {
                    Log.adsb.info("drop STALE \(ac.callsign ?? ac.icao24, privacy: .public) age=\(Int(now.timeIntervalSince(ts)))s (limit \(Int(maxAge))s)")
                }
            }
        }

        for obs in annotated where !obs.grounded {
            let belowElev = obs.elevationDeg <= ObservedAircraft.minVisibleElevationDeg
            let tooFar = obs.slantDistanceMeters >= obs.visibilityCapMeters
            if belowElev { diag.belowElevation += 1 }
            if tooFar { diag.tooFar += 1 }
            if verbose && (belowElev || tooFar) {
                let why = [belowElev ? "low-elev" : nil, tooFar ? "too-far" : nil]
                    .compactMap { $0 }.joined(separator: "+")
                Log.adsb.info("drop \(why, privacy: .public) \(obs.aircraft.callsign ?? obs.aircraft.icao24, privacy: .public) elev=\(String(format: "%.1f", obs.elevationDeg))° dist=\(String(format: "%.1f", obs.slantDistanceMeters / 1000))km")
            }
        }

        diag.shown = annotated.filter(\.isLikelyVisibleToObserver).count
        self.diagnostic = diag

        if diag != lastLoggedDiagnostic {
            Log.adsb.info("visibility funnel: fetched=\(diag.fetched) onGround=\(diag.onGround) stale=\(diag.stale) lowElev=\(diag.belowElevation) tooFar=\(diag.tooFar) → shown=\(diag.shown)")
            lastLoggedDiagnostic = diag
        }
    }
}
