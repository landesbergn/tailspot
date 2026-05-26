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

struct CatchDetailView: View {
    let row: HangarRow

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

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
        .navigationBarBackButtonHidden(true)
        .task {
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
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
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
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
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
            Text(observerCoordText)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(Brand.Color.textTertiary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 10))
    }

    private var observerCoordText: String {
        let lat = first.observerLat
        let lon = first.observerLon
        let latH = lat >= 0 ? "N" : "S"
        let lonH = lon >= 0 ? "E" : "W"
        return String(format: "%.4f° %@, %.4f° %@", abs(lat), latH, abs(lon), lonH)
    }

    // MARK: - Floating chrome pills

    /// Back chevron (left) + share (right) — `.ultraThinMaterial` discs
    /// with a white 10% hairline. System nav bar is hidden so they own
    /// the top of the view.
    private var chromeBar: some View {
        HStack {
            chromePill(icon: "chevron.left") { dismiss() }
            Spacer()
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

    private func chromePillBody(icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Brand.Color.textPrimary)
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
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
