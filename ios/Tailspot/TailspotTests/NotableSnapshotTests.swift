//
//  NotableSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the notable-plane feature (the
//  SettledCardSnapshotTests pattern): renders every touched surface to
//  /private/tmp/tailspot_snaps/notable_*.png as before/after pairs, the same
//  plane without and with the server's notable flag. Covers a long name, a
//  missing name, an unknown kind, and notable + first-of-type together.
//  NOT an assertion test: it writes PNGs for a person to look at.
//

#if DEBUG
import Testing
import SwiftUI
import SwiftData
import UIKit
@testable import Tailspot

@MainActor
@Suite("Notable plane snapshots (visual pass)", .serialized)
struct NotableSnapshotTests {

    private static let dir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)

    // MARK: Fixtures

    static let team = NotablePlane(kind: "team", label: "Team plane",
                                   name: "Golden State Warriors")!
    /// The longest category the server sends, with a long name under it.
    static let longName = NotablePlane(
        kind: "government", label: "Head of state and government",
        name: "United States Air Force, 89th Airlift Wing, Presidential Airlift Group")!
    static let noName = NotablePlane(kind: "business", label: "Business jet", name: nil)!
    /// A kind this build has never heard of: renders from its label.
    static let unknownKind = NotablePlane(kind: "zeppelin", label: "Airship of note",
                                          name: "Spirit of Innovation")!

    private static func b752(notable: NotablePlane?, firstOfType: Bool = false,
                             pressSize: Int = 1, photo: URL? = nil) -> CardPlane {
        CardPlane(
            callsign: "DAL8935", model: "Boeing 757-200", carrier: "Delta Air Lines",
            rarity: .uncommon, type: .narrow,
            altText: "34,000 ft", speedText: "462 kt", distText: "11.4 km",
            photoURL: photo, photoFocus: photo == nil ? nil : CGPoint(x: 0.6, y: 0.35),
            originIcao: "OAK", destIcao: "DEN",
            originName: "Oakland", destName: "Denver",
            isFirstOfType: firstOfType, pressSize: pressSize, notable: notable,
            icao24: "a1b2c3")
    }

    private static func vc25(notable: NotablePlane?, firstOfType: Bool = true) -> CardPlane {
        CardPlane(
            callsign: "SAM28000", model: "Boeing VC-25A", carrier: "U.S. Air Force",
            rarity: .legendary, type: .mil,
            altText: "31,000 ft", speedText: "480 kt", distText: "18.9 km",
            originIcao: "ADW", destIcao: nil, originName: "Joint Base Andrews", destName: nil,
            isFirstOfType: firstOfType, notable: notable, icao24: "adfdf8")
    }

    private static func gulfstream(notable: NotablePlane?) -> CardPlane {
        CardPlane(
            callsign: "N650GX", model: "Gulfstream G650", carrier: "Private",
            rarity: .rare, type: .biz,
            altText: "41,000 ft", speedText: "505 kt", distText: "14.0 km",
            notable: notable, icao24: "a8c0de")
    }

    // MARK: Render helpers

    private func write(_ view: some View, _ name: String, scale: CGFloat = 3) {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        let renderer = ImageRenderer(content: view
            .environment(\.colorScheme, .dark)
            .environment(\.replayMaskingDisabled, true))
        renderer.scale = scale
        guard let img = renderer.uiImage, let data = img.pngData() else { return }
        try? data.write(to: Self.dir.appendingPathComponent("\(name).png"))
    }

    /// Hosted-window render, for views ImageRenderer can't draw (ScrollView).
    private func hosted(_ view: some View, _ name: String,
                        size: CGSize = CGSize(width: 393, height: 852)) async {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        let bounds = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: view.preferredColorScheme(.dark))
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(400))
        let png = UIGraphicsImageRenderer(bounds: bounds).pngData { _ in
            host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try? png.write(to: Self.dir.appendingPathComponent("\(name).png"))
        window.isHidden = true
    }

    private func syntheticPhoto() -> URL? {
        let size = CGSize(width: 1200, height: 1600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let colors = [UIColor(red: 0.09, green: 0.23, blue: 0.42, alpha: 1).cgColor,
                          UIColor(red: 0.55, green: 0.75, blue: 0.92, alpha: 1).cgColor]
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: colors as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            UIColor(white: 0.12, alpha: 1).setFill()
            cg.fillEllipse(in: CGRect(x: 680, y: 540, width: 90, height: 30))
        }
        guard let data = img.jpegData(compressionQuality: 0.9) else { return nil }
        let url = Self.dir.appendingPathComponent("notable_synthetic_catch.jpg")
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        try? data.write(to: url)
        return url
    }

    // MARK: 1. Live AR label

    private func observed(callsign: String, notable: NotablePlane?) -> ObservedAircraft {
        ObservedAircraft(
            aircraft: Aircraft(
                icao24: "a1b2c3", callsign: callsign, originCountry: "United States",
                longitude: -122.3, latitude: 37.7, altitudeMeters: 9_000,
                velocityMps: 230, trackDeg: 90, onGround: false, positionTimestamp: nil,
                typecode: "B752", notable: notable),
            bearingDeg: 10, elevationDeg: 30,
            groundDistanceMeters: 9_000, slantDistanceMeters: 11_400)
    }

    @Test func renderARLabels() {
        let meta = AircraftMetadata(icao24: "a1b2c3", registration: "N661DN",
                                    manufacturerName: "Boeing", manufacturerIcao: nil,
                                    model: "757-200", typecode: "B752", operatorName: "Delta")
        let styles: [(String, PlaneLabel.Style)] = [
            ("chosen", .chosen), ("quiet", .quiet), ("faint", .faint), ("pinned", .pinned),
        ]
        // Bright sky and dark sky: the gold star has to read on both.
        let skies: [(String, [Color])] = [
            ("daysky", [Color(red: 0.36, green: 0.60, blue: 0.88), Color(red: 0.78, green: 0.88, blue: 0.97)]),
            ("dusk", [Color(red: 0.05, green: 0.07, blue: 0.15), Color(red: 0.25, green: 0.22, blue: 0.35)]),
        ]
        for (skyName, colors) in skies {
            for (tag, notable) in [("before", nil), ("after", Self.team)] as [(String, NotablePlane?)] {
                let view = ZStack {
                    LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
                    ForEach(Array(styles.enumerated()), id: \.offset) { i, s in
                        PlaneLabel(aircraft: observed(callsign: "DAL8935", notable: notable),
                                   position: CGPoint(x: 100 + CGFloat(i % 2) * 190,
                                                     y: 100 + CGFloat(i / 2) * 190),
                                   style: s.1, metadata: meta)
                    }
                }
                .frame(width: 393, height: 400)
                write(view, "notable_arlabel_\(skyName)_\(tag)")
            }
        }
    }

    // MARK: 2. Reveal

    @Test func renderReveals() {
        let screen = CGSize(width: 393, height: 852)
        let cases: [(String, CardPlane)] = [
            ("notable_reveal_team_before", Self.b752(notable: nil)),
            ("notable_reveal_team_after", Self.b752(notable: Self.team)),
            ("notable_reveal_longname_firstoftype_before", Self.vc25(notable: nil)),
            ("notable_reveal_longname_firstoftype_after", Self.vc25(notable: Self.longName)),
            ("notable_reveal_noname_before", Self.gulfstream(notable: nil)),
            ("notable_reveal_noname_after", Self.gulfstream(notable: Self.noName)),
            ("notable_reveal_unknownkind_after", Self.gulfstream(notable: Self.unknownKind)),
            ("notable_reveal_everybonus_after",
             Self.b752(notable: Self.team, firstOfType: true, pressSize: 3)),
        ]
        for (name, plane) in cases {
            let view = CatchRevealView(plane: plane, entryNumber: 62, onDismiss: {}, onViewInHangar: {})
                ._snapshotScreen(width: min(screen.width - 28, 420), size: screen)
            write(view, name)
        }
        // A duplicate of a notable plane: the plate shows, no bonus line.
        let dup = CatchRevealView(plane: Self.b752(notable: Self.team), entryNumber: 62,
                                  onDismiss: {}, onViewInHangar: {}, isDuplicate: true)
            ._snapshotScreen(width: min(screen.width - 28, 420), size: screen)
        write(dup, "notable_reveal_team_duplicate")
        // The short screen (SE safe area), worst case: long name + two bonuses.
        let se = CGSize(width: 375, height: 647)
        for (tag, notable) in [("before", nil), ("after", Self.longName)] as [(String, NotablePlane?)] {
            let view = CatchRevealView(plane: Self.vc25(notable: notable), entryNumber: 4,
                                       onDismiss: {}, onViewInHangar: {})
                ._snapshotScreen(width: min(se.width - 28, 420), size: se)
            write(view, "notable_reveal_se_longname_\(tag)", scale: 2)
        }
    }

    // MARK: 3. Multi-catch summary

    @Test func renderMultiCatchSummary() {
        for (tag, notable) in [("before", nil), ("after", Self.team)] as [(String, NotablePlane?)] {
            let entries: [MultiCatchReveal.Entry] = [
                .init(plane: Self.b752(notable: notable, firstOfType: true, pressSize: 2),
                      isDuplicate: false),
                .init(plane: .init(callsign: "SWA4244", model: "Boeing 737-800", carrier: "Southwest",
                                   rarity: .common, type: .narrow, pressSize: 2), isDuplicate: false),
                .init(plane: Self.gulfstream(notable: notable == nil ? nil : Self.noName),
                      isDuplicate: true),
            ]
            var multi = MultiCatchReveal(entries: entries, lastEntryNumber: 48,
                                         onDismiss: {}, onViewInHangar: {})
            multi._snapshotPage = entries.count
            write(multi.frame(width: 393, height: 852), "notable_multi_summary_\(tag)")
        }
    }

    // MARK: 4. Settled card

    @Test func renderSettledCards() {
        let cases: [(String, CardPlane, Bool)] = [
            ("notable_settled_team_before", Self.b752(notable: nil), false),
            ("notable_settled_team_after", Self.b752(notable: Self.team), false),
            ("notable_settled_longname_firstoftype_before", Self.vc25(notable: nil), true),
            ("notable_settled_longname_firstoftype_after", Self.vc25(notable: Self.longName), true),
            ("notable_settled_noname_before", Self.gulfstream(notable: nil), false),
            ("notable_settled_noname_after", Self.gulfstream(notable: Self.noName), false),
            ("notable_settled_everybonus_after",
             Self.b752(notable: Self.team, firstOfType: true, pressSize: 2), true),
        ]
        for (name, plane, first) in cases {
            let view = SettledCatchCard(plane: plane, isFirstOfType: first, width: 357,
                                        caughtAt: Date(timeIntervalSince1970: 1_790_000_000))
                .padding(12)
                .background(Brand.Color.bgPrimary)
            write(view, name)
        }
    }

    // MARK: 5. Share cards

    @Test func renderShareCards() {
        let photo = syntheticPhoto()
        let cases: [(String, CardPlane)] = [
            ("team_before", Self.b752(notable: nil, firstOfType: true, photo: photo)),
            ("team_after", Self.b752(notable: Self.team, firstOfType: true, photo: photo)),
            ("longname_before", Self.vc25(notable: nil)),
            ("longname_after", Self.vc25(notable: Self.longName)),
            ("noname_before", Self.gulfstream(notable: nil)),
            ("noname_after", Self.gulfstream(notable: Self.noName)),
        ]
        for (tag, plane) in cases {
            write(CatchShareCard(plane: plane), "notable_share_card_\(tag)")
            write(CatchShareCompactCard(plane: plane, format: .post), "notable_share_post_\(tag)")
            write(CatchShareCompactCard(plane: plane, format: .square), "notable_share_square_\(tag)")
        }
    }

    // MARK: 6. Card back

    @Test func renderCardBacks() async {
        let info = TypeInfo(entryId: "b752", wikipediaTitle: "Boeing 757", wikidataId: nil,
                            firstFlightYear: 1982, numberBuilt: 1_050,
                            wingspanMeters: 38.05, lengthMeters: 47.32, photo: nil)
        let history = TypeHistory(
            firstCaughtAt: Date(timeIntervalSince1970: 1_780_000_000),
            airlines: [.init(name: "Delta Air Lines", count: 3), .init(name: "United Airlines", count: 1)])
        let summary = WikipediaSummary(
            extract: "The Boeing 757 is an American narrow-body airliner designed and built by Boeing Commercial Airplanes.",
            intro: "The Boeing 757 is an American narrow-body airliner designed and built by Boeing Commercial Airplanes. It entered service in 1983.",
            pageURL: URL(string: "https://en.m.wikipedia.org/wiki/Boeing_757")!)
        func model(_ notable: NotablePlane?) -> CardBackModel {
            CardBackModel(modelName: "Boeing 757-200", registration: "N661DN", rarity: .uncommon,
                          closeup: .none, typeInfo: info, history: history,
                          summary: summary, summaryLoading: false, notable: notable)
        }
        let cases: [(String, NotablePlane?)] = [
            ("before", nil), ("team_after", Self.team),
            ("longname_after", Self.longName), ("noname_after", Self.noName),
        ]
        for (tag, notable) in cases {
            let view = CatchCardBack(model: model(notable), width: 357,
                                     onOpenURL: { _ in }, snapshotImage: nil)
                .frame(height: 560)
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Brand.Color.bgPrimary)
            await hosted(view, "notable_cardback_\(tag)", size: CGSize(width: 393, height: 680))
        }
    }

    // MARK: 7. Hangar row

    private func makeCatch(
        icao: String, callsign: String?, operatorName: String?, typecode: String?,
        origin: String? = nil, dest: String? = nil, place: String? = nil,
        at: TimeInterval = 1_790_000_000, notable: NotablePlane? = nil
    ) -> Catch {
        let c = Catch(icao24: icao, callsign: callsign, model: nil, manufacturer: nil,
                      operatorName: operatorName,
                      caughtAt: Date(timeIntervalSince1970: at),
                      observerLat: 37.87, observerLon: -122.27, slantDistanceMeters: 9_800,
                      typecode: typecode, originIcao: origin, destIcao: dest, placeName: place)
        c.setNotable(notable)
        return c
    }

    @Test func renderHangarRows() {
        // (name, catch builder, rich, first-of-type)
        typealias Row = (String, (NotablePlane?) -> Catch, NotablePlane, Bool, Bool)
        let rowsToRender: [Row] = [
            ("team", { self.makeCatch(icao: "a1b2c3", callsign: "DAL8935", operatorName: "Delta Air Lines",
                                      typecode: "B752", origin: "KOAK", dest: "KDEN", notable: $0) },
             Self.team, true, false),
            ("team_firstoftype", { self.makeCatch(icao: "a1b2c3", callsign: "DAL8935",
                                                  operatorName: "Delta Air Lines", typecode: "B752",
                                                  origin: "KOAK", dest: "KDEN", notable: $0) },
             Self.team, true, true),
            ("longname_firstoftype", { self.makeCatch(icao: "ae1234", callsign: "RCH130",
                                                      operatorName: "U.S. Air Force", typecode: "C30J",
                                                      origin: "KSUU", dest: "PHIK", notable: $0) },
             Self.longName, true, true),
            ("noname_noroute", { self.makeCatch(icao: "a7c8d9", callsign: "N700GX", operatorName: nil,
                                                typecode: "GLEX", place: "Oakland, CA", notable: $0) },
             Self.noName, true, false),
            ("compact_sets", { self.makeCatch(icao: "a1b2c3", callsign: "DAL8935",
                                              operatorName: "Delta Air Lines", typecode: "B752",
                                              place: "Oakland, CA", notable: $0) },
             Self.team, false, false),
        ]
        for (name, build, notable, rich, first) in rowsToRender {
            for (tag, flag) in [("before", nil), ("after", notable)] as [(String, NotablePlane?)] {
                let c = build(flag)
                let row = HangarRow(icao24: c.icao24, mostRecent: c, count: 1, allCatches: [c])
                // The narrowest feed card (375 pt phone) and the widest.
                for width in [343.0, 370.0] {
                    let view = TailCard(row: row, showPoints: rich, isFirstOfType: first)
                        .frame(width: width)
                        .padding(12)
                        .background(Brand.Color.bgPrimary)
                    write(view, "notable_hangarrow_\(name)_w\(Int(width))_\(tag)")
                }
            }
        }
        // Largest text size: the stacked accessibility layout.
        let c = makeCatch(icao: "ae1234", callsign: "RCH130", operatorName: "U.S. Air Force",
                          typecode: "C30J", origin: "KSUU", dest: "PHIK", notable: Self.longName)
        let row = HangarRow(icao24: c.icao24, mostRecent: c, count: 1, allCatches: [c])
        write(TailCard(row: row, showPoints: true, isFirstOfType: true)
            .frame(width: 343).padding(12).background(Brand.Color.bgPrimary)
            .dynamicTypeSize(.accessibility2), "notable_hangarrow_longname_ax2_after")
    }

    // MARK: 8. Hangar Catches list + filter

    private func hangar(notableCount: Int) throws -> ModelContainer {
        let container = try ModelContainer(
            for: Catch.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        TestContainerRetention.retain(container)
        let seeds: [(String, String, String, String, NotablePlane?)] = [
            ("a1b2c3", "DAL8935", "B752", "Oakland", Self.team),
            ("a2b3c4", "SWA4244", "B738", "Berkeley", nil),
            ("adfdf8", "SAM28000", "B742", "Alameda", Self.longName),
            ("86e123", "ANA858", "B789", "San Francisco", nil),
            ("a8c0de", "N650GX", "GLF6", "Oakland", Self.noName),
            ("4b1801", "SWR38", "A333", "Berkeley", nil),
            ("a4e172", "N4521C", "C172", "Oakland", nil),
        ]
        var flagged = 0
        for (i, s) in seeds.enumerated() {
            let c = Catch(icao24: s.0, callsign: s.1, model: nil, manufacturer: nil,
                          caughtAt: Date(timeIntervalSince1970: 1_790_000_000 - Double(i) * 3_600),
                          observerLat: 37.87, observerLon: -122.27, slantDistanceMeters: 9_800,
                          typecode: s.2)
            c.placeName = s.3
            if let n = s.4, flagged < notableCount {
                c.setNotable(n)
                flagged += 1
            }
            container.mainContext.insert(c)
        }
        return container
    }

    private func catchesScreen(query: String = "") -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                HangarSegmentedSwitcher(selection: .constant(.recent))
                HangarRecentView(initialQuery: query)
            }
            .background(Brand.Color.bgPrimary)
        }
    }

    @Test func renderHangarCatchesList() async throws {
        await hosted(catchesScreen().modelContainer(try hangar(notableCount: 0)),
                     "notable_catches_list_before")
        await hosted(catchesScreen().modelContainer(try hangar(notableCount: 3)),
                     "notable_catches_list_after")
        await hosted(catchesScreen(query: "warriors").modelContainer(try hangar(notableCount: 3)),
                     "notable_catches_search_by_name")
        await hosted(catchesScreen(query: "notable").modelContainer(try hangar(notableCount: 0)),
                     "notable_catches_word_empty")
    }
}
#endif
