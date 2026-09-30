//
//  HandleEditTests.swift
//  TailspotTests
//
//  The handle edit sheet (Profile + Settings) and the shared HandleClaimer:
//  format rules, when Save turns on, and what each claim outcome persists.
//  Plus a snapshot pass of the sheet's states for the PR's visual review.
//

import Foundation
import SwiftUI
import Testing
@testable import Tailspot

@Suite("Handle rules")
struct HandleRulesTests {
    @Test(arguments: ["noah", "blue_hour", "abc", "A1_b2", String(repeating: "x", count: 20), "  maia  "])
    func valid(_ h: String) { #expect(HandleRules.isValid(h)) }

    /// Mirrors the server's ASCII-only regex: "é" would pass `isLetter` and
    /// then come back 422.
    @Test(arguments: ["ab", String(repeating: "x", count: 21), "no ah", "no-ah", "noé", "@noah", "", "   "])
    func invalid(_ h: String) { #expect(!HandleRules.isValid(h)) }
}

@Suite("Handle edit sheet: Save enablement")
@MainActor
struct HandleEditSaveTests {
    @Test func unchangedHandleCannotSave() {
        #expect(!HandleEditSheet.canSave(draft: "noah", current: "noah"))
        #expect(!HandleEditSheet.canSave(draft: " noah ", current: "noah"))
    }

    @Test func realChangeCanSave() {
        #expect(HandleEditSheet.canSave(draft: "noah_spots", current: "noah"))
    }

    /// The server treats "Noah" and "noah" as the same device's handle, so a
    /// case-only rename is allowed.
    @Test func caseOnlyChangeCanSave() {
        #expect(HandleEditSheet.canSave(draft: "Noah", current: "noah"))
    }

    @Test func invalidDraftCannotSave() {
        #expect(!HandleEditSheet.canSave(draft: "no", current: "noah"))
        #expect(!HandleEditSheet.canSave(draft: "no ah", current: nil))
    }

    @Test func firstClaimCanSaveAnyValidHandle() {
        #expect(HandleEditSheet.canSave(draft: "noah", current: nil))
    }
}

@Suite("HandleClaimer outcomes")
@MainActor
struct HandleClaimerTests {
    private final class Log {
        var events: [(String, [String: String])] = []
        var identifies: [(String, String)] = []
        func report(_ name: String, _ props: [String: AnalyticsValue]) {
            var flat: [String: String] = [:]
            for (k, v) in props { if case .string(let s) = v { flat[k] = s } }
            events.append((name, flat))
        }
    }

    private func make(_ outcome: FakeClaimClient.Outcome) -> (HandleClaimer, UserDefaults, FakeClaimClient, Log) {
        let defaults = UserDefaults(suiteName: "tailspot.test.claimer.\(UUID().uuidString)")!
        defaults.set("noah", forKey: SpotterHandle.storageKey)
        defaults.set("noah", forKey: SpotterHandle.confirmedKey)
        let fake = FakeClaimClient()
        fake.outcome = outcome
        let log = Log()
        let claimer = HandleClaimer(client: fake, defaults: defaults,
                                    report: log.report,
                                    identify: { log.identifies.append(($0, $1)) })
        return (claimer, defaults, fake, log)
    }

    @Test func successPersistsBothKeysAndIdentifies() async {
        let (claimer, defaults, fake, log) = make(.success)
        let result = await claimer.claim("  noah_spots ", source: "profile")

        #expect(result == .saved("noah_spots"))
        #expect(fake.claimedHandles == ["noah_spots"])
        #expect(defaults.string(forKey: SpotterHandle.storageKey) == "noah_spots")
        #expect(defaults.string(forKey: SpotterHandle.confirmedKey) == "noah_spots")
        #expect(log.identifies.first?.1 == "noah_spots")
        #expect(log.events.first?.0 == "handle_claimed")
        #expect(log.events.first?.1 == ["result": "success", "source": "profile"])
    }

    @Test func takenKeepsTheOldHandle() async {
        let (claimer, defaults, _, log) = make(.taken)
        let result = await claimer.claim("maia", source: "settings")

        #expect(result == .taken("maia"))
        #expect(result.message == "@maia is taken. Try another.")
        #expect(defaults.string(forKey: SpotterHandle.storageKey) == "noah")
        #expect(log.identifies.isEmpty)
        #expect(log.events.first?.1 == ["result": "taken", "source": "settings"])
    }

    @Test func notAllowedKeepsTheOldHandle() async {
        let (claimer, defaults, _, _) = make(.failure(AccountError.handleNotAllowed))
        let result = await claimer.claim("sh1thead", source: "profile")

        #expect(result == .notAllowed("sh1thead"))
        #expect(defaults.string(forKey: SpotterHandle.storageKey) == "noah")
    }

    /// Regression for the blue_hour strand: the old Settings save kept the
    /// new handle locally on a network failure, so the phone showed a name
    /// the server never recorded. Now nothing is persisted.
    @Test func networkFailurePersistsNothing() async {
        let (claimer, defaults, _, log) = make(.failure(AccountError.http(status: 503)))
        let result = await claimer.claim("noah_spots", source: "profile")

        #expect(result == .failed)
        #expect(result.message == "Couldn't save. Check your connection.")
        #expect(defaults.string(forKey: SpotterHandle.storageKey) == "noah")
        #expect(defaults.string(forKey: SpotterHandle.confirmedKey) == "noah")
        #expect(log.events.first?.1["result"] == "failed")
    }
}

// MARK: - Visual pass

/// Renders the sheet's states to /private/tmp/tailspot_snaps for the PR's
/// before/after table. Profile + Settings "after" renders come from
/// ProfileSettingsSnapshotTests (profile_hub, settings, *_unclaimed).
@MainActor
@Suite("Handle edit sheet snapshots", .serialized)
struct HandleEditSnapshotTests {
    private static let snapDir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)

    /// Host the sheet's content directly at medium-detent height (about half
    /// an iPhone 16 screen). A real `.sheet` presentation draws blank in an
    /// offscreen test window, so the grabber and rounded top aren't shown.
    private func snapshot(_ sheet: HandleEditSheet, as name: String) async {
        try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 440)
        let host = UIHostingController(rootView: sheet)
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        try? await Task.sleep(for: .seconds(0.5))
        let png = UIGraphicsImageRenderer(bounds: bounds).pngData { _ in
            host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try? png.write(to: Self.snapDir.appendingPathComponent("\(name).png"))
        window.isHidden = true
    }

    private func withHandle(_ value: String, _ body: () async -> Void) async {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: SpotterHandle.storageKey)
        defaults.set(value, forKey: SpotterHandle.storageKey)
        await body()
        defaults.set(saved, forKey: SpotterHandle.storageKey)
    }

    @Test func renderSheetStates() async {
        await withHandle("noah") {
            await snapshot(HandleEditSheet(source: "snapshot", initialDraft: "noah_spots"), as: "handle_sheet_edit")
            await snapshot(HandleEditSheet(source: "snapshot", initialDraft: "maia",
                                           initialOutcome: .taken("maia")), as: "handle_sheet_taken")
            await snapshot(HandleEditSheet(source: "snapshot", initialDraft: "noah_spots",
                                           initialOutcome: .failed), as: "handle_sheet_offline")
        }
        await withHandle(SpotterHandle.defaultPlaceholder) {
            await snapshot(HandleEditSheet(source: "snapshot"), as: "handle_sheet_claim")
        }
        #expect(true)
    }
}
