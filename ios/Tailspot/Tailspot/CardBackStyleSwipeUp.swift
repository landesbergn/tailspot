//
//  CardBackStyleSwipeUp.swift
//  Tailspot
//
//  Card-back style "Swipe up" (design experiment, 2026-10-26; see
//  CardBackStyles.swift). The back sits BELOW the catch card, never on top
//  of it: under the card is a "^ ABOUT THIS PLANE" tab. Scroll up and the card slides off the top of
//  its slot while the back slides in, snapping into place; at the top the
//  tab has turned into "v BACK TO CATCH". Scroll down (or tap the tab) to
//  go back.
//
//  Second pass (Noah, 2026-10-26: "don't stack the cards on top of each
//  other, and make the animation much more smooth like scrolling, but also
//  with a click into place"): it's now a real scroll view, not a drag that
//  slides one card over the other.
//
//  Third pass (Noah, 2026-10-27: "make the spacing cleaner so the card fits
//  in the frame"; on the reveal the tab overlapped "tap to continue"): no
//  peek of the back and no grabber, just a compact tab, so the slot is only
//  the card plus 36 pt.
//
//  Explain-as-we-go — how it works:
//   - The card slot is a vertical `ScrollView` with a fixed-height window:
//     the card's height plus the tab. Inside, the content is
//     simply the card, then the tab, then the back, stacked top to bottom.
//     The window clips, so whatever has scrolled out of it isn't drawn.
//   - Two snap points, set with `.scrollTargetLayout()` +
//     `.scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))`:
//     the card's top and the tab's top. A released scroll glides with the
//     finger's speed and decelerates into whichever is next — real scroll
//     physics with the click at the end.
//   - This scroll view sits inside the detail screen's own vertical one.
//     A vertical drag that starts on the card moves the card, not the
//     screen; the screen still scrolls from anywhere below the slot.
//   - `progress` (0 = card, 1 = back) is read off the scroll offset as it
//     moves and only drives the tab's label turning over.
//   - Reduce Motion: the tab's label swaps instead of turning, and taps
//     jump instead of scrolling.
//

import SwiftUI
import os

// MARK: - Pure decisions (unit-tested)

/// The pull-up's geometry; page bookkeeping is `CardPagerMath`.
/// `nonisolated` — plain math, no UI state.
nonisolated enum PullUpMath {
    /// The tab between the card and the back.
    static let tabHeight: CGFloat = 36

    /// The slot's fixed height: the card and the tab. At rest on the back,
    /// the same window shows the tab and the back (the back is the card's
    /// size), so nothing peeks or gets cut off either way.
    static func windowHeight(frontHeight: CGFloat) -> CGFloat {
        frontHeight + tabHeight
    }

    /// The scroll distance from the card's snap point to the back's: the
    /// card's height (the back's snap point is the tab's top).
    static func step(frontHeight: CGFloat) -> CGFloat {
        max(0, frontHeight)
    }

    /// "ABOUT THIS PLANE" fades out over the first half of the scroll…
    static func aboutOpacity(progress: Double) -> Double {
        min(1, max(0, 1 - progress * 2))
    }

    /// …and "BACK TO CATCH" fades in over the second half.
    static func backToCatchOpacity(progress: Double) -> Double {
        min(1, max(0, progress * 2 - 1))
    }

    /// The chevron turns from up to down as the scroll goes.
    static func chevronDegrees(progress: Double) -> Double {
        180 * min(1, max(0, progress))
    }
}

/// What the swipe-up scroll watcher reports each time either value changes.
nonisolated struct PullUpScrollState: Equatable, Sendable {
    /// 0 (card) … 1 (back), in 5% steps.
    var progress: Double
    /// The page the scroll is resting on; nil mid-scroll.
    var resting: CardPagerMath.Page?
}

// MARK: - PullUpCard

struct PullUpCard<Front: View, Back: View>: View {
    @Binding var showingBack: Bool
    /// False while the host isn't ready for a turn-over (the catch reveal
    /// before it settles): no swipe or drag, and no tease of the back.
    let enabled: Bool
    private let front: Front
    private let back: Back

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The front's measured size; the back is laid out at exactly this.
    @State private var frontSize: CGSize = .zero
    /// The page the scroll last came to rest on.
    @State private var page: CardPagerMath.Page
    /// The page the scroll is resting on right now; nil mid-scroll.
    @State private var restingPage: CardPagerMath.Page?
    /// 0 (card) … 1 (back), from the scroll offset, in 5% steps so the tab
    /// re-renders ~20 times over a scroll rather than every frame.
    @State private var progress: Double
    @State private var position = ScrollPosition()

    init(showingBack: Binding<Bool>, enabled: Bool = true,
         @ViewBuilder front: () -> Front, @ViewBuilder back: () -> Back) {
        self._showingBack = showingBack
        self.enabled = enabled
        let initial = CardPagerMath.page(showingBack: showingBack.wrappedValue)
        self._page = State(initialValue: initial)
        self._restingPage = State(initialValue: initial)
        self._progress = State(initialValue: initial == .back ? 1 : 0)
        self.front = front()
        self.back = back()
    }

    private var step: CGFloat { PullUpMath.step(frontHeight: frontSize.height) }

