//
//  CatchShareSheet.swift
//  Tailspot
//
//  Share a catch by DESTINATION, the pattern Spotify, Strava and Letterboxd
//  use: people think "post to my story", not "I want 9:16", so each button
//  picks the right shape itself (2026-10-05, replacing a Square / Portrait /
//  Story picker).
//
//   - Instagram Story: straight into Instagram's story editor with the card
//     as a movable sticker over a blurred catch photo (`InstagramStories`).
//     Without a Meta app ID, or without Instagram installed, the same 9:16
//     composition goes through the system share sheet instead.
//   - Instagram Post: the 4:5 compact card through the system share sheet
//     (Instagram offers no direct feed API to any app).
//   - Save: the full card straight into Photos.
//   - More: the full card plus the App Store link, for Messages, WhatsApp,
//     Mail, Save Image and the rest.
//
//  Instagram's share extension rejects SwiftUI `ShareLink` items with
//  "Content currently unavailable" (it can't load the lazy Transferable
//  image, and text alongside the image trips it too), so every destination
//  hands a plain `UIImage` to `UIActivityViewController` instead, and the
//  Instagram ones send the image alone (2026-10-07).
//
//  SwiftUI note: ImageRenderer is synchronous and heavy at 3×, so the
//  images render one at a time in `.task`, yielding between renders so the
//  preview appears first and the buttons enable as their image lands.
//

import SwiftUI

struct CatchShareSheet: View {
    let plane: CardPlane
    /// Share-sheet preview title ("Caught UAL2476 · Boeing 737-900 on Tailspot").
    let shareText: String
    /// Text that rides with the image (carries the App Store link).
    let shareMessage: String
    /// Whether the catch has the user's own photo (analytics only).
    let hasCatchPhoto: Bool

    @Environment(\.dismiss) private var dismiss

    @State private var card: UIImage?
    @State private var sticker: UIImage?
    @State private var storyBackground: UIImage?
    @State private var story: UIImage?
    @State private var post: UIImage?
    @State private var directStories = false
    /// The system share sheet's contents while it's up.
    @State private var activity: ActivityRequest?
    @State private var saved = false

    /// Items for one presentation of the system share sheet.
    private struct ActivityRequest: Identifiable {
        let id = UUID()
        let items: [Any]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack(alignment: .top, spacing: 12) {
                    storyButton
                    imageShareButton(post, destination: "instagram_post",
                                     icon: "rectangle.portrait", label: "Instagram\nPost")
                    saveButton
                    imageShareButton(card, destination: "more",
                                     icon: "ellipsis", label: "More\n",
                                     withMessage: true)
                }
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
        .sheet(item: $activity) { request in
            ActivityShareSheet(items: request.items) { _ in }
                .presentationDetents([.medium, .large])
        }
        .task { await renderAll() }
    }

    /// Render in the order the screen needs them: the preview first, then
    /// the story layers, then the post.
    private func renderAll() async {
        directStories = InstagramStories.canShare()
        if card == nil { card = CatchShare.uiImage(for: plane) }
        await Task.yield()
        if sticker == nil { sticker = CatchShare.stickerImage(for: plane) }
        await Task.yield()
        if storyBackground == nil { storyBackground = CatchShare.storyBackgroundImage(for: plane) }
        await Task.yield()
        if story == nil, let sticker { story = CatchShare.storyImage(for: plane, sticker: sticker) }
        await Task.yield()
        if post == nil { post = CatchShare.uiImage(for: plane, format: .post) }
    }

    /// The card as it will appear; each destination frames it for its shape.
    private var preview: some View {
        ZStack {
            if let card {
                Image(uiImage: card)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Share preview")
    }

    // MARK: - Destinations

    /// Direct into Instagram's story editor when configured and installed;
    /// otherwise the flattened 9:16 story through the system share sheet.
    @ViewBuilder
    private var storyButton: some View {
        if directStories {
            Button {
                guard let sticker else { return }
                InstagramStories.share(sticker: sticker, background: storyBackground)
                captureShare("instagram_story", method: "direct")
            } label: {
                tile(icon: "plus.circle", label: "Instagram\nStory")
            }
            .buttonStyle(.plain)
            .disabled(sticker == nil)
        } else {
            imageShareButton(story, destination: "instagram_story",
                             icon: "plus.circle", label: "Instagram\nStory")
        }
    }

    /// Opens the system share sheet with a rendered image, disabled until
    /// the image exists. Only "More" adds the App Store link: Messages and
    /// Mail deliver it with the card, but Instagram's extension refuses an
    /// image that arrives with text.
    @ViewBuilder
    private func imageShareButton(_ ui: UIImage?, destination: String,
                                  icon: String, label: String,
                                  withMessage: Bool = false) -> some View {
        if let ui {
            Button {
                activity = ActivityRequest(items: withMessage ? [ui, shareMessage] : [ui])
                captureShare(destination, method: "share_sheet")
            } label: {
                tile(icon: icon, label: label)
            }
            .buttonStyle(.plain)
        } else {
            tile(icon: icon, label: label)
                .opacity(0.4)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Preparing image")
        }
    }

    /// Saves the full card to Photos in one tap. Needs
    /// `NSPhotoLibraryAddUsageDescription` (add-only access; iOS asks once).
    private var saveButton: some View {
        Button {
            guard let card, !saved else { return }
            UIImageWriteToSavedPhotosAlbum(card, nil, nil, nil)
            saved = true
            captureShare("save_photos", method: "direct")
        } label: {
            tile(icon: saved ? "checkmark" : "arrow.down.to.line",
                 label: saved ? "Saved\n" : "Save\n")
        }
        .buttonStyle(.plain)
        .disabled(card == nil)
        .opacity(card == nil ? 0.4 : 1)
        .sensoryFeedback(.success, trigger: saved)
    }

    private func tile(icon: String, label: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Brand.Color.bgPrimary)
                .frame(width: 58, height: 58)
                .background(Brand.Color.cyan, in: .circle)
            Text(label)
                .font(Brand.Font.mono(size: 11, weight: .semibold, relativeTo: .caption))
                .multilineTextAlignment(.center)
                .foregroundStyle(Brand.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces))
    }

    /// Share-funnel signal, read next to the "Tailspot Catch Share" campaign
    /// in App Analytics.
    private func captureShare(_ destination: String, method: String) {
        Analytics.capture("catch_share_opened", [
            "rarity": .string(plane.rarity.label),
            "has_photo": .bool(hasCatchPhoto),
            "destination": .string(destination),
            "method": .string(method),
        ])
    }
}
