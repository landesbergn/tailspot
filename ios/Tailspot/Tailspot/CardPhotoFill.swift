//
//  CardPhotoFill.swift
//  Tailspot
//
//  The catch card fits its phone (Noah, 2026-11-22), on the reveal and the
//  Hangar detail screen. The PHOTO is the only thing that absorbs height:
//   - a card with little on it grows its photo, up to square, until the
//     card fills the screen;
//   - a card too tall for the screen takes height back from its photo,
//     down to a floor, and only then scrolls;
//   - everything under the photo is drawn at its designed size times the
//     card's width scale (width / 300), on every phone and every card.
//     Height pressure never shrinks text.
//
//   - a card STILL too tall with its photo at the floor scales everything
//     under the photo down together, by one factor, to 88% at most; only
//     past that does it scroll. One factor for the whole block, so its
//     proportions never change (the old layout's fault was shrinking some
//     lines and not others).
//
//  How. Each screen offers its card the height it should fill
//  (`ProposedHeightLayout`, in CatchRevealView.swift). Inside the card the
//  photo's frame has a minimum and a maximum, and the block under it is in
//  a `ShrinkToFitLayout` with layout priority over the photo, so the stack
//  gives the block its full height first and the photo what is left. One
//  layout pass: nothing is measured into state and fed back, so nothing
//  settles a frame late and nothing can loop.
//

import SwiftUI

nonisolated enum CardPhotoFill {
    /// The shortest the photo may get when the card is too tall for the
    /// screen: 60% of its usual height. Below that it stops reading as a
    /// photo once the notable caption (up to ~45 pt, two lines) is on it.
    static func minHeight(base: CGFloat) -> CGFloat { base * 0.6 }

    /// The most the block under the photo may scale down to fit: below
    /// this the smallest labels (9 pt at 300 wide) stop being readable.
    static let minTextScale: CGFloat = 0.88

    /// The tallest the photo may grow: its own width (a square). The photo
    /// sits inside the card's 18 pt (at 300 wide) side padding.
    static func maxHeight(cardWidth: CGFloat, base: CGFloat) -> CGFloat {
        max(base, cardWidth - 2 * 18 * (cardWidth / 300))
    }
}

/// Lays its child out at its designed (ideal) height when it is offered that
/// much, and otherwise scales the whole child down to fit the offer, to
/// `minScale` at most.
///
/// Scaling is uniform and exact, with no arithmetic about what is in the
/// child: the child is laid out WIDER than the space, at its designed
/// sizes, by 1 / scale, and `shrinksToFit` draws it scaled back down to the
/// space's width. So every font, gap and rule shrinks by the same factor
/// and the block still spans the card. (The alternative, predicting the
/// block's height from its rows and building it with smaller fonts, needs a
/// second copy of every metric on the card that has to be kept in step.)
nonisolated struct ShrinkToFitLayout: Layout {
    var minScale: CGFloat

    private func ideal(_ child: LayoutSubview, width: CGFloat) -> CGSize {
        child.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    /// The scale that fits a child whose designed height is `designed`
    /// into `height`.
    private func scale(designed: CGFloat, into height: CGFloat?) -> CGFloat {
        guard let height, designed > 0 else { return 1 }
        return min(1, max(minScale, height / designed))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        guard let width = proposal.width else { return child.sizeThatFits(proposal) }
        let designed = ideal(child, width: width)
        let scale = scale(designed: designed.height, into: proposal.height)
        guard scale < 1 else { return designed }
        return CGSize(width: width, height: ideal(child, width: width / scale).height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        // The same inputs as `sizeThatFits`, so the block is drawn at the
        // factor it was sized for (the bounds' own height is that size,
        // not the offer, and would give a slightly different factor).
        let width = proposal.width ?? bounds.width
        let scale = scale(designed: ideal(child, width: width).height,
                          into: proposal.height ?? bounds.height)
        child.place(at: bounds.origin, anchor: .topLeading,
                    proposal: ProposedViewSize(width: bounds.width / scale, height: nil))
    }
}

extension View {
    /// The block under a catch card's photo: at its designed size when the
    /// card has room, scaled down as one piece (to `minScale` at most) when
    /// the card is too tall even with its photo at the floor. `width` is
    /// the card's width. Layout priority puts it ahead of the photo, so the
    /// photo gives up all it can before this shrinks at all.
    func shrinksToFit(width: CGFloat, minScale: CGFloat) -> some View {
        ShrinkToFitLayout(minScale: minScale) {
            // Laid out wider than the card when it must shrink (see the
            // layout); drawn scaled back to the card's width.
            visualEffect { content, geometry in
                content.scaleEffect(width / max(geometry.size.width, 1), anchor: .topLeading)
            }
        }
        .layoutPriority(1)
    }
}

/// Parts of a catch card whose frames the layout tests read
/// (`CardFillLayoutTests`). Nothing in the app reads them.
nonisolated enum CardFramePart: Hashable, Sendable {
    case card, photo, turnRow
    /// The callsign line, the ALT (and DIST) value rows and the route code
    /// row: text that height pressure used to shrink, and must not.
    case callsign, altValue, distValue, routeCodes
}

nonisolated struct CardFrameKey: PreferenceKey {
    static let defaultValue: [CardFramePart: CGRect] = [:]
    static func reduce(value: inout [CardFramePart: CGRect],
                       nextValue: () -> [CardFramePart: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

#if DEBUG
/// How many times a catch card has been built, for the test that proves the
/// screens settle (`CardFillLayoutTests.screensStopLayingOut`): a
/// measurement that feeds its own layout shows up as a count that never
/// stops climbing. Main-thread only, like every view body.
nonisolated enum CardBuildCounter {
    nonisolated(unsafe) static var builds = 0
}
#endif

extension View {
    /// Publishes this view's frame (window coordinates) under `part` for the
    /// layout tests; nil publishes nothing. Debug builds only: Release
    /// compiles it away.
    func reportsCardFrame(_ part: CardFramePart?) -> some View {
        #if DEBUG
        if part == .card { CardBuildCounter.builds += 1 }
        return background {
            if let part {
                GeometryReader { geo in
                    Color.clear.preference(key: CardFrameKey.self,
                                           value: [part: geo.frame(in: .global)])
                }
            }
        }
        #else
        return self
        #endif
    }
}
