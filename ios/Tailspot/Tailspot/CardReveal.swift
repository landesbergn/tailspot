//
//  CardReveal.swift
//  Tailspot
//
//  The "Card reveal" catch moment — replaces the v0 green flash
//  overlay. Full-screen takeover with a rarity-tinted backdrop
//  (radial bloom + light rays), a "● NEW CARD · ENTRY #N" pill at
//  the top, the catch card center-stage at size .lg with full holo
//  treatment, and two minimal buttons: "View in Hangar" and a
//  primary "Keep spotting" button that dismisses.
//
//  Tapping the card flips it to the logbook-style back. Tap the back
//  to flip forward. Modeled as a single state machine inside the
//  reveal so the call site (ContentView) only needs to present /
//  dismiss the whole sheet.
//

import SwiftUI

struct CardReveal: View {
    let plane: CardPlane
    /// Entry number to render in the "● NEW CARD · ENTRY #N" pill.
    /// Caller computes this (typically the count of unique icao24
    /// in the Hangar after the catch lands).
    let entryNumber: Int
    /// Caller's dismiss handler. Fires on Keep-spotting tap or a
    /// downward swipe.
    let onDismiss: () -> Void
    /// Caller's "go to Hangar" handler. Fires on View-in-Hangar tap.
    /// Tailspot's call site dismisses the reveal AND opens the
    /// Hangar sheet.
    let onViewInHangar: () -> Void
    /// Re-catch of a plane already in the Hangar. When true, the reveal
    /// still fires (per spec § 3.4) but the rarity bloom + light rays
    /// are suppressed and a diagonal red `ALREADY CAUGHT` stamp is
    /// laid over the card front. T8 threads the flag through
    /// `PendingReveal`; T10 makes the view consume it.
    var isDuplicate: Bool = false

    @State private var showingBack = false
    @State private var animateIn = false
    /// Rendered share-card image, prepared once on appear (ImageRenderer is
    /// synchronous and this view animates — never render it on the body path).
    @State private var shareImage: Image?
    var body: some View {
        ZStack {
            // Backdrop — rarity-tinted radial bloom with subtle light
            // rays, blended over the brand-dark ground.
            Brand.Color.bgPrimary.ignoresSafeArea()
            backdrop.ignoresSafeArea()

            VStack(spacing: 18) {
                statusPill
                    .opacity(animateIn ? 1 : 0)
                    .offset(y: animateIn ? 0 : -8)

                Spacer(minLength: 0)

                cardFlip
                    .scaleEffect(animateIn ? 1 : 0.85)
                    .opacity(animateIn ? 1 : 0)

                // Surface the flip affordance — users won't know the
                // card is interactive otherwise. The hint cycles to
                // "tap card to flip back" while the back is visible,
                // so the gesture is always documented in the same
                // spot.
                Text(showingBack ? "tap card to flip back" : "tap card to flip")
                    .font(Brand.Font.mono(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Brand.Color.textTertiary)
                    .opacity(animateIn ? 0.8 : 0)
                    .padding(.top, 6)

                Spacer(minLength: 0)

                buttons
                    .opacity(animateIn ? 1 : 0)
                    .offset(y: animateIn ? 0 : 12)
            }
            .padding(.top, 64)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
                animateIn = true
            }
            if shareImage == nil {
                shareImage = CatchShare.image(for: plane)
            }
        }
        .background(.black) // covers any underlying view bleed-through
    }

    /// Text that rides as the share-sheet preview title.
    private var shareTitle: String {
        let cs = plane.callsign?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (cs?.isEmpty == false ? cs! : "a plane")
        let model = plane.model.map { " · \($0)" } ?? ""
        return "Caught \(name)\(model) on Tailspot"
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        ZStack {
            // Tier-tinted radial bloom (subtle on common/uncommon,
            // strong on rare+). Suppressed entirely on duplicate
            // catches — the bloom is the loud "you got something new"
            // signal that the ALREADY CAUGHT stamp explicitly
            // contradicts. Spec § 3.4.
            if !isDuplicate {
                let bloomOpacity: Double = {
                    switch plane.rarity {
                    case .common:    return 0.10
                    case .uncommon:  return 0.18
                    case .rare:      return 0.28
                    case .epic:      return 0.36
                    case .legendary: return 0.48
                    }
                }()
                RadialGradient(
                    gradient: Gradient(colors: [
                        plane.rarity.tint.opacity(bloomOpacity), .clear,
                    ]),
                    center: UnitPoint(x: 0.5, y: 0.42),
                    startRadius: 0,
                    endRadius: 380
                )
                .blendMode(.screen)
                // Light rays — only show on rare+ tiers, kept restrained
                // so the card stays the focal point. Also suppressed on
                // duplicates by the surrounding `if !isDuplicate`.
                if plane.rarity.ordinal >= Rarity.rare.ordinal {
                    lightRays
                        .blendMode(.screen)
                        .opacity(0.35)
                }
            }
        }
    }

