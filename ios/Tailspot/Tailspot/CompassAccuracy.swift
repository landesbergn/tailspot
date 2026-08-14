//
//  CompassAccuracy.swift
//  Tailspot
//
//  The one shared "good compass" line, in degrees of reported heading
//  accuracy. Below it: the AR caution banner clears, the calibration
//  sheet flips to its recovered state (and fires `compass_calibrated`),
//  and Gate 5 stops treating the compass as poor.
//
//  One number so the surfaces can't drift apart again — they did: the
//  sheet hardcoded ±10° while the banner cleared at ±15°, so a user at
//  ±12° watched the banner vanish while the sheet still read amber and
//  said their heading was off (error-copy pass, 2026-08-14).
//
//  Deliberately NOT here: the banner's arm threshold (±25°) and its 4 s
//  debounce stay private to ContentView — they tune when to *shout*,
//  not what counts as good. (Onboarding once had its own stricter ±10°
//  latch; the whole step was removed 2026-08-13 (#183), so the banner →
//  sheet path is the only calibration surface left.)
//

nonisolated enum CompassAccuracy {
    static let goodDeg: Double = 15
}
