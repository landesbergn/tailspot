//
//  TrophiesTabSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the rebuilt Trophies tab and its satellites
//  (TrophyRecapSnapshotTests pattern). NOT an assertion test: writes PNGs to
//  /private/tmp/tailspot_snaps/trophies_tab/ and passes. Review the images.
//
//  Views take synthetic `TrophyProgressInputs` (no SwiftData rows), hosted
//  in a real window and captured with drawHierarchy. The tab scrolls, and
//  a window taller than ~2,000 pt won't draw, so long states are captured
//  as several screen-height slices by moving the UIScrollView's offset.
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
@testable import Tailspot

@MainActor
@Suite("Trophies tab snapshots (visual pass)", .serialized)
struct TrophiesTabSnapshotTests {

    private static let snapDir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps/trophies_tab", isDirectory: true)
    private static let units = DisplayUnits.localized(for: Locale(identifier: "en_US"))

    // MARK: Synthetic players

    private var mid: TrophyProgressInputs {
        TrophyProgressInputs(
            totalCatches: 212, uniqueAirframes: 80, wideBodyCatches: 31, regionalCatches: 12,
            heritageCatches: 0, rareTierCatches: 6, epicTierCatches: 1, legendaryTierCatches: 0,
            rarePlusUnique: 9, longestSlantKm: 22, bestMultiCatchCount: 2, nightCatches: 3,
            narrowBodyCatches: 90, uniqueOperators: 27, uniquePlaces: 6, completedSets: 2,
            distinctDays: 14, distinctCountries: 1, farCatchCount: 4, bestBurstWithinTenMin: 3,
            hasRepeatAirframeAcrossDays: true, longestDayStreak: 3,
            caughtTags: ["heavymetal"], bestCatchesInOneDay: 12, dayPartsCovered: 3,
            distinctTypes: 4, weekendDaysHit: 1, totalPoints: 2400, correctGuesses: 6,
            bestGuessStreak: 2)
    }

    private var heavy: TrophyProgressInputs {
        TrophyProgressInputs(
            totalCatches: 640, uniqueAirframes: 410, wideBodyCatches: 190, regionalCatches: 160,
            heritageCatches: 6, rareTierCatches: 40, epicTierCatches: 9, legendaryTierCatches: 2,
            rarePlusUnique: 55, longestSlantKm: 61, bestMultiCatchCount: 5, nightCatches: 120,
            narrowBodyCatches: 420, uniqueOperators: 110, uniquePlaces: 60, completedSets: 17,
            distinctDays: 120, distinctCountries: 4, farCatchCount: 30, redEyeCatches: 4,
            bestBurstWithinTenMin: 6, hasRepeatAirframeAcrossDays: true, longestDayStreak: 12,
            caughtTags: ["heavymetal", "freighter", "bizjet", "turboprop", "military", "helicopter"],
            highestAltitudeM: 13_000, fastestVelocityMps: 280, bestCatchesInOneDay: 31,
            dayPartsCovered: 4, lowestAltitudeM: 100, maxCatchesAtOnePlace: 60, distinctTypes: 7,
            weekendDaysHit: 2, hadDawnCatch: true, hadConsecutiveSameOperator: true,
            triedGroundedCatch: true, totalPoints: 30_000, correctGuesses: 60, bestGuessStreak: 9,
            weeklyWins: 3, everToppedAllTime: true)
    }

    private func dates(for inputs: TrophyProgressInputs) -> [String: Date] {
        var out: [String: Date] = [:]
        for (i, a) in Trophies.roster.enumerated() where a.isEarned(inputs: inputs) {
            out[a.id] = Date(timeIntervalSince1970: 1_760_000_000 + Double(i) * 86_400 * 2)
        }
        return out
    }

    private func tab(_ inputs: TrophyProgressInputs) -> TrophiesTabContentView {
        TrophiesTabContentView(content: .make(inputs: inputs), dates: dates(for: inputs), units: Self.units)
    }

    private func real(_ id: String) -> Achievement { Trophies.roster.first { $0.id == id }! }

    // MARK: Capture

