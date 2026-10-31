//
//  MultiCatchReveal.swift
//  Tailspot
//
//  The reveal for a press that caught ≥2 planes in one frame (T11).
//
//  THE RUN (2026-10-31 redesign). Each plane gets the real single-catch
//  reveal (`CatchRevealView`, in `sequence` mode), one after another, then
//  a summary card in the same reveal vocabulary (RP palette, split-flap
//  head, rarity frame, score ledger). It replaced a tilted fan of mini
//  cards under a magenta MULTI-CATCH banner, which Noah called "an
//  eye-sore that feels disjointed from the rest of the app": a multi-catch
//  looked like a different game from a single catch. Now it reads as the
//  same moment, more than once — a crescendo, not a new screen type.
//
//    plane 1 reveal → "Next plane" → plane 2 reveal → … → "See the total"
//    → summary (each plane, its tier and points; the ledger; Continue /
//    View in Hangar)
//
//  A stories-style progress strip at the top says where you are in the
//  run. Each fresh plane's page plays one rung of the ascending chime
//  ladder (`RevealAudio`), so the run climbs as it goes; duplicates play
//  the single reveal's ALREADY CAUGHT state and stay silent. "Skip to
//  total" jumps straight to the summary from any plane.
//
//  NO COMBO MULTIPLIER (2026-10-23): the points shown are exactly what each
//  catch earns on its own, base + FIRST OF TYPE via `ScoringBonuses`, the
//  same source as the single reveal's ledger (the server never awarded a
//  combo). Duplicates earn nothing.
//
//  Single-catch reveals go straight to `CatchRevealView`; this view
//  assumes `entries.count >= 2`.
//

import SwiftUI

