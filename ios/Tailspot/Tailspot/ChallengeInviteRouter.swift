//
//  ChallengeInviteRouter.swift
//  Tailspot
//
//  The bridge between "a tailspot.app/c/CODE link opened the app" and the
//  catch screen actually showing something. `TailspotApp` parses the URL
//  and parks the code on `ChallengesModel`; this zero-size view watches
//  (verdict, pendingInviteCode), turns them into a `ChallengesModel.InviteRoute`
//  with the model's pure routing function, and drives the presentation
//  through `ChallengeInvitePresentation` — which is where the "dismiss
//  what's open, wait, then present, and only then drop the code" order
//  lives.
//
//  Why a view and not another modifier on `ContentView.body`: that body
//  sits AT the Swift type-checker's expression budget (PR #184, and the
//  whole reason `PrimarySheet` exists), so a new `.onChange` + `.alert`
//  pair on the chain is not an option. A sub-view placed inside an
//  EXISTING overlay closure observes the model on its own, owns its own
//  alert, and costs the body nothing.
//
//  Explain-as-we-go: reading `model.verdict` / `model.pendingInviteCode`
//  inside `body` is what subscribes this view to them — that's the
//  Observation framework (iOS 17+): no publishers, no `objectWillChange`,
//  the view re-renders when exactly those properties change. `.task(id:)`
//  also runs once when the view appears, which is what delivers a link
//  that landed while onboarding was still up, or before this screen
//  existed.
//

import SwiftUI
import os

/// An invite code on its way to the join sheet. `sheet(item:)` wants an
/// `Identifiable` and a bare `String` isn't one; the code is its own id.
struct InviteLinkCode: Identifiable, Equatable {
    let id: String
}

struct ChallengeInviteRouter: View {
    /// Optional so previews, tests and any host without the app-wide
    /// model render nothing instead of trapping — same shape as
    /// `ChallengesFlagButton`.
    @Environment(ChallengesModel.self) private var model: ChallengesModel?
    /// The alert's App Store action. An `.alert` builder keeps Buttons and
    /// may drop anything else, so a `Link` in there can silently vanish —
    /// a Button that calls `openURL` is the supported shape.
    @Environment(\.openURL) private var openURL

    /// WHICH primary sheet is covering the catch screen right now, not just
    /// whether one is. Everything this router shows is invisible or
    /// unreliable under a sheet — but the Challenges sheet is a special
    /// case, because it is the destination: dismissing and re-presenting it
    /// destroys the push its resident hub was about to make. See
    /// `ChallengeInvitePresentation.plan(sheetOpen:)`.
    let sheetOpen: PrimarySheet?
    /// Close whatever primary sheet is up (`primarySheet = nil`).
    let dismissPrimarySheet: () -> Void
    /// Show the Challenges sheet. The hub inside it is the ONE consumer of
    /// the pending code (`ChallengesModel.consumePendingInvite(for:)`), so
    /// this router never clears it on the happy path.
    let presentChallenges: () -> Void
    /// The kill switch is on — say so in the host's toast slot.
    let showUnavailableToast: () -> Void

    /// Non-nil while the "too old to join" alert is up; carries the
    /// server's minimum build for the log line.
    @State private var updateRequiredMinBuild: Int?

    var body: some View {
        // A zero-size, non-interactive view: it exists only to observe.
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            // `.task(id:)` rather than `.onChange(of:initial:)`: it runs on
            // appear AND on every route change, it runs after the view
            // update instead of inside it, and it gives the async context
            // the dismiss-then-present sequence needs.
            .task(id: model?.inviteRoute) {
                await deliver(model?.inviteRoute)
            }
            // A tapped challenge notification parks a detail id on the
            // model (`ChallengesModel.openChallenge(id:)`). Same job as the
            // invite route above, same sequencing, one less decision: there
            // is no build gate on READING a challenge you are already in, so
            // a parked id always means "show it".
            .task(id: model?.pendingDetailId) {
                await deliverDetail(model?.pendingDetailId)
            }
            .alert("Update Tailspot to join this challenge",
                   isPresented: Binding(
                    get: { updateRequiredMinBuild != nil },
                    set: { if !$0 { updateRequiredMinBuild = nil } }
                   )) {
                Button("Update Tailspot") { openURL(appStoreURL) }
                Button("Not now", role: .cancel) { updateRequiredMinBuild = nil }
            } message: {
                Text("This version of the app is too old for the current challenge rules.")
            }
    }

