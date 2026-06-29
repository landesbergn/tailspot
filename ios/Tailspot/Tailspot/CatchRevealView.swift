//
//  CatchRevealView.swift
//  Tailspot
//
//  The catch-reveal moment — the agreed Decision-2 design (minimal +
//  split-flap + photo + score ledger). Ported from the `RevealV3`
//  prototype: every beat is a function of a single normalized clock
//  `t` (0 → 1) through `ss()` smoothsteps. The prototype rendered frames
//  by hand for the GIF mockups; here `TimelineView(.animation)` drives
//  `t` live off a start timestamp, so the same interpolation plays as a
//  real ~60fps animation.
//
//  Reveal cadence is tier-scaled: a common plane settles quickly and
//  quietly, a legendary one takes its time with a tinted bloom. The
//  score ledger counts up from the rarity base, adding a FIRST OF TYPE
//  line when this is a new type for the observer. (The 10% route-guess
//  bonus line lands with the guess round — Phase 2's remaining piece.)
//
//  This replaces the v0 holo-flip `CardReveal` for single catches. The
//  multi-catch path still routes through `MultiCatchReveal`.
//

import SwiftUI
import UIKit

// MARK: - Reveal animation math (verbatim from the RevealV3 prototype)

private func revClamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(max(x, lo), hi) }
/// Smoothstep from `a` to `b`, evaluated at `x`. Returns 0 below `a`,
/// 1 above `b`, eased in between — the prototype's per-element timing.
private func ss(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let u = revClamp((x - a) / (b - a))
    return u * u * (3 - 2 * u)
}
private func easeOut(_ x: Double) -> Double { let u = revClamp(x); return 1 - (1 - u) * (1 - u) }

/// Split-flap character pool (no vowel-ambiguous I/O, plus digits + dash).
private let flapPool = Array("ABCDEFGHJKLMNPQRSTUVWXYZ0123456789-")

/// Reveal-local palette — the near-black card ground and the neutral
/// ink/rule tones from the prototype. Tier accent comes from
/// `Rarity.color` so the reveal matches Hangar/badge tiering.
private enum RP {
    static let bg = Color(hex: 0x08090C)
    static let ink = Color(hex: 0xE7EEF5)
    static let muted = Color(hex: 0x8DA0B2)
    static let faint = Color(hex: 0x5F7284)
    static let rule = Color(hex: 0x232C38)
    static let gold = Color(hex: 0xFBBF24)
    static let flapFace = Color(hex: 0x131720)
    static let flapUnsettled = Color(hex: 0x6B7886)
}

// MARK: - Split-flap row

private struct FlapRow: View {
    let text: String
    let t: Double
    let startT: Double
    let spanT: Double
    let fs: CGFloat
    let cw: CGFloat
    let color: Color

    var body: some View {
        let chars = Array(text)
        let n = max(1, chars.count - 1)
        HStack(spacing: 2.5) {
            ForEach(Array(chars.enumerated()), id: \.offset) { i, ch in
                let isSettled = t >= startT + (Double(i) / Double(n)) * spanT
                let shown: Character = ch == " "
                    ? " "
                    : (isSettled ? ch : flapPool[abs(Int(t * 42) + i * 5) % flapPool.count])
                ZStack {
                    RoundedRectangle(cornerRadius: 3).fill(RP.flapFace)
                    RoundedRectangle(cornerRadius: 3).stroke(RP.rule, lineWidth: 1)
                    Rectangle().fill(.black.opacity(0.45)).frame(height: 1)
                    Text(String(shown))
                        .font(.system(size: fs, weight: .bold, design: .monospaced))
                        .foregroundColor(isSettled ? color : RP.flapUnsettled)
                }
                .frame(width: ch == " " ? cw * 0.45 : cw, height: fs * 1.5)
                .opacity(ch == " " ? 0 : 1)
            }
        }
    }
}

// MARK: - Photo hero (real catch photo, else the sky placeholder)

private struct RevealPhoto: View {
    let url: URL?

    var body: some View {
        if let image = url.flatMap({ UIImage(contentsOfFile: $0.path) }) {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            SkyPlaceholder()
        }
    }
}

