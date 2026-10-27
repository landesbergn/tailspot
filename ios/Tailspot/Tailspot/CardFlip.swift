//
//  CardFlip.swift
//  Tailspot
//
//  Turning a catch card over (2026-10-25). `FlipCard` holds two faces — the
//  catch card as it is today on the front, the closeup + type info
//  (`CatchCardBack`) on the back — and turns between them with a real 3D
//  flip around the vertical axis. `CardTurnOverButton` is the mono-caps
//  control at the bottom of each face ("ABOUT THIS PLANE" / "BACK TO CATCH").
//
//  Explain-as-we-go — how the flip works:
//   - `rotation3DEffect(_:axis:perspective:)` draws a view as if it were a
//     flat plate rotated in 3D. Axis (0, 1, 0) is the vertical (Y) axis, so
//     the card turns like a page; `perspective` controls how strongly the
//     near edge grows and the far edge shrinks (0 = flat, 1 = extreme).
//   - Both faces sit in one ZStack and rotate together. The back is
//     PRE-ROTATED by 180° (its rotation is `angle − 180`), so when the card
//     has turned 180° the back has turned 0° and reads the right way round
//     instead of mirrored.
//   - Which face is showing must switch at EXACTLY 90°, the instant the card
//     is edge-on. If we just set `opacity(isFlipped ? …)`, SwiftUI would
//     cross-fade the two faces over the whole animation and you'd see the
//     back bleed through the front. So the per-face modifier (`FlipFace`)
//     conforms to `Animatable`: SwiftUI then calls its `body` on EVERY frame
//     of the animation with the in-between angle (via `animatableData`),
//     and the modifier decides per frame which face is visible.
//   - Reduce Motion: no rotation at all, a short crossfade instead.
//

import SwiftUI

// MARK: - Pure decisions (unit-tested)

/// The flip's pure decisions, kept out of the views so tests can pin them.
/// `nonisolated` — plain math, no UI state.
nonisolated enum CardFlipMath {
    enum Face: Equatable, Sendable { case front, back }
    enum SwipeDirection: Equatable, Sendable { case left, right }

    /// A horizontal drag must travel at least this far to flip the card.
    static let swipeThreshold: CGFloat = 40
    /// The resting angles: 0° shows the front, 180° the back.
    static let frontAngle: Double = 0
    static let backAngle: Double = 180
    /// `rotation3DEffect` perspective — enough depth to read as 3D without
    /// the near edge ballooning past the screen on a 393 pt card.
    static let perspective: CGFloat = 0.45
    /// Peak opacity of the light sheen (reached edge-on, at 90°).
    static let sheenPeak: Double = 0.22

    static func restingAngle(isFlipped: Bool) -> Double {
        isFlipped ? backAngle : frontAngle
    }

    /// Which face faces the viewer at `angle` degrees. The switch happens at
    /// 90° (and back again at 270°): [−90, 90) is the front, [90, 270) the
    /// back, wrapping every 360°.
    static func visibleFace(angle: Double) -> Face {
        var a = angle.truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        return (a >= 90 && a < 270) ? .back : .front
    }

    /// Classifies a drag's total translation: a horizontal swipe (|dx| > |dy|
    /// and |dx| ≥ threshold) in either direction, or nil — a vertical drag
    /// belongs to the scroll view, a short one to nothing.
    static func swipeDirection(translation: CGSize,
                               threshold: CGFloat = swipeThreshold) -> SwipeDirection? {
        let dx = translation.width, dy = translation.height
        guard abs(dx) > abs(dy), abs(dx) >= threshold else { return nil }
        return dx < 0 ? .left : .right
    }

    /// Reduce Motion crossfade: the face's opacity at `angle` (0…180 maps to
    /// a linear dissolve front → back; clamped outside that range).
    static func crossfadeOpacity(angle: Double, face: Face) -> Double {
        let progress = min(1, max(0, angle / backAngle))
        return face == .back ? progress : 1 - progress
    }

    /// The sheen's opacity: zero at rest, peaking at `sheenPeak` when the card
    /// is edge-on (|sin| is 1 at 90° and 270°).
    static func sheenOpacity(angle: Double) -> Double {
        let s = sin(angle * .pi / 180)
        return sheenPeak * s * s
    }
}

// MARK: - FlipCard

struct FlipCard<Front: View, Back: View>: View {
    @Binding var isFlipped: Bool
    /// Swipe-to-flip only when true (the reveal enables it once the catch
    /// has settled). The turn-over buttons live inside the faces and are the
    /// caller's to enable.
    let enabled: Bool
    private let front: Front
    private let back: Back

    /// The flip ignores the system Reduce Motion setting (Noah, 2026-10-26):
    /// the turn IS the interaction, and the crossfade read as "nothing
    /// happened". The crossfade path stays below, unused, until the
    /// card-back experiment picks a winner and the losers are deleted.
    private let reduceMotion = false
    /// The front's measured size. The back is laid out at exactly this size
    /// so the card doesn't change shape when it turns over.
    @State private var frontSize: CGSize = .zero

    #if DEBUG
    /// Test hook: render a frozen mid-flip frame (degrees) instead of the
    /// angle `isFlipped` implies. See `_snapshotAngle(_:)`.
    fileprivate var snapshotAngle: Double? = nil
    #endif

    init(isFlipped: Binding<Bool>, enabled: Bool = true,
         @ViewBuilder front: () -> Front, @ViewBuilder back: () -> Back) {
        self._isFlipped = isFlipped
        self.enabled = enabled
        self.front = front()
        self.back = back()
    }

