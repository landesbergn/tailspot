//
//  CatchDetailView.swift
//  Tailspot
//
//  Tail detail — PokeCard hero front-and-center. Rewritten per spec
//  § 8 (T18): the card carries identity (callsign + model + carrier)
//  and the photo slot, so the page drops the prior 320pt photo hero,
//  the 6-cell stats grid, and the catch-log timeline. What remains is
//  the card + EARNED panel + first-caught panel + (optional)
//  Planespotters attribution.
//
//  Photo-slot priority is owned by `PokeCardView` via `PokePlane.photoURL`:
//  the default builder threads the user's catch JPEG when present. We
//  fall through to Planespotters here: on appear, if there's no catch
//  photo we fetch by icao24, then rebuild the PokePlane with that URL.
//  If Planespotters also has nothing, the card paints its own
//  rarity-tinted striped placeholder.
//
//  Dates pulled from `row.firstCatch` (earliest), not `row.mostRecent`,
//  so "FIRST CAUGHT" reads as a fact about the tail, not the latest tap.
//

import SwiftUI
import SwiftData
import os

struct CatchDetailView: View {
    let row: HangarRow

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var modelContext

    @State private var showDeleteConfirm = false

    /// Planespotters lookup, only consulted when the catch has no
    /// user-captured photo of its own. nil = not loaded yet OR none
    /// available; we don't need to distinguish for the card (it falls
    /// through to its placeholder either way), but we DO need the
    /// distinction for the attribution chip — hence `didFetchPhoto`.
    @State private var planespottersPhoto: PlanePhoto? = nil
    @State private var didFetchPhoto = false

    private var first: Catch { row.firstCatch }
    private var rarity: Rarity { row.rarity }
    private var type: AircraftType { row.aircraftType }
    private var hasCatchPhoto: Bool { first.photoFilename != nil }

    var body: some View {
        ZStack(alignment: .top) {
            Brand.Color.bgPrimary.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    pokeCardHero
                        .padding(.top, 8)
                    earnedPanel
                    firstCaughtPanel
                    airframePanel
                    if let photo = planespottersPhoto, !hasCatchPhoto {
                        attribution(photo)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 64)
                .padding(.bottom, 40)
            }

            chromeBar
                .padding(.top, 8)
        }
        .toolbar(.hidden, for: .navigationBar)
        .alert(deleteTitle, isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
        // Preserves swipe-from-left-edge to pop. The floating chevron
        // pill is the explicit back affordance; the swipe is the
        // implicit one. `.navigationBarBackButtonHidden(true)` would
        // disable the interactive pop gesture in addition to hiding
        // the (already hidden) back button.
        .task {
            await backfillIfNeeded()
            // Skip the net call when the user has a catch photo —
            // the card already paints that JPEG and attribution is
            // suppressed.
            guard !didFetchPhoto, !hasCatchPhoto else {
                didFetchPhoto = true
                return
            }
            didFetchPhoto = true
            let fetched = await PlanespottersClient.shared.photo(for: first.icao24)
            withAnimation(.easeInOut(duration: 0.25)) {
                planespottersPhoto = fetched
            }
        }
    }

    // MARK: - Hero

    /// PokeCard at `.lg`, centered. Photo slot is resolved here: catch
    /// JPEG (handled by `PokePlane.init(catchRecord:)`) → Planespotters
    /// thumbnail (rebuilt below once `planespottersPhoto` lands) →
    /// striped rarity placeholder (handled by the card itself).
    private var pokeCardHero: some View {
        PokeCardView(plane: pokePlane, size: .lg)
            .frame(maxWidth: .infinity)
    }

    /// `PokePlane` for the card. When the catch carries its own photo
    /// we use the default builder (which threads `photoFilename` into
    /// `photoURL`). Otherwise we layer a Planespotters URL on top once
    /// the network call returns; until it returns, `photoURL` is nil
    /// and the card falls through to its striped placeholder.
    private var pokePlane: PokePlane {
        let base = PokePlane(catchRecord: first)
        if hasCatchPhoto { return base }
        guard let photo = planespottersPhoto else { return base }
        return PokePlane(
            callsign: base.callsign,
            model: base.model,
            carrier: base.carrier,
            rarity: base.rarity,
            type: base.type,
            altText: base.altText,
            speedText: base.speedText,
            distText: base.distText,
            photoURL: photo.thumbnailLargeURL
        )
    }

    // MARK: - EARNED panel

