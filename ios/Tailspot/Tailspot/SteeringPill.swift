//
//  SteeringPill.swift
//  Tailspot
//
//  The first-catch steering pill: "PLANE IN RANGE · TURN LEFT · 4 KM".
//
//  Why: a third of new users have a catchable plane around them and still
//  never catch one. When the only plane is off-frame (often behind them)
//  the camera shows no label, no pill and no arrow. This pill points them
//  at it. It is deliberately the small slice of draft PR #225 (the full
//  guided first catch); the rest waits on the frame-vs-legacy catch-model
//  verdict (#229), and nothing here depends on which model wins.
//
//  Rules (Noah, 2026-10-23):
//   - zero-catch users only, and gone for good after the first catch
//     (a persisted latch, so deleting that catch doesn't bring it back);
//   - only when a catchable plane is in range but no plane label is on
//     screen;
//   - never on an unreliable compass, because a wrong arrow mis-teaches;
//   - never over a feed error (the error pill wins).
//
//  "Catchable" is the camera's own interactive-visible set (the ambient
//  visibility tier plus any tap-revealed plane; grounded planes never),
//  passed in by ContentView. Turning toward a target from that set puts a
//  catchable label on screen. A plane that is only reveal-reachable would
//  still need a tap, so it isn't steered at.
//
//  Everything here is pure and `nonisolated` so tests drive it without
//  SwiftUI, the same way `ActivationTelemetry` and `Geo` are tested.
//

import Foundation
import CoreGraphics

/// Which way to turn. Raw values are the `steering_pill_shown` telemetry
/// vocabulary; don't rename.
nonisolated enum SteeringDirection: String, Sendable, CaseIterable {
    /// The plane's bearing is inside the horizontal field of view but it is
    /// off the top or bottom of the frame: tilt, don't turn.
    case ahead
    case left
    case right
    case behind
}

/// One steerable plane, as plain values (ContentView builds these from
/// `ObservedAircraft`, whose tier properties are MainActor-bound).
nonisolated struct SteeringTarget: Equatable, Sendable {
    let icao24: String
    /// True bearing from the observer, degrees.
    let bearingDeg: Double
    /// Elevation above the observer's horizon, degrees.
    let elevationDeg: Double
    let slantDistanceMeters: Double
}

/// What the pill shows.
nonisolated struct SteeringHint: Equatable, Sendable {
    let icao24: String
    let direction: SteeringDirection
    /// Target elevation minus camera elevation. Positive = tilt up. Only
    /// read for `.ahead`.
    let elevationDeltaDeg: Double
    let distanceMeters: Double
}

