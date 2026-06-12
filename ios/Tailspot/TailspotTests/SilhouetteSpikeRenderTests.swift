//
//  SilhouetteSpikeRenderTests.swift
//  TailspotTests
//
//  STAGE-2b CARD-STYLE SPIKE render harness (feat/card-style-spike).
//
//  Not a behavioral test — a render driver. It stamps the spike card
//  variants and the raw silhouettes to PNGs under /tmp/card-spike/ via
//  ImageRenderer (MainActor, scale 3, the same path PublicScreens uses
//  for its share card), then writes the contact-sheet index.html. Noah
//  opens the HTML in a browser to pick a style direction.
//
//  The `#expect`s only assert the PNGs were written (non-empty), so the
//  suite stays green; the real output is the images themselves, which
//  the authoring agent reads back and judges.
//

import Testing
import SwiftUI
import UIKit
@testable import Tailspot

@MainActor
@Suite("SilhouetteSpikeRender")
struct SilhouetteSpikeRenderTests {

    private static let outDir = URL(fileURLWithPath: "/tmp/card-spike", isDirectory: true)

    // Sample plane values per kind. callsign/model/carrier are plausible
    // so the card chrome reads realistically; rarity per the brief.
    private func plane(for kind: SilhouetteKind, rarity: Rarity) -> CardPlane {
        switch kind {
        case .a320:
            return CardPlane(callsign: "UAL1234", model: "Airbus A320", carrier: "United Airlines",
                             rarity: rarity, type: .narrow,
                             altText: "FL360", speedText: "451 kt", distText: "8.2 km")
        case .b747:
            return CardPlane(callsign: "BOX452", model: "Boeing 747-400F", carrier: "Cargolux",
                             rarity: rarity, type: .wide,
                             altText: "FL340", speedText: "488 kt", distText: "14.5 km")
        case .citation:
            return CardPlane(callsign: "N680QS", model: "Cessna Citation Latitude", carrier: "NetJets",
                             rarity: rarity, type: .biz,
                             altText: "FL410", speedText: "402 kt", distText: "6.1 km")
        case .c172:
            return CardPlane(callsign: "N51782", model: "Cessna 172 Skyhawk", carrier: nil,
                             rarity: rarity, type: .ga,
                             altText: "3,500 ft", speedText: "108 kt", distText: "2.3 km")
        case .heli:
            return CardPlane(callsign: "N206BH", model: "Bell 206 JetRanger", carrier: nil,
                             rarity: rarity, type: .ga,
                             altText: "1,200 ft", speedText: "118 kt", distText: "3.4 km")
        }
    }

    /// Render any SwiftUI view to a PNG at scale 3 and write it to outDir.
    @discardableResult
    private func render<V: View>(_ view: V, to name: String) -> Bool {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        guard let ui = renderer.uiImage, let png = ui.pngData() else { return false }
        let url = Self.outDir.appendingPathComponent(name)
        do {
            try png.write(to: url)
            return !png.isEmpty
        } catch {
            return false
        }
    }

    /// The direction judged strongest across the full range. The contact
    /// sheet's "range row" uses this. (Authoring agent: update after
    /// reading the PNGs.)
    static let rangeStyle: SilhouetteStyle = .solidFlat

    @Test func renderSpikeSheet() throws {
        try FileManager.default.createDirectory(at: Self.outDir, withIntermediateDirectories: true)

        var written: [String] = []

        // 1. A320, all three directions, full md card, rarity common.
        for style in SilhouetteStyle.allCases {
            let suffix: String
            switch style {
            case .blueprint: suffix = "A"
            case .solidFlat: suffix = "B"
            case .duotone:   suffix = "C"
            }
            let livery: LiveryAccent? = (style == .duotone) ? .united : nil
            let card = SilhouetteSpikeCard(
                plane: plane(for: .a320, rarity: .common),
                kind: .a320, style: style, livery: livery, size: .md
            )
            .padding(20)
            .background(Brand.Color.bgPrimary)
            let name = "a320-\(suffix).png"
            #expect(render(card, to: name), "failed to render \(name)")
            written.append(name)
        }

        // 2. The range row in the chosen direction.
        let rangeStyle = Self.rangeStyle
        let rangeStyleSuffix: String = {
            switch rangeStyle {
            case .blueprint: return "A"
            case .solidFlat: return "B"
            case .duotone:   return "C"
            }
        }()
        let rangeSpecs: [(SilhouetteKind, Rarity, String)] = [
            (.b747, .rare, "b747"),
            (.citation, .uncommon, "citation"),
            (.c172, .common, "c172"),
            (.heli, .uncommon, "heli"),
        ]
        for (kind, rarity, base) in rangeSpecs {
            let card = SilhouetteSpikeCard(
                plane: plane(for: kind, rarity: rarity),
                kind: kind, style: rangeStyle, size: .md
            )
            .padding(20)
            .background(Brand.Color.bgPrimary)
            let name = "\(base)-\(rangeStyleSuffix).png"
            #expect(render(card, to: name), "failed to render \(name)")
            written.append(name)
        }

        // 3. Raw silhouette checks — large, plain ground.
        for kind in SilhouetteKind.allCases {
            let card = SilhouetteCheckCard(kind: kind)
                .padding(20)
                .background(Brand.Color.bgPrimary)
            let name = "silhouette-check-\(kind.rawValue).png"
            #expect(render(card, to: name), "failed to render \(name)")
            written.append(name)
        }

        // 4. Write the contact sheet.
        try writeIndexHTML(rangeStyle: rangeStyle, rangeStyleSuffix: rangeStyleSuffix, rangeSpecs: rangeSpecs)

        #expect(written.count == 12)
    }