    var body: some View {
        let step = self.step
        let measured = frontSize.width > 0 && frontSize.height > 0

        ScrollView(.vertical) {
            VStack(spacing: 0) {
                front
                    .environment(\.catchCardReservesTurnOverSpace, true)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { frontSize = $0 }
                    .accessibilityElement(children: .contain)
                    .accessibilityAction(named: "About this plane") { showingBack = true }
                    .accessibilityHidden(page != .front)

                // The back's page: the tab, then the back. Its top is the
                // second snap point. Not laid out at full size until the
                // front has been measured, so it can't set the window size.
                VStack(spacing: 0) {
                    tab
                    if measured {
                        back
                            .frame(width: frontSize.width, height: frontSize.height)
                            // Mid-scroll taps shouldn't hit the back's
                            // buttons; drags still scroll.
                            .allowsHitTesting(restingPage == .back)
                            .accessibilityElement(children: .contain)
                            .accessibilityHidden(page != .back)
                    }
                }
                // No tab until the host enables the turn-over.
                .opacity(enabled ? 1 : 0)
                .allowsHitTesting(enabled)
                .animation(.easeOut(duration: 0.25), value: enabled)
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
        .scrollDisabled(!enabled)
        .scrollPosition($position)
        // ONE scroll watcher reporting both values: a second
        // `onScrollGeometryChange` on the same scroll view never fired on
        // the device (2026-10-26), so the page never settled — the tab kept
        // saying ABOUT THIS PLANE and the Wikipedia fetch, which waits for
        // the first turn-over, never started.
        .onScrollGeometryChange(for: PullUpScrollState.self) { geo in
            let offset = geo.contentOffset.y + geo.contentInsets.top
            let p = CardPagerMath.progress(offset: offset, step: step)
            return PullUpScrollState(progress: (p * 20).rounded() / 20,
                                     resting: CardPagerMath.restingPage(offset: offset, step: step))
        } action: { _, state in
            progress = state.progress
            settle(on: state.resting)
        }
        // Backstop: whenever the scroll stops moving, settle on the nearer
        // page, so a landing a hair off the snap point still counts.
        .onScrollPhaseChange { _, phase in
            guard phase == .idle else { return }
            settle(on: progress >= 0.5 ? .back : .front)
        }
        .frame(width: measured ? frontSize.width : nil,
               height: measured ? PullUpMath.windowHeight(frontHeight: frontSize.height) : nil)
        .onChange(of: showingBack) { _, wantsBack in
            let target = CardPagerMath.page(showingBack: wantsBack)
            guard target != page else { return }
            page = target
            Log.ui.debug("pull-up card: programmatic → \(wantsBack ? "back" : "front", privacy: .public)")
            scroll(to: target, animated: !reduceMotion)
        }
        // Opened already on the back: move there once the offset is known.
        .onChange(of: frontSize.height) { old, new in
            guard old == 0, new > 0, page == .back else { return }
            scroll(to: .back, animated: false)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: page)
    }

    /// The tab between the card and the back: a chevron and a label that turn over from "ABOUT THIS PLANE" (pointing up) to
    /// "BACK TO CATCH" (pointing down) as the scroll goes. Tap to go to the
    /// other side.
    private var tab: some View {
        let scale = frontSize.width / 300
        let p = progress
        return HStack(spacing: 7 * scale) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .rotationEffect(.degrees(reduceMotion
                                             ? (page == .back ? 180 : 0)
                                             : PullUpMath.chevronDegrees(progress: p)))
                ZStack {
                    tabLabel("ABOUT THIS PLANE", scale: scale)
                        .opacity(reduceMotion ? (page == .back ? 0 : 1)
                                              : PullUpMath.aboutOpacity(progress: p))
                    tabLabel("BACK TO CATCH", scale: scale)
                        .opacity(reduceMotion ? (page == .back ? 1 : 0)
                                              : PullUpMath.backToCatchOpacity(progress: p))
            }
        }
        .foregroundStyle(RP.muted)
        .frame(width: frontSize.width > 0 ? frontSize.width : nil, height: PullUpMath.tabHeight)
        .contentShape(Rectangle())
        .onTapGesture { showingBack = page == .front }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(page == .front ? "About this plane" : "Back to catch")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { showingBack = page == .front }
    }

    private func tabLabel(_ text: String, scale: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 11 * scale, weight: .semibold, design: .monospaced))
            .tracking(1.5)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    /// The scroll came to rest (or left rest). A new page from a user
    /// scroll becomes the binding's value.
    private func settle(on resting: CardPagerMath.Page?) {
        restingPage = resting
        guard let resting, resting != page else { return }
        page = resting
        Log.ui.debug("pull-up card: scrolled → \(resting == .back ? "back" : "front", privacy: .public)")
        let wantsBack = resting == .back
        if showingBack != wantsBack { showingBack = wantsBack }
    }

    private func scroll(to target: CardPagerMath.Page, animated: Bool) {
        let y = CardPagerMath.offset(for: target, step: step)
        if animated {
            withAnimation(.smooth(duration: 0.45)) { position.scrollTo(y: y) }
        } else {
            position.scrollTo(y: y)
        }
    }
}
