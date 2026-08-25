//
//  DouglasSetsSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness (SettledCardSnapshotTests pattern) for the
//  McDonnell Douglas naming rework: renders the settled catch card for an
//  MD-11 with the name derived through AircraftNaming — proving a catch
//  whose stored manufacturer is the pre-rename "Boeing" re-labels on read.
//  PNG lands in /private/tmp/tailspot_snaps. NOT an assertion test (the
//  one #expect pins the derived name itself).
//
//  The set screens themselves aren't renderable here: SetDetailScreen is
//  List-backed (ImageRenderer draws the prohibition glyph for UIKit-backed
//  containers) and SetsBrowser is a LazyVStack (lays out empty without a
//  live viewport). Slot membership is asserted in FamilySetsTests instead.
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
import os
@testable import Tailspot

@MainActor
@Suite("Douglas naming snapshots (visual pass)")
struct DouglasSetsSnapshotTests {

    @Test func renderMD11Card() {
        let dir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // manufacturer "Boeing" = what the backend resolved before the
        // rename; the typecode table must win on read.
        let name = AircraftNaming.canonical(
            typecode: "MD11", manufacturer: "Boeing", model: "MD-11"
        ).displayName
        #expect(name == "McDonnell Douglas MD-11")

        let card = VStack {
            SettledCatchCard(plane: CardPlane(
                callsign: "FDX1268", model: name, carrier: "FedEx",
                rarity: .epic, type: .wide,
                altText: "4,850 ft", speedText: "231 kt", distText: "6.4 km",
                originIcao: "OAK", destIcao: "MEM",
                originName: "Oakland", destName: "Memphis"), isFirstOfType: true, width: 357)
        }
        .padding(12)
        .background(Brand.Color.bgPrimary)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        guard let ui = renderer.uiImage, let png = ui.pngData() else {
            Log.ui.error("Douglas snapshot render failed")
            return
        }
        try? png.write(to: dir.appendingPathComponent("douglas_md11_card.png"))
    }
}
#endif
