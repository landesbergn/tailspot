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
    let catchRecord: Catch

    @State private var photo: PlanePhoto?
    @State private var didLoadPhoto = false

    var body: some View {
        List {
            photoSection
            Section("Identity") {
                row("Callsign", catchRecord.callsign ?? "—")
                row("ICAO24",   catchRecord.icao24)
                row("Aircraft", aircraftText)
                row("Operator", catchRecord.operatorName ?? "—")
            }

            Section("When & where") {
                row("Caught",          catchRecord.caughtAt.formatted(date: .abbreviated, time: .shortened))
                row("From",            String(format: "%.4f°, %.4f°", catchRecord.observerLat, catchRecord.observerLon))
                row("Slant distance",  String(format: "%.1f km", catchRecord.slantDistanceMeters / 1000))
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
