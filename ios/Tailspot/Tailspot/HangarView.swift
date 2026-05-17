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

struct HangarView: View {
    @Environment(\.dismiss) private var dismiss
    /// Pulled from the model container injected by TailspotApp. The
    /// @Query auto-updates when new Catches are inserted — so if you
    /// catch a plane, dismiss to the AR view, catch another, then
    /// come back, the list reflects both without manual refresh.
    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]
    @State private var grouping: HangarGrouping = .aircraftType

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(titleText)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                }
                .navigationDestination(for: Catch.self) { c in
                    CatchDetailView(catchRecord: c)
                }
        }
    }

    private var titleText: String {
        catches.isEmpty ? "Hangar" : "Hangar  ·  \(catches.count)"
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
                    Text("Type").tag(HangarGrouping.aircraftType)
                    Text("Airline").tag(HangarGrouping.airline)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
            }

            ForEach(groups) { group in
                Section {
                    ForEach(group.catches) { c in
                        NavigationLink(value: c) {
                            row(c)
                        }
                    }
                } header: {
                    sectionHeader(group)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func sectionHeader(_ group: HangarGroup) -> some View {
        HStack {
            Text(group.title)
            Spacer()
            Text("\(group.catches.count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func row(_ c: Catch) -> some View {
        let title = c.callsign?.trimmedNonEmpty ?? c.icao24
        let subtitle = rowSubtitle(c)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "airplane")
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.monospaced())
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(c.caughtAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                .font(.caption2)
                .foregroundStyle(.secondary)
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
