//
//  CardBackStyleSwipeLeft.swift
//  Tailspot
//
//  Card-back style "Swipe left" (design experiment, 2026-10-26; see
//  CardBackStyles.swift). The back is the NEXT card in a two-card carousel,
//  the same size as the catch card: at rest its left edge peeks in from the
//  right, dimmed, with a vertical "ABOUT THIS PLANE" tab on it. Swipe left
//  (or tap the peek) and it pages over and snaps into place; swipe right
//  (or BACK TO CATCH) to go back.
//
//  Second pass (Noah, 2026-10-26: "match the card sizes … each card kind of
//  clicks into place"): the off-to-the-side card no longer shrinks, and the
//  paging is the system's own instead of a hand-written rule.
//
//  Explain-as-we-go — how the carousel works:
//   - It's a real horizontal `ScrollView` nested inside the detail screen's
//     vertical one. UIKit (which SwiftUI's ScrollView is built on) locks a
//     drag to whichever scroll view's axis it starts along, so a vertical
//     drag on the card still scrolls the page and a sideways one pages the
//     carousel — no hand-written gesture arbitration.
//   - `.scrollTargetLayout()` marks each card as a place the scroll may stop,
//     and `.scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))`
//     makes a released swipe glide to the nearest card's leading edge, never
//     skipping one. The glide keeps the finger's speed and decelerates into
//     place, which is the "click" — the same physics as the Home Screen.
//   - `.scrollClipDisabled()` lets the cards draw outside the scroll view's
//     bounds, which is how the neighbour shows in the side gutter. Touches
//     don't reach content outside a scroll view's bounds, so tapping the
//     peek goes through a separate tab overlay.
//   - `.scrollTransition` re-styles each card from its position in the
//     scroll view every frame (phase value 0 = in place, ±1 = off to a side)
//     WITHOUT re-running this view's `body` — cheap, and it tracks the
//     finger exactly. It only dims now; nothing scales.
//   - `showingBack` is the source of truth both ways. A user swipe commits
//     when the scroll comes to rest on a page; a programmatic change scrolls
//     to the page. `page` remembers the last settled page so neither path
//     echoes the other.
//   - Reduce Motion: no gradual dim (the far card is simply dimmed or not),
//     and programmatic page changes jump without animation.
//

import SwiftUI
import os

// MARK: - Pure decisions (unit-tested)

/// The carousel's own numbers; page bookkeeping is `CardPagerMath`.
/// `nonisolated` — plain math, no UI state.
nonisolated enum SwipePeekMath {
    /// Space between the two cards. The peek visible on screen is the side
    /// gutter minus this.
    static let gap: CGFloat = 10
    /// Opacity of the card that's off to the side (it sits on the dark
    /// screen background, so lower opacity reads as dimmed).
    static let peekOpacity: Double = 0.55

    /// The card's opacity at a scroll-transition phase value (−1 … 1): 1 in
    /// place, `peekOpacity` off to the side. Reduce Motion: a step at half
    /// way instead of a ramp.
    static func opacity(progress: Double, reduceMotion: Bool) -> Double {
        let d = min(1, abs(progress))
        if reduceMotion { return d >= 0.5 ? peekOpacity : 1 }
        return 1 - (1 - peekOpacity) * d
    }
}

// MARK: - SwipePeekCard

struct SwipePeekCard<Front: View, Back: View>: View {
    @Binding var showingBack: Bool
    private let front: Front
    private let back: Back

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The front's measured size. The back is laid out at exactly this size
    /// so both cards are the same shape.
    @State private var frontSize: CGSize = .zero
    /// The side gutter between the carousel and the screen edge — the room
    /// the peek has to show in, and the width of the tap tabs.
    @State private var gutter: CGFloat = 0
    /// The page the scroll last came to rest on.
    @State private var page: CardPagerMath.Page
    /// The page the scroll is resting on right now; nil mid-swipe. Drives
    /// the peek tabs, which only show at rest.
    @State private var restingPage: CardPagerMath.Page?
    @State private var position = ScrollPosition()

    init(showingBack: Binding<Bool>,
         @ViewBuilder front: () -> Front, @ViewBuilder back: () -> Back) {
        self._showingBack = showingBack
        let initial = CardPagerMath.page(showingBack: showingBack.wrappedValue)
        self._page = State(initialValue: initial)
        self._restingPage = State(initialValue: initial)
        self.front = front()
        self.back = back()
    }

    /// One card width plus the gap: the scroll distance between pages.
    private var step: CGFloat {
        frontSize.width > 0 ? frontSize.width + SwipePeekMath.gap : 0
    }

