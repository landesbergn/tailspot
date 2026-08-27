//
//  GuidedCatch.swift
//  Tailspot
//
//  The guided first-catch engine (PLAN docs/plans/2026-08-27-0834, U1).
//  ONE funnel owns all guided-mode state: whether the mode is active,
//  which coaching step is current, and which plane steering points at.
//  ContentView feeds it plain values (catch count, candidate list, pose,
//  flags) and renders whatever comes back — no reader anywhere else
//  derives guided state on its own (KTD1, the Streaks.summary lesson:
//  a debug override honoured by only some readers made two screens
//  disagree; here the override is a synthetic INPUT into this single
//  seam).
//
//  Everything is pure and nonisolated so TailspotTests can drive it
//  without a MainActor or SwiftUI. The caller supplies candidates
//  computed from the label pipeline's own visible set (KTD3 — the
//  visibility filter is purely geometric, so off-frame planes already
//  pass it; a parallel range definition could drift and steer at a
//  plane the tier computation classifies hidden).
//
//  Retirement is a persisted latch, not a live zero-catch check (KTD2):
//  set when the first catch resolves as kept, so a discarded suspect
//  first catch re-arms the mode (plan A2), and celebration/telemetry
//  state can never disagree with the trigger.
//

import Foundation

/// One steerable plane, as plain values. Built by ContentView from the
/// label pipeline's candidate set; the engine never touches
/// `ObservedAircraft` (MainActor-isolated tier properties).
nonisolated struct GuidedCandidate: Equatable {
    let icao24: String
    /// True bearing from the observer to the plane, degrees 0..<360.
    let bearingDeg: Double
    /// Elevation above the observer's horizon, degrees.
    let elevationDeg: Double
    let slantDistanceMeters: Double
    /// Short label for the steering tag (callsign or model), best-effort.
    let displayName: String?
}

/// Where to turn to bring the target into frame. `turnDeg` is the signed
/// shortest-way delta from the phone's heading to the target bearing:
/// positive = turn right, negative = turn left; |turnDeg| > 90 reads as
/// "behind you". `elevationDeltaDeg` is target elevation minus camera
/// elevation: positive = tilt up.
nonisolated struct GuidedSteering: Equatable {
    let icao24: String
    let turnDeg: Double
    let elevationDeltaDeg: Double
    let distanceMeters: Double
    let displayName: String?

    var isBehind: Bool { abs(turnDeg) > 90 }
}

/// The coaching step the viewfinder renders. Order of the guards that
/// produce these is fixed (plan U1): Scanning > GoOutside > Calibrate >
/// QuietSky > Find/Center/Capture.
nonisolated enum GuidedCatchStep: Equatable {
    /// No ADS-B response yet — never claim a quiet sky before data loads.
    case scanning
    /// `pointedIndoors` latched — the honest first step is going outside.
    case goOutside
    /// Compass warning latched — steering on a bad heading mis-teaches
    /// (KD5); prompt calibration instead of pointing arrows.
    case calibrate
    /// Data loaded, nothing catchable in range (R6).
    case quietSky
    /// A target exists but is not on screen. Steering is nil when the
    /// heading is unavailable (pre-GPS-fix) — banner without an arrow.
    case find(GuidedSteering?)
    /// Target projects on screen; capture not yet enabled — center it.
    case center
    /// Capture is enabled — the pulse moment.
    case capture
}

nonisolated struct GuidedCatchInputs {
    var hasFirstADSBResponse: Bool
    var pointedIndoors: Bool
    var compassWarningLatched: Bool
    var candidates: [GuidedCandidate]
    /// The engine's previously chosen target, for hysteresis.
    var currentTargetIcao24: String?
    /// Phone true heading, nil before the first fix.
    var headingDeg: Double?
    var cameraElevationDeg: Double
    /// Icaos currently projecting inside the camera frame.
    var onScreenIcaos: Set<String>
    /// The capture button's enablement (any catchable mode).
    var captureEnabled: Bool
}

nonisolated struct GuidedDerivation: Equatable {
    let step: GuidedCatchStep
    /// The chosen steering target, carried across ticks for hysteresis.
    let targetIcao24: String?
}

