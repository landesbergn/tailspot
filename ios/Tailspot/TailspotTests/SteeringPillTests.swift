//
//  SteeringPillTests.swift
//  TailspotTests
//
//  The first-catch steering pill's pure rules: bearing -> direction (with
//  the 0/360 wrap), who is eligible, the compass gate, the order the gates
//  apply in, target hysteresis, the copy, and the telemetry vocabulary.
//

import Foundation
import Testing
@testable import Tailspot

@Suite("SteeringPill")
struct SteeringPillTests {

    private static let hfov: Double = 56   // ContentView.baseHfovDeg at 1x

    private func dir(_ heading: Double, _ bearing: Double, hfov: Double = hfov) -> SteeringDirection {
        SteeringPill.direction(headingDeg: heading, targetBearingDeg: bearing, hfovDeg: hfov)
    }

    // MARK: - Direction mapping

    @Test func signedDeltaWrapsTheShortWay() {
        #expect(SteeringPill.signedDelta(fromDeg: 350, toDeg: 10) == 20)
        #expect(SteeringPill.signedDelta(fromDeg: 10, toDeg: 350) == -20)
        #expect(SteeringPill.signedDelta(fromDeg: 0, toDeg: 180) == 180)
        #expect(SteeringPill.signedDelta(fromDeg: 90, toDeg: 90) == 0)
        // Out-of-range inputs (a bearing of 370, a heading of -10) still land
        // in -180...180.
        #expect(SteeringPill.signedDelta(fromDeg: -10, toDeg: 370) == 20)
        #expect(SteeringPill.signedDelta(fromDeg: 720, toDeg: 0) == 0)
    }

    @Test func leftAndRightFollowTheShortestTurn() {
        #expect(dir(0, 90) == .right)
        #expect(dir(0, 270) == .left)
        #expect(dir(90, 0) == .left)
        #expect(dir(270, 0) == .right)
    }

    @Test func leftAndRightAcrossNorth() {
        // Facing 350, plane at 60: 70 degrees clockwise -> right, not a
        // 290-degree left.
        #expect(dir(350, 60) == .right)
        // Facing 20, plane at 300: 80 degrees counter-clockwise -> left.
        #expect(dir(20, 300) == .left)
    }

    @Test func aheadMeansInsideTheHorizontalFieldOfView() {
        #expect(dir(0, 0) == .ahead)
        #expect(dir(355, 20) == .ahead)        // +25, inside the 28 half-FOV
        #expect(dir(5, 340) == .ahead)         // -25 across north
        #expect(dir(0, 28) == .ahead)          // exactly at the edge
        #expect(dir(0, 29) == .right)
        // Zoomed 2x the field narrows to 28, so the same plane is a turn.
        #expect(dir(0, 20, hfov: 28) == .right)
    }

    @Test func behindFromOneThirtyFiveEitherWay() {
        #expect(dir(0, 180) == .behind)
        #expect(dir(0, 135) == .behind)
        #expect(dir(0, 225) == .behind)
        #expect(dir(0, 134) == .right)
        #expect(dir(0, 226) == .left)
        // Across north: facing 10, plane at 170 is 160 clockwise.
        #expect(dir(10, 170) == .behind)
        #expect(dir(200, 30) == .behind)
    }

    // MARK: - Eligibility

    @Test func onlyZeroCatchUsersWhoHaventRetired() {
        #expect(SteeringPill.isEligible(catchCount: 0, retired: false))
        #expect(!SteeringPill.isEligible(catchCount: 1, retired: false))
        #expect(!SteeringPill.isEligible(catchCount: 40, retired: true))
        // Deleting the only catch doesn't bring it back.
        #expect(!SteeringPill.isEligible(catchCount: 0, retired: true))
    }

    @Test func debugOverrideMakesAVeteranEligible() {
        // The wrench override: a phone with a real Hangar, already retired,
        // still gets the pill so Noah can field-test it.
        #expect(SteeringPill.isEligible(catchCount: 40, retired: true, debugForced: true))
        #expect(SteeringPill.isEligible(catchCount: 0, retired: false, debugForced: true))
        // Off is exactly the production rule.
        #expect(!SteeringPill.isEligible(catchCount: 40, retired: true, debugForced: false))
        #expect(SteeringPill.isEligible(catchCount: 0, retired: false, debugForced: false))
        // Distinct from the retired key, so flipping it never touches the latch.
        #expect(SteeringPill.debugForceKey != SteeringPill.retiredKey)
    }

