//
//  HangarSegmentedSwitcher.swift
//  Tailspot
//
//  3-segment switcher used at the top of the Hangar sheet. Cyan-on-
//  bgElevated, matches the canvas design. Spec § 4.1.
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
        HStack(spacing: 2) {
            ForEach(HangarSegment.allCases) { seg in
                Button {
                    selection = seg
                } label: {
                    Text(seg.label)
                        .font(.system(size: 13, weight: selection == seg ? .semibold : .medium))
                        .foregroundStyle(selection == seg ? Brand.Color.textPrimary : Brand.Color.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            selection == seg
                                ? Brand.Color.bgSurface
                                : Color.clear,
                            in: .rect(cornerRadius: 8)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
