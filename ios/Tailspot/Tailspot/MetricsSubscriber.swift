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
//  Crash-report payloads (MXDiagnosticPayload, iOS 14+) are processed
//  separately: we capture a `metrickit_crash` event with the crash count.
//  No stack traces — the full symbolicated trace is in App Store Connect.
//
//  MetricKit API notes:
//    - Hang time: `applicationResponsivenessMetrics.histogrammedApplicationHangTime`
//      (MXAppResponsivenessMetric) — we sum bucket durations for a total.
//    - Peak memory: `memoryMetrics.peakMemoryUsage` in megabytes.
//    - Launch time: `applicationLaunchMetrics.histogrammedTimeToFirstDraw`
//      median bucket in milliseconds.
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
        // ── Hang time ─────────────────────────────────────────────────
        // Sum all histogram buckets to get total hang time in the period.
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

        // ── Launch time (median bucket) ────────────────────────────────
        let launchTimeMs: Double = {
            guard let launch = payload.applicationLaunchMetrics else { return 0 }
            var bucketValues: [Double] = []
            let enumerator = launch.histogrammedTimeToFirstDraw.bucketEnumerator
            while let bucket = enumerator.nextObject() as? MXHistogramBucket<UnitDuration> {
                bucketValues.append(bucket.bucketEnd.converted(to: .milliseconds).value)
            }
            return bucketValues.sorted().middle ?? 0
        }()

        // ── Log summary ────────────────────────────────────────────────

        Log.metrics.info(
            "MetricKit payload: hangTotal=\(totalHangSeconds, privacy: .public)s peakMemory=\(peakMemoryMB, privacy: .public)MB launchTime=\(launchTimeMs, privacy: .public)ms"
        )

        // ── Analytics event ────────────────────────────────────────────

        Analytics.capture("metrickit_payload", [
            "hang_total_s":     .double(totalHangSeconds),
            "peak_memory_mb":   .double(peakMemoryMB),
            "launch_time_ms":   .double(launchTimeMs),
        ])
    }

    @available(iOS 14.0, *)
    private nonisolated func processDiagnosticPayload(_ payload: MXDiagnosticPayload) {
        let crashCount = payload.crashDiagnostics?.count ?? 0
        guard crashCount > 0 else { return }

        // Log one line per crash report with the exception type (no stack —
        // the full symbolicated trace is in App Store Connect Organizer).
        for (idx, crash) in (payload.crashDiagnostics ?? []).enumerated() {
            let reason = crash.exceptionType?.debugDescription ?? "unknown"
            Log.metrics.fault(
                "MetricKit crash #\(idx + 1, privacy: .public): \(reason, privacy: .public)"
            )
        }

        Analytics.capture("metrickit_crash", [
            "crash_count": .int(crashCount),
        ])
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
