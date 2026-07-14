//
//  CatchTelemetry.swift
//  Tailspot
//
//  Catch-lifecycle analytics for the catch-confirmation-rate north-star
//  (STRATEGY.md). The catch path lives deep inside ContentView and the
//  delete path inside CatchDetailView — both untestable in isolation — so
//  the *logic* (which event, which properties) is factored out here as
//  pure builders that unit tests can pin, with thin `@MainActor` wrappers
//  that read a `Catch` and hand off to `Analytics.capture`.
//
//  Events (via Analytics.swift):
//    - catch_performed  — fires once per processed target on a catch tap.
//                         Successful catches carry rarity/type/slant;
//                         duplicates (already in the Hangar, no new row)
//                         carry only icao24 + is_duplicate=true.
//    - catch_uploaded   — fires once per catch the backend accepts. Carries
//                         the aircraft IDENTITY snapshotted on the Catch
//                         (tail number, typecode, manufacturer, model,
//                         operator, type, ADS-B category, callsign) plus the
//                         authoritative rarity/points/duplicate from the
//                         server response — so PostHog can show *which* plane
//                         was caught. Airframe attributes, not user PII; the
//                         only location is the coarse reverse-geocoded
//                         place_name (no precise coordinates).
//    - catch_deleted    — fires once per delete action (a HangarRow may
//                         group N icao rows; `count` records how many).
//
//  Together with the post-catch confirm outcomes (catch_suspect_kept /
//  catch_suspect_discarded) these are the numerator + negative signals the
//  catch-confirmation-rate funnel needs.
//

import Foundation

