//
//  HangarSetsView.swift
//  Tailspot
//
//  Sets-view body for the Hangar sheet. Vertical list of 7 set tiles
//  (one per AircraftType, in the curated order baked into
//  `PokeSets.all`: Narrow / Wide / Regional / Biz / Mil / GA /
//  Heritage). Each tile shows the number of distinct tails the user
//  has caught in that type — no curated enumeration, no locked
//  silhouettes. Tap → SetDetailView, which lists the model groups the
//  user has actually caught in that type.
//
//  Revamped 2026-05-26 per Noah's field-test feedback: "show the
//  number of planes caught per category" rather than enumerate
//  possible slots. Keeps the surface flexible as planes are added to
//  the OpenSky model space over time.
//

import SwiftUI
import SwiftData

struct HangarSetsView: View {
    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]

    /// One flat dedup'd row list (Recent mode collapses by icao24).
    /// Each tile then filters to its own type.
    private var rows: [HangarRow] {
        HangarGrouping.group(catches, by: .recent).first?.rows ?? []
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(PokeSets.all) { set in
                    let tailCount = rows.filter { $0.aircraftType == set.type }.count
                    NavigationLink(value: SetDetailRoute(setId: set.id)) {
                        SetTile(set: set, tailCount: tailCount)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Brand.Color.bgPrimary)
    }
}

/// Stable navigation target — set identified by its `PokeSet.id`
/// ("narrow", "wide", "regional"...). HangarView's NavigationStack
/// resolves this into a `SetDetailView` by looking up `PokeSets.all`.
struct SetDetailRoute: Hashable {
    let setId: String
}

// MARK: - Tile

private struct SetTile: View {
    let set: PokeSet
    let tailCount: Int

    private var isLocked: Bool { tailCount == 0 }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(set.type.tint)
                Text(set.type.glyph)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black.opacity(0.7))
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(set.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.Color.textPrimary)
                Text(set.type.summary)
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 0) {
                Text("\(tailCount)")
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(isLocked ? Brand.Color.textTertiary : set.type.tint)
                Text("caught")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(Brand.Color.textTertiary)
            }
        }
        .padding(14)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 10))
        .opacity(isLocked ? 0.6 : 1.0)
    }
}

// The real `SetDetailView` lives in `SetDetailView.swift`.
// Routing from `SetDetailRoute` is wired in `HangarView` via
// `.navigationDestination(for: SetDetailRoute.self)`.
