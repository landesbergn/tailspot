//
//  ReviewPrompt.swift
//  Tailspot
//
//  The in-app App Store review ask (v1.1 R7): request the system rating
//  sheet at a high moment — right after a catch's reveal closes, once the
//  user's Hangar says they're sticky — never during capture or the reveal.
//
//  Split like the trophy machinery: `ReviewPromptPolicy` is the pure,
//  directly-testable decision ("is this user sticky, and may this version
//  still ask?"), and `ReviewPrompter` is the @MainActor side-effect owner
//  (UserDefaults stamp + analytics + the StoreKit call, injectable for
//  tests).
//
//  "Sticky" is data-derived (prod catches table, 2026-08-25, 39 devices):
//  the later-day return rate flattens at ~91% from the 2nd–3rd catch on,
//  so the floor is 3 total catches — BUT 14 of 33 devices hit their 3rd
//  catch in a single day (an airport rapid-fire triple), and a first
//  session isn't stickiness however hot it runs. Requiring a 2nd distinct
//  catch-day makes "they came back" true by construction; the day-1 triple
//  crowd is simply deferred to their next catch day, which ~91% reach.
//
//  Timing contract: the ONLY trigger is the post-reveal moment funnel in
//  ContentView (`presentSuspectReviewIfNeeded`), and the ask is that
//  funnel's LOWEST priority — the save-failure toast, the streak
//  pre-prompt, the suspect Keep/Discard review, a jump to the Hangar, and
//  a pending trophy celebration all claim the moment first. A contested
//  moment DROPS the ask rather than queueing it; eligibility is durable,
//  so it simply re-tries when the next catch's reveal closes.
//
//  Apple's own throttle (at most 3 displays per 365 days, and the sheet
//  may be silently suppressed) sits under ours; StoreKit never reports
//  whether the sheet actually appeared, so the version stamp commits on
//  REQUEST, not on display — at most one ask per public release, even if
//  the OS swallowed it.
//

import Foundation
import StoreKit
import UIKit

/// Pure eligibility decision — free of I/O so it unit-tests directly.
nonisolated enum ReviewPromptPolicy {

    /// Floor before the app is allowed to ask at all. See the header for
    /// the prod-data derivation (later-day return flattens ~91% here).
    static let minimumCatches = 3

    /// Catches on at least this many distinct local days (`Streaks.dayKey`
    /// buckets) — the comeback, not the first-session hot streak, is the
    /// stickiness signal (42% of devices reach 3 catches on day 1).
    static let minimumCatchDays = 2

    /// One ask per public release: eligible again only after
    /// `MARKETING_VERSION` moves past the stamped one.
    static func shouldRequest(
        totalCatches: Int,
        distinctCatchDays: Int,
        currentVersion: String,
        lastPromptedVersion: String?
    ) -> Bool {
        guard totalCatches >= minimumCatches else { return false }
        guard distinctCatchDays >= minimumCatchDays else { return false }
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

    /// The post-reveal hook (see the timing contract above): a catch's
    /// reveal closed and nothing else claimed the moment. Both counts come
    /// from the caller's live Hangar snapshot.
    func catchMomentEnded(totalCatches: Int, distinctCatchDays: Int) {
        guard ReviewPromptPolicy.shouldRequest(
            totalCatches: totalCatches,
            distinctCatchDays: distinctCatchDays,
            currentVersion: currentVersion,
            lastPromptedVersion: lastPromptedVersion
        ) else { return }
        // Stamp BEFORE the request: StoreKit gives no shown/suppressed
        // signal, so the invariant is at-most-one REQUEST per version.
        defaults.set(currentVersion, forKey: Self.lastVersionKey)
        Analytics.capture("review_prompt_requested", [
            "trigger": .string("post_catch_reveal"),
            "total_catches": .int(totalCatches),
            "distinct_catch_days": .int(distinctCatchDays),
        ])
        request()
    }

    #if DEBUG
    /// Clear the once-per-version stamp so the ask can be exercised
    /// repeatedly on-device (dev builds always display the sheet; the
    /// stamp would otherwise burn on the first eligible reveal). Wired
    /// into the debug overlay — never ship a reset path.
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
