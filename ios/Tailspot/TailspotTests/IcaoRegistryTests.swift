//
//  IcaoRegistryTests.swift
//  TailspotTests
//
//  Tests for the deterministic US ICAO 24-bit address <-> N-number
//  encoding. Known-good pairs verified against the FAA's positional
//  encoding algorithm.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("IcaoRegistry")
nonisolated struct IcaoRegistryTests {

    // MARK: - nNumber(forIcao24:)

    @Test func nNumberCirrusSR20() {
        // a9eefa -> N7391E (confirmed against FAA algorithm)
        #expect(IcaoRegistry.nNumber(forIcao24: "a9eefa") == "N7391E")
    }

    @Test func nNumberEmbraerE175() {
        // a8d71c -> N669PY (confirmed against FAA algorithm)
        #expect(IcaoRegistry.nNumber(forIcao24: "a8d71c") == "N669PY")
    }

    @Test func nNumberPilatus() {
        // a00965 -> N101KA (confirmed against FAA algorithm)
        #expect(IcaoRegistry.nNumber(forIcao24: "a00965") == "N101KA")
    }

    @Test func nNumberKoreanReturnsNil() {
        // 71c575 is in the Korean block, not US civil
        #expect(IcaoRegistry.nNumber(forIcao24: "71c575") == nil)
    }

    @Test func nNumberCanadianReturnsNil() {
        // ae2691 is in the Canadian block (AE0000+), not US civil
        #expect(IcaoRegistry.nNumber(forIcao24: "ae2691") == nil)
    }

    @Test func nNumberGarbageReturnsNil() {
        #expect(IcaoRegistry.nNumber(forIcao24: "garbage") == nil)
    }

    @Test func nNumberEmptyReturnsNil() {
        #expect(IcaoRegistry.nNumber(forIcao24: "") == nil)
    }

    @Test func nNumberUppercaseInput() {
        // Input is case-insensitive hex
        #expect(IcaoRegistry.nNumber(forIcao24: "A9EEFA") == "N7391E")
    }

    // MARK: - isUS(icao24:)

    @Test func isUSForUSCivilIcao() {
        #expect(IcaoRegistry.isUS(icao24: "a9eefa") == true)
    }

    @Test func isUSForKorean() {
        #expect(IcaoRegistry.isUS(icao24: "71c575") == false)
    }

    @Test func isUSForGarbage() {
        #expect(IcaoRegistry.isUS(icao24: "garbage") == false)
    }
}
