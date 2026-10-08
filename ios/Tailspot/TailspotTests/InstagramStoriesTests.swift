//
//  InstagramStoriesTests.swift
//  TailspotTests
//
//  Pins the hand-off contract with Instagram's story editor: the URL shape
//  (Meta rejects requests without `source_application`) and the pasteboard
//  keys it reads. A typo in either fails silently on device: Instagram just
//  opens an empty editor.
//

import Foundation
import Testing
@testable import Tailspot

@Suite struct InstagramStoriesTests {

    @Test func shareURLCarriesSourceApplication() throws {
        let url = try #require(InstagramStories.shareURL(appID: "1234567890"))
        #expect(url.absoluteString == "instagram-stories://share?source_application=1234567890")
    }

    @Test func pasteboardItemWithBackgroundImage() {
        let item = InstagramStories.pasteboardItem(sticker: Data([1]), background: Data([2]))
        #expect(item["com.instagram.sharedSticker.stickerImage"] as? Data == Data([1]))
        #expect(item["com.instagram.sharedSticker.backgroundImage"] as? Data == Data([2]))
        #expect(item["com.instagram.sharedSticker.backgroundTopColor"] == nil)
    }

    @Test func pasteboardItemFallsBackToGradientColors() {
        let item = InstagramStories.pasteboardItem(sticker: Data([1]), background: nil)
        #expect(item["com.instagram.sharedSticker.backgroundImage"] == nil)
        #expect(item["com.instagram.sharedSticker.backgroundTopColor"] as? String == "#0A0E1A")
        #expect(item["com.instagram.sharedSticker.backgroundBottomColor"] as? String == "#050810")
    }
}