nonisolated enum CatchTelemetry {

    static let performedEvent = "catch_performed"
    static let uploadedEvent = "catch_uploaded"
    static let deletedEvent = "catch_deleted"
    // Gate-positive streams. Post-catch confirm model (2026-07-04): the gates
    // no longer block the catch, so these record "the gate raised suspicion",
    // not a user-facing wall. Names kept for dashboard continuity with the
    // pre-2026-07-04 blocking era; the *_override events retired with it.
    static let blockedOutdoorsEvent = "catch_blocked_outdoors"
    static let blockedSizeEvent = "catch_blocked_size"
    // Uncertain-aim flag (2026-07-13). Fires when a center catch is flagged as
    // maybe-the-wrong-plane (off-crosshair + small under a poor compass) — the
    // calibration stream for the confidence floor.
    static let uncertainAimEvent = "catch_uncertain_aim"
    // Lever 2 (localized sky gate). `catch_local_gate` fires on EVERY catch
    // (shadow + enforce) with the per-target verdict + features — the
    // calibration stream for the on-device texture threshold.
    static let localGateEvent = "catch_local_gate"
    // Lever 4 (detector soft-gate). `catch_detector_gate` fires on every
    // single-target catch (shadow + enforce) with the verdict + envelope
    // signals — the calibration stream that decides when enforcement is safe
    // to flip (watch the in-envelope no-detection rate on real catches).
    static let detectorGateEvent = "catch_detector_gate"
    // Post-catch confirm outcomes: a suspected catch records + reveals
    // instantly, then gets one Keep/Discard question after the reveal.
    // `catch_suspected` fires when a row is quarantined; kept/discarded record
    // the answer — the EARNED confirm/deny signal for the north-star (a
    // discard also fires `catch_deleted`, so the headline rate absorbs it).
    static let suspectedEvent = "catch_suspected"
    static let suspectKeptEvent = "catch_suspect_kept"
    static let suspectDiscardedEvent = "catch_suspect_discarded"
    // Bonus-round engagement funnel (game-layer PR3). `guess_round_shown`
    // fires when the pre-reveal guess cover appears; `_answered` carries the
    // kind + local verdict (the per-device accuracy stream that watches for
    // 100%-correct cheat outliers — plan §A4) + elapsed ms; `_skipped` records
    // the quiet opt-out. Together they feed the catches-per-spotter analysis of
    // whether the guessing hook actually works.
    static let guessRoundShownEvent = "guess_round_shown"
    static let guessRoundAnsweredEvent = "guess_round_answered"
    static let guessRoundSkippedEvent = "guess_round_skipped"
    // Activation milestone: the user's very FIRST catch ever (the Hangar was
    // empty before this tap). The single most load-bearing activation edge —
    // ~36 openers → 5 catchers/30d (PLAN §9 #3) — so it gets a first-class
    // event funnels can pivot on, not a HogQL reconstruction over
    // catch_performed. Fired at most once per install (UserDefaults latch;
    // a reinstall wipes the Hangar AND the latch together, so "first catch
    // in this Hangar" stays true).
    static let firstCatchEvent = "first_plane_catch"
    static let firstCatchFiredKey = "tailspot.telemetry.firstCatchFired"
    // Grounded easter egg (2026-07-09): the user tapped a parked plane in
    // the AR view. No catch is attempted (grounded planes are never
    // catchable) — the toast + this event ARE the feature's output, and the
    // event doubles as the how-often-does-this-happen signal for the
    // "Ground Stop" secret badge.
    static let groundedAttemptEvent = "grounded_catch_attempt"

    // MARK: - Pure property builders (unit-tested)

    /// Properties for a successful catch of a single airframe.
    static func performedProperties(
        icao24: String,
        rarity: String,
        aircraftType: String,
        slantKm: Double,
        visualConfirmEnabled: Bool,
        visualFixConfidence: Float?,
        multiN: Int = 1,
        angularSizeArcmin: Double? = nil,
        detectorVerdict: DetectorGateVerdict? = nil
    ) -> [String: AnalyticsValue] {
        var props: [String: AnalyticsValue] = [
            "icao24": .string(icao24),
            "rarity": .string(rarity),
            "aircraft_type": .string(aircraftType),
            "slant_km": .double(slantKm),
            "is_duplicate": .bool(false),
            // Visual-confirmation context (2026-06-26 go-live): is the feature
            // on, and did the caught plane have a live detector fix at catch
            // time + how confident. The wild "is it actually helping?" signal.
            "visual_confirm_enabled": .bool(visualConfirmEnabled),
            "visual_fix_active": .bool(visualFixConfidence != nil),
            // Anti-cheat (PR1): how many planes this one tap caught (L1 should
            // drive it toward 1 — the spray firehose is gone), and the caught
            // plane's apparent angular size (L3 — catches should trend bigger /
            // closer). Together they watch the fix without a new dashboard.
            "multi_n": .int(multiN),
        ]
        if let c = visualFixConfidence { props["visual_fix_confidence"] = .double(Double(c)) }
        if let a = angularSizeArcmin { props["angular_size_arcmin"] = .double(a) }
        // L4 detector soft-gate verdict for this target; omitted when the
        // gate didn't run (multi-catch, no photo) so absent means "not judged".
        if let v = detectorVerdict { props["detector_verdict"] = .string(v.rawValue) }
        return props
    }

    /// Properties for the activation milestone (`first_plane_catch`): the
    /// identity of the plane that converted this user, in the same vocabulary
    /// as catch_performed so the two join cleanly.
    static func firstCatchProperties(
        icao24: String,
        rarity: String,
        aircraftType: String,
        slantKm: Double
    ) -> [String: AnalyticsValue] {
        [
            "icao24": .string(icao24),
            "rarity": .string(rarity),
            "aircraft_type": .string(aircraftType),
            "slant_km": .double(slantKm),
        ]
    }

    /// Properties for a grounded-plane tap (`grounded_catch_attempt`):
    /// icao24 only — no location, no airframe fields; the plane was never
    /// caught, so there is nothing else honest to attach.
    static func groundedAttemptProperties(icao24: String) -> [String: AnalyticsValue] {
        ["icao24": .string(icao24)]
    }

    /// Fired once per grounded-plane tap, alongside the parked-plane toast.
    static func fireGroundedAttempt(icao24: String) {
        Analytics.capture(groundedAttemptEvent, groundedAttemptProperties(icao24: icao24))
    }

    /// Properties for a duplicate-catch tap — the target is already in the
    /// Hangar, so no `Catch` row exists to read rarity/type from. We still
    /// record the attempt (it IS a capture attempt — part of the funnel
    /// denominator) flagged as a duplicate.
    static func duplicateProperties(icao24: String) -> [String: AnalyticsValue] {
        [
            "icao24": .string(icao24),
            "is_duplicate": .bool(true),
        ]
    }

    /// Properties for a server-confirmed catch upload (`catch_uploaded`).
    ///
    /// Carries the aircraft IDENTITY captured on the `Catch` so PostHog can
    /// answer "which specific plane was caught" — tail number, typecode,
    /// manufacturer, model, operator, derived type, ADS-B emitter category,
    /// and callsign. `rarity`/`points`/`duplicate` come from the authoritative
    /// server response (rarity falls back to the local resolved value when the
    /// server omits it). These are airframe attributes, NOT user PII — the only
    /// location is the coarse reverse-geocoded `place_name` (no coordinates).
    ///
    /// Nil/blank string fields are OMITTED (matching `deletedProperties` and
    /// `Catch.preferredAirframeField`'s blank-is-absent rule) — never sent as
    /// null or a placeholder, so PostHog only sees keys we actually know.
    static func uploadedProperties(
        icao24: String,
        rarity: String,
        points: Int,
        duplicate: Bool,
        registration: String?,
        typecode: String?,
        manufacturer: String?,
        model: String?,
        operatorName: String?,
        aircraftType: String?,
        category: String?,
        callsign: String?,
        placeName: String?
    ) -> [String: AnalyticsValue] {
        var props: [String: AnalyticsValue] = [
            "icao24": .string(icao24),
            "rarity": .string(rarity),
            "points": .int(points),
            "duplicate": .bool(duplicate),
        ]
        // Insert only when the value is non-nil and non-blank — a missing
        // airframe field should be an absent key, not "" or null.
        func add(_ key: String, _ value: String?) {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return }
            props[key] = .string(trimmed)
        }
        add("registration", registration)
        add("typecode", typecode)
        add("manufacturer", manufacturer)
        add("model", model)
        add("operator_name", operatorName)
        add("aircraft_type", aircraftType)
        add("category", category)
        add("callsign", callsign)
        add("place_name", placeName)
        return props
    }

    /// Properties for a delete. `count` is the number of underlying `Catch`
    /// rows the deleted Hangar row grouped (≥1). `rarity` is omitted when
    /// unknown rather than sent as a placeholder.
    static func deletedProperties(
        icao24: String,
        count: Int,
        rarity: String?
    ) -> [String: AnalyticsValue] {
        var props: [String: AnalyticsValue] = [
            "icao24": .string(icao24),
            "count": .int(count),
        ]
        if let rarity { props["rarity"] = .string(rarity) }
        return props
    }

    /// Properties for the v1 authenticity gate events (block + override):
    /// the verdict + raw scene signals, so the false-block rate can be
    /// watched and the corpus re-scored.
    static func outdoorGateProperties(
        verdict: SkyVerdict,
        features: SkyFeatures?,
        gpsAccuracyMeters: Double?
    ) -> [String: AnalyticsValue] {
        var props: [String: AnalyticsValue] = ["verdict": .string(verdict.rawValue)]
        if let f = features {
            props["edge_density"] = .double(f.edgeDensity)
            props["tile_variance"] = .double(f.tileVariance)
            props["warmth"] = .double(f.warmth)
            props["mean_luminance"] = .double(f.meanLuminance)
        } else {
            props["features_available"] = .bool(false)
        }
        if let g = gpsAccuracyMeters { props["gps_accuracy_m"] = .double(g) }
        return props
    }

    /// Properties for the angular-size-floor events (Lever 3 block + override):
    /// the blocked target's apparent size + slant, so the floor can be tuned
    /// from real blocks and the override (false-block) rate watched.
    static func sizeGateProperties(
        arcmin: Double, slantKm: Double, blockedCount: Int = 1
    ) -> [String: AnalyticsValue] {
        [
            "angular_size_arcmin": .double(arcmin),
            "slant_km": .double(slantKm),
            "blocked_count": .int(blockedCount),
            "floor_arcmin": .double(ObservedAircraft.catchSizeFloorArcminutes),
        ]
    }

    // MARK: - Bonus-round property builders (unit-tested)

    /// Properties for `guess_round_shown` — the round kind offered.
    static func guessRoundShownProperties(kind: GuessKind) -> [String: AnalyticsValue] {
        ["kind": .string(kind.rawValue)]
    }

    /// Properties for `guess_round_answered` — the kind, the LOCAL verdict, and
    /// (when measured) how long the user took. `elapsedMs` is omitted when nil,
    /// matching the omit-blank convention elsewhere in this file.
    static func guessRoundAnsweredProperties(
        kind: GuessKind, correct: Bool, elapsedMs: Int? = nil
    ) -> [String: AnalyticsValue] {
        var props: [String: AnalyticsValue] = [
            "kind": .string(kind.rawValue),
            "correct": .bool(correct),
        ]
        if let elapsedMs { props["elapsed_ms"] = .int(elapsedMs) }
        return props
    }

    /// Properties for `guess_round_skipped` — the kind the user opted out of.
    static func guessRoundSkippedProperties(
        kind: GuessKind, elapsedMs: Int? = nil
    ) -> [String: AnalyticsValue] {
        var props: [String: AnalyticsValue] = ["kind": .string(kind.rawValue)]
        if let elapsedMs { props["elapsed_ms"] = .int(elapsedMs) }
        return props
    }

    // MARK: - Fire wrappers (read MainActor-isolated `Catch`, then capture)

    @MainActor static func firePerformed(
        _ row: Catch,
        visualConfirmEnabled: Bool,
        visualFixConfidence: Float?,
        multiN: Int = 1,
        angularSizeArcmin: Double? = nil,
        detectorVerdict: DetectorGateVerdict? = nil
    ) {
        Analytics.capture(performedEvent, performedProperties(
            icao24: row.icao24,
            rarity: row.resolvedRarity.rawValue,
            aircraftType: row.resolvedType.rawValue,
            slantKm: row.slantDistanceMeters / 1000,
            visualConfirmEnabled: visualConfirmEnabled,
            visualFixConfidence: visualFixConfidence,
            multiN: multiN,
            angularSizeArcmin: angularSizeArcmin,
            detectorVerdict: detectorVerdict
        ))
    }

    /// Fire `first_plane_catch` once per install. The caller decides
    /// "the Hangar was empty before this tap"; the latch here makes the
    /// event idempotent across any double-fire path.
    @MainActor static func fireFirstCatch(_ row: Catch) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: firstCatchFiredKey) else { return }
        defaults.set(true, forKey: firstCatchFiredKey)
        Analytics.capture(firstCatchEvent, firstCatchProperties(
            icao24: row.icao24,
            rarity: row.resolvedRarity.rawValue,
            aircraftType: row.resolvedType.rawValue,
            slantKm: row.slantDistanceMeters / 1000
        ))
    }

    @MainActor static func fireDuplicate(icao24: String) {
        Analytics.capture(performedEvent, duplicateProperties(icao24: icao24))
    }

    /// Fire `catch_uploaded` after the backend accepts a catch. Reads the
    /// aircraft identity off the `Catch` (MainActor-isolated SwiftData row)
    /// and the rarity/points/duplicate off the server response. Rarity prefers
    /// the server value (authoritative re-tiering) and falls back to the
    /// locally resolved tier when the response omits it.
    @MainActor static func fireUploaded(_ row: Catch, response: UploadCatchResponse) {
        Analytics.capture(uploadedEvent, uploadedProperties(
            icao24: row.icao24,
            rarity: response.rarity ?? row.resolvedRarity.rawValue,
            points: response.points,
            duplicate: response.duplicate,
            registration: row.registration,
            typecode: row.typecode,
            manufacturer: row.manufacturer,
            model: row.model,
            operatorName: row.operatorName,
            aircraftType: row.resolvedType.rawValue,
            category: row.category,
            callsign: row.callsign,
            placeName: row.placeName
        ))
    }

    @MainActor static func fireDeleted(icao24: String, count: Int, rarity: String?) {
        Analytics.capture(deletedEvent, deletedProperties(
            icao24: icao24, count: count, rarity: rarity
        ))
    }

    /// Fired when the indoor gate suspects a catch (verdict `.notSky`).
    /// Post-catch confirm: raises suspicion, never blocks.
    static func fireBlockedOutdoors(
        verdict: SkyVerdict, features: SkyFeatures?, gpsAccuracyMeters: Double?
    ) {
        Analytics.capture(blockedOutdoorsEvent, outdoorGateProperties(
            verdict: verdict, features: features, gpsAccuracyMeters: gpsAccuracyMeters
        ))
    }

    /// Fired when the angular-size floor suspects a target (too small-and-
    /// distant to resolve). `blockedCount` ≥ 1 — on a multi-tap it's how many
    /// targets the floor flagged.
    static func fireBlockedSize(arcmin: Double, slantKm: Double, blockedCount: Int = 1) {
        Analytics.capture(blockedSizeEvent, sizeGateProperties(
            arcmin: arcmin, slantKm: slantKm, blockedCount: blockedCount
        ))
    }

    /// Fired when a center (non-tapped) catch is flagged uncertain-aim: the
    /// target's crosshair offset, apparent size, compass accuracy, and the
    /// computed confidence — so the floor can be tuned from real flags.
    static func fireUncertainAim(
        offsetDeg: Double, arcmin: Double, headingAccuracyDeg: Double, confidence: Double
    ) {
        Analytics.capture(uncertainAimEvent, [
            "offset_deg": .double(offsetDeg),
            "angular_size_arcmin": .double(arcmin),
            "heading_accuracy_deg": .double(headingAccuracyDeg),
            "confidence": .double(confidence),
        ])
    }

    /// Properties for the localized-sky-gate events (L2): the verdict + the
    /// patch features + whether it would block and whether enforcement is on,
    /// so the on-device texture threshold can be calibrated from real catches.
    static func localGateProperties(
        verdict: SkyVerdict, features: LocalSkyFeatures,
        wouldBlock: Bool, enforcing: Bool
    ) -> [String: AnalyticsValue] {
        [
            "verdict": .string(verdict.rawValue),
            "patch_texture": .double(features.patchTexture),
            "patch_warmth": .double(features.patchWarmth),
            "patch_lum": .double(features.patchLum),
            "sky_fraction": .double(features.skyFraction),
            "would_block": .bool(wouldBlock),
            "enforcing": .bool(enforcing),
        ]
    }

    /// Fired once per catch target with the L2 verdict — on every catch, in
    /// shadow and enforce mode. The calibration stream for the texture floor.
    static func fireLocalGate(
        verdict: SkyVerdict, features: LocalSkyFeatures,
        wouldBlock: Bool, enforcing: Bool
    ) {
        Analytics.capture(localGateEvent, localGateProperties(
            verdict: verdict, features: features, wouldBlock: wouldBlock, enforcing: enforcing
        ))
    }

    /// Properties for the detector-soft-gate events (L4): the verdict + the
    /// envelope signals + how the plane was (or wasn't) corroborated, so the
    /// footprint/luminance envelope can be calibrated from real catches
    /// before enforcement flips on.
    static func detectorGateProperties(
        verdict: DetectorGateVerdict,
        snapHit: Bool,
        liveFix: Bool,
        expectedFootprintPx: Double?,
        meanLuminance: Double?,
        enforcing: Bool
    ) -> [String: AnalyticsValue] {
        var props: [String: AnalyticsValue] = [
            "verdict": .string(verdict.rawValue),
            "snap_hit": .bool(snapHit),
            "live_fix": .bool(liveFix),
            "would_flag": .bool(verdict == .noDetection),
            "enforcing": .bool(enforcing),
        ]
        if let f = expectedFootprintPx { props["expected_footprint_px"] = .double(f) }
        if let l = meanLuminance { props["mean_luminance"] = .double(l) }
        return props
    }

    /// Fired once per single-target catch with the L4 verdict — on every such
    /// catch, in shadow and enforce mode. The calibration stream that gates
    /// flipping enforcement.
    static func fireDetectorGate(
        verdict: DetectorGateVerdict,
        snapHit: Bool,
        liveFix: Bool,
        expectedFootprintPx: Double?,
        meanLuminance: Double?,
        enforcing: Bool
    ) {
        Analytics.capture(detectorGateEvent, detectorGateProperties(
            verdict: verdict, snapHit: snapHit, liveFix: liveFix,
            expectedFootprintPx: expectedFootprintPx,
            meanLuminance: meanLuminance, enforcing: enforcing
        ))
    }

    // MARK: - Bonus-round fire wrappers

    /// Fired when the pre-reveal guess cover appears (ContentView presents it).
    @MainActor static func fireGuessRoundShown(kind: GuessKind) {
        Analytics.capture(guessRoundShownEvent, guessRoundShownProperties(kind: kind))
    }

    /// Fired when the user answers — carries the local verdict + elapsed ms.
    @MainActor static func fireGuessRoundAnswered(
        kind: GuessKind, correct: Bool, elapsedMs: Int? = nil
    ) {
        Analytics.capture(guessRoundAnsweredEvent, guessRoundAnsweredProperties(
            kind: kind, correct: correct, elapsedMs: elapsedMs
        ))
    }

    /// Fired when the user SKIPs the round.
    @MainActor static func fireGuessRoundSkipped(kind: GuessKind, elapsedMs: Int? = nil) {
        Analytics.capture(guessRoundSkippedEvent, guessRoundSkippedProperties(
            kind: kind, elapsedMs: elapsedMs
        ))
    }

    // MARK: - Post-catch confirm (suspected → kept / discarded)

    /// Properties for the post-catch confirm events: the reason plus the
    /// target's size/distance context when the size floor supplied it.
    static func suspectProperties(
        icao24: String, reason: CatchSuspicion,
        arcmin: Double? = nil, slantKm: Double? = nil
    ) -> [String: AnalyticsValue] {
        var props: [String: AnalyticsValue] = [
            "icao24": .string(icao24),
            "reason": .string(reason.rawValue),
        ]
        if let a = arcmin { props["angular_size_arcmin"] = .double(a) }
        if let s = slantKm { props["slant_km"] = .double(s) }
        return props
    }

    /// Fired when a catch is quarantined as suspected (once per suspected row,
    /// at catch time — alongside the gate-positive stream that raised it).
    static func fireSuspected(
        icao24: String, reason: CatchSuspicion,
        arcmin: Double? = nil, slantKm: Double? = nil
    ) {
        Analytics.capture(suspectedEvent, suspectProperties(
            icao24: icao24, reason: reason, arcmin: arcmin, slantKm: slantKm
        ))
    }

    /// The user vouched for a suspected catch — it un-quarantines and uploads.
    static func fireSuspectKept(icao24: String, reason: CatchSuspicion) {
        Analytics.capture(suspectKeptEvent, suspectProperties(icao24: icao24, reason: reason))
    }

    /// The user agreed the catch wasn't real — the row is deleted. The caller
    /// also fires `catch_deleted` so the north-star headline absorbs it.
    static func fireSuspectDiscarded(icao24: String, reason: CatchSuspicion) {
        Analytics.capture(suspectDiscardedEvent, suspectProperties(icao24: icao24, reason: reason))
    }
}

