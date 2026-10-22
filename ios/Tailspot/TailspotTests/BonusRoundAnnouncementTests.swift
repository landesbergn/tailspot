//
//  BonusRoundAnnouncementTests.swift
//  TailspotTests
//
//  Pins the VoiceOver copy for the in-card bonus round (a11y pass,
//  2026-10-22). The reveal posts these strings when the chips pop in and
//  when the round resolves; before, the whole round was silent.
//

import Testing
@testable import Tailspot

@Suite("Bonus round VoiceOver copy")
struct BonusRoundAnnouncementTests {

    @Test func poppedReadsPromptAndChoiceCount() {
        #expect(BonusRoundAnnouncement.popped(prompt: "Where's it headed?", choiceCount: 4)
                == "Bonus round. Where's it headed? 4 choices.")
        #expect(BonusRoundAnnouncement.popped(prompt: "Where's it coming from?", choiceCount: 4)
                == "Bonus round. Where's it coming from? 4 choices.")
    }

    @Test func poppedAddsAFullStopOnlyWhenThePromptHasNone() {
        #expect(BonusRoundAnnouncement.popped(prompt: "Pick one", choiceCount: 3)
                == "Bonus round. Pick one. 3 choices.")
    }

    @Test func poppedUsesTheRealQuestionPrompts() {
        // Every prompt the live question can produce ends in "?", so none
        // gets a doubled "?." in the spoken line.
        for endpoint in [GuessOptions.RouteEndpoint.origin, .destination] {
            let q = GuessRoundQuestion(route: .init(
                endpoint: endpoint,
                options: [.init(value: "KSFO", display: "SFO")],
                correctValue: "KSFO"))
            let line = BonusRoundAnnouncement.popped(prompt: q.prompt, choiceCount: 4)
            #expect(!line.contains("?."))
            #expect(line.hasPrefix("Bonus round. "))
        }
    }

    @Test func resolvedCorrectSaysTheBonus() {
        #expect(BonusRoundAnnouncement.resolved(correct: true, answered: true,
                                                bonus: 13, correctDisplay: "HKG")
                == "Correct, plus 13 points.")
    }

    @Test func resolvedWrongNamesTheRightAnswer() {
        #expect(BonusRoundAnnouncement.resolved(correct: false, answered: true,
                                                bonus: 13, correctDisplay: "HKG")
                == "Not quite. It was HKG.")
    }

    @Test func resolvedSkipNamesTheRightAnswer() {
        #expect(BonusRoundAnnouncement.resolved(correct: false, answered: false,
                                                bonus: 13, correctDisplay: "HKG")
                == "Skipped. It was HKG.")
    }
}
