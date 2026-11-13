//
//  CardBackFillMatrixTests.swift
//  TailspotTests
//
//  Visual matrix for the card back's fill (2026-11-13): the back is laid
//  out at the FRONT's height, so whether it fills well depends on the
//  front's content (route or not) against the back's (history, specs,
//  summary length), at each device width. One contact sheet per width
//  lands in /private/tmp/tailspot_snaps/fill_<width>.png: columns are back
//  variants, rows are front variants, every card turned to its back
//  through a real FlipCard. Asserts only "it rendered"; the PNGs are for
//  looking at.
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
@testable import Tailspot

@MainActor
@Suite("Card back fill matrix (visual pass)", .serialized)
struct CardBackFillMatrixTests {

    // Test copy written for the fixtures (not real Wikipedia text).
    static let longIntro = """
    The Example Jet is a twin-engine narrow-body airliner developed in the \
    1990s as a stretched member of an earlier family. It entered service \
    with a launch customer in 1998 and went on to become the most widely \
    flown variant of its line. Operators valued its range and its common \
    type rating with smaller siblings. Later production added split-scimitar \
    winglets and a refreshed cabin. More than four thousand were delivered \
    before the line moved on to a re-engined successor.
    """
    static let page = URL(string: "https://en.m.wikipedia.org/wiki/Example")!

    struct Variant { let name: String; let model: CardBackModel }

    static var backs: [Variant] {
        let photo = BackFixtures.planespotters
        let fullSpecs = BackFixtures.b738Info
        let threeSpecs = TypeInfo(entryId: "x", wikipediaTitle: nil, wikidataId: nil,
                                  firstFlightYear: 1981, numberBuilt: nil,
                                  wingspanMeters: 47.6, lengthMeters: 61.4, photo: nil)
        let oneAirline = TypeHistory(firstCaughtAt: BackFixtures.firstCaught,
                                     airlines: [.init(name: "Delta Air Lines", count: 1)])
        let noAirline = TypeHistory(firstCaughtAt: BackFixtures.firstCaught, airlines: [])
        func m(_ name: String, _ info: TypeInfo?, _ h: TypeHistory?,
               _ s: WikipediaSummary?, loading: Bool = false) -> CardBackModel {
            CardBackModel(modelName: name, registration: "N832MH", rarity: .common,
                          closeup: .planespotters(photo), typeInfo: info, history: h,
                          summary: s, summaryLoading: loading)
        }
        return [
            Variant(name: "long intro, 1 airline",
                    model: m("Boeing 737-800", fullSpecs, oneAirline,
                             WikipediaSummary(extract: "Short.", intro: longIntro, pageURL: page))),
            Variant(name: "one-sentence, no intro",
                    model: m("Boeing 767-400", threeSpecs, oneAirline,
                             WikipediaSummary(extract: "The Boeing 767 is an American wide-body airliner developed and manufactured by Boeing Commercial Airplanes.",
                                              pageURL: page))),
            Variant(name: "heavy: log +more, long name",
                    model: m("Bombardier CRJ900LR Regional Jet Long Range", fullSpecs,
                             BackFixtures.b738History,
                             WikipediaSummary(extract: "Short.", intro: longIntro, pageURL: page))),
            Variant(name: "GA: no airlines",
                    model: m("Piper PA-28 Cherokee", threeSpecs, noAirline,
                             WikipediaSummary(extract: "Short.", intro: longIntro, pageURL: page))),
            Variant(name: "loading summary",
                    model: m("Airbus A321neo", fullSpecs, oneAirline, nil, loading: true)),
            Variant(name: "no summary",
                    model: m("Unknown aircraft", nil, oneAirline, nil)),
        ]
    }

    static func front(route: Bool) -> CardPlane {
        CardPlane(
            callsign: "DAL1532", model: "Boeing 767-400", carrier: "Delta Air Lines",
            rarity: .common, type: .wide,
            altText: "11,250 ft", speedText: "342 mph", distText: "3.1 mi",
            originIcao: route ? "SFO" : nil, destIcao: route ? "ATL" : nil,
            originName: route ? "San Francisco" : nil, destName: route ? "Atlanta" : nil,
            isFirstOfType: route, icao24: "a4f2c1")
    }

    /// Card widths as CatchDetailView computes them: min(screen − 36, 420).
    /// iPhone SE/13 mini (375), 17 / 16 (393), 17 Pro Max (440).
    @Test(arguments: [339.0, 357, 404])
    func fillSheet(_ width: Double) async throws {
        let w = CGFloat(width)
        let backs = Self.backs
        let sheet = VStack(alignment: .leading, spacing: 30) {
            ForEach([true, false], id: \.self) { route in
                HStack(alignment: .top, spacing: 24) {
                    ForEach(backs.indices, id: \.self) { i in
                        VStack(spacing: 6) {
                            Text("\(backs[i].name) · \(route ? "route" : "no route")")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white)
                            FlipCard(isFlipped: .constant(true)) {
                                SettledCatchCard(plane: Self.front(route: route),
                                                 isFirstOfType: route, width: w)
                            } back: {
                                CatchCardBack(model: backs[i].model, width: w,
                                              onOpenURL: { _ in },
                                              snapshotImage: Self.photo)
                            }
                            ._snapshotAngle(180)
                            .frame(width: w)
                        }
                    }
                }
            }
        }
        .padding(24)

        let canvas = CGRect(x: 0, y: 0,
                            width: CGFloat(backs.count) * (w + 24) + 48,
                            height: 2 * (w * 2.3 + 80) + 60)
        let dir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let host = UIHostingController(rootView:
            sheet.frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
                .background(Brand.Color.bgPrimary)
                .environment(\.replayMaskingDisabled, true))
        let window = UIWindow(frame: canvas)
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(800))
        host.view.layoutIfNeeded()
        let png = UIGraphicsImageRenderer(bounds: canvas).pngData { _ in
            host.view.drawHierarchy(in: canvas, afterScreenUpdates: true)
        }
        try png.write(to: dir.appendingPathComponent("fill_\(Int(width)).png"))
        window.isHidden = true
        #expect(!png.isEmpty)
    }

    static let photo: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 533)).image { ctx in
        UIColor(red: 0.45, green: 0.62, blue: 0.82, alpha: 1).setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 533))
    }
}
#endif
