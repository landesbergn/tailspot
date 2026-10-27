//
//  CardBackStyleRealFlip.swift
//  Tailspot
//
//  Card-back style "Real card flip" (design experiment, 2026-10-26; see
//  `CardBackStyles.swift`). Same two faces and the same 3D turn as the
//  shipped `FlipCard`, but dressed up to feel like turning over a physical
//  trading card:
//   - THICKNESS: the card is a slab ~4.5 pt thick. Edge-on you see a solid
//     edge (dark rims, a lighter card-stock core) instead of nothing.
//   - LIFT: the card rises off the table while it turns — it scales up ~5%
//     and its shadow grows, softens and slides away — then settles.
//   - LIGHT: a specular glare band sweeps across the face and the face
//     darkens as it tilts away from you.
//   - YOUR FINGER: a horizontal drag turns the card under the finger; let go
//     and it springs to whichever side it's past (or the side a flick was
//     heading to), with a light haptic when it commits.
//
//  Explain-as-we-go — how the thickness is faked:
//   - SwiftUI has no real 3D, only `rotation3DEffect`, which draws a FLAT
//     view as if it were a plate rotated in 3D. A plate has no thickness,
//     and exactly edge-on (90°) it draws nothing at all.
//   - So the card is a stack of plates: the front face in front, the back
//     face behind, and a few card-shaped "slices" in between (`RealFlipSlab`).
//     All of them rotate by the same angle; each is then shifted sideways by
//     `depth × sin(angle)` — where a point that far in front of the pivot
//     ends up after the turn. At rest the shift is 0 and the slices hide
//     under the face; mid-turn they peek out past the face's near edge as a
//     striped edge, which is what a real card's edge looks like.
//   - Positive angles bring the card's LEFT edge toward you (measured with
//     ImageRenderer, 2026-10-26), which is the convention the sideways shift
//     formula assumes (x' = x·cos θ + z·sin θ).
//   - The slices never render at exactly 90° (they'd vanish); they're nudged
//     0.8° off, which draws a sliver about as wide as the card is thick.
//
//  The faces still switch at exactly 90° via an `Animatable` modifier, as in
//  `FlipCard` (see the long comment at the top of CardFlip.swift).
//
//  Second pass (Noah, 2026-10-26: "looks identical to shipped"). The turn
//  was more physical, but at rest it was the same flat card, and the turn
//  is over in half a second. What now sets it apart:
//   - IT'S IN YOUR HAND: the card tilts a few degrees as you tilt the phone
//     (CoreMotion gravity, `CardTilt` below), and a glossy sheen slides
//     across it as it does, like a foil trading card catching the light.
//   - IT HAS AN EDGE AT REST: a sliver of card stock shows under the bottom
//     edge, shifting with the tilt, so it reads as a thick card lying on
//     the table, not a picture.
//   - A BIGGER TURN: the card rises twice as far (10%), tips toward you as
//     it lifts, and takes a little longer to come down.
//
//  Reduce Motion: no rotation, lift, tilt or glare — the faces crossfade,
//  and a horizontal swipe still turns the card over.
//

import SwiftUI
import CoreMotion
import os

// MARK: - Pure math (unit-tested)

