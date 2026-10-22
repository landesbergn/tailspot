//
//  MetricsSubscriber.swift
//  Tailspot
//
//  MetricKit subscriber for production observability.
//
//  MetricKit is Apple's on-device diagnostic framework (iOS 13+). The OS
//  delivers payloads once per day (or on first install) with aggregated
//  performance metrics: hang time histogram, launch time, peak memory, etc.
//  No third-party crash SDK is needed for this baseline — App Store Connect /
//  Xcode Organizer also aggregates raw crashes; MetricKit lets the app log
//  headline numbers and capture a compact analytics event so they land in the
//  same PostHog funnel as usage events.
//
//  Registration:
//    MetricsSubscriber.shared.register() — called once in TailspotApp.init.
//    MXMetricManager retains the subscriber weakly, so a singleton keeps it alive.
//
//  On payload receipt:
//    1. Log a compact human-readable summary via Log.metrics.
//    2. Capture a `metrickit_payload` analytics event with headline numbers.
//       We deliberately do NOT forward the raw payload — it would be verbose
//       and most fields aren't actionable at this stage.
//
//  Diagnostic payloads (MXDiagnosticPayload, iOS 14+) are processed
//  separately: one `metrickit_crash` event per crash and one `metrickit_hang`
//  per hang diagnostic, each with the build it came from, the top 8 frames
//  of the crashed or hung thread, and the first 5 frames from the Tailspot
//  binary itself (system frames usually fill the top 8), all as binary name +
//  offset + binary UUID (and, for crashes, the exception, signal and
//  termination reason). That is enough
//  to symbolicate with `atos` against the archived dSYM without App Store
//  Connect. No file paths or user data: MetricKitParser documents exactly
//  what is kept.
//
//  MetricKit API notes:
//    - Hang time: `applicationResponsivenessMetrics.histogrammedApplicationHangTime`
//      (MXAppResponsivenessMetric). `hang_count_v2` = sum of bucketCount,
//      `hang_total_s_v2` = sum of count x bucket midpoint.
//    - Peak memory: `memoryMetrics.peakMemoryUsage` in megabytes.
//    - Launch time: `applicationLaunchMetrics.histogrammedTimeToFirstDraw`
//      count-weighted p50 / p90 in milliseconds (`launch_p50_ms_v2`, ...).
//    - App exits: `applicationExitMetrics` foreground/background counts
//      (`exit_fg_*`, `exit_bg_*`), the only signal for jetsam/watchdog kills.
//    The pre-v2 fields (`hang_total_s`, `launch_time_ms`) still send for one
//    release so old and new series don't mix; drop them after 1.2.3.
//    All histogram properties are non-optional (always present in a non-nil
//    parent metric object), so no nil-coalescence needed after the outer guard.
//

import MetricKit
import Foundation
import os

// MARK: - MetricsSubscriber

/// MetricKit subscriber — register once at launch via `shared.register()`.
/// The class is `@MainActor` because `MXMetricManagerSubscriber` callbacks
/// arrive on the main thread and the Xcode 26 default-MainActor isolation
/// applies here.
@MainActor
final class MetricsSubscriber: NSObject, MXMetricManagerSubscriber {

    static let shared = MetricsSubscriber()
    private override init() { super.init() }

    // MARK: - Registration

    /// Register with MetricKit. Call once in `TailspotApp.init`.
    /// Safe to call multiple times — MXMetricManager ignores duplicate adds.
    func register() {
        MXMetricManager.shared.add(self)
        Log.metrics.info("MetricsSubscriber: registered with MXMetricManager")
    }

    // MARK: - MXMetricManagerSubscriber

