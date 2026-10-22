//
//  ActivationTelemetry.swift
//  Tailspot
//
//  Activation-funnel analytics for the onboarding re-do (PLAN §9 #3).
//  The measured leak is ~36 openers → 5 catchers/30d, but the funnel is
//  blind between the SDK's "Application Opened" and `first_plane_catch` —
//  nothing records which onboarding step users abandon, whether they
//  denied a permission, whether the camera ever produced a frame, or
//  whether they ever SAW a plane label. These events light that up, so
//  the redesign's effect is measurable instead of vibes.
//
//  Same shape as CatchTelemetry: pure property builders unit tests can
//  pin, thin fire wrappers over `Analytics.capture`, and once-per-install
//  UserDefaults latches for the milestone events (mirroring
//  `first_plane_catch` — a reinstall wipes Hangar and latches together).
//
//  Funnel, in order:
//    Application Opened (SDK autocapture)
//      → onboarding_step_viewed (welcome / permissions / handle)
//      → permission_outcome (camera / location, granted?, location_accuracy)
//      → onboarding_completed (claim result)
//      → ar_first_frame        [once per install]
//      → first_plane_seen      [once per install] (a plane in RANGE, any direction)
//      → first_label_on_screen [once per install] (a label actually drawn in frame)
//      → first_label_tap       [once per install] (the user pinned a label)
//      → first_plane_catch     (CatchTelemetry)
//  Plus the compass triad (caution shown / sheet opened / calibrated) —
//  the suspected silent killer of "saw a label but it pointed wrong" —
//  and two dead-end detectors: empty_sky_state_shown (what the empty-sky
//  pill said, once per variant per session) and the permission recovery
//  card pair (shown / Open Settings tapped).
//
//  empty_sky_state_shown is driven by ContentView's 1 Hz timer loop, not by
//  the ADS-B publish: with no GPS fix the feed never publishes, and that is
//  the most common way to be stuck on SCANNING SKY. `has_location` splits
//  "no fix yet" from "fix, but the feed is slow or failing".
//
//  Reading the label milestones: they shipped in 1.2.3. Installs from before
//  then had already latched ar_first_frame without a timestamp, so they fire
//  the new events once after updating, WITHOUT `seconds_since_ar_first_frame`.
//  A first-run funnel should keep only events that carry that property.
//

import CoreLocation
import Foundation

