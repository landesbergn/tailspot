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
//  line when this is a new type for the observer.
//
//  IN-CARD ROUTE BONUS ROUND (game-layer PR3; in-card redesign per Noah
//  2026-07-10). When the catch is guess-eligible, the reveal still plays
//  its full settle first; THEN the ROUTE panel — which rendered masked as
//  a "Where's it headed?" prompt — hosts four airport chips that pop in on
//  the card. Answering resolves the route in place: the tapped chip flashes,
//  the masked panel crossfades to the real route, and a correct call rolls a
//  "10% ROUTE BONUS" line into the ledger with the TOTAL counting up. This
//  replaced the separate pre-reveal `GuessRoundView` cover — the guess and
//  the reveal are now one fluid surface. ContentView threads the question in
//  via `guess` + resolves through `onGuessResolved`; the eligibility/cadence
//  gate (`GuessRoundPlanner` + `GuessScheduler`) is unchanged.
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
let flapPool = Array("ABCDEFGHJKLMNPQRSTUVWXYZ0123456789-")

/// The reveal's palette — the near-black card ground and the neutral
/// ink/rule tones from the prototype. Tier accent comes from
/// `Rarity.color` so the reveal matches Hangar/badge tiering.
/// INTERNAL (2026-07-05): these tokens — plus FlapRow/wrapName/RevealPhoto/
/// splitUnit/statCell/ledgerRow — are the shared "reveal vocabulary" that
/// `SettledCatchCard` (the Hangar detail screen) renders at rest, so the
/// catch moment and the collection speak one visual language (Direction B).
enum RP {
    static let bg = Color(hex: 0x08090C)
    static let ink = Color(hex: 0xE7EEF5)
    static let muted = Color(hex: 0x8DA0B2)
    static let faint = Color(hex: 0x5F7284)
    static let rule = Color(hex: 0x232C38)
    static let gold = Brand.Color.ledgerGold
    static let flapFace = Color(hex: 0x131720)
    static let flapUnsettled = Color(hex: 0x6B7886)
}

// MARK: - Split-flap row

struct FlapRow: View {
    let text: String
    let t: Double
    let startT: Double
    let spanT: Double
    let fs: CGFloat
    let cw: CGFloat
    var gap: CGFloat = 2.5
    /// Global index of this row's first character, and the total character
    /// count across all wrapped rows — so the split-flap settle flows
    /// continuously across lines instead of restarting on each line.
    var indexOffset: Int = 0
    var totalCount: Int = 0
    /// Reduce Motion: skip the tumbling random characters and fade the
    /// settled text straight in over the same clock window, so the reveal
    /// ends on the identical settled frame.
    var reduceMotion: Bool = false
    let color: Color

    var body: some View {
        let chars = Array(text)
        let total = totalCount > 0 ? totalCount : chars.count
        let n = max(1, total - 1)
        // Reduce-Motion fade progress across the row's settle window (guard
        // spanT == 0 — SettledCatchCard renders the rested frame directly).
        let fade = spanT > 0 ? ss(startT, startT + spanT, t) : 1
        HStack(spacing: gap) {
            ForEach(Array(chars.enumerated()), id: \.offset) { i, ch in
                let isSettled = reduceMotion
                    || t >= startT + (Double(indexOffset + i) / Double(n)) * spanT
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
                        .opacity(reduceMotion ? fade : 1)
                }
                .frame(width: ch == " " ? cw * 0.45 : cw, height: fs * 1.5)
                .opacity(ch == " " ? 0 : 1)
            }
        }
    }
}

/// One wrapped line of the split-flap name. `id` is the global character
/// offset of the line's first character (unique across lines).
struct FlapLine: Identifiable { let id: Int; let text: String }

/// Greedy word-wrap for the split-flap name: break on spaces; hard-break a
/// single word longer than `perLine`. Keeps each line within the budget so
/// cells stay legible (wrap) instead of shrinking to fit everything on one line.
func wrapName(_ s: String, perLine: Int) -> [String] {
    let limit = max(1, perLine)
    var lines: [String] = []
    var cur = ""
    for w in s.split(separator: " ").map(String.init) {
        var word = w
        while word.count > limit {                       // hard-break over-long words
            if !cur.isEmpty { lines.append(cur); cur = "" }
            let idx = word.index(word.startIndex, offsetBy: limit)
            lines.append(String(word[..<idx]))
            word = String(word[idx...])
        }
        if cur.isEmpty {
            cur = word
        } else if cur.count + 1 + word.count <= limit {
            cur += " " + word
        } else {
            lines.append(cur); cur = word
        }
    }
    if !cur.isEmpty { lines.append(cur) }
    return lines.isEmpty ? [s] : lines
}

// MARK: - Photo hero (real catch photo, else the sky placeholder)

