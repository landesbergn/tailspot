//
//  CatchDetailView.swift
//  Tailspot
//
//  Read-only detail for a catch. Ported from the design canvas's
//  `DetailA` (detail-hangar-profile.jsx) — photo-led collector card
//  with floating chrome pills, badges over the photo edge, an EARNED
//  rarity panel, a stat grid, and a CAUGHT AT panel. Replaces the
//  earlier iOS-grouped-list layout that didn't match the canvas.
//
//  The Catch is a frozen snapshot of what we knew at catch time — we
//  don't re-fetch live metadata or position. The Planespotters photo
//  is the one exception (photos aren't part of the snapshot, and the
//  TOS prohibits caching image bytes to disk anyway).
//
//  Stats grid is sized to what's actually in the SwiftData `Catch`
//  model. Altitude / ground speed / aircraft heading / bearing are
//  NOT yet captured at catch time — when those land on `Catch`, swap
//  the catch-history-derived cells for the canvas's full 6-stat set.
//

import SwiftUI

struct CatchDetailView: View {
    let row: HangarRow

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var c: Catch { row.mostRecent }
    private var rarity: Rarity { row.rarity }
    private var type: AircraftType { row.aircraftType }

    /// Tri-state for the photo: loading | loaded | not-available.
    /// Keeps the hero from shifting once the network call settles.
    private enum PhotoState: Equatable {
        case loading
        case loaded(PlanePhoto)
        case notAvailable
    }

    @State private var photoState: PhotoState = .loading
    @State private var didLoadPhoto = false

    private var hasCatchPhoto: Bool { c.photoFilename != nil }

    private static let heroHeight: CGFloat = 320

