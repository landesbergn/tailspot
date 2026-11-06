//
//  HangarReconcile.swift
//  Tailspot
//
//  One-time cleanup: delete the server catches a user already deleted from
//  their Hangar on a build that didn't tell the server.
//
//  Why it exists: before #295 (2026-09-27) a Hangar delete was local-only,
//  so the server kept the row and it kept counting toward the leaderboard
//  and challenges. #295 syncs new deletes, but the old ones were never sent
//  and the app kept no record of them. On Noah's phone that was 17 catches
//  (Hangar 588, leaderboard 605). The phone is the only place that knows,
//  so the fix runs on the phone: list the server's catches, compare with
//  the Hangar, and send a delete for each one the Hangar no longer has.
//
//  What counts as deleted (`HangarReconcile.plan`): a server row whose uuid
//  is not in the Hangar, caught AT OR AFTER the oldest catch still in the
//  Hangar. The time floor protects one case: a reinstall where the user
//  skipped the restore offer (or caught a plane before it appeared). Their
//  old server catches aren't in the Hangar either, but they were never
//  deleted, and they're all older than the first catch on the new install.
//  The cost: a pre-#295 delete of the user's very oldest catches stays on
//  the server. Rare, and the safe side to miss on.
//
//  Guards (each skips without deleting anything):
//    - Hangar empty or unreadable. A failed fetch must never read as "the
//      user deleted everything".
//    - The restore prompt is up (an empty Hangar already covers this; the
//      check makes the ordering explicit).
//    - (Not a skip, an exclusion.) The two operator-credited rows
//      `MissedCatchRepair` pulls down are never orphans, even before that
//      pull has landed.
//    - Orphans would be more than half the server total. That pattern isn't
//      a few old deletes, it's something wrong; report it and stop.
//
//  Runs once per install: the latch is set after a run that finished (sent
//  or skipped by the half rule). A network failure or an empty Hangar leaves
//  it unset, so the next launch tries again. The deletes themselves go
//  through `CatchDeletionSync`, which retries across launches and records
//  them in its ledger (so Hangar restore won't offer them back).
//

import Foundation
import SwiftData
import os

// MARK: - The plan (pure, tested on its own)

enum HangarReconcile {
    /// What a run should do.
    enum Plan: Equatable {
        /// Nothing to delete.
        case nothing
        /// Send these server uuids to `CatchDeletionSync` (lowercased).
        case delete([String])
        /// Too many to be old deletes; touch nothing.
        case tooMany(orphans: Int)
    }

    /// One server row, reduced to what the plan needs.
    struct ServerCatch: Equatable {
        let uuid: String
        /// Unix seconds.
        let caughtAt: Double
    }

    /// Decide which server catches the user deleted locally.
    ///
    /// - `localUuids`: every `serverUuid` in the Hangar (any case).
    /// - `oldestLocalCaughtAt`: unix seconds of the oldest Hangar catch.
    /// - `alreadyDeleted`: `CatchDeletionSync`'s ledger. Those are queued or
    ///   sent already; they're left out of the count so the half rule and
    ///   the analytics only see the old, unsynced deletes.
    nonisolated static func plan(
        server: [ServerCatch],
        localUuids: Set<String>,
        oldestLocalCaughtAt: Double,
        alreadyDeleted: Set<String>
    ) -> Plan {
        let local = Set(localUuids.map { $0.lowercased() })
        let ledger = Set(alreadyDeleted.map { $0.lowercased() })
        var seen = Set<String>()
        var orphans: [String] = []
        for row in server {
            let uuid = row.uuid.lowercased()
            guard seen.insert(uuid).inserted,
                  !local.contains(uuid),
                  !ledger.contains(uuid),
                  row.caughtAt >= oldestLocalCaughtAt
            else { continue }
            orphans.append(uuid)
        }
        if orphans.isEmpty { return .nothing }
        if orphans.count * 2 > server.count { return .tooMany(orphans: orphans.count) }
        return .delete(orphans)
    }
}

// MARK: - The launch run

@MainActor
final class HangarReconcileManager {
    static let doneKey = "tailspot.hangar.reconcile.v1.done"