    // MARK: - Contact sheet

    private func writeIndexHTML(
        rangeStyle: SilhouetteStyle,
        rangeStyleSuffix: String,
        rangeSpecs: [(SilhouetteKind, Rarity, String)]
    ) throws {
        func styleCard(suffix: String, style: SilhouetteStyle) -> String {
            """
            <figure class="card">
              <img src="a320-\(suffix).png" alt="A320 \(style.shortName)">
              <figcaption><b>\(style.shortName)</b><br><span>\(style.oneLiner)</span></figcaption>
            </figure>
            """
        }

        let topRow = SilhouetteStyle.allCases.map { style -> String in
            let suffix: String
            switch style {
            case .blueprint: suffix = "A"
            case .solidFlat: suffix = "B"
            case .duotone:   suffix = "C"
            }
            return styleCard(suffix: suffix, style: style)
        }.joined(separator: "\n")

        let rangeRow = rangeSpecs.map { (kind, rarity, base) -> String in
            """
            <figure class="card">
              <img src="\(base)-\(rangeStyleSuffix).png" alt="\(kind.label)">
              <figcaption><b>\(kind.label)</b><br><span>rarity: \(rarity.rawValue)</span></figcaption>
            </figure>
            """
        }.joined(separator: "\n")

        let silRow = SilhouetteKind.allCases.map { kind -> String in
            """
            <figure class="card">
              <img src="silhouette-check-\(kind.rawValue).png" alt="\(kind.label)">
              <figcaption><b>\(kind.label)</b></figcaption>
            </figure>
            """
        }.joined(separator: "\n")

        let html = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Tailspot card style spike — pick a direction</title>
          <style>
            :root { color-scheme: dark; }
            body {
              margin: 0; padding: 32px 24px 64px;
              background: #0A0E1A; color: #E8F4FF;
              font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            }
            h1 { font-size: 22px; margin: 0 0 4px; letter-spacing: 0.3px; }
            h2 { font-size: 15px; font-weight: 600; color: #A0B0C0;
                 text-transform: uppercase; letter-spacing: 1.2px;
                 margin: 40px 0 16px; border-bottom: 1px solid #1A2030; padding-bottom: 8px; }
            .sub { color: #7F8B98; margin: 0 0 8px; }
            .row { display: flex; flex-wrap: wrap; gap: 24px; align-items: flex-start; }
            figure.card { margin: 0; width: 280px; }
            figure.card img { width: 100%; height: auto; display: block;
              border-radius: 10px; }
            figcaption { margin-top: 10px; font-size: 13px; }
            figcaption b { color: #00D4FF; }
            figcaption span { color: #A0B0C0; font-size: 12px; }
            .note { color: #7F8B98; font-size: 13px; max-width: 70ch; margin: 6px 0 0; }
          </style>
        </head>
        <body>
          <h1>Tailspot card style spike — pick a direction</h1>
          <p class="sub">Stage 2b. Same A320 (common) rendered three ways. Pick one; Stage 2c builds it out.</p>

          <h2>Three directions — A320</h2>
          <div class="row">
            \(topRow)
          </div>

          <h2>Range — \(rangeStyle.shortName) across the visual span</h2>
          <p class="note">The direction judged strongest across narrowbody → jumbo → bizjet → GA → helicopter, applied uniformly so the range reads as one system.</p>
          <div class="row">
            \(rangeRow)
          </div>

          <h2>Raw silhouettes (proportion check)</h2>
          <p class="note">Solid fill on a plain ground — shape problems can't hide behind line-work or glow.</p>
          <div class="row">
            \(silRow)
          </div>
        </body>
        </html>
        """

        let url = Self.outDir.appendingPathComponent("index.html")
        try html.write(to: url, atomically: true, encoding: .utf8)
    }
}
