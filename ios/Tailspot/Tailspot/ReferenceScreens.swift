//
//  ReferenceScreens.swift
//  Tailspot
//
//  Catalog-backed rarity guide. Each tier links to the aircraft assigned to
//  it in AircraftTypes.json and marks typecodes already present in the local
//  Hangar, so this screen stays accurate as the catalog evolves.
//

import SwiftUI

// MARK: - Rarity

struct RarityReferenceScreen: View {
    let catches: [Catch]

    init(catches: [Catch] = []) {
        self.catches = catches
    }

    var body: some View {
        let caughtTypecodes: Set<String> = Set(catches.compactMap { row -> String? in
            guard let rawTypecode = row.typecode else { return nil }
            let code = rawTypecode
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            guard !code.isEmpty else { return nil }
            return code
        })

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Rarity.allCases, id: \.self) { r in
                    let aircraft = AircraftNaming.aircraft(in: r)
                    NavigationLink {
                        RarityTierDetailScreen(
                            rarity: r,
                            aircraft: aircraft,
                            caughtTypecodes: caughtTypecodes
                        )
                    } label: {
                        RarityReferenceCard(
                            rarity: r,
                            aircraftCount: aircraft.count,
                            caughtCount: aircraft.lazy.filter {
                                caughtTypecodes.contains($0.typecode)
                            }.count
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .background(Brand.Color.bgPrimary.ignoresSafeArea())
        .navigationTitle("Rarity")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RarityReferenceCard: View {
    let rarity: Rarity
    let aircraftCount: Int
    let caughtCount: Int

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: Brand.Radius.row).fill(rarity.tint.opacity(0.18))
                Text("\(rarity.basePoints)")
                    .font(Brand.Font.mono(size: 18, weight: .heavy))
                    .foregroundStyle(rarity.tint)
            }
            .frame(width: 64, height: 64)
            .overlay(
                RoundedRectangle(cornerRadius: Brand.Radius.row).strokeBorder(rarity.tint, lineWidth: 1)
            )
            VStack(alignment: .leading, spacing: 4) {
                RarityBadge(rarity: rarity, size: .md)
                Text("\(aircraftCount) aircraft · \(caughtCount) caught")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Brand.Color.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(14)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: Brand.Radius.card))
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(rarity.label.capitalized), \(rarity.basePoints) points, \(aircraftCount) aircraft, \(caughtCount) caught"
        )
        .accessibilityHint("Shows every aircraft in this tier")
    }
}

private struct RarityTierDetailScreen: View {
    private enum AircraftFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case caught = "Caught"
        case uncaught = "Uncaught"

        var id: Self { self }
    }

    let rarity: Rarity
    let aircraft: [AircraftNaming.CatalogAircraft]
    let caughtTypecodes: Set<String>

    @State private var searchText = ""
    @State private var aircraftFilter: AircraftFilter = .all

    private var visibleAircraft: [AircraftNaming.CatalogAircraft] {
        let statusMatches = aircraft.filter { plane in
            switch aircraftFilter {
            case .all:
                return true
            case .caught:
                return caughtTypecodes.contains(plane.typecode)
            case .uncaught:
                return !caughtTypecodes.contains(plane.typecode)
            }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return statusMatches }
        return statusMatches.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.typecode.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Aircraft status", selection: $aircraftFilter) {
                    ForEach(AircraftFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Brand.Color.bgPrimary)
            }

            Section {
                ForEach(visibleAircraft) { plane in
                    RarityAircraftRow(
                        plane: plane,
                        isCaught: caughtTypecodes.contains(plane.typecode)
                    )
                }
            } header: {
                Text("\(visibleAircraft.count) aircraft")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Brand.Color.bgPrimary)
        .navigationTitle(rarity.label.capitalized)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search aircraft or typecode")
        .overlay {
            if visibleAircraft.isEmpty {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        aircraftFilter == .caught ? "No caught aircraft" : "No uncaught aircraft",
                        systemImage: aircraftFilter == .caught ? "checkmark.circle" : "circle.slash"
                    )
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
    }
}

private struct RarityAircraftRow: View {
    let plane: AircraftNaming.CatalogAircraft
    let isCaught: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(plane.displayName)
                    .font(Brand.Font.body)
                    .foregroundStyle(isCaught ? Brand.Color.textPrimary : Brand.Color.textSecondary)
                Text(plane.typecode)
                    .font(Brand.Font.mono(size: 11, weight: .semibold, relativeTo: .caption))
                    .foregroundStyle(Brand.Color.textTertiary)
            }
            Spacer(minLength: 8)
            if isCaught {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Brand.Color.cyan)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 5)
        .listRowBackground(Brand.Color.bgPrimary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(plane.displayName), \(plane.typecode), \(isCaught ? "caught" : "not caught")"
        )
    }
}

#Preview("Rarity") {
    NavigationStack { RarityReferenceScreen() }
}
