//
//  CatchMode.swift
//  Tailspot
//
//  The catch-mode A/B switch (2026-09-02). PR #229 (frame-is-the-catch)
//  replaced the shipped catch interaction wholesale; to compare the two in
//  the field on ONE build, the pre-#229 model is kept alive as `.legacy`
//  and this enum picks which one the AR view runs.
//
//  Debug seam, single funnel (the [[lesson-debug-seam-single-funnel]]
//  rule): the value is UserDefaults-backed and ONLY honored in DEBUG
//  builds — `effective(stored:)` collapses to `.frame` in Release, so a
//  flipped switch on Noah's phone can never leak into a TestFlight / App
//  Store install that shares the same defaults container. The only setter
//  is the wrench-panel row in ContentView; the screen is badged while
//  `.legacy` is live, and every catch event carries `catch_mode` so the
//  two streams split cleanly in PostHog.
//

import Foundation

/// Which catch interaction the AR view runs.
nonisolated enum CatchMode: String, CaseIterable, Sendable {
    /// Frame-is-the-catch (PR #229, 2026-08-28): press membership =
    /// bright-tier on-frame planes, size-ranked, capped at
    /// `maxCatchTargets`; taps assert, never select.
    case frame
    /// The shipped (v1.1.x App Store) model: tap-to-pin via
    /// `LockOnEngine`, the 100 pt central catch zone, dominance
    /// selection, the lone-plane rule, Gate 5, pre-press detector
    /// tracking of the pinned plane.
    case legacy

    /// UserDefaults key. `tailspot.debug.*` namespace like the gate
    /// toggles (`VisualConfirmationPipeline.localGateKey`).
    static let storageKey = "tailspot.debug.catchMode"

    /// What the app runs when nothing is stored.
    static let `default`: CatchMode = .frame

    /// The mode a stored raw value resolves to. Unknown / nil → default.
    /// Pure so the resolution rule is unit-testable.
    static func resolve(stored raw: String?) -> CatchMode {
        raw.flatMap(CatchMode.init(rawValue:)) ?? .default
    }

    /// The mode the live app should ACTUALLY run for a stored value:
    /// the stored choice on Debug builds, always `.frame` on Release.
    /// Release ignores the store on purpose (see the header).
    static func effective(stored raw: String?) -> CatchMode {
        #if DEBUG
        return resolve(stored: raw)
        #else
        return .frame
        #endif
    }

    /// Short label for the debug row / screen badge / telemetry.
    var label: String {
        switch self {
        case .frame:  return "FRAME"
        case .legacy: return "LEGACY"
        }
    }

    /// The other mode — what the debug row switches to.
    var toggled: CatchMode {
        self == .frame ? .legacy : .frame
    }
}
