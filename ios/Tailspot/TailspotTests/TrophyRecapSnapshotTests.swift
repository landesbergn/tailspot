//
//  TrophyRecapSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the one-time trophy-case recap sheet
//  (ProfileSettingsSnapshotTests pattern; the Trophies tab itself lives in
//  TrophiesTabSnapshotTests). NOT an
//  assertion test: writes PNGs to /private/tmp/tailspot_snaps and passes —
//  review the images after running.
//
//  Window-hosted (drawHierarchy) rather than ImageRenderer because both
//  views scroll — ImageRenderer sizes a ScrollView to its ideal (unbounded)
//  content, while a real window lays it out at screen size like the device.
//  The recap renders through `_snapshotScreen` (the settled t=1 frame) so
//  the count-up / stagger clock can't leave a half-revealed image.
//

#if DEBUG
import Testing
import SwiftUI
import SwiftData
import UIKit
@testable import Tailspot

@MainActor
@Suite("Trophy recap snapshots (visual pass)", .serialized)
struct TrophyRecapSnapshotTests {

    private static let snapDir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)

    /// Host `view` in a real window and snapshot via drawHierarchy. `height`
    /// is parameterized so the full Hangar trophy list (taller than a phone)
    /// can be captured in one image — including the below-the-fold masked
    /// secret rows.
    private func snapshot<V: View>(_ view: V, as name: String, height: CGFloat = 852) async {
        try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
        let bounds = CGRect(x: 0, y: 0, width: 393, height: height)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        try? await Task.sleep(for: .seconds(0.3))
        // Explicit scale: the default (screen scale, 3×) would push the tall
        // full-list captures past Metal's max texture extent and come out
        // blank — 1× is plenty for a layout eyeball at 4000+ points.
        let format = UIGraphicsImageRendererFormat()
        format.scale = height > 2000 ? 1 : 2
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let png = renderer.pngData { _ in
            host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try? png.write(to: Self.snapDir.appendingPathComponent("\(name).png"))
        window.isHidden = true
    }

    private func real(_ id: String) -> Achievement {
        Trophies.roster.first { $0.id == id }!
    }

    // MARK: - Recap sheet

    @Test func renderRecapStates() async {
        // 1 trophy — the minimum recap (singular copy, lone hex centered).
        await snapshot(
                  TrophyRecapView(recap: TrophyRecap(achievements: [real("firstcatch")]), onDismiss: {})
                      ._snapshotScreen(size: CGSize(width: 393, height: 852)),
                  as: "recap_one_trophy"
        )

        // A packed case — two dozen earned incl. the new points/guess
        // trophies and revealed secrets; the grid must scroll, not squash.
        let manyIds = ["firstcatch", "spotter", "catcher", "fourfigures", "calledit",
                       "clairvoyant", "hotstreak", "heavy", "narrow", "regional",
                       "world", "airlines", "places", "rarehunter", "regular",
                       "night", "firstrare", "epic", "heavymetal", "freighter",
                       "varietypack", "homebody", "redeye", "groundstop"]
        await snapshot(
                  TrophyRecapView(recap: TrophyRecap(achievements: manyIds.map(real)), onDismiss: {})
                      ._snapshotScreen(size: CGSize(width: 393, height: 852)),
                  as: "recap_many_trophies"
        )

        // Long titles — synthetic worst case for cell wrapping/clipping.
        let longNames = [
            Achievement(id: "long1", title: "Transcontinental Heavyweight Champion",
                        summary: "", tiers: [.init(tier: .gold, at: 1)], progress: { _ in 1 }),
            Achievement(id: "long2", title: "Extraordinarily Clairvoyant Route Whisperer",
                        summary: "", tiers: [.init(tier: .gold, at: 1)], progress: { _ in 1 }),
            Achievement(id: "long3", title: "Around-the-World Weekend Warrior",
                        summary: "", tiers: [.init(tier: .gold, at: 1)], progress: { _ in 1 }),
        ]
        await snapshot(
                  TrophyRecapView(recap: TrophyRecap(achievements: longNames), onDismiss: {})
                      ._snapshotScreen(size: CGSize(width: 393, height: 852)),
                  as: "recap_long_names"
        )
    }

    // MARK: - Roster-bump reseed cards

    /// What a roster-bump reseed now presents: ordinary "NEW TROPHY" cards
    /// (not the recap sheet). Drives a REAL reseed — a roster-3 ledger that
    /// never knew Heritage / Living History / Constellation, then today's
    /// roster over a Hangar that qualifies for all three — and renders the
    /// overlay the way ContentView mounts it. The longer settle lets the
    /// card's spring entrance finish.
    @Test func renderReseedUnlockCards() async throws {
        let tag = UUID().uuidString
        let ledger = UserDefaultsTrophyLedger(defaults: UserDefaults(suiteName: "snap.reseed.\(tag)")!)
        let suite = UserDefaults(suiteName: "snap.reseed.facts.\(tag)")!
        let events = TrophyEventStore(defaults: suite)
        let standing = LeaderboardStandingCache(defaults: suite)
        let press = Date(timeIntervalSince1970: 1_716_000_000)
        func mk(_ typecode: String?, _ at: Date) -> Catch {
            Catch(icao24: String(UUID().uuidString.prefix(6)).lowercased(), callsign: nil,
                  model: nil, manufacturer: nil, caughtAt: at,
                  observerLat: 0, observerLon: 0, slantDistanceMeters: 1000, typecode: typecode)
        }
        let hangar = [mk(nil, press), mk(nil, press)]
            + (0..<5).map { mk("DC3", press.addingTimeInterval(Double($0 + 1) * 3600)) }
        let added = ["heritage", "heritage2", "multi"]
        TrophyUnlockCenter(ledger: ledger, roster: Trophies.roster.filter { !added.contains($0.id) },
                           events: events, standing: standing, rosterVersion: 3)
            .enqueueNewUnlocks(from: hangar)
        let center = TrophyUnlockCenter(ledger: ledger, events: events, standing: standing)
        center.enqueueNewUnlocks(from: hangar)
        #expect(center.pendingRecap == nil)
        #expect(center.head?.achievementID == "heritage")

        try await snapshotSettled(TrophyUnlockView(center: center), as: "reseed_card_heritage_of_3")
        center.advance(); center.advance()
        try await snapshotSettled(TrophyUnlockView(center: center), as: "reseed_card_constellation_last")
    }

    /// `snapshot` with a longer settle for the animated unlock card. Waits
    /// with an async sleep, not a RunLoop spin, so the view's `.task` (which
    /// starts the entrance) actually gets the main actor and runs.
    private func snapshotSettled<V: View>(_ view: V, as name: String) async throws {
        try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .seconds(1.5))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let png = UIGraphicsImageRenderer(bounds: bounds, format: format).pngData { _ in
            host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try? png.write(to: Self.snapDir.appendingPathComponent("\(name).png"))
        window.isHidden = true
    }
}
#endif
