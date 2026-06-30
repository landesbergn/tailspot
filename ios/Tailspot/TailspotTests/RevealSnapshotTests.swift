//
//  RevealSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the catch reveal. Renders `CatchRevealView`'s card
//  (at the settled final frame) to PNGs via ImageRenderer so the layout can be
//  eyeballed off-device — the iOS Simulator can't show GPS/camera, but it
//  renders SwiftUI fine. NOT an assertion test: it writes images to
//  /private/tmp/tailspot_snaps and passes. Review the PNGs after running.
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
@testable import Tailspot

@MainActor
@Suite("Reveal snapshots (visual pass)")
struct RevealSnapshotTests {

    @Test func renderRevealCards() {
        let dir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let cases: [(String, CardPlane)] = [
            ("a220_route_uncommon", CardPlane(
                callsign: "JBU613", model: "Airbus A220-300", carrier: "JetBlue",
                rarity: .uncommon, type: .narrow,
                altText: "35,433 ft", speedText: "451 kt", distText: "14.5 km",
                originIcao: "KBOS", destIcao: "KSFO",
                originName: "Boston Logan", destName: "San Francisco")),
            ("cessna_noroute_common", CardPlane(
                callsign: "N4521C", model: "Cessna 172", carrier: "Private",
                rarity: .common, type: .ga,
                altText: "3,609 ft", speedText: "101 kt", distText: "3.8 km")),
            ("c17_longname_epic", CardPlane(
                callsign: "RCH872", model: "Boeing C-17 Globemaster III", carrier: "U.S. Air Force",
                rarity: .epic, type: .mil,
                altText: "27,887 ft", speedText: "418 kt", distText: "9.2 km",
                originIcao: "KSUU", destIcao: "PHIK",
                originName: "Travis AFB", destName: "Honolulu")),
            ("b52_legendary_partialroute", CardPlane(
                callsign: "DOOM11", model: "Boeing B-52 Stratofortress", carrier: "U.S. Air Force",
                rarity: .legendary, type: .mil,
                altText: "40,026 ft", speedText: "488 kt", distText: "31.0 km",
                originIcao: "KBAD", destIcao: nil,
                originName: "Barksdale AFB", destName: nil)),
        ]

        for (name, plane) in cases {
            let card = CatchRevealView(plane: plane, entryNumber: 62, onDismiss: {}, onViewInHangar: {})
                ._snapshotCard(t: 1.0, width: 360)
                .frame(width: 360)
                .background(Color.black)
            let renderer = ImageRenderer(content: card)
            renderer.scale = 3
            // Pure side-effect harness — never fail CI over a render/write hiccup.
            guard let img = renderer.uiImage, let data = img.pngData() else { continue }
            try? data.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }
}
#endif
