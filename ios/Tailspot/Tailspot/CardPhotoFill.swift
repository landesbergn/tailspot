//
//  CardPhotoFill.swift
//  Tailspot
//
//  The catch card fills the phone (Noah, 2026-11-22): on the reveal and the
//  Hangar detail screen a card with little on it ended well above the bottom
//  of the screen. The spare height goes to the PHOTO, up to square, and
//  everything under the photo keeps the size it had.
//
//  How. Each screen offers its card the height it should fill
//  (`ProposedHeightLayout`, in CatchRevealView.swift). Inside the card the
//  photo is the only part that can take up height; everything under it is
//  pinned at the size it always had, by `ProposedHeightLayout(height: nil)`
//  on the detail screen (ideal size, as its scroll view gave it) and by
//  `SettledMinimumHeightLayout` on the reveal (below; read its comment
//  before touching the reveal card's layout). It is all one layout pass:
//  nothing is measured into state and fed back, so there is nothing to
//  settle a frame late and nothing that can loop.
//

import SwiftUI

nonisolated enum CardPhotoFill {
    /// The tallest the photo may grow: its own width (a square). The photo
    /// sits inside the card's 18 pt (at 300 wide) side padding.
    static func maxHeight(cardWidth: CGFloat, base: CGFloat) -> CGFloat {
        max(base, cardWidth - 2 * 18 * (cardWidth / 300))
    }
}

/// Pins the reveal card's content under the photo at the height it had
/// before the card filled the screen, whatever height the card is offered,
/// so spare height can only reach the photo.
///
/// That height is NOT simply the content's minimum, and getting it wrong
/// changes the size of the callsign line, the ALT/SPD values and the route
/// codes (all `minimumScaleFactor` text). It was never designed; it fell out
/// of the old layout like this:
///  1. The reveal column offered the card zero height. A stack measures a
///     child at zero (its minimum), then places it IN the height it
///     measured, and offered that height the content lays out a little
///     taller than its minimum (some text takes its full size first).
///  2. `FlipCard` measured the card it saw and sized its back face to
///     that. SwiftUI reports a view's size snapped to whole pixels at where
///     the view sits on screen, so the back came out up to a pixel taller
///     or shorter than the card. The back shared a ZStack with the front,
///     so a taller back grew the stack, and with it the front's next offer,
///     and the content could grow again.
///  3. That repeated until the snapped size stopped giving the content
///     more than it already had. Where it stopped depended on the pixel
///     the card's edges landed on, so on the phone's size and the card's
///     height: the same card draws large ALT/SPD on one phone and small on
///     the next (`CardFillLayoutTests` has the table).
/// `settledSize` runs the same climb directly, in one layout pass, from
/// where the card USED to sit (centered in the viewport above its turn
/// row, at its old photo height), so the answer does not move when the
/// photo grows. `above` is the old photo block over the content, `below`
/// the turn row under the card, `viewport` the reveal's scroll viewport
/// (nil before it is measured: then sizes are snapped up, the common case),
/// `pixel` one pixel in points.
///
/// The old climb was a measurement feeding its own layout; this is plain
/// arithmetic on the same numbers. It ends when the height stops changing
/// or comes back to one it has already tried (the old layout would have
/// flickered between the two; this takes the first). Each step adds at
/// most a pixel, so a card whose text can grow a lot takes a few dozen
/// steps (75 is the most seen across nine phone sizes); `maxSteps` is a
/// bound well above that, and `CardFillLayoutTests` fails if any card gets
/// near it.
nonisolated struct SettledMinimumHeightLayout: Layout {
    var above: CGFloat
    var below: CGFloat
    var viewport: CGFloat?
    var pixel: CGFloat

    static let maxSteps = 400
    #if DEBUG
    /// The most steps any card has needed, for the test above.
    nonisolated(unsafe) static var mostStepsTaken = 0
    #endif

    /// The height `FlipCard` would have measured for a card `height` tall:
    /// the distance between its top and bottom edges, each snapped to the
    /// nearest pixel where the old column put them.
    private func measuredCardHeight(_ height: CGFloat) -> CGFloat {
        guard let viewport else { return (height / pixel - 0.0001).rounded(.up) * pixel }
        func snap(_ y: CGFloat) -> CGFloat { (y / pixel + 0.5).rounded(.down) * pixel }
        // Centered when card and turn row fit the viewport, else at the top.
        let top = height + below < viewport ? (viewport - height - below) / 2 : 0
        return snap(top + height) - snap(top)
    }

    private func settledSize(_ child: LayoutSubview, width: CGFloat?) -> CGSize {
        func size(offered height: CGFloat) -> CGSize {
            child.sizeThatFits(ProposedViewSize(width: width, height: height))
        }
        let minimum = size(offered: 0).height
        var settled = size(offered: minimum)
        var tried: [CGFloat] = [settled.height]
        var steps = 0
        while steps < Self.maxSteps {
            steps += 1
            let next = size(offered: max(minimum, measuredCardHeight(above + settled.height) - above))
            if tried.contains(where: { abs($0 - next.height) < 0.0001 }) { break }
            tried.append(next.height)
            settled = next
        }
        #if DEBUG
        Self.mostStepsTaken = max(Self.mostStepsTaken, steps)
        #endif
        return settled
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return settledSize(child, width: proposal.width)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// Parts of a catch card whose frames the layout tests read
/// (`CardFillLayoutTests`). Nothing in the app reads them.
nonisolated enum CardFramePart: Hashable, Sendable {
    case card, photo, turnRow
    /// The callsign line, the ALT (and DIST) value rows and the route code
    /// row: the text whose size the reveal's squeeze decides.
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
