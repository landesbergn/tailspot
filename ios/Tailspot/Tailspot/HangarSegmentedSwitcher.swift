//
//  HangarSegmentedSwitcher.swift
//  Tailspot
//
//  Top-of-Hangar segment switcher (Sets / Recent / Trophies).
//
//  Rebuilt 2026-06-15: the hand-rolled version had ~30pt-tall buttons
//  whose taps dropped near the edges (Noah field-reported laggy/missed
//  taps). This version uses an iOS 26 Liquid Glass track with a
//  matched-geometry selection pill, 44pt-tall tap targets, and a capsule
//  `contentShape` so the whole segment is hittable.
//

import SwiftUI

enum HangarSegment: String, CaseIterable, Identifiable {
    case sets, recent, trophies
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sets:     return "Sets"
        case .recent:   return "Recent"
        case .trophies: return "Trophies"
        }
    }
}

struct HangarSegmentedSwitcher: View {
    @Binding var selection: HangarSegment
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Track width captured for the drag→segment mapping below (equal-width
    /// segments, so an x position maps to an index by simple division).
    @State private var trackWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 6) {
            ForEach(HangarSegment.allCases) { seg in
                segmentButton(seg)
            }
        }
        // Animate ONLY the pill, scoped to the switcher. Previously the tap
        // used withAnimation { selection = ... }, which animated the whole
        // downstream content swap (Sets/Recent/Trophies rebuild) — that's what
        // felt slow/laggy. Here the content swaps instantly; just the pill slides.
        // Under Reduce Motion the pill jumps instead of sliding.
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: selection)
        .padding(5)
        .glassEffect(.regular, in: .capsule)   // iOS 26 Liquid Glass track
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            trackWidth = width
        }
        // Touch-down + slide selection, matching the native iOS 26 glass
        // segmented control (field report 2026-07-19: the Button-only version
        // felt laggy because Buttons fire on touch-UP — the pill couldn't
        // move until the finger lifted — and the track didn't support the
        // press-and-drag-across-segments pattern at all). minimumDistance 0
        // makes .onChanged fire the moment the finger lands, so the pill and
        // shading respond instantly, and dragging slides the selection
        // segment-by-segment under the finger. simultaneousGesture keeps the
        // Buttons working for plain taps and accessibility. The gesture is
        // confined to the switcher, so it can't fight the page TabView's
        // content swipe below.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { select(atX: $0.location.x) }
                .onEnded { select(atX: $0.location.x) }
        )
        // The native control's selection tick as the pill crosses segments
        // (fires on tap-switch too; trigger dedupes on unchanged selection).
        .sensoryFeedback(.selection, trigger: selection)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // Container semantics so VoiceOver users can also step segments
        // with the adjustable swipe (the per-button .isSelected traits
        // stay for element-by-element navigation).
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hangar section")
        .accessibilityValue(selection.label)
        .accessibilityAdjustableAction { direction in
            let all = HangarSegment.allCases
            guard let idx = all.firstIndex(of: selection) else { return }
            switch direction {
            case .increment:
                if idx < all.count - 1 { selection = all[idx + 1] }
            case .decrement:
                if idx > 0 { selection = all[idx - 1] }
            @unknown default:
                break
            }
        }
    }

    /// Map a track-local x position to a segment and select it (no-op when
    /// already selected, so a drag only writes — and only ticks the haptic —
    /// on actual crossings). Segments are equal-width thirds of the track;
    /// the 5 pt track padding is negligible against a ~120 pt segment. The
    /// app is portrait, iPhone-only, and English-only, so LTR is assumed.
    private func select(atX x: CGFloat) {
        guard trackWidth > 0 else { return }
        let all = HangarSegment.allCases
        let segmentWidth = trackWidth / CGFloat(all.count)
        let index = min(all.count - 1, max(0, Int(x / segmentWidth)))
        let seg = all[index]
        if seg != selection { selection = seg }
    }

    private func segmentButton(_ seg: HangarSegment) -> some View {
        let isSelected = selection == seg
        return Button {
            selection = seg
        } label: {
            Text(seg.label)
                .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Brand.Color.bgPrimary : Brand.Color.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Brand.Color.cyan)
                            .matchedGeometryEffect(id: "hangarSegPill", in: pill)
                    }
                }
                .contentShape(.capsule)   // full-segment hit area
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