/// The real flip's pure decisions: angles, drag → angle, release → side, and
/// the lift / shadow / glare curves. `nonisolated` — plain math, no UI state.
///
/// Angles are in degrees and are NOT wrapped: the front rests at any
/// multiple of 360, the back at 180 + any multiple of 360, so a card turned
/// over twice in the same direction sits at 360 rather than spinning back.
nonisolated enum RealFlipMath {
    /// Whether a drag is ours (a clearly horizontal turn) or someone else's.
    enum DragIntent: Equatable, Sendable { case turn, ignore }

    /// Card thickness in points. Real trading cards are ~0.3 mm; this is
    /// exaggerated so the edge reads on a phone.
    static let thickness: CGFloat = 6
    /// How many slices make up the edge between the two faces.
    static let sliceCount = 7
    /// `rotation3DEffect` perspective; a touch stronger than FlipCard's 0.45
    /// so the near edge visibly swells.
    static let perspective: CGFloat = 0.5
    /// Extra scale at full lift (edge-on): 10%.
    static let liftScale: CGFloat = 0.10
    /// How far the card tips toward you (about its horizontal axis) at full
    /// lift, so the turn isn't a flat spin in one plane.
    static let liftTipDegrees: Double = 9
    /// The resting edge under the card: how far it shows below the bottom
    /// edge, and how far it shifts per degree of tilt.
    static let restEdgeDepth: CGFloat = 4
    static let restEdgeShiftPerDegree: CGFloat = 0.45
    /// Lift while a finger holds the card, before it has turned at all — the
    /// card "picks up" as soon as the drag starts.
    static let holdLift: Double = 0.3
    /// Drags starting this close to the card's leading edge are left alone,
    /// so the screen's edge swipe-back keeps working.
    static let leadingEdgeGuard: CGFloat = 24
    /// A drag is a turn only when it is this many times wider than tall.
    static let horizontalDominance: CGFloat = 1.5
    /// Past a half turn the card resists: each extra point of drag turns it a
    /// quarter as much.
    static let rubberBand: Double = 0.25
    /// The slices stay at least this far from edge-on (see header).
    static let slabEdgeOnNudge: Double = 0.8
    /// Peak opacity of the glare band (reached at 45° of tilt).
    static let glarePeak: Double = 0.38
    /// The resting sheen: always a faint gloss, brighter as the phone tilts.
    static let sheenBase: Double = 0.07
    static let sheenTiltBoost: Double = 0.16
    /// How dark the face gets edge-on (black overlay opacity).
    static let shadePeak: Double = 0.45

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }

    /// `degrees` wrapped into [-180, 180).
    static func wrapped(_ degrees: Double) -> Double {
        var a = (degrees + 180).truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        return a - 180
    }

    /// A face's tilt away from the viewer, in [-180, 180): 0 = facing you,
    /// ±90 = edge-on. The back is pre-rotated by 180°, as in FlipCard.
    static func localAngle(angle: Double, isBack: Bool) -> Double {
        wrapped(isBack ? angle - 180 : angle)
    }

    /// The resting angle for `showingBack` closest to `near` — so a turn
    /// takes the short way round. On a tie (from the other side's rest) it
    /// turns forward (+180), so taps always turn the card the same way.
    static func restingAngle(showingBack: Bool, near: Double) -> Double {
        let base: Double = showingBack ? 180 : 0
        let lower = base + 360 * ((near - base) / 360).rounded(.down)
        let upper = lower + 360
        return (upper - near) <= (near - lower) ? upper : lower
    }

    /// The angle under the finger: a drag across the card's full width turns
    /// it half a turn (180°), in the drag's direction. Beyond a half turn
    /// from `start` it rubber-bands.
    static func dragAngle(start: Double, translation: CGFloat, cardWidth: CGFloat) -> Double {
        let width = max(Double(cardWidth), 1)
        let raw = 180 * Double(translation) / width
        let magnitude = abs(raw)
        let banded = magnitude <= 180 ? magnitude : 180 + (magnitude - 180) * rubberBand
        return start + (raw < 0 ? -banded : banded)
    }

    /// Where the card comes to rest after a drag that began at `start` (a
    /// resting angle) and is heading for `projected` (the angle at the drag's
    /// predicted end, so a flick counts). Past a quarter turn it completes
    /// the half turn in that direction; otherwise it falls back to `start`.
    static func settleAngle(start: Double, projected: Double) -> Double {
        let delta = min(180, max(-180, projected - start))
        guard abs(delta) >= 90 else { return start }
        return start + (delta < 0 ? -180 : 180)
    }

    /// Classifies a drag on its first update. Only a clearly horizontal drag
    /// that doesn't start on the leading-edge strip turns the card; anything
    /// else belongs to the scroll view or the swipe-back.
    static func dragIntent(translation: CGSize, startX: CGFloat) -> DragIntent {
        guard startX >= leadingEdgeGuard else { return .ignore }
        let dx = abs(translation.width), dy = abs(translation.height)
        return dx > dy * horizontalDominance ? .turn : .ignore
    }

    /// How far off the table the card is, 0…1: |sin| of the angle (1
    /// edge-on), but at least `holdLift × hold` while a finger is on it.
    static func lift(angle: Double, hold: Double) -> Double {
        let turning = abs(sin(radians(angle)))
        return min(1, max(turning, holdLift * min(1, max(0, hold))))
    }

    struct Shadow: Equatable, Sendable {
        var opacity: Double
        var radius: CGFloat
        var x: CGFloat
        var y: CGFloat
    }

    /// The shadow under the card. Resting: tight and close. Lifted: bigger,
    /// softer, fainter, dropped further, and pushed sideways away from the
    /// edge coming up toward you.
    static func shadow(angle: Double, lift: Double) -> Shadow {
        let l = min(1, max(0, lift))
        return Shadow(opacity: 0.45 - 0.15 * l,
                      radius: CGFloat(4 + 20 * l),
                      x: CGFloat(-14 * sin(radians(angle)) * l),
                      y: CGFloat(3 + 15 * l))
    }

    /// The glare band for a face tilted `localAngle`: where it sits across
    /// the face (0 = left edge, 1 = right edge; it slides right → left as the
    /// card turns forward) and how bright it is (0 facing you and edge-on,
    /// peak at 45°).
    static func glare(localAngle: Double) -> (center: Double, opacity: Double) {
        let a = min(90, max(-90, localAngle))
        let center = 0.5 - 0.6 * a / 90
        let opacity = glarePeak * max(0, sin(radians(2 * abs(a))))
        return (center, opacity)
    }

    /// The face's darkening as it tilts away from the light (0 facing you,
    /// `shadePeak` edge-on).
    static func shade(localAngle: Double) -> Double {
        shadePeak * (1 - max(0, cos(radians(localAngle))))
    }

    /// Sideways shift of a plate `depth` points in front of the card's
    /// centre plane, at `angle` (see header).
    static func depthOffset(depth: CGFloat, angle: Double) -> CGFloat {
        depth * CGFloat(sin(radians(angle)))
    }

    /// The face's own sideways shift: each face sits half the thickness in
    /// front of the centre plane in its own (pre-rotated) frame.
    static func faceOffset(angle: Double, isBack: Bool, thickness: CGFloat = thickness) -> CGFloat {
        depthOffset(depth: thickness / 2, angle: isBack ? angle - 180 : angle)
    }

    /// The slices' depths (front-face side positive), evenly spaced strictly
    /// between the two faces and sorted back-to-front for the current angle
    /// — SwiftUI draws in order with no depth buffer, so the nearest slice
    /// must be drawn last.
    static func sliceDepths(angle: Double, count: Int = sliceCount,
                            thickness: CGFloat = thickness) -> [CGFloat] {
        guard count > 0 else { return [] }
        let depths = (0..<count).map { i in
            -thickness / 2 + thickness * (CGFloat(i) + 0.5) / CGFloat(count)
        }
        let toward = cos(radians(angle))
        return depths.sorted { Double($0) * toward < Double($1) * toward }
    }

    /// Whether a slice at `depth` is card-stock core (lighter) or rim.
    static func isCore(depth: CGFloat, thickness: CGFloat = thickness) -> Bool {
        abs(depth) < thickness * 0.3
    }

    /// Whether the edge shows at all (it hides under the face at rest).
    static func slabVisible(angle: Double) -> Bool {
        abs(sin(radians(angle))) > 0.01
    }

    /// The slices' rotation: `angle`, but never within `slabEdgeOnNudge` of
    /// edge-on, where a flat plate draws nothing.
    static func slabAngle(_ angle: Double) -> Double {
        // How far past the last edge-on pose (90 + 180k) the angle is.
        var r = (angle - 90).truncatingRemainder(dividingBy: 180)
        if r < 0 { r += 180 }                           // r in [0, 180)
        if r < slabEdgeOnNudge { return angle + (slabEdgeOnNudge - r) }
        if r > 180 - slabEdgeOnNudge { return angle - (slabEdgeOnNudge - (180 - r)) }
        return angle
    }

    /// The edge's brightness adjustment: brightest edge-on, when it faces
    /// you and catches the light; a little dimmer when seen obliquely.
    static func edgeBrightness(angle: Double) -> Double {
        -0.12 + 0.16 * abs(sin(radians(angle)))
    }

    /// The resting sheen for a hand tilt of (`tiltX`, `tiltY`) degrees: where
    /// its diagonal band crosses the face (0 = left, 1 = right; tilting the
    /// card's right edge away slides it left) and how bright it is.
    static func sheen(tiltX: Double, tiltY: Double) -> (center: Double, opacity: Double) {
        let maxTilt = CardTiltMath.maxDegrees
        let x = min(1, max(-1, tiltY / maxTilt))
        let y = min(1, max(-1, tiltX / maxTilt))
        let center = 0.5 - 0.55 * x + 0.2 * y
        let amount = min(1, (x * x + y * y).squareRoot())
        return (center, sheenBase + sheenTiltBoost * amount)
    }

    /// The resting edge's offset under the card for a hand tilt: always
    /// `restEdgeDepth` down, and shifted toward the side tilted away.
    static func restEdgeOffset(tiltX: Double, tiltY: Double) -> CGSize {
        CGSize(width: -CGFloat(tiltY) * restEdgeShiftPerDegree,
               height: restEdgeDepth + CGFloat(max(0, tiltX)) * restEdgeShiftPerDegree)
    }

    /// Reduce Motion crossfade: a face's opacity at `angle`. A smooth
    /// dissolve on (1 − cos)/2, so it works for any resting angle.
    static func crossfadeOpacity(angle: Double, isBack: Bool) -> Double {
        let back = (1 - cos(radians(angle))) / 2
        return isBack ? back : 1 - back
    }
}