    /// Twelve faint radial spokes emanating from the bloom center.
    /// Drawn as a single Canvas so we only allocate once.
    private var lightRays: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.42)
            let count = 12
            for i in 0..<count {
                let theta = (Double(i) / Double(count)) * .pi * 2
                let dx = cos(theta) * Double(max(size.width, size.height))
                let dy = sin(theta) * Double(max(size.width, size.height))
                var p = Path()
                p.move(to: center)
                p.addLine(to: CGPoint(x: center.x + CGFloat(dx), y: center.y + CGFloat(dy)))
                ctx.stroke(
                    p,
                    with: .color(plane.rarity.tint.opacity(0.40)),
                    style: .init(lineWidth: 1.2)
                )
            }
        }
    }

    // MARK: - Status pill

    private var statusPill: some View {
        // Duplicate path swaps the green "NEW CARD" pill for an amber
        // "RE-CATCH" pill so the top chrome telegraphs the duplicate
        // state before the eye even reaches the stamp. Entry # still
        // shown — useful as a "this is the Nth unique" cue.
        let dotColor = isDuplicate ? Brand.Color.alertCaution : Brand.Color.alertNormal
        let label    = isDuplicate
            ? "RE-CATCH · ENTRY #\(String(format: "%03d", entryNumber))"
            : "NEW CARD · ENTRY #\(String(format: "%03d", entryNumber))"
        return HStack(spacing: 8) {
            Circle().fill(dotColor)
                .frame(width: 8, height: 8)
                .shadow(color: dotColor.opacity(0.6), radius: 4)
            Text(label)
                .font(Brand.Font.mono(size: 11, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Brand.Color.bgPrimary.opacity(0.75), in: .capsule)
        .overlay(
            Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
    }

    // MARK: - Card with flip

    private var cardFlip: some View {
        ZStack {
            if showingBack {
                CardBackView(plane: plane)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.92).combined(with: .opacity),
                        removal:   .scale(scale: 1.08).combined(with: .opacity)
                    ))
            } else {
                CatchCardView(plane: plane, size: .lg)
                    .overlay {
                        // Diagonal red-bordered "ALREADY CAUGHT" stamp,
                        // shown only on the card front for duplicates.
                        // Hidden on the logbook back so the spec sheet
                        // stays legible. Spec § 3.4.
                        if isDuplicate {
                            alreadyCaughtStamp
                                .accessibilityLabel("Already caught")
                        }
                    }
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.92).combined(with: .opacity),
                        removal:   .scale(scale: 1.08).combined(with: .opacity)
                    ))
            }
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.35)) {
                showingBack.toggle()
            }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(showingBack ? "Show card front" : "Show card details on back")
    }

    /// Trading-card "stamp" overlay laid diagonally across the catch card
    /// front when the catch is a re-catch. Modeled after physical
    /// stamps — monospaced bold all-caps with a hard rectangular
    /// border in `Brand.Color.alertWarning`.
    private var alreadyCaughtStamp: some View {
        Text("ALREADY\nCAUGHT")
            .font(Brand.Font.mono(size: 26, weight: .black))
            .tracking(2)
            .multilineTextAlignment(.center)
            .foregroundStyle(Brand.Color.alertWarning)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Brand.Color.bgPrimary.opacity(0.85))
            .overlay(
                Rectangle()
                    .strokeBorder(Brand.Color.alertWarning, lineWidth: 2.5)
            )
            .rotationEffect(.degrees(-18))
            .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 2)
    }

    // MARK: - Buttons

    private var buttons: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    onViewInHangar()
                } label: {
                    Text("View in Hangar")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Brand.Color.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Brand.Color.bgElevated.opacity(0.85), in: .rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                // Share the catch as a polished card image (prepared on appear).
                if let shareImage {
                    ShareLink(item: shareImage, preview: SharePreview(shareTitle, image: shareImage)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Brand.Color.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Brand.Color.bgElevated.opacity(0.85), in: .rect(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                onDismiss()
            } label: {
                Text("Keep spotting")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Brand.Color.cyan, in: .rect(cornerRadius: 12))
                    .shadow(color: Brand.Color.cyan.opacity(0.35), radius: 14, y: 6)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: 360)
    }

}

