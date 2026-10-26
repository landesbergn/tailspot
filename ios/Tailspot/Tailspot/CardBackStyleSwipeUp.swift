//
//  CardBackStyleSwipeUp.swift
//  Tailspot
//
//  Card-back style "Swipe up" (design experiment, 2026-10-26; see
//  CardBackStyles.swift). The back is a second card tucked UNDER the catch
//  card, its top peeking out below the front's bottom edge as a tab that
//  reads "ABOUT THIS PLANE". Drag that tab up (or tap it) and the back
//  slides up over the catch card, which recedes and dims; drag the back's
//  grabber down (or hit BACK TO CATCH) and it tucks away again.
//
//  Explain-as-we-go — how it works:
//   - One number drives everything: `progress`, 0 = tucked (tease showing),
//     1 = the back fully covers the front. While a finger is down it comes
//     from the drag; otherwise from `showingBack` (0 or 1).
//   - The back never takes part in layout. It's laid out at exactly the
//     front's measured size (like FlipCard) and MOVED with `.offset`, which
//     shifts where a view draws without changing the space it occupies. The
//     slot reserves the tease's height once with bottom padding, so pulling
//     the back up never makes the content below jump.
//   - Below the slot the tucked back must not draw over the fine print, so
//     it's `.mask`ed: only the part above the slot's bottom edge shows.
//   - Like FlipFace in CardFlip.swift, the per-layer modifiers conform to
//     `Animatable`: SwiftUI hands them every in-between progress during the
//     spring, so the back can stay ABOVE the front (zIndex) for the whole
//     ride down and only drop behind it once it has landed.
//   - The drag lives on the tease strip and the grabber only, never on the
//     whole card. A `.gesture(DragGesture)` wins over the enclosing
//     ScrollView for touches that START on it; everywhere else the screen
//     scrolls as usual.
//   - Reduce Motion: the drag doesn't track and nothing scales; a release
//     past a short threshold commits, and the back makes a quick eased slide.
//

import SwiftUI
import os

// MARK: - Pure decisions (unit-tested)

/// The pull-up's geometry and decisions, kept out of the view so tests can
/// pin them. `nonisolated` — plain math, no UI state.
nonisolated enum PullUpMath {
    /// How much of the back shows below the front at rest (the tab strip).
    static let teaseHeight: CGFloat = 64
    /// How far the back's top tucks UNDER the front at rest, so its
    /// rounded top corners hide behind the front like a stacked card.
    static let tuck: CGFloat = 14
    /// The tucked back is drawn slightly narrower — the second card in a
    /// stack — and grows to full size as it comes up.
    static let restBackScale: Double = 0.94
    /// The front at progress 1: shrunk a touch and dimmed, receding.
    static let recededFrontScale: Double = 0.96
    static let maxFrontDim: Double = 0.45
    /// A flick faster than this (pt/s) commits in its direction whatever
    /// the distance travelled.
    static let flickVelocity: CGFloat = 500
    /// Reduce Motion (no tracking): a release must have travelled this far.
    static let reduceMotionThreshold: CGFloat = 30

    static func clamp(_ p: Double) -> Double { min(1, max(0, p)) }

    /// The back's top edge (in the front's coordinates) when tucked.
    static func restTop(frontHeight: CGFloat) -> CGFloat {
        max(0, frontHeight - tuck)
    }

    /// The back's top edge at `progress`: `restTop` at 0, the front's top
    /// (0) at 1. Not clamped, so a spring's overshoot reads as overshoot.
    static func backTop(progress: Double, frontHeight: CGFloat) -> CGFloat {
        restTop(frontHeight: frontHeight) * CGFloat(1 - progress)
    }

    /// The slot's full height: the front plus the reserved tease.
    static func slotHeight(frontHeight: CGFloat) -> CGFloat {
        frontHeight + teaseHeight
    }

    /// How much of the back (from its top) may draw: everything above the
    /// slot's bottom edge, so a tucked back never covers what's below.
    static func visibleHeight(progress: Double, frontHeight: CGFloat) -> CGFloat {
        max(0, slotHeight(frontHeight: frontHeight) - backTop(progress: progress, frontHeight: frontHeight))
    }

    /// Progress while dragging: where the gesture started (shown or not)
    /// minus the drag (up is negative y, so up raises progress), as a
    /// fraction of the travel, clamped to 0…1.
    static func progress(startShown: Bool, translationY: CGFloat, frontHeight: CGFloat) -> Double {
        let base: Double = startShown ? 1 : 0
        let travel = restTop(frontHeight: frontHeight)
        guard travel > 0 else { return base }
        return clamp(base - Double(translationY / travel))
    }

    /// Where a release lands: a flick commits in its direction (up = show);
    /// otherwise past halfway shows, short of it tucks.
    static func shouldShow(startShown: Bool, translationY: CGFloat,
                           velocityY: CGFloat, frontHeight: CGFloat) -> Bool {
        if abs(velocityY) >= flickVelocity { return velocityY < 0 }
        return progress(startShown: startShown, translationY: translationY,
                        frontHeight: frontHeight) >= 0.5
    }

    /// Reduce Motion release: direction past a short threshold, else stay.
    static func reduceMotionShouldShow(startShown: Bool, translationY: CGFloat) -> Bool {
        if translationY <= -reduceMotionThreshold { return true }
        if translationY >= reduceMotionThreshold { return false }
        return startShown
    }

    static func frontScale(progress: Double) -> Double {
        1 - (1 - recededFrontScale) * clamp(progress)
    }

    static func frontDim(progress: Double) -> Double {
        maxFrontDim * clamp(progress)
    }

    static func backScale(progress: Double) -> Double {
        restBackScale + (1 - restBackScale) * clamp(progress)
    }

    /// The back is drawn above the front as soon as it starts moving and
    /// until it has fully landed back in its tuck.
    static func backIsAboveFront(progress: Double) -> Bool {
        progress > 0.001
    }

    /// The tab strip fades out over the first third of the pull.
    static func stripOpacity(progress: Double) -> Double {
        clamp(1 - progress * 3)
    }

    /// The shown back's grabber fades in over the last third.
    static func grabberOpacity(progress: Double) -> Double {
        clamp((progress - 2.0 / 3.0) * 3)
    }
}

