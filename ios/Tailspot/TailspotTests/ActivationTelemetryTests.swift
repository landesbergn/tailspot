//
//  ActivationTelemetryTests.swift
//  TailspotTests
//
//  Activation-funnel telemetry (PLAN §9 #3): the pure builders and the
//  once-per-install latch semantics. Same pattern as CatchTelemetryTests —
//  pin the event vocabulary so a rename can't silently break the PostHog
//  funnel.
//

import CoreLocation
import Foundation
import Testing
@testable import Tailspot

@Suite("ActivationTelemetry")
struct ActivationTelemetryTests {

    // MARK: - Step naming

    @Test func stepNamesMatchTheShippedFlow() {
        // These strings are the PostHog funnel vocabulary — the dashboard
        // breaks if they drift from the OnboardingFlow step indexes.
        #expect(ActivationTelemetry.stepName(0) == "welcome")
        #expect(ActivationTelemetry.stepName(1) == "permissions")
        #expect(ActivationTelemetry.stepName(2) == "handle")
    }

    @Test func unknownStepsStillReportRatherThanVanish() {
        // A future 4th step must show up in the funnel even before anyone
        // names it here. (Index 3 was "calibration" until the step's
        // removal, 2026-08-13 — it must NOT report that name anymore.)
        #expect(ActivationTelemetry.stepName(3) == "step_3")
        #expect(ActivationTelemetry.stepName(4) == "step_4")
    }

    // MARK: - Builders

    @Test func stepViewedCarriesIndexAndName() {
        let p = ActivationTelemetry.stepViewedProperties(step: 1)
        #expect(p["step"]?.jsonValue as? Int == 1)
        #expect(p["step_name"]?.jsonValue as? String == "permissions")
    }

    @Test func permissionOutcomeCarriesPermissionAndGrant() {
        let p = ActivationTelemetry.permissionProperties(permission: "camera", granted: false)
        #expect(p["permission"]?.jsonValue as? String == "camera")
        #expect(p["granted"]?.jsonValue as? Bool == false)
    }

    @Test func completedCarriesClaimResult() {
        let p = ActivationTelemetry.completedProperties(claimResult: "offline_fallback")
        #expect(p["handle_claim"]?.jsonValue as? String == "offline_fallback")
        // The compass step is gone — completion must no longer report a
        // "calibrated" split (old events keep theirs; new ones are clean).
        #expect(p["calibrated"] == nil)
    }

    // MARK: - Once-per-install latches

    private func freshDefaults() throws -> UserDefaults {
        let suite = "activation-telemetry-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func arFirstFrameLatchesAfterOneFire() throws {
        let defaults = try freshDefaults()
        #expect(!defaults.bool(forKey: ActivationTelemetry.arFirstFrameFiredKey))
        ActivationTelemetry.fireARFirstFrameOnce(defaults: defaults)
        #expect(defaults.bool(forKey: ActivationTelemetry.arFirstFrameFiredKey))
        // Second call must be a no-op (the latch survives) — this runs on
        // the camera frame path, so idempotence is the load-bearing part.
        ActivationTelemetry.fireARFirstFrameOnce(defaults: defaults)
        #expect(defaults.bool(forKey: ActivationTelemetry.arFirstFrameFiredKey))
    }

    @Test func firstPlaneSeenLatchesAfterOneFire() throws {
        let defaults = try freshDefaults()
        ActivationTelemetry.fireFirstPlaneSeenOnce(visibleCount: 3, defaults: defaults)
        #expect(defaults.bool(forKey: ActivationTelemetry.firstPlaneSeenFiredKey))
    }

