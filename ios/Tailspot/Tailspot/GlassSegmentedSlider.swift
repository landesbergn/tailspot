//
//  GlassSegmentedSlider.swift
//  Tailspot
//
//  The shared Liquid Glass segmented slider — extracted 2026-07-19 from
//  HangarSegmentedSwitcher (four field rounds with Noah landed on this
//  construction) so the leaderboard's window switcher can share it.
//
//  Construction notes (each one earned by a field round):
//  - A GlassEffectContainer blends a glass capsule track with a
//    brand-cyan `.interactive()` glass thumb — the liquid press/stretch
//    response comes from the system, not hand animation.
//  - Glass shapes are lifted into their OWN layer composited above the
//    container's content, so the labels must live OUTSIDE the container
//    or the thumb draws over them.
//  - A zero-distance drag drives the thumb continuously under the
//    finger (Buttons fire on touch-UP — that read as lag); animating
//    the retargeted thumb x each frame makes the spring trail
//    liquid-style and springs it across on a plain tap.
//  - Selection flips discretely at boundary crossings (content + haptic
//    tick follow live); the thumb snaps to its segment's rest position
//    on release.
//  - The finger position lives in @GestureState, which auto-resets when
//    the gesture ends OR IS CANCELLED — load-bearing inside a List,
//    where the scroll pan can steal a touch mid-drag (a plain @State
//    would leave the thumb stranded at the last finger x).
//

import SwiftUI

struct GlassSegmentedSlider<Segment: Hashable, SegmentLabel: View>: View {
    @Binding var selection: Segment
    let segments: [Segment]
    var segmentHeight: CGFloat
    var trackPadding: CGFloat
    /// VoiceOver name for the whole control (it reads as one adjustable
    /// button; individual segments aren't element-navigable).
    let accessibilityTitle: String
    /// VoiceOver value for a segment (usually its visible label).
    let segmentTitle: (Segment) -> String
    /// The visible label for a segment; the slider owns layout (equal-width
    /// cells at `segmentHeight`), the caller owns type/color styling.
    @ViewBuilder let segmentLabel: (Segment, _ isSelected: Bool) -> SegmentLabel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Finger-driven thumb center x while a drag is live; nil = resting on
    /// the selected segment. Distinct from `selection` so the thumb can sit
    /// BETWEEN segments mid-drag while selection flips at crossings.
    @GestureState private var dragX: CGFloat? = nil

    init(
        selection: Binding<Segment>,
        segments: [Segment],
        segmentHeight: CGFloat = 44,
        trackPadding: CGFloat = 5,
        accessibilityTitle: String,
        segmentTitle: @escaping (Segment) -> String,
        @ViewBuilder segmentLabel: @escaping (Segment, _ isSelected: Bool) -> SegmentLabel
    ) {
        self._selection = selection
        self.segments = segments
        self.segmentHeight = segmentHeight
        self.trackPadding = trackPadding
        self.accessibilityTitle = accessibilityTitle
        self.segmentTitle = segmentTitle
        self.segmentLabel = segmentLabel
    }

    private var controlHeight: CGFloat { segmentHeight + trackPadding * 2 }

    var body: some View {
        GeometryReader { geo in
            let innerWidth = geo.size.width - trackPadding * 2
            let segmentWidth = innerWidth / CGFloat(segments.count)
            let selectedIndex = CGFloat(segments.firstIndex(of: selection) ?? 0)
            let restX = trackPadding + segmentWidth * (selectedIndex + 0.5)
            let minX = trackPadding + segmentWidth / 2
            let thumbX = dragX.map { min(max($0, minX), geo.size.width - minX) } ?? restX

            ZStack {
                // Glass only in here — see the layer-compositing note above.
                // Container-wrapping also keeps the glass from swallowing
                // sibling taps (the PR #127 lesson).
                GlassEffectContainer {
                    ZStack {
                        Capsule()
                            .fill(.clear)
                            .glassEffect(.regular, in: .capsule)
                        Capsule()
                            .fill(.clear)
                            .frame(width: segmentWidth, height: segmentHeight)
                            .glassEffect(
                                .regular.tint(Brand.Color.cyan.opacity(0.85)).interactive(),
                                in: .capsule
                            )
                            .position(x: thumbX, y: controlHeight / 2)
                    }
                }

                HStack(spacing: 0) {
                    ForEach(segments, id: \.self) { seg in
                        segmentLabel(seg, selection == seg)
                            .frame(maxWidth: .infinity, minHeight: segmentHeight)
                    }
                }
                .padding(.horizontal, trackPadding)
                .allowsHitTesting(false)   // the drag gesture owns input
            }
            // Animating the continuously-retargeted thumb x is deliberate:
            // the spring re-aims every frame, so the thumb TRAILS the finger
            // slightly and springs across on a plain tap. Reduce Motion pins
            // it directly to the target.
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: thumbX)
            .contentShape(.capsule)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragX) { value, state, _ in
                        state = value.location.x
                    }
                    .onChanged { select(atX: $0.location.x, segmentWidth: segmentWidth) }
                    .onEnded { select(atX: $0.location.x, segmentWidth: segmentWidth) }
            )
        }
        .frame(height: controlHeight)
        // The selection tick as the thumb lands on / crosses segments
        // (select() no-ops on unchanged selection, so drags only tick on
        // actual crossings).
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(segmentTitle(selection))
        .accessibilityAddTraits(.isButton)
        .accessibilityAdjustableAction { direction in
            guard let idx = segments.firstIndex(of: selection) else { return }
            switch direction {
            case .increment:
                if idx < segments.count - 1 { selection = segments[idx + 1] }
            case .decrement:
                if idx > 0 { selection = segments[idx - 1] }
            @unknown default:
                break
            }
        }
    }

    /// Map a control-local x to a segment and select it (no-op when already
    /// selected). Portrait, iPhone-only, English-only app — LTR assumed.
    private func select(atX x: CGFloat, segmentWidth: CGFloat) {
        guard segmentWidth > 0 else { return }
        let index = min(segments.count - 1, max(0, Int((x - trackPadding) / segmentWidth)))
        let seg = segments[index]
        if seg != selection { selection = seg }
    }
}
