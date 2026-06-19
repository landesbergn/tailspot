//
//  LogCapture.swift
//  Tailspot
//
//  Mirrors a recording session's os.Logger output to a `.log` file paired
//  with the replay `.jsonl`, so a recorded session carries the app's own
//  logs for offline diagnosis (retires PLAN §9 #1 — "capture os_log from
//  the device").
//
//  os.Logger output can't be teed at the call site without touching every
//  Log.* site, so entries are pulled back from the unified log via
//  OSLogStore at stop. The entry source is injectable: production uses
//  OSLogStore (current-process scope, no special entitlement on iOS 15+);
//  tests inject a fixture so the writer is verified without the unified log.
//
//  Best-effort by contract: capture must never break a recording, so every
//  failure path is swallowed (logged, not thrown).
//

import Foundation
import OSLog

/// One captured log entry — the unit LogCapture writes. Decoupled from
/// `OSLogEntryLog` so the writer is testable with fixtures.
nonisolated struct CapturedLogEntry: Equatable, Sendable {
    let date: Date
    let category: String
    let level: String
    let message: String
}

@MainActor
final class LogCapture {
    /// Returns this process's subsystem log entries since `since`.
    typealias EntrySource = (_ since: Date) -> [CapturedLogEntry]

    private let source: EntrySource
    /// Cap so a long session can't write an unbounded file. The newest
    /// `maxEntries` are kept — the tail is the most relevant context for a
    /// miss diagnosed at the end of a session.
    private let maxEntries: Int

    private var startDate: Date?
    private(set) var fileURL: URL?

    init(source: @escaping EntrySource = LogCapture.osLogStoreSource,
         maxEntries: Int = 5000) {
        self.source = source
        self.maxEntries = maxEntries
    }

    /// Begin a capture window. `url` is the paired `.log` path; `since` is
    /// the recording-start instant (the lower bound of the log query).
    func start(at url: URL, since: Date) {
        startDate = since
        fileURL = url
    }

    /// Pull the window's entries and write them to the file. No-op (returns
    /// nil) if start was never called. Clears state so the instance reuses.
    @discardableResult
    func stop() -> URL? {
        defer { startDate = nil; fileURL = nil }
        guard let startDate, let fileURL else { return nil }
        let entries = Array(source(startDate).suffix(maxEntries))
        // Each line newline-terminated so any prefix up to a `\n` is a
        // complete record — a file truncated by a crash stays readable.
        let text = entries.map { Self.format($0) + "\n" }.joined()
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data(text.utf8).write(to: fileURL)
            return fileURL
        } catch {
            Log.ui.error("Log capture write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// One line per entry: ISO time · level · `[category]` · message.
    static func format(_ e: CapturedLogEntry) -> String {
        let stamp = Self.isoFormatter.string(from: e.date)
        let level = e.level.padding(toLength: 7, withPad: " ", startingAt: 0)
        return "\(stamp)  \(level)  [\(e.category)] \(e.message)"
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // MARK: - OSLogStore source (production)

    /// Pulls os.Logger entries for our subsystem from the unified log since
    /// `since`. Best-effort — returns `[]` on any failure (OSLogStore can be
    /// unavailable or empty depending on the platform/state); capture must
    /// never throw into the recording path.
    nonisolated static func osLogStoreSource(since: Date) -> [CapturedLogEntry] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: since)
            let subsystem = "com.landesberg.tailspot"
            var out: [CapturedLogEntry] = []
            for case let log as OSLogEntryLog in try store.getEntries(at: position)
            where log.subsystem == subsystem {
                out.append(.init(
                    date: log.date,
                    category: log.category,
                    level: levelName(log.level),
                    message: log.composedMessage))
            }
            return out
        } catch {
            return []
        }
    }

    private nonisolated static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .undefined: return "—"
        case .debug:     return "debug"
        case .info:      return "info"
        case .notice:    return "notice"
        case .error:     return "error"
        case .fault:     return "fault"
        @unknown default: return "?"
        }
    }
}
