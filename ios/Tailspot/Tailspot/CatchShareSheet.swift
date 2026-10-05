//
//  CatchShareSheet.swift
//  Tailspot
//
//  Pick a share format, see exactly what will be posted, then hand it to
//  the system share sheet. Opened by CatchDetailView's share pill
//  (2026-10-05) — before this the pill went straight to ShareLink with the
//  tall natural artboard, which Instagram's feed cropped.
//
//  SwiftUI note: ImageRenderer is synchronous and fairly heavy at 3×, so
//  each format renders once, on demand, inside `.task(id: format)` and is
//  kept in `rendered`. Flipping back to a format already seen is instant.
//  `@AppStorage` remembers the last format, so a user who always posts
//  squares lands on Square next time.
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
    @AppStorage("catchShareFormat") private var format: ShareFormat = .square
    @State private var rendered: [ShareFormat: UIImage] = [:]

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker("Format", selection: $format) {
                    ForEach(ShareFormat.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.segmented)

                Text(format.hint.uppercased())
                    .font(Brand.Font.mono(size: 11, weight: .semibold, relativeTo: .caption))
                    .tracking(1.2)
                    .foregroundStyle(Brand.Color.textTertiary)

                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                shareButton
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
        .task(id: format) {
            if rendered[format] == nil {
                rendered[format] = CatchShare.uiImage(for: plane, format: format)
            }
        }
    }

    /// The exact image that will be shared, scaled to fit. Aspect ratio is
    /// held from the format's canvas so the slot doesn't jump while a new
    /// format renders.
    private var preview: some View {
        ZStack {
            if let ui = rendered[format] {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().tint(Brand.Color.cyan)
            }
        }
        .aspectRatio(format.canvas.width / format.canvas.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.row))
        .overlay(
            RoundedRectangle(cornerRadius: Brand.Radius.row)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(format.title) share preview")
    }

    @ViewBuilder
    private var shareButton: some View {
        if let ui = rendered[format] {
            let img = Image(uiImage: ui)
            // The App Store link travels in `message:`; targets that pair
            // text with an attachment (Messages, Mail) deliver both, and
            // text-hostile ones (Instagram) post the image alone.
            ShareLink(
                item: img,
                message: Text(shareMessage),
                preview: SharePreview(shareText, image: img)
            ) {
                shareLabel
            }
            .buttonStyle(.glassProminent)
            .tint(Brand.Color.cyan)
            // ShareLink has no tap callback; a simultaneous gesture marks
            // the system sheet opening (completion isn't observable).
            .simultaneousGesture(TapGesture().onEnded {
                Analytics.capture("catch_share_opened", [
                    "rarity": .string(plane.rarity.label),
                    "has_photo": .bool(hasCatchPhoto),
                    "format": .string(format.rawValue),
                ])
            })
        } else {
            Button {} label: { shareLabel }
                .buttonStyle(.glassProminent)
                .tint(Brand.Color.cyan)
                .disabled(true)
        }
    }

    private var shareLabel: some View {
        Label("Share", systemImage: "square.and.arrow.up")
            .font(Brand.Font.mono(size: 15, weight: .bold, relativeTo: .body))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }
}
