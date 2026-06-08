//
//  ReplayRecorder.swift
//  Tailspot
//
//  Records sensor + ADS-B traces during a field session so we can
//  replay them offline and validate identification / lock-on / future
//  visual-confirmation tweaks without standing under an approach path.
//  Phase 0 main infrastructure per PLAN.md §3.0.
//
//  Format: JSONL (one JSON object per line). One `session-start`
//  header line, then one `tick` line per recorded moment. JSONL is
//  used (instead of one big array) so a crash mid-session leaves a
//  partial-but-valid file — every complete line is independently
//  decodable.
//
//  The recorder is intentionally MainActor and synchronous on the
//  write path. At 1 Hz the per-tick payload is small (a handful of
//  doubles + up to a few dozen aircraft snapshots) so a blocking
//  FileHandle.write off the main thread isn't worth the complexity
//  yet.
//
//  Files land in `Documents/replays/replay-<utc>.jsonl`. Retrieve
//  with:
//
//    xcrun devicectl device copy from \
//      --device <udid> \
//      --domain-type appDataContainer \
//      --domain-identifier com.landesberg.Tailspot \
//      --source Documents/replays \
//      --destination ./replays
//
//  The --domain-type / --domain-identifier pair is required —
//  without them devicectl doesn't know which app's container to look
//  in and the call fails with a (cryptic) error.
//

import Foundation
import Combine
import CoreGraphics
import os

// MARK: - Event model

