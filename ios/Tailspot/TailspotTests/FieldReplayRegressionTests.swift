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

    /// Field miss #3 (2026-06-12, Berkeley): SKW5480 at 18.0 km / 12.1° —
    /// CONFIRMED VISIBLE by Noah, hidden by the low-elevation cap
    /// (~7.7 km at that elevation). The case that ended boolean
    /// visibility: under tiered visibility it must be at least faint —
    /// i.e. never absent from the overlay/list.
    @Test func skw5480LowElevationVisiblePlaneIsNeverHidden() throws {
        let report = try analyze("replay-2026-06-13T001130Z")
        let sightings = report.ticks.flatMap(\.aircraft).filter { $0.icao24 == "a04f49" }
        #expect(!sightings.isEmpty, "SKW5480 missing from fixture data")
        let allVisible = sightings.allSatisfy { $0.isVisible }
        #expect(allVisible, "SKW5480 (confirmed visible, 18.0 km @ 12.1°) must never be hidden")
    }

    /// Field miss #4 (2026-06-12 evening, Berkeley): a close GA fly-by
    /// (best candidate N21866, 5.8 km / 6°) produced no label — the
    /// small-airframe HALF-cap put its threshold at ~3 km. The same tail
    /// was a confirmed GHOST at 6.3 km on 2026-06-06: one aircraft,
    /// field-documented on both sides of the curve. The half-cap now
    /// shapes emphasis only; close GA must always be at least faint.
    @Test func n21866CloseGAFlybyIsNeverHidden() throws {
        let report = try analyze("replay-2026-06-13T002736Z")
        let sightings = report.ticks.flatMap(\.aircraft).filter { $0.icao24 == "a1da83" }
        #expect(!sightings.isEmpty, "N21866 missing from fixture data")
        let allVisible = sightings.allSatisfy { $0.isVisible }
        #expect(allVisible, "N21866 (5.8 km @ 6°, GA fly-by) must never be hidden")
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
