//
//  CardBackStyleUnfold.swift
//  Tailspot
//
//  Card-back style "Unfold" (design experiment, 2026-10-26 — see
//  CardBackStyles.swift). The catch card is a folded boarding pass: a short
//  ticket-stub tab ("ABOUT THIS PLANE ▾", perforated along its top edge)
//  hangs from the card's bottom edge. Tap it, or pull it down, and the back
//  (`CatchCardBack`) hinges open BELOW the card, so the catch stays in view
//  and the page grows to fit. Tap the tab again ("FOLD UP ▴"), pull it up,
//  or press the back's BACK TO CATCH to fold it away.
//
//  Explain-as-we-go — how the unfold works:
//   - One number drives everything: `progress`, 0 = folded, 1 = open. At
//     rest it comes from `showingBack`; while a finger is on the tab it
//     comes from the drag (`@GestureState`, which SwiftUI resets to nil by
//     itself when the gesture ends OR is cancelled, so a drag stolen by the
//     scroll view can't leave the panel stuck half-open).
//   - The panel is the back laid out at full size, then drawn with
//     `rotation3DEffect` around the X (horizontal) axis, anchored at its TOP
//     edge — the fold line. −90° is edge-on (folded up behind the card,
//     invisible); 0° is flat. The slot it sits in is `progress × height`
//     tall, and the angle is chosen so the tilted panel's projected height
//     matches the slot (cos(angle) = progress) — the panel's bottom edge
//     rides exactly on the slot's bottom edge, and on your finger.
//   - Height and angle must stay in step on EVERY frame. If they were two
//     separately animated values, SwiftUI would interpolate each linearly
//     and they'd drift apart mid-animation (gap or overlap under the
//     panel). So, like `FlipFace` in CardFlip.swift, the panel's modifier is
//     `Animatable`: SwiftUI animates `progress` itself and re-runs the
//     modifier's `body` per frame, which derives both from it.
//   - Because the slot's height changes per frame, the ScrollView lays the
//     screen out per frame too — the fine print below slides down smoothly.
//   - Paper-fold shading: a gradient that darkens the panel while it's
//     angled away from the light and fades out as it lies flat.
//   - Reduce Motion: no hinge. The slot still grows, and the panel fades in
//     and is revealed top-down (clipped to the slot).
//

import SwiftUI
import os

// MARK: - Pure decisions (unit-tested)

/// The unfold's pure decisions, kept out of the views so tests can pin
/// them. `nonisolated` — plain math, no UI state.
nonisolated enum UnfoldMath {
    /// The tab's height — also its hit target, so ≥ 44 pt.
    static let tabHeight: CGFloat = 44
    /// How far the folded tab is inset from each side of the card, so it
    /// hangs from the straight part of the card's bottom edge rather than
    /// under its rounded corners (Brand.Radius.hero, 26 pt). The inset goes
    /// to 0 as the panel opens and the tab becomes the full-width seam.
    static let tabInset: CGFloat = 26
    /// `rotation3DEffect` perspective — enough depth that the panel reads as
    /// tilting away, not as squashing.
    static let perspective: CGFloat = 0.5
    /// Darkest the fold shading gets (at the folded end).
    static let shadePeak: Double = 0.6
    /// A released drag opens the panel if it would land at least this far
    /// open (fraction of the panel's height), else folds it.
    static let commitThreshold: Double = 0.5
    /// Below this progress the panel fades out, so the edge-on sliver is
    /// never drawn.
    static let fadeInEnd: Double = 0.04

    static func clamped(_ progress: Double) -> Double {
        min(1, max(0, progress))
    }

    /// 1 when open, 0 when folded.
    static func restingProgress(isOpen: Bool) -> Double {
        isOpen ? 1 : 0
    }

    /// Progress while dragging: the panel's bottom edge follows the finger,
    /// so a vertical `translation` (down = positive) of one panel height is
    /// a full open/fold. Clamped to 0…1; a panel with no height can't move.
    static func dragProgress(start: Double, translation: CGFloat,
                             panelHeight: CGFloat) -> Double {
        guard panelHeight > 0 else { return clamped(start) }
        return clamped(start + Double(translation / panelHeight))
    }

    /// Whether a released drag leaves the panel open. Uses the PREDICTED end
    /// translation (where the finger's momentum would carry it), so a short
    /// fast flick commits as surely as a long slow pull, and a pull that
    /// flicks back the other way at the end doesn't.
    static func shouldOpen(start: Double, predictedTranslation: CGFloat,
                           panelHeight: CGFloat) -> Bool {
        dragProgress(start: start, translation: predictedTranslation,
                     panelHeight: panelHeight) >= commitThreshold
    }

    /// The hinge angle (degrees, around X, anchored at the panel's top) for
    /// `progress`: −90 folded, 0 flat. Picked so the tilted panel's projected
    /// height, height × cos(angle), equals the slot's, height × progress.
    static func foldAngle(progress: Double) -> Double {
        -acos(clamped(progress)) * 180 / .pi
    }

    /// The panel slot's height on the page.
    static func slotHeight(progress: Double, panelHeight: CGFloat) -> CGFloat {
        CGFloat(clamped(progress)) * max(0, panelHeight)
    }

    /// The fold shading's opacity: `shadePeak` folded, 0 flat. Linear in
    /// 1 − cos(angle), which is 1 − progress.
    static func shadeOpacity(progress: Double) -> Double {
        shadePeak * (1 - clamped(progress))
    }

    /// The panel's opacity: 0 at rest folded, fully opaque from `fadeInEnd`.
    static func panelOpacity(progress: Double) -> Double {
        min(1, clamped(progress) / fadeInEnd)
    }
}