// MARK: - RealisticFlipCard

struct RealisticFlipCard<Front: View, Back: View>: View {
    @Binding var showingBack: Bool
    private let front: Front
    private let back: Back

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The card's current angle (degrees, unwrapped). Animated with
    /// `withAnimation` for taps / programmatic turns; set directly while a
    /// finger drags it.
    @State private var angle: Double
    /// 1 while a finger holds the card (animates the "pick up" lift).
    @State private var hold: Double = 0
    /// The front's measured size. The back and the edge slices are laid out
    /// at exactly this size.
    @State private var frontSize: CGSize = .zero
    /// The resting angle a turn-drag started from; nil when not dragging.
    @State private var dragStartAngle: Double?
    /// The current drag's classification, made on its first update.
    @State private var dragIntent: RealFlipMath.DragIntent?
    /// `@GestureState` resets to its initial value by itself when a gesture
    /// ends OR is cancelled (e.g. the scroll view takes over). `onEnded`
    /// doesn't run on cancel, so this is how a half-turned card notices it
    /// was dropped.
    @GestureState private var gestureActive = false
    /// The hand tilt from CoreMotion. `@Observable`, so only this view
    /// re-renders as it changes — the faces' own bodies don't re-run.
    @State private var tilt = CardTilt()

    #if DEBUG
    /// Test hook: render a frozen frame at this angle. See `_snapshotAngle(_:)`.
    fileprivate var snapshotAngle: Double? = nil
    #endif

