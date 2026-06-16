//
//  FieldReplayRegressionTests.swift
//  TailspotTests
//
//  Every documented field miss becomes a PERMANENT fixture: the actual
//  replay recording from Noah's phone, committed under FieldReplays/,
//  replayed through the real ReplayAnalyzer (the same projection +
//  visibility code the live app runs), with an assertion that the missed
//  plane can never be missed that way again. Identification is the
//  product; these tests are its floor.
//
//  When a new field miss is diagnosed: commit the replay, add a case
//  here with the icao24 + the story, make it green. Never delete a case.
//

import CoreGraphics
import Foundation
import Testing
@testable import Tailspot

/// Bundle hook — Swift Testing has no Bundle.module in xcodeproj targets.
private final class FieldReplayBundleToken {}

@MainActor
@Suite("Field replay regressions")
struct FieldReplayRegressionTests {

    private func loadReplay(_ name: String) throws -> [ReplayEvent] {
        let bundle = Bundle(for: FieldReplayBundleToken.self)
        let url = try #require(bundle.url(forResource: name, withExtension: "jsonl"),
                               "fixture \(name).jsonl missing from test bundle")
        return try ReplayJSONL.decode(Data(contentsOf: url))
    }

    /// The analyzer with the app's real screen/FOV defaults.
    private func analyze(_ name: String) throws -> ReplayReport {
        let analyzer = ReplayAnalyzer()
        return analyzer.analyze(try loadReplay(name))
    }

    /// Field miss #1 (2026-06-11, Sea Ranch): ANA179 at 12.1 km cruise,
    /// slant 19.2 km, elevation 39.1° — clearly visible by contrail,
    /// pruned by the old 13 km plateau. Fixed by the contrail segment
    /// (PR #17); pinned here against the real recording forever.
    @Test func ana179ContrailPlaneIsVisible() throws {
        let report = try analyze("replay-2026-06-11T161754Z")
        let sightings = report.ticks.flatMap(\.aircraft).filter { $0.icao24 == "86d5d8" }
        #expect(!sightings.isEmpty, "ANA179 missing from fixture data")
        let allVisible = sightings.allSatisfy { $0.isVisible }
        #expect(allVisible, "ANA179 (19.2 km @ 39.1°, contrail-visible) must pass visibility")
    }

    /// Field miss #2 (2026-06-12, Berkeley): GTI9648, an Atlas 747
    /// freighter at 16.6 km / 43.8° — in-data, fresh, visibility-passing,
    /// but Noah was at 5× zoom (11° FOV) pointing 12–17° off-axis, so the
    /// label projected just off-screen and taps found empty sky. The
    /// viewport half of the fix is the off-screen chevrons (PR #28, whose
    /// complement tests guarantee label-or-chevron); THIS test pins the
    /// data half: the plane must remain visibility-passing.
    @Test func gti9648ZoomedOffFramePlaneIsVisible() throws {
        let report = try analyze("replay-2026-06-12T235400Z")
        let sightings = report.ticks.flatMap(\.aircraft).filter { $0.icao24 == "abbe4a" }
        #expect(!sightings.isEmpty, "GTI9648 missing from fixture data")
        let allVisible = sightings.allSatisfy { $0.isVisible }
        #expect(allVisible, "GTI9648 (16.6 km @ 43.8°) must pass visibility")
    }

    /// Field case #3 (2026-06-12, Berkeley) — REVISED for the precision
    /// doctrine (2026-06-15). SKW5480 at 18.0 km / 12.1° was confirmed
    /// visible on a clear day, and under the old "never hide inside 35 km"
    /// tier it was pinned always-visible. The backend's dense MLAT feed made
    /// that flat ceiling untenable (replay-2026-06-15: 76 contacts, ~20 false
    /// faint labels), so the faint band is now `faintBandFactor`× the curve.
    /// SKW5480 sits beyond it and no longer auto-labels — the deliberate
    /// precision tradeoff (it also contradicts the ghost data: 8.1 km @ 12°
    /// was a confirmed ghost). The fixture stays; the assertion is inverted
    /// to PIN the intended behavior, not to bless the miss. Recall for this
    /// far class is a planned tap-to-reveal affordance.
    @Test func skw5480FarPlaneNotAutoLabeledUnderPrecisionPolicy() throws {
        let report = try analyze("replay-2026-06-13T001130Z")
        let sightings = report.ticks.flatMap(\.aircraft).filter { $0.icao24 == "a04f49" }
        #expect(!sightings.isEmpty, "SKW5480 missing from fixture data")
        let allHidden = sightings.allSatisfy { !$0.isVisible }
        #expect(allHidden, "SKW5480 (18.0 km @ 12.1°) is intentionally not auto-labeled under the precision band")
    }

    /// Field case #4 (2026-06-12 evening, Berkeley) — REVISED for the
    /// precision doctrine (2026-06-15). N21866 (GA fly-by) was confirmed
    /// visible once and a confirmed GHOST at 6.3 km on 2026-06-06 — one
    /// tail, documented on both sides of the margin. Under the precision
    /// band it behaves exactly as a close fly-by should: labeled at closest
    /// approach (inside 2× the GA half-cap), dropped as it recedes. So
    /// unlike far traffic (SKW5480), close GA stays CATCHABLE — the band
    /// shows it when it's actually near. The assertion pins the recall
    /// floor: it must be visible in at least its closest tick(s).
    @Test func n21866CloseGAFlybyIsCatchableAtClosestApproach() throws {
        let report = try analyze("replay-2026-06-13T002736Z")
        let sightings = report.ticks.flatMap(\.aircraft).filter { $0.icao24 == "a1da83" }
        #expect(!sightings.isEmpty, "N21866 missing from fixture data")
        #expect(sightings.contains { $0.isVisible },
                "N21866 (close GA fly-by) must be labelable at closest approach, not entirely hidden")
    }

    /// Field datum (2026-06-15, Berkeley) — the precision turning point and
    /// the reason the flat faint ceiling died. The first 0.5.0 backend
    /// session pulled 76 MLAT contacts in a single tick, of which exactly
    /// ONE — FDX350, an FDX freighter at 4.9 km / 19.4° — was actually
    /// visible (Noah pinned it; everything else was far/low/on the horizon).
    /// The old flat 35 km ceiling surfaced ~20 of the rest as faint labels.
    /// With the curve-relative band, FDX350 stays full and the firehose is
    /// gone. This fixture pins both halves: the real plane stays, the wall
    /// of false labels does not return.
    @Test func precisionBandSuppressesMLATFirehose() throws {
        let report = try analyze("replay-2026-06-15T001746Z")
        let fedex = report.ticks.flatMap(\.aircraft).filter { $0.icao24 == "ac1846" }
        #expect(!fedex.isEmpty, "FDX350 missing from fixture data")
        #expect(fedex.allSatisfy { $0.isVisible }, "FDX350 (4.9 km @ 19.4°) must stay labeled")
        let maxVisible = report.ticks.map(\.visibleCount).max() ?? 0
        #expect(maxVisible <= 3,
                "precision band must keep the 76-contact MLAT feed to a handful of labels (got \(maxVisible))")
    }

    /// The faint ceiling still excludes the absurd: in the SKW5480
    /// recording, SKW3211 sat at 56 km slant / 0.7° elevation — below the
    /// horizon floor and far beyond any visibility claim. The tier change
    /// must NOT have turned the overlay into a 77-label firehose.
    @Test func tierChangeDoesNotShowEverything() throws {
        let report = try analyze("replay-2026-06-13T001130Z")
        guard let lastTick = report.ticks.last else {
            Issue.record("no ticks in fixture"); return
        }
        let far = lastTick.aircraft.first { $0.icao24 == "a129b0" }
        if let far { #expect(!far.isVisible, "56 km @ 0.7° must stay hidden") }
        // And the overall visible share stays a filter, not a pass-through.
        #expect(lastTick.visibleCount < lastTick.aircraft.count / 2,
                "visibility must still exclude the majority of a 77-plane bbox")
    }
}
