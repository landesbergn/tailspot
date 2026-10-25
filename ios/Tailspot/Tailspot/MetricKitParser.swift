//
//  MetricKitParser.swift
//  Tailspot
//
//  Pure helpers that turn MetricKit diagnostics into compact, PII-free
//  analytics properties. `MetricsSubscriber` is the only production caller.
//
//  Why a separate file of pure functions: MetricKit's classes
//  (`MXCrashDiagnostic`, `MXHistogram`, …) have no public initializers, so a
//  test cannot build one. What a test CAN build is the JSON MetricKit hands us
//  through `jsonRepresentation()`, and plain `(start, end, count)` tuples for
//  histograms. So all the logic lives here, over those plain inputs, and the
//  subscriber only does the thin "read the MetricKit object → call this" step.
//
//  Shape of a diagnostic's JSON (Apple's documented `MXDiagnostic` format):
//
//    {
//      "diagnosticMetaData": {
//        "appVersion": "1.2.2", "appBuildVersion": "107",
//        "osVersion": "iPhone OS 27.0.1 (24A…)",
//        "exceptionType": 1, "exceptionCode": 0, "signal": 11,
//        "terminationReason": "Namespace SIGNAL, Code 0xb", …
//      },
//      "callStackTree": {
//        "callStackPerThread": true,
//        "callStacks": [
//          { "threadAttributed": true,          ← the crashed / hung thread
//            "callStackRootFrames": [            ← the TOP frame (innermost)
//              { "binaryName": "Tailspot", "binaryUUID": "…",
//                "offsetIntoBinaryTextSegment": 123456,
//                "subFrames": [ { …its caller… } ] } ] } ]
//      }
//    }
//
//  A stack is a chain: the root frame is where the thread was, and each
//  `subFrames[0]` is the function that called it. Walking that chain gives the
//  frames in the same top-down order a crash log prints them.
//
//  What leaves the device: binary NAMES (never paths), offsets, binary UUIDs
//  (build identifiers, needed to symbolicate with `atos` against the archived
//  dSYM), exception numbers, and Apple's termination-reason string, truncated.
//  No user data, no file paths, no addresses that identify the device.
//

import Foundation

