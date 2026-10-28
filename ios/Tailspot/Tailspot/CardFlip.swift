//
//  CardFlip.swift
//  Tailspot
//
//  Turning a catch card over (2026-10-25). `FlipCard` holds two faces — the
//  catch card as it is today on the front, the closeup + type info
//  (`CatchCardBack`) on the back — and turns between them with a real 3D
//  flip around the vertical axis. `CardTurnOverButton` is the mono-caps
//  control ("ABOUT THIS PLANE" / "BACK TO CATCH").
//
//  The control sits UNDER the card, not on it (2026-10-28, Noah: "maybe the
//  flip button should be outside of the card?"): it's something you do to
//  the card, not something printed on it, and inside it crowded TOTAL and
//  the streak. FlipCard draws one control for both faces; its label says
//  where the next turn goes.
//
//  Turn direction (2026-10-27, Noah: "fix the flip direction so it depends
//  which way you swipe or where you tap"): a swipe turns the card the way
//  the finger went, and a tap on the turn-over control turns it the way
//  pressing that side of a real card would (tap the right half, the right
//  edge goes away). So the angle is no longer just 0 or 180: each turn adds
//  or takes away 180°, and the card can keep turning the same way.
//
//  The peek (2026-10-27): turning the card over isn't obvious, so the first
//  few times a card is shown it tilts about halfway over on its own and
//  springs back, with a tap of haptics. It stops for good once you've
//  turned a card yourself (`CardFlipTease`).
//
//  Explain-as-we-go — how the flip works:
//   - `rotation3DEffect(_:axis:perspective:)` draws a view as if it were a
//     flat plate rotated in 3D. Axis (0, 1, 0) is the vertical (Y) axis, so
//     the card turns like a page; `perspective` controls how strongly the
//     near edge grows and the far edge shrinks (0 = flat, 1 = extreme).
//     A positive angle sends the right edge away from you.
//   - Both faces sit in one ZStack and rotate together. The back is
//     PRE-ROTATED by 180° (its rotation is `angle − 180`), so when the card
//     has turned 180° (either way) the back reads the right way round
//     instead of mirrored.
//   - Which face is showing must switch at EXACTLY 90°, the instant the card
//     is edge-on. If we just set `opacity(isFlipped ? …)`, SwiftUI would
//     cross-fade the two faces over the whole animation and you'd see the
//     back bleed through the front. So the per-face modifier (`FlipFace`)
//     conforms to `Animatable`: SwiftUI then calls its `body` on EVERY frame
//     of the animation with the in-between angle (via `animatableData`),
//     and the modifier decides per frame which face is visible.
//   - The turn-over control doesn't know which way to turn, so
//     the flip hands it a "which way" callback through the environment
//     (`cardTurnDirection`); the control reports the side it was tapped on,
//     then runs its action as before.
//   - Reduce Motion: ignored by the turn (Noah, 2026-10-26: the turn IS the
//     interaction, and a crossfade read as "nothing happened") and by the
//     peek (2026-10-28: "the motion is minimal enough").
//

import SwiftUI

// MARK: - Pure decisions (unit-tested)

