//
//  CompassCalibrationSheet.swift
//  Tailspot
//
//  Surfaced when the user taps the AR caution badge. Says the compass is
//  off, shows the figure-8 motion that re-calibrates the magnetometer,
//  and shows the live accuracy so the user can watch the ±° number drop
//  as they move the phone. When it drops under the good line the head
//  flips to "fixed" and a success haptic fires, since someone waving
//  their phone around can't read the screen.
//
//  The sheet doesn't actually call any calibration API — iOS
//  performs the calibration in the background once the user makes
//  the motion. We just show the user what to do.
//
//  The close X is the only way out. A "Got it" button sat under it until
//  the 2026-10-31 copy pass; with the native X on every sheet it was a
//  second, louder way to do the same thing.
//

import SwiftUI

struct CompassCalibrationSheet: View {
    @ObservedObject var location: LocationManager
    @Environment(\.dismiss) private var dismiss

    /// Accuracy threshold at which we consider the compass "good enough" —
    /// the shared `CompassAccuracy.goodDeg`, the same line that clears the
    /// AR caution banner. (This used to hardcode ±10° while the banner
    /// cleared at ±15°: a user at ±12° watched the banner vanish while
    /// this sheet still read amber — and `compass_calibrated` never fired.)
    private static let goodAccuracyThreshold: Double = CompassAccuracy.goodDeg

    /// True when the live accuracy reading has dropped under the
    /// threshold while the sheet's open. Latches once it goes good
    /// so a transient bad sample doesn't flip the indicator back.
    @State private var calibratedThisSession = false

    /// Flips only on a real recovery (not the onAppear seed), so the
    /// success haptic doesn't fire for a user who opened it already good.
    @State private var recoveredWhileOpen = false

    /// nil when CoreLocation has no valid accuracy (it reports -1 while
    /// the compass is badly uncalibrated).
    private var accuracyText: String? {
        guard let acc = location.headingAccuracy, acc >= 0 else { return nil }
        return String(format: "±%.0f°", acc)
    }

    private var accuracyIsGood: Bool {
        guard let acc = location.headingAccuracy, acc >= 0 else { return false }
        return acc <= Self.goodAccuracyThreshold
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Every line that changes on recovery lays out both
                    // states (`steadyText`), so the flip swaps words and
                    // colours in place and nothing below it moves.
                    steadyText("Your compass is off", "Compass fixed")
                        .brandDisplayFont()
                        .foregroundStyle(Brand.Color.textPrimary)
                    steadyText("Labels may drift until you recalibrate.",
                               "Labels line up with planes again.")
                        .font(Brand.Font.body)
                        .foregroundStyle(Brand.Color.textSecondary)
                        .padding(.top, 6)

                    // The figure-8 gives way to a green check in the same
                    // frame: the one big "done" signal on the screen.
                    ZStack {
                        Figure8Animation()
                            .opacity(calibratedThisSession ? 0 : 1)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 72, weight: .semibold))
                            .foregroundStyle(Brand.Color.alertNormal)
                            .scaleEffect(calibratedThisSession ? 1 : 0.6)
                            .opacity(calibratedThisSession ? 1 : 0)
                    }
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
                    .accessibilityHidden(true)
                    steadyText("Move your phone in a figure-8 two or three times.",
                               "Do this again if the warning comes back.",
                               alignment: .top)
                        .font(Brand.Font.cardTitle)
                        .foregroundStyle(calibratedThisSession
                                         ? Brand.Color.textSecondary
                                         : Brand.Color.textPrimary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)

                    readout
                        .padding(.top, 32)
                }
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 28)
                .animation(.spring(duration: 0.35, bounce: 0.3), value: calibratedThisSession)
            }
            .background(Brand.Color.bgPrimary.ignoresSafeArea())
            .toolbar {
                // iOS 26 close button: the same X every sheet uses.
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .sensoryFeedback(.success, trigger: recoveredWhileOpen) { _, recovered in recovered }
        .onChange(of: accuracyIsGood) { _, isGood in
            if isGood, !calibratedThisSession {
                calibratedThisSession = true
                recoveredWhileOpen = true
                // The haptic's VoiceOver counterpart: the head flips, but
                // focus is rarely on it mid-figure-8.
                AccessibilityNotification.Announcement("Compass fixed").post()
                // Activation funnel: the user opened the sheet with a bad
                // compass and moved it back under the good threshold — the
                // coaching worked. (The onAppear seed below deliberately
                // does NOT fire this: arriving already-good isn't a
                // calibration.)
                ActivationTelemetry.fireCompassCalibrated(
                    headingAccuracyDeg: location.headingAccuracy
                )
            }
        }
        .onAppear {
            // Seed the latch — if the user opens the sheet when
            // already-good readings arrive (rare but possible), don't
            // pretend they need to recalibrate.
            if accuracyIsGood { calibratedThisSession = true }
        }
    }

    /// Both strings laid out in one cell, only the current one visible:
    /// the cell is as tall as the longer of the two in either state.
    private func steadyText(_ off: String, _ fixed: String,
                            alignment: Alignment = .topLeading) -> some View {
        ZStack(alignment: alignment) {
            Text(off)
                .opacity(calibratedThisSession ? 0 : 1)
                .accessibilityHidden(calibratedThisSession)
            Text(fixed)
                .opacity(calibratedThisSession ? 1 : 0)
                .accessibilityHidden(!calibratedThisSession)
        }
    }

    // MARK: - Readout

    /// The live accuracy, big enough to watch tick down from arm's length,
    /// with the target beside it. Tint and status follow the live reading,
    /// not the latch, so it never claims "good" over a bad number.
    private var readout: some View {
        let tint = accuracyIsGood ? Brand.Color.alertNormal : Brand.Color.alertCaution
        return VStack(alignment: .leading, spacing: 4) {
            Text("ACCURACY")
                .font(Brand.Font.mono(size: 10, weight: .semibold, relativeTo: .caption2))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.textTertiary)
            // Side by side when it fits; stacked at large text sizes, where
            // the scaled value and the hint can't share an SE's width.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    accuracyValue(tint: tint)
                    Spacer(minLength: 0)
                    accuracyStatus
                }
                VStack(alignment: .leading, spacing: 4) {
                    accuracyValue(tint: tint)
                    accuracyStatus
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: accuracyIsGood)
        .animation(.default, value: accuracyText)
        // One element with a live value, so VoiceOver users get the same
        // feedback the visual ±° tick-down provides.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Compass accuracy")
        .accessibilityValue(
            (accuracyText ?? "no reading")
            + (accuracyIsGood ? ", good" : ", aim for \(Int(Self.goodAccuracyThreshold)) degrees or less")
        )
    }

    /// NO READING is set smaller than a number, so a hidden "±00°" holds
    /// the row at the number's height: the first real reading doesn't
    /// push anything.
    private func accuracyValue(tint: Color) -> some View {
        ZStack(alignment: .leading) {
            Text("±00°")
                .font(Brand.Font.mono(size: 34, weight: .bold, relativeTo: .title))
                .hidden()
            Text(accuracyText ?? "NO READING")
                .font(Brand.Font.mono(size: accuracyText == nil ? 20 : 34,
                                      weight: .bold, relativeTo: .title))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText())
        }
        .fixedSize()
    }

    @ViewBuilder
    private var accuracyStatus: some View {
        if accuracyIsGood {
            Label("Good", systemImage: "checkmark")
                .font(Brand.Font.body.weight(.semibold))
                .foregroundStyle(Brand.Color.alertNormal)
        } else {
            Text("Aim for ±\(Int(Self.goodAccuracyThreshold))° or less")
                .font(Brand.Font.body)
                .foregroundStyle(Brand.Color.textSecondary)
        }
    }
}

