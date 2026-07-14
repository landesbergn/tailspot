//
//  MapScreen.swift
//  Tailspot
//
//  Geographic map of every catch's observer location, with one
//  rarity-tinted pin per Catch. Uses the MapKit / SwiftUI iOS 17+
//  `Map` API. Pins are colored by the catch's rarity; tapping a
//  pin opens its CatchDetailView.
//
//  The map auto-fits to the bounding box of all catches on first
//  render. Subsequent layout pans/zooms by the user are preserved
//  via `@State var position: MapCameraPosition`.
//

import SwiftUI
import SwiftData
import MapKit
import CoreLocation

struct MapScreen: View {
    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]
    @State private var position: MapCameraPosition = .automatic
    @State private var selectedCatch: Catch?

    /// Filter pinned to a rarity range (`nil` = all). Lets the user
    /// flip to "show only rare+" — useful at high catch volumes.
    @State private var minRarityFilter: Rarity? = nil

    private var visibleCatches: [Catch] {
        guard let min = minRarityFilter else { return catches }
        return catches.filter { $0.resolvedRarity.ordinal >= min.ordinal }
    }

    var body: some View {
        ZStack {
            Map(position: $position, selection: $selectedCatch) {
                ForEach(visibleCatches) { c in
                    Annotation(c.callsign ?? c.icao24, coordinate: c.coordinate) {
                        pin(for: c)
                            .onTapGesture { selectedCatch = c }
                    }
                    .tag(c)
                }
            }
            .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
            .mapControlVisibility(.hidden)
            .ignoresSafeArea(edges: .horizontal)

            VStack {
                filterStrip
                Spacer()
                summaryPanel
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 24)
        }
        .navigationTitle("Map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    fitToCatches()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityLabel("Fit map to catches")
            }
        }
        .onAppear { fitToCatches() }
        .sheet(item: $selectedCatch) { c in
            NavigationStack {
                // presentedModally: this is a sheet, so the detail's chrome
                // shows a close (X) affordance instead of the push-style
                // back chevron.
                CatchDetailView(row: HangarRow(
                    icao24: c.icao24,
                    mostRecent: c,
                    count: 1,
                    allCatches: [c]
                ), presentedModally: true)
            }
        }
    }

    // MARK: - Pins

    private func pin(for c: Catch) -> some View {
        let tint = c.resolvedRarity.tint
        return ZStack {
            Circle()
                .fill(tint)
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2))
                .shadow(color: tint.opacity(0.6), radius: 6)
            // Legendary gets a halo so it pops at low zoom.
            if c.resolvedRarity == .legendary {
                Circle()
                    .strokeBorder(tint.opacity(0.6), lineWidth: 1)
                    .frame(width: 30, height: 30)
            }
        }
        // The dot stays 16 pt (30 with halo) and centered on the
        // coordinate; the transparent 44 pt frame is the HIG tap target.
        // Rarity is color-only on screen, so the label carries it for
        // VoiceOver.
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("\(c.callsign ?? c.icao24.uppercased()), \(c.resolvedRarity.label)")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Filter strip

    // Horizontally scrollable: six chips don't quite fit a 393pt screen,
    // and letting the row wrap hyphenated LEGENDARY across two lines
    // ("LEGENDAR-Y"). Chips are lineLimit(1)+fixedSize so they can never
    // wrap; overflow scrolls instead.
    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip(label: "ALL", tint: Brand.Color.textPrimary, active: minRarityFilter == nil) {
                    minRarityFilter = nil
                }
                ForEach(Rarity.allCases, id: \.self) { r in
                    filterChip(label: r.label, tint: r.tint, active: minRarityFilter == r) {
                        minRarityFilter = minRarityFilter == r ? nil : r
                    }
                }
            }
            // Chips carry a 44 pt hit frame (below), so the strip needs
            // almost no vertical padding of its own to stay a slim capsule.
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
        }
        .background(.thinMaterial, in: .capsule)
        .clipShape(.capsule)
    }

    private func filterChip(label: String, tint: Color, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                // 11 pt is the HIG text floor; these are interactive labels,
                // not decorative eyebrows.
                .font(Brand.Font.mono(size: 11, weight: .bold, relativeTo: .caption2))
                .tracking(0.8)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(active ? .black.opacity(0.85) : tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(active ? tint : .clear, in: .capsule)
                // The visible capsule stays slim; the frame is the hit area.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: - Summary panel

    private var summaryPanel: some View {
        let total = visibleCatches.count
        let unique = Set(visibleCatches.map(\.icao24)).count
        let span = dateSpanText
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(total) sightings")
                    .font(Brand.Font.cardTitle)
                    .foregroundStyle(Brand.Color.textPrimary)
                if let span {
                    Text(span)
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textSecondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(unique)")
                    .font(Brand.Font.mono(size: 18, weight: .heavy, relativeTo: .title3))
                    .foregroundStyle(Brand.Color.cyan)
                    .monospacedDigit()
                Text("UNIQUE")
                    .font(Brand.Font.mono(size: 9, weight: .semibold, relativeTo: .caption2))
                    .tracking(1)
                    .foregroundStyle(Brand.Color.textTertiary)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: .rect(cornerRadius: Brand.Radius.card))
        .accessibilityElement(children: .combine)
    }

    private var dateSpanText: String? {
        guard let oldest = visibleCatches.map(\.caughtAt).min(),
              let newest = visibleCatches.map(\.caughtAt).max()
        else { return nil }
        let days = Calendar.current.dateComponents([.day], from: oldest, to: newest).day ?? 0
        if days <= 0 { return "today" }
        return "\(days + 1) days"
    }

    // MARK: - Camera fit

    private func fitToCatches() {
        let coords = visibleCatches.map(\.coordinate)
        guard let first = coords.first else { return }
        if coords.count == 1 {
            position = .region(MKCoordinateRegion(
                center: first,
                latitudinalMeters: 5_000,
                longitudinalMeters: 5_000
            ))
            return
        }
        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return }
        let center = CLLocationCoordinate2D(
            latitude:  (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.4, 0.04),
            longitudeDelta: max((maxLon - minLon) * 1.4, 0.04)
        )
        position = .region(MKCoordinateRegion(center: center, span: span))
    }
}

private extension Catch {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: observerLat, longitude: observerLon)
    }
}

#Preview {
    NavigationStack { MapScreen() }
        .modelContainer(for: Catch.self, inMemory: true)
}
