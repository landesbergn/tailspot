//
//  CatchBackfill.swift
//  Tailspot
//
//  Shared airframe-fact backfill for catches. Names resolve from the
//  ICAO typecode table, so a catch missing its typecode shows a messy
//  free-text name; this recovers typecode (+ other airframe-static
//  facts) once per catch. Used per-catch by CatchDetailView and
//  collection-wide by HangarView on open.
//
//  Fill-only-if-nil (recorded values never overwritten); moment-data
//  (altitude/speed/distance/date) is NEVER touched. TWO documented
//  best-effort exceptions resolve from the CURRENT record, not as-flown:
//  operatorName, and — since 2026-07-04 (Noah's call: backfill old cards)
//  — the route (origin → destination by callsign, `GET /v1/routes`).
//  Scheduled callsigns keep their city pair for their scheduled life, so
//  the current filing is almost always the flown route.
//

import Foundation
import SwiftData

@MainActor
enum CatchBackfill {
    /// One shared backend client for all backfill (per-catch + bulk).
    /// Bypasses ADSBManager's MetadataCache by design — the manager
    /// isn't reachable from the Hangar sheet; this is a one-shot
    /// recovery path. The backend serves merged FAA / DOC-8643 metadata.
    static let client: ADSBSource = TailspotBackendClient()
    /// Concrete client for route lookups — `route(forCallsign:)` is a
    /// backfill concern and deliberately NOT part of the ADSBSource seam.
    static let routeClient = TailspotBackendClient()

    /// Fill nil airframe fields on `catches` (all sharing one icao24)
    /// from `meta`. Pure given the inputs — no I/O. Returns true if it
    /// changed anything. alt/speed/place are NOT touched here.
    static func applyMetadata(_ meta: AircraftMetadata, to catches: [Catch]) -> Bool {
        var changed = false
        for c in catches {
            if c.registration == nil, let v = meta.registration?.trimmedNonEmpty { c.registration = v; changed = true }
            if c.typecode == nil,     let v = meta.typecode?.trimmedNonEmpty     { c.typecode = v; changed = true }
            if c.manufacturer == nil, let v = meta.manufacturerName?.trimmedNonEmpty { c.manufacturer = v; changed = true }
            if c.model == nil,        let v = meta.model?.trimmedNonEmpty        { c.model = v; changed = true }
            if c.operatorName == nil, let v = meta.operatorName?.trimmedNonEmpty { c.operatorName = v; changed = true }
        }
        return changed
    }

    /// Whether this catch still needs an airframe fetch (the gate the
    /// callers use to avoid redundant network calls).
    static func needsMetadata(_ c: Catch) -> Bool {
        c.typecode == nil || c.registration == nil
    }

    /// Whether this catch can gain a backfilled route: it has a callsign to
    /// look up and BOTH route codes are nil. A one-sided route recorded at
    /// catch time is moment-data and is deliberately left alone — mixing an
    /// as-flown origin with a currently-filed destination would fabricate a
    /// journey no one observed.
    static func needsRoute(_ c: Catch) -> Bool {
        c.originIcao == nil && c.destIcao == nil
            && !(c.callsign ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Fill the route onto `catches` (all sharing one callsign) — only rows
    /// where BOTH codes are still nil, and only from a complete origin+dest
    /// answer (a half route is worse than none on the card). Names fill
    /// alongside their codes. Returns true if anything changed.
    static func applyRoute(_ route: BackendAircraft.Route, to catches: [Catch]) -> Bool {
        guard let origin = route.originIcao?.trimmedNonEmpty,
              let dest = route.destIcao?.trimmedNonEmpty else { return false }
        var changed = false
        for c in catches where c.originIcao == nil && c.destIcao == nil {
            c.originIcao = origin
            c.destIcao = dest
            if let v = route.originName?.trimmedNonEmpty { c.originName = v }
            if let v = route.destName?.trimmedNonEmpty { c.destName = v }
            changed = true
        }
        return changed
    }

    /// FAA-registry fallback for US aircraft OpenSky has no record of.
    /// Fills make/model/aircraftType/registration (fill-only-if-nil) from
    /// the bundled snapshot. Returns true if it changed anything.
    static func applyFAAFallback(to catches: [Catch], icao24: String) -> Bool {
        guard let rec = FAARegistry.record(forIcao24: icao24) else { return false }
        let nNumber = IcaoRegistry.nNumber(forIcao24: icao24)
        var changed = false
        for c in catches {
            if c.manufacturer == nil { c.manufacturer = rec.make; changed = true }
            if c.model == nil { c.model = rec.model; changed = true }
            if c.aircraftType == nil, let t = rec.type { c.aircraftType = t.rawValue; changed = true }
            if c.registration == nil, let n = nNumber { c.registration = n; changed = true }
        }
        return changed
    }

    /// Collection-wide pass: for every catch missing airframe facts,
    /// fetch metadata ONCE per distinct icao24 and fill. Bounded,
    /// idempotent, swallows errors. Saves once at the end. Runs in the
    /// background off a Hangar `.task`; never blocks UI.
    static func backfillAll(_ catches: [Catch], in context: ModelContext) async {
        var changedAny = false
        // Offline operator backfill: resolve the airline from the callsign's
        // ICAO prefix for any catch missing an operator (the feed often supplies
        // none). No network; covers ALL catches — not just those that also need
        // typecode/registration, which is the only thing `needsMetadata` gates.
        for c in catches where c.operatorName == nil {
            if let airline = Airlines.name(forCallsign: c.callsign) {
                c.operatorName = airline
                changedAny = true
            }
        }
        // Group by icao24 so we fetch once per airframe, not per row.
        let needing = catches.filter(needsMetadata)
        let byIcao = Dictionary(grouping: needing) { $0.icao24 }
        for (icao, rows) in byIcao {
            let trimmed = icao.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let meta = (try? await client.aircraftMetadata(icao24: trimmed)) ?? nil {
                if applyMetadata(meta, to: rows) { changedAny = true }
            }
            // FAA fallback: if OpenSky gave nothing (typecode + model still
            // nil after the metadata attempt), try the bundled FAA snapshot.
            let needsFAA = rows.contains { $0.typecode == nil && $0.model == nil }
            if needsFAA {
                if applyFAAFallback(to: rows, icao24: trimmed) { changedAny = true }
            }
            if Task.isCancelled { break }
        }

        // Route backfill (2026-07-04): once per DISTINCT callsign, fill
        // origin → destination onto catches that predate route capture.
        // Errors are swallowed per lookup (a 502/offline just means a later
        // Hangar open retries); a null route is a real answer we stop on
        // for this pass.
        let routeNeeding = catches.filter(needsRoute)
        let byCallsign = Dictionary(grouping: routeNeeding) {
            ($0.callsign ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }
        for (callsign, rows) in byCallsign where !callsign.isEmpty {
            if Task.isCancelled { break }
            guard let route = (try? await routeClient.route(forCallsign: callsign)) ?? nil
            else { continue }
            if applyRoute(route, to: rows) { changedAny = true }
        }

        if changedAny { try? context.save() }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
