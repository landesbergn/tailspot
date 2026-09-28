//
//  CatchDeletionSync.swift
//  Tailspot
//
//  Tells the backend when the user deletes a catch, so it stops counting
//  toward the leaderboard and challenge scores (and stops coming back on a
//  Hangar restore). Before this, a Hangar delete was local-only: the server
//  kept the row, and all of those read the server's rows.
//
//  Wire contract:
//
//      DELETE /v1/catches/<catchUuid>
//      Authorization: Bearer <device token>
//      → 204   (also when there was nothing to delete — idempotent)
//
//  Deletes are queued in UserDefaults FIRST and then sent, so a delete made
//  offline (or one whose request fails) is retried on the next app open.
//  Only a success — or an answer that means "nothing to do" — takes a uuid
//  off the queue. Conventions mirror `PushTokenClient`: nonisolated struct,
//  injectable session / defaults / token, 15 s timeout.
//
//  Explain-as-we-go: the queue lives in UserDefaults rather than SwiftData
//  because the Catch row it refers to is already gone — there is no model
//  left to hang a "pending delete" flag on.
//

import Foundation
import os

nonisolated struct CatchDeletionSync {
    static let pendingKey = "tailspot.catches.pendingDeletes"

    let baseURL: URL
    private let session: URLSession
    private let defaults: UserDefaults
    /// The stored device token, or nil. Deliberately NOT read-or-register:
    /// a device with no token never uploaded anything, so there is nothing
    /// on the server to delete.
    private let token: @Sendable () -> String?

    init(
        baseURL: URL = TailspotAccountClient.defaultBaseURL,
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        tokenProvider: (@Sendable () -> String?)? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        self.defaults = defaults
        self.token = tokenProvider ?? {
            TailspotAccountClient(baseURL: baseURL, session: session).storedToken
        }
    }

    /// The fire-and-forget entry the delete sites and the uploader call:
    /// queue, then try to send. Capture the uuids BEFORE `modelContext.delete`
    /// — a deleted model's properties can't be read afterwards.
    static func deleteRemotely(_ catchUuids: [String]) {
        let uuids = catchUuids.filter { !$0.isEmpty }
        guard !uuids.isEmpty else { return }
        let sync = CatchDeletionSync()
        sync.enqueue(uuids)
        Task.detached { await sync.drain() }
    }

    // MARK: - Queue

    var pending: [String] {
        defaults.stringArray(forKey: Self.pendingKey) ?? []
    }

    func enqueue(_ uuids: [String]) {
        var queue = pending
        for uuid in uuids where !queue.contains(uuid) { queue.append(uuid) }
        defaults.set(queue, forKey: Self.pendingKey)
    }

    private func remove(_ uuid: String) {
        defaults.set(pending.filter { $0 != uuid }, forKey: Self.pendingKey)
    }

    // MARK: - Send

    enum Outcome: Equatable {
        /// Deleted, or nothing to delete — off the queue.
        case done
        /// Try again later (network, 5xx, auth hiccup).
        case retry
        /// Rate limited — stop this run, keep everything queued.
        case stop
    }

    /// Pure status → outcome, tested on its own.
    static func outcome(forStatus status: Int) -> Outcome {
        switch status {
        case 200..<300: return .done
        // The route answers 204 even when there's nothing to delete, so a
        // 404 only means a server that doesn't have the route yet. Keep the
        // delete queued — this build may reach phones before the backend.
        case 404: return .retry
        // A 400 means the uuid can never be valid; retrying forever helps nobody.
        case 400: return .done
        case 429: return .stop
        default: return .retry
        }
    }

    /// Send every queued delete once. Non-throwing: there is nobody to tell,
    /// and the retry is the next app open.
    func drain() async {
        let queue = pending
        guard !queue.isEmpty else { return }
        guard let token = token() else {
            // Never registered → never uploaded → nothing server-side.
            defaults.removeObject(forKey: Self.pendingKey)
            return
        }
        for uuid in queue {
            let result: Outcome
            do {
                result = Self.outcome(forStatus: try await send(catchUuid: uuid, token: token))
            } catch {
                result = .retry
            }
            switch result {
            case .done: remove(uuid)
            case .retry:
                Log.ui.error("Catch delete sync failed for one catch; will retry next open")
            case .stop:
                Log.ui.notice("Catch delete sync rate limited; deferring the rest")
                return
            }
        }
    }

    /// The bare DELETE; returns the HTTP status.
    func send(catchUuid: String, token: String) async throws -> Int {
        guard let url = URL(string: "v1/catches/\(catchUuid)", relativeTo: baseURL)?.absoluteURL else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return http.statusCode
    }
}
