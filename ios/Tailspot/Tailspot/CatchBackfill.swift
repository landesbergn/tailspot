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
//  the current filing is almost always the flown route. A THIRD carve-out
//  (2026-07-19): a stored route provably implausible for where the catch
//  happened (`clearImplausibleRoutes`) is cleared and re-resolved — those
//  values were bad enrichment, not observations.
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

    // MARK: - Per-launch negative cache
    //
    // In-memory only, NO persistence — deliberately the zero-risk version.
    // Rows for airframes the backend has no record of (foreign GA — e.g.
    // Noah's Bali catches) and callsigns whose route lookup keeps answering
    // null stay `needsMetadata` / `needsRoute` forever, so `backfillAll` used
    // to re-fire the same doomed network lookups on EVERY Hangar open. Once a
    // key is attempted THIS launch and comes back a definite miss (not a
    // transport error — those still retry next open), we record it here and
    // skip it on later same-launch passes. A relaunch starts empty and
    // re-attempts everything, so first-pass-of-launch behavior is unchanged.
    // MainActor-isolated (default isolation), so no locking is needed.
    private static var unresolvedIcaos: Set<String> = []
    private static var unresolvedCallsigns: Set<String> = []

    /// Test-only reset for the per-launch negative caches — they are process
    /// static, so tests must clear them to stay independent of each other.
    static func _resetNegativeCacheForTesting() {
        unresolvedIcaos.removeAll()
        unresolvedCallsigns.removeAll()
    }

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

    /// Whether this catch can gain something from a route lookup: it has a
    /// callsign, and EITHER both route codes are nil (full fill) OR it has a
    /// full ICAO route but no IATA display codes yet (translation fill —
    /// added 2026-07-05 with the IATA switch, so pre-IATA rows upgrade).
    /// A one-sided route recorded at catch time is moment-data and is left
    /// alone — mixing an as-flown origin with a currently-filed destination
    /// would fabricate a journey no one observed.
    static func needsRoute(_ c: Catch) -> Bool {
        guard !(c.callsign ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        let noRoute = c.originIcao == nil && c.destIcao == nil
        let fullRouteNoIata = c.originIcao != nil && c.destIcao != nil
            && c.originIata == nil && c.destIata == nil
        return noRoute || fullRouteNoIata
    }

    /// Catch-TIME route resolve (2026-07-12). The backend enriches routes
    /// opportunistically: adsb.lol carries a plane's position but not its
    /// route, so the backend looks the route up in a SEPARATE call and caches
    /// it by callsign — the first time it sees a callsign, `/v1/aircraft`
    /// ships WITHOUT the route and the value only rides a later poll (~1 poll,
    /// ~10–20 s). Since you spot-and-catch fast, the catch frequently freezes
    /// a route-less row, and the route-guess bonus round (which decides on the
    /// route present AT catch) never fires. This resolves the route right at
    /// catch — the SAME per-callsign `/v1/routes` lookup the Hangar backfill
    /// uses — so a fresh catch can carry its route immediately. Best-effort:
    /// nil on a miss, a round-trip (the resolver has no live track to pick a
    /// leg), or any transport error. Overlap it with the shutter so it adds
    /// no perceptible latency to the reveal.
    /// Bounded so a slow adsb.lol lookup can never stall the reveal (which is
    /// instant by design). The lookup overlaps the shutter/detector work at
    /// the call site, so this deadline caps only the ADDITIONAL wait past that;
    /// on a miss the row still heals later via the Hangar backfill, just
    /// without a round this time.
    static func resolveCatchTimeRoute(
        callsign: String?,
        lat: Double? = nil,
        lng: Double? = nil,
        track: Double? = nil,
        timeout: Duration = .milliseconds(1500)
    ) async -> BackendAircraft.Route? {
        guard let cs = callsign?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cs.isEmpty else { return nil }
        // Capture the Sendable client into a local so the @Sendable task-group
        // children don't reach back into MainActor-isolated static state.
        let client = routeClient
        return await withTaskGroup(of: BackendAircraft.Route?.self) { group in
            // The plane's live position + track ride along (2026-07-19) so the
            // server can pick the current leg of a multi-leg filing and reject
            // a stale one — see `TailspotBackendClient.route(forCallsign:)`.
            group.addTask {
                (try? await client.route(forCallsign: cs, lat: lat, lng: lng, track: track)) ?? nil
            }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            // First to finish wins — a fast route (hit OR a definite miss)
            // returns immediately; if the network is slow, the sleep fires and
            // we proceed route-less. Cancel the loser either way.
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Fill route facts onto `catches` (all sharing one callsign) from a
    /// complete origin+dest answer (a half route is worse than none on the
    /// card). Two cases, both fill-only-if-nil:
    ///  - BOTH codes nil → fill the whole route (codes, IATA, names).
    ///  - Full ICAO route, IATA missing → fill IATA + names ONLY when the
    ///    lookup's ICAO pair MATCHES the stored one — translating the codes
    ///    we recorded, never re-routing a catch whose current filing differs.
    /// Returns true if anything changed.
    static func applyRoute(_ route: BackendAircraft.Route, to catches: [Catch]) -> Bool {
        guard let origin = route.originIcao?.trimmedNonEmpty,
              let dest = route.destIcao?.trimmedNonEmpty else { return false }
        var changed = false
        for c in catches {
            if c.originIcao == nil && c.destIcao == nil {
                c.originIcao = origin
                c.destIcao = dest
                if let v = route.originIata?.trimmedNonEmpty { c.originIata = v }
                if let v = route.destIata?.trimmedNonEmpty { c.destIata = v }
                if let v = route.originName?.trimmedNonEmpty { c.originName = v }
                if let v = route.destName?.trimmedNonEmpty { c.destName = v }
                changed = true
            } else if c.originIcao == origin, c.destIcao == dest {
                if c.originIata == nil, let v = route.originIata?.trimmedNonEmpty {
                    c.originIata = v; changed = true
                }
                if c.destIata == nil, let v = route.destIata?.trimmedNonEmpty {
                    c.destIata = v; changed = true
                }
                if c.originName == nil, let v = route.originName?.trimmedNonEmpty {
                    c.originName = v; changed = true
                }
                if c.destName == nil, let v = route.destName?.trimmedNonEmpty {
                    c.destName = v; changed = true
                }
            }
        }
        return changed
    }

    /// One-time repair for degenerate stored routes (origin == destination):
    /// an out-and-back filing ("KLGA-KTEB-KLGA") used to collapse to
    /// "KLGA → KLGA" (field report 2026-07-05; the parser now rejects it
    /// server-side). Clearing all four fields returns the row to the
    /// fill-nil-only pool — the next lookup now answers null and it stays
    /// clean. Returns true if anything changed.
    static func clearDegenerateRoutes(_ catches: [Catch]) -> Bool {
        var changed = false
        for c in catches {
            guard let o = c.originIcao?.trimmedNonEmpty,
                  let d = c.destIcao?.trimmedNonEmpty, o == d else { continue }
            c.originIcao = nil
            c.destIcao = nil
            c.originIata = nil
            c.destIata = nil
            c.originName = nil
            c.destName = nil
            changed = true
        }
        return changed
    }

    /// Repair for IMPLAUSIBLE stored routes (2026-07-19, SFO-arrival field
    /// reports): two backend bugs wrote routes the catch was nowhere near —
    /// a multi-leg filing collapsed to first → last (UAL1375 "ONT → ORD" on
    /// an ONT → SFO arrival), and a stale per-callsign filing served verbatim
    /// (SWA1067 "MAF → DAL" on a BWI → SFO flight). Both leave the same
    /// signature: the observer (who was within slant range of the plane) is
    /// far from the stored route's great-circle corridor. Clearing the route
    /// returns the row to the fill-nil pool, where the now position-aware
    /// lookup re-fills it correctly — or honestly leaves it routeless.
    ///
    /// Deliberately LOOSER than the server's corridor gate (its tolerance
    /// plus the catch's slant distance): a route the server judged plausible
    /// for the PLANE must never be re-cleared here against the OBSERVER.
    /// A route with an endpoint missing from the bundled airport table can't
    /// be judged and is left alone. Returns true if anything changed.
    static func clearImplausibleRoutes(_ catches: [Catch]) -> Bool {
        var changed = false
        for c in catches {
            guard let o = c.originIcao?.trimmedNonEmpty?.uppercased(),
                  let d = c.destIcao?.trimmedNonEmpty?.uppercased(),
                  let origin = GuessOptions.airportsByIcao[o],
                  let dest = GuessOptions.airportsByIcao[d] else { continue }
            let slackKm = c.slantDistanceMeters / 1000
            guard !isPlausiblyOnCorridor(
                lat: c.observerLat, lon: c.observerLon,
                fromLat: origin.lat, fromLon: origin.lon,
                toLat: dest.lat, toLon: dest.lon,
                extraToleranceKm: slackKm
            ) else { continue }
            c.originIcao = nil
            c.destIcao = nil
            c.originIata = nil
            c.destIata = nil
            c.originName = nil
            c.destName = nil
            changed = true
        }
        return changed
    }

    /// Corridor plausibility, mirroring the backend's gate (`isOnCorridor` in
    /// adsblolRoutes.ts): the point must lie within a tolerance of the
    /// great-circle SEGMENT origin → destination. Mid-corridor the tolerance
    /// scales with leg length (long-haul routings bow off the great circle);
    /// beyond an endpoint only the base tolerance applies. `extraToleranceKm`
    /// widens both (the observer-to-plane slant, see caller).
    static func isPlausiblyOnCorridor(
        lat: Double, lon: Double,
        fromLat: Double, fromLon: Double,
        toLat: Double, toLon: Double,
        extraToleranceKm: Double = 0
    ) -> Bool {
        let baseKm = 250.0
        let legFraction = 0.15
        let legKm = Geo.distance(fromLat: fromLat, lon: fromLon, toLat: toLat, lon: toLon) / 1000

        let d12 = legKm * 1000 / Geo.earthRadiusMeters // angular leg length
        if d12 == 0 {
            let toOrigin = Geo.distance(fromLat: lat, lon: lon, toLat: fromLat, lon: fromLon) / 1000
            return toOrigin <= baseKm + extraToleranceKm
        }
        let d13 = Geo.distance(fromLat: fromLat, lon: fromLon, toLat: lat, lon: lon)
            / Geo.earthRadiusMeters
        let θ12 = Geo.bearing(fromLat: fromLat, lon: fromLon, toLat: toLat, lon: toLon) * .pi / 180
        let θ13 = Geo.bearing(fromLat: fromLat, lon: fromLon, toLat: lat, lon: lon) * .pi / 180
        let crossTrack = asin(sin(d13) * sin(θ13 - θ12))
        let alongTrack = acos(min(1, max(-1, cos(d13) / max(cos(crossTrack), 1e-12))))
            * (cos(θ13 - θ12) < 0 ? -1 : 1)

        let distanceKm: Double
        let onSegment: Bool
        if alongTrack < 0 {
            distanceKm = Geo.distance(fromLat: lat, lon: lon, toLat: fromLat, lon: fromLon) / 1000
            onSegment = false
        } else if alongTrack > d12 {
            distanceKm = Geo.distance(fromLat: lat, lon: lon, toLat: toLat, lon: toLon) / 1000
            onSegment = false
        } else {
            distanceKm = abs(crossTrack) * Geo.earthRadiusMeters / 1000
            onSegment = true
        }
        let tolKm = (onSegment ? max(baseKm, legFraction * legKm) : baseKm) + extraToleranceKm
        return distanceKm <= tolKm
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
    static func backfillAll(
        _ catches: [Catch],
        in context: ModelContext,
        source: ADSBSource = CatchBackfill.client
    ) async {
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
            // Per-launch negative cache: skip an icao24 already attempted this
            // launch that came back a definite miss (foreign-GA airframes the
            // backend has no record of — e.g. Noah's Bali catches — stay
            // needsMetadata forever, so without this every Hangar open re-fetches
            // them). Cleared on relaunch.
            if unresolvedIcaos.contains(trimmed) { continue }
            var transportError = false
            do {
                if let meta = try await source.aircraftMetadata(icao24: trimmed) {
                    if applyMetadata(meta, to: rows) { changedAny = true }
                }
            } catch {
                // Transient (502/offline): a real attempt but NOT a definite
                // miss — leave it out of the cache so a later open retries.
                transportError = true
            }
            // FAA fallback: if OpenSky gave nothing (typecode + model still
            // nil after the metadata attempt), try the bundled FAA snapshot.
            let needsFAA = rows.contains { $0.typecode == nil && $0.model == nil }
            if needsFAA {
                if applyFAAFallback(to: rows, icao24: trimmed) { changedAny = true }
            }
            // Record a definite miss so later same-launch passes skip it. A
            // full resolve drops out of `needsMetadata` on its own (never
            // cached); a partial fill that still needs data IS cached — we've
            // already asked the backend everything it knows this launch.
            if !transportError && rows.contains(where: needsMetadata) {
                unresolvedIcaos.insert(trimmed)
            }
            if Task.isCancelled { break }
        }

        // Degenerate-route repair (2026-07-05): "KLGA → KLGA" rows from the
        // old first→last collapse of out-and-back filings get cleared, which
        // drops them back into the fill pool below (where the fixed lookup
        // now answers null). No network; must run BEFORE needsRoute filters.
        if clearDegenerateRoutes(catches) { changedAny = true }

        // Implausible-route repair (2026-07-19): a stored route whose corridor
        // the catch was nowhere near (the stale-filing / first→last-collapse
        // bugs) gets cleared, dropping the row into the fill pool below where
        // the position-aware lookup re-answers correctly or honestly nil.
        if clearImplausibleRoutes(catches) { changedAny = true }

        // Route backfill (2026-07-04): fill origin → destination onto catches
        // that predate route capture — and, since 2026-07-05, IATA display
        // codes onto rows that have an ICAO route but predate the IATA
        // fields. PER ROW since 2026-07-19, because the lookup now carries
        // the catch's observer position (the plane was within slant range of
        // it) so the server can pick the leg of a multi-leg filing and gate a
        // stale one — and two catches sharing a callsign can be different
        // flights on different legs. Deduped by callsign + coarse position so
        // same-spot rows still cost one lookup. Errors are swallowed per
        // lookup (a 502/offline just means a later Hangar open retries); a
        // null route is a real answer we stop on for this pass.
        var routeCache: [String: BackendAircraft.Route?] = [:]
        for c in catches.filter(needsRoute) {
            if Task.isCancelled { break }
            let callsign = (c.callsign ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !callsign.isEmpty else { continue }
            // ~0.1° bucket (≈11 km) — catches from one spotting session share
            // a lookup; a different day's catch elsewhere gets its own. The
            // SAME key feeds the per-launch negative cache: answers are
            // position-aware now, so a definite miss for one spot must not
            // silence a different spot's lookup for the same callsign.
            let key = "\(callsign)|\(Int(c.observerLat * 10))|\(Int(c.observerLon * 10))"
            if unresolvedCallsigns.contains(key) { continue }
            let route: BackendAircraft.Route?
            if let cached = routeCache[key] {
                route = cached
            } else {
                guard let fetched = try? await routeClient.route(
                    forCallsign: callsign, lat: c.observerLat, lng: c.observerLon
                ) else { continue } // transport error → retry next pass, don't cache
                routeCache[key] = fetched
                route = fetched
            }
            if let route, applyRoute(route, to: [c]) { changedAny = true }
            // A definite answer (a null route, or one this row couldn't use)
            // that leaves the row still needing a route won't resolve again
            // this launch — negative-cache the callsign+spot so later Hangar
            // opens skip the doomed re-fetch. A successful fill drops out of
            // `needsRoute` on its own and is never cached.
            if needsRoute(c) { unresolvedCallsigns.insert(key) }
        }

        if changedAny { try? context.save() }
    }

    /// UserDefaults key + current version for the one-time `photoFocus`
    /// recovery. Bump the version to force a re-scan after the baked
    /// brackets change on disk (e.g. an offline heal re-draws them).
    static let focusBackfillVersionKey = "tailspot.focusBackfillVersion"
    static let focusBackfillVersion = 1

    /// One-time pass: for every catch with a saved photo, recover the crop
    /// focus from the baked cyan bracket (`CatchPhotoFocusRecovery`) so
    /// pre-focus / re-healed catches center the plane instead of
    /// center-cropping. Version-gated so it scans once; file read + pixel
    /// scan run off the MainActor, only the model write is here. Sets focus
    /// when it's nil OR the bracket has clearly moved from the stored point
    /// (a heal) — a no-op for new catches, which already store this point.
    static func backfillPhotoFocus(_ catches: [Catch], in context: ModelContext) async {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: focusBackfillVersionKey) < focusBackfillVersion
        else { return }

        var changed = false
        var completed = true
        for c in catches {
            if Task.isCancelled { completed = false; break }
            guard let name = c.photoFilename,
                  let url = CatchPhotoStore.url(forFilename: name) else { continue }
            let focus = await Task.detached(priority: .utility) { () -> CGPoint? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return CatchPhotoFocusRecovery.recoverFocus(fromJPEG: data)
            }.value
            guard let focus else { continue }
            let movedX = abs((c.photoFocusX ?? -9) - Double(focus.x))
            let movedY = abs((c.photoFocusY ?? -9) - Double(focus.y))
            if c.photoFocusX == nil || movedX > 0.03 || movedY > 0.03 {
                c.photoFocusX = Double(focus.x)
                c.photoFocusY = Double(focus.y)
                changed = true
            }
        }
        if changed { try? context.save() }
        // Only mark done on a full pass — a cancelled run resumes next open.
        if completed { defaults.set(focusBackfillVersion, forKey: focusBackfillVersionKey) }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
