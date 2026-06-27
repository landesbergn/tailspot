//
//  DeviceID.swift
//  Tailspot
//
//  The canonical backend device identifier (TailspotAccountClient). It is also
//  the value we `identify()` the PostHog SDK to (Analytics.identify), so the
//  analytics person resolves to the same id as the backend device — but the SDK
//  itself owns the live analytics distinct_id; this type is no longer read as
//  the distinct_id directly. Stored in the Keychain so it survives app
//  delete/reinstall — UserDefaults is wiped on uninstall, which minted a new
//  id on every reinstall and fragmented one device into many PostHog persons.
//
//  A UserDefaults "mirror" is kept as the always-available fast read; the
//  Keychain is the survives-reinstall source of truth. Resolution order:
//  mirror → Keychain → generate. In production the id now originates ONLY from
//  the server (ensureRegistered writes it through `set`); the minting fallback
//  in `current()` is retained for completeness/tests but no production path
//  calls it, so the app never invents a local id that registration must swap.
//
//  nonisolated to match KeychainStore / TailspotAccountClient; the read API is
//  synchronous and non-throwing (a plain string read for the registration and
//  identify call sites).
//

import Foundation
import Security

/// Result of reading the durable (Keychain) store. Distinguishes a genuine
/// absence (safe to generate) from a locked/unavailable read (defer — a new id
/// here would mint a duplicate identity).
nonisolated enum DeviceIDDurableResult: Equatable {
    case found(String)
    case absent
    case unavailable
}

/// Durable backing store for the device id. A protocol seam so tests inject an
/// in-memory fake and never touch the process-global Keychain — which, unlike a
/// UserDefaults suite, cannot be isolated per parallel test suite.
nonisolated protocol DeviceIDDurableStore {
    func read() -> DeviceIDDurableResult
    @discardableResult func write(_ value: String) -> Bool
}

/// Production durable store: the device id in the Keychain under account
/// "deviceId", co-located with the device token under the same service so the
/// two identity halves can't desync. Reuses `KeychainStore`.
nonisolated struct KeychainDeviceIDStore: DeviceIDDurableStore {
    static let account = "deviceId"

    func read() -> DeviceIDDurableResult {
        let (value, status) = KeychainStore.loadWithStatus(account: Self.account)
        if status == errSecSuccess, let value, !value.isEmpty { return .found(value) }
        if status == errSecItemNotFound { return .absent }
        // Any other status — errSecInteractionNotAllowed before first unlock, or
        // CI-clone entitlement errors — is "can't tell": defer, don't generate.
        return .unavailable
    }

    @discardableResult func write(_ value: String) -> Bool {
        KeychainStore.save(secret: value, account: Self.account)
    }
}

nonisolated enum DeviceID {
    /// The shared UserDefaults key — the same one TailspotAccountClient used, so
    /// for an existing install the mirror already holds the current id (which is
    /// what the one-time migration copies into the Keychain).
    static let mirrorKey = "tailspot.account.deviceId"
    /// One-time flag: set once the mirror value has been copied into the
    /// Keychain, so we don't re-write the Keychain on every launch.
    private static let migratedKey = "tailspot.account.deviceId.keychainSynced"

    private enum Resolution { case value(String); case absent; case unavailable }

    private static func resolve(mirror: UserDefaults,
                                durable: DeviceIDDurableStore) -> Resolution {
        // Mirror present (the common case, incl. every existing install): use it,
        // and one-time copy it into the Keychain — the migration write-through.
        if let v = mirror.string(forKey: mirrorKey), !v.isEmpty {
            if !mirror.bool(forKey: migratedKey), durable.write(v) {
                mirror.set(true, forKey: migratedKey)
            }
            return .value(v)
        }
        // Mirror absent — a fresh install, OR a reinstall that wiped UserDefaults.
        switch durable.read() {
        case .found(let v):
            // Reinstall restore: repopulate the mirror from the surviving Keychain.
            mirror.set(v, forKey: mirrorKey)
            mirror.set(true, forKey: migratedKey)
            return .value(v)
        case .absent:
            return .absent
        case .unavailable:
            return .unavailable
        }
    }

    /// The device id, generating and persisting one if none exists. Synchronous,
    /// non-throwing. No production caller today (the id comes from the server via
    /// `set`); retained for completeness and exercised by DeviceIDTests.
    static func current(mirror: UserDefaults = .standard,
                        durable: DeviceIDDurableStore = KeychainDeviceIDStore()) -> String {
        switch resolve(mirror: mirror, durable: durable) {
        case .value(let v):
            return v
        case .absent:
            let new = UUID().uuidString
            durable.write(new)
            mirror.set(new, forKey: mirrorKey)
            mirror.set(true, forKey: migratedKey)
            return new
        case .unavailable:
            // Defensive: protected data locked. The app has no pre-first-unlock
            // entry point today, so this is unreachable — but if one is ever
            // added, return a transient id WITHOUT persisting so a locked read
            // never enshrines a new/duplicate identity.
            return UUID().uuidString
        }
    }

    /// The persisted device id if one exists, without generating. Used by
    /// TailspotAccountClient's registration short-circuit (presence check).
    static func currentIfPresent(mirror: UserDefaults = .standard,
                                 durable: DeviceIDDurableStore = KeychainDeviceIDStore()) -> String? {
        if case .value(let v) = resolve(mirror: mirror, durable: durable) { return v }
        return nil
    }

    /// Persist `id` as the canonical device id (Keychain + mirror). Used by
    /// ensureRegistered to store the server-minted id, keeping the analytics
    /// distinct_id and the backend device id equal.
    static func set(_ id: String,
                    mirror: UserDefaults = .standard,
                    durable: DeviceIDDurableStore = KeychainDeviceIDStore()) {
        durable.write(id)
        mirror.set(id, forKey: mirrorKey)
        mirror.set(true, forKey: migratedKey)
    }
}
