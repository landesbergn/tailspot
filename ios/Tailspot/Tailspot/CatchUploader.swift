//
//  CatchUploader.swift
//  Tailspot
//
//  Uploads pending Catch rows to the Tailspot backend.
//
//  Design:
//  - `CatchUploader` is a @MainActor class so it can safely read and
//    mutate SwiftData rows (which are MainActor-isolated under Xcode 26's
//    default-actor rule).
//  - `uploadPending(context:)` fetches all Catch rows where `uploadedAt`
//    is nil, assigns a `serverUuid` if absent, and uploads them sequentially
//    via `TailspotAccountClient`. A failed upload leaves the row pending for
//    the next run (non-throwing per-catch error handling). A duplicate
//    response (server already saw that UUID) is treated as success and marks
//    the row uploaded — idempotent by design.
//  - Hook: TailspotApp hooks `scenePhase → .active` to fire `uploadPending`.
//    Per-catch immediate upload after a new catch is a follow-up (PLAN §9).
//

import Foundation
import SwiftData
import os

@MainActor
class CatchUploader {
    private let client: TailspotAccountClient

    init(client: TailspotAccountClient = TailspotAccountClient()) {
        self.client = client
    }

    /// Upload every Catch row that has not yet been acknowledged by the
    /// backend (`uploadedAt == nil`). Idempotent — safe to call on every
    /// foreground transition.
    ///
    /// Flow per pending row:
    ///   1. Assign `serverUuid` (UUID string) if nil — once set it never
    ///      changes, so retries replay the same UUID and the server dedupes.
    ///   2. Call `ensureRegistered()` — no-op if already registered.
    ///   3. POST the catch; on success or duplicate, set `uploadedAt = now`.
    ///   4. On any error, log and continue — the row stays pending.
    func uploadPending(context: ModelContext) async {
        let pendingRows: [Catch]
        do {
            // Fetch all rows where uploadedAt is nil.
            var descriptor = FetchDescriptor<Catch>(
                predicate: #Predicate<Catch> { $0.uploadedAt == nil }
            )
            descriptor.sortBy = [SortDescriptor(\Catch.caughtAt, order: .forward)]
            pendingRows = try context.fetch(descriptor)
        } catch {
            Log.ui.error("CatchUploader: fetch pending failed: \(error, privacy: .public)")
            return
        }

        guard !pendingRows.isEmpty else { return }
        Log.ui.info("CatchUploader: \(pendingRows.count, privacy: .public) pending catch(es) to upload")

        // Ensure we have a device registration before uploading anything.
        do {
            try await client.ensureRegistered()
        } catch {
            Log.ui.error("CatchUploader: registration failed, aborting upload: \(error, privacy: .public)")
            return
        }

        var successCount = 0
        for catchRow in pendingRows {
            // Assign a stable UUID for this catch if it doesn't have one yet.
            if catchRow.serverUuid == nil {
                catchRow.serverUuid = UUID().uuidString
            }
            guard let uuid = catchRow.serverUuid else { continue }

            do {
                let response = try await client.uploadCatch(
                    catchUuid: uuid,
                    icao24: catchRow.icao24,
                    callsign: catchRow.callsign,
                    caughtAt: catchRow.caughtAt,
                    observerLat: catchRow.observerLat,
                    observerLon: catchRow.observerLon,
                    headingDeg: nil,
                    elevationDeg: nil,
                    headingAccuracyDeg: nil
                )
                // Mark uploaded regardless of duplicate status — both mean the
                // server has accepted this catch.
                catchRow.uploadedAt = Date()
                successCount += 1
                Log.ui.info(
                    "CatchUploader: uploaded \(catchRow.icao24, privacy: .public) pts=\(response.points, privacy: .public) dup=\(response.duplicate, privacy: .public)"
                )
            } catch {
                // Non-fatal: leave pending for the next foreground transition.
                Log.ui.error(
                    "CatchUploader: upload failed icao=\(catchRow.icao24, privacy: .public) err=\(error, privacy: .public)"
                )
            }
        }

        // Persist all mutations (uploadedAt + serverUuid assignments) in one save.
        if successCount > 0 {
            do {
                try context.save()
                Log.ui.info("CatchUploader: saved \(successCount, privacy: .public) uploaded catch(es)")
            } catch {
                Log.ui.error("CatchUploader: save failed: \(error, privacy: .public)")
            }
        }
    }
}
