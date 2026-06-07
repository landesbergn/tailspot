//
//  IcaoRegistry.swift
//  Tailspot
//
//  Deterministic US ICAO 24-bit address <-> N-number conversion.
//  US civil registrations occupy the hex block A00001..ADF7C7; the
//  mapping is a fixed positional encoding (no data file needed). Used
//  to recover a tail number for US aircraft OpenSky has no record of,
//  and (separately) the FAA-registry fallback keys on the raw icao24.
//
import Foundation

nonisolated enum IcaoRegistry {
    private static let usLow: UInt32  = 0xA00001
    private static let usHigh: UInt32 = 0xADF7C7
    // N-number suffix alphabet: A-Z minus I and O (ambiguous with 1/0).
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")

    /// True if this icao24 is in the US civil block.
    static func isUS(icao24: String) -> Bool {
        guard let v = UInt32(icao24.trimmingCharacters(in: .whitespaces), radix: 16) else { return false }
        return v >= usLow && v <= usHigh
    }

    /// US N-number for an icao24, or nil if outside the US block /
    /// unparseable. e.g. "a9eefa" -> "N7391E".
    static func nNumber(forIcao24 icao24: String) -> String? {
        guard let v = UInt32(icao24.trimmingCharacters(in: .whitespaces), radix: 16),
              v >= usLow, v <= usHigh else { return nil }
        var rem = Int(v - usLow)
        var n = "N"
        // Position 1: 1-5
        n += String(rem / 101711 + 1); rem %= 101711
        if rem < 601 { return n + suffix(rem) }
        rem -= 601
        n += String(rem / 10111); rem %= 10111
        if rem < 601 { return n + suffix(rem) }
        rem -= 601
        n += String(rem / 951); rem %= 951
        if rem < 601 { return n + suffix(rem) }
        rem -= 601
        n += String(rem / 35); rem %= 35
        if rem < 25 { return n + (rem > 0 ? String(alphabet[rem - 1]) : "") }
        return n + String(rem - 25)
    }

    /// 0 -> "", 1..24 -> single letter, 25..600 -> two letters.
    private static func suffix(_ r: Int) -> String {
        if r == 0 { return "" }
        let x = r - 1
        if x < 24 { return String(alphabet[x]) }
        let y = x - 24
        let first = alphabet[y / 25]
        let secondIdx = y % 25
        return secondIdx == 0 ? String(first) : String(first) + String(alphabet[secondIdx - 1])
    }
}
