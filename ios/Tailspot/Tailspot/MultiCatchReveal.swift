//
//  MultiCatchReveal.swift
//  Tailspot
//
//  The full-screen reveal that fires when the user captures
//  multiple planes in a single frame. N cards fan out from
//  center with rarity-driven holo treatment; a "combo math"
//  receipt sits above them showing the base + multiplier ladder.
//
//  Combo multiplier (per the design canvas):
//    2 in frame → ×1.5
//    3 in frame → ×2.0
//    4 in frame → ×2.5
//    5+ in frame → ×3.0
//
//  Single-catch reveal (`CardReveal.swift`) handles the N=1 case;
//  this view assumes `planes.count >= 2`.
//

import SwiftUI

struct MultiCatchReveal: View {
    let planes: [PokePlane]
    /// First entry number in the run — caller computes this (count
    /// of unique icao24 BEFORE the run minus 0..<N, or just the
    /// count of unique icao24 after, displayed once).
    let lastEntryNumber: Int
    let onDismiss: () -> Void
    let onViewInHangar: () -> Void

    @State private var animateIn = false
    @State private var revealedCount = 0
    /// Index of the currently-frontmost card. Drives a subtle
    /// elevation effect — the front card sits a hair higher.
    @State private var frontIndex: Int = 0

    private static let maxFan = 5

    private var totalBase: Int {
        planes.reduce(0) { $0 + $1.rarity.basePoints }
    }

    private var multiplier: Double {
        Self.comboMultiplier(for: planes.count)
    }

    private var totalAwarded: Int {
        Int((Double(totalBase) * multiplier).rounded())
    }

    /// Combo multiplier as a function of fan size.
    static func comboMultiplier(for n: Int) -> Double {
        switch n {
        case ..<2: return 1.0
        case 2:    return 1.5
        case 3:    return 2.0
        case 4:    return 2.5
        default:   return 3.0
        }
    }