// MARK: - Figure 8 animation

/// Animated cyan dot tracing a figure-8 path. Pure SwiftUI — no
/// CABasicAnimation needed; `TimelineView` ticks the dot's
/// parametric position every frame. (Lived in OnboardingFlow.swift
/// while onboarding had a calibration step; this sheet is the only
/// consumer since that step's removal, 2026-08-13.)
/// Reduce Motion: a static path illustration — the dashed figure-8
/// with a steady dot, no TimelineView ticking.
struct Figure8Animation: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            canvas(dotPhase: .pi / 4)   // a static, clearly on-path dot
        } else {
            TimelineView(.animation(minimumInterval: 1.0/30.0)) { context in
                // Animated dot along the path. Period: 3.2s.
                let now = context.date.timeIntervalSinceReferenceDate
                let t = (now.truncatingRemainder(dividingBy: 3.2)) / 3.2 * .pi * 2
                canvas(dotPhase: t)
            }
        }
    }

    /// The figure-8 illustration at a given dot position (parametric
    /// angle 0…2π along the lemniscate).
    private func canvas(dotPhase: Double) -> some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let centerX = w / 2
            let centerY = h / 2
            // The lemniscate spans 2×scale wide and 1×scale tall: fill
            // the frame's height without overrunning its width.
            let scale = min(w * 0.4, h * 0.8)
            // Trace the underlying figure-8 (lemniscate-ish) as a
            // dashed reference path.
            var ref = Path()
            let steps = 120
            for i in 0...steps {
                let t = Double(i) / Double(steps) * .pi * 2
                let x = centerX + CGFloat(sin(t) * Double(scale))
                let y = centerY + CGFloat(sin(2 * t) * Double(scale * 0.5))
                if i == 0 { ref.move(to: .init(x: x, y: y)) }
                else { ref.addLine(to: .init(x: x, y: y)) }
            }
            ctx.stroke(
                ref,
                with: .color(Brand.Color.cyan.opacity(0.35)),
                style: .init(lineWidth: 1.4, dash: [3, 5])
            )
            let x = centerX + CGFloat(sin(dotPhase) * Double(scale))
            let y = centerY + CGFloat(sin(2 * dotPhase) * Double(scale * 0.5))
            let dot = Path(ellipseIn: CGRect(x: x - 6, y: y - 6, width: 12, height: 12))
            ctx.fill(dot, with: .color(Brand.Color.cyan))
        }
    }
}

#Preview {
    CompassCalibrationSheet(location: LocationManager())
}
