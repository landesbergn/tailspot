//
//  CardBackSnapshotTests.swift
//  TailspotTests
//
//  The card back (2026-10-25): formatting decisions pinned as plain unit
//  tests, plus a visual pass — the back in its three shapes (airframe photo
//  with everything, a GA type with the Commons fallback and fewer facts,
//  and the bare minimum) and five frames of the 3D flip from a real
//  SettledCatchCard front. Hosted in a UIWindow and captured with
//  drawHierarchy (ImageRenderer can't render the flip's 3D transforms
//  faithfully); PNGs land in /private/tmp/tailspot_snaps. The snapshot
//  suite asserts only "it rendered" — the PNGs are for looking at.
//

import Testing
import SwiftUI
import UIKit
@testable import Tailspot

// MARK: - Fixed example data

nonisolated enum BackFixtures {
    static let firstCaught = Date(timeIntervalSince1970: 1_772_625_600) // 2026-03-04 12:00 UTC

    static let b738Info = TypeInfo(
        entryId: "f737-800", wikipediaTitle: "Boeing 737 Next Generation", wikidataId: "Q1084919",
        firstFlightYear: 1997, numberBuilt: 4991, wingspanMeters: 35.79, lengthMeters: 39.47,
        photo: nil)

    static let b738History = TypeHistory(
        firstCaughtAt: firstCaught,
        airlines: [
            .init(name: "United", count: 3), .init(name: "Southwest", count: 2),
            .init(name: "Alaska", count: 1), .init(name: "American", count: 1),
            .init(name: "Delta", count: 1),
        ])

    // Test copy written for the fixture (not real Wikipedia text).
    static let b738Summary = WikipediaSummary(
        extract: "The Boeing 737-800 is a stretched member of the 737 Next Generation family of narrow-body airliners. It entered service in 1998 and became the most widely flown variant of the family.",
        intro: "The Boeing 737-800 is a stretched member of the 737 Next Generation family of narrow-body airliners. It entered service in 1998 and became the most widely flown variant of the family. A third sentence only the sheet shows.",
        pageURL: URL(string: "https://en.m.wikipedia.org/wiki/Boeing_737_Next_Generation")!)

    static let planespotters = PlanePhoto(
        thumbnailLargeURL: URL(string: "https://t.plnspttrs.net/00000/0000000_280.jpg")!,
        thumbnailURL: URL(string: "https://t.plnspttrs.net/00000/0000000_t.jpg")!,
        link: URL(string: "https://www.planespotters.net/photo/0000000")!,
        photographer: "Test Photographer")

    static let b738 = CardBackModel(
        modelName: "Boeing 737-800", registration: "N37267", rarity: .common,
        closeup: .planespotters(planespotters), typeInfo: b738Info, history: b738History,
        summary: b738Summary, summaryLoading: false)

    static let c172Photo = TypePhoto(
        imageURL: URL(string: "https://upload.wikimedia.org/wikipedia/commons/thumb/x/xx/Example.jpg/800px-Example.jpg")!,
        pageURL: URL(string: "https://commons.wikimedia.org/wiki/File:Example.jpg")!,
        artist: "Example Artist", license: "CC BY-SA 4.0")

    static let c172 = CardBackModel(
        modelName: "Cessna 172 Skyhawk", registration: "N12345", rarity: .uncommon,
        closeup: .commons(c172Photo),
        typeInfo: TypeInfo(entryId: "c172", wikipediaTitle: nil, wikidataId: nil,
                           firstFlightYear: 1955, numberBuilt: nil,
                           wingspanMeters: 11.0, lengthMeters: 8.28, photo: c172Photo),
        history: TypeHistory(firstCaughtAt: firstCaught, airlines: []),
        summary: nil, summaryLoading: false)

    static let minimal = CardBackModel(
        modelName: "Unknown aircraft", registration: nil, rarity: .common,
        closeup: .none, typeInfo: nil,
        history: TypeHistory(firstCaughtAt: firstCaught,
                             airlines: [.init(name: "Southwest", count: 2)]),
        summary: nil, summaryLoading: false)
}

// MARK: - Formatting

@Suite("Card back formatting")
struct CardBackFormatTests {
    private let us = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")

    @Test func numberBuiltIsExactAndGrouped() {
        #expect(CardBackFormat.numberBuilt(4991, locale: us) == "4,991")
        #expect(CardBackFormat.numberBuilt(44_000, locale: us) == "44,000")
        #expect(CardBackFormat.numberBuilt(4991, locale: de) == "4.991")
        #expect(CardBackFormat.numberBuilt(12, locale: us) == "12")
    }

    @Test func lengthsFollowTheUnitAndLocale() {
        #expect(CardBackFormat.length(meters: 35.79, unit: .meters, locale: us) == "35.8 m")
        #expect(CardBackFormat.length(meters: 11.0, unit: .meters, locale: us) == "11 m")
        #expect(CardBackFormat.length(meters: 35.79, unit: .feet, locale: us) == "117 ft")
        let german = CardBackFormat.splitMeasurement(
            CardBackFormat.length(meters: 35.79, unit: .meters, locale: de))
        #expect(german.value == "35,8")
        #expect(german.unit == "m")
    }

