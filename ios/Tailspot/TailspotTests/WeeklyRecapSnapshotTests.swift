//
//  WeeklyRecapSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the weekly recap (TrophyRecapSnapshotTests
//  pattern). NOT an assertion test beyond "it rendered": writes PNGs to
//  /private/tmp/tailspot_snaps for review. The banner and recap screen are
//  window-hosted (drawHierarchy) like the device; the share image goes
//  through the same ImageRenderer path the Share button uses.
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
@testable import Tailspot

@MainActor
@Suite("Weekly recap snapshots (visual pass)", .serialized)
struct WeeklyRecapSnapshotTests {

    private static let snapDir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)

    private func snapshot<V: View>(_ view: V, as name: String, height: CGFloat = 852) async {
        try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
        let bounds = CGRect(x: 0, y: 0, width: 393, height: height)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        try? await Task.sleep(for: .seconds(0.3))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let png = UIGraphicsImageRenderer(bounds: bounds, format: format).pngData { _ in
            host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try? png.write(to: Self.snapDir.appendingPathComponent("\(name).png"))
        window.isHidden = true
    }

    private static func noonUTC(_ key: String) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        let p = key.split(separator: "-").compactMap { Int($0) }
        var c = DateComponents()
        c.year = p[0]; c.month = p[1]; c.day = p[2]; c.hour = 12
        return cal.date(from: c)!
    }

    /// A busy week: nine catches over five days, a rare bizjet with a real
    /// photo as the standout.
    private func sampleWeek() -> (WeeklyRecap, String?) {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let photoData = try? Data(contentsOf: repo.appendingPathComponent("marketing/catch-photos/bd700_rare.jpg"))
        let photo = photoData.flatMap { CatchPhotoStore.save($0, icao24: "a1b2c3", at: Date(timeIntervalSince1970: 1)) }

        func mk(_ day: String, _ cs: String, _ tc: String, alt: Double, photo: String? = nil,
                from: String? = nil, to: String? = nil) -> Catch {
            let c = Catch(icao24: String(cs.lowercased().prefix(6)), callsign: cs, model: nil, manufacturer: nil,
                          photoFilename: photo, caughtAt: Self.noonUTC(day), observerLat: 37.87,
                          observerLon: -122.27, slantDistanceMeters: 3000, typecode: tc,
                          altitudeMeters: alt, originIata: from, destIata: to)
            c.caughtDayKey = day
            return c
        }
        let rows = [
            mk("2026-11-02", "SWA1598", "B738", alt: 1200),
            mk("2026-11-02", "UAL2476", "B739", alt: 3400),
            mk("2026-11-03", "ASA331", "A21N", alt: 5200),
            mk("2026-11-04", "N700GX", "GLEX", alt: 12497, photo: photo, from: "OAK", to: "TEB"),
            mk("2026-11-04", "SKW5512", "E75L", alt: 2100),
            mk("2026-11-04", "DAL88", "B77W", alt: 9800),
            mk("2026-11-05", "UAL837", "B789", alt: 7600),
            mk("2026-11-07", "SWA22", "B738", alt: 900),
            mk("2026-11-07", "AAL1", "A21N", alt: 4000),
        ]
        return (WeeklyRecap.lastWeek(catches: rows, now: Self.noonUTC("2026-11-09"), timeZone: .gmt)!, photo)
    }

    @Test func renderWeeklyRecap() async throws {
        let (recap, photo) = sampleWeek()
        // The sample photo lives in the test host's catches folder; remove it.
        defer { CatchPhotoStore.delete(filename: photo) }

        await snapshot(
            VStack(spacing: 0) {
                WeeklyRecapBanner(recap: recap, onOpen: {}, onDismiss: {})
                Spacer()
            }
            .background(Brand.Color.bgPrimary),
            as: "weekly_recap_banner", height: 160
        )

        await snapshot(WeeklyRecapScreen(recap: recap, weeklyRank: 4), as: "weekly_recap_screen")

        let image = try #require(WeeklyRecapShareImage.render(recap, weeklyRank: 4))
        #expect(image.size.width * image.scale == 1080)
        #expect(image.size.height * image.scale == 1920)
        try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
        try image.pngData()?.write(to: Self.snapDir.appendingPathComponent("weekly_recap_share.png"))

        // A quiet week: one catch, no photo, nothing new.
        let quiet = WeeklyRecap.week(startingAt: "2026-11-02", catches: {
            let c = Catch(icao24: "abc123", callsign: "SWA1", model: nil, manufacturer: nil,
                          caughtAt: Self.noonUTC("2026-11-05"), observerLat: 0, observerLon: 0,
                          slantDistanceMeters: 1000, typecode: "B738")
            c.caughtDayKey = "2026-11-05"
            return [c]
        }(), timeZone: .gmt)!
        await snapshot(WeeklyRecapScreen(recap: quiet), as: "weekly_recap_screen_quiet")
        let quietImage = try #require(WeeklyRecapShareImage.render(quiet))
        try quietImage.pngData()?.write(to: Self.snapDir.appendingPathComponent("weekly_recap_share_quiet.png"))
    }
}
#endif
