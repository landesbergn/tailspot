//
//  HangarView.swift
//  Tailspot
//
//  The collection view ("Hangar") — every catch the user has logged.
//  Presented as a sheet from ContentView. Catches sharing an icao24
//  collapse into one MiniCard with a ×N count badge (dedupe via
//  HangarGrouping.recent → single chronological bucket).
//
//  Layout: nav (Lockup + count pill) → horizontal filter chips
//  (All / Rare+ / per-AircraftType) → 2-col LazyVGrid of MiniCards.
//  Matches `HangarB` on the design canvas (detail-hangar-profile.jsx).
//
//  Delete: tap-and-hold a card → context menu → Delete. Grid views
//  don't get swipe-actions, so the gesture moved to long-press.
//

import SwiftUI
import SwiftData
import os

struct HangarView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    /// Pulled from the model container injected by TailspotApp. The
    /// @Query auto-updates when new Catches are inserted — so if you
    /// catch a plane, dismiss to the AR view, catch another, then
    /// come back, the grid reflects both without manual refresh.
    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]
    @State private var filter: HangarFilter = .all
    /// When non-nil, a delete-confirm alert is presented for this
    /// row. Triggered by the context-menu Delete action; confirming
    /// wipes every Catch in `row.allCatches`.
    @State private var rowToDelete: HangarRow?

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Brand.Color.bgPrimary, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        // Canvas-style small Lockup — peaked-roof
                        // hangar glyph + TAILSPOT wordmark at 13pt.
                        HStack(spacing: 8) {
                            HangarGlyph(
                                lineWidth: 2,
                                tint: Brand.Color.cyan
                            )
                            .frame(width: 22, height: 22)
                            Text("TAILSPOT")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .tracking(2)
                                .foregroundStyle(Brand.Color.textPrimary)
                        }
                    }
                    if !catches.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            // Accent pill — `N catches` — matches
                            // canvas `pill accent` on the right.
                            Text("\(catches.count) catches")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .tracking(0.4)
                                .foregroundStyle(Brand.Color.cyan)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Brand.Color.cyan.opacity(0.16), in: .capsule)
                        }
                    }
                }
                .navigationDestination(for: HangarRow.self) { row in
                    CatchDetailView(row: row)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if catches.isEmpty {
            emptyState
        } else {
            cardGrid
        }
    }

    // MARK: - Card grid

    /// The dedup'd, recency-sorted row list (every icao24 once).
    /// Computed once per body render; cheap until the catches set
    /// grows into the thousands, at which point this wants a
    /// memoization wrapper.
    private var allRows: [HangarRow] {
        HangarGrouping.group(catches, by: .recent).first?.rows ?? []
    }

    /// The rows after filter application. The filter chips' counts
    /// derive from `allRows` (not `filteredRows`) so the user sees
    /// the static buckets, not "how many of the current filter."
    private var filteredRows: [HangarRow] {
        allRows.filter { filter.includes($0) }
    }

    private var cardGrid: some View {
        // Chips live ABOVE the ScrollView in a fixed bar so taps on
        // them don't race with the NavigationLink-wrapped grid
        // underneath. Earlier nesting (chips inside the same outer
        // ScrollView as the LazyVGrid) caused chip taps to fall
        // through to the topmost NavigationLink.
        VStack(spacing: 0) {
            filterChips
                .padding(.top, 4)
                .padding(.bottom, 8)
                .background(Brand.Color.bgPrimary)

            ScrollView {
                if filteredRows.isEmpty {
                    emptyFilterState
                        .padding(.top, 32)
                } else {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)
                        ],
                        spacing: 12
                    ) {
                        ForEach(filteredRows) { row in
                            NavigationLink(value: row) {
                                MiniCardView(row: row)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    rowToDelete = row
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 32)
                }
            }
        }
        .background(Brand.Color.bgPrimary)
        .alert(
            deleteAlertTitle,
            isPresented: Binding(
                get: { rowToDelete != nil },
                set: { if !$0 { rowToDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let row = rowToDelete { performDelete(row: row) }
            }
            Button("Cancel", role: .cancel) {
                rowToDelete = nil
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    /// Horizontal-scrolling filter chips above the grid. Always
    /// shows "All · N" + "Rare+ · K" (when K > 0), then one chip
    /// per AircraftType the user has at least one catch of, sorted
    /// by ordinal (narrow → wide → regional → ...).
    private var filterChips: some View {
        let chips = buildChips()
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chips, id: \.id) { chip in
                    Button {
                        filter = chip.filter
                    } label: {
                        chipLabel(text: chip.label, count: chip.count, active: filter == chip.filter)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// Bundle of (filter, label, count) used to render one filter
    /// chip. `id` is the filter's stable identity.
    private struct Chip {
        let id: HangarFilter
        let label: String
        let count: Int
        var filter: HangarFilter { id }
    }

    private func buildChips() -> [Chip] {
        var out: [Chip] = []
        out.append(Chip(id: .all, label: "All", count: allRows.count))

        let rarePlus = allRows.filter { $0.rarity.ordinal >= Rarity.rare.ordinal }
        if !rarePlus.isEmpty {
            out.append(Chip(id: .rarePlus, label: "Rare+", count: rarePlus.count))
        }

        // One chip per non-empty AircraftType bucket, ordered by the
        // enum's canonical ordering.
        for type in AircraftType.allCases {
            let rows = allRows.filter { $0.aircraftType == type }
            if rows.isEmpty { continue }
            out.append(Chip(
                id: .type(type),
                label: type.label.capitalized,
                count: rows.count
            ))
        }
        return out
    }

    private func chipLabel(text: String, count: Int, active: Bool) -> some View {
        HStack(spacing: 5) {
            Text(text)
            Text("·")
                .opacity(0.6)
            Text("\(count)")
                .monospacedDigit()
        }
        .font(.system(size: 12, weight: .semibold))
        .tracking(0.2)
        .foregroundStyle(active ? Color.black.opacity(0.85) : Brand.Color.textSecondary)
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(active ? Brand.Color.cyan : Brand.Color.bgElevated, in: .capsule)
    }

    private var emptyFilterState: some View {
        VStack(spacing: 8) {
            Text("No catches in this filter")
                .font(Brand.Font.body)
                .foregroundStyle(Brand.Color.textSecondary)
            Button("Show all") { filter = .all }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Brand.Color.cyan)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Delete

    private var deleteAlertTitle: String {
        guard let row = rowToDelete else { return "" }
        let cs = row.mostRecent.callsign?.trimmedNonEmpty ?? row.icao24
        if row.count == 1 {
            return "Delete catch of \(cs)?"
        }
        return "Delete all \(row.count) catches of \(cs)?"
    }

    private func performDelete(row: HangarRow) {
        for c in row.allCatches {
            modelContext.delete(c)
        }
        do {
            try modelContext.save()
        } catch {
            Log.adsb.error("Hangar delete failed for \(row.icao24, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        rowToDelete = nil
    }

    // MARK: - Empty state

    /// The first-launch empty state — explains the catch loop and
    /// previews the sets the user has to fill. Matches the design
    /// canvas's "Go outside." treatment.
    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heroBlock
                setsPreview
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .background(Brand.Color.bgPrimary)
    }

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Circle().fill(Brand.Color.cyan.opacity(0.12))
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(Brand.Color.cyan)
            }
            .frame(width: 64, height: 64)
            Text("Go outside.")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Brand.Color.textPrimary)
            Text("Tailspot needs a clear view of the sky. Point your phone up, hold a plane in the reticle to catch it.")
                .font(Brand.Font.body)
                .foregroundStyle(Brand.Color.textSecondary)
            Button {
                // Hangar is sheet-presented from ContentView, so
                // dismissing it lands the user back in the AR view.
                dismiss()
            } label: {
                Text("Open AR view")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black.opacity(0.88))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Brand.Color.cyan, in: .rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    private var setsPreview: some View {
        let previewSets: [PokeSet] = PokeSets.all.filter {
            [.narrow, .wide, .regional, .heritage].contains($0.type)
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text("SETS TO COLLECT")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.textTertiary)
            VStack(spacing: 8) {
                ForEach(previewSets) { set in
                    setPreviewRow(set)
                }
            }
        }
    }

    private func setPreviewRow(_ set: PokeSet) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(set.type.tint.opacity(0.20))
                Text(set.type.glyph)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(set.type.tint)
            }
            .frame(width: 30, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(set.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.Color.textPrimary)
                Text(set.type.summary)
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("0 / \(set.entries.count)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Brand.Color.textTertiary)
                .monospacedDigit()
        }
        .padding(12)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 12))
    }
}

// MARK: - HangarFilter

/// What's currently visible in the Hangar grid. Used to drive both
/// the chip selection and the row filter predicate.
enum HangarFilter: Hashable {
    case all
    case rarePlus
    case type(AircraftType)

    func includes(_ row: HangarRow) -> Bool {
        switch self {
        case .all:              return true
        case .rarePlus:         return row.rarity.ordinal >= Rarity.rare.ordinal
        case .type(let t):      return row.aircraftType == t
        }
    }
}

private extension String {
    /// Trim + nil-if-empty.
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

#Preview {
    HangarView()
        .modelContainer(for: Catch.self, inMemory: true)
}
