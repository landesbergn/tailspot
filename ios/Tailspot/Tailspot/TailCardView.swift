//
//  TailCardView.swift
//  Tailspot
//
//  The one clean "caught tail" card, shared across the Hangar. A photo
//  thumbnail plus a varied three-line stack so the feed doesn't read as a
//  repeating template: cyan callsign · airline, then the make/model on its
//  own line, then a quiet date · location. The Recent feed opts in
//  (`showPoints`) to the rich variant — it adds the make/model line and a
//  rarity-tinted point value as a trailing readout (in place of the
//  chevron). The Sets view leaves `showPoints` off and renders the compact
//  two-line card (no model — every row in a set shares it — and no points).
//  Two colors carry meaning (cyan = callsign, rarity tint = points); all
//  other text is one grey, the `·` separators a dimmer grey. No type pills.
//  Used by the Recent feed (HangarRecentView) and the model-detail screen
//  (SetsScreen). Taps into the full CatchDetailView.
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
            ZStack {
                if let photoURL {
                    AsyncImage(url: photoURL) { phase in
                        if case .success(let img) = phase {
                            img.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            SlotPlaceholder()
                        }
                    }
                } else {
                    SlotPlaceholder()
                }
            }
            .frame(width: 76, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 11))

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

                // Line 2 — make/model on its own line, the rich card's distinct
                // "solo" row. Recent feed only, and only when a name resolves.
                if showPoints, let model {
                    Text(model)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Brand.Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                // Line 3 — date · location, icon-free, the quietest tier.
                HStack(spacing: 6) {
                    Text(c.caughtAt.formatted(.dateTime.month().day().year())).fixedSize()
                    separator
                    Text(place ?? "Location unknown").lineLimit(1).truncationMode(.tail)
                }
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Brand.Color.textTertiary)
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
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
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
