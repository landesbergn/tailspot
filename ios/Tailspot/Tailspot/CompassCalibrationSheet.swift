//
//  CompassCalibrationSheet.swift
//  Tailspot
//
//  Surfaced when the user taps the AR caution badge. Explains why
//  the compass reads as untrustworthy, demonstrates the figure-8
//  motion that re-calibrates the magnetometer, and shows a live
//  readout of current heading + accuracy so the user can see the
//  ±° number drop as they move the phone.
//
//  The sheet doesn't actually call any calibration API — iOS
//  performs the calibration in the background once the user makes
//  the motion. We just show the user what to do.
//

import SwiftUI

struct CompassCalibrationSheet: View {
    @ObservedObject var location: LocationManager
    @Environment(\.dismiss) private var dismiss

    /// Accuracy threshold at which we consider the compass "good
    /// enough" — mirrors `ContentView.isHeadingAccuracyBad`.
    private static let goodAccuracyThreshold: Double = 10

    /// True when the live accuracy reading has dropped under the
    /// threshold while the sheet's open. Latches once it goes good
    /// so a transient bad sample doesn't flip the indicator back.
    @State private var calibratedThisSession = false

    private var accuracyText: String {
        guard let acc = location.headingAccuracy, acc >= 0 else { return "—" }
        return String(format: "±%.0f°", acc)
    }

    private var headingText: String {
        guard let h = location.heading else { return "—" }
        return String(format: "%.0f°", h)
    }

    private var accuracyIsGood: Bool {
        guard let acc = location.headingAccuracy, acc >= 0 else { return false }
        return acc <= Self.goodAccuracyThreshold
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        headlineBlock
                        readoutCard
                        animationBlock
                        explanationBlock
                        Spacer(minLength: 16)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
                VStack {
                    Spacer()
                    dismissButton
                        .padding(.horizontal, 22)
                        .padding(.bottom, 22)
                }
            }
            .navigationTitle("Compass")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onChange(of: accuracyIsGood) { _, isGood in
            if isGood, !calibratedThisSession {
                calibratedThisSession = true
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

    // MARK: - Sections

    private var headlineBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(calibratedThisSession ? "COMPASS · CALIBRATED" : "COMPASS · CALIBRATE")
                .font(Brand.Font.mono(size: 10, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(calibratedThisSession ? Brand.Color.alertNormal : Brand.Color.alertCaution)
            Text(calibratedThisSession
                 ? "You're good to go."
                 : "Your heading is off by more than ±10°.")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Brand.Color.textPrimary)
            Text(calibratedThisSession
                 ? "Brackets will now sit on the right plane. You can dismiss."
                 : "AR brackets will sit off to the side of the actual plane until you recalibrate.")
                .font(Brand.Font.body)
                .foregroundStyle(Brand.Color.textSecondary)
        }
    }

    /// Live readout: HDG (degrees) and ±° accuracy. Updates in real
    /// time so the user sees the number change as they move.
    private var readoutCard: some View {
        let tint = accuracyIsGood ? Brand.Color.alertNormal : Brand.Color.alertCaution
        return HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("HEADING")
                    .font(Brand.Font.mono(size: 9, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Brand.Color.textTertiary)
                Text(headingText)
                    .font(Brand.Font.mono(size: 28, weight: .heavy))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .monospacedDigit()
            }
            Rectangle().fill(Brand.Color.bgPrimary.opacity(0.6)).frame(width: 1, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text("ACCURACY")
                    .font(Brand.Font.mono(size: 9, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Brand.Color.textTertiary)
                Text(accuracyText)
                    .font(Brand.Font.mono(size: 28, weight: .heavy))
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }
            Spacer()
            statusGlyph
        }
        .padding(16)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(tint.opacity(0.4), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.25), value: accuracyIsGood)
    }

    private var statusGlyph: some View {
        Image(systemName: accuracyIsGood
              ? "checkmark.circle.fill"
              : "exclamationmark.triangle.fill")
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(accuracyIsGood ? Brand.Color.alertNormal : Brand.Color.alertCaution)
    }

    private var animationBlock: some View {
        VStack(spacing: 8) {
            Text(calibratedThisSession ? "WHEN YOU NEED TO RECALIBRATE" : "TRACE A FIGURE-8")
                .font(Brand.Font.mono(size: 9, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Brand.Color.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Figure8Animation()
                .frame(height: 200)
                .padding(.vertical, 8)
                .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 14))
                .opacity(calibratedThisSession ? 0.55 : 1)
        }
    }

    private var explanationBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            ExplanationRow(
                glyph: "magnifyingglass",
                title: "What's wrong",
                detail: "iPhone's magnetometer drifts near metal — cars, bridges, steel-framed buildings, even appliances. Off by ±10° puts AR brackets ~50 px off-target at 4× zoom."
            )
            ExplanationRow(
                glyph: "infinity",
                title: "What fixes it",
                detail: "Move the phone in a smooth figure-8 in the air, like writing the number 8 with your hand. Two or three passes is enough."
            )
            ExplanationRow(
                glyph: "checkmark.seal",
                title: "How you know it worked",
                detail: "The accuracy number above ticks down. When it drops under ±10°, brackets sit on the right plane again."
            )
        }
    }

    private var dismissButton: some View {
        Button {
            dismiss()
        } label: {
            HStack(spacing: 6) {
                if calibratedThisSession {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                }
                Text(calibratedThisSession ? "All good" : "Got it")
                    .font(.system(size: 16, weight: .bold))
            }
            .foregroundStyle(.black.opacity(0.88))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                (calibratedThisSession ? Brand.Color.alertNormal : Brand.Color.cyan),
                in: .rect(cornerRadius: 14)
            )
            .shadow(color: (calibratedThisSession
                            ? Brand.Color.alertNormal
                            : Brand.Color.cyan).opacity(0.30),
                    radius: 14, y: 6)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.25), value: calibratedThisSession)
    }
}

private struct ExplanationRow: View {
    let glyph: String
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: glyph)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Brand.Color.cyan)
                .frame(width: 28, height: 28)
                .background(Brand.Color.cyan.opacity(0.12), in: .rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.Color.textPrimary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.Color.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }
}

#Preview {
    CompassCalibrationSheet(location: LocationManager())
}
