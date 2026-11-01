//
//  SteeringPillSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the first-catch steering pill (the
//  CompassWarningSnapshotTests pattern): renders the SHIPPING
//  `HUDStatusPill` at the AR HUD's low-pill position over a day-sky and a
//  dusk backdrop, at default type and accessibility2. Writes PNGs to
//  /private/tmp/tailspot_snaps/steering and passes; look at them after a
//  run. The pulse is off so renders are deterministic. The width check is
//  a real assertion: the longest copy must fit a 375 pt phone.
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
@testable import Tailspot

@MainActor
@Suite("Steering pill (visual pass)")
struct SteeringPillSnapshotTests {

    private static let dir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps/steering", isDirectory: true)

    private func steering(_ direction: SteeringDirection, meters: Double, unit: DistanceUnit = .kilometers) -> HUDStatusPill {
        let hint = SteeringHint(icao24: "abc123", direction: direction, elevationDeltaDeg: 10, distanceMeters: meters)
        return HUDStatusPill(text: SteeringPill.text(hint, unit: unit), tint: Brand.Color.cyan, pulsing: false,
                             glyph: SteeringPill.glyph(hint))
    }

    /// A phone-sized camera stand-in with the pill where `statusPillOverlay`
    /// puts it (centred, 18% of the height off the bottom).
    private func scene(_ pill: HUDStatusPill?, sky: [Color], type: DynamicTypeSize) -> some View {
        let size = CGSize(width: 393, height: 852)
        return ZStack {
            LinearGradient(colors: sky, startPoint: .top, endPoint: .bottom)
            VStack {
                Spacer()
                if let pill { pill.padding(.horizontal, 16).padding(.bottom, size.height * 0.18) }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
        .dynamicTypeSize(type)
    }

    private func write(_ view: some View, _ name: String) {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        guard let png = renderer.uiImage?.pngData() else {
            Issue.record("render failed for \(name)")
            return
        }
        try? png.write(to: Self.dir.appendingPathComponent("\(name).png"))
    }

    @Test func renderSteeringPill() {
        let day = [Color(hex: 0x9FC4E8), Color(hex: 0xD8E8F4)]
        let dusk = [Color(hex: 0x1A2A44), Color(hex: 0x4A5A78)]
        for (typeName, type) in [("default", DynamicTypeSize.large), ("ax2", .accessibility2)] {
            // Before: a plane in range behind the user, nothing on screen.
            write(scene(nil, sky: day, type: type), "before_offframe_\(typeName)")
            write(scene(steering(.left, meters: 4_200), sky: day, type: type), "after_left_day_\(typeName)")
            write(scene(steering(.behind, meters: 12_600, unit: .miles), sky: dusk, type: type), "after_behind_dusk_\(typeName)")
            write(scene(steering(.right, meters: 800), sky: dusk, type: type), "after_right_dusk_\(typeName)")
            // The empty-sky pill now renders through the same view (plus the
            // centred wrap and 16 pt gutter): compare with its before.
            let empty = HUDStatusPill(text: "NO AIRCRAFT IN VIEW · 3 NEARBY", tint: Brand.Color.textSecondary, pulsing: false)
            write(scene(empty, sky: dusk, type: type), "after_emptysky_\(typeName)")
        }
    }

    @Test func longestCopyFitsASmallPhone() {
        // "TURN RIGHT" plus a two-digit distance is the longest pill.
        let pill = steering(.right, meters: 34_000)
        // Default type: one line on a 375 pt phone. (At accessibility sizes
        // the mono face scales and the pill wraps to two centred lines; the
        // ax2 renders above are the check for that.)
        let renderer = ImageRenderer(content: pill.environment(\.colorScheme, .dark).dynamicTypeSize(.large))
        renderer.scale = 1
        let width = renderer.uiImage?.size.width ?? .infinity
        #expect(width <= 375 - 32, "steering pill is \(width) pt wide")
    }
}
#endif
