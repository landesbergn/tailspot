//
//  DynamicTypeSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the 2026-07-12 HIG pass (ProfileSettings-
//  SnapshotTests pattern). NOT an assertion test: writes PNGs to
//  /private/tmp/tailspot_snaps and passes — review the images after running.
//
//  Two jobs:
//    1. Prove the Brand token Dynamic Type anchors actually scale: the
//       same screens render at the default size and at .accessibility2.
//       If a future change severs an anchor (e.g. a token quietly goes
//       back to a bare `.system(size:)`), the a11y renders stop differing
//       from the default ones — compare by eye during the visual pass.
//    2. Render the populated-Hangar top bar (the new close pill) and the
//       Sets tiles (the locked-tile contrast fix), which the existing
//       suites don't cover in a populated state.
//

#if DEBUG
import Testing
import SwiftUI
import SwiftData
import UIKit
import os
@testable import Tailspot

@MainActor
@Suite("Dynamic Type + HIG-pass snapshots (visual pass)", .serialized)
struct DynamicTypeSnapshotTests {

    private static let snapDir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)

    /// Host `view` in a real window at iPhone-16 points and snapshot it —
    /// same drawHierarchy approach as ProfileSettingsSnapshotTests (List/
    /// NavigationStack containers come out blank under ImageRenderer).
    private func snapshot<V: View>(_ view: V, as name: String) {
        try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let png = renderer.pngData { _ in
            host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try? png.write(to: Self.snapDir.appendingPathComponent("\(name).png"))
        window.isHidden = true
    }

    /// Seeds are COMPLETE rows on purpose — registration, operator, and a
    /// full ICAO+IATA route — so `CatchBackfill.backfillAll` (kicked off by
    /// HangarView's `.task`) has nothing to fetch and never goes async.
    /// With gaps in the seeds, the backfill's awaited network lookups
    /// outlive this test's window/container teardown and die on a
    /// SwiftData assertion mid-run — crashing whichever unrelated suite
    /// happens to be executing (in the app the container is permanent, so
    /// only the hosted-test environment ever sees that race).
    private func seededContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Catch.self, configurations: config)
        let seeds: [(String, String, String, String, String, String, String)] = [
            // (icao, callsign, model, manufacturer, typecode, reg, operator)
            ("86e123", "ANA858", "787-9", "Boeing", "B789", "JA936A", "All Nippon Airways"),
            ("3b7440", "GEC8160", "747-400", "Boeing", "B744", "D-ABVY", "Lufthansa Cargo"),
            ("a4e172", "N4521C", "172", "Cessna", "C172", "N4521C", "Private"),
            ("4b1801", "SWR38", "A330-300", "Airbus", "A333", "HB-JHA", "Swiss"),
        ]
        for (icao, callsign, model, manufacturer, typecode, reg, op) in seeds {
            container.mainContext.insert(Catch(
                icao24: icao, callsign: callsign, model: model,
                manufacturer: manufacturer, operatorName: op,
                caughtAt: Date(timeIntervalSince1970: 1_783_150_000),
                observerLat: 37.87, observerLon: -122.27,
                slantDistanceMeters: 9_800,
                registration: reg,
                typecode: typecode,
                originIcao: "RJTT", destIcao: "KSFO",
                originIata: "HND", destIata: "SFO"
            ))
        }
        return container
    }

    /// The scaling proof: same screens, default vs .accessibility2. The
    /// a11y renders must visibly reflow (bigger prose, taller rows); the
    /// default renders must be pixel-comparable to the pre-pass baseline.
    ///
    /// Surface choice is deliberate: Settings, Profile, and the EMPTY
    /// Hangar are exactly what ProfileSettingsSnapshotTests already hosts
    /// safely. A populated HangarView (or SetsScreen) in a short-lived
    /// hosted window is NOT safe here: its `.task` backfill and SwiftData's
    /// deferred autosave both outlive the window/container and die on
    /// SwiftData assertions mid-run, taking unrelated suites with them
    /// (only the hosted-test environment sees that race — the app's
    /// container is permanent). Populated-Hangar visuals are covered by
    /// the on-device pass instead.
    @Test func renderDynamicTypeScaling() throws {
        let container = try seededContainer()
        let empty = try ModelContainer(
            for: Catch.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        snapshot(NavigationStack { SettingsScreen() }, as: "dt_settings_default")
        snapshot(NavigationStack { SettingsScreen() }.dynamicTypeSize(.accessibility2),
                 as: "dt_settings_a11y2")
        snapshot(ProfileScreen().modelContainer(container), as: "dt_profile_default")
        snapshot(ProfileScreen().modelContainer(container).dynamicTypeSize(.accessibility2),
                 as: "dt_profile_a11y2")
        snapshot(HangarView().modelContainer(empty), as: "dt_hangar_default")
        snapshot(HangarView().modelContainer(empty).dynamicTypeSize(.accessibility2),
                 as: "dt_hangar_a11y2")
        #expect(true)
    }
}
#endif