/// The flip's pure decisions, kept out of the views so tests can pin them.
/// `nonisolated` — plain math, no UI state.
nonisolated enum CardFlipMath {
    enum Face: Equatable, Sendable { case front, back }
    /// Which way the card turns: `.right` sends the right edge away (the
    /// angle grows), `.left` the left edge (it shrinks).
    enum TurnDirection: Equatable, Sendable { case left, right }

    /// How long after a swipe ends a tap on the card still counts as part
    /// of it: the drag's end and the tap's touch-up land in the same
    /// gesture pass, in no promised order.
    static let swipeTapGrace: TimeInterval = 0.3

    /// Whether a tap on something inside the card is really the end of a
    /// swipe (or a scroll) and should do nothing (2026-10-27): true while a
    /// drag is under way, and for `swipeTapGrace` after it ends.
    static func tapIsPartOfSwipe(dragging: Bool, swipeEndedAt: Date?, now: Date) -> Bool {
        if dragging { return true }
        guard let swipeEndedAt else { return false }
        return now.timeIntervalSince(swipeEndedAt) < swipeTapGrace
    }

    /// A horizontal drag must travel at least this far to flip the card.
    static let swipeThreshold: CGFloat = 40
    /// `rotation3DEffect` perspective — enough depth to read as 3D without
    /// the near edge ballooning past the screen on a 393 pt card.
    static let perspective: CGFloat = 0.45
    /// Peak opacity of the light sheen (reached edge-on, at 90°).
    static let sheenPeak: Double = 0.22

    /// Where a card first shows: 0° the front, 180° the back.
    static func restingAngle(isFlipped: Bool) -> Double {
        isFlipped ? 180 : 0
    }

    /// Which face faces the viewer at `angle` degrees. The switch happens at
    /// 90° (and back again at 270°): [−90, 90) is the front, [90, 270) the
    /// back, wrapping every 360°.
    static func visibleFace(angle: Double) -> Face {
        var a = angle.truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        return (a >= 90 && a < 270) ? .back : .front
    }

    /// The angle after one turn in `direction`.
    static func turnedAngle(from angle: Double, direction: TurnDirection) -> Double {
        angle + (direction == .right ? 180 : -180)
    }

    /// The way to turn when nothing says which (VoiceOver, a turn the
    /// screen asks for): back toward 0, so the card unwinds the way it
    /// came; from 0 (or below), to the right.
    static func defaultDirection(from angle: Double) -> TurnDirection {
        angle > 0 ? .left : .right
    }

    /// A tap on the turn-over control: the side tapped goes away, as if
    /// you'd pressed that edge of a real card.
    static func tapDirection(x: CGFloat, width: CGFloat) -> TurnDirection {
        x < width / 2 ? .left : .right
    }

    /// Classifies a drag's total translation: a horizontal swipe (|dx| > |dy|
    /// and |dx| ≥ threshold) turns the card the way the finger went
    /// (dragging the surface right sends the right edge away); anything
    /// else is nil — a vertical drag belongs to the scroll view, a short
    /// one to nothing.
    static func swipeDirection(translation: CGSize,
                               threshold: CGFloat = swipeThreshold) -> TurnDirection? {
        let dx = translation.width, dy = translation.height
        guard abs(dx) > abs(dy), abs(dx) >= threshold else { return nil }
        return dx < 0 ? .left : .right
    }

    /// The sheen's opacity: zero at rest, peaking at `sheenPeak` when the card
    /// is edge-on (|sin| is 1 at 90° and 270°).
    static func sheenOpacity(angle: Double) -> Double {
        let s = sin(angle * .pi / 180)
        return sheenPeak * s * s
    }

    /// How far through the current half-turn the card is, 0…1, counted in
    /// the direction it's turning — what sweeps the sheen across the face.
    static func halfTurnProgress(angle: Double) -> Double {
        let r = angle.truncatingRemainder(dividingBy: 180)
        return r >= 0 ? r / 180 : 1 + r / 180
    }
}

/// When the card peeks over on its own. `nonisolated` — plain policy.
nonisolated enum CardFlipTease {
    /// The peek stops after this many showings even if nobody turns a card.
    static let maxShows = 5
    /// How far the card tilts: past halfway to edge-on, enough for the
    /// sheen to catch, never far enough to show the back.
    static let peakDegrees: Double = 50
    /// The wait after the card is ready (the reveal settles; the detail
    /// screen opens) before it peeks, so it reads as the card's own move.
    static let delay: Duration = .milliseconds(900)

    static func shouldTease(hasTurnedACard: Bool, timesShown: Int) -> Bool {
        !hasTurnedACard && timesShown < maxShows
    }
}

/// Where the peek's two numbers live, across launches.
enum CardFlipTeaseStore {
    static let turnedKey = "tailspot.cardFlip.hasTurned"
    static let shownKey = "tailspot.cardFlip.teasesShown"

    static var hasTurnedACard: Bool {
        get { UserDefaults.standard.bool(forKey: turnedKey) }
        set { UserDefaults.standard.set(newValue, forKey: turnedKey) }
    }

