//
//  HangarSetsView.swift
//  Tailspot
//
//  Sets-view body for the Hangar sheet. Vertical list of 7 set tiles
//  (one per AircraftType, in the curated order baked into
//  `PokeSets.all`: Narrow / Wide / Regional / Biz / Mil / GA /
//  Heritage). Each tile shows slot-progress + a thumbnail strip of
//  caught vs locked model slots. Tap → SetDetailView (Task 16 fills
//  it in; the stub at the bottom of this file is the temporary
//  destination). Spec § 5.1.
//

import SwiftUI
import SwiftData

struct HangarSetsView: View {
    /// Pulled from the model container injected by TailspotApp. The
    /// @Query auto-updates when new Catches are inserted — so the set
    /// tiles repopulate without us having to reach across to HangarView.
    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]

    /// One flat dedup'd row list (Recent mode collapses by icao24 only,
    /// without any section bucketing). `resolveSlots(for:in:)` then
    /// pivots that into per-entry slots for each set.
    private var rows: [HangarRow] {
        HangarGrouping.group(catches, by: .recent).first?.rows ?? []
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(PokeSets.all) { set in
                    NavigationLink(value: SetDetailRoute(setId: set.id)) {
                        SetTile(set: set, slots: HangarGrouping.resolveSlots(for: set, in: rows))
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

/// Stable navigation target — set identified by its `PokeSet.id` (a
/// short stable string like "narrow", "wide", "regional"...).
/// HangarView's NavigationStack resolves this into a `SetDetailView`
/// by looking the set up in `PokeSets.all`.
struct SetDetailRoute: Hashable {
    let setId: String
}

// MARK: - Tile

private struct SetTile: View {
    let set: PokeSet
    let slots: [ModelSlot]

    private var caughtCount: Int { slots.filter(\.isCaught).count }
    private var totalCount: Int { slots.count }
    private var isLocked: Bool { caughtCount == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(set.type.tint)
                    Text(set.type.glyph)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black.opacity(0.7))
                }
                .frame(width: 30, height: 30)

                Text(set.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.Color.textPrimary)
                Spacer()
                Text("\(caughtCount) / \(totalCount)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(isLocked ? Brand.Color.textTertiary : set.type.tint)
                    .monospacedDigit()
            }

            // Thumbnail strip — one cell per slot, left-to-right in
            // entry order. Caught slots have a 1pt top rail in the
            // type tint + a short model token label; locked slots show
            // a centered "?".
            HStack(spacing: 4) {
                ForEach(slots) { slot in
                    Group {
                        if slot.isCaught {
                            VStack(spacing: 0) {
                                Rectangle().fill(set.type.tint).frame(height: 1)
                                Text(shortLabel(for: slot.entry))
                                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Brand.Color.textPrimary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                    .frame(maxWidth: .infinity, minHeight: 21)
                                    .background(Brand.Color.bgSurface)
                            }
                        } else {
                            Text("?")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Brand.Color.textTertiary.opacity(0.5))
                                .frame(maxWidth: .infinity, minHeight: 22)
                                .background(Brand.Color.bgSurface)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
        }
        .padding(12)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 10))
        .opacity(isLocked ? 0.55 : 1.0)
    }

    /// Concise (~3–6 char) label for the thumbnail strip. `PokeSetEntry`
    /// carries no dedicated short-name field today; the first entry in
    /// `modelTokens` (e.g., "737-8", "a380", "c-130") is the closest
    /// thing to a canonical short string and tends to read well in a
    /// monospaced 8pt cell. We uppercase for visual consistency with
    /// the wider HUD treatment. If a set ever ships with empty
    /// `modelTokens`, fall back to the first 4 chars of canonicalName
    /// so the cell isn't blank.
    private func shortLabel(for entry: PokeSetEntry) -> String {
        if let first = entry.modelTokens.first, !first.isEmpty {
            return first.uppercased()
        }
        return String(entry.canonicalName.prefix(4)).uppercased()
    }
}

// The real `SetDetailView` lives in `SetDetailView.swift` (Task 16).
// Routing from `SetDetailRoute` is wired in `HangarView` via
// `.navigationDestination(for: SetDetailRoute.self)`.