    var body: some View {
        ZStack {
            Brand.Color.bgPrimary.ignoresSafeArea()
            backdrop.ignoresSafeArea()

            VStack(spacing: 14) {
                statusPill
                    .opacity(animateIn ? 1 : 0)
                    .offset(y: animateIn ? 0 : -8)

                Spacer(minLength: 0)

                fan
                    .opacity(animateIn ? 1 : 0)
                    .scaleEffect(animateIn ? 1 : 0.8)

                Spacer(minLength: 0)

                receipt
                    .opacity(animateIn ? 1 : 0)
                    .offset(y: animateIn ? 0 : 8)

                buttons
                    .opacity(animateIn ? 1 : 0)
                    .offset(y: animateIn ? 0 : 12)
            }
            .padding(.top, 64)
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
        .background(.black)
        .onAppear {
            // Stagger card reveal: each new card lands ~150ms after
            // the previous, capped at `maxFan`. Front-of-stack walks
            // through them so the eye gets pulled left-to-right.
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
                animateIn = true
            }
            let count = min(planes.count, Self.maxFan)
            for i in 0..<count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20 * Double(i)) {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
                        revealedCount = i + 1
                        frontIndex = i
                    }
                }
            }
        }
    }

    // MARK: - Backdrop

    /// Magenta-heavy backdrop — multi-catch is the "advisory" /
    /// special-moment color in the FAA-aligned palette.
    private var backdrop: some View {
        ZStack {
            RadialGradient(
                gradient: Gradient(colors: [
                    Brand.Color.alertAdvisory.opacity(0.30), .clear,
                ]),
                center: UnitPoint(x: 0.5, y: 0.42),
                startRadius: 0,
                endRadius: 420
            )
            .blendMode(.screen)
            // Subtle cyan undertone to keep the brand voice intact.
            RadialGradient(
                gradient: Gradient(colors: [
                    Brand.Color.cyan.opacity(0.10), .clear,
                ]),
                center: UnitPoint(x: 0.5, y: 0.75),
                startRadius: 0,
                endRadius: 320
            )
            .blendMode(.screen)
        }
    }

    // MARK: - Status pill

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle().fill(Brand.Color.alertAdvisory)
                .frame(width: 8, height: 8)
                .shadow(color: Brand.Color.alertAdvisory.opacity(0.6), radius: 4)
            Text("\(planes.count)× MULTI-CATCH · COMBO ×\(formatMultiplier(multiplier))")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Brand.Color.bgPrimary.opacity(0.75), in: .capsule)
        .overlay(Capsule().strokeBorder(Brand.Color.alertAdvisory.opacity(0.55), lineWidth: 1))
    }

    private func formatMultiplier(_ x: Double) -> String {
        x.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", x)
            : String(format: "%.1f", x)
    }

    // MARK: - Fan

    private var fan: some View {
        // Lay out up to `maxFan` cards arranged on an arc. Use
        // medium card size (220×308) so up to 5 fit comfortably on
        // an iPhone-width sheet.
        let count = min(planes.count, Self.maxFan)
        // Total spread in degrees; widens with count but caps so
        // edge cards stay readable.
        let totalSpread: Double = {
            switch count {
            case 2:  return 16
            case 3:  return 30
            case 4:  return 44
            default: return 56
            }
        }()
        let step = count == 1 ? 0 : totalSpread / Double(count - 1)
        return ZStack {
            ForEach(0..<count, id: \.self) { i in
                let angle = -totalSpread/2 + step * Double(i)
                let isFront = i == frontIndex
                let visible = i < revealedCount
                PokeCardView(
                    plane: planes[i],
                    size: .md,
                    holoIntensity: 0.65,
                    rotation: .degrees(angle)
                )
                .offset(x: CGFloat(i - count/2) * 28, y: isFront ? -8 : 0)
                .zIndex(isFront ? 1000 : Double(i))
                .opacity(visible ? 1 : 0)
                .scaleEffect(visible ? 1 : 0.6)
                .onTapGesture {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        frontIndex = i
                    }
                }
            }
        }
        .frame(height: 320)
    }

    // MARK: - Receipt

    private var receipt: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Base")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
                Spacer()
                Text("\(totalBase) pt")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .monospacedDigit()
            }
            HStack {
                Text("Combo (×\(formatMultiplier(multiplier)))")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.alertAdvisory)
                Spacer()
                Text("+\(totalAwarded - totalBase) pt")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Brand.Color.alertAdvisory)
                    .monospacedDigit()
            }
            Divider().background(Brand.Color.textTertiary.opacity(0.3)).padding(.vertical, 2)
            HStack {
                Text("AWARDED")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(Brand.Color.textTertiary)
                Spacer()
                Text("+\(totalAwarded.formatted(.number)) pt")
                    .font(.system(size: 22, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Brand.Color.cyan)
                    .monospacedDigit()
            }
        }
        .padding(14)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Brand.Color.alertAdvisory.opacity(0.30), lineWidth: 1)
        )
        .frame(maxWidth: 360)
    }

    // MARK: - Buttons

    private var buttons: some View {
        VStack(spacing: 10) {
            Button(action: onViewInHangar) {
                Text("View in Hangar")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Brand.Color.bgElevated.opacity(0.85), in: .rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            Button(action: onDismiss) {
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

#Preview {
    MultiCatchReveal(
        planes: [
            .init(callsign: "UAL248", model: "Boeing 787-9", carrier: "United", rarity: .rare, type: .wide),
            .init(callsign: "DAL2104", model: "Airbus A320", carrier: "Delta", rarity: .common, type: .narrow),
            .init(callsign: "ASA1276", model: "Boeing 737 MAX", carrier: "Alaska", rarity: .uncommon, type: .narrow),
        ],
        lastEntryNumber: 48,
        onDismiss: {},
        onViewInHangar: {}
    )
}
