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
//  - Hooks: TailspotApp fires `uploadPending` on `scenePhase → .active` (the
//    retry net), and ContentView fires it right after a catch saves
//    (per-catch immediate upload, 2026-08-24 — so the server
//    knows the points before the user first opens Profile/Leaderboard).
//    Overlapping sweeps are safe: both run on the MainActor over the same
//    context, and the serverUuid assigned before the first POST makes any
//    double-send a server-side duplicate, not a double catch.
//

import Foundation
import SwiftData
import os

/// What a Catch row can tell the backend's validator: the observer pose at
/// shutter press and the caught plane's ADS-B fix. All optional — every field
/// is absent on rows written before the app recorded them, and an all-nil
/// value produces byte-for-byte the request the app sent before this change.
///
/// `nonisolated` because it's a plain value type: pulling it out of
/// `CatchUploader` (which is `@MainActor`) lets the mapping be unit-tested
/// without a SwiftData container. See ios/CLAUDE.md on default MainActor
/// isolation.
nonisolated struct CatchUploadPose: Equatable, Sendable {
    var headingDeg: Double?
    var elevationDeg: Double?
    var headingAccuracyDeg: Double?
    var aircraft: UploadCatchRequest.Aircraft?

    static let empty = CatchUploadPose()

    /// Read the pose + aircraft position out of a stored
    /// `Catch.captureDiagnosticsJSON` blob.
    ///
    /// Deliberately total (never throws, never fails a catch): anything it
    /// can't read becomes nil, which uploads as JSON null and validates as
    /// "unverifiable" — the pre-2026-09-07 behaviour.
    ///
    /// Two rules worth knowing:
    ///  - `headingAccuracyDeg` is `CLLocation.headingAccuracy`, where a
    ///    NEGATIVE value means "the OS says this heading is invalid". The
    ///    validator WIDENS its bearing tolerance by whatever we send, so a
    ///    negative would tighten it — nonsense. Map it to nil instead.
    ///  - the aircraft block is all-or-nothing: the backend requires
    ///    lat + lon + altitudeMeters together (a partial object is a 422),
    ///    so a blob missing any one of them sends no block at all.
    static func from(diagnosticsJSON: String?) -> CatchUploadPose {
        guard let diag = CatchCaptureDiagnostics.from(json: diagnosticsJSON) else {
            return .empty
        }
        let aircraft: UploadCatchRequest.Aircraft? = {
            guard let lat = diag.aircraftLat,
                  let lon = diag.aircraftLon,
                  let alt = diag.aircraftAltitudeMeters else { return nil }
            return .init(
                lat: lat,
                lon: lon,
                altitudeMeters: alt,
                positionTimestamp: diag.aircraftPositionTimestamp?.timeIntervalSince1970
            )
        }()
        return CatchUploadPose(
            headingDeg: diag.headingDeg,
            elevationDeg: diag.cameraElevationDeg,
            headingAccuracyDeg: diag.headingAccuracyDeg.flatMap { $0 < 0 ? nil : $0 },
            aircraft: aircraft
        )
    }
}

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
    /// `suspectReason` is a legacy field from the retired post-catch review
    /// flow. It deliberately does not participate here, which also releases
    /// old rows that were left pending by that flow.
    static let pendingPredicate = #Predicate<Catch> {
        $0.uploadedAt == nil
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

            // The pose the phone held at shutter press, read back out of the
            // row's capture-diagnostics blob. Rows written before the app
            // recorded it yield `.empty` and upload exactly as they did.
            let pose = CatchUploadPose.from(diagnosticsJSON: catchRow.captureDiagnosticsJSON)

            while true {
                do {
                    let response = try await client.uploadCatch(
                        catchUuid: uuid,
                        icao24: catchRow.icao24,
                        callsign: catchRow.callsign,
                        caughtAt: catchRow.caughtAt,
                        observerLat: catchRow.observerLat,
                        observerLon: catchRow.observerLon,
                        headingDeg: pose.headingDeg,
                        elevationDeg: pose.elevationDeg,
                        headingAccuracyDeg: pose.headingAccuracyDeg,
                        // The caught plane's ADS-B fix at press time. Together
                        // with the pose above this is what the server's
                        // validator correlates; nil → JSON null → the catch is
                        // accepted and recorded "unverifiable".
                        aircraft: pose.aircraft,
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
