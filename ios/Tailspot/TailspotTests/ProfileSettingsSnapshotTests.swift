//
//  ProfileSettingsSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the Profile hub + Settings + reference screens
//  (TailCardSnapshotTests pattern). NOT an assertion test: writes PNGs to
//  /private/tmp/tailspot_snaps and passes — review the images after running.
//
//  These screens are List/NavigationStack-based, which ImageRenderer can't
//  render (UIKit-backed containers come out blank), so this suite hosts each
//  screen in a real UIWindow and snapshots via drawHierarchy — possible
//  because TailspotTests runs hosted in Tailspot.app.
//

#if DEBUG
import Testing
import SwiftUI
import SwiftData
import UIKit
import os
@testable import Tailspot

@MainActor
@Suite("Profile + Settings snapshots (visual pass)", .serialized)
struct ProfileSettingsSnapshotTests {

    private static let snapDir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)

    /// Host `view` in a real window at iPhone-16 points and snapshot it.
    /// `afterScreenUpdates: true` forces the List/NavigationStack to lay out.
    private func snapshot<V: View>(_ view: V, as name: String) {
        try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        // One run-loop turn so async layout (List cells) settles.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let png = renderer.pngData { _ in
            host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try? png.write(to: Self.snapDir.appendingPathComponent("\(name).png"))
        window.isHidden = true
    }

    private func seededContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Catch.self, configurations: config)
        TestContainerRetention.retain(container)
        let seeds: [(String, String?, String?, String?, String?)] = [
            // (icao, callsign, model, manufacturer, typecode)
            ("86e123", "ANA858", "787-9", "Boeing", "B789"),
            ("3b7440", "GEC8160", "747-400", "Boeing", "B744"),
            ("a4e172", "N4521C", "172", "Cessna", "C172"),
            ("ae01c7", "RCH872", "C-17 Globemaster III", "Boeing", "C17"),
            ("ae0b52", "GHOST11", "B-52 Stratofortress", "Boeing", "B52"),
            ("4b1801", "SWR38", "A330-300", "Airbus", "A333"),
        ]
        for (icao, callsign, model, manufacturer, typecode) in seeds {
            container.mainContext.insert(Catch(
                icao24: icao, callsign: callsign, model: model,
                manufacturer: manufacturer, operatorName: nil,
                caughtAt: Date(timeIntervalSince1970: 1_783_150_000),
                observerLat: 37.87, observerLon: -122.27,
                slantDistanceMeters: 9_800,
                typecode: typecode
            ))
        }
        return container
    }

    @Test func renderProfileAndSettings() throws {
        let defaults = UserDefaults.standard
        // Deterministic identity + standing for the render; restore after.
        let savedHandle = defaults.object(forKey: SpotterHandle.storageKey)
        let savedPoints = defaults.object(forKey: "tailspot.standing.points")
        let savedRank = defaults.object(forKey: "tailspot.standing.rank")
        defaults.set("noah", forKey: SpotterHandle.storageKey)
        defaults.set(1370, forKey: "tailspot.standing.points")
        defaults.set(1, forKey: "tailspot.standing.rank")
        defer {
            defaults.set(savedHandle, forKey: SpotterHandle.storageKey)
            defaults.set(savedPoints, forKey: "tailspot.standing.points")
            defaults.set(savedRank, forKey: "tailspot.standing.rank")
        }

        let container = try seededContainer()
        snapshot(ProfileScreen().modelContainer(container), as: "profile_hub")
        snapshot(NavigationStack { SettingsScreen() }, as: "settings")
        snapshot(NavigationStack { RarityReferenceScreen() }, as: "reference_rarity")
        snapshot(NavigationStack { MapScreen() }.modelContainer(container), as: "map")
        #expect(true)
    }

    /// The unclaimed-handle designed state (2026-07-10 polish sweep D6):
    /// Profile header must show the CLAIM YOUR HANDLE affordance, never
    /// "@spotter_42" masquerading as a claimed identity.
    @Test func renderProfileUnclaimed() throws {
        let defaults = UserDefaults.standard
        let savedHandle = defaults.object(forKey: SpotterHandle.storageKey)
        let savedPoints = defaults.object(forKey: "tailspot.standing.points")
        let savedRank = defaults.object(forKey: "tailspot.standing.rank")
        defaults.set(SpotterHandle.defaultPlaceholder, forKey: SpotterHandle.storageKey)
        defaults.set(120, forKey: "tailspot.standing.points")
        defaults.set(0, forKey: "tailspot.standing.rank")
        defer {
            defaults.set(savedHandle, forKey: SpotterHandle.storageKey)
            defaults.set(savedPoints, forKey: "tailspot.standing.points")
            defaults.set(savedRank, forKey: "tailspot.standing.rank")
        }
        let container = try seededContainer()
        snapshot(ProfileScreen().modelContainer(container), as: "profile_hub_unclaimed")
        // Settings with an unclaimed handle: the field must show its
        // "handle" prompt, not a prefilled "spotter_42" value.
        snapshot(NavigationStack { SettingsScreen() }, as: "settings_unclaimed")
        #expect(true)
    }

    /// Empty-Hangar "Go outside." hero + a model-detail empty state — the
    /// two empty-state heads converted to Brand.Font.display (D3).
    @Test func renderEmptyStates() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let empty = try ModelContainer(for: Catch.self, configurations: config)
        TestContainerRetention.retain(empty)
        snapshot(HangarView().modelContainer(empty), as: "hangar_empty")
        if let entry = CardSets.all.first?.entries.first {
            snapshot(
                NavigationStack { ModelDetailScreen(entry: entry) }.modelContainer(empty),
                as: "model_detail_empty"
            )
        }
        #expect(true)
    }

    @Test func renderLeaderboard() throws {
        let defaults = UserDefaults.standard
        let savedHandle = defaults.object(forKey: SpotterHandle.storageKey)
        defaults.set("noah", forKey: SpotterHandle.storageKey)
        defer { defaults.set(savedHandle, forKey: SpotterHandle.storageKey) }

        let entries: [LeaderboardEntry] = [
            .init(rank: 1, handle: "skykid", points: 4210, catches: 61),
            .init(rank: 2, handle: "noah", points: 2755, catches: 43),
            .init(rank: 3, handle: "contrail", points: 1980, catches: 35),
            .init(rank: 4, handle: "heavywatcher", points: 1420, catches: 28),
            .init(rank: 5, handle: "dotbali", points: 660, catches: 12),
        ]
        let container = try seededContainer()
        snapshot(
            NavigationStack {
                LeaderboardScreen(_debugEntries: entries, me: MyStanding(rank: 2, points: 2755))
            }
            .modelContainer(container),
            as: "leaderboard"
        )
        // Handle-less variant exercises the "claim a handle" standing hint
        // (the section-header + stale-copy fixes both render here).
        defaults.set(SpotterHandle.defaultPlaceholder, forKey: SpotterHandle.storageKey)
        snapshot(
            NavigationStack {
                LeaderboardScreen(_debugEntries: entries, me: nil)
            }
            .modelContainer(container),
            as: "leaderboard_nohandle"
        )
        #expect(true)
    }
}
#endif
