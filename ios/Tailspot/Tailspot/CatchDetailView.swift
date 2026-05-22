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

    /// True when this catch was auto-captured with a camera photo.
    /// Drives both the catch-photo hero rendering and the
    /// Planespotters-fallback gate (we skip the live photo when the
    /// user already has their own "moment" photo).
    private var hasCatchPhoto: Bool {
        catchRecord.photoFilename != nil
    }

    var body: some View {
        List {
            pokeCardSection
            // The PokeCard's photo slot already renders the user's
            // catch photo (when present) as the card's hero — showing
            // it again full-width below was duplicate weight. When
            // there's no catch photo, the card falls back to a
            // rarity-tinted placeholder and the Planespotters section
            // below provides the reference photo (with attribution).
            if !hasCatchPhoto {
                photoSection
            }
            Section("Identity") {
                self.row("Callsign", catchRecord.callsign ?? "—")
                self.row("ICAO24",   catchRecord.icao24)
                self.row("Aircraft", aircraftText)
                self.row("Operator", catchRecord.operatorName ?? "—")
                self.row("Rarity",   catchRecord.resolvedRarity.label)
                self.row("Type",     catchRecord.resolvedType.label)
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
            // Skip the Planespotters fetch when we already have the
            // user's own catch photo — that's the hero and nothing
            // else is going to render in the photo slot.
            guard !didLoadPhoto, !hasCatchPhoto else { return }
            didLoadPhoto = true
            let fetched = await PlanespottersClient.shared.photo(for: catchRecord.icao24)
            withAnimation(.easeInOut(duration: 0.3)) {
                photoState = fetched.map(PhotoState.loaded) ?? .notAvailable
            }
        }
    }

    // MARK: - PokeCard hero

    /// The PokeCard hero — first thing the user sees on the detail
    /// screen. Renders the catch as a 280×400 collectible with the
    /// rarity-driven holo treatment. Background of the list section
    /// is transparent so the card's own shadow + rarity glow read
    /// against the table backdrop.
    private var pokeCardSection: some View {
        Section {
            HStack {
                Spacer(minLength: 0)
                PokeCardView(
                    plane: PokePlane(catchRecord: catchRecord),
                    size: .lg
                )
                Spacer(minLength: 0)
            }
            .padding(.vertical, 20)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
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

    /// Photo section. Loading + loaded both render at a 3:2 aspect
    /// ratio (matches the natural shape of Planespotters' thumbnail_large
    /// at 420×280), with `.fit` aspect mode on the image so the whole
    /// plane is always visible — wider/narrower photos letterbox
    /// against the `bgElevated` base instead of being cropped.
    /// `notAvailable` collapses to a compact ~40pt strip so a missing
    /// photo doesn't bloat the page.
    @ViewBuilder
    private var photoSection: some View {
        switch photoState {
        case .loading:
            Section { loadingSlab }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
        case .loaded(let photo):
            Section { loadedPhotoView(photo) }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
        case .notAvailable:
            Section { noPhotoStrip }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
        }
    }

    private var loadingSlab: some View {
        ZStack {
            Brand.Color.bgElevated
            ProgressView().tint(Brand.Color.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(3.0 / 2.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Loaded photo at 3:2 aspect with `.fit` so the entire airframe
    /// is visible. Letterbox bands (if any) are `bgElevated`. Only the
    /// attribution chip in the bottom-leading corner is tappable — the
    /// photo itself is not a hyperlink (per UX preference).
    private func loadedPhotoView(_ photo: PlanePhoto) -> some View {
        ZStack(alignment: .bottomLeading) {
            Brand.Color.bgElevated

            AsyncImage(url: photo.thumbnailLargeURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .transition(.opacity)
                case .empty:
                    ProgressView().tint(Brand.Color.textSecondary)
                case .failure:
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title2)
                        .foregroundStyle(Brand.Color.textTertiary)
                @unknown default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button {
                UIApplication.shared.open(photo.link)
            } label: {
                Text("© \(photo.photographer) · planespotters.net")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.6), in: .rect(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(3.0 / 2.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Compact "no photo" strip. Doesn't reserve hero-photo space when
    /// Planespotters has no record for this icao24 — keeps the page
    /// from feeling padded out by a void.
    private var noPhotoStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .foregroundStyle(Brand.Color.textTertiary)
            Text("No photo available")
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.textTertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 8))
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
