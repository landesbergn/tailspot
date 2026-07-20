//
//  FarToastRegressionTests.swift
//  TailspotTests
//
//  Field regression for the Dumbarton/Oakland far-toast bug (2026-07-19,
//  fixed 2026-07-20): six consecutive empty-sky taps at a visible plane all
//  classified `filtered-far` and toasted "Nearest plane is ~28 km out"
//  (SKW3789) / "~10 km out" (N20230) while the user was looking at a real
//  plane. Ground truth is the on-device recording, bundled LOCAL-ONLY as
//  `local-fartoast-2026-07-19.jsonl` (gitignored — same tier as
//  FailureModeRegressionTests; the suite SKIPS on CI where the file is
//  absent).
//
//  The test replays every recorded empty-tap through the SAME geometry the
//  live tap handler uses (ObservedAircraft.annotate + Geo camera basis at
//  the aligned tick's pose/zoom) and pins the intended post-fix behavior:
//  the old tier-blind selection must still reproduce `filtered-far` (the
//  bug is real and stays reproducible), and the fixed pipeline must never
//  emit a far-toast claim while an actionable plane sits in the data.
//

import CoreGraphics
import CoreLocation
import Foundation
import Testing

@testable import Tailspot

/// Bundle hook — Swift Testing has no Bundle.module in xcodeproj targets.
private final class FarToastReplayToken {}

@MainActor
@Suite("Far-toast field regression (local)")
struct FarToastRegressionTests {

    nonisolated static var fixtureURL: URL? {
        Bundle(for: FarToastReplayToken.self)
            .url(forResource: "local-fartoast-2026-07-19", withExtension: "jsonl")
    }

    /// iPhone 16 portrait defaults, matching `ReplayAnalyzer`'s.
    private static let screenSize = CGSize(width: 393, height: 852)
    private static let baseHfovDeg = 56.0
    private static let baseVfovDeg = 72.0

    /// Rebuild the empty-sky-tap candidate set for one recorded tap,
    /// mirroring `recordEmptySkyTapDiagnosis` exactly: annotate the aligned
    /// tick's raw aircraft with the tick's observer pose, compute each
    /// plane's angular offset from the tapped direction under the tick's
    /// heading/elevation/zoom, and snapshot tier/reveal facts.
    private func candidates(
        tap: ReplayEvent.EmptyTap, tick: ReplayEvent.Tick
    ) throws -> (candidates: [EmptySkyTapCandidate], observed: [ObservedAircraft]) {
        let s = tick.sensor
        let lat = try #require(s.latitude)
        let lon = try #require(s.longitude)
        let heading = try #require(s.headingDeg)
        let observer = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: s.altitudeMeters ?? 0,
            horizontalAccuracy: s.horizontalAccuracyMeters ?? 10,
            verticalAccuracy: 10,
            timestamp: tick.timestamp
        )
        let observed = tick.aircraft.compactMap {
            ObservedAircraft.annotate(Aircraft($0), observer: observer, now: tick.timestamp)
        }
        let zoom = s.zoomFactor ?? 1.0
        let hfovDeg = Self.baseHfovDeg / zoom
        let vfovDeg = Self.baseVfovDeg / zoom
        // Gravity-derived roll, matching ReplayAnalyzer (Euler rollRad is
        // unreliable at the portrait hold).
        let rollDeg: Double
        if let gx = s.gravityX, let gy = s.gravityY, let gz = s.gravityZ {
            rollDeg = Geo.rollDeg(gravityX: gx, gravityY: gy, gravityZ: gz)
        } else {
            rollDeg = 0
        }
        let basis = Geo.cameraBasis(
            headingDeg: heading,
            cameraElevationDeg: s.cameraElevationDeg,
            rollDeg: rollDeg
        )
        let tapAzDeg = (Double(tap.x) / Double(Self.screenSize.width) - 0.5) * hfovDeg
        let tapElDeg = (0.5 - Double(tap.y) / Double(Self.screenSize.height)) * vfovDeg

