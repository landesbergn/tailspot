//
//  CatchMode.swift
//  Tailspot
//
//  The catch-rule feature flag. PR #229 (frame-is-the-catch) replaced the
//  shipped catch interaction wholesale; it ships DARK behind the PostHog
//  flag `frame-is-the-catch`, with the shipped zones-and-pins model kept
//  alive as `.legacy` — the default for everyone the flag doesn't target.
//  (Began 2026-09-02 as a Debug-only A/B; became a remote flag 2026-10-25
//  so #229 can merge to main and ride trains switched off.)
//
//  Resolution (`effective`), one funnel:
//    1. DEBUG only: a wrench-panel override, if set, wins.
//    2. Otherwise the PostHog flag: enabled → `.frame`, anything else
//       (off, not yet loaded, analytics keyless) → `.legacy`.
//  Release never reads the override key, so a flipped Debug phone can't
//  leak into a TestFlight / App Store install that shares the defaults
//  container. Every catch event carries `catch_mode`, and PostHog's own
//  `$feature_flag_called` records which value each person saw.
//
//  Swift pattern note: `CatchModeFlag` is `@Observable` (the Observation
//  framework, iOS 17+): SwiftUI views that READ `remoteEnabled` re-render
//  when it changes, without `@Published` / `ObservableObject` plumbing.
//

import Foundation
import Observation
import os
import PostHog

/// Which catch interaction the AR view runs.
nonisolated enum CatchMode: String, CaseIterable, Sendable {
    /// Frame-is-the-catch (PR #229, 2026-08-28): press membership =
    /// bright-tier on-frame planes, size-ranked, capped at
    /// `maxCatchTargets`; taps assert, never select.
    case frame
    /// The shipped App Store model: tap-to-pin via `LockOnEngine`, the
    /// 100 pt central catch zone, dominance selection, the lone-plane
    /// rule, Gate 5, pre-press detector tracking of the pinned plane.
    case legacy

    /// UserDefaults key for the Debug wrench override. `tailspot.debug.*`
    /// namespace like the gate toggles. Absent = follow the PostHog flag.
    static let storageKey = "tailspot.debug.catchMode"

    /// PostHog feature-flag key. Boolean flag; ON = the frame rule.
    static let remoteFlagKey = "frame-is-the-catch"

    /// What runs when the flag is off or unknown: the shipped rule.
    static let `default`: CatchMode = .legacy

    /// The mode the PostHog flag alone selects.
    static func fromRemote(enabled: Bool) -> CatchMode {
        enabled ? .frame : .default
    }

    /// The mode a stored override resolves to. nil / unknown → no override.
    static func override(stored raw: String?) -> CatchMode? {
        raw.flatMap(CatchMode.init(rawValue:))
    }

    /// Pure resolution rule, testable on both build kinds.
    /// `honorOverride` is true only on DEBUG builds (see `effective`).
    static func resolve(override raw: String?, remoteEnabled: Bool, honorOverride: Bool) -> CatchMode {
        if honorOverride, let forced = override(stored: raw) { return forced }
        return fromRemote(enabled: remoteEnabled)
    }

    /// The mode the live app should ACTUALLY run: the Debug override when
    /// one is set, else the PostHog flag. Release ignores the override.
    static func effective(override raw: String?, remoteEnabled: Bool) -> CatchMode {
        #if DEBUG
        return resolve(override: raw, remoteEnabled: remoteEnabled, honorOverride: true)
        #else
        return resolve(override: raw, remoteEnabled: remoteEnabled, honorOverride: false)
        #endif
    }

    /// Short label for the debug row / screen badge. (Telemetry uses
    /// `rawValue`, which stays "frame" / "legacy".)
    var label: String {
        switch self {
        case .frame:  return "NEW"
        case .legacy: return "OLD"
        }
    }
}

/// The remote half of the catch-rule flag: the PostHog value, applied at
/// SESSION boundaries only. A rule that changes under the user's thumb
/// mid-aim (pins vanish, the ×N badge recounts) reads as a bug, so the
/// value is read once at launch (PostHog serves its disk cache before the
/// network answers) and re-read when the app comes to the foreground.
/// Flipping the flag in PostHog therefore lands on the next foreground.
@MainActor
@Observable
final class CatchModeFlag {
    static let shared = CatchModeFlag()

    /// Whether the PostHog flag is on for this person, as last applied.
    private(set) var remoteEnabled: Bool

    private let read: () -> Bool
    private let reload: (@escaping () -> Void) -> Void

    /// Test seam: inject the reader and the reloader. Production reads
    /// PostHog; when analytics is keyless the SDK isn't set up and
    /// `isFeatureEnabled` answers false, so the flag reads as off.
    init(
        read: @escaping () -> Bool = { PostHogSDK.shared.isFeatureEnabled(CatchMode.remoteFlagKey) },
        reload: @escaping (@escaping () -> Void) -> Void = { PostHogSDK.shared.reloadFeatureFlags($0) }
    ) {
        self.read = read
        self.reload = reload
        self.remoteEnabled = read()
        // Cold launch is a session start too, and `.onChange(of:
        // scenePhase)` doesn't fire for the initial `.active`.
        fetchFresh()
    }

    /// Foreground hook: apply the cached value now, then a fresh one.
    func refreshForNewSession() {
        apply(read())
        fetchFresh()
    }

    /// Ask PostHog for a fresh value and apply it when it lands (a second
    /// or so in — still the start of the session, before anything is
    /// aimed). PostHog calls back off the main thread, hence the hop.
    private func fetchFresh() {
        reload { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.apply(self.read())
            }
        }
    }

    private func apply(_ value: Bool) {
        guard value != remoteEnabled else { return }
        remoteEnabled = value
        Log.ui.notice("Catch rule flag \(CatchMode.remoteFlagKey, privacy: .public) → \(value, privacy: .public)")
    }
}
