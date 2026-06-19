//
//  FailureModeRegressionTests.swift
//  TailspotTests
//
//  Local-tier regression bench. Real field recordings carry GPS + logs, so
//  the corpus is LOCAL ONLY: drop `local-<name>.jsonl` recordings into this
//  folder (TailspotTests/). They are gitignored — never committed, never in
//  the public repo or its CI — but Xcode 16's synchronized folder still
//  bundles whatever is on disk, so they run on your machine. On a fresh CI
//  clone the gitignored files are absent, so this suite finds no fixtures
//  and SKIPS, keeping GitHub's public CI green. The redacted, committed CI
//  tier (FieldReplays/, U6) is what runs there.
//

import Testing
import Foundation
@testable import Tailspot

/// Bundle hook — Swift Testing has no Bundle.module in xcodeproj targets.
private final class LocalReplayToken {}

@MainActor
@Suite("Failure-mode regressions (local)")
struct FailureModeRegressionTests {

    /// Gitignored `local-*.jsonl` recordings bundled from this folder.
    /// `nonisolated` so the `.enabled(if:)` trait (a Sendable closure) can
    /// read it; it only touches Bundle/URL, which are isolation-free.
    nonisolated static var localFixtures: [URL] {
        let bundle = Bundle(for: LocalReplayToken.self)
        let urls = bundle.urls(forResourcesWithExtension: "jsonl", subdirectory: nil) ?? []
        return urls
            .filter { $0.lastPathComponent.hasPrefix("local-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Scores every local recording, surfacing its failure-mode diagnosis.
    /// Skipped entirely when no local fixtures are present (CI), so the
    /// public suite stays green. As specific misses are triaged, add a
    /// per-fixture assertion pinning the intended behaviour.
    @Test(.enabled(if: !FailureModeRegressionTests.localFixtures.isEmpty))
    func localCorpusIsScorable() throws {
        for url in Self.localFixtures {
            let events = try ReplayJSONL.decode(Data(contentsOf: url))
            let report = ReplayAnalyzer().scoreFailureModes(events)
            // Smoke: scoring + diagnosis complete and stay inspectable. The
            // bench surfaces failures rather than asserting zero; tighten to
            // mode-specific expectations per fixture as cases are triaged.
            #expect(!report.diagnose().isEmpty)
        }
    }
}
