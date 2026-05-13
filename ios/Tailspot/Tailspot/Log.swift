//
//  Log.swift
//  Tailspot
//
//  Thin wrapper around `os.Logger` so the whole app writes through one
//  subsystem ("com.landesberg.tailspot"), grouped by category. The
//  bin/log-tail script on the Mac runs `log stream --predicate
//  'subsystem == "com.landesberg.tailspot"'` against the connected
//  iPhone — without this stable subsystem, the stream would either be
//  unfiltered fire-hose or have to predicate on the bundle ID
//  (which doesn't work cleanly for system-emitted lines).
//
//  Logger calls are async-safe, free to call from any actor, and
//  zero-cost when the level is filtered out at the unified-logging
//  layer. Use these instead of print().
//

import os

enum Log {
    static let openSky  = Logger(subsystem: "com.landesberg.tailspot", category: "openSky")
    static let adsb     = Logger(subsystem: "com.landesberg.tailspot", category: "adsb")
    static let location = Logger(subsystem: "com.landesberg.tailspot", category: "location")
    static let motion   = Logger(subsystem: "com.landesberg.tailspot", category: "motion")
    static let ui       = Logger(subsystem: "com.landesberg.tailspot", category: "ui")
}
