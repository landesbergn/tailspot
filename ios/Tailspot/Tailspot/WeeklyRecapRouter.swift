//
//  WeeklyRecapRouter.swift
//  Tailspot
//
//  Opens the weekly recap when its Monday notification is tapped. Same
//  pattern as ChallengeInviteRouter: a zero-size view inside an existing
//  ContentView overlay watches `WeeklyRecapRelay.shared.pendingOpen`, closes
//  whatever primary sheet is up, waits for it to go, then presents the
//  recap sheet. (ContentView.body is at the type-checker's budget, so this
//  can't be another modifier there.)
//

import SwiftUI
import SwiftData
import os

struct WeeklyRecapRouter: View {
    let sheetOpen: PrimarySheet?
    let dismissPrimarySheet: () -> Void
    let presentRecap: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            // Runs on appear too, which delivers a cold-start tap once the
            // catch screen exists.
            .task(id: WeeklyRecapRelay.shared.pendingOpen) {
                await deliver()
            }
    }

    private func deliver() async {
        guard WeeklyRecapRelay.shared.pendingOpen else { return }
        let plan: ChallengeInvitePresentation.Plan
        switch sheetOpen {
        case .none: plan = .presentNow
        case .weeklyRecap: plan = .handInPlace
        default: plan = .dismissThenPresent
        }
        Log.ui.notice("Weekly recap notification: opening the recap")
        try? await ChallengeInvitePresentation.run(
            plan: plan,
            dismiss: dismissPrimarySheet,
            settle: ChallengeInvitePresentation.sleepForDismissal,
            present: presentRecap,
            thenClear: { WeeklyRecapRelay.shared.pendingOpen = false })
    }
}

/// The recap as a root sheet (from the notification). Computes last week
/// from the live Hangar; if the week's catches are gone, says so.
struct WeeklyRecapSheet: View {
    @Query private var catches: [Catch]
    @Environment(\.dismiss) private var dismiss
    @State private var recap: WeeklyRecap?
    @State private var loaded = false

    var body: some View {
        Group {
            if let recap {
                WeeklyRecapScreen(recap: recap)
            } else if loaded {
                NavigationStack {
                VStack(spacing: 16) {
                    Spacer()
                    Text("No catches last week")
                        .font(.title3.weight(.semibold))
                        .brandDisplayFont()
                        .foregroundStyle(Brand.Color.textPrimary)
                    Text("Catch a plane this week and your recap shows up next Monday.")
                        .font(.body)
                        .foregroundStyle(Brand.Color.textSecondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Brand.Color.bgPrimary)
                // Same native close as WeeklyRecapScreen, so the X never moves.
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .close) { dismiss() }
                    }
                }
                }
            } else {
                Brand.Color.bgPrimary
            }
        }
        .task {
            let r = WeeklyRecap.lastWeek(catches: catches)
            recap = r
            loaded = true
            if let r {
                WeeklyRecapTelemetry.fire(WeeklyRecapTelemetry.openedEvent, r,
                                          extra: ["via": .string("notification")])
            }
        }
    }
}
