//
//  CatchShareCard.swift
//  Tailspot
//
//  The share artboard — rendered to an Image via ImageRenderer and handed
//  to ShareLink, so a friend receives a clean card instead of a manual
//  screenshot. Surfaced from CatchDetailView (the share pill) and the
//  post-catch reveal.
//
//  Since Direction B (2026-07-05) the artboard IS the settled reveal card
//  — `SettledCatchCard`, the same view the Hangar detail frames — wrapped
//  in minimal brand chrome (wordmark above, "CAUGHT ON TAILSPOT" below).
//  One card design across catch, Hangar, and share.
//
//  ImageRenderer is synchronous and can't wait on AsyncImage, so only the
//  LOCAL capture photo renders into a share (RevealPhoto loads file URLs
//  synchronously); remote Planespotters heroes fall back to the card's sky
//  placeholder — same behavior as the pre-B share card.
//
//  Share FORMATS (2026-10-05): the natural artboard is ~1:1.85, which
//  Instagram's feed crops and other targets letterbox. `ShareFormat` adds
//  three fixed canvases sized for social posting — Square 1:1 and
//  Portrait 4:5 (the Instagram feed's two shapes) use a compact layout
//  built from the same reveal atoms; Story 9:16 frames the full artboard.
//  The user picks one in `CatchShareSheet`.
//

import SwiftUI

struct CatchShareCard: View {
    let plane: CardPlane

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "airplane")
                    .foregroundStyle(Brand.Color.cyan)
                    .font(.system(size: 15, weight: .semibold))
                Text("TAILSPOT")
                    .font(Brand.Font.mono(size: 14, weight: .bold))
                    .tracking(3)
                    .foregroundStyle(Brand.Color.textPrimary)
                Spacer()
                Circle().fill(plane.rarity.tint).frame(width: 6, height: 6)
                Text(plane.rarity.label.uppercased())
                    .font(Brand.Font.mono(size: 11, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(plane.rarity.tint)
            }
            .padding(.horizontal, 4)

            SettledCatchCard(
                plane: plane,
                isFirstOfType: plane.isFirstOfType,
                width: 320
            )

            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.Color.cyan)
                Text("CAUGHT ON TAILSPOT")
                    .font(Brand.Font.mono(size: 10, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(Brand.Color.textTertiary)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(Brand.Color.bgPrimary)
    }
}

// MARK: - Render helper

enum CatchShare {
    /// App Store listing link that rides along with every shared card —
    /// the catch share is the app's only organic install loop, and a card
    /// image alone gives the recipient no path to install. Campaign form
    /// and attribution rationale: AppStoreListing.swift.
    static let storeURL = AppStoreListing.url(campaign: "Tailspot Catch Share")

    /// Stamp the share card into an Image for ShareLink. MainActor because
    /// ImageRenderer renders a live SwiftUI view. Height follows the card's
    /// natural size (the split-flap name can wrap to a second line).
    @MainActor
    static func image(for plane: CardPlane) -> Image {
        if let ui = uiImage(for: plane) {
            return Image(uiImage: ui)
        }
        return Image(systemName: "airplane")
    }

    /// The raw render behind `image(for:)` — split out so tests can assert
    /// on pixels. `\.replayMaskingDisabled` drops the session-replay photo
    /// mask from this OFFSCREEN tree: ImageRenderer draws the mask's hidden
    /// UIKit tag views as a yellow no-entry placeholder over the hero (the
    /// "photo mask on shared cards" bug), and these pixels never appear on
    /// screen, so replay can't capture them anyway — no privacy loss. See
    /// CatchPhotoReplayMask.swift.
    @MainActor
    static func uiImage(for plane: CardPlane) -> UIImage? {
        let renderer = ImageRenderer(
            content: CatchShareCard(plane: plane)
                .environment(\.replayMaskingDisabled, true)
        )
        renderer.scale = 3
        return renderer.uiImage
    }

    /// Render the share card on a fixed social canvas. Pixel size is exactly
    /// `format.pixelSize` (canvas points × 3), so the image drops into
    /// Instagram's feed or a story without a crop. Story embeds the natural
    /// artboard (rendered first, then scaled to fit), so a long wrapped name
    /// can never overflow the 9:16 frame.
    @MainActor
    static func uiImage(for plane: CardPlane, format: ShareFormat) -> UIImage? {
        let content: AnyView
        switch format {
        case .square, .portrait:
            content = AnyView(CatchShareCompactCard(plane: plane, format: format))
        case .story:
            guard let artboard = uiImage(for: plane) else { return nil }
            content = AnyView(CatchShareStoryCanvas(plane: plane, artboard: artboard))
        }
        let renderer = ImageRenderer(
            content: content
                .frame(width: format.canvas.width, height: format.canvas.height)
                .environment(\.replayMaskingDisabled, true)
        )
        renderer.scale = 3
        return renderer.uiImage
    }
}