    var body: some View {
        ZStack(alignment: .top) {
            Brand.Color.bgPrimary.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    photoHero
                    contentColumn
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 40)
                }
            }
            .ignoresSafeArea(.container, edges: .top)

            chromeBar
                .padding(.top, 8)
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .task {
            guard !didLoadPhoto, !hasCatchPhoto else {
                if hasCatchPhoto { photoState = .notAvailable } // skip net call
                didLoadPhoto = true
                return
            }
            didLoadPhoto = true
            let fetched = await PlanespottersClient.shared.photo(for: c.icao24)
            withAnimation(.easeInOut(duration: 0.25)) {
                photoState = fetched.map(PhotoState.loaded) ?? .notAvailable
            }
        }
    }

    // MARK: - Hero

    /// Photo hero with bottom gradient fade and the rarity/type/time
    /// badges anchored over the bottom of the photo (canvas top:230
    /// in a 320pt photo = ~90pt above the bottom edge).
    private var photoHero: some View {
        ZStack(alignment: .bottomLeading) {
            heroPhoto
                .frame(height: Self.heroHeight)
                .frame(maxWidth: .infinity)
                .clipped()

            // Fade transparent → bg-primary so the photo dissolves
            // into the page rather than ending in a hard edge.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.4),
                    .init(color: Brand.Color.bgPrimary.opacity(0.85), location: 0.8),
                    .init(color: Brand.Color.bgPrimary, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Self.heroHeight)
            .allowsHitTesting(false)

            // Badge row over the bottom-leading region.
            HStack(spacing: 6) {
                RarityBadge(rarity: rarity, size: .md)
                TypeBadge(type: type, size: .md)
                timeAgoPill
            }
            .padding(.leading, 18)
            .padding(.bottom, 24)
        }
        .frame(height: Self.heroHeight)
    }

    /// What's actually drawn behind the gradient: catch photo → live
    /// Planespotters → striped rarity placeholder.
    @ViewBuilder
    private var heroPhoto: some View {
        if hasCatchPhoto,
           let fn = c.photoFilename,
           let url = CatchPhotoStore.url(forFilename: fn) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fill)
                case .empty, .failure:
                    heroPlaceholder
                @unknown default:
                    heroPlaceholder
                }
            }
        } else {
            switch photoState {
            case .loading:
                heroPlaceholder
                    .overlay(ProgressView().tint(Brand.Color.textSecondary))
            case .loaded(let photo):
                AsyncImage(url: photo.thumbnailLargeURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fill)
                    case .empty:
                        heroPlaceholder
                            .overlay(ProgressView().tint(Brand.Color.textSecondary))
                    case .failure:
                        heroPlaceholder
                    @unknown default:
                        heroPlaceholder
                    }
                }
            case .notAvailable:
                heroPlaceholder
            }
        }
    }

    /// Diagonal-striped fallback in the rarity tint, behind the
    /// gradient fade so it doesn't dominate.
    private var heroPlaceholder: some View {
        ZStack {
            Brand.Color.bgSurface
            HeroStripesShape()
                .stroke(rarity.tint.opacity(0.18), lineWidth: 10)
                .clipped()
        }
    }

    /// "● 2m ago" — relative time pill in the alertNormal (green)
    /// theme to match the canvas's `pill normal`.
    private var timeAgoPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Brand.Color.alertNormal)
                .frame(width: 5, height: 5)
            Text(c.caughtAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(Brand.Color.alertNormal)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Brand.Color.alertNormal.opacity(0.16), in: .capsule)
    }

    // MARK: - Floating chrome

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

    /// The canvas's `ChromePill` — translucent dark disc with a thin
    /// hairline border, used as a back/share affordance over the hero.
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

    /// Text rendered into the share sheet. Free text, no attachment —
    /// keeps the share predictable across iOS share targets.
    private var shareText: String {
        let cs = c.callsign?.trimmedNonEmpty ?? c.icao24
        let model = HangarGrouping.key(for: c, mode: .aircraftType)
        let modelPart = model == HangarGrouping.unknownTitle ? "" : " · \(model)"
        return "Caught \(cs)\(modelPart) on Tailspot"
    }

    // MARK: - Content column

    private var contentColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            headline
            earnedPanel
            statsGrid
            caughtAtPanel
            attribution
        }
    }

    /// Display title: small cyan callsign · ICAO; large display model
    /// title; muted operator subtitle.
    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(callsignLine)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .tracking(0.4)
                .foregroundStyle(Brand.Color.cyan)
            Text(modelText)
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(Brand.Color.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(operatorText)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Brand.Color.textSecondary)
                .lineLimit(1)
        }
    }

    private var callsignLine: String {
        let cs = c.callsign?.trimmedNonEmpty ?? c.icao24.uppercased()
        return "\(cs) · \(c.icao24.uppercased())"
    }
    private var modelText: String {
        let key = HangarGrouping.key(for: c, mode: .aircraftType)
        return key == HangarGrouping.unknownTitle ? "Unknown aircraft" : key
    }
    private var operatorText: String {
        c.operatorName?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? "—"
    }

    // MARK: - EARNED panel

    /// Rarity-tinted box: +N pts (left), catch index (right). Bordered
    /// with the rarity color, faint rarity-tinted background. Matches
    /// canvas `DetailA` (line 47-62).
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
                Text(typeLabel)
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

    private var typeLabel: String {
        "Type · \(type.label.capitalized)"
    }

    // MARK: - Stats grid

    /// 2-col grid of stat cells. Six cells sized to what the Catch
    /// model actually carries — distance + icao24 from the snapshot,
    /// plus four derived from the catch history (count, first-caught,
    /// best range, total points).
    private var statsGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ],
            spacing: 10
        ) {
            statCell(label: "DISTANCE",
                     value: distanceText,
                     hint: "slant")
            statCell(label: "ICAO24",
                     value: c.icao24.uppercased(),
                     hint: "hex")
            statCell(label: "TIMES CAUGHT",
                     value: "×\(row.count)",
                     hint: row.count == 1 ? "first time" : nil)
            statCell(label: "FIRST CAUGHT",
                     value: firstCaughtDateText,
                     hint: nil)
            statCell(label: "BEST RANGE",
                     value: bestRangeText,
                     hint: "closest")
            statCell(label: "POINTS",
                     value: "+\(rarity.basePoints * row.count)",
                     hint: "total")
        }
    }

    private func statCell(label: String, value: String, hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.textTertiary)
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .monospaced))
                .foregroundStyle(Brand.Color.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let hint {
                Text(hint)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Brand.Color.textTertiary)
            } else {
                // Reserved spacer to keep cell heights consistent.
                Text(" ")
                    .font(.system(size: 10))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 10))
    }

    private var distanceText: String {
        let km = c.slantDistanceMeters / 1000
        guard km.isFinite, km > 0 else { return "—" }
        return String(format: "%.1f km", km)
    }
    private var firstCaughtDateText: String {
        let earliest = row.allCatches.last?.caughtAt ?? c.caughtAt
        return earliest.formatted(.dateTime.month(.abbreviated).day())
    }
    private var bestRangeText: String {
        let best = row.allCatches.map(\.slantDistanceMeters).min() ?? c.slantDistanceMeters
        let km = best / 1000
        guard km.isFinite, km > 0 else { return "—" }
        return String(format: "%.1f km", km)
    }

    // MARK: - CAUGHT AT panel

    private var caughtAtPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CAUGHT AT")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.textTertiary)
            Text(c.caughtAt.formatted(date: .abbreviated, time: .shortened))
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
        let latH = c.observerLat >= 0 ? "N" : "S"
        let lonH = c.observerLon >= 0 ? "E" : "W"
        return String(format: "%.4f° %@, %.4f° %@",
                      abs(c.observerLat), latH,
                      abs(c.observerLon), lonH)
    }

    // MARK: - Attribution

    /// Planespotters attribution chip (text button → opens the photo
    /// page in Safari). Hidden when we're not showing a Planespotters
    /// photo (catch-photo runs or notAvailable).
    @ViewBuilder
    private var attribution: some View {
        if case .loaded(let photo) = photoState, !hasCatchPhoto {
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
        } else {
            EmptyView()
        }
    }
}

/// Diagonal stripe pattern used in the hero placeholder. Same shape
/// math as MiniCardView's StripesShape — duplicated here to avoid a
/// cross-file private dependency.
private struct HeroStripesShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let step: CGFloat = 18
        var x = -rect.height
        while x < rect.width + rect.height {
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x + rect.height, y: rect.height))
            x += step
        }
        return p
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    var nonEmpty: String? { isEmpty ? nil : self }
}
