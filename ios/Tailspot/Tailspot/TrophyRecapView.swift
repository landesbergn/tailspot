//
//  TrophyRecapView.swift
//  Tailspot
//
//  The one-time "trophy case" recap — a full-screen celebratory sheet shown
//  the first time the unlock machinery seeds an existing Hangar, presenting
//  everything the user has ALREADY earned as one moment (instead of a
//  per-trophy unlock flood; see TrophyUnlockCenter's first-seed path). A
//  later roster expansion does not use it: those few new grants get the
//  ordinary unlock card.
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
                Self.headline(count: recap.earned, isUpdate: recap.isUpdate)
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
                .padding(.top, 44)
                .padding(.bottom, 18)

            // The case itself — every earned trophy, roster order, secrets
            // included (earning reveals them). A small case (≤ 2 rows) sits
            // directly under the headline; a full one scrolls, with the fold
            // cutting through a row as the scroll affordance.
            if recap.achievements.count <= 6 {
                // Under the headline, not floating mid-screen: the count
                // and the badges read as one statement.
                grid(t: t)
                    .padding(.top, 18)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    grid(t: t)
                        .padding(.top, 16)
                        // 28 = the fade below: scrolled to the end, the last
                        // row clears the fade instead of sitting in it.
                        .padding(.bottom, 28)
                }
                // `.mask` keeps only the parts of the view where the mask
                // shape is opaque: solid black down to the last 28 pt, then
                // a fade to clear, so the fold dissolves into RP.bg instead
                // of a hard cut right above the footer.
                .mask(
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 28)
                    }
                )
                .frame(maxHeight: .infinity)
            }

            footer(t: t)
                .padding(.top, 14)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RP.bg.ignoresSafeArea())
    }

    /// "5 new trophies" / "12 trophies earned": the whole message in one line.
    static func headline(count: Int, isUpdate: Bool) -> String {
        if isUpdate { return "\(count) New \(count == 1 ? "Trophy" : "Trophies")" }
        return "\(count) \(count == 1 ? "Trophy" : "Trophies") Earned"
    }

    private func header(t: Double) -> some View {
        // The count rolls up over the first half of the reveal,
        // reveal-ledger style.
        let count = Int((Double(recap.earned) * easeOutQuad(ss(0.10, 0.55, t))).rounded())
        return VStack(spacing: 18) {
            Text(Self.headline(count: t >= 1 ? recap.earned : count, isUpdate: recap.isUpdate))
                .brandDisplayFont()
                .foregroundColor(RP.ink)
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
                .opacity(ss(0.0, 0.2, t))
            Rectangle()
                .fill(RP.rule)
                .frame(height: 1)
                .padding(.horizontal, 44)
                .scaleEffect(x: ss(0.12, 0.4, t), anchor: .center)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.headline(count: recap.earned, isUpdate: recap.isUpdate))
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
            TrophyBadge(TrophyBadgeSpec(earnedAchievement: ach), size: 72)
            Text(TrophyTracks.displayTitle(for: ach))
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
        .accessibilityLabel("\(TrophyTracks.displayTitle(for: ach)), earned")
    }

    private func footer(t: Double) -> some View {
        VStack(spacing: 16) {
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

    /// Smoothstep of `x` between `a` and `b` — 0 before, 1 after. Kept
    /// local (not the module `ss`) for its `b > a` guard: a late row's
    /// window can collapse to zero width at t = 1.
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
