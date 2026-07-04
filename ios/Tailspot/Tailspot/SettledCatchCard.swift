//
//  SettledCatchCard.swift
//  Tailspot
//
//  The reveal card AT REST — Direction B ("the settled reveal", Noah's pick
//  2026-07-05): whatever the catch moment showed is exactly what the Hangar
//  detail screen frames later. Same photo hero, split-flap name (settled,
//  never animating), tier line, ALT/SPD + full-width ROUTE data section,
//  and the score ledger — built from the SAME atoms the reveal animates
//  (RP palette, FlapRow at t=1, statCell/ledgerRow, RevealPhoto), so the
//  two screens cannot drift apart in vocabulary.
//
//  Differences from the animated reveal, all deliberate:
//   - No entry number (the historical entry position isn't stored).
//   - No duplicate branch (the Hangar shows one row per airframe).
//   - The ledger re-derives points from the CURRENT scoring table (same
//     philosophy as `Catch.resolvedRarity` — re-tiering corrects old
//     catches on read); FIRST OF TYPE is the historical fact passed in.
//

import SwiftUI

struct SettledCatchCard: View {
    let plane: CardPlane
    /// Whether THIS catch was the first of its typecode when caught —
    /// computed historically by the caller (earliest caughtAt wins).
    let isFirstOfType: Bool
    /// Card width in points; every internal metric scales off it exactly
    /// like the reveal (the prototype's sizes were tuned for 300 pt).
    let width: CGFloat

    private var base: Int { plane.rarity.basePoints }
    private var bonus: Int { isFirstOfType ? Int((Double(base) * 0.5).rounded()) : 0 }

    var body: some View {
        let accent = plane.rarity.tint
        let scale = width / 300
        let hPad = 22 * scale
        let avail = Double(width - 2 * hPad)

        // Split-flap sizing — identical math to the reveal, settled at t=1.
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

        return VStack(alignment: .leading, spacing: 0) {
            RevealPhoto(url: plane.photoURL)
                .frame(height: 168 * scale)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(accent.opacity(plane.rarity.ordinal >= Rarity.rare.ordinal ? 0.35 : 0.18), lineWidth: 1)
                )
                .padding(18 * scale)

            VStack(alignment: .leading, spacing: 11 * scale) {
                VStack(alignment: .leading, spacing: 4 * scale) {
                    ForEach(flapLines) { fl in
                        // t=1 / spanT=0 → every cell settled; the flap frame
                        // stays (that's the vocabulary), the motion doesn't.
                        FlapRow(text: fl.text, t: 1, startT: 0, spanT: 0,
                                fs: fs, cw: cw, gap: flapGap,
                                indexOffset: fl.id, totalCount: totalFlapChars, color: RP.ink)
                    }
                }

                HStack(spacing: 7 * scale) {
                    Circle().fill(accent).frame(width: 6 * scale, height: 6 * scale)
                    Text(plane.rarity.label.uppercased())
                        .font(.system(size: 11 * scale, weight: .semibold, design: .monospaced))
                        .tracking(3).foregroundColor(accent)
                    if let carrier = plane.carrier?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !carrier.isEmpty {
                        Text("· \(carrier.uppercased())")
                            .font(.system(size: 10 * scale, weight: .semibold, design: .monospaced))
                            .tracking(1).foregroundColor(RP.muted)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }

                Rectangle().fill(RP.rule).frame(height: 1)

                dataSection(scale: scale, accent: accent)

                VStack(spacing: 8 * scale) {
                    Rectangle().fill(RP.rule).frame(height: 1).padding(.top, 4 * scale)
                    ledgerRow(plane.rarity.label.uppercased(), "+\(base)", RP.muted, 1, scale: scale)
                    if bonus > 0 {
                        ledgerRow("FIRST OF TYPE", "+\(bonus)", RP.gold, 1, scale: scale)
                    }
                    Rectangle().fill(RP.rule).frame(height: 1)
                    ledgerRow("EARNED", "+\(base + bonus)", accent, 1, scale: scale, big: true)
                }
            }
            .padding(.horizontal, hPad)
            .padding(.bottom, 22 * scale)
        }
        .background(RP.bg)
        .frame(width: width)
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(RP.rule, lineWidth: 1))
    }

    // ALT / SPD two-column row, then a rule and the full-width ROUTE row
    // (display codes — IATA preferred upstream — tinted arrow, city subline);
    // no route → DIST takes the full-width slot. The reveal's dataSection
    // shape, settled.
    @ViewBuilder
    private func dataSection(scale: CGFloat, accent: Color) -> some View {
        let hasRoute = (plane.originIcao ?? plane.destIcao) != nil
        VStack(alignment: .leading, spacing: 12 * scale) {
            HStack(spacing: 14 * scale) {
                statCell("ALT", plane.altText, scale: scale, accent: accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                statCell("SPD", plane.speedText, scale: scale, accent: accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(RP.rule).frame(height: 1)
            if hasRoute {
                routeCell(scale: scale, accent: accent)
            } else {
                statCell("DIST", plane.distText, scale: scale, accent: accent)
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
