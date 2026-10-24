//
//  GuessRecreditSweep.swift
//  Tailspot
//
//  One-time re-credit of old bonus-round guesses.
//
//  From 1.1.0 through 1.2.2 a fresh catch uploaded before its bonus-round
//  guess resolved, and the server keeps the original row when a catch is
//  replayed, so it never saw the guess and never paid the +25% bonus (about
//  1,950 correct guesses). #355 fixed new catches. The phone still has every
//  old guess frozen on its Catch row, so this sweep sends each one once:
//
//      POST /v1/catches/<serverUuid>/guess
//      { "kind": "route"|"type", "value": "KSFO", "localCorrect": true }
//      → 200 { applied, points, guessKind, guessCorrect }
//        404 { code: "catch_not_found" }   409 { code: "after_cutover" }
//
//  The server re-checks TYPE guesses itself and trusts `localCorrect` for
//  ROUTE guesses, but only for catches it stored before a fixed cutover.
//
//  Shape of a run:
//  - Runs on each foreground until it has finished once, then never again
//    (`completeKey` in UserDefaults). Each finished row gets
//    `guessRecreditedAt`, so a run killed halfway resumes where it stopped.
//  - The row fetch runs on a background `@ModelActor` (its own ModelContext
//    off the main thread) and hands back plain values. Marking a row done
//    happens on the main context, like every other Catch write in the app.
//  - Any network trouble stops the run quietly; the next foreground resumes.
//    A 404 without the route's `code` means the server is older than the
//    endpoint ("not deployed yet"): stop and try again later, never mark done.
//  - Paced under the server's 120/min per-device limit.
//

import Foundation
import SwiftData
import os

/// One row to send: plain values, safe to hand across actors.
/// `PersistentIdentifier` is SwiftData's Sendable handle to a row.
nonisolated struct GuessRecreditCandidate: Sendable, Equatable {
    let id: PersistentIdentifier
    let serverUuid: String
    let kind: String
    let value: String
    let localCorrect: Bool
}

/// Reads candidate rows off the main thread.
///
/// `@ModelActor` is a SwiftData macro: it turns this actor into the owner of
/// its own `ModelContext` (`modelContext`), created from the container you
/// pass in and only ever used on this actor's executor, which is a
/// background thread. The main UI context is untouched while the fetch runs.
@ModelActor
actor GuessRecreditReader {
    /// Rows with a guess the server may never have seen: answered, given an
    /// upload uuid, uploaded, and not yet handled by the sweep. A row that
    /// hasn't uploaded yet needs nothing from here: its upload carries the
    /// guess (fixed in #355).
    /// The value and uuid checks happen in Swift below: a five-clause
    /// `#Predicate` is past what the compiler will type-check in time.
    static let candidatePredicate = #Predicate<Catch> {
        $0.guessKind != nil && $0.uploadedAt != nil && $0.guessRecreditedAt == nil
    }

    func candidates() throws -> [GuessRecreditCandidate] {
        var descriptor = FetchDescriptor<Catch>(predicate: Self.candidatePredicate)
        descriptor.sortBy = [SortDescriptor(\Catch.caughtAt, order: .forward)]
        return try modelContext.fetch(descriptor).compactMap { (row: Catch) -> GuessRecreditCandidate? in
            guard let uuid = row.serverUuid, let kind = row.guessKind,
                  let value = row.guessValue, !kind.isEmpty, !value.isEmpty else { return nil }
            return GuessRecreditCandidate(
                id: row.persistentModelID, serverUuid: uuid, kind: kind, value: value,
                localCorrect: row.guessCorrect ?? false)
        }
    }
}

