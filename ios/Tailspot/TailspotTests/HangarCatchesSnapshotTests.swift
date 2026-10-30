//
//  HangarCatchesSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the Hangar's Catches segment (renamed from
//  "Recent" 2026-10-30) and its search field. NOT an assertion test:
//  writes PNGs to /private/tmp/tailspot_snaps — review them after
//  running. Hosted in a real UIWindow (ProfileSettingsSnapshotTests
//  pattern) because ImageRenderer draws ScrollView content blank.
//

#if DEBUG
import Testing
import SwiftUI
import SwiftData
import UIKit
@testable import Tailspot

@MainActor
@Suite("Hangar Catches snapshots (visual pass)", .serialized)
struct HangarCatchesSnapshotTests {

    private static let snapDir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)

    private func snapshot<V: View>(_ view: V, as name: String) async {
        try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        let host = UIHostingController(rootView: view.preferredColorScheme(.dark))
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(400))
        let png = UIGraphicsImageRenderer(bounds: bounds).pngData { _ in
            host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try? png.write(to: Self.snapDir.appendingPathComponent("\(name).png"))
        window.isHidden = true
    }

    private func container(count: Int) throws -> ModelContainer {
        let container = try ModelContainer(
            for: Catch.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        TestContainerRetention.retain(container)
        let seeds: [(String, String, String, String)] = [
            // (icao, callsign, typecode, place)
            ("a1b2c3", "SWA4244", "B738", "Oakland"),
            ("a2b3c4", "DAL972", "A321", "Berkeley"),
            ("86e123", "ANA858", "B789", "San Francisco"),
            ("4b1801", "SWR38", "A333", "Berkeley"),
            ("ae01c7", "RCH872", "C17", "Alameda"),
            ("a4e172", "N4521C", "C172", "Oakland"),
            ("3b7440", "GEC8160", "B744", "Richmond"),
        ]
        for (i, s) in seeds.prefix(count).enumerated() {
            let c = Catch(
                icao24: s.0, callsign: s.1, model: nil, manufacturer: nil,
                operatorName: nil,
                caughtAt: Date(timeIntervalSince1970: 1_783_150_000 - Double(i) * 3_600),
                observerLat: 37.87, observerLon: -122.27,
                slantDistanceMeters: 9_800,
                typecode: s.2
            )
            c.placeName = s.3
            container.mainContext.insert(c)
        }
        return container
    }

    private func screen(query: String = "") -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                HangarSegmentedSwitcher(selection: .constant(.recent))
                HangarRecentView(initialQuery: query)
            }
            .background(Brand.Color.bgPrimary)
        }
    }

    @Test func renderCatchesSearchStates() async throws {
        await snapshot(screen().modelContainer(try container(count: 5)), as: "catches_5_no_search")
        await snapshot(screen().modelContainer(try container(count: 7)), as: "catches_7_search")
        await snapshot(screen(query: "boeing").modelContainer(try container(count: 7)), as: "catches_7_query_boeing")
        await snapshot(screen(query: "zzz").modelContainer(try container(count: 7)), as: "catches_7_no_match")
        #expect(true)
    }
}
#endif
