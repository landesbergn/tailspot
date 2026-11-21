//
//  NotableBackfill.swift
//  Tailspot
//
//  One-time reconcile of the notable-airframe flag on catches made before
//  the app knew about it.
//
//  New catches get the flag at the press (from the live feed) and again from
//  the upload response. Older rows have nothing, but the server can tell:
//  each `GET /v1/catches` row carries a `notable` verdict (`NotableVerdict`):
//  an object when the airframe is notable, an explicit null when it is not.
//  So this lists the device's server catches once and applies each verdict
//  to the matching Hangar row (matched by `serverUuid`): an object sets or
//  corrects the flag, a null clears it, and a row the server said nothing
//  about is left alone.
//
//  What it may do: write `notableKind` / `notableLabel` / `notableName`.
//  That is all. It never deletes a catch and never touches any other field
//  (the phone is the source of truth for catches; see HangarReconcile.swift).
//
//  Shape of a run, modelled on GuessRecreditSweep / HangarReconcile:
//  - Tried once per launch (from ContentView's launch task) until one run
//    has finished, then never again (`completeKey`).
//  - It finishes, and latches, only when the server PROVED it knows about
//    notable planes: the list held at least one row, and every row on every
//    page carried the `notable` key. A server that predates the feature
//    omits the key; the run then stops after its first page, changes
//    nothing, and the next launch tries again (one request per launch).
//  - No token, no network, a failed page or a failed save: stop quietly
//    with the latch unset, and the next launch tries again.
//  - Re-running is harmless: a row that already matches is left alone.
//

import Foundation
import SwiftData
import os

enum NotableBackfill {
    /// One server row, reduced to what the reconcile needs.
    nonisolated struct ServerRow: Equatable, Sendable {
        let uuid: String
        let verdict: NotableVerdict
    }

    /// The verdict each server uuid carries (lowercased uuid; the server
    /// sends lowercase, the phone mints uppercase). Pure, tested on its own.
    nonisolated static func verdictsByUuid(_ server: [ServerRow]) -> [String: NotableVerdict] {
        var out: [String: NotableVerdict] = [:]
        for row in server { out[row.uuid.lowercased()] = row.verdict }
        return out
    }

    /// Did the server show that it knows about notable planes? Only when it
    /// returned rows and every one carried the key. An empty list proves
    /// nothing either way, so it does not count.
    nonisolated static func provesServerAware(_ rows: [ServerRow]) -> Bool {
        !rows.isEmpty && rows.allSatisfy(\.verdict.isKnown)
    }

    /// Apply the server's verdicts to the matching rows. Returns how many
    /// rows changed. Rows the server didn't list are not touched, so a
    /// second run over the same data changes nothing.
    @discardableResult
    static func apply(_ verdicts: [String: NotableVerdict], to catches: [Catch]) -> Int {
        guard !verdicts.isEmpty else { return 0 }
        var changed = 0
        for c in catches {
            guard let uuid = c.serverUuid?.lowercased(), let verdict = verdicts[uuid] else { continue }
            if c.applyNotable(verdict) { changed += 1 }
        }
        return changed
    }
}

@MainActor
struct NotableBackfillRunner {
    /// Bump the suffix only to deliberately run the reconcile again everywhere.
    static let completeKey = "tailspot.notableBackfill.v1.complete"

    /// One run at a time, app-wide.
    private static var isRunning = false

    /// One server page: its rows and the server's total.
    typealias FetchPage = (_ limit: Int, _ offset: Int) async throws
        -> (rows: [NotableBackfill.ServerRow], total: Int)

    private let defaults: UserDefaults
    private let hasToken: () -> Bool
    private let fetchPage: FetchPage

    init(
        defaults: UserDefaults = .standard,
        client: TailspotAccountClient = TailspotAccountClient(),
        hasToken: (() -> Bool)? = nil,
        fetchPage: FetchPage? = nil
    ) {
        self.defaults = defaults
        self.hasToken = hasToken ?? { client.storedToken != nil }
        self.fetchPage = fetchPage ?? { limit, offset in
            let page = try await client.fetchCatches(limit: limit, offset: offset)
            let rows = page.catches.map {
                NotableBackfill.ServerRow(uuid: $0.catchUuid, verdict: $0.notable)
            }
            return (rows, page.total)
        }
    }

    var isComplete: Bool { defaults.bool(forKey: Self.completeKey) }

    /// Run once if the reconcile hasn't finished on this device. Never
    /// throws. Returns the number of rows it changed, or nil when it didn't
    /// finish (and so didn't latch).
    @discardableResult
    func runIfNeeded(context: ModelContext) async -> Int? {
        guard !isComplete, !Self.isRunning else { return nil }
        Self.isRunning = true
        defer { Self.isRunning = false }

        // Not registered yet: nothing can be listed. Try again next launch.
        guard hasToken() else { return nil }
        // An empty Hangar has nothing to reconcile. Don't latch: a restore
        // may fill it later (restored rows carry the flag themselves, and an
        // unlatched run costs one cheap count per launch).
        guard ((try? context.fetchCount(FetchDescriptor<Catch>())) ?? 0) > 0 else { return nil }

        var server: [NotableBackfill.ServerRow] = []
        do {
            for _ in 0..<40 {   // same 20k cap as restore and reconcile
                let page = try await fetchPage(500, server.count)
                server.append(contentsOf: page.rows)
                // A page with a row that lacks the key: this server predates
                // the feature (or sent something unreadable). Stop here, so
                // an old server costs one request per launch, and change
                // nothing: half a list is not a verdict.
                guard NotableBackfill.provesServerAware(page.rows) else {
                    Log.ui.info("NotableBackfill: server did not prove it knows notable planes; will retry next launch")
                    return nil
                }
                if server.count >= page.total { break }
                if Task.isCancelled { return nil }
            }
        } catch {
            Log.ui.info("NotableBackfill: server list failed; will retry next launch")
            return nil
        }

        guard let local = try? context.fetch(FetchDescriptor<Catch>()) else { return nil }
        let changed = NotableBackfill.apply(NotableBackfill.verdictsByUuid(server), to: local)
        if changed > 0 {
            do { try context.save() } catch {
                Log.ui.error("NotableBackfill: save failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        defaults.set(true, forKey: Self.completeKey)
        Log.ui.info("NotableBackfill: changed \(changed, privacy: .public) of \(local.count, privacy: .public) catch(es)")
        return changed
    }
}