    static var timesShown: Int {
        get { UserDefaults.standard.integer(forKey: shownKey) }
        set { UserDefaults.standard.set(newValue, forKey: shownKey) }
    }

    #if DEBUG
    /// The wrench panel's "Reset card peek": back to a new user's state, so
    /// the next cards peek again.
    static func debugReset() {
        UserDefaults.standard.removeObject(forKey: turnedKey)
        UserDefaults.standard.removeObject(forKey: shownKey)
    }
    #endif
}

/// What a FlipCard's faces ask before acting on a tap: is this finger
/// really swiping? SwiftUI lets a tap gesture or a Button inside the card
/// fire even when the touch moved, as long as it lifts inside the control,
/// so a swipe that starts on the photo or the Wikipedia teaser would open
/// it as well as turning the card. A plain class, not observed: the faces
/// read it at tap time and nothing needs to redraw when it changes.
final class CardSwipeGuard {
    private var dragging = false
    private var endedAt: Date?

    func dragChanged() { dragging = true }
    func dragEnded() {
        dragging = false
        endedAt = .now
    }

    var swallowsTap: Bool {
        CardFlipMath.tapIsPartOfSwipe(dragging: dragging, swipeEndedAt: endedAt, now: .now)
    }
}

/// `.onCardTap { }`: `onTapGesture` that ignores a touch that was part of
/// a swipe on the enclosing FlipCard. A modifier rather than a helper on
/// the screen, because only views INSIDE the FlipCard see its guard in
/// their environment.
private struct CardTap: ViewModifier {
    @Environment(\.cardSwipeGuard) private var swipeGuard
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onTapGesture {
            guard swipeGuard?.swallowsTap != true else { return }
            action()
        }
    }
}

extension View {
    func onCardTap(perform action: @escaping () -> Void) -> some View {
        modifier(CardTap(action: action))
    }
}

extension EnvironmentValues {
    /// Set by `FlipCard` on its faces: a turn-over control calls it with the
    /// side it was tapped on just before its action turns the card. nil
    /// outside a FlipCard. `@Entry` declares an environment key and its
    /// default in one line.
    @Entry var cardTurnDirection: ((CardFlipMath.TurnDirection) -> Void)? = nil
    /// Set by `FlipCard` on its faces; nil outside one. See `CardSwipeGuard`.
    @Entry var cardSwipeGuard: CardSwipeGuard? = nil
}

// MARK: - FlipCard

struct FlipCard<Front: View, Back: View>: View {
    @Binding var isFlipped: Bool
    /// Swipe-to-flip, the turn-over control and the peek only when true (the
    /// reveal enables them once the catch has settled). The control is
    /// always laid out, only hidden, so the column never grows at settle.
    let enabled: Bool
    /// Whether this card may peek over on its own (`CardFlipTease`).
    let teases: Bool
    private let front: Front
    private let back: Back

    /// The front's measured size. The back is laid out at exactly this size
    /// so the card doesn't change shape when it turns over.
    @State private var frontSize: CGSize = .zero
    /// The card's turn, in degrees: 0 the front, ±180 the back, ±360 the
    /// front again… Its sign says which way it went.
    @State private var angle: Double
    /// The peek's extra tilt on top of `angle`; 0 except mid-peek.
    @State private var teaseAngle: Double = 0
    /// The way the next turn goes, from the gesture or tap that asked for
    /// it; nil = `CardFlipMath.defaultDirection`.
    @State private var pendingDirection: CardFlipMath.TurnDirection?
    @State private var teaseCount = 0
    /// `@State` keeps the one guard alive across redraws.
    @State private var swipeGuard = CardSwipeGuard()
    @GestureState private var dragActive = false

    #if DEBUG
    /// Test hook: render a frozen mid-flip frame (degrees) instead of the
    /// card's own angle. See `_snapshotAngle(_:)`.
    fileprivate var snapshotAngle: Double? = nil
    #endif

