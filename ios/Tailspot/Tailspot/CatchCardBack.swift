//
//  CatchCardBack.swift
//  Tailspot
//
//  The BACK of a catch card (2026-10-25) — what you see when you turn the
//  card over (`FlipCard`, CardFlip.swift). Top to bottom:
//   1. The closeup: the Planespotters photo of this exact airframe, else a
//      Wikimedia Commons photo of the type (no "representative" label —
//      Noah's call — but the licence credit is always shown), else a quiet
//      sky. The photo itself links to its source page (Planespotters TOS;
//      Commons asks for a link to the file page).
//   2. The model name.
//   3. You and this type, no header (Noah, 2026-10-26: the rules between
//      sections are enough) — computed from the Hangar (`TypeHistory`).
//   4. Specs, no header, on one row — bundled Wikidata facts (`TypeInfo`).
//      Missing facts are omitted, never guessed; a section with nothing in
//      it disappears.
//   5. The Wikipedia summary, unedited, with its CC BY-SA credit and a
//      "Read more" link.
//   6. BACK TO CATCH.
//
//  Built from the same atoms as the front (RP palette, CatchRarityFrame,
//  CatchRarityBorder, the mono label/ledger vocabulary) so the two faces
//  read as one card. FlipCard lays the back out at the FRONT's measured
//  height; when the content doesn't fit, the Wikipedia extract is the part
//  that gives way (lowest layout priority).
//

import SwiftUI
import UIKit

// MARK: - Model

/// What the closeup slot shows.
nonisolated enum CardBackCloseup: Equatable, Sendable {
    /// Lookups still in flight.
    case loading
    /// The Planespotters photo of this exact airframe.
    case planespotters(PlanePhoto)
    /// A Wikimedia Commons photo of the aircraft type (bundled metadata).
    case commons(TypePhoto)
    /// Nothing to show — a quiet sky, no claim about the plane.
    case none
}

nonisolated extension CardBackCloseup {
    /// The closeup a caller shows, from what its lookups have found so far.
    /// The exact airframe (Planespotters) wins whenever it's in; until the
    /// Planespotters lookup has answered the slot says `.loading` (so a
    /// Commons type photo never flashes up and then gets replaced); after a
    /// miss it falls back to the bundled Commons photo of the type, else
    /// the quiet sky.
    static func resolve(planespotters: PlanePhoto?, lookupDone: Bool,
                        typePhoto: TypePhoto?) -> CardBackCloseup {
        if let planespotters { return .planespotters(planespotters) }
        guard lookupDone else { return .loading }
        if let typePhoto { return .commons(typePhoto) }
        return .none
    }

    /// The `closeup` property on `catch_card_turned`.
    var analyticsValue: String {
        switch self {
        case .loading: return "loading"
        case .planespotters: return "planespotters"
        case .commons: return "commons"
        case .none: return "none"
        }
    }
}

/// `catch_card_turned` — fired each time a card is turned over, either way.
/// One helper so the detail screen and the reveal send the same shape.
/// Since 2026-10-31 it also says which catch was being looked at: `icao24`,
/// `catch_uuid` (the card's own catch) and `catch_uuids` (comma-separated,
/// every catch the card stands for: a Hangar card groups all catches of one
/// airframe). The uuids match `catch_uuid` on `catch_performed`, so the
/// PostHog catch log can show whether each catch's card was ever turned.
enum CardTurnAnalytics {
    enum Source: String { case detail, reveal }

    /// The event's properties. Pure, so tests pin the shape.
    /// `catchUuids[0]` is the card's own catch. Uuids and `icao24` are
    /// omitted when unknown (the reveal's early shell before its row
    /// exists), never sent blank.
    nonisolated static func properties(source: Source, flipped: Bool,
                                       closeup: CardBackCloseup,
                                       hasTypeInfo: Bool,
                                       catchUuids: [String] = [],
                                       icao24: String? = nil) -> [String: AnalyticsValue] {
        var props: [String: AnalyticsValue] = [
            "source": .string(source.rawValue),
            "side": .string(flipped ? "back" : "front"),
            "closeup": .string(closeup.analyticsValue),
            "has_type_info": .bool(hasTypeInfo),
        ]
        let uuids = catchUuids.filter { !$0.isEmpty }
        if let own = uuids.first {
            props["catch_uuid"] = .string(own)
            props["catch_uuids"] = .string(uuids.joined(separator: ","))
        }
        if let icao24, !icao24.isEmpty { props["icao24"] = .string(icao24) }
        return props
    }

