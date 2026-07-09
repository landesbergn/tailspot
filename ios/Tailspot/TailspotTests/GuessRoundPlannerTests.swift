//
//  GuessRoundPlannerTests.swift
//  TailspotTests
//
//  Pins the pure eligibility translation (game-layer PR3): the mapping from a
//  catch batch's shape + its single fresh row's frozen fields to the
//  GuessScheduler inputs. Keeps ContentView's sequencing a thin call — the
//  "should this catch host a bonus round?" rule lives here and is tested off
//  the MainActor. Route/type availability delegate to GuessOptions (pinned by
//  GuessOptionsTests); these assert the batch gate + wiring.
//

import Foundation
import Testing
@testable import Tailspot

@Suite("GuessRoundPlanner — eligibility inputs")
struct GuessRoundPlannerTests {

    @Test func freshSingleWithRouteAndTypeCanOfferRound() {
        let inputs = GuessRoundPlanner.inputs(
            freshCount: 1, duplicateCount: 0, suspectReason: nil,
            originIcao: "KSFO", destIcao: "VHHH", typecode: "B738"
        )
        #expect(inputs.isFreshSingle)
        #expect(!inputs.isSuspect)
        #expect(inputs.routeAvailable)
        #expect(inputs.typeAvailable)
        #expect(inputs.canOfferRound)
    }

    @Test func aDuplicateInTheBatchIsNeverFreshSingle() {
        let inputs = GuessRoundPlanner.inputs(
            freshCount: 1, duplicateCount: 1, suspectReason: nil,
            originIcao: "KSFO", destIcao: "VHHH", typecode: "B738"
        )
        #expect(!inputs.isFreshSingle)
        #expect(!inputs.canOfferRound)
    }

    @Test func aMultiCatchIsNeverFreshSingle() {
        let inputs = GuessRoundPlanner.inputs(
            freshCount: 2, duplicateCount: 0, suspectReason: nil,
            originIcao: "KSFO", destIcao: "VHHH", typecode: "B738"
        )
        #expect(!inputs.isFreshSingle)
        #expect(!inputs.canOfferRound)
    }

    @Test func aDuplicateOnlyBatchIsNeverFreshSingle() {
        let inputs = GuessRoundPlanner.inputs(
            freshCount: 0, duplicateCount: 1, suspectReason: nil,
            originIcao: nil, destIcao: nil, typecode: nil
        )
        #expect(!inputs.isFreshSingle)
        #expect(!inputs.canOfferRound)
    }

    @Test func suspectReasonFlagsSuspectButStaysFreshSingle() {
        // The scheduler (not this flag) uses isSuspect to decline; a suspect
        // fresh single is still a fresh single, so the flag must surface.
        let inputs = GuessRoundPlanner.inputs(
            freshCount: 1, duplicateCount: 0, suspectReason: "too_far",
            originIcao: "KSFO", destIcao: "VHHH", typecode: "B738"
        )
        #expect(inputs.isFreshSingle)
        #expect(inputs.isSuspect)
    }

    @Test func noRouteNoTypeCannotOfferRound() {
        let inputs = GuessRoundPlanner.inputs(
            freshCount: 1, duplicateCount: 0, suspectReason: nil,
            originIcao: nil, destIcao: nil, typecode: nil
        )
        #expect(inputs.isFreshSingle)
        #expect(!inputs.routeAvailable)
        #expect(!inputs.typeAvailable)
        #expect(!inputs.canOfferRound)
    }

    @Test func typeOnlyCatchStillOffersRound() {
        // A routeless GA plane with a known typecode still hosts a type round.
        let inputs = GuessRoundPlanner.inputs(
            freshCount: 1, duplicateCount: 0, suspectReason: nil,
            originIcao: nil, destIcao: nil, typecode: "B738"
        )
        #expect(!inputs.routeAvailable)
        #expect(inputs.typeAvailable)
        #expect(inputs.canOfferRound)
    }

    @Test func routeOnlyCatchStillOffersRound() {
        // A known route but an unresolvable typecode still hosts a route round.
        let inputs = GuessRoundPlanner.inputs(
            freshCount: 1, duplicateCount: 0, suspectReason: nil,
            originIcao: "KSFO", destIcao: "VHHH", typecode: "ZZZ9"
        )
        #expect(inputs.routeAvailable)
        #expect(!inputs.typeAvailable)
        #expect(inputs.canOfferRound)
    }
}