/// The prototype's stylized sky — a banking silhouette over a gradient.
/// Stands in until a real catch photo exists (and for fabricated catches).
private struct SkyPlaceholder: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x163A6B), Color(hex: 0x4F86C4), Color(hex: 0xBCDCF2)],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(
                colors: [Color(hex: 0xFFF3D6, alpha: 0.85), .clear],
                center: UnitPoint(x: 0.8, y: 0.2), startRadius: 1, endRadius: 120
            )
            Ellipse().fill(.white.opacity(0.45)).frame(width: 110, height: 26).offset(x: -78, y: 44)
            Ellipse().fill(.white.opacity(0.30)).frame(width: 150, height: 30).offset(x: 56, y: 56)
            Capsule()
                .fill(LinearGradient(colors: [.white.opacity(0), .white.opacity(0.6)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 96, height: 3).rotationEffect(.degrees(-16)).offset(x: -26, y: -16)
            Image(systemName: "airplane")
                .font(.system(size: 28))
                .foregroundColor(.black.opacity(0.72))
                .rotationEffect(.degrees(22)).offset(x: 28, y: -14)
            LinearGradient(colors: [.clear, .black.opacity(0.18)], startPoint: .center, endPoint: .bottom)
        }
    }
}

// MARK: - Data + ledger cells

private func dataCell(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(label).font(.system(size: 8.5, design: .monospaced)).tracking(1).foregroundColor(RP.faint)
        Text(value).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundColor(RP.ink)
    }
}

private func ledgerRow(_ label: String, _ amount: String, _ color: Color, _ opacity: Double, big: Bool = false) -> some View {
    HStack {
        Text(label)
            .font(.system(size: big ? 12 : 11, weight: big ? .heavy : .regular, design: .monospaced))
            .tracking(big ? 1.5 : 0)
            .foregroundColor(big ? RP.ink : RP.muted)
        Spacer()
        Text(amount)
            .font(.system(size: big ? 24 : 13, weight: big ? .bold : .semibold, design: .monospaced))
            .foregroundColor(color)
    }
    .opacity(opacity)
}

// MARK: - CatchRevealView

struct CatchRevealView: View {
    let plane: CardPlane
    /// "ENTRY #N" — caller passes the count of unique icao24 after the catch.
    let entryNumber: Int
    let onDismiss: () -> Void
    let onViewInHangar: () -> Void
    var isDuplicate: Bool = false

    /// Animation clock anchor. nil until `onAppear`; `t` is 0 until set.
    @State private var start: Date?
    /// Flips true once the reveal has played out (or the user taps to skip),
    /// gating the dismiss CTAs and the success haptic.
    @State private var settled = false

    /// Tier-scaled wall-clock for the whole reveal.
    private var duration: Double {
        switch plane.rarity {
        case .common:    return 1.7
        case .uncommon:  return 1.9
        case .rare:      return 2.2
        case .epic:      return 2.6
        case .legendary: return 3.2
        }
    }

    private var base: Int { plane.rarity.basePoints }
    private var firstOfTypeBonus: Int {
        plane.isFirstOfType && !isDuplicate ? Int((Double(base) * 0.5).rounded()) : 0
    }
    private var finalTotal: Int { isDuplicate ? 0 : base + firstOfTypeBonus }

