//
//  HangarRestore.swift
//  Tailspot
//
//  Restore-from-server for the Hangar (PLAN §9 #7, issue #58).
//
//  The Hangar is local-only SwiftData, but every recorded catch was POSTed to
//  the backend for scoring — so after a delete + reinstall, the Keychain
//  device id (#55) re-presents the same identity and `GET /v1/catches` can
//  hand the collection back. This file owns that flow:
//
//    - `HangarRestore` — the pure-ish mapping layer: server row → `Catch`,
//      plus the idempotency plan (skip rows whose `catchUuid` already exists
//      locally as a `serverUuid`, so a re-run never duplicates).
//    - `HangarRestoreManager` — the @MainActor state machine ContentView
//      drives: check-on-launch (empty Hangar + server catches > 0 → offer),
//      then page/insert/save on accept.
//
//  What restore can and cannot bring back:
//    - Catch DATA comes back: identity (icao24/callsign/registration/
//      typecode/names), the catch moment (caughtAt, observer position), and
//      the frozen scoring facts (rarity audit value, guess fields).
//    - PHOTOS are gone forever — they were never uploaded (see issue #58's
//      privacy/storage call). Restored rows have `photoFilename = nil` and
//      render the standard placeholder hero. The prompt says so plainly.
//    - Moment-data the server never stored stays nil (speed, place name,
//      route) or takes the documented unknown sentinel (slant distance = 0
//      renders "—"). The existing `CatchBackfill` heals what it can heal
//      (operator, route-by-callsign, place) on the next Hangar open, exactly
//      as it does for organic old rows.
//
//  Two rules this flow must never break (both covered by tests):
//    - Restored rows are born `uploadedAt != nil`, so `CatchUploader` never
//      re-POSTs them (the server already has them — that's where they came
//      from).
//    - After the bulk insert, the trophy ledger is RE-SEEDED (acknowledged =
//      current earned state) before SwiftUI's diff task can run, so a
//      restored collection never floods the user with one-by-one trophy
//      celebrations for trophies they earned long ago.
//

import Foundation
// Combine, not SwiftUI: this file holds state (`ObservableObject` /
// `@Published`) but renders nothing — the repo convention for model files.
import Combine
import SwiftData
import os

// MARK: - Mapping + idempotency (the testable core)

@MainActor
enum HangarRestore {
    /// Build a local `Catch` from a server row. Field-by-field:
    ///   - Airframe + identity map across directly (nil stays nil — the
    ///     regular Hangar backfill can heal names later, same as any old row).
    ///   - `rarity` maps through the shared raw values ("rare" both sides);
    ///     an unknown server string falls back to the classifier, same as an
    ///     organic catch with no explicit tier.
    ///   - `slantDistanceMeters` is 0 — the server never stored it (the
    ///     uploader sends `aircraft: null`) and the field is non-optional.
    ///     0 is the documented "unknown" sentinel: cards render "—" and the
    ///     distance trophies treat it as never-far (no false awards).
    ///   - `serverUuid` = the row's `catchUuid` (the restore/idempotency key)
    ///     and `uploadedAt` = now, so the uploader's pending predicate
    ///     (`uploadedAt == nil`) can never re-POST a restored row.
    static func makeCatch(from row: RestoredCatchRow) -> Catch {
        let restored = Catch(
            icao24: row.icao24,
            callsign: row.callsign,
            model: row.model,
            manufacturer: row.manufacturer,
            caughtAt: Date(timeIntervalSince1970: row.caughtAt),
            observerLat: row.observerLat,
            observerLon: row.observerLon,
            slantDistanceMeters: 0,
            registration: row.registration,
            typecode: row.typecode,
            altitudeMeters: row.aircraftAltitudeMeters,
            rarity: row.rarity.flatMap(Rarity.init(rawValue:))
        )
        // Post-init fields (deliberately not on the init, matching how they're
        // written in the organic flow: the guess happens after the row is
        // born; serverUuid/uploadedAt belong to the uploader).
        restored.serverUuid = row.catchUuid
        restored.uploadedAt = Date()
        restored.guessKind = row.guessKind
        restored.guessValue = row.guessValue
        // guessCorrect only means something when a guess was actually made —
        // the server echoes false for guess-less rows, which must stay nil
        // locally (nil = "no bonus round", not "guessed wrong").
        restored.guessCorrect = row.guessKind != nil ? row.guessCorrect : nil
        return restored
    }

