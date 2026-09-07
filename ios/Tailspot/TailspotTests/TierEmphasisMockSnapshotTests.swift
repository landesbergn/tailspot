//
//  TierEmphasisMockSnapshotTests.swift
//  TailspotTests
//
//  MOCK harness (2026-09-06): "how else could the card say RARE?" Noah
//  finds the tier-coloured FONT on the reveal / settled card strange — the
//  unit suffixes (ft / kt / km), the route arrow and the big TOTAL amount
//  all take `rarity.tint`. This renders the settled card with the text
//  neutralised and the tier emphasised by other means, one mechanism per
//  variant, across three tiers, so the options can be compared side by
//  side. Test-target only: it re-composes the card from the SAME shared
//  atoms (RP palette, FlapRow, RevealPhoto, statCell, ledgerRow) so the
//  mocks are pixel-faithful without touching production views. The
//  `current` style renders the real `SettledCatchCard` for the baseline.
//
//  NOT an assertion test — writes PNGs to /private/tmp/tailspot_snaps/tier_mocks
//  and passes. Real catch photos come from `bin/marketing-stage-photos`.
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
import os
@testable import Tailspot

/// One mechanism per case. Every case except `current` neutralises the
/// tinted text (units → muted, arrow → muted, total → ink).
enum TierEmphasis: String, CaseIterable {
    /// The real `SettledCatchCard` — today's design.
    case current
    /// Text neutralised, nothing added — the floor every other variant builds on.
    case neutral
    /// 5 pt tier rail along the card's top edge (the CatchCardView precedent).
    case rail
    /// The tier WORD as a filled capsule in the identity row — dark text on the tint,
    /// TypeBadge's recipe — replacing the dot.
    case pill
    /// Five ordinal pips in the identity row, filled up to the tier.
    case pips
    /// The photo frame and the card border carry the tint; a soft bloom behind.
    case frame
    /// A tier stamp on the photo hero: "RARE · +50" capsule, bottom-left.
    case stamp
    /// A tint wash from the card's top edge down through the hero, plus tinted rules.
    case wash
}

struct MockTierCard: View {
    let plane: CardPlane
    let isFirstOfType: Bool
    let width: CGFloat
    let style: TierEmphasis

    private var base: Int { plane.rarity.basePoints }
    private var bonus: Int { isFirstOfType ? Int((Double(base) * 0.5).rounded()) : 0 }

    var body: some View {
        let tint = plane.rarity.tint
        // Neutral text everywhere except the baseline.
        let textAccent = RP.muted
        let totalColor = RP.ink
        let scale = width / 300
        let hPad = 22 * scale
        let avail = Double(width - 2 * hPad)

        let model = (plane.model ?? "UNKNOWN AIRCRAFT").uppercased()
        let flapGap = 2.5 * scale
        let maxCW = 17.5 * scale
        let minCW = 12.0 * scale
        let perLine = max(6, Int((avail + Double(flapGap)) / Double(minCW + flapGap)))
        let nameLines = model.count <= perLine ? [model] : wrapName(model, perLine: perLine)
        let longestLine = nameLines.map(\.count).max() ?? model.count
        let cwFit = CGFloat((avail - Double(flapGap) * Double(max(0, longestLine - 1))) / Double(max(1, longestLine)))
        let cw = min(maxCW, max(minCW, cwFit))
        let fs = min(15 * scale, cw * 0.86)
        let totalFlapChars = nameLines.reduce(0) { $0 + $1.count }
        let flapLines: [FlapLine] = {
            var acc = 0
            return nameLines.map { line in
                let l = FlapLine(id: acc, text: line); acc += line.count; return l
            }
        }()

        let ruleColor: Color = style == .wash ? tint.opacity(0.45) : RP.rule
        let cardStroke: Color = style == .frame ? tint.opacity(0.55) : RP.rule

        return ZStack {
            if style == .frame {
                RadialGradient(colors: [tint.opacity(0.22), .clear],
                               center: .top, startRadius: 1, endRadius: Double(width) * 0.8)
                    .blur(radius: 8)
            }
            VStack(alignment: .leading, spacing: 0) {
                if style == .rail {
                    Rectangle().fill(tint).frame(height: 5 * scale)
                }
                hero(scale: scale, tint: tint)
                    .padding(18 * scale)
                    .padding(.top, style == .rail ? -4 * scale : 0)

                VStack(alignment: .leading, spacing: 11 * scale) {
                    VStack(alignment: .leading, spacing: 4 * scale) {
                        ForEach(flapLines) { fl in
                            FlapRow(text: fl.text, t: 1, startT: 0, spanT: 0,
                                    fs: fs, cw: cw, gap: flapGap,
                                    indexOffset: fl.id, totalCount: totalFlapChars, color: RP.ink)
                        }
                    }

                    identity(scale: scale, tint: tint)

                    Rectangle().fill(ruleColor).frame(height: 1)

                    VStack(alignment: .leading, spacing: 12 * scale) {
                        HStack(spacing: 14 * scale) {
                            statCell("ALT", plane.altText, scale: scale, accent: textAccent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            statCell("SPD", plane.speedText, scale: scale, accent: textAccent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Rectangle().fill(ruleColor).frame(height: 1)
                        if (plane.originIcao ?? plane.destIcao) != nil {
                            routeCell(scale: scale, accent: textAccent)
                        } else {
                            statCell("DIST", plane.distText, scale: scale, accent: textAccent)
                        }
                    }

                    VStack(spacing: 8 * scale) {
                        Rectangle().fill(ruleColor).frame(height: 1).padding(.top, 4 * scale)
                        ledgerRow(plane.rarity.label.uppercased(), "+\(base)", RP.muted, 1, scale: scale)
                        if bonus > 0 {
                            ledgerRow("FIRST OF TYPE", "+\(bonus)", RP.gold, 1, scale: scale)
                        }
                        Rectangle().fill(ruleColor).frame(height: 1)
                        ledgerRow("EARNED", "+\(base + bonus)", totalColor, 1, scale: scale, big: true)
                    }
                }
                .padding(.horizontal, hPad)
                .padding(.bottom, 22 * scale)
            }
            .background(cardBackground(tint: tint))
            .frame(width: width)
            .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.hero))
            .overlay(RoundedRectangle(cornerRadius: Brand.Radius.hero).stroke(cardStroke, lineWidth: 1))
        }
    }

    @ViewBuilder
    private func cardBackground(tint: Color) -> some View {
        if style == .wash {
            ZStack {
                RP.bg
                LinearGradient(colors: [tint.opacity(0.20), tint.opacity(0.0)],
                               startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.42))
            }
        } else {
            RP.bg
        }
    }

