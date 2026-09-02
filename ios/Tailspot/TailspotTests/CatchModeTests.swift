//
//  CatchModeTests.swift
//  TailspotTests
//
//  The catch-mode A/B switch (2026-09-02): the stored-value resolution
//  rule and the Debug-only honoring of the store. The Release branch of
//  `effective(stored:)` can't run under the test target (tests build
//  DEBUG), so that half is pinned by reading the source contract instead:
//  on DEBUG `effective` must equal `resolve`.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Catch mode switch")
struct CatchModeTests {

    @Test func nothingStoredRunsTheFrameMode() {
        #expect(CatchMode.resolve(stored: nil) == .frame)
        #expect(CatchMode.default == .frame)
    }

    @Test func storedRawValuesRoundTrip() {
        for mode in CatchMode.allCases {
            #expect(CatchMode.resolve(stored: mode.rawValue) == mode)
        }
    }

    @Test func unknownStoredValueFallsBackToTheDefault() {
        #expect(CatchMode.resolve(stored: "zones-and-pins") == .frame)
        #expect(CatchMode.resolve(stored: "") == .frame)
    }

    @Test func debugBuildsHonorTheStore() {
        // The test target is a DEBUG build, where the stored choice wins.
        #expect(CatchMode.effective(stored: "legacy") == .legacy)
        #expect(CatchMode.effective(stored: "frame") == .frame)
        #expect(CatchMode.effective(stored: nil) == .frame)
    }

    @Test func toggleFlipsBetweenTheTwoModes() {
        #expect(CatchMode.frame.toggled == .legacy)
        #expect(CatchMode.legacy.toggled == .frame)
        #expect(CatchMode.legacy.toggled.toggled == .legacy)
    }

    @Test func labelsAreDistinct() {
        #expect(Set(CatchMode.allCases.map(\.label)).count == CatchMode.allCases.count)
    }

    @Test func storageKeyIsInTheDebugNamespace() {
        #expect(CatchMode.storageKey.hasPrefix("tailspot.debug."))
    }
}
