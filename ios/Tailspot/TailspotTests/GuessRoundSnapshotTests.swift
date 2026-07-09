//
//  GuessRoundSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the pre-reveal BONUS ROUND (game-layer PR3),
//  mirroring RevealSnapshotTests. Renders the route-question screen, the
//  type-question screen, and a reveal WITH a guess-bonus ledger line to PNGs
//  via ImageRenderer so the layout can be eyeballed off-device. NOT an
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
                question: .route(route), photoURL: nil, photoFocus: nil,
                onComplete: { _, _ in }
            )._snapshotScreen(width: cardWidth, size: screen)
            write(view, name: "guess_route_question", to: dir)
        }

        // 2 — type question ("CALL THE TYPE" · Boeing 737-800 among 4 chips).
        if let type = typeQuestion() {
            let view = GuessRoundView(
                question: .type(type), photoURL: nil, photoFocus: nil,
                onComplete: { _, _ in }
            )._snapshotScreen(width: cardWidth, size: screen)
            write(view, name: "guess_type_question", to: dir)
        }

        // 3 — reveal WITH a correct-guess bonus line (rare wide, first-of-type +
        // a correct TYPE call → both bonus lines + the count-up TOTAL that
        // includes them).
        let base = Rarity.rare.basePoints
        let plane = CardPlane(
            callsign: "UAL248", model: "Boeing 787-9", carrier: "United Airlines",
            rarity: .rare, type: .wide,
            altText: "37,004 ft", speedText: "478 kt", distText: "12.0 km",
            originIcao: "KSFO", destIcao: "RJTT",
            originName: "San Francisco", destName: "Tokyo Narita",
            isFirstOfType: true,
            guessKind: .type,
            guessBonusPoints: ScoringBonuses.guessBonus(base: base, kind: .type)
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

    private func typeQuestion() -> GuessOptions.TypeQuestion? {
        var rng = SeededRNG(seed: 7)
        return GuessOptions.typeQuestion(typecode: "B738", using: &rng)
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