    private func hero(scale: CGFloat, tint: Color) -> some View {
        let strong = style == .frame
        // Today's border: faint tint, a little stronger from rare up. The
        // neutral variants keep it as-is (it's not text); `frame` turns it up.
        let borderOpacity: Double = strong ? 0.95
            : (plane.rarity.ordinal >= Rarity.rare.ordinal ? 0.35 : 0.18)
        let borderColor: Color = style == .neutral ? RP.rule : tint.opacity(borderOpacity)
        return RevealPhoto(url: plane.photoURL, focus: plane.photoFocus)
            .frame(height: 168 * scale)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Brand.Radius.card)
                    .stroke(borderColor, lineWidth: strong ? 1.5 : 1)
            )
            .overlay(alignment: .bottomLeading) {
                if style == .stamp {
                    HStack(spacing: 5 * scale) {
                        Text(plane.rarity.label.uppercased())
                            .tracking(1.2)
                        Text("+\(base)")
                            .opacity(0.8)
                    }
                    .font(.system(size: 10 * scale, weight: .bold, design: .monospaced))
                    .foregroundColor(.black.opacity(0.8))
                    .padding(.horizontal, 9 * scale)
                    .padding(.vertical, 5 * scale)
                    .background(tint, in: Capsule())
                    .overlay(Capsule().stroke(.black.opacity(0.25), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                    .padding(10 * scale)
                }
            }
            .shadow(color: strong ? tint.opacity(0.45) : .clear, radius: 14 * scale)
    }

    private func identity(scale: CGFloat, tint: Color) -> some View {
        let parts = [plane.callsign, plane.carrier]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
        let label = Text(parts.joined(separator: " · "))
            .font(.system(size: 11 * scale, weight: .semibold, design: .monospaced))
            .tracking(1).foregroundColor(RP.ink)
            .lineLimit(1).minimumScaleFactor(0.7)
        return HStack(spacing: 7 * scale) {
            switch style {
            case .pill:
                Text(plane.rarity.label.uppercased())
                    .font(.system(size: 9 * scale, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundColor(.black.opacity(0.8))
                    .padding(.horizontal, 7 * scale)
                    .padding(.vertical, 3 * scale)
                    .background(tint, in: Capsule())
                label
            case .pips:
                HStack(spacing: 2.5 * scale) {
                    ForEach(0..<5, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(i <= plane.rarity.ordinal ? tint : RP.rule)
                            .frame(width: 7 * scale, height: 4 * scale)
                    }
                }
                .padding(.trailing, 2 * scale)
                label
            case .stamp:
                // The stamp on the photo already names the tier — the row is plain.
                label
            default:
                Circle().fill(tint).frame(width: 6 * scale, height: 6 * scale)
                label
            }
        }
    }

    private func routeCell(scale: CGFloat, accent: Color) -> some View {
        let codeFont = Font.system(size: 21 * scale, weight: .semibold, design: .monospaced)
        let arrowFont = Font.system(size: 16 * scale, weight: .semibold, design: .monospaced)
        return VStack(alignment: .leading, spacing: 3 * scale) {
            Text("ROUTE")
                .font(.system(size: 9.5 * scale, weight: .semibold, design: .monospaced))
                .tracking(1.5).foregroundColor(RP.faint)
            HStack(alignment: .firstTextBaseline, spacing: 8 * scale) {
                if let o = plane.originIcao {
                    Text(o).font(codeFont).foregroundColor(RP.ink)
                    if let d = plane.destIcao {
                        Text("→").font(arrowFont).foregroundColor(accent)
                        Text(d).font(codeFont).foregroundColor(RP.ink)
                    }
                } else if let d = plane.destIcao {
                    Text("→").font(arrowFont).foregroundColor(accent)
                    Text(d).font(codeFont).foregroundColor(RP.ink)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.6)
            if plane.originName != nil || plane.destName != nil {
                HStack(spacing: 5 * scale) {
                    if let on = plane.originName {
                        Text(on)
                        if let dn = plane.destName {
                            Text("→").foregroundColor(RP.faint)
                            Text(dn)
                        }
                    } else if let dn = plane.destName {
                        Text("→").foregroundColor(RP.faint)
                        Text(dn)
                    }
                }
                .font(.system(size: 12 * scale))
                .foregroundColor(RP.muted)
                .lineLimit(1).minimumScaleFactor(0.6)
            }
        }
    }
}

@MainActor
@Suite("Tier emphasis mocks (visual pass)")
struct TierEmphasisMockSnapshotTests {

    private static let photoDir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps/marketing/photos", isDirectory: true)

    private func photo(_ name: String) -> URL? {
        let url = Self.photoDir.appendingPathComponent("\(name).jpg")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Missing staged photo \(name).jpg — run bin/marketing-stage-photos")
            return nil
        }
        return url
    }

    @Test func renderTierEmphasisMocks() {
        let dir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps/tier_mocks", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Three tiers: the grey floor, brand cyan (rare IS the brand colour,
        // so "is that tier or chrome?" is sharpest here), and collector gold.
        // Common and rare are real catches with their recorded numbers; the
        // legendary is a stand-in on a real photo (no legendary in the set).
        let planes: [(String, CardPlane, Bool)] = [
            ("common", CardPlane(
                callsign: "DAL405", model: "Boeing 767-300", carrier: "Delta Air Lines",
                rarity: .common, type: .wide,
                altText: "11,975 ft", speedText: "312 kt", distText: "14.2 km",
                photoURL: photo("b767_with_route"), photoFocus: CGPoint(x: 0.512, y: 0.5048),
                originIcao: "SFO", destIcao: "JFK",
                originName: "San Francisco", destName: "New York"), false),
            ("rare", CardPlane(
                callsign: "WWI21", model: "BD-700 Global Express", carrier: "Worldwide Jet Charter",
                rarity: .rare, type: .biz,
                altText: "43,225 ft", speedText: "546 kt", distText: "27.1 km",
                photoURL: photo("bd700_rare"), photoFocus: CGPoint(x: 0.4994, y: 0.499)), true),
            ("legendary", CardPlane(
                callsign: "DOOM11", model: "Boeing B-52 Stratofortress", carrier: "U.S. Air Force",
                rarity: .legendary, type: .mil,
                altText: "40,026 ft", speedText: "488 kt", distText: "31.0 km",
                photoURL: photo("b737"), photoFocus: CGPoint(x: 0.4284, y: 0.5),
                originIcao: "BAD", destIcao: "SFO",
                originName: "Barksdale AFB", destName: "San Francisco"), true),
        ]

        for style in TierEmphasis.allCases {
            for (tier, plane, fot) in planes {
                let card: AnyView = style == .current
                    ? AnyView(SettledCatchCard(plane: plane, isFirstOfType: fot, width: 357))
                    : AnyView(MockTierCard(plane: plane, isFirstOfType: fot, width: 357, style: style))
                let view = card
                    .padding(24)
                    .background(Brand.Color.bgPrimary)
                    .environment(\.colorScheme, .dark)
                    .environment(\.replayMaskingDisabled, true)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 3
                guard let ui = renderer.uiImage, let png = ui.pngData() else {
                    Log.ui.error("Tier mock render failed: \(style.rawValue, privacy: .public) \(tier, privacy: .public)")
                    continue
                }
                try? png.write(to: dir.appendingPathComponent("\(style.rawValue)_\(tier).png"))
            }
        }
        #expect(true)
    }
}
#endif
