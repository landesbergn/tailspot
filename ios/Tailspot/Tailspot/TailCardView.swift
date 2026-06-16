//
//  TailCardView.swift
//  Tailspot
//
//  The one clean "caught tail" card, shared across the Hangar. A photo
//  thumbnail plus the data we actually prioritize: the flight callsign
//  (cyan), the airline, and when + where it was caught. No rarity-tinted
//  chrome or narrow/wide type pills — those were the stale elements the
//  old MiniCard carried; the unified language here is a neutral card with
//  a cyan accent. Used by the Recent feed (HangarRecentView) and the
//  model-detail screen (SetsScreen). Taps into the full CatchDetailView.
//

import SwiftUI

struct TailCard: View {
    let row: HangarRow

    private var photoURL: URL? {
        row.mostRecent.photoFilename.flatMap { CatchPhotoStore.url(forFilename: $0) }
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

            VStack(alignment: .leading, spacing: 4) {
                Text(tailNumber)
                    .font(Brand.Font.mono(size: 15, weight: .bold))
                    .foregroundStyle(Brand.Color.cyan)
                    .lineLimit(1)
                Text(airline)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .lineLimit(1)
                Label {
                    Text(c.caughtAt.formatted(.dateTime.month().day().year()))
                } icon: {
                    Image(systemName: "calendar")
                }
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.textSecondary)
                Label {
                    Text(place ?? "Location unknown")
                } icon: {
                    Image(systemName: "mappin.and.ellipse")
                }
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.textTertiary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Brand.Color.textTertiary.opacity(0.6))
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
