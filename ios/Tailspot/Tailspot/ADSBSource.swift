//
//  ADSBSource.swift
//  Tailspot
//
//  A protocol — Swift's term for "interface" — that says: anyone who
//  conforms to ADSBSource must provide a way to fetch aircraft inside
//  a lat/lon bounding box. Once we have this, ADSBManager can call
//  `aircraftInBbox` without caring whether the data is coming from
//  OpenSky, a mock generator for couch-testing, or — eventually —
//  our own backend proxy.
//
//  The protocol is `Sendable` so the conformer can be safely held by
//  the @MainActor ADSBManager and called across an `await`. (Same
//  reason OpenSkyClient was made Sendable last commit.)
//

import Foundation

protocol ADSBSource: Sendable {
    func aircraftInBbox(
        lamin: Double, lomin: Double, lamax: Double, lomax: Double
    ) async throws -> [Aircraft]
}
