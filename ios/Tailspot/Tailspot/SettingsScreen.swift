//
//  SettingsScreen.swift
//  Tailspot
//
//  iOS-grouped settings: identity (handle), privacy (public hangar
//  toggle, location-when-in-use disclosure), playback (live/mock
//  source toggle, autocatch hold duration display), about (version,
//  acknowledgements).
//

import SwiftUI

struct SettingsScreen: View {
    @AppStorage(SpotterHandle.storageKey) private var handle: String = SpotterHandle.defaultPlaceholder
    @AppStorage("tailspot.profile.public") private var publicProfile: Bool = true
    @AppStorage("tailspot.notif.rare") private var notifyRare: Bool = false

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Handle")
                    Spacer()
                    Text("@")
                        .foregroundStyle(Brand.Color.textTertiary)
                    TextField("handle", text: $handle)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(Brand.Font.mono(size: 17))
                }
            } header: {
                Text("Identity")
            } footer: {
                Text("Your handle is the only thing visible on the leaderboard and public hangar.")
            }

            Section {
                Toggle("Public hangar", isOn: $publicProfile)
                LabeledLink(label: "Location data", value: "While-in-use")
                LabeledLink(label: "Camera", value: "AR preview only")
            } header: {
                Text("Privacy")
            } footer: {
                Text("Public hangar lets other spotters visit your catches. Location is read live but never written to disk or transmitted.")
            }

            Section("Playback") {
                LabeledLink(label: "Source", value: "LIVE or MOCK in debug overlay")
                LabeledLink(label: "Autocatch hold", value: "3.0 s")
                LabeledLink(label: "Visibility cap", value: "30 km")
            }

            Section {
                Toggle("Rare-aircraft alerts", isOn: $notifyRare)
                NavigationLink("All notifications") {
                    NotificationsScreen()
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Get a push when a rare-tier or higher airframe is overhead within the next 5 minutes.")
            }

            Section("About") {
                LabeledLink(label: "Data source", value: "OpenSky Network")
                LabeledLink(label: "Photos", value: "Planespotters.net")
            }

            // Version/build footer at the page bottom — tester-visible,
            // tap-to-copy so bug reports can paste an exact identifier.
            // Replaces the separate Version + Build rows we used to
            // have inside About.
            Section {
            } footer: {
                versionFooter
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// "Tailspot 0.1.0 (build N) · tap to copy". Tap copies the same
    /// string to the clipboard so a tester reporting a bug can paste
    /// it verbatim into a message — no "what version are you on?"
    /// back-and-forth.
    private var versionFooter: some View {
        Button {
            UIPasteboard.general.string = Bundle.main.tailspotVersionLine
            // Light haptic confirms the copy without yanking focus.
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        } label: {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(Bundle.main.tailspotVersionLine)
                    .font(Brand.Font.mono(size: 11, weight: .regular))
                    .foregroundStyle(Brand.Color.textTertiary)
                Text(" · tap to copy")
                    .font(Brand.Font.mono(size: 11, weight: .regular))
                    .foregroundStyle(Brand.Color.textTertiary.opacity(0.6))
                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct LabeledLink: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(Brand.Color.textSecondary)
        }
    }
}

private extension Bundle {
    var shortVersion: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }
    var buildNumber: String {
        (object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "—"
    }
    /// Combined "Tailspot X.Y.Z (build N)" string — used by the
    /// Settings footer for both display and clipboard payload.
    var tailspotVersionLine: String {
        "Tailspot \(shortVersion) (build \(buildNumber))"
    }
}

#Preview {
    NavigationStack { SettingsScreen() }
}
