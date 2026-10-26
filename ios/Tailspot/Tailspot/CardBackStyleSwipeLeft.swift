//
//  CardBackStyleSwipeLeft.swift
//  Tailspot
//
//  Card-back style "Swipe left" (design experiment, 2026-10-26; see
//  CardBackStyles.swift). The back is the NEXT card in a two-card carousel:
//  at rest on the catch card, the back's left edge peeks in from the right
//  side of the screen, shrunk and dimmed, with a vertical "ABOUT THIS PLANE"
//  tab on it. Swipe left (or tap the peek) and the back slides into the
//  slot while the catch card shrinks off to the left and peeks from there;
//  swipe right (or BACK TO CATCH) to go back.
//
//  Explain-as-we-go — how the carousel works:
//   - It's a real horizontal `ScrollView` nested inside the detail screen's
//     vertical one. UIKit (which SwiftUI's ScrollView is built on) locks a
//     drag to whichever scroll view's axis it starts along, so a vertical
//     drag on the card still scrolls the page and a sideways one pages the
//     carousel — no hand-written gesture arbitration. The left-edge swipe
//     back is untouched: the carousel sits 18 pt in from the screen edge.
//   - `.scrollClipDisabled()` lets the cards draw outside the scroll view's
//     bounds, which is how the neighbour shows in the 18 pt side gutter.
//     The peek can only ever be as wide as that gutter (minus the gap
//     between cards), because the front card is laid out by the screen at
//     full width. Touches don't reach content outside a scroll view's
//     bounds, so tapping the peek goes through a separate tab overlay.
//   - Paging: a custom `ScrollTargetBehavior` (`SwipePeekPaging`). When the
//     finger lifts, the system asks it where the scroll should come to rest,
//     handing it the spot a free-spinning scroll WOULD stop at (that already
//     includes the flick's speed). We round that to a page: a quarter card
//     of travel, or a flick, is enough to turn the page.
//   - `.scrollTransition` re-styles each card from its position in the
//     scroll view every frame (phase value 0 = centred, ±1 = off to a side)
//     WITHOUT re-running this view's `body` — cheap, and it tracks the
//     finger exactly. That's where the 0.94 scale and the dim come from.
//   - `ScrollPosition` + `scrollTo(x:)` scrolls programmatically (the
//     back's BACK TO CATCH button flips the binding; we animate there).
//   - `showingBack` is the source of truth both ways. A user swipe commits
//     when the scroll comes to rest on a page; a programmatic change scrolls
//     to the page. `page` remembers the last settled page so neither path
//     echoes the other.
//   - Reduce Motion: no scale and no gradual dim (the far card is simply
//     dimmed or not), and programmatic page changes jump without animation.
//

import SwiftUI
import os

// MARK: - Pure decisions (unit-tested)

/// The carousel's pure decisions, kept out of the views so tests can pin
/// them. `nonisolated` — plain math, no UI state.
nonisolated enum SwipePeekMath {
    enum Page: Int, Equatable, Hashable, Sendable { case front = 0, back = 1 }

    /// Space between the two cards. The peek visible on screen is the side
    /// gutter (18 pt on the detail screen) minus this.
    static let gap: CGFloat = 4
    /// Scale of the card that's off to the side.
    static let peekScale: CGFloat = 0.94
    /// Opacity of the card that's off to the side (it sits on the dark
    /// screen background, so lower opacity reads as dimmed).
    static let peekOpacity: Double = 0.5
    /// Fraction of a page the projected scroll must travel to turn the page.
    static let commitFraction: CGFloat = 0.25
    /// How close (pt) the scroll offset must be to a page to count as at rest.
    static let restTolerance: CGFloat = 1

    static func page(showingBack: Bool) -> Page {
        showingBack ? .back : .front
    }

    /// Horizontal content offset at which `page` sits in the slot. `step` is
    /// one card width plus the gap.
    static func offset(for page: Page, step: CGFloat) -> CGFloat {
        CGFloat(page.rawValue) * step
    }

    /// Where a released scroll should land. `projectedOffset` is the offset a
    /// free scroll would stop at (it includes the flick's momentum); moving
    /// more than `commitFraction` of a page from `current` turns the page,
    /// anything less springs back. Only one page exists either side.
    static func targetPage(from current: Page, projectedOffset: CGFloat,
                           step: CGFloat) -> Page {
        guard step > 0 else { return current }
        let travel = projectedOffset - offset(for: current, step: step)
        if travel > step * commitFraction { return .back }
        if travel < -step * commitFraction { return .front }
        return current
    }

    /// The page the scroll is resting on, or nil while it's between pages
    /// (mid-swipe, or rubber-banding past an end).
    static func restingPage(offset: CGFloat, step: CGFloat,
                            tolerance: CGFloat = restTolerance) -> Page? {
        guard step > 0 else { return .front }
        if abs(offset - self.offset(for: .front, step: step)) <= tolerance { return .front }
        if abs(offset - self.offset(for: .back, step: step)) <= tolerance { return .back }
        return nil
    }

    /// How far a card is from the slot, 0 (centred) … 1 (fully off to a
    /// side), from a scroll-transition phase value (−1 … 1).
    static func distance(progress: Double) -> Double {
        min(1, abs(progress))
    }

    /// The card's scale at `progress`: 1 in the slot, `peekScale` off to the
    /// side, linear between. Reduce Motion: always 1.
    static func scale(progress: Double, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion else { return 1 }
        return 1 - (1 - peekScale) * CGFloat(distance(progress: progress))
    }

    /// The card's opacity at `progress`: 1 in the slot, `peekOpacity` off to
    /// the side. Reduce Motion: a step at half way instead of a ramp.
    static func opacity(progress: Double, reduceMotion: Bool) -> Double {
        let d = distance(progress: progress)
        if reduceMotion { return d >= 0.5 ? peekOpacity : 1 }
        return 1 - (1 - peekOpacity) * d
    }

    /// Scale toward the edge nearest the slot, so the shrink comes off the
    /// card's far side and the peeking edge keeps its full width in the
    /// gutter. Positive progress = the card is to the right.
    static func scaleAnchor(progress: Double) -> UnitPoint {
        progress >= 0 ? .leading : .trailing
    }
}