struct RevealPhoto: View {
    let url: URL?
    /// Where the plane sits in the photo (normalized 0…1, top-left origin —
    /// `Catch.photoFocus`). Non-nil → the aspect-fill crop centers on the
    /// plane instead of the frame center, clamped so no edge ever shows.
    /// nil (pre-focus catches, Planespotters photos) → plain center fill.
    var focus: CGPoint? = nil

    var body: some View {
        if let image = url.flatMap({ UIImage(contentsOfFile: $0.path) }) {
            // Both paths clip HERE: the fill overflow isn't reliably caught
            // by the caller's clipShape under ImageRenderer (share renders
            // showed the oversize image bleeding past the card).
            if let focus {
                GeometryReader { geo in
                    let layout = FocusFill.layout(
                        imageSize: image.size, frameSize: geo.size, focus: focus
                    )
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: layout.size.width, height: layout.size.height)
                        .offset(x: layout.origin.x, y: layout.origin.y)
                }
                .clipped()
            } else {
                Color.clear
                    .overlay(
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    )
                    .clipped()
            }
        } else if let url, !url.isFileURL {
            // Remote hero (Planespotters thumbnail on catches with no local
            // photo). AsyncImage can't be waited on by ImageRenderer, so
            // share renders show the placeholder — same as the old share
            // card, which also skipped remote photos.
            AsyncImage(url: url) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                SkyPlaceholder()
            }
        } else {
            SkyPlaceholder()
        }
    }
}

