//
//  TrophyBadge.swift
//  Tailspot
//
//  The one badge drawing used everywhere a trophy appears (Trophies tab,
//  detail, share card, unlock moment, recap): ONE monoline SF Symbol inside
//  a segmented ring. Art direction "C" of the 2026-11 trophies rebuild.
//
//    • A track level has N rim segments (the track's real level count,
//      2-5); `filled` of them are cyan, the rest dim.
//    • A feat is one continuous ring: cyan when earned, dim when locked.
//    • Locked / unearned badges draw a dim symbol on the deepest surface;
//      a locked secret shows a question mark instead of its symbol.
//
//  It is drawn with a single Canvas (no blur, shadow or offscreen pass)
//  because it repeats dozens of times in a scrolling list. Call sites own
//  the accessibility label, so the badge hides itself from VoiceOver.
//

import SwiftUI

/// What a badge draws, separated from the view so ordering/derivation is
/// unit-testable. Pure value type.
nonisolated struct TrophyBadgeSpec: Equatable, Sendable {
    let symbol: String
    /// Rim segments: a track's level count, or 1 for a feat's single ring.
    let segments: Int
    let filled: Int
    /// Styled as earned (cyan ring + bright symbol).
    let earned: Bool
    /// Secret + locked: draw the question mark, not the symbol.
    let masked: Bool

    /// A track as it stands: `level` of `levelCount` segments filled.
    init(state: TrophyTrackState) {
        symbol = state.track.symbol
        segments = max(1, state.levelCount)
        filled = state.level
        earned = state.level > 0
        masked = false
    }

    /// A feat, earned or not. A secret that is still locked is masked.
    init(feat: Achievement, earned: Bool) {
        symbol = TrophyTracks.featSymbol(for: feat.id)
        segments = 1
        filled = earned ? 1 : 0
        self.earned = earned
        masked = feat.secret && !earned
    }

    /// An achievement the player has just earned (unlock card, recap): a
    /// track level lights its own segments, a feat lights its ring.
    init(earnedAchievement a: Achievement) {
        if let track = TrophyTracks.track(forAchievementID: a.id),
           let level = TrophyTracks.level(ofAchievementID: a.id) {
            self.init(symbol: track.symbol, segments: max(1, track.levelIDs.count),
                      filled: level, earned: true, masked: false)
        } else {
            self.init(feat: a, earned: true)
        }
    }

    /// The badge for any achievement given the player's progress. A track
    /// level shows the track's ring: lit up to the level this achievement
    /// is when earned, otherwise up to the level the player holds.
    init(achievement a: Achievement, inputs: TrophyProgressInputs, roster: [Achievement] = Trophies.roster) {
        if let track = TrophyTracks.track(forAchievementID: a.id),
           let state = TrophyTrackState.make(track: track, inputs: inputs, roster: roster) {
            var spec = TrophyBadgeSpec(state: state)
            if a.isEarned(inputs: inputs), let level = TrophyTracks.level(ofAchievementID: a.id) {
                spec = TrophyBadgeSpec(symbol: spec.symbol, segments: spec.segments,
                                       filled: max(level, spec.filled), earned: true, masked: false)
            }
            self = spec
        } else {
            self.init(feat: a, earned: a.isEarned(inputs: inputs))
        }
    }

    init(symbol: String, segments: Int, filled: Int, earned: Bool, masked: Bool) {
        self.symbol = symbol
        self.segments = segments
        self.filled = filled
        self.earned = earned
        self.masked = masked
    }
}

struct TrophyBadge: View {
    let symbol: String
    var segments: Int = 1
    var filled: Int = 0
    var earned: Bool = false
    var masked: Bool = false
    var size: CGFloat = 56

    init(symbol: String, segments: Int = 1, filled: Int = 0,
         earned: Bool = false, masked: Bool = false, size: CGFloat = 56) {
        self.symbol = symbol
        self.segments = segments
        self.filled = filled
        self.earned = earned
        self.masked = masked
        self.size = size
    }

    init(_ spec: TrophyBadgeSpec, size: CGFloat = 56) {
        self.init(symbol: spec.symbol, segments: spec.segments, filled: spec.filled,
                  earned: spec.earned, masked: spec.masked, size: size)
    }

    var body: some View {
        // Fixed-size artwork: it scales with its caller's `size`, not with
        // Dynamic Type (like the other artboard glyphs).
        ZStack {
            Canvas { ctx, canvasSize in
                drawRing(in: &ctx, size: canvasSize)
            }
            Image(systemName: masked ? "questionmark" : symbol)
                .font(.system(size: size * 0.36, weight: .regular))
                .foregroundStyle(earned ? Brand.Color.textPrimary : Brand.Color.textTertiary)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func drawRing(in ctx: inout GraphicsContext, size canvas: CGSize) {
        let rect = CGRect(origin: .zero, size: canvas)
        ctx.fill(Path(ellipseIn: rect),
                 with: .color(earned ? Brand.Color.bgElevated : Brand.Color.bgSurface))
        let line = max(2, size * 0.055)
        let ringRect = rect.insetBy(dx: size * 0.03 + line / 2, dy: size * 0.03 + line / 2)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = ringRect.width / 2
        let count = max(1, segments)
        let lit = Brand.Color.cyan
        let dim = Brand.Color.textTertiary.opacity(0.5)
        let style = StrokeStyle(lineWidth: line, lineCap: .round)
        if count == 1 {
            ctx.stroke(Path(ellipseIn: ringRect), with: .color(filled > 0 ? lit : dim), style: style)
            return
        }
        // A small gap between segments; round caps eat a little of it, so
        // the angular gap is widened by the cap radius.
        let gap = Double(line) / Double(radius) + 0.12
        let slice = 2 * Double.pi / Double(count)
        for i in 0..<count {
            let start = -Double.pi / 2 + slice * Double(i) + gap / 2
            let end = -Double.pi / 2 + slice * Double(i + 1) - gap / 2
            var arc = Path()
            arc.addArc(center: center, radius: radius,
                       startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
            ctx.stroke(arc, with: .color(i < filled ? lit : dim), style: style)
        }
    }
}

#Preview("Badges") {
    HStack(spacing: 16) {
        TrophyBadge(symbol: "airplane", segments: 3, filled: 2, earned: true, size: 64)
        TrophyBadge(symbol: "ticket", segments: 4, filled: 0, size: 64)
        TrophyBadge(symbol: "crown", filled: 1, earned: true, size: 64)
        TrophyBadge(symbol: "crown", masked: true, size: 64)
    }
    .padding()
    .background(Brand.Color.bgPrimary)
}