    init(showingBack: Binding<Bool>,
         @ViewBuilder front: () -> Front, @ViewBuilder back: () -> Back) {
        self._showingBack = showingBack
        // `State(initialValue:)` seeds @State from an init argument; after the
        // first render SwiftUI owns the value and ignores this.
        self._angle = State(initialValue: showingBack.wrappedValue ? 180 : 0)
        self.front = front()
        self.back = back()
    }

    private var renderAngle: Double {
        #if DEBUG
        if let snapshotAngle { return snapshotAngle }
        #endif
        return angle
    }

    private var renderHold: Double {
        #if DEBUG
        if snapshotAngle != nil { return 0 }
        #endif
        return hold
    }

    private var turnAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.8, bounce: 0.18)
    }

    /// The hand tilt to draw (degrees); none under Reduce Motion or in a
    /// frozen snapshot frame.
    private var renderTilt: (x: Double, y: Double) {
        #if DEBUG
        if snapshotAngle != nil { return (0, 0) }
        #endif
        return reduceMotion ? (0, 0) : (tilt.x, tilt.y)
    }

    var body: some View {
        let hand = renderTilt
        // The hand's side-to-side tilt simply adds to the turn angle, so the
        // edge, the shading and the glare all respond to it for free.
        let angle = renderAngle + hand.y
        ZStack {
            if frontSize.width > 0, frontSize.height > 0, !reduceMotion {
                Color.clear
                    .frame(width: frontSize.width, height: frontSize.height)
                    .modifier(RealFlipSlab(angle: angle))
            }

            front
                .onGeometryChange(for: CGSize.self) { $0.size } action: { frontSize = $0 }
                // Before the face modifier, so the sheen turns with the face.
                .overlay { if !reduceMotion { RealFlipSheen(tiltX: hand.x, tiltY: hand.y) } }
                .modifier(RealFlipFace(angle: angle, isBack: false, reduceMotion: reduceMotion))

            // Not laid out until the front has been measured — otherwise a
            // back that fills its proposal would size the ZStack to it.
            if frontSize.width > 0, frontSize.height > 0 {
                back
                    .frame(width: frontSize.width, height: frontSize.height)
                    .overlay { if !reduceMotion { RealFlipSheen(tiltX: hand.x, tiltY: hand.y) } }
                    .modifier(RealFlipFace(angle: angle, isBack: true, reduceMotion: reduceMotion))
            }
        }
        .modifier(RealFlipLift(angle: angle, hold: renderHold, tiltX: hand.x, tiltY: hand.y,
                               reduceMotion: reduceMotion))
        // Draw above the screen's later siblings, so the lifted card and its
        // shadow pass over them rather than under.
        .zIndex(1)
        // `simultaneousGesture`: the drag runs ALONGSIDE the scroll view's
        // pan and the faces' buttons instead of competing with them. A tap
        // never travels 12 pt, so buttons and photo taps are untouched; a
        // vertical drag is classified `.ignore` on its first update and left
        // to the scroll view.
        .simultaneousGesture(turnGesture)
        .onChange(of: showingBack) { _, back in
            // Taps on the faces' buttons and any other binding change animate
            // the full turn. During a drag the drag owns the angle.
            guard dragStartAngle == nil else { return }
            let target = RealFlipMath.restingAngle(showingBack: back, near: self.angle)
            guard target != self.angle else { return }
            withAnimation(turnAnimation) { self.angle = target }
        }
        .onChange(of: gestureActive) { _, active in
            guard !active else { return }
            // Let `onEnded` (which normally runs around now) go first; if the
            // drag is still open afterwards it was cancelled — settle it.
            Task { @MainActor in
                await Task.yield()
                if dragStartAngle != nil { finishDrag(projected: self.angle) }
                dragIntent = nil
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: showingBack)
        .onAppear { if !reduceMotion { tilt.start() } }
        .onDisappear { tilt.stop() }
    }

    // MARK: Drag

    private var turnGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($gestureActive) { _, active, _ in active = true }
            .onChanged { value in dragChanged(value) }
            .onEnded { value in dragEnded(value) }
    }

    private func dragChanged(_ value: DragGesture.Value) {
        if dragIntent == nil {
            dragIntent = RealFlipMath.dragIntent(translation: value.translation,
                                                 startX: value.startLocation.x)
            guard dragIntent == .turn, !reduceMotion else { return }
            // Start from the resting angle the card is heading to, so grabbing
            // it mid-animation doesn't jump.
            dragStartAngle = RealFlipMath.restingAngle(showingBack: showingBack, near: angle)
            withAnimation(.spring(duration: 0.25)) { hold = 1 }
        }
        guard dragIntent == .turn, let start = dragStartAngle else { return }
        // No animation: the card tracks the finger 1:1.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            angle = RealFlipMath.dragAngle(start: start,
                                           translation: value.translation.width,
                                           cardWidth: frontSize.width)
        }
    }

    private func dragEnded(_ value: DragGesture.Value) {
        defer { dragIntent = nil }
        guard dragIntent == .turn else { return }
        if reduceMotion {
            // No finger-tracking under Reduce Motion: a swipe just turns it.
            if CardFlipMath.swipeDirection(translation: value.translation) != nil {
                showingBack.toggle()
            }
            return
        }
        guard let start = dragStartAngle else { return }
        // `predictedEndTranslation` is where SwiftUI thinks the finger would
        // have stopped given its speed — a quick flick projects past 90°
        // even if the finger itself only moved a little.
        let projected = RealFlipMath.dragAngle(start: start,
                                               translation: value.predictedEndTranslation.width,
                                               cardWidth: frontSize.width)
        finishDrag(projected: projected)
    }

    /// Springs the card to its resting side and commits the binding.
    private func finishDrag(projected: Double) {
        guard let start = dragStartAngle else { return }
        let rest = RealFlipMath.settleAngle(start: start, projected: projected)
        let back = CardFlipMath.visibleFace(angle: rest) == .back
        dragStartAngle = nil
        withAnimation(.spring(duration: 0.55, bounce: 0.2)) {
            angle = rest
            hold = 0
        }
        if back != showingBack {
            Log.ui.debug("Real card flip: drag turned the card to the \(back ? "back" : "front", privacy: .public)")
            showingBack = back
        }
    }
}