/// Pure aspect-fill-around-a-focus-point math: scale the image to cover
/// `frameSize` (identical scale to `.fill`), then slide it so `focus` lands
/// as close to the frame center as the image edges allow. `origin` is the
/// image's top-left offset within the frame (always ≤ 0 on the overflowing
/// axis). `nonisolated` — pure geometry, unit-tested without a view tree.
nonisolated enum FocusFill {
    struct Layout: Equatable {
        let size: CGSize
        let origin: CGPoint
    }

    /// How far past plain aspect-fill the crop may zoom to bring an
    /// edge-of-frame plane toward center. The hero slot is short and wide,
    /// so at pure fill a plane in the outer ~top/bottom band pins to the
    /// edge (it can't slide far enough without exposing background). Zooming
    /// in a little grows the overflow so the focus point can reach center;
    /// capped so an extreme-edge plane doesn't crop the photo to a sliver.
    /// Center-band planes need no zoom, so they're unaffected.
    static let maxCenteringZoom: CGFloat = 1.6

    static func layout(imageSize: CGSize, frameSize: CGSize, focus: CGPoint) -> Layout {
        guard imageSize.width > 0, imageSize.height > 0,
              frameSize.width > 0, frameSize.height > 0
        else { return Layout(size: frameSize, origin: .zero) }
        let fill = max(frameSize.width / imageSize.width,
                       frameSize.height / imageSize.height)
        // Scale needed for the focus point to reach the frame center on each
        // axis: the scaled image must extend at least half a frame past the
        // focus on the tighter side (`min(focus, 1−focus)`). Take the larger
        // requirement, floored at fill and capped at the zoom limit.
        let marginX = max(0.001, min(focus.x, 1 - focus.x))
        let marginY = max(0.001, min(focus.y, 1 - focus.y))
        let needX = frameSize.width / (2 * marginX * imageSize.width)
        let needY = frameSize.height / (2 * marginY * imageSize.height)
        let s = min(fill * maxCenteringZoom, max(fill, needX, needY))
        let size = CGSize(width: imageSize.width * s, height: imageSize.height * s)
        // Ideal: focus point at the frame center. Clamp between "image's
        // trailing edge flush with the frame" and "leading edge flush" so
        // the fill never exposes background.
        let x = min(0, max(frameSize.width - size.width,
                           frameSize.width / 2 - focus.x * size.width))
        let y = min(0, max(frameSize.height - size.height,
                           frameSize.height / 2 - focus.y * size.height))
        return Layout(size: size, origin: CGPoint(x: x, y: y))
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

/// Splits a pre-formatted value like "36,745 ft" into ("36,745", "ft") so the
/// unit can render smaller + tinted. Splits on the last space; no space → no unit.
func splitUnit(_ s: String?) -> (value: String, unit: String?) {
    guard let s, !s.isEmpty else { return ("—", nil) }
    if let r = s.range(of: " ", options: .backwards) {
        return (String(s[..<r.lowerBound]), String(s[r.upperBound...]))
    }
    return (s, nil)
}

/// A labelled stat — big monospaced value with a smaller tinted unit suffix.
func statCell(_ label: String, _ raw: String?, scale: CGFloat, accent: Color) -> some View {
    let parts = splitUnit(raw)
    return VStack(alignment: .leading, spacing: 3 * scale) {
        Text(label)
            .font(.system(size: 9.5 * scale, weight: .semibold, design: .monospaced))
            .tracking(1.5).foregroundColor(RP.faint)
        HStack(alignment: .firstTextBaseline, spacing: 4 * scale) {
            Text(parts.value)
                .font(.system(size: 21 * scale, weight: .semibold, design: .monospaced))
                .foregroundColor(RP.ink)
            if let unit = parts.unit {
                Text(unit)
                    .font(.system(size: 12 * scale, weight: .medium, design: .monospaced))
                    .foregroundColor(accent)
            }
        }
        .lineLimit(1).minimumScaleFactor(0.6)
    }
}

func ledgerRow(_ label: String, _ amount: String, _ color: Color, _ opacity: Double, scale: CGFloat, big: Bool = false) -> some View {
    HStack {
        Text(label)
            .font(.system(size: (big ? 12 : 11) * scale, weight: big ? .heavy : .regular, design: .monospaced))
            .tracking(big ? 1.5 : 0)
            .foregroundColor(big ? RP.ink : RP.muted)
        Spacer()
        Text(amount)
            .font(.system(size: (big ? 24 : 13) * scale, weight: big ? .bold : .semibold, design: .monospaced))
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

    /// In-card ROUTE BONUS ROUND (game-layer PR3; in-card redesign per Noah
    /// 2026-07-10). Non-nil → after the reveal settles, the ROUTE panel renders
    /// MASKED and 4 airport chips pop in on the card; answering resolves the
    /// route in place. nil → a plain reveal (the common no-round path). Only a
    /// fresh single catch is ever handed one (ContentView + GuessScheduler gate).
    var guess: GuessRoundQuestion? = nil
    /// Fired once when the chips pop in (ContentView stamps the "shown" time +
    /// fires `guess_round_shown`). The elapsed clock for `_answered`/`_skipped`
    /// starts here, not at reveal-present, so it reflects the actual deliberation.
    var onGuessShown: (() -> Void)? = nil
    /// Fired once when the round resolves: a tapped answer (`answeredValue` = the
    /// chip's wire value, `correct` = local verdict) or SKIP / dismiss-mid-chips
    /// (`answeredValue == nil`, `correct == false`). ContentView freezes the
    /// outcome onto the row + fires `guess_round_answered`/`_skipped`.
    var onGuessResolved: ((_ answeredValue: String?, _ correct: Bool) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    #if DEBUG
    /// Snapshot/visual-pass seam — `accessibilityReduceMotion` is a read-only
    /// environment key, so the render harness forces it here instead.
    /// nil (production) = follow the system setting.
    var _reduceMotionOverride: Bool? = nil
    private var reduceMotion: Bool { _reduceMotionOverride ?? systemReduceMotion }
    #else
    private var reduceMotion: Bool { systemReduceMotion }
    #endif

    /// Animation clock anchor. nil until `onAppear`; `t` is 0 until set.
    @State private var start: Date?
    /// Flips true once the reveal has played out (or the user taps to skip),
    /// gating the dismiss CTAs and the success haptic.
    @State private var settled = false

    // MARK: In-card bonus round state

    /// Chip lifecycle: `.hidden` during the reveal, `.shown` once the round pops
    /// in (chips interactive), `.collapsed` after the answer settles (chips gone,
    /// full route + any bonus line remain).
    @State private var chipsPhase: ChipsPhase = .hidden
    /// Clock anchor for the staggered chip pop-in. Set when chips first show.
    @State private var chipsStart: Date?
    /// The resolved outcome — nil while prompting, set once on tap / skip /
    /// dismiss-mid-chips. Drives the chip flash, the masked→real route crossfade,
    /// and (on a correct call) the bonus ledger line + count-up.
    @State private var resolution: GuessResolution?
    /// Clock anchor for the correct-answer bonus count-up (route bonus rolling
    /// into the TOTAL). nil unless the answer was correct.
    @State private var bonusStart: Date?
    /// Latches on the first resolve so the round resolves exactly once.
    @State private var guessResolved = false
    /// Once-only guard so `onGuessShown` fires a single time.
    @State private var guessShownFired = false
    /// Sensory-feedback triggers — counters so repeats can't collapse.
    @State private var successBeat = 0
    @State private var missBeat = 0

    enum ChipsPhase { case hidden, shown, collapsed }

    /// A resolved bonus-round outcome. `answeredValue == nil` ⇒ SKIP / dismiss.
    struct GuessResolution: Equatable {
        let answeredValue: String?
        let correct: Bool
    }

    /// The immutable per-frame description of the bonus round the card renders —
    /// mapped from the `@State` above (live) or built directly (snapshots). Keeps
    /// `card` a pure function of its clocks + this value so any beat renders as a
    /// static frame for the visual-pass harness.
    struct GuessRender: Equatable {
        let question: GuessRoundQuestion
        /// nil ⇒ prompting (masked route); non-nil ⇒ resolved (real route shows).
        let resolution: GuessResolution?
        /// Chips present in the card's layout (popped in, not yet collapsed).
        let chipsInLayout: Bool
        /// Stagger clock for the chip pop-in (0 → 1). 1 = fully popped.
        let popClock: Double
    }

    /// How long the correct-answer bonus count-up takes.
    private let bonusCountUpDuration: Double = 0.6
    /// How long the staggered chip pop-in takes.
    private var chipPopDuration: Double { reduceMotion ? 0.25 : 0.6 }

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
        // Fraction via ScoringBonuses (pinned to scoring-bonuses.json by the
        // parity test) — never a local literal, so the ledger can't drift
        // from the server's award.
        plane.isFirstOfType && !isDuplicate ? ScoringBonuses.firstOfTypeBonus(base: base) : 0
    }
    /// The route bonus a correct in-card guess earns — derived live off the base
    /// like `firstOfTypeBonus`, so it re-tiers on read. Route-only per Noah.
    private var routeBonus: Int {
        isDuplicate ? 0 : ScoringBonuses.guessBonus(base: base, kind: .route)
    }
    /// Pre-frozen guess bonus for the LEGACY (no live round) path only: a plane
    /// whose row already recorded a correct guess (e.g. a re-render). With a live
    /// `guess` payload the count-up drives the bonus instead, so this is 0.
    private var frozenGuessBonus: Int {
        guard guess == nil, plane.guessKind != nil, !isDuplicate else { return 0 }
        return plane.guessBonusPoints
    }
    /// The target the reveal's own count-up climbs to — base + first-of-type +
    /// any pre-frozen bonus. The LIVE route bonus is deliberately excluded: it
    /// counts up separately (on `bonusStart`) once the player answers correctly.
    private var revealTargetTotal: Int { isDuplicate ? 0 : base + firstOfTypeBonus + frozenGuessBonus }

    var body: some View {
        GeometryReader { geo in
            let width = min(geo.size.width - 28, 420)
            ZStack {
                RP.bg.ignoresSafeArea()

                // Full-screen dismiss / skip catcher, BELOW the card and CTA.
                // The card normally has hit-testing off so taps on it fall
                // through to here; while the bonus-round chips are up the card
                // captures taps instead (so the chips + SKIP work) and only
                // margin taps reach this catcher. The CTA buttons sit above and
                // capture their own taps.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { advanceOrDismiss() }
                    .ignoresSafeArea()

                TimelineView(.animation) { context in
                    let t = start.map { revClamp(context.date.timeIntervalSince($0) / duration) } ?? 0
                    let bt = bonusStart.map { revClamp(context.date.timeIntervalSince($0) / bonusCountUpDuration) } ?? 0
                    let gt = chipsStart.map { revClamp(context.date.timeIntervalSince($0) / chipPopDuration) }
                        ?? (chipsPhase == .shown ? 1 : 0)
                    layout(t: t, bt: bt, gt: gt, width: width)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { start = Date() }
            .task {
                try? await Task.sleep(for: .seconds(duration))
                withAnimation(.easeOut(duration: 0.3)) { settled = true }
            }
            // Pop the bonus round the moment the reveal settles — whether it
            // settled naturally or the user tapped to skip the animation.
            .onChange(of: settled) { _, isSettled in
                if isSettled { popBonusRoundIfEligible() }
            }
            .sensoryFeedback(.success, trigger: settled)
            .sensoryFeedback(.success, trigger: successBeat)
            .sensoryFeedback(.error, trigger: missBeat)
        }
    }

    /// Card stacked ABOVE the CTA so the "tap to continue / View in Hangar"
    /// row is always a reserved strip below the card — never overlapped by a
    /// tall (wrapped-name) card, which is what happened when the card was
    /// free-centered in the full screen and the CTA was pinned to the bottom.
    /// The card's frame fills the space above the CTA and centers its content;
    /// card taps fall through (hit-testing off) to the dismiss catcher behind,
    /// while the CTA captures its own taps.
    @ViewBuilder
    private func layout(t: Double, bt: Double, gt: Double, width: CGFloat) -> some View {
        // Map the live bonus-round @State into the immutable per-frame render.
        let render: GuessRender? = guess.map {
            GuessRender(question: $0,
                        resolution: resolution,
                        chipsInLayout: chipsPhase == .shown,
                        popClock: gt)
        }
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            card(t: t, bt: bt, width: width, render: render)
                // The card is normally tap-through (taps fall to the dismiss
                // catcher behind). While the chips are up it must capture taps
                // so the chips + SKIP are interactive; margin taps still reach
                // the catcher and count as a skip-then-dismiss.
                .allowsHitTesting(chipsPhase == .shown)
            Spacer(minLength: 0)
            ctaRow
                .opacity(settled ? 1 : 0)
                .allowsHitTesting(settled)
                .padding(.top, 14)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func advanceOrDismiss() {
        if settled {
            // A margin tap while the (unanswered) chips are up counts as a skip.
            resolveAsSkipIfNeeded()
            onDismiss()
        } else {
            // Skip the animation straight to its final frame.
            start = Date().addingTimeInterval(-duration)
            withAnimation(.easeOut(duration: 0.25)) { settled = true }
        }
    }

    // MARK: - Bonus-round lifecycle

    /// Pops the chips in ~0.2 s after the reveal settles (guarded to once). Fires
    /// `onGuessShown` so ContentView stamps the deliberation clock + telemetry.
    private func popBonusRoundIfEligible() {
        guard guess != nil, chipsPhase == .hidden else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.2))
            guard chipsPhase == .hidden, resolution == nil else { return }
            chipsStart = Date()
            withAnimation(reduceMotion ? .easeOut(duration: 0.25)
                                       : .spring(response: 0.42, dampingFraction: 0.72)) {
                chipsPhase = .shown
            }
            if !guessShownFired {
                guessShownFired = true
                onGuessShown?()
            }
        }
    }

    /// Tap on a chip — lock the set, flash the verdict, crossfade to the real
    /// route, and (if correct) roll the bonus into the TOTAL. Resolves once.
    private func tapChip(_ option: GuessOptions.Option) {
        guard let q = guess, !guessResolved else { return }
        guessResolved = true
        let correct = option.value == q.correctValue
        withAnimation(reduceMotion ? .easeOut(duration: 0.2)
                                   : .spring(response: 0.35, dampingFraction: 0.7)) {
            resolution = GuessResolution(answeredValue: option.value, correct: correct)
        }
        if correct { bonusStart = Date(); successBeat += 1 } else { missBeat += 1 }
        onGuessResolved?(option.value, correct)
        scheduleCollapse(correct: correct)
    }

    /// Quiet SKIP — resolve with no answer (no flash, no bonus line), then the
    /// route reveals and the chips collapse like a wrong-minus-flash.
    private func skipBonusRound() {
        guard guess != nil, !guessResolved else { return }
        guessResolved = true
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.3)) {
            resolution = GuessResolution(answeredValue: nil, correct: false)
        }
        onGuessResolved?(nil, false)
        scheduleCollapse(correct: false)
    }

    /// After the verdict registers (a miss lingers a touch less than a correct
    /// call's count-up), collapse the chips away — the settled card with the full
    /// route (+ bonus line if earned) is what remains.
    private func scheduleCollapse(correct: Bool) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(correct ? 1.15 : 0.95))
            withAnimation(reduceMotion ? .easeOut(duration: 0.25)
                                       : .easeInOut(duration: 0.4)) {
                chipsPhase = .collapsed
            }
        }
    }

    /// Dismissing (CTA / margin tap) while the chips are still up counts as a
    /// SKIP: resolve first (freeze nothing — a nil answer), then let the caller
    /// dismiss. No collapse animation — we're leaving the reveal.
    private func resolveAsSkipIfNeeded() {
        guard guess != nil, !guessResolved else { return }
        guessResolved = true
        resolution = GuessResolution(answeredValue: nil, correct: false)
        onGuessResolved?(nil, false)
    }

    #if DEBUG
    /// Renders the FULL reveal (card + CTA over the background) at a fixed
    /// final state and concrete screen size — used by the snapshot / visual-
    /// pass test (`RevealSnapshotTests`). Renders the whole screen, not just
    /// the card, so card↔CTA spacing/overlap is visible. Uses a CONCRETE
    /// `.frame(width:height:)` (not the device `layout`'s greedy
    /// `maxHeight: .infinity`) because ImageRenderer double-renders greedy
    /// frames — a snapshot-only artifact, not a device behavior. DEBUG-only.
    @MainActor func _snapshotScreen(
        width: CGFloat, size: CGSize, guessState: GuessSnapshotState? = nil
    ) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            card(t: 1.0, bt: guessState?.bt ?? 0, width: width, render: guessState?.render)
            Spacer(minLength: 0)
            ctaRow
                .padding(.top, 14)
                .padding(.bottom, 28)
        }
        .frame(width: size.width, height: size.height)
        .background(RP.bg)
    }

    /// A static bonus-round beat for the visual-pass harness: the immutable
    /// render + the count-up clock value to freeze the TOTAL at.
    struct GuessSnapshotState {
        let render: GuessRender
        let bt: Double
    }
    #endif

    // The card itself, fully parameterized by the reveal clock `t`, the bonus
    // count-up clock `bt`, and the immutable bonus-round `render` (nil = plain
    // reveal). Keeping it pure of `@State` lets any beat render as a static frame.
    private func card(t: Double, bt: Double, width: CGFloat, render: GuessRender?) -> some View {
        let accent = plane.rarity.tint
        // The prototype's absolute sizes were tuned for a 300pt-wide card.
        // Scale every metric off the real card width so it reads full-size
        // (and not vertically cramped) on a phone instead of postage-stamp.
        let scale = width / 300
        let hPad = 22 * scale
        let avail = Double(width - 2 * hPad)
        let line = ss(0.5, 0.7, t)
        // While the four chips occupy the card, the photo hero shrinks so the
        // whole round + ledger clears the safe area (Dynamic Island eats the
        // top); it restores to full height once the chips collapse, so the
        // settled card matches a plain reveal. The change rides the chip
        // pop/collapse animation, reading as the card making room then restoring.
        let photoHeight = ((render?.chipsInLayout ?? false) ? 100.0 : 168.0) * scale
        // The reveal's own count-up climbs to the pre-bonus total; a correct
        // in-card guess then rolls its route bonus in on the separate `bt` clock.
        let revealCount = Int((Double(revealTargetTotal) * easeOut(ss(0.82, 0.96, t))).rounded())
        let liveBonus = (render?.resolution?.correct == true) ? routeBonus : 0
        let bonusCount = Int((Double(liveBonus) * easeOut(bt)).rounded())
        let total = revealCount + bonusCount

        // Split-flap sizing: keep cells legible. If the name won't fit on one
        // line at the floor cell size, WRAP it across lines rather than shrink
        // the flaps to dust.
        let model = (plane.model ?? "UNKNOWN AIRCRAFT").uppercased()
        let flapGap = 2.5 * scale
        let maxCW = 17.5 * scale
        let minCW = 12.0 * scale
        // Most chars that fit on a line before cells would drop below the floor.
        let perLine = max(6, Int((avail + Double(flapGap)) / Double(minCW + flapGap)))
        let nameLines = model.count <= perLine ? [model] : wrapName(model, perLine: perLine)
        let longestLine = nameLines.map(\.count).max() ?? model.count
        // Largest uniform cell that fits the longest wrapped line.
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

        return ZStack {
            // Tier bloom behind the card — modest for rare, cinematic for legendary.
            if plane.rarity.ordinal >= Rarity.epic.ordinal {
                RadialGradient(colors: [accent.opacity(0.22), .clear],
                               center: .center, startRadius: 1, endRadius: Double(width) * 0.9)
                    .opacity(ss(0.0, 0.4, t) * (plane.rarity == .legendary ? 1.0 : 0.6))
                    .blur(radius: 8)
            }

            VStack(alignment: .leading, spacing: 0) {
                RevealPhoto(url: plane.photoURL, focus: plane.photoFocus)
                    .frame(height: photoHeight)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(accent.opacity(plane.rarity.ordinal >= Rarity.rare.ordinal ? 0.35 : 0.18), lineWidth: 1)
                    )
                    .opacity(ss(0.0, 0.18, t))
                    .padding(18 * scale)

                VStack(alignment: .leading, spacing: 11 * scale) {
                    VStack(alignment: .leading, spacing: 4 * scale) {
                        ForEach(flapLines) { fl in
                            FlapRow(text: fl.text, t: t, startT: 0.24, spanT: 0.36,
                                    fs: fs, cw: cw, gap: flapGap,
                                    indexOffset: fl.id, totalCount: totalFlapChars,
                                    reduceMotion: reduceMotion, color: RP.ink)
                        }
                    }

                    HStack(spacing: 7 * scale) {
                        Circle().fill(accent).frame(width: 6 * scale, height: 6 * scale)
                        Text(plane.rarity.label.uppercased())
                            .font(.system(size: 11 * scale, weight: .semibold, design: .monospaced))
                            .tracking(3).foregroundColor(accent)
                        if isDuplicate {
                            Text("· ALREADY CAUGHT")
                                .font(.system(size: 10 * scale, weight: .semibold, design: .monospaced))
                                .tracking(1).foregroundColor(Brand.Color.duplicateRose)
                        }
                    }
                    .opacity(ss(0.56, 0.7, t))

                    Rectangle().fill(RP.rule).frame(width: CGFloat(avail) * line, height: 1)

                    dataSection(t: t, scale: scale, accent: accent, render: render)

                    // The bonus round — chips pop in below the route section
                    // once the reveal settles, and collapse away after the answer.
                    if let render, render.chipsInLayout {
                        routeBonusChips(render: render, scale: scale)
                            .padding(.top, 2 * scale)
                            .transition(.opacity)
                    }

                    VStack(spacing: 8 * scale) {
                        Rectangle().fill(RP.rule).frame(height: 1).padding(.top, 4 * scale)
                        if isDuplicate {
                            ledgerRow("ALREADY IN HANGAR", "", RP.muted, ss(0.78, 0.86, t), scale: scale)
                        } else {
                            ledgerRow(plane.rarity.label.uppercased(), "+\(base)", RP.muted, ss(0.78, 0.86, t), scale: scale)
                            if firstOfTypeBonus > 0 {
                                ledgerRow("FIRST OF TYPE", "+\(firstOfTypeBonus)", RP.gold, ss(0.82, 0.9, t), scale: scale)
                            }
                            // Route-guess bonus. In the live in-card round it
                            // appears ONLY on a correct call and fades in with
                            // the count-up (`bt`); the legacy re-render path uses
                            // the pre-frozen amount. Label locked to "10% ROUTE
                            // BONUS" (Noah 2026-07-09).
                            if let render {
                                if render.resolution?.correct == true, routeBonus > 0 {
                                    ledgerRow("10% ROUTE BONUS", "+\(routeBonus)", RP.gold, ss(0.0, 0.4, bt), scale: scale)
                                }
                            } else if frozenGuessBonus > 0 {
                                ledgerRow("10% ROUTE BONUS", "+\(frozenGuessBonus)", RP.gold, ss(0.83, 0.91, t), scale: scale)
                            }
                        }
                        Rectangle().fill(RP.rule).frame(height: 1)
                        ledgerRow("TOTAL", "+\(total)", accent, ss(0.84, 0.92, t), scale: scale, big: true)
                    }

                    // Entry stamp — hidden while the chips occupy the card, so
                    // the round has room; it returns once they collapse.
                    if !(render?.chipsInLayout ?? false) {
                        HStack {
                            Spacer()
                            Text("ENTRY #\(entryNumber)")
                                .font(.system(size: 9 * scale, weight: .semibold, design: .monospaced))
                                .tracking(1.5).foregroundColor(RP.faint)
                        }
                        .opacity(ss(0.9, 1.0, t))
                        .padding(.top, 2 * scale)
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
    }

    // ALT / SPD as a two-column top row, then (when there's route data) a
    // rule and a full-width ROUTE row: big ICAO codes with a tinted arrow and
    // the human-readable city names underneath. No route → DIST joins row one.
    //
    // With a bonus round in play, the route slot renders MASKED (the question
    // prompt) while prompting and CROSSFADES to the real route once resolved.
    @ViewBuilder
    private func dataSection(t: Double, scale: CGFloat, accent: Color, render: GuessRender?) -> some View {
        let hasRoute = (plane.originIcao ?? plane.destIcao) != nil
        VStack(alignment: .leading, spacing: 12 * scale) {
            // ALT / SPD — always two columns with a real gap so wide values
            // (e.g. "35,433 ft") never butt against the next column.
            HStack(spacing: 14 * scale) {
                statCell("ALT", plane.altText, scale: scale, accent: accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                statCell("SPD", plane.speedText, scale: scale, accent: accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .opacity(ss(0.6, 0.76, t))

            // The third fact gets its own full-width row: ROUTE when we have
            // it, otherwise DIST. Never a cramped third column.
            Rectangle().fill(RP.rule).frame(height: 1)
            Group {
                if let render {
                    // ZStack crossfade: both layers reserve the slot so its
                    // height is stable across the masked→real flip (no jump).
                    ZStack(alignment: .leading) {
                        maskedRoutePrompt(question: render.question, scale: scale)
                            .opacity(render.resolution == nil ? 1 : 0)
                        realRouteOrDist(hasRoute: hasRoute, scale: scale, accent: accent)
                            .opacity(render.resolution == nil ? 0 : 1)
                    }
                } else {
                    realRouteOrDist(hasRoute: hasRoute, scale: scale, accent: accent)
                }
            }
            .opacity(ss(0.66, 0.82, t))
        }
    }

    @ViewBuilder
    private func realRouteOrDist(hasRoute: Bool, scale: CGFloat, accent: Color) -> some View {
        if hasRoute {
            routeCell(scale: scale, accent: accent)
        } else {
            statCell("DIST", plane.distText, scale: scale, accent: accent)
        }
    }

    /// The masked ROUTE slot during the bonus round: a gold eyebrow + the
    /// cyan-mono question, occupying the same slot the real route will crossfade
    /// into. Styled to match the card's mono labels.
    private func maskedRoutePrompt(question: GuessRoundQuestion, scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            Text("BONUS ROUND · +10%")
                .font(.system(size: 9.5 * scale, weight: .bold, design: .monospaced))
                .tracking(1.5).foregroundColor(RP.gold)
            Text(question.prompt)
                .font(.system(size: 15 * scale, weight: .bold, design: .monospaced))
                .foregroundColor(Brand.Color.cyan)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(2).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func routeCell(scale: CGFloat, accent: Color) -> some View {
        // Only draw the arrow + second endpoint when BOTH exist — a one-sided
        // route (origin known, destination not filed yet) shows just the one
        // code, never a dangling "→ —".
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

    private var ctaRow: some View {
        HStack(spacing: 18) {
            Text("tap to continue")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1.2).foregroundColor(RP.faint)
                .contentShape(Rectangle())
                .onTapGesture { resolveAsSkipIfNeeded(); onDismiss() }
            Button(action: { resolveAsSkipIfNeeded(); onViewInHangar() }) {
                Text("View in Hangar ›")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(0.5).foregroundColor(plane.rarity.tint)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Bonus-round chips

    /// The 4 airport chips (staggered pop-in via `render.popClock`) + a quiet
    /// SKIP. Chip styling matches the onboarding elevated + cyan-hairline look;
    /// resolving flips the tapped chip green/red and highlights the right answer.
    private func routeBonusChips(render: GuessRender, scale: CGFloat) -> some View {
        VStack(spacing: 8 * scale) {
            ForEach(Array(render.question.options.enumerated()), id: \.element.value) { idx, option in
                let pop = chipPop(idx: idx, gt: render.popClock)
                answerChip(option, render: render, scale: scale)
                    .opacity(min(1, pop))
                    // Reduce Motion: plain fade, no scale pop.
                    .scaleEffect(reduceMotion ? 1 : 0.82 + 0.18 * pop, anchor: .center)
            }
            // SKIP retires the instant the player commits.
            Button(action: skipBonusRound) {
                Text("SKIP")
                    .font(.system(size: 11 * scale, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(RP.faint)
                    .padding(.vertical, 6 * scale)
                    .padding(.horizontal, 18 * scale)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(render.resolution != nil)
            .opacity(render.resolution == nil ? min(1, chipPop(idx: render.question.options.count, gt: render.popClock)) : 0)
        }
        .padding(.top, 2 * scale)
    }

    private func answerChip(_ option: GuessOptions.Option, render: GuessRender, scale: CGFloat) -> some View {
        let state = chipState(for: option.value, render: render)
        return Button {
            tapChip(option)
        } label: {
            HStack(spacing: 8 * scale) {
                Text(option.display)
                    .font(.system(size: 14 * scale, weight: .semibold, design: .monospaced))
                    .foregroundStyle(state.textColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                switch state {
                case .correct:
                    Image(systemName: "checkmark")
                        .font(.system(size: 12 * scale, weight: .bold))
                        .foregroundStyle(Brand.Color.alertNormal)
                case .wrong:
                    Image(systemName: "xmark")
                        .font(.system(size: 12 * scale, weight: .bold))
                        .foregroundStyle(Brand.Color.alertWarning)
                case .idle, .dimmed:
                    EmptyView()
                }
            }
            .padding(.horizontal, 14 * scale)
            .padding(.vertical, 11 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(state.background, in: .rect(cornerRadius: 11 * scale))
            .overlay(
                RoundedRectangle(cornerRadius: 11 * scale)
                    .strokeBorder(state.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(render.resolution != nil)
    }

    private enum ChipState {
        case idle       // prompting: tappable
        case correct    // resolved: the right answer (green)
        case wrong      // resolved: the tapped wrong answer (red)
        case dimmed     // resolved: an untaken chip (or any chip on SKIP)

        var background: Color {
            switch self {
            case .idle:    return Brand.Color.bgElevated
            case .correct: return Brand.Color.alertNormal.opacity(0.15)
            case .wrong:   return Brand.Color.alertWarning.opacity(0.15)
            case .dimmed:  return Brand.Color.bgElevated.opacity(0.5)
            }
        }
        var border: Color {
            switch self {
            case .idle:    return Brand.Color.cyan.opacity(0.20)
            case .correct: return Brand.Color.alertNormal
            case .wrong:   return Brand.Color.alertWarning
            case .dimmed:  return Brand.Color.cyan.opacity(0.06)
            }
        }
        var textColor: Color {
            switch self {
            case .idle, .correct, .wrong: return Brand.Color.textPrimary
            case .dimmed:                 return Brand.Color.textTertiary
            }
        }
    }

    private func chipState(for value: String, render: GuessRender) -> ChipState {
        guard let res = render.resolution else { return .idle }
        // SKIP / dismiss (no answer) collapses quietly — no green/red flash.
        if res.answeredValue == nil { return .dimmed }
        if value == render.question.correctValue { return .correct }
        if value == res.answeredValue { return .wrong }
        return .dimmed
    }

    /// Staggered pop-in: chip `idx` starts a beat after the one before it and
    /// springs to full with a slight overshoot. Reduced-motion → a plain fade,
    /// no stagger.
    private func chipPop(idx: Int, gt: Double) -> Double {
        if reduceMotion { return ss(0, 1, gt) }
        let start = Double(idx) * 0.07
        return easeOutBack(ss(start, start + 0.42, gt))
    }

    /// easeOutBack — overshoots slightly past 1 before settling, for the springy
    /// chip pop. Callers clamp opacity to ≤ 1; the scale keeps the overshoot.
    private func easeOutBack(_ x: Double) -> Double {
        let u = revClamp(x)
        let c1 = 1.70158
        let c3 = c1 + 1
        return 1 + c3 * pow(u - 1, 3) + c1 * pow(u - 1, 2)
    }
}