/// One line in the JSONL file. The `type` discriminator lets us add
/// more event variants later without breaking decoders written today.
///
/// `nonisolated` because this is a pure-data value type that flows
/// across actor boundaries (recorder is MainActor; decoder is called
/// from anywhere). Matches the repo convention documented in
/// CLAUDE.md "MainActor default isolation."
nonisolated enum ReplayEvent: Equatable, Sendable {
    case sessionStart(SessionStart)
    case tick(Tick)
    /// User explicitly pinned the lock to a specific aircraft via tap.
    /// Recorded so the analyzer's lock-on path matches what live actually
    /// did — without these, the analyzer would compute center-driven
    /// locks and diverge whenever tap-to-ID was used.
    case tapPin(TapPin)
    /// User cleared the pin (tap-same-plane toggle, tap-empty-sky, or
    /// pinned plane left visibility). Separate from `tapPin` rather than
    /// folded into a nil-icao form so the wire format is unambiguous.
    case unpin(Unpin)

    struct SessionStart: Codable, Equatable, Sendable {
        let timestamp: Date
        let appVersion: String
        let deviceModel: String
        /// Schema version. Bump when we change field meanings (renames
        /// are fine to ignore if you add coding keys). Decoders should
        /// refuse files newer than they know.
        let schemaVersion: Int
    }

    struct Tick: Codable, Equatable, Sendable {
        let timestamp: Date
        let sensor: SensorSnapshot
        let aircraft: [AircraftSnapshot]
    }

    struct TapPin: Codable, Equatable, Sendable {
        let timestamp: Date
        let icao24: String
        /// Screen location of the tap, in points, at the moment of the pin.
        /// Optional for back-compat — files recorded before the 3D-pinhole
        /// work carry icao only; the analyzer treats a tap-pin without a
        /// location as "this icao was confirmed visible" (today's behavior).
        /// When present it is pixel-exact ground truth for the projection
        /// and the eventual visual-confirmation work.
        let x: Double?
        let y: Double?

        init(timestamp: Date, icao24: String, x: Double? = nil, y: Double? = nil) {
            self.timestamp = timestamp
            self.icao24 = icao24
            self.x = x
            self.y = y
        }
    }

    struct Unpin: Codable, Equatable, Sendable {
        let timestamp: Date
    }

    struct SensorSnapshot: Codable, Equatable, Sendable {
        let latitude: Double?
        let longitude: Double?
        let altitudeMeters: Double?
        let horizontalAccuracyMeters: Double?
        let headingDeg: Double?
        let headingAccuracyDeg: Double?
        let pitchRad: Double
        let rollRad: Double
        let yawRad: Double
        let cameraElevationDeg: Double
        /// Camera zoom factor at the moment of capture (1.0 = no zoom).
        /// Optional for back-compat — recordings made before zoom shipped
        /// don't have this field; analyzer treats nil as 1.0. Synthesized
        /// `Codable` tolerates the missing key because the property is
        /// `Optional`.
        let zoomFactor: Double?
        /// Device gravity vector (CMDeviceMotion.gravity) at capture, in the
        /// device frame. Optional for back-compat — files recorded before the
        /// 3D-pinhole work don't have it, and the analyzer falls back to
        /// roll = 0. When present it lets a recording reconstruct the exact
        /// live camera basis (heading + gravity → elevation + roll), which
        /// the flaky Euler `rollRad` can't provide near the portrait hold.
        let gravityX: Double?
        let gravityY: Double?
        let gravityZ: Double?

        init(
            latitude: Double?, longitude: Double?, altitudeMeters: Double?,
            horizontalAccuracyMeters: Double?, headingDeg: Double?,
            headingAccuracyDeg: Double?, pitchRad: Double, rollRad: Double,
            yawRad: Double, cameraElevationDeg: Double, zoomFactor: Double?,
            gravityX: Double? = nil, gravityY: Double? = nil, gravityZ: Double? = nil
        ) {
            self.latitude = latitude
            self.longitude = longitude
            self.altitudeMeters = altitudeMeters
            self.horizontalAccuracyMeters = horizontalAccuracyMeters
            self.headingDeg = headingDeg
            self.headingAccuracyDeg = headingAccuracyDeg
            self.pitchRad = pitchRad
            self.rollRad = rollRad
            self.yawRad = yawRad
            self.cameraElevationDeg = cameraElevationDeg
            self.zoomFactor = zoomFactor
            self.gravityX = gravityX
            self.gravityY = gravityY
            self.gravityZ = gravityZ
        }
    }

    /// A flat snapshot of the fields we want to replay through the
    /// engine. Deliberately separate from `Aircraft` (which has a
    /// positional OpenSky-shaped Decodable) so the replay format is
    /// stable even if Aircraft's decoder changes.
    struct AircraftSnapshot: Codable, Equatable, Sendable {
        let icao24: String
        let callsign: String?
        let originCountry: String
        let latitude: Double
        let longitude: Double
        let altitudeMeters: Double
        let velocityMps: Double?
        let trackDeg: Double?
        let onGround: Bool
        let positionTimestamp: Date?
    }
}

nonisolated extension ReplayEvent.AircraftSnapshot {
    /// Build a snapshot from a live `Aircraft`. Used at record time.
    init(_ a: Aircraft) {
        self.icao24 = a.icao24
        self.callsign = a.callsign
        self.originCountry = a.originCountry
        self.latitude = a.latitude
        self.longitude = a.longitude
        self.altitudeMeters = a.altitudeMeters
        self.velocityMps = a.velocityMps
        self.trackDeg = a.trackDeg
        self.onGround = a.onGround
        self.positionTimestamp = a.positionTimestamp
    }
}

// MARK: - JSONL coding

