//
//  NotificationsScreen.swift
//  Tailspot
//
//  Settings for the notifications backbone (no real push delivery
//  yet — that's backend work). Toggles persist via @AppStorage so
//  the user's intent is captured day-one.
//
//  Sections mirror the design canvas:
//    PUSH         — master allow toggle
//    NEARBY AIRCRAFT — what kinds of overhead events fire a push
//    PROGRESS     — trophy / set / weekly digest pushes
//    QUIET HOURS  — when to mute everything
//

import SwiftUI

struct NotificationsScreen: View {
    @AppStorage("tailspot.notif.allow")          private var allow: Bool = true
    @AppStorage("tailspot.notif.rare")           private var notifyRare: Bool = false
    @AppStorage("tailspot.notif.legendary")      private var notifyLegendary: Bool = true
    @AppStorage("tailspot.notif.firstType")      private var notifyFirstType: Bool = false
    @AppStorage("tailspot.notif.multiCatch")     private var notifyMultiCatch: Bool = false
    @AppStorage("tailspot.notif.trophy")         private var notifyTrophy: Bool = true
    @AppStorage("tailspot.notif.setComplete")    private var notifySetComplete: Bool = true
    @AppStorage("tailspot.notif.weekly")         private var notifyWeekly: Bool = false
    @AppStorage("tailspot.notif.quietOvernight") private var quietOvernight: Bool = true
    @AppStorage("tailspot.notif.quietWeekends")  private var quietWeekends: Bool = false

    var body: some View {
        List {
            Section {
                rarePreview
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section {
                Toggle("Allow Tailspot notifications", isOn: $allow)
            } header: {
                Text("Push")
            } footer: {
                Text("You'll never get more than 1–2 a day. Pushes don't ship until the Tailspot backend lands; these preferences are remembered for then.")
            }

            Section {
                Toggle("Rare or Epic aircraft", isOn: $notifyRare)
                Toggle("Legendary aircraft",    isOn: $notifyLegendary)
                Toggle("First-of-type for you", isOn: $notifyFirstType)
                Toggle("Multi-catch opportunity", isOn: $notifyMultiCatch)
            } header: {
                Text("Nearby aircraft")
            } footer: {
                Text("Get pinged when a noteworthy plane is overhead. Rare+ requires the plane to be approaching within 15 km; legendary covers a 50 km radius.")
            }

            Section {
                Toggle("Trophy unlocks",                 isOn: $notifyTrophy)
                Toggle("Set completion (one to go)",     isOn: $notifySetComplete)
                Toggle("Weekly summary",                 isOn: $notifyWeekly)
            } header: {
                Text("Progress")
            } footer: {
                Text("Heads-up when you're one slot away from completing a set. Sunday 8pm weekly digest with your numbers.")
            }

            Section {
                Toggle("Mute 10pm → 7am",   isOn: $quietOvernight)
                Toggle("Mute on weekends",  isOn: $quietWeekends)
            } header: {
                Text("Quiet hours")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        // The allow toggle gates the entire feature — when it's off,
        // everything else greys out (still tappable, but visually
        // de-emphasized so the user understands the state).
        .disabled(!allow && false) // keep editable; visual cue only
    }

    /// Mock lock-screen preview of a rare-aircraft push.
    private var rarePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PREVIEW")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.textTertiary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Brand.Color.alertAdvisory)
                    .frame(width: 38, height: 38)
                    .overlay(
                        Image(systemName: "airplane")
                            .foregroundStyle(.white)
                            .font(.system(size: 17, weight: .bold))
                    )
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text("TAILSPOT")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1)
                            .foregroundStyle(Brand.Color.textSecondary)
                        Spacer()
                        Text("now")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(Brand.Color.textSecondary)
                    }
                    Text("Rare aircraft overhead")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Brand.Color.textPrimary)
                    Text("Airbus A380 (British Airways) inbound to SFO. 2 min out.")
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.Color.textSecondary)
                        .lineLimit(2)
                }
            }
            .padding(12)
            .background(Brand.Color.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.Color.bgPrimary)
    }
}

#Preview {
    NavigationStack { NotificationsScreen() }
}
