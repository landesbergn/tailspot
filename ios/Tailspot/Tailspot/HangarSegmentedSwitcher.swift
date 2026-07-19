//
//  HangarSegmentedSwitcher.swift
//  Tailspot
//
//  Top-of-Hangar segment switcher (Sets / Recent / Trophies).
//
//  Fourth build (2026-07-19, after three field rounds with Noah):
//  hand-rolled buttons → custom glass track with Buttons (fired on
//  touch-UP — felt laggy) → native segmented Picker (right physics,
//  but renders as the compact ~32 pt control, not the floating glass
//  slider) → THIS: a proper Liquid Glass slider built from the iOS 26
//  glass APIs. A GlassEffectContainer blends a glass track with a
//  cyan-tinted `.interactive()` glass thumb; a zero-distance drag
//  drives the thumb CONTINUOUSLY under the finger (with a short snappy
//  spring, so it trails liquid-style and springs to a press), selection
//  flips live as the thumb crosses segment boundaries (page + haptic
//  tick follow), and on release the thumb snaps to its segment's rest
//  position. 44 pt targets throughout (the 2026-06-15 requirement).
//

import SwiftUI

enum HangarSegment: String, CaseIterable, Identifiable {
    case sets, recent, trophies
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sets:     return "Sets"
        case .recent:   return "Recent"
        case .trophies: return "Trophies"
        }
    }
}

struct HangarSegmentedSwitcher: View {
    @Binding var selection: HangarSegment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Finger-driven thumb center x while a drag is live; nil = resting on
    /// the selected segment. Distinct from `selection` so the thumb can sit
    /// BETWEEN segments mid-drag (the slider visual) while selection flips
    /// discretely at boundary crossings.
    @State private var dragX: CGFloat? = nil

    private static let trackPadding: CGFloat = 5
    private static let segmentHeight: CGFloat = 44
    private static let controlHeight: CGFloat = segmentHeight + trackPadding * 2

    var body: some View {
        GeometryReader { geo in
            let segments = HangarSegment.allCases
            let innerWidth = geo.size.width - Self.trackPadding * 2
            let segmentWidth = innerWidth / CGFloat(segments.count)
            let selectedIndex = CGFloat(segments.firstIndex(of: selection) ?? 0)
            let restX = Self.trackPadding + segmentWidth * (selectedIndex + 0.5)
            // Mid-drag the thumb follows the finger, clamped so it never
            // escapes the track; at rest it centers on the selected segment.
            let minX = Self.trackPadding + segmentWidth / 2
            let thumbX = dragX.map { min(max($0, minX), geo.size.width - minX) } ?? restX

            // One container so the track and thumb read as a single liquid
            // surface (and so the glass thumb doesn't swallow taps for
            // non-glass siblings — the Profile-bug lesson, PR #127).
            GlassEffectContainer {
                ZStack {
                    // The sliding thumb: brand-cyan glass. `.interactive()`
                    // is what gives the liquid press/stretch response.
                    Capsule()
                        .fill(.clear)
                        .frame(width: segmentWidth, height: Self.segmentHeight)
                        .glassEffect(
                            .regular.tint(Brand.Color.cyan.opacity(0.85)).interactive(),
                            in: .capsule
                        )
                        .position(x: thumbX, y: Self.controlHeight / 2)

                    HStack(spacing: 0) {
                        ForEach(segments) { seg in
                            Text(seg.label)
                                .font(.system(size: 15, weight: selection == seg ? .semibold : .medium))
                                .foregroundStyle(
                                    selection == seg ? Brand.Color.bgPrimary : Brand.Color.textSecondary
                                )
                                .frame(maxWidth: .infinity, minHeight: Self.segmentHeight)
                        }
                    }
                    .padding(.horizontal, Self.trackPadding)
                }
            }
            .background {
                Capsule().fill(.clear).glassEffect(.regular, in: .capsule)
            }
            // Animating the continuously-retargeted thumb x is deliberate:
            // the spring re-aims every frame, so the thumb TRAILS the finger
            // slightly (the native glass-slider feel) and springs across on
            // a plain tap. Reduce Motion pins it directly to the target.
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: thumbX)
            .contentShape(.capsule)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragX = value.location.x
                        select(atX: value.location.x, segmentWidth: segmentWidth)
                    }
                    .onEnded { value in
                        select(atX: value.location.x, segmentWidth: segmentWidth)
                        dragX = nil   // thumb snaps to the segment's rest position
                    }
            )
        }
        .frame(height: Self.controlHeight)
        // The selection tick as the thumb lands on / crosses segments
        // (select() no-ops on unchanged selection, so drags only tick on
        // actual crossings).
        .sensoryFeedback(.selection, trigger: selection)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // Container semantics so VoiceOver users step segments with the
        // adjustable swipe; the drag surface itself isn't element-navigable.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hangar section")
        .accessibilityValue(selection.label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAdjustableAction { direction in
            let all = HangarSegment.allCases
            guard let idx = all.firstIndex(of: selection) else { return }
            switch direction {
            case .increment:
                if idx < all.count - 1 { selection = all[idx + 1] }
            case .decrement:
                if idx > 0 { selection = all[idx - 1] }
            @unknown default:
                break
            }
        }
    }

    /// Map a control-local x to a segment and select it (no-op when already
    /// selected). Portrait, iPhone-only, English-only app — LTR assumed.
    private func select(atX x: CGFloat, segmentWidth: CGFloat) {
        guard segmentWidth > 0 else { return }
        let all = HangarSegment.allCases
        let index = min(all.count - 1, max(0, Int((x - Self.trackPadding) / segmentWidth)))
        let seg = all[index]
        if seg != selection { selection = seg }
    }
}