    /// The `serverUuid`s already present locally, lowercased. Server uuids
    /// come back lowercase (Postgres uuid) while locally-minted ones are
    /// uppercase (`UUID().uuidString`), so all comparison is case-folded.
    static func existingServerUuids(in context: ModelContext) -> Set<String> {
        let rows = (try? context.fetch(FetchDescriptor<Catch>())) ?? []
        return Set(rows.compactMap { $0.serverUuid?.lowercased() })
    }

    /// The idempotency plan: of `rows`, the ones safe to insert — not already
    /// present locally (by case-folded uuid) and deduped within the batch
    /// itself (a paging overlap must not double-insert). Pure; order-preserving.
    nonisolated static func rowsToInsert(
        _ rows: [RestoredCatchRow],
        existingServerUuids existing: Set<String>
    ) -> [RestoredCatchRow] {
        var seen = existing
        var planned: [RestoredCatchRow] = []
        for row in rows {
            let key = row.catchUuid.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            planned.append(row)
        }
        return planned
    }

    /// Map + insert every not-yet-present row into `context` (no save — the
    /// caller saves once, after the trophy-ledger reseed). Returns how many
    /// rows were actually inserted; a re-run over the same rows returns 0.
    @discardableResult
    static func insertRestored(_ rows: [RestoredCatchRow], into context: ModelContext) -> Int {
        let planned = rowsToInsert(rows, existingServerUuids: existingServerUuids(in: context))
        for row in planned {
            context.insert(makeCatch(from: row))
        }
        return planned.count
    }
}

// MARK: - Manager (the launch check + restore state machine)

@MainActor
final class HangarRestoreManager: ObservableObject {
    /// The restore flow's presentation state. `idle` renders nothing; every
    /// other case drives one screen of `HangarRestorePromptView`.
    enum Phase: Equatable {
        case idle
        /// The server holds `total` catches and the local Hangar is empty —
        /// the prompt is up, waiting for Restore / Not now.
        case offer(total: Int)
        case restoring
        case done(restored: Int)
        /// Transport/store failure mid-restore. Carries the offered total so
        /// "Try again" can re-arm the offer (already-inserted rows are skipped
        /// by the uuid plan, so a partial first attempt is harmless).
        case failed(total: Int)
    }

    @Published private(set) var phase: Phase = .idle

    /// True whenever the prompt overlay should be on screen.
    var isPresenting: Bool { phase != .idle }

    private let client: TailspotAccountClient
    /// One check per launch: a decline shouldn't re-nag until the next launch,
    /// and the empty-Hangar fresh install shouldn't re-poll the server either.
    private var checkedThisLaunch = false

    init(client: TailspotAccountClient = TailspotAccountClient()) {
        self.client = client
    }

