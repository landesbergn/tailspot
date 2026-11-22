//
//  CardFillLayoutTests.swift
//  TailspotTests
//
//  The catch card fills the screen (Noah, 2026-11-22): on the reveal and on
//  the Hangar detail screen a card with little on it used to end well above
//  the bottom, leaving a band of empty screen. The spare height now goes to
//  the photo, up to square; everything under the photo keeps its size, and
//  a card that already fills or overflows the screen is unchanged.
//
//  Two halves:
//   - `render…` writes PNGs for a person to look at (the NotableSnapshotTests
//     pattern), both screens × four phones × three cards, to
//     /private/tmp/tailspot_snaps/fill_<screen>_<size>_<case>.png. Each PNG
//     is the WHOLE screen: the layout runs in the phone's safe area and the
//     status-bar / home-indicator bands are padded back on, so the image's
//     bottom edge is the screen's bottom edge.
//   - `…FillsOrCaps` are the real assertions. They host the LIVE screens in a
//     window the size of the phone's safe area and read the frames the card
//     reports (`CardFrameKey`): real layout, no hand-computed heights.
//
//  Both screens scroll, and ImageRenderer cannot draw scroll-view content,
//  so the PNGs are captures of the live screens hosted in a window.
//

#if DEBUG
import Testing
import SwiftUI
import SwiftData
import UIKit
@testable import Tailspot

@MainActor
@Suite("Catch card fills the screen", .serialized)
struct CardFillLayoutTests {

