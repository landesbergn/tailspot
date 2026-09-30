//
//  ChallengeBuildGate.swift
//  Tailspot
//
//  Client-side read of GET /v1/challenges/config (section 11.2): the one
//  config endpoint the app and the web landing page both read, deciding
//  whether Challenges is usable on this build without a client release.
//  `nonisolated` — pure, no networking (the fetch + 60s cache live in the
//  phase-2 client).
//

import Foundation

nonisolated enum ChallengeBuildGate {
    enum Verdict: Equatable {
        /// Config fetched, flag on, build meets `minBuild`.
        case available
        /// Config fetched but `enabled` is false — the kill switch.
        case disabled
        /// Config fetched, flag on, but this build predates `minBuild`.
        case updateRequired(minBuild: Int)
        /// Config not yet fetched (or the fetch failed) — caller should
        /// fail soft (hide the entry point) rather than assume available.
        case unknown
    }

    /// No config → `unknown` (fail soft, section 11.2's table: never assume
    /// available before the flag is known). Disabled beats a stale/low
    /// build number since the spec's kill switch must always win.
    static func verdict(config: ChallengesConfig?, currentBuild: Int) -> Verdict {
        guard let config else { return .unknown }
        guard config.enabled else { return .disabled }
        guard currentBuild >= config.minBuild else {
            return .updateRequired(minBuild: config.minBuild)
        }
        return .available
    }

    /// `CFBundleVersion` — the same build number the App Store and TestFlight
    /// show, and what the server's `minBuild` is compared against (section
    /// 11.2: "minBuild: 95, // CFBundleVersion the client must meet").
    static func currentBuild(bundle: Bundle = .main) -> Int {
        guard let raw = bundle.infoDictionary?["CFBundleVersion"] as? String,
              let value = Int(raw) else {
            return 0
        }
        return value
    }
}
