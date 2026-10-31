//
//  BackControlsDeviceRenderTests.swift
//  TailspotTests
//
//  Visual-pass harness (NOT an assertion test) for the back-controls pass
//  (2026-10-30, design/back-controls-audit.html): renders every screen whose
//  exit control changed, at the smallest (iPhone SE) and largest (16 Pro Max)
//  supported sizes, so the before and after can be compared side by side.
//  Writes PNGs to /private/tmp/tailspot_back_controls/<tag>/. OPT-IN, like
//  RevealDeviceMatrixRenderTests — run it against the old and the new code:
//
//      TEST_RUNNER_TAILSPOT_BACK_CONTROLS=before xcodebuild test … \
//        -only-testing:TailspotTests/BackControlsDeviceRenderTests
//
//  Hosted live in a UIWindow (not ImageRenderer) because navigation bars,
//  Lists and ScrollViews don't draw under ImageRenderer. The window is the
//  full screen size and the status bar / home indicator come from
//  `additionalSafeAreaInsets`, so the toolbar sits where it does on a phone.
//

#if DEBUG
import Testing
import SwiftUI
import SwiftData
import UIKit
@testable import Tailspot

/// Output folder name ("before" / "after"). nil disables the suite.
private let backControlsTag: String? = ProcessInfo.processInfo.environment["TAILSPOT_BACK_CONTROLS"]

@MainActor
@Suite("Back controls device renders (visual pass)", .serialized,
       .enabled(if: backControlsTag != nil, "opt-in: set TEST_RUNNER_TAILSPOT_BACK_CONTROLS=<tag>"))
struct BackControlsDeviceRenderTests {

    static let outDir = URL(fileURLWithPath: "/private/tmp/tailspot_back_controls/\(backControlsTag ?? "unset")",
                            isDirectory: true)

