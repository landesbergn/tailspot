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
import UserNotifications
@testable import Tailspot

extension StandardDefaultsSnapshotSuites {
    @MainActor
    @Suite("Profile + Settings snapshots (visual pass)", .serialized)
    struct ProfileSettingsSnapshotTests {

        private static let snapDir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)

        /// Host `view` in a real window at iPhone-16 points and snapshot it.
        /// `afterScreenUpdates: true` forces the List/NavigationStack to lay out.
        private func snapshot<V: View>(_ view: V, as name: String) async {
            try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
            let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
            let host = UIHostingController(rootView: view)
            let window = UIWindow(frame: bounds)
            window.rootViewController = host
            window.overrideUserInterfaceStyle = .dark
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            // One run-loop turn so async layout (List cells) settles.
            try? await Task.sleep(for: .seconds(0.3))
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

        @Test func renderProfileAndSettings() async throws {
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
            await snapshot(ProfileScreen().modelContainer(container), as: "profile_hub")
            await snapshot(NavigationStack { SettingsScreen() }, as: "settings")
            // UNITS section with the non-default choices selected.
            let prefs = UnitPreferences.shared
            let (savedAlt, savedSpd, savedDist) = (prefs.altitude, prefs.speed, prefs.distance)
            prefs.altitude = .meters
            prefs.speed = .kph
            prefs.distance = .miles
            await snapshot(NavigationStack { SettingsScreen() }, as: "settings_metric")
            prefs.altitude = savedAlt
            prefs.speed = savedSpd
            prefs.distance = savedDist
            await snapshot(NavigationStack { RarityReferenceScreen() }, as: "reference_rarity")
            await snapshot(NavigationStack { MapScreen() }.modelContainer(container), as: "map")
            #expect(true)
        }

        /// The unclaimed-handle designed state (2026-07-10 polish sweep D6):
        /// Profile header must show the CLAIM YOUR HANDLE affordance, never
        /// "@spotter_42" masquerading as a claimed identity.
        @Test func renderProfileUnclaimed() async throws {
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
            await snapshot(ProfileScreen().modelContainer(container), as: "profile_hub_unclaimed")
            // Settings with an unclaimed handle: the field must show its
            // "handle" prompt, not a prefilled "spotter_42" value.
            await snapshot(NavigationStack { SettingsScreen() }, as: "settings_unclaimed")
            #expect(true)
        }

        /// Streak surfaces (catch-streaks round): the Profile card in its
        /// at-risk and safe states, and Settings' REMINDERS section in the
        /// permission-denied state. Seeds are date-relative (streaks are
        /// about "today") — visual pass only, nothing pixel-compares.
        @Test func renderStreakStates() async throws {
            let defaults = UserDefaults.standard
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

            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: Catch.self, configurations: config)
            TestContainerRetention.retain(container)
            let cal = Calendar.current
            let noonToday = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
            func seed(daysAgo: Int) {
                container.mainContext.insert(Catch(
                    icao24: UUID().uuidString.prefix(6).lowercased(),
                    callsign: "ANA858", model: "787-9", manufacturer: "Boeing",
                    operatorName: nil,
                    caughtAt: cal.date(byAdding: .day, value: -daysAgo, to: noonToday)!,
                    observerLat: 37.87, observerLon: -122.27,
                    slantDistanceMeters: 9_800, typecode: "B789"
                ))
            }
            // Five consecutive days ending YESTERDAY → live 5-day streak, at risk.
            for back in 1...5 { seed(daysAgo: back) }
            await snapshot(ProfileScreen().modelContainer(container), as: "profile_streak_at_risk")
            // Today's catch lands → 6 days, safe. Current == longest, so the
            // state line's record half reads "your best yet".
            seed(daysAgo: 0)
            await snapshot(ProfileScreen().modelContainer(container), as: "profile_streak_safe")

            // Behind the record: a 2-day run today with an old 9-day run in the
            // history, so the suffix reads "best 9" instead. The other half of
            // `streakRecordSuffix`, and the longest line the card has to fit.
            let behind = try ModelContainer(for: Catch.self, configurations: config)
            TestContainerRetention.retain(behind)
            for back in [0, 1] + Array(20...28) {
                behind.mainContext.insert(Catch(
                    icao24: UUID().uuidString.prefix(6).lowercased(),
                    callsign: "ANA858", model: "787-9", manufacturer: "Boeing",
                    operatorName: nil,
                    caughtAt: cal.date(byAdding: .day, value: -back, to: noonToday)!,
                    observerLat: 37.87, observerLon: -122.27,
                    slantDistanceMeters: 9_800, typecode: "B789"
                ))
            }
            await snapshot(ProfileScreen().modelContainer(behind), as: "profile_streak_behind_best")

            // Settings: REMINDERS in the permission-denied state (dimmed toggle
            // + Open Settings escape hatch + explanatory footer).
            var denied = SettingsScreen()
            denied._notifStatusOverride = .denied
            await snapshot(NavigationStack { denied }, as: "settings_reminders_denied")
            #expect(true)
        }

