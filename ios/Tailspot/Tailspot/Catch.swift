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
import CoreGraphics
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
    /// catch moment, when the live feed carried a route. Recorded as-observed;
    /// a FULLY-nil route may later heal via `CatchBackfill`'s per-callsign
    /// lookup (2026-07-04, best-effort current filing — see CLAUDE.md's
    /// frozen-moment exceptions). nil for the many routeless catches
    /// (GA/military). Added 2026-06 — optional + nil-default for SwiftData
    /// lightweight migration.
    var originIcao: String?
    /// ICAO airport code (4-letter, e.g. "EGLL") of the flight's DESTINATION at
    /// the catch moment. Same source/semantics/migration as `originIcao`.
    var destIcao: String?
    /// IATA display code (3-letter, e.g. "HND") of the origin, when the route
    /// source carried it — what travelers read; display goes through
    /// `displayOrigin`, which prefers this and falls back to the ICAO code.
    /// Added 2026-07-05 — optional + nil-default for lightweight migration.
    var originIata: String?
    /// IATA display code of the destination. Same as `originIata`.
    var destIata: String?
    /// Human-readable origin airport / city (e.g. "Tokyo Narita"), when the
    /// route source provided it. Same optional/nil-default lightweight-migration
    /// lifecycle as `originIcao`; shown under the ICAO code in the reveal.
    var originName: String?
    /// Human-readable destination airport / city (e.g. "San Francisco").
    var destName: String?
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
    /// Why the authenticity gates doubted this catch at capture time
    /// (`"occluded"` / `"too_far"` / `"indoor"`), or nil for a clean or
    /// user-kept catch. Post-catch confirm model (2026-07-04): gates never
    /// block — a suspected catch records + reveals instantly, then gets one
    /// Keep/Discard question after the reveal. While non-nil the row is
    /// quarantined from upload (`CatchUploader` skips it); Keep clears the
    /// flag (uploads next scene-activation), Discard deletes the row.
    /// Added 2026-07-04 — optional + nil-default for lightweight migration.
    var suspectReason: String?
    /// Where the caught plane sits inside the saved catch photo, as
    /// NORMALIZED photo coordinates (0…1, top-left origin) — the same point
    /// the composer draws the lock-on bracket around. Lets every photo
    /// display (settled card, reveal, share) anchor its aspect-fill crop on
    /// the plane instead of the frame center, so an off-center plane isn't
    /// cropped out of the hero. nil (pre-field rows / compose failures) →
    /// center crop, the old behavior. Added 2026-07-05 — optional +
    /// nil-default for lightweight migration.
    var photoFocusX: Double?
    var photoFocusY: Double?
    /// Which bonus-round question this catch was asked and ANSWERED —
    /// `"route"` / `"type"` (`GuessKind.rawValue`). nil = the round never
    /// fired for this catch or the user hit SKIP. Written once at answer
    /// time (game-layer PR3) and shipped with the deferred upload, never
    /// mutated after. Like `serverUuid`, not exposed on the init — the
    /// guess happens after the row is born. Added 2026-07 (game-layer
    /// PR2) — optional + nil-default for lightweight migration.
    var guessKind: String?
    /// The guessed VALUE, frozen at answer time: an ICAO airport ident
    /// ("VHHH") for route guesses, an ICAO typecode ("B738") for type
    /// guesses. This — never a verdict — is what `POST /v1/catches`
    /// carries; the server verifies it against its own truth. Same
    /// lifecycle/migration as `guessKind`.
    var guessValue: String?
    /// The LOCAL verdict, frozen at answer time — drives the reveal
    /// ledger and guess trophies offline. The server independently
    /// re-verifies at upload (`UploadCatchResponse.guessCorrect`);
    /// rare drift is accepted (plan §A4, D9 optimistic). Same
    /// lifecycle/migration as `guessKind`.
    var guessCorrect: Bool?
    /// Capture-time targeting context as a JSON `CatchCaptureDiagnostics`
    /// blob: the camera pose, compass accuracy, the caught plane's crosshair
    /// offset, and the other candidates the selector passed over. PURE
    /// DEBUGGING — never read by scoring/display/gates; lets a "wrong plane"
    /// mis-catch be diagnosed from the row (the A319 field case, 2026-07-13)
    /// without a live replay. Written once at catch time, like `serverUuid`
    /// not exposed on the init. Added 2026-07-13 — optional + nil-default for
    /// SwiftData lightweight migration; old rows simply have nil.
    var captureDiagnosticsJSON: String?

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
        originIata: String? = nil,
        destIata: String? = nil,
        originName: String? = nil,
        destName: String? = nil,
        placeName: String? = nil,
        country: String? = nil,
        rarity: Rarity? = nil,
        aircraftType: AircraftType? = nil,
        suspectReason: String? = nil,
        photoFocusX: Double? = nil,
        photoFocusY: Double? = nil
    ) {
        self.suspectReason = suspectReason
        self.photoFocusX = photoFocusX
        self.photoFocusY = photoFocusY
        self.originIata = originIata
        self.destIata = destIata
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
        self.originName = originName
        self.destName = destName
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

    /// The airport code to DISPLAY for the origin: the IATA code when we
    /// have it ("HND" — what travelers actually read), falling back to the
    /// ICAO ident ("RJTT"). Every route display site goes through this pair
    /// rather than reading `originIcao` directly (Noah, 2026-07-05).
    var displayOrigin: String? { originIata ?? originIcao }
    /// Display code for the destination. Same preference as `displayOrigin`.
    var displayDest: String? { destIata ?? destIcao }

    /// The photo focus as a CGPoint, or nil when either axis is missing
    /// (pre-field rows) — callers treat nil as "center crop".
    var photoFocus: CGPoint? {
        guard let x = photoFocusX, let y = photoFocusY else { return nil }
        return CGPoint(x: x, y: y)
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
