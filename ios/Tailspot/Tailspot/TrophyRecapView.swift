//
//  TrophyRecapView.swift
//  Tailspot
//
//  The one-time "trophy case" recap — a full-screen celebratory sheet shown
//  on first launch after a trophy-roster expansion, presenting everything
//  the user has ALREADY earned under the new roster as one moment (instead
//  of a per-trophy unlock flood; see TrophyUnlockCenter's reseed path).
//
//  House style follows the catch reveal (CatchRevealView): the dark RP
//  palette, monospaced type, gold accents, and a count-up. Like the reveal,
//  the whole composition is a pure function of a reveal clock `t` — a
//  `TimelineView(.animation)` drives `t` from 0→1 once, then the view swaps
//  to a settled static frame (and Reduce Motion renders the settled frame
//  from the start). Keeping the body pure of animation state is also what
//  lets the snapshot harness render any beat as a static image.
//

import SwiftUI

struct TrophyRecapView: View {
    let recap: TrophyRecap
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Wall-clock start of the reveal; `t` is elapsed/duration clamped to 1.
    @State private var began = Date()
    /// Once the clock has run its course, stop the TimelineView entirely —
    /// no reason to re-render 120×/s a frame that no longer changes.
    @State private var settled = false

    private let revealDuration = 1.8

    var body: some View {
        Group {
            if settled || reduceMotion {
                content(t: 1)
            } else {
                TimelineView(.animation) { context in
                    content(t: clamp(context.date.timeIntervalSince(began) / revealDuration))
                }
            }
        }
        .onAppear {
            began = Date()
            AccessibilityNotification.Announcement(
                "Trophy case: \(recap.earned) \(recap.earned == 1 ? "trophy" : "trophies") already earned."
            ).post()
        }
        .task {
            try? await Task.sleep(for: .seconds(revealDuration + 0.1))
            settled = true
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(named: "Dismiss") { onDismiss() }
    }

    // MARK: - Composition (pure in t)

    private func content(t: Double) -> some View {
        VStack(spacing: 0) {
            header(t: t)
                .padding(.top, 30)
                .padding(.bottom, 18)

            // The case itself — every earned trophy, roster order, secrets
            // included (earning reveals them). A small case (≤ 2 rows) sits
            // centered in the open space; a full one scrolls, with the fold
            // cutting through a row as the scroll affordance.
            if recap.achievements.count <= 6 {
                Spacer(minLength: 0)
                grid(t: t)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    grid(t: t)
                        .padding(.vertical, 16)
                }
                .frame(maxHeight: .infinity)
            }

            footer(t: t)
                .padding(.top, 14)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RP.bg.ignoresSafeArea())
    }

    private func header(t: Double) -> some View {
        // The earned count rolls up over the first half of the reveal,
        // reveal-ledger style.
        let count = Int((Double(recap.earned) * easeOutQuad(ss(0.10, 0.55, t))).rounded())
        return VStack(spacing: 8) {
            Text("YOUR TROPHY CASE")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .tracking(3)
                .foregroundColor(RP.gold)
                .opacity(ss(0.0, 0.12, t))
            Text("\(count)")
                .font(.system(size: 56, weight: .heavy, design: .monospaced))
                .foregroundColor(RP.ink)
                .monospacedDigit()
                .opacity(ss(0.05, 0.2, t))
            Text(recap.earned == 1 ? "TROPHY ALREADY EARNED" : "TROPHIES ALREADY EARNED")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundColor(RP.muted)
                .opacity(ss(0.1, 0.25, t))
            Rectangle()
                .fill(RP.rule)
                .frame(height: 1)
                .padding(.horizontal, 44)
                .padding(.top, 10)
                .scaleEffect(x: ss(0.12, 0.4, t), anchor: .center)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Trophy case: \(recap.earned) \(recap.earned == 1 ? "trophy" : "trophies") already earned")
    }

    private func grid(t: Double) -> some View {
        // Column count adapts down for tiny cases so one or two trophies
        // render centered instead of pinned into the left column.
        let columns = min(3, max(1, recap.achievements.count))
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: columns),
            spacing: 22
        ) {
            ForEach(Array(recap.achievements.enumerated()), id: \.element.id) { idx, ach in
                cell(ach, idx: idx, t: t)
            }
        }
        .padding(.horizontal, 26)
    }

    private func cell(_ ach: Achievement, idx: Int, t: Double) -> some View {
        // Stagger the hexes in across the middle of the reveal. Only the
        // first ~4 rows get individual beats — everything below the fold
        // lands with the last visible row rather than dribbling in unseen.
        let staggered = min(idx, 11)
        let start = 0.30 + 0.45 * Double(staggered) / 12.0
        let p = easeOutQuad(ss(start, min(start + 0.18, 1.0), t))
        return VStack(spacing: 8) {
            TrophyView(tier: .platinum, iconName: ach.iconName, size: 72)
            Text(ach.title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(RP.muted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .opacity(p)
        .scaleEffect(0.7 + 0.3 * p)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(ach.title), earned")
    }

    private func footer(t: Double) -> some View {
        VStack(spacing: 16) {
            Text("The trophy roster just grew — these are already yours.\nMore are hidden until you find them.")
                .font(Brand.Font.caption)
                .foregroundColor(RP.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button(action: onDismiss) {
                Text("TO THE SKIES ›")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundColor(RP.bg)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(RP.gold))
                    // The gold capsule renders ~37 pt tall; the expanded hit
                    // shape tops it up to the 44 pt target.
                    .contentShape(Rectangle().inset(by: -4))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Continue")
        }
        .opacity(ss(0.55, 0.8, t))
    }

    // MARK: - Easing (local copies — CatchRevealView's are file-private)

    private func clamp(_ x: Double) -> Double { min(1, max(0, x)) }

    /// Smoothstep of `x` between `a` and `b` — 0 before, 1 after.
    private func ss(_ a: Double, _ b: Double, _ x: Double) -> Double {
        guard b > a else { return x >= b ? 1 : 0 }
        let u = clamp((x - a) / (b - a))
        return u * u * (3 - 2 * u)
    }

    private func easeOutQuad(_ x: Double) -> Double {
        let u = clamp(x)
        return 1 - (1 - u) * (1 - u)
    }

    #if DEBUG
    /// Settled final frame at a concrete size for the snapshot / visual-pass
    /// harness (the `_snapshotScreen` pattern from CatchRevealView) — pure of
    /// clock state, so the render is deterministic. DEBUG-only.
    @MainActor func _snapshotScreen(size: CGSize) -> some View {
        content(t: 1)
            .frame(width: size.width, height: size.height)
    }
    #endif
}

#Preview("Recap — a few") {
    TrophyRecapView(
        recap: TrophyRecap(achievements: Array(Trophies.roster.prefix(5))),
        onDismiss: {}
    )
}

#Preview("Recap — full case") {
    TrophyRecapView(
        recap: TrophyRecap(achievements: Array(Trophies.roster.prefix(24))),
        onDismiss: {}
    )
}
