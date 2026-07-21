//
//  MarketingSnapshotTests.swift
//  TailspotTests
//
//  Marketing-capture harness for the App Store screenshot set
//  (docs/ga/screenshot-plan.md). Renders the six planned shots as
//  full-screen 393×852 @3x PNGs into /private/tmp/tailspot_snaps/marketing/
//  for the framing pass in marketing/app-store-screenshots. NOT an
//  assertion test — same visual-pass pattern as RevealSnapshotTests.
//
//  Shot 1 (the AR catch moment) is a STYLIZED STAND-IN: the simulator has
//  no camera/GPS, so it composes the real HUD components (LockBrackets +
//  the PlaneLabel pill styling) over the onboarding dusk-sky treatment.
//  Replace with a real field capture per the screenshot plan before GA.
//  Shots 2–6 are the real screens with fixture data.
//

#if DEBUG
import Testing
import SwiftUI
import SwiftData
import UIKit
@testable import Tailspot

@MainActor
@Suite(
    "Marketing snapshots (App Store set)",
    .serialized,
    // Capture harness, not a regression net: the window-hosted shots need the
    // booted-sim watcher (tools/marketing-shot-watcher.sh) and crash/idle on
    // CI's parallel clones. Run deliberately:
    //   TEST_RUNNER_MARKETING_CAPTURE=1 xcodebuild test … \
    //     -destination 'platform=iOS Simulator,id=<booted sim>' \
    //     -parallel-testing-enabled NO -only-testing:TailspotTests/MarketingSnapshotTests
    .enabled(if: ProcessInfo.processInfo.environment["MARKETING_CAPTURE"] == "1")
)
struct MarketingSnapshotTests {

    private static let dir = URL(
        fileURLWithPath: "/private/tmp/tailspot_snaps/marketing", isDirectory: true)

    private static let screen = CGSize(width: 393, height: 852)

    /// HangarView's `.task` kicks off `CatchBackfill` against the model
    /// context; if the window/container die before it finishes, the task's
    /// model refs trap (`Catch.registration.getter` assertion — the crash
    /// that took down the whole runner). Retain them for the process
    /// lifetime instead.
    private static var retained: [Any] = []

    // MARK: - Writers (both snapshot paths used by the existing harnesses)

