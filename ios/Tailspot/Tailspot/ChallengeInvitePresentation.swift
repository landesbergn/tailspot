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
//  3. (Review of PR #289.) If the destination sheet is ALREADY the one on
//     screen, dismissing and re-presenting is not just wasteful — it is a
//     race the app loses. The resident hub consumes the parked value and
//     pushes; 450 ms later the router's re-presented hub arrives with
//     nothing left to consume, and the push the user was waiting for went
//     down with the sheet that was dismissed under it. So a destination
//     that is already up is `handInPlace`: do nothing, and let the
//     resident consumer do its job.
//
//  And the ordering rule that falls out of all three: whatever tells the
//  user something happens BEFORE the pending code is dropped, so a message
//  that never made it to the screen can't take the invite with it.
//

import Foundation

nonisolated enum ChallengeInvitePresentation {

    /// What has to happen before the invite's destination is visible.
    enum Plan: Equatable {
        /// Nothing is covering the catch screen — present immediately.
        case presentNow
        /// A DIFFERENT primary sheet is up: dismiss it, wait for the
        /// dismissal, then present.
        case dismissThenPresent
        /// The destination sheet is already on screen. Present nothing and
        /// dismiss nothing — the hub living inside it is the one consumer
        /// of the parked code / detail id, and it is already watching.
        case handInPlace
    }

    /// How long to let a sheet dismissal finish before presenting on top
    /// of it. The system dismissal animation is ~0.35 s; 0.45 s clears it
    /// with margin and is still under the "did that work?" threshold.
    static let dismissSettle: Duration = .milliseconds(450)

    /// How long to let a navigation POP finish before pushing a different
    /// destination onto the same stack. Shorter than a sheet dismissal —
    /// the push animation is ~0.35 s but the binding is free far sooner.
    static let popSettle: Duration = .milliseconds(350)

    /// The plan for a DESTINATION (the Challenges sheet): three-way,
    /// because "the destination is already up" is its own answer.
    static func plan(sheetOpen: PrimarySheet?) -> Plan {
        switch sheetOpen {
        case .none:       return .presentNow
        case .challenges: return .handInPlace
        default:          return .dismissThenPresent
        }
    }

    /// The plan for a MESSAGE (the "too old" alert, the unavailable toast):
    /// two-way, and deliberately NOT the three-way version above. An alert
    /// or a toast raised by the catch screen sits UNDER any presented
    /// sheet, the Challenges sheet included — so unlike a destination, a
    /// message always needs the sheet gone first.
    static func messagePlan(isPrimarySheetPresented: Bool) -> Plan {
        isPrimarySheetPresented ? .dismissThenPresent : .presentNow
    }

    /// Run a plan. `settle` is injected so tests drive the ordering
    /// without waiting half a second, and `thenClear` runs LAST so the
    /// pending invite code outlives the thing that consumes or explains
    /// it (see the ordering rule above).
    ///
    /// Throws on cancellation rather than swallowing it: the router's task
    /// is invalidated when the route changes or the view goes away, and a
    /// `present()` that runs after that presents the WRONG thing. Callers
    /// use `try?` — they have nothing to do with the error beyond stopping.
    @MainActor
    static func run(plan: Plan,
                    dismiss: () -> Void,
                    settle: () async throws -> Void,
                    present: () -> Void,
                    thenClear: () -> Void = {}) async throws {
        switch plan {
        case .handInPlace:
            // Nothing to present and nothing to dismiss. `thenClear` still
            // runs so a message path that resolves in place can drop its
            // pending value.
            break
        case .dismissThenPresent:
            dismiss()
            try await settle()
            try Task.checkCancellation()
            present()
        case .presentNow:
            present()
        }
        thenClear()
    }

    /// The production `settle`: a plain sleep that propagates cancellation.
    static func sleepForDismissal() async throws {
        try await Task.sleep(for: dismissSettle)
    }

    /// The production settle for a pop-then-push on one navigation stack.
    static func sleepForPop() async throws {
        try await Task.sleep(for: popSettle)
    }
}
