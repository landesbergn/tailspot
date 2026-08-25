//
//  CatchPhotoViewer.swift
//  Tailspot
//
//  Full-res catch-photo viewing, opened from the card hero on the reveal
//  (CatchRevealView) and the Hangar detail (CatchDetailView) — Photos-style:
//  a pinch that starts ON the card photo grows the full image out of the
//  card toward full screen under the fingers, and a tap plays the same
//  morph automatically. The pieces:
//
//   - `HeroZoomModel` — per-screen state machine (idle → transitioning →
//     open) driving one interactive zoom transition.
//   - `HeroZoomSource` — modifier on the card hero: publishes its global
//     frame, owns the pinch gesture, hides the hero while the overlay
//     draws the photo.
//   - `HeroZoomOverlay` — full-screen layer at the screen root: renders
//     the morphing photo between the hero's crop-rect and the screen-fit
//     rect (progress 0→1), then swaps in `CatchPhotoViewer` when open.
//   - `CatchPhotoViewer` — the open end-state: black ground, X pill, and
//     a pinch-zoomable image (1x–6x).
//
//  The interactive zoom host is UIKit (`UIScrollView` via
//  UIViewRepresentable) ON PURPOSE — an exception to the SwiftUI-first
//  rule: `viewForZooming` gives pinch-anchored zoom, pan clamping,
//  rubber-band bounce, and deceleration for free, all tuned to match
//  Photos.app. The morph itself is pure SwiftUI geometry.
//
//  Gestures: pinch on the card hero opens interactively (release past
//  ~30% commits, under it springs back) · in the viewer, pinch 1x–6x ·
//  double-tap toggles 1x/3x toward the tap · single tap closes (morphs
//  back into the card), as does the X pill.
//

import SwiftUI
import Observation

// MARK: - Transition state machine

/// One per screen (owned via `@State`), shared between the hero (source
/// gesture + frame) and the overlay (rendering). Also the seam the tap
/// path uses, so tap and pinch produce the same transition.
/// `@Observable` (the Observation macro), NOT ObservableObject: views
/// holding it as a plain `let` auto-track exactly the properties they
/// read — and under the project's default MainActor isolation the
/// ObservableObject route trips an isolated-conformance error at the
/// `@ObservedObject` use site (SettledCatchCard) anyway.
@Observable
final class HeroZoomModel {
    enum Phase: Equatable {
        /// Nothing showing; hero visible.
        case idle
        /// The morph is on screen — pinch-driven or animating (open,
        /// spring-back, or close).
        case transitioning
        /// Fully open: the interactive viewer owns the screen.
        case open
    }

    private(set) var phase: Phase = .idle
    /// 0 = photo framed exactly in the card hero, 1 = full-screen fit.
    private(set) var progress: CGFloat = 0

    /// The hero's live frame in global (window) coordinates — written by
    /// `HeroZoomSource` on every layout change, read by the overlay.
    /// Observation-ignored: it changes on scroll, and the overlay only
    /// needs the value while a transition is already re-rendering it —
    /// tracked, every card scroll would invalidate the (empty) overlay.
    @ObservationIgnored var heroFrame: CGRect = .zero

    @ObservationIgnored private(set) var image: UIImage? = nil
    @ObservationIgnored private(set) var focus: CGPoint? = nil

    /// Fired once per committed open with the gesture ("tap" | "pinch") —
    /// the screen hangs its analytics here.
    @ObservationIgnored var onCommit: ((String) -> Void)?

    /// Pinch magnification that maps to progress 1 (fingers ~2x apart).
    private static let openMagnification: CGFloat = 2.0
    /// Release at or past this progress commits the open.
    private static let commitProgress: CGFloat = 0.3
    private static let settle: Animation = .spring(response: 0.32, dampingFraction: 0.86)
    private static let settleMs = 340

    func pinchChanged(magnification: CGFloat, url: URL, focus: CGPoint?) {
        guard phase != .open else { return }
        if image == nil {
            // Cache hit: the card hero decoded this same file (RevealPhoto).
            guard let decoded = RevealPhoto.cachedDecode(url: url) else { return }
            image = decoded
            self.focus = focus
        }
        phase = .transitioning
        progress = min(1, max(0, (magnification - 1) / (Self.openMagnification - 1)))
    }

    func pinchEnded() {
        guard phase == .transitioning else { return }
        if progress >= Self.commitProgress {
            commit(method: "pinch")
        } else {
            settle(to: 0, then: .idle)
        }
    }

    func openByTap(url: URL, focus: CGPoint?) {
        guard phase == .idle, let decoded = RevealPhoto.cachedDecode(url: url) else { return }
        image = decoded
        self.focus = focus
        phase = .transitioning
        progress = 0
        commit(method: "tap")
    }

    func close() {
        guard phase == .open else { return }
        phase = .transitioning
        settle(to: 0, then: .idle)
    }

    private func commit(method: String) {
        onCommit?(method)
        settle(to: 1, then: .open)
    }

    /// Animate progress to an endpoint, then adopt `end` — unless a new
    /// pinch grabbed the transition mid-flight (progress moved again).
    private func settle(to target: CGFloat, then end: Phase) {
        withAnimation(Self.settle) { progress = target }
        Task {
            try? await Task.sleep(for: .milliseconds(Self.settleMs))
            guard phase == .transitioning, progress == target else { return }
            phase = end
            if end == .idle { image = nil; focus = nil }
        }
    }
}