// MARK: - Social formats

/// The fixed-size canvases the share sheet offers. Canvases are in points at
/// a 360 pt width; the render scale of 3 makes every format 1080 px wide —
/// Instagram's native width, so nothing gets resampled on upload.
nonisolated enum ShareFormat: String, CaseIterable, Identifiable, Sendable {
    case square, portrait, story

    var id: String { rawValue }

    /// Segmented-picker title.
    var title: String {
        switch self {
        case .square: "Square"
        case .portrait: "Portrait"
        case .story: "Story"
        }
    }

    /// Ratio + where it fits, shown under the picker.
    var hint: String {
        switch self {
        case .square: "1:1 · feed posts"
        case .portrait: "4:5 · tallest feed post"
        case .story: "9:16 · stories and reels"
        }
    }

    var canvas: CGSize {
        switch self {
        case .square: CGSize(width: 360, height: 360)
        case .portrait: CGSize(width: 360, height: 450)
        case .story: CGSize(width: 360, height: 640)
        }
    }

    /// Rendered size at the share scale (3×): 1080×1080 / 1080×1350 / 1080×1920.
    var pixelSize: CGSize { CGSize(width: canvas.width * 3, height: canvas.height * 3) }
}

/// Square and 4:5 layout. The settled card is too tall for these shapes,
/// so this keeps its vocabulary (rarity frame, photo hero, split-flap name,
/// identity row, stat cells) and drops the ledger to a single points total.
/// The hero is the flexible element: it takes whatever height the text
/// leaves, so 4:5 simply gets a taller photo than 1:1.
struct CatchShareCompactCard: View {
    let plane: CardPlane
    let format: ShareFormat

    private var points: Int {
        let base = plane.rarity.basePoints
        let bonus = plane.isFirstOfType ? Int((Double(base) * 0.5).rounded()) : 0
        return base + bonus
    }

