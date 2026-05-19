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

    @State private var photo: PlanePhoto?
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
            photo = await PlanespottersClient.shared.photo(for: catchRecord.icao24)
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

    @ViewBuilder
    private var photoSection: some View {
        if let photo {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    AsyncImage(url: photo.thumbnailLargeURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .failure:
                            placeholderRect
                        case .empty:
                            placeholderRect.overlay(ProgressView())
                        @unknown default:
                            placeholderRect
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .clipped()
                    .cornerRadius(8)

                    // TOS attribution: photographer credit + link to Planespotters page.
                    Button {
                        UIApplication.shared.open(photo.link)
                    } label: {
                        Text("© \(photo.photographer) · planespotters.net")
                            .font(Brand.Font.caption)
                            .foregroundStyle(Brand.Color.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
        }
    }

    private var placeholderRect: some View {
        Rectangle()
            .fill(Brand.Color.bgElevated)
            .frame(height: 220)
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