    /// Launch check: when the local Hangar is empty and this device's
    /// (Keychain-surviving) identity holds catches on the server, offer the
    /// restore. Runs at most once per launch; quietly does nothing in every
    /// other situation (rows exist locally, fresh identity, offline…).
    ///
    /// Registration note: this WAITS for the token instead of calling
    /// `ensureRegistered()` itself — TailspotApp's scenePhase task registers
    /// exactly once at launch, and racing a second `POST /v1/devices` on a
    /// fresh install could mint a duplicate identity (the exact bug #55/#76
    /// class this feature builds on).
    func checkIfNeeded(context: ModelContext) async {
        guard !checkedThisLaunch else { return }
        checkedThisLaunch = true

        guard localCatchCount(in: context) == 0 else { return }

        // Wait (bounded) for the launch registration to land. On a reinstall
        // the Keychain token is already there and this exits on the first
        // spin; a genuinely fresh install becomes registered within a beat.
        for _ in 0..<15 where client.storedToken == nil {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
        }
        guard client.storedToken != nil else {
            Log.ui.info("HangarRestore: no registration yet; skipping check this launch")
            return
        }

        // Cheapest possible probe: one row, but the full `total`.
        guard let head = try? await client.fetchCatches(limit: 1, offset: 0),
              head.total > 0 else { return }

        // Re-check emptiness — the user may have caught a plane while we
        // waited on registration; a non-empty Hangar means no prompt (organic
        // rows + a restore is a merge question we deliberately don't open).
        guard localCatchCount(in: context) == 0 else { return }

        Log.ui.info("HangarRestore: server holds \(head.total, privacy: .public) catches; offering restore")
        phase = .offer(total: head.total)
    }

    /// Pull every server catch, insert the missing ones, reseed the trophy
    /// ledger (no celebration flood), save, and fire ONE analytics event.
    /// Safe to re-run: the uuid plan makes a second pass a no-op.
    func restore(context: ModelContext, unlockCenter: TrophyUnlockCenter) async {
        guard case .offer(let offeredTotal) = phase else { return }
        phase = .restoring

        do {
            // Page to completion (oldest first). The safety cap can't bite a
            // real collection (500/page × 40 = 20k catches); it exists so a
            // confused server total can never loop us forever.
            var rows: [RestoredCatchRow] = []
            var total = 0
            for _ in 0..<40 {
                let page = try await client.fetchCatches(limit: 500, offset: rows.count)
                rows.append(contentsOf: page.catches)
                total = page.total
                if rows.count >= page.total || page.catches.isEmpty { break }
            }

            let inserted = HangarRestore.insertRestored(rows, into: context)

            // Reseed BEFORE anything can observe the new rows: acknowledging
            // the restored collection's earned tiers now means ContentView's
            // `.task(id: catches.count)` diff finds nothing to celebrate.
            // (Same silent-seed pattern as a first launch — restored trophies
            // are visible in the trophy case, not re-toasted one by one.)
            let allRows = (try? context.fetch(FetchDescriptor<Catch>())) ?? []
            unlockCenter.reseedAfterRestore(from: allRows)

            try context.save()

            // ONE event for the whole restore — deliberately no per-catch
            // telemetry (these aren't new catches) and no re-upload.
            Analytics.capture("hangar_restored", [
                "count": .int(inserted),
                "server_total": .int(total),
            ])
            Log.ui.info("HangarRestore: restored \(inserted, privacy: .public) of \(total, privacy: .public) server catches")
            phase = .done(restored: inserted)
        } catch {
            Log.ui.error("HangarRestore: restore failed: \(error, privacy: .public)")
            phase = .failed(total: offeredTotal)
        }
    }

    /// "Not now" on the offer (or dismissing the failed state). The check is
    /// latched, so the prompt stays away until the next launch.
    func decline() {
        phase = .idle
    }

    /// Retry from the failed state: re-arm the offer so the user can tap
    /// Restore again (already-inserted rows are skipped by the uuid plan).
    func retry() {
        guard case .failed(let total) = phase else { return }
        phase = .offer(total: total)
    }

    /// Dismiss the success screen.
    func finish() {
        phase = .idle
    }

    private func localCatchCount(in context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<Catch>())) ?? 0
    }

    #if DEBUG
    /// Snapshot-harness hook: `phase` is `private(set)` so production code
    /// can only move through the real transitions; the visual-pass tests
    /// need to render each screen directly.
    func _setPhaseForSnapshot(_ p: Phase) {
        phase = p
    }
    #endif
}
