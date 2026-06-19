//
//  HandleSyncer.swift
//  Tailspot
//
//  Durably syncs the locally-chosen spotter handle to the backend.
//
//  Why this exists (the babyjoda bug, 2026-06-20):
//  Claiming a handle in onboarding/Settings was fire-and-forget. On ANY
//  non-409 failure (offline, a 401 because the device token wasn't minted
//  yet, a backend cold-start timeout) the UI persisted the handle LOCALLY
//  and moved on — with no retry. The phone then showed "@babyjoda" + her
//  points, but the server never recorded her handle, so the leaderboard
//  (which only lists devices WITH a handle) never showed her. Her *catches*
//  synced fine because `CatchUploader` retries every foreground; her handle
//  had no equivalent. This is that equivalent.
//
//  Design (mirrors CatchUploader):
//  - `@MainActor` class; `syncIfNeeded()` is idempotent and non-throwing,
//    safe to call on every `scenePhase → .active`.
//  - State is two UserDefaults keys: the chosen handle (SpotterHandle.storageKey,
//    written by the @AppStorage in onboarding/Settings) and a "confirmed"
//    marker (SpotterHandle.confirmedKey) holding the handle value the server
//    has acknowledged for THIS device. When they differ, we (re)claim.
//  - Re-claiming a handle you already own is a server-side no-op success
//    (the conflict check in store.claimHandle excludes your own device), so
//    a `confirmed == nil` fresh state safely re-confirms an already-correct
//    handle (noah) AND finally claims a stranded one (babyjoda) — one
//    mechanism backfills existing victims and prevents new ones, no
//    one-shot migration code required.
//

import Foundation
import os

/// The slice of `TailspotAccountClient` the syncer needs. A protocol seam so
/// tests drive `HandleSyncer` directly with a fake instead of the network.
protocol HandleClaiming {
    @discardableResult
    func ensureRegistered() async throws -> String
    func claimHandle(_ handle: String) async throws
}

extension TailspotAccountClient: HandleClaiming {}

@MainActor
final class HandleSyncer {
    private let client: any HandleClaiming
    private let defaults: UserDefaults

    init(client: any HandleClaiming = TailspotAccountClient(),
         defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
    }

    /// Claim the locally-chosen handle on the backend if the server hasn't
    /// confirmed it yet. Idempotent + non-throwing. Skips when there's nothing
    /// to do so the steady state costs zero network calls.
    func syncIfNeeded() async {
        let local = (defaults.string(forKey: SpotterHandle.storageKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let confirmed = defaults.string(forKey: SpotterHandle.confirmedKey)

        // Already confirmed on the backend — the common steady state.
        if local == confirmed { return }
        // No handle chosen at all.
        if local.isEmpty { return }
        // Still on the untouched default placeholder (the user never picked a
        // handle). Never auto-claim the literal placeholder string — a user
        // who genuinely picks it gets `confirmed` set via the claim path, so
        // this only guards the never-chosen case.
        if local == SpotterHandle.defaultPlaceholder && confirmed == nil { return }

        do {
            _ = try await client.ensureRegistered()
            try await client.claimHandle(local)
            defaults.set(local, forKey: SpotterHandle.confirmedKey)
            Log.ui.info("HandleSyncer: confirmed handle on backend")
        } catch AccountError.handleTaken {
            // Genuinely held by another device — can't resolve automatically.
            // Leave `confirmed` unset; the user can rename in Settings. A
            // re-attempt next foreground is harmless (a single 409).
            Log.ui.notice("HandleSyncer: handle is taken; cannot auto-claim")
        } catch {
            // Transient (offline / 5xx / not-yet-registered). Leave `confirmed`
            // unset so the next foreground retries.
            Log.ui.error("HandleSyncer: claim failed (will retry next foreground): \(error, privacy: .public)")
        }
    }
}
