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
//  (altitude/speed/distance/date) is NEVER touched. operatorName is the
//  documented exception — best-effort CURRENT operator, not as-flown.
//

import Foundation
import SwiftData

@MainActor
enum CatchBackfill {
    /// One shared anonymous client for all backfill (per-catch + bulk).
    /// Bypasses ADSBManager's MetadataCache by design — the manager
    /// isn't reachable from the Hangar sheet; this is a one-shot
    /// recovery path. Metadata works anonymously.
    static let client = OpenSkyClient()

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
        // Group by icao24 so we fetch once per airframe, not per row.
        let needing = catches.filter(needsMetadata)
        guard !needing.isEmpty else { return }
        let byIcao = Dictionary(grouping: needing) { $0.icao24 }
        var changedAny = false
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
        if changedAny { try? context.save() }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
