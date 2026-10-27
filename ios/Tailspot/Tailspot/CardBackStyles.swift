//
//  CardBackStyles.swift
//  Tailspot
//
//  Design experiment (2026-10-26): four ways to get from the catch card to
//  its back (the closeup + "about this plane"), used by both the catch
//  detail screen and the catch reveal, switchable from the detail screen
//  in Debug builds so each can be tried by feel on a phone.
//  Release builds always use `.flip`, the shipped behaviour; the switch is
//  never read there.
//
//  Every style presents the same two views — the catch card (front) and
//  `CatchCardBack` (back) — and reports which side is showing through one
//  `showingBack` binding, so the screen around it doesn't care which style
//  is live. Once one is picked, the losers get deleted along with this
//  switch.
//

import SwiftUI

enum CardBackStyle: String, CaseIterable, Identifiable, Sendable {
    /// The shipped 3D flip (`FlipCard`): button or horizontal swipe.
    case flip
    /// A heavier, physical card: thickness, lift, moving shadow and glare,
    /// and the turn follows your finger.
    case realFlip
    /// The back sits beside the card, its edge peeking in from the right;
    /// swipe left and it pages over, snapping into place.
    case swipeLeft
    /// The back sits below the card behind an "ABOUT THIS PLANE" tab;
    /// scroll up and it snaps into place where the card was.
    case swipeUp

    var id: String { rawValue }

    /// Name in the Debug style menu.
    var title: String {
        switch self {
        case .flip: return "Flip (shipped)"
        case .realFlip: return "Real card flip"
        case .swipeLeft: return "Swipe left"
        case .swipeUp: return "Swipe up"
        }
    }

    /// Whether the front shows its "ABOUT THIS PLANE" button. The swipe
    /// styles have a visible tease of the back instead.
    var frontShowsTurnOverButton: Bool {
        switch self {
        case .flip, .realFlip: return true
        case .swipeLeft, .swipeUp: return false
        }
    }

    /// Whether the back shows its "BACK TO CATCH" button. Swipe up has the
    /// tab above the back for that instead.
    var backShowsTurnBackButton: Bool { self != .swipeUp }


    #if DEBUG
    static let defaultsKey = "tailspot.debug.cardBackStyle"

    /// Debug only: the style picked in the detail screen's menu.
    static var current: CardBackStyle {
        get {
            UserDefaults.standard.string(forKey: defaultsKey)
                .flatMap(CardBackStyle.init(rawValue:)) ?? .flip
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
    #else
    static var current: CardBackStyle { .flip }
    #endif
}

/// The card slot on the detail screen: picks the style's container.
/// `front` is handed a `showBack` action to wire into its turn-over button
/// when `style` shows one.
struct CardBackPresenter<Front: View, Back: View>: View {
    let style: CardBackStyle
    @Binding var showingBack: Bool
    /// False while the host isn't ready for a turn-over (the catch reveal
    /// before it settles); passed through to the style.
    let enabled: Bool
    private let front: Front
    private let back: Back

    init(style: CardBackStyle, showingBack: Binding<Bool>, enabled: Bool = true,
         @ViewBuilder front: (_ showBack: @escaping () -> Void) -> Front,
         @ViewBuilder back: () -> Back) {
        self.style = style
        self._showingBack = showingBack
        self.enabled = enabled
        let binding = showingBack
        self.front = front({ binding.wrappedValue = true })
        self.back = back()
    }

    var body: some View {
        switch style {
        case .flip:
            FlipCard(isFlipped: $showingBack, enabled: enabled) { front } back: { back }
        case .realFlip:
            RealisticFlipCard(showingBack: $showingBack, enabled: enabled) { front } back: { back }
        case .swipeLeft:
            SwipePeekCard(showingBack: $showingBack, enabled: enabled) { front } back: { back }
        case .swipeUp:
            PullUpCard(showingBack: $showingBack, enabled: enabled) { front } back: { back }
        }
    }
}

// MARK: - Two-page pager (swipe left / swipe up)

/// The two swipe styles are both a real `ScrollView` with exactly two
/// pages, the catch card and its back, that snaps to a page when the
/// finger lifts. This is the shared bookkeeping: which page is which,
/// where each sits, and whether the scroll is resting on one.
/// `nonisolated` — plain math, no UI state.
nonisolated enum CardPagerMath {
    enum Page: Int, Equatable, Hashable, Sendable { case front = 0, back = 1 }

    /// How close (pt) the scroll offset must be to a page to count as at rest.
    static let restTolerance: CGFloat = 1

    static func page(showingBack: Bool) -> Page {
        showingBack ? .back : .front
    }

    /// Content offset (along the scroll axis) at which `page` is in place.
    /// `step` is the distance between the two pages.
    static func offset(for page: Page, step: CGFloat) -> CGFloat {
        CGFloat(page.rawValue) * step
    }

    /// The page the scroll is resting on, or nil while it's between pages
    /// (mid-swipe, or rubber-banding past an end).
    static func restingPage(offset: CGFloat, step: CGFloat,
                            tolerance: CGFloat = restTolerance) -> Page? {
        guard step > 0 else { return .front }
        if abs(offset) <= tolerance { return .front }
        if abs(offset - step) <= tolerance { return .back }
        return nil
    }

    /// How far toward the back the scroll is, 0 (front) … 1 (back),
    /// clamped so a rubber-band past either end reads as that end.
    static func progress(offset: CGFloat, step: CGFloat) -> Double {
        guard step > 0 else { return 0 }
        return Double(min(1, max(0, offset / step)))
    }
}

extension EnvironmentValues {
    /// Whether the catch card keeps its turn-over button's room with the
    /// button hidden. The swipe pagers lay the two cards side by side (or
    /// one above the other), so they must be the same size, and the back is
    /// laid out for a card with that button, as the shipped flip has.
    /// `@Entry` declares an environment key and its default in one line.
    @Entry var catchCardReservesTurnOverSpace: Bool = false
}
