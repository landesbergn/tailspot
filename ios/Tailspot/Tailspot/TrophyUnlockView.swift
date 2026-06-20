//
//  TrophyUnlockView.swift
//  Tailspot
//
//  The full-screen "moment" — a dimmed takeover over the live AR that
//  celebrates a newly-unlocked trophy. Drains `TrophyUnlockCenter`'s
//  queue one event at a time (tap to advance), and renders the one-time
//  recap first when present.
//
//  Mounted once at a root level (ContentView / HangarView) via the
//  unified `rootModal` cover — see KTD-5. Reads `head` / `pendingRecap`
//  and drives the queue through the center's methods.
//
//  Accessibility + Reduce Motion are first-class here: a hidden trophy
//  opens on a neutral `???` hex (no tier-color spoiler) and reveals to
//  its real metal; VoiceOver gets a modal label, a Dismiss action, and a
//  reveal announcement; Reduce Motion swaps the zoom/shine for a fade.
//

import SwiftUI

struct TrophyUnlockView: View {
    @ObservedObject var center: TrophyUnlockCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appeared = false
    @State private var revealed = false   // hidden `???` → real identity
    @State private var hapticTick = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea()

            if let recap = center.pendingRecap {
                recapCard(recap)
            } else if let event = center.head {
                eventCard(event)
            } else {
                Color.clear   // queue drained — the cover dismisses (U6)
            }
        }
        .sensoryFeedback(.success, trigger: hapticTick)
        // Re-run per head so each queued event gets its own commit, anim,
        // haptic, and (for hidden) `???`→reveal beat.
        .task(id: center.head?.id) { await presentHead() }
        .task(id: center.pendingRecap) {
            guard center.pendingRecap != nil else { return }
            hapticTick &+= 1
            animateIn()
        }
    }

    // MARK: - Event card

    @ViewBuilder
    private func eventCard(_ event: TrophyUnlockEvent) -> some View {
        let hiddenMasked = event.achievement.hidden && !revealed
        VStack(spacing: 18) {
            // Banner — held back until reveal so a hidden trophy's tier
            // (the metal color) isn't spoiled before its name.
            Text(hiddenMasked ? "SECRET UNLOCKED" : bannerText(event))
                .font(Brand.Font.mono(size: 12, weight: .bold))
                .tracking(2)
                .foregroundStyle(hiddenMasked ? Brand.Color.textSecondary
                                              : Color(hex: event.newTier.outerHex))

            // Hex: neutral locked-grey while `???`, real tier metal on reveal.
            Group {
                if hiddenMasked {
                    TrophyView(tier: .bronze, iconName: event.achievement.iconName,
                               size: 132, locked: true)
                } else {
                    TrophyView(tier: event.newTier, iconName: event.achievement.iconName,
                               size: 132)
                }
            }
            .scaleEffect(appeared ? 1 : (reduceMotion ? 1 : 0.4))
            .opacity(appeared ? 1 : 0)

            Text(hiddenMasked ? "???" : event.achievement.title)
                .font(Brand.Font.mono(size: 24, weight: .heavy))
                .foregroundStyle(Brand.Color.textPrimary)
                .multilineTextAlignment(.center)

            Text(hiddenMasked ? (event.achievement.teaser ?? "") : event.achievement.summary)
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            footer(remaining: center.pendingEvents.count)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { center.advance() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(accessibilityLabel(event, masked: hiddenMasked))
        .accessibilityAction(named: "Dismiss") { center.advance() }
    }

    @ViewBuilder
    private func footer(remaining: Int) -> some View {
        VStack(spacing: 10) {
            Text("Tap to continue")
                .font(Brand.Font.mono(size: 11, weight: .semibold))
                .foregroundStyle(Brand.Color.textTertiary)
            if remaining > 1 {
                Button {
                    center.skipAll()
                } label: {
                    Text("SKIP ALL · \(remaining)")
                        .font(Brand.Font.mono(size: 11, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(Brand.Color.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .overlay(Capsule().strokeBorder(Brand.Color.textTertiary.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Recap card

    @ViewBuilder
    private func recapCard(_ recap: TrophyRecap) -> some View {
        VStack(spacing: 18) {
            Text("YOUR TROPHY CASE")
                .font(Brand.Font.mono(size: 12, weight: .bold))
                .tracking(2)
                .foregroundStyle(Brand.Color.cyan)
            TrophyView(tier: .gold, iconName: "crown", size: 120)
                .scaleEffect(appeared ? 1 : (reduceMotion ? 1 : 0.4))
                .opacity(appeared ? 1 : 0)
            Text("New: trophies now unlock with a moment.")
                .font(Brand.Font.cardTitle)
                .foregroundStyle(Brand.Color.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Text("You've already earned \(recap.medals) medal\(recap.medals == 1 ? "" : "s") and \(recap.badges) badge\(recap.badges == 1 ? "" : "s"). Keep catching to unlock more.")
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Text("Tap to continue")
                .font(Brand.Font.mono(size: 11, weight: .semibold))
                .foregroundStyle(Brand.Color.textTertiary)
                .padding(.top, 4)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { center.dismissRecap() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Trophy case: \(recap.medals) medals and \(recap.badges) badges already earned. Trophies now unlock with a moment.")
        .accessibilityAction(named: "Dismiss") { center.dismissRecap() }
    }

    // MARK: - Presentation

    private func presentHead() async {
        guard let event = center.head else { return }
        center.markShown(event)                       // commit-on-shown
        revealed = !event.achievement.hidden          // non-hidden: identity up front
        hapticTick &+= 1
        animateIn()
        guard event.achievement.hidden else { return }
        // Brief `???` beat, then reveal the real metal + name.
        try? await Task.sleep(for: .seconds(reduceMotion ? 0.1 : 0.9))
        guard center.head?.id == event.id else { return }  // user didn't tap past it
        withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8)) {
            revealed = true
        }
        AccessibilityNotification.Announcement("\(event.achievement.title) unlocked").post()
    }

    private func animateIn() {
        appeared = false
        withAnimation(reduceMotion ? .easeIn(duration: 0.2)
                                   : .spring(response: 0.5, dampingFraction: 0.7)) {
            appeared = true
        }
    }

    private func bannerText(_ event: TrophyUnlockEvent) -> String {
        switch event.kind {
        case .badgeEarned: return "UNLOCKED"
        case .tierUp:      return "NEW · \(event.newTier.label)"
        }
    }

    private func accessibilityLabel(_ event: TrophyUnlockEvent, masked: Bool) -> String {
        if masked { return "Secret trophy unlocked. \(event.achievement.teaser ?? "")" }
        switch event.kind {
        case .badgeEarned: return "\(event.achievement.title) unlocked. \(event.achievement.summary)"
        case .tierUp:      return "Reached \(event.newTier.label), \(event.achievement.title). \(event.achievement.summary)"
        }
    }
}

#Preview("Tier up") {
    let center = TrophyUnlockCenter()
    center.debugEnqueueSample(hidden: false)
    return TrophyUnlockView(center: center)
}

#Preview("Hidden reveal") {
    let center = TrophyUnlockCenter()
    center.debugEnqueueSample(hidden: true)
    return TrophyUnlockView(center: center)
}
