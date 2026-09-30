//
//  CatchCaptureDiagnostics.swift
//  Tailspot
//
//  What the app knew about HOW a plane got selected at the moment of capture —
//  the camera pose, the compass quality, and the OTHER candidates the selector
//  passed over. Stored as a single JSON blob on the Catch row
//  (`captureDiagnosticsJSON`) so a mis-catch (wrong plane) is diagnosable from
//  the row itself instead of needing a live replay that recording wasn't
//  running for (the A319 field case, 2026-07-13).
//
//  Pure debugging data — never drives scoring, display, or gates. One JSON
//  field keeps the SwiftData schema flat and lets fields be added later
//  without a new migration.
//

import Foundation

/// The capture-time targeting context for one catch, encoded into
/// `Catch.captureDiagnosticsJSON`.
nonisolated struct CatchCaptureDiagnostics: Codable, Equatable, Sendable {
    /// Camera look direction at capture: heading (° true north), elevation
    /// (° above horizon, = 90 − pitch), roll (°), and zoom factor.
    var headingDeg: Double?
    var cameraElevationDeg: Double?
    var rollDeg: Double?
    var zoom: Double?
    /// `CLLocation.headingAccuracy` (°) at capture — the σ that scales the
    /// selector; large = the reticle was untrustworthy. -1 = OS says invalid.
    var headingAccuracyDeg: Double?
    /// The caught plane's angular offset (°) from the crosshair.
    var targetOffsetDeg: Double?
    /// The caught plane's apparent angular size (arcmin).
    var targetArcmin: Double?
    /// True = an explicit tap pinned this plane; false = center capture.
    var wasTapped: Bool?
    /// How many labelable planes were in the catch zone (1 = no ambiguity).
    var candidateCount: Int?
    /// The other in-zone candidates the selector passed over, nearest-offset
    /// first — the field that answers "was there a closer plane you meant?".
    var alternatives: [Alternative]?
    /// The selector that chose this plane.
    var selector: String?

    // ── Caught aircraft's position at shutter press (added 2026-09-07) ──
    // The ADS-B fix the app was looking at when the shutter fired. Recorded so
    // the upload can hand the backend's catch validator something to correlate
    // the observer pose against — without it every stored verdict is
    // "unverifiable" and anti-cheat can't work (see
    // backend/src/catches/validateCatch.ts).
    //
    // These are ADDITIVE optionals: blobs written before this change simply
    // lack the keys, and Swift's synthesized Decodable turns an absent key for
    // an Optional into nil. Old rows keep decoding exactly as before.
    var aircraftLat: Double? = nil
    var aircraftLon: Double? = nil
    var aircraftAltitudeMeters: Double? = nil
    /// The timestamp of that ADS-B fix. Encoded as UNIX SECONDS (see the
    /// coder configuration below) rather than Foundation's default
    /// "seconds since 2001" so the value is readable next to every other
    /// timestamp in the system (and matches what the wire wants).
    var aircraftPositionTimestamp: Date? = nil

    nonisolated struct Alternative: Codable, Equatable, Sendable {
        var icao24: String
        var offsetDeg: Double
        var slantKm: Double
        var arcmin: Double
    }

    // Dates go over as unix seconds in BOTH directions. The struct had no
    // Date field before `aircraftPositionTimestamp`, so switching the strategy
    // can't change how any previously-written blob decodes.
    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    /// Encode to the compact JSON stored on the row. Returns nil only if
    /// encoding fails (it won't for this value type) so the catch never fails
    /// on a diagnostics problem.
    func jsonString() -> String? {
        guard let data = try? Self.encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode a stored blob for offline debugging.
    static func from(json: String?) -> CatchCaptureDiagnostics? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(CatchCaptureDiagnostics.self, from: data)
    }
}