nonisolated enum MetricKitParser {

    // MARK: - Limits

    /// Frames of the crashed/hung thread we keep. Enough to see "which of our
    /// functions was on top" without making the event large.
    static let maxFrames = 8
    /// Frames of OUR binary we keep, wherever they sit in the stack. A crash
    /// or hang usually has several system frames on top (abort machinery,
    /// SwiftData/CoreData/sqlite, mach_msg), so the top 8 alone often never
    /// reach a Tailspot function; these are the ones that say where we were.
    static let maxAppFrames = 5
    /// How far down the stack we walk looking for app frames. A bound, so a
    /// deep recursion (or a malformed cyclic-looking chain) stays cheap.
    static let maxWalkFrames = 128
    /// The app's executable name, which is what MetricKit puts in
    /// `binaryName` for our own frames. Read from Info.plist so a rename
    /// can't silently break the match; "Tailspot" if the key is missing.
    static let appBinaryName: String =
        Bundle.main.infoDictionary?["CFBundleExecutable"] as? String ?? "Tailspot"
    /// Cap on Apple's free-text termination reason.
    static let maxTerminationReasonLength = 200
    /// Cap on the raw-JSON fallback sent when parsing fails.
    static let maxRawFallbackBytes = 1024

    // MARK: - Parsed diagnostic

    /// One parsed `MXDiagnostic` (crash or hang). Every field is optional:
    /// MetricKit omits keys freely, and a missing key must never drop the event.
    struct Diagnostic: Equatable, Sendable {
        var appVersion: String?
        var appBuild: String?
        var osVersion: String?
        var exceptionType: Int?
        var exceptionCode: Int?
        var signal: Int?
        var terminationReason: String?
        /// Hang length in seconds, from the `hangDuration` metadata string.
        var hangDurationSeconds: Double?
        /// "Tailspot+0x1e240 (UUID)" strings, top frame first.
        var topFrames: [String] = []
        /// The first `maxAppFrames` frames from the app's own binary, top
        /// first, found anywhere in the first `maxWalkFrames` of the stack.
        var appFrames: [String] = []
        /// Stack depth (0 = top) of the first app frame, if there is one.
        var firstAppFrameIndex: Int?
        /// True when the JSON decoded AND a call stack with frames was found.
        var parseOK: Bool = false
    }

    /// Parse one diagnostic's `jsonRepresentation()`. Never throws: malformed
    /// input comes back with `parseOK == false` so the caller can still send
    /// the event (with a raw fallback) instead of losing the crash entirely.
    static func parseDiagnostic(_ data: Data, appBinaryName: String = MetricKitParser.appBinaryName) -> Diagnostic {
        var out = Diagnostic()
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            return out
        }

        if let meta = root["diagnosticMetaData"] as? [String: Any] {
            out.appVersion = string(meta["appVersion"])
            out.appBuild = string(meta["appBuildVersion"])
            out.osVersion = string(meta["osVersion"])
            out.exceptionType = int(meta["exceptionType"])
            out.exceptionCode = int(meta["exceptionCode"])
            out.signal = int(meta["signal"])
            out.terminationReason = string(meta["terminationReason"])
            out.hangDurationSeconds = durationSeconds(meta["hangDuration"])
        }

        if let tree = root["callStackTree"] as? [String: Any] {
            let walk = walkAttributedStack(callStackTree: tree, appBinaryName: appBinaryName)
            out.topFrames = walk.top
            out.appFrames = walk.app
            out.firstAppFrameIndex = walk.firstAppIndex
        }
        out.parseOK = !out.topFrames.isEmpty
        return out
    }

    /// Walk the attributed thread's stack once, top first, collecting the
    /// first `maxFrames` frames AND the first `maxAppFrames` frames from our
    /// own binary (bounded at `maxWalkFrames` deep).
    static func walkAttributedStack(callStackTree tree: [String: Any],
                                    appBinaryName: String = MetricKitParser.appBinaryName)
        -> (top: [String], app: [String], firstAppIndex: Int?) {
        guard let stacks = tree["callStacks"] as? [[String: Any]], !stacks.isEmpty else {
            return ([], [], nil)
        }
        // `threadAttributed` marks the thread the diagnostic is about (the
        // crashed thread, or the main thread for a hang). Fall back to the
        // first stack if no thread carries the flag.
        let stack = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks[0]
        guard let roots = stack["callStackRootFrames"] as? [[String: Any]],
              var frame = roots.first else {
            return ([], [], nil)
        }

        var top: [String] = []
        var app: [String] = []
        var firstAppIndex: Int?
        var depth = 0
        while depth < maxWalkFrames {
            let isApp = binaryName(string(frame["binaryName"])) == appBinaryName
            if top.count < maxFrames { top.append(describe(frame: frame)) }
            if isApp && app.count < maxAppFrames {
                if firstAppIndex == nil { firstAppIndex = depth }
                app.append(describe(frame: frame))
            }
            // Stop early once both lists are full.
            if top.count >= maxFrames && app.count >= maxAppFrames { break }
            guard let next = (frame["subFrames"] as? [[String: Any]])?.first else { break }
            frame = next
            depth += 1
        }
        return (top, app, firstAppIndex)
    }

    /// The attributed thread's first `maxFrames` frames, top first.
    static func topFrames(callStackTree tree: [String: Any]) -> [String] {
        walkAttributedStack(callStackTree: tree).top
    }

    /// "Tailspot+0x1e240 (UUID)". `atos -o Tailspot.dSYM -l 0x0 0x1e240`-style
    /// symbolication needs exactly these three pieces.
    static func describe(frame: [String: Any]) -> String {
        let name = binaryName(string(frame["binaryName"]))
        let offset = int(frame["offsetIntoBinaryTextSegment"]).map { "0x" + String($0, radix: 16) } ?? "?"
        let uuid = string(frame["binaryUUID"]) ?? "?"
        return "\(name)+\(offset) (\(uuid))"
    }

    /// Just the last path component, so a full path can never leak even if a
    /// future OS starts sending one in `binaryName`.
    static func binaryName(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "?" }
        return (raw as NSString).lastPathComponent
    }

    // MARK: - Event properties

    /// Typed values read straight off the MetricKit object. They win over the
    /// JSON when present (the typed API is Apple's contract; the JSON keys are
    /// only documented by example), and the JSON fills anything they lack —
    /// `appVersion`, for one, exists only in the JSON.
    struct TypedFields: Sendable {
        var appBuild: String?
        var osVersion: String?
        var exceptionType: Int?
        var exceptionCode: Int?
        var signal: Int?
        var terminationReason: String?
        var hangDurationSeconds: Double?
    }

    /// Properties for one `metrickit_crash` event.
    static func crashProperties(diagnosticJSON json: Data,
                                typed: TypedFields = TypedFields(),
                                appBinaryName: String = MetricKitParser.appBinaryName) -> [String: AnalyticsValue] {
        let parsed = parseDiagnostic(json, appBinaryName: appBinaryName)
        var props = commonProperties(parsed: parsed, typed: typed, json: json)
        // Kept so the existing "crashes per day" series doesn't break: every
        // event is now exactly one crash.
        props["crash_count"] = .int(1)

        if let type = typed.exceptionType ?? parsed.exceptionType {
            props["exception_type"] = .int(type)
            if let name = exceptionName(type) { props["exception_name"] = .string(name) }
        }
        if let code = typed.exceptionCode ?? parsed.exceptionCode {
            props["exception_code"] = .int(code)
        }
        if let signal = typed.signal ?? parsed.signal {
            props["signal"] = .int(signal)
            if let name = signalName(signal) { props["signal_name"] = .string(name) }
        }
        if let reason = typed.terminationReason ?? parsed.terminationReason {
            props["termination_reason"] = .string(
                truncate(redactPaths(reason), maxLength: maxTerminationReasonLength))
        }
        return props
    }

    /// Properties for one `metrickit_hang` event.
    static func hangProperties(diagnosticJSON json: Data,
                               typed: TypedFields = TypedFields(),
                               appBinaryName: String = MetricKitParser.appBinaryName) -> [String: AnalyticsValue] {
        let parsed = parseDiagnostic(json, appBinaryName: appBinaryName)
        var props = commonProperties(parsed: parsed, typed: typed, json: json)
        if let seconds = typed.hangDurationSeconds ?? parsed.hangDurationSeconds {
            props["hang_duration_s"] = .double(seconds)
        }
        return props
    }

    /// Fields shared by crash and hang events: the build the diagnostic came
    /// FROM (not the build that happened to deliver it a launch later), the
    /// frames, and the parse outcome with a small raw fallback on failure.
    private static func commonProperties(parsed: Diagnostic,
                                         typed: TypedFields,
                                         json: Data) -> [String: AnalyticsValue] {
        var props: [String: AnalyticsValue] = ["parse_ok": .bool(parsed.parseOK)]
        if let v = parsed.appVersion { props["diag_app_version"] = .string(v) }
        if let b = typed.appBuild ?? parsed.appBuild { props["diag_app_build"] = .string(b) }
        if let os = typed.osVersion ?? parsed.osVersion { props["diag_os_version"] = .string(os) }
        if !parsed.topFrames.isEmpty {
            props["top_frames"] = .string(parsed.topFrames.joined(separator: "\n"))
            // Absent (not empty) when no app frame was found in the walk, so
            // "the stack never touched our code" is a filterable state.
            if !parsed.appFrames.isEmpty {
                props["app_frames"] = .string(parsed.appFrames.joined(separator: "\n"))
            }
            if let index = parsed.firstAppFrameIndex {
                props["first_app_frame_index"] = .int(index)
            }
        } else {
            props["raw_fallback"] = .string(rawFallback(json))
        }
        return props
    }

    /// The first `maxRawFallbackBytes` of the JSON, with paths reduced to file
    /// names, so a format change we didn't anticipate is still debuggable.
    static func rawFallback(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        return truncateUTF8(redactPaths(text), maxBytes: maxRawFallbackBytes)
    }

    // MARK: - Histograms

    /// One MetricKit histogram bucket as plain numbers (seconds or ms — the
    /// caller picks the unit when it converts).
    struct Bucket: Equatable, Sendable {
        var start: Double
        var end: Double
        var count: Int
        var midpoint: Double { (start + end) / 2 }
    }

    /// How many hangs the histogram describes. (The old `hang_total_s` summed
    /// bucket END values and never looked at the count, so it was neither a
    /// count nor a duration.)
    static func totalCount(_ buckets: [Bucket]) -> Int {
        buckets.reduce(0) { $0 + max($1.count, 0) }
    }

    /// Estimated total time: each bucket contributes count × its midpoint.
    static func weightedTotal(_ buckets: [Bucket]) -> Double {
        buckets.reduce(0) { $0 + Double(max($1.count, 0)) * $1.midpoint }
    }

    /// Count-weighted percentile (`fraction` in 0…1): the midpoint of the
    /// bucket holding that share of all samples. Nil when there are no
    /// samples, so an empty histogram is "no data", not a fake zero.
    static func weightedPercentile(_ buckets: [Bucket], fraction: Double) -> Double? {
        let sorted = buckets.filter { $0.count > 0 }.sorted { $0.start < $1.start }
        let total = totalCount(sorted)
        guard total > 0 else { return nil }
        let target = max(1, Int((Double(total) * fraction).rounded(.up)))
        var running = 0
        for bucket in sorted {
            running += bucket.count
            if running >= target { return bucket.midpoint }
        }
        return sorted.last?.midpoint
    }

    /// The corrected `_v2` fields for `metrickit_payload`. A missing histogram
    /// (nil) adds nothing, so the new series carries no placeholder zeros.
    static func histogramProperties(hangBucketsSeconds hang: [Bucket]?,
                                    launchBucketsMs launch: [Bucket]?) -> [String: AnalyticsValue] {
        var props: [String: AnalyticsValue] = [:]
        if let hang {
            props["hang_count_v2"] = .int(totalCount(hang))
            props["hang_total_s_v2"] = .double(weightedTotal(hang))
        }
        if let launch {
            if let p50 = weightedPercentile(launch, fraction: 0.5) {
                props["launch_p50_ms_v2"] = .double(p50)
            }
            if let p90 = weightedPercentile(launch, fraction: 0.9) {
                props["launch_p90_ms_v2"] = .double(p90)
            }
        }
        return props
    }

    // MARK: - App exits

    /// Cumulative exit counts for one state (foreground or background), read
    /// from `MXAppExitMetric`. Memory-limit (jetsam) and watchdog kills never
    /// produce a crash diagnostic, so these counts are the only place they show.
    struct ExitCounts: Equatable, Sendable {
        var normal = 0
        var memoryResourceLimit = 0
        var appWatchdog = 0
        var abnormal = 0
        var badAccess = 0
        var illegalInstruction = 0
        // Background-only reasons (MXBackgroundExitData has them, the
        // foreground data doesn't); nil for foreground counts so no field is
        // emitted. Background jetsam lands in memoryPressure, and 0xdead10cc
        // (killed while suspended holding the SwiftData/sqlite lock) in
        // suspendedWithLockedFile.
        var memoryPressure: Int? = nil
        var suspendedWithLockedFile: Int? = nil
        var backgroundTaskAssertionTimeout: Int? = nil
        var cpuResourceLimit: Int? = nil
    }

    static func exitProperties(foreground: ExitCounts?, background: ExitCounts?) -> [String: AnalyticsValue] {
        var props: [String: AnalyticsValue] = [:]
        for (prefix, counts) in [("exit_fg_", foreground), ("exit_bg_", background)] {
            guard let counts else { continue }
            props[prefix + "normal"] = .int(counts.normal)
            props[prefix + "memory_limit"] = .int(counts.memoryResourceLimit)
            props[prefix + "watchdog"] = .int(counts.appWatchdog)
            props[prefix + "abnormal"] = .int(counts.abnormal)
            props[prefix + "bad_access"] = .int(counts.badAccess)
            props[prefix + "illegal_instruction"] = .int(counts.illegalInstruction)
            if let n = counts.memoryPressure { props[prefix + "memory_pressure"] = .int(n) }
            if let n = counts.suspendedWithLockedFile { props[prefix + "locked_file"] = .int(n) }
            if let n = counts.backgroundTaskAssertionTimeout { props[prefix + "task_timeout"] = .int(n) }
            if let n = counts.cpuResourceLimit { props[prefix + "cpu_limit"] = .int(n) }
        }
        return props
    }

    // MARK: - Names

    /// Mach exception type → the name a crash log prints. A Swift runtime trap
    /// (force-unwrap of nil, array out of range) shows up as EXC_BREAKPOINT.
    static func exceptionName(_ type: Int) -> String? {
        switch type {
        case 1: "EXC_BAD_ACCESS"
        case 2: "EXC_BAD_INSTRUCTION"
        case 3: "EXC_ARITHMETIC"
        case 4: "EXC_EMULATION"
        case 5: "EXC_SOFTWARE"
        case 6: "EXC_BREAKPOINT"
        case 10: "EXC_CRASH"
        case 11: "EXC_RESOURCE"
        case 12: "EXC_GUARD"
        default: nil
        }
    }

    static func signalName(_ signal: Int) -> String? {
        switch signal {
        case 4: "SIGILL"
        case 5: "SIGTRAP"
        case 6: "SIGABRT"
        case 8: "SIGFPE"
        case 9: "SIGKILL"
        case 10: "SIGBUS"
        case 11: "SIGSEGV"
        case 15: "SIGTERM"
        default: nil
        }
    }

    // MARK: - Small helpers

    /// Replace every absolute path with its last component
    /// ("/private/var/containers/…/Tailspot" → "Tailspot").
    static func redactPaths(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?:/[^\s/"',()<>]+){2,}"#) else {
            return text
        }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += (ns.substring(with: match.range) as NSString).lastPathComponent
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    static func truncate(_ text: String, maxLength: Int) -> String {
        text.count <= maxLength ? text : String(text.prefix(maxLength))
    }

    /// Truncate to at most `maxBytes` of UTF-8 without splitting a character.
    static func truncateUTF8(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var out = ""
        var bytes = 0
        for ch in text {
            let n = String(ch).utf8.count
            if bytes + n > maxBytes { break }
            out.append(ch)
            bytes += n
        }
        return out
    }

    /// "3.12 sec" / "3120 ms" / a bare number → seconds.
    static func durationSeconds(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        guard let s = value as? String else { return nil }
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard let first = parts.first, let number = Double(first) else { return nil }
        let unit = parts.count > 1 ? parts[1].lowercased() : "sec"
        return unit.hasPrefix("ms") ? number / 1000 : number
    }

    private static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }
}
