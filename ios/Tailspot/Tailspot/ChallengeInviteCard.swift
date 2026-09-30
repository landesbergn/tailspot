//
//  ChallengeInviteCard.swift
//  Tailspot
//
//  The link preview for a shared challenge invite. Without it, Messages
//  fetched https://tailspot.app/c/CODE itself, followed the 302 to the App
//  Store, and showed the generic App Store listing image, which said
//  nothing about the challenge.
//
//  Explain-as-we-go: `UIActivityViewController` accepts plain values
//  (strings, URLs) or a `UIActivityItemSource`, an object it asks for the
//  item lazily. One of the source's optional methods,
//  `activityViewControllerLinkMetadata(_:)`, returns an `LPLinkMetadata`
//  (from Apple's LinkPresentation framework): title, URL, and a preview
//  image. When that is supplied, the share sheet header and the Messages
//  rich-link bubble use it instead of fetching the page, so the recipient
//  sees this card. Apps that fetch the link on their own (WhatsApp, Slack)
//  still follow the redirect; this covers iMessage, where invites mostly go.
//
//  The card is drawn with SwiftUI and stamped to a bitmap with
//  `ImageRenderer`, the same approach as `CatchShareCard`.
//

import LinkPresentation
import SwiftUI
import UIKit

/// The 1.91:1 artboard Messages shows as the large link-preview image.
struct ChallengeInviteCard: View {
    let name: String
    let creatorHandle: String
    let durationPreset: String
    let startsAt: Date
    let endsAt: Date
    let code: String?
    var calendar: Calendar = .current

    static let size = CGSize(width: 600, height: 314)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "airplane")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.Color.cyan)
                Text("TAILSPOT")
                    .font(Brand.Font.mono(size: 14, weight: .bold))
                    .tracking(3)
                    .foregroundStyle(Brand.Color.textPrimary)
                Spacer()
                Text("CHALLENGE INVITE")
                    .font(Brand.Font.mono(size: 12, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(Brand.Color.cyan)
            }

            Spacer(minLength: 16)

            Text("@\(creatorHandle) challenges you to")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Brand.Color.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(name)
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(Brand.Color.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .padding(.top, 4)

            Spacer(minLength: 16)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ChallengeCopy.durationLabel(durationPreset).uppercased())
                        .font(Brand.Font.mono(size: 12, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(Brand.Color.textTertiary)
                    Text(ChallengeCopy.windowLine(startsAt: startsAt, endsAt: endsAt, calendar: calendar))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Brand.Color.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 16)
                if let code {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("CODE")
                            .font(Brand.Font.mono(size: 10, weight: .semibold))
                            .tracking(1.2)
                            .foregroundStyle(Brand.Color.textTertiary)
                        Text(code)
                            .font(Brand.Font.mono(size: 26, weight: .bold))
                            .tracking(3)
                            .foregroundStyle(Brand.Color.cyan)
                    }
                }
            }
        }
        .padding(28)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(
            LinearGradient(colors: [Brand.Color.bgElevated, Brand.Color.bgPrimary],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
        )
        .overlay(alignment: .topTrailing) {
            // A faint oversized plane, so the card reads as Tailspot at
            // thumbnail size where the text is too small to matter.
            Image(systemName: "airplane")
                .font(.system(size: 220, weight: .regular))
                .rotationEffect(.degrees(-30))
                .foregroundStyle(Brand.Color.cyan.opacity(0.06))
                .offset(x: 50, y: 30)
        }
        .clipped()
    }
}

extension ChallengeInviteCard {
    init(challenge s: ChallengeSummary) {
        self.init(name: s.name, creatorHandle: s.creatorHandle, durationPreset: s.durationPreset,
                  startsAt: s.startsAt, endsAt: s.endsAt, code: s.code)
    }

    /// The card as a bitmap (1200×628 px at scale 2).
    @MainActor
    static func uiImage(for challenge: ChallengeSummary) -> UIImage? {
        let renderer = ImageRenderer(content: ChallengeInviteCard(challenge: challenge))
        renderer.scale = 2
        return renderer.uiImage
    }
}

/// The invite URL as a share-sheet item that carries its own preview.
/// Hands the share sheet the plain URL (so Copy, Mail and every app still
/// get a normal link) plus `LPLinkMetadata` with the rendered card.
final class ChallengeInviteItemSource: NSObject, UIActivityItemSource {
    let url: URL
    let metadata: LPLinkMetadata

    init(url: URL, title: String, image: UIImage?) {
        self.url = url
        let metadata = LPLinkMetadata()
        metadata.originalURL = url
        metadata.url = url
        metadata.title = title
        if let image {
            metadata.imageProvider = NSItemProvider(object: image)
        }
        self.metadata = metadata
    }

    /// Built from a challenge: title is the challenge name, image the card.
    @MainActor
    convenience init(url: URL, challenge: ChallengeSummary) {
        self.init(url: url, title: Self.title(for: challenge),
                  image: ChallengeInviteCard.uiImage(for: challenge))
    }

    /// The bold line under the preview image.
    static func title(for challenge: ChallengeSummary) -> String {
        "\(challenge.name) · Tailspot challenge"
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        url
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        metadata
    }
}