    /// ImageRenderer path — for views ImageRenderer can handle.
    private func write(_ view: some View, name: String) {
        try? FileManager.default.createDirectory(
            at: Self.dir, withIntermediateDirectories: true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        // Pure side-effect harness — never fail CI over a render/write hiccup.
        guard let img = renderer.uiImage, let data = img.pngData() else { return }
        try? data.write(to: Self.dir.appendingPathComponent("\(name).png"))
    }

    /// On-screen capture path — for List/NavigationStack screens.
    /// Offscreen capture (drawHierarchy AND layer.render) relocates Liquid
    /// Glass (.glassEffect) backdrop layers to the window origin, garbling
    /// the segmented switchers. So instead: show the window on the REAL
    /// simulator screen (real scene → real safe areas, correct glass) and
    /// hand off to an outside `simctl io screenshot` watcher via flag files
    /// (`ready_<name>` → watcher screenshots + touches `done_<name>`).
    /// Run with -parallel-testing-enabled NO so the host app is on the
    /// booted, watchable simulator, with the watcher loop running.
    private func snapshotWindow(_ view: some View, name: String, settle: TimeInterval = 0.5) {
        try? FileManager.default.createDirectory(
            at: Self.dir, withIntermediateDirectories: true)
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: view)
        window.frame = scene.screen.bounds
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.windowLevel = .statusBar - 1   // below system chrome, above app
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))

        let ready = Self.dir.appendingPathComponent("ready_\(name)")
        let done = Self.dir.appendingPathComponent("done_\(name)")
        try? FileManager.default.removeItem(at: done)
        try? Data().write(to: ready)
        // Wait up to 20 s for the outside watcher to screenshot; keep the
        // run loop alive so the window stays rendered.
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: done.path), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }
        window.isHidden = true
        Self.retained.append(window)
    }

    // MARK: - Shot 1 · The catch moment (stylized stand-in)

    /// Full-screen version of the onboarding AR-mock treatment: the REAL
    /// LockBrackets + PlaneLabel pill styling over the dusk-sky gradient.
    private func arCatchScene() -> some View {
        let pinnedRarity = resolveAROverlayRarity(
            typecode: "A388", manufacturer: "Airbus", model: "A380-800",
            operatorName: "Lufthansa")
        let ambientRarity = resolveAROverlayRarity(
            typecode: "E75L", manufacturer: "Embraer", model: "ERJ-175",
            operatorName: "SkyWest")

        return ZStack {
            // Dusk sky — the onboarding viewport's stops, full screen.
            LinearGradient(
                stops: [
                    .init(color: Color(red: 0.04, green: 0.07, blue: 0.15), location: 0),
                    .init(color: Color(red: 0.09, green: 0.13, blue: 0.24), location: 0.62),
                    .init(color: Color(red: 0.23, green: 0.19, blue: 0.25), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )

            // The pinned plane: the HUD's lock-on variant (thick brackets,
            // expanded pill with the base-point award).
            VStack(spacing: 2) {
                ZStack {
                    Image(systemName: "airplane")
                        .font(.system(size: 54, weight: .regular))
                        .foregroundStyle(.white.opacity(0.92))
                        .rotationEffect(.degrees(-18))
                    LockBrackets(boxSize: 150, color: Brand.Color.cyan,
                                 opacity: 1.0, lineWidth: 3.5)
                }
                HStack(spacing: 4) {
                    Text("DLH454")
                        .font(Brand.Font.mono(size: 11, weight: .bold))
                        .foregroundStyle(Brand.Color.cyan)
                    Text("· \(pinnedRarity.label) +\(pinnedRarity.basePoints)")
                        .font(Brand.Font.mono(size: 9, weight: .semibold))
                        .foregroundStyle(pinnedRarity.tint)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Brand.Color.bgPrimary.opacity(0.55),
                            in: .rect(cornerRadius: 4))
            }
            .position(x: 172, y: 348)

            // A second, farther plane — dimmed like the HUD dims
            // non-primary labels, so the sky reads as live.
            VStack(spacing: 2) {
                ZStack {
                    Image(systemName: "airplane")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.white.opacity(0.5))
                        .rotationEffect(.degrees(10))
                    LockBrackets(boxSize: 52, color: Brand.Color.cyan,
                                 opacity: 0.45, lineWidth: 1.5)
                }
                HStack(spacing: 4) {
                    Text("SKW3412")
                        .font(Brand.Font.mono(size: 8, weight: .bold))
                        .foregroundStyle(Brand.Color.cyan.opacity(0.6))
                    Text("· \(ambientRarity.label)")
                        .font(Brand.Font.mono(size: 7, weight: .semibold))
                        .foregroundStyle(ambientRarity.tint.opacity(0.6))
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(Brand.Color.bgPrimary.opacity(0.45),
                            in: .rect(cornerRadius: 3))
            }
            .position(x: 300, y: 480)
        }
        .frame(width: Self.screen.width, height: Self.screen.height)
    }

    @Test func renderARCatchMoment() {
        write(arCatchScene(), name: "mkt_01_ar_catch")
    }

    // MARK: - Shot 2 · The reveal

    @Test func renderReveal() {
        // The same plane shot 1 locks onto — point → catch → reveal.
        let plane = CardPlane(
            callsign: "DLH454", model: "Airbus A380-800", carrier: "Lufthansa",
            rarity: .rare, type: .wide,
            altText: "11,475 ft", speedText: "318 kt", distText: "8.6 km",
            originIcao: "FRA", destIcao: "SFO",
            originName: "Frankfurt", destName: "San Francisco",
            isFirstOfType: true
        )
        let view = CatchRevealView(plane: plane, entryNumber: 18,
                                   onDismiss: {}, onViewInHangar: {})
            ._snapshotScreen(width: min(Self.screen.width - 28, 420), size: Self.screen)
        write(view, name: "mkt_02_reveal")
    }

    // MARK: - Shot 2b · The collection card (stylized, same sky as shot 1)

    /// The shot-1 AR lock-on moment re-composed at the card hero's landscape
    /// aspect — this becomes the front card's "catch photo", so slide 2
    /// literally shows the slide-1 catch filed into the collection.
    /// RevealPhoto decodes file URLs synchronously (its ImageRenderer
    /// contract), so a pre-rendered JPEG on disk shows up in a static render.
    private func arHeroPhotoURL() -> URL? {
        let pinnedRarity = resolveAROverlayRarity(
            typecode: "A388", manufacturer: "Airbus", model: "A380-800",
            operatorName: "Lufthansa")
        let scene = ZStack {
            LinearGradient(
                stops: [
                    .init(color: Color(red: 0.04, green: 0.07, blue: 0.15), location: 0),
                    .init(color: Color(red: 0.09, green: 0.13, blue: 0.24), location: 0.62),
                    .init(color: Color(red: 0.23, green: 0.19, blue: 0.25), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            VStack(spacing: 2) {
                ZStack {
                    Image(systemName: "airplane")
                        .font(.system(size: 44, weight: .regular))
                        .foregroundStyle(.white.opacity(0.92))
                        .rotationEffect(.degrees(-18))
                    LockBrackets(boxSize: 120, color: Brand.Color.cyan,
                                 opacity: 1.0, lineWidth: 3)
                }
                HStack(spacing: 4) {
                    Text("DLH454")
                        .font(Brand.Font.mono(size: 11, weight: .bold))
                        .foregroundStyle(Brand.Color.cyan)
                    Text("· \(pinnedRarity.label) +\(pinnedRarity.basePoints)")
                        .font(Brand.Font.mono(size: 9, weight: .semibold))
                        .foregroundStyle(pinnedRarity.tint)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Brand.Color.bgPrimary.opacity(0.55),
                            in: .rect(cornerRadius: 4))
            }
            .position(x: 168, y: 104)
        }
        .frame(width: 400, height: 220)
        let renderer = ImageRenderer(content: scene)
        renderer.scale = 3
        guard let img = renderer.uiImage,
              let jpeg = img.jpegData(compressionQuality: 0.92) else { return nil }
        let url = Self.dir.appendingPathComponent("ar_hero_photo.jpg")
        try? FileManager.default.createDirectory(
            at: Self.dir, withIntermediateDirectories: true)
        try? jpeg.write(to: url)
        return url
    }

    /// "Add each catch to your collection" — the caught A380's settled card
    /// floating in the shot-1 dusk sky, its hero photo the AR lock-on moment
    /// itself, with a previous catch peeking out behind it so it reads as a
    /// growing stack, not a lone receipt.
    @Test func renderCollectionCard() {
        let front = CardPlane(
            callsign: "DLH454", model: "Airbus A380-800", carrier: "Lufthansa",
            rarity: .rare, type: .wide,
            altText: "11,475 ft", speedText: "318 kt", distText: "8.6 km",
            photoURL: arHeroPhotoURL(),
            originIcao: "FRA", destIcao: "SFO",
            originName: "Frankfurt", destName: "San Francisco"
        )
        let behind = CardPlane(
            callsign: "CPA873", model: "Boeing 747-8F", carrier: "Cathay Pacific Cargo",
            rarity: .epic, type: .wide,
            altText: "31,025 ft", speedText: "486 kt", distText: "14.3 km",
            originIcao: "SFO", destIcao: "HKG",
            originName: "San Francisco", destName: "Hong Kong"
        )
        let view = ZStack {
            LinearGradient(
                stops: [
                    .init(color: Color(red: 0.04, green: 0.07, blue: 0.15), location: 0),
                    .init(color: Color(red: 0.09, green: 0.13, blue: 0.24), location: 0.62),
                    .init(color: Color(red: 0.23, green: 0.19, blue: 0.25), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            SettledCatchCard(plane: behind, isFirstOfType: false, width: 330)
                .rotationEffect(.degrees(6))
                .offset(x: 34, y: -44)
                .opacity(0.35)
            SettledCatchCard(plane: front, isFirstOfType: true, width: 344)
                .shadow(color: .black.opacity(0.45), radius: 28, y: 14)
        }
        .frame(width: Self.screen.width, height: Self.screen.height)
        // NOT the ImageRenderer path: `.postHogMask` wraps the photo in a
        // UIKit tag view, and ImageRenderer draws platform views as the
        // yellow "no entry" placeholder. drawHierarchy in an offscreen
        // window renders it fine (no .glassEffect in the card, so the
        // glass-garble caveat doesn't apply).
        let bounds = CGRect(origin: .zero, size: Self.screen)
        let host = UIHostingController(rootView: view.ignoresSafeArea())
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.isHidden = false
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 3
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: fmt)
        let png = renderer.pngData { _ in
            host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try? png.write(to: Self.dir.appendingPathComponent("mkt_07_collection.png"))
        window.isHidden = true
        Self.retained.append(window)
    }

    // MARK: - Shot 3 · The guess round (chips popped, route masked)

    @Test func renderGuessRound() {
        var rng = SeededRNG(seed: 7)
        guard let route = GuessOptions.routeQuestion(
            originIcao: "KSFO", destIcao: "VHHH",
            observerLat: 37.87, observerLon: -122.27,
            using: &rng
        ) else {
            Issue.record("route question fixture failed to build")
            return
        }
        let question = GuessRoundQuestion(route: route)
        // B748 is epic in AircraftTypes.json — an honest tier for the ad.
        let plane = CardPlane(
            callsign: "CPA873", model: "Boeing 747-8F", carrier: "Cathay Pacific Cargo",
            rarity: .epic, type: .wide,
            altText: "31,025 ft", speedText: "486 kt", distText: "14.3 km",
            originIcao: "SFO", destIcao: "HKG",
            originName: "San Francisco", destName: "Hong Kong",
            isFirstOfType: true
        )
        let popped = CatchRevealView.GuessSnapshotState(
            render: .init(question: question, resolution: nil,
                          chipsInLayout: true, popClock: 1),
            bt: 0
        )
        let view = CatchRevealView(plane: plane, entryNumber: 18,
                                   onDismiss: {}, onViewInHangar: {}, guess: question)
            ._snapshotScreen(width: min(Self.screen.width - 28, 420),
                             size: Self.screen, guessState: popped)
        write(view, name: "mkt_03_guess_round")
    }

    // MARK: - Shots 4 + 5 · The Hangar (sets grid, trophy case)

    /// A believable Berkeley-area collection across all seven sets.
    private func seededContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Catch.self, configurations: config)
        let context = ModelContext(container)

        // (callsign, model, manufacturer, operator, typecode, registration,
        //  origin, dest, daysAgo, slantKm)
        let fleet: [(String?, String, String, String?, String, String,
                     String?, String?, Double, Double)] = [
            ("UAL1512", "737 MAX 9", "Boeing", "United Airlines", "B39M", "N37522",
             "KSFO", "KSEA", 0.2, 8.4),
            ("SWA1234", "737-800", "Boeing", "Southwest Airlines", "B738", "N8325D",
             "KOAK", "KSAN", 0.4, 4.2),
            ("ASA331", "A321neo", "Airbus", "Alaska Airlines", "A21N", "N928VA",
             "KSFO", "KPDX", 1.1, 9.6),
            ("DAL972", "A220-300", "Airbus", "Delta Air Lines", "BCS3", "N305DU",
             "KSLC", "KSFO", 2.0, 12.1),
            ("UAL857", "777-300ER", "Boeing", "United Airlines", "B77W", "N2749U",
             "KSFO", "ZSPD", 2.3, 11.2),
            ("ANA858", "787-9", "Boeing", "All Nippon Airways", "B789", "JA936A",
             "RJTT", "KSFO", 3.1, 13.5),
            ("KAL024", "A350-900", "Airbus", "Korean Air", "A359", "HL8598",
             "RKSI", "KSFO", 4.4, 15.0),
            ("CPA879", "747-8F", "Boeing", "Cathay Pacific Cargo", "B748", "B-LJC",
             "VHHH", "KSFO", 5.2, 17.7),
            ("SKW3412", "ERJ-175", "Embraer", "SkyWest Airlines", "E75L", "N161SY",
             "KSFO", "KBOI", 5.9, 7.3),
            ("QXE2201", "ERJ-175", "Embraer", "Horizon Air", "E75L", "N651QX",
             "KPDX", "KSJC", 7.0, 9.9),
            ("N123GS", "G650ER", "Gulfstream Aerospace", nil, "GLF6", "N123GS",
             "KSJC", "PHNL", 8.5, 6.1),
            ("N77XJ", "Citation X", "Cessna", nil, "C750", "N77XJ",
             "KOAK", "KLAS", 9.8, 5.5),
            ("RCH872", "C-17 Globemaster III", "Boeing", "U.S. Air Force", "C17", "07-7189",
             "KSUU", "PHIK", 11.0, 9.2),
            ("GOLD61", "KC-135R Stratotanker", "Boeing", "U.S. Air Force", "K35R", "62-3534",
             "KSUU", nil, 12.4, 21.0),
            ("N4521C", "172", "Cessna", nil, "C172", "N4521C",
             nil, nil, 13.1, 3.8),
            ("N8127T", "SR22", "Cirrus", nil, "S22T", "N8127T",
             nil, nil, 14.6, 4.4),
            ("N877MG", "DC-3", "Douglas", nil, "DC3", "N877MG",
             nil, nil, 16.2, 5.9),
        ]

        let now = Date()
        for (i, f) in fleet.enumerated() {
            let c = Catch(
                icao24: String(format: "a%05x", 0x1000 + i * 613),
                callsign: f.0, model: f.1, manufacturer: f.2,
                operatorName: f.3,
                caughtAt: now.addingTimeInterval(-f.8 * 86_400),
                observerLat: 37.87, observerLon: -122.27,
                slantDistanceMeters: f.9 * 1_000,
                registration: f.5,
                typecode: f.4,
                originIcao: f.6, destIcao: f.7,
                placeName: "Berkeley, CA"
            )
            context.insert(c)
        }
        try context.save()
        return container
    }

    @Test func renderHangarSetsAndTrophies() throws {
        let container = try seededContainer()
        Self.retained.append(container)

        // HangarView reads its segment from @AppStorage — pin it per shot
        // and restore afterward.
        let defaults = UserDefaults.standard
        let savedSegment = defaults.object(forKey: "tailspot.hangar.view")
        defer { defaults.set(savedSegment, forKey: "tailspot.hangar.view") }

        defaults.set(HangarSegment.sets.rawValue, forKey: "tailspot.hangar.view")
        snapshotWindow(HangarView().modelContainer(container),
                       name: "mkt_04_hangar_sets", settle: 0.8)

        defaults.set(HangarSegment.trophies.rawValue, forKey: "tailspot.hangar.view")
        snapshotWindow(HangarView().modelContainer(container),
                       name: "mkt_05_trophies", settle: 0.8)
    }

    // MARK: - Shot 6 · The leaderboard

    @Test func renderLeaderboard() throws {
        let defaults = UserDefaults.standard
        let savedHandle = defaults.object(forKey: SpotterHandle.storageKey)
        defaults.set("noah", forKey: SpotterHandle.storageKey)
        defer { defaults.set(savedHandle, forKey: SpotterHandle.storageKey) }

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Catch.self, configurations: config)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let resetsAt = iso.string(
            from: Date().addingTimeInterval(2 * 86_400 + 14 * 3_600 + 600))

        let entries: [LeaderboardEntry] = [
            .init(rank: 1, handle: "skykid", points: 1_240, catches: 21),
            .init(rank: 2, handle: "noah", points: 985, catches: 17),
            .init(rank: 3, handle: "contrail", points: 720, catches: 14),
            .init(rank: 4, handle: "heavywatcher", points: 615, catches: 9),
            .init(rank: 5, handle: "finalapproach", points: 450, catches: 11),
            .init(rank: 6, handle: "spotterella", points: 380, catches: 8),
            .init(rank: 7, handle: "dotbali", points: 240, catches: 6),
            .init(rank: 8, handle: "gearup", points: 110, catches: 3),
        ]
        let response = LeaderboardResponse(
            entries: entries,
            me: MyStanding(rank: 2, points: 985, weeklyWins: 1, everToppedAllTime: false),
            window: "week",
            resetsAt: resetsAt,
            champions: [LeaderboardChampion(handle: "contrail", points: 860,
                                            weekStart: "2026-07-13")]
        )
        let view = NavigationStack {
            LeaderboardScreen(_debugWindows: [.week: response], selected: .week)
        }
        .modelContainer(container)
        snapshotWindow(view, name: "mkt_06_leaderboard", settle: 0.8)
    }
}
#endif