    @Test func latchKeysAreDistinctFromEachOtherAndFirstCatch() {
        // Independent milestones — a shared key would collapse the funnel
        // into one event.
        let keys = [
            ActivationTelemetry.arFirstFrameFiredKey,
            ActivationTelemetry.firstPlaneSeenFiredKey,
            ActivationTelemetry.firstLabelOnScreenFiredKey,
            ActivationTelemetry.firstLabelTapFiredKey,
            ActivationTelemetry.arFirstFrameAtKey,
            CatchTelemetry.firstCatchFiredKey,
        ]
        #expect(Set(keys).count == keys.count)
    }

    @Test func newEventNamesArePinnedFunnelVocabulary() {
        // PostHog funnel vocabulary: a rename silently orphans the funnel.
        #expect(ActivationTelemetry.firstLabelOnScreenEvent == "first_label_on_screen")
        #expect(ActivationTelemetry.firstLabelTapEvent == "first_label_tap")
        #expect(ActivationTelemetry.emptySkyStateShownEvent == "empty_sky_state_shown")
        #expect(ActivationTelemetry.permissionRecoveryShownEvent == "permission_recovery_shown")
        #expect(ActivationTelemetry.permissionRecoverySettingsTappedEvent == "permission_recovery_settings_tapped")
        #expect(ActivationTelemetry.EmptySkyVariant.allCases.map(\.rawValue) == ["scanning", "none-nearby", "n-nearby"])
    }

    // MARK: - first_label_on_screen / first_label_tap latches

    @Test func firstLabelOnScreenLatchesAfterOneFire() throws {
        let defaults = try freshDefaults()
        #expect(!ActivationTelemetry.firstLabelOnScreenFired(defaults: defaults))
        ActivationTelemetry.fireFirstLabelOnScreenOnce(
            headingAccuracyDeg: 12, visibleCount: 3, onScreenCount: 1, defaults: defaults)
        #expect(ActivationTelemetry.firstLabelOnScreenFired(defaults: defaults))
        // Idempotent: the 1 Hz hook calls it again next tick.
        ActivationTelemetry.fireFirstLabelOnScreenOnce(
            headingAccuracyDeg: 12, visibleCount: 3, onScreenCount: 2, defaults: defaults)
        #expect(ActivationTelemetry.firstLabelOnScreenFired(defaults: defaults))
    }

    @Test func firstLabelOnScreenDoesNotLatchWhenNothingIsInFrame() throws {
        // A plane in range but behind the user (on-screen count 0) is the
        // exact case first_plane_seen gets wrong; it must not spend the latch.
        let defaults = try freshDefaults()
        ActivationTelemetry.fireFirstLabelOnScreenOnce(
            headingAccuracyDeg: 12, visibleCount: 4, onScreenCount: 0, defaults: defaults)
        #expect(!ActivationTelemetry.firstLabelOnScreenFired(defaults: defaults))
    }

    @Test func firstLabelTapLatchesAfterOneFire() throws {
        let defaults = try freshDefaults()
        #expect(!defaults.bool(forKey: ActivationTelemetry.firstLabelTapFiredKey))
        ActivationTelemetry.fireFirstLabelTapOnce(
            via: "direct", headingAccuracyDeg: nil, visibleCount: 1, onScreenCount: 1, defaults: defaults)
        #expect(defaults.bool(forKey: ActivationTelemetry.firstLabelTapFiredKey))
        ActivationTelemetry.fireFirstLabelTapOnce(
            via: "widened", headingAccuracyDeg: nil, visibleCount: 1, onScreenCount: 1, defaults: defaults)
        #expect(defaults.bool(forKey: ActivationTelemetry.firstLabelTapFiredKey))
    }

    @Test func labelLatchesAreIndependentOfFirstPlaneSeen() throws {
        // first_plane_seen keeps its old meaning; latching it must not
        // pre-latch the new label milestones (or vice versa).
        let defaults = try freshDefaults()
        ActivationTelemetry.fireFirstPlaneSeenOnce(visibleCount: 2, defaults: defaults)
        #expect(!ActivationTelemetry.firstLabelOnScreenFired(defaults: defaults))
        #expect(!defaults.bool(forKey: ActivationTelemetry.firstLabelTapFiredKey))
    }

