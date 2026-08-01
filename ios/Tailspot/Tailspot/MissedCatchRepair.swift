//
//  MissedCatchRepair.swift
//  Tailspot
//
//  TEMPORARY, SINGLE-PURPOSE RECOVERY — safe to delete once it has run.
//
//  Two catches were recorded on one tester's device and never reached the
//  server, so they exist in neither the Hangar nor the leaderboard:
//
//    1. ae0584 — a Lockheed C-5M Super Galaxy (USAF 87-0039, RCH2067),
//       tap-revealed 2026-06-30 at 39.0° off-axis. The tap-reveal cone
//       (`emptySkyTapMaxOffsetDeg` = 40) is WIDER than the camera frame
//       (56° H × 72° V — 28°/36° half-angles), so the plane was pinned and
//       force-locked while being impossible to project on screen; the capture
//       button only targets a pin when `onScreenIcaos.contains(pin)`, so the
//       shutter could never fire on it. (That underlying bug is tracked
//       separately — this file only repairs the damage it did.)
//    2. a3bef1 — a Cessna 340 (N340SU), 2026-07-18. A plain upload gap.
//
//  The server side was credited by `backend/src/tools/backfill-missed-catches.ts`,
//  which inserts those two rows under FIXED catchUuids. This file is the client
//  half: it pulls exactly those uuids down so the cards appear in the Hangar
//  and every derived surface (sets, trophies, local stats) recomputes off them.
//
//  WHY THIS IS NOT A GENERAL "SYNC MISSING CATCHES" FEATURE
//  --------------------------------------------------------
//  There is no DELETE endpoint: deleting a catch removes it locally while the
//  server keeps the row forever. A general merge would therefore resurrect
//  every catch every user has ever deleted. This repair is double-gated so it
//  cannot do that:
//    - it only runs on the ONE device that owns these rows (`repairDeviceID`),
//      so every other install does no work and makes no network call; and
//    - even there it may only insert `repairableUUIDs` — a fixed two-entry
//      allowlist. Nothing else the server returns can be inserted.
//  It is also latched, so it runs at most once per install.
//
//  Trophies are deliberately NOT reseeded (unlike `HangarRestore.restore`):
//  recovering an epic military catch SHOULD get its unlock moment, and
//  `reseedAfterRestore` would both suppress that and clear pending events the
//  user has legitimately earned elsewhere.
//

import Foundation
import Combine
import SwiftData
import os

@MainActor
enum MissedCatchRepair {

    /// The only device this repair touches — the backend device id of the
    /// tester whose two catches were lost. An opaque server-issued uuid.
    /// Every other install compares, mismatches, and returns immediately.
    static let repairDeviceID = "efb375ca-bd56-53af-9437-337feb1ec197"

    /// The only server rows this repair may insert, matching the fixed uuids
    /// `backfill-missed-catches.ts` writes. Compared case-folded, like the
    /// rest of the restore path (Postgres returns lowercase; locally-minted
    /// uuids are uppercase).
    static let repairableUUIDs: Set<String> = [
        "bacf0000-0000-4000-8000-0000000000c5",
        "bacf0000-0000-4000-8000-00000000c340",
    ]

    /// Run-once latch. Versioned so a future repair can't be blocked by this one.
    static let latchKey = "tailspot.repair.missedCatches.v1"

    /// Whether this install is the one the repair targets and hasn't run yet.
    /// Pure + injectable so tests don't need a Keychain or a real device id.
    nonisolated static func shouldRun(
        deviceID: String?,
        alreadyRan: Bool
    ) -> Bool {
        guard !alreadyRan else { return false }
        guard let deviceID, deviceID.lowercased() == repairDeviceID else { return false }
        return true
    }

    /// Of `rows`, the ones this repair is allowed to insert. Everything the
    /// server returns that isn't on the allowlist is ignored — this is what
    /// keeps the repair from behaving like a general merge.
    nonisolated static func repairableRows(_ rows: [RestoredCatchRow]) -> [RestoredCatchRow] {
        rows.filter { repairableUUIDs.contains($0.catchUuid.lowercased()) }
    }
}

// MARK: - Runner

@MainActor
final class MissedCatchRepairRunner {
    private let client: TailspotAccountClient
    private let defaults: UserDefaults

    init(
        client: TailspotAccountClient = TailspotAccountClient(),
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.defaults = defaults
    }

    /// Insert the recovered catches if this is the targeted device. A no-op —
    /// with NO network call — on every other install.
    ///
    /// Returns how many rows were inserted (0 on any no-op path), so tests and
    /// the caller can assert the outcome.
    @discardableResult
    func runIfNeeded(context: ModelContext, deviceID: String? = DeviceID.currentIfPresent()) async -> Int {
        guard MissedCatchRepair.shouldRun(
            deviceID: deviceID,
            alreadyRan: defaults.bool(forKey: MissedCatchRepair.latchKey)
        ) else { return 0 }

        // Needs the bearer token to read the collection back. If registration
        // hasn't landed yet we simply try again next launch — the latch is
        // only set once the repair has actually been attempted end to end.
        guard client.storedToken != nil else {
            Log.ui.info("MissedCatchRepair: no token yet; will retry next launch")
            return 0
        }

        do {
            // Page to completion: the recovered rows are backdated, so they sit
            // in the middle of an oldest-first collection, not at the end.
            var rows: [RestoredCatchRow] = []
            for _ in 0..<40 {
                let page = try await client.fetchCatches(limit: 500, offset: rows.count)
                rows.append(contentsOf: page.catches)
                if rows.count >= page.total || page.catches.isEmpty { break }
            }

            let repairable = MissedCatchRepair.repairableRows(rows)
            guard !repairable.isEmpty else {
                // The server hasn't been backfilled yet. Don't latch — this is
                // the ordering the rollout expects to hit at least once.
                Log.ui.info("MissedCatchRepair: no recoverable rows on the server yet")
                return 0
            }

            // `insertRestored` re-checks serverUuid against the whole Hangar,
            // so this is idempotent even if the latch is ever lost.
            let inserted = HangarRestore.insertRestored(repairable, into: context)
            try context.save()

            // Latch only after a successful save.
            defaults.set(true, forKey: MissedCatchRepair.latchKey)

            if inserted > 0 {
                Analytics.capture("missed_catch_repaired", ["count": .int(inserted)])
            }
            Log.ui.info("MissedCatchRepair: inserted \(inserted, privacy: .public) recovered catch(es)")
            return inserted
        } catch {
            // Transport failure — leave the latch clear and retry next launch.
            Log.ui.error("MissedCatchRepair: failed: \(error, privacy: .public)")
            return 0
        }
    }
}
