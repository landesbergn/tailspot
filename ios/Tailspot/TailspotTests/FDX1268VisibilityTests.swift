//
//  FDX1268VisibilityTests.swift
//  TailspotTests
//
//  Field miss 2026-06-19 (Noah, on a walk): FDX1268 (icao ac5c1f), a FedEx
//  freighter at ~10.9 km / 3.6° elevation, clearly visible by eye but the
//  app filtered it into the hidden tier — tapping it produced empty-taps
//  with reason "filtered".
//
//  RESOLUTION (tap-to-reveal, not a filter loosening): FDX1268 is
//  geometrically inseparable from the 2026-06-15 MLAT firehose (same low /
//  fast / large-airframe approach class), so ambient-labeling it would
//  resurface the clutter the precision band deliberately kills (see
//  FieldReplayRegressionTests.precisionBandSuppressesMLATFirehose). It stays
//  HIDDEN in the ambient HUD; a tap reveals it (ContentView.handleTap branch
//  4). So the regression floor here is no longer "isVisible" — it's that the
//  bench DETECTS the miss: the recorded empty-tap (reason "filtered") must
//  score as a missedPlane, which is what drives the tap-to-reveal demand
//  signal and would catch any future regression that re-hides this class
//  without a reveal path.
//
//  Local fixture (real GPS, gitignored as local-*); runs on Noah's machine
//  and SKIPS in CI until a redacted fixture is promoted into FieldReplays/.
//

import Testing
import Foundation
@testable import Tailspot

private final class FDXReplayToken {}

@MainActor
@Suite("FDX1268 visibility regression")
struct FDX1268VisibilityTests {

    nonisolated static var fixture: URL? {
        Bundle(for: FDXReplayToken.self).url(forResource: "local-fdx1268", withExtension: "jsonl")
    }

    @Test(.enabled(if: FDX1268VisibilityTests.fixture != nil))
    func fdx1268IsScoredMissedByTheBench() throws {
        let events = try ReplayJSONL.decode(Data(contentsOf: Self.fixture!))
        let report = ReplayAnalyzer().scoreFailureModes(events)
        let missed = report.findings(for: .missedPlane).filter { $0.icao24 == "ac5c1f" }
        #expect(!missed.isEmpty,
                "FDX1268 (ac5c1f) empty-tap (reason 'filtered') must score as a missedPlane — the bench has to see the field miss so tap-to-reveal stays demand-driven")
    }

    /// The plane genuinely sits in the hidden tier (the reveal path, not the
    /// ambient filter, is what makes it catchable). Pins the design choice:
    /// admitting it ambiently would resurface the 06-15 firehose.
    @Test(.enabled(if: FDX1268VisibilityTests.fixture != nil))
    func fdx1268StaysHiddenInTheAmbientHUD() throws {
        let events = try ReplayJSONL.decode(Data(contentsOf: Self.fixture!))
        let report = ReplayAnalyzer().analyze(events)
        let sightings = report.ticks.flatMap(\.aircraft).filter { $0.icao24 == "ac5c1f" }
        #expect(!sightings.isEmpty, "FDX1268 (ac5c1f) missing from fixture data")
        #expect(sightings.allSatisfy { !$0.isVisible },
                "FDX1268 is intentionally not ambient-labeled (inseparable from the 06-15 firehose); tap-to-reveal is its catch path")
    }
}
