//
//  ComingSoonPill.swift
//  Tailspot
//
//  Reusable callout that marks a screen as preview-only — visible
//  in the UI but backed by mock data or non-functional toggles.
//  Prevents the "is this broken?" loop for early testers when they
//  tap into Leaderboard, Public Hangar, or Notifications and find
//  no real backend behind them.
//
//  Visual: small amber pill with a hammer.fill SF Symbol + COMING
//  SOON label. Amber = "caution / not yet" per Brand semantics
//  (see Brand.Color.alertWarning).
//

import SwiftUI

struct ComingSoonPill: View {
    /// Optional sublabel rendered after the dot — e.g., "mock data"
    /// or "no push delivery yet". Lets each surface explain what
    /// specifically isn't real, while keeping the affordance uniform.
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 11, weight: .semibold))
            Text("COMING SOON")
                .font(Brand.Font.mono(size: 10, weight: .bold))
                .tracking(1.4)
            if let subtitle {
                Text("·").foregroundStyle(Brand.Color.alertWarning.opacity(0.5))
                Text(subtitle)
                    .font(Brand.Font.mono(size: 10, weight: .regular))
                    .foregroundStyle(Brand.Color.alertWarning.opacity(0.85))
            }
        }
        .foregroundStyle(Brand.Color.alertWarning)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(Brand.Color.alertWarning.opacity(0.14))
        )
        .overlay(
            Capsule().strokeBorder(Brand.Color.alertWarning.opacity(0.45), lineWidth: 1)
        )
    }
}

/// Full-width banner variant for screens where a pill would be too
/// subtle (e.g., directly under the screen title). Shows the pill
/// inline with a one-line explanation.
struct ComingSoonBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            ComingSoonPill()
            Text(message)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Brand.Color.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Brand.Color.bgElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Brand.Color.alertWarning.opacity(0.25), lineWidth: 1)
        )
    }
}

#Preview {
    VStack(spacing: 16) {
        ComingSoonPill()
        ComingSoonPill(subtitle: "mock data")
        ComingSoonBanner(message: "Leaderboard rows are placeholders until the backend ships.")
    }
    .padding(24)
    .background(Brand.Color.bgPrimary)
}
