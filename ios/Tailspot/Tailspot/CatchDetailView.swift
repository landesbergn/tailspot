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
//  The card turns over (2026-10-25): `FlipCard` holds the settled card on
//  the front and `CatchCardBack` (closeup photo + type info) on the back.
//  Planespotters is fetched on appear for EVERY catch now, because the
//  back's closeup wants the exact airframe even when the front shows the
//  user's own photo. The Wikipedia summary waits for the first turn-over.
//
//  Dates pulled from `row.firstCatch` (earliest), not `row.mostRecent`,
//  so CAUGHT reads as a fact about the tail, not the latest tap.
//

import SwiftUI
import SwiftData
import os

struct CatchDetailView: View {
    let row: HangarRow
    /// True when this detail is the root of a sheet (MapScreen's pin
    /// detail) rather than a push. A back chevron inside a modal reads
    /// as push navigation, so the chrome pill renders an X instead —
    /// same dismiss, honest affordance.
    var presentedModally: Bool = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var modelContext

    @State private var showDeleteConfirm = false
    @State private var showShareSheet = false
    /// Photos-style zoom transition for the user's own catch photo: the
    /// card hero feeds it (HeroZoomSource inside SettledCatchCard), the
    /// overlay at this screen's root renders the morph + open viewer.
    @State private var heroZoom = HeroZoomModel()

    /// Planespotters lookup, only consulted when the catch has no
    /// user-captured photo of its own. nil = not loaded yet OR none
    /// available; we don't need to distinguish for the card (it falls
    /// through to its placeholder either way), but we DO need the
    /// distinction for the attribution chip — hence `didFetchPhoto`.
    @State private var planespottersPhoto: PlanePhoto? = nil
    @State private var didFetchPhoto = false
    /// True once the Planespotters lookup has ANSWERED (hit or miss) — the
    /// back's closeup shows `.loading` until then.
    @State private var planespottersResolved = false

    // MARK: Card back (2026-10-25)

