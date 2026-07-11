//
//  HangarRestorePromptView.swift
//  Tailspot
//
//  The restore-from-server moment (PLAN §9 #7, issue #58): a full-screen
//  branded takeover — same chrome family as `TrophyUnlockView` (opaque
//  radial spotlight, mono eyebrow, glyph, short copy) — shown when a fresh
//  install's Keychain identity turns out to hold catches on the server.
//
//  One view, four screens, driven by `HangarRestoreManager.phase`:
//    offer      "N catches found — restore?"  RESTORE / NOT NOW
//    restoring  spinner
//    done       "N catches restored"          DONE
//    failed     "couldn't reach Tailspot"     TRY AGAIN / NOT NOW
//
//  The photo caveat is load-bearing copy: photos were never uploaded, so
//  they cannot come back — the prompt says so up front (plainly, gently)
//  rather than letting the user discover placeholder heroes afterwards.
//

import SwiftUI
import SwiftData

struct HangarRestorePromptView: View {
    @ObservedObject var manager: HangarRestoreManager
    /// Restore inserts into the live store, so it takes the view's context —
    /// the same one ContentView's `@Query` observes.
    let context: ModelContext
    /// Reseeded after the bulk insert so restored trophies never re-toast.
    let unlockCenter: TrophyUnlockCenter

    var body: some View {
        ZStack {
            // Opaque branded spotlight — the TrophyUnlockView takeover chrome.
            RadialGradient(
                colors: [Brand.Color.bgElevated, Brand.Color.bgPrimary],
                center: .center, startRadius: 0, endRadius: 520
            )
            .ignoresSafeArea()

            switch manager.phase {
            case .idle:
                Color.clear
            case .offer(let total):
                offerCard(total: total)
            case .restoring:
                restoringCard
            case .done(let restored):
                doneCard(restored: restored)
            case .failed:
                failedCard
            }
        }
        .accessibilityAddTraits(.isModal)
    }

    // MARK: - Screens

    @ViewBuilder
    private func offerCard(total: Int) -> some View {
        VStack(spacing: 18) {
            eyebrow("WELCOME BACK")
            glyph()
            Text(catchCount(total) + " FOUND")
                .font(Brand.Font.mono(size: 24, weight: .heavy))
                .foregroundStyle(Brand.Color.textPrimary)
                .multilineTextAlignment(.center)
            Text("This device's catches are saved with Tailspot. Restore them to your Hangar?")
                .font(Brand.Font.body)
                .foregroundStyle(Brand.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            photoCaveat
            VStack(spacing: 14) {
                primaryButton("RESTORE " + catchCount(total)) {
                    Task { await manager.restore(context: context, unlockCenter: unlockCenter) }
                }
                quietButton("NOT NOW") { manager.decline() }
            }
            .padding(.top, 8)
        }
        .padding(.vertical, 40)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Welcome back. \(catchCount(total).lowercased()) from this device found on the server. Restore them to your Hangar? Photos can't be recovered.")
    }

    private var restoringCard: some View {
        VStack(spacing: 18) {
            eyebrow("HANGAR RESTORE")
            // A drawn HUD-style sweep, not a system ProgressView: it matches
            // the brand (cyan arc on the radar-dark field) and it renders in
            // ImageRenderer snapshots, which draw UIKit-backed spinners as a
            // placeholder glyph.
            RestoreSweep()
                .padding(.vertical, 20)
            Text("RESTORING…")
                .font(Brand.Font.mono(size: 18, weight: .heavy))
                .foregroundStyle(Brand.Color.textPrimary)
            Text("Pulling your catches from the tower.")
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.textSecondary)
        }
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private func doneCard(restored: Int) -> some View {
        VStack(spacing: 18) {
            eyebrow("HANGAR RESTORED")
            glyph()
            Text(catchCount(restored) + " RESTORED")
                .font(Brand.Font.mono(size: 24, weight: .heavy))
                .foregroundStyle(Brand.Color.textPrimary)
                .multilineTextAlignment(.center)
            Text("Your collection is back — points, trophies and all. New catches will fill it with fresh photos.")
                .font(Brand.Font.body)
                .foregroundStyle(Brand.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            primaryButton("DONE") { manager.finish() }
                .padding(.top, 8)
        }
        .padding(.vertical, 40)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hangar restored: \(catchCount(restored).lowercased()).")
    }

    private var failedCard: some View {
        VStack(spacing: 18) {
            eyebrow("HANGAR RESTORE")
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Brand.Color.alertCaution)
                .padding(.vertical, 8)
            // No apostrophes in mono headlines: B612 Mono gives the mark a
            // full fixed-width advance, which reads as "COULDN' T".
            Text("RESTORE FAILED")
                .font(Brand.Font.mono(size: 22, weight: .heavy))
                .foregroundStyle(Brand.Color.textPrimary)
            Text("Couldn't reach Tailspot. Your catches are safe on the server — try again in a moment.")
                .font(Brand.Font.body)
                .foregroundStyle(Brand.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            VStack(spacing: 14) {
                primaryButton("TRY AGAIN") { manager.retry() }
                quietButton("NOT NOW") { manager.decline() }
            }
            .padding(.top, 8)
        }
        .padding(.vertical, 40)
    }

    // MARK: - Pieces

    /// The photo truth, said once, plainly but gently.
    private var photoCaveat: some View {
        (Text(Image(systemName: "camera.on.rectangle"))
            + Text("  Catch photos only ever lived on this phone, so they can't come back — restored cards use the standard artwork."))
            .font(Brand.Font.caption)
            .foregroundStyle(Brand.Color.textTertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 44)
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(Brand.Font.mono(size: 13, weight: .heavy))
            .tracking(4)
            .foregroundStyle(Brand.Color.cyan)
    }

    /// The hangar mark inside the same soft cyan halo the trophy moment uses.
    private func glyph() -> some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [Brand.Color.cyan.opacity(0.25), .clear],
                    center: .center, startRadius: 0, endRadius: 110))
                .frame(width: 220, height: 220)
            HangarGlyph(tint: Brand.Color.cyan)
                .frame(width: 84, height: 84)
        }
        .frame(height: 170)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Brand.Font.mono(size: 14, weight: .bold))
                .tracking(1)
                .foregroundStyle(Brand.Color.bgPrimary)
                .padding(.horizontal, 28)
                .padding(.vertical, 13)
                .background(Capsule().fill(Brand.Color.cyan))
        }
        .buttonStyle(.plain)
    }

    private func quietButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Brand.Font.mono(size: 12, weight: .bold))
                .tracking(1)
                .foregroundStyle(Brand.Color.textSecondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .overlay(Capsule().strokeBorder(Brand.Color.textTertiary.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// "1 CATCH" / "62 CATCHES" — the shared count lockup.
    private func catchCount(_ n: Int) -> String {
        n == 1 ? "1 CATCH" : "\(n) CATCHES"
    }
}

/// The restoring indicator: a cyan arc sweeping around a faint track — the
/// HUD's radar language, drawn (Circle + trim) so it needs no UIKit spinner.
/// Spins continuously; under Reduce Motion it breathes opacity instead.
private struct RestoreSweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Brand.Color.cyan.opacity(0.15), lineWidth: 4)
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(Brand.Color.cyan, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
        }
        .frame(width: 64, height: 64)
        .opacity(reduceMotion && spinning ? 0.5 : 1)
        .onAppear {
            if reduceMotion {
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                    spinning = true
                }
            } else {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
        }
        .accessibilityLabel("Restoring")
    }
}