#if DEBUG
extension RealisticFlipCard {
    /// Freeze the card at `degrees` (0 = front, 90 = edge-on, 180 = back) —
    /// for snapshot tests rendering mid-turn frames. nil = normal behaviour.
    func _snapshotAngle(_ degrees: Double?) -> RealisticFlipCard {
        var copy = self
        copy.snapshotAngle = degrees
        return copy
    }
}
#endif

// MARK: - Face

/// One face's share of the turn: rotation, sideways depth shift, glare and
/// shading, and whether it's the face showing at the current (animating)
/// angle. `Animatable`, so SwiftUI re-runs `body` every frame with the
/// in-between angle and the face switch lands exactly at 90°.
private struct RealFlipFace: ViewModifier, Animatable {
    var angle: Double
    let isBack: Bool
    let reduceMotion: Bool

    nonisolated var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        let me: CardFlipMath.Face = isBack ? .back : .front
        let shown = CardFlipMath.visibleFace(angle: angle) == me
        if reduceMotion {
            content
                .opacity(RealFlipMath.crossfadeOpacity(angle: angle, isBack: isBack))
                .accessibilityHidden(!shown)
                .allowsHitTesting(shown)
        } else {
            let local = RealFlipMath.localAngle(angle: angle, isBack: isBack)
            content
                .overlay { RealFlipLight(localAngle: local) }
                .rotation3DEffect(.degrees(isBack ? angle - 180 : angle),
                                  axis: (x: 0, y: 1, z: 0),
                                  perspective: RealFlipMath.perspective)
                .offset(x: RealFlipMath.faceOffset(angle: angle, isBack: isBack))
                .opacity(shown ? 1 : 0)
                .accessibilityHidden(!shown)
                .allowsHitTesting(shown)
        }
    }
}

