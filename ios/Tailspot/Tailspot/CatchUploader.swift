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
//  - Guess holds (2026-10-21): a fresh catch that hosts a route-guess bonus
//    round is HELD out of every sweep until the guess resolves (answer,
//    skip, or reveal dismiss), because a row is only ever POSTed once and
//    the server can only award the bonus for a guess it sees. Before the
//    hold, the immediate upload above always beat the guess, and almost no
//    route-guess bonus reached the server from 1.1.0 on. See
//    `CatchUploadHolds`.
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

/// Which pending rows are waiting on their route-guess answer, keyed by the
/// row's `serverUuid`, with the moment each hold was placed.
///
/// A plain value type with no SwiftData in it, so the hold rules are unit-
/// tested directly (CatchUploadHoldTests). The live registry is the single
/// `CatchUploader.guessHolds` below. It is in memory only on purpose: if the
/// app is killed mid-reveal the hold is simply gone, and the row uploads on
/// the next launch without its guess (exactly what happened before holds).
nonisolated struct CatchUploadHolds: Equatable, Sendable {
    /// A hold that is never released (a reveal path that forgot to, a user
    /// who left the bonus chips up for minutes) must not strand the catch:
    /// after this long the row uploads anyway, without the guess. A real
    /// answer lands within seconds of the chips popping.
    static let timeout: TimeInterval = 120

    private(set) var placedAt: [String: Date] = [:]

    mutating func hold(_ key: String, now: Date = Date()) {
        placedAt[key] = now
    }

    /// Remove the hold. Returns true when there was one, so the caller only
    /// kicks an upload when releasing actually freed a row.
    @discardableResult
    mutating func release(_ key: String) -> Bool {
        placedAt.removeValue(forKey: key) != nil
    }

    /// Should the uploader skip this row right now? A row with no
    /// `serverUuid` can't have been held (the hold assigns one first).
    static func isHeld(key: String?, holds: [String: Date], now: Date,
                       timeout: TimeInterval = CatchUploadHolds.timeout) -> Bool {
        guard let key, let placed = holds[key] else { return false }
        return now.timeIntervalSince(placed) < timeout
    }

    func isHeld(_ key: String?, now: Date = Date()) -> Bool {
        Self.isHeld(key: key, holds: placedAt, now: now)
    }
}

@MainActor
class CatchUploader {
    /// The app's one hold registry. `static` on a `@MainActor` class makes it
    /// MainActor-isolated too, so every read and write happens on the main
    /// thread alongside the SwiftData rows it describes. No lock needed.
    static var guessHolds = CatchUploadHolds()

    /// Hold `row` out of uploads until its route guess resolves, and schedule
    /// one sweep just past the timeout so a hold nobody released still
    /// uploads within ~2 minutes instead of waiting for the next foreground.
    ///
    /// Assigns the row's `serverUuid` if it has none (the uploader would do
    /// the same on its first attempt), so the hold has a stable key.
    static func holdForGuess(_ row: Catch, context: ModelContext) {
        if row.serverUuid == nil { row.serverUuid = UUID().uuidString }
        guard let key = row.serverUuid else { return }
        guessHolds.hold(key)
        Log.ui.info("CatchUploader: holding \(row.icao24, privacy: .public) for its route guess")
        Task {
            try? await Task.sleep(for: .seconds(CatchUploadHolds.timeout + 1))
            await CatchUploader().uploadPending(context: context)
        }
    }

    /// Release `row`'s guess hold (if any) and upload it now. Called when the
    /// reveal's bonus round resolves or the reveal closes. A no-op for a row
    /// that was never held, so every reveal-ending path can call it safely.
    static func releaseGuessHold(for row: Catch?, context: ModelContext) {
        guard let key = row?.serverUuid, guessHolds.release(key) else { return }
        Task { await CatchUploader().uploadPending(context: context) }
    }

    /// True when the live registry says to skip this row right now.
    static func isHeldForGuess(_ row: Catch, now: Date = Date()) -> Bool {
        guessHolds.isHeld(row.serverUuid, now: now)
    }


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

    /// A row the user deleted since the fetch: deleted-but-unsaved, or saved
    /// and detached from its context.
    static func isGone(_ row: Catch) -> Bool {
        row.isDeleted || row.modelContext == nil
    }

    func uploadPending(context: ModelContext) async {
        let fetchedRows: [Catch]
        do {
            var descriptor = FetchDescriptor<Catch>(predicate: Self.pendingPredicate)
            descriptor.sortBy = [SortDescriptor(\Catch.caughtAt, order: .forward)]
            fetchedRows = try context.fetch(descriptor)
        } catch {
            Log.ui.error("CatchUploader: fetch pending failed: \(error, privacy: .public)")
            return
        }

        // Rows waiting on a route-guess answer sit this sweep out (see
        // `CatchUploadHolds`). The loop below re-checks per row, because a
        // hold can be placed while this sweep is awaiting the network.
        let pendingRows = fetchedRows.filter { !Self.isHeldForGuess($0) }
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
        let deletions = CatchDeletionSync()
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
            // The sweep awaits the network per row, and a Hangar delete can
            // land in between. A deleted row must not be uploaded (it would
            // start counting again), and its properties can't be read.
            // `isDeleted` alone isn't enough: it is only true between
            // `delete()` and `save()`, and the delete sites save at once —
            // after that the model has simply left its context.
            if Self.isGone(catchRow) { continue }
            let icao = catchRow.icao24
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
                // A 429 wait below can outlast a Hangar delete.
                if Self.isGone(catchRow) || deletions.wasDeleted(uuid) { break }
                // ...or a guess hold placed after this sweep's fetch. The
                // release kicks its own sweep, so skipping here loses nothing.
                if Self.isHeldForGuess(catchRow) { break }
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
                    // Deleted while this POST was in flight: the DELETE may
                    // have reached the server first (a no-op), so this POST
                    // just put the catch back. Send the delete again.
                    if Self.isGone(catchRow) || deletions.wasDeleted(uuid) {
                        CatchDeletionSync.deleteRemotely([uuid])
                        break
                    }
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
                        "CatchUploader: upload failed icao=\(icao, privacy: .public) err=\(error, privacy: .public)"
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