/// What one POST came back as. Pure mapping, tested on its own.
nonisolated enum GuessRecreditOutcome: Equatable, Sendable {
    /// The server stored the guess and re-scored the catch.
    case applied(correct: Bool)
    /// The catch already had a guess on the server. Nothing changed.
    case alreadyHadGuess
    /// Not this device's catch on the server (deleted, or a re-registered
    /// device). It will never succeed.
    case notFound
    /// Stored after the server's re-credit cutover. It will never succeed.
    case afterCutover
    /// The server refused the body (400/422). Retrying sends the same body.
    case rejected
    /// 429: wait and retry the same row.
    case rateLimited(retryAfter: TimeInterval?)
    /// The server doesn't have the endpoint yet (an un-coded 404, or 410).
    case endpointMissing
    /// Auth, server error, no network: stop, try again next launch.
    case retryLater

    /// Whether the row is finished with, whatever the answer was.
    var marksRowDone: Bool {
        switch self {
        case .applied, .alreadyHadGuess, .notFound, .afterCutover, .rejected: return true
        case .rateLimited, .endpointMissing, .retryLater: return false
        }
    }

    private struct Body: Decodable {
        var applied: Bool?
        var guessCorrect: Bool?
        var code: String?
    }

    static func classify(status: Int, body: Data, retryAfter: String?) -> GuessRecreditOutcome {
        let decoded = try? JSONDecoder().decode(Body.self, from: body)
        switch status {
        case 200:
            // A 200 means the server handled it. Missing fields read as "no".
            if decoded?.applied == true { return .applied(correct: decoded?.guessCorrect == true) }
            return .alreadyHadGuess
        case 404:
            // The route's own 404 carries a code; Fastify's "no such route"
            // 404 from a server without this endpoint does not.
            return decoded?.code == "catch_not_found" ? .notFound : .endpointMissing
        case 410:
            return .endpointMissing
        case 409:
            return decoded?.code == "after_cutover" ? .afterCutover : .retryLater
        case 400, 422:
            return .rejected
        case 429:
            return .rateLimited(retryAfter: retryAfter.flatMap { TimeInterval($0) })
        default:
            return .retryLater
        }
    }
}

/// Counts for the end-of-run `guess_recredit_sent` event.
nonisolated struct GuessRecreditTally: Equatable, Sendable {
    enum StopReason: String, Sendable {
        case none, endpointMissing = "endpoint_missing", network, rateLimited = "rate_limited",
             cancelled
    }

    var candidates = 0
    var applied = 0
    /// Applied AND correct: these earned the bonus.
    var credited = 0
    var alreadyHadGuess = 0
    var notFound = 0
    var afterCutover = 0
    var rejected = 0
    var stop: StopReason = .none

    var finished: Int { applied + alreadyHadGuess + notFound + afterCutover + rejected }

    mutating func record(_ outcome: GuessRecreditOutcome) {
        switch outcome {
        case .applied(let correct):
            applied += 1
            if correct { credited += 1 }
        case .alreadyHadGuess: alreadyHadGuess += 1
        case .notFound: notFound += 1
        case .afterCutover: afterCutover += 1
        case .rejected: rejected += 1
        case .rateLimited, .endpointMissing, .retryLater: break
        }
    }

    var properties: [String: AnalyticsValue] {
        [
            "candidates": .int(candidates),
            "sent": .int(finished),
            "applied": .int(applied),
            "credited": .int(credited),
            "already_had_guess": .int(alreadyHadGuess),
            "not_found": .int(notFound),
            "after_cutover": .int(afterCutover),
            "rejected": .int(rejected),
            "remaining": .int(candidates - finished),
            "stopped": .string(stop.rawValue),
        ]
    }
}

/// The sweep itself. MainActor (the default isolation) so the row writes and
/// the `isRunning` guard live on one actor, like `CatchDeletionSync`.
struct GuessRecreditSweep {
    /// Bump the suffix only to deliberately run the sweep again on every
    /// device (a new server cutover, say).
    static let completeKey = "tailspot.guessRecredit.v1.complete"
    static let eventName = "guess_recredit_sent"

    /// One run at a time, app-wide (foregrounds can overlap a slow run).
    private static var isRunning = false

    let baseURL: URL
    private let session: URLSession
    private let defaults: UserDefaults
    private let token: () -> String?
    /// Gap between requests. 0.6 s ≈ 100/min, under the 120/min per-device
    /// limit and leaving room on the shared per-IP bucket.
    private let pace: Duration
    /// Longest single 429 wait, and how many waits a run allows.
    private let maxRateLimitWait: TimeInterval
    private let maxRateLimitWaits: Int
    private let capture: (String, [String: AnalyticsValue]) -> Void

    init(
        baseURL: URL = TailspotAccountClient.defaultBaseURL,
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        tokenProvider: (() -> String?)? = nil,
        pace: Duration = .milliseconds(600),
        maxRateLimitWait: TimeInterval = 60,
        maxRateLimitWaits: Int = 5,
        capture: @escaping (String, [String: AnalyticsValue]) -> Void = { Analytics.capture($0, $1) }
    ) {
        self.baseURL = baseURL
        self.session = session
        self.defaults = defaults
        self.token = tokenProvider ?? {
            TailspotAccountClient(baseURL: baseURL, session: session).storedToken
        }
        self.pace = pace
        self.maxRateLimitWait = maxRateLimitWait
        self.maxRateLimitWaits = maxRateLimitWaits
        self.capture = capture
    }