    /// Called by MetricKit (at most once per day) with metric payloads.
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            processMetricPayload(payload)
        }
    }

    /// Called by MetricKit with diagnostic / crash payloads (iOS 14+).
    @available(iOS 14.0, *)
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            processDiagnosticPayload(payload)
        }
    }

    // MARK: - Processing

    private nonisolated func processMetricPayload(_ payload: MXMetricPayload) {
        // ── Hang time (LEGACY field) ───────────────────────────────────
        // Kept unchanged for one release so the existing PostHog series doesn't
        // break. It sums bucket END values and ignores how many hangs fell in
        // each bucket, so it is neither a count nor a duration. Read
        // `hang_count_v2` / `hang_total_s_v2` instead.
        let totalHangSeconds: Double = {
            guard let responsiveness = payload.applicationResponsivenessMetrics else {
                return 0
            }
            var total = 0.0
            let enumerator = responsiveness.histogrammedApplicationHangTime.bucketEnumerator
            while let bucket = enumerator.nextObject() as? MXHistogramBucket<UnitDuration> {
                total += bucket.bucketEnd.converted(to: .seconds).value
            }
            return total
        }()

        // ── Peak memory ────────────────────────────────────────────────
        let peakMemoryMB: Double = {
            guard let mem = payload.memoryMetrics else { return 0 }
            return mem.peakMemoryUsage.converted(to: UnitInformationStorage.megabytes).value
        }()

        // ── Launch time (LEGACY field) ─────────────────────────────────
        // Unweighted median of bucket edges, also kept for one release only.
        // `launch_p50_ms_v2` / `launch_p90_ms_v2` are count-weighted.
        let launchTimeMs: Double = {
            guard let launch = payload.applicationLaunchMetrics else { return 0 }
            var bucketValues: [Double] = []
            let enumerator = launch.histogrammedTimeToFirstDraw.bucketEnumerator
            while let bucket = enumerator.nextObject() as? MXHistogramBucket<UnitDuration> {
                bucketValues.append(bucket.bucketEnd.converted(to: .milliseconds).value)
            }
            return bucketValues.sorted().middle ?? 0
        }()

        // ── Corrected histograms (v2) ──────────────────────────────────
        // Read each histogram into plain (start, end, count) buckets; the math
        // lives in MetricKitParser where tests can reach it.
        let hangBuckets = payload.applicationResponsivenessMetrics.map {
            Self.buckets($0.histogrammedApplicationHangTime, unit: .seconds)
        }
        let launchBuckets = payload.applicationLaunchMetrics.map {
            Self.buckets($0.histogrammedTimeToFirstDraw, unit: .milliseconds)
        }

        // ── App exits ──────────────────────────────────────────────────
        // Memory-limit (jetsam) and watchdog kills never arrive as crash
        // diagnostics; these cumulative counts are the only place they show.
        let exits = payload.applicationExitMetrics
        let foregroundExits = exits.map { e in
            MetricKitParser.ExitCounts(
                normal: e.foregroundExitData.cumulativeNormalAppExitCount,
                memoryResourceLimit: e.foregroundExitData.cumulativeMemoryResourceLimitExitCount,
                appWatchdog: e.foregroundExitData.cumulativeAppWatchdogExitCount,
                abnormal: e.foregroundExitData.cumulativeAbnormalExitCount,
                badAccess: e.foregroundExitData.cumulativeBadAccessExitCount,
                illegalInstruction: e.foregroundExitData.cumulativeIllegalInstructionExitCount)
        }
        let backgroundExits = exits.map { e in
            MetricKitParser.ExitCounts(
                normal: e.backgroundExitData.cumulativeNormalAppExitCount,
                memoryResourceLimit: e.backgroundExitData.cumulativeMemoryResourceLimitExitCount,
                appWatchdog: e.backgroundExitData.cumulativeAppWatchdogExitCount,
                abnormal: e.backgroundExitData.cumulativeAbnormalExitCount,
                badAccess: e.backgroundExitData.cumulativeBadAccessExitCount,
                illegalInstruction: e.backgroundExitData.cumulativeIllegalInstructionExitCount,
                memoryPressure: e.backgroundExitData.cumulativeMemoryPressureExitCount,
                suspendedWithLockedFile: e.backgroundExitData.cumulativeSuspendedWithLockedFileExitCount,
                backgroundTaskAssertionTimeout: e.backgroundExitData.cumulativeBackgroundTaskAssertionTimeoutExitCount,
                cpuResourceLimit: e.backgroundExitData.cumulativeCPUResourceLimitExitCount)
        }

        // ── Log summary ────────────────────────────────────────────────

        Log.metrics.info(
            "MetricKit payload: hangTotal=\(totalHangSeconds, privacy: .public)s peakMemory=\(peakMemoryMB, privacy: .public)MB launchTime=\(launchTimeMs, privacy: .public)ms"
        )

        // ── Analytics event ────────────────────────────────────────────

        var properties: [String: AnalyticsValue] = [
            "hang_total_s":     .double(totalHangSeconds),
            "peak_memory_mb":   .double(peakMemoryMB),
            "launch_time_ms":   .double(launchTimeMs),
        ]
        // `merge(_:uniquingKeysWith:)` folds one dictionary into another; the
        // closure picks which value wins on a key clash (none expected here).
        properties.merge(
            MetricKitParser.histogramProperties(hangBucketsSeconds: hangBuckets,
                                                launchBucketsMs: launchBuckets)
        ) { _, new in new }
        properties.merge(
            MetricKitParser.exitProperties(foreground: foregroundExits, background: backgroundExits)
        ) { _, new in new }
        // The build the metrics describe, which can differ from the build that
        // delivers them (the `$app_version` PostHog stamps at send time).
        if let build = payload.metaData?.applicationBuildVersion {
            properties["diag_app_build"] = .string(build)
        }
        Analytics.capture("metrickit_payload", properties)
    }

    /// Copy an `MXHistogram<UnitDuration>` into plain buckets in `unit`.
    /// `bucketEnumerator` is an Objective-C `NSEnumerator`, hence the
    /// `nextObject()` loop and the cast.
    private nonisolated static func buckets(_ histogram: MXHistogram<UnitDuration>,
                                            unit: UnitDuration) -> [MetricKitParser.Bucket] {
        var out: [MetricKitParser.Bucket] = []
        let enumerator = histogram.bucketEnumerator
        while let bucket = enumerator.nextObject() as? MXHistogramBucket<UnitDuration> {
            out.append(MetricKitParser.Bucket(
                start: bucket.bucketStart.converted(to: unit).value,
                end: bucket.bucketEnd.converted(to: unit).value,
                count: bucket.bucketCount))
        }
        return out
    }

    @available(iOS 14.0, *)
    private nonisolated func processDiagnosticPayload(_ payload: MXDiagnosticPayload) {
        // One `metrickit_crash` per crash (it used to be one event carrying
        // only a count). Each carries the exception, signal, termination
        // reason, the build it came from, and the crashed thread's top frames:
        // enough to symbolicate against the archived dSYM.
        for (idx, crash) in (payload.crashDiagnostics ?? []).enumerated() {
            let typed = MetricKitParser.TypedFields(
                appBuild: crash.metaData.applicationBuildVersion,
                osVersion: crash.metaData.osVersion,
                exceptionType: crash.exceptionType?.intValue,
                exceptionCode: crash.exceptionCode?.intValue,
                signal: crash.signal?.intValue,
                terminationReason: crash.terminationReason)
            let properties = MetricKitParser.crashProperties(
                diagnosticJSON: crash.jsonRepresentation(), typed: typed)
            let reason = crash.exceptionType?.debugDescription ?? "unknown"
            Log.metrics.fault(
                "MetricKit crash #\(idx + 1, privacy: .public): \(reason, privacy: .public)"
            )
            Analytics.capture("metrickit_crash", properties)
        }

        // One `metrickit_hang` per hang diagnostic, with the hung thread's top
        // frames. The payload histogram only counts hangs; this says where.
        for hang in payload.hangDiagnostics ?? [] {
            let seconds = hang.hangDuration.converted(to: .seconds).value
            let typed = MetricKitParser.TypedFields(
                appBuild: hang.metaData.applicationBuildVersion,
                osVersion: hang.metaData.osVersion,
                hangDurationSeconds: seconds)
            let properties = MetricKitParser.hangProperties(
                diagnosticJSON: hang.jsonRepresentation(), typed: typed)
            Log.metrics.notice("MetricKit hang: \(seconds, privacy: .public)s")
            Analytics.capture("metrickit_hang", properties)
        }
    }
}

// MARK: - Array median helper

private extension Array where Element: Comparable {
    /// Lower-median element (nil for empty arrays).
    nonisolated var middle: Element? {
        guard !isEmpty else { return nil }
        return sorted()[count / 2]
    }
}
