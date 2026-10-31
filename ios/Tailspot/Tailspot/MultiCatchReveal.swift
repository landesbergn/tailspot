//
//  MultiCatchReveal.swift
//  Tailspot
//
//  The hype-peak full-screen reveal that fires when the user catches
//  ≥2 planes in a single frame (T11). Cards stagger in one-at-a-time
//  (~250 ms apart); each non-duplicate landing fires a haptic + chime
//  via `RevealAudio.tap(step:)`. A banner builds across the reveal:
//
//    "CATCH ×1"  →  "MULTI-CATCH ×2 · +N pts"  →  "MULTI-CATCH ×3 · +M pts"
//
//  Only fresh (non-duplicate) tails count toward the banner and the
//  awarded points. Duplicates appear inline with an `ALREADY CAUGHT`
//  stamp (reused styling from `CardReveal` T10) and earn nothing.
//
//  NO COMBO MULTIPLIER (2026-10-23). This view used to multiply the run
//  by ×1.5–×3.0 ("COMBO ×1.5" on the receipt), but the server never
//  awarded a combo (no scoring version has one), so the leaderboard
//  showed fewer points than the reveal promised. The points shown are
//  now exactly what each catch earns on its own: base + FIRST OF TYPE
//  (via `ScoringBonuses`, the same source as the single reveal's
//  ledger). "MULTI-CATCH ×N" stays as a celebration, not a multiplier.
//  Nothing local ever stored the combo: points are re-derived from the
//  rarity base wherever they're totalled, so there's no data to fix.
//
//  Single-catch reveal (`CardReveal.swift`) handles the N=1 case;
//  this view assumes `entries.count >= 2`.
//

import SwiftUI