    private var angle: Double {
        #if DEBUG
        if let snapshotAngle { return snapshotAngle }
        #endif
        return CardFlipMath.restingAngle(isFlipped: isFlipped)
    }

    var body: some View {
        let angle = self.angle
        ZStack {
            front
                .onGeometryChange(for: CGSize.self) { $0.size } action: { frontSize = $0 }
                .modifier(FlipFace(angle: angle, isBack: false, reduceMotion: reduceMotion))

            // Not laid out until the front has been measured — otherwise a
            // back that fills its proposal would size the ZStack to it.
            if frontSize.width > 0, frontSize.height > 0 {
                back
                    .frame(width: frontSize.width, height: frontSize.height)
                    .modifier(FlipFace(angle: angle, isBack: true, reduceMotion: reduceMotion))
            }
        }
        // Spring for the turn; a short ease for the Reduce Motion crossfade.
        // `value: isFlipped` scopes the animation to the flip alone.
        .animation(reduceMotion
                       ? .easeInOut(duration: 0.25)
                       : .spring(duration: 0.55, bounce: 0.18),
                   value: isFlipped)
        // A horizontal swipe also turns the card. `simultaneousGesture` lets
        // the enclosing ScrollView keep its vertical drag, and buttons inside
        // the faces keep their taps (a tap never travels 20 pt).
        .simultaneousGesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                guard CardFlipMath.swipeDirection(translation: value.translation) != nil else { return }
                isFlipped.toggle()
            },
            isEnabled: enabled
        )
        .sensoryFeedback(.impact(weight: .light), trigger: isFlipped)
    }
}

#if DEBUG
extension FlipCard {
    /// Freeze the card at `degrees` (0 = front, 90 = edge-on, 180 = back) —
    /// for snapshot tests rendering mid-flip frames. nil = normal behaviour.
    func _snapshotAngle(_ degrees: Double?) -> FlipCard {
        var copy = self
        copy.snapshotAngle = degrees
        return copy
    }
}
#endif

/// One face's share of the flip: its rotation, the sheen, and whether it's
/// the face showing at the current (animating) angle.
///
/// `Animatable`: SwiftUI interpolates `animatableData` (the angle) and
/// re-runs `body` every frame, which is what lets the visible face switch at
/// exactly 90° instead of cross-fading over the whole turn.
private struct FlipFace: ViewModifier, Animatable {
    var angle: Double
    let isBack: Bool
    let reduceMotion: Bool

    nonisolated var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        let me: CardFlipMath.Face = isBack ? .back : .front
        if reduceMotion {
            // Crossfade: no rotation. The angle still animates 0 → 180, but
            // here it only drives a continuous opacity ramp, so the faces
            // dissolve into each other. VoiceOver / hits follow whichever
            // face is past the midpoint.
            let shown = CardFlipMath.visibleFace(angle: angle) == me
            content
                .opacity(CardFlipMath.crossfadeOpacity(angle: angle, face: me))
                .accessibilityHidden(!shown)
                .allowsHitTesting(shown)
        } else {
            let shown = CardFlipMath.visibleFace(angle: angle) == me
            content
                .overlay { sheen }
                // The back's rotation is offset by 180° (pre-rotated), so at
                // angle 180 it sits at 0° and reads correctly.
                .rotation3DEffect(.degrees(isBack ? angle - 180 : angle),
                                  axis: (x: 0, y: 1, z: 0),
                                  perspective: CardFlipMath.perspective)
                .opacity(shown ? 1 : 0)
                .accessibilityHidden(!shown)
                .allowsHitTesting(shown)
        }
    }

    /// A soft diagonal highlight that brightens as the card turns edge-on —
    /// the light catching the card. Clipped to the card's hero radius, never
    /// interactive or read by VoiceOver.
    private var sheen: some View {
        let progress = min(1, max(0, angle / 180))
        return LinearGradient(
            colors: [.white.opacity(0), .white, .white.opacity(0)],
            startPoint: UnitPoint(x: -0.6 + progress * 1.2, y: 0),
            endPoint: UnitPoint(x: 0.4 + progress * 1.2, y: 1)
        )
        .opacity(CardFlipMath.sheenOpacity(angle: angle))
        .blendMode(.plusLighter)
        .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.hero))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Turn-over button

/// The full-width text control at the bottom of a card face — mono caps in
/// the card's label vocabulary, with a rotate glyph. A real Button, so
/// VoiceOver reads "About this plane, button"; the hit target is at least
/// 44 pt tall whatever the card scale.
struct CardTurnOverButton: View {
    let title: String
    let scale: CGFloat
    let action: () -> Void

    init(title: String, scale: CGFloat, action: @escaping () -> Void) {
        self.title = title
        self.scale = scale
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7 * scale) {
                Image(systemName: "arrow.trianglehead.2.counterclockwise.rotate.90")
                    .font(.system(size: 11 * scale, weight: .semibold))
                Text(title.uppercased())
                    .font(.system(size: 11 * scale, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(RP.muted)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // "ABOUT THIS PLANE" → "About this plane": VoiceOver would otherwise
        // spell an all-caps label out or read it shouty.
        .accessibilityLabel(Self.accessibilityLabel(for: title))
    }

    /// Sentence case for VoiceOver: "ABOUT THIS PLANE" → "About this plane".
    nonisolated static func accessibilityLabel(for title: String) -> String {
        let lower = title.lowercased()
        guard let first = lower.first else { return title }
        return first.uppercased() + lower.dropFirst()
    }
}
