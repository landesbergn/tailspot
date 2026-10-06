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
//  two fixed canvases, chosen by DESTINATION in `CatchShareSheet` (the
//  Spotify / Strava pattern: people pick where to post, the app picks the
//  shape). Post is 4:5, the tallest shape the Instagram feed shows
//  uncropped, using a compact layout built from the same reveal atoms.
//  Story is 9:16: the artboard as a transparent "sticker" over a blurred
//  catch photo — the same two layers `InstagramStories` hands to
//  Instagram's own story editor when direct sharing is configured.
//

import SwiftUI

struct CatchShareCard: View {
    let plane: CardPlane
    /// false renders on a clear background — the story sticker, which
    /// sits on a blurred photo instead of the flat app background.
    var opaque: Bool = true

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
            .modifier(StickerLegibility(enabled: !opaque))

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
                    // Tertiary grey disappears on a bright sky backdrop.
                    .foregroundStyle(opaque ? Brand.Color.textTertiary : Brand.Color.textSecondary)
            }
            .modifier(StickerLegibility(enabled: !opaque))
        }
        .padding(20)
        .frame(width: 360)
        .background(opaque ? Brand.Color.bgPrimary : Color.clear)
    }
}

/// Soft shadow under the sticker's header and footer, which sit directly
/// on the photo backdrop instead of the dark card.
private struct StickerLegibility: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(enabled ? 0.55 : 0), radius: 4, y: 1)
    }
}

// MARK: - Render helper

enum CatchShare {
    /// App Store listing link that rides along with every shared card —
    /// the catch share is the app's only organic install loop, and a card
    /// image alone gives the recipient no path to install. Campaign form
    /// and attribution rationale: AppStoreListing.swift.
    static let storeURL = AppStoreListing.url(campaign: "Tailspot Catch Share")

    /// The full share card at its natural height (the split-flap name can
    /// wrap to a second line) — the "More" destination's image. MainActor
    /// because ImageRenderer renders a live SwiftUI view.
    /// `\.replayMaskingDisabled` drops the session-replay photo
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

    /// The artboard on a transparent background, for stories. Instagram's
    /// story editor takes it as the movable sticker layer.
    @MainActor
    static func stickerImage(for plane: CardPlane) -> UIImage? {
        let renderer = ImageRenderer(
            content: CatchShareCard(plane: plane, opaque: false)
                .environment(\.replayMaskingDisabled, true)
        )
        renderer.scale = 3
        renderer.isOpaque = false
        return renderer.uiImage
    }

    /// The 9:16 backdrop behind a story sticker: the catch photo, blurred
    /// and darkened, or the rarity glow when there's no local photo.
    @MainActor
    static func storyBackgroundImage(for plane: CardPlane) -> UIImage? {
        render(CatchShareStoryBackground(plane: plane), format: .story)
    }

    /// Render the share card on a fixed social canvas. Pixel size is exactly
    /// `format.pixelSize` (canvas points × 3), so the image drops into the
    /// Instagram feed or a story without a crop. Story composes the sticker
    /// (rendered first, then scaled to fit) over its backdrop, so a long
    /// wrapped name can never overflow the 9:16 frame.
    @MainActor
    static func uiImage(for plane: CardPlane, format: ShareFormat) -> UIImage? {
        switch format {
        case .post:
            return render(CatchShareCompactCard(plane: plane), format: .post)
        case .story:
            guard let sticker = stickerImage(for: plane) else { return nil }
            return storyImage(for: plane, sticker: sticker)
        }
    }

    /// Story canvas from an already-rendered sticker, so the share sheet
    /// can reuse one sticker render for both the direct Instagram path and
    /// this flattened fallback.
    @MainActor
    static func storyImage(for plane: CardPlane, sticker: UIImage) -> UIImage? {
        render(CatchShareStoryCanvas(plane: plane, sticker: sticker), format: .story)
    }

    @MainActor
    private static func render(_ view: some View, format: ShareFormat) -> UIImage? {
        let renderer = ImageRenderer(
            content: view
                .frame(width: format.canvas.width, height: format.canvas.height)
                .environment(\.replayMaskingDisabled, true)
        )
        renderer.scale = 3
        return renderer.uiImage
    }
}

// MARK: - Social formats

/// The fixed-size canvases behind the share destinations. Canvases are in
/// points at a 360 pt width; the render scale of 3 makes every format
/// 1080 px wide, Instagram's native width, so nothing is resampled on upload.
nonisolated enum ShareFormat: String, CaseIterable, Sendable {
    /// 4:5, the Instagram feed's tallest uncropped shape.
    case post
    /// 9:16, stories and reels.
    case story

    var canvas: CGSize {
        switch self {
        case .post: CGSize(width: 360, height: 450)
        case .story: CGSize(width: 360, height: 640)
        }
    }

    /// Rendered size at the share scale (3×): 1080×1350 / 1080×1920.
    var pixelSize: CGSize { CGSize(width: canvas.width * 3, height: canvas.height * 3) }
}

/// 4:5 feed-post layout. The settled card is too tall for this shape, so
/// this keeps its vocabulary (rarity frame, photo hero, split-flap name,
/// identity row, stat cells) and drops the ledger to a single points total.
/// The hero is the flexible element: it takes whatever height the text
/// leaves, so the photo gets every spare point of the canvas.
struct CatchShareCompactCard: View {
    let plane: CardPlane

    private var points: Int {
        let base = plane.rarity.basePoints
        let bonus = plane.isFirstOfType ? Int((Double(base) * 0.5).rounded()) : 0
        return base + bonus
    }

    var body: some View {
        let accent = plane.rarity.tint
        let canvas = ShareFormat.post.canvas
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
    /// two lines — a third line would eat into the hero, so
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

/// 9:16 backdrop: the user's own catch photo, blurred and darkened so the
/// card reads on top of it; the rarity glow when there's no local photo
/// (remote Planespotters heroes can't load inside ImageRenderer).
struct CatchShareStoryBackground: View {
    let plane: CardPlane

    var body: some View {
        ZStack {
            Brand.Color.bgPrimary
            if let url = plane.photoURL, url.isFileURL,
               let photo = RevealPhoto.cachedDecode(url: url) {
                Color.clear
                    .overlay(Image(uiImage: photo).resizable().scaledToFill())
                    .clipped()
                    .blur(radius: 22, opaque: true)
                    .overlay(Color.black.opacity(0.3))
            } else {
                RadialGradient(colors: [plane.rarity.tint.opacity(0.14), .clear],
                               center: .center, startRadius: 10, endRadius: 340)
            }
        }
    }
}

/// 9:16 canvas: the transparent artboard sticker, scaled to fit and
/// centered over the story backdrop.
struct CatchShareStoryCanvas: View {
    let plane: CardPlane
    let sticker: UIImage

    var body: some View {
        ZStack {
            CatchShareStoryBackground(plane: plane)
            Image(uiImage: sticker)
                .resizable()
                .scaledToFit()
                .padding(.horizontal, 12)
                .padding(.vertical, 48)
        }
    }
}