/// Why the authenticity gates doubted a catch. Raw values are the persisted
/// `Catch.suspectReason` strings and the telemetry `reason` property.
nonisolated enum CatchSuspicion: String, Sendable, CaseIterable {
    case occluded            // L2: the patch under the bracket reads building/tree
    case noDetection = "no_detection"  // L4: camera should have seen it, didn't
    case tooFar = "too_far"  // L3: below the angular-size floor
    case uncertainAim = "uncertain_aim"  // center catch off-crosshair + small under a poor compass → maybe the wrong plane
    case indoor              // whole-frame SkyCheck: not pointed at open sky

    /// Precedence when several gates fire on one target — the most specific,
    /// most actionable reason wins the review copy
    /// (occluded > noDetection > tooFar > uncertainAim > indoor).
    static func preferred(_ current: CatchSuspicion?, _ new: CatchSuspicion) -> CatchSuspicion {
        guard let current else { return new }
        return current.priority >= new.priority ? current : new
    }

    private var priority: Int {
        switch self {
        case .occluded: return 5
        case .noDetection: return 4
        case .tooFar: return 3
        case .uncertainAim: return 2
        case .indoor: return 1
        }
    }

    /// The post-reveal review question for a single suspected catch. Keeps the
    /// playful product tone — a doubt, not an accusation.
    func question(slantKm: Double?) -> String {
        switch self {
        case .occluded:
            return "Looks like something was between you and that one — did you really see it?"
        case .noDetection:
            return "The camera couldn't spot that one — did you really see it?"
        case .tooFar:
            if let km = slantKm, km.isFinite, km > 0 {
                return "That one was \(Int(km.rounded())) km out — could you really see it?"
            }
            return "That one was a long way out — could you really see it?"
        case .uncertainAim:
            return "Your compass was off and that one wasn't dead-center — is it the plane you meant?"
        case .indoor:
            return "Looks like you were indoors — did you really see it?"
        }
    }
}