nonisolated enum ActivationTelemetry {

    static let stepViewedEvent = "onboarding_step_viewed"
    static let completedEvent = "onboarding_completed"
    static let permissionOutcomeEvent = "permission_outcome"
    static let arFirstFrameEvent = "ar_first_frame"
    static let firstPlaneSeenEvent = "first_plane_seen"
    static let firstLabelOnScreenEvent = "first_label_on_screen"
    static let firstLabelTapEvent = "first_label_tap"
    static let emptySkyStateShownEvent = "empty_sky_state_shown"
    static let permissionRecoveryShownEvent = "permission_recovery_shown"
    static let permissionRecoverySettingsTappedEvent = "permission_recovery_settings_tapped"
    static let compassCautionEvent = "compass_caution_shown"
    static let compassSheetOpenedEvent = "compass_sheet_opened"
    static let compassCalibratedEvent = "compass_calibrated"

    static let arFirstFrameFiredKey = "tailspot.telemetry.arFirstFrameFired"
    static let firstPlaneSeenFiredKey = "tailspot.telemetry.firstPlaneSeenFired"
    static let firstLabelOnScreenFiredKey = "tailspot.telemetry.firstLabelOnScreenFired"
    static let firstLabelTapFiredKey = "tailspot.telemetry.firstLabelTapFired"
    /// Wall-clock time (seconds since 1970) of the first camera frame ever,
    /// stamped together with the `ar_first_frame` latch. Absent on installs
    /// that latched before 1.2.3 (see the header note).
    static let arFirstFrameAtKey = "tailspot.telemetry.arFirstFrameAt"

    // MARK: - Pure builders (unit-tested)

    /// Stable analytics name for an onboarding step index. Indexes match
    /// `OnboardingFlow.step`; anything past the known steps reports the
    /// index so a future 4th step can't silently vanish from the funnel.
    /// ("calibration" was step 3 until 2026-08-13 — historical funnel data
    /// carries it; the step is gone from the flow.)
    static func stepName(_ step: Int) -> String {
        switch step {
        case 0: return "welcome"
        case 1: return "permissions"
        case 2: return "handle"
        default: return "step_\(step)"
        }
    }

    static func stepViewedProperties(step: Int) -> [String: AnalyticsValue] {
        [
            "step": .int(step),
            "step_name": .string(stepName(step)),
        ]
    }

    /// `locationAccuracy` is "precise" or "approximate". It only means
    /// something for a granted location prompt, so callers pass nil
    /// otherwise and the property is left off.
    static func permissionProperties(
        permission: String,
        granted: Bool,
        locationAccuracy: String? = nil
    ) -> [String: AnalyticsValue] {
        var props: [String: AnalyticsValue] = [
            "permission": .string(permission),
            "granted": .bool(granted),
        ]
        if let locationAccuracy { props["location_accuracy"] = .string(locationAccuracy) }
        return props
    }

    /// Analytics name for iOS's Precise Location switch. Approximate
    /// location blurs the fix by kilometres, which throws off the bearing
    /// to a nearby plane, so this split matters when diagnosing "never saw
    /// a label".
    static func locationAccuracyName(_ accuracy: CLAccuracyAuthorization) -> String {
        switch accuracy {
        case .fullAccuracy: return "precise"
        case .reducedAccuracy: return "approximate"
        @unknown default: return "unknown"
        }
    }

    static func completedProperties(claimResult: String) -> [String: AnalyticsValue] {
        // "calibrated" rode along here while onboarding had a compass step
        // (removed 2026-08-13) — old events carry it, new ones don't.
        [
            "handle_claim": .string(claimResult),
        ]
    }

    // MARK: - Label milestones (pure parts)

    /// How many of `targets` (bearing/elevation in degrees) project INSIDE
    /// the camera frame for this pose. It is the same frustum test the label
    /// renderer uses (`Geo.screenPosition` returns nil outside it), so a
    /// count above 0 means a label was actually drawn, not just in range.
    ///
    /// The test doesn't depend on the screen's size in points: the
    /// projection normalises against the half-FOV tangents before scaling.
    /// So a unit size is used, and callers outside the AR view's
    /// GeometryReader don't need its size.
    static func onScreenCount(
        targets: [(bearingDeg: Double, elevationDeg: Double)],
        basis: Geo.CameraBasis,
        hfovDeg: Double,
        vfovDeg: Double
    ) -> Int {
        let unit = CGSize(width: 1, height: 1)
        return targets.count { t in
            Geo.screenPosition(
                targetBearingDeg: t.bearingDeg,
                targetElevationDeg: t.elevationDeg,
                basis: basis,
                screenSize: unit,
                hfovDeg: hfovDeg,
                vfovDeg: vfovDeg
            ) != nil
        }
    }

    /// `onScreenCount` for a raw pose. Returns nil while the compass has no
    /// heading yet: the label renderer falls back to heading 0 then, so a
    /// count would be measured against a made-up direction. The 1 Hz
    /// caller treats nil as "can't tell yet" and doesn't latch.
    static func onScreenCount(
        targets: [(bearingDeg: Double, elevationDeg: Double)],
        headingDeg: Double?,
        cameraElevationDeg: Double,
        rollDeg: Double,
        hfovDeg: Double,
        vfovDeg: Double
    ) -> Int? {
        guard let headingDeg else { return nil }
        let basis = Geo.cameraBasis(
            headingDeg: headingDeg, cameraElevationDeg: cameraElevationDeg, rollDeg: rollDeg
        )
        return onScreenCount(targets: targets, basis: basis, hfovDeg: hfovDeg, vfovDeg: vfovDeg)
    }

    /// Seconds since this install's first camera frame, or nil when the
    /// stamp is missing (an install that latched before 1.2.3).
    static func secondsSinceARFirstFrame(
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> Double? {
        guard let at = defaults.object(forKey: arFirstFrameAtKey) as? Double else { return nil }
        return max(0, now.timeIntervalSince1970 - at)
    }

    /// Properties shared by both label milestones. Heading accuracy and the
    /// time since the first frame are left off when unknown (no compass fix
    /// yet, or a pre-1.2.3 install) instead of being sent as a fake 0. The
    /// on-screen count is left off too when there was no heading to
    /// measure it against.
    static func labelProperties(
        headingAccuracyDeg: Double?,
        secondsSinceARFirstFrame: Double?,
        visibleCount: Int,
        onScreenCount: Int?
    ) -> [String: AnalyticsValue] {
        var props: [String: AnalyticsValue] = [
            "visible_count": .int(visibleCount),
        ]
        if let onScreenCount { props["on_screen_count"] = .int(onScreenCount) }
        // CoreLocation reports a negative accuracy for an invalid heading.
        if let a = headingAccuracyDeg, a >= 0 { props["heading_accuracy_deg"] = .double(a) }
        if let s = secondsSinceARFirstFrame { props["seconds_since_ar_first_frame"] = .double(s.rounded()) }
        return props
    }

    // MARK: - Empty-sky state (pure parts)

    /// What the empty-sky status pill is telling the user. Only the states
    /// no other event covers: a feed error already fires
    /// `adsb_fetch_error_shown`, and whole-frame label suppression fires
    /// `indoor_hint_shown`, so those (and the brief "RECONNECTING…" state)
    /// make `emptySkyVariant` return nil.
    enum EmptySkyVariant: String, CaseIterable, Sendable {
        /// "SCANNING SKY…": no successful feed fetch yet.
        case scanning
        /// "NO AIRCRAFT NEARBY": the feed answered with no airborne traffic.
        case noneNearby = "none-nearby"
        /// "NO AIRCRAFT IN VIEW · N NEARBY": traffic exists, but none passes
        /// the visibility filter (below the horizon or too far).
        case nNearby = "n-nearby"
    }

    /// Follows the branch order of `ContentView.emptySkyOverlay`'s pill text
    /// so the event reports what the pill said. nil when the overlay isn't
    /// showing (a plane is visible) or the state is covered by another event.
    static func emptySkyVariant(
        visibleCount: Int,
        rawCount: Int,
        hasError: Bool,
        neverFetched: Bool,
        isReconnecting: Bool,
        labelsSuppressed: Bool
    ) -> EmptySkyVariant? {
        guard visibleCount == 0, !hasError, !labelsSuppressed else { return nil }
        if neverFetched { return .scanning }
        if isReconnecting { return nil }
        return rawCount > 0 ? .nNearby : .noneNearby
    }

    /// "SCANNING SKY…" shows for a moment at every launch, so it only counts
    /// once the session is this old: the signal we want is "stuck scanning",
    /// not "the app just started".
    static let scanningReportAfterSeconds: Double = 5

    /// Once per variant per session. The `alreadyReported` set lives in the
    /// view as `@State`, so a relaunch starts fresh.
    static func shouldReportEmptySky(
        _ variant: EmptySkyVariant,
        alreadyReported: Set<EmptySkyVariant>,
        secondsInSession: Double
    ) -> Bool {
        guard !alreadyReported.contains(variant) else { return false }
        if variant == .scanning { return secondsInSession >= scanningReportAfterSeconds }
        return true
    }

    /// Per-session state for `empty_sky_state_shown`: when the session
    /// started and which variants it has reported. ContentView holds one as
    /// `@State` and resets it when the app goes to the background, so a
    /// return from the background is a new session (fresh variants, and
    /// `seconds_in_session` doesn't count time spent in the background).
    struct EmptySkySession: Equatable, Sendable {
        private(set) var start: Date?
        private(set) var reported: Set<EmptySkyVariant> = []

        /// Every variant has been reported, so the 1 Hz tick can stop work.
        var isComplete: Bool { reported.count == EmptySkyVariant.allCases.count }

        /// Seconds since the session started, starting it at `now` on the
        /// first call.
        mutating func secondsInSession(now: Date) -> Double {
            if start == nil { start = now }
            return now.timeIntervalSince(start ?? now)
        }

        /// True (and records the variant) when `variant` should report now.
        mutating func claim(_ variant: EmptySkyVariant, now: Date) -> Bool {
            let seconds = secondsInSession(now: now)
            guard shouldReportEmptySky(variant, alreadyReported: reported, secondsInSession: seconds) else {
                return false
            }
            reported.insert(variant)
            return true
        }

        mutating func reset() { self = EmptySkySession() }
    }

    /// `permission_recovery_shown` fires when the recovery card goes from
    /// hidden to showing, once per transition. It's driven from ContentView's
    /// state, not the card's `.onAppear`, so remounts and snapshot harnesses
    /// don't re-fire it.
    static func recoveryCardBecameVisible(wasShowing: Bool, isShowing: Bool) -> Bool {
        isShowing && !wasShowing
    }

    static func emptySkyProperties(
        variant: EmptySkyVariant,
        rawCount: Int,
        nearestSlantMeters: Double?,
        secondsInSession: Double,
        hasLocation: Bool
    ) -> [String: AnalyticsValue] {
        var props: [String: AnalyticsValue] = [
            "variant": .string(variant.rawValue),
            "raw_count": .int(rawCount),
            "seconds_in_session": .double(secondsInSession.rounded()),
            // false = no GPS fix yet, so the feed can't even be asked.
            "has_location": .bool(hasLocation),
        ]
        if let m = nearestSlantMeters {
            // One decimal place of km keeps the value easy to bucket.
            props["nearest_slant_km"] = .double((m / 100).rounded() / 10)
        }
        return props
    }

    static func permissionRecoveryProperties(cameraDenied: Bool, locationDenied: Bool) -> [String: AnalyticsValue] {
        [
            "camera_denied": .bool(cameraDenied),
            "location_denied": .bool(locationDenied),
        ]
    }

    // MARK: - Fire wrappers

    static func fireStepViewed(step: Int) {
        Analytics.capture(stepViewedEvent, stepViewedProperties(step: step))
    }

    /// `claimResult`: "success" (backend accepted the handle) or
    /// "offline_fallback" (claim failed non-409; handle persisted locally,
    /// retried later by HandleSyncer). A 409 keeps the user on the handle
    /// step, so it never reaches completion — `handle_claimed` records it.
    static func fireCompleted(claimResult: String) {
        Analytics.capture(completedEvent, completedProperties(claimResult: claimResult))
    }

    static func firePermissionOutcome(permission: String, granted: Bool, locationAccuracy: String? = nil) {
        Analytics.capture(permissionOutcomeEvent, permissionProperties(
            permission: permission, granted: granted, locationAccuracy: locationAccuracy
        ))
    }

    /// The camera produced its first frame ever — the user reached a live
    /// AR view. Once per install (latch), like `first_plane_catch`. Also
    /// stamps the time, so the label milestones can say how long the user
    /// had the camera up before a label appeared or before they tapped one.
    static func fireARFirstFrameOnce(now: Date = Date(), defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: arFirstFrameFiredKey) else { return }
        defaults.set(true, forKey: arFirstFrameFiredKey)
        defaults.set(now.timeIntervalSince1970, forKey: arFirstFrameAtKey)
        Analytics.capture(arFirstFrameEvent, [:])
    }

    /// A plane passed the visibility filter for the first time ever. Once
    /// per install (latch).
    ///
    /// This fires off the visibility FILTER, not the screen: the plane can
    /// be behind the user with no label drawn. The meaning is kept for
    /// funnel continuity; `first_label_on_screen` is the "a label was
    /// actually drawn" milestone.
    static func fireFirstPlaneSeenOnce(visibleCount: Int, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: firstPlaneSeenFiredKey) else { return }
        defaults.set(true, forKey: firstPlaneSeenFiredKey)
        Analytics.capture(firstPlaneSeenEvent, ["visible_count": .int(visibleCount)])
    }

    /// True once `first_label_on_screen` has fired on this install, so the
    /// 1 Hz caller can stop doing projection work for the session.
    static func firstLabelOnScreenFired(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: firstLabelOnScreenFiredKey)
    }

    /// A plane label was drawn inside the camera frame for the first time
    /// ever: the user SAW something to catch, not just had one in range.
    /// Once per install (latch). A zero `onScreenCount` is a no-op, so the
    /// caller can pass whatever it measured.
    static func fireFirstLabelOnScreenOnce(
        headingAccuracyDeg: Double?,
        visibleCount: Int,
        onScreenCount: Int,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        guard onScreenCount > 0, !defaults.bool(forKey: firstLabelOnScreenFiredKey) else { return }
        defaults.set(true, forKey: firstLabelOnScreenFiredKey)
        Analytics.capture(firstLabelOnScreenEvent, labelProperties(
            headingAccuracyDeg: headingAccuracyDeg,
            secondsSinceARFirstFrame: secondsSinceARFirstFrame(now: now, defaults: defaults),
            visibleCount: visibleCount,
            onScreenCount: onScreenCount
        ))
    }

    /// The user pinned a plane label for the first time ever: the intent
    /// signal between seeing and catching. Once per install (latch). `via`
    /// names the tap path ("direct", "widened", "voiceover"). Tap-reveals
    /// of hidden planes don't count, since no label was on screen;
    /// `tap_reveal` records those.
    static func fireFirstLabelTapOnce(
        via: String,
        headingAccuracyDeg: Double?,
        visibleCount: Int,
        onScreenCount: Int?,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: firstLabelTapFiredKey) else { return }
        defaults.set(true, forKey: firstLabelTapFiredKey)
        var props = labelProperties(
            headingAccuracyDeg: headingAccuracyDeg,
            secondsSinceARFirstFrame: secondsSinceARFirstFrame(now: now, defaults: defaults),
            visibleCount: visibleCount,
            onScreenCount: onScreenCount
        )
        props["via"] = .string(via)
        Analytics.capture(firstLabelTapEvent, props)
    }

    /// The label-tap entry point for the pin sites. A tapped label was on
    /// screen by definition, but `first_label_on_screen` is only sampled at
    /// ~1 Hz, so a quick first tap could beat it. This fires the on-screen
    /// milestone first when it hasn't fired yet (with at least the tapped
    /// label counted), so the funnel never shows a tap without, or before,
    /// an on-screen label.
    static func recordLabelTap(
        via: String,
        headingAccuracyDeg: Double?,
        visibleCount: Int,
        onScreenCount: Int?,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: firstLabelTapFiredKey) else { return }
        fireFirstLabelOnScreenOnce(
            headingAccuracyDeg: headingAccuracyDeg,
            visibleCount: visibleCount,
            onScreenCount: max(onScreenCount ?? 0, 1),
            now: now,
            defaults: defaults
        )
        fireFirstLabelTapOnce(
            via: via,
            headingAccuracyDeg: headingAccuracyDeg,
            visibleCount: visibleCount,
            onScreenCount: onScreenCount,
            now: now,
            defaults: defaults
        )
    }

    /// Session-scoped (the caller holds the per-variant latch).
    static func fireEmptySkyStateShown(
        variant: EmptySkyVariant,
        rawCount: Int,
        nearestSlantMeters: Double?,
        secondsInSession: Double,
        hasLocation: Bool
    ) {
        Analytics.capture(emptySkyStateShownEvent, emptySkyProperties(
            variant: variant, rawCount: rawCount,
            nearestSlantMeters: nearestSlantMeters, secondsInSession: secondsInSession,
            hasLocation: hasLocation
        ))
    }

    static func firePermissionRecoveryShown(cameraDenied: Bool, locationDenied: Bool) {
        Analytics.capture(permissionRecoveryShownEvent, permissionRecoveryProperties(
            cameraDenied: cameraDenied, locationDenied: locationDenied
        ))
    }

    static func firePermissionRecoverySettingsTapped(cameraDenied: Bool, locationDenied: Bool) {
        Analytics.capture(permissionRecoverySettingsTappedEvent, permissionRecoveryProperties(
            cameraDenied: cameraDenied, locationDenied: locationDenied
        ))
    }

    // MARK: - Compass triad (session-scoped; the caution badge is already
    // debounced 4 s + hysteresis upstream, so volume stays low)

    static func fireCompassCautionShown(headingAccuracyDeg: Double?) {
        var props: [String: AnalyticsValue] = [:]
        if let a = headingAccuracyDeg { props["heading_accuracy_deg"] = .double(a) }
        Analytics.capture(compassCautionEvent, props)
    }

    static func fireCompassSheetOpened(headingAccuracyDeg: Double?) {
        var props: [String: AnalyticsValue] = [:]
        if let a = headingAccuracyDeg { props["heading_accuracy_deg"] = .double(a) }
        Analytics.capture(compassSheetOpenedEvent, props)
    }

    static func fireCompassCalibrated(headingAccuracyDeg: Double?) {
        var props: [String: AnalyticsValue] = [:]
        if let a = headingAccuracyDeg { props["heading_accuracy_deg"] = .double(a) }
        Analytics.capture(compassCalibratedEvent, props)
    }
}
