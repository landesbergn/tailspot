//
//  FAARegistryTests.swift
//  TailspotTests
//
//  Integration tests for FAARegistry against the REAL bundled assets
//  (faa-aircraft.bin + faa-models.json). Tests run hosted in the app,
//  so Bundle.main resolves to the Tailspot bundle.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("FAARegistry")
nonisolated struct FAARegistryTests {

    // MARK: - Known US aircraft (integration tests against real bundle)

    @Test func recordForCirrusSR20() {
        // icao a9eefa -> Cirrus SR20, GA
        let rec = FAARegistry.record(forIcao24: "a9eefa")
        #expect(rec != nil)
        #expect(rec?.make == "Cirrus")
        #expect(rec?.model == "SR20")
        #expect(rec?.type == .ga)
    }

    @Test func recordForEmbraerE175() {
        // icao a8d71c -> Embraer ERJ 170-200 LR, regional
        let rec = FAARegistry.record(forIcao24: "a8d71c")
        #expect(rec != nil)
        #expect(rec?.make == "Embraer")
        #expect(rec?.model == "ERJ 170-200 LR")
        #expect(rec?.type == .regional)
    }

    @Test func recordForPilatus() {
        // icao a00965 -> Pilatus, GA
        let rec = FAARegistry.record(forIcao24: "a00965")
        #expect(rec != nil)
        #expect(rec?.make == "Pilatus")
        #expect(rec?.type == .ga)
    }

    // MARK: - Non-US / out-of-range

    @Test func recordForKoreanReturnsNil() {
        // 71c575 is not in the US civil block
        #expect(FAARegistry.record(forIcao24: "71c575") == nil)
    }

    @Test func recordForAllFFReturnsNil() {
        // ffffff is above US civil block
        #expect(FAARegistry.record(forIcao24: "ffffff") == nil)
    }

    @Test func recordForGarbageReturnsNil() {
        #expect(FAARegistry.record(forIcao24: "garbage") == nil)
    }

    // MARK: - Case insensitivity

    @Test func recordForUppercaseIcao() {
        let lower = FAARegistry.record(forIcao24: "a9eefa")
        let upper = FAARegistry.record(forIcao24: "A9EEFA")
        #expect(lower == upper)
    }
}
