//
//  MilitaryDesignators.swift
//  Tailspot
//
//  A curated, EXACT-MATCH set of ICAO type designators that are genuinely
//  military combat aircraft (fighters, attack, bombers, EW) but are
//  MISCLASSIFIED in the bundled `AircraftTypes.json` as `.narrow` / `.wide`
//  / `.ga`.
//
//  Why this exists (root cause):
//    The 2026-06-09 classification round used an exact-match MIL set in
//    tools/generate-aircraft-types.py, but deliberately left ~110 military
//    jets miscoded as "low ROI" because they don't surface in-app. The
//    guess mechanic changed that calculus: `GuessOptions.typeQuestion`
//    samples distractors by shared `AircraftType`, so a commercial
//    narrowbody (e.g. A321neo) could draw a Boeing EA-18 Growler or a
//    Tupolev Tu-22 — absurd distractors that give the answer away and read
//    as broken.
//
//  Why a Swift SET and not a generator/JSON fix:
//    Completing the classification in the generator is the "right" long-term
//    fix, BUT (1) generate-aircraft-types.py fetches LIVE ICAO DOC 8643 data
//    over HTTP — there is no offline source snapshot in the repo, so a
//    regeneration would mix unrelated upstream drift into the diff (the
//    documented reason PR1 avoided running it); and (2) reclassifying these
//    designators to `.mil` moves their rarity `common → epic` (the military
//    default in aircraft_rarity), and AircraftTypes.json feeds scoring — a
//    rarity change requires a scoring_version bump + prod re-score, which is
//    out of scope for a distractor-quality fix. So the correction lives here,
//    at the pure runtime layer, with ZERO scoring impact. When a
//    deterministic regen eventually lands (source saved offline + rescore),
//    these become truly `.mil` and this set becomes redundant but harmless
//    (`isMilitary` short-circuits on `type == .mil`).
//
//  Why EXACT-MATCH and not a regex/keyword predicate:
//    Model-string keywords flood with false positives — Diamond DA-20
//    "Falcon", Grumman AA-5 "Tiger", Titan "Tornado" ultralight, the
//    aerobatic Sukhoi Su-26/29/31, and the Tupolev Tu-134/154/204/334
//    AIRLINERS all read "military" to a regex but are not. Every designator
//    below was reviewed one-by-one against its DOC 8643 model string;
//    airliners and civilian look-alikes are intentionally excluded.
//
//  `nonisolated` per repo convention: pure value logic callable from any
//  actor.
//

import Foundation

nonisolated enum MilitaryDesignators {

    /// ICAO designators that are genuine military combat aircraft but are
    /// miscoded as `.narrow` / `.wide` / `.ga` in the bundled table. Keys are
    /// uppercased ICAO designators, matching `AircraftTypes.json` keys.
    ///
    /// Scoped to MANNED (and jet-class UCAV) combat types — fighters, attack,
    /// strike, EW, bombers. Deliberately EXCLUDES: Tupolev airliners
    /// (Tu-134/154/204/334), aerobatic/utility Sukhois (Su-26/29/31/38/80),
    /// and WWII warbird light types — none of which belong in a `.mil` pool.
    static let miscoded: Set<String> = [
        // ── Western fighters / attack / strike / EW ──
        "A4",    // McDonnell Douglas A-4 Skyhawk
        "A6",    // Grumman A-6 Intruder
        "A10",   // Fairchild A-10 Thunderbolt II
        "AJET",  // Dassault/Dornier Alpha Jet
        "BUC",   // Hawker Siddeley Buccaneer
        "F2",    // Mitsubishi F-2
        "F4",    // McDonnell Douglas F-4 Phantom II
        "F5",    // Northrop F-5 Tiger II
        "F8",    // Chance Vought F-8 Crusader
        "F14",   // Grumman F-14 Tomcat
        "F15",   // McDonnell Douglas F-15 Eagle
        "F16",   // General Dynamics F-16 Fighting Falcon
        "F18S",  // Boeing EA-18 Growler  ← the reported offender
        "F22",   // Lockheed Martin F-22 Raptor
        "F35",   // Lockheed Martin F-35A Lightning II
        "VF35",  // Lockheed Martin F-35B Lightning II
        "F104",  // Lockheed F-104 Starfighter
        "F117",  // Lockheed F-117 Nighthawk
        "JAGR",  // SEPECAT Jaguar
        "K50",   // KAI T-50 / A-50 Golden Eagle
        "KFIR",  // IAI Kfir
        "MYS4",  // Dassault Mystère IV
        "MIRA",  // Dassault Mirage III
        "MRF1",  // Dassault Mirage F1
        "RFAL",  // Dassault Rafale
        "SMB2",  // Dassault Super Mystère B2
        "SB35",  // Saab 35 Draken
        "SB37",  // Saab 37 Viggen
        "SGCD",  // Saab JAS 39C Gripen
        "SGEF",  // Saab JAS 39E Gripen
        "TOR",   // Panavia Tornado

        // ── Soviet / Russian / Chinese fighters, attack & bombers ──
        "MG17",  // Shenyang J-5 / MiG-17
        "MG19",  // Shenyang J-6 / MiG-19
        "MG21",  // Chengdu J-7 / MiG-21
        "MG23",  // Mikoyan MiG-23
        "MG25",  // Mikoyan MiG-25
        "MG29",  // Mikoyan MiG-29
        "MG31",  // Mikoyan MiG-31
        "MG44",  // Mikoyan MiG 1.44
        "SU7",   // Sukhoi Su-7
        "SU17",  // Sukhoi Su-17
        "SU24",  // Sukhoi Su-24
        "SU25",  // Sukhoi Su-25
        "SU27",  // Sukhoi Su-27 / Shenyang J-11
        "SU57",  // Sukhoi Su-57 (T-50)
        "J10",   // Chengdu J-10
        "J20",   // Chengdu J-20
        "Q5",    // Nanchang/Hongdu Q-5 (A-5)
        "GJ11",  // Hongdu GJ-11 Sharp Sword (stealth UCAV)
        "JH7",   // Xian JH-7 Flounder
        "T22M",  // Tupolev Tu-22M Backfire (bomber)
        "TU22",  // Tupolev Tu-22 Blinder (bomber)
        "TU16",  // Tupolev Tu-16 Badger (bomber)
        "T160",  // Tupolev Tu-160 Blackjack (bomber)
        "TU95",  // Tupolev Tu-95 / Tu-142 Bear (bomber)
    ]

    /// True when a typecode is military — either the bundled table already
    /// classifies it `.mil`, or it's one of the known-miscoded designators
    /// above. `typecode` must be an uppercased ICAO designator (as produced
    /// by the table keys and `GuessOptions.normalizedIdent`).
    static func isMilitary(typecode: String, type: AircraftType?) -> Bool {
        type == .mil || miscoded.contains(typecode)
    }
}