    /// One server page: rows plus the server's total.
    typealias FetchPage = (_ limit: Int, _ offset: Int) async throws -> (rows: [HangarReconcile.ServerCatch], total: Int)

    private let defaults: UserDefaults
    private let hasToken: () -> Bool
    private let fetchPage: FetchPage
    private let deletedLedger: () -> Set<String>
    private let sendDeletes: ([String]) -> Void
    private let capture: (String, [String: AnalyticsValue]) -> Void
    private var ranThisLaunch = false

    init(
        defaults: UserDefaults = .standard,
        client: TailspotAccountClient = TailspotAccountClient(),
        hasToken: (() -> Bool)? = nil,
        fetchPage: FetchPage? = nil,
        deletedLedger: @escaping () -> Set<String> = { CatchDeletionSync().deletedSet },
        sendDeletes: @escaping ([String]) -> Void = { CatchDeletionSync.deleteRemotely($0) },
        capture: @escaping (String, [String: AnalyticsValue]) -> Void = { Analytics.capture($0, $1) }
    ) {
        self.defaults = defaults
        self.hasToken = hasToken ?? { client.storedToken != nil }
        self.fetchPage = fetchPage ?? { limit, offset in
            let page = try await client.fetchCatches(limit: limit, offset: offset)
            return (page.catches.map { .init(uuid: $0.catchUuid, caughtAt: $0.caughtAt) }, page.total)
        }
        self.deletedLedger = deletedLedger
        self.sendDeletes = sendDeletes
        self.capture = capture
    }

    /// Launch entry. Waits (bounded) for TailspotApp's launch registration
    /// instead of registering itself, like `HangarRestoreManager`.
    func runIfNeeded(context: ModelContext, restorePresenting: () -> Bool, tokenWaitSeconds: Int = 15) async {
        guard !ranThisLaunch, !defaults.bool(forKey: Self.doneKey) else { return }
        ranThisLaunch = true

        for _ in 0..<tokenWaitSeconds where !hasToken() {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
        }
        guard hasToken(), !restorePresenting() else { return }
        // Cheap local check before any network: an empty Hangar skips without
        // setting the flag, so without this it would page the whole server
        // list on every launch (a reinstall that said "Not now" to restore).
        guard ((try? context.fetchCount(FetchDescriptor<Catch>())) ?? 0) > 0 else { return }

        // Server first, Hangar second: a catch uploaded while we page is
        // already in the Hangar by the time we read it, so it can't look
        // like an orphan.
        var server: [HangarReconcile.ServerCatch] = []
        do {
            for _ in 0..<40 {   // same 20k cap as restore
                let page = try await fetchPage(500, server.count)
                server.append(contentsOf: page.rows)
                if server.count >= page.total || page.rows.isEmpty { break }
            }
        } catch {
            Log.ui.info("HangarReconcile: server list failed; will retry next launch")
            return
        }

        guard !restorePresenting(),
              let local = try? context.fetch(FetchDescriptor<Catch>()),
              let oldest = local.map(\.caughtAt).min()
        else { return }   // unreadable or empty Hangar: never treat as "deleted everything"

        let plan = HangarReconcile.plan(
            server: server,
            localUuids: Set(local.compactMap(\.serverUuid)),
            oldestLocalCaughtAt: oldest.timeIntervalSince1970,
            // The operator-credited rows (`MissedCatchRepair`) were inserted
            // server-side; their client pull runs in a separate launch task and
            // may not have landed yet. Never treat them as deleted.
            alreadyDeleted: deletedLedger().union(MissedCatchRepair.repairableUUIDs)
        )

        var props: [String: AnalyticsValue] = [
            "server_total": .int(server.count),
            "local_total": .int(local.count),
        ]
        switch plan {
        case .nothing:
            props["orphans"] = .int(0)
            props["outcome"] = .string("nothing")
        case .delete(let uuids):
            props["orphans"] = .int(uuids.count)
            props["outcome"] = .string("deleted")
            sendDeletes(uuids)
        case .tooMany(let n):
            props["orphans"] = .int(n)
            props["outcome"] = .string("too_many")
        }
        capture("hangar_reconciled", props)
        Log.ui.info("HangarReconcile: \(String(describing: plan), privacy: .public)")
        defaults.set(true, forKey: Self.doneKey)
    }
}