struct MultiCatchReveal: View {
    /// Pairing of a card payload with a duplicate flag. Duplicates
    /// render inline with the ALREADY CAUGHT stamp and earn nothing
    /// (no points, no chime).
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let plane: CardPlane
        let isDuplicate: Bool
    }

    let entries: [Entry]
    /// First entry number in the run — caller computes this. Appended to
    /// the banner as "· ENTRY #N" once the last card has landed.
    let lastEntryNumber: Int
    let onDismiss: () -> Void
    let onViewInHangar: () -> Void

    /// Reduce Motion: cards keep the one-at-a-time cadence (the haptic +
    /// chime ladder rides it) but land as plain fades — no spring, no
    /// slide/scale entrances.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 0..<entries.count as the stagger advances. -1 = pre-stagger.
    @State private var landedIndex: Int = -1

    #if DEBUG
    /// Snapshot seam: ImageRenderer never runs `.task`, so `landedIndex` would
    /// stay at -1 (an empty screen). true renders the final, all-landed frame.
    var _snapshotAllLanded = false
    private var revealedIndex: Int { _snapshotAllLanded ? entries.count - 1 : landedIndex }
    #else
    private var revealedIndex: Int { landedIndex }
    #endif

    /// Time between successive card lands. 0.25 s matches spec § 3.3.
    private static let staggerInterval: TimeInterval = 0.25
    /// Cap the fan to 5 cards visually even if more entries arrive
    /// (defensive — `performCatch` already gates at ≤5 from the AR
    /// zone, but the math should still degrade gracefully).
    private static let maxFan = 5

    /// The share sheet for `shareSubject`.
    @State private var showShareSheet = false

    // MARK: - Points (running totals based on revealedIndex)

    /// What the run is worth, counting only fresh tails. Each fresh card
    /// earns exactly what it would on its own (base + first-of-type); there
    /// is no multi-catch multiplier, because the server doesn't award one.
    struct Tally: Equatable {
        var freshCount = 0
        var duplicateCount = 0
        var basePoints = 0
        var firstOfTypePoints = 0
        var awarded: Int { basePoints + firstOfTypePoints }
    }

    static func tally<C: Collection>(_ entries: C) -> Tally where C.Element == Entry {
        var t = Tally()
        for e in entries {
            if e.isDuplicate { t.duplicateCount += 1; continue }
            let base = e.plane.rarity.basePoints
            t.freshCount += 1
            t.basePoints += base
            if e.plane.isFirstOfType {
                t.firstOfTypePoints += ScoringBonuses.firstOfTypeBonus(base: base)
            }
        }
        return t
    }

    /// First-of-type flags for a run's fresh catches, in order. The server
    /// pays the bonus once per typecode the device didn't already hold
    /// (`isFirstOfType` checks its history before each insert), so when a run
    /// has two catches of a new type only the first earns it. The per-row
    /// Hangar scan in `ContentView.cardPlane` can't see that: it gave both
    /// rows the same answer, so the receipt showed two bonuses or none.
    /// Both catches share a typecode and so a base, so which one carries
    /// the bonus doesn't change the total. A nil typecode never qualifies.
    nonisolated static func runFirstOfType(typecodes: [String?],
                                           heldTypecodes: Set<String>) -> [Bool] {
        var seen = heldTypecodes
        return typecodes.map { tc in
            guard let tc else { return false }
            return seen.insert(tc).inserted
        }
    }

    /// The card the Share button sends: the rarest fresh catch of the run
    /// (the first one on a tie), else the rarest card overall when every
    /// card was already caught. The fan has no single "current" card, so
    /// the best catch is the one worth showing off.
    static func shareSubject(_ entries: [Entry]) -> Entry? {
        let fresh = entries.filter { !$0.isDuplicate }
        let pool = fresh.isEmpty ? entries : fresh
        return pool.reduce(nil) { best, e in
            guard let best else { return e }
            return e.plane.rarity.basePoints > best.plane.rarity.basePoints ? e : best
        }
    }

    /// Banner text for the tally of the cards landed so far.
    static func bannerLabel(for t: Tally) -> String {
        switch t.freshCount {
        // Edge case: a dup revealed first. Quiet placeholder so the banner
        // slot doesn't pop later.
        case 0: return "ALREADY CAUGHT"
        case 1: return "CATCH ×1"
        default: return "MULTI-CATCH ×\(t.freshCount) · +\(t.awarded) pts"
        }
    }

    /// Up-to-`revealedIndex` slice — what the user can see right now.
    private var visibleEntries: ArraySlice<Entry> {
        guard revealedIndex >= 0 else { return entries.prefix(0) }
        return entries.prefix(revealedIndex + 1)
    }

    /// Count of fresh (non-duplicate) cards revealed so far.
    private var freshSoFar: Int {
        visibleEntries.filter { !$0.isDuplicate }.count
    }

    var body: some View {
        ZStack {
            Brand.Color.bgPrimary.ignoresSafeArea()
            backdrop.ignoresSafeArea()

            VStack(spacing: 14) {
                // One header (beauty pass 2026-10-31): the separate
                // "3× MULTI-CATCH · ENTRY #N" pill above this disagreed with
                // the banner's fresh-only count, so the entry number now
                // rides on the banner instead.
                banner
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
                landedIndex = i
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
                try? await Task.sleep(for: .seconds(Self.staggerInterval))
            }
            // The stagger + receipt carry no accessible narration of their
            // own, so the result is announced once the run completes.
            AccessibilityNotification.Announcement(Self.announcement(for: Self.tally(entries))).post()
        }
        .sheet(isPresented: $showShareSheet) {
            if let subject = Self.shareSubject(entries) {
                let plane = subject.plane
                let text = CatchShare.shareText(for: plane)
                CatchShareSheet(plane: plane,
                                shareText: text,
                                shareMessage: CatchShare.shareMessage(shareText: text),
                                hasCatchPhoto: plane.photoURL?.isFileURL == true,
                                source: .multiReveal)
            }
        }
    }

    /// One-sentence VoiceOver summary of the whole multi-catch, posted when
    /// the last card lands (mirrors the receipt's math).
    static func announcement(for t: Tally) -> String {
        var parts = ["\(t.freshCount) planes caught"]
        if t.duplicateCount > 0 { parts.append("\(t.duplicateCount) already in hangar") }
        if t.firstOfTypePoints > 0 { parts.append("first of type plus \(t.firstOfTypePoints)") }
        parts.append("\(t.awarded) points awarded")
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

    // MARK: - Banner (T11)

    /// Builds across the stagger. Reads "CATCH ×1" at the first fresh
    /// tail; flips to "MULTI-CATCH ×N · +M pts" once a second fresh tail
    /// lands. Duplicate-only states (e.g., first card revealed is a dup)
    /// read as "ALREADY CAUGHT" until a fresh tail arrives.
    ///
    /// Plain `some View` getter (no `@ViewBuilder`) because we need
    /// the `let` declarations + explicit `return` — the builder DSL
    /// would treat the `return` as disabling itself and warn.
    private var banner: some View {
        let soFar = Self.tally(visibleEntries)
        let isMultiLive = soFar.freshCount >= 2
        let tint: Color = isMultiLive
            ? Brand.Color.alertAdvisory
            : (soFar.freshCount == 0 ? Brand.Color.alertWarning : Brand.Color.cyan)
        // The entry number joins once the tally settles (every card landed),
        // so the label doesn't grow mid-stagger.
        let settled = revealedIndex >= entries.count - 1
        let label = Self.bannerLabel(for: soFar)
            + (settled ? " · ENTRY #\(lastEntryNumber)" : "")
        // Tracking 1.5 (was 2) and a 0.5 floor: "MULTI-CATCH ×N · +M pts"
        // is longer than the old "COMBO ×N +M pts" and has to fit one line
        // on an SE at the largest text sizes.
        return Text(label)
            .font(Brand.Font.mono(size: 14, weight: .bold))
            .tracking(1.5)
            .foregroundStyle(tint)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(tint.opacity(0.16), in: .capsule)
            .overlay(Capsule().strokeBorder(tint.opacity(0.55), lineWidth: 1))
            .scaleEffect(isMultiLive && !reduceMotion ? 1.02 : 1.0)
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
                        // Pinned inside the card's photo well (top-trailing),
                        // so it never covers the type and operator lines.
                        // The full card-sized frame is rotated, not the
                        // stamp alone: rotating around the CARD's centre
                        // keeps the stamp on the photo as the fan tilts it.
                        let dims = CatchCardView.CardSize.md.dims
                        alreadyCaughtStampSmall
                            .padding(.top, 44)
                            .padding(.trailing, 22)
                            .frame(width: dims.width, height: dims.height, alignment: .topTrailing)
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
            // duplicateRose, not alertWarning red: a re-catch isn't a
            // warning (Brand.Color.duplicateRose exists for exactly this).
            .foregroundStyle(Brand.Color.duplicateRose)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Brand.Color.bgPrimary.opacity(0.85))
            .overlay(
                Rectangle()
                    .strokeBorder(Brand.Color.duplicateRose, lineWidth: 1)
            )
            .rotationEffect(.degrees(-12))
            .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 1)
            // Parity with the full-size stamp: read as a phrase, not as
            // two shouted lines split by the hard wrap.
            .accessibilityLabel("Already caught")
    }

    // MARK: - Receipt (final state)

    private var receipt: some View {
        let t = Self.tally(entries)
        return VStack(spacing: 6) {
            HStack {
                Text("Base")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
                Spacer()
                Text("\(t.basePoints) pt")
                    .font(Brand.Font.mono(size: 12, weight: .bold))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .monospacedDigit()
            }
            // Same bonus, same gold, as the single reveal's FIRST OF TYPE
            // ledger line.
            if t.firstOfTypePoints > 0 {
                HStack {
                    Text("First of type")
                        .font(Brand.Font.caption)
                        .foregroundStyle(RP.gold)
                    Spacer()
                    Text("+\(t.firstOfTypePoints) pt")
                        .font(Brand.Font.mono(size: 12, weight: .bold))
                        .foregroundStyle(RP.gold)
                        .monospacedDigit()
                }
            }
            if t.duplicateCount > 0 {
                HStack {
                    Text("Already in Hangar")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.duplicateRose)
                    Spacer()
                    Text("×\(t.duplicateCount)")
                        .font(Brand.Font.mono(size: 12, weight: .bold))
                        .foregroundStyle(Brand.Color.duplicateRose)
                        .monospacedDigit()
                }
            }
            Divider().background(Brand.Color.textTertiary.opacity(0.3)).padding(.vertical, 2)
            HStack {
                Text("TOTAL")
                    .font(Brand.Font.mono(size: 10, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(Brand.Color.textTertiary)
                Spacer()
                Text("+\(t.awarded.formatted(.number)) pt")
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
            // View in Hangar and Share split the secondary row, so Share
            // costs no extra height on a screen that's already full.
            HStack(spacing: 10) {
                Button(action: onViewInHangar) {
                    secondaryLabel("View in Hangar")
                }
                .buttonStyle(.plain)
                if let subject = Self.shareSubject(entries) {
                    Button {
                        CatchShareAnalytics(plane: subject.plane,
                                            hasCatchPhoto: subject.plane.photoURL?.isFileURL == true,
                                            source: .multiReveal)
                            .sheetOpened()
                        showShareSheet = true
                    } label: {
                        secondaryLabel(Self.shareTitle(for: subject.plane))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Self.shareAccessibilityLabel(for: subject.plane))
                }
            }

            Button(action: onDismiss) {
                Text("Keep spotting")
                    .font(.callout.weight(.bold))
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

    /// "Share UAL248": names the card that goes out, since the fan has
    /// several.
    /// Callsign, else hex id (`CatchShare.identifier`, the share copy's rule).
    static func shareTitle(for plane: CardPlane) -> String {
        guard let id = CatchShare.identifier(for: plane) else { return "Share" }
        return "Share \(id)"
    }

    /// VoiceOver label: the visible title first, so Voice Control's "tap
    /// Share UAL248" still matches, then the model for context.
    static func shareAccessibilityLabel(for plane: CardPlane) -> String {
        let title = shareTitle(for: plane)
        guard let model = plane.model?.trimmingCharacters(in: .whitespaces), !model.isEmpty else {
            return title == "Share" ? "Share best catch" : title
        }
        return "\(title), \(model)"
    }

    /// Built-in text styles (.subheadline = 15 pt at the default size) so
    /// the buttons scale with Dynamic Type; one line, shrinking before it
    /// truncates, since two share a row.
    private func secondaryLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Brand.Color.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Brand.Color.bgElevated.opacity(0.85), in: .rect(cornerRadius: Brand.Radius.row))
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
