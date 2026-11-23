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
//  A card too tall for its screen takes height back from the photo, down
//  to a floor, before it scrolls. And the text under the photo is at its
//  designed size times the card's width scale on every phone: height
//  pressure never shrinks it (`textUnderThePhotoIsAtItsDesignedSize`).
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
    // Every other screen shape the app runs on (iOS 26 floor: iPhone 11 on).
    // The mini is the one to watch: the SE's width with far more height, so
    // its photo grows the most relative to its width.
    static let mini = Phone(tag: "375x812", size: CGSize(width: 375, height: 812), top: 50, bottom: 34)
    static let iPhone14 = Phone(tag: "390x844", size: CGSize(width: 390, height: 844), top: 47, bottom: 34)
    static let iPhone11 = Phone(tag: "414x896", size: CGSize(width: 414, height: 896), top: 48, bottom: 34)
    static let plus = Phone(tag: "428x926", size: CGSize(width: 428, height: 926), top: 47, bottom: 34)
    static let oldProMax = Phone(tag: "430x932", size: CGSize(width: 430, height: 932), top: 59, bottom: 34)
    static let phones = [se, mini, iPhone14, iPhone16, iPhone17, iPhone11, plus, oldProMax, proMax]

    // MARK: Cards

    /// `plain` is the card Noah reported (SHORT without the notable caption
    /// and its ledger row): asserted on, and rendered on the iPhone 16 only.
    enum Card: String, CaseIterable {
        case plain, short, typical, tall, taller
        static let rendered: [Card] = [.short, .typical, .tall, .taller]
    }

    static let team = NotablePlane(kind: "team", label: "Team plane", name: "Golden State Warriors")!
    /// Long enough that the caption on the photo takes its two-line form.
    static let longCaption = NotablePlane(
        kind: "government", label: "Head of state and government",
        name: "United States Air Force, 89th Airlift Wing")!

    /// PLAIN: no route, common, one-line name, a two-row ledger.
    /// SHORT: the same with the notable caption on (and its ledger row).
    /// TYPICAL: a route and a one-line name.
    /// TALL: a three-line name, a route, first-of-type and notable rows.
    /// TALLER: the card that overflowed Noah's iPhone 16 (2026-11-22): a
    /// three-line name, a DIST row, three ledger rows and a total, with the
    /// two-line notable caption on the photo. Too tall for most screens at
    /// the usual photo height, so the photo gives height back.
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
        case .taller:
            return CardPlane(
                callsign: "N680CS", model: "Cessna 680 Citation Sovereign", carrier: "Private",
                rarity: .uncommon, type: .biz,
                altText: "41,000 ft", speedText: "430 kt", distText: "14.0 km",
                photoURL: photo, photoFocus: focus,
                isFirstOfType: true, notable: longCaption, icao24: "fa0005")
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
        let taller = make("fa0005", "N680CS", "Private", "C680", alt: 12_500, speed: 221, dist: 14_000,
                          notable: longCaption, at: at)
        // Saved, so the detail screen's query sees the older 737 from its
        // first pass (unsaved, FIRST OF TYPE can flicker onto the ledger).
        try container.mainContext.save()
        return (container, [.plain: plain, .short: short, .typical: typical, .tall: tall,
                            .taller: taller])
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
        /// Everything in the card under the photo, as one height.
        var underPhoto: CGFloat? {
            guard let card, let photo else { return nil }
            return card.height - photo.height
        }
    }

    /// The squeezed text the fill must not resize.
    static let textParts: [(CardFramePart, String)] = [
        (.callsign, "callsign"), (.altValue, "ALT"), (.distValue, "DIST"), (.routeCodes, "route"),
    ]

    private struct Hosted {
        let window: UIWindow
        let view: UIView
        let frames: Frames
    }

    /// Puts `view` in a window of `size`, without waiting. The caller's root
    /// ignores the simulator's own safe area, so the window's size is the
    /// layout's size.
    private func mount(_ view: some View, size: CGSize) -> Hosted {
        // No peek (`CardFlipTease`): mid-tilt, the card's frames and the
        // capture are of a turned card. The peek decides once, when the card
        // appears, so the flag only has to hold until then.
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
        return Hosted(window: window, view: controller.view, frames: frames)
    }

    /// Waits `settle`, then until every card has reported its frames and
    /// they have stopped moving (the reveal's card settles over a few layout
    /// passes), giving up after 20 s. Waits are `Task.sleep`, never a
    /// run-loop spin (which blocks the screens' own `.task`s).
    private func waitUntilSteady(_ hosted: [Hosted], settle: Duration) async {
        try? await Task.sleep(for: settle)
        let started = Date()
        var last: [[CardFramePart: CGRect]] = []
        var steady = 0
        repeat {
            for h in hosted {
                h.view.setNeedsLayout()
                h.view.layoutIfNeeded()
            }
            try? await Task.sleep(for: .milliseconds(120))
            let now = hosted.map(\.frames.parts)
            steady = (hosted.allSatisfy(\.frames.complete) && now == last) ? steady + 1 : 0
            last = now
        } while steady < 2 && Date().timeIntervalSince(started) < 20
    }

    private func host(_ view: some View, size: CGSize, settle: Duration) async -> Hosted {
        let hosted = mount(view, size: size)
        await waitUntilSteady([hosted], settle: settle)
        return hosted
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let s = view as? UIScrollView { return s }
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }

    private func mountReveal(_ card: Card, on phone: Phone) -> Hosted {
        var reveal = CatchRevealView(plane: Self.plane(card, photo: nil), entryNumber: 62,
                                     onDismiss: {}, onViewInHangar: {})
        reveal._reduceMotionOverride = true
        return mount(reveal, size: phone.safe)
    }

    private func liveReveal(_ card: Card, on phone: Phone) async -> (Hosted, CGRect?) {
        let hosted = mountReveal(card, on: phone)
        await waitUntilSteady([hosted], settle: .milliseconds(400))
        let viewport = firstScrollView(in: hosted.view).map { $0.convert($0.bounds, to: hosted.window) }
        return (hosted, viewport)
    }

    /// The detail screen laid out in the phone's safe area. With `fullScreen`
    /// the status-bar and home-indicator bands are padded back on around it,
    /// so a capture of the window is the whole screen.
    private func mountDetail(_ card: Card, on phone: Phone, fullScreen: Bool,
                             photoFilename: String? = nil) throws -> Hosted {
        let (container, catches) = try Self.hangar(photoFilename: photoFilename)
        let c = try #require(catches[card])
        let row = HangarRow(icao24: c.icao24, mostRecent: c, count: 1, allCatches: [c])
        let screen = CatchDetailView(row: row)
            .frame(width: phone.safe.width, height: phone.safe.height)
            .padding(.top, fullScreen ? phone.top : 0)
            .padding(.bottom, fullScreen ? phone.bottom : 0)
            .background(Brand.Color.bgPrimary)
            .modelContainer(container)
        return mount(screen, size: fullScreen ? phone.size : phone.safe)
    }

    private func liveDetail(_ card: Card, on phone: Phone, fullScreen: Bool,
                            photoFilename: String? = nil) async throws -> Hosted {
        let hosted = try mountDetail(card, on: phone, fullScreen: fullScreen,
                                     photoFilename: photoFilename)
        await waitUntilSteady([hosted], settle: .milliseconds(400))
        return hosted
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
            for card in Card.rendered + ([Self.iPhone16.tag, Self.mini.tag].contains(phone.tag) ? [.plain] : []) {
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
            for card in Card.rendered + ([Self.iPhone16.tag, Self.mini.tag].contains(phone.tag) ? [.plain] : []) {
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

    private static func revealPhotoFloor(_ phone: Phone) -> CGFloat {
        100 * min(phone.safe.width - 28, 420) / 300
    }

    private static func detailPhotoFloor(_ phone: Phone) -> CGFloat {
        CardPhotoFill.minHeight(base: detailBasePhotoHeight(phone))
    }

    /// A card too tall for the SE even with the photo at its floor keeps the
    /// photo at the floor (the reveal's chips-up height) and scrolls.
    @Test func revealTallCardOnSEShrinksThePhotoToItsFloor() async throws {
        let (hosted, _) = await liveReveal(.tall, on: Self.se)
        defer { hosted.window.isHidden = true }
        let photo = try #require(hosted.frames.photo)
        #expect(abs(photo.height - Self.revealPhotoFloor(Self.se)) < 0.5,
                "photo \(photo.height) should be at its floor \(Self.revealPhotoFloor(Self.se))")
        let scroll = try #require(firstScrollView(in: hosted.view))
        #expect(scroll.contentSize.height > scroll.bounds.height + 1, "the SE card should still scroll")
    }

    /// The card Noah reported on the saved-catch screen (TALLER). On the
    /// detail screen, 6.1" phones and up: the photo gives back just enough
    /// height that the turn-over row ends inside the screen, and stays
    /// between its floor and its usual height. On the SE it is at the floor
    /// and the screen scrolls. On the reveal: see the note in the loop.
    @Test func tallerCardShrinksItsPhotoToFit() async throws {
        var lines: [String] = []
        defer {
            try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
            try? lines.joined(separator: "\n").write(
                to: Self.dir.appendingPathComponent("fill_taller_measurements.txt"),
                atomically: true, encoding: .utf8)
        }
        for phone in Self.phones {
            let (reveal, viewportFrame) = await liveReveal(.taller, on: phone)
            let detail = try await liveDetail(.taller, on: phone, fullScreen: false)
            defer { reveal.window.isHidden = true; detail.window.isHidden = true }
            let viewport = try #require(viewportFrame)
            let cases: [(String, Frames, CGFloat, CGFloat, CGFloat, UIView)] = [
                ("reveal", reveal.frames, Self.revealPhotoFloor(phone), Self.revealBasePhotoHeight(phone),
                 viewport.maxY, reveal.view),
                ("detail", detail.frames, Self.detailPhotoFloor(phone), Self.detailBasePhotoHeight(phone),
                 phone.safe.height, detail.view),
            ]
            for (screen, frames, floor, base, bottomEdge, view) in cases {
                let name = "\(screen) \(phone.tag)"
                let photo = try #require(frames.photo, "\(name): no photo frame")
                let turnRow = try #require(frames.turnRow, "\(name): no turn row frame")
                let scroll = try #require(firstScrollView(in: view), "\(name): no scroll view")
                let scrolls = scroll.contentSize.height > scroll.bounds.height + 1
                lines.append(String(format: "%@: photo %.1f (floor %.1f, base %.1f), turn row ends %.1f, "
                                    + "screen ends %.1f, scrolls %@", name, photo.height, floor, base,
                                    turnRow.maxY, bottomEdge, scrolls ? "yes" : "no"))
                #expect(photo.height >= floor - 0.5, "\(name): photo \(photo.height) under its floor \(floor)")
                if phone.tag == Self.se.tag {
                    #expect(abs(photo.height - floor) < 0.5, "\(name): photo \(photo.height), floor \(floor)")
                    #expect(scrolls, "\(name): should scroll")
                } else if phone.size.width >= 393 {
                    #expect(turnRow.maxY <= bottomEdge + 0.5,
                            "\(name): turn row ends at \(turnRow.maxY), screen at \(bottomEdge)")
                    #expect(photo.height <= base + 0.5, "\(name): photo \(photo.height) over base \(base)")
                    #expect(!scrolls, "\(name): should not scroll")
                }
            }
        }
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

    @Test func detailTallCardOnSEShrinksThePhotoToItsFloor() async throws {
        let hosted = try await liveDetail(.tall, on: Self.se, fullScreen: false)
        defer { hosted.window.isHidden = true }
        let photo = try #require(hosted.frames.photo)
        #expect(abs(photo.height - Self.detailPhotoFloor(Self.se)) < 0.5,
                "photo \(photo.height) should be at its floor \(Self.detailPhotoFloor(Self.se))")
        let scroll = try #require(firstScrollView(in: hosted.view))
        #expect(scroll.contentSize.height > scroll.bounds.height + 1, "the SE card should still scroll")
    }

    /// The text under the photo, on every phone and card, both screens
    /// (Noah, 2026-11-22):
    ///  - it is drawn at its DESIGNED size times the card's width scale
    ///    (card width / 300) times ONE factor for the whole block;
    ///  - the factor is 1 whenever the card fits with its photo above the
    ///    floor (the photo gives way first), and never below 0.88;
    ///  - a card that still scrolls has its photo at the floor and its
    ///    factor at 0.88: it has given everything it can.
    /// Before these rules the reveal drew ALT/SPD small on short cards and
    /// on a 414-wide phone, and route codes small beside large ALT, by an
    /// accident of its layout: some lines shrank and others did not.
    ///
    /// The designed size is measured, not written down: each screen hosted
    /// 393 wide and far taller than any card, where nothing is under
    /// pressure. A screen's factor is its block's height (the card less
    /// its photo and the photo's padding) against that; each probed line
    /// (callsign, ALT value, DIST value, route codes) must then be its
    /// designed height × width scale × that same factor. Frames are
    /// reported snapped to the pixel grid, so each measurement can be a
    /// pixel out; a line that shrank on its own is a third smaller.
    ///
    /// Also here, since it hosts everything anyway: the photo stays between
    /// its floor and its own width. Writes fill_measurements.txt.
    @Test func textUnderThePhotoIsAtItsDesignedSize() async throws {
        let tolerance: CGFloat = 0.7
        let roomy = Phone(tag: "roomy", size: CGSize(width: 393, height: 1_700), top: 0, bottom: 0)
        /// A screen's width scale, and the photo padding that is not part
        /// of the block (18 pt at 300 wide, above and below the photo).
        func metrics(_ screen: String, _ phone: Phone) -> (scale: CGFloat, base: CGFloat, floor: CGFloat) {
            screen == "reveal"
                ? (min(phone.safe.width - 28, 420) / 300, Self.revealBasePhotoHeight(phone), Self.revealPhotoFloor(phone))
                : (min(phone.safe.width - 36, 420) / 300, Self.detailBasePhotoHeight(phone), Self.detailPhotoFloor(phone))
        }
        func block(_ frames: Frames, scale: CGFloat) -> CGFloat? {
            frames.underPhoto.map { $0 - 36 * scale }
        }
        func mountAll(on phone: Phone) throws -> [(String, Card, Hosted)] {
            try Card.allCases.flatMap { card in
                [("reveal", card, mountReveal(card, on: phone)),
                 ("detail", card, try mountDetail(card, on: phone, fullScreen: false))]
            }
        }

        // Designed sizes at scale 1, per screen and card.
        var designedBlock: [String: CGFloat] = [:]
        var designedText: [String: [CardFramePart: CGSize]] = [:]
        let reference = try mountAll(on: roomy)
        await waitUntilSteady(reference.map(\.2), settle: .milliseconds(600))
        for (screen, card, hosted) in reference {
            hosted.window.isHidden = true
            let scale = metrics(screen, roomy).scale
            let key = "\(screen) \(card.rawValue)"
            designedBlock[key] = try #require(block(hosted.frames, scale: scale), "\(key): no reference frames") / scale
            designedText[key] = hosted.frames.parts.mapValues {
                CGSize(width: $0.width / scale, height: $0.height / scale)
            }
        }

        var lines = ["screen size card | photo (floor, base, width) | factor | scrolls | "
                     + "text height (designed at scale 1): callsign, ALT, DIST, route"]
        defer {
            try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
            try? lines.joined(separator: "\n").write(
                to: Self.dir.appendingPathComponent("fill_measurements.txt"), atomically: true, encoding: .utf8)
        }
        // One phone at a time, its ten screens side by side.
        for phone in Self.phones {
            let mounted = try mountAll(on: phone)
            await waitUntilSteady(mounted.map(\.2), settle: .milliseconds(600))
            for (screen, card, hosted) in mounted {
                hosted.window.isHidden = true
                let name = "\(screen) \(phone.tag) \(card.rawValue)"
                let key = "\(screen) \(card.rawValue)"
                let (scale, base, floor) = metrics(screen, phone)
                let photo = try #require(hosted.frames.photo, "\(name): no photo frame")
                #expect(photo.height >= floor - 0.5, "\(name): photo \(photo.size) under its floor \(floor)")
                #expect(photo.height <= photo.width + 0.5, "\(name): photo \(photo.size) taller than wide")

                let designed = try #require(designedBlock[key])
                let factor = try #require(block(hosted.frames, scale: scale)) / (designed * scale)
                let atFloor = photo.height < floor + 0.5
                let scrolls = firstScrollView(in: hosted.view)
                    .map { $0.contentSize.height > $0.bounds.height + 1 } ?? false
                #expect(factor > CardPhotoFill.minTextScale - 0.005 && factor < 1.005, "\(name): factor \(factor)")
                if !atFloor {
                    #expect(abs(factor - 1) < 0.005, "\(name): factor \(factor) with the photo at \(photo.height), floor \(floor)")
                }
                if scrolls {
                    #expect(atFloor, "\(name): scrolls with the photo at \(photo.height), floor \(floor)")
                    #expect(factor < CardPhotoFill.minTextScale + 0.005, "\(name): scrolls at factor \(factor)")
                }

                var texts: [String] = []
                for (part, label) in Self.textParts {
                    let want = designedText[key]?[part]
                    let got = hosted.frames.parts[part]?.height
                    #expect((got == nil) == (want == nil), "\(name): \(label) on screen \(got != nil), designed \(want != nil)")
                    guard let got, let want else { texts.append("\(label) -"); continue }
                    // Every probed line is its designed height × the card's
                    // width scale × the block's one factor.
                    #expect(abs(got - want.height * scale * factor) < tolerance,
                            "\(name): \(label) is \(got) pt; designed \(want.height) × \(scale) × \(factor)")
                    texts.append(String(format: "%@ %.2f (%.2f)", label, got, want.height))
                }
                lines.append(String(format: "%@ | %.1f (%.1f, %.1f, %.1f) | %.3f | %@ | ", name, photo.height,
                                    floor, base, photo.width, factor, scrolls ? "SCROLLS" : "fits")
                             + texts.joined(separator: ", "))
            }
        }
    }

    /// Neither screen keeps laying out once it has settled. The fill
    /// measures the card and feeds the photo's height from it; a
    /// measurement that included its own result once made the detail screen
    /// rebuild its card forever (a frozen screen on a phone). Every phone
    /// and card, both screens, all on screen together: after they settle,
    /// the count of card builds must stop. (The bound allows a late
    /// Planespotters answer per detail screen; a loop runs to thousands.)
    @Test func screensStopLayingOut() async throws {
        var mounted: [Hosted] = []
        for phone in Self.phones {
            for card in Card.allCases {
                mounted.append(mountReveal(card, on: phone))
                mounted.append(try mountDetail(card, on: phone, fullScreen: false))
            }
        }
        defer { mounted.forEach { $0.window.isHidden = true } }
        // Past the reveal's ceremony (its clock rebuilds the card every
        // frame until it settles) and the detail screen's lookups.
        try? await Task.sleep(for: .seconds(6))
        let before = CardBuildCounter.builds
        try? await Task.sleep(for: .seconds(2))
        let builds = CardBuildCounter.builds - before
        #expect(builds <= mounted.count * 2,
                "\(builds) card builds in 2 s across \(mounted.count) settled screens")
        let allReported = mounted.allSatisfy { $0.frames.complete }
        #expect(allReported, "every screen should have laid its card out")
    }

    /// With `fillsHeight`, the card's shortest is the plain card (at its
    /// ideal size) less exactly what the photo may give back and what the
    /// block under it may scale away (12% of its height).
    @Test func settledCardShrinksOnlyByItsPhotoAndTextScale() {
        for card in Card.allCases {
            let first = card == .tall || card == .taller
            let plane = Self.plane(card, photo: nil)
            let was = UIHostingController(rootView:
                SettledCatchCard(plane: plane, isFirstOfType: first, width: 357).fixedSize())
                .sizeThatFits(in: CGSize(width: 357, height: 2_500)).height
            let shortest = UIHostingController(rootView:
                SettledCatchCard(plane: plane, isFirstOfType: first, width: 357, fillsHeight: true))
                .sizeThatFits(in: CGSize(width: 357, height: 10)).height
            let scale: CGFloat = 357 / 300
            let photo = 168 * scale
            let block = was - photo - 36 * scale
            let expected = was - (photo - CardPhotoFill.minHeight(base: photo))
                - block * (1 - CardPhotoFill.minTextScale)
            // Loose by a few points: laid out wider to be scaled down, a
            // line that was width-limited can come out a little different.
            #expect(abs(shortest - expected) < 3, "\(card): \(shortest) vs \(expected) (was \(was))")
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
