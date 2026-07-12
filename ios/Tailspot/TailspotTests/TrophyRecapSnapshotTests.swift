//
//  TrophyRecapSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the one-time trophy-case recap sheet + the
//  Hangar trophy grid states (ProfileSettingsSnapshotTests pattern). NOT an
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
@Suite("Trophy recap + grid snapshots (visual pass)", .serialized)
struct TrophyRecapSnapshotTests {

    private static let snapDir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)

    /// Host `view` in a real window and snapshot via drawHierarchy. `height`
    /// is parameterized so the full Hangar trophy list (taller than a phone)
    /// can be captured in one image — including the below-the-fold masked
    /// secret rows.
    private func snapshot<V: View>(_ view: V, as name: String, height: CGFloat = 852) {
        try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
        let bounds = CGRect(x: 0, y: 0, width: 393, height: height)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
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

    @Test func renderRecapStates() {
        // 1 trophy — the minimum recap (singular copy, lone hex centered).
        snapshot(
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
        snapshot(
            TrophyRecapView(recap: TrophyRecap(achievements: manyIds.map(real)), onDismiss: {})
                ._snapshotScreen(size: CGSize(width: 393, height: 852)),
            as: "recap_many_trophies"
        )

        // Long titles — synthetic worst case for cell wrapping/clipping.
        let longNames = [
            Achievement(id: "long1", title: "Transcontinental Heavyweight Champion",
                        summary: "", iconName: "coin",
                        tiers: [.init(tier: .gold, at: 1)], progress: { _ in 1 }),
            Achievement(id: "long2", title: "Extraordinarily Clairvoyant Route Whisperer",
                        summary: "", iconName: "crystal",
                        tiers: [.init(tier: .gold, at: 1)], progress: { _ in 1 }),
            Achievement(id: "long3", title: "Around-the-World Weekend Warrior",
                        summary: "", iconName: "bolt",
                        tiers: [.init(tier: .gold, at: 1)], progress: { _ in 1 }),
        ]
        snapshot(
            TrophyRecapView(recap: TrophyRecap(achievements: longNames), onDismiss: {})
                ._snapshotScreen(size: CGSize(width: 393, height: 852)),
            as: "recap_long_names"
        )
    }

    // MARK: - Hangar trophy list states

    /// Catches producing a good mix: a few earned rows, a partial Four
    /// Figures progress bar, an earned Called It, and locked secrets.
    private func mixedCatches() -> [Catch] {
        let seeds: [(String, String?, String)] = [
            // (icao, typecode, operator)
            ("86e123", "B789", "ANA"), ("3b7440", "B744", "Lufthansa"),
            ("a4e172", "C172", "Private"), ("ae01c7", "C17", "USAF"),
            ("4b1801", "A333", "Swiss"), ("a1b2c3", "B738", "United"),
        ]
        var catches = seeds.enumerated().map { i, s in
            Catch(
                icao24: s.0, callsign: nil, model: nil, manufacturer: nil,
                operatorName: s.2,
                caughtAt: Date(timeIntervalSince1970: 1_716_000_000 + Double(i) * 3600),
                observerLat: 37.87, observerLon: -122.27,
                slantDistanceMeters: 8_000, typecode: s.1
            )
        }
        // One correct route call so Called It shows earned.
        let guessedCatch = Catch(
            icao24: "d0d0d0", callsign: "UAL1", model: nil, manufacturer: nil,
            operatorName: "United",
            caughtAt: Date(timeIntervalSince1970: 1_716_100_000),
            observerLat: 37.87, observerLon: -122.27,
            slantDistanceMeters: 9_000, typecode: "A320"
        )
        guessedCatch.guessKind = GuessKind.route.rawValue
        guessedCatch.guessValue = "KSFO"
        guessedCatch.guessCorrect = true
        catches.append(guessedCatch)
        return catches
    }

    /// The exact cards the Hangar Trophies tab shows (same `TrophyBoard`
    /// ordering + `TrophyCardRow` rendering), in a plain non-lazy column so
    /// ImageRenderer captures the full height — a >2,000 pt offscreen window
    /// won't draw at all (render-server limit), which is why this doesn't go
    /// through the window-host helper. A curated sub-roster keeps each image
    /// readable while still covering every visual state.
    private func cardColumn(
        roster: [Achievement], catches: [Catch],
        weeklyWins: Int = 0, everToppedAllTime: Bool = false
    ) -> some View {
        // Suite-isolated event + standing stores so a stray
        // `groundedCatchAttempt` (or a cached weekly win) on the host app's
        // standard defaults can't flip the Ground Stop / winner rows. The
        // winner-trophy states are driven by the parameters, written through
        // the same `update(from:)` path the screens use.
        let suite = UserDefaults(suiteName: "snap.\(UUID().uuidString)")!
        let events = TrophyEventStore(defaults: suite)
        let standing = LeaderboardStandingCache(defaults: suite)
        standing.update(from: MyStanding(rank: 1, points: 0,
                                         weeklyWins: weeklyWins,
                                         everToppedAllTime: everToppedAllTime))
        let inputs = Trophies.inputs(from: catches, events: events, standing: standing)
        let items = TrophyBoard.visible(roster: roster, inputs: inputs)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(items) { TrophyCardRow(ach: $0, inputs: inputs) }
        }
        .padding(16)
        .frame(width: 393)
        .background(Brand.Color.bgPrimary)
    }

    private func snapshotColumn<V: View>(_ view: V, as name: String) {
        try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let img = renderer.uiImage, let data = img.pngData() else { return }
        try? data.write(to: Self.snapDir.appendingPathComponent("\(name).png"))
    }

    @Test func renderTrophyListStates() {
        // Representative sub-roster: milestone chain heads, the new points +
        // guess families, a progress-bar family, and two secrets.
        let ids = ["firstcatch", "spotter", "fourfigures", "highroller",
                   "calledit", "clairvoyant", "rarehunter", "hotstreak", "groundstop"]
        let roster = ids.map(real)

        // Mixed: earned rows lead (cyan hex), Four Figures shows a partial
        // progress bar, Clairvoyant appears (prereq earned) at 1/10,
        // High Roller stays hidden (chained), secrets render masked.
        snapshotColumn(
            cardColumn(roster: roster, catches: mixedCatches()),
            as: "trophy_list_mixed"
        )
        // Fresh install: everything locked; secrets are the "???" placeholder,
        // chained milestones (spotter/highroller/clairvoyant) hidden entirely.
        snapshotColumn(
            cardColumn(roster: roster, catches: []),
            as: "trophy_list_fresh_secrets_masked"
        )
    }

    /// Winner-trophy rows (dynamic-leaderboards PR3) across their states:
    /// locked (fresh install, Dynasty masked), first crown (Top Flight
    /// earned, Dynasty STILL masked), and server facts maxed (all earned,
    /// Dynasty revealed). Earned rows sort first — the order flip between
    /// images is TrophyBoard working, not a bug.
    @Test func renderWinnerTrophyStates() {
        let winners = ["topflight", "charttopper", "dynasty"].map(real)
        snapshotColumn(
            cardColumn(roster: winners, catches: []),
            as: "trophy_winners_locked_dynasty_masked"
        )
        snapshotColumn(
            cardColumn(roster: winners, catches: [], weeklyWins: 1),
            as: "trophy_winners_first_crown"
        )
        snapshotColumn(
            cardColumn(roster: winners, catches: [], weeklyWins: 3, everToppedAllTime: true),
            as: "trophy_winners_all_earned"
        )
    }
}
#endif