// MARK: - UnfoldCard

struct UnfoldCard<Front: View, Back: View>: View {
    @Binding var showingBack: Bool
    private let front: Front
    private let back: Back

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The front's measured size. The back is laid out at exactly this size
    /// (CatchCardBack fills the height it's given).
    @State private var frontSize: CGSize = .zero
    /// The tab drag's vertical translation, nil when no finger is down.
    /// `@GestureState` resets by itself when the gesture ends or is
    /// cancelled; `resetTransaction` makes that reset animate, so a pull
    /// that doesn't commit springs back instead of snapping.
    @GestureState(resetTransaction: Transaction(animation: .spring(duration: 0.45, bounce: 0.1)))
    private var dragY: CGFloat? = nil

    #if DEBUG
    /// Test hook: render a frozen frame (0 = folded … 1 = open) instead of
    /// the progress `showingBack` implies. See `_snapshotProgress(_:)`.
    fileprivate var snapshotProgress: Double? = nil
    #endif

    init(showingBack: Binding<Bool>,
         @ViewBuilder front: () -> Front, @ViewBuilder back: () -> Back) {
        self._showingBack = showingBack
        self.front = front()
        self.back = back()
    }

    private var restingProgress: Double {
        UnfoldMath.restingProgress(isOpen: showingBack)
    }

    private var progress: Double {
        #if DEBUG
        if let snapshotProgress { return snapshotProgress }
        #endif
        guard let dragY else { return restingProgress }
        return UnfoldMath.dragProgress(start: restingProgress, translation: dragY,
                                       panelHeight: frontSize.height)
    }

    var body: some View {
        let progress = self.progress
        VStack(spacing: 0) {
            front
                .onGeometryChange(for: CGSize.self) { $0.size } action: { frontSize = $0 }

            // Not laid out until the front has been measured — the back
            // fills its proposed height, so it needs the front's first.
            if frontSize.width > 0, frontSize.height > 0 {
                UnfoldTab(progress: progress, isOpen: showingBack, width: frontSize.width)
                    // The drag lives on the tab ONLY, so the scroll view
                    // keeps scrolling everywhere else. `exclusively(before:)`
                    // tries the drag first; a touch that never moves 4 pt
                    // fails the drag and falls through to the tap — so one
                    // touch is never both a tap and a pull.
                    .gesture(tabDrag.exclusively(before: TapGesture().onEnded { toggle() }))
                    // VoiceOver: one button, "About this plane" / "Fold up".
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(showingBack ? "Fold up" : "About this plane")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { toggle() }
                    .zIndex(1)

                back
                    .frame(width: frontSize.width, height: frontSize.height)
                    .modifier(UnfoldPanel(progress: progress,
                                          panelHeight: frontSize.height,
                                          reduceMotion: reduceMotion))
                    // Interactive only when fully open and not mid-drag;
                    // folded, VoiceOver skips it entirely.
                    .allowsHitTesting(showingBack && dragY == nil)
                    .accessibilityHidden(!showingBack)
            }
        }
        // Programmatic changes (the tab tap, BACK TO CATCH, a committed
        // drag) animate. `value: showingBack` scopes the animation to that
        // change, so the drag itself tracks the finger with no lag.
        .animation(reduceMotion
                       ? .easeInOut(duration: 0.25)
                       : .spring(duration: 0.55, bounce: 0.12),
                   value: showingBack)
        .sensoryFeedback(.impact(weight: .light), trigger: showingBack)
    }

    private func toggle() {
        showingBack.toggle()
    }

