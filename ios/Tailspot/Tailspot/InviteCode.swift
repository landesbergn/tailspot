//
//  InviteCode.swift
//  Tailspot
//
//  Invite-code parsing and normalization (section 9.1: "Codes are
//  unguessable (about 40 bits)... 8 characters from a 31-symbol alphabet")
//  and the universal-link shape (section 11: "https://tailspot.app/c/CODE.
//  One shape, no query parameters."). `nonisolated` — pure, no networking,
//  no UI. Used by both the Join-with-code entry field and `onOpenURL`.
//

import Foundation

nonisolated enum InviteCode {
    /// A-Z minus the visually-ambiguous I, L, O, plus digits 2-9 (0 and 1
    /// dropped for the same reason). 23 letters + 8 digits = 31 symbols,
    /// ~40 bits over 8 characters (log2(31^8) ≈ 39.6).
    static let alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
    static let codeLength = 8

    private static let alphabetSet = Set(alphabet)

    /// Uppercases and strips every whitespace/newline character plus dashes
    /// (how someone naturally types or pastes a code — "k7m4 qd2x",
    /// "K7M4-QD2X", or a line-wrapped paste out of Messages), then validates
    /// every remaining character is in the alphabet and the length is
    /// exactly 8. The strip set matches the backend's `[\s-]` exactly, so a
    /// paste the server would accept never fails on the phone first:
    /// `CharacterSet.whitespacesAndNewlines` covers tab, newline, carriage
    /// return and the non-breaking space a rich-text paste can carry.
    /// Deliberately does NOT remap ambiguous input (e.g. typed "0" → "O"):
    /// the alphabet excludes 0/1/I/L/O precisely so a typo is rejected
    /// rather than silently corrected into a different, valid-looking code.
    static func normalize(_ raw: String) -> String? {
        let stripped = String(raw.uppercased().unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "-"
        })
        guard stripped.count == codeLength,
              stripped.allSatisfy({ alphabetSet.contains($0) }) else {
            return nil
        }
        return stripped
    }

    /// Accepts `https://tailspot.app/c/CODE` and `https://www.tailspot.app/c/CODE`,
    /// with or without a trailing slash; rejects any other host or path
    /// shape. The extracted code is run through `normalize` so a
    /// mixed-case or otherwise malformed path segment is caught the same
    /// way typed input is.
    static func parse(url: URL) -> String? {
        guard let host = url.host?.lowercased(),
              host == "tailspot.app" || host == "www.tailspot.app" else {
            return nil
        }
        let segments = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count == 2, segments[0] == "c" else { return nil }
        return normalize(String(segments[1]))
    }

    /// The canonical share link for an already-normalized code.
    static func inviteURL(for code: String) -> URL {
        URL(string: "https://tailspot.app/c/\(code)")!
    }
}
