//
//  ChallengeInviteRouter.swift
//  Tailspot
//
//  The bridge between "a tailspot.app/c/CODE link opened the app" and the
//  catch screen actually showing something. `TailspotApp` parses the URL
//  and parks the code on `ChallengesModel`; this zero-size view watches
//  (verdict, pendingInviteCode), turns them into a `ChallengesModel.InviteRoute`
//  with the model's pure routing function, and reports it.
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

    /// Show the Challenges surface; the hub picks the pending code up and
    /// opens the join sheet with it.
    let onJoin: (String) -> Void
    /// The kill switch is on — say so in the host's toast slot.
    let onUnavailable: () -> Void

    /// Non-nil while the "too old to join" alert is up; carries the
    /// server's minimum build for the log line.
    @State private var updateRequiredMinBuild: Int?

    var body: some View {
        // A zero-size, non-interactive view: it exists only to observe.
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            // `.task(id:)` rather than `.onChange(of:initial:)`: it runs on
            // appear AND on every route change, and it runs after the view
            // update instead of inside it — this closure both writes local
            // state and clears the code on the model.
            .task(id: model?.inviteRoute) {
                deliver(model?.inviteRoute)
            }
            .alert("Update Tailspot to join this challenge",
                   isPresented: Binding(
                    get: { updateRequiredMinBuild != nil },
                    set: { if !$0 { updateRequiredMinBuild = nil } }
                   )) {
                Link("Open the App Store", destination: appStoreURL)
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

    private func deliver(_ route: ChallengesModel.InviteRoute?) {
        guard let model, let route else { return }
        switch route {
        case .join(let code):
            // The code stays parked — the hub clears it when it opens the
            // join sheet, so this survives the sheet's presentation.
            Log.ui.notice("Challenge invite link: opening join for a code")
            onJoin(code)
        case .updateRequired(let minBuild):
            model.clearPendingInvite()
            updateRequiredMinBuild = minBuild
            Analytics.capture("challenge_invite_opened", [
                "via": .string("universal_link"),
                "status": .string("update_required"),
            ])
        case .unavailable:
            model.clearPendingInvite()
            onUnavailable()
            Analytics.capture("challenge_invite_opened", [
                "via": .string("universal_link"),
                "status": .string("unavailable"),
            ])
        case .waitForConfig:
            // `openInvite` is already refreshing the config; when it lands
            // this fires again with a real verdict.
            break
        }
    }
}
