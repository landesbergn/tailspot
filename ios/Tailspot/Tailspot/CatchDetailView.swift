//
//  CatchDetailView.swift
//  Tailspot
//
//  Tail detail — Direction B, "the settled reveal" (Noah's pick,
//  2026-07-05): the reveal card AT REST is the whole story. One
//  `SettledCatchCard` (photo hero, settled split-flap name, tier line,
//  ALT/SPD + ROUTE, score ledger) + one quiet fine-print block
//  (REG/ICAO/TYPE + caught date · place) + optional Planespotters
//  attribution. The old EARNED / ROUTE / FIRST CAUGHT / AIRFRAME box
//  stack is gone — each fact appears exactly once.
//
//  Photo slot: the user's catch JPEG when present; otherwise we fetch a
//  Planespotters thumbnail by icao24 on appear and rebuild the CardPlane
//  with that URL; if that also misses, the card paints its placeholder.
//
//  Dates pulled from `row.firstCatch` (earliest), not `row.mostRecent`,
//  so CAUGHT reads as a fact about the tail, not the latest tap.
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

    /// Whole-Hangar query, only consulted by `wasFirstOfType` (the ledger's
    /// FIRST OF TYPE line needs to know whether any catch of this typecode
    /// predates this one).
    @Query private var allCatches: [Catch]

    private var first: Catch { row.firstCatch }
    private var rarity: Rarity { row.rarity }
    private var type: AircraftType { row.aircraftType }
    private var hasCatchPhoto: Bool { first.photoFilename != nil }

    var body: some View {
        GeometryReader { geo in
        ZStack(alignment: .top) {
            Brand.Color.bgPrimary.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    // Direction B (2026-07-05): the reveal card at rest IS
                    // the detail screen — one card design across the app.
                    SettledCatchCard(
                        plane: detailPlane,
                        isFirstOfType: wasFirstOfType,
                        width: min(geo.size.width - 36, 420)
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    finePrint
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
        }
        .toolbar(.hidden, for: .navigationBar)
        .swipeBackEnabled()
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

    // MARK: - Card model

    /// `CardPlane` for the settled card. Route display codes prefer IATA
    /// (`Catch.displayOrigin`/`displayDest`). Photo slot: catch JPEG →
    /// Planespotters thumbnail (once loaded) → the card's placeholder.
    private var detailPlane: CardPlane {
        let canonical = AircraftNaming.canonical(
            typecode: first.typecode,
            manufacturer: first.manufacturer,
            model: first.model
        )
        let photoURL = hasCatchPhoto
            ? first.photoFilename.flatMap { CatchPhotoStore.url(forFilename: $0) }
            : planespottersPhoto?.thumbnailLargeURL
        return CardPlane(
            callsign: first.callsign,
            model: canonical.displayName ?? first.model,
            carrier: Airlines.operatorLabel(operatorName: first.operatorName,
                                            callsign: first.callsign),
            rarity: rarity,
            type: type,
            altText: CardPlane.altText(fromMeters: first.altitudeMeters),
            speedText: CardPlane.speedText(fromMps: first.velocityMps),
            distText: String(format: "%.1f km", first.slantDistanceMeters / 1000),
            photoURL: photoURL,
            photoFocus: hasCatchPhoto ? first.photoFocus : nil,
            originIcao: first.displayOrigin,
            destIcao: first.displayDest,
            originName: first.originName,
            destName: first.destName,
            isFirstOfType: wasFirstOfType
        )
    }

    /// Historical first-of-type: no catch of this typecode predates the
    /// row's earliest. Mirrors the +50% the backend awarded at catch time
    /// (re-derived, like `resolvedRarity` — no stored flag needed).
    private var wasFirstOfType: Bool {
        guard let tc = first.typecode else { return false }
        return !allCatches.contains { $0.typecode == tc && $0.caughtAt < first.caughtAt }
    }

    // MARK: - Fine print (below the card)

    /// The quiet facts under the card, one block in the reveal's label
    /// vocabulary: airframe identity (REG / ICAO / TYPE — backfillable
    /// facts, "—" when unknown) above a rule, then the catch moment
    /// (date · time · place). Everything the old EARNED / ROUTE / FIRST
    /// CAUGHT / AIRFRAME boxes said now lives either on the card (points,
    /// tier, route) or here — each fact exactly once.
    private var finePrint: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                airframeField("REG", first.registration?.trimmedNonEmpty ?? "—")
                airframeField("ICAO", first.icao24.uppercased())
                airframeField("TYPE", first.typecode?.trimmedNonEmpty ?? "—")
            }
            Rectangle().fill(Brand.Color.textPrimary.opacity(0.07)).frame(height: 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("CAUGHT")
                    .font(Brand.Font.mono(size: 8, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Brand.Color.textTertiary)
                Text("\(first.caughtAt.formatted(date: .abbreviated, time: .shortened)) · \(first.placeName ?? observerCoordText)")
                    .font(Brand.Font.mono(size: 12, weight: .regular))
                    .foregroundStyle(Brand.Color.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
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
        // Render the share card once per build (ImageRenderer is synchronous;
        // this view isn't on a hot render path).
        let img = shareImage
        return HStack {
            chromePill(icon: "chevron.left") { dismiss() }
            Spacer()
            Button {
                showDeleteConfirm = true
            } label: {
                chromePillBody(icon: "trash", tint: Brand.Color.alertWarning)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            // Share a polished card image (not just text) so friends get a
            // clean card instead of a screenshot; the text rides as the
            // preview title.
            ShareLink(item: img, preview: SharePreview(shareText, image: img)) {
                chromePillBody(icon: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    /// Rendered share-card image for this catch — the settled card in share
    /// chrome; the local capture photo when present, else the sky placeholder.
    private var shareImage: Image {
        CatchShare.image(for: detailPlane)
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
        // Catch-confirmation telemetry (north-star): a delete is the
        // strongest "didn't keep/trust it" signal. Fire once per delete
        // action before the rows go away.
        CatchTelemetry.fireDeleted(
            icao24: row.icao24,
            count: row.count,
            rarity: row.allCatches.first?.resolvedRarity.rawValue
        )
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
            // FAA fallback: if OpenSky gave nothing (typecode + model still
            // nil), try the bundled FAA snapshot for US-registered aircraft.
            if first.typecode == nil && first.model == nil {
                if CatchBackfill.applyFAAFallback(to: row.allCatches, icao24: first.icao24) { dirty = true }
            }
        }

        // Place + country are both properties of the observer location, so
        // one geocode fills whichever is still nil (fill-if-nil; never
        // overwrites a recorded value).
        if (first.placeName == nil || first.country == nil),
           first.observerLat != 0 || first.observerLon != 0 {
            let (place, country) = await ReverseGeocode.placeAndCountry(
                lat: first.observerLat, lon: first.observerLon
            )
            if first.placeName == nil, let place { first.placeName = place; dirty = true }
            if first.country == nil, let country { first.country = country; dirty = true }
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
