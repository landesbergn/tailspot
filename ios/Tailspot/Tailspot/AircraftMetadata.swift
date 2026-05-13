//
//  AircraftMetadata.swift
//  Tailspot
//
//  Per-aircraft metadata from OpenSky's
//  /api/metadata/aircraft/icao/{icao24} endpoint. Decoded once per
//  unique icao24 that the user taps, cached in MetadataCache.
//
//  Almost every field is optional — OpenSky's DB has plenty of holes,
//  especially for non-US GA. icao24 is the only field we require.
//
//  `nonisolated` + `Sendable` per the repo convention: this is a pure
//  value type that flows from the OpenSky client (any actor) to
//  ADSBManager (@MainActor) to the detail view.
//

import Foundation

nonisolated struct AircraftMetadata: Equatable, Sendable {
    let icao24: String
    let registration: String?
    let manufacturerName: String?
    let manufacturerIcao: String?
    let model: String?
    let typecode: String?
    // `operator` is a Swift reserved word; decode the JSON key
    // "operator" into `operatorName` via CodingKeys.
    let operatorName: String?
}

nonisolated extension AircraftMetadata: Decodable {
    enum CodingKeys: String, CodingKey {
        case icao24
        case registration
        case manufacturerName
        case manufacturerIcao
        case model
        case typecode
        case operatorName = "operator"
    }
}