    /// Pull the tab down to unfold, up to fold. `.updating` feeds the live
    /// translation into `dragY`; on release the predicted landing point
    /// decides which way it settles.
    private var tabDrag: some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($dragY) { value, state, _ in
                state = value.translation.height
            }
            .onEnded { value in
                let open = UnfoldMath.shouldOpen(start: restingProgress,
                                                 predictedTranslation: value.predictedEndTranslation.height,
                                                 panelHeight: frontSize.height)
                if open != showingBack {
                    Log.ui.debug("Unfold card: drag \(open ? "opened" : "folded", privacy: .public) the back")
                    showingBack = open
                }
            }
    }
}

#if DEBUG
extension UnfoldCard {
    /// Freeze the unfold at `progress` (0 = folded, 0.5 = half open,
    /// 1 = open) — for snapshot tests. nil = normal behaviour.
    func _snapshotProgress(_ progress: Double?) -> UnfoldCard {
        var copy = self
        copy.snapshotProgress = progress
        return copy
    }
}
#endif

// MARK: - Panel

/// The back's share of the unfold: its slot height, hinge angle, shading
/// and fade, all derived from one animating `progress`.
///
/// `Animatable`: SwiftUI interpolates `animatableData` (the progress) and
/// re-runs `body` every frame, so the slot height and the hinge angle are
/// always computed from the same in-between value.
private struct UnfoldPanel: ViewModifier, Animatable {
    var progress: Double
    let panelHeight: CGFloat
    let reduceMotion: Bool

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let slot = UnfoldMath.slotHeight(progress: progress, panelHeight: panelHeight)
        if reduceMotion {
            // No hinge: the panel is revealed top-down by the growing slot
            // (clipped) and fades in.
            content
                .opacity(UnfoldMath.clamped(progress))
                .frame(height: slot, alignment: .top)
                .clipped()
        } else {
            content
                .overlay { shade }
                // Anchored at the TOP edge — the fold line. Negative angles
                // tip the bottom edge away from you, up behind the card.
                .rotation3DEffect(.degrees(UnfoldMath.foldAngle(progress: progress)),
                                  axis: (x: 1, y: 0, z: 0),
                                  anchor: .top,
                                  perspective: UnfoldMath.perspective)
                .opacity(UnfoldMath.panelOpacity(progress: progress))
                // The slot is shorter than the panel while it's tilted; the
                // panel's full-size layout hangs out of the slot's bottom
                // (top-aligned) and the tilt draws it back inside. Not
                // clipped — perspective can push a hair past the slot.
                .frame(height: slot, alignment: .top)
        }
    }

    /// Paper-fold shading: darker toward the far (bottom) edge, which is
    /// tilted furthest from the light. Clipped to the card's hero radius,
    /// never interactive or read by VoiceOver.
    private var shade: some View {
        let s = UnfoldMath.shadeOpacity(progress: progress)
        return LinearGradient(
            colors: [.black.opacity(s * 0.35), .black.opacity(s)],
            startPoint: .top, endPoint: .bottom
        )
        .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.hero))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Tab

/// The ticket-stub tab under the card. Folded, it's a stub inset from the
/// card's rounded corners with rounded bottom corners; as the panel opens it
/// widens into a full-width seam between the card and the back, and its
/// chevron turns to point up.
private struct UnfoldTab: View {
    let progress: Double
    let isOpen: Bool
    let width: CGFloat

    var body: some View {
        let p = CGFloat(UnfoldMath.clamped(progress))
        let tabWidth = max(0, width - 2 * UnfoldMath.tabInset * (1 - p))
        let radius = Brand.Radius.card * (1 - p)
        // Only the bottom corners round; the top edge is the tear line.
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: radius,
                                           bottomTrailingRadius: radius,
                                           style: .continuous)

        HStack(spacing: 7) {
            Text(isOpen ? "FOLD UP" : "ABOUT THIS PLANE")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                // ▾ folded → ▴ open, turning with the panel.
                .rotationEffect(.degrees(180 * Double(p)))
        }
        .foregroundStyle(RP.muted)
        .frame(width: tabWidth, height: UnfoldMath.tabHeight)
        .background(shape.fill(RP.flapFace))
        .overlay(alignment: .top) { perforation(width: tabWidth) }
        // The whole row under the card is the hit target, not just the stub.
        .frame(width: width)
        .contentShape(Rectangle())
    }

    /// The perforation: a dashed line along the tab's top edge, where a
    /// ticket stub tears off. `Path` is itself a view; we know the width, so
    /// no GeometryReader is needed.
    private func perforation(width: CGFloat) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 8, y: 0.5))
            path.addLine(to: CGPoint(x: max(8, width - 8), y: 0.5))
        }
        .stroke(RP.faint, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        .frame(width: width, height: 1)
        .accessibilityHidden(true)
    }
}
