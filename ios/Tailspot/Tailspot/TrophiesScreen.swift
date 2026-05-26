//
//  TrophiesScreen.swift
//  Tailspot
//
//  Thin nav-bar wrapper around `HangarTrophiesView`. Trophies now
//  live inside the Hangar's Trophies segment (Spec § 4.2, § 7); this
//  wrapper exists so any remaining push paths that still construct
//  `TrophiesScreen()` (settings, future deep links) keep working
//  without re-implementing the body.
//

import SwiftUI
import SwiftData

struct TrophiesScreen: View {
    var body: some View {
        HangarTrophiesView()
            .navigationTitle("Trophies")
            .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        TrophiesScreen()
    }
    .modelContainer(for: Catch.self, inMemory: true)
}