struct MultiCatchReveal: View {
    /// Pairing of a card payload with a duplicate flag. Duplicates play the
    /// single reveal's ALREADY CAUGHT state and earn nothing.
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let plane: CardPlane
        let isDuplicate: Bool
    }

    let entries: [Entry]
    /// The Hangar's unique-catch count after this run (the caller computes
    /// it); the run's last fresh plane is this entry number.
    let lastEntryNumber: Int
    let onDismiss: () -> Void
    let onViewInHangar: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 0..<entries.count = that plane's reveal; entries.count = the summary.
    @State private var page = 0
    /// Clock anchor for the summary's split-flap head and row stagger.
    @State private var summaryStart: Date?
    /// Pauses the summary's TimelineView once its clock has clamped.
    @State private var summaryAnimationDone = false

    #if DEBUG
    /// Snapshot seam: ImageRenderer can't tap through the run, so this
    /// renders a given page directly (entries.count = the summary, settled).
    var _snapshotPage: Int? = nil
    private var currentPage: Int { _snapshotPage ?? page }
    #else
    private var currentPage: Int { page }
    #endif

    private var onSummary: Bool { currentPage >= entries.count }

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

    /// The entry number each plane's reveal shows: fresh planes count up to
    /// `lastEntryNumber` in run order; a duplicate shows the current count,
    /// like the single duplicate reveal.
    static func entryNumbers(_ entries: [Entry], lastEntryNumber: Int) -> [Int] {
        let fresh = entries.filter { !$0.isDuplicate }.count
        var next = lastEntryNumber - fresh + 1
        return entries.map { e in
            if e.isDuplicate { return lastEntryNumber }
            defer { next += 1 }
            return next
        }
    }

    /// The step of the chime ladder a page plays: the count of fresh planes
    /// up to and including it, minus one, so the ladder climbs 1→2→3 even
    /// with a duplicate between two fresh planes. nil for a duplicate.
    static func chimeStep(_ entries: [Entry], page: Int) -> Int? {
        guard entries.indices.contains(page), !entries[page].isDuplicate else { return nil }
        return entries.prefix(page + 1).filter { !$0.isDuplicate }.count - 1
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

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            RP.bg.ignoresSafeArea()

            Group {
                if onSummary {
                    summary
                        .transition(pageTransition)
                } else {
                    planePage(currentPage)
                        // Room for the progress strip above, so it never sits
                        // on the card's top edge on a short phone.
                        .safeAreaInset(edge: .top, spacing: 0) {
                            Color.clear.frame(height: Self.stripHeight)
                        }
                        // A fresh identity per page restarts the reveal's
                        // clocks, so every plane gets its full moment.
                        .id(currentPage)
                        .transition(pageTransition)
                }
            }

            progressStrip
        }
        .animation(reduceMotion ? .easeOut(duration: 0.25)
                                : .spring(response: 0.45, dampingFraction: 0.86),
                   value: currentPage)
        .onAppear { playChime(for: 0) }
    }

    private var pageTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                          removal: .move(edge: .leading).combined(with: .opacity))
    }

    private func planePage(_ i: Int) -> some View {
        let entry = entries[i]
        let sequence = CatchRevealView.RevealSequence(index: i, count: entries.count)
        return CatchRevealView(
            plane: entry.plane,
            entryNumber: Self.entryNumbers(entries, lastEntryNumber: lastEntryNumber)[i],
            onDismiss: { advance() },
            // Before the last plane the second exit skips to the total; on
            // the last plane it is the real View in Hangar.
            onViewInHangar: sequence.isLast ? onViewInHangar : { goToSummary() },
            isDuplicate: entry.isDuplicate,
            sequence: sequence
        )
    }

    private func advance() {
        page += 1
        playChime(for: page)
    }

    private func goToSummary() {
        page = entries.count
    }

    private func playChime(for page: Int) {
        #if DEBUG
        if _snapshotPage != nil { return }
        #endif
        if let step = Self.chimeStep(entries, page: page) {
            RevealAudio.tap(step: step)
        }
    }

    // MARK: - Progress strip

    /// The strip's top padding + bar + a gap below it.
    private static let stripHeight: CGFloat = 6 + 3 + 8

    /// Stories-style segments: one per plane, lit up to the current one.
    /// Gone on the summary, where the run is complete.
    private var progressStrip: some View {
        HStack(spacing: 4) {
            ForEach(entries.indices, id: \.self) { i in
                Capsule()
                    .fill(RP.ink.opacity(i <= currentPage ? 0.85 : 0.18))
                    .frame(height: 3)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .opacity(onSummary ? 0 : 1)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Plane \(min(currentPage, entries.count - 1) + 1) of \(entries.count)")
        .accessibilityHidden(onSummary)
    }

    // MARK: - Summary

    /// The rarest fresh plane's tier frames the summary (the run's best
    /// catch); every plane already caught → the rarest overall.
    private var headlineRarity: Rarity {
        let fresh = entries.filter { !$0.isDuplicate }
        let pool = fresh.isEmpty ? entries : fresh
        return pool.map(\.plane.rarity).max { $0.basePoints < $1.basePoints } ?? .common
    }

    private var summary: some View {
        GeometryReader { geo in
            let width = min(geo.size.width - 28, 420)
            let scale = width / 300
            // Centred when it fits; scrolls when it can't (a five-plane run
            // on an SE). ViewThatFits rather than an always-on ScrollView,
            // which also keeps the snapshot harness able to draw it
            // (ImageRenderer leaves ScrollView content blank).
            ViewThatFits(in: .vertical) {
                summaryColumn(width: width, scale: scale)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                ScrollView {
                    summaryColumn(width: width, scale: scale)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear {
            if summaryStart == nil { summaryStart = Date() }
            AccessibilityNotification.Announcement(Self.announcement(for: Self.tally(entries))).post()
        }
        .task {
            try? await Task.sleep(for: .seconds(1.5))
            summaryAnimationDone = true
        }
    }

    private func summaryColumn(width: CGFloat, scale: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            TimelineView(.animation(paused: summaryAnimationDone || settledSummary)) { ctx in
                let t = settledSummary ? 1 : summaryStart.map { revClamp(ctx.date.timeIntervalSince($0) / 1.4) } ?? 0
                summaryCard(t: t, scale: scale)
                    .frame(width: width)
            }
            Spacer(minLength: 12)
            summaryCTAs
                .padding(.top, 24)
                .padding(.bottom, 28)
        }
    }

    private var settledSummary: Bool {
        #if DEBUG
        if _snapshotPage != nil { return true }
        #endif
        return reduceMotion
    }

    private func summaryCard(t: Double, scale: CGFloat) -> some View {
        let tally = Self.tally(entries)
        let accent = headlineRarity.tint
        let head = "\(entries.count) PLANES"
        let cw = 20 * scale
        return VStack(alignment: .leading, spacing: 12 * scale) {
            HStack {
                Text("MULTI-CATCH")
                    .font(.system(size: 10 * scale, weight: .heavy, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(accent)
                Spacer()
                Text("ENTRY #\(lastEntryNumber)")
                    .font(.system(size: 10 * scale, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundColor(RP.faint)
            }
            FlapRow(text: head, t: t, startT: 0.0, spanT: 0.45,
                    fs: min(22 * scale, cw * 0.86), cw: cw, gap: 2.5 * scale,
                    reduceMotion: reduceMotion, color: RP.ink)
            Text("One frame.")
                .font(.system(size: 15 * scale))
                .foregroundColor(RP.muted)

            Rectangle().fill(RP.rule).frame(height: 1)

            VStack(spacing: 10 * scale) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                    let n = Double(max(1, entries.count))
                    summaryRow(e, scale: scale)
                        .opacity(ss(0.3 + 0.3 * Double(i) / n, 0.45 + 0.3 * Double(i) / n, t))
                }
            }

            Rectangle().fill(RP.rule).frame(height: 1)

            VStack(spacing: 8 * scale) {
                ledgerRow("BASE", "+\(tally.basePoints)", RP.muted, 1, scale: scale)
                if tally.firstOfTypePoints > 0 {
                    ledgerRow("FIRST OF TYPE", "+\(tally.firstOfTypePoints)", RP.gold, 1, scale: scale)
                }
                if tally.duplicateCount > 0 {
                    ledgerRow("ALREADY CAUGHT", "×\(tally.duplicateCount)",
                              Brand.Color.duplicateRose, 1, scale: scale)
                }
                Rectangle().fill(RP.rule).frame(height: 1)
                ledgerRow("TOTAL", "+\(Int((Double(tally.awarded) * ss(0.7, 1.0, t)).rounded()))",
                          accent, 1, scale: scale, big: true)
            }
            .opacity(ss(0.6, 0.8, t))
        }
        .padding(20 * scale)
        .modifier(CatchRarityFrame(rarity: headlineRarity, scale: scale))
        .accessibilityElement(children: .combine)
    }

    /// One plane of the run: its catch photo, name, callsign and tier, and
    /// what it earned (or ALREADY CAUGHT).
    private func summaryRow(_ e: Entry, scale: CGFloat) -> some View {
        let p = e.plane
        let earned = e.isDuplicate ? 0
            : p.rarity.basePoints + (p.isFirstOfType ? ScoringBonuses.firstOfTypeBonus(base: p.rarity.basePoints) : 0)
        return HStack(spacing: 12 * scale) {
            thumb(p, scale: scale)
                .frame(width: 44 * scale, height: 44 * scale)
                .clipShape(RoundedRectangle(cornerRadius: 8 * scale))
                .overlay(RoundedRectangle(cornerRadius: 8 * scale).strokeBorder(RP.rule, lineWidth: 1))
                .opacity(e.isDuplicate ? 0.55 : 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3 * scale) {
                Text(p.model ?? CatchShare.identifier(for: p) ?? "Unidentified aircraft")
                    .font(.system(size: 15 * scale, weight: .semibold))
                    .foregroundColor(e.isDuplicate ? RP.muted : RP.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                HStack(spacing: 6 * scale) {
                    if let cs = CatchShare.identifier(for: p) {
                        Text(cs).foregroundColor(RP.muted)
                    }
                    Text(p.rarity.label).foregroundColor(p.rarity.tint)
                }
                .font(.system(size: 10 * scale, weight: .semibold, design: .monospaced))
                .tracking(1)
                .lineLimit(1)
            }
            Spacer(minLength: 8 * scale)
            if e.isDuplicate {
                // Short, so it never truncates beside a long model name; the
                // ledger below spells out ALREADY CAUGHT.
                Text("IN HANGAR")
                    .font(.system(size: 9 * scale, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundColor(Brand.Color.duplicateRose)
            } else {
                Text("+\(earned)")
                    .font(.system(size: 16 * scale, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(RP.ink)
            }
        }
    }

    /// The plane's catch photo, or (no photo yet) a tier-tinted tile with a
    /// plane glyph: the reveal's full-size sky placeholder crops to a
    /// meaningless corner at thumbnail size.
    @ViewBuilder
    private func thumb(_ p: CardPlane, scale: CGFloat) -> some View {
        if p.photoURL != nil {
            RevealPhoto(url: p.photoURL, focus: p.photoFocus)
        } else {
            ZStack {
                RP.flapFace
                p.rarity.tint.opacity(0.10)
                Image(systemName: "airplane")
                    .font(.system(size: 17 * scale, weight: .semibold))
                    .foregroundStyle(p.rarity.tint.opacity(0.8))
            }
        }
    }

    /// The same quiet exits as the single reveal's CTA row.
    private var summaryCTAs: some View {
        HStack(spacing: 22) {
            Button(action: onDismiss) {
                Text("Continue")
                    .font(Brand.Font.body.weight(.semibold))
                    .foregroundColor(RP.ink)
                    .contentShape(Rectangle().inset(by: -16))
            }
            .buttonStyle(.plain)
            Button(action: onViewInHangar) {
                Text("View in Hangar ›")
                    .font(Brand.Font.body)
                    .foregroundColor(RP.muted)
                    .contentShape(Rectangle().inset(by: -16))
            }
            .buttonStyle(.plain)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}