    /// Which face of the card is up. FlipCard also toggles it on a swipe,
    /// so side effects hang off `onChange(of: isFlipped)`, not the buttons.
    @State private var isFlipped = false
    /// A turn to the back made before the Planespotters lookup answered;
    /// reported once the closeup resolves (`CardTurnAnalytics.sendsImmediately`).
    @State private var pendingTurnReport = false
    /// Bundled type facts + "you and this type", computed once on appear
    /// (after the backfill, which can fill a missing typecode) rather than
    /// in `body` — TypeHistory walks the whole Hangar.
    @State private var typeInfo: TypeInfo? = nil
    @State private var typeHistory: TypeHistory? = nil
    /// The live Wikipedia summary, fetched on the first turn-over.
    @State private var summary: WikipediaSummary? = nil
    @State private var summaryLoading = false
    @State private var didRequestSummary = false

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
                    let cardWidth = min(geo.size.width - 36, 420)
                    FlipCard(isFlipped: $isFlipped) {
                        SettledCatchCard(
                            plane: detailPlane,
                            isFirstOfType: wasFirstOfType,
                            width: cardWidth,
                            // User catch photo → the full-res zoom viewer.
                            // Planespotters hero → its photo page (TOS: the
                            // thumbnail itself must link there; licensing review
                            // 2026-07-11 — the tappable caption below stays as
                            // the visible credit). Placeholder → inert.
                            onPhotoTap: heroTapAction,
                            photoTapAccessibilityLabel: hasCatchPhoto
                                ? "View photo full screen"
                                : "View photo on Planespotters.net",
                            heroZoom: hasCatchPhoto ? heroZoom : nil,
                            caughtAt: first.caughtAt
                        )
                    } back: {
                        CatchCardBack(model: backModel, width: cardWidth,
                                      onOpenURL: { openURL($0) })
                    }
                    .frame(maxWidth: .infinity)
                    if let photo = planespottersPhoto, !hasCatchPhoto {
                        attribution(photo)
                    }
                }
                .padding(.horizontal, 18)
                // Clears the 44 pt floating chrome bar (8 pt top inset + 36 pt
                // pill) with a 12 pt breath — was 72 pt of dead air (2026-08-12
                // spacing pass: the pills → photo gap read as empty).
                .padding(.top, 56)
                .padding(.bottom, 40)
            }

            chromeBar
                .padding(.top, 8)

            // Morph layer: empty while idle; renders the photo growing out
            // of (and back into) the card, then the open viewer. Sits above
            // the chrome so the open photo owns the whole screen.
            HeroZoomOverlay(model: heroZoom)
        }
        }
        .toolbar(.hidden, for: .navigationBar)
        .swipeBackEnabled()
        .onAppear {
            heroZoom.onCommit = { method in
                Analytics.capture("catch_photo_viewer_opened",
                                  ["source": .string("detail"), "method": .string(method)])
            }
        }
        .sheet(isPresented: $showShareSheet) {
            CatchShareSheet(plane: detailPlane,
                            shareText: shareText,
                            shareMessage: shareMessage,
                            hasCatchPhoto: hasCatchPhoto,
                            source: .detail)
        }
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
            // Type facts before AND after the backfill: the first pass
            // fills the back straight away, the second catches a typecode
            // the backfill just recovered.
            computeTypeFacts()
            // Only when the backfill filled a field the type facts read.
            let factsKey = { [first.typecode, first.manufacturer, first.model, first.operatorName] }
            let before = factsKey()
            await backfillIfNeeded()
            if factsKey() != before { computeTypeFacts() }
            if isFlipped { fetchSummaryIfNeeded() }
            // Fetched for every catch: the front hero only uses it when
            // there's no catch photo (`detailPlane`), but the back's
            // closeup always wants the exact airframe.
            guard !didFetchPhoto else { return }
            didFetchPhoto = true
            let fetched = await PlanespottersClient.shared.photo(for: first.icao24)
            withAnimation(.easeInOut(duration: 0.25)) {
                planespottersPhoto = fetched
                planespottersResolved = true
            }
        }
        .onChange(of: isFlipped) { _, flipped in
            if pendingTurnReport { sendTurnReport(flipped: true) }
            if CardTurnAnalytics.sendsImmediately(flipped: flipped, closeup: backModel.closeup) {
                sendTurnReport(flipped: flipped)
            } else {
                pendingTurnReport = true
            }
            if flipped { fetchSummaryIfNeeded() }
        }
        .onChange(of: backModel.closeup) { _, closeup in
            if pendingTurnReport, closeup != .loading { sendTurnReport(flipped: true) }
        }
    }

    // MARK: - Card back

    /// What the back renders. Cheap: everything heavy is cached in @State.
    private var backModel: CardBackModel {
        CardBackModel(
            modelName: detailPlane.model ?? "Unknown aircraft",
            registration: first.registration,
            rarity: rarity,
            closeup: .resolve(planespotters: planespottersPhoto,
                              lookupDone: planespottersResolved,
                              typePhoto: typeInfo?.photo),
            typeInfo: typeInfo,
            history: typeHistory,
            summary: summary,
            summaryLoading: summaryLoading
        )
    }

    private func sendTurnReport(flipped: Bool) {
        pendingTurnReport = false
        CardTurnAnalytics.capture(source: .detail, flipped: flipped,
                                  closeup: backModel.closeup,
                                  hasTypeInfo: typeInfo != nil)
    }

    private func computeTypeFacts() {
        typeInfo = TypeInfoStore.info(for: first)
        typeHistory = TypeHistory.compute(for: first, in: allCatches)
    }

    /// One Wikipedia request per screen visit, on the first turn-over.
    private func fetchSummaryIfNeeded() {
        guard !didRequestSummary, let title = typeInfo?.wikipediaTitle else { return }
        didRequestSummary = true
        summaryLoading = true
        Task {
            let fetched = await WikipediaSummaryClient.shared.summary(forTitle: title)
            withAnimation(.easeInOut(duration: 0.25)) {
                summary = fetched
                summaryLoading = false
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
            distText: CardPlane.distText(fromMeters: first.slantDistanceMeters),
            photoURL: photoURL,
            photoFocus: hasCatchPhoto ? first.photoFocus : nil,
            originIcao: first.displayOrigin,
            destIcao: first.displayDest,
            originName: first.originName,
            destName: first.destName,
            isFirstOfType: wasFirstOfType,
            icao24: first.icao24
        )
    }

    /// The Planespotters photo-page URL when — and only when — the card
    /// hero is a Planespotters image (no user catch photo). nil keeps the
    /// hero inert (user photo or placeholder).
    private var heroPhotoLink: URL? {
        hasCatchPhoto ? nil : planespottersPhoto?.link
    }

    /// Full-res file URL of the user's own catch photo, when there is one —
    /// the tap-to-zoom subject.
    private var catchPhotoURL: URL? {
        hasCatchPhoto ? first.photoFilename.flatMap { CatchPhotoStore.url(forFilename: $0) } : nil
    }

    /// What tapping the hero does: user catch photo → play the zoom morph
    /// (same transition the pinch drives); Planespotters hero → its photo
    /// page; placeholder → nothing (nil).
    private var heroTapAction: (() -> Void)? {
        if let url = catchPhotoURL {
            let focus = first.photoFocus
            return { heroZoom.openByTap(url: url, focus: focus) }
        }
        return heroPhotoLink.map { url in { openURL(url) } }
    }

    /// Historical first-of-type: no catch of this typecode predates the
    /// row's earliest. Mirrors the +50% the backend awarded at catch time
    /// (re-derived, like `resolvedRarity` — no stored flag needed).
    private var wasFirstOfType: Bool {
        guard let tc = first.typecode else { return false }
        return !allCatches.contains { $0.typecode == tc && $0.caughtAt < first.caughtAt }
    }

    // MARK: - Floating chrome pills

    /// Back chevron (left) + trash + share (right) — `.ultraThinMaterial`
    /// discs with a white 10% hairline. System nav bar is hidden so they
    /// own the top of the view.
    private var chromeBar: some View {
        HStack {
            chromePill(icon: presentedModally ? "xmark" : "chevron.left") { dismiss() }
                .accessibilityLabel(presentedModally ? "Close" : "Back")
            Spacer()
            Button {
                showDeleteConfirm = true
            } label: {
                chromePillBody(icon: "trash", tint: Brand.Color.alertWarning)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete catch")
            .padding(.trailing, 8)
            // Share opens CatchShareSheet (swipeable shapes + destinations).
            // This tap is the top of the share funnel; the sheet reports the
            // rest (CatchShareAnalytics).
            Button {
                CatchShareAnalytics(plane: detailPlane, hasCatchPhoto: hasCatchPhoto, source: .detail)
                    .sheetOpened()
                showShareSheet = true
            } label: {
                chromePillBody(icon: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share catch")
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
            // 44pt minimum hit target (HIG): the disc stays 36pt visually,
            // the tappable region grows 4pt past every edge via contentShape.
            .contentShape(Rectangle().inset(by: -4))
    }

    /// Share copy, built by `CatchShare` so the reveal's Share says the same.
    /// The model is the card's (canonical) name, as on the reveal, so the
    /// words match the card in the image.
    private var shareText: String {
        CatchShare.shareText(for: detailPlane)
    }

    private var shareMessage: String { CatchShare.shareMessage(shareText: shareText) }

    // MARK: - Attribution

    /// Planespotters TOS: any UI that displays one of their photos must
    /// credit the photographer and link the photo page — and the photo
    /// THUMBNAIL itself must carry that link (licensing review 2026-07-11;
    /// wired via `SettledCatchCard.onPhotoTap` above). This caption stays
    /// as the visible "© photographer" credit, also tappable. Hidden when
    /// we're not actually showing a Planespotters image (catch photo or
    /// nothing-found).
    private func attribution(_ photo: PlanePhoto) -> some View {
        // 11 pt secondary (not 10 pt tertiary): this is an interactive
        // credit link the TOS requires people to be able to find and tap —
        // it has to clear the HIG text floor and read as tappable. The
        // inset grows the one-line label to a ≥44 pt hit target.
        Button {
            openURL(photo.link)
        } label: {
            Text("© \(photo.photographer) · planespotters.net")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Brand.Color.textSecondary)
                .contentShape(Rectangle().inset(by: -15))
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
            rarity: row.allCatches.first?.resolvedRarity.rawValue,
            source: .hangarDelete
        )
        // Capture the server ids BEFORE the delete — a deleted model's
        // properties can't be read afterwards.
        let serverUuids = row.allCatches.compactMap(\.serverUuid)
        for c in row.allCatches {
            CatchPhotoStore.delete(filename: c.photoFilename)
            modelContext.delete(c)
        }
        do { try modelContext.save() } catch {
            Log.adsb.error("Detail delete failed for \(row.icao24, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        // …and off the server, so it stops counting toward the leaderboard
        // and challenge scores.
        CatchDeletionSync.deleteRemotely(serverUuids)
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
