//
//  CardBackStyleZoom.swift
//  Tailspot
//
//  Card-back style "Zoom in" (`CardBackStyle.photoZoom`, design experiment
//  2026-10-26). Tapping the card's photo, or its ABOUT THIS PLANE button,
//  zooms the whole card up into a full-screen "about this plane" page, the
//  way an App Store "Today" card opens. Drag the page down (or tap the close
//  button, or BACK TO CATCH) and it shrinks back into the card.
//
//  Explain-as-we-go — how the zoom works:
//   - iOS 18 added *zoom navigation transitions*. You tag the view the zoom
//     should grow out of with `.matchedTransitionSource(id:in:)`, and tag the
//     presented screen with `.navigationTransition(.zoom(sourceID:in:))`
//     using the same id and `@Namespace`. The system then animates the
//     presented screen out of (and back into) the source's frame.
//   - It works for NavigationStack pushes, sheets AND full-screen covers.
//     We use `.fullScreenCover(isPresented:)`: the cover is driven straight
//     by the `showingBack` binding, so every way of closing it — the close
//     button, BACK TO CATCH, or the system's interactive drag-down that the
//     zoom transition adds for free — writes `false` back into the binding.
//   - Reduce Motion: the system swaps the zoom for its own gentler
//     transition; nothing in this file animates on its own.
//   - The existing photo zoom morph (`HeroZoomOverlay` on the detail screen)
//     is a different, hand-built overlay. This style doesn't touch it — the
//     caller just routes the photo tap here instead while this style is live.
//

import SwiftUI
import os

// MARK: - Pure decisions (unit-tested)

/// The zoom page's layout decisions, kept out of the view so tests can pin
/// them. `nonisolated` — plain math, no UI state.
nonisolated enum PhotoZoomMath {
    /// Minimum side margin around the card on the page.
    static let pageHorizontalInset: CGFloat = 16
    /// Space between the top chrome row (title + close button) and the card.
    static let cardTopSpacing: CGFloat = 12

    /// The size the back is laid out at on the page: the front's measured
    /// size, so it reads as the same card brought front and centre — but
    /// never wider than the page allows (`containerWidth` minus an inset on
    /// each side). Height stays the front's (the back is built to fill the
    /// front's height; the page scrolls if it's taller than the screen).
    /// nil until the front has been measured: there's nothing to match yet.
    static func pageCardSize(frontSize: CGSize, containerWidth: CGFloat,
                             inset: CGFloat = pageHorizontalInset) -> CGSize? {
        guard frontSize.width > 0, frontSize.height > 0 else { return nil }
        let available = max(0, containerWidth - 2 * inset)
        // An unmeasured container (0) shouldn't shrink the card to nothing.
        let width = available > 0 ? min(frontSize.width, available) : frontSize.width
        return CGSize(width: width, height: frontSize.height)
    }

    /// Haptic only when the page opens; closing is quiet (the drag-down
    /// already has its own physical feel).
    static func playsOpenHaptic(old: Bool, new: Bool) -> Bool {
        !old && new
    }
}

// MARK: - PhotoZoomCard

struct PhotoZoomCard<Front: View, Back: View>: View {
    @Binding var showingBack: Bool
    private let front: Front
    private let back: Back

    /// `@Namespace` gives this view its own id space for matching the zoom's
    /// source (the card) with its destination (the page).
    @Namespace private var zoomNamespace
    /// The front's measured size; the page lays the back out at this size.
    @State private var frontSize: CGSize = .zero

    private static var zoomID: String { "catch-card" }

    init(showingBack: Binding<Bool>,
         @ViewBuilder front: () -> Front, @ViewBuilder back: () -> Back) {
        self._showingBack = showingBack
        self.front = front()
        self.back = back()
    }

    var body: some View {
        front
            .onGeometryChange(for: CGSize.self) { $0.size } action: { frontSize = $0 }
            // The card is where the page zooms out of and back into.
            .matchedTransitionSource(id: Self.zoomID, in: zoomNamespace)
            .fullScreenCover(isPresented: $showingBack) {
                PhotoZoomPage(frontSize: frontSize, onClose: { showingBack = false }) {
                    back
                }
                .navigationTransition(.zoom(sourceID: Self.zoomID, in: zoomNamespace))
            }
            // A light tap on open only: the closure form of `sensoryFeedback`
            // gets the old and new values and returns nil for "no haptic".
            .sensoryFeedback(trigger: showingBack) { old, new in
                PhotoZoomMath.playsOpenHaptic(old: old, new: new) ? .impact(weight: .light) : nil
            }
            .onChange(of: showingBack) { _, isOpen in
                Log.ui.debug("card back zoom page \(isOpen ? "opened" : "closed", privacy: .public)")
            }
    }
}

// MARK: - The page

/// The full-screen "about this plane" page: a title + close button row, then
/// the back of the card centred at the front's size, then a hint.
private struct PhotoZoomPage<Back: View>: View {
    let frontSize: CGSize
    let onClose: () -> Void
    private let back: Back

    /// Moves VoiceOver to the page title when the page opens, so the new
    /// screen is announced by name instead of landing on an arbitrary view.
    @AccessibilityFocusState private var titleFocused: Bool

    init(frontSize: CGSize, onClose: @escaping () -> Void, @ViewBuilder back: () -> Back) {
        self.frontSize = frontSize
        self.onClose = onClose
        self.back = back()
    }

    var body: some View {
        // GeometryReader for the page width, so the card never overflows a
        // narrower screen than the one it was measured on.
        GeometryReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: PhotoZoomMath.cardTopSpacing) {
                    header
                    if let size = PhotoZoomMath.pageCardSize(frontSize: frontSize,
                                                              containerWidth: proxy.size.width) {
                        back
                            .frame(width: size.width, height: size.height)
                    }
                    Text("DRAG DOWN TO CLOSE")
                        .font(Brand.Font.mono(size: 10, relativeTo: .caption2))
                        .tracking(1.5)
                        .foregroundStyle(RP.faint)
                        .padding(.top, 4)
                        .padding(.bottom, 24)
                        // The close button says the same thing for
                        // VoiceOver; the gesture hint is visual-only.
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Brand.Color.bgPrimary.ignoresSafeArea())
        .onAppear { titleFocused = true }
    }

    /// "ABOUT THIS PLANE" (left) and the close disc (right), in the detail
    /// screen's chrome vocabulary.
    private var header: some View {
        HStack {
            Text("ABOUT THIS PLANE")
                .font(Brand.Font.mono(size: 11, weight: .semibold, relativeTo: .caption))
                .tracking(1.5)
                .foregroundStyle(RP.muted)
                .accessibilityLabel("About this plane")
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)
            Spacer()
            Button(action: onClose) {
                // Same disc as the detail screen's chrome pills: 36 pt
                // `.ultraThinMaterial` circle, white 10% hairline, 44 pt hit
                // target via the outset contentShape.
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: .circle)
                    .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 1))
                    .contentShape(Rectangle().inset(by: -4))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to catch")
        }
        .padding(.horizontal, PhotoZoomMath.pageHorizontalInset)
        .padding(.top, 8)
    }
}
