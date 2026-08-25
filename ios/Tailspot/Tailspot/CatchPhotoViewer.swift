//
//  CatchPhotoViewer.swift
//  Tailspot
//
//  Full-screen pinch-zoom viewer for the user's own catch photo — opened
//  by tapping the card hero on the reveal (CatchRevealView) and the Hangar
//  detail (CatchDetailView). The card crops the photo to its hero slot;
//  this is the one place the full frame shows at full resolution.
//
//  The zooming itself is UIKit (`UIScrollView` via UIViewRepresentable)
//  ON PURPOSE — an exception to the SwiftUI-first rule: a scroll view's
//  `viewForZooming` gives pinch-anchored zoom, pan clamping, rubber-band
//  bounce, and deceleration for free, all tuned to match Photos.app.
//  Rebuilding that feel from raw SwiftUI MagnifyGesture + DragGesture is
//  a page of fiddly anchor math that still reads slightly "off" — the
//  scroll-view wrap is the standard iOS pattern for a photo lightbox.
//
//  Gestures: pinch 1x–6x · double-tap toggles 1x/3x (zooms toward the
//  tap) · single tap closes (plus the explicit X pill).
//

import SwiftUI

struct CatchPhotoViewer: View {
    /// File URL of the full-res catch JPEG (`CatchPhotoStore`). The viewer
    /// is only ever offered for local user photos — remote (Planespotters)
    /// heroes keep their TOS-required link-out instead.
    let url: URL

    @Environment(\.dismiss) private var dismiss

    /// Synchronous decode through RevealPhoto's cache: the card hero that
    /// opened this viewer decoded the SAME file, so this is a cache hit —
    /// no loading state needed. (A cold miss is the card's accepted decode
    /// cost too; see RevealPhoto's cache comment.) nil = file gone
    /// (sandbox cleared / deleted via Files) — quiet fallback below.
    private var image: UIImage? { RevealPhoto.cachedDecode(url: url) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            if let image {
                ZoomableImageView(image: image, onSingleTap: { dismiss() })
                    .ignoresSafeArea()
                    // PRIVACY: same posture as every catch-photo render
                    // site — the user's own photo is masked from PostHog
                    // session replay.
                    .catchPhotoReplayMask()
                    .accessibilityLabel("Catch photo, full screen")
            } else {
                Text("Photo unavailable")
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.Color.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // X pill — same chrome vocabulary as the detail screen's pills.
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: .circle)
                    .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 1))
                    .contentShape(Rectangle().inset(by: -4))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .padding(.top, 8)
            .padding(.leading, 16)
        }
    }
}

// MARK: - In-place pinch on the card hero

/// Pinch-to-zoom directly on a card's photo hero: the image magnifies
/// live under the fingers inside its rounded window (anchored at the
/// pinch start point, rubber-banding below 1x), and on release past
/// `openThreshold` it hands off to the full-screen
/// viewer via `onOpen`; under it, it springs back. The modifier owns the
/// hero's clip so the magnified image stays inside the photo window —
/// the card layout never moves.
///
/// `onOpen == nil` disables the gesture (mask `.subviews`) but keeps the
/// view structure identical, so surfaces can flip it on per-frame (the
/// reveal enables it only once settled) without SwiftUI rebuilding the
/// hero. Inert under ImageRenderer (pure SwiftUI, no platform views).
struct HeroPinchZoom: ViewModifier {
    /// Handoff on a committed pinch; nil = gesture off (share renders,
    /// Planespotters/placeholder heroes, unsettled reveal).
    var onOpen: (() -> Void)?

    private static let openThreshold: CGFloat = 1.25

    @State private var scale: CGFloat = 1
    @State private var anchor: UnitPoint = .center

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale, anchor: anchor)
            .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.card))
            .contentShape(RoundedRectangle(cornerRadius: Brand.Radius.card))
            .simultaneousGesture(magnify, including: onOpen != nil ? .all : .subviews)
    }

    private var magnify: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.02)
            .onChanged { value in
                anchor = value.startAnchor
                // Pinching in gets resistance, not a shrunken photo.
                scale = value.magnification >= 1
                    ? value.magnification
                    : 1 - (1 - value.magnification) * 0.3
            }
            .onEnded { value in
                if value.magnification > Self.openThreshold, let onOpen {
                    onOpen()
                    // Snap back UNDER the incoming full-screen cover: the
                    // cover's slide-up takes ~0.4 s, and an animated reset
                    // racing it reads as the photo deflating mid-handoff.
                    Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        scale = 1; anchor = .center
                    }
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        scale = 1
                    }
                }
            }
    }
}

// MARK: - UIScrollView zoom host

private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let onSingleTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSingleTap: onSingleTap) }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = FitScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.bouncesZoom = true
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        // The centering math below owns the insets; the safe area must not.
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        scroll.addSubview(imageView)
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleSingleTap))
        // Without this the single-tap fires on the first tap of a double —
        // closing the viewer when the user meant to zoom.
        singleTap.require(toFail: doubleTap)
        scroll.addGestureRecognizer(singleTap)

        // First layout happens after SwiftUI sizes the representable —
        // bounds are .zero here, so the aspect-fit frame is computed in
        // layoutSubviews (and again on any resize).
        scroll.onLayout = { [weak scroll, weak coordinator = context.coordinator] in
            guard let scroll, let coordinator else { return }
            coordinator.fitIfNeeded(scroll)
        }
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {}

    /// Plain UIScrollView that surfaces layoutSubviews to the coordinator —
    /// the one hook that fires whenever the hosting SwiftUI view (re)sizes it.
    private final class FitScrollView: UIScrollView {
        var onLayout: (() -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        private let onSingleTap: () -> Void
        /// Bounds the current image frame was fit for — skips redundant
        /// refits (layoutSubviews fires on every zoom/pan tick too).
        private var fittedSize: CGSize = .zero

        init(onSingleTap: @escaping () -> Void) {
            self.onSingleTap = onSingleTap
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        /// Aspect-fit the image at zoom 1 and center it. Re-runs only when
        /// the scroll view's bounds actually change (first layout; the app
        /// is portrait-pinned, so in practice that's the only time).
        func fitIfNeeded(_ scroll: UIScrollView) {
            guard let imageView, let image = imageView.image,
                  scroll.bounds.width > 0, scroll.bounds.height > 0 else { return }
            guard scroll.bounds.size != fittedSize else {
                center(scroll)
                return
            }
            fittedSize = scroll.bounds.size
            let scale = min(scroll.bounds.width / image.size.width,
                            scroll.bounds.height / image.size.height)
            let fit = CGSize(width: image.size.width * scale,
                             height: image.size.height * scale)
            scroll.zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: fit)
            scroll.contentSize = fit
            center(scroll)
        }

        /// Keep smaller-than-bounds content optically centered by padding
        /// with insets — the standard UIScrollView zoom-centering trick.
        private func center(_ scroll: UIScrollView) {
            let dx = max(0, (scroll.bounds.width - scroll.contentSize.width) / 2)
            let dy = max(0, (scroll.bounds.height - scroll.contentSize.height) / 2)
            scroll.contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            center(scrollView)
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView, let imageView else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else {
                // Zoom to a rect sized for 3x, centered on the tap, so the
                // detail the user tapped is what fills the screen.
                let target: CGFloat = 3
                let point = gesture.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / target,
                                  height: scroll.bounds.height / target)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2,
                                       y: point.y - size.height / 2,
                                       width: size.width, height: size.height),
                            animated: true)
            }
        }

        @objc func handleSingleTap() {
            onSingleTap()
        }
    }
}
