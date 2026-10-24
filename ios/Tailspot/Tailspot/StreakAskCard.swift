//
//  StreakAskCard.swift
//  Tailspot
//
//  The streak notification pre-prompt card, pulled out of ContentView so
//  the first ask and the one re-offer share one view (and so the snapshot
//  harness can render it; ContentView's overlay is private). ContentView
//  owns presentation, telemetry and the permission call; this view is
//  layout plus two callbacks.
//
//  Solid card, not `.glassEffect` (bare glass siblings swallow taps on
//  views below — the Profile bug, PR #127). All prose, no mono (Noah,
//  2026-08-19). Copy is his: the question leads, the mechanism explains
//  itself in one line, and neither mentions the reminder hour or a day
//  threshold — numbers in the copy go stale the moment a constant moves.
//

import SwiftUI

struct StreakAskCard: View {
    let days: Int
    /// "Notify me", or "Open Settings" for a re-offer to someone iOS
    /// already denied (the system dialog can't be shown again).
    var acceptLabel: String = "Notify me"
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Brand.Color.alertCaution)
                        // flame.fill's ink sits high in its layout box, so plain
                        // centring leaves it ~1 pt above the text. Same nudge as
                        // the Profile card's flame, scaled to this glyph size.
                        .offset(y: 1)
                        .accessibilityHidden(true)
                    HStack(spacing: 5) {
                        Text("\(days)")
                            .font(.system(.subheadline, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Brand.Color.textPrimary)
                        Text("day streak")
                            .font(.system(.subheadline, weight: .medium))
                            .foregroundStyle(Brand.Color.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(days) day streak")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Protect your streak?")
                        .font(.system(.title3, weight: .bold))
                        .foregroundStyle(Brand.Color.textPrimary)
                    Text("Turn on notifications to help keep your streak going.")
                        .font(.subheadline)
                        .foregroundStyle(Brand.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Button(action: onAccept) {
                        Text(acceptLabel)
                            .font(Brand.Font.button)
                            .foregroundStyle(Brand.Color.bgPrimary)
                            .padding(.vertical, 13)
                            .frame(maxWidth: .infinity)
                            .background(Brand.Color.cyan,
                                        in: .rect(cornerRadius: Brand.Radius.row))
                    }
                    .buttonStyle(.plain)
                    Button(action: onDecline) {
                        Text("Not now")
                            // Same size as the primary, one weight
                            // down: declining stays easy to hit and
                            // easy to read, without competing.
                            .font(.system(.callout, weight: .medium))
                            .foregroundStyle(Brand.Color.textSecondary)
                            .padding(.vertical, 13)
                            .padding(.horizontal, 20)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
            .padding(20)
            .background(Brand.Color.bgElevated,
                        in: .rect(cornerRadius: Brand.Radius.card))
            .padding(.horizontal, 16)
            // Clear the capture bar (its buttons sit ~100 pt tall with
            // the home indicator inset).
            .padding(.bottom, 110)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