    // MARK: - seconds_since_ar_first_frame

    @Test func arFirstFrameStampsItsTimeOnce() throws {
        let defaults = try freshDefaults()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        ActivationTelemetry.fireARFirstFrameOnce(now: t0, defaults: defaults)
        let later = t0.addingTimeInterval(42)
        #expect(ActivationTelemetry.secondsSinceARFirstFrame(now: later, defaults: defaults) == 42)
        // A second frame (already latched) must not move the stamp.
        ActivationTelemetry.fireARFirstFrameOnce(now: later, defaults: defaults)
        #expect(ActivationTelemetry.secondsSinceARFirstFrame(now: later, defaults: defaults) == 42)
    }

    @Test func preStampInstallsReportNoElapsedTime() throws {
        // An install that latched ar_first_frame before the stamp existed:
        // the property must be absent, not a fake value. This is what lets
        // the funnel tell pre-1.2.3 installs apart.
        let defaults = try freshDefaults()
        defaults.set(true, forKey: ActivationTelemetry.arFirstFrameFiredKey)
        ActivationTelemetry.fireARFirstFrameOnce(defaults: defaults)
        #expect(ActivationTelemetry.secondsSinceARFirstFrame(defaults: defaults) == nil)
    }

    // MARK: - Label properties

    @Test func labelPropertiesCarryCountsAccuracyAndElapsed() {
        let p = ActivationTelemetry.labelProperties(
            headingAccuracyDeg: 17.5, secondsSinceARFirstFrame: 63.4,
            visibleCount: 5, onScreenCount: 2)
        #expect(p["visible_count"]?.jsonValue as? Int == 5)
        #expect(p["on_screen_count"]?.jsonValue as? Int == 2)
        #expect(p["heading_accuracy_deg"]?.jsonValue as? Double == 17.5)
        #expect(p["seconds_since_ar_first_frame"]?.jsonValue as? Double == 63)
    }

    @Test func labelPropertiesOmitUnknownsInsteadOfFaking() {
        // nil accuracy (no compass yet), a negative one (CoreLocation's
        // "invalid"), and a missing first-frame stamp are all left off.
        let none = ActivationTelemetry.labelProperties(
            headingAccuracyDeg: nil, secondsSinceARFirstFrame: nil, visibleCount: 1, onScreenCount: 1)
        #expect(none["heading_accuracy_deg"] == nil)
        #expect(none["seconds_since_ar_first_frame"] == nil)
        let invalid = ActivationTelemetry.labelProperties(
            headingAccuracyDeg: -1, secondsSinceARFirstFrame: nil, visibleCount: 1, onScreenCount: 1)
        #expect(invalid["heading_accuracy_deg"] == nil)
    }

    // MARK: - On-screen projection

    /// Facing due north, camera tilted 30° up, upright.
    private let northUp30 = Geo.cameraBasis(headingDeg: 0, cameraElevationDeg: 30, rollDeg: 0)

    @Test func planeInFrameCountsOne() {
        let n = ActivationTelemetry.onScreenCount(
            targets: [(bearingDeg: 5, elevationDeg: 28)],
            basis: northUp30, hfovDeg: 56, vfovDeg: 72)
        #expect(n == 1)
    }

    @Test func planeBehindTheUserCountsZero() {
        // In range (it would pass the visibility filter), but due south while
        // the camera faces north: no label is drawn.
        let n = ActivationTelemetry.onScreenCount(
            targets: [(bearingDeg: 180, elevationDeg: 28)],
            basis: northUp30, hfovDeg: 56, vfovDeg: 72)
        #expect(n == 0)
    }

    @Test func planeJustOutsideTheFieldOfViewCountsZero() {
        // 40° to the right is past the 28° half-HFOV.
        let n = ActivationTelemetry.onScreenCount(
            targets: [(bearingDeg: 40, elevationDeg: 30)],
            basis: northUp30, hfovDeg: 56, vfovDeg: 72)
        #expect(n == 0)
    }

