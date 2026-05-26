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
    /// Segment selection for the 3-view Hangar shell (Spec § 4.1).
    /// Persisted across launches via @AppStorage so the user lands
    /// on whichever view they were last using.
    @AppStorage("tailspot.hangar.view") private var rawSegment: String = HangarSegment.sets.rawValue
    /// When non-nil, a delete-confirm alert is presented for this
    /// row. Triggered by the context-menu Delete action; confirming
    /// wipes every Catch in `row.allCatches`.
    @State private var rowToDelete: HangarRow?

    /// Two-way binding into the @AppStorage-backed raw string —
    /// lets the segmented switcher work in `HangarSegment` units
    /// while we persist the raw value.
    private var segment: Binding<HangarSegment> {
        Binding(
            get: { HangarSegment(rawValue: rawSegment) ?? .sets },
            set: { rawSegment = $0.rawValue }
        )
    }

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
            // Empty state replaces the whole switcher — easier than
            // threading "empty" into each of the three views.
            emptyState
        } else {
            VStack(spacing: 0) {
                HangarSegmentedSwitcher(selection: segment)
                Group {
                    switch segment.wrappedValue {
                    case .sets:     HangarSetsView()
                    case .recent:   HangarRecentView()
                    case .trophies: HangarTrophiesView()
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

// MARK: - Segment view stubs
//
// Temporary placeholders for the three Hangar segments. Each gets
// fleshed out in a follow-up task:
//   - HangarSetsView      → Task 15 (rich set tiles)
//   - HangarRecentView    → Task 13 (extracted MiniCard grid)
//   - HangarTrophiesView  → Task 14 (Trophies surface moves in)
//
// Inline keeps the diff small until those tasks land.
struct HangarSetsView: View {
    var body: some View {
        Text("Sets")
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Brand.Color.bgPrimary)
    }
}

struct HangarRecentView: View {
    var body: some View {
        Text("Recent")
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Brand.Color.bgPrimary)
    }
}

struct HangarTrophiesView: View {
    var body: some View {
        Text("Trophies")
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Brand.Color.bgPrimary)
    }
}

#Preview {
    HangarView()
        .modelContainer(for: Catch.self, inMemory: true)
}
