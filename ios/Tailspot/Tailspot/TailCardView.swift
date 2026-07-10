//
//  TailCardView.swift
//  Tailspot
//
//  The one clean "caught tail" card, shared across the Hangar. A photo
//  thumbnail plus a varied three-line stack so the feed doesn't read as a
//  repeating template. The Recent feed opts in (`showPoints`) to the rich
//  variant, which speaks the REVEAL's design language (CatchRevealView,
//  2026-07-04): cyan callsign · airline, then the make/model promoted to
//  the hero line (the card's echo of the reveal's split-flap name), then
//  the reveal's ROUTE vocabulary — mono ICAO codes with a rarity-tinted
//  arrow (HND → SFO) · short date — falling back to the quiet
//  date · location when the catch carries no route. A rarity-tinted point
//  value sits as the trailing readout (in place of the chevron). The Sets
//  view leaves `showPoints` off and renders the compact two-line card (no
//  model — every row in a set shares it — and no points). Two hues carry
//  meaning (cyan = callsign; the rarity tint = points + route arrow); all
//  other text is greys. No type pills. Used by the Recent feed
//  (HangarRecentView) and the model-detail screen (SetsScreen). Taps into
//  the full CatchDetailView.
//

import SwiftUI

struct TailCard: View {
    let row: HangarRow
    /// Render the rich Recent-feed variant: adds the make/model line and the
    /// rarity-tinted point value (`basePoints`) as a trailing readout. Off by
    /// default — the Sets view leaves it off and shows the compact card, since
    /// every catch in a set shares a model and a rarity (both would be redundant).
    var showPoints: Bool = false

    private var photoURL: URL? {
        row.mostRecent.photoFilename.flatMap { CatchPhotoStore.url(forFilename: $0) }
    }

    /// Dimmed middle-dot used between fields on a line.
    private var separator: some View {
        Text("·").font(.system(size: 13, weight: .regular)).foregroundStyle(Brand.Color.textTertiary)
    }

    /// The reveal's route row, list-sized: mono ICAO codes in secondary ink
    /// with the arrow in the rarity tint (CatchRevealView's `routeCell`
    /// vocabulary). One-sided routes render one code (or `→ CODE` for a
    /// destination-only filing) — never a dangling arrow.
    @ViewBuilder
    private func routeLine(origin: String?, dest: String?, tint: Color) -> some View {
        let codeFont = Brand.Font.mono(size: 13, weight: .semibold)
        HStack(spacing: 5) {
            if let origin {
                Text(origin).font(codeFont).foregroundStyle(Brand.Color.textSecondary)
                if let dest {
                    Text("→").font(Brand.Font.mono(size: 12, weight: .semibold)).foregroundStyle(tint)
                    Text(dest).font(codeFont).foregroundStyle(Brand.Color.textSecondary)
                }
            } else if let dest {
                Text("→").font(Brand.Font.mono(size: 12, weight: .semibold)).foregroundStyle(tint)
                Text(dest).font(codeFont).foregroundStyle(Brand.Color.textSecondary)
            }
        }
        .fixedSize()
    }

    var body: some View {
        let c = row.mostRecent
        let reg = c.registration?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let callsign = c.callsign?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        // Lead with the flight callsign (e.g. SWA4244) — the identifier Noah
        // wants — not the opaque N-registration. Fall back to the registration,
        // then the hex id, only when there's no callsign.
        let tailNumber = callsign ?? reg ?? row.icao24.uppercased()
        // Resolve the airline from the callsign when no operator was recorded;
        // GA-format callsigns fall back to "Private".
        let airline = Airlines.operatorLabel(operatorName: c.operatorName, callsign: c.callsign)
        let place = c.placeName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        // Canonical "Boeing 737-800" from the typecode (falls back to the
        // cleaned make/model strings); nil for older typeless rows, which
        // simply hide the make/model line.
        let model = AircraftNaming.canonical(
            typecode: c.typecode, manufacturer: c.manufacturer, model: c.model
        ).displayName

        return HStack(spacing: 12) {
            // Crop toward the plane (Catch.photoFocus), same as the big card —
            // not a plain center-crop that hides an edge-of-frame plane. Decoded
            // at thumbnail size off the main actor (FocusThumbnail).
            FocusThumbnail(url: photoURL, focus: c.photoFocus, side: 76)
                .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.row))

            VStack(alignment: .leading, spacing: 5) {
                // Line 1 — cyan callsign · airline. The callsign is the lead
                // identifier (never truncated); a long airline tail-truncates.
                HStack(spacing: 6) {
                    Text(tailNumber)
                        .font(Brand.Font.mono(size: 15, weight: .bold))
                        .foregroundStyle(Brand.Color.cyan)
                        .fixedSize()
                        .layoutPriority(1)
                    separator
                    Text(airline)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Brand.Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                // Line 2 — make/model as the card's HERO line (the reveal
                // makes the name the payoff; the feed card echoes it in
                // primary ink). Recent feed only, and only when a name
                // resolves.
                if showPoints, let model {
                    Text(model)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Brand.Color.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                // Line 3 — the reveal's ROUTE vocabulary when the catch
                // carries one (mono airport codes — IATA preferred, ICAO
                // fallback — rarity-tinted arrow, short date), else the
                // quiet date · location. Reveal rule: a one-sided route
                // never dangles an arrow at "—".
                let origin = c.displayOrigin
                let dest = c.displayDest
                if showPoints, origin != nil || dest != nil {
                    HStack(spacing: 6) {
                        routeLine(origin: origin, dest: dest, tint: row.rarity.tint)
                        separator
                        Text(c.caughtAt.formatted(.dateTime.month().day())).fixedSize()
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Brand.Color.textTertiary)
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(c.caughtAt.formatted(.dateTime.month().day().year())).fixedSize()
                        separator
                        Text(place ?? "Location unknown").lineLimit(1).truncationMode(.tail)
                    }
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Brand.Color.textTertiary)
                }
            }

            Spacer(minLength: 8)

            if showPoints {
                // Trailing rarity value — points as a tinted readout with a tiny
                // PTS caption, vertically centered, in place of the chevron (the
                // row is still a tappable NavigationLink). basePoints via
                // row.rarity (resolved live); String() keeps them ungrouped.
                VStack(alignment: .trailing, spacing: -1) {
                    Text(String(row.rarity.basePoints))
                        .font(Brand.Font.mono(size: 20, weight: .bold))
                        .foregroundStyle(row.rarity.tint)
                        .monospacedDigit()
                    Text("PTS")
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(1.5)
                        .foregroundStyle(Brand.Color.textTertiary)
                }
                .fixedSize()
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.Color.textTertiary.opacity(0.6))
            }
        }
        .padding(12)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: Brand.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Brand.Radius.card)
                .strokeBorder(Brand.Color.textPrimary.opacity(0.06), lineWidth: 1)
        )
    }
}

/// Calm placeholder for a photo area when no capture photo exists.
struct SlotPlaceholder: View {
    var body: some View {
        ZStack {
            Brand.Color.bgSurface
            Image(systemName: "airplane")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Brand.Color.textTertiary.opacity(0.5))
                .rotationEffect(.degrees(-45))
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
