//
//  TrophyAdvanceStrip.swift
//  Tailspot
//
//  The one quiet line on the catch reveal that says which trophy track this
//  catch moved: a small badge (the level being chased), "Airlines III", a
//  thin progress bar and "28 / 30" in mono cyan. Its job is to let the player
//  SEE the goal move at the moment of the catch.
//
//  It is plain data in (`TrophyAdvance`, computed by `TrophyUnlockCenter`),
//  so snapshots can render it without the unlock center. It is not
//  interactive, and the reveal places it as an overlay (see
//  `CatchRevealView.trophyStripOverlay`) so its arrival never moves the card.
//

import SwiftUI

extension TrophyAdvance {
    /// "Airlines III": the track and the level being chased.
    nonisolated var title: String { "\(track.name) \(TrophyTracks.roman(level))" }

    /// "28 / 30" (grouped digits for the big tracks, e.g. points).
    nonisolated var countText: String {
        "\(Self.grouped(progress)) / \(Self.grouped(goal))"
    }

    /// One combined VoiceOver phrase: "Airlines level 3, 28 of 30".
    nonisolated var accessibilityText: String {
        "\(track.name) level \(level), \(Self.grouped(progress)) of \(Self.grouped(goal))"
    }

    /// The ring: the track's segments, those below the chased level lit.
    nonisolated var badgeSpec: TrophyBadgeSpec {
        TrophyBadgeSpec(symbol: track.symbol, segments: max(1, track.levelIDs.count),
                        filled: max(0, level - 1), earned: level > 1, masked: false)
    }

    private nonisolated static func grouped(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic))
    }
}

struct TrophyAdvanceStrip: View {
    let advance: TrophyAdvance
    /// One slim row (no container) for short screens, where the strip has to
    /// fit the reveal's 24 pt of air above the Continue row. The regular form
    /// is a two-row pill. Both are fixed-size (they sit under a fixed-size
    /// card, like the CTA row).
    var compact = false

    /// Heights the reveal reserves its overlay slot by.
    static let regularHeight: CGFloat = 42
    static let compactHeight: CGFloat = 22

    var body: some View {
        Group {
            if compact { compactBody } else { regularBody }
        }
        // The strip has a fixed height (it overlays a fixed slot), so its
        // text scales with Dynamic Type only up to what that height holds.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(advance.accessibilityText)
    }

    private var regularBody: some View {
        HStack(spacing: 10) {
            TrophyBadge(advance.badgeSpec, size: 30)
            VStack(spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(advance.title)
                        .font(.footnote.weight(.medium))
                        .minimumScaleFactor(0.8)
                        .foregroundColor(RP.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    count
                }
                bar
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.regularHeight)
        .background(RoundedRectangle(cornerRadius: Brand.Radius.row, style: .continuous)
            .fill(Brand.Color.bgElevated))
    }

    private var compactBody: some View {
        HStack(spacing: 8) {
            TrophyBadge(advance.badgeSpec, size: 20)
            Text(advance.title)
                .font(.caption.weight(.medium))
                .foregroundColor(RP.ink)
                .lineLimit(1)
                .fixedSize()
            bar
            count
        }
        .padding(.horizontal, 4)
        .frame(height: Self.compactHeight)
    }

    private var count: some View {
        Text(advance.countText)
            .font(Brand.Font.mono(fixedSize: 11, weight: .semibold))
            .foregroundColor(Brand.Color.cyan)
            .lineLimit(1)
            .fixedSize()
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(RP.rule)
                Capsule().fill(Brand.Color.cyan)
                    .frame(width: max(3, geo.size.width * advance.fraction))
            }
        }
        .frame(height: 3)
    }
}