    /// The server can hand down its own listing URL (config `appStoreURL`);
    /// otherwise the app's own campaign-attributed listing link.
    private var appStoreURL: URL {
        if let raw = model?.config?.appStoreURL, let url = URL(string: raw) {
            return url
        }
        return AppStoreListing.url(campaign: "Challenge Invite")
    }

    /// Present the Challenges sheet for a notification tap. The id stays
    /// parked: the hub inside the sheet consumes it and pushes the detail,
    /// the same one-owner handover the invite code uses.
    private func deliverDetail(_ detailId: String?) async {
        guard detailId != nil else { return }
        let plan = ChallengeInvitePresentation.plan(sheetOpen: sheetOpen)
        guard plan != .handInPlace else {
            // The Challenges sheet is already up and its hub is already
            // watching `pendingDetailId`. Dismissing it here would take the
            // hub's push down with it and hand the re-presented hub nothing.
            Log.ui.notice("Challenge notification: Challenges already open, hub takes it")
            return
        }
        Log.ui.notice("Challenge notification: opening Challenges for a detail")
        try? await ChallengeInvitePresentation.run(
            plan: plan,
            dismiss: dismissPrimarySheet,
            settle: ChallengeInvitePresentation.sleepForDismissal,
            present: presentChallenges)
    }

    private func deliver(_ route: ChallengesModel.InviteRoute?) async {
        guard let model, let route else { return }
        // Two plans, on purpose: a DESTINATION that is already up needs
        // nothing done to it, while a MESSAGE always needs the sheet gone
        // first because alerts and toasts render under one.
        let destinationPlan = ChallengeInvitePresentation.plan(sheetOpen: sheetOpen)
        let plan = ChallengeInvitePresentation.messagePlan(
            isPrimarySheetPresented: sheetOpen != nil)

        switch route {
        case .join:
            // The code stays parked: the hub inside the Challenges sheet
            // consumes it (and only that hub does). Clearing here would
            // hand the sheet an empty join.
            //
            // Same `handInPlace` rule as a notification tap: if the
            // Challenges sheet is already up, its hub is already watching
            // the route, and re-presenting would race its join sheet away.
            guard destinationPlan != .handInPlace else {
                Log.ui.notice("Challenge invite link: Challenges already open, hub takes it")
                return
            }
            Log.ui.notice("Challenge invite link: opening Challenges for a code")
            try? await ChallengeInvitePresentation.run(
                plan: destinationPlan,
                dismiss: dismissPrimarySheet,
                settle: ChallengeInvitePresentation.sleepForDismissal,
                present: presentChallenges)

        case .updateRequired(let minBuild):
            // Alert first, drop the code second — an alert that never
            // reached the screen must not take the invite with it.
            try? await ChallengeInvitePresentation.run(
                plan: plan,
                dismiss: dismissPrimarySheet,
                settle: ChallengeInvitePresentation.sleepForDismissal,
                present: {
                    updateRequiredMinBuild = minBuild
                    Analytics.capture("challenge_invite_opened", [
                        "via": .string("universal_link"),
                        "status": .string("update_required"),
                    ])
                },
                thenClear: { model.clearPendingInvite() })

        case .unavailable:
            try? await ChallengeInvitePresentation.run(
                plan: plan,
                dismiss: dismissPrimarySheet,
                settle: ChallengeInvitePresentation.sleepForDismissal,
                present: {
                    showUnavailableToast()
                    Analytics.capture("challenge_invite_opened", [
                        "via": .string("universal_link"),
                        "status": .string("unavailable"),
                    ])
                },
                thenClear: { model.clearPendingInvite() })

        case .waitForConfig:
            // `openInvite` is already refreshing the config; when it lands
            // this fires again with a real verdict.
            break
        }
    }
}
