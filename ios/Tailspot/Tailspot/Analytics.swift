//
//  Analytics.swift
//  Tailspot
//
//  Anonymous product analytics via PostHog's REST capture API.
//  No third-party SDK — pure URLSession against the PostHog batch
//  capture endpoint. Design is deliberately minimal and privacy-first.
//
//  Privacy posture (frozen):
//    - distinct_id = the SAME anonymous device UUID stored under the
//      "tailspot.account.deviceId" UserDefaults key that TailspotAccountClient
//      uses. If absent, the same generate-and-store logic is used so the
//      analytics ID is always the same as the account ID. No names, emails,
//      precise location, or anything ATT-triggering.
//    - Coarse region (bbox centre rounded to 1°) is acceptable in
//      aircraft-fetch events; other events carry no location at all.
//
//  No-op when key is absent:
//    - POSTHOG_API_KEY baked into Info.plist via xcconfig substitution
//      (mirrors OPENSKY_CLIENT_ID exactly). When the key is absent or
//      empty, every capture() call is a no-op: zero network, zero queue.
//
//  Queue / flush semantics:
//    - In-memory queue, capped at 500 events (drop-oldest on overflow).
//    - Auto-flush when: queue depth ≥ 10 events, OR 30-second timer fires.
//    - willResignActive flush via NotificationCenter observer.
//    - Flush: POST /batch/ with the PostHog batch envelope, fire-and-forget.
//    - One retry on transport failure; batch dropped on the second failure.
//      Analytics MUST never queue unboundedly or block main.
//
//  Capture endpoint shape (PostHog batch):
//    POST https://us.i.posthog.com/batch/
//    Content-Type: application/json
//    {
//      "api_key": "<key>",
//      "batch": [
//        {
//          "event": "<name>",
//          "distinct_id": "<deviceId>",
//          "timestamp": "2026-06-11T12:34:56.000Z",
//          "properties": { "$lib": "tailspot-ios", ... }
//        }
//      ]
//    }
//
//  DEFERRED events (need ContentView — unmerged branch owns it):
//    - ar_session_started  (ContentView scenePhase active, AR running)
//    - lock_acquired       (LockOnEngine .locked transition, icao24/rarity)
//    - catch_performed     (catch button tapped, before CatchUploader —
//                           rarity/type/slant at the moment of capture)
//    Instrument these once the ContentView branch merges.
//

import Foundation
import UIKit
import os

// MARK: - AnalyticsValue

/// A tagged-union property value that is Sendable and JSON-encodable
/// without importing the full Codable machinery into every call site.
/// String / Int / Double / Bool covers every event property in this version.
nonisolated enum AnalyticsValue: Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    /// The underlying value as Any, for use in JSON serialisation.
    var jsonValue: Any {
        switch self {
        case .string(let s): return s
        case .int(let i):    return i
        case .double(let d): return d
        case .bool(let b):   return b
        }
    }
}

// MARK: - AnalyticsTransport (seam for testing)

/// Minimal transport seam: takes the batch-body Data and sends it.
/// Production uses URLSession; tests inject a capture-and-succeed stub.
nonisolated protocol AnalyticsTransport: Sendable {
    func send(_ data: Data) async throws
}

/// Default production transport — POSTs to the PostHog batch endpoint.
nonisolated private struct PostHogTransport: AnalyticsTransport {
    private let endpoint = URL(string: "https://us.i.posthog.com/batch/")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ data: Data) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        // We don't inspect the response body — only surface hard errors upward
        // so the caller can decide to retry once.
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 500 {
            throw URLError(.badServerResponse)
        }
    }
}

// MARK: - Analytics

