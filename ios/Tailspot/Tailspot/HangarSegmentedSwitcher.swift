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