    private static let dir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)

    // MARK: Phones

    struct Phone {
        let tag: String
        let size: CGSize
        let top: CGFloat
        let bottom: CGFloat
        var safe: CGSize { CGSize(width: size.width, height: size.height - top - bottom) }
    }

    static let se = Phone(tag: "375x667", size: CGSize(width: 375, height: 667), top: 20, bottom: 0)
    static let iPhone16 = Phone(tag: "393x852", size: CGSize(width: 393, height: 852), top: 59, bottom: 34)
    static let iPhone17 = Phone(tag: "402x874", size: CGSize(width: 402, height: 874), top: 62, bottom: 34)
    static let proMax = Phone(tag: "440x956", size: CGSize(width: 440, height: 956), top: 62, bottom: 34)
    static let phones = [se, iPhone16, iPhone17, proMax]

    // MARK: Cards

    /// `plain` is the card Noah reported (SHORT without the notable caption
    /// and its ledger row): asserted on, and rendered on the iPhone 16 only.
    enum Card: String, CaseIterable {
        case plain, short, typical, tall
        static let rendered: [Card] = [.short, .typical, .tall]
    }

    static let team = NotablePlane(kind: "team", label: "Team plane", name: "Golden State Warriors")!

    /// PLAIN: no route, common, one-line name, a two-row ledger.
    /// SHORT: the same with the notable caption on (and its ledger row).
    /// TYPICAL: a route and a one-line name.
    /// TALL: a three-line name, a route, first-of-type and notable rows.
    private static func plane(_ card: Card, photo: URL?) -> CardPlane {
        let focus = photo == nil ? nil : CGPoint(x: 0.5, y: 0.45)
        switch card {
        case .plain, .short:
            return CardPlane(
                callsign: "SWA4244", model: "Boeing 737-800", carrier: "Southwest Airlines",
                rarity: .common, type: .narrow,
                altText: "12,400 ft", speedText: "310 kt", distText: "6.2 km",
                photoURL: photo, photoFocus: focus,
                notable: card == .short ? team : nil, icao24: "fa0001")
        case .typical:
            return CardPlane(
                callsign: "SWA1187", model: "Boeing 737-800", carrier: "Southwest Airlines",
                rarity: .common, type: .narrow,
                altText: "34,000 ft", speedText: "462 kt", distText: "11.4 km",
                photoURL: photo, photoFocus: focus,
                originIcao: "OAK", destIcao: "DEN", originName: "Oakland", destName: "Denver",
                icao24: "fa0002")
        case .tall:
            return CardPlane(
                callsign: "N217MH", model: "Bell 206 JetRanger / LongRanger", carrier: "Private",
                rarity: .uncommon, type: .ga,
                altText: "1,975 ft", speedText: "65 kt", distText: "0.6 km",
                photoURL: photo, photoFocus: focus,
                originIcao: "OAK", destIcao: "SQL", originName: "Oakland", destName: "San Carlos",
                isFirstOfType: true, notable: team, icao24: "fa0003")
        }
    }

    /// The same three cards as saved catches, for the detail screen. An older
    /// 737-800 catch keeps SHORT and TYPICAL from being first of their type.
    private static func hangar(photoFilename: String?) throws -> (ModelContainer, [Card: Catch]) {
        let container = try ModelContainer(
            for: Catch.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        TestContainerRetention.retain(container)
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        func make(_ icao: String, _ callsign: String, _ op: String, _ typecode: String,
                  alt: Double, speed: Double, dist: Double,
                  route: (String, String, String, String)? = nil,
                  notable: NotablePlane? = nil, at: Date) -> Catch {
            let c = Catch(icao24: icao, callsign: callsign, model: nil, manufacturer: nil,
                          operatorName: op, photoFilename: photoFilename, caughtAt: at,
                          observerLat: 37.87, observerLon: -122.27, slantDistanceMeters: dist,
                          typecode: typecode, altitudeMeters: alt, velocityMps: speed,
                          originIcao: route?.0, destIcao: route?.1,
                          originName: route?.2, destName: route?.3,
                          placeName: "Berkeley", country: "US",
                          photoFocusX: 0.5, photoFocusY: 0.45)
            c.setNotable(notable)
            container.mainContext.insert(c)
            return c
        }
        _ = make("fa0000", "SWA12", "Southwest Airlines", "B738", alt: 9_000, speed: 220,
                 dist: 9_000, at: at.addingTimeInterval(-86_400))
        let short = make("fa0001", "SWA4244", "Southwest Airlines", "B738", alt: 3_780, speed: 160,
                         dist: 6_200, notable: team, at: at)
        let plain = make("fa0004", "SWA4244", "Southwest Airlines", "B738", alt: 3_780, speed: 160,
                         dist: 6_200, at: at)
        let typical = make("fa0002", "SWA1187", "Southwest Airlines", "B738", alt: 10_360, speed: 238,
                           dist: 11_400, route: ("OAK", "DEN", "Oakland", "Denver"), at: at)
        let tall = make("fa0003", "N217MH", "Private", "B06", alt: 600, speed: 33, dist: 600,
                        route: ("OAK", "SQL", "Oakland", "San Carlos"), notable: team, at: at)
        return (container, [.plain: plain, .short: short, .typical: typical, .tall: tall])
    }

    /// A sky with a small dark plane where the focus point is, so the crop
    /// at each photo height is easy to judge.
    private static func photoData() -> Data? {
        let size = CGSize(width: 1200, height: 1600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let colors = [UIColor(red: 0.09, green: 0.23, blue: 0.42, alpha: 1).cgColor,
                          UIColor(red: 0.55, green: 0.75, blue: 0.92, alpha: 1).cgColor]
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: colors as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            UIColor(white: 0.12, alpha: 1).setFill()
            cg.fillEllipse(in: CGRect(x: 510, y: 700, width: 180, height: 40))
            cg.fill(CGRect(x: 585, y: 640, width: 30, height: 160))
        }
        return img.jpegData(compressionQuality: 0.9)
    }

    private static func photoFile() -> URL? {
        guard let data = photoData() else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fill_synthetic_catch.jpg")
        try? data.write(to: url)
        return url
    }

    // MARK: Hosting

    /// Frames the card reports, in window coordinates.
    private final class Frames {
        var parts: [CardFramePart: CGRect] = [:]
        var photo: CGRect? { parts[.photo] }
        var card: CGRect? { parts[.card] }
        var turnRow: CGRect? { parts[.turnRow] }
        var complete: Bool { photo != nil && card != nil && turnRow != nil }
    }

    private struct Hosted {
        let window: UIWindow
        let view: UIView
        let frames: Frames
    }

    /// Hosts `view` in a window of `size` and waits for the card to report
    /// its frames. The caller's root ignores the simulator's own safe area,
    /// so the window's size is the layout's size. Waits are `Task.sleep`,
    /// never a run-loop spin (which blocks the screens' own `.task`s).
    private func host(_ view: some View, size: CGSize, settle: Duration) async -> Hosted {
        // No peek (`CardFlipTease`): mid-tilt, the card's frames and the
        // capture are of a turned card. The peek decides once, as it appears.
        let hadTurned = CardFlipTeaseStore.hasTurnedACard
        CardFlipTeaseStore.hasTurnedACard = true
        defer { CardFlipTeaseStore.hasTurnedACard = hadTurned }
        let frames = Frames()
        let root = view
            .onPreferenceChange(CardFrameKey.self) { frames.parts = $0 }
            .environment(\.replayMaskingDisabled, true)
            .ignoresSafeArea()
        let controller = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        try? await Task.sleep(for: settle)
        let started = Date()
        repeat {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(150))
        } while !frames.complete && Date().timeIntervalSince(started) < 20
        return Hosted(window: window, view: controller.view, frames: frames)
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let s = view as? UIScrollView { return s }
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }

    private func liveReveal(_ card: Card, on phone: Phone) async -> (Hosted, CGRect?) {
        var reveal = CatchRevealView(plane: Self.plane(card, photo: nil), entryNumber: 62,
                                     onDismiss: {}, onViewInHangar: {})
        reveal._reduceMotionOverride = true
        let hosted = await host(reveal, size: phone.safe, settle: .milliseconds(600))
        let viewport = firstScrollView(in: hosted.view).map { $0.convert($0.bounds, to: hosted.window) }
        return (hosted, viewport)
    }

    /// The detail screen laid out in the phone's safe area. With `fullScreen`
    /// the status-bar and home-indicator bands are padded back on around it,
    /// so a capture of the window is the whole screen.
    private func liveDetail(_ card: Card, on phone: Phone, fullScreen: Bool,
                            photoFilename: String? = nil) async throws -> Hosted {
        let (container, catches) = try Self.hangar(photoFilename: photoFilename)
        let c = try #require(catches[card])
        let row = HangarRow(icao24: c.icao24, mostRecent: c, count: 1, allCatches: [c])
        let screen = CatchDetailView(row: row)
            .frame(width: phone.safe.width, height: phone.safe.height)
            .padding(.top, fullScreen ? phone.top : 0)
            .padding(.bottom, fullScreen ? phone.bottom : 0)
            .background(Brand.Color.bgPrimary)
            .modelContainer(container)
        return await host(screen, size: fullScreen ? phone.size : phone.safe, settle: .milliseconds(900))
    }

    // MARK: Renders (for a person to look at)

    private func capture(_ hosted: Hosted, size: CGSize, as name: String) {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        let bounds = CGRect(origin: .zero, size: size)
        let png = UIGraphicsImageRenderer(bounds: bounds).pngData { _ in
            hosted.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try? png.write(to: Self.dir.appendingPathComponent("\(name).png"))
        hosted.window.isHidden = true
    }

    /// The LIVE reveal, settled (Reduce Motion ends on the same frame, sooner),
    /// scroll view and all: `_snapshotScreen`'s ImageRenderer mirror cuts the
    /// top off a card that overflows, which the device never does.
    @Test func renderReveals() async {
        let photo = Self.photoFile()
        for phone in Self.phones {
            for card in Card.rendered + (phone.tag == Self.iPhone16.tag ? [.plain] : []) {
                var reveal = CatchRevealView(plane: Self.plane(card, photo: photo), entryNumber: 62,
                                             onDismiss: {}, onViewInHangar: {})
                reveal._reduceMotionOverride = true
                let screen = reveal
                    .frame(width: phone.safe.width, height: phone.safe.height)
                    .padding(.top, phone.top)
                    .padding(.bottom, phone.bottom)
                    .background(RP.bg)
                let hosted = await host(screen, size: phone.size, settle: .milliseconds(3_500))
                capture(hosted, size: phone.size, as: "fill_reveal_\(phone.tag)_\(card.rawValue)")
            }
        }
    }

    @Test func renderDetails() async throws {
        // The detail screen reads its photo from the catch-photo folder.
        let filename = Self.photoData().flatMap {
            CatchPhotoStore.save($0, icao24: "fa00ff", at: Date(timeIntervalSince1970: 1_790_000_000))
        }
        defer {
            if let filename, let url = CatchPhotoStore.url(forFilename: filename) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        for phone in Self.phones {
            for card in Card.rendered + (phone.tag == Self.iPhone16.tag ? [.plain] : []) {
                let hosted = try await liveDetail(card, on: phone, fullScreen: true,
                                                  photoFilename: filename)
                capture(hosted, size: phone.size, as: "fill_detail_\(phone.tag)_\(card.rawValue)")
            }
        }
    }

    /// The back is laid out at the front's size, so it gets taller too:
    /// the PLAIN card at the height the iPhone 16 detail screen offers it.
    @Test func renderDetailBack() async {
        let phone = Self.iPhone16
        let width = min(phone.safe.width - 36, 420)
        let offered = phone.safe.height - CatchDetailView.columnTopInset - CatchDetailView.columnBottomInset
        let front = SettledCatchCard(plane: Self.plane(.plain, photo: Self.photoFile()),
                                     isFirstOfType: false, width: width,
                                     caughtAt: Date(timeIntervalSince1970: 1_790_000_000),
                                     fillsHeight: true)
        for (tag, angle) in [("front", 0.0), ("back", 180.0)] {
            let view = ProposedHeightLayout(height: offered) {
                FlipCard(isFlipped: .constant(angle == 180), teases: false) {
                    front
                } back: {
                    CatchCardBack(model: BackFixtures.b738, width: width, onOpenURL: { _ in })
                }
                ._snapshotAngle(angle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Brand.Color.bgPrimary.ignoresSafeArea())
            let size = CGSize(width: phone.size.width, height: offered + 36)
            let hosted = await host(view, size: size, settle: .milliseconds(500))
            capture(hosted, size: size, as: "fill_detail_393x852_plain_flip_\(tag)")
        }
    }

    // MARK: Assertions

    private static func revealBasePhotoHeight(_ phone: Phone) -> CGFloat {
        152 * min(phone.safe.width - 28, 420) / 300
    }

    private static func detailBasePhotoHeight(_ phone: Phone) -> CGFloat {
        168 * min(phone.safe.width - 36, 420) / 300
    }

    /// On a 6.1" and a 6.9" phone the SHORT card's photo grows, and the card
    /// plus its turn-over row then fill the viewport to the margin, unless
    /// the photo reached square first.
    @Test func revealShortCardFillsOrCaps() async throws {
        for phone in [Self.iPhone16, Self.proMax] {
        let (hosted, viewportFrame) = await liveReveal(.short, on: phone)
        defer { hosted.window.isHidden = true }
        let photo = try #require(hosted.frames.photo)
        let card = try #require(hosted.frames.card)
        let turnRow = try #require(hosted.frames.turnRow)
        let viewport = try #require(viewportFrame)

        #expect(photo.height > Self.revealBasePhotoHeight(phone) + 1,
                "photo \(photo.height) should be taller than its base \(Self.revealBasePhotoHeight(phone))")
        #expect(photo.height <= photo.width + 0.5)
        let atCap = abs(photo.height - photo.width) < 0.5
        let top = card.minY - viewport.minY
        let bottom = viewport.maxY - turnRow.maxY
        let fills = abs(top - CatchRevealView.fillMargin) < 1 && abs(bottom - CatchRevealView.fillMargin) < 1
        #expect(fills || atCap, "top gap \(top), bottom gap \(bottom), photo \(photo.size)")
        // Capped or not, the card stays centered in the viewport.
        #expect(abs(top - bottom) < 1, "top gap \(top) vs bottom gap \(bottom)")
        }
    }

    /// A card that already overflows the SE keeps the photo it always had.
    @Test func revealTallCardOnSEKeepsBasePhoto() async throws {
        let (hosted, _) = await liveReveal(.tall, on: Self.se)
        defer { hosted.window.isHidden = true }
        let photo = try #require(hosted.frames.photo)
        #expect(abs(photo.height - Self.revealBasePhotoHeight(Self.se)) < 0.5,
                "photo \(photo.height) should stay at \(Self.revealBasePhotoHeight(Self.se))")
        #expect(photo.height <= photo.width + 0.5)
    }

    /// The detail screen's text is at full size (the reveal's is squeezed)
    /// and it carries the caught-at line, so its card is taller. With the
    /// 8 pt bottom inset (Noah, 2026-11-22: the card should run the full
    /// length of the phone) PLAIN and SHORT both grow their photo on the
    /// 6.1" and 6.9" phones, each ending at the bottom inset or with a
    /// square photo.
    @Test func detailShortCardFillsOrCaps() async throws {
        let cases: [(Phone, Card, Bool)] = [
            (Self.iPhone16, .plain, true), (Self.proMax, .plain, true),
            (Self.iPhone16, .short, true), (Self.proMax, .short, true),
        ]
        for (phone, which, mustGrow) in cases {
        let hosted = try await liveDetail(which, on: phone, fullScreen: false)
        defer { hosted.window.isHidden = true }
        let photo = try #require(hosted.frames.photo)
        let card = try #require(hosted.frames.card)
        let turnRow = try #require(hosted.frames.turnRow)
        let base = Self.detailBasePhotoHeight(phone)

        #expect(photo.height > base + (mustGrow ? 1 : -0.5),
                "\(phone.tag) \(which): photo \(photo.height), base \(base)")
        #expect(photo.height <= photo.width + 0.5)
        let atCap = abs(photo.height - photo.width) < 0.5
        // The card stays top-aligned under the chrome bar either way.
        #expect(abs(card.minY - CatchDetailView.columnTopInset) < 1, "card top \(card.minY)")
        let bottom = phone.safe.height - turnRow.maxY
        if mustGrow {
            #expect(abs(bottom - CatchDetailView.columnBottomInset) < 1 || atCap,
                    "\(phone.tag) \(which): bottom gap \(bottom), photo \(photo.size)")
        } else {
            #expect(abs(photo.height - base) < 0.5, "\(phone.tag) \(which): photo \(photo.height)")
            #expect(bottom < CatchDetailView.columnBottomInset + 1, "bottom gap \(bottom)")
        }
        }
    }

    @Test func detailTallCardOnSEKeepsBasePhoto() async throws {
        let hosted = try await liveDetail(.tall, on: Self.se, fullScreen: false)
        defer { hosted.window.isHidden = true }
        let photo = try #require(hosted.frames.photo)
        #expect(abs(photo.height - Self.detailBasePhotoHeight(Self.se)) < 0.5,
                "photo \(photo.height) should stay at \(Self.detailBasePhotoHeight(Self.se))")
        #expect(photo.height <= photo.width + 0.5)
    }

    /// Every phone and card, both screens: the photo is never shorter than
    /// its base height and never taller than it is wide.
    @Test func photoStaysBetweenBaseAndSquare() async throws {
        var lines = ["screen size card: photo height (base, width)"]
        defer {
            try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
            try? lines.joined(separator: "\n").write(
                to: Self.dir.appendingPathComponent("fill_measurements.txt"), atomically: true, encoding: .utf8)
        }
        func line(_ screen: String, _ phone: Phone, _ card: Card, _ photo: CGRect, base: CGFloat) -> String {
            String(format: "%@ %@ %@: %.1f (base %.1f, width %.1f)",
                   screen, phone.tag, card.rawValue, photo.height, base, photo.width)
        }
        for phone in Self.phones {
            for card in Card.allCases {
                let (reveal, _) = await liveReveal(card, on: phone)
                let revealPhoto = try #require(reveal.frames.photo)
                reveal.window.isHidden = true
                lines.append(line("reveal", phone, card, revealPhoto, base: Self.revealBasePhotoHeight(phone)))
                #expect(revealPhoto.height >= Self.revealBasePhotoHeight(phone) - 0.5,
                        "reveal \(phone.tag) \(card): \(revealPhoto.size)")
                #expect(revealPhoto.height <= revealPhoto.width + 0.5,
                        "reveal \(phone.tag) \(card): \(revealPhoto.size)")

                let detail = try await liveDetail(card, on: phone, fullScreen: false)
                let detailPhoto = try #require(detail.frames.photo)
                detail.window.isHidden = true
                lines.append(line("detail", phone, card, detailPhoto, base: Self.detailBasePhotoHeight(phone)))
                #expect(detailPhoto.height >= Self.detailBasePhotoHeight(phone) - 0.5,
                        "detail \(phone.tag) \(card): \(detailPhoto.size)")
                #expect(detailPhoto.height <= detailPhoto.width + 0.5,
                        "detail \(phone.tag) \(card): \(detailPhoto.size)")
            }
        }
    }

    /// With `fillsHeight` and no spare height, the card is the size the
    /// detail screen's scroll view always made it: the plain card's.
    @Test func settledCardWithFillAndNoSpareHeightIsThePlainCard() {
        for card in Card.allCases {
            let plain = UIHostingController(rootView: SettledCatchCard(
                plane: Self.plane(card, photo: nil), isFirstOfType: card == .tall, width: 357))
            let filling = UIHostingController(rootView: SettledCatchCard(
                plane: Self.plane(card, photo: nil), isFirstOfType: card == .tall, width: 357,
                fillsHeight: true))
            let was = plain.sizeThatFits(in: CGSize(width: 357, height: 2_500))
            let now = filling.sizeThatFits(in: CGSize(width: 357, height: 10))
            #expect(abs(was.height - now.height) < 0.5, "\(card): \(was.height) vs \(now.height)")
        }
    }

    /// The share cards and every fixed render use the card without
    /// `fillsHeight`: offered any height, it is the size it always was.
    @Test func settledCardWithoutFillIgnoresSpareHeight() {
        let card = SettledCatchCard(plane: Self.plane(.short, photo: nil),
                                    isFirstOfType: false, width: 357)
        let controller = UIHostingController(rootView: card)
        let natural = controller.sizeThatFits(in: CGSize(width: 357, height: 1_500))
        let offeredMore = controller.sizeThatFits(in: CGSize(width: 357, height: 2_500))
        #expect(abs(natural.height - offeredMore.height) < 0.5)
    }
}
#endif
