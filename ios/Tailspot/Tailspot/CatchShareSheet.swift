//
//  CatchShareSheet.swift
//  Tailspot
//
//  Share a catch the way Strava and Spotify do (2026-10-07): a swipeable
//  preview of every shape on top, destinations underneath. What you see is
//  what you send. Save, Copy, Messages and More act on the shape on screen,
//  so a square or a 4:5 post saves as easily as the full card.
//
//  Shapes (`SharePage`): Post 4:5 (Instagram feed), Square 1:1 (X, Threads,
//  WhatsApp, a square grid), Story 9:16, and the full-height card. Story
//  has a background picker (the Spotify move): blurred catch photo, rarity
//  glow, or plain dark.
//
//  Destinations:
//   - Instagram Story: flips the preview to Story, then goes straight into
//     Instagram's story editor with the card as a movable sticker
//     (`InstagramStories`). Without a Meta app ID, or without Instagram,
//     the flattened 9:16 image goes through the system share sheet.
//   - Instagram Post: flips to Post and opens the system share sheet with
//     the 4:5 image (Instagram offers no direct feed API to any app).
//   - Messages: Apple's composer with the image and App Store link attached
//     (hidden where Messages isn't set up).
//   - Copy: the image onto the clipboard, for pasting into any chat.
//   - Save: the image into Photos.
//   - More: the system share sheet with the image and App Store link.
//
//  Instagram's share extension rejects SwiftUI `ShareLink` items with
//  "Content currently unavailable" (it can't load the lazy Transferable
//  image, and text alongside the image trips it too), so destinations hand
//  a plain `UIImage` to `UIActivityViewController`, and the Instagram ones
//  send the image alone.
//
//  SwiftUI note: ImageRenderer is synchronous and heavy at 3×, so the
//  images render one at a time in `.task`, yielding between renders so the
//  first page appears quickly and the rest fill in behind it.
//

import os
import Photos
import SwiftUI

/// One page of the share preview: a shape the catch can be sent as.
enum SharePage: String, CaseIterable, Identifiable {
    case post, square, story, card

    var id: String { rawValue }

    var title: String {
        switch self {
        case .post: "Post"
        case .square: "Square"
        case .story: "Story"
        case .card: "Card"
        }
    }

    /// Spoken with the title so VoiceOver users hear the shape.
    var accessibilityShape: String {
        switch self {
        case .post: "4 by 5"
        case .square: "square"
        case .story: "9 by 16"
        case .card: "full card"
        }
    }
}

struct CatchShareSheet: View {
    let plane: CardPlane
    /// Share-sheet preview title ("Caught UAL2476 · Boeing 737-900 on Tailspot").
    let shareText: String
    /// Text that rides with the image (carries the App Store link).
    let shareMessage: String
    /// Whether the catch has the user's own photo (analytics only).
    let hasCatchPhoto: Bool

    @Environment(\.dismiss) private var dismiss

    /// Opens on Post; tests start elsewhere to snapshot each page.
    @State private var page: SharePage

    init(plane: CardPlane, shareText: String, shareMessage: String,
         hasCatchPhoto: Bool, startPage: SharePage = .post) {
        self.plane = plane
        self.shareText = shareText
        self.shareMessage = shareMessage
        self.hasCatchPhoto = hasCatchPhoto
        _page = State(initialValue: startPage)
    }
    @State private var images: [SharePage: UIImage] = [:]
    @State private var sticker: UIImage?
    @State private var storyBackground: UIImage?
    @State private var backdrop: StoryBackdrop = .glow
    @State private var backdrops: [StoryBackdrop] = []
    @State private var directStories = false
    @State private var presented: Presented?
    @State private var savedPages: Set<SharePage> = []
    @State private var copiedPage: SharePage?
    @State private var showPhotosDenied = false
    /// Funnel bookkeeping for `catch_share_format_selected` /
    /// `catch_share_closed`. `pendingVia` names a programmatic page change
    /// (chip or destination tap) so onChange can tell it from a swipe.
    @State private var pendingVia: String?
    @State private var viewedPages: Set<SharePage> = []
    @State private var didShare = false

