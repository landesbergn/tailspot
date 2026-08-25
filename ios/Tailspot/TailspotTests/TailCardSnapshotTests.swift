//
//  TailCardSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the Hangar tail card (RevealSnapshotTests
//  pattern): renders the rich Recent variant + the compact Sets variant to
//  PNGs via ImageRenderer so the layout can be eyeballed off-device. NOT an
//  assertion test: it writes images to /private/tmp/tailspot_snaps and
//  passes. Review the PNGs after running. Edge cases per the visual-pass
//  rule: routes (both/one-sided/none), long names, every rarity tier,
//  callsign fallbacks.
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
import os
@testable import Tailspot

@MainActor
@Suite("Tail card snapshots (visual pass)")
struct TailCardSnapshotTests {

    private func makeCatch(
        icao: String, callsign: String?, model: String?, manufacturer: String?,
        operatorName: String?, typecode: String?,
        origin: String? = nil, dest: String? = nil,
        place: String? = nil,
        // Default sits BEFORE the 2026-08-13 route re-balance cutover, so a
        // route guess on it renders the legacy +10% era. Bonus cases that
        // want the +25% era pass a post-cutover instant.
        caughtAt: TimeInterval = 1_783_150_000
    ) -> Catch {
        Catch(
            icao24: icao, callsign: callsign, model: model,
            manufacturer: manufacturer, operatorName: operatorName,
            caughtAt: Date(timeIntervalSince1970: caughtAt),
            observerLat: 35.55, observerLon: 139.78,
            slantDistanceMeters: 9_800,
            typecode: typecode,
            originIcao: origin, destIcao: dest,
            placeName: place
        )
    }

    /// Stamps a recorded CORRECT route call onto the row (guess fields
    /// aren't on the init — the guess happens after the row is born).
    private func withCorrectRouteGuess(_ c: Catch) -> Catch {
        c.guessKind = GuessKind.route.rawValue
        c.guessValue = c.destIcao ?? "KSFO"
        c.guessCorrect = true
        return c
    }

    @Test func renderTailCards() {
        let dir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // (name, catch, rich variant, first-of-type)
        let cases: [(String, Catch, Bool, Bool)] = [
            ("card_route_common", makeCatch(
                icao: "86e123", callsign: "ANA858", model: "787-9", manufacturer: "Boeing",
                operatorName: "All Nippon Airways", typecode: "B789",
                origin: "RJTT", dest: "KSFO", place: "Ota City"), true, false),
            ("card_oneside_route_rare", makeCatch(
                icao: "3b7440", callsign: "GEC8160", model: "747-400", manufacturer: "Boeing",
                operatorName: "Lufthansa Cargo", typecode: "B744",
                origin: "RJAA", dest: nil), true, false),
            ("card_noroute_ga", makeCatch(
                icao: "a4e172", callsign: "N4521C", model: "172", manufacturer: "Cessna",
                operatorName: nil, typecode: "C172", place: "Berkeley, CA"), true, false),
            ("card_longname_epic", makeCatch(
                icao: "ae01c7", callsign: "RCH872", model: "C-17 Globemaster III",
                manufacturer: "Boeing", operatorName: "U.S. Air Force", typecode: "C17",
                origin: "KSUU", dest: "PHIK"), true, false),
            ("card_legendary_nocallsign", makeCatch(
                icao: "ae0b52", callsign: nil, model: "B-52 Stratofortress",
                manufacturer: "Boeing", operatorName: "U.S. Air Force", typecode: "B52",
                origin: "KBAD", dest: nil, place: "Barksdale"), true, false),
            ("card_missing_everything", makeCatch(
                icao: "84b0a5", callsign: nil, model: nil, manufacturer: nil,
                operatorName: nil, typecode: nil), true, false),
            ("card_sets_compact_regression", makeCatch(
                icao: "86e123", callsign: "ANA858", model: "787-9", manufacturer: "Boeing",
                operatorName: "All Nippon Airways", typecode: "B789",
                origin: "RJTT", dest: "KSFO", place: "Ota City"), false, false),
            // Bonus rows — the C+ readout (mock round 2026-08-24): full total
            // over the "base +bonus" micro-ledger in one rarity tint, gold
            // sparkle on the model line for first-of-type.
            ("card_bonus_first_and_guess_legendary", withCorrectRouteGuess(makeCatch(
                icao: "ae0b53", callsign: "DOOM91", model: "B-52 Stratofortress",
                manufacturer: "Boeing", operatorName: "U.S. Air Force", typecode: "B52",
                origin: "KBAD", dest: "KSFO", caughtAt: 1_787_000_000)), true, true),
            ("card_bonus_first_epic", makeCatch(
                icao: "ae01c8", callsign: "RCH873", model: "C-17 Globemaster III",
                manufacturer: "Boeing", operatorName: "U.S. Air Force", typecode: "C17",
                origin: "KSUU", dest: "PHIK", caughtAt: 1_787_000_000), true, true),
            // Pre-cutover correct route call — the legacy +10% era readout
            // (the default caughtAt predates the re-balance).
            ("card_bonus_guess_legacy", withCorrectRouteGuess(makeCatch(
                icao: "86e124", callsign: "ANA857", model: "787-9", manufacturer: "Boeing",
                operatorName: "All Nippon Airways", typecode: "B789",
                origin: "KSFO", dest: "RJTT", place: "Ota City")), true, false),
        ]

        for (name, c, rich, first) in cases {
            let row = HangarRow(icao24: c.icao24, mostRecent: c, count: 1, allCatches: [c])
            let view = TailCard(row: row, showPoints: rich, isFirstOfType: first)
                .frame(width: 361)
                .padding(12)
                .background(Brand.Color.bgPrimary)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            guard let ui = renderer.uiImage, let png = ui.pngData() else {
                Log.ui.error("TailCard snapshot render failed: \(name, privacy: .public)")
                continue
            }
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
        }
        #expect(true)
    }
}
#endif