    @Test func splitMeasurementHandlesNonBreakingSpaces() {
        for (raw, value, unit) in [("117 ft", "117", "ft"),
                                   ("35,8\u{00A0}m", "35,8", "m"),
                                   ("35,8\u{202F}m", "35,8", "m")] {
            let p = CardBackFormat.splitMeasurement(raw)
            #expect(p.value == value)
            #expect(p.unit == unit)
        }
        let bare = CardBackFormat.splitMeasurement("1997")
        #expect(bare.value == "1997" && bare.unit == nil)
    }

    @Test func specCellsOmitUnknownFactsAndKeepYearsUngrouped() {
        let all = CardBackFormat.specCells(BackFixtures.b738Info, unit: .meters, locale: us)
        #expect(all.map(\.label) == ["FIRST FLEW", "BUILT", "WINGSPAN", "LENGTH"])
        #expect(all[0].value == "1997")
        #expect(all[1].value == "4,991")
        #expect(all[2] == CardBackCell(label: "WINGSPAN", value: "35.8", unit: "m"))

        let ga = CardBackFormat.specCells(BackFixtures.c172.typeInfo, unit: .feet, locale: us)
        #expect(ga.map(\.label) == ["FIRST FLEW", "WINGSPAN", "LENGTH"])

        #expect(CardBackFormat.specCells(nil, unit: .feet, locale: us).isEmpty)
        let empty = TypeInfo(entryId: "", wikipediaTitle: nil, wikidataId: nil, firstFlightYear: nil,
                             numberBuilt: nil, wingspanMeters: nil, lengthMeters: nil, photo: nil)
        #expect(CardBackFormat.specCells(empty, unit: .feet, locale: us).isEmpty)
    }

    @Test func catchLogShowsTopThreeThenHowManyMore() {
        let log = CardBackFormat.catchLog(BackFixtures.b738History.airlines)
        #expect(log.rows == [.init(name: "United", count: "3×"),
                             .init(name: "Southwest", count: "2×"),
                             .init(name: "Alaska", count: "1×")])
        #expect(log.more == 2)
        let one = CardBackFormat.catchLog([.init(name: "Southwest", count: 2)])
        #expect(one.rows == [.init(name: "Southwest", count: "2×")] && one.more == 0)
        let empty = CardBackFormat.catchLog([])
        #expect(empty.rows.isEmpty && empty.more == 0)
    }

    @Test func firstCaughtIsAShortDate() {
        #expect(CardBackFormat.firstCaught(BackFixtures.firstCaught, locale: us,
                                           timeZone: TimeZone(identifier: "UTC")!) == "Mar 4, 2026")
    }

    @Test func registrationTagOnlyOnThisAirframesPhoto() {
        #expect(CardBackFormat.showsRegistrationTag(for: .planespotters(BackFixtures.planespotters)))
        #expect(!CardBackFormat.showsRegistrationTag(for: .commons(BackFixtures.c172Photo)))
        #expect(!CardBackFormat.showsRegistrationTag(for: .none))
        #expect(!CardBackFormat.showsRegistrationTag(for: .loading))
    }

    @Test func creditsAndLinksPerCloseup() {
        let ps = CardBackCloseup.planespotters(BackFixtures.planespotters)
        #expect(CardBackFormat.credit(for: ps) == "© Test Photographer · planespotters.net")
        #expect(CardBackFormat.link(for: ps) == BackFixtures.planespotters.link)
        #expect(CardBackFormat.photoAccessibilityLabel(for: ps) == "View photo on Planespotters.net")

        let commons = CardBackCloseup.commons(BackFixtures.c172Photo)
        #expect(CardBackFormat.credit(for: commons) == "Example Artist · CC BY-SA 4.0 · Wikimedia Commons")
        #expect(CardBackFormat.link(for: commons) == BackFixtures.c172Photo.pageURL)
        #expect(CardBackFormat.photoAccessibilityLabel(for: commons) == "View photo on Wikimedia Commons")

        // The licence and source live in `source`, which the view never
        // truncates; only the author gives way on a long Commons credit.
        let long = TypePhoto(imageURL: BackFixtures.c172Photo.imageURL,
                             pageURL: BackFixtures.c172Photo.pageURL,
                             artist: String(repeating: "Very Long Author Name ", count: 8),
                             license: "CC BY-SA 2.0")
        #expect(CardBackFormat.creditParts(for: .commons(long))?.source == "CC BY-SA 2.0 · Wikimedia Commons")
        #expect(CardBackFormat.creditParts(for: ps)
                == .init(author: "© Test Photographer", source: "planespotters.net"))

        // Public domain with no known author: credit the licence alone.
        let anon = TypePhoto(imageURL: BackFixtures.c172Photo.imageURL,
                             pageURL: BackFixtures.c172Photo.pageURL,
                             artist: "", license: "Public domain")
        #expect(CardBackFormat.creditParts(for: .commons(anon))?.author == nil)
        #expect(CardBackFormat.credit(for: .commons(anon)) == "Public domain · Wikimedia Commons")

        for quiet in [CardBackCloseup.none, .loading] {
            #expect(CardBackFormat.credit(for: quiet) == nil)
            #expect(CardBackFormat.link(for: quiet) == nil)
        }
    }

    @Test func wikipediaBlockShowsOnlyWithSummaryOrLoading() {
        var m = BackFixtures.minimal
        #expect(!CardBackFormat.showsWikipedia(m))
        m.summaryLoading = true
        #expect(CardBackFormat.showsWikipedia(m))
        m.summaryLoading = false
        m.summary = BackFixtures.b738Summary
        #expect(CardBackFormat.showsWikipedia(m))
    }
}

