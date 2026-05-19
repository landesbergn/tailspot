//
//  HangarView.swift
//  Tailspot
//
//  The collection view ("Hangar") — lists everything the user has
//  caught. Presented as a sheet from ContentView. Each row is one
//  Catch (one tap = one event); duplicates are intentionally allowed
//  and shown as separate rows.
//
//  Grouping switches between aircraft type (manufacturer + model) and
//  airline (operatorName) via a segmented picker. Grouping logic
//  lives in HangarGrouping so it stays unit-testable.
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
    /// come back, the list reflects both without manual refresh.
    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]
    @State private var grouping: HangarGrouping = .aircraftType
    /// When non-nil, a delete-confirm alert is presented for this
    /// row. Triggered by the swipe action; confirming wipes every
    /// Catch in `row.allCatches`.
    @State private var rowToDelete: HangarRow?

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .principal) {
                        // Horizontal brand lockup: airplane glyph + TAILSPOT wordmark.
                        HStack(spacing: 8) {
                            Image(systemName: "airplane")
                                .foregroundStyle(Brand.Color.cyan)
                            Text("TAILSPOT")
                                .font(Brand.Font.wordmark)
                                .foregroundStyle(Brand.Color.textPrimary)
                                .tracking(4)
                        }
                    }
                    if !catches.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            Text("\(catches.count)")
                                .font(Brand.Font.hudCallsign)
                                .foregroundStyle(Brand.Color.textPrimary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Brand.Color.bgElevated, in: .capsule)
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
            groupedList
        }
    }

    // MARK: - List

    /// Grouping picker rendered above the list as a list section so
    /// it scrolls naturally and doesn't fight the nav title. Inline
    /// is also closer to where the eye lands first.
    private var groupedList: some View {
        let groups = HangarGrouping.group(catches, by: grouping)
        return List {
            Section {
                statsRow
                Picker("Group by", selection: $grouping) {
                    Text("Type").tag(HangarGrouping.aircraftType)
                    Text("Airline").tag(HangarGrouping.airline)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
            }

            ForEach(groups) { group in
                Section {
                    ForEach(group.rows) { row in
                        NavigationLink(value: row) {
                            rowView(row)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                rowToDelete = row
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    sectionHeader(group)
                }
            }
        }
        .listStyle(.insetGrouped)
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

    /// Alert title built from the row's icao24 + count. Pluralizes the
    /// noun so 1-catch reads naturally.
    private var deleteAlertTitle: String {
        guard let row = rowToDelete else { return "" }
        let cs = row.mostRecent.callsign?.trimmedNonEmpty ?? row.icao24
        if row.count == 1 {
            return "Delete catch of \(cs)?"
        }
        return "Delete all \(row.count) catches of \(cs)?"
    }

    /// Drops every Catch in the row's `allCatches` from the SwiftData
    /// store. @Query auto-refreshes; the row disappears from the
    /// list as soon as the save completes. Group sections empty out
    /// naturally if every row in them is deleted.
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

    /// Compact stats summary rendered above the grouping picker.
    /// Three at-a-glance counts: total events caught, unique airframes
    /// in the collection, and rare-tagged unique airframes. Pure-mono
    /// numerics so the values line up across re-renders.
    private var statsRow: some View {
        HStack(spacing: 0) {
            statPill(value: catches.count, label: "caught")
            statDivider
            statPill(value: uniqueIcaoCount, label: "unique")
            statDivider
            statPill(value: rareUniqueCount, label: "rare",
                     valueColor: rareUniqueCount > 0 ? Brand.Color.alertAdvisory : Brand.Color.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowBackground(Color.clear)
    }

    /// One column of the stats row. `valueColor` defaults to textPrimary
    /// — the rare column overrides to magenta when count > 0 so the
    /// trophy reads at a glance.
    private func statPill(value: Int, label: String, valueColor: Color = Brand.Color.textPrimary) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(valueColor)
                .monospacedDigit()
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Brand.Color.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Brand.Color.bgElevated)
            .frame(width: 1, height: 32)
    }

    private var uniqueIcaoCount: Int {
        Set(catches.map(\.icao24)).count
    }

    private var rareUniqueCount: Int {
        catches.reduce(into: Set<String>()) { acc, c in
            if HangarRarity.tier(for: c) == .rare {
                acc.insert(c.icao24)
            }
        }.count
    }

    private func sectionHeader(_ group: HangarGroup) -> some View {
        HStack {
            Text(group.title)
            Spacer()
            Text("\(group.rows.count)")
                .foregroundStyle(Brand.Color.textSecondary)
                .monospacedDigit()
        }
    }

    private func rowView(_ row: HangarRow) -> some View {
        let c = row.mostRecent
        let title = c.callsign?.trimmedNonEmpty ?? c.icao24
        let subtitle = rowSubtitle(c)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "airplane")
                .foregroundStyle(Brand.Color.cyan)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(Brand.Font.hudCallsign)
                    if row.count > 1 {
                        Text("×\(row.count)")
                            .font(Brand.Font.caption)
                            .foregroundStyle(Brand.Color.textPrimary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Brand.Color.bgElevated, in: .capsule)
                    }
                    if row.rarity == .rare {
                        Text("RARE")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .tracking(0.5)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Brand.Color.alertAdvisory, in: .capsule)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(c.caughtAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.textTertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    /// Subtitle composes whichever of (operator, type) ISN'T already
    /// in the section header, plus the slant distance. Lets the row
    /// add information rather than restate it.
    private func rowSubtitle(_ c: Catch) -> String? {
        var pieces: [String] = []

        let typeText = HangarGrouping.key(for: c, mode: .aircraftType)
        let airlineText = HangarGrouping.key(for: c, mode: .airline)

        switch grouping {
        case .aircraftType:
            if airlineText != HangarGrouping.unknownTitle {
                pieces.append(airlineText)
            }
        case .airline:
            if typeText != HangarGrouping.unknownTitle {
                pieces.append(typeText)
            }
        }

        let km = c.slantDistanceMeters / 1000
        if km.isFinite, km > 0 {
            pieces.append(String(format: "%.1f km", km))
        }

        return pieces.isEmpty ? nil : pieces.joined(separator: "  ·  ")
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Hangar is empty", systemImage: "tray")
        } description: {
            Text("Lock onto a plane in the AR view, then tap **Catch this plane** to add it here.")
                .multilineTextAlignment(.center)
        }
    }
}

private extension String {
    /// Trim + nil-if-empty, used so an all-whitespace callsign falls
    /// back to the icao24 instead of rendering as blank space.
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

#Preview {
    HangarView()
        .modelContainer(for: Catch.self, inMemory: true)
}