    var body: some View {
        let step = self.step
        let reduceMotion = self.reduceMotion

        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: SwipePeekMath.gap) {
                front
                    .environment(\.catchCardReservesTurnOverSpace, true)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { frontSize = $0 }
                    .modifier(PeekDim(reduceMotion: reduceMotion))
                    .accessibilityElement(children: .contain)
                    .accessibilityAction(named: "About this plane") { showingBack = true }
                    .accessibilityHidden(page != .front)

                // Not laid out at full size until the front has been
                // measured — otherwise a back that fills its proposal would
                // set the carousel's height.
                Group {
                    if frontSize.width > 0, frontSize.height > 0 {
                        back.frame(width: frontSize.width, height: frontSize.height)
                    } else {
                        Color.clear.frame(width: 0, height: 0)
                    }
                }
                .modifier(PeekDim(reduceMotion: reduceMotion))
                .accessibilityElement(children: .contain)
                .accessibilityAction(named: "Back to catch") { showingBack = false }
                .accessibilityHidden(page != .back)
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
        .scrollPosition($position)
        // `onScrollGeometryChange` runs `of:` on every scroll frame but only
        // calls `action` when its result changes — here, when the scroll
        // arrives at (or leaves) a page. Cheap enough to watch continuously.
        .onScrollGeometryChange(for: CardPagerMath.Page?.self) { geo in
            CardPagerMath.restingPage(offset: geo.contentOffset.x + geo.contentInsets.leading,
                                      step: step)
        } action: { _, resting in
            settle(on: resting)
        }
        // The carousel is exactly one card wide, so a page fills it and the
        // neighbour sits just outside, in the gutter.
        .frame(width: frontSize.width > 0 ? frontSize.width : nil)
        .overlay(alignment: .trailing) {
            peekTab(title: "About this plane", edge: .trailing, shown: restingPage == .front) {
                showingBack = true
            }
            .offset(x: gutter)
        }
        .overlay(alignment: .leading) {
            peekTab(title: "Back to catch", edge: .leading, shown: restingPage == .back) {
                showingBack = false
            }
            .offset(x: -gutter)
        }
        .animation(.easeOut(duration: 0.2), value: restingPage)
        // Gutter = this view's distance from the enclosing (vertical) scroll
        // view's leading edge; the detail screen is symmetric.
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).minX } action: {
            gutter = min(max($0, 0), 40)
        }
        .onChange(of: showingBack) { _, wantsBack in
            let target = CardPagerMath.page(showingBack: wantsBack)
            guard target != page else { return }
            page = target
            Log.ui.debug("swipe-peek: programmatic → \(wantsBack ? "back" : "front", privacy: .public)")
            scroll(to: target, animated: !reduceMotion)
        }
        // Opened already on the back (state kept across a re-render): move
        // there once the front has been measured and the offset is known.
        .onChange(of: frontSize.width) { old, new in
            guard old == 0, new > 0, page == .back else { return }
            scroll(to: .back, animated: false)
        }
        // The tick lands as the card settles, not when the finger lifts.
        .sensoryFeedback(.impact(weight: .light), trigger: page)
    }

    /// The scroll came to rest (or left rest). A new page from a user swipe
    /// becomes the binding's value.
    private func settle(on resting: CardPagerMath.Page?) {
        restingPage = resting
        guard let resting, resting != page else { return }
        page = resting
        Log.ui.debug("swipe-peek: swiped → \(resting == .back ? "back" : "front", privacy: .public)")
        let wantsBack = resting == .back
        if showingBack != wantsBack { showingBack = wantsBack }
    }

    private func scroll(to target: CardPagerMath.Page, animated: Bool) {
        let x = CardPagerMath.offset(for: target, step: step)
        if animated {
            // Wrapping a ScrollPosition change in withAnimation is what
            // makes the scroll animate instead of jumping.
            withAnimation(.smooth(duration: 0.4)) { position.scrollTo(x: x) }
        } else {
            position.scrollTo(x: x)
        }
    }

    /// The tap target over the peeking card, in the gutter: a chevron and a
    /// vertical mono-caps label ("ABOUT THIS PLANE" reading upward on the
    /// right, "BACK TO CATCH" reading downward on the left). Hidden from
    /// VoiceOver — the cards' accessibility actions do the same job.
    private func peekTab(title: String, edge: HorizontalEdge, shown: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: edge == .trailing ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 13, weight: .semibold))
                // Rotation is purely visual — layout still sees the text
                // lying flat — so the fixed frame reserves the rotated
                // footprint: gutter-narrow, tall enough for the label.
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .lineLimit(1)
                    .fixedSize()
                    .rotationEffect(.degrees(edge == .trailing ? -90 : 90))
                    .frame(width: 12, height: 130)
            }
            .foregroundStyle(RP.muted)
            .frame(width: gutter)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(shown && gutter >= 12 ? 1 : 0)
        .allowsHitTesting(shown && gutter >= 12)
        .accessibilityHidden(true)
    }
}

/// Dims a card as it scrolls away from the slot.
///
/// `scrollTransition` hands the closure a phase whose `value` runs from 0
/// (fully in view) to ±1 (fully out, −1 to the left, +1 to the right),
/// re-evaluated every frame of a scroll. The closure must be `@Sendable`,
/// so it only calls the `nonisolated` math above.
private struct PeekDim: ViewModifier {
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        // Copy to a local so the @Sendable closure captures a Bool, not self.
        let reduceMotion = self.reduceMotion
        return content.scrollTransition(.interactive, axis: .horizontal) { effect, phase in
            effect.opacity(SwipePeekMath.opacity(progress: phase.value, reduceMotion: reduceMotion))
        }
    }
}