/// The light on a face: a darkening as it tilts away, and a diagonal
/// specular band that slides across it. Clipped to the card's hero radius,
/// never interactive or read by VoiceOver.
private struct RealFlipLight: View {
    let localAngle: Double

    var body: some View {
        let glare = RealFlipMath.glare(localAngle: localAngle)
        // The band is ~0.5 of the face wide; the gradient's end points move
        // with `center`, and beyond them it stays clear.
        let halfWidth = 0.25
        ZStack {
            Color.black.opacity(RealFlipMath.shade(localAngle: localAngle))
            LinearGradient(colors: [.white.opacity(0), .white, .white.opacity(0)],
                           startPoint: UnitPoint(x: glare.center - halfWidth - 0.15, y: 0),
                           endPoint: UnitPoint(x: glare.center + halfWidth + 0.15, y: 1))
                .opacity(glare.opacity)
                // `.plusLighter` ADDS the light to what's below, like a real
                // highlight, instead of painting a white veil over it.
                .blendMode(.plusLighter)
        }
        .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.hero))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Edge

/// The card's thickness: card-shaped slices between the two faces, each
/// rotated with the card and shifted sideways by its depth (see header).
/// Hidden at rest, a striped edge mid-turn, a solid edge when edge-on.
private struct RealFlipSlab: ViewModifier, Animatable {
    var angle: Double