    /// What's presented over the sheet: the system share sheet or the
    /// Messages composer, plus which destination and shape it's sending, so
    /// the outcome can be reported against them.
    private struct Presented: Identifiable {
        enum Kind {
            case activity([Any])
            case message(UIImage)
        }
        let id = UUID()
        let kind: Kind
        let destination: String
        let format: SharePage
    }

    private var current: UIImage? { images[page] }

    private var analytics: CatchShareAnalytics {
        CatchShareAnalytics(plane: plane, hasCatchPhoto: hasCatchPhoto)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                carousel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                pagePicker
                backdropPicker
                    .opacity(page == .story && backdrops.count > 1 ? 1 : 0)
                    .allowsHitTesting(page == .story && backdrops.count > 1)
                    .accessibilityHidden(page != .story || backdrops.count < 2)
                actionRow
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Brand.Color.bgElevated.ignoresSafeArea())
            .navigationTitle("Share catch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
        .sheet(item: $presented) { p in
            switch p.kind {
            case .activity(let items):
                ActivityShareSheet(items: items) { method in
                    if let method {
                        reportCompleted(p.destination, format: p.format, method: method)
                    } else {
                        analytics.cancelled(p.destination, format: p.format)
                    }
                }
                .presentationDetents([.medium, .large])
            case .message(let image):
                MessageComposeSheet(image: image, message: shareMessage) { result in
                    switch CatchShareAnalytics.outcome(result) {
                    case .completed:
                        reportCompleted(p.destination, format: p.format, method: "sent")
                    case .cancelled:
                        analytics.cancelled(p.destination, format: p.format)
                    case .failed:
                        analytics.failed(p.destination, format: p.format, reason: "send_failed")
                    }
                }
                .ignoresSafeArea()
            }
        }
        .alert("Tailspot can't save to Photos", isPresented: $showPhotosDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow Tailspot to add photos in Settings, then tap Save again.")
        }
        .sensoryFeedback(.success, trigger: savedPages.count)
        .sensoryFeedback(.success, trigger: copiedPage) { _, new in new != nil }
        .task { await renderAll() }
        .onChange(of: backdrop) { _, _ in rerenderStory() }
        .onChange(of: page) { _, new in
            viewedPages.insert(new)
            analytics.formatSelected(new, via: pendingVia ?? "swipe")
            pendingVia = nil
        }
        .onAppear { viewedPages.insert(page) }
        .onDisappear {
            analytics.sheetClosed(shared: didShare, formatsViewed: viewedPages.count,
                                  lastFormat: page)
        }
    }

    private func reportCompleted(_ destination: String, format: SharePage, method: String) {
        didShare = true
        analytics.completed(destination, format: format, method: method)
    }

    /// Move the preview programmatically, tagging why for the funnel.
    private func show(_ target: SharePage, via: String) {
        guard target != page else { return }
        pendingVia = via
        withAnimation(.snappy) { page = target }
    }

    // MARK: - Rendering

    /// Render in the order the screen needs them: the opening page first,
    /// then the other shapes, then the story layers.
    private func renderAll() async {
        directStories = InstagramStories.canShare()
        backdrops = StoryBackdrop.available(for: plane)
        backdrop = StoryBackdrop.default(for: plane)
        if images[.post] == nil { images[.post] = CatchShare.uiImage(for: plane, format: .post) }
        await Task.yield()
        if images[.square] == nil { images[.square] = CatchShare.uiImage(for: plane, format: .square) }
        await Task.yield()
        if images[.card] == nil { images[.card] = CatchShare.uiImage(for: plane) }
        await Task.yield()
        if sticker == nil { sticker = CatchShare.stickerImage(for: plane) }
        await Task.yield()
        rerenderStory()
    }

    /// The story backdrop and flattened story for the chosen background.
    private func rerenderStory() {
        guard let sticker else { return }
        storyBackground = CatchShare.storyBackgroundImage(for: plane, backdrop: backdrop)
        images[.story] = CatchShare.storyImage(for: plane, sticker: sticker, backdrop: backdrop)
        savedPages.remove(.story)
    }

    // MARK: - Preview

