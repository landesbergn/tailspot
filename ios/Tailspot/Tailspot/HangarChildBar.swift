//
//  HangarChildBar.swift
//  Tailspot
//
//  Reusable top bar for child screens pushed inside the Hangar sheet
//  (SetDetailView, ModelSlotDetailView). Renders a custom chevron-back
//  button + centered title.
//
//  We need this because `HangarView` hides the system nav bar entirely
//  to render its own Lockup + count pill chrome. Without matching
//  custom chrome in the pushed children, iOS would animate the nav bar
//  in mid-transition and the content would visibly shift down — the
//  bug Noah field-reported on 2026-05-26.
//

import SwiftUI

/// Drop-in top bar for any Hangar child view. Hosts a chevron-back
/// button that calls `dismiss()` (the standard `NavigationStack`
/// pop) and a centered title. Pair with `.toolbar(.hidden, for:
/// .navigationBar)` + `.navigationBarBackButtonHidden(true)` on the
/// parent view so the system bar stays out of the picture during the
/// push transition.
struct HangarChildBar: View {
    let title: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // Centered title via overlay so it doesn't shift when the
            // back button width changes (e.g., during a transition).
            Text(title)
                // .subheadline == 15 pt at the default setting, but scales
                // with Dynamic Type (a bare size: 15 doesn't).
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 56) // keep the title clear of the chevron

            HStack(spacing: 4) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Brand.Color.cyan)
                        .frame(width: 36, height: 36)
                        // 44pt minimum hit target (HIG): keep the 36pt visual
                        // footprint, grow the tappable region 4pt past every
                        // edge via contentShape.
                        .contentShape(Rectangle().inset(by: -4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")

                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Brand.Color.bgPrimary)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Brand.Color.textPrimary.opacity(0.04))
                .frame(height: 1)
        }
    }
}
