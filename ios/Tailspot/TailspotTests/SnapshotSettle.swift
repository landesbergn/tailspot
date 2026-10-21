//
//  SnapshotSettle.swift
//  TailspotTests
//
//  Shared wait for the window-hosted snapshot harnesses: instead of sleeping
//  a fixed span before `drawHierarchy`, sample the view every 50 ms and stop
//  once it draws the same pixels several samples running. The old fixed
//  sleeps (0.3–3 s per shot) were most of the unit-test wall clock: the suite
//  runs on the main actor, so it is effectively serial, and ~60 s of the CI
//  run was snapshot harnesses waiting on screens that had already settled.
//
//  `atMost` is the old fixed wait, so the poll is never slower than the
//  sleep it replaced. What it detects is committed content changes (layout
//  passes, an async image or `.task` result landing); it does NOT see a
//  Core Animation / SwiftUI animation in flight, which draws from the
//  presentation layer — a mid-animation screen reads as still within the
//  ~0.2 s minimum. A shot that waits out an animation must keep a fixed
//  wait or pass `atLeast` (see ChallengeScreensSnapshotTests' `animated`).
//
//  Two flavours, matching the two harness styles already in the suite:
//  `spin` pumps the run loop (synchronous tests), `wait` sleeps between
//  samples (async tests whose view does work in `.task` — a run-loop spin
//  starves those main-actor jobs; see RevealShortScreenTests).
//
//  Samples render at 1× into a bitmap and compare raw bytes, with
//  `afterScreenUpdates: false` — they read what the run loop has already
//  committed rather than forcing a commit. Forcing one cost ~60 ms a sample
//  (an already-still screen took ~0.45 s to confirm, longer than the 0.3 s
//  waits it replaced), and the forced commits nudged some screens onto a
//  different frame than the old fixed sleep captured. The final capture in
//  each harness still forces its commit, as before. PNGs were diffed against
//  the fixed-sleep output when this landed: identical apart from the
//  randomized onboarding suggestions, a couple of mid-animation pixels that
//  also differ run to run, and the known Liquid Glass offscreen garble.
//

#if DEBUG
import UIKit

@MainActor
enum SnapshotSettle {
    static let tick: TimeInterval = 0.05
    /// Identical samples in a row that count as settled (~150 ms still).
    static let stableSamples = 3

    /// Run-loop flavour, for synchronous tests.
    static func spin(_ view: UIView, bounds: CGRect, atMost cap: TimeInterval) {
        let deadline = Date().addingTimeInterval(cap)
        var tracker = Tracker()
        while Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(tick)))
            if tracker.observe(sample(view, bounds: bounds)) { return }
        }
    }

    /// Task-sleep flavour, for async tests. `atLeast` holds off sampling for
    /// views with a timed sequence that pauses mid-way (the reveal ceremony).
    static func wait(_ view: UIView, bounds: CGRect,
                     atLeast floor: TimeInterval = 0, atMost cap: TimeInterval) async {
        let start = Date()
        var tracker = Tracker()
        while Date().timeIntervalSince(start) < cap {
            try? await Task.sleep(for: .seconds(tick))
            guard Date().timeIntervalSince(start) >= floor else { continue }
            if tracker.observe(sample(view, bounds: bounds)) { return }
        }
    }

    private struct Tracker {
        private var last: Data?
        private var repeats = 0

        /// True once `stableSamples` consecutive samples matched the one before.
        mutating func observe(_ frame: Data?) -> Bool {
            if let frame, frame == last { repeats += 1 } else { repeats = 0 }
            last = frame
            return repeats >= SnapshotSettle.stableSamples
        }
    }

    private static func sample(_ view: UIView, bounds: CGRect) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            view.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
        guard let data = image.cgImage?.dataProvider?.data else { return nil }
        return data as Data
    }
}
#endif
