//
//  TailspotApp.swift
//  Tailspot
//
//  Created by Noah Landesberg on 5/5/26.
//

import SwiftUI
import os

@main
struct TailspotApp: App {
    init() {
        // Surfaces in bin/log-tail. Useful as a heartbeat so the
        // deploy loop confirms a launch reached app code; also gives
        // us a "session boundary" line for debugging later sessions.
        Log.ui.notice("Tailspot launched")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
