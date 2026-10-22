//
//  MetricKitParserTests.swift
//  TailspotTests
//
//  MetricKit classes can't be constructed in a test, so these drive the parser
//  through the same JSON `MXDiagnostic.jsonRepresentation()` produces (shape
//  from Apple's documentation and WWDC20 "What's new in MetricKit" samples)
//  and through plain histogram buckets.
//

import Foundation
import Testing
@testable import Tailspot

@Suite("MetricKitParser")
struct MetricKitParserTests {

    // MARK: - Fixtures

    /// A nested frame chain: frame i's caller is subFrames[0].
    private static func frameChain(_ frames: [(String, Int, String)]) -> [String: Any] {
        var node: [String: Any]? = nil
        for (name, offset, uuid) in frames.reversed() {
            var f: [String: Any] = [
                "binaryName": name,
                "binaryUUID": uuid,
                "offsetIntoBinaryTextSegment": offset,
                "address": 0x1_0000_0000 + offset,
                "sampleCount": 1,
            ]
            if let node { f["subFrames"] = [node] }
            node = f
        }
        return node ?? [:]
    }

    private static let appUUID = "A1B2C3D4-0000-1111-2222-333344445555"
    private static let coreUUID = "F0E1D2C3-AAAA-BBBB-CCCC-DDDDEEEEFFFF"

