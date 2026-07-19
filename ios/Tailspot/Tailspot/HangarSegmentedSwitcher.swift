//
//  HangarSegmentedSwitcher.swift
//  Tailspot
//
//  Top-of-Hangar segment switcher (Sets / Recent / Trophies).
//
//  Rebuilt 2026-06-15 (hand-rolled buttons → custom Liquid Glass track)
//  and again 2026-07-19: the custom track — even with a touch-down drag
//  gesture bolted on — never matched the native control's feel (Noah:
//  "the sliding controls don't work as well or smoothly as I want").
//  On iOS 26 the NATIVE segmented control IS the Liquid Glass
//  implementation: glass track, sliding glass thumb, touch-down
//  response, press-and-drag across segments, and full accessibility
//  (adjustable + per-segment elements), all UIKit-implemented. So this
//  is now a plain segmented Picker — the system behavior instead of an
//  approximation of it. Trade-off, made knowingly: the cyan brand pill
//  became the system glass thumb.
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

    var body: some View {
        Picker("Hangar section", selection: $selection) {
            ForEach(HangarSegment.allCases) { seg in
                Text(seg.label).tag(seg)
            }
        }
        .pickerStyle(.segmented)
        // The native control moves the thumb; this adds the selection tick
        // the glass tab bars use, firing once per actual segment change.
        .sensoryFeedback(.selection, trigger: selection)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
