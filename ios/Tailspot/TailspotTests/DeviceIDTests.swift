//
//  DeviceIDTests.swift
//  TailspotTests
//
//  Covers the device-id resolution/migration logic against an in-memory fake
//  durable store (the real Keychain is process-global and can't be isolated
//  per parallel suite), plus one probe-gated real-Keychain assertion for the
//  new status-returning read.
//

import Testing
import Foundation
import Security
@testable import Tailspot

/// In-memory durable store for DeviceID logic tests. Shared with AnalyticsTests
/// so the analytics distinct_id tests also stay off the real Keychain.
nonisolated final class FakeDeviceIDStore: DeviceIDDurableStore {
    enum Mode { case normal, unavailable }
    var stored: String?
    var mode: Mode
    private(set) var writeCount = 0

    init(stored: String? = nil, mode: Mode = .normal) {
        self.stored = stored
        self.mode = mode
    }

    func read() -> DeviceIDDurableResult {
        if mode == .unavailable { return .unavailable }
        if let stored, !stored.isEmpty { return .found(stored) }
        return .absent
    }

    @discardableResult func write(_ value: String) -> Bool {
        if mode == .unavailable { return false }
        stored = value
        writeCount += 1
        return true
    }
}

@Suite("DeviceID")
struct DeviceIDTests {
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "deviceid-test-\(UUID().uuidString)")!
    }
    private let key = "tailspot.account.deviceId"

    /// Existing install: the id is in the UserDefaults mirror. It's returned and
    /// copied into the Keychain exactly once (the migration write-through).
    @Test func mirrorPresentReturnsItAndMigratesOnce() {
        let defaults = isolatedDefaults()
        let id = "legacy-\(UUID().uuidString)"
        defaults.set(id, forKey: key)
        let fake = FakeDeviceIDStore()

        let first = DeviceID.current(mirror: defaults, durable: fake)
        #expect(first == id)
        #expect(fake.stored == id)
        #expect(fake.writeCount == 1)

        let second = DeviceID.current(mirror: defaults, durable: fake)
        #expect(second == id)
        #expect(fake.writeCount == 1)   // one-time migration, not re-written each launch
    }

    /// Reinstall: the mirror is wiped but the Keychain survived → restored.
    @Test func reinstallRestoresFromDurable() {
        let defaults = isolatedDefaults()
        let id = "survived-\(UUID().uuidString)"
        let fake = FakeDeviceIDStore(stored: id)

        let resolved = DeviceID.current(mirror: defaults, durable: fake)
        #expect(resolved == id)
        #expect(defaults.string(forKey: key) == id)
    }

    /// Genuine first launch: both absent → generate once, persist to both, stable.
    @Test func bothAbsentGeneratesAndPersists() {
        let defaults = isolatedDefaults()
        let fake = FakeDeviceIDStore()

        let id = DeviceID.current(mirror: defaults, durable: fake)
        #expect(!id.isEmpty)
        #expect(defaults.string(forKey: key) == id)
        #expect(fake.stored == id)

        #expect(DeviceID.current(mirror: defaults, durable: fake) == id)
    }

    /// Locked Keychain with an empty mirror must NOT persist a new id (R3).
    @Test func lockedDurableDoesNotPersist() {
        let defaults = isolatedDefaults()
        let fake = FakeDeviceIDStore(mode: .unavailable)

        let id = DeviceID.current(mirror: defaults, durable: fake)
        #expect(!id.isEmpty)                          // returns a transient id
        #expect(defaults.string(forKey: key) == nil) // persists nothing
        #expect(fake.stored == nil)
    }

    @Test func currentIfPresentNilWhenAbsent() {
        let defaults = isolatedDefaults()
        #expect(DeviceID.currentIfPresent(mirror: defaults, durable: FakeDeviceIDStore()) == nil)
    }

    @Test func currentIfPresentReturnsValueAndRestores() {
        let defaults = isolatedDefaults()
        let id = "present-\(UUID().uuidString)"
        let fake = FakeDeviceIDStore(stored: id)
        #expect(DeviceID.currentIfPresent(mirror: defaults, durable: fake) == id)
        #expect(defaults.string(forKey: key) == id)
    }

    @Test func setPersistsToBoth() {
        let defaults = isolatedDefaults()
        let fake = FakeDeviceIDStore()
        let id = "server-\(UUID().uuidString)"
        DeviceID.set(id, mirror: defaults, durable: fake)
        #expect(defaults.string(forKey: key) == id)
        #expect(fake.stored == id)
    }

    // One real-Keychain assertion for the new status-returning read, on a unique
    // account so it never touches the real "deviceId". Probe-gated: CI sim clones
    // have no keychain and error on every SecItemAdd.
    private static let keychainAvailable: Bool = {
        let probe = "tailspot.test.deviceid.probe.\(UUID().uuidString)"
        let ok = KeychainStore.save(secret: "probe", account: probe)
        KeychainStore.delete(account: probe)
        return ok
    }()

    @Test func loadWithStatusDistinguishesFoundFromNotFound() {
        guard Self.keychainAvailable else { return }
        let account = "tailspot.test.deviceid.\(UUID().uuidString)"
        KeychainStore.save(secret: "abc", account: account)
        let found = KeychainStore.loadWithStatus(account: account)
        #expect(found.value == "abc")
        #expect(found.status == errSecSuccess)

        KeychainStore.delete(account: account)
        let gone = KeychainStore.loadWithStatus(account: account)
        #expect(gone.value == nil)
        #expect(gone.status == errSecItemNotFound)
    }
}
