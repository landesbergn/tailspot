//
//  PrimarySheet.swift
//  Tailspot
//
//  The three full-height surfaces the catch screen presents over the AR
//  view: Hangar, Profile and (since the Challenges navigation change,
//  2026-09-15) the Leaderboard. They used to be two independent Bools
//  (`showHangar` / `showProfile`), each with its own `.sheet` and
//  `.onChange` on `ContentView.body` — and that body sits AT the Swift
//  type-checker's expression budget, so a third pair of chain links for
//  Leaders was not an option. One optional enum drives ONE `.sheet(item:)`
//  and ONE `.onChange`, which is shorter than what it replaced and covers
//  all three. `sheet(item:)` is SwiftUI's "present whichever value is
//  non-nil" form: setting the state to `.leaders` presents, setting it back
//  to nil dismisses, and the closure receives the case so it can pick the
//  content.
//
//  Every "is a primary sheet up?" gate in ContentView (camera occlusion,
//  trophy/restore overlays, the streak ask) reads `primarySheet == nil`,
//  so Leaders is automatically treated exactly like Hangar and Profile.
//

import SwiftUI

/// Which primary sheet the catch screen is showing. `Identifiable` is what
/// `.sheet(item:)` requires; the raw value doubles as the id.
///
/// `nonisolated` (the project defaults every type to `@MainActor`): this is
/// a pure value type, and `ChallengeInvitePresentation` — which is
/// nonisolated because it is pure decision logic — takes one as a
/// parameter and compares it. A MainActor-isolated `Equatable` conformance
/// could not be used there.
nonisolated enum PrimarySheet: String, Identifiable {
    case hangar, profile, leaders
    /// The Challenges hub, opened by a `tailspot.app/c/CODE` invite link.
    /// Every other way in is a push inside Profile or Leaders; a link has
    /// no stack of its own, so it gets a root sheet like those two.
    case challenges
    var id: String { rawValue }
}

/// The Leaderboard as a ROOT sheet. `LeaderboardScreen` was written to be
/// pushed inside Profile's NavigationStack (which already had a Done
/// button); presented on its own it needs its own stack and its own Done.
/// The screen itself is untouched — same title, same window switcher, same
/// podium — so the two entry points (bar button here, Profile tile there)
/// render identically.
struct LeadersSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// The screen to host. Production passes nothing and gets the live,
    /// fetching `LeaderboardScreen()`; tests pass one built with its
    /// DEBUG fixture initializer so a hosted snapshot never reaches
    /// api.tailspot.app from CI.
    private let screen: LeaderboardScreen

    init(screen: LeaderboardScreen = LeaderboardScreen()) {
        self.screen = screen
    }

    var body: some View {
        NavigationStack {
            screen
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// The Challenges hub as a ROOT sheet, for invite links. Same shape as
/// `LeadersSheet` and for the same reason: `ChallengesHub` is written to be
/// pushed inside someone else's `NavigationStack` (Profile's, Leaders'), so
/// presented on its own it needs a stack and a Done button. The hub itself
/// is untouched — it picks the pending invite code off the model and opens
/// its own join sheet, exactly as it does for a typed code.
///
/// The source is `deep_link` (`ChallengesModel.inviteSource`), which is
/// both the spec §12 vocabulary value for a link and the permission to
/// consume the pending code: no other hub may take it.
struct ChallengesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ChallengesHub(source: ChallengesModel.inviteSource)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
