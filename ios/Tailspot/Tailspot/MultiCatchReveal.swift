//
//  MultiCatchReveal.swift
//  Tailspot
//
//  The hype-peak full-screen reveal that fires when the user catches
//  ≥2 planes in a single frame (T11). Cards stagger in one-at-a-time
//  (~250 ms apart); each non-duplicate landing fires a haptic + chime
//  via `RevealAudio.tap(step:)`. A combo banner builds across the
//  reveal:
//
//    "CATCH ×1"  →  "COMBO ×2 +N pts"  →  "COMBO ×3 +M pts"  ...
//
//  Only fresh (non-duplicate) tails contribute to the combo count and
//  the awarded points. Duplicates appear inline with an `ALREADY
//  CAUGHT` stamp (reused styling from `CardReveal` T10) but don't
//  bump the combo.
//
//  Combo multiplier (per the design canvas — preserved API; tests pin
//  these values):
//    2 fresh → ×1.5
//    3 fresh → ×2.0
//    4 fresh → ×2.5
//    5+ fresh → ×3.0
//
//  Single-catch reveal (`CardReveal.swift`) handles the N=1 case;
//  this view assumes `entries.count >= 2`.
//

import SwiftUI

struct MultiCatchReveal: View {
    /// Pairing of a card payload with a duplicate flag. Duplicates
    /// render inline with the ALREADY CAUGHT stamp but don't contribute
    /// to the combo math (no points, no chime).
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let plane: CardPlane
        let isDuplicate: Bool
    }

    let entries: [Entry]
    /// First entry number in the run — caller computes this. Shown in
    /// the status pill as a quiet "ENTRY #N" tag at the top.
    let lastEntryNumber: Int
    let onDismiss: () -> Void
    let onViewInHangar: () -> Void

    /// Reduce Motion: cards keep the one-at-a-time cadence (the haptic +
    /// chime ladder rides it) but land as plain fades — no spring, no
    /// slide/scale entrances.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 0..<entries.count as the stagger advances. -1 = pre-stagger.
    @State private var revealedIndex: Int = -1

    /// Time between successive card lands. 0.25 s matches spec § 3.3.
    private static let stagger: TimeInterval = 0.25
    /// Cap the fan to 5 cards visually even if more entries arrive
    /// (defensive — `performCatch` already gates at ≤5 from the AR
    /// zone, but the math should still degrade gracefully).
    private static let maxFan = 5

    // MARK: - Combo math (running totals based on revealedIndex)

    /// Up-to-`revealedIndex` slice — what the user can see right now.
    private var visibleEntries: ArraySlice<Entry> {
        guard revealedIndex >= 0 else { return entries.prefix(0) }
        return entries.prefix(revealedIndex + 1)
    }

    /// Count of fresh (non-duplicate) cards revealed so far.
    private var freshSoFar: Int {
        visibleEntries.filter { !$0.isDuplicate }.count
    }

    /// Total fresh count at the end of the run — pins the multiplier.
    private var totalFresh: Int {
        entries.filter { !$0.isDuplicate }.count
    }

    /// Base points across all currently-visible fresh cards.
    private var baseSoFar: Int {
        visibleEntries
            .filter { !$0.isDuplicate }
            .reduce(0) { $0 + $1.plane.rarity.basePoints }
    }

    /// Points awarded so far (base × multiplier). Multiplier is keyed
    /// to the *final* fresh count (not the running one) so the banner
    /// uses the same multiplier the receipt will close with.
    private var awardedSoFar: Int {
        Int((Double(baseSoFar) * Self.comboMultiplier(for: totalFresh)).rounded())
    }

    /// Combo multiplier as a function of fresh-catch count. (Tests
    /// pin these values; the API is preserved from the prior version.)
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
                    .opacity(revealedIndex >= 0 ? 1 : 0)
                    .offset(y: revealedIndex >= 0 || reduceMotion ? 0 : -8)

                comboBanner
                    .opacity(revealedIndex >= 0 ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: freshSoFar)

                Spacer(minLength: 0)

                fan

                Spacer(minLength: 0)

                // Receipt + dismiss button reveal only after the last
                // card has landed so the eye stays on the cards
                // during stagger.
                if revealedIndex >= entries.count - 1 {
                    receipt
                        .transition(reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .move(edge: .bottom)))
                    buttons
                        .transition(reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.top, 64)
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
            .animation(reduceMotion
                ? .easeOut(duration: 0.25)
                : .spring(response: 0.45, dampingFraction: 0.78),
                       value: revealedIndex)
        }
        .background(.black)
        .task {
            // Initial settle frame before the stagger so the backdrop
            // can paint without the first card popping in mid-fade.
            try? await Task.sleep(for: .milliseconds(120))
            for i in 0..<entries.count {
                revealedIndex = i
                let entry = entries[i]
                // Haptic + chime only for fresh tails. Duplicates land
                // silently so the chime ladder reads as the new-catch
                // count.
                if !entry.isDuplicate {
                    // Use the count of fresh cards landed so far as
                    // the chime step — so the chime ladder ascends
                    // 1→2→3 even if a dup sits between two fresh.
                    let freshStep = entries.prefix(i + 1)
                        .filter { !$0.isDuplicate }.count - 1
                    RevealAudio.tap(step: max(0, freshStep))
                }
                try? await Task.sleep(for: .seconds(Self.stagger))
            }
            // The stagger + receipt carry no accessible narration of their
            // own, so the combo result is announced once the run completes.
            AccessibilityNotification.Announcement(comboAnnouncement).post()
        }
    }

    /// One-sentence VoiceOver summary of the whole multi-catch, posted when
    /// the last card lands (mirrors the receipt's math).
    private var comboAnnouncement: String {
        let totalBase = entries
            .filter { !$0.isDuplicate }
            .reduce(0) { $0 + $1.plane.rarity.basePoints }
        let multiplier = Self.comboMultiplier(for: totalFresh)
        let totalAwarded = Int((Double(totalBase) * multiplier).rounded())
        let dupCount = entries.filter(\.isDuplicate).count
        var parts = ["\(totalFresh) planes caught"]
        if dupCount > 0 { parts.append("\(dupCount) already in hangar") }
        if totalFresh >= 2 { parts.append("combo times \(formatMultiplier(multiplier))") }
        parts.append("\(totalAwarded) points awarded")
        return parts.joined(separator: ", ")
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
            Text("\(entries.count)× MULTI-CATCH · ENTRY #\(lastEntryNumber)")
                .font(Brand.Font.mono(size: 11, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Brand.Color.bgPrimary.opacity(0.75), in: .capsule)
        .overlay(Capsule().strokeBorder(Brand.Color.alertAdvisory.opacity(0.55), lineWidth: 1))
        // One element — the glowing dot is decorative next to the text.
        .accessibilityElement(children: .combine)
    }

    private func formatMultiplier(_ x: Double) -> String {
        x.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", x)
            : String(format: "%.1f", x)
    }

    // MARK: - Combo banner (T11)

    /// Builds across the stagger. Reads "CATCH ×1" at the first fresh
    /// tail; flips to "COMBO ×N +M pts" once a second fresh tail
    /// lands. Duplicate-only states (e.g., first card revealed is a
    /// dup) read as "DUPLICATE" until a fresh tail arrives.
    ///
    /// Plain `some View` getter (no `@ViewBuilder`) because we need
    /// the `let` declarations + explicit `return` — the builder DSL
    /// would treat the `return` as disabling itself and warn.
    private var comboBanner: some View {
        let label: String
        let isComboLive = freshSoFar >= 2
        if freshSoFar == 0 {
            // Edge case: dup revealed first. Quiet placeholder so the
            // banner slot doesn't pop later.
            label = "ALREADY CAUGHT"
        } else if freshSoFar == 1 {
            label = "CATCH ×1"
        } else {
            label = "COMBO ×\(freshSoFar) +\(awardedSoFar) pts"
        }
        let tint: Color = isComboLive
            ? Brand.Color.alertAdvisory
            : (freshSoFar == 0 ? Brand.Color.alertWarning : Brand.Color.cyan)
        return Text(label)
            .font(Brand.Font.mono(size: 14, weight: .bold))
            .tracking(2)
            .foregroundStyle(tint)
            .monospacedDigit()
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(tint.opacity(0.16), in: .capsule)
            .overlay(Capsule().strokeBorder(tint.opacity(0.55), lineWidth: 1))
            .scaleEffect(isComboLive && !reduceMotion ? 1.02 : 1.0)
    }

    // MARK: - Fan

    private var fan: some View {
        // Lay out up to `maxFan` cards arranged on an arc. Use
        // medium card size (220×308) so up to 5 fit comfortably on
        // an iPhone-width sheet.
        let count = min(entries.count, Self.maxFan)
        // Total spread in degrees; widens with count but caps so
        // edge cards stay readable.
        let totalSpread: Double = {
            switch count {
            case ..<2: return 0
            case 2:    return 16
            case 3:    return 30
            case 4:    return 44
            default:   return 56
            }
        }()
        let step = count <= 1 ? 0 : totalSpread / Double(count - 1)
        let halfCount = Double(count) / 2.0
        return ZStack {
            ForEach(Array(entries.prefix(count).enumerated()), id: \.element.id) { i, entry in
                let angle = -totalSpread/2 + step * Double(i)
                let visible = i <= revealedIndex
                // Offset cards horizontally from center; symmetric.
                let xOffset = (Double(i) - halfCount + 0.5) * 28
                ZStack {
                    CatchCardView(
                        plane: entry.plane,
                        size: .md,
                        holoIntensity: entry.isDuplicate ? 0.25 : 0.65,
                        rotation: .degrees(angle)
                    )
                    if entry.isDuplicate {
                        alreadyCaughtStampSmall
                            .rotationEffect(.degrees(angle))
                            .allowsHitTesting(false)
                    }
                }
                .offset(x: CGFloat(xOffset), y: visible || reduceMotion ? 0 : 40)
                .zIndex(Double(i))
                .opacity(visible ? 1 : 0)
                .scaleEffect(visible || reduceMotion ? 1 : 0.6)
                .animation(reduceMotion
                    ? .easeOut(duration: 0.25)
                    : .spring(response: 0.45, dampingFraction: 0.7),
                           value: revealedIndex)
            }
        }
        .frame(height: 320)
    }

    /// Smaller version of CardReveal's diagonal ALREADY CAUGHT stamp.
    /// Intentionally inlined (rather than imported) so MultiCatchReveal
    /// stays self-contained — see T10 comment in CardReveal.swift for
    /// the full-size source.
    private var alreadyCaughtStampSmall: some View {
        Text("ALREADY\nCAUGHT")
            .font(Brand.Font.mono(size: 14, weight: .black))
            .tracking(1.5)
            .multilineTextAlignment(.center)
            .foregroundStyle(Brand.Color.alertWarning)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Brand.Color.bgPrimary.opacity(0.85))
            .overlay(
                Rectangle()
                    .strokeBorder(Brand.Color.alertWarning, lineWidth: 1.5)
            )
            .rotationEffect(.degrees(-18))
            .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 1)
            // Parity with the full-size stamp: read as a phrase, not as
            // two shouted lines split by the hard wrap.
            .accessibilityLabel("Already caught")
    }

    // MARK: - Receipt (final state)

    private var receipt: some View {
        let totalBase = entries
            .filter { !$0.isDuplicate }
            .reduce(0) { $0 + $1.plane.rarity.basePoints }
        let multiplier = Self.comboMultiplier(for: totalFresh)
        let totalAwarded = Int((Double(totalBase) * multiplier).rounded())
        let dupCount = entries.filter(\.isDuplicate).count
        return VStack(spacing: 6) {
            HStack {
                Text("Base")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
                Spacer()
                Text("\(totalBase) pt")
                    .font(Brand.Font.mono(size: 12, weight: .bold))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .monospacedDigit()
            }
            HStack {
                Text("Combo (×\(formatMultiplier(multiplier)))")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.alertAdvisory)
                Spacer()
                Text("+\(totalAwarded - totalBase) pt")
                    .font(Brand.Font.mono(size: 12, weight: .bold))
                    .foregroundStyle(Brand.Color.alertAdvisory)
                    .monospacedDigit()
            }
            if dupCount > 0 {
                HStack {
                    Text("Already in Hangar")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.alertWarning)
                    Spacer()
                    Text("×\(dupCount)")
                        .font(Brand.Font.mono(size: 12, weight: .bold))
                        .foregroundStyle(Brand.Color.alertWarning)
                        .monospacedDigit()
                }
            }
            Divider().background(Brand.Color.textTertiary.opacity(0.3)).padding(.vertical, 2)
            HStack {
                Text("AWARDED")
                    .font(Brand.Font.mono(size: 10, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(Brand.Color.textTertiary)
                Spacer()
                Text("+\(totalAwarded.formatted(.number)) pt")
                    .font(Brand.Font.mono(size: 22, weight: .heavy))
                    .foregroundStyle(Brand.Color.cyan)
                    .monospacedDigit()
            }
        }
        .padding(14)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: Brand.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Brand.Radius.card)
                .strokeBorder(Brand.Color.alertAdvisory.opacity(0.30), lineWidth: 1)
        )
        .frame(maxWidth: 360)
        // The ledger reads as one receipt, not eight loose fragments.
        .accessibilityElement(children: .combine)
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
                    .background(Brand.Color.bgElevated.opacity(0.85), in: .rect(cornerRadius: Brand.Radius.row))
            }
            .buttonStyle(.plain)

            Button(action: onDismiss) {
                Text("Keep spotting")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Brand.Color.cyan, in: .rect(cornerRadius: Brand.Radius.row))
                    .shadow(color: Brand.Color.cyan.opacity(0.35), radius: 14, y: 6)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: 360)
    }
}

