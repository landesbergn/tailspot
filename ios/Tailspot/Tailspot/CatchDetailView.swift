//
//  CatchDetailView.swift
//  Tailspot
//
//  Read-only detail for a single Catch row in the Hangar. The Catch
//  is a frozen snapshot of what we knew at catch time — we don't try
//  to re-fetch live metadata or position here; that would make a
//  catch from yesterday look different tomorrow, which defeats the
//  point of a collection.
//
//  The photoSection (top of the list) does make a live Planespotters
//  fetch, which is intentional: photos aren't part of the catch
//  snapshot, and the TOS prohibits caching image bytes to disk anyway.
//  Showing the current photo for an icao24 is fine — it's more like
//  a "what does this plane look like?" reference than a snapshot.
//

import SwiftUI

struct CatchDetailView: View {
    /// A whole HangarRow — every catch sharing this icao24 plus the
    /// "representative" most-recent catch used for identity fields.
    let row: HangarRow

    /// Convenience accessor for the most-recent catch, used for header
    /// text + identity rows. The full list is rendered in the Catches
    /// section below.
    private var catchRecord: Catch { row.mostRecent }

    /// Tri-state for the photo section so the view reserves space
    /// while the API call is in flight — no layout shift when the
    /// photo lands. `notAvailable` is a true miss (Planespotters has
    /// no record); we still render a small placeholder so the section
    /// height doesn't change.
    private enum PhotoState: Equatable {
        case loading
        case loaded(PlanePhoto)
        case notAvailable
    }

    @State private var photoState: PhotoState = .loading
    @State private var didLoadPhoto = false

    var body: some View {
        List {
            photoSection
            Section("Identity") {
                self.row("Callsign", catchRecord.callsign ?? "—")
                self.row("ICAO24",   catchRecord.icao24)
                self.row("Aircraft", aircraftText)
                self.row("Operator", catchRecord.operatorName ?? "—")
            }

            Section(catchesSectionTitle) {
                ForEach(row.allCatches) { c in
                    catchTimelineRow(c)
                }
            }
        }
        .navigationTitle(catchRecord.callsign?.trimmedNonEmpty ?? catchRecord.icao24)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !didLoadPhoto else { return }
            didLoadPhoto = true
            let fetched = await PlanespottersClient.shared.photo(for: catchRecord.icao24)
            withAnimation(.easeInOut(duration: 0.3)) {
                photoState = fetched.map(PhotoState.loaded) ?? .notAvailable
            }
        }
    }

    // MARK: - Catches timeline

    private var catchesSectionTitle: String {
        row.count == 1 ? "Caught once" : "Caught \(row.count) times"
    }

    /// One entry in the catch-history timeline. Top line = timestamp
    /// (most prominent) + slant distance. Sub line = observer lat/lon.
    private func catchTimelineRow(_ c: Catch) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(c.caughtAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Brand.Font.body)
                Spacer()
                Text(String(format: "%.1f km", c.slantDistanceMeters / 1000))
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
                    .monospacedDigit()
            }
            Text(String(format: "%.4f°, %.4f°", c.observerLat, c.observerLon))
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.textTertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    // MARK: - Photo section

    /// Always-rendered section that reserves the photo block from the
    /// start so the page doesn't jump when the API lands. The outer
    /// 220pt slab is constant; only the inner content swaps between
    /// a spinner (loading), the photo (loaded), or a small "no photo"
    /// affordance (Planespotters has no record).
    private var photoSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Brand.Color.bgElevated
                    photoSlabContent
                }
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .clipped()
                .cornerRadius(8)

                // TOS attribution: photographer credit + link to
                // Planespotters page. Only shown when loaded; we
                // accept the small ~24pt growth on transition since
                // the 220pt slab itself is already reserved.
                if case .loaded(let photo) = photoState {
                    Button {
                        UIApplication.shared.open(photo.link)
                    } label: {
                        Text("© \(photo.photographer) · planespotters.net")
                            .font(Brand.Font.caption)
                            .foregroundStyle(Brand.Color.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .padding(.vertical, 4)
        }
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
    }

    @ViewBuilder
    private var photoSlabContent: some View {
        switch photoState {
        case .loading:
            ProgressView()
                .tint(Brand.Color.textSecondary)
        case .loaded(let photo):
            AsyncImage(url: photo.thumbnailLargeURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                case .empty:
                    ProgressView()
                        .tint(Brand.Color.textSecondary)
                case .failure:
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title2)
                        .foregroundStyle(Brand.Color.textTertiary)
                @unknown default:
                    EmptyView()
                }
            }
        case .notAvailable:
            VStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(Brand.Color.textTertiary)
                Text("No photo available")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textTertiary)
            }
        }
    }

    // MARK: - Helpers

    private var aircraftText: String {
        let key = HangarGrouping.key(for: catchRecord, mode: .aircraftType)
        return key == HangarGrouping.unknownTitle ? "—" : key
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(Brand.Color.textSecondary)
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
