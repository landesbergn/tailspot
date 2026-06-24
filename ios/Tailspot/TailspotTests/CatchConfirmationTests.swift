//
//  CatchConfirmationTests.swift
//  TailspotTests
//
//  Covers the reveal-moment "is this right?" verdict: the additive
//  Catch.confirmed flag (nil = unanswered) and the confirm/deny event
//  shape. The UI wiring (CardReveal affordance → ContentView.confirmCatch)
//  is exercised on-device; here we pin the persistence + event contract.
//

import Foundation
import Testing
import SwiftData
@testable import Tailspot

@MainActor
@Suite("Catch confirmation")
struct CatchConfirmationTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Catch.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func sampleCatch() -> Catch {
        Catch(
            icao24: "ac5c1f", callsign: "FDX1268", model: "Boeing 777F",
            manufacturer: "Boeing", caughtAt: Date(),
            observerLat: 37.8, observerLon: -122.3, slantDistanceMeters: 10_900
        )
    }

    @Test func confirmedDefaultsToNil() throws {
        let ctx = try makeContext()
        let c = sampleCatch()
        ctx.insert(c)
        try ctx.save()
        #expect(c.confirmed == nil)   // unanswered until the user taps
    }

    @Test func confirmedPersistsTrueThenFalse() throws {
        let ctx = try makeContext()
        let c = sampleCatch()
        ctx.insert(c)
        c.confirmed = true
        try ctx.save()
        #expect(c.confirmed == true)
        c.confirmed = false
        try ctx.save()
        #expect(c.confirmed == false)
    }

    @Test func confirmationPropertiesCarryIcaoAndRarity() {
        let p = CatchTelemetry.confirmationProperties(icao24: "ac5c1f", rarity: "rare")
        #expect(p["icao24"]?.jsonValue as? String == "ac5c1f")
        #expect(p["rarity"]?.jsonValue as? String == "rare")
    }

    @Test func confirmDenyEventNamesAreStable() {
        #expect(CatchTelemetry.confirmedEvent == "catch_confirmed")
        #expect(CatchTelemetry.deniedEvent == "catch_denied")
    }
}