    /// A crash on the SECOND thread (threadAttributed) with 10 frames, so the
    /// parser must both pick the right thread and truncate to 8.
    private static func crashJSON() -> Data {
        let otherThread: [String: Any] = [
            "threadAttributed": false,
            "callStackRootFrames": [frameChain([("libsystem_kernel.dylib", 0x10, coreUUID)])],
        ]
        var crashed: [(String, Int, String)] = [("libswiftCore.dylib", 0x3a4f0, coreUUID)]
        for i in 0..<9 { crashed.append(("Tailspot", 0x1e240 + i, appUUID)) }
        let crashedThread: [String: Any] = [
            "threadAttributed": true,
            "callStackRootFrames": [frameChain(crashed)],
        ]
        let json: [String: Any] = [
            "version": "1.0.0",
            "diagnosticMetaData": [
                "appVersion": "1.2.2",
                "appBuildVersion": "107",
                "osVersion": "iPhone OS 27.2 (24C55)",
                "deviceType": "iPhone17,2",
                "exceptionType": 6,
                "exceptionCode": 1,
                "signal": 5,
                "terminationReason": "Namespace SIGNAL, Code 5 Trace/BPT trap: 5 at /private/var/containers/Bundle/Application/ABC/Tailspot.app/Tailspot",
                "platformArchitecture": "arm64e",
            ],
            "callStackTree": [
                "callStackPerThread": true,
                "callStacks": [otherThread, crashedThread],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private static func hangJSON() -> Data {
        let json: [String: Any] = [
            "diagnosticMetaData": [
                "appVersion": "1.2.2",
                "appBuildVersion": "107",
                "osVersion": "iPhone OS 27.0.1 (24A350)",
                "hangDuration": "3.25 sec",
            ],
            "callStackTree": [
                "callStackPerThread": true,
                "callStacks": [[
                    "threadAttributed": true,
                    "callStackRootFrames": [frameChain([
                        ("SwiftData", 0x500, coreUUID),
                        ("Tailspot", 0x9abc, appUUID),
                    ])],
                ]],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func string(_ v: AnalyticsValue?) -> String? { v?.jsonValue as? String }
    private func int(_ v: AnalyticsValue?) -> Int? { v?.jsonValue as? Int }
    private func double(_ v: AnalyticsValue?) -> Double? { v?.jsonValue as? Double }
    private func bool(_ v: AnalyticsValue?) -> Bool? { v?.jsonValue as? Bool }

    // MARK: - Crash parsing

    @Test func crashFieldsComeFromTheDiagnosticNotTheDeliveringBuild() {
        let props = MetricKitParser.crashProperties(diagnosticJSON: Self.crashJSON())
        #expect(bool(props["parse_ok"]) == true)
        #expect(int(props["crash_count"]) == 1)
        #expect(int(props["exception_type"]) == 6)
        #expect(string(props["exception_name"]) == "EXC_BREAKPOINT")
        #expect(int(props["exception_code"]) == 1)
        #expect(int(props["signal"]) == 5)
        #expect(string(props["signal_name"]) == "SIGTRAP")
        #expect(string(props["diag_app_version"]) == "1.2.2")
        #expect(string(props["diag_app_build"]) == "107")
        #expect(string(props["diag_os_version"]) == "iPhone OS 27.2 (24C55)")
        #expect(props["raw_fallback"] == nil)
    }

    @Test func topFramesComeFromTheAttributedThreadTopFirstAndStopAtEight() {
        let parsed = MetricKitParser.parseDiagnostic(Self.crashJSON())
        #expect(parsed.topFrames.count == MetricKitParser.maxFrames)
        #expect(parsed.topFrames.first == "libswiftCore.dylib+0x3a4f0 (\(Self.coreUUID))")
        #expect(parsed.topFrames[1] == "Tailspot+0x1e240 (\(Self.appUUID))")
        #expect(parsed.topFrames.last == "Tailspot+0x1e246 (\(Self.appUUID))")
        #expect(!parsed.topFrames.contains { $0.hasPrefix("libsystem_kernel") })
    }

    /// The realistic shape: an uncaught-exception SIGABRT with 12 system
    /// frames (abort machinery, objc/C++ terminate, CoreFoundation) on top of
    /// the first Tailspot frame, then 7 more Tailspot frames.
    private static func systemOnTopCrashJSON() -> Data {
        var chain: [(String, Int, String)] = [
            ("libsystem_kernel.dylib", 0x1, coreUUID), ("libsystem_pthread.dylib", 0x2, coreUUID),
            ("libsystem_c.dylib", 0x3, coreUUID), ("libc++abi.dylib", 0x4, coreUUID),
            ("libc++abi.dylib", 0x5, coreUUID), ("libobjc.A.dylib", 0x6, coreUUID),
            ("libc++abi.dylib", 0x7, coreUUID), ("libc++abi.dylib", 0x8, coreUUID),
            ("libobjc.A.dylib", 0x9, coreUUID), ("CoreFoundation", 0xa, coreUUID),
            ("CoreData", 0xb, coreUUID), ("SwiftData", 0xc, coreUUID),
        ]
        for i in 0..<8 { chain.append(("Tailspot", 0x2000 + i, appUUID)) }
        let json: [String: Any] = [
            "diagnosticMetaData": ["appBuildVersion": "107", "signal": 6, "exceptionType": 10],
            "callStackTree": ["callStacks": [[
                "threadAttributed": true,
                "callStackRootFrames": [frameChain(chain)],
            ]]],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test func appFramesReachPastSystemFramesOnTop() {
        let parsed = MetricKitParser.parseDiagnostic(Self.systemOnTopCrashJSON(), appBinaryName: "Tailspot")
        // The top 8 never reach our code: that is exactly why app_frames exists.
        #expect(parsed.topFrames.count == MetricKitParser.maxFrames)
        #expect(!parsed.topFrames.contains { $0.hasPrefix("Tailspot+") })
        #expect(parsed.firstAppFrameIndex == 12)
        #expect(parsed.appFrames.count == MetricKitParser.maxAppFrames)
        #expect(parsed.appFrames.first == "Tailspot+0x2000 (\(Self.appUUID))")
        #expect(parsed.appFrames.last == "Tailspot+0x2004 (\(Self.appUUID))")

        let props = MetricKitParser.crashProperties(
            diagnosticJSON: Self.systemOnTopCrashJSON(), appBinaryName: "Tailspot")
        let appFrames = string(props["app_frames"])?.split(separator: "\n") ?? []
        #expect(appFrames.count == MetricKitParser.maxAppFrames)
        #expect(appFrames.first == "Tailspot+0x2000 (\(Self.appUUID))")
        #expect(int(props["first_app_frame_index"]) == 12)
        #expect(string(props["signal_name"]) == "SIGABRT")
    }

    @Test func noAppFrameMeansNoAppFramesField() {
        // Same stack, but the app binary is named something else: the walk
        // finds no app frame, so the field is absent rather than empty.
        let props = MetricKitParser.crashProperties(
            diagnosticJSON: Self.systemOnTopCrashJSON(), appBinaryName: "SomeOtherApp")
        #expect(bool(props["parse_ok"]) == true)
        #expect(props["app_frames"] == nil)
        #expect(props["first_app_frame_index"] == nil)
    }

    @Test func stackWalkIsBounded() {
        // A 300-deep system-only stack with our frame below the walk limit.
        var chain = (0..<300).map { ("libdeep.dylib", $0, Self.coreUUID) }
        chain.append(("Tailspot", 0x1, Self.appUUID))
        let tree: [String: Any] = ["callStacks": [[
            "threadAttributed": true, "callStackRootFrames": [Self.frameChain(chain)],
        ]]]
        let walk = MetricKitParser.walkAttributedStack(callStackTree: tree, appBinaryName: "Tailspot")
        #expect(walk.top.count == MetricKitParser.maxFrames)
        #expect(walk.app.isEmpty)
        #expect(walk.firstAppIndex == nil)
    }

    @Test func appBinaryNameComesFromInfoPlist() {
        // The test host is the app, so its executable is "Tailspot".
        #expect(MetricKitParser.appBinaryName == "Tailspot")
        let parsed = MetricKitParser.parseDiagnostic(Self.crashJSON())
        #expect(parsed.firstAppFrameIndex == 1)
        #expect(parsed.appFrames.first == "Tailspot+0x1e240 (\(Self.appUUID))")
    }

    @Test func terminationReasonIsTruncatedAndCarriesNoPaths() {
        let props = MetricKitParser.crashProperties(diagnosticJSON: Self.crashJSON())
        let reason = string(props["termination_reason"]) ?? ""
        #expect(reason.hasPrefix("Namespace SIGNAL, Code 5"))
        #expect(reason.hasSuffix("at Tailspot"))
        #expect(!reason.contains("/private"))
        #expect(!reason.contains(".app/"))
        // A lone slash in Apple's own wording is not a path and survives.
        #expect(reason.contains("Trace/BPT trap"))

        let long = String(repeating: "x", count: 500)
        let capped = MetricKitParser.crashProperties(
            diagnosticJSON: Self.crashJSON(),
            typed: .init(terminationReason: long))
        #expect(string(capped["termination_reason"])?.count == MetricKitParser.maxTerminationReasonLength)
    }

    @Test func typedValuesWinOverJSON() {
        let props = MetricKitParser.crashProperties(
            diagnosticJSON: Self.crashJSON(),
            typed: .init(appBuild: "108", exceptionType: 1, signal: 11))
        #expect(string(props["diag_app_build"]) == "108")
        #expect(string(props["exception_name"]) == "EXC_BAD_ACCESS")
        #expect(string(props["signal_name"]) == "SIGSEGV")
        // JSON still fills what the typed API lacks.
        #expect(string(props["diag_app_version"]) == "1.2.2")
    }

    @Test func binaryNamesNeverIncludePaths() {
        #expect(MetricKitParser.binaryName("/usr/lib/system/libsystem_kernel.dylib") == "libsystem_kernel.dylib")
        #expect(MetricKitParser.binaryName("Tailspot") == "Tailspot")
        #expect(MetricKitParser.binaryName(nil) == "?")
    }

    // MARK: - Malformed input

    @Test func malformedJSONIsParseFailureWithSmallRawFallback() {
        let garbage = Data(("{not json " + String(repeating: "/private/var/mobile/x ", count: 200)).utf8)
        let props = MetricKitParser.crashProperties(
            diagnosticJSON: garbage, typed: .init(appBuild: "107", signal: 11))
        #expect(bool(props["parse_ok"]) == false)
        #expect(props["top_frames"] == nil)
        let raw = string(props["raw_fallback"]) ?? ""
        #expect(!raw.isEmpty)
        #expect(raw.utf8.count <= MetricKitParser.maxRawFallbackBytes)
        #expect(!raw.contains("/private/var"))
        // The typed fields still make it out, so the crash isn't lost.
        #expect(string(props["diag_app_build"]) == "107")
        #expect(int(props["signal"]) == 11)
    }

    @Test func validJSONWithoutCallStackIsAlsoParseFailure() {
        let json = try! JSONSerialization.data(withJSONObject: [
            "diagnosticMetaData": ["appBuildVersion": "107"],
            "callStackTree": ["callStacks": []],
        ])
        let parsed = MetricKitParser.parseDiagnostic(json)
        #expect(parsed.parseOK == false)
        #expect(parsed.appBuild == "107")
    }

    @Test func eventStaysSmall() {
        let props = MetricKitParser.crashProperties(diagnosticJSON: Self.crashJSON())
        let bytes = props.values.reduce(0) { total, value in
            total + ((value.jsonValue as? String)?.utf8.count ?? 8)
        }
        #expect(bytes < 1500)
    }

    // MARK: - Hangs

    @Test func hangPropertiesParseDurationAndFrames() {
        let props = MetricKitParser.hangProperties(diagnosticJSON: Self.hangJSON())
        #expect(double(props["hang_duration_s"]) == 3.25)
        #expect(string(props["diag_app_build"]) == "107")
        #expect(bool(props["parse_ok"]) == true)
        let frames = string(props["top_frames"])?.split(separator: "\n") ?? []
        #expect(frames.count == 2)
        #expect(frames.last == "Tailspot+0x9abc (\(Self.appUUID))")
    }

    @Test func durationStrings() {
        #expect(MetricKitParser.durationSeconds("3.25 sec") == 3.25)
        #expect(MetricKitParser.durationSeconds("1500 ms") == 1.5)
        #expect(MetricKitParser.durationSeconds(NSNumber(value: 2)) == 2)
        #expect(MetricKitParser.durationSeconds("soon") == nil)
    }

    // MARK: - Histograms (hand-computed)

    private typealias B = MetricKitParser.Bucket

    /// Hang buckets in seconds: 3 hangs in 0.25-0.5s, 1 in 1-2s, 0 in 2-4s.
    private let hangs = [B(start: 0.25, end: 0.5, count: 3),
                         B(start: 1, end: 2, count: 1),
                         B(start: 2, end: 4, count: 0)]

    @Test func hangCountSumsBucketCounts() {
        #expect(MetricKitParser.totalCount(hangs) == 4)
    }

    @Test func hangTotalIsCountTimesMidpoint() {
        // 3 x 0.375 + 1 x 1.5 + 0 x 3 = 2.625. The legacy field reported
        // 0.5 + 2 + 4 = 6.5 for this same histogram.
        #expect(abs(MetricKitParser.weightedTotal(hangs) - 2.625) < 1e-9)
    }

    @Test func launchPercentilesAreCountWeighted() {
        // 8 launches at 100-200 ms, 1 at 1000-2000, 1 at 5000-6000 (ms).
        let launches = [B(start: 5000, end: 6000, count: 1),   // unsorted on purpose
                        B(start: 100, end: 200, count: 8),
                        B(start: 1000, end: 2000, count: 1)]
        // p50: rank 5 of 10 → the 100-200 bucket.
        #expect(MetricKitParser.weightedPercentile(launches, fraction: 0.5) == 150)
        // p90: rank 9 of 10 → the 1000-2000 bucket.
        #expect(MetricKitParser.weightedPercentile(launches, fraction: 0.9) == 1500)
        // The legacy unweighted median of bucket ENDS would say 2000.
    }

    @Test func emptyHistogramsGiveNoV2LaunchFields() {
        let props = MetricKitParser.histogramProperties(
            hangBucketsSeconds: [], launchBucketsMs: [B(start: 0, end: 100, count: 0)])
        #expect(int(props["hang_count_v2"]) == 0)
        #expect(double(props["hang_total_s_v2"]) == 0)
        #expect(props["launch_p50_ms_v2"] == nil)
        #expect(props["launch_p90_ms_v2"] == nil)

        let none = MetricKitParser.histogramProperties(hangBucketsSeconds: nil, launchBucketsMs: nil)
        #expect(none.isEmpty)
    }

    // MARK: - Exits

    @Test func exitCountsMapToPrefixedFields() {
        let fg = MetricKitParser.ExitCounts(normal: 10, memoryResourceLimit: 2, appWatchdog: 1,
                                            abnormal: 0, badAccess: 3, illegalInstruction: 4)
        let props = MetricKitParser.exitProperties(foreground: fg, background: nil)
        #expect(int(props["exit_fg_normal"]) == 10)
        #expect(int(props["exit_fg_memory_limit"]) == 2)
        #expect(int(props["exit_fg_watchdog"]) == 1)
        #expect(int(props["exit_fg_bad_access"]) == 3)
        #expect(int(props["exit_fg_illegal_instruction"]) == 4)
        #expect(props["exit_bg_normal"] == nil)
        #expect(props.count == 6)
    }

    @Test func backgroundOnlyExitReasonsAreEmittedForBackground() {
        let bg = MetricKitParser.ExitCounts(normal: 5, memoryPressure: 7, suspendedWithLockedFile: 2,
                                            backgroundTaskAssertionTimeout: 1, cpuResourceLimit: 0)
        let props = MetricKitParser.exitProperties(foreground: nil, background: bg)
        #expect(int(props["exit_bg_memory_pressure"]) == 7)
        #expect(int(props["exit_bg_locked_file"]) == 2)
        #expect(int(props["exit_bg_task_timeout"]) == 1)
        #expect(int(props["exit_bg_cpu_limit"]) == 0)
        #expect(props.count == 10)
    }
}
