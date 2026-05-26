//
//  ModelSlotDetailView.swift
//  Tailspot
//
//  The screen between Set detail and Tail detail — lists every
//  distinct tail (icao24) the user has caught of one model. Spec § 5.3.
//
//  Reached by tapping a caught slot in `SetDetailView`. Each row is
//  one `HangarRow` (collapsed by icao24) and pushes the existing
//  `CatchDetailView` via the `HangarRow` navigation destination
//  already wired up in `HangarView`. Task 18 will rewrite that detail
//  screen with the PokeCard hero treatment; T17 stays scope-disciplined
//  and only owns the tail-list surface.
//

import SwiftUI
import SwiftData

struct ModelSlotDetailView: View {
    let set: PokeSet
    let entry: PokeSetEntry

    /// Same query shape as `SetDetailView` — the dedup'd flat row list
    /// is the input to `PokeSets.matches` so this screen stays in
    /// lockstep with its parent. Pulling the query here (rather than
    /// threading state through the route value) keeps the route value
    /// trivially `Hashable`.
    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]

    /// Collapse-by-icao24 first, then filter to just the rows whose
    /// most-recent catch matches this slot's `modelTokens`. Mirrors the
    /// resolver inside `HangarGrouping.resolveSlots` — using
    /// `PokeSets.matches` directly keeps a single source of truth for
    /// Catch → PokeSetEntry membership.
    private var rows: [HangarRow] {
        HangarGrouping.group(catches, by: .recent).first?.rows ?? []
    }
    private var tails: [HangarRow] {
        rows.filter { PokeSets.matches(catch: $0.mostRecent, entry: entry) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                // Breadcrumb — `#NN · SET NAME` in muted mono. The
                // index matches the `#NN` numbering used in the set
                // grid so the user can trust the navigation chain.
                Text("#\(String(format: "%02d", indexInSet)) · \(set.title.uppercased())")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(Brand.Color.textTertiary)

                // Hero — canonical model name, full strength.
                Text(entry.canonicalName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Brand.Color.textPrimary)

                // Distinct-tail count in the set's type tint so the
                // surface visually belongs to its parent set.
                Text("\(tails.count) distinct tail\(tails.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(set.type.tint)

                Text("TAILS YOU'VE CAUGHT")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(Brand.Color.textTertiary)
                    .padding(.top, 14)
                    .padding(.bottom, 4)

                // Vertical list of tail rows. Each pushes a
                // `HangarRow`, which `HangarView`'s existing
                // `.navigationDestination(for: HangarRow.self)` resolves
                // to `CatchDetailView`. T18 rewrites that destination.
                VStack(spacing: 6) {
                    ForEach(tails) { row in
                        NavigationLink(value: row) {
                            tailRow(row)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Brand.Color.bgPrimary)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Brand.Color.bgPrimary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    /// 1-based position of this entry within its parent set, used by
    /// the breadcrumb. Falls back to 1 if (somehow) the entry isn't
    /// found — better than crashing on a stale nav route.
    private var indexInSet: Int {
        (set.entries.firstIndex(where: { $0.id == entry.id }) ?? 0) + 1
    }

    /// One row per distinct tail. Layout per spec § 5.3:
    ///  - 3pt rarity-tinted left rail (visual link to the PokeCard system)
    ///  - cyan callsign (or icao24 fallback) in mono
    ///  - icao24 · operator in muted mono
    ///  - relative timestamp anchored right (uses `firstCatch.caughtAt`
    ///    so the "when did I first catch this tail" reading is stable
    ///    across multiple catches of the same airframe).
    private func tailRow(_ row: HangarRow) -> some View {
        let cs = row.mostRecent.callsign?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? row.icao24.uppercased()
        return HStack(spacing: 10) {
            Rectangle()
                .fill(row.rarity.tint)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(cs)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Brand.Color.cyan)
                Text("\(row.icao24) · \(row.mostRecent.operatorName ?? "—")")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(Brand.Color.textTertiary)
            }
            Spacer()
            Text(row.firstCatch.caughtAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(Brand.Color.textTertiary)
        }
        .padding(.vertical, 8)
        .padding(.trailing, 12)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 7))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

private extension String {
    /// Returns self if non-empty, otherwise nil. Used to fold a
    /// whitespace-only or empty callsign into the icao24 fallback path.
    var nonEmpty: String? { isEmpty ? nil : self }
}
