//
//  ReviewPrompt.swift
//  Tailspot
//
//  The in-app App Store review ask (v1.1 R7): request the system rating
//  sheet at a high moment — after a trophy-unlock celebration completes —
//  never during capture or the reveal.
//
//  Split like the trophy machinery: `ReviewPromptPolicy` is the pure,
//  directly-testable decision ("should this drain ask?"), and
//  `ReviewPrompter` is the @MainActor side-effect owner (UserDefaults
//  stamp + analytics + the StoreKit call, injectable for tests).
//
//  Timing contract: the ONLY trigger is `TrophyUnlockCenter`'s tap-through
//  drain (the user tapped through every queued celebration). That moment is
//  structurally safe — the celebration overlay is a full-screen takeover
//  that only presents when no reveal or sheet is up, so a capture can never
//  be in flight when it fires. `skipAll` deliberately does NOT trigger
//  (skipping signals a hurry — the worst time to beg), and neither does the
//  one-time roster recap (an update moment, not a fresh achievement).
//
//  Apple's own throttle (at most 3 prompts per 365 days, and the sheet may
//  be silently suppressed) sits under ours; StoreKit never reports whether
//  the sheet actually appeared, so the version stamp commits on REQUEST,
//  not on display — at most one ask per public release, even if the OS
//  swallowed it.
//

import Foundation
import StoreKit
import UIKit

/// Pure eligibility decision — free of I/O so it unit-tests directly.
nonisolated enum ReviewPromptPolicy {

    /// Floor before the app is allowed to ask at all. The first trophy
    /// ("Catcher" bronze) unlocks on the very first catch — asking for a
    /// rating thirty seconds into someone's first session is premature.
    /// Three catches means the moment repeats on a user who came back.
    static let minimumCatches = 3

    /// One ask per public release: eligible again only after
    /// `MARKETING_VERSION` moves past the stamped one.
    static func shouldRequest(
        totalCatches: Int,
        currentVersion: String,
        lastPromptedVersion: String?
    ) -> Bool {
        guard totalCatches >= minimumCatches else { return false }
        return currentVersion != lastPromptedVersion
    }
}

/// Owns the ask's side effects: the once-per-version stamp, the analytics
/// breadcrumb, and the StoreKit request. `request` is injectable so tests
/// observe the fire without touching StoreKit.
@MainActor
final class ReviewPrompter {

    static let shared = ReviewPrompter()

    private static let lastVersionKey = "reviewPromptLastVersion"

    private let defaults: UserDefaults
    private let currentVersion: String
    private let request: () -> Void

    init(
        defaults: UserDefaults = .standard,
        currentVersion: String = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
        request: @escaping () -> Void = ReviewPrompter.presentSystemSheet
    ) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.request = request
    }

    var lastPromptedVersion: String? {
        defaults.string(forKey: Self.lastVersionKey)
    }

    /// The trophy-celebration drain hook (see the timing contract above).
    /// `totalCatches` is the Hangar size the unlock center last diffed.
    func celebrationCompleted(totalCatches: Int) {
        guard ReviewPromptPolicy.shouldRequest(
            totalCatches: totalCatches,
            currentVersion: currentVersion,
            lastPromptedVersion: lastPromptedVersion
        ) else { return }
        // Stamp BEFORE the request: StoreKit gives no shown/suppressed
        // signal, so the invariant is at-most-one REQUEST per version.
        defaults.set(currentVersion, forKey: Self.lastVersionKey)
        Analytics.capture("review_prompt_requested", [
            "trigger": .string("trophy_unlock"),
            "total_catches": .int(totalCatches),
        ])
        request()
    }

    #if DEBUG
    /// Clear the once-per-version stamp so the ask can be exercised
    /// repeatedly on-device (dev builds always display the sheet; the
    /// stamp would otherwise burn on the first trophy drain). Wired into
    /// the debug overlay — never ship a reset path.
    func debugClearStamp() {
        defaults.removeObject(forKey: Self.lastVersionKey)
    }
    #endif

    /// The real ask: the system rating sheet over the foreground scene.
    /// Display is the OS's call — it may quietly decline (its 3-per-365
    /// budget, or the user disabled in-app rating requests system-wide).
    private static func presentSystemSheet() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }
        AppStore.requestReview(in: scene)
    }
}