    struct Device { let name: String; let size: CGSize; let insets: UIEdgeInsets }
    static let devices: [Device] = [
        Device(name: "se", size: CGSize(width: 375, height: 667),
               insets: UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0)),
        Device(name: "promax", size: CGSize(width: 440, height: 956),
               insets: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)),
    ]

    private func render<V: View>(_ view: V, as name: String, wait: Double = 1.5) async {
        try? FileManager.default.createDirectory(at: Self.outDir, withIntermediateDirectories: true)
        for device in Self.devices {
            let host = UIHostingController(rootView: view.environment(\.replayMaskingDisabled, true))
            host.additionalSafeAreaInsets = device.insets
            let bounds = CGRect(origin: .zero, size: device.size)
            let window = UIWindow(frame: bounds)
            window.rootViewController = host
            window.overrideUserInterfaceStyle = .dark
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            try? await Task.sleep(for: .seconds(wait))
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try? await Task.sleep(for: .seconds(0.3))
            let png = UIGraphicsImageRenderer(bounds: bounds).pngData { _ in
                host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            try? png.write(to: Self.outDir.appendingPathComponent("\(name)__\(device.name).png"))
            window.isHidden = true
        }
    }

    // MARK: - Fixtures

    private func seededContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Catch.self, configurations: config)
        TestContainerRetention.retain(container)
        let seeds: [(String, String, String, String, String, String)] = [
            ("86e123", "ANA858", "787-9", "Boeing", "B789", "All Nippon Airways"),
            ("a4e172", "N4521C", "172", "Cessna", "C172", "Private"),
            ("ae01c7", "RCH872", "C-17 Globemaster III", "Boeing", "C17", "U.S. Air Force"),
            ("4b1801", "SWR38", "A330-300", "Airbus", "A333", "Swiss"),
            ("a0b1c2", "SWA1234", "737-800", "Boeing", "B738", "Southwest Airlines"),
        ]
        for (i, s) in seeds.enumerated() {
            container.mainContext.insert(Catch(
                icao24: s.0, callsign: s.1, model: s.2, manufacturer: s.3, operatorName: s.5,
                caughtAt: Date(timeIntervalSince1970: 1_783_150_000 - Double(i) * 3_600),
                observerLat: 37.87, observerLon: -122.27,
                slantDistanceMeters: 9_800, typecode: s.4))
        }
        return container
    }

    private func newestCatch(_ container: ModelContainer) throws -> Catch {
        try container.mainContext.fetch(
            FetchDescriptor<Catch>(sortBy: [SortDescriptor(\.caughtAt, order: .reverse)]))[0]
    }

    private func fixturePhotoURL() throws -> URL {
        let size = CGSize(width: 1200, height: 1600)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(red: 0.25, green: 0.45, blue: 0.75, alpha: 1).cgColor,
                          UIColor(red: 0.75, green: 0.85, blue: 0.95, alpha: 1).cgColor]
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            UIColor(white: 0.15, alpha: 1).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 420, y: 500, width: 420, height: 60))
            ctx.cgContext.fill(CGRect(x: 600, y: 340, width: 45, height: 380))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("back_controls_fixture.jpg")
        try img.jpegData(compressionQuality: 0.8)!.write(to: url)
        return url
    }

    private func challengesModel() async -> ChallengesModel {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let service = FixtureChallengesService(state: ChallengeFixtures.demoState(now: now))
        let defaults = UserDefaults(suiteName: "BackControlsRender-\(UUID().uuidString)")!
        let model = ChallengesModel(service: service, currentBuild: 100, now: { now }, defaults: defaults)
        await model.refreshConfig()
        await model.refreshList()
        return model
    }

    // MARK: - Renders

    @Test func renderScreens() async throws {
        let container = try seededContainer()
        let model = await challengesModel()

        await render(HangarView().modelContainer(container).environment(model), as: "01_hangar")
        await render(ProfileScreen().modelContainer(container).environment(model), as: "02_profile")

        let entries = [
            LeaderboardEntry(rank: 1, handle: "skykid", points: 4210, catches: 61),
            LeaderboardEntry(rank: 2, handle: "noah", points: 2755, catches: 43),
            LeaderboardEntry(rank: 3, handle: "contrail", points: 1980, catches: 35),
        ]
        let screen = LeaderboardScreen(
            _debugWindows: [.week: LeaderboardResponse(entries: entries, me: MyStanding(rank: 2, points: 2755), window: "week")])
        await render(LeadersSheet(screen: screen).modelContainer(container).environment(model), as: "03_leaderboard")
        await render(ChallengesSheet().environment(model), as: "04_challenges")
        await render(CompassCalibrationSheet(location: LocationManager()), as: "05_compass")
        await render(WikipediaSummarySheet(title: "Boeing 737-800",
                                           summary: BackFixtures.b738Summary,
                                           onOpenURL: { _ in }), as: "06_wikipedia")

        let c = try newestCatch(container)
        let row = HangarRow(icao24: c.icao24, mostRecent: c, count: 1, allCatches: [c])
        await render(NavigationStack { CatchDetailView(row: row) }.modelContainer(container),
                     as: "07_detail_from_hangar", wait: 2)
        await render(NavigationStack { CatchDetailView(row: row, presentedModally: true) }.modelContainer(container),
                     as: "08_detail_from_map", wait: 2)
        await render(CatchPhotoViewer(url: try fixturePhotoURL()), as: "09_photo", wait: 2)
        await render(VStack(spacing: 0) { HangarChildBar(title: "Boeing 737"); Spacer() }
                        .background(Brand.Color.bgPrimary), as: "10_set_detail_bar")

        var reveal = CatchRevealView(
            plane: CardPlane(callsign: "JBU613", model: "Airbus A220-300", carrier: "JetBlue",
                             rarity: .uncommon, type: .narrow,
                             altText: "35,433 ft", speedText: "451 kt", distText: "14.5 km",
                             originIcao: "KBOS", destIcao: "KSFO",
                             originName: "Boston Logan", destName: "San Francisco"),
            entryNumber: 4, onDismiss: {}, onViewInHangar: {}, guess: nil)
        reveal.streakDays = 1
        reveal._reduceMotionOverride = true
        await render(reveal.ignoresSafeArea(), as: "11_reveal", wait: 4)

        // An unlock card, not the first-run recap: seed a ledger under an
        // older roster first (TrophyRecapSnapshotTests' reseed recipe), so
        // the next center sees "new trophies" one card at a time.
        let tag = UUID().uuidString
        let ledger = UserDefaultsTrophyLedger(defaults: UserDefaults(suiteName: "back.trophy.\(tag)")!)
        let suite = UserDefaults(suiteName: "back.trophy.facts.\(tag)")!
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
        await render(TrophyUnlockView(center: center), as: "12_trophy", wait: 2.5)
        #expect(true)
    }
}
#endif
