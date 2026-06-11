//
//  NotificationsScreen.swift
//  Tailspot
//
//  Honest placeholder — push notifications are not implemented yet.
//  The fake @AppStorage toggles from the mock UI have been removed:
//  they stored state for a feature that doesn't exist, which created
//  a false impression of functionality for testers. The backend push
//  infrastructure is a PLAN §9 follow-up.
//

import SwiftUI

struct NotificationsScreen: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Notifications are coming after launch", systemImage: "bell.slash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Brand.Color.textPrimary)
                    Text("Push alerts for rare-aircraft overhead, trophy unlocks, and set completions ship with the Tailspot backend. Your preferences will be configurable here once the feature lands.")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textSecondary)
                }
                .padding(.vertical, 6)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { NotificationsScreen() }
}