    @Test func caughtNeedsACatchDatedAfterTheShow() {
        let shown = Date(timeIntervalSince1970: 1_000_000)
        // A real first catch after the pill showed.
        #expect(SteeringPill.shouldFireCaught(
            shownAt: shown, catchDates: [shown.addingTimeInterval(42)]))
        // A Hangar restore into a zero-catch reinstall: old catches only.
        #expect(!SteeringPill.shouldFireCaught(
            shownAt: shown,
            catchDates: [shown.addingTimeInterval(-86_400), shown.addingTimeInterval(-60)]))
        // Restore plus a fresh catch still counts.
        #expect(SteeringPill.shouldFireCaught(
            shownAt: shown,
            catchDates: [shown.addingTimeInterval(-86_400), shown.addingTimeInterval(5)]))
        // Pill never showed this session.
        #expect(!SteeringPill.shouldFireCaught(shownAt: nil, catchDates: [shown]))
    }

    @Test func retiredKeyIsStable() {
        // Renaming the key would re-arm the pill for every veteran.
        #expect(SteeringPill.retiredKey == "tailspot.steering.retired")
    }

    // MARK: - Compass gate

    @Test func compassGate() {
        func ok(_ h: Double?, _ a: Double?, latched: Bool = false) -> Bool {
            SteeringPill.isCompassReliable(headingDeg: h, headingAccuracyDeg: a, cautionLatched: latched)
        }
        #expect(ok(120, 8))
        #expect(ok(120, 25))                    // the banner's arm line is still trusted
        #expect(!ok(120, 25.1))
        #expect(!ok(120, 60))
        #expect(!ok(nil, 8))                    // no heading fix yet
        #expect(!ok(120, nil))                  // accuracy unknown
        #expect(!ok(120, -1))                   // CoreLocation's "invalid"
        // The caution banner is up (it clears only under 15): don't steer
        // while the app is telling the user their compass is off.
        #expect(!ok(120, 18, latched: true))
        #expect(!ok(120, 5, latched: true))
    }

    // MARK: - The decision

    private let behindPlane = SteeringTarget(
        icao24: "abc123", bearingDeg: 180, elevationDeg: 20, slantDistanceMeters: 4_200
    )

    private func hint(
        eligible: Bool = true,
        error: Bool = false,
        compass: Bool = true,
        candidates: [SteeringTarget]? = nil,
        current: String? = nil,
        heading: Double = 0,
        camEl: Double = 15
    ) -> SteeringHint? {
        SteeringPill.hint(
            eligible: eligible,
            hasFeedError: error,
            compassReliable: compass,
            candidates: candidates ?? [behindPlane],
            currentTargetIcao24: current,
            headingDeg: heading,
            cameraElevationDeg: camEl,
            rollDeg: 0,
            hfovDeg: 56,
            vfovDeg: 72
        )
    }

    @Test func showsForAnOffScreenPlane() throws {
        let h = try #require(hint())
        #expect(h.icao24 == "abc123")
        #expect(h.direction == .behind)
        #expect(h.distanceMeters == 4_200)
    }

    @Test func eachGateHidesIt() {
        #expect(hint(eligible: false) == nil)
        #expect(hint(error: true) == nil)
        #expect(hint(compass: false) == nil)
        #expect(hint(candidates: []) == nil)
    }

    @Test func hiddenWhenAnyLabelIsOnScreen() {
        // A second plane dead ahead at the camera's elevation projects on
        // screen: the user already has a label to aim at.
        let ahead = SteeringTarget(icao24: "def456", bearingDeg: 2, elevationDeg: 15, slantDistanceMeters: 20_000)
        #expect(hint(candidates: [behindPlane, ahead]) == nil)
    }

    @Test func aheadButOffTheTopSaysTiltUp() throws {
        // Bearing dead ahead but 60 degrees above a camera held level: off
        // the top of a 72-degree vertical field.
        let high = SteeringTarget(icao24: "aaa111", bearingDeg: 0, elevationDeg: 60, slantDistanceMeters: 3_000)
        let h = try #require(hint(candidates: [high], camEl: 0))
        #expect(h.direction == .ahead)
        #expect(SteeringPill.directionText(h) == "TILT UP")
        // Camera tipped up at 80 with the plane low ahead: tilt down.
        let low = SteeringTarget(icao24: "aaa222", bearingDeg: 0, elevationDeg: 5, slantDistanceMeters: 3_000)
        let d = try #require(hint(candidates: [low], camEl: 80))
        #expect(SteeringPill.directionText(d) == "TILT DOWN")
    }

    @Test func picksTheNearestWithHysteresis() {
        let a = SteeringTarget(icao24: "a", bearingDeg: 90, elevationDeg: 10, slantDistanceMeters: 10_000)
        let b = SteeringTarget(icao24: "b", bearingDeg: 270, elevationDeg: 10, slantDistanceMeters: 9_000)
        let c = SteeringTarget(icao24: "c", bearingDeg: 270, elevationDeg: 10, slantDistanceMeters: 7_000)
        // No current target: nearest wins.
        #expect(SteeringPill.pickTarget(current: nil, candidates: [a, b])?.icao24 == "b")
        // Holding a: b is only 10% closer, so the arrow doesn't flip.
        #expect(SteeringPill.pickTarget(current: "a", candidates: [a, b])?.icao24 == "a")
        // c is 30% closer than a: switch.
        #expect(SteeringPill.pickTarget(current: "a", candidates: [a, c])?.icao24 == "c")
        // The held plane left the set: fall back to nearest.
        #expect(SteeringPill.pickTarget(current: "gone", candidates: [a, b])?.icao24 == "b")
        #expect(SteeringPill.pickTarget(current: "a", candidates: []) == nil)
    }

    // MARK: - Copy

    @Test func distanceCopyInTheUsersUnits() {
        #expect(SteeringPill.distanceText(meters: 4_200, unit: .kilometers) == "4 KM")
        #expect(SteeringPill.distanceText(meters: 12_600, unit: .kilometers) == "13 KM")
        #expect(SteeringPill.distanceText(meters: 1_430, unit: .kilometers) == "1.4 KM")
        #expect(SteeringPill.distanceText(meters: 600, unit: .kilometers) == "<1 KM")
        #expect(SteeringPill.distanceText(meters: 6_437, unit: .miles) == "4 MI")
        #expect(SteeringPill.distanceText(meters: 800, unit: .miles) == "<1 MI")
    }

    @Test func fullPillCopy() {
        // Compare with plain spaces; the non-breaking ones are checked below.
        func text(_ h: SteeringHint, unit: DistanceUnit) -> String {
            SteeringPill.text(h, unit: unit).replacingOccurrences(of: "\u{00A0}", with: " ")
        }
        let left = SteeringHint(icao24: "x", direction: .left, elevationDeltaDeg: 5, distanceMeters: 4_000)
        #expect(text(left, unit: .kilometers) == "PLANE IN RANGE · TURN LEFT · 4 KM")
        let right = SteeringHint(icao24: "x", direction: .right, elevationDeltaDeg: 5, distanceMeters: 4_000)
        #expect(text(right, unit: .kilometers) == "PLANE IN RANGE · TURN RIGHT · 4 KM")
        let behind = SteeringHint(icao24: "x", direction: .behind, elevationDeltaDeg: 5, distanceMeters: 9_656)
        #expect(text(behind, unit: .miles) == "PLANE IN RANGE · BEHIND YOU · 6 MI")
    }

    @Test func wrapsOnlyAtTheSeparators() {
        let h = SteeringHint(icao24: "x", direction: .behind, elevationDeltaDeg: 0, distanceMeters: 4_000)
        let t = SteeringPill.text(h, unit: .kilometers)
        // The only breakable spaces are the two around each "·".
        #expect(t.split(separator: " ").count == 5)
        #expect(t.contains("BEHIND\u{00A0}YOU"))
        #expect(t.contains("4\u{00A0}KM"))
    }

    // MARK: - Telemetry

    @Test func eventNamesArePinned() {
        #expect(SteeringPill.shownEvent == "steering_pill_shown")
        #expect(SteeringPill.caughtEvent == "steering_pill_caught")
        #expect(SteeringDirection.allCases.map(\.rawValue) == ["ahead", "left", "right", "behind"])
    }

    @Test func distanceBuckets() {
        #expect(SteeringPill.distanceBucket(meters: 1_999) == "<2km")
        #expect(SteeringPill.distanceBucket(meters: 2_000) == "2-5km")
        #expect(SteeringPill.distanceBucket(meters: 7_000) == "5-10km")
        #expect(SteeringPill.distanceBucket(meters: 15_000) == "10-20km")
        #expect(SteeringPill.distanceBucket(meters: 34_000) == "20km+")
    }

    @Test func shownPropertiesCarryDirectionBucketAndAccuracy() {
        let h = SteeringHint(icao24: "x", direction: .behind, elevationDeltaDeg: 0, distanceMeters: 4_200)
        let p = SteeringPill.shownProperties(h, headingAccuracyDeg: 12)
        #expect(p["direction"]?.jsonValue as? String == "behind")
        #expect(p["distance_bucket"]?.jsonValue as? String == "2-5km")
        #expect(p["heading_accuracy_deg"]?.jsonValue as? Double == 12)
        // No icao24 or raw distance: the event is about the nudge, not the plane.
        #expect(p["icao24"] == nil)
        // Invalid accuracy is left off, not sent as a fake value.
        #expect(SteeringPill.shownProperties(h, headingAccuracyDeg: -1)["heading_accuracy_deg"] == nil)
    }
}
