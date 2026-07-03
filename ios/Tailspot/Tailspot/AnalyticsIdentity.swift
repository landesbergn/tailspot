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

    // MARK: - Identify routing (the pinned-id fallback)

    /// How the sink should deliver an `identify(distinctId, handle:)` call,
    /// given the SDK's current identity state.
    enum IdentifyRoute: Equatable {
        /// The SDK will accept the identify: either its very first one, or a
        /// re-identify with the id it already holds (posthog-ios turns the
        /// latter into a `$set` of the user properties — the self-heal path).
        case identify
        /// The SDK is already identified under a DIFFERENT distinct_id, so
        /// posthog-ios silently drops `identify()` — the handle `$set` inside
        /// it included. Deliver the handle as a plain `$set` capture on the
        /// *current* person instead.
        case setHandleOnCurrentPerson
        /// Identify would be dropped and there is no handle to salvage.
        case drop
    }

    /// Decide how to route an identify call around a posthog-ios quirk:
    /// `identify()` is a SILENT no-op when the SDK is already identified under
    /// a different distinct_id (its different-id branch requires "not yet
    /// identified"; there is no error, no event). Devices pinned to a pre-#76
    /// throwaway local id hit exactly that every launch — the self-heal
    /// `identify(serverId, handle:)` evaporated client-side, which is why
    /// claimed handles (eagle_eye, skywatcher; found 2026-07-04) never reached
    /// their PostHog persons. The escape hatch: `$set` the handle on whatever
    /// person the SDK is pinned to — the 2026-06-26/27 server-side merges made
    /// that the same person as the server-id one, and even unmerged, labelling
    /// the active person with the handle is what makes it findable.
    ///
    /// `isIdentified` is inferred as `currentDistinctId != anonymousId`: until
    /// the first accepted identify, posthog-ios reports the anonymous id as the
    /// distinct id, and after one it keeps the anonymous id around unchanged.
    static func identifyRoute(target: String,
                              currentDistinctId: String,
                              anonymousId: String,
                              hasHandle: Bool) -> IdentifyRoute {
        let isIdentified = currentDistinctId != anonymousId
        if !isIdentified || currentDistinctId == target { return .identify }
        return hasHandle ? .setHandleOnCurrentPerson : .drop
    }

    /// Person properties to `$set` alongside the launch `identify()`, or `nil`
    /// when there's nothing to sync.
    ///
    /// Identifying at launch fixes the *person id* (events stop fragmenting) but
    /// does not, on its own, attach the `handle` person property — that is only
    /// `$set` at claim time (OnboardingFlow / SettingsScreen). So a canonical
    /// person that's missing the handle (claimed on a since-merged anonymous
    /// profile, or on an older build) would never re-acquire it just by
    /// reopening the app. Returning the on-device handle here lets the launch
    /// `identify(_:userProperties:)` re-affiliate it every run; posthog-ios
    /// dedupes an identical repeat `$set`, so doing it each launch is cheap and
    /// idempotent. Mirrors `launchIdentity`'s gate: only a real, claimed handle.
    static func launchUserProperties(handle: String?, placeholder: String) -> [String: Any]? {
        guard isClaimedHandle(handle, placeholder: placeholder),
              let handle = handle?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return ["handle": handle]
    }
}
