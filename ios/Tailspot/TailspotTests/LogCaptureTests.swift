//
//  LogCaptureTests.swift
//  TailspotTests
//
//  Verifies the LogCapture file writer with an injected fixture source
//  (the OSLogStore path is device/integration-verified, not unit-tested).
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Log capture")
@MainActor
struct LogCaptureTests {

    private let t0 = Date(timeIntervalSince1970: 1_715_000_000)

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("logcap-\(UUID().uuidString).log")
    }

    @Test func writesEntriesInOrderWithCategoryAndLevel() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let entries = [
            CapturedLogEntry(date: t0, category: "ui", level: "notice", message: "recording started"),
            CapturedLogEntry(date: t0.addingTimeInterval(1), category: "adsb", level: "error", message: "metadata lookup failed"),
        ]
        let cap = LogCapture(source: { _ in entries })
        cap.start(at: url, since: t0)
        let written = cap.stop()

        #expect(written == url)
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)
        #expect(lines[0].contains("[ui]"))
        #expect(lines[0].contains("recording started"))
        #expect(lines[1].contains("[adsb]"))
        #expect(lines[1].contains("metadata lookup failed"))
        // Order preserved.
        #expect(text.range(of: "started")!.lowerBound < text.range(of: "lookup")!.lowerBound)
    }

    @Test func stopWithoutStartWritesNothing() {
        let url = tempURL()
        let cap = LogCapture(source: { _ in
            [CapturedLogEntry(date: self.t0, category: "ui", level: "info", message: "x")]
        })
        #expect(cap.stop() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func boundsToNewestMaxEntries() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let many = (0..<100).map {
            CapturedLogEntry(date: t0.addingTimeInterval(Double($0)),
                             category: "ui", level: "info", message: "line\($0)")
        }
        let cap = LogCapture(source: { _ in many }, maxEntries: 10)
        cap.start(at: url, since: t0)
        cap.stop()

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 10)
        #expect(lines.first!.contains("line90"))   // keeps the newest tail
        #expect(lines.last!.contains("line99"))
    }

    @Test func everyLineIsNewlineTerminatedForCrashTolerance() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cap = LogCapture(source: { _ in
            [CapturedLogEntry(date: self.t0, category: "ui", level: "info", message: "only")]
        })
        cap.start(at: url, since: t0)
        cap.stop()
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasSuffix("\n"))   // a truncated tail still leaves complete lines
    }
}
