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
//      → permission_outcome (camera / location, granted?)
//      → onboarding_completed (claim result)
//      → ar_first_frame        [once per install]
//      → first_plane_seen      [once per install]
//      → first_plane_catch     (CatchTelemetry)
//  Plus the compass triad (caution shown / sheet opened / calibrated) —
//  the suspected silent killer of "saw a label but it pointed wrong".
//

import Foundation

nonisolated enum ActivationTelemetry {

    static let stepViewedEvent = "onboarding_step_viewed"
    static let completedEvent = "onboarding_completed"
    static let permissionOutcomeEvent = "permission_outcome"
    static let arFirstFrameEvent = "ar_first_frame"
    static let firstPlaneSeenEvent = "first_plane_seen"
    static let compassCautionEvent = "compass_caution_shown"
    static let compassSheetOpenedEvent = "compass_sheet_opened"
    static let compassCalibratedEvent = "compass_calibrated"

    static let arFirstFrameFiredKey = "tailspot.telemetry.arFirstFrameFired"
    static let firstPlaneSeenFiredKey = "tailspot.telemetry.firstPlaneSeenFired"

    // MARK: - Pure builders (unit-tested)

    /// Stable analytics name for an onboarding step index. Indexes match
    /// `OnboardingFlow.step`; anything past the known steps reports the
    /// index so a future 4th step can't silently vanish from the funnel.
    static func stepName(_ step: Int) -> String {
        switch step {
        case 0: return "welcome"
        case 1: return "permissions"
        case 2: return "handle"
        case 3: return "calibration"
        default: return "step_\(step)"
        }
    }

    static func stepViewedProperties(step: Int) -> [String: AnalyticsValue] {
        [
            "step": .int(step),
            "step_name": .string(stepName(step)),
        ]
    }

    static func permissionProperties(permission: String, granted: Bool) -> [String: AnalyticsValue] {
        [
            "permission": .string(permission),
            "granted": .bool(granted),
        ]
    }

    static func completedProperties(claimResult: String, calibrated: Bool) -> [String: AnalyticsValue] {
        [
            "handle_claim": .string(claimResult),
            // Did the user calibrate the compass in-flow (vs skip)? The
            // split against later compass_caution_shown rates is the
            // evidence for whether the step earns its place.
            "calibrated": .bool(calibrated),
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
    static func fireCompleted(claimResult: String, calibrated: Bool) {
        Analytics.capture(completedEvent, completedProperties(
            claimResult: claimResult, calibrated: calibrated
        ))
    }

    static func firePermissionOutcome(permission: String, granted: Bool) {
        Analytics.capture(permissionOutcomeEvent, permissionProperties(
            permission: permission, granted: granted
        ))
    }

    /// The camera produced its first frame ever — the user reached a live
    /// AR view. Once per install (latch), like `first_plane_catch`.
    static func fireARFirstFrameOnce(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: arFirstFrameFiredKey) else { return }
        defaults.set(true, forKey: arFirstFrameFiredKey)
        Analytics.capture(arFirstFrameEvent, [:])
    }

    /// A plane label became visible for the first time ever — the user has
    /// something to catch. Once per install (latch).
    static func fireFirstPlaneSeenOnce(visibleCount: Int, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: firstPlaneSeenFiredKey) else { return }
        defaults.set(true, forKey: firstPlaneSeenFiredKey)
        Analytics.capture(firstPlaneSeenEvent, ["visible_count": .int(visibleCount)])
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
