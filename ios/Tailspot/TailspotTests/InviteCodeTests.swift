//
//  InviteCodeTests.swift
//  TailspotTests
//
//  Code normalization (lowercase, spaces, dashes, wrong length, ambiguous
//  characters rejected) and universal-link parsing for both hosts, a
//  trailing slash, wrong host and wrong path (spec section 13).
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Invite code")
struct InviteCodeTests {

    // MARK: - alphabet

    @Test func alphabetHas31Symbols() {
        #expect(InviteCode.alphabet.count == 31)
    }

    @Test func alphabetExcludesAmbiguousCharacters() {
        for bad in "01IL O".compactMap({ $0 == " " ? nil : $0 }) {
            #expect(!InviteCode.alphabet.contains(bad))
        }
    }

    // MARK: - normalize

    @Test func normalizeAcceptsValidUppercaseCode() {
        #expect(InviteCode.normalize("K7M4QD2X") == "K7M4QD2X")
    }

    @Test func normalizeUppercasesLowercaseInput() {
        #expect(InviteCode.normalize("k7m4qd2x") == "K7M4QD2X")
    }

    @Test func normalizeStripsSpaces() {
        #expect(InviteCode.normalize("K7M4 QD2X") == "K7M4QD2X")
        #expect(InviteCode.normalize("K7 M4 QD 2X") == "K7M4QD2X")
    }

    @Test func normalizeStripsDashes() {
        #expect(InviteCode.normalize("K7M4-QD2X") == "K7M4QD2X")
    }

    /// The backend strips `[\s-]` before validating, so anything it would
    /// accept has to normalize here too — a code pasted out of Messages can
    /// carry a newline, a tab or a non-breaking space.
    @Test func normalizeStripsEveryKindOfWhitespace() {
        #expect(InviteCode.normalize("K7M4\nQD2X") == "K7M4QD2X")
        #expect(InviteCode.normalize("K7M4\tQD2X") == "K7M4QD2X")
        #expect(InviteCode.normalize("\n K7M4-QD2X \r\n") == "K7M4QD2X")
        #expect(InviteCode.normalize("K7M4\u{00A0}QD2X") == "K7M4QD2X")  // non-breaking space
    }

    @Test func normalizeRejectsWrongLength() {
        #expect(InviteCode.normalize("K7M4QD2") == nil)   // 7 chars
        #expect(InviteCode.normalize("K7M4QD2XX") == nil) // 9 chars
    }

    @Test func normalizeRejectsAmbiguousCharacters() {
        #expect(InviteCode.normalize("K7M4QD2O") == nil) // O
        #expect(InviteCode.normalize("K7M4QD20") == nil) // 0
        #expect(InviteCode.normalize("K7M4QDI2") == nil) // I (7 alnum but has I)
        #expect(InviteCode.normalize("K7M4QD12") == nil) // 1
        #expect(InviteCode.normalize("K7M4QDL2") == nil) // L
    }

    // MARK: - parse(url:)

    @Test func parseAcceptsBareHost() {
        let url = URL(string: "https://tailspot.app/c/K7M4QD2X")!
        #expect(InviteCode.parse(url: url) == "K7M4QD2X")
    }

    @Test func parseAcceptsWWWHost() {
        let url = URL(string: "https://www.tailspot.app/c/K7M4QD2X")!
        #expect(InviteCode.parse(url: url) == "K7M4QD2X")
    }

    @Test func parseAcceptsTrailingSlash() {
        let url = URL(string: "https://tailspot.app/c/K7M4QD2X/")!
        #expect(InviteCode.parse(url: url) == "K7M4QD2X")
    }

    @Test func parseRejectsWrongHost() {
        let url = URL(string: "https://evil.example.com/c/K7M4QD2X")!
        #expect(InviteCode.parse(url: url) == nil)
    }

    @Test func parseRejectsWrongPath() {
        let url = URL(string: "https://tailspot.app/challenges/K7M4QD2X")!
        #expect(InviteCode.parse(url: url) == nil)
        let url2 = URL(string: "https://tailspot.app/c/K7M4QD2X/extra")!
        #expect(InviteCode.parse(url: url2) == nil)
    }

    @Test func parseRejectsMalformedCodeInValidPath() {
        let url = URL(string: "https://tailspot.app/c/short")!
        #expect(InviteCode.parse(url: url) == nil)
    }

    // MARK: - inviteURL

    @Test func inviteURLRoundTrips() {
        let url = InviteCode.inviteURL(for: "K7M4QD2X")
        #expect(InviteCode.parse(url: url) == "K7M4QD2X")
        #expect(url.absoluteString == "https://tailspot.app/c/K7M4QD2X")
    }
}