nonisolated extension ReplayEvent: Codable {
    /// Discriminator + payload format on the wire:
    ///   {"type":"session-start", ...session fields...}
    ///   {"type":"tick", ...tick fields...}
    /// Keeping the discriminator flat (rather than nesting under a
    /// "payload" key) makes individual lines easier to read by eye.
    private enum CodingKeys: String, CodingKey { case type }
    private enum Kind: String, Codable {
        case sessionStart = "session-start"
        case tick
        case tapPin = "tap-pin"
        case unpin
    }

    init(from decoder: Decoder) throws {
        let kindContainer = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try kindContainer.decode(Kind.self, forKey: .type)
        switch kind {
        case .sessionStart:
            self = .sessionStart(try SessionStart(from: decoder))
        case .tick:
            self = .tick(try Tick(from: decoder))
        case .tapPin:
            self = .tapPin(try TapPin(from: decoder))
        case .unpin:
            self = .unpin(try Unpin(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sessionStart(let s):
            try c.encode(Kind.sessionStart, forKey: .type)
            try s.encode(to: encoder)
        case .tick(let t):
            try c.encode(Kind.tick, forKey: .type)
            try t.encode(to: encoder)
        case .tapPin(let p):
            try c.encode(Kind.tapPin, forKey: .type)
            try p.encode(to: encoder)
        case .unpin(let u):
            try c.encode(Kind.unpin, forKey: .type)
            try u.encode(to: encoder)
        }
    }
}

/// Reader for files written by `ReplayRecorder`. Decodes line-by-line
/// so a partial (crash-truncated) trailing line is silently dropped
/// instead of failing the whole parse. Used by tests today; future
/// engine replay will reuse it.
nonisolated enum ReplayJSONL {
    /// Encoder/decoder pair pinned for both directions. ISO8601 dates
    /// keep the wire format human-readable.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Encode a single event as one JSONL line (UTF-8 JSON + trailing newline).
    static func line(for event: ReplayEvent) throws -> Data {
        var data = try encoder.encode(event)
        data.append(0x0A) // newline
        return data
    }

    /// Decode every complete line. A trailing partial line (no newline)
    /// is dropped silently — matches what a crash mid-write leaves
    /// behind, and lets the rest of the session still be replayable.
    /// Blank lines are ignored.
    static func decode(_ data: Data) throws -> [ReplayEvent] {
        guard let s = String(data: data, encoding: .utf8) else { return [] }
        var lines = s.split(separator: "\n", omittingEmptySubsequences: true)
        // If the source doesn't end with \n, the last segment is a
        // partial write (e.g., process killed mid-line). Drop it.
        if !s.hasSuffix("\n"), !lines.isEmpty {
            lines.removeLast()
        }
        return try lines.map { try decoder.decode(ReplayEvent.self, from: Data($0.utf8)) }
    }
}

// MARK: - Recorder

@MainActor
final class ReplayRecorder: ObservableObject {
    /// Schema version baked into every session-start. Bump when an
    /// existing field's meaning changes.
    static let schemaVersion = 1

    @Published private(set) var isRecording = false
    @Published private(set) var eventCount = 0
    @Published private(set) var currentFileURL: URL?

    private var fileHandle: FileHandle?

    /// Start a new recording. If `at` is nil, the file is created at
    /// `Documents/replays/replay-<utc>.jsonl`. Tests pass an explicit
    /// URL pointing into a temp directory. Throws if a recording is
    /// already in progress or the file can't be created.
    @discardableResult
    func start(at url: URL? = nil,
               appVersion: String = ReplayRecorder.bundleShortVersion(),
               deviceModel: String = ReplayRecorder.currentDeviceModel(),
               now: Date = Date()) throws -> URL {
        if isRecording { throw RecorderError.alreadyRecording }

        let target: URL
        if let url {
            target = url
        } else {
            target = try Self.makeDefaultURL(now: now)
        }

        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Truncate any existing file with the same path so a re-run
        // starts cleanly. In production we use a timestamped name so
        // collisions effectively can't happen; this is mostly for tests.
        FileManager.default.createFile(atPath: target.path, contents: nil)

        let handle = try FileHandle(forWritingTo: target)
        // Move to end in case someone reused the URL.
        try handle.seekToEnd()

        self.fileHandle = handle
        self.currentFileURL = target
        self.isRecording = true
        self.eventCount = 0

        try writeLine(.sessionStart(.init(
            timestamp: now,
            appVersion: appVersion,
            deviceModel: deviceModel,
            schemaVersion: Self.schemaVersion
        )))

        Log.ui.notice("Replay recording started at \(target.path, privacy: .public)")
        return target
    }

    /// Append one tick. No-op when not recording so callers can safely
    /// fire from a timer without checking isRecording themselves.
    func recordTick(_ tick: ReplayEvent.Tick) {
        guard isRecording else { return }
        writeOrStop(.tick(tick))
    }

    /// Append a tap-pin event. Called from `ContentView.handleTap` when
    /// the user explicitly pins onto a plane.
    func recordTapPin(icao24: String, at now: Date = Date(), tapPoint: CGPoint? = nil) {
        guard isRecording else { return }
        writeOrStop(.tapPin(.init(
            timestamp: now, icao24: icao24,
            x: tapPoint.map { Double($0.x) },
            y: tapPoint.map { Double($0.y) }
        )))
    }

    /// Append an unpin event. Called when the user clears the pin
    /// (tap-empty-sky, tap-same-plane-toggle, or the pinned plane
    /// leaving visibility).
    func recordUnpin(at now: Date = Date()) {
        guard isRecording else { return }
        writeOrStop(.unpin(.init(timestamp: now)))
    }

    /// Common write+errstop helper. A failed write usually means the
    /// disk filled or the file descriptor died — surface and stop;
    /// silently dropping events would make the file deceptive.
    private func writeOrStop(_ event: ReplayEvent) {
        do {
            try writeLine(event)
        } catch {
            Log.ui.error("Replay write failed: \(error.localizedDescription, privacy: .public)")
            stop()
        }
    }

    /// Close the file handle and clear recording state. Safe to call
    /// when not recording (no-op).
    func stop() {
        guard isRecording else { return }
        try? fileHandle?.close()
        fileHandle = nil
        isRecording = false
        Log.ui.notice("Replay recording stopped (\(self.eventCount) events)")
    }

    enum RecorderError: Error, Equatable {
        case alreadyRecording
    }

    // MARK: - Internals

    private func writeLine(_ event: ReplayEvent) throws {
        guard let handle = fileHandle else { return }
        let data = try ReplayJSONL.line(for: event)
        try handle.write(contentsOf: data)
        eventCount += 1
    }

    private static func makeDefaultURL(now: Date) throws -> URL {
        let docs = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        // Colons are filesystem-safe on iOS but not on macOS — strip
        // them so a copied-off file works everywhere.
        let stamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "")
        return docs
            .appendingPathComponent("replays", isDirectory: true)
            .appendingPathComponent("replay-\(stamp).jsonl", isDirectory: false)
    }

    nonisolated static func bundleShortVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Find the most-recently-modified `.jsonl` in the standard
    /// `Documents/replays/` directory. Returns nil if the directory
    /// doesn't exist (no recording made yet) or contains no `.jsonl`
    /// files. Used by the "Analyze last recording" debug row in
    /// ContentView so the user can immediately inspect what the
    /// engine saw without going through a file picker.
    nonisolated static func mostRecentRecording() -> URL? {
        let fm = FileManager.default
        guard let docs = try? fm.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return nil }
        let dir = docs.appendingPathComponent("replays", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return entries
            .filter { $0.pathExtension == "jsonl" }
            .sorted { lhs, rhs in
                let lm = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rm = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lm > rm
            }
            .first
    }

    /// Coarse device model identifier (e.g., "iPhone17,3"). Recorded so
    /// a replay file alone is enough to interpret heading/pitch noise
    /// characteristics that vary by hardware.
    nonisolated static func currentDeviceModel() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        // utsname.machine is a fixed-size C-char tuple — bridge via
        // its address to read the null-terminated string. Compute the
        // capacity into a local first; reading sysinfo.machine inside
        // the &-pointer block triggers exclusive-access overlap.
        let size = MemoryLayout.size(ofValue: sysinfo.machine)
        return withUnsafePointer(to: &sysinfo.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: size) {
                String(cString: $0)
            }
        }
    }
}