    /// Whether a turn can be reported right away. A turn to the back while
    /// the closeup is still `.loading` waits for the lookup, so `closeup`
    /// says which photo the user actually got (on the reveal nothing is
    /// fetched until the first turn, so it would otherwise always read
    /// "loading").
    nonisolated static func sendsImmediately(flipped: Bool, closeup: CardBackCloseup) -> Bool {
        !(flipped && closeup == .loading)
    }

    /// Sends the event unless `muted` (the DEBUG simulated reveal).
    /// `rows` are the catches the card stands for, the card's own first.
    /// Rows already deleted are skipped (touching a model that has left its
    /// context can trap); a live row with no uuid yet gets one minted.
    static func capture(source: Source, flipped: Bool, closeup: CardBackCloseup,
                        hasTypeInfo: Bool, rows: [Catch], icao24: String?,
                        muted: Bool = false) {
        guard !muted else { return }
        let live = rows.filter { !CatchUploader.isGone($0) }
        Analytics.capture("catch_card_turned",
                          properties(source: source, flipped: flipped,
                                     closeup: closeup, hasTypeInfo: hasTypeInfo,
                                     catchUuids: live.map { $0.ensureServerUuid() },
                                     icao24: live.first?.icao24 ?? icao24))
    }
}

/// Everything the back renders — pure data, assembled by the caller
/// (CatchDetailView / CatchRevealView).
nonisolated struct CardBackModel: Equatable, Sendable {
    var modelName: String
    var registration: String?
    var rarity: Rarity
    var closeup: CardBackCloseup
    var typeInfo: TypeInfo?
    var history: TypeHistory?
    var summary: WikipediaSummary?
    var summaryLoading: Bool
}

// MARK: - Formatting (unit-tested)

/// One label/value cell on the back. `unit` renders smaller and muted after
/// the value ("117" + "ft"), like the front's statCell.
nonisolated struct CardBackCell: Equatable, Sendable {
    let label: String
    let value: String
    var unit: String? = nil
}