    private func capture<V: View>(_ view: V, as name: String, scrollTo offsets: [CGFloat] = [],
                                  settle: Double = 0.4, size: CGSize = CGSize(width: 393, height: 852)) async throws {
        try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
        let bounds = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .seconds(settle))
        func write(_ suffix: String) {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let png = UIGraphicsImageRenderer(bounds: bounds, format: format).pngData { _ in
                host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            try? png.write(to: Self.snapDir.appendingPathComponent("\(name)\(suffix).png"))
        }
        write(offsets.isEmpty ? "" : "_1")
        for (i, y) in offsets.enumerated() {
            guard let scroll = Self.firstScrollView(in: host.view) else { break }
            let maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
            scroll.setContentOffset(CGPoint(x: 0, y: min(y, maxY)), animated: false)
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .seconds(0.3))
            write("_\(i + 2)")
        }
        window.isHidden = true
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let s = view as? UIScrollView, s.contentSize.height > s.bounds.height { return s }
        for sub in view.subviews { if let s = firstScrollView(in: sub) { return s } }
        return nil
    }

    // MARK: The tab

    @Test func renderTabNewPlayer() async throws {
        try await capture(tab(.zero), as: "tab_new_player", scrollTo: [900])
    }

    @Test func renderTabMidPlayer() async throws {
        try await capture(tab(mid), as: "tab_mid_player", scrollTo: [700, 1500])
    }

    @Test func renderTabHeavyPlayer() async throws {
        try await capture(tab(heavy), as: "tab_heavy_player", scrollTo: [700, 1400, 2100])
    }

    @Test func renderTabAccessibilitySize() async throws {
        try await capture(tab(mid).dynamicTypeSize(.accessibility3), as: "tab_a11y_size",
                          scrollTo: [900, 1900])
    }

    // MARK: Detail

    private func detail(_ id: String, _ inputs: TrophyProgressInputs) -> some View {
        TrophyDetailSheet(achievement: real(id), inputs: inputs, dates: dates(for: inputs),
                          units: Self.units, handleOverride: "mach_6415") {}
    }

    @Test func renderDetails() async throws {
        try await capture(detail("airlines", mid), as: "detail_track_midway")
        try await capture(detail("airlines2", mid), as: "detail_track_chased_level")
        try await capture(detail("heavy3", heavy), as: "detail_track_maxed")
        try await capture(detail("heavymetal", heavy), as: "detail_feat_earned")
        try await capture(detail("firstrare", .zero), as: "detail_feat_locked_progress")
        try await capture(detail("hattrick", .zero), as: "detail_secret_masked")
        try await capture(detail("heavy", mid).dynamicTypeSize(.accessibility3), as: "detail_a11y_size",
                          scrollTo: [800])
    }

    // MARK: Share card

    @Test func renderShareCards() throws {
        try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
        let cards: [(String, TrophyShareCard)] = [
            ("share_card_track", TrophyShareCard(
                badge: TrophyBadgeSpec(earnedAchievement: real("heavy2")),
                title: "Heavies II", summary: TrophyTracks.displaySummary(for: real("heavy2"), units: Self.units),
                earnedAt: Date(timeIntervalSince1970: 1_764_000_000), handle: "mach_6415")),
            ("share_card_feat_no_handle", TrophyShareCard(
                badge: TrophyBadgeSpec(earnedAchievement: real("heavymetal")),
                title: real("heavymetal").title, summary: real("heavymetal").summary,
                earnedAt: nil, handle: nil)),
        ]
        for (name, card) in cards {
            let image = try #require(card.uiImage())
            try image.pngData()?.write(to: Self.snapDir.appendingPathComponent("\(name).png"))
        }
    }

    // MARK: Unlock + recap

    @Test func renderUnlockCards() async throws {
        let level = TrophyUnlockCenter()
        level.debugEnqueueSample(secret: false)      // Logbook III, a track level
        try await capture(TrophyUnlockView(center: level), as: "unlock_track_level", settle: 1.5)
        let feat = TrophyUnlockCenter()
        feat.debugEnqueueSample(secret: true)        // a secret feat
        try await capture(TrophyUnlockView(center: feat), as: "unlock_secret_feat", settle: 1.5)
    }

    /// The "almost there" card that follows a reveal when the catch left a
    /// level one or two short.
    @Test func renderNearMissCards() async throws {
        func card(_ trackID: String, level: Int, progress: Int) -> TrophyUnlockView {
            let track = TrophyTracks.all.first { $0.id == trackID }!
            let ach = real(track.levelIDs[level - 1])
            let defaults = UserDefaults(suiteName: "snap.near.\(UUID().uuidString)")!
            let center = TrophyUnlockCenter(nearStore: TrophyNearStore(defaults: defaults))
            center.debugSetNearMiss(TrophyNearMiss(track: track, level: level, progress: progress,
                                                   goal: ach.threshold, achievement: ach))
            return TrophyUnlockView(center: center)
        }
        try await capture(card("airlines", level: 2, progress: 28), as: "near_miss_airlines", settle: 1.5)
        try await capture(card("heavies", level: 1, progress: 9), as: "near_miss_heavies_one_left", settle: 1.5)
    }

    @Test func renderRecap() async throws {
        let ids = ["firstcatch", "spotter", "heavy", "heavy2", "airlines", "heavymetal"]
        let recap = TrophyRecap(achievements: ids.map(real))
        try await capture(
            TrophyRecapView(recap: recap, onDismiss: {})
                ._snapshotScreen(size: CGSize(width: 393, height: 852)),
            as: "recap_six")
    }
}
#endif