        var out: [EmptySkyTapCandidate] = []
        for (i, obs) in observed.enumerated() {
            let v = Geo.cameraFrameVector(
                targetBearingDeg: obs.bearingDeg,
                targetElevationDeg: obs.elevationDeg,
                basis: basis
            )
            let azDeg = atan2(v.x, max(v.z, 1e-6)) * 180 / .pi
            let elDeg = atan2(v.y, max(v.z, 1e-6)) * 180 / .pi
            let off = v.z <= 0
                ? 180.0
                : ((azDeg - tapAzDeg) * (azDeg - tapAzDeg)
                    + (elDeg - tapElDeg) * (elDeg - tapElDeg)).squareRoot()
            out.append(EmptySkyTapCandidate(
                index: i,
                offsetDeg: off,
                onScreen: obs.screenPosition(
                    basis: basis, in: Self.screenSize,
                    hfovDeg: hfovDeg, vfovDeg: vfovDeg
                ) != nil,
                grounded: obs.grounded,
                tier: obs.visibilityTier,
                plausiblyRevealable: obs.isPlausiblyRevealable
            ))
        }
        return (out, observed)
    }

    @Test(.enabled(if: FarToastRegressionTests.fixtureURL != nil))
    func recordedTapsNeverToastWhileAnActionablePlaneIsInData() throws {
        let url = try #require(Self.fixtureURL)
        let events = try ReplayJSONL.decode(Data(contentsOf: url))
        let ordered = events.sorted { $0.timestamp < $1.timestamp }
        let ticks = ordered.compactMap { if case .tick(let t) = $0 { t } else { nil } }
        let taps = ordered.compactMap { if case .emptyTap(let t) = $0 { t } else { nil } }
        try #require(!ticks.isEmpty)
        try #require(!taps.isEmpty)

        var oldFilteredFar = 0
        for tap in taps {
            // Align to the tick on screen at the tap (latest at-or-before;
            // first tick for a tap that precedes it).
            let tick = ticks.last(where: { $0.timestamp <= tap.timestamp }) ?? ticks[0]
            let (cands, observed) = try candidates(tap: tap, tick: tick)

            // OLD behavior (tier-blind angular minimum) — keep the bug
            // reproducible: the recording's own diagnosis said filtered-far.
            if let primary = cands.min(by: { $0.offsetDeg < $1.offsetDeg }) {
                let oldReason = classifyEmptySkyTapNearest(
                    offsetDeg: primary.offsetDeg, grounded: primary.grounded,
                    tier: primary.tier, onScreen: primary.onScreen,
                    plausiblyRevealable: primary.plausiblyRevealable
                )
                if oldReason == "filtered-far" { oldFilteredFar += 1 }
            }

            // NEW pipeline: subject selection + honesty guard.
            let choice = chooseEmptySkyTapSubject(cands)
            let anyActionable = observed.contains { $0.isPlausiblyRevealable }
            if choice?.reason == "filtered-far" {
                let slant = farTapToastSlantMeters(airborne: observed
                    .filter { !$0.grounded }
                    .map { ($0.slantDistanceMeters, $0.isPlausiblyRevealable) })
                // The fix's contract: no far-toast claim while an actionable
                // plane is anywhere in the data.
                #expect(!(anyActionable && slant != nil),
                        "tap at \(tap.timestamp) would still toast despite an actionable plane in data")
                // When the toast IS allowed, it must quote the distance-
                // nearest airborne plane, not the angular winner.
                if let slant {
                    let minSlant = observed.filter { !$0.grounded }
                        .map(\.slantDistanceMeters).min()
                    #expect(slant == minSlant)
                }
            }
        }

        // The recording reproduced the bug under the old selection — if this
        // ever drops to zero the fixture no longer covers the regression.
        #expect(oldFilteredFar == taps.count,
                "expected every recorded tap to reproduce filtered-far under the old selection (got \(oldFilteredFar)/\(taps.count))")
    }

    /// Human-readable per-tap reconstruction, printed on demand while
    /// triaging (run with `-only-testing` and read the output). Not an
    /// assertion — the pinned contract lives in the test above.
    @Test(.enabled(if: FarToastRegressionTests.fixtureURL != nil))
    func printTapDiagnoses() throws {
        let url = try #require(Self.fixtureURL)
        let events = try ReplayJSONL.decode(Data(contentsOf: url))
        let ordered = events.sorted { $0.timestamp < $1.timestamp }
        let ticks = ordered.compactMap { if case .tick(let t) = $0 { t } else { nil } }
        let taps = ordered.compactMap { if case .emptyTap(let t) = $0 { t } else { nil } }

        var diag: [String] = []
        for (n, tap) in taps.enumerated() {
            let tick = ticks.last(where: { $0.timestamp <= tap.timestamp }) ?? ticks[0]
            let (cands, observed) = try candidates(tap: tap, tick: tick)
            let choice = chooseEmptySkyTapSubject(cands)
            var line = "tap#\(n) recorded=\(tap.reason)/\(tap.nearestCallsign ?? "—")"
            if let c = choice {
                let obs = observed[c.candidate.index]
                line += " → new=\(c.reason)\(c.rescued ? " (rescued)" : "")"
                line += " subject=\(obs.aircraft.callsign ?? obs.aircraft.icao24)"
                line += String(format: " %.1f km @ %+.1f° off=%.1f°",
                               obs.slantDistanceMeters / 1000, obs.elevationDeg,
                               c.candidate.offsetDeg)
            }
            let slant = farTapToastSlantMeters(airborne: observed
                .filter { !$0.grounded }
                .map { ($0.slantDistanceMeters, $0.isPlausiblyRevealable) })
            line += slant.map { String(format: " toast=%.1f km", $0 / 1000) } ?? " toast=suppressed"
            print("[far-toast-regression] \(line)")
            diag.append(line)
        }
        #expect(!taps.isEmpty)
    }
}