// MARK: - Card back

/// The logbook entry on the back of the card. Reads as a
/// structured spec sheet: identity row + watermark + caught footer.
struct CardBackView: View {
    let plane: CardPlane

    var body: some View {
        let dims = CatchCardView.CardSize.lg.dims
        ZStack {
            LinearGradient(
                colors: [Brand.Color.bgElevated, Brand.Color.bgSurface],
                startPoint: .top, endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(plane.rarity.tint).frame(height: 5)
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("LOGBOOK ENTRY")
                            .font(Brand.Font.mono(size: 10, weight: .bold))
                            .tracking(1.6)
                            .foregroundStyle(Brand.Color.textTertiary)
                        Spacer()
                        RarityBadge(rarity: plane.rarity, size: .sm)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plane.model?.trimmedNonEmpty ?? "Unknown")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Brand.Color.textPrimary)
                        if let carrier = plane.carrier?.trimmedNonEmpty {
                            Text(carrier)
                                .font(Brand.Font.cardSubtitle)
                                .foregroundStyle(Brand.Color.textSecondary)
                        }
                    }
                    Divider().background(Brand.Color.textTertiary.opacity(0.3))
                    statBlock("Callsign", plane.callsign?.trimmedNonEmpty ?? "—")
                    statBlock("Altitude", plane.altText ?? "—")
                    statBlock("Speed",    plane.speedText ?? "—")
                    statBlock("Distance", plane.distText ?? "—")
                    Divider().background(Brand.Color.textTertiary.opacity(0.3))
                    HStack {
                        TypeBadge(type: plane.type, size: .sm)
                        Spacer()
                        Text("+\(plane.rarity.basePoints) pt")
                            .font(Brand.Font.mono(size: 14, weight: .bold))
                            .foregroundStyle(plane.rarity.tint)
                    }
                    Spacer(minLength: 0)
                    Text("TAILSPOT · TAP TO FLIP")
                        .font(Brand.Font.mono(size: 8, weight: .semibold))
                        .tracking(1.4)
                        .foregroundStyle(Brand.Color.textTertiary.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(dims.width * 0.06)
            }
        }
        .frame(width: dims.width, height: dims.height)
        .clipShape(RoundedRectangle(cornerRadius: dims.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: dims.cornerRadius)
                .strokeBorder(plane.rarity.tint, lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.55), radius: 20, x: 0, y: 14)
        .shadow(color: plane.rarity.tint.opacity(0.25), radius: 18)
    }

    private func statBlock(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label.uppercased())
                .font(Brand.Font.mono(size: 9, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Brand.Color.textTertiary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(Brand.Font.mono(size: 12, weight: .bold))
                .foregroundStyle(Brand.Color.textPrimary)
                .monospacedDigit()
            Spacer()
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

#Preview("New catch") {
    CardReveal(
        plane: CardPlane(
            callsign: "BAW286",
            model: "Airbus A380",
            carrier: "British Airways",
            rarity: .epic,
            type: .wide,
            altText: "FL360",
            speedText: "488 kt",
            distText: "9 km"
        ),
        entryNumber: 48,
        onDismiss: {},
        onViewInHangar: {}
    )
}

#Preview("Re-catch (duplicate)") {
    CardReveal(
        plane: CardPlane(
            callsign: "BAW286",
            model: "Airbus A380",
            carrier: "British Airways",
            rarity: .epic,
            type: .wide,
            altText: "FL360",
            speedText: "488 kt",
            distText: "9 km"
        ),
        entryNumber: 48,
        onDismiss: {},
        onViewInHangar: {},
        isDuplicate: true
    )
}
