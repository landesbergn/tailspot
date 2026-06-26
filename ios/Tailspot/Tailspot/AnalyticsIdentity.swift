//
//  AnalyticsIdentity.swift
//  Tailspot
//
//  Pure decision logic for *when* and *with which id* to call PostHog's
//  `identify()`. Factored out of the SDK call site so it's unit-testable
//  without touching the PostHog SDK or the network (the SDK is process-global
//  and not injectable; this logic is not).
//
//  Why this exists (the duplicate-person bug, 2026-06-26):
//  The analytics distinct_id is the server-minted device id (keychain-backed,
//  see DeviceID). On a FRESH install that id doesn't exist until the device
//  registers with the backend. The old launch path called
//  `PostHogSDK.identify(Analytics.distinctId())` unconditionally in
//  `TailspotApp.init` — which, before registration, *minted a throwaway local
//  UUID* and pinned the SDK to it. Registration then replaced the device id
//  with the server's, so every later REST event landed on a SECOND, anonymous
//  person while the SDK stayed stuck on the local-id person. One physical
//  device fragmented into two PostHog profiles (one identified + handle, one
//  anonymous holding the real product events).
//
//  The fix has two halves, both gated by this logic:
//   1. At launch we identify ONLY when a canonical device id already exists
//      AND the user has a claimed handle — i.e. a returning, registered user.
//      We read the id with `DeviceID.currentIfPresent()` (never mints), so a
//      first launch no longer pins the SDK to a soon-replaced local id.
//   2. A first-time user's SDK identify happens *after* the handle is claimed
//      (registration is awaited there), so the SDK's very first identify uses
//      the server id — see the claim sites in OnboardingFlow / SettingsScreen.
//

import Foundation

nonisolated enum AnalyticsIdentity {

    /// The canonical distinct_id to call `identify()` with at app launch, or
    /// `nil` to defer.
    ///
    /// Returns the id only for a returning, registered user: one who already
    /// has a persisted (server-minted, keychain-backed) device id AND a claimed
    /// handle. For a genuine first launch — no device id yet, or only the
    /// untouched placeholder handle — this returns `nil` so we neither mint a
    /// throwaway local id nor pin the SDK to a non-canonical identity before
    /// registration establishes the real one.
    ///
    /// - Parameters:
    ///   - deviceId: the result of `DeviceID.currentIfPresent()` — pass the
    ///     non-minting read so calling this never creates an id as a side effect.
    ///   - hasClaimedHandle: whether the user has a real, claimed handle
    ///     (see `isClaimedHandle`).
    static func launchIdentity(deviceId: String?, hasClaimedHandle: Bool) -> String? {
        guard hasClaimedHandle, let deviceId, !deviceId.isEmpty else { return nil }
        return deviceId
    }

    /// Whether `handle` is a real, user-claimed handle rather than the untouched
    /// onboarding placeholder, empty, or whitespace-only. The placeholder is
    /// passed in (rather than read from `SpotterHandle`) to keep this pure and
    /// trivially testable.
    static func isClaimedHandle(_ handle: String?, placeholder: String) -> Bool {
        guard let handle = handle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !handle.isEmpty,
              handle != placeholder else { return false }
        return true
    }
}