// MARK: - Visual pass

#if DEBUG
@MainActor
@Suite("Card back snapshots (visual pass)", .serialized)
struct CardBackSnapshotTests {

    private static let snapDir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)
    private static let canvas = CGRect(x: 0, y: 0, width: 393, height: 852)
    private static let cardWidth: CGFloat = 353

    /// A drawn stand-in for a remote photo: sky gradient + plane silhouette.
    private static let testPhoto: UIImage = {
        let size = CGSize(width: 800, height: 533)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(red: 0.16, green: 0.36, blue: 0.66, alpha: 1).cgColor,
                          UIColor(red: 0.74, green: 0.86, blue: 0.95, alpha: 1).cgColor]
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: colors as CFArray, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(g, start: .zero,
                                                 end: CGPoint(x: 0, y: size.height), options: [])
            }
            let config = UIImage.SymbolConfiguration(pointSize: 220, weight: .regular)
            if let plane = UIImage(systemName: "airplane", withConfiguration: config)?
                .withTintColor(UIColor(white: 0.1, alpha: 0.85), renderingMode: .alwaysOriginal) {
                plane.draw(in: CGRect(x: 260, y: 150, width: plane.size.width, height: plane.size.height))
            }
        }
    }()

    private func render<V: View>(_ view: V, name: String) async throws -> Data {
        try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
        let bounds = Self.canvas
        let host = UIHostingController(rootView:
            view
                .frame(width: bounds.width, height: bounds.height, alignment: .top)
                .background(Brand.Color.bgPrimary)
                .environment(\.replayMaskingDisabled, true))
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        // Two layout passes: FlipCard measures the front before laying out
        // the back.
        try await Task.sleep(for: .milliseconds(600))
        host.view.layoutIfNeeded()
        let png = UIGraphicsImageRenderer(bounds: bounds).pngData { _ in
            host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try png.write(to: Self.snapDir.appendingPathComponent(name))
        window.isHidden = true
        return png
    }

    private func back(_ model: CardBackModel, photo: UIImage?) -> some View {
        CatchCardBack(model: model, width: Self.cardWidth,
                      onOpenURL: { _ in }, onTurnBack: {}, snapshotImage: photo)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 60)
    }

    @Test func backPlanespotters() async throws {
        let png = try await render(back(BackFixtures.b738, photo: Self.testPhoto),
                                   name: "closeup_back_planespotters.png")
        #expect(!png.isEmpty)
    }

    @Test func backCommonsGA() async throws {
        let png = try await render(back(BackFixtures.c172, photo: Self.testPhoto),
                                   name: "closeup_back_commons_ga.png")
        #expect(!png.isEmpty)
    }

    @Test func backMinimal() async throws {
        let png = try await render(back(BackFixtures.minimal, photo: nil),
                                   name: "closeup_back_minimal.png")
        #expect(!png.isEmpty)
    }

    @Test(arguments: [0.0, 45, 90, 135, 180])
    func flipFrame(_ degrees: Double) async throws {
        let plane = CardPlane(
            callsign: "UAL1532", model: "Boeing 737-800", carrier: "United Airlines",
            rarity: .common, type: .narrow,
            altText: "11,250 ft", speedText: "342 mph", distText: "3.1 mi",
            originIcao: "SFO", destIcao: "DEN",
            originName: "San Francisco", destName: "Denver",
            isFirstOfType: true, icao24: "a4f2c1")
        let card = FlipCard(isFlipped: .constant(false)) {
            SettledCatchCard(plane: plane, isFirstOfType: true, width: Self.cardWidth,
                             onTurnOver: {})
        } back: {
            CatchCardBack(model: BackFixtures.b738, width: Self.cardWidth,
                          onOpenURL: { _ in }, onTurnBack: {}, snapshotImage: Self.testPhoto)
        }
        ._snapshotAngle(degrees)
        let name = String(format: "closeup_flip_%03d.png", Int(degrees))
        let png = try await render(card.padding(.top, 60), name: name)
        #expect(!png.isEmpty)
    }
}
#endif
