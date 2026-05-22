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
                        .font(.system(.body, design: .monospaced))
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
                LabeledLink(label: "Version", value: Bundle.main.shortVersion)
                LabeledLink(label: "Build", value: Bundle.main.buildNumber)
                LabeledLink(label: "Data source", value: "OpenSky Network")
                LabeledLink(label: "Photos", value: "Planespotters.net")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
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
}

#Preview {
    NavigationStack { SettingsScreen() }
}
