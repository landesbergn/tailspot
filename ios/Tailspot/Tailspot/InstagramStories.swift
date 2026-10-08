//
//  InstagramStories.swift
//  Tailspot
//
//  Direct share into Instagram's story editor, the path Spotify and Strava
//  use for stories. Instead of a flattened image through the system share
//  sheet, the app hands Instagram two layers on the pasteboard: the catch
//  card as a movable sticker, and a 9:16 backdrop. Instagram opens its
//  editor with both, so the user can move, resize and draw before posting.
//
//  Meta requires a registered Facebook app ID on every request
//  (`source_application`). Until `META_APP_ID` is set in the xcconfig,
//  `isConfigured` is false and the share sheet's story button falls back
//  to the system share sheet with the flattened 9:16 image.
//
//  iOS note: `canOpenURL` only answers for schemes listed under
//  `LSApplicationQueriesSchemes` in Info.plist (an Apple privacy rule), so
//  `instagram-stories` is listed there. Pasteboard items carry a short
//  expiration so the images don't linger after the hand-off.
//

import UIKit

enum InstagramStories {
    /// Meta app ID from Info.plist (`MetaAppID`, fed by `META_APP_ID` in
    /// Tailspot.xcconfig). nil when unset.
    static var appID: String? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "MetaAppID") as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static var isConfigured: Bool { appID != nil }

    /// `instagram-stories://share?source_application=<id>`.
    nonisolated static func shareURL(appID: String) -> URL? {
        var c = URLComponents()
        c.scheme = "instagram-stories"
        c.host = "share"
        c.queryItems = [URLQueryItem(name: "source_application", value: appID)]
        return c.url
    }

    /// Pasteboard keys Instagram's story editor reads.
    nonisolated enum Key {
        static let sticker = "com.instagram.sharedSticker.stickerImage"
        static let background = "com.instagram.sharedSticker.backgroundImage"
        static let topColor = "com.instagram.sharedSticker.backgroundTopColor"
        static let bottomColor = "com.instagram.sharedSticker.backgroundBottomColor"
    }

    /// The single pasteboard item: sticker PNG, plus the backdrop JPEG when
    /// there is one, else a top/bottom gradient in the app's dark tones.
    nonisolated static func pasteboardItem(sticker: Data, background: Data?) -> [String: Any] {
        var item: [String: Any] = [Key.sticker: sticker]
        if let background {
            item[Key.background] = background
        } else {
            item[Key.topColor] = "#0A0E1A"
            item[Key.bottomColor] = "#050810"
        }
        return item
    }

    /// True when the app ID is set and Instagram is installed.
    static func canShare() -> Bool {
        guard let id = appID, let url = shareURL(appID: id) else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// Put the layers on the pasteboard and open Instagram's story editor.
    /// Returns false (nothing opened) when not configured or encoding fails.
    @discardableResult
    static func share(sticker: UIImage, background: UIImage?) -> Bool {
        guard let id = appID, let url = shareURL(appID: id),
              let stickerData = sticker.pngData() else { return false }
        let item = pasteboardItem(sticker: stickerData, background: background?.jpegData(compressionQuality: 0.9))
        UIPasteboard.general.setItems(
            [item],
            options: [.expirationDate: Date().addingTimeInterval(5 * 60)]
        )
        UIApplication.shared.open(url)
        return true
    }
}
