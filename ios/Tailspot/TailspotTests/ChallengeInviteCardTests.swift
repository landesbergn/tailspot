//
//  ChallengeInviteCardTests.swift
//  TailspotTests
//
//  The invite link preview: the share sheet must still hand every app the
//  plain invite URL, and the LPLinkMetadata beside it must carry the
//  challenge's own title and a rendered card, so Messages stops showing the
//  App Store listing the link redirects to.
//

import Foundation
import LinkPresentation
import Testing
import UIKit
@testable import Tailspot

@MainActor
@Suite("Challenge invite link preview")
struct ChallengeInviteCardTests {

    private func summary(name: String = "Weekend Flyoff", code: String? = "K7M4QD") throws -> ChallengeSummary {
        let codeJSON = code.map { "\"\($0)\"" } ?? "null"
        let json = """
        {
          "id": "c1", "kind": "private", "code": \(codeJSON),
          "inviteURL": "https://tailspot.app/c/K7M4QD", "name": "\(name)",
          "creatorHandle": "eli", "startsAt": "2026-09-20T09:00:00.000Z",
          "endsAt": "2026-09-23T09:00:00.000Z", "durationPreset": "3d",
          "maxParticipants": 10, "status": "upcoming", "outcome": null,
          "participantCount": 1, "isCreator": true, "isParticipant": true
        }
        """
        return try ChallengeJSON.decoder.decode(ChallengeSummary.self, from: Data(json.utf8))
    }

    private let url = URL(string: "https://tailspot.app/c/K7M4QD")!

    @Test func cardRendersAtLinkPreviewSize() throws {
        let image = try #require(ChallengeInviteCard.uiImage(for: try summary()))
        #expect(image.size.width * image.scale == 1200)
        #expect(image.size.height * image.scale == 628)
        exportIfRequested(image, "invite-card")
    }

    /// A long name and no code must still render at the fixed size (the
    /// name scales down rather than growing the card).
    @Test func longNameWithoutCodeKeepsTheSize() throws {
        let long = try summary(name: "The Extremely Long Bay Area Heavy Metal Spotting Championship", code: nil)
        let image = try #require(ChallengeInviteCard.uiImage(for: long))
        #expect(image.size.width * image.scale == 1200)
        #expect(image.size.height * image.scale == 628)
        exportIfRequested(image, "invite-card-long")
    }

    @Test func itemSourceSharesThePlainURL() throws {
        let source = ChallengeInviteItemSource(url: url, challenge: try summary())
        let sheet = UIActivityViewController(activityItems: [], applicationActivities: nil)
        #expect(source.activityViewControllerPlaceholderItem(sheet) as? URL == url)
        #expect(source.activityViewController(sheet, itemForActivityType: .message) as? URL == url)
        #expect(source.activityViewController(sheet, itemForActivityType: .copyToPasteboard) as? URL == url)
        #expect(source.activityViewController(sheet, itemForActivityType: nil) as? URL == url)
    }

    @Test func metadataCarriesTheChallenge() throws {
        let source = ChallengeInviteItemSource(url: url, challenge: try summary())
        let sheet = UIActivityViewController(activityItems: [], applicationActivities: nil)
        let metadata = try #require(source.activityViewControllerLinkMetadata(sheet))
        #expect(metadata.title == "Weekend Flyoff · Tailspot challenge")
        #expect(metadata.url == url)
        #expect(metadata.originalURL == url)
        #expect(metadata.imageProvider != nil)
    }

    /// Writes the PNG for a visual check when the run sets
    /// TEST_RUNNER_INVITE_CARD_DIR (xcodebuild strips the prefix).
    private func exportIfRequested(_ image: UIImage, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["INVITE_CARD_DIR"],
              let png = image.pngData() else { return }
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}