    @Test func zoomNarrowsWhatCountsAsOnScreen() {
        // 20° off-axis is in frame at 1× (half-HFOV 28°) but not at 2×
        // (half-HFOV 14°) — the caller divides the FOV by zoom like the
        // label loop does.
        let target = [(bearingDeg: 20.0, elevationDeg: 30.0)]
        #expect(ActivationTelemetry.onScreenCount(
            targets: target, basis: northUp30, hfovDeg: 56, vfovDeg: 72) == 1)
        #expect(ActivationTelemetry.onScreenCount(
            targets: target, basis: northUp30, hfovDeg: 28, vfovDeg: 36) == 0)
    }

    @Test func mixedSkyCountsOnlyTheFramedPlanes() {
        let n = ActivationTelemetry.onScreenCount(
            targets: [
                (bearingDeg: 0, elevationDeg: 30),     // dead centre
                (bearingDeg: 350, elevationDeg: 20),   // in frame, left-low
                (bearingDeg: 180, elevationDeg: 30),   // behind
                (bearingDeg: 90, elevationDeg: 10),    // off to the right
            ],
            basis: northUp30, hfovDeg: 56, vfovDeg: 72)
        #expect(n == 2)
    }

    @Test func onScreenCountMatchesTheRenderersFrustumAtRealScreenSize() {
        // The helper projects onto a unit size; the label loop projects onto
        // the AR view's real size. The in/out decision must be identical.
        let size = CGSize(width: 402, height: 874)
        for bearing in stride(from: 0.0, to: 360, by: 7) {
            for elevation in stride(from: -10.0, through: 89, by: 6) {
                let rendered = Geo.screenPosition(
                    targetBearingDeg: bearing, targetElevationDeg: elevation,
                    basis: northUp30, screenSize: size, hfovDeg: 56, vfovDeg: 72) != nil
                let counted = ActivationTelemetry.onScreenCount(
                    targets: [(bearingDeg: bearing, elevationDeg: elevation)],
                    basis: northUp30, hfovDeg: 56, vfovDeg: 72) == 1
                #expect(rendered == counted, "bearing \(bearing) elevation \(elevation)")
            }
        }
    }

    // MARK: - empty_sky_state_shown

    private func variant(
        visible: Int = 0, raw: Int = 0, error: Bool = false, neverFetched: Bool = false,
        reconnecting: Bool = false, suppressed: Bool = false
    ) -> ActivationTelemetry.EmptySkyVariant? {
        ActivationTelemetry.emptySkyVariant(
            visibleCount: visible, rawCount: raw, hasError: error,
            neverFetched: neverFetched, isReconnecting: reconnecting, labelsSuppressed: suppressed)
    }

    @Test func emptySkyVariantMirrorsThePillText() {
        #expect(variant(neverFetched: true) == .scanning)
        #expect(variant(raw: 0) == .noneNearby)
        #expect(variant(raw: 7) == .nNearby)
    }

    @Test func emptySkyVariantSkipsStatesOtherEventsCover() {
        // Planes visible → no empty-sky overlay at all.
        #expect(variant(visible: 1, raw: 3) == nil)
        // Feed error → adsb_fetch_error_shown already covers it, even before
        // the first fetch (the pill shows the error then, not SCANNING).
        #expect(variant(raw: 3, error: true) == nil)
        #expect(variant(error: true, neverFetched: true) == nil)
        // Whole-frame suppression → indoor_hint_shown covers it.
        #expect(variant(raw: 3, suppressed: true) == nil)
        // Brief RECONNECTING… state isn't one of the three variants.
        #expect(variant(raw: 3, reconnecting: true) == nil)
    }

    @Test func emptySkyReportsOncePerVariantPerSession() {
        var reported: Set<ActivationTelemetry.EmptySkyVariant> = []
        #expect(ActivationTelemetry.shouldReportEmptySky(.nNearby, alreadyReported: reported, secondsInSession: 30))
        reported.insert(.nNearby)
        #expect(!ActivationTelemetry.shouldReportEmptySky(.nNearby, alreadyReported: reported, secondsInSession: 90))
        // A different state later in the same session still reports.
        #expect(ActivationTelemetry.shouldReportEmptySky(.noneNearby, alreadyReported: reported, secondsInSession: 90))
    }

    @Test func scanningOnlyReportsOnceItLooksStuck() {
        // Every launch shows SCANNING for a moment; only a lingering one counts.
        #expect(!ActivationTelemetry.shouldReportEmptySky(.scanning, alreadyReported: [], secondsInSession: 0))
        #expect(!ActivationTelemetry.shouldReportEmptySky(.scanning, alreadyReported: [], secondsInSession: 4.9))
        #expect(ActivationTelemetry.shouldReportEmptySky(
            .scanning, alreadyReported: [], secondsInSession: ActivationTelemetry.scanningReportAfterSeconds))
        #expect(!ActivationTelemetry.shouldReportEmptySky(.scanning, alreadyReported: [.scanning], secondsInSession: 60))
    }

    @Test func emptySkyPropertiesCarryVariantCountAndNearest() {
        let p = ActivationTelemetry.emptySkyProperties(
            variant: .nNearby, rawCount: 6, nearestSlantMeters: 31_449, secondsInSession: 12.6,
            hasLocation: true)
        #expect(p["variant"]?.jsonValue as? String == "n-nearby")
        #expect(p["has_location"]?.jsonValue as? Bool == true)
        #expect(p["raw_count"]?.jsonValue as? Int == 6)
        #expect(p["nearest_slant_km"]?.jsonValue as? Double == 31.4)
        #expect(p["seconds_in_session"]?.jsonValue as? Double == 13)
        let empty = ActivationTelemetry.emptySkyProperties(
            variant: .noneNearby, rawCount: 0, nearestSlantMeters: nil, secondsInSession: 3,
            hasLocation: true)
        #expect(empty["nearest_slant_km"] == nil)
    }

    @Test func stuckScanningSaysWhetherThereIsAFix() {
        // The no-fix case is the common stuck-SCANNING cause; the property
        // must be present (false), not left off, so the funnel can split on it.
        let p = ActivationTelemetry.emptySkyProperties(
            variant: .scanning, rawCount: 0, nearestSlantMeters: nil, secondsInSession: 30,
            hasLocation: false)
        #expect(p["variant"]?.jsonValue as? String == "scanning")
        #expect(p["has_location"]?.jsonValue as? Bool == false)
    }

    // MARK: - Permission recovery + location accuracy

    @Test func permissionRecoveryCarriesWhichPermissionsAreDenied() {
        let p = ActivationTelemetry.permissionRecoveryProperties(cameraDenied: false, locationDenied: true)
        #expect(p["camera_denied"]?.jsonValue as? Bool == false)
        #expect(p["location_denied"]?.jsonValue as? Bool == true)
    }

    @Test func locationOutcomeCarriesAccuracyOnlyWhenGiven() {
        let precise = ActivationTelemetry.permissionProperties(
            permission: "location", granted: true, locationAccuracy: "approximate")
        #expect(precise["location_accuracy"]?.jsonValue as? String == "approximate")
        // Camera outcomes and denials carry no accuracy property.
        let camera = ActivationTelemetry.permissionProperties(permission: "camera", granted: true)
        #expect(camera["location_accuracy"] == nil)
    }

    @Test func locationAccuracyNames() {
        #expect(ActivationTelemetry.locationAccuracyName(.fullAccuracy) == "precise")
        #expect(ActivationTelemetry.locationAccuracyName(.reducedAccuracy) == "approximate")
    }
}