// MARK: - PullUpCard

struct PullUpCard<Front: View, Back: View>: View {
    @Binding var showingBack: Bool
    private let front: Front
    private let back: Back

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The front's measured size; the back is laid out at exactly this.
    @State private var frontSize: CGSize = .zero
    /// The live drag's vertical translation, nil when no finger is down.
    @State private var dragY: CGFloat? = nil
    /// True only while the drag gesture is active. `@GestureState` resets
    /// itself when a gesture ends OR is cancelled (e.g. the scroll view
    /// takes the touch), which `onEnded` alone wouldn't tell us.
    @GestureState private var isDragging = false

    init(showingBack: Binding<Bool>,
         @ViewBuilder front: () -> Front, @ViewBuilder back: () -> Back) {
        self._showingBack = showingBack
        self.front = front()
        self.back = back()
    }

    private var progress: Double {
        guard let dragY else { return showingBack ? 1 : 0 }
        return PullUpMath.progress(startShown: showingBack, translationY: dragY,
                                   frontHeight: frontSize.height)
    }

    /// Spring for the pull; a short ease for Reduce Motion.
    private var settleAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.15)
    }

    var body: some View {
        let p = progress
        ZStack(alignment: .top) {
            front
                .onGeometryChange(for: CGSize.self) { $0.size } action: { frontSize = $0 }
                .modifier(PullUpFrontLayer(progress: p, reduceMotion: reduceMotion))
                .accessibilityHidden(showingBack)
                .allowsHitTesting(!showingBack)

            // Not laid out until the front has been measured — otherwise a
            // back that fills its proposal would size the ZStack to it.
            if frontSize.width > 0, frontSize.height > 0 {
                backLayer(progress: p)
                    .modifier(PullUpBackLayer(progress: p, frontSize: frontSize,
                                              reduceMotion: reduceMotion))
            }
        }
        // Reserve the tease once, so the slot never changes height.
        .padding(.bottom, PullUpMath.teaseHeight)
        // Programmatic changes (BACK TO CATCH, the caller) animate too.
        // `value: showingBack` scopes it so live drag updates don't lag.
        .animation(settleAnimation, value: showingBack)
        .sensoryFeedback(.impact(weight: .light), trigger: showingBack)
        .onChange(of: isDragging) { _, dragging in
            // A cancelled drag never reaches onEnded: settle where we were.
            if !dragging, dragY != nil {
                withAnimation(settleAnimation) { dragY = nil }
            }
        }
    }

    // MARK: Back layer

    private func backLayer(progress p: Double) -> some View {
        let scale = frontSize.width / 300
        return ZStack(alignment: .top) {
            back
                .frame(width: frontSize.width, height: frontSize.height)
                .accessibilityHidden(!showingBack)
                .allowsHitTesting(showingBack)

            teaseStrip(scale: scale)
                .opacity(PullUpMath.stripOpacity(progress: p))
                .allowsHitTesting(!showingBack)
                .accessibilityHidden(showingBack)

            grabber(scale: scale)
                .opacity(PullUpMath.grabberOpacity(progress: p))
                .allowsHitTesting(showingBack)
        }
    }

    /// The peeking tab: grabber pill + "ABOUT THIS PLANE" on the card's ink,
    /// covering the back's top so the tease reads as one quiet strip.
    private func teaseStrip(scale: CGFloat) -> some View {
        VStack(spacing: 9) {
            Capsule()
                .fill(RP.faint)
                .frame(width: 36, height: 5)
            HStack(spacing: 7 * scale) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11 * scale, weight: .semibold))
                Text("ABOUT THIS PLANE")
                    .font(.system(size: 11 * scale, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(RP.muted)
        }
        .frame(maxWidth: .infinity)
        .frame(height: PullUpMath.teaseHeight)
        .padding(.top, PullUpMath.tuck)
        // The fill runs a little past the strip: the tucked back is drawn
        // scaled down, so without the extra the photo would peek below it.
        .background(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: Brand.Radius.hero,
                                   topTrailingRadius: Brand.Radius.hero)
                .fill(RP.bg)
                .frame(height: PullUpMath.tuck + PullUpMath.teaseHeight + 24)
                .padding(.horizontal, 1)   // keep the frame's border visible
                .padding(.top, 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { commit(true) }
        .gesture(pullGesture)
        // One VoiceOver element that acts like a button.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("About this plane")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { commit(true) }
    }

    /// The shown back's handle: drag it down to tuck the back away. Sits in
    /// the back's top padding, above the closeup. VoiceOver uses BACK TO
    /// CATCH instead.
    private func grabber(scale: CGFloat) -> some View {
        Capsule()
            .fill(RP.faint)
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 18 * scale + 10)
            .contentShape(Rectangle())
            .gesture(pullGesture)
            .accessibilityHidden(true)
    }

    // MARK: Gesture

    /// `.global` coordinates: the strip moves under the finger as it drags,
    /// and a translation measured in its own (moving) space would feed back
    /// on itself and jitter.
    private var pullGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                guard !reduceMotion else { return }
                dragY = value.translation.height
            }
            .onEnded { value in
                let show = reduceMotion
                    ? PullUpMath.reduceMotionShouldShow(startShown: showingBack,
                                                        translationY: value.translation.height)
                    : PullUpMath.shouldShow(startShown: showingBack,
                                            translationY: value.translation.height,
                                            velocityY: value.velocity.height,
                                            frontHeight: frontSize.height)
                commit(show)
            }
    }

    private func commit(_ show: Bool) {
        if show != showingBack {
            Log.ui.debug("pull-up card: \(show ? "back shown" : "back tucked", privacy: .public)")
        }
        withAnimation(settleAnimation) {
            dragY = nil
            showingBack = show
        }
    }
}