/// Singleton analytics client. `nonisolated` so `capture(...)` can be called
/// from any isolation context — the queue is protected by an actor underneath.
///
/// Usage:
///   Analytics.capture("app_opened", ["version": .string("1.0"), "build": .int(42)])
///
/// When the PostHog API key is absent or empty, every call is a silent no-op.
nonisolated enum Analytics {

    // MARK: - Internals

    /// Actor-isolated state: queue + flush bookkeeping.
    actor Queue {
        struct QueuedEvent: Sendable {
            let event: String
            let distinctId: String
            let timestamp: Date
            let properties: [String: AnalyticsValue]
        }

        static let maxDepth = 500
        static let flushThreshold = 10

        private var events: [QueuedEvent] = []
        private var flushTask: Task<Void, Never>?

        let apiKey: String
        let transport: any AnalyticsTransport

        init(apiKey: String, transport: any AnalyticsTransport) {
            self.apiKey = apiKey
            self.transport = transport
        }

        // MARK: Enqueue

        func enqueue(event: String, distinctId: String, properties: [String: AnalyticsValue]) {
            let e = QueuedEvent(
                event: event,
                distinctId: distinctId,
                timestamp: Date(),
                properties: properties
            )
            // Cap at maxDepth — drop oldest.
            if events.count >= Self.maxDepth {
                events.removeFirst()
            }
            events.append(e)

            if events.count >= Self.flushThreshold {
                startFlushTimer(after: 0) // immediate
            } else {
                startFlushTimerIfNeeded()
            }
        }

        // MARK: Flush

        func flush() async {
            guard !events.isEmpty else { return }
            let batch = events
            events = []
            await sendBatch(batch, retrying: true)
        }

        // MARK: Timer

        private func startFlushTimerIfNeeded() {
            guard flushTask == nil else { return }
            startFlushTimer(after: 30)
        }

        private func startFlushTimer(after seconds: TimeInterval) {
            flushTask?.cancel()
            flushTask = Task { [weak self] in
                if seconds > 0 {
                    try? await Task.sleep(for: .seconds(seconds))
                }
                guard !Task.isCancelled else { return }
                await self?.timerFired()
            }
        }

        private func timerFired() async {
            flushTask = nil
            await flush()
        }

        // MARK: Network

        private func sendBatch(_ batch: [QueuedEvent], retrying: Bool) async {
            guard let data = encodeBatch(batch) else {
                Log.analytics.error("Analytics: failed to encode batch of \(batch.count, privacy: .public) events")
                return
            }
            do {
                try await transport.send(data)
                Log.analytics.info("Analytics: flushed \(batch.count, privacy: .public) event(s)")
            } catch {
                if retrying {
                    Log.analytics.notice("Analytics: flush failed, retrying once — \(error.localizedDescription, privacy: .public)")
                    await sendBatch(batch, retrying: false)
                } else {
                    Log.analytics.error("Analytics: dropping batch of \(batch.count, privacy: .public) events after retry — \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        // MARK: JSON encoding

        private func encodeBatch(_ batch: [QueuedEvent]) -> Data? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            let events: [[String: Any]] = batch.map { e in
                var props: [String: Any] = [
                    "$lib": "tailspot-ios",
                ]
                for (k, v) in e.properties {
                    props[k] = v.jsonValue
                }
                return [
                    "event": e.event,
                    "distinct_id": e.distinctId,
                    "timestamp": formatter.string(from: e.timestamp),
                    "properties": props,
                ]
            }

            let payload: [String: Any] = [
                "api_key": apiKey,
                "batch": events,
            ]

            return try? JSONSerialization.data(withJSONObject: payload)
        }
    }

    // MARK: - Singleton queue

    /// Lazily-initialised backing queue. Nil when the API key is absent.
    private static let _queue: Queue? = {
        guard let key = apiKeyFromBundle(), !key.isEmpty else {
            Log.analytics.notice("Analytics: POSTHOG_API_KEY absent — analytics disabled (no-op mode)")
            return nil
        }
        let q = Queue(apiKey: key, transport: PostHogTransport())
        // Flush on willResignActive so batches aren't lost when the user
        // backgrounds the app mid-session.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: nil
        ) { _ in
            Task { await q.flush() }
        }
        return q
    }()

    /// Overridable queue for tests — set before calling capture().
    /// When non-nil, this wins over _queue (including when _queue would be nil).
    nonisolated(unsafe) static var _testQueue: Queue? = nil

    private static var activeQueue: Queue? { _testQueue ?? _queue }

    // MARK: - Public API

    /// Capture a named event with structured properties. Fire-and-forget —
    /// never throws, never blocks the caller. Safe to call from any actor.
    ///
    /// When the API key is absent: this is a silent no-op.
    static func capture(_ event: String, _ properties: [String: AnalyticsValue] = [:]) {
        guard let q = activeQueue else { return }
        let id = distinctId()
        Task {
            await q.enqueue(event: event, distinctId: id, properties: properties)
        }
    }

    /// Force-flush all queued events immediately. Used by test code and the
    /// willResignActive observer to ensure nothing is dropped.
    static func flush() async {
        await activeQueue?.flush()
    }

    // MARK: - DeviceID

    private static let deviceIdKey = "tailspot.account.deviceId"

    /// The anonymous device identifier — the same value TailspotAccountClient
    /// stores under "tailspot.account.deviceId". If absent (first-ever launch
    /// before any registration), we generate-and-store under that exact key
    /// so all callers share the same UUID.
    static func distinctId() -> String {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey),
           !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: deviceIdKey)
        return generated
    }

    // MARK: - Bundle key resolution

    private static func apiKeyFromBundle() -> String? {
        Bundle.main.object(forInfoDictionaryKey: "PostHogAPIKey") as? String
    }
}

// MARK: - Queue factory for testing

extension Analytics {
    /// Create a fresh test queue with an injected transport. Assign to
    /// `Analytics._testQueue` in setUp and nil it in tearDown.
    static func makeTestQueue(transport: any AnalyticsTransport) -> Queue {
        Queue(apiKey: "test-key", transport: transport)
    }
}
