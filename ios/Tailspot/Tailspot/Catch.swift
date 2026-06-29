//
//  Catch.swift
//  Tailspot
//
//  The persisted record of "user tapped Catch on this aircraft."
//
//  Stored via SwiftData. SwiftData is Apple's modern persistence
//  framework (iOS 17+): you annotate a class with @Model and it
//  generates the database schema, change tracking, and query API
//  for you. Compared to Core Data it removes the boilerplate
//  (xcdatamodeld file, NSManagedObject subclasses) and integrates
//  natively with SwiftUI's @Query / .modelContainer modifiers.
//
//  v1 keeps the schema flat and stores everything we know at catch
//  time — including the metadata snapshot — so the Hangar list view
//  doesn't have to re-fetch anything. Future migrations can split
//  this into joined tables if it grows.
//
//  @Model classes are reference types (final class) and isolated to
//  the actor of the ModelContext that holds them. The repo's
//  MainActor-default isolation under Xcode 26 means Catch instances
//  are MainActor — which matches reality: the only places we
//  insert/query catches are SwiftUI views (always MainActor).
//

import Foundation
import SwiftData

@Model
final class Catch {
    var icao24: String
    var callsign: String?
    var model: String?
    var manufacturer: String?
    /// Airline / operator name as reported by OpenSky's metadata
    /// endpoint at catch time. Added in Hangar v0 so the collection
    /// can group by airline as well as aircraft type. Optional and
    /// nullable — older rows written before this field existed simply
    /// have nil here (SwiftData lightweight migration).
    var operatorName: String?
    /// Filename (not full path) of the camera frame captured at the
    /// moment of the auto-catch, saved at
    /// `Documents/catches/<filename>.jpg`. Optional — catches written
    /// before auto-catch shipped have nil; catches where the camera
    /// capture failed also have nil. The file-on-disk approach keeps
    /// photo bytes out of the SwiftData store so the DB doesn't bloat
    /// as the collection grows.
    var photoFilename: String?
    var caughtAt: Date
    var observerLat: Double
    var observerLon: Double
    var slantDistanceMeters: Double
    /// Rarity tier snapshotted at catch time. Persisted as the raw
    /// string value so SwiftData doesn't care about the Swift enum.
    /// Optional + nil-by-default so lightweight migration covers
    /// pre-existing rows; the `resolvedRarity` computed property
    /// backfills via the classifier when nil.
    var rarity: String?
    /// Pokédex-style aircraft type snapshotted at catch time. Same
    /// storage strategy as `rarity` — raw string, optional, backfilled
    /// by the classifier when nil.
    var aircraftType: String?
    /// Tail number (registration) from OpenSky metadata at catch time —
    /// or recovered later by the detail view's backfill (registration
    /// is a property of the airframe, not the moment). Added 2026-06,
    /// optional + nil-default for lightweight migration.
    var registration: String?
    /// ICAO type designator ("B77W") — the key into AircraftNaming's
    /// DOC 8643 table. Same migration strategy as `registration`.
    var typecode: String?
    /// ADS-B emitter category as broadcast at the catch moment (e.g. "A5"
    /// heavy, "A7" rotorcraft). As-observed from the live feed — the FAA-only
    /// metadata endpoint doesn't carry it, so there's no backfill source; old
    /// rows stay nil. Its job is authoritative rotorcraft tagging (A7 → the
    /// "helicopter" tag / Whirlybird trophy) without guessing from brand
    /// strings. Added 2026-06 — optional + nil-default for lightweight migration.
    var category: String?
    /// Aircraft altitude (m MSL) at the catch moment. NEVER backfilled
    /// — the moment is unrecoverable; old rows render "—".
    var altitudeMeters: Double?
    /// Aircraft ground speed (m/s) at the catch moment. Same rules as
    /// `altitudeMeters`.
    var velocityMps: Double?
    /// ICAO airport code (4-letter, e.g. "KSFO") of the flight's ORIGIN at the
    /// catch moment, when the live feed carried a route. A frozen-at-catch
    /// airframe/flight fact like altitude/velocity — NEVER backfilled (the route
    /// of a past flight is unrecoverable). nil for the many routeless catches
    /// (GA/military) and for rows written before this field existed. Added
    /// 2026-06 — optional + nil-default for SwiftData lightweight migration.
    var originIcao: String?
    /// ICAO airport code (4-letter, e.g. "EGLL") of the flight's DESTINATION at
    /// the catch moment. Same source/semantics/migration as `originIcao`.
    var destIcao: String?
    /// Reverse-geocoded observer place, e.g. "Berkeley, CA". Filled
    /// post-save at catch time (never blocks the catch) or by the
    /// detail-view backfill.
    var placeName: String?
    /// Reverse-geocoded observer COUNTRY — a stable key (ISO country code
    /// when available, else the country display name), e.g. "US". Same
    /// fill-if-nil lifecycle as `placeName` (post-save at catch time or the
    /// detail-view backfill). Drives the Mr. Worldwide trophy (catch in 2+
    /// countries). Added 2026-06 — optional + nil-default for lightweight
    /// migration; pre-existing rows backfill on a later detail-view open.
    var country: String?
    /// Stable per-device UUID for this catch, used as the server-side
    /// idempotency key when uploading to `POST /v1/catches`. Assigned
    /// lazily by `CatchUploader` (not at insert time) so existing rows
    /// stay valid; once set it is never regenerated, so a retry after a
    /// network failure replays the SAME uuid and the server dedupes.
    /// Added WP 1.7 — optional + nil-default for lightweight migration.
    var serverUuid: String?
    /// When this catch was successfully accepted by the backend (fresh
    /// insert OR server-confirmed duplicate). `nil` → still pending
    /// upload; `CatchUploader.uploadPending` fetches exactly the nil
    /// rows. Added WP 1.7 — optional + nil-default for lightweight
    /// migration (every pre-WP-1.7 row is "pending" and uploads on the
    /// next launch, which is the intended backfill behavior).
    var uploadedAt: Date?

