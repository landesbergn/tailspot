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

    /// Always-rendered photo slab — fixed 220pt height so the page
    /// doesn't shift when the API resolves. The single 220pt block
    /// holds (in order of stack): a bgElevated base, the per-state
    /// content (spinner / photo / no-photo placeholder), and (when
    /// loaded) an attribution chip overlaid on the bottom-leading
    /// corner of the photo so the credit + tap-target are visually
    /// attached to the image and can't clip against the row's edge.
    private var photoSection: some View {
        Section {
            ZStack {
                Brand.Color.bgElevated
                photoSlabContent
            }
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 8))
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
            loadedPhotoView(photo)
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

    /// The loaded-photo presentation: image fills the slab; attribution
    /// chip overlays the bottom-leading corner. Whole thing is wrapped
    /// in a Button so a tap anywhere on the photo opens the
    /// Planespotters page in Safari (TOS attribution requirement).
    private func loadedPhotoView(_ photo: PlanePhoto) -> some View {
        Button {
            UIApplication.shared.open(photo.link)
        } label: {
            ZStack(alignment: .bottomLeading) {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                Text("© \(photo.photographer) · planespotters.net")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: .rect(cornerRadius: 4))
                    .padding(8)
            }
        }
        .buttonStyle(.plain)
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