// MARK: - Morph geometry

/// Frame interpolation for the transition: where the image rectangle and
/// its clip live at a given progress. `fillRect` reuses `FocusFill` so
/// progress 0 matches the card hero's crop EXACTLY — the morph starts
/// pixel-aligned with what the card shows.
nonisolated enum HeroZoomMath {
    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }

    static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t),
               width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t))
    }

    /// Aspect-fit rect of the image centered in `bounds` — the same frame
    /// the viewer's UIScrollView computes at zoom 1, so the overlay→viewer
    /// swap at progress 1 is seamless.
    static func fitRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let s = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * s, height: imageSize.height * s)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// The image's aspect-fill rect inside the hero frame — focus-cropped
    /// via `FocusFill.layout` when a focus exists (identical math to
    /// RevealPhoto's render), plain center fill otherwise.
    static func fillRect(imageSize: CGSize, in rect: CGRect, focus: CGPoint?) -> CGRect {
        if let focus {
            let l = FocusFill.layout(imageSize: imageSize, frameSize: rect.size, focus: focus)
            return CGRect(x: rect.minX + l.origin.x, y: rect.minY + l.origin.y,
                          width: l.size.width, height: l.size.height)
        }
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let s = max(rect.width / imageSize.width, rect.height / imageSize.height)
        let size = CGSize(width: imageSize.width * s, height: imageSize.height * s)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}

// MARK: - Hero-side modifier

/// Applied to the card hero. Publishes the hero's global frame, attaches
/// the opening pinch, and hides the hero while the overlay owns the photo
/// (the overlay's progress-0 frame is pixel-identical, so the swap is
/// invisible). The gesture mask flips with `enabled` instead of a
/// structural if/else so toggling it (the reveal enables only once
/// settled) never changes the hero's view identity mid-ceremony.
struct HeroZoomSource: ViewModifier {
    /// Plain reference — @Observable tracking notices the `phase` read
    /// in `body` and re-renders on exactly that.
    let model: HeroZoomModel
    /// The zoomable photo (local user JPEG); nil keeps the pinch off.
    let url: URL?
    let focus: CGPoint?
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .opacity(model.phase == .idle ? 1 : 0)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                model.heroFrame = frame
            }
            .simultaneousGesture(
                MagnifyGesture(minimumScaleDelta: 0.02)
                    .onChanged { value in
                        guard let url else { return }
                        model.pinchChanged(magnification: value.magnification,
                                           url: url, focus: focus)
                    }
                    .onEnded { _ in model.pinchEnded() },
                including: enabled && url != nil ? .all : .subviews
            )
    }
}

// MARK: - Screen-root overlay

/// Place LAST in a screen's root ZStack. Empty while idle. During the
/// transition it draws the scrim + the morphing photo; once open it hosts
/// the interactive viewer. Hit-testing only when open, so an in-flight
/// pinch keeps flowing to the hero underneath.
struct HeroZoomOverlay: View {
    let model: HeroZoomModel

    var body: some View {
        GeometryReader { geo in
            if model.phase != .idle, let image = model.image {
                // Work in overlay-local coordinates: the hero frame is
                // global, so subtract this overlay's own global origin
                // (normally .zero once ignoresSafeArea makes it fill the
                // window — the translation is a guard, not a hope).
                let origin = geo.frame(in: .global).origin
                let bounds = CGRect(origin: .zero, size: geo.size)
                let hero = model.heroFrame.offsetBy(dx: -origin.x, dy: -origin.y)
                let p = model.progress

                ZStack(alignment: .topLeading) {
                    Color.black.opacity(Double(p))

                    if model.phase == .open {
                        CatchPhotoViewer(image: image, onClose: { model.close() })
                    } else {
                        let src = HeroZoomMath.fillRect(imageSize: image.size,
                                                        in: hero, focus: model.focus)
                        let dst = HeroZoomMath.fitRect(imageSize: image.size, in: bounds)
                        let img = HeroZoomMath.lerp(src, dst, p)
                        let clip = HeroZoomMath.lerp(hero, bounds, p)
                        ZStack(alignment: .topLeading) {
                            Image(uiImage: image)
                                .resizable()
                                .frame(width: img.width, height: img.height)
                                .offset(x: img.minX, y: img.minY)
                        }
                        .frame(width: geo.size.width, height: geo.size.height,
                               alignment: .topLeading)
                        .mask(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: (1 - p) * Brand.Radius.card)
                                .frame(width: clip.width, height: clip.height)
                                .offset(x: clip.minX, y: clip.minY)
                        }
                        // PRIVACY: the user's own photo, mid-morph — masked
                        // from session replay like every other render site.
                        .catchPhotoReplayMask()
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(model.phase == .open)
    }
}

// MARK: - Open end-state

struct CatchPhotoViewer: View {
    /// nil = file gone (sandbox cleared / deleted via Files) — quiet
    /// fallback below rather than a broken screen.
    let image: UIImage?
    let onClose: () -> Void

    init(image: UIImage?, onClose: @escaping () -> Void) {
        self.image = image
        self.onClose = onClose
    }

    /// Convenience for standalone hosting (snapshot tests): synchronous
    /// decode through RevealPhoto's cache.
    init(url: URL, onClose: @escaping () -> Void = {}) {
        self.init(image: RevealPhoto.cachedDecode(url: url), onClose: onClose)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            if let image {
                ZoomableImageView(image: image, onSingleTap: onClose)
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
            Button(action: onClose) {
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