        /// REMINDERS in each OS permission state, through the
        /// `_notifStatusOverride` seam. `.notDetermined` is the state a user is
        /// left in after tapping "Not now" on the in-camera pre-prompt: the
        /// section must offer a way to turn reminders on, not show ON toggles
        /// that never fire. Both toggles are forced ON (the default) so the
        /// render matches what those users actually see.
        @Test func renderReminderPermissionStates() async throws {
            let defaults = UserDefaults.standard
            let keys = [SpotterHandle.storageKey, StreakReminders.enabledKey,
                        ChallengeReminderScheduler.enabledKey]
            let saved = keys.map { defaults.object(forKey: $0) }
            defaults.set("noah", forKey: SpotterHandle.storageKey)
            defaults.set(true, forKey: StreakReminders.enabledKey)
            defaults.set(true, forKey: ChallengeReminderScheduler.enabledKey)
            defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }

            let states: [(UNAuthorizationStatus, String)] = [
                (.notDetermined, "not_determined"),
                (.denied, "denied"),
                (.authorized, "authorized"),
            ]
            for (status, name) in states {
                var screen = SettingsScreen()
                screen._notifStatusOverride = status
                await snapshot(NavigationStack { screen }, as: "settings_reminders_\(name)")
            }
            #expect(true)
        }

        /// Empty-Hangar "Go outside." hero + a model-detail empty state — the
        /// two empty-state heads converted to Brand.Font.display (D3).
        @Test func renderEmptyStates() async throws {
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            let empty = try ModelContainer(for: Catch.self, configurations: config)
            TestContainerRetention.retain(empty)
            await snapshot(HangarView().modelContainer(empty), as: "hangar_empty")
            if let entry = CardSets.all.first?.entries.first {
                await snapshot(
                          NavigationStack { ModelDetailScreen(entry: entry) }.modelContainer(empty),
                          as: "model_detail_empty"
                )
            }
            #expect(true)
        }

        @Test func renderLeaderboard() async throws {
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
            await snapshot(
                      NavigationStack {
                          LeaderboardScreen(_debugEntries: entries, me: MyStanding(rank: 2, points: 2755))
                      }
                      .modelContainer(container),
                      as: "leaderboard"
            )
            // Unranked variant (zero-point rank fix, 2026-08-24): the server sends
            // rank 0 for a device with zero in-window points; the YOU row must
            // render "—", never "0" (nor the old census-sized rank). A distinct
            // handle so the fixture's @noah at rank 2 doesn't read as the same
            // user.
            defaults.set("newspotter", forKey: SpotterHandle.storageKey)
            await snapshot(
                      NavigationStack {
                          LeaderboardScreen(_debugEntries: entries, me: MyStanding(rank: 0, points: 0))
                      }
                      .modelContainer(container),
                      as: "leaderboard_unranked"
            )
            // Handle-less variant exercises the "claim a handle" standing hint
            // (the section-header + stale-copy fixes both render here).
            defaults.set(SpotterHandle.defaultPlaceholder, forKey: SpotterHandle.storageKey)
            await snapshot(
                      NavigationStack {
                          LeaderboardScreen(_debugEntries: entries, me: nil)
                      }
                      .modelContainer(container),
                      as: "leaderboard_nohandle"
            )
            #expect(true)
        }
    }
}

/// Settings → REMINDERS row-state mapper. The bug it guards: a user who
/// tapped "Not now" on the pre-prompt stays `.notDetermined` in iOS, and
/// Settings used to show them ON toggles that could never deliver anything.
@Suite("Reminders row state")
struct RemindersRowStateTests {

    @Test func notDeterminedWithAToggleOnNeedsPermission() {
        #expect(RemindersRowState.resolve(authorization: .notDetermined, anyToggleOn: true) == .needsPermission)
    }

    /// Both toggles OFF: the user muted reminders. OFF toggles are honest,
    /// and flipping one on already fires the system prompt, so no button.
    @Test func notDeterminedWithTogglesOffKeepsToggles() {
        #expect(RemindersRowState.resolve(authorization: .notDetermined, anyToggleOn: false) == .toggles)
    }

    /// nil = the async permission read hasn't returned yet (first frame of
    /// every Settings open). Must show the toggles, not flash "Turn on
    /// reminders" at someone who granted permission long ago.
    @Test func unreadStatusShowsToggles() {
        #expect(RemindersRowState.resolve(authorization: nil, anyToggleOn: true) == .toggles)
        #expect(RemindersRowState.resolve(authorization: nil, anyToggleOn: false) == .toggles)
    }

    @Test func deniedIsDeniedWhateverTheToggles() {
        #expect(RemindersRowState.resolve(authorization: .denied, anyToggleOn: true) == .denied)
        #expect(RemindersRowState.resolve(authorization: .denied, anyToggleOn: false) == .denied)
    }

    @Test(arguments: [UNAuthorizationStatus.authorized, .provisional, .ephemeral])
    func grantedStatusesKeepToggles(status: UNAuthorizationStatus) {
        #expect(RemindersRowState.resolve(authorization: status, anyToggleOn: true) == .toggles)
        #expect(RemindersRowState.resolve(authorization: status, anyToggleOn: false) == .toggles)
    }

    /// The never-asked footer must not promise notifications ("Get
    /// notified…") that can't arrive.
    @Test func needsPermissionFooterIsHonest() {
        let footer = RemindersRowState.needsPermission.footer
        #expect(footer == "Reminders are off until you allow notifications.")
        #expect(!footer.contains("Get notified"))
        #expect(RemindersRowState.toggles.footer.hasPrefix("Get notified"))
        #expect(RemindersRowState.denied.footer.contains("iOS Settings"))
    }
}
#endif
