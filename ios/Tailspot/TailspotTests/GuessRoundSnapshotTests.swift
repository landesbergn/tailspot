//
//  GuessRoundSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the IN-CARD ROUTE BONUS ROUND (game-layer PR3;
//  in-card redesign per Noah 2026-07-10). The round now plays ON the reveal
//  card (`CatchRevealView`), so this renders the three beats — chips popped +
//  masked route, correct-answer settled (with the "10% ROUTE BONUS" ledger
//  line + rolled-up TOTAL), wrong-answer settled (route revealed, no line) — as
//  static frames via `_snapshotScreen(guessState:)`. NOT an assertion test: it
//  writes PNGs to /private/tmp/tailspot_snaps and passes. Review the PNGs.
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

    @Test func renderInCardBonusRoundBeats() {
        let dir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let screen = CGSize(width: 393, height: 852)
        let cardWidth = min(screen.width - 28, 420)

        guard let route = routeQuestion() else {
            Issue.record("route question fixture failed to build")
            return
        }
        let question = GuessRoundQuestion(route: route)
        // The catch under the round — rare + first-of-type so the ledger is rich
        // (base + FIRST OF TYPE + the route bonus). guessKind is deliberately nil:
        // the reveal drives the bonus live, exactly as at catch time.
        let plane = CardPlane(
            callsign: "UAL248", model: "Boeing 787-9", carrier: "United Airlines",
            rarity: .rare, type: .wide,
            altText: "37,004 ft", speedText: "478 kt", distText: "12.0 km",
            originIcao: "SFO", destIcao: "HKG",
            originName: "San Francisco", destName: "Hong Kong",
            isFirstOfType: true
        )

        func reveal() -> CatchRevealView {
            CatchRevealView(plane: plane, entryNumber: 62, onDismiss: {}, onViewInHangar: {},
                            guess: question)
        }

        // (a) — chips popped in, route masked, TOTAL at the pre-bonus value.
        let popped = CatchRevealView.GuessSnapshotState(
            render: .init(question: question, resolution: nil, chipsInLayout: true, popClock: 1),
            bt: 0
        )
        write(reveal()._snapshotScreen(width: cardWidth, size: screen, guessState: popped),
              name: "guess_chips_popped", to: dir)

        // (b) — correct answer settled: chips collapsed, real route, "10% ROUTE
        // BONUS +N" in the ledger, TOTAL rolled up to include it (bt = 1).
        let correct = CatchRevealView.GuessSnapshotState(
            render: .init(
                question: question,
                resolution: .init(answeredValue: question.correctValue, correct: true),
                chipsInLayout: false, popClock: 1),
            bt: 1
        )
        write(reveal()._snapshotScreen(width: cardWidth, size: screen, guessState: correct),
              name: "guess_correct_settled", to: dir)

        // (c) — wrong answer settled: chips collapsed, real route revealed, NO
        // bonus line, TOTAL at the pre-bonus value.
        let wrongValue = question.options.first { $0.value != question.correctValue }?.value ?? ""
        let wrong = CatchRevealView.GuessSnapshotState(
            render: .init(
                question: question,
                resolution: .init(answeredValue: wrongValue, correct: false),
                chipsInLayout: false, popClock: 1),
            bt: 0
        )
        write(reveal()._snapshotScreen(width: cardWidth, size: screen, guessState: wrong),
              name: "guess_wrong_settled", to: dir)
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
