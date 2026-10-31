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
                .padding(.horizontal, 64) // 12 pt bar inset + 44 pt back disc + 8 pt gap

            HStack(spacing: 4) {
                // The shared 44 pt back disc (ChromeButton.swift), so a
                // Hangar push looks like the catch detail's back control.
                ChromeButton(.back) { dismiss() }

                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(Brand.Color.bgPrimary)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Brand.Color.textPrimary.opacity(0.04))
                .frame(height: 1)
        }
    }
}
