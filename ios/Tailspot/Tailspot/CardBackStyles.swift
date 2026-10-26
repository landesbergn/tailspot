//
//  CardBackStyles.swift
//  Tailspot
//
//  Design experiment (2026-10-26): six ways to get from the catch card to
//  its back (the closeup + "about this plane"), switchable on the catch
//  detail screen in Debug builds so each can be tried by feel on a phone.
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
    /// swipe left to slide over to it.
    case swipeLeft
    /// The back's top peeks out under the card; swipe it up over the card.
    case swipeUp
    /// The card's bottom unfolds like a folded boarding pass, dropping the
    /// back out below while the catch stays in view.
    case unfold
    /// Tap the card and it zooms into a full-screen page with the back.
    case photoZoom

    var id: String { rawValue }

    /// Name in the Debug style menu.
    var title: String {
        switch self {
        case .flip: return "Flip (shipped)"
        case .realFlip: return "Real card flip"
        case .swipeLeft: return "Swipe left"
        case .swipeUp: return "Swipe up"
        case .unfold: return "Unfold"
        case .photoZoom: return "Zoom in"
        }
    }

    /// Whether the front shows its "ABOUT THIS PLANE" button. The swipe and
    /// unfold styles have a visible tease of the back instead.
    var frontShowsTurnOverButton: Bool {
        switch self {
        case .flip, .realFlip, .photoZoom: return true
        case .swipeLeft, .swipeUp, .unfold: return false
        }
    }

    /// How much narrower than the usual card this style draws it. Swipe
    /// left needs a wider side gutter for the next card to peek into; the
    /// card fills the width otherwise, which left only a ~14 pt sliver.
    var cardWidthInset: CGFloat { self == .swipeLeft ? 44 : 0 }

    /// Whether tapping the front's photo shows the back (instead of the
    /// photo viewer / Planespotters page).
    var photoTapShowsBack: Bool { self == .photoZoom }

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
/// `front` is handed a `showBack` action to wire into its own controls
/// (turn-over button, photo tap) as `style` asks.
struct CardBackPresenter<Front: View, Back: View>: View {
    let style: CardBackStyle
    @Binding var showingBack: Bool
    private let front: Front
    private let back: Back

    init(style: CardBackStyle, showingBack: Binding<Bool>,
         @ViewBuilder front: (_ showBack: @escaping () -> Void) -> Front,
         @ViewBuilder back: () -> Back) {
        self.style = style
        self._showingBack = showingBack
        let binding = showingBack
        self.front = front({ binding.wrappedValue = true })
        self.back = back()
    }

    var body: some View {
        switch style {
        case .flip:
            FlipCard(isFlipped: $showingBack) { front } back: { back }
        case .realFlip:
            RealisticFlipCard(showingBack: $showingBack) { front } back: { back }
        case .swipeLeft:
            SwipePeekCard(showingBack: $showingBack) { front } back: { back }
        case .swipeUp:
            PullUpCard(showingBack: $showingBack) { front } back: { back }
        case .unfold:
            UnfoldCard(showingBack: $showingBack) { front } back: { back }
        case .photoZoom:
            PhotoZoomCard(showingBack: $showingBack) { front } back: { back }
        }
    }
}
