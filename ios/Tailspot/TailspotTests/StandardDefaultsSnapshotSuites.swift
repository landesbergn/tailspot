//
//  StandardDefaultsSnapshotSuites.swift
//  TailspotTests
//
//  The snapshot suites that write the spotter handle (and other @AppStorage
//  keys) into `UserDefaults.standard`, where the screens under test read
//  them. Their settle waits are `await Task.sleep`, so two of these suites
//  running side by side would interleave on the main actor: one would render
//  with the other's handle, and their save/restore pairs would unwind out of
//  order and leave a stale handle behind. Each suite nests in this one, and
//  `.serialized` on a parent applies to every suite inside it, so they run
//  one test at a time while the rest of the suite still runs in parallel.
//

import Testing

@Suite(.serialized)
enum StandardDefaultsSnapshotSuites {}