// MARK: - Per-frame layers

/// The front's share: recede (scale) and dim as the back comes up.
/// `Animatable` so it follows the spring frame by frame, like FlipFace.
private struct PullUpFrontLayer: ViewModifier, Animatable {
    var progress: Double
    let reduceMotion: Bool

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: Brand.Radius.hero)
                    .fill(Color.black.opacity(PullUpMath.frontDim(progress: progress)))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .scaleEffect(reduceMotion ? 1 : PullUpMath.frontScale(progress: progress))
            .zIndex(0)
    }
}

/// The back's share: its position, the stacked-card scale, the mask that
/// keeps a tucked back inside the slot, and whether it draws above the front.
private struct PullUpBackLayer: ViewModifier, Animatable {
    var progress: Double
    let frontSize: CGSize
    let reduceMotion: Bool

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let height = frontSize.height
        content
            .frame(width: frontSize.width, height: height, alignment: .top)
            // Scale before masking/offsetting: the mask is measured in the
            // unscaled frame, so it always ends at the slot's bottom edge.
            .scaleEffect(reduceMotion ? 1 : PullUpMath.backScale(progress: progress),
                         anchor: .top)
            // Wider than the card so the frame's soft shadow isn't cut at
            // the sides; only the height matters.
            .mask(alignment: .top) {
                Rectangle()
                    .frame(width: frontSize.width + 40,
                           height: PullUpMath.visibleHeight(progress: progress, frontHeight: height))
            }
            .offset(y: PullUpMath.backTop(progress: progress, frontHeight: height))
            .zIndex(PullUpMath.backIsAboveFront(progress: progress) ? 1 : -1)
    }
}
