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
                .toolbarBackground(Brand.Color.bgPrimary, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        // Canvas-style small Lockup — peaked-roof
                        // hangar glyph + TAILSPOT wordmark at 13pt.
                        // Replaces the iOS-default nav title.
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
                            // Accent pill — "N catches" — matches
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
                Picker("Group by", selection: $grouping) {
                    Text("By type").tag(HangarGrouping.aircraftType)
                    Text("By airline").tag(HangarGrouping.airline)
                    Text("Recent").tag(HangarGrouping.recent)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listRowSeparator(.hidden)

            ForEach(groups) { group in
                Section {
                    ForEach(group.rows) { row in
                        NavigationLink(value: row) {
                            rowView(row)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                rowToDelete = row
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    // Recent mode is a single flat bucket — no header.
                    if grouping != .recent {
                        sectionHeader(group)
                    }
                }
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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

    /// Section header in the canvas style: small uppercase mono label
    /// on the left, "N CAUGHT" caption on the right where N is the
    /// section's total catch-event count (not unique-row count) —
    /// matches `WIDE-BODY · 6 CAUGHT` on detail-hangar-profile.jsx.
    private func sectionHeader(_ group: HangarGroup) -> some View {
        let totalEvents = group.rows.reduce(0) { $0 + $1.count }
        return HStack {
            Text(group.title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .default))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.textTertiary)
            Spacer()
            Text("\(totalEvents) CAUGHT")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(Brand.Color.textTertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 0, trailing: 16))
        .textCase(nil)
    }

    /// One Hangar row, rendered as a dark elevated card with a 3pt
    /// solid rarity-tinted left stripe — matches the canvas's
    /// `HangarRow` (detail-hangar-profile.jsx:298-336).
    ///
    /// Card layout: [type-glyph chip][callsign + rarity badge + model
    /// · distance][×N + relative time]. The type chip is a solid
    /// type-tinted square with the single-letter aircraft-type glyph
    /// in dark text — the canvas's "playful collector" treatment.
    private func rowView(_ row: HangarRow) -> some View {
        let c = row.mostRecent
        let title = c.callsign?.trimmedNonEmpty ?? c.icao24
        let subtitle = rowSubtitle(c)
        let rarity = row.rarity
        let type = row.aircraftType
        return HStack(alignment: .center, spacing: 12) {
            // Type chip — solid type-tinted square with letter glyph.
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(type.tint)
                Text(type.glyph)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.black.opacity(0.7))
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(Brand.Font.hudCallsign)
                        .foregroundStyle(Brand.Color.cyan)
                    // Rare+ tiers (rare/epic/legendary) get an inline
                    // badge — common/uncommon stay quiet so the badge
                    // population actually means something.
                    if rarity.ordinal >= Rarity.rare.ordinal {
                        RarityBadge(rarity: rarity, size: .sm)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Brand.Color.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 4) {
                if row.count > 1 {
                    Text("×\(row.count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Brand.Color.textPrimary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Brand.Color.textPrimary.opacity(0.1), in: .capsule)
                }
                Text(c.caughtAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(Brand.Color.textTertiary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Brand.Color.bgElevated)
        )
        .overlay(alignment: .leading) {
            // Rarity-tinted left stripe — 3pt solid, inset slightly
            // so it sits inside the card's rounded corner.
            UnevenRoundedRectangle(
                topLeadingRadius: 8,
                bottomLeadingRadius: 8,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
            .fill(rarity.tint)
            .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Subtitle in canvas form: "{model} · {distance}". The model
    /// text is always shown (so airline-grouped rows still tell the
    /// reader what kind of plane it is, and recent rows aren't bare).
    /// Section headers handle the airline/type disambiguation.
    private func rowSubtitle(_ c: Catch) -> String? {
        var pieces: [String] = []

        let typeText = HangarGrouping.key(for: c, mode: .aircraftType)
        if typeText != HangarGrouping.unknownTitle {
            pieces.append(typeText)
        }

        let km = c.slantDistanceMeters / 1000
        if km.isFinite, km > 0 {
            pieces.append(String(format: "%.1f km", km))
        }

        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
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
                // If Hangar ever gets pushed inside a navigation
                // stack instead, this needs to walk back further.
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

    /// Compact preview of the 4 most common type sets so the
    /// first-launch user sees what they're collecting toward.
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
