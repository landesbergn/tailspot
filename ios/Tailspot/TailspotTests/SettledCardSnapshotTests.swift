//
//  SettledCardSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the Direction-B detail card (RevealSnapshotTests
//  pattern): renders `SettledCatchCard` to PNGs via ImageRenderer so the
//  settled layout can be eyeballed off-device. NOT an assertion test — it
//  writes to /private/tmp/tailspot_snaps and passes. Cases cover: full
//  IATA route, no route (DIST fallback), first-of-type ledger line, long
//  wrapped names, and the tier extremes.
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
import os
@testable import Tailspot

@MainActor
@Suite("Settled card snapshots (visual pass)")
struct SettledCardSnapshotTests {

    @Test func renderSettledCards() {
        let dir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let cases: [(String, CardPlane, Bool)] = [
            ("settled_route_common", CardPlane(
                callsign: "JAL305", model: "Boeing 737-800", carrier: "Japan Airlines",
                rarity: .common, type: .narrow,
                altText: "4,250 ft", speedText: "192 kt", distText: "38.6 km",
                originIcao: "HND", destIcao: "FUK",
                originName: "Tokyo", destName: "Fukuoka"), false),
            ("settled_firstoftype_epic", CardPlane(
                callsign: "RCH872", model: "Boeing C-17 Globemaster III", carrier: "U.S. Air Force",
                rarity: .epic, type: .mil,
                altText: "27,887 ft", speedText: "418 kt", distText: "9.2 km",
                originIcao: "SUU", destIcao: "HIK",
                originName: "Travis AFB", destName: "Honolulu"), true),
            ("settled_noroute_ga", CardPlane(
                callsign: "N4521C", model: "Cessna 172", carrier: "Private",
                rarity: .common, type: .ga,
                altText: "3,609 ft", speedText: "101 kt", distText: "3.8 km"), false),
            ("settled_legendary_oneside", CardPlane(
                callsign: "DOOM11", model: "Boeing B-52 Stratofortress", carrier: "U.S. Air Force",
                rarity: .legendary, type: .mil,
                altText: "40,026 ft", speedText: "488 kt", distText: "31.0 km",
                originIcao: "BAD", destIcao: nil,
                originName: "Barksdale AFB", destName: nil), true),
            ("settled_missing_everything", CardPlane(
                callsign: nil, model: nil, carrier: nil,
                rarity: .common, type: .ga,
                altText: nil, speedText: nil, distText: "12.0 km"), false),
        ]

        for (name, plane, fot) in cases {
            let view = VStack {
                SettledCatchCard(plane: plane, isFirstOfType: fot, width: 357)
            }
            .padding(12)
            .background(Brand.Color.bgPrimary)
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            guard let ui = renderer.uiImage, let png = ui.pngData() else {
                Log.ui.error("Settled card snapshot render failed: \(name, privacy: .public)")
                continue
            }
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
        }
        #expect(true)
    }
}
#endif