    var body: some View {
        GeometryReader { geo in
            let width = min(geo.size.width - 36, 360)
            ZStack {
                RP.bg.ignoresSafeArea()

                TimelineView(.animation) { context in
                    let t = start.map { revClamp(context.date.timeIntervalSince($0) / duration) } ?? 0
                    card(t: t, width: width)
                        .frame(maxHeight: .infinity)
                }

                // Dismiss affordances — only once the reveal has settled.
                VStack {
                    Spacer()
                    ctaRow.opacity(settled ? 1 : 0)
                }
                .padding(.bottom, 44)
                .allowsHitTesting(settled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                if settled {
                    onDismiss()
                } else {
                    // Skip the animation to its final frame.
                    start = Date().addingTimeInterval(-duration)
                    withAnimation(.easeOut(duration: 0.25)) { settled = true }
                }
            }
            .onAppear { start = Date() }
            .task {
                try? await Task.sleep(for: .seconds(duration))
                withAnimation(.easeOut(duration: 0.3)) { settled = true }
            }
            .sensoryFeedback(.success, trigger: settled)
        }
    }

    // The card itself, fully parameterized by the reveal clock `t`.
    private func card(t: Double, width: CGFloat) -> some View {
        let accent = plane.rarity.tint
        let line = ss(0.5, 0.7, t)
        let total = Int((Double(finalTotal) * easeOut(ss(0.82, 0.96, t))).rounded())

        // Split-flap sizing: shrink the cells to fit the model on one line.
        let model = (plane.model ?? "UNKNOWN AIRCRAFT").uppercased()
        let chars = Array(model)
        let weighted = chars.reduce(0.0) { $0 + ($1 == " " ? 0.45 : 1.0) }
        let spacingTotal = 2.5 * Double(max(0, chars.count - 1))
        let avail = Double(width) - 44   // 22pt horizontal padding each side
        let cw = min(17.5, max(8.0, (avail - spacingTotal) / max(weighted, 1)))
        let fs = min(15, cw * 0.86)

        let routeOrDist = plane.routeText ?? plane.distText
        let routeLabel = plane.routeText != nil ? "ROUTE" : "DIST"

        return ZStack {
            // Tier bloom behind the card — modest for rare, cinematic for legendary.
            if plane.rarity.ordinal >= Rarity.epic.ordinal {
                RadialGradient(colors: [accent.opacity(0.22), .clear],
                               center: .center, startRadius: 1, endRadius: Double(width) * 0.9)
                    .opacity(ss(0.0, 0.4, t) * (plane.rarity == .legendary ? 1.0 : 0.6))
                    .blur(radius: 8)
            }

            VStack(alignment: .leading, spacing: 0) {
                RevealPhoto(url: plane.photoURL)
                    .frame(height: 168)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(accent.opacity(plane.rarity.ordinal >= Rarity.rare.ordinal ? 0.35 : 0.18), lineWidth: 1)
                    )
                    .opacity(ss(0.0, 0.18, t))
                    .padding(16)

                VStack(alignment: .leading, spacing: 7) {
                    FlapRow(text: model, t: t, startT: 0.24, spanT: 0.36, fs: fs, cw: cw, color: RP.ink)

                    HStack(spacing: 7) {
                        Circle().fill(accent).frame(width: 6, height: 6)
                        Text(plane.rarity.label.uppercased())
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(3).foregroundColor(accent)
                        if isDuplicate {
                            Text("· ALREADY CAUGHT")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .tracking(1).foregroundColor(Color(hex: 0xE0556B))
                        }
                    }
                    .opacity(ss(0.56, 0.7, t))

                    Rectangle().fill(RP.rule).frame(width: (Double(width) - 44) * line, height: 1).padding(.vertical, 2)

                    HStack(spacing: 16) {
                        dataCell("ALT", plane.altText ?? "—")
                        dataCell("SPD", plane.speedText ?? "—")
                        dataCell(routeLabel, routeOrDist ?? "—")
                    }
                    .opacity(ss(0.6, 0.78, t))

                    VStack(spacing: 6) {
                        Rectangle().fill(RP.rule).frame(height: 1).padding(.top, 6)
                        if isDuplicate {
                            ledgerRow("ALREADY IN HANGAR", "", RP.muted, ss(0.78, 0.86, t))
                        } else {
                            ledgerRow(plane.rarity.label.uppercased(), "+\(base)", RP.muted, ss(0.78, 0.86, t))
                            if firstOfTypeBonus > 0 {
                                ledgerRow("FIRST OF TYPE", "+\(firstOfTypeBonus)", RP.gold, ss(0.82, 0.9, t))
                            }
                        }
                        Rectangle().fill(RP.rule).frame(height: 1)
                        ledgerRow("TOTAL", "+\(total)", accent, ss(0.84, 0.92, t), big: true)
                    }

                    HStack {
                        Spacer()
                        Text("ENTRY #\(entryNumber)")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(1.5).foregroundColor(RP.faint)
                    }
                    .opacity(ss(0.9, 1.0, t))
                    .padding(.top, 4)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 20)
            }
            .background(RP.bg)
            .frame(width: width)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(RP.rule, lineWidth: 1))
        }
    }

    private var ctaRow: some View {
        HStack(spacing: 18) {
            Text("tap to continue")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1.2).foregroundColor(RP.faint)
            Button(action: onViewInHangar) {
                Text("View in Hangar ›")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(0.5).foregroundColor(plane.rarity.tint)
            }
            .buttonStyle(.plain)
        }
    }
}
