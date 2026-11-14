//
//  TrophyShareCard.swift
//  Tailspot
//
//  The share artboard for one earned trophy: badge, title, summary, earned
//  date, the player's @handle (when they have claimed one) and the Tailspot
//  wordmark. A fixed-size card (like `CatchShareCard`) rendered to an image
//  with `ImageRenderer` and handed to the system share sheet
//  (`ActivityShareSheet`), so a friend receives a clean picture.
//
//  Dynamic Type is pinned: an artboard is a bitmap, so it must not change
//  shape with the sharer's text size.
//

import SwiftUI
import UIKit

struct TrophyShareCard: View {
    let badge: TrophyBadgeSpec
    let title: String
    let summary: String
    var earnedAt: Date?
    /// Claimed handle without the "@", or nil.
    var handle: String?

    static let size = CGSize(width: 360, height: 450)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "airplane")
                    .foregroundStyle(Brand.Color.cyan)
                    .font(.system(size: 15, weight: .semibold))
                Text("TAILSPOT")
                    .font(Brand.Font.mono(fixedSize: 14, weight: .bold))
                    .tracking(3)
                    .foregroundStyle(Brand.Color.textPrimary)
                Spacer()
                Text("TROPHY")
                    .font(Brand.Font.mono(fixedSize: 11, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(Brand.Color.cyan)
            }

            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Brand.Color.cyan.opacity(0.22), .clear],
                                         center: .center, startRadius: 0, endRadius: 130))
                    .frame(width: 260, height: 260)
                TrophyBadge(badge, size: 170)
            }

            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                    .lineLimit(2)
                Text(summary)
                    .font(.system(size: 15))
                    .foregroundStyle(Brand.Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                if let earnedAt {
                    Text("EARNED \(earnedAt.formatted(.dateTime.month(.abbreviated).day().year()).uppercased())")
                        .font(Brand.Font.mono(fixedSize: 11, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(Brand.Color.textTertiary)
                        .padding(.top, 4)
                }
                if let handle {
                    Text("@\(handle)")
                        .font(Brand.Font.mono(fixedSize: 13, weight: .bold))
                        .foregroundStyle(Brand.Color.cyan)
                }
            }
            .padding(.top, 6)

            Spacer(minLength: 14)

            Text(Brand.monoTight("tailspot.app", size: 10))
                .font(Brand.Font.mono(fixedSize: 10, weight: .semibold))
                .foregroundStyle(Brand.Color.textTertiary)
        }
        .padding(22)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Brand.Color.bgPrimary)
        .environment(\.dynamicTypeSize, .large)
        .environment(\.colorScheme, .dark)
    }

    /// The card as a bitmap (1080 × 1350 px at scale 3).
    @MainActor
    func uiImage() -> UIImage? {
        let renderer = ImageRenderer(content: self)
        renderer.scale = 3
        return renderer.uiImage
    }
}