    init(
        icao24: String,
        callsign: String?,
        model: String?,
        manufacturer: String?,
        operatorName: String? = nil,
        photoFilename: String? = nil,
        caughtAt: Date,
        observerLat: Double,
        observerLon: Double,
        slantDistanceMeters: Double,
        registration: String? = nil,
        typecode: String? = nil,
        category: String? = nil,
        altitudeMeters: Double? = nil,
        velocityMps: Double? = nil,
        originIcao: String? = nil,
        destIcao: String? = nil,
        placeName: String? = nil,
        country: String? = nil,
        rarity: Rarity? = nil,
        aircraftType: AircraftType? = nil
    ) {
        self.icao24 = icao24
        self.callsign = callsign
        self.model = model
        self.manufacturer = manufacturer
        self.operatorName = operatorName
        self.photoFilename = photoFilename
        self.caughtAt = caughtAt
        self.observerLat = observerLat
        self.observerLon = observerLon
        self.slantDistanceMeters = slantDistanceMeters
        self.registration = registration
        self.typecode = typecode
        self.category = category
        self.altitudeMeters = altitudeMeters
        self.velocityMps = velocityMps
        self.originIcao = originIcao
        self.destIcao = destIcao
        self.placeName = placeName
        self.country = country
        // If the caller didn't explicitly classify, run the classifier
        // at insert time so the row is born with a stable (rarity, type)
        // pair. Rows written before this field existed end up with nil
        // and get backfilled on read via `resolvedRarity` / `resolvedType`.
        let (autoRarity, autoType) = AircraftClassifier.classify(
            manufacturer: manufacturer,
            model: model,
            operatorName: operatorName
        )
        self.rarity = (rarity ?? autoRarity).rawValue
        self.aircraftType = (aircraftType ?? autoType).rawValue
    }

    /// The rarity tier for this airframe. Resolved live from the
    /// typecode (authoritative, like `resolvedType`); when there is NO
    /// typecode it resolves to a single conservative default (`.common`).
    ///
    /// SINGLE-SOURCE RULE: rarity has exactly ONE source — the per-typecode
    /// `rarity` in AircraftTypes.json (`AircraftNaming.rarity(forTypecode:)`).
    /// The string classifier no longer supplies a rarity here: its curated
    /// ladder diverged from the activity table, so the no-typecode path is a
    /// flat `.common` rather than a second tier ladder. (The classifier still
    /// provides the no-typecode TYPE — see `resolvedType`; only its rarity
    /// output stopped being a rarity source.)
    ///
    /// NOTE: unlike `resolvedType`, this does NOT read the stored
    /// `rarity` snapshot. Rarity floats with the activity table so
    /// re-tiering corrects prior catches on read (spec 2026-06-08) —
    /// the deliberate exception to the frozen-moment rule. The stored
    /// `rarity` string is kept only as an as-caught audit value.
    var resolvedRarity: Rarity {
        if let r = AircraftNaming.rarity(forTypecode: typecode) { return r }
        return .common
    }

