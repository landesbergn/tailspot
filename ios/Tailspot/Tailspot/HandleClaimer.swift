//
//  HandleClaimer.swift
//  Tailspot
//
//  The one claim round-trip behind every "change / pick your handle" surface:
//  the Profile + Settings edit sheet (HandleEditSheet) and the Challenges
//  claim card (HandleClaimCard). Register → PUT handle → persist locally →
//  identify, with the result mapped to something a view can show.
//
//  Onboarding keeps its own copy on purpose: its failure path finishes
//  onboarding, which none of these surfaces do.
//
//  Unlike the old Settings save, a network failure does NOT persist the
//  handle locally. Keeping an unsent handle on the phone is how a device ends
//  up showing a name the server never recorded (the blue_hour strand,
//  2026-09-29); here the user keeps their typed text and can try again.
//

import Foundation
import os

/// Handle format, mirrored from the backend's HANDLE_RE: 3–20 characters of
/// letters, digits or underscore. The server re-checks; this only drives the
/// Save button.
nonisolated enum HandleRules {
    static let lengthRange = 3...20

    static func isValid(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard lengthRange.contains(t.count) else { return false }
        // ASCII only, like the server regex: `Character.isLetter` would pass
        // "é" and the save would come back 422.
        return t.unicodeScalars.allSatisfy { s in
            s.isASCII && (CharacterSet.alphanumerics.contains(s) || s == "_")
        }
    }
}

enum HandleClaimOutcome: Equatable {
    case saved(String)
    case taken(String)
    case notAllowed(String)
    case failed

    /// Inline copy for the non-success cases (nil on success).
    var message: String? {
        switch self {
        case .saved: return nil
        case .taken(let h): return "@\(h) is taken. Try another."
        case .notAllowed(let h): return "@\(h) isn't allowed. Try another."
        case .failed: return "Couldn't save. Check your connection."
        }
    }
}

@MainActor
struct HandleClaimer {
    typealias Report = (String, [String: AnalyticsValue]) -> Void
    typealias Identify = (String, String) -> Void

    var client: any HandleClaiming = TailspotAccountClient()
    var defaults: UserDefaults = .standard
    var report: Report = { Analytics.capture($0, $1) }
    var identify: Identify = { Analytics.identify($0, handle: $1) }

    /// Claim `raw` (trimmed) for this device. `source` tags `handle_claimed`
    /// ("profile", "settings", "challenge_join", "challenge_create").
    func claim(_ raw: String, source: String) async -> HandleClaimOutcome {
        let handle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let deviceId = try await client.ensureRegistered()
            try await client.claimHandle(handle)
            // Both keys: the displayed handle and the server confirmation, so
            // HandleSyncer sees them equal and stays idle.
            defaults.set(handle, forKey: SpotterHandle.storageKey)
            defaults.set(handle, forKey: SpotterHandle.confirmedKey)
            identify(deviceId, handle)
            report("handle_claimed", ["result": .string("success"), "source": .string(source)])
            return .saved(handle)
        } catch AccountError.handleTaken {
            report("handle_claimed", ["result": .string("taken"), "source": .string(source)])
            return .taken(handle)
        } catch AccountError.handleNotAllowed {
            report("handle_claimed", ["result": .string("not_allowed"), "source": .string(source)])
            return .notAllowed(handle)
        } catch {
            Log.ui.error("HandleClaimer(\(source, privacy: .public)): claim failed: \(error, privacy: .public)")
            report("handle_claimed", ["result": .string("failed"), "source": .string(source)])
            return .failed
        }
    }
}