    init(isFlipped: Binding<Bool>, enabled: Bool = true, teases: Bool = true,
         @ViewBuilder front: () -> Front, @ViewBuilder back: () -> Back) {
        self._isFlipped = isFlipped
        self.enabled = enabled
        self.teases = teases
        self._angle = State(initialValue: CardFlipMath.restingAngle(isFlipped: isFlipped.wrappedValue))
        self.front = front()
        self.back = back()
    }

    private var shownAngle: Double {
        #if DEBUG
        if let snapshotAngle { return snapshotAngle }
        #endif
        return angle + teaseAngle
    }

    var body: some View {
        let shownAngle = self.shownAngle
        VStack(spacing: 0) {
            ZStack {
                front
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { frontSize = $0 }
                    .modifier(FlipFace(angle: shownAngle, isBack: false))

                // Not laid out until the front has been measured — otherwise a
                // back that fills its proposal would size the ZStack to it.
                if frontSize.width > 0, frontSize.height > 0 {
                    back
                        .frame(width: frontSize.width, height: frontSize.height)
                        .modifier(FlipFace(angle: shownAngle, isBack: true))
                }
            }

            // Under the card, not on either face. Scaled like the card (its
            // design width is 300 pt); `isFlipped` is where the card is going,
            // so the label changes the moment it's tapped.
            CardTurnRow(flipped: isFlipped, scale: frontSize.width / 300) {
                isFlipped.toggle()
            }
            .opacity(enabled ? 1 : 0)
            .allowsHitTesting(enabled)
            .accessibilityHidden(!enabled)
            .animation(.easeOut(duration: 0.25), value: enabled)
        }
        .environment(\.cardTurnDirection) { pendingDirection = $0 }
        .environment(\.cardSwipeGuard, swipeGuard)
        // `value: angle` scopes the spring to turns; the peek animates its
        // own `teaseAngle` with `withAnimation`.
        .animation(.spring(duration: 0.55, bounce: 0.18), value: angle)
        // A horizontal swipe also turns the card, the way the finger went.
        // `simultaneousGesture` lets the enclosing ScrollView keep its
        // vertical drag, and taps inside the faces keep working (a tap never
        // travels 20 pt). Any drag past that, sideways or a scroll, tells
        // the guard, so a control the finger started on doesn't also fire.
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
            .updating($dragActive) { _, active, _ in active = true }
            .onChanged { _ in swipeGuard.dragChanged() }
            .onEnded { value in
                guard let direction = CardFlipMath.swipeDirection(translation: value.translation)
                else { return }
                pendingDirection = direction
                isFlipped.toggle()
            },
            isEnabled: enabled
        )
        // `@GestureState` snaps back to false when the drag ends OR is
        // cancelled (a scroll view taking the touch), where `onEnded` would
        // never run and the guard would swallow every later tap.
        .onChange(of: dragActive) { _, active in
            if !active { swipeGuard.dragEnded() }
        }
        .onChange(of: isFlipped) { _, flipped in turn(toBack: flipped) }
        .task(id: enabled) { await peekIfDue() }
        .sensoryFeedback(.impact(weight: .light), trigger: isFlipped)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: teaseCount)
    }

    /// `isFlipped` changed (a swipe, a turn-over control, or the screen):
    /// turn the card the asked-for way, unless it already shows that face.
    private func turn(toBack: Bool) {
        let direction = pendingDirection ?? CardFlipMath.defaultDirection(from: angle)
        pendingDirection = nil
        guard (CardFlipMath.visibleFace(angle: angle) == .back) != toBack else { return }
        angle = CardFlipMath.turnedAngle(from: angle, direction: direction)
        CardFlipTeaseStore.hasTurnedACard = true
    }

    /// The peek: once the card is ready, if this person hasn't found the
    /// turn yet, tilt it most of the way to edge-on and let it spring back.
    /// Re-runs when `enabled` changes (`.task(id:)`), and is cancelled with
    /// the view.
    private func peekIfDue() async {
        guard teases, enabled,
              CardFlipTease.shouldTease(hasTurnedACard: CardFlipTeaseStore.hasTurnedACard,
                                        timesShown: CardFlipTeaseStore.timesShown)
        else { return }
        #if DEBUG
        guard snapshotAngle == nil else { return }
        #endif
        try? await Task.sleep(for: CardFlipTease.delay)
        guard !Task.isCancelled, !isFlipped,
              CardFlipMath.visibleFace(angle: angle) == .front else { return }
        CardFlipTeaseStore.timesShown += 1
        teaseCount += 1
        // Tilt the way an untouched card would turn, then back with a bounce.
        let peak = CardFlipMath.defaultDirection(from: angle) == .right
            ? CardFlipTease.peakDegrees : -CardFlipTease.peakDegrees
        withAnimation(.easeOut(duration: 0.32)) { teaseAngle = peak }
        try? await Task.sleep(for: .milliseconds(380))
        withAnimation(.spring(duration: 0.7, bounce: 0.45)) { teaseAngle = 0 }
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

    nonisolated var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        let me: CardFlipMath.Face = isBack ? .back : .front
        let shown = CardFlipMath.visibleFace(angle: angle) == me
        content
            .overlay { sheen }
            // The back's rotation is offset by 180° (pre-rotated), so at
            // ±180 it sits at 0° or −360° and reads correctly.
            .rotation3DEffect(.degrees(isBack ? angle - 180 : angle),
                              axis: (x: 0, y: 1, z: 0),
                              perspective: CardFlipMath.perspective)
            .opacity(shown ? 1 : 0)
            .accessibilityHidden(!shown)
            .allowsHitTesting(shown)
    }

    /// A soft diagonal highlight that brightens as the card turns edge-on —
    /// the light catching the card. Clipped to the card's hero radius, never
    /// interactive or read by VoiceOver.
    private var sheen: some View {
        let progress = CardFlipMath.halfTurnProgress(angle: angle)
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

/// The control under a FlipCard: "ABOUT THIS PLANE" on the front, "BACK TO
/// CATCH" on the back. Its own view so the reveal's static snapshot (which
/// renders the card without a FlipCard) draws the same row.
struct CardTurnRow: View {
    let flipped: Bool
    let scale: CGFloat
    let action: () -> Void

    var body: some View {
        CardTurnOverButton(title: Self.title(flipped: flipped),
                           scale: max(scale, 0.5), action: action)
            // The label swap fades rather than snapping mid-turn.
            .animation(.easeOut(duration: 0.2), value: flipped)
            // The 44 pt hit row overhangs the air above and below it by
            // 8 pt each way (negative padding shrinks the LAYOUT box, not
            // the tappable one), so it costs the column ~28 pt + the gap.
            .padding(.vertical, -8)
            .padding(.top, 4 * scale)
    }

    /// Where the next turn goes: the back's contents, or home to the front.
    nonisolated static func title(flipped: Bool) -> String {
        flipped ? "BACK TO CATCH" : "ABOUT THIS PLANE"
    }
}

/// The full-width text control at the bottom of a card face — mono caps in
/// the card's label vocabulary, with a rotate glyph. VoiceOver reads it
/// as "About this plane, button"; the hit target is at least
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

    /// Inside a FlipCard: report which half was tapped (see `body`).
    @Environment(\.cardTurnDirection) private var noteTurnDirection
    @Environment(\.cardSwipeGuard) private var swipeGuard
    @State private var width: CGFloat = 0

    var body: some View {
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // A tap with a location instead of a Button, so the card turns the
        // way the tapped side would (2026-10-27): the side is reported to
        // the enclosing FlipCard first, then the action turns the card.
        .onTapGesture { location in
            guard swipeGuard?.swallowsTap != true else { return }
            noteTurnDirection?(CardFlipMath.tapDirection(x: location.x, width: width))
            action()
        }
        // What the Button gave VoiceOver: one element, a button, that acts.
        // "ABOUT THIS PLANE" → "About this plane": VoiceOver would otherwise
        // spell an all-caps label out or read it shouty.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(for: title))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }

    /// Sentence case for VoiceOver: "ABOUT THIS PLANE" → "About this plane".
    nonisolated static func accessibilityLabel(for title: String) -> String {
        let lower = title.lowercased()
        guard let first = lower.first else { return title }
        return first.uppercased() + lower.dropFirst()
    }
}
