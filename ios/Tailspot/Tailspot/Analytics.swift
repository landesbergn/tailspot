//
//  Analytics.swift
//  Tailspot
//
//  Product analytics — a thin facade over the PostHog iOS SDK. There is now a
//  SINGLE analytics pipeline: every product event, person-property `$set`, and
//  identify goes through `PostHogSDK.shared`.
//
//  History (why this used to be two pipelines): this file was originally a
//  hand-rolled, SDK-free REST pipeline (URLSession → PostHog /batch/), written
//  during the no-third-party-deps phase. The PostHog SDK was later added ONLY
//  for session replay (#41), which has no REST path — so the app ran the SDK
//  AND this REST pipeline side by side, each with its own independent identity.
//  That fragmented one device into multiple PostHog persons (the SDK's anon id
//  + a locally-minted REST id that registration then swapped to the server id,
//  with nothing aliasing the two). The dependency that justified the REST path
//  was already paid the moment the SDK shipped, so consolidating onto the SDK
//  removes the duplicate events and the whole identity-fragmentation bug class.
//  See PLAN §9 / CHANGELOG (2026-06-27).
//
//  Identity — the rule that was being broken: NEVER swap the distinct_id under
//  the SDK. The SDK owns an anonymous distinct_id from first launch; the moment
//  the device registers with the backend we call `identify(serverDeviceId)`
//  exactly once (TailspotAccountClient.ensureRegistered, and the handle-claim
//  sites), and PostHog natively aliases the prior anonymous activity into the
//  server-id person. The server device id stays the canonical person id, so
//  PostHog persons line up 1:1 with backend devices (and catches/leaderboard).
//  The backend device id itself still lives in `DeviceID` (Keychain) for the
//  catches API — it is the value we identify() to, not a separate analytics id.
//
//  No-op when the PostHog key is absent (keyless / CI / unit-test builds): the
//  production sink is nil, so every call is a silent no-op with zero network.
//  Tests inject a recording `AnalyticsSink` via `_testSink`.
//

import Foundation
import os
import PostHog

// MARK: - AnalyticsValue

/// A tagged-union property value that is Sendable and JSON-encodable
/// without importing the full Codable machinery into every call site.
/// String / Int / Double / Bool covers every event property in this version.
nonisolated enum AnalyticsValue: Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    /// The underlying value as Any, for the SDK's `[String: Any]` properties.
    var jsonValue: Any {
        switch self {
        case .string(let s): return s
        case .int(let i):    return i
        case .double(let d): return d
        case .bool(let b):   return b
        }
    }
}

// MARK: - AnalyticsSink (seam for testing)

/// The capture/identify surface, abstracted so unit tests can substitute a
/// recording fake. The PostHog SDK is process-global and not injectable, so the
/// seam lives here (around our calls) rather than around `PostHogSDK.shared`.
nonisolated protocol AnalyticsSink: Sendable {
    func capture(_ event: String, _ properties: [String: AnalyticsValue])
    func identify(_ distinctId: String, handle: String?)
    func flush()
}

/// Production sink — forwards straight to the PostHog SDK. Built only when an
/// API key is present (see `Analytics._sdkSink`), so a keyless build never
/// touches the SDK.
nonisolated private struct PostHogAnalyticsSink: AnalyticsSink {
    func capture(_ event: String, _ properties: [String: AnalyticsValue]) {
        PostHogSDK.shared.capture(event, properties: properties.mapValues { $0.jsonValue })
    }

    func identify(_ distinctId: String, handle: String?) {
        guard !distinctId.isEmpty else { return }
        if let handle, !handle.isEmpty {
            // `identify(_:userProperties:)` `$set`s the handle alongside the
            // identify. posthog-ios dedupes an identical repeat, and an already-
            // identified SDK ignores a *different* id (identify is call-once),
            // so re-calling on launch self-heals a profile missing the handle.
            PostHogSDK.shared.identify(distinctId, userProperties: ["handle": handle])
        } else {
            PostHogSDK.shared.identify(distinctId)
        }
    }

    func flush() {
        PostHogSDK.shared.flush()
    }
}

// MARK: - Analytics

nonisolated enum Analytics {

    /// Test-only recording sink. When non-nil it wins over the production sink
    /// (including in keyless builds). Set in setUp, nil in tearDown.
    nonisolated(unsafe) static var _testSink: AnalyticsSink?

    /// Production sink — nil when the PostHog API key is absent (keyless no-op).
    private static let _sdkSink: AnalyticsSink? = {
        guard let key = apiKeyFromBundle(), !key.isEmpty else {
            Log.analytics.notice("Analytics: POSTHOG_API_KEY absent — analytics disabled (no-op mode)")
            return nil
        }
        return PostHogAnalyticsSink()
    }()

    private static var sink: AnalyticsSink? { _testSink ?? _sdkSink }

    // MARK: - Public API

    /// Capture a named event with structured properties. Fire-and-forget —
    /// never throws, never blocks. No-op when the API key is absent.
    static func capture(_ event: String, _ properties: [String: AnalyticsValue] = [:]) {
        sink?.capture(event, properties)
    }

    /// Identify the current install as `distinctId` (the canonical server-minted
    /// device id), optionally `$set`ting the claimed `handle`. Call once the
    /// backend device id exists (registration / handle claim); PostHog aliases
    /// the prior anonymous activity into this person. No-op when keyless.
    static func identify(_ distinctId: String, handle: String? = nil) {
        sink?.identify(distinctId, handle: handle)
    }

    /// Force-flush queued events. The SDK flushes eagerly (flushAt = 1), so this
    /// is rarely needed; retained for symmetry and tests.
    static func flush() {
        sink?.flush()
    }

    // MARK: - Bundle key resolution

    /// The PostHog project API key from Info.plist (xcconfig-substituted), or
    /// nil/empty when unset. Shared with `PostHogSessionReplay.start()` so the
    /// SDK setup and this facade use the exact same key + key-name.
    static var apiKey: String? { apiKeyFromBundle() }

    private static func apiKeyFromBundle() -> String? {
        Bundle.main.object(forInfoDictionaryKey: "PostHogAPIKey") as? String
    }
}
