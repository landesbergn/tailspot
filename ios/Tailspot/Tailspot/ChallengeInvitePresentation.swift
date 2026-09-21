//
//  ChallengeInvitePresentation.swift
//  Tailspot
//
//  The sequencing an invite link needs when something is already on
//  screen, split into a pure decision and one async step so it can be
//  tested without a view.
//
//  Two real problems it solves, both found in review:
//
//  1. Swapping `primarySheet` from one case straight to another relies on
//     `.sheet(item:)` noticing the id change and re-presenting. That is
//     not reliable — the dismissal and the presentation race, and the new
//     sheet can be swallowed. Dismiss, let the dismissal finish, then
//     present.
//  2. An alert or a toast published by the catch screen is UNDER any
//     presented sheet, so "your build is too old" said while the Hangar
//     is open is said to nobody. Same fix, same order.
//
//  And the ordering rule that falls out of both: whatever tells the user
//  something happens BEFORE the pending code is dropped, so a message
//  that never made it to the screen can't take the invite with it.
//

import Foundation

nonisolated enum ChallengeInvitePresentation {

    /// What has to happen before the invite's destination is visible.
    enum Plan: Equatable {
        /// Nothing is covering the catch screen — present immediately.
        case presentNow
        /// A primary sheet is up: dismiss it, wait for the dismissal, then
        /// present.
        case dismissThenPresent
    }

    /// How long to let a sheet dismissal finish before presenting on top
    /// of it. The system dismissal animation is ~0.35 s; 0.45 s clears it
    /// with margin and is still under the "did that work?" threshold.
    static let dismissSettle: Duration = .milliseconds(450)

    static func plan(isPrimarySheetPresented: Bool) -> Plan {
        isPrimarySheetPresented ? .dismissThenPresent : .presentNow
    }

    /// Run a plan. `settle` is injected so tests drive the ordering
    /// without waiting half a second, and `thenClear` runs LAST so the
    /// pending invite code outlives the thing that consumes or explains
    /// it (see the ordering rule above).
    @MainActor
    static func run(plan: Plan,
                    dismiss: () -> Void,
                    settle: () async -> Void,
                    present: () -> Void,
                    thenClear: () -> Void = {}) async {
        if plan == .dismissThenPresent {
            dismiss()
            await settle()
        }
        present()
        thenClear()
    }

    /// The production `settle`: a plain sleep. `try?` because the task
    /// this runs in is cancelled when the route changes or the view goes
    /// away, and a cancelled wait should just stop waiting.
    static func sleepForDismissal() async {
        try? await Task.sleep(for: dismissSettle)
    }
}