// MARK: - Paging behaviour

/// Snaps the carousel to a page when the finger lifts (see the file header).
/// `nonisolated` so it satisfies `ScrollTargetBehavior` whatever that
/// protocol's isolation; it only holds plain values.
nonisolated struct SwipePeekPaging: ScrollTargetBehavior {
    /// One card width plus the gap; 0 until the front has been measured.
    let step: CGFloat
    /// The page the scroll last rested on.
    let currentPage: SwipePeekMath.Page

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard step > 0 else { return }
        let page = SwipePeekMath.targetPage(from: currentPage,
                                            projectedOffset: target.rect.minX,
                                            step: step)
        target.rect.origin.x = SwipePeekMath.offset(for: page, step: step)
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
    @State private var page: SwipePeekMath.Page
    /// The page the scroll is resting on right now; nil mid-swipe. Drives
    /// the peek tabs, which only show at rest.
    @State private var restingPage: SwipePeekMath.Page?
    @State private var position = ScrollPosition()

    init(showingBack: Binding<Bool>,
         @ViewBuilder front: () -> Front, @ViewBuilder back: () -> Back) {
        self._showingBack = showingBack
        let initial = SwipePeekMath.page(showingBack: showingBack.wrappedValue)
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
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { frontSize = $0 }
                    .modifier(PeekTransition(reduceMotion: reduceMotion))
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
                .modifier(PeekTransition(reduceMotion: reduceMotion))
                .accessibilityElement(children: .contain)
                .accessibilityAction(named: "Back to catch") { showingBack = false }
                .accessibilityHidden(page != .back)
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .scrollTargetBehavior(SwipePeekPaging(step: step, currentPage: page))
        .scrollPosition($position)
        // `onScrollGeometryChange` runs `of:` on every scroll frame but only
        // calls `action` when its result changes — here, when the scroll
        // arrives at (or leaves) a page. Cheap enough to watch continuously.
        .onScrollGeometryChange(for: SwipePeekMath.Page?.self) { geo in
            SwipePeekMath.restingPage(offset: geo.contentOffset.x + geo.contentInsets.leading,
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
            let target = SwipePeekMath.page(showingBack: wantsBack)
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
        .sensoryFeedback(.impact(weight: .light), trigger: page)
    }

    /// The scroll came to rest (or left rest). A new page from a user swipe
    /// becomes the binding's value.
    private func settle(on resting: SwipePeekMath.Page?) {
        restingPage = resting
        guard let resting, resting != page else { return }
        page = resting
        Log.ui.debug("swipe-peek: swiped → \(resting == .back ? "back" : "front", privacy: .public)")
        let wantsBack = resting == .back
        if showingBack != wantsBack { showingBack = wantsBack }
    }

    private func scroll(to target: SwipePeekMath.Page, animated: Bool) {
        let x = SwipePeekMath.offset(for: target, step: step)
        if animated {
            // Wrapping a ScrollPosition change in withAnimation is what
            // makes the scroll animate instead of jumping.
            withAnimation(.spring(duration: 0.45, bounce: 0.1)) { position.scrollTo(x: x) }
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

/// Shrinks and dims a card as it scrolls away from the slot.
///
/// `scrollTransition` hands the closure a phase whose `value` runs from 0
/// (fully in view) to ±1 (fully out, −1 to the left, +1 to the right),
/// re-evaluated every frame of a scroll. The closure must be `@Sendable`,
/// so it only calls the `nonisolated` math above.
private struct PeekTransition: ViewModifier {
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        // Copy to a local so the @Sendable closure captures a Bool, not self.
        let reduceMotion = self.reduceMotion
        return content.scrollTransition(.interactive, axis: .horizontal) { effect, phase in
            let p = phase.value
            return effect
                .scaleEffect(SwipePeekMath.scale(progress: p, reduceMotion: reduceMotion),
                             anchor: SwipePeekMath.scaleAnchor(progress: p))
                .opacity(SwipePeekMath.opacity(progress: p, reduceMotion: reduceMotion))
        }
    }
}