    var body: some View {
        let accent = plane.rarity.tint
        let canvas = format.canvas
        let outerPad: CGFloat = 18
        let cardWidth = canvas.width - 2 * outerPad
        // Stats and type are tuned for the 300 pt prototype, like the
        // settled card; 0.9 keeps the three-up stat row legible at 324 pt.
        let scale: CGFloat = 0.9
        let inner: CGFloat = 12

        VStack(spacing: 10) {
            header(accent: accent)

            VStack(alignment: .leading, spacing: 9) {
                hero(accent: accent)
                    .frame(maxHeight: .infinity)

                flapName(width: cardWidth - 2 * inner)

                HStack(alignment: .center, spacing: 8) {
                    identityRow(callsign: plane.callsign, carrier: plane.carrier,
                                rarity: plane.rarity, scale: scale)
                    Spacer(minLength: 4)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("+\(points)")
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundColor(accent)
                        Text("PTS")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(RP.muted)
                    }
                    .fixedSize()
                }

                Rectangle().fill(RP.rule).frame(height: 1)

                statsRow(scale: scale, accent: accent)
            }
            .padding(inner)
            .frame(width: cardWidth)
            .frame(maxHeight: .infinity)
            .modifier(CatchRarityFrame(rarity: plane.rarity, scale: 1))

            footer
        }
        .padding(.horizontal, outerPad)
        .padding(.vertical, 14)
        .frame(width: canvas.width, height: canvas.height)
        .background(Brand.Color.bgPrimary)
    }

    private func header(accent: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "airplane")
                .foregroundStyle(Brand.Color.cyan)
                .font(.system(size: 13, weight: .semibold))
            Text("TAILSPOT")
                .font(Brand.Font.mono(size: 12, weight: .bold))
                .tracking(3)
                .foregroundStyle(Brand.Color.textPrimary)
            Spacer()
            Circle().fill(accent).frame(width: 6, height: 6)
            Text(plane.rarity.label.uppercased())
                .font(Brand.Font.mono(size: 10, weight: .semibold))
                .tracking(2)
                .foregroundStyle(accent)
        }
        .padding(.horizontal, 4)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 10))
                .foregroundStyle(Brand.Color.cyan)
            Text("CAUGHT ON TAILSPOT")
                .font(Brand.Font.mono(size: 9, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(Brand.Color.textTertiary)
        }
    }

    /// Photo hero with the FIRST OF TYPE badge riding its corner (the
    /// ledger line it replaces).
    private func hero(accent: Color) -> some View {
        RevealPhoto(url: plane.photoURL, focus: plane.photoFocus)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.card))
            .overlay(
                CatchRarityBorder(rarity: plane.rarity,
                                  cornerRadius: Brand.Radius.card, emphasis: 0.55)
            )
            .overlay(alignment: .bottomLeading) {
                if plane.isFirstOfType {
                    Text("FIRST OF TYPE")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundColor(RP.bg)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(RP.gold, in: .rect(cornerRadius: Brand.Radius.chip))
                        .padding(8)
                }
            }
    }

    /// Settled split-flap name, sized like the settled card but capped at
    /// two lines — a third line would eat the hero on the square canvas, so
    /// anything past two lines is folded into the second and the cells
    /// shrink to fit.
    private func flapName(width: CGFloat) -> some View {
        let model = (plane.model ?? "UNKNOWN AIRCRAFT").uppercased()
        let gap: CGFloat = 2
        let maxCW: CGFloat = 15
        let minCW: CGFloat = 9
        let perLine = max(6, Int((width + gap) / (11 + gap)))
        var lines = model.count <= perLine ? [model] : wrapName(model, perLine: perLine)
        if lines.count > 2 {
            lines = [lines[0], lines[1...].joined(separator: " ")]
        }
        let longest = CGFloat(lines.map(\.count).max() ?? model.count)
        let cwFit = (width - gap * max(0, longest - 1)) / max(1, longest)
        let cw = min(maxCW, max(minCW, cwFit))
        let fs = min(13, cw * 0.86)
        let total = lines.reduce(0) { $0 + $1.count }
        var offset = 0
        let flapLines: [FlapLine] = lines.map { line in
            defer { offset += line.count }
            return FlapLine(id: offset, text: line)
        }
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(flapLines) { fl in
                FlapRow(text: fl.text, t: 1, startT: 0, spanT: 0,
                        fs: fs, cw: cw, gap: gap,
                        indexOffset: fl.id, totalCount: total, color: RP.ink)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(plane.model ?? "Unknown aircraft"))
    }

    /// ALT · SPD · ROUTE (or DIST when there's no route) in one row.
    private func statsRow(scale: CGFloat, accent: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            statCell("ALT", plane.altText, scale: scale, accent: accent)
                .frame(maxWidth: .infinity, alignment: .leading)
            statCell("SPD", plane.speedText, scale: scale, accent: accent)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let route = routeText {
                VStack(alignment: .leading, spacing: 3 * scale) {
                    Text("ROUTE")
                        .font(.system(size: 9.5 * scale, weight: .semibold, design: .monospaced))
                        .tracking(1.5).foregroundColor(RP.faint)
                    Text(route)
                        .font(.system(size: 21 * scale, weight: .semibold, design: .monospaced))
                        .foregroundColor(RP.ink)
                        .lineLimit(1).minimumScaleFactor(0.5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                statCell("DIST", plane.distText, scale: scale, accent: accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// "SFO→HNL", "SFO→", or "→HNL"; nil when the catch has no route.
    private var routeText: String? {
        switch (plane.originIcao, plane.destIcao) {
        case let (o?, d?): "\(o)→\(d)"
        case let (o?, nil): "\(o)→"
        case let (nil, d?): "→\(d)"
        case (nil, nil): nil
        }
    }
}

/// 9:16 canvas: the full share artboard, scaled to fit and centered, over a
/// soft glow in the catch's rarity tint so the empty space above and below
/// reads as backdrop rather than letterbox.
struct CatchShareStoryCanvas: View {
    let plane: CardPlane
    let artboard: UIImage

    var body: some View {
        ZStack {
            Brand.Color.bgPrimary
            RadialGradient(colors: [plane.rarity.tint.opacity(0.14), .clear],
                           center: .center, startRadius: 10, endRadius: 340)
            Image(uiImage: artboard)
                .resizable()
                .scaledToFit()
                .padding(.horizontal, 8)
                .padding(.vertical, 40)
        }
    }
}