    /// Rarity-tinted summary box: base points (left), rarity + type
    /// (right). Spec § 8.
    private var earnedPanel: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("EARNED")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(rarity.tint)
                Text("+\(rarity.basePoints) pts")
                    .font(Brand.Font.mono(size: 22, weight: .bold))
                    .foregroundStyle(rarity.tint)
                    .monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(rarity.label)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Brand.Color.textTertiary)
                Text("Type · \(type.label.capitalized)")
                    .font(Brand.Font.mono(size: 10, weight: .regular))
                    .foregroundStyle(Brand.Color.textTertiary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(rarity.tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(rarity.tint, lineWidth: 1)
        )
    }

    // MARK: - First-caught panel

    /// Earliest catch on this tail: date · time, then observer lat/lon
    /// with hemispheric letters.
    private var firstCaughtPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FIRST CAUGHT")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.textTertiary)
            Text(first.caughtAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Brand.Color.textPrimary)
            Text(first.placeName ?? observerCoordText)
                .font(Brand.Font.mono(size: 12, weight: .regular))
                .foregroundStyle(Brand.Color.textTertiary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 10))
    }

    // MARK: - Airframe panel

    /// Registration (tail number) + ICAO hex + type designator. These
    /// are airframe facts, not moment facts — recoverable by the
    /// backfill for rows that predate the fields. "—" when OpenSky
    /// simply doesn't know.
    private var airframePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AIRFRAME")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.textTertiary)
            HStack(spacing: 0) {
                airframeField("REG", first.registration?.trimmedNonEmpty ?? "—")
                airframeField("ICAO", first.icao24.uppercased())
                airframeField("TYPE", first.typecode?.trimmedNonEmpty ?? "—")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 10))
    }

    private func airframeField(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Brand.Font.mono(size: 8, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Brand.Color.textTertiary)
            Text(value)
                .font(Brand.Font.mono(size: 13, weight: .bold))
                .foregroundStyle(Brand.Color.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var observerCoordText: String {
        let lat = first.observerLat
        let lon = first.observerLon
        let latH = lat >= 0 ? "N" : "S"
        let lonH = lon >= 0 ? "E" : "W"
        return String(format: "%.4f° %@, %.4f° %@", abs(lat), latH, abs(lon), lonH)
    }

    // MARK: - Floating chrome pills

    /// Back chevron (left) + trash + share (right) — `.ultraThinMaterial`
    /// discs with a white 10% hairline. System nav bar is hidden so they
    /// own the top of the view.
    private var chromeBar: some View {
        HStack {
            chromePill(icon: "chevron.left") { dismiss() }
            Spacer()
            Button {
                showDeleteConfirm = true
            } label: {
                chromePillBody(icon: "trash", tint: Brand.Color.alertWarning)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            ShareLink(item: shareText) {
                chromePillBody(icon: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    private func chromePill(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            chromePillBody(icon: icon)
        }
        .buttonStyle(.plain)
    }

    private func chromePillBody(icon: String, tint: Color = Brand.Color.textPrimary) -> some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(.ultraThinMaterial, in: .circle)
            .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }

    /// Free text for the iOS share sheet. No image attachment — keeps
    /// share targets (Messages, Mail, copy-link, etc.) predictable.
    private var shareText: String {
        let cs = first.callsign?.trimmedNonEmpty ?? first.icao24.uppercased()
        let model = first.model?.trimmedNonEmpty
        let modelPart = model.map { " · \($0)" } ?? ""
        return "Caught \(cs)\(modelPart) on Tailspot"
    }

    // MARK: - Attribution

    /// Planespotters TOS: any UI that displays one of their photos must
    /// link the photo page and credit the photographer. Hidden when
    /// we're not actually showing a Planespotters image (catch photo or
    /// nothing-found).
    private func attribution(_ photo: PlanePhoto) -> some View {
        Button {
            openURL(photo.link)
        } label: {
            Text("© \(photo.photographer) · planespotters.net")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(Brand.Color.textTertiary)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 4)
    }

    // MARK: - Delete

    private var deleteTitle: String {
        let cs = first.callsign?.trimmedNonEmpty ?? first.icao24.uppercased()
        if row.count == 1 { return "Delete catch of \(cs)?" }
        return "Delete all \(row.count) catches of \(cs)?"
    }

    /// Drops every catch in the row AND each catch's photo file —
    /// rows referencing dead files would render placeholder stripes
    /// and the orphaned JPEGs would pile up in Documents/catches.
    private func performDelete() {
        for c in row.allCatches {
            CatchPhotoStore.delete(filename: c.photoFilename)
            modelContext.delete(c)
        }
        do { try modelContext.save() } catch {
            Log.adsb.error("Detail delete failed for \(row.icao24, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        dismiss()
    }

    // MARK: - Backfill

    /// One-time recovery of airframe-static facts for rows written
    /// before these fields existed. AMENDS the "read-only snapshot"
    /// rule deliberately (spec 2026-06-06 § E): fill-only-if-nil, so
    /// recorded values are never overwritten, and moment-data
    /// (alt/speed) is never touched. operatorName is the documented
    /// exception — what we recover is the CURRENT operator, not
    /// as-flown; better than a permanent blank for pre-field rows.
    /// Persisted on success, so each row backfills at most once;
    /// offline/failed fetches leave nil and retry on the next open.
    private func backfillIfNeeded() async {
        var dirty = false

        if CatchBackfill.needsMetadata(first) {
            if let meta = (try? await CatchBackfill.client.aircraftMetadata(icao24: first.icao24)) ?? nil {
                if CatchBackfill.applyMetadata(meta, to: row.allCatches) { dirty = true }
            }
        }

        if first.placeName == nil, first.observerLat != 0 || first.observerLon != 0 {
            if let place = await ReverseGeocode.placeName(
                lat: first.observerLat, lon: first.observerLon
            ) {
                first.placeName = place
                dirty = true
            }
        }

        if dirty { try? modelContext.save() }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