nonisolated enum SteeringPill {

    // MARK: - Eligibility (zero catches, persisted retirement)

    /// Set the first time the app sees a non-empty Hangar. Never cleared:
    /// the pill is a first-catch aid, and a veteran who deletes their only
    /// catch shouldn't get it back. A reinstall wipes it along with the
    /// Hangar, which is right (a fresh install is a fresh first catch).
    static let retiredKey = "tailspot.steering.retired"

    static func isEligible(catchCount: Int, retired: Bool) -> Bool {
        catchCount == 0 && !retired
    }

    // MARK: - Compass gate

    /// Worst heading accuracy (degrees) the pill trusts. Matches the AR
    /// caution banner's arm threshold (`ContentView.compassBadThreshold`):
    /// at 25° the bracket-vs-plane offset is plainly visible, so steering on
    /// a worse heading would point the wrong way about as often as not.
    static let maxHeadingAccuracyDeg: Double = 25

    /// True when the heading is good enough to steer by: a real fix, a
    /// known accuracy (CoreLocation reports a negative value for an invalid
    /// heading) no worse than `maxHeadingAccuracyDeg`, and the caution
    /// banner not latched. The latch matters on its own: once the banner is
    /// up it only clears below ±15°, so between 15° and 25° the user is
    /// being told their compass is off and the pill must not contradict it.
    static func isCompassReliable(
        headingDeg: Double?,
        headingAccuracyDeg: Double?,
        cautionLatched: Bool
    ) -> Bool {
        guard headingDeg != nil, !cautionLatched,
              let acc = headingAccuracyDeg, acc >= 0 else { return false }
        return acc <= maxHeadingAccuracyDeg
    }

    // MARK: - Direction math

    /// Signed shortest-way delta from `fromDeg` to `toDeg`, in -180...180.
    /// Positive = clockwise (turn right). Handles the 359°→1° wrap.
    static func signedDelta(fromDeg: Double, toDeg: Double) -> Double {
        var d = (toDeg - fromDeg).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    /// Past this many degrees either way the copy says BEHIND YOU rather
    /// than a turn: at 135°+ "turn left" and "turn right" are both roughly
    /// right and the user needs to spin, not nudge.
    static let behindThresholdDeg: Double = 135

    /// LEFT / RIGHT / AHEAD / BEHIND for a heading and a target bearing.
    /// AHEAD means the bearing is already inside the horizontal field of
    /// view (`|delta| <= hfov/2`), so the plane must be off the top or
    /// bottom of the frame.
    static func direction(
        headingDeg: Double,
        targetBearingDeg: Double,
        hfovDeg: Double
    ) -> SteeringDirection {
        let delta = signedDelta(fromDeg: headingDeg, toDeg: targetBearingDeg)
        if abs(delta) <= hfovDeg / 2 { return .ahead }
        if abs(delta) >= behindThresholdDeg { return .behind }
        return delta < 0 ? .left : .right
    }

    // MARK: - Target choice (hysteresis borrowed from #225's GuidedCatch)

    /// Nearest by slant, but hold the current target while it's still a
    /// candidate unless a challenger is at least 20% closer, so two planes
    /// at similar range can't flip the arrow every second.
    static func pickTarget(
        current: String?,
        candidates: [SteeringTarget],
        hysteresis: Double = 0.8
    ) -> SteeringTarget? {
        guard let nearest = candidates.min(by: { $0.slantDistanceMeters < $1.slantDistanceMeters }) else {
            return nil
        }
        guard let current,
              let held = candidates.first(where: { $0.icao24 == current }),
              held.icao24 != nearest.icao24
        else { return nearest }
        return nearest.slantDistanceMeters < held.slantDistanceMeters * hysteresis ? nearest : held
    }

    // MARK: - The one decision

    /// The pill to show, or nil. Order: eligibility, feed error, compass,
    /// any label already on screen, then a target. `onScreen` is the same
    /// frustum test the label renderer uses (`Geo.screenPosition`).
    static func hint(
        eligible: Bool,
        hasFeedError: Bool,
        compassReliable: Bool,
        candidates: [SteeringTarget],
        currentTargetIcao24: String?,
        headingDeg: Double,
        cameraElevationDeg: Double,
        hfovDeg: Double,
        onScreen: (SteeringTarget) -> Bool
    ) -> SteeringHint? {
        guard eligible, !hasFeedError, compassReliable, !candidates.isEmpty else { return nil }
        // A label on screen means the user already has something to aim at.
        guard !candidates.contains(where: onScreen) else { return nil }
        guard let target = pickTarget(current: currentTargetIcao24, candidates: candidates) else {
            return nil
        }
        return SteeringHint(
            icao24: target.icao24,
            direction: direction(
                headingDeg: headingDeg, targetBearingDeg: target.bearingDeg, hfovDeg: hfovDeg
            ),
            elevationDeltaDeg: target.elevationDeg - cameraElevationDeg,
            distanceMeters: target.slantDistanceMeters
        )
    }

    /// `hint` with the label renderer's projection plugged in. The frustum
    /// test doesn't depend on the screen's size (the projection normalises
    /// against the half-FOV tangents), so a unit size lets the 1 Hz
    /// telemetry tick, which has no GeometryReader, agree with the render.
    static func hint(
        eligible: Bool,
        hasFeedError: Bool,
        compassReliable: Bool,
        candidates: [SteeringTarget],
        currentTargetIcao24: String?,
        headingDeg: Double,
        cameraElevationDeg: Double,
        rollDeg: Double,
        hfovDeg: Double,
        vfovDeg: Double
    ) -> SteeringHint? {
        let basis = Geo.cameraBasis(
            headingDeg: headingDeg, cameraElevationDeg: cameraElevationDeg, rollDeg: rollDeg
        )
        let unit = CGSize(width: 1, height: 1)
        return hint(
            eligible: eligible,
            hasFeedError: hasFeedError,
            compassReliable: compassReliable,
            candidates: candidates,
            currentTargetIcao24: currentTargetIcao24,
            headingDeg: headingDeg,
            cameraElevationDeg: cameraElevationDeg,
            hfovDeg: hfovDeg,
            onScreen: { t in
                Geo.screenPosition(
                    targetBearingDeg: t.bearingDeg,
                    targetElevationDeg: t.elevationDeg,
                    basis: basis,
                    screenSize: unit,
                    hfovDeg: hfovDeg,
                    vfovDeg: vfovDeg
                ) != nil
            }
        )
    }

    // MARK: - Copy

    /// "4 KM" / "2.5 MI" / "<1 KM". Whole units from 2 up (the pill is a
    /// nudge, not a readout), one decimal below that, and "<1" under one
    /// unit so a close plane doesn't read "0 KM".
    static func distanceText(meters: Double, unit: DistanceUnit) -> String {
        let v = unit.value(meters: meters)
        let sym = unit.symbol.uppercased()
        if v < 1 { return "<1 \(sym)" }
        if v < 2 { return String(format: "%.1f %@", v, sym) }
        return "\(Int(v.rounded())) \(sym)"
    }

    /// The middle segment of the pill.
    static func directionText(_ hint: SteeringHint) -> String {
        switch hint.direction {
        case .left: "TURN LEFT"
        case .right: "TURN RIGHT"
        case .behind: "BEHIND YOU"
        case .ahead: hint.elevationDeltaDeg >= 0 ? "TILT UP" : "TILT DOWN"
        }
    }

    /// "PLANE IN RANGE · TURN LEFT · 4 KM" — mono ALL-CAPS, the empty-sky
    /// pill's own register. Spaces inside each segment are non-breaking, so
    /// when the pill wraps at accessibility type sizes it breaks at a " · "
    /// and never inside "BEHIND YOU" or "4 KM".
    static func text(_ hint: SteeringHint, unit: DistanceUnit) -> String {
        ["PLANE IN RANGE", directionText(hint), distanceText(meters: hint.distanceMeters, unit: unit)]
            .map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }
            .joined(separator: " · ")
    }

    // MARK: - Telemetry

    static let shownEvent = "steering_pill_shown"
    static let caughtEvent = "steering_pill_caught"

    /// Coarse distance buckets for `steering_pill_shown` (always km, so the
    /// dashboard doesn't split on the user's unit setting).
    static func distanceBucket(meters: Double) -> String {
        switch meters {
        case ..<2_000: "<2km"
        case ..<5_000: "2-5km"
        case ..<10_000: "5-10km"
        case ..<20_000: "10-20km"
        default: "20km+"
        }
    }

    static func shownProperties(
        _ hint: SteeringHint,
        headingAccuracyDeg: Double?
    ) -> [String: AnalyticsValue] {
        var props: [String: AnalyticsValue] = [
            "direction": .string(hint.direction.rawValue),
            "distance_bucket": .string(distanceBucket(meters: hint.distanceMeters)),
        ]
        if let a = headingAccuracyDeg, a >= 0 { props["heading_accuracy_deg"] = .double(a) }
        return props
    }

    /// Once per session; the caller holds the latch.
    static func fireShown(_ hint: SteeringHint, headingAccuracyDeg: Double?) {
        Analytics.capture(shownEvent, shownProperties(hint, headingAccuracyDeg: headingAccuracyDeg))
    }

    /// The first catch landed in a session where the pill had shown. The
    /// funnel is shown → caught, both per person.
    static func fireCaught(secondsSinceShown: Double) {
        Analytics.capture(caughtEvent, ["seconds_since_shown": .double(secondsSinceShown.rounded())])
    }
}
