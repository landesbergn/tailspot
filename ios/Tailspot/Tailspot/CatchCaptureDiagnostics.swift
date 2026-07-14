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

    nonisolated struct Alternative: Codable, Equatable, Sendable {
        var icao24: String
        var offsetDeg: Double
        var slantKm: Double
        var arcmin: Double
    }

    /// Encode to the compact JSON stored on the row. Returns nil only if
    /// encoding fails (it won't for this value type) so the catch never fails
    /// on a diagnostics problem.
    func jsonString() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode a stored blob for offline debugging.
    static func from(json: String?) -> CatchCaptureDiagnostics? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CatchCaptureDiagnostics.self, from: data)
    }
}