#Preview("Multi (3 fresh)") {
    MultiCatchReveal(
        entries: [
            .init(plane: .init(callsign: "UAL248", model: "Boeing 787-9", carrier: "United", rarity: .rare, type: .wide), isDuplicate: false),
            .init(plane: .init(callsign: "DAL2104", model: "Airbus A320", carrier: "Delta", rarity: .common, type: .narrow), isDuplicate: false),
            .init(plane: .init(callsign: "ASA1276", model: "Boeing 737 MAX", carrier: "Alaska", rarity: .uncommon, type: .narrow), isDuplicate: false),
        ],
        lastEntryNumber: 48,
        onDismiss: {},
        onViewInHangar: {}
    )
}

#Preview("Multi (2 fresh + 1 dup)") {
    MultiCatchReveal(
        entries: [
            .init(plane: .init(callsign: "UAL248", model: "Boeing 787-9", carrier: "United", rarity: .rare, type: .wide), isDuplicate: false),
            .init(plane: .init(callsign: "DAL2104", model: "Airbus A320", carrier: "Delta", rarity: .common, type: .narrow), isDuplicate: true),
            .init(plane: .init(callsign: "ASA1276", model: "Boeing 737 MAX", carrier: "Alaska", rarity: .uncommon, type: .narrow), isDuplicate: false),
        ],
        lastEntryNumber: 49,
        onDismiss: {},
        onViewInHangar: {}
    )
}