    nonisolated var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        content.overlay {
            if RealFlipMath.slabVisible(angle: angle) {
                let rotation = RealFlipMath.slabAngle(angle)
                let depths = RealFlipMath.sliceDepths(angle: angle)
                ZStack {
                    // `id: \.offset` — the slices are re-sorted as the card
                    // turns, so identity follows the draw position, not the
                    // depth; they're plain shapes with no state to keep.
                    ForEach(Array(depths.enumerated()), id: \.offset) { slice in
                        let depth = slice.element
                        RoundedRectangle(cornerRadius: Brand.Radius.hero)
                            .fill(RealFlipMath.isCore(depth: depth) ? RP.flapUnsettled : RP.rule)
                            .rotation3DEffect(.degrees(rotation),
                                              axis: (x: 0, y: 1, z: 0),
                                              perspective: RealFlipMath.perspective)
                            .offset(x: RealFlipMath.depthOffset(depth: depth, angle: angle))
                    }
                }
                .brightness(RealFlipMath.edgeBrightness(angle: angle))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Lift

/// Lifts the whole card off the table: scale up and a growing, softening,
/// sliding shadow. Animates both the angle and the finger's hold.
private struct RealFlipLift: ViewModifier, Animatable {
    var angle: Double
    var hold: Double
    let tiltX: Double
    let tiltY: Double
    let reduceMotion: Bool

    /// `AnimatablePair` lets one modifier animate two numbers at once.
    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(angle, hold) }
        set { angle = newValue.first; hold = newValue.second }
    }

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            let lift = RealFlipMath.lift(angle: angle, hold: hold)
            let shadow = RealFlipMath.shadow(angle: angle, lift: lift)
            let edge = RealFlipMath.restEdgeOffset(tiltX: tiltX, tiltY: tiltY)
            content
                // The resting edge: a card-stock sliver peeking out under the
                // bottom edge. It doesn't turn with the card, so it fades out
                // as soon as the card leaves the table.
                .background {
                    RoundedRectangle(cornerRadius: Brand.Radius.hero)
                        .fill(RP.flapUnsettled)
                        .overlay(RoundedRectangle(cornerRadius: Brand.Radius.hero)
                            .strokeBorder(RP.rule, lineWidth: 1))
                        .offset(edge)
                        .opacity(1 - min(1, lift * 3))
                        .accessibilityHidden(true)
                }
                // Flatten the stack into one layer first, so the shadow is
                // cast by the card's outline — without it, `.shadow` on a
                // container shadows every subview separately.
                .compositingGroup()
                .shadow(color: .black.opacity(shadow.opacity),
                        radius: shadow.radius, x: shadow.x, y: shadow.y)
                .scaleEffect(1 + RealFlipMath.liftScale * CGFloat(lift))
                // Tip toward you as it lifts, plus the hand's forward tilt.
                .rotation3DEffect(.degrees(tiltX + RealFlipMath.liftTipDegrees * lift),
                                  axis: (x: 1, y: 0, z: 0),
                                  perspective: RealFlipMath.perspective)
        }
    }
}

