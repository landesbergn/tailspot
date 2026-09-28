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
//  Two lists in UserDefaults (the Catch row is already gone, so there is no
//  model left to hang a flag on):
//  - `pending`: deletes not yet confirmed by the server. Queued FIRST, then
//    sent; only a success leaves the queue, so an offline delete retries on
//    the next app open.
//  - `deleted`: a ledger of every uuid the user deleted (bounded). The server
//    keeps no tombstone, so a POST that lands AFTER the DELETE (an upload
//    that was in flight when the user deleted) puts the catch back. The
//    uploader checks this ledger after each POST and re-sends the delete;
//    Hangar restore skips ledger uuids so a deleted catch isn't offered back.
//
//  MainActor (the default isolation) on purpose: every read-modify-write of
//  the two lists happens on one actor, and `isDraining` keeps two sends from
//  overlapping — two concurrent drains could otherwise drop a uuid that was
//  enqueued between one's read and its write.
//

import Foundation
import os

struct CatchDeletionSync {
    static let pendingKey = "tailspot.catches.pendingDeletes"
    static let deletedKey = "tailspot.catches.deletedLedger"
    /// Enough for any real Hangar; the oldest entries fall off first.
    static let ledgerLimit = 2000

    /// One drain at a time, app-wide.
    private static var isDraining = false

    let baseURL: URL
    private let session: URLSession
    private let defaults: UserDefaults
    /// The stored device token, or nil. Deliberately NOT read-or-register:
    /// registering can't help delete something uploaded under a token we
    /// can't read, and a missing read may be transient (Keychain locked),
    /// so a nil KEEPS the queue for next time rather than dropping it.
    private let token: () -> String?

    init(
        baseURL: URL = TailspotAccountClient.defaultBaseURL,
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        tokenProvider: (() -> String?)? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        self.defaults = defaults
        self.token = tokenProvider ?? {
            TailspotAccountClient(baseURL: baseURL, session: session).storedToken
        }
    }

    /// The entry the delete sites and the uploader call: record, queue, then
    /// try to send in the background. Capture the uuids BEFORE
    /// `modelContext.delete` — a deleted model's properties can't be read.
    static func deleteRemotely(_ catchUuids: [String]) {
        let sync = CatchDeletionSync()
        sync.enqueue(catchUuids)
        Task { await sync.drain() }
    }

    // MARK: - Lists

    var pending: [String] { defaults.stringArray(forKey: Self.pendingKey) ?? [] }
    var ledger: [String] { defaults.stringArray(forKey: Self.deletedKey) ?? [] }

    /// Whether the user deleted this catch (case-folded, as uuids are
    /// compared everywhere else).
    func wasDeleted(_ uuid: String) -> Bool {
        ledger.contains(uuid.lowercased())
    }

    /// Every deleted uuid, lowercased — for Hangar restore to skip.
    var deletedSet: Set<String> { Set(ledger) }

    func enqueue(_ uuids: [String]) {
        let clean = uuids.map { $0.lowercased() }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return }
        var queue = pending
        for uuid in clean where !queue.contains(uuid) { queue.append(uuid) }
        defaults.set(queue, forKey: Self.pendingKey)
        var book = ledger
        for uuid in clean where !book.contains(uuid) { book.append(uuid) }
        if book.count > Self.ledgerLimit { book.removeFirst(book.count - Self.ledgerLimit) }
        defaults.set(book, forKey: Self.deletedKey)
    }

    private func remove(_ uuid: String) {
        defaults.set(pending.filter { $0 != uuid }, forKey: Self.pendingKey)
    }

    // MARK: - Send

    enum Outcome: Equatable {
        /// Deleted, or nothing to delete — off the queue.
        case done
        /// This one failed; try the rest, and it again next open.
        case retry
        /// Stop this run and keep everything (rate limit, auth, no network).
        case stop
    }

    /// Pure status → outcome, tested on its own.
    static func outcome(forStatus status: Int) -> Outcome {
        switch status {
        case 200..<300: return .done
        // A 400 means the uuid can never be valid; retrying forever helps nobody.
        case 400: return .done
        // The route answers 204 even when there's nothing to delete, so a
        // 404 only means a server that doesn't have the route yet. Keep it.
        case 404: return .retry
        // Rate limited, or the token isn't accepted (a disabled device, a
        // rotated token): every other request would get the same answer.
        case 401, 403, 429: return .stop
        default: return .retry
        }
    }

    /// Send every queued delete once. Non-throwing: there is nobody to tell,
    /// and the retry is the next app open. A call while another drain is
    /// running returns immediately — the running one re-reads the queue as
    /// it goes, so anything enqueued meanwhile is sent in the same pass.
    func drain() async {
        guard !Self.isDraining else { return }
        Self.isDraining = true
        defer { Self.isDraining = false }

        guard !pending.isEmpty else { return }
        guard let token = token() else {
            Log.ui.notice("Catch delete sync: no device token readable; keeping \(pending.count, privacy: .public) queued")
            return
        }
        var attempted = Set<String>()
        while let uuid = pending.first(where: { !attempted.contains($0) }) {
            attempted.insert(uuid)
            let result: Outcome
            do {
                result = Self.outcome(forStatus: try await send(catchUuid: uuid, token: token))
            } catch {
                // No network (or a timeout): the rest would fail the same way,
                // and each would cost up to the full timeout.
                result = .stop
            }
            switch result {
            case .done: remove(uuid)
            case .retry:
                Log.ui.error("Catch delete sync failed for one catch; will retry next open")
            case .stop:
                Log.ui.notice("Catch delete sync stopped early; the rest wait for the next open")
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
