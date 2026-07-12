//
//  PermissionRecoveryCard.swift
//  Tailspot
//
//  Centered recovery card for explicitly-denied permissions: name what's
//  missing, why it matters, and the one tap that fixes it. iOS only
//  re-asks via Settings, so "Open Settings" is the whole affordance.
//
//  Before this existed, a camera denial rendered as a silent black void
//  and a location denial as a forever-"waiting" GPS — first-run dead ends
//  found while instrumenting the activation funnel (PLAN §9 #3).
//
//  A standalone view (not a ContentView private) so the snapshot harness
//  can render every denial combination without a camera or a device.
//

import SwiftUI
import UIKit

struct PermissionRecoveryCard: View {
    let cameraDenied: Bool
    let locationDenied: Bool

    private var glyph: String {
        if cameraDenied && locationDenied { return "gearshape.fill" }
        return cameraDenied ? "camera.fill" : "location.slash.fill"
    }

    private var title: String {
        if cameraDenied && locationDenied { return "Camera & location are off" }
        return cameraDenied ? "The sky view needs the camera" : "Which sky are you under?"
    }

    private var message: String {
        if cameraDenied && locationDenied {
            return "Tailspot points a camera at the sky and matches what it sees against live flights near you. Both permissions are off — flip them on in Settings."
        }
        if cameraDenied {
            return "Tailspot never records or uploads the camera feed — it's only the window you spot through. Turn it on in Settings."
        }
        return "Without your location, Tailspot can't match the planes overhead. Allow location while using the app in Settings."
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: glyph)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Brand.Color.alertCaution)
                // The title restates the denied capability; keep VoiceOver
                // from reading the raw SF Symbol name.
                .accessibilityHidden(true)
            Text(title)
                .brandDisplayFont()
                .foregroundStyle(Brand.Color.textPrimary)
                .multilineTextAlignment(.center)
                // At display size the longer titles need a second line, but
                // this Text truncated instead of wrapping (the container
                // offers one line's height during measurement). Vertical
                // fixedSize lets it take the height it needs.
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(Brand.Font.body)
                .foregroundStyle(Brand.Color.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black.opacity(0.88))
                    .padding(.horizontal, 26)
                    .padding(.vertical, 12)
                    .frame(minHeight: 44)
                    .background(Brand.Color.cyan, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: 320)
        .background(Brand.Color.bgElevated.opacity(0.96), in: .rect(cornerRadius: Brand.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Brand.Radius.card)
                .strokeBorder(Brand.Color.alertCaution.opacity(0.35), lineWidth: 1)
        )
    }
}

#Preview {
    ZStack {
        Brand.Color.bgPrimary.ignoresSafeArea()
        PermissionRecoveryCard(cameraDenied: true, locationDenied: false)
    }
}