/// The back's copy decisions, kept out of the view so tests can pin them.
/// `nonisolated` — pure formatting over Sendable data.
nonisolated enum CardBackFormat {
    /// The registration tag goes on the photo only when the photo IS this
    /// airframe (Planespotters looks it up by icao24). A Commons type photo
    /// shows some other C172, so stamping this plane's tail number on it
    /// would claim an identity the photo doesn't have.
    static func showsRegistrationTag(for closeup: CardBackCloseup) -> Bool {
        if case .planespotters = closeup { return true }
        return false
    }

    /// "Mar 4, 2026" in the user's locale.
    static func firstCaught(_ date: Date, locale: Locale = .current,
                            timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.locale = locale
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// One row of the catch log: "SOUTHWEST" … "2×".
    struct LogRow: Equatable, Sendable {
        let name: String
        let count: String
    }

    /// The catch log: the top `top` operators as rows, then how many more
    /// operators there are (shown as "+N more"). Empty rows when the list is.
    static func catchLog(_ list: [TypeHistory.AirlineCount],
                         top: Int = 3) -> (rows: [LogRow], more: Int) {
        let named = list.filter { !$0.name.isEmpty && $0.count > 0 }
        let rows = named.prefix(top).map { LogRow(name: $0.name, count: "\($0.count)×") }
        return (rows, named.count - rows.count)
    }

    /// The exact number, grouped for the locale ("5,215") — never rounded
    /// or approximated.
    static func numberBuilt(_ n: Int, locale: Locale = .current) -> String {
        n.formatted(.number.grouping(.automatic).locale(locale))
    }

    /// A length in the app's chosen altitude unit (Settings → UNITS: feet →
    /// "117 ft", meters → "35.8 m"), number-formatted for the locale via
    /// MeasurementFormatter. Deliberate deviation from the spec's "unit from
    /// the locale": the app already has a units setting, and a back that said
    /// metres under a front that says feet would read as two cards (PLAN §9
    /// flags it for Noah's device pass). Feet are whole; meters keep one decimal under
    /// 100 m (wingspans/lengths of light aircraft need it), whole above.
    static func length(meters: Double, unit: AltitudeUnit, locale: Locale = .current) -> String {
        let f = MeasurementFormatter()
        f.locale = locale
        f.unitOptions = .providedUnit
        f.unitStyle = .medium
        f.numberFormatter.locale = locale
        let m = Measurement(value: meters, unit: UnitLength.meters)
        switch unit {
        case .feet:
            f.numberFormatter.maximumFractionDigits = 0
            return f.string(from: m.converted(to: .feet))
        case .meters:
            f.numberFormatter.minimumFractionDigits = 0
            f.numberFormatter.maximumFractionDigits = meters < 100 ? 1 : 0
            return f.string(from: m)
        }
    }

    /// Splits "117 ft" → ("117", "ft") on the last space — or the last
    /// non-breaking space some locales use between number and unit.
    static func splitMeasurement(_ s: String) -> (value: String, unit: String?) {
        let separators: [Character] = [" ", "\u{00A0}", "\u{202F}"]
        guard let idx = s.lastIndex(where: { separators.contains($0) }) else { return (s, nil) }
        let value = String(s[..<idx])
        let unit = String(s[s.index(after: idx)...])
        return unit.isEmpty ? (s, nil) : (value, unit)
    }

    /// The SPECS cells, in display order, omitting anything unknown.
    static func specCells(_ info: TypeInfo?, unit: AltitudeUnit,
                          locale: Locale = .current) -> [CardBackCell] {
        guard let info else { return [] }
        var cells: [CardBackCell] = []
        if let y = info.firstFlightYear, y > 0 {
            // A year is not a quantity: no grouping ("1967", not "1,967").
            cells.append(CardBackCell(label: "FIRST FLEW", value: String(y)))
        }
        if let n = info.numberBuilt, n > 0 {
            cells.append(CardBackCell(label: "BUILT", value: numberBuilt(n, locale: locale)))
        }
        if let w = info.wingspanMeters, w > 0 {
            let p = splitMeasurement(length(meters: w, unit: unit, locale: locale))
            cells.append(CardBackCell(label: "WINGSPAN", value: p.value, unit: p.unit))
        }
        if let l = info.lengthMeters, l > 0 {
            let p = splitMeasurement(length(meters: l, unit: unit, locale: locale))
            cells.append(CardBackCell(label: "LENGTH", value: p.value, unit: p.unit))
        }
        return cells
    }

    /// The closeup's credit, split in two so the view can let a long
    /// author name truncate while the licence and source always stay
    /// visible (CC BY / BY-SA attribution needs both). `author` is nil for
    /// a public-domain Commons photo with no known author.
    struct Credit: Equatable, Sendable {
        let author: String?
        let source: String
        /// "author · source", or just the source.
        var text: String { author.map { "\($0) · \(source)" } ?? source }
    }

    static func creditParts(for closeup: CardBackCloseup) -> Credit? {
        switch closeup {
        case .planespotters(let p):
            return Credit(author: "© \(p.photographer)", source: "planespotters.net")
        case .commons(let t):
            let artist = t.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            return Credit(author: artist.isEmpty ? nil : artist,
                          source: "\(t.license) · Wikimedia Commons")
        case .loading, .none:
            return nil
        }
    }

    /// The closeup's credit line — always shown with a remote photo.
    static func credit(for closeup: CardBackCloseup) -> String? {
        creditParts(for: closeup)?.text
    }

    /// Where tapping the photo (or its credit) goes.
    static func link(for closeup: CardBackCloseup) -> URL? {
        switch closeup {
        case .planespotters(let p): return p.link
        case .commons(let t): return t.pageURL
        case .loading, .none: return nil
        }
    }

    /// VoiceOver label for the photo button.
    static func photoAccessibilityLabel(for closeup: CardBackCloseup) -> String? {
        switch closeup {
        case .planespotters: return "View photo on Planespotters.net"
        case .commons: return "View photo on Wikimedia Commons"
        case .loading, .none: return nil
        }
    }

    /// Whether the Wikipedia block renders at all: a summary, or one loading.
    static func showsWikipedia(_ model: CardBackModel) -> Bool {
        model.summary != nil || model.summaryLoading
    }
}

// MARK: - View

struct CatchCardBack: View {
    let model: CardBackModel
    let width: CGFloat
    let onOpenURL: (URL) -> Void
    /// DEBUG/test hook: shown in place of the remote closeup so hosted
    /// snapshots (which can't wait on AsyncImage) still show a photo.
    let snapshotImage: UIImage?
    @State private var showingSummary = false
    @Environment(\.cardSwipeGuard) private var swipeGuard

    /// The photo and credit links: a swipe that started on them turns the
    /// card instead of opening Planespotters (see `CardSwipeGuard`).
    private func openUnlessSwiping(_ url: URL) {
        guard swipeGuard?.swallowsTap != true else { return }
        onOpenURL(url)
    }

    init(model: CardBackModel, width: CGFloat,
         onOpenURL: @escaping (URL) -> Void,
         snapshotImage: UIImage? = nil) {
        self.model = model
        self.width = width
        self.onOpenURL = onOpenURL
        self.snapshotImage = snapshotImage
    }

    var body: some View {
        let scale = width / 300
        let hPad = 22 * scale
        let history = model.history
        let first = history?.firstCaughtAt.map { CardBackFormat.firstCaught($0) }
        let log = CardBackFormat.catchLog(history?.airlines ?? [])
        let hasHistory = first != nil || !log.rows.isEmpty
        let specs = CardBackFormat.specCells(model.typeInfo, unit: UnitPreferences.shared.altitude)

        return VStack(alignment: .leading, spacing: 0) {
            closeupBlock(scale: scale)
                .padding([.horizontal, .top], 18 * scale)
                .padding(.bottom, 10 * scale)

            VStack(alignment: .leading, spacing: 10 * scale) {
                Text(model.modelName.uppercased())
                    .font(.system(size: 17 * scale, weight: .bold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(RP.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)

                if hasHistory {
                    Rectangle().fill(RP.rule).frame(height: 1)
                    VStack(spacing: 6 * scale) {
                        if let first { ledgerLine("FIRST CAUGHT", first, scale: scale) }
                        // The catch log: who was flying the ones you caught.
                        ForEach(log.rows, id: \.name) { row in
                            logLine(row.name.uppercased(), row.count, scale: scale)
                                .accessibilityLabel("\(row.name), \(row.count.dropLast()) caught")
                        }
                        if log.more > 0 {
                            logLine("+\(log.more) MORE", "", scale: scale)
                        }
                    }
                }

                if !specs.isEmpty {
                    Rectangle().fill(RP.rule).frame(height: 1)
                    specGrid(specs, scale: scale)
                }

                if CardBackFormat.showsWikipedia(model) {
                    Rectangle().fill(RP.rule).frame(height: 1)
                    wikipediaBlock(scale: scale)
                }
            }
            .padding(.horizontal, hPad)

            Spacer(minLength: 0)
        }
        .frame(width: width)
        // Fill whatever height FlipCard gives (the front's), so the frame's
        // background and border cover the whole face. BACK TO CATCH lives
        // under the card (`FlipCard`), not on it.
        .frame(maxHeight: .infinity, alignment: .top)
        .modifier(CatchRarityFrame(rarity: model.rarity, scale: scale))
    }

    // MARK: Closeup

    @ViewBuilder
    private func closeupBlock(scale: CGFloat) -> some View {
        let photo = closeupImage(scale: scale)
            // 132 (not the spec's ~190, nor the front hero's 168): the back is
            // laid out at the FRONT's height, and at 150 the Wikipedia extract on
            // a typical 737 detail card shrank to a single line.
            .frame(height: 132 * scale)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.card))
            .overlay(alignment: .topLeading) { registrationTag(scale: scale) }
            .overlay(
                CatchRarityBorder(rarity: model.rarity,
                                  cornerRadius: Brand.Radius.card, emphasis: 0.55)
            )
        let link = CardBackFormat.link(for: model.closeup)

        VStack(spacing: 6 * scale) {
            if let link {
                // TOS: the thumbnail itself links to its source page.
                Button { openUnlessSwiping(link) } label: { photo }
                    .buttonStyle(.plain)
                    .accessibilityLabel(CardBackFormat.photoAccessibilityLabel(for: model.closeup) ?? "View photo")
            } else {
                photo
            }

            if let credit = CardBackFormat.creditParts(for: model.closeup), let link {
                Button { openUnlessSwiping(link) } label: {
                    // Author and source as two Texts: only the author
                    // truncates (at its tail); the licence + source keep
                    // their full width (`fixedSize`), so attribution never
                    // loses the licence however long the Commons author is.
                    HStack(spacing: 4 * scale) {
                        if let author = credit.author {
                            Text(author)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text("·").fixedSize()
                        }
                        Text(credit.source)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .font(.system(size: 10.5 * scale))
                    .foregroundStyle(RP.muted)
                    // Grow the one-line credit toward a 44 pt target.
                    .contentShape(Rectangle().inset(by: -12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(credit.text)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    @ViewBuilder
    private func closeupImage(scale: CGFloat) -> some View {
        switch model.closeup {
        case .loading:
            photoPlaceholder(loading: true, scale: scale)
        case .none:
            photoPlaceholder(loading: false, scale: scale)
        case .planespotters(let p):
            remoteImage(p.thumbnailLargeURL)
        case .commons(let t):
            remoteImage(t.imageURL)
        }
    }

    /// No photo (yet): a plain dark panel that says so, not the front's
    /// illustrated sky, which read as a broken image on the back.
    private func photoPlaceholder(loading: Bool, scale: CGFloat) -> some View {
        ZStack {
            Brand.Color.bgElevated
            if loading {
                ProgressView().tint(RP.muted)
            } else {
                VStack(spacing: 8 * scale) {
                    Image(systemName: "photo")
                        .font(.system(size: 20 * scale, weight: .regular))
                    Text("NO PHOTO AVAILABLE")
                        .font(.system(size: 10 * scale, weight: .semibold, design: .monospaced))
                        .tracking(1.5)
                }
                .foregroundStyle(RP.faint)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(loading ? "Loading photo" : "No photo available")
    }

    /// Remote photo, loaded from its source URL every time (Planespotters
    /// terms: never stored). `snapshotImage` stands in for tests.
    @ViewBuilder
    private func remoteImage(_ url: URL) -> some View {
        if let snapshotImage {
            Color.clear
                .overlay(Image(uiImage: snapshotImage).resizable().aspectRatio(contentMode: .fill))
                .clipped()
        } else {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    Color.clear
                        .overlay(image.resizable().aspectRatio(contentMode: .fill))
                        .clipped()
                case .failure:
                    photoPlaceholder(loading: false, scale: 1)
                default:
                    photoPlaceholder(loading: true, scale: 1)
                }
            }
        }
    }

    @ViewBuilder
    private func registrationTag(scale: CGFloat) -> some View {
        if CardBackFormat.showsRegistrationTag(for: model.closeup),
           let reg = model.registration?.trimmingCharacters(in: .whitespaces), !reg.isEmpty {
            Text(reg.uppercased())
                .font(.system(size: 10 * scale, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(RP.ink)
                .padding(.horizontal, 7 * scale)
                .padding(.vertical, 4 * scale)
                .background(RP.bg.opacity(0.72),
                            in: RoundedRectangle(cornerRadius: Brand.Radius.chip))
                .padding(8 * scale)
                .accessibilityLabel("Registration \(reg)")
        }
    }

    // MARK: Sections

    /// Label left, value right — the front ledger's shape, quieter.
    private func ledgerLine(_ label: String, _ value: String, scale: CGFloat,
                            lines: Int = 1) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10 * scale) {
            Text(label)
                .font(.system(size: 10 * scale, weight: .regular, design: .monospaced))
                .foregroundStyle(RP.muted)
                .fixedSize()
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 11.5 * scale, weight: .semibold, design: .monospaced))
                .foregroundStyle(RP.ink)
                .multilineTextAlignment(.trailing)
                .lineLimit(lines)
                .minimumScaleFactor(0.75)
        }
        .accessibilityElement(children: .combine)
    }

    /// A catch-log row: operator left (truncates if it must), count right.
    private func logLine(_ name: String, _ count: String, scale: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10 * scale) {
            Text(name)
                .font(.system(size: 10 * scale, weight: .regular, design: .monospaced))
                .foregroundStyle(RP.muted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Text(count)
                .font(.system(size: 11.5 * scale, weight: .semibold, design: .monospaced))
                .foregroundStyle(RP.ink)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    /// Two-column grid of the known specs, in the front's statCell style.
    /// All the specs on one row (Noah, 2026-10-26). Each cell keeps its
    /// natural width and the leftover space is shared out between them —
    /// equal columns squeezed "FIRST FLEW" smaller than its neighbours.
    /// Four cells (with BUILT) fit the detail card's width with ~8 pt
    /// between the middle two; three leave plenty of room.
    private func specGrid(_ cells: [CardBackCell], scale: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.element.label) { i, cell in
                if i > 0 { Spacer(minLength: 8 * scale) }
                specCell(cell, scale: scale).fixedSize()
            }
            if cells.count == 1 { Spacer(minLength: 0) }
        }
    }

    private func specCell(_ cell: CardBackCell, scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2 * scale) {
            Text(cell.label)
                .font(.system(size: 9.5 * scale, weight: .semibold, design: .monospaced))
                .tracking(1.5).foregroundStyle(RP.faint)
            HStack(alignment: .firstTextBaseline, spacing: 4 * scale) {
                Text(cell.value)
                    .font(.system(size: 16 * scale, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RP.ink)
                if let unit = cell.unit {
                    Text(unit)
                        .font(.system(size: 11 * scale, weight: .medium, design: .monospaced))
                        .foregroundStyle(RP.muted)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func wikipediaBlock(scale: CGFloat) -> some View {
        if let summary = model.summary {
            // The card only has room for a teaser (the back is sized to the
            // front), so the whole block opens a sheet with the article's
            // full intro paragraph.
            //
            // `onCardTap`, not a Button: a swipe that starts on the teaser
            // turns the card without opening the sheet (a plain tap gesture
            // or Button still fires if the finger lifts inside it). The
            // accessibility traits and action below restore what a Button
            // gives VoiceOver.
            VStack(alignment: .leading, spacing: 6 * scale) {
                // Unedited Wikipedia text. Lowest layout priority: when
                // the back is shorter than its content, this is what
                // truncates first.
                Text(summary.extract)
                    .font(.system(size: 12.5 * scale))
                    .foregroundStyle(RP.ink.opacity(0.88))
                    .lineSpacing(1.5 * scale)
                    .lineLimit(5)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(-1)
                HStack(spacing: 6 * scale) {
                    // The licence credit never truncates.
                    Text("From Wikipedia · CC BY-SA 4.0")
                        .font(.system(size: 9.5 * scale, weight: .regular, design: .monospaced))
                        .foregroundStyle(RP.faint)
                        .fixedSize()
                    Spacer(minLength: 0)
                    Text("MORE ›")
                        .font(.system(size: 9.5 * scale, weight: .semibold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(RP.muted)
                        .fixedSize()
                }
            }
            .contentShape(Rectangle())
            .onCardTap { showingSummary = true }
            .layoutPriority(-1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary.extract)
            .accessibilityHint("Opens the Wikipedia summary")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { showingSummary = true }
            .sheet(isPresented: $showingSummary) {
                WikipediaSummarySheet(title: model.modelName, summary: summary,
                                      onOpenURL: onOpenURL)
            }
        } else {
            // Loading: a quiet placeholder line, nothing that reads as text.
            VStack(alignment: .leading, spacing: 6 * scale) {
                RoundedRectangle(cornerRadius: 2).fill(RP.rule)
                    .frame(height: 7 * scale)
                RoundedRectangle(cornerRadius: 2).fill(RP.rule)
                    .frame(width: 140 * scale, height: 7 * scale)
            }
            .padding(.vertical, 4 * scale)
            .accessibilityElement()
            .accessibilityLabel("Loading Wikipedia summary")
        }
    }
}

/// The Wikipedia intro for this type, opened from the card back's teaser:
/// the article's whole lead paragraph, unedited, with its credit and a link
/// to the full article.
struct WikipediaSummarySheet: View {
    let title: String
    let summary: WikipediaSummary
    let onOpenURL: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(summary.intro.isEmpty ? summary.extract : summary.intro)
                        .font(.body)
                        .foregroundStyle(Brand.Color.textPrimary)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Text("From Wikipedia · CC BY-SA 4.0")
                        .font(Brand.Font.mono(size: 11, relativeTo: .caption))
                        .foregroundStyle(Brand.Color.textSecondary)
                    Button {
                        onOpenURL(summary.pageURL)
                    } label: {
                        Label("Read the full article on Wikipedia", systemImage: "arrow.up.right")
                            .font(.body.weight(.semibold))
                    }
                    .padding(.top, 4)
                }
                .padding(20)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // iOS 26 close button: the same X every sheet uses.
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}