    /// The aircraft type for this airframe.
    ///
    /// Priority:
    ///   1. Typecode → DOC 8643/FAA-derived type from the bundled table.
    ///      Read-time lookup so backfilled catches re-bucket automatically
    ///      when the table is regenerated, without a schema migration.
    ///   2. Stored snapshot (`aircraftType` raw string) — a stable frozen
    ///      value written at catch time from the classifier.
    ///   3. String classifier fallback for pre-typecode rows.
    var resolvedType: AircraftType {
        // Authoritative: typecode → DOC 8643/FAA-derived type.
        if let t = AircraftNaming.aircraftType(forTypecode: typecode) { return t }
        if let raw = aircraftType, let t = AircraftType(rawValue: raw) { return t }
        return AircraftClassifier.classify(
            manufacturer: manufacturer,
            model: model,
            operatorName: operatorName
        ).type
    }

    /// Returns true when at least one `Catch` row with the given icao24
    /// (case-insensitive comparison after trim) exists in the context.
    /// Used by the capture path to gate insertion — duplicates render as
    /// quiet "ALREADY CAUGHT" reveals but don't add a new row.
    nonisolated static func exists(icao24: String, in context: ModelContext) -> Bool {
        let key = icao24.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return false }
        let predicate = #Predicate<Catch> { $0.icao24 == key }
        var descriptor = FetchDescriptor<Catch>(predicate: predicate)
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor).first) != nil)
    }

    /// The airframe field (typecode / registration) to persist on a new catch,
    /// preferring the LIVE position feed over the per-hex metadata endpoint.
    ///
    /// adsb.lol carries `t`/`r` for essentially every airframe — including the
    /// foreign-registered tails the backend's FAA-only `/v1/metadata` cannot
    /// resolve — so the feed value is both more available and as-observed. A
    /// blank string is treated as absent (returns nil) so the fill-only-if-nil
    /// Hangar backfill can still heal the field later from a richer source.
    nonisolated static func preferredAirframeField(feed: String?, metadata: String?) -> String? {
        func cleaned(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        return cleaned(feed) ?? cleaned(metadata)
    }
}

// MARK: - Photo file helpers

/// Filesystem helpers for catch photos. Catches don't ship the photo
/// bytes inside the SwiftData store — they ship a filename. The bytes
/// live in `Documents/catches/<filename>.jpg`, which `Documents/` puts
/// inside the app sandbox.
nonisolated enum CatchPhotoStore {
    /// The directory all catch photos live in. Created lazily.
    static func directory() throws -> URL {
        let docs = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = docs.appendingPathComponent("catches", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write `data` to a uniquely-named .jpg in the catches dir and
    /// return the bare filename to stash on the `Catch`. Filename
    /// embeds icao + epoch timestamp so it's grep-friendly during
    /// debugging. Returns nil on any file-system error — we never
    /// throw past this point; a Catch can exist without a photo.
    static func save(_ data: Data, icao24: String, at timestamp: Date) -> String? {
        do {
            let dir = try directory()
            let filename = "\(icao24.lowercased())_\(Int(timestamp.timeIntervalSince1970)).jpg"
            let url = dir.appendingPathComponent(filename)
            try data.write(to: url, options: .atomic)
            return filename
        } catch {
            return nil
        }
    }

    /// Resolve a bare filename to the full on-disk URL. Returns nil if
    /// the file isn't present (e.g., user deleted Documents via Files
    /// or the app sandbox got cleared).
    static func url(forFilename filename: String) -> URL? {
        guard let dir = try? directory() else { return nil }
        let candidate = dir.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Delete the photo file for a Catch being removed. Safe to call
    /// with a nil filename (no-op) or a missing file (no-op).
    static func delete(filename: String?) {
        guard let filename, let url = url(forFilename: filename) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
