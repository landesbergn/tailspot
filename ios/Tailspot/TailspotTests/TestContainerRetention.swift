//
//  TestContainerRetention.swift
//  TailspotTests
//

import SwiftData

/// Process-lifetime retention for per-test in-memory ModelContainers.
///
/// SwiftData schedules deferred autosave/teardown work (a timer on the main
/// run loop) as soon as rows are inserted; if the container deallocs when a
/// test returns, the timer later fires into deallocated state and traps in
/// _SwiftData_SwiftUI — crashing the test host and insta-failing whichever
/// suites are mid-flight. That was the CI/local "random tests fail at
/// 0.000 s" flake (EXC_BREAKPOINT in SwiftData ← __NSFireTimer, diagnosed
/// from the xcresult 2026-07-21). Leaking tiny in-memory stores for the
/// process lifetime is the standard workaround — same pattern as
/// CatchBackfillTests.retainedContainers and MarketingSnapshotTests.retained,
/// which predate this helper.
enum TestContainerRetention {
    private static var retained: [ModelContainer] = []

    static func retain(_ container: ModelContainer) {
        retained.append(container)
    }
}