    var isComplete: Bool { defaults.bool(forKey: Self.completeKey) }

    /// Run once if the sweep hasn't finished on this device. Never throws:
    /// there is nobody to tell, and the retry is the next foreground.
    /// Returns the tally when it had rows to send (for tests).
    @discardableResult
    func runIfNeeded(container: ModelContainer) async -> GuessRecreditTally? {
        guard !isComplete, !Self.isRunning else { return nil }
        Self.isRunning = true
        defer { Self.isRunning = false }

        // Not registered (or the Keychain is locked): nothing can be sent.
        guard let token = token() else { return nil }

        let candidates: [GuessRecreditCandidate]
        do {
            candidates = try await GuessRecreditReader(modelContainer: container).candidates()
        } catch {
            Log.ui.error("Guess re-credit: fetch failed: \(error, privacy: .public)")
            return nil
        }
        guard !candidates.isEmpty else {
            defaults.set(true, forKey: Self.completeKey)
            return nil
        }
        Log.ui.info("Guess re-credit: \(candidates.count, privacy: .public) guess(es) to send")

        let context = container.mainContext
        var tally = GuessRecreditTally()
        tally.candidates = candidates.count
        var rateLimitWaits = 0

        sweep: for (index, candidate) in candidates.enumerated() {
            if index > 0 { try? await Task.sleep(for: pace) }
            while true {
                if Task.isCancelled { tally.stop = .cancelled; break sweep }
                let outcome = await send(candidate, token: token)
                if outcome.marksRowDone {
                    tally.record(outcome)
                    markDone(candidate.serverUuid, context: context)
                    break
                }
                switch outcome {
                case .rateLimited(let retryAfter):
                    guard rateLimitWaits < maxRateLimitWaits else {
                        tally.stop = .rateLimited
                        break sweep
                    }
                    rateLimitWaits += 1
                    let wait = min(max(retryAfter ?? 1.2, 0), maxRateLimitWait)
                    try? await Task.sleep(for: .seconds(wait))
                    // loop retries the same row
                case .endpointMissing:
                    tally.stop = .endpointMissing
                    break sweep
                default:
                    tally.stop = .network
                    break sweep
                }
            }
        }

        do {
            try context.save()
        } catch {
            Log.ui.error("Guess re-credit: save failed: \(error, privacy: .public)")
        }
        if tally.stop == .none {
            defaults.set(true, forKey: Self.completeKey)
        }
        Log.ui.info(
            "Guess re-credit: sent \(tally.finished, privacy: .public)/\(tally.candidates, privacy: .public), credited \(tally.credited, privacy: .public), stopped=\(tally.stop.rawValue, privacy: .public)"
        )
        // Only runs that got answers are counted. A run that stopped on its
        // first request (offline, or the server not deployed yet) would
        // otherwise fire on every foreground until it gets through.
        if tally.finished > 0 {
            capture(Self.eventName, tally.properties)
        }
        return tally
    }

    /// Stamp the row on the main context. Looked up by `serverUuid` rather
    /// than the background id, so a row deleted mid-run is simply not found.
    private func markDone(_ serverUuid: String, context: ModelContext) {
        var descriptor = FetchDescriptor<Catch>(predicate: #Predicate { $0.serverUuid == serverUuid })
        descriptor.fetchLimit = 1
        guard let row = try? context.fetch(descriptor).first else { return }
        row.guessRecreditedAt = Date()
    }

    /// The POST; transport errors read as "try again later".
    func send(_ candidate: GuessRecreditCandidate, token: String) async -> GuessRecreditOutcome {
        guard let url = URL(string: "v1/catches/\(candidate.serverUuid)/guess", relativeTo: baseURL)?
            .absoluteURL else { return .rejected }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "kind": candidate.kind, "value": candidate.value, "localCorrect": candidate.localCorrect,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .retryLater }
            return GuessRecreditOutcome.classify(
                status: http.statusCode, body: data,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        } catch {
            return .retryLater
        }
    }
}