    /// Swipeable preview, one page per shape, each drawn at its real
    /// proportions so the user sees exactly what will be sent.
    private var carousel: some View {
        TabView(selection: $page) {
            ForEach(SharePage.allCases) { p in
                ZStack {
                    if let ui = images[p] {
                        Image(uiImage: ui)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.row))
                            .overlay(
                                RoundedRectangle(cornerRadius: Brand.Radius.row)
                                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                            )
                    } else {
                        ProgressView().tint(Brand.Color.cyan)
                    }
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tag(p)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(p.title) preview, \(p.accessibilityShape)")
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    /// Named page chips in place of dots, so each shape is findable by
    /// name and tappable as well as swipeable.
    private var pagePicker: some View {
        HStack(spacing: 6) {
            ForEach(SharePage.allCases) { p in
                chip(p.title, selected: page == p) {
                    show(p, via: "chip")
                }
            }
        }
    }

    private var backdropPicker: some View {
        HStack(spacing: 6) {
            Text("BACKGROUND")
                .font(Brand.Font.mono(size: 10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(Brand.Color.textTertiary)
                .padding(.trailing, 4)
            ForEach(backdrops, id: \.self) { b in
                chip(b.label, selected: backdrop == b) {
                    guard backdrop != b else { return }
                    backdrop = b
                    analytics.backdropSelected(b)
                }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(Brand.Font.mono(size: 11, weight: .semibold))
                .tracking(1)
                .foregroundStyle(selected ? Brand.Color.bgPrimary : Brand.Color.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selected ? Brand.Color.cyan : .white.opacity(0.06),
                            in: .rect(cornerRadius: Brand.Radius.chip))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Destinations

    private var actionRow: some View {
        // Evenly spread when the row fits; scrolls at large Dynamic Type.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 4) { tiles }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) { tiles }
            }
        }
    }


    @ViewBuilder
    private var tiles: some View {
        tileButton(.instagram, "Story", ready: images[.story] != nil) {
            show(.story, via: "destination")
            analytics.destinationTapped("instagram_story", format: .story)
            if directStories, let sticker {
                if InstagramStories.share(sticker: sticker, background: storyBackground) {
                    reportCompleted("instagram_story", format: .story, method: "instagram_handoff")
                }
            } else if let story = images[.story] {
                presented = Presented(kind: .activity([story]),
                                      destination: "instagram_story", format: .story)
            }
        }
        tileButton(.instagram, "Post", ready: images[.post] != nil) {
            show(.post, via: "destination")
            analytics.destinationTapped("instagram_post", format: .post)
            guard let post = images[.post] else { return }
            presented = Presented(kind: .activity([post]),
                                  destination: "instagram_post", format: .post)
        }
        if MessageComposeSheet.isAvailable {
            tileButton(.messages, "Messages", ready: current != nil) {
                analytics.destinationTapped("messages", format: page)
                guard let current else { return }
                presented = Presented(kind: .message(current),
                                      destination: "messages", format: page)
            }
        }
        tileButton(.symbol(copiedPage == page ? "checkmark" : "doc.on.doc"),
                   copiedPage == page ? "Copied" : "Copy", ready: current != nil) {
            analytics.destinationTapped("copy", format: page)
            guard let current else { return }
            UIPasteboard.general.image = current
            copiedPage = page
            reportCompleted("copy", format: page, method: "copied")
            let copied = page
            Task {
                try? await Task.sleep(for: .seconds(2))
                if copiedPage == copied { copiedPage = nil }
            }
        }
        tileButton(.symbol(savedPages.contains(page) ? "checkmark" : "square.and.arrow.down"),
                   savedPages.contains(page) ? "Saved" : "Save", ready: current != nil) {
            analytics.destinationTapped("save_photos", format: page)
            guard let current, !savedPages.contains(page) else { return }
            save(current, format: page)
        }
        tileButton(.symbol("ellipsis"), "More", ready: current != nil) {
            analytics.destinationTapped("more", format: page)
            guard let current else { return }
            presented = Presented(kind: .activity([current, shareMessage]),
                                  destination: "more", format: page)
        }
    }

    /// Save through PhotoKit rather than UIImageWriteToSavedPhotosAlbum, so
    /// the result comes back: "Saved" and `catch_share_completed` only on a
    /// real save; a refusal offers Settings and reports `photos_denied`.
    ///
    /// Explain-as-we-go: `performChanges` runs the block on PhotoKit's own
    /// queue and throws if the user refused add access (iOS asks the first
    /// time, using NSPhotoLibraryAddUsageDescription).
    private func save(_ image: UIImage, format: SharePage) {
        Task {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
                savedPages.insert(format)
                reportCompleted("save_photos", format: format, method: "saved")
            } catch {
                let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
                let denied = status == .denied || status == .restricted
                analytics.failed("save_photos", format: format,
                                 reason: denied ? "photos_denied" : "error")
                if denied { showPhotosDenied = true }
                Log.ui.error("Share save to Photos failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func tileButton(_ icon: ShareTileIcon, _ label: String, ready: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            tile(icon: icon, label: label)
        }
        .buttonStyle(.plain)
        .disabled(!ready)
        .opacity(ready ? 1 : 0.4)
        .accessibilityHint(ready ? "" : "Preparing image")
    }

    private func tile(icon: ShareTileIcon, label: String) -> some View {
        VStack(spacing: 7) {
            Group {
                switch icon {
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Brand.Color.bgPrimary)
                        .frame(width: 50, height: 50)
                        .background(Brand.Color.cyan, in: .circle)
                case .instagram:
                    InstagramGlyph()
                        .stroke(.white, lineWidth: 2.3)
                        .frame(width: 24, height: 24)
                        .frame(width: 50, height: 50)
                        .background(InstagramGlyph.gradient, in: .circle)
                case .messages:
                    Image(systemName: "message.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 50, height: 50)
                        .background(ShareTileIcon.messagesGreen, in: .circle)
                }
            }
            Text(label)
                .font(Brand.Font.mono(size: 10, weight: .semibold, relativeTo: .caption))
                .foregroundStyle(Brand.Color.textPrimary)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(minWidth: 52)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(icon.isInstagram ? "Instagram \(label)" : label)
    }
}

/// What a destination tile shows: an SF Symbol on the app's cyan, or a
/// destination in its own colours, the way Strava's share row does: the
/// Instagram glyph on Instagram's gradient, a white bubble on Messages
/// green. The brand mark is what people scan for in a share row, and
/// Meta's brand rules allow the glyph, unaltered, for "share to
/// Instagram" buttons; there's no SF Symbol for it.
enum ShareTileIcon {
    case symbol(String)
    case instagram
    case messages

    /// Messages' green, lighter at the top like the iOS app icon.
    static let messagesGreen = LinearGradient(
        colors: [Color(red: 0.40, green: 0.89, blue: 0.40),
                 Color(red: 0.11, green: 0.75, blue: 0.23)],
        startPoint: .top, endPoint: .bottom)

    var isInstagram: Bool {
        if case .instagram = self { return true }
        return false
    }
}

/// The Instagram glyph (rounded square, lens, flash dot) drawn as a
/// stroked path, so the app ships no image asset for it. Proportions follow
/// Meta's published glyph.
struct InstagramGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let r = CGRect(x: rect.midX - s / 2, y: rect.midY - s / 2, width: s, height: s)
        var p = Path()
        p.addRoundedRect(in: r, cornerSize: CGSize(width: s * 0.28, height: s * 0.28),
                         style: .continuous)
        p.addEllipse(in: r.insetBy(dx: s * 0.27, dy: s * 0.27))
        let dot = s * 0.07
        p.addEllipse(in: CGRect(x: r.minX + s * 0.75 - dot / 2, y: r.minY + s * 0.25 - dot / 2,
                                width: dot, height: dot))
        return p
    }

    /// Instagram's brand gradient: warm yellow at the bottom-left through
    /// orange and magenta to purple-blue at the top-right.
    static let gradient = RadialGradient(
        colors: [Color(red: 0.99, green: 0.86, blue: 0.40),
                 Color(red: 0.98, green: 0.49, blue: 0.12),
                 Color(red: 0.84, green: 0.16, blue: 0.46),
                 Color(red: 0.59, green: 0.18, blue: 0.75),
                 Color(red: 0.31, green: 0.36, blue: 0.84)],
        center: UnitPoint(x: 0.25, y: 1.05), startRadius: 0, endRadius: 80)
}
