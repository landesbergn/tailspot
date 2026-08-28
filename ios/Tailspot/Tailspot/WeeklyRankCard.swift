//
//  WeeklyRankCard.swift
//  Tailspot
//
//  The first-catch landing moment (plan U3, R8/KD4): after the reveal,
//  route guess, suspect review, and trophy celebration have all settled,
//  the new catcher sees their place on the THIS WEEK leaderboard — the
//  climbable board, not the all-time one that compounds forever.
//
//  Sequencing (KTD4): ContentView arms this at first-catch insert and
//  presents only when the post-reveal arbitration is clear. The rank
//  fetch pre-warms at catch time, in parallel with the celebration; the
//  card mounts only once resolved. A pending upload or slow fetch
//  degrades to rank-free copy within the A5 budget — the moment always
//  renders and never blocks anything.
//

import SwiftUI

/// What the card shows. `rank` nil = the A5 rank-free fallback (upload
/// pending / fetch failed / backend reported unranked).
nonisolated struct WeeklyRankMoment: Equatable {
    let rank: Int?
    /// Debug forced run (R10) — real read-only fetch, badged.
    let forced: Bool
}

/// Pure presentation-gate + rank mapping, kept out of ContentView so the
/// arbitration order is unit-testable (plan U3 test scenarios).
nonisolated enum WeeklyRankArbitration {

    /// The moment may present only when every prior claimant of the
    /// post-catch sequence has settled: reveal covers down, suspect
    /// Keep/Discard resolved, trophy queue drained, streak notification
    /// pre-prompt answered (on a fresh install's first catch the ask is
    /// staged by default — day-1 streaks are eligible since #213), no
    /// sheet on top, and nothing already showing or resolving.
    static func canPresent(
        armed: Bool,
        revealUp: Bool,
        suspectReviewUp: Bool,
        trophiesPending: Bool,
        streakAskUp: Bool,
        sheetUp: Bool,
        alreadyShowing: Bool,
        resolving: Bool
    ) -> Bool {
        armed && !revealUp && !suspectReviewUp && !trophiesPending
            && !streakAskUp && !sheetUp && !alreadyShowing && !resolving
    }

    /// The backend reports `rank: 0` for a device with zero in-window
    /// points (the upload hasn't landed yet) — that is "unranked", never a
    /// displayable place.
    static func displayRank(_ standing: MyStanding?) -> Int? {
        guard let rank = standing?.rank, rank > 0 else { return nil }
        return rank
    }
}

/// Pre-warmed rank resolution. Started at catch time so the network
/// round-trips overlap the reveal/trophy celebration; the presentation
/// side awaits it with the short A5 budget.
@MainActor
final class WeeklyRankPrewarm {
    var task: Task<Int?, Never>?
    /// Outer `nil` = not finished; `.some(x)` = finished with rank `x`
    /// (which is itself nil for the rank-free fallback). `awaitRank` polls
    /// this instead of awaiting `task.value`: a non-throwing task's value
    /// cannot be awaited with a deadline (cancelling the awaiting child
    /// does not make the await return, and `withTaskGroup` waits for all
    /// children), so a result slot is the only shape that actually bounds
    /// the celebration's wall-clock wait to the A5 budget.
    var resolved: Int??

    func cancel() {
        task?.cancel()
        task = nil
        resolved = nil
    }

    /// The one place that knows the endpoint/window/mapping triple — the
    /// pre-warm path and the debug forced loop both call it.
    static func fetchRankNow() async -> Int? {
        let response = try? await TailspotAccountClient().leaderboard(window: .week, limit: 1)
        return WeeklyRankArbitration.displayRank(response?.me)
    }

    /// Wait for the catch's upload to confirm (the per-catch sweep runs in
    /// parallel), then fetch the caller's weekly standing. Internally
    /// generous (a slow field upload can still land a rank) — the
    /// presentation-side `awaitRank(budgetSeconds:)` is what keeps the
    /// celebration snappy.
    func start(isUploaded: @escaping @MainActor () -> Bool) {
        cancel()
        task = Task { @MainActor in
            let uploadDeadline = Date().addingTimeInterval(30)
            while !isUploaded() && Date() < uploadDeadline && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard isUploaded(), !Task.isCancelled else {
                resolved = .some(nil)
                return nil
            }
            let rank = await Self.fetchRankNow()
            resolved = .some(rank)
            return rank
        }
    }

    /// Race the pre-warmed resolution against the A5 presentation budget.
    /// Truly bounded: returns the resolved rank, or nil once the budget
    /// elapses — the underlying task keeps running harmlessly and a later
    /// call returns its cached result.
    func awaitRank(budgetSeconds: Double) async -> Int? {
        let deadline = Date().addingTimeInterval(budgetSeconds)
        while resolved == nil && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return resolved ?? nil
    }
}

/// The bottom celebration card — same solid-card shape as the streak ask
/// (bare glass siblings swallow taps, PR #127). Mono for the rank readout,
/// prose for the human lines.
struct WeeklyRankCardView: View {
    let moment: WeeklyRankMoment
    let onSeeBoard: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Brand.Color.cyan)
                        .accessibilityHidden(true)
                    Text("FIRST CATCH")
                        .font(Brand.Font.mono(size: 11, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(Brand.Color.textTertiary)
                    if moment.forced {
                        ForcedBadge()
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    if let rank = moment.rank {
                        Text("#\(rank) this week")
                            .font(.system(.title3, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Brand.Color.textPrimary)
                        Text("The weekly board resets every Monday — plenty of room to climb.")
                            .font(.subheadline)
                            .foregroundStyle(Brand.Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("This week's board is waiting")
                            .font(.system(.title3, weight: .bold))
                            .foregroundStyle(Brand.Color.textPrimary)
                        Text("Your catch lands on it once it syncs. The board resets every Monday.")
                            .font(.subheadline)
                            .foregroundStyle(Brand.Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 12) {
                    Button(action: onSeeBoard) {
                        Text("See the board")
                            .font(Brand.Font.button)
                            .foregroundStyle(Brand.Color.bgPrimary)
                            .padding(.vertical, 13)
                            .frame(maxWidth: .infinity)
                            .background(Brand.Color.cyan,
                                        in: .rect(cornerRadius: Brand.Radius.row))
                    }
                    .buttonStyle(.plain)
                    Button(action: onDismiss) {
                        Text("Done")
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
            .padding(.bottom, 110)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
