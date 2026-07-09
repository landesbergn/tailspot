//
//  GuessRoundSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the pre-reveal ROUTE BONUS ROUND (game-layer PR3;
//  route-only per Noah 2026-07-09), mirroring RevealSnapshotTests. Renders the
//  route-question screen and a reveal WITH a "10% ROUTE BONUS" ledger line to
//  PNGs via ImageRenderer so the layout can be eyeballed off-device. NOT an
//  assertion test: it writes images to /private/tmp/tailspot_snaps and passes.
//  Review the PNGs after running.
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
@testable import Tailspot

@MainActor
@Suite("Guess-round snapshots (visual pass)")
struct GuessRoundSnapshotTests {

    // Berkeley — the home-base observer, so the fixture route asks the endpoint
    // farther out (KSFO → VHHH ⇒ "Where's it headed?").
    private let observerLat = 37.87
    private let observerLon = -122.27

    @Test func renderGuessScreensAndBonusReveal() {
        let dir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let screen = CGSize(width: 393, height: 852)
        let cardWidth = min(screen.width - 28, 420)

        // 1 — route question ("Where's it headed?" · HKG among 4 chips).
        if let route = routeQuestion() {
            let view = GuessRoundView(
                question: GuessRoundQuestion(route: route), photoURL: nil, photoFocus: nil,
                onComplete: { _, _ in }
            )._snapshotScreen(width: cardWidth, size: screen)
            write(view, name: "guess_route_question", to: dir)
        }

        // 2 — reveal WITH a correct route-guess bonus line (rare wide,
        // first-of-type + a correct ROUTE call → both bonus lines + the
        // count-up TOTAL that includes them; the guess line reads
        // "10% ROUTE BONUS +N").
        let base = Rarity.rare.basePoints
        let plane = CardPlane(
            callsign: "UAL248", model: "Boeing 787-9", carrier: "United Airlines",
            rarity: .rare, type: .wide,
            altText: "37,004 ft", speedText: "478 kt", distText: "12.0 km",
            originIcao: "KSFO", destIcao: "RJTT",
            originName: "San Francisco", destName: "Tokyo Narita",
            isFirstOfType: true,
            guessKind: .route,
            guessBonusPoints: ScoringBonuses.guessBonus(base: base, kind: .route)
        )
        let reveal = CatchRevealView(
            plane: plane, entryNumber: 62, onDismiss: {}, onViewInHangar: {}
        )._snapshotScreen(width: cardWidth, size: screen)
        write(reveal, name: "reveal_with_guess_bonus", to: dir)
    }

    // MARK: - Fixtures

    private func routeQuestion() -> GuessOptions.RouteQuestion? {
        var rng = SeededRNG(seed: 7)
        return GuessOptions.routeQuestion(
            originIcao: "KSFO", destIcao: "VHHH",
            observerLat: observerLat, observerLon: observerLon,
            using: &rng
        )
    }

    private func write(_ view: some View, name: String, to dir: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        // Pure side-effect harness — never fail CI over a render/write hiccup.
        guard let img = renderer.uiImage, let data = img.pngData() else { return }
        try? data.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
#endif
