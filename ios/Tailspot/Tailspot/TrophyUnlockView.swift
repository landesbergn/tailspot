//
//  TrophyUnlockView.swift
//  Tailspot
//
//  The full-screen "moment" — an opaque branded takeover over the live AR
//  that celebrates a newly-unlocked achievement. Drains
//  `TrophyUnlockCenter`'s queue one event at a time (tap to advance), and
//  renders the one-time recap first when present.
//
//  Mounted once at a root level (ContentView) — see KTD-5. Achievements are
//  binary now: every unlock is just "UNLOCKED" (or "SECRET UNLOCKED" for a
//  previously-hidden one), in the brand cyan, not a metal tier.
//
//  Accessibility + Reduce Motion are first-class: VoiceOver gets a modal
//  label, a Dismiss action, and an unlock announcement; Reduce Motion swaps
//  the zoom/shine for a fade.
//

import SwiftUI

struct TrophyUnlockView: View {
    @ObservedObject var center: TrophyUnlockCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appeared = false
    @State private var hapticTick = 0
    @State private var rayAngle = 0.0

    /// Achievements render in a single cyan-family hex — set apart from the
    /// rarity/type pills by shape + a consistent cool tone (not gold).
    private let tier: TrophyTier = .platinum

    var body: some View {
        ZStack {
            // Opaque branded spotlight — a clean full takeover, not a
            // translucent scrim over the live camera.
            RadialGradient(
                colors: [Brand.Color.bgElevated, Brand.Color.bgPrimary],
                center: .center, startRadius: 0, endRadius: 520
            )
            .ignoresSafeArea()

            if let recap = center.pendingRecap {
                // The one-time full-screen "trophy case" recap (its own
                // composition, reveal-styled) — presented before the queue.
                TrophyRecapView(recap: recap) { center.dismissRecap() }
            } else if let event = center.head {
                eventCard(event)
            } else {
                Color.clear   // queue drained — the cover dismisses (U6)
            }
        }
        .sensoryFeedback(.success, trigger: hapticTick)
        // Keyed on `eventTaskKey` (nil while a recap is up) so an event queued
        // *behind* the recap isn't committed/animated until the recap is
        // dismissed — then it re-fires for its proper entrance.
        .task(id: eventTaskKey) { await presentHead() }
        .task(id: center.pendingRecap) {
            guard center.pendingRecap != nil else { return }
            hapticTick &+= 1
            animateIn()
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 22).repeatForever(autoreverses: false)) {
                rayAngle = 360
            }
        }
    }

    // MARK: - Celebratory hex (glow halo + rotating ray burst behind it)

    @ViewBuilder
    private func celebratoryHex(_ iconName: String, size: CGFloat) -> some View {
        ZStack {
            // Soft cyan halo.
            Circle()
                .fill(RadialGradient(
                    colors: [Brand.Color.cyan.opacity(0.30), .clear],
                    center: .center, startRadius: 0, endRadius: size * 1.25))
                .frame(width: size * 2.6, height: size * 2.6)
            // Slowly-rotating rays, faded at the center so they don't cover the
            // hex, and at the rim. Suppressed under Reduce Motion.
            if !reduceMotion {
                RayBurst(count: 12)
                    .fill(Brand.Color.cyan.opacity(0.18))
                    .frame(width: size * 2.4, height: size * 2.4)
                    .mask(RadialGradient(
                        colors: [.clear, .white, .clear],
                        center: .center, startRadius: size * 0.55, endRadius: size * 1.2))
                    .rotationEffect(.degrees(rayAngle))
            }
            TrophyView(tier: tier, iconName: iconName, size: size)
        }
        .scaleEffect(appeared ? 1 : (reduceMotion ? 1 : 0.4))
        .opacity(appeared ? 1 : 0)
    }

    // MARK: - Event card

    @ViewBuilder
    private func eventCard(_ event: TrophyUnlockEvent) -> some View {
        VStack(spacing: 18) {
            Text("NEW TROPHY")
                .font(Brand.Font.mono(size: 13, weight: .heavy))
                .tracking(4)
                .foregroundStyle(Brand.Color.cyan)

            celebratoryHex(event.achievement.iconName, size: 132)

            Text(event.achievement.title)
                .font(Brand.Font.mono(size: 24, weight: .heavy))
                .foregroundStyle(Brand.Color.textPrimary)
                .multilineTextAlignment(.center)

            Text(event.achievement.summary)
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
        .accessibilityLabel("\(event.achievement.title) unlocked. \(event.achievement.summary)")
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

    // MARK: - Presentation

    /// Task id for the event presentation — nil while a recap is showing, so
    /// the event behind it isn't committed/animated early; flips to the head's
    /// id when the recap clears, re-firing `presentHead`.
    private var eventTaskKey: String? {
        center.pendingRecap == nil ? center.head?.id : nil
    }

    private func presentHead() async {
        guard center.pendingRecap == nil, let event = center.head else { return }
        center.markShown(event)                       // commit-on-shown
        hapticTick &+= 1
        animateIn()
        AccessibilityNotification.Announcement("\(event.achievement.title) unlocked").post()
    }

    private func animateIn() {
        appeared = false
        withAnimation(reduceMotion ? .easeIn(duration: 0.2)
                                   : .spring(response: 0.5, dampingFraction: 0.7)) {
            appeared = true
        }
    }
}

/// A starburst of `count` triangular rays radiating from center — the soft
/// celebration glow behind a new trophy.
private struct RayBurst: Shape {
    let count: Int
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let halfWidth = (.pi / Double(count)) * 0.5
        for i in 0..<count {
            let a = Double(i) / Double(count) * 2 * .pi
            p.move(to: c)
            p.addLine(to: CGPoint(x: c.x + CGFloat(cos(a - halfWidth)) * r,
                                  y: c.y + CGFloat(sin(a - halfWidth)) * r))
            p.addLine(to: CGPoint(x: c.x + CGFloat(cos(a + halfWidth)) * r,
                                  y: c.y + CGFloat(sin(a + halfWidth)) * r))
            p.closeSubpath()
        }
        return p
    }
}

// `#Preview`'s trailing closure is a `@ViewBuilder`, so it can't hold an
// explicit `return` or an intermediate `Void`-returning setup call. Build the
// configured center in an immediately-invoked closure on the argument instead,
// keeping the builder body a single view expression.
//
// Both previews must live inside `#if DEBUG`: they call
// `TrophyUnlockCenter.debugEnqueueSample`, which is itself `#if DEBUG`-only.
// `#Preview` bodies are compiled in every configuration, so without this guard
// a Release build (device deploy / archive) fails to resolve the call even
// though Debug simulator builds and the unit-test CI don't.
#if DEBUG
#Preview("Unlock") {
    TrophyUnlockView(center: {
        let center = TrophyUnlockCenter()
        center.debugEnqueueSample(secret: false)
        return center
    }())
}

#Preview("Secret unlock") {
    TrophyUnlockView(center: {
        let center = TrophyUnlockCenter()
        center.debugEnqueueSample(secret: true)
        return center
    }())
}
#endif
