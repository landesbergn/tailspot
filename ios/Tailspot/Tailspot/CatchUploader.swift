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
    /// What "pending upload" means: never uploaded AND not quarantined as a
    /// gate suspect (post-catch confirm, 2026-07-04) — a suspected catch must
    /// not touch the server/leaderboard until the user answers Keep (clears
    /// `suspectReason`); Discard deletes the row. Static so the quarantine
    /// rule is unit-testable against an in-memory store.
    static let pendingPredicate = #Predicate<Catch> {
        $0.uploadedAt == nil && $0.suspectReason == nil
    }

    func uploadPending(context: ModelContext) async {
        let pendingRows: [Catch]
        do {
            var descriptor = FetchDescriptor<Catch>(predicate: Self.pendingPredicate)
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
        // The backend rate-limits catch uploads (token bucket, ~60/min per
        // device). The old loop blasted every pending row straight through, so
        // a backlog backfill drained the bucket in milliseconds, most rows got
        // 429'd, and they re-stormed on the next launch (never reaching the
        // leaderboard). Now a 429 makes us wait for the bucket to refill and
        // retry the SAME row — bounded, so a huge backlog can't hang the task;
        // whatever's left simply defers to the next foreground transition.
        var rateLimitWaits = 0
        let maxRateLimitWaits = 90   // ~90 × 1.2 s ≈ a <2 min ceiling per run

        uploadLoop:
        for catchRow in pendingRows {
            // Assign a stable UUID for this catch if it doesn't have one yet.
            if catchRow.serverUuid == nil {
                catchRow.serverUuid = UUID().uuidString
            }
            guard let uuid = catchRow.serverUuid else { continue }

            while true {
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
                        headingAccuracyDeg: nil,
                        // The frozen bonus-round guess (game-layer PR2). The
                        // wire carries the guess VALUE only — the server
                        // verifies it against its own truth and awards the
                        // bonus itself; the local `guessCorrect` verdict is
                        // display/trophy state and never leaves the device.
                        guessKind: catchRow.guessKind,
                        guessValue: catchRow.guessValue
                    )
                    // Mark uploaded regardless of duplicate status — both mean
                    // the server has accepted this catch.
                    catchRow.uploadedAt = Date()
                    successCount += 1
                    Log.ui.info(
                        "CatchUploader: uploaded \(catchRow.icao24, privacy: .public) pts=\(response.points, privacy: .public) dup=\(response.duplicate, privacy: .public)"
                    )
                    // Analytics: record the successful upload with the aircraft
                    // identity from the Catch (tail/type/operator/etc.) so PostHog
                    // can show *which* plane was caught. Rarity/points/duplicate
                    // come from the authoritative server response. Airframe
                    // attributes only — no precise coordinates, just coarse
                    // place_name. (See CatchTelemetry.uploadedProperties.)
                    CatchTelemetry.fireUploaded(catchRow, response: response)
                    break   // success → move to the next catch
                } catch AccountError.http(let status) where status == 429 {
                    // Rate limited. Wait for the bucket to refill (~1 token/sec
                    // at 60/min) and retry this same row, up to the ceiling.
                    guard rateLimitWaits < maxRateLimitWaits else {
                        Log.ui.notice("CatchUploader: rate limited; deferring remaining catches to the next launch")
                        break uploadLoop
                    }
                    rateLimitWaits += 1
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    if Task.isCancelled { break uploadLoop }
                    // loop retries the same catchRow
                } catch {
                    // Non-rate-limit error: leave this row pending and move on.
                    Log.ui.error(
                        "CatchUploader: upload failed icao=\(catchRow.icao24, privacy: .public) err=\(error, privacy: .public)"
                    )
                    break
                }
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