nonisolated enum GuidedCatch {

    // MARK: - Activation (KTD1 seam, KTD2 latch)

    /// Persisted retirement latch. Set only when a first catch resolves as
    /// kept (immediately for a non-suspect catch, on Keep for a suspect
    /// one — U3 owns the call site). A reinstall wipes it together with
    /// the Hangar, which is correct: a fresh install is a fresh first
    /// catch.
    static let retiredKey = "tailspot.guided.retired"

    static func isRetired(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: retiredKey)
    }

    static func markRetired(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: retiredKey)
    }

    /// THE mode trigger. The debug override feeds a synthetic input
    /// (`forcedZeroCatches`) rather than overriding the output, so every
    /// reader that goes through this seam agrees, and telemetry that
    /// checks `isForced` separately can stay honest.
    static func isModeActive(
        catchCount: Int,
        retired: Bool,
        forcedZeroCatches: Bool = false
    ) -> Bool {
        let effectiveCount = forcedZeroCatches ? 0 : catchCount
        guard effectiveCount == 0 else { return false }
        // The latch only matters for the discard edge (count back to 0
        // after celebration) and manual deletes — forced runs never set it.
        return forcedZeroCatches || !retired
    }

    // MARK: - Target selection (KTD3 hysteresis)

    /// Nearest-by-slant with stickiness: hold the current target while it
    /// remains a candidate unless a challenger is at least 20% closer, so
    /// the arrow doesn't flip between polls/re-annotations.
    static func pickTarget(
        current: String?,
        candidates: [GuidedCandidate],
        hysteresis: Double = 0.8
    ) -> GuidedCandidate? {
        guard let nearest = candidates.min(by: { $0.slantDistanceMeters < $1.slantDistanceMeters }) else {
            return nil
        }
        guard
            let current,
            let held = candidates.first(where: { $0.icao24 == current }),
            held.icao24 != nearest.icao24
        else { return nearest }
        return nearest.slantDistanceMeters < held.slantDistanceMeters * hysteresis ? nearest : held
    }

    // MARK: - Steering math

    /// Signed shortest-way angular delta, normalized to -180..180.
    static func signedDelta(fromDeg: Double, toDeg: Double) -> Double {
        var d = (toDeg - fromDeg).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    static func steering(
        to target: GuidedCandidate,
        headingDeg: Double,
        cameraElevationDeg: Double
    ) -> GuidedSteering {
        GuidedSteering(
            icao24: target.icao24,
            turnDeg: signedDelta(fromDeg: headingDeg, toDeg: target.bearingDeg),
            elevationDeltaDeg: target.elevationDeg - cameraElevationDeg,
            distanceMeters: target.slantDistanceMeters,
            displayName: target.displayName
        )
    }

    // MARK: - Step derivation

    static func deriveStep(_ inputs: GuidedCatchInputs) -> GuidedDerivation {
        guard inputs.hasFirstADSBResponse else {
            return GuidedDerivation(step: .scanning, targetIcao24: inputs.currentTargetIcao24)
        }
        guard !inputs.pointedIndoors else {
            return GuidedDerivation(step: .goOutside, targetIcao24: inputs.currentTargetIcao24)
        }
        guard !inputs.compassWarningLatched else {
            return GuidedDerivation(step: .calibrate, targetIcao24: inputs.currentTargetIcao24)
        }
        guard let target = pickTarget(
            current: inputs.currentTargetIcao24,
            candidates: inputs.candidates
        ) else {
            return GuidedDerivation(step: .quietSky, targetIcao24: nil)
        }

        if inputs.onScreenIcaos.contains(target.icao24) {
            return GuidedDerivation(
                step: inputs.captureEnabled ? .capture : .center,
                targetIcao24: target.icao24
            )
        }
        let steer = inputs.headingDeg.map {
            steering(to: target, headingDeg: $0, cameraElevationDeg: inputs.cameraElevationDeg)
        }
        return GuidedDerivation(step: .find(steer), targetIcao24: target.icao24)
    }
}

#if DEBUG
/// Debug-only forced mode (R10). Cycled from the wrench panel; feeds the
/// synthetic `forcedZeroCatches` INPUT into `GuidedCatch.isModeActive` —
/// never a per-reader output override. Release builds compile none of
/// this out of existence.
nonisolated enum GuidedCatchDebug {
    static let forcedKey = "tailspot.debug.guidedForced"

    static func isForced(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: forcedKey)
    }

    static func setForced(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: forcedKey)
    }
}
#endif