// MARK: - Sheen

/// The resting gloss on each face: a soft diagonal band that slides
/// across as the phone tilts. Independent of the turn's own glare, which
/// only shows mid-turn.
private struct RealFlipSheen: View {
    let tiltX: Double
    let tiltY: Double

    var body: some View {
        let sheen = RealFlipMath.sheen(tiltX: tiltX, tiltY: tiltY)
        LinearGradient(colors: [.white.opacity(0), .white, .white.opacity(0)],
                       startPoint: UnitPoint(x: sheen.center - 0.35, y: 0),
                       endPoint: UnitPoint(x: sheen.center + 0.35, y: 1))
            .opacity(sheen.opacity)
            .blendMode(.plusLighter)
            .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.hero))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Hand tilt

/// Turns the phone's tilt into a small card tilt. The card follows CHANGES
/// in how you hold the phone and drifts back to flat over about a second,
/// so it looks level however you happen to hold it. `nonisolated` — plain
/// math, unit-tested.
nonisolated enum CardTiltMath {
    /// The card never tilts further than this either way (degrees).
    static let maxDegrees: Double = 8
    /// Degrees of card tilt per unit of gravity change (1 g ≈ 90° of phone
    /// tilt, so ~0.18 g, about 16° of phone tilt, reaches the maximum).
    static let gain: Double = 45
    /// How much of the gap to the current reading the baseline closes each
    /// sample: at 60 Hz, 0.03 settles in about a second.
    static let baselineRate: Double = 0.03

    struct State: Equatable, Sendable {
        var baselineX: Double? = nil
        var baselineY: Double? = nil
        /// Card tilt about its horizontal axis (top edge away = positive).
        var x: Double = 0
        /// Card tilt about its vertical axis (a positive angle brings the
        /// card's left edge toward you, matching `RealFlipMath`).
        var y: Double = 0
    }

    /// One gravity sample (device frame, in g) folded into the state.
    static func step(_ state: State, gravityX gx: Double, gravityY gy: Double) -> State {
        var next = state
        let bx = state.baselineX ?? gx
        let by = state.baselineY ?? gy
        next.baselineX = bx + (gx - bx) * baselineRate
        next.baselineY = by + (gy - by) * baselineRate
        // Tilting the phone's right side down (gravity x grows) should bring
        // the card's right edge toward you: a negative y angle.
        next.y = clamp(-(gx - bx) * gain)
        // Tilting the phone's top away (gravity y falls toward −1) should
        // tip the card's top away too.
        next.x = clamp(-(gy - by) * gain)
        return next
    }

    static func clamp(_ d: Double) -> Double { min(maxDegrees, max(-maxDegrees, d)) }
}

/// The live hand tilt for the real flip: CoreMotion gravity at 60 Hz, folded
/// through `CardTiltMath`. `@Observable` so a view reading `x`/`y` re-renders
/// only itself when they change. Device motion needs no permission prompt.
@Observable
final class CardTilt {
    private(set) var x: Double = 0
    private(set) var y: Double = 0
    @ObservationIgnored private var state = CardTiltMath.State()
    @ObservationIgnored private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        // Delivered on the main queue, where this (MainActor) class lives —
        // one tiny update per frame, nothing heavy.
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let next = CardTiltMath.step(self.state, gravityX: motion.gravity.x,
                                         gravityY: motion.gravity.y)
            self.state = next
            // Skip sub-0.05° jitter so a phone lying still doesn't re-render.
            if abs(next.x - self.x) > 0.05 || abs(next.y - self.y) > 0.05 {
                self.x = next.x
                self.y = next.y
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        state = CardTiltMath.State()
        x = 0
        y = 0
    }
}
