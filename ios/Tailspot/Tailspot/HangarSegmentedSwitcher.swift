//
//  HangarSegmentedSwitcher.swift
//  Tailspot
//
//  Top-of-Hangar segment switcher (Sets / Catches / Trophies) — a thin
//  wrapper over the shared GlassSegmentedSlider (which grew out of four
//  2026-07-19 field rounds on THIS control; construction notes live
//  there). This file owns only the Hangar's segment model, label
//  styling, and outer spacing.
//

import SwiftUI

enum HangarSegment: String, CaseIterable, Identifiable {
    case sets, recent, trophies
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sets:     return "Sets"
        // Shown as "Catches" since 2026-10-30; the case keeps its old
        // name so stored selections and call sites stay put.
        case .recent:   return "Catches"
        case .trophies: return "Trophies"
        }
    }
}

struct HangarSegmentedSwitcher: View {
    @Binding var selection: HangarSegment

    var body: some View {
        GlassSegmentedSlider(
            selection: $selection,
            segments: HangarSegment.allCases,
            accessibilityTitle: "Hangar section",
            segmentTitle: { $0.label }
        ) { seg, isSelected in
            Text(seg.label)
                // Brand.Font.body == .subheadline, whose default metric is
                // the 15 pt this always was — now it scales.
                .font(Brand.Font.body.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Brand.Color.bgPrimary : Brand.Color.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
