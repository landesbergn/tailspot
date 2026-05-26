# Capture & Hangar Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the capture + hangar redesign from `docs/superpowers/specs/2026-05-25-capture-and-hangar-redesign-design.md` — all-frame ambient lock with tap-pin override, unique-tail catch model with quiet-reveal duplicates, segmented Hangar (Sets default · Recent · Trophies), set→model-slot→tail drill-down, PokeCard-first tail detail.

**Architecture:** SwiftUI + SwiftData on iOS 17+. The lock engine simplifies (auto-acquire removed); per-plane labels become a rendering concern, not an engine state. Catch insertion gains a uniqueness gate; duplicates render with an `ALREADY CAUGHT` stamp but don't write to the DB or score. The Hangar sheet grows a 3-segment switcher; Sets gets a 4-level drill-down (landing → set detail → model slot → tail). Catch detail rewrites to put PokeCard front-and-center.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing (`@Test`, `#expect`), iOS Simulator + paired iPhone for visual verification via `bin/deploy`. `AudioServicesPlaySystemSound` for reveal chimes. `UIImpactFeedbackGenerator` for haptics. Existing `PokeCardView`, `MultiCatchReveal`, `Brand` tokens, `LockOnEngine` are foundations.

**Visual verification convention:** UI tasks end with `bin/deploy` + a self-check that the result matches the spec mockup at `.superpowers/brainstorm/<latest>/content/spec-with-visuals.html`. The session uses Noah's `feedback-workflow-autonomy` memory: commit + deploy autonomously after tests pass; don't push to remote.

**Test command (used throughout):**

```
xcodebuild test \
  -project ios/Tailspot/Tailspot.xcodeproj \
  -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests
```

---

## File Structure

**New files**

| Path | Responsibility |
|------|---|
| `ios/Tailspot/Tailspot/ModelSlot.swift` | View-model bundling `(entry: PokeSetEntry, tails: [HangarRow])` + a resolver that takes the dedup'd row list + a `PokeSet` and returns the slots, with caught tails attached. |
| `ios/Tailspot/Tailspot/HangarSegmentedSwitcher.swift` | Small SwiftUI view: 3-segment cyan-on-bgElevated control used in the Hangar sheet. Decoupled so the picker style is reusable + easy to replace. |
| `ios/Tailspot/Tailspot/HangarSetsView.swift` | Sets-view body (set landing tile list). |
| `ios/Tailspot/Tailspot/HangarRecentView.swift` | Recent-view body (dedup'd MiniCard grid). |
| `ios/Tailspot/Tailspot/HangarTrophiesView.swift` | Trophies-view body (port of existing `TrophiesScreen` content). |
| `ios/Tailspot/Tailspot/SetDetailView.swift` | Set detail screen — model slot grid + header + next-milestone line. |
| `ios/Tailspot/Tailspot/ModelSlotDetailView.swift` | NEW screen sitting between Set detail and Tail detail — vertical list of distinct tails of one model. |
| `ios/Tailspot/Tailspot/RevealAudio.swift` | Helper that plays the ascending chime tones during multi-catch reveal. Wraps `AudioServicesPlaySystemSoundID`. |

**Modified files**

| Path | Change |
|------|---|
| `ios/Tailspot/Tailspot/Catch.swift` | Add static helper `Catch.exists(icao24:in:)` for the uniqueness gate. |
| `ios/Tailspot/Tailspot/HangarGrouping.swift` | Add `firstCaught: Date` and `firstCatch: Catch` to `HangarRow`. Add `HangarGrouping.resolveSlots(for:in:)` returning `[ModelSlot]` for a given set. |
| `ios/Tailspot/Tailspot/LockOnEngine.swift` | Drop `.acquiring` state and `acquisitionDuration`. Reduce state machine to `.idle`, `.locked`, `.sticky`. `forceLock` remains the only entry to locked state. |
| `ios/Tailspot/Tailspot/HangarView.swift` | Replace the `LazyVGrid` body with the 3-segment switcher + the new view bodies. Keep toolbar + count pill + delete alert. |
| `ios/Tailspot/Tailspot/MiniCardView.swift` | Drop `×N` count pill (dedup eliminates the need). |
| `ios/Tailspot/Tailspot/CatchDetailView.swift` | Full rewrite — PokeCard hero + EARNED + First-caught + attribution. |
| `ios/Tailspot/Tailspot/CardReveal.swift` | Add `isDuplicate` flag and the `ALREADY CAUGHT` diagonal stamp + muted treatment. |
| `ios/Tailspot/Tailspot/MultiCatchReveal.swift` | Replace simultaneous fan with staggered reveal + haptic taps + chime + combo banner. Duplicates render inline marked but don't add to combo. |
| `ios/Tailspot/Tailspot/ContentView.swift` | All-frame label rendering on every visible plane. Remove auto-acquire bracket states. Unified `performCatch` entry point. Tap-empty "try harder" behavior. Capture button affordance update (`×N` corner badge for multi). |
| `ios/Tailspot/Tailspot/ProfileScreen.swift` | Remove the `RECENT MEDALS` strip + `Trophies` quick link. |
| `ios/Tailspot/Tailspot/TrophiesScreen.swift` | Either deleted or reduced to a thin re-exporter for the standalone Profile push path (decided in Task 11). |
| `ios/Tailspot/TailspotTests/CatchTests.swift` | Flip `storesMultipleCatchesIncludingDuplicates` to `duplicateInsertIsRejected`. |
| `ios/Tailspot/TailspotTests/HangarGroupingTests.swift` | Add tests for `firstCaught` + `ModelSlot` resolution. |
| `ios/Tailspot/TailspotTests/LockOnEngineTests.swift` | Remove acquisition-state tests; add direct-to-locked tests via `forceLock`. |

---

## Task 1: `Catch` uniqueness helper + flipped test

**Files:**
- Modify: `ios/Tailspot/Tailspot/Catch.swift`
- Test: `ios/Tailspot/TailspotTests/CatchTests.swift`

The catch insertion path needs a fast "does this icao24 already exist" check. Add it as a static helper on `Catch` so the insertion sites (`performAutoCatch`, `performMultiCatch` — merged in Task 8) can call it before constructing a new row.

- [ ] **Step 1: Open the existing test file and replace the duplicates-allowed test**

```swift
// Replace the existing test `storesMultipleCatchesIncludingDuplicates`
// in ios/Tailspot/TailspotTests/CatchTests.swift with:

@Test func duplicateInsertIsRejected() throws {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: Catch.self, configurations: config)
    let ctx = ModelContext(container)

    let icao = "abc123"

    // First insert succeeds.
    ctx.insert(Catch(
        icao24: icao,
        callsign: "UAL248",
        model: "737-800",
        manufacturer: "BOEING",
        operatorName: "United",
        caughtAt: Date(),
        observerLat: 37.871, observerLon: -122.272,
        slantDistanceMeters: 12_400
    ))
    try ctx.save()

    // Sanity: the row is there.
    let before = try ctx.fetch(FetchDescriptor<Catch>())
    #expect(before.count == 1)

    // The Catch model itself enforces nothing — uniqueness is gated at
    // the insertion site (ContentView.performCatch). What we test here
    // is the static helper that those sites use.
    #expect(Catch.exists(icao24: icao, in: ctx) == true)
    #expect(Catch.exists(icao24: "deadbeef", in: ctx) == false)
}
```

- [ ] **Step 2: Run the test, verify it fails (Catch.exists doesn't exist yet)**

Run the test command. Expected: build failure — `Type 'Catch' has no member 'exists'`.

- [ ] **Step 3: Add the static helper to `Catch.swift`**

Append inside the `Catch` `@Model` class (e.g., after the existing initializer; preserve the existing class-isolation rules — the helper is `nonisolated static`):

```swift
/// Returns true when at least one `Catch` row with the given icao24
/// (case-insensitive comparison after trim) exists in the context.
/// Used by the capture path to gate insertion — duplicates render as
/// quiet "ALREADY CAUGHT" reveals but don't add a new row.
nonisolated static func exists(icao24: String, in context: ModelContext) -> Bool {
    let key = icao24.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !key.isEmpty else { return false }
    let predicate = #Predicate<Catch> { $0.icao24 == key }
    var descriptor = FetchDescriptor<Catch>(predicate: predicate)
    descriptor.fetchLimit = 1
    return ((try? context.fetch(descriptor).first) != nil)
}
```

If the existing `Catch.swift` doesn't already `import SwiftData`, add it at the top. (It likely does — the rest of the model uses it.)

- [ ] **Step 4: Run the test, verify it passes**

Run the test command. Expected: `duplicateInsertIsRejected` passes. All other tests still pass.

- [ ] **Step 5: Commit**

```bash
git add ios/Tailspot/Tailspot/Catch.swift ios/Tailspot/TailspotTests/CatchTests.swift
git commit -m "$(cat <<'EOF'
Add Catch.exists(icao24:in:) uniqueness helper

Spec § 9.1 — duplicate catches don't write a new row. The insertion
sites in ContentView (merged in Task 8) call this before inserting;
match → skip insert + render the duplicate reveal state.

Flips CatchTests::storesMultipleCatchesIncludingDuplicates to
duplicateInsertIsRejected, asserting the helper returns true/false
based on existence.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `HangarRow.firstCatch` helper + tests

**Files:**
- Modify: `ios/Tailspot/Tailspot/HangarGrouping.swift`
- Test: `ios/Tailspot/TailspotTests/HangarGroupingTests.swift`

`CatchDetailView`'s First-caught panel needs the earliest catch (not most recent) so legacy multi-catch rows show the original. Add `firstCatch` on `HangarRow` — derived from `allCatches.last` since `allCatches` is sorted most-recent-first.

- [ ] **Step 1: Add the failing test**

In `HangarGroupingTests.swift`, after `rowsWithinAGroupAreSortedMostRecentFirst`:

```swift
@Test func hangarRowFirstCatchIsEarliestInAllCatches() {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let groups = HangarGrouping.group([
        makeCatch(icao: "x", manufacturer: "BOEING", model: "737", caughtAt: t0.addingTimeInterval(120)),
        makeCatch(icao: "x", manufacturer: "BOEING", model: "737", caughtAt: t0),
        makeCatch(icao: "x", manufacturer: "BOEING", model: "737", caughtAt: t0.addingTimeInterval(60)),
    ], by: .aircraftType)

    let row = groups[0].rows[0]
    #expect(row.icao24 == "x")
    #expect(row.firstCatch.caughtAt == t0)
    #expect(row.mostRecent.caughtAt == t0.addingTimeInterval(120))
}
```

- [ ] **Step 2: Run the test, verify it fails (firstCatch doesn't exist)**

Expected: `HangarRow` has no member `firstCatch`.

- [ ] **Step 3: Add `firstCatch` to `HangarRow`**

In `HangarGrouping.swift`, inside the `HangarRow` struct, after `mostRecent`:

```swift
/// Earliest catch in the row's history. With Task 8's dedup-on-insert
/// going forward there's only ever one Catch per icao24, so this
/// equals `mostRecent`. Legacy multi-catch rows (pre-dedup) surface
/// the original moment here — used by CatchDetailView's First-caught
/// panel.
var firstCatch: Catch { allCatches.last ?? mostRecent }
```

(`allCatches` is already sorted most-recent-first by `dedupe`, so `.last` is the earliest.)

- [ ] **Step 4: Run tests, verify pass**

All `HangarGroupingTests` pass.

- [ ] **Step 5: Commit**

```bash
git add ios/Tailspot/Tailspot/HangarGrouping.swift ios/Tailspot/TailspotTests/HangarGroupingTests.swift
git commit -m "Add HangarRow.firstCatch (earliest catch) helper

Spec § 8 — First-caught panel in the rewritten CatchDetailView
shows the earliest catch in the row's history, not the most recent.
Relevant for legacy pre-dedup rows; post-dedup it equals mostRecent.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `ModelSlot` view-model + resolver + tests

**Files:**
- Create: `ios/Tailspot/Tailspot/ModelSlot.swift`
- Modify: `ios/Tailspot/Tailspot/HangarGrouping.swift`
- Test: `ios/Tailspot/TailspotTests/HangarGroupingTests.swift`

`SetDetailView` (Task 14) needs to know — for each `PokeSetEntry` in a given set — how many distinct tails the user has caught of that model, plus the list of those tails (for the model-slot drill-in). The resolver consumes the dedup'd `HangarRow` list + a `PokeSet` and produces `[ModelSlot]`.

Mapping a `Catch` to a `PokeSetEntry` reuses the existing matching logic in `Sets.swift` — `PokeSets.match(_:against:)` (or whichever entry-point currently powers `PokeSets.status` / `PokeSets.progress`). Don't introduce a new matcher.

- [ ] **Step 1: Find the existing Catch→PokeSetEntry matcher**

```bash
grep -nE "(func match|func status|func progress|fillsSlot)" ios/Tailspot/Tailspot/Sets.swift | head -20
```

Read whatever surface area the file exposes (likely `PokeSets.status(of:against:)` per CLAUDE.md's mention). Note the function signature you'll call. If no single-shot "does this catch fill this entry" boolean exists, the underlying token comparison is what we'll wrap.

- [ ] **Step 2: Add the failing test**

In `HangarGroupingTests.swift`, at the bottom:

```swift
@Test func resolveSlotsForSetGroupsCaughtTailsByEntry() throws {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    // Two 737s (different tails), one A320 — narrow-body.
    let catches = [
        makeCatch(icao: "boeing1", manufacturer: "BOEING", model: "737-800", caughtAt: t0),
        makeCatch(icao: "boeing2", manufacturer: "BOEING", model: "737-800", caughtAt: t0.addingTimeInterval(60)),
        makeCatch(icao: "airbus1", manufacturer: "AIRBUS", model: "A320",    caughtAt: t0.addingTimeInterval(30)),
    ]
    let rows = HangarGrouping.group(catches, by: .recent).first?.rows ?? []
    #expect(rows.count == 3)

    // Find the narrow-body set in PokeSets.all.
    guard let narrow = PokeSets.all.first(where: { $0.type == .narrow }) else {
        Issue.record("No narrow-body set declared in PokeSets.all")
        return
    }

    let slots = HangarGrouping.resolveSlots(for: narrow, in: rows)
    #expect(slots.count == narrow.entries.count)

    // The 737-800 slot has 2 distinct tails.
    let b737 = slots.first(where: { $0.entry.modelMatchTokens.contains(where: { $0.localizedCaseInsensitiveContains("737") }) })
    #expect(b737?.tails.count == 2)

    // The A320 slot has 1.
    let a320 = slots.first(where: { $0.entry.modelMatchTokens.contains(where: { $0.localizedCaseInsensitiveContains("A320") }) })
    #expect(a320?.tails.count == 1)
}
```

Note: `modelMatchTokens` is illustrative; if the real field on `PokeSetEntry` is named differently (e.g., `match`, `tokens`, `pattern`), adjust the test to use the actual field after Step 1's inspection. The point of the test is: the resolver attaches the right tails to the right entries.

- [ ] **Step 3: Run the test, verify it fails (resolveSlots doesn't exist)**

Expected: `Type 'HangarGrouping' has no member 'resolveSlots'`.

- [ ] **Step 4: Create `ModelSlot.swift`**

```swift
//
//  ModelSlot.swift
//  Tailspot
//
//  View-model wrapping a (PokeSetEntry, [HangarRow]) pair. Used by
//  SetDetailView's slot grid and ModelSlotDetailView's tail list.
//  Spec § 9.2.
//

import Foundation

struct ModelSlot: Identifiable, Hashable {
    let entry: PokeSetEntry
    let tails: [HangarRow]

    var id: String { entry.id } // PokeSetEntry already conforms to Identifiable

    var isCaught: Bool { !tails.isEmpty }
    var distinctTailCount: Int { tails.count }
}
```

If `PokeSetEntry` is not already `Identifiable` or its `id` is differently named, adjust accordingly — verify in `Sets.swift`.

- [ ] **Step 5: Add `resolveSlots` to `HangarGrouping.swift`**

Append after the `key(for:mode:)` static:

```swift
/// Returns one `ModelSlot` per entry in the given set, with the
/// dedup'd HangarRows that fall into each slot attached. Rows that
/// don't match any entry in the set are dropped from the result
/// (they still appear in Recent — sets are a curated lens, not a
/// universal bucket). Empty `tails` means the slot is locked.
///
/// The Catch → PokeSetEntry match reuses the existing `Sets.swift`
/// matcher (Spec § 9.2 — no new matcher introduced).
static func resolveSlots(for set: PokeSet, in rows: [HangarRow]) -> [ModelSlot] {
    set.entries.map { entry in
        let matchingTails = rows.filter { row in
            PokeSets.matches(catch: row.mostRecent, entry: entry)
        }
        return ModelSlot(entry: entry, tails: matchingTails)
    }
}
```

The function `PokeSets.matches(catch:entry:)` may not exist by that exact name. **Step 6 below resolves that.**

- [ ] **Step 6: Expose / add the single-shot matcher in `Sets.swift`**

Open `Sets.swift`. If a public method already returns "does this catch fill this entry," wire `resolveSlots` to it (change the call in Step 5 accordingly). If not, add a thin nonisolated static that delegates to the existing internal matching:

```swift
// In Sets.swift, inside `enum PokeSets`:

/// True when the given Catch satisfies the given entry's match
/// criteria. Thin wrapper around the existing internal matcher used
/// by `status(of:against:)` and `progress(of:against:)`; exposed so
/// HangarGrouping.resolveSlots can pivot on it.
nonisolated static func matches(catch c: Catch, entry: PokeSetEntry) -> Bool {
    // <implementation reuses whatever PokeSetEntry stores for matching —
    //  often a list of model substring tokens with case-insensitive
    //  comparison. Don't reinvent.>
}
```

Implementation: read the current internal matcher (whatever drives `PokeSets.status(of:against:)`) and call it here. If the existing matcher already takes (Catch, PokeSetEntry) — even as a private — promote it.

- [ ] **Step 7: Run tests, verify the new test passes**

If the resolver test fails because the matcher tokens field is named differently than the test assumed, adjust the test in Step 2 to match the real field on `PokeSetEntry`. Run again.

- [ ] **Step 8: Commit**

```bash
git add ios/Tailspot/Tailspot/ModelSlot.swift ios/Tailspot/Tailspot/HangarGrouping.swift ios/Tailspot/Tailspot/Sets.swift ios/Tailspot/TailspotTests/HangarGroupingTests.swift
git commit -m "Add ModelSlot view-model + HangarGrouping.resolveSlots(for:in:)

Spec § 9.2 — view-model that bundles (PokeSetEntry, [HangarRow]) for
SetDetailView's slot grid and ModelSlotDetailView's tail list. The
Catch → PokeSetEntry match reuses Sets.swift's existing matcher (now
exposed as PokeSets.matches(catch:entry:) — same internal logic, just
a public surface for the resolver to call).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Simplify `LockOnEngine` — remove `.acquiring`

**Files:**
- Modify: `ios/Tailspot/Tailspot/LockOnEngine.swift`
- Test: `ios/Tailspot/TailspotTests/LockOnEngineTests.swift`

The new model has no auto-acquire (all-frame labels are ambient; pin is explicit via tap). Drop `.acquiring`, `acquisitionDuration`, `acquisitionProgress`. The engine becomes a 3-state machine: `.idle / .locked / .sticky`. `forceLock` is the only way into `.locked`.

- [ ] **Step 1: Rewrite the relevant LockOnEngineTests cases first**

Open `ios/Tailspot/TailspotTests/LockOnEngineTests.swift`. Delete every test that asserts `.acquiring` behavior (e.g., `acquisitionProgressIsZeroOutsideAcquiring`, `acquiringLostTargetReturnsToIdle`, `acquiringDifferentTargetRestartsAcquisition`). Replace with:

```swift
@Test func forceLockMovesIdleToLocked() {
    let engine = LockOnEngine()
    #expect(engine.state == .idle)
    engine.forceLock(targetIcao24: "abc")
    if case .locked(let t, _) = engine.state {
        #expect(t == "abc")
    } else {
        Issue.record("Expected .locked after forceLock")
    }
}

@Test func updateWithNilFromLockedMovesToSticky() {
    let engine = LockOnEngine()
    engine.forceLock(targetIcao24: "abc")
    engine.update(closestTargetIcao24: nil, now: Date())
    if case .sticky(let t, _) = engine.state {
        #expect(t == "abc")
    } else {
        Issue.record("Expected .sticky after losing target")
    }
}

@Test func stickyExpiresToIdleAfterDuration() {
    let engine = LockOnEngine()
    engine.stickyHoldDuration = 0.1
    let t0 = Date()
    engine.forceLock(targetIcao24: "abc", now: t0)
    engine.update(closestTargetIcao24: nil, now: t0)
    engine.update(closestTargetIcao24: nil, now: t0.addingTimeInterval(0.2))
    #expect(engine.state == .idle)
}

@Test func stickyRecoversToLockedOnSameTarget() {
    let engine = LockOnEngine()
    let t0 = Date()
    engine.forceLock(targetIcao24: "abc", now: t0)
    engine.update(closestTargetIcao24: nil, now: t0)
    engine.update(closestTargetIcao24: "abc", now: t0.addingTimeInterval(0.5))
    if case .locked(let t, _) = engine.state {
        #expect(t == "abc")
    } else {
        Issue.record("Expected .locked after sticky recovery")
    }
}
```

- [ ] **Step 2: Run tests, verify the new ones fail (engine still has .acquiring)**

Expected: compile errors on `.acquiring`-related code paths from the test changes, OR test failures because update() still routes idle→acquiring.

- [ ] **Step 3: Simplify `LockOnEngine.State`**

In `LockOnEngine.swift`, replace the `State` enum:

```swift
enum State: Equatable {
    case idle
    case locked(targetIcao24: String, lockedAt: Date)
    case sticky(targetIcao24: String, lostAt: Date)

    /// The icao24 of whichever aircraft is currently locked / held.
    /// Nil only when idle.
    var targetIcao24: String? {
        switch self {
        case .idle: return nil
        case .locked(let t, _), .sticky(let t, _): return t
        }
    }

    /// True when actively presenting a lock or holding sticky.
    var isLockedOrSticky: Bool {
        switch self {
        case .locked, .sticky: return true
        case .idle: return false
        }
    }
}
```

- [ ] **Step 4: Simplify `update(closestTargetIcao24:now:)`**

Replace the existing implementation:

```swift
func update(closestTargetIcao24: String?, now: Date = Date()) {
    switch state {
    case .idle:
        // No auto-acquire — the engine only enters locked via
        // forceLock(). update() doesn't drive idle → locked anymore.
        break

    case .locked(let oldIcao, _):
        guard let icao = closestTargetIcao24 else {
            state = .sticky(targetIcao24: oldIcao, lostAt: now)
            return
        }
        if icao != oldIcao {
            // The currently-locked plane is no longer the closest —
            // hold sticky on the old one. The user can tap to re-pin
            // if they want a different target.
            state = .sticky(targetIcao24: oldIcao, lostAt: now)
        }

    case .sticky(let oldIcao, let lostAt):
        if let icao = closestTargetIcao24, icao == oldIcao {
            state = .locked(targetIcao24: icao, lockedAt: now)
        } else if now.timeIntervalSince(lostAt) >= stickyHoldDuration {
            state = .idle
        }
    }
}
```

- [ ] **Step 5: Remove `acquisitionDuration` and `acquisitionProgress`**

Delete the `acquisitionDuration` stored property and the `acquisitionProgress(now:)` method. Update the file header comment block to reflect the simplified state machine (delete the .acquiring transitions from the comment).

- [ ] **Step 6: Add `unpin()` method**

For ContentView to clear a pin (tap-empty-while-pinned per spec § 3.1), add:

```swift
/// Clear any active lock/sticky and return to idle. Used by
/// ContentView when the user taps empty sky while a pin is in
/// effect.
func unpin() {
    state = .idle
}
```

- [ ] **Step 7: Find callers of removed APIs and stub them**

```bash
grep -nE "acquisitionProgress|acquisitionDuration|\.acquiring" ios/Tailspot/Tailspot/*.swift
```

Likely callers: `ContentView.swift` (bracket animation), `ReplayAnalyzer.swift` if it tracks engine state. For each match:
  - In `ContentView.swift`: remove the bracket-progress-based animation; the new design has either bright-locked brackets (pinned) or no brackets (idle/sticky-fade). Bracket animation between states stays — just no `acquisitionProgress` driving it.
  - In `ReplayAnalyzer.swift`: if it switches over engine state, drop the `.acquiring` arm.

- [ ] **Step 8: Run tests, verify all pass**

All LockOnEngineTests, ContentViewTests (if any), ReplayAnalyzerTests pass.

- [ ] **Step 9: Build the sim target to catch missed callers**

```bash
xcodebuild build -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' 2>&1 | grep -E "error:|BUILD" | tail -10
```

Expected: `** BUILD SUCCEEDED **`. Any errors → fix the caller and re-build.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "Simplify LockOnEngine — drop .acquiring, lock-only-via-forceLock

Spec § 9.3 — all-frame labels are now ambient (rendered per-plane by
the AR overlay, not driven by lock state). The lock concept only
applies to an explicit pin. Engine becomes idle / locked / sticky.
update() no longer drives idle → locked; forceLock() is the only
entry to locked. New unpin() clears any active lock.

Removes acquisitionProgress and acquisitionDuration. Existing
ContentView bracket-progress animation gives way to the cleaner
on/off pinned-vs-not treatment in Task 5.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: All-frame ambient labels in the AR overlay

**Files:**
- Modify: `ios/Tailspot/Tailspot/ContentView.swift`

Render a faint cyan corner-bracket pair + small label (`callsign · rarity teaser`) on **every** visible plane. The pinned plane (if any) gets brighter/thicker brackets + an expanded label. Other planes dim to ~35% opacity when something's pinned.

This task is structural — no unit tests; verification is visual. Build + deploy + look at the camera view.

- [ ] **Step 1: Locate the existing single-plane lock-bracket rendering**

```bash
grep -nE "lock\.state|lockOn\.state|LockBrackets|cornerBracket|Brand\.Color\.cyan" ios/Tailspot/Tailspot/ContentView.swift | head -30
```

Identify the existing block that draws brackets + label for the locked target. You're replacing it with an iteration over visible aircraft.

- [ ] **Step 2: Write a `PlaneLabel` helper view inside ContentView (or as a private struct in the same file)**

```swift
/// Per-plane label rendered above the aircraft's projected screen
/// position. `isPinned` swaps to the bright/expanded variant.
private struct PlaneLabel: View {
    let aircraft: ObservedAircraft
    let position: CGPoint
    let isPinned: Bool
    let isDimmed: Bool  // true when something ELSE is pinned

    var body: some View {
        let rarity = aircraft.metadata?.rarity ?? .common
        let callsign = aircraft.aircraft.callsign?.trimmingCharacters(in: .whitespaces)
            .nonEmpty ?? aircraft.aircraft.icao24.uppercased()
        VStack(spacing: 0) {
            // Corner brackets
            ZStack {
                LockBrackets(
                    color: Brand.Color.cyan,
                    armLength: isPinned ? 20 : 12,
                    thickness: isPinned ? 2.5 : 1.5
                )
                .frame(width: isPinned ? 56 : 36, height: isPinned ? 56 : 36)
            }
            // Label below brackets
            HStack(spacing: 4) {
                Text(callsign)
                    .font(.system(size: isPinned ? 11 : 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Brand.Color.cyan)
                if isPinned {
                    // Expanded: include rarity + points hint.
                    Text("· \(rarity.label) +\(rarity.basePoints)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(rarity.tint)
                } else {
                    Text("· \(rarity.label)")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(rarity.tint)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.55), in: .rect(cornerRadius: 4))
            .padding(.top, 2)
        }
        .position(position)
        .opacity(isDimmed ? 0.35 : 1.0)
        .allowsHitTesting(false)
    }
}

/// Shared corner-bracket primitive: 4 short L's at the corners of a
/// square frame. Pulled out so the per-plane label and any other
/// reticle-style usage can share geometry.
private struct LockBrackets: View {
    var color: Color
    var armLength: CGFloat
    var thickness: CGFloat
    var body: some View {
        ZStack {
            // Each corner: two perpendicular lines forming an L.
            ForEach(Array([
                (h: Alignment.topLeading,    dx: 0,             dy: 0,             rot: 0.0),
                (h: Alignment.topTrailing,   dx: -armLength,    dy: 0,             rot: 90.0),
                (h: Alignment.bottomTrailing,dx: -armLength,    dy: -armLength,    rot: 180.0),
                (h: Alignment.bottomLeading, dx: 0,             dy: -armLength,    rot: 270.0),
            ].enumerated()), id: \.offset) { _, corner in
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(color).frame(width: armLength, height: thickness)
                    Rectangle().fill(color).frame(width: thickness, height: armLength)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.h)
            }
        }
    }
}
```

- [ ] **Step 3: Replace the single-plane bracket block with iteration**

In ContentView's body (inside the `TimelineView` that already projects positions), iterate every visible aircraft and render a `PlaneLabel`:

```swift
// Inside the GeometryReader/TimelineView block where you have
// `let observed = adsb.observed.filter(\.isLikelyVisibleToObserver)`
// and `screenSize`, `phoneHeading`, `cameraElevation`, etc.:

let pinnedIcao: String? = lockOn.state.targetIcao24
ForEach(observed, id: \.aircraft.icao24) { obs in
    if let pos = obs.screenPosition(
        phoneHeadingDeg: phoneHeading,
        cameraElevationDeg: cameraElevation,
        in: screenSize,
        hfovDeg: ContentView.baseHfovDeg / zoom,
        vfovDeg: ContentView.baseVfovDeg / zoom
    ) {
        PlaneLabel(
            aircraft: obs,
            position: pos,
            isPinned: obs.aircraft.icao24 == pinnedIcao,
            isDimmed: pinnedIcao != nil && obs.aircraft.icao24 != pinnedIcao
        )
    }
}
```

Remove the prior code path that drew brackets only for `lockOn.state.targetIcao24`.

- [ ] **Step 4: Delete the now-unused acquisition-bracket animation**

Search and remove any block that read `lockOn.acquisitionProgress(...)` (deleted in Task 4) — likely an opacity / scale on a bracket overlay.

- [ ] **Step 5: Build for simulator**

```bash
xcodebuild build -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' 2>&1 | grep -E "error:|BUILD" | tail -10
```

Expected: `** BUILD SUCCEEDED **`. Fix any errors.

- [ ] **Step 6: Run the test suite**

Run the test command. All existing tests pass; no new tests for this task.

- [ ] **Step 7: Deploy + visually confirm**

```bash
bin/deploy
```

Confirm on device:
- Every visible plane has a faint cyan corner-bracket pair + small `callsign · RARITY` label.
- Tap a plane: that plane's brackets brighten + thicken; its label expands to include points; other planes dim to ~35%.
- Tap the pinned plane again: returns to all-frame, all labels back to full opacity.
- Tap empty sky with a pin: clears the pin (next task fully wires the "try harder" tap-empty behavior).

- [ ] **Step 8: Commit**

```bash
git add ios/Tailspot/Tailspot/ContentView.swift
git commit -m "AR overlay: per-plane ambient labels for all visible aircraft

Spec § 3.1 — every visible plane now gets a faint cyan corner-
bracket pair + 'callsign · RARITY' label. The pinned plane (if any)
brightens; others dim to 35%. Removes the single-target acquisition
bracket animation tied to LockOnEngine.acquisitionProgress (which
was deleted in Task 4).

New PlaneLabel + LockBrackets primitives encapsulate the shared
bracket geometry so future surfaces (e.g., a different reticle
treatment for pinned vs locked) can reuse it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Tap-empty "try harder" behavior

**Files:**
- Modify: `ios/Tailspot/Tailspot/ContentView.swift`

Spec § 3.1: tap-empty-while-pinned clears the pin; tap-empty-while-not-pinned widens the search radius and pins the nearest visible plane (or surfaces a `NO AIRCRAFT HERE` ripple).

- [ ] **Step 1: Find the existing tap handler in ContentView**

```bash
grep -nE "SpatialTapGesture|onTapGesture|tap location|pinnedIcao" ios/Tailspot/Tailspot/ContentView.swift | head -10
```

You'll likely find a tap handler that calls `closestTargetIcao24(in:at:...)` with the tap point + 100 px radius.

- [ ] **Step 2: Update the tap handler to implement the spec**

Replace the existing tap handler logic with:

```swift
// Inside the SpatialTapGesture / onTapGesture closure, where `tap` is
// the CGPoint of the tap and `observed` is the visible aircraft set:

let pinned = lockOn.state.targetIcao24

// 1) Tap directly on a plane (≤100 px radius): pin it (toggle if same)
if let icao = closestTargetIcao24(
    in: observed,
    at: tap,
    phoneHeadingDeg: phoneHeading,
    cameraElevationDeg: cameraElevation,
    screenSize: screenSize,
    hfovDeg: ContentView.baseHfovDeg / zoom,
    vfovDeg: ContentView.baseVfovDeg / zoom,
    lockZoneRadius: 100
) {
    if icao == pinned {
        lockOn.unpin()              // tap same plane = clear
    } else {
        lockOn.forceLock(targetIcao24: icao)
    }
    return
}

// 2) Tap on empty sky:
if pinned != nil {
    // Clear pin → all-frame.
    lockOn.unpin()
    return
}

// 3) No pin, tap on empty sky → "try harder": widen search to 250 px.
if let icao = closestTargetIcao24(
    in: observed,
    at: tap,
    phoneHeadingDeg: phoneHeading,
    cameraElevationDeg: cameraElevation,
    screenSize: screenSize,
    hfovDeg: ContentView.baseHfovDeg / zoom,
    vfovDeg: ContentView.baseVfovDeg / zoom,
    lockZoneRadius: 250
) {
    lockOn.forceLock(targetIcao24: icao)
    return
}

// 4) Truly empty — brief NO AIRCRAFT HERE ripple at tap point.
showEmptyTapRipple(at: tap)
```

- [ ] **Step 3: Add the empty-tap ripple feedback**

Add `@State private var emptyRipple: (CGPoint, Date)? = nil` near the other state.

Add the helper:

```swift
private func showEmptyTapRipple(at point: CGPoint) {
    let now = Date()
    emptyRipple = (point, now)
    // Auto-clear after 1s so the ripple doesn't linger.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        if let r = emptyRipple, r.1 == now {
            emptyRipple = nil
        }
    }
}
```

Render the ripple overlay:

```swift
// In the body, alongside the other AR overlays:
if let (point, since) = emptyRipple {
    EmptyTapRippleView(at: point, since: since)
        .allowsHitTesting(false)
}
```

`EmptyTapRippleView`:

```swift
private struct EmptyTapRippleView: View {
    let at: CGPoint
    let since: Date

    var body: some View {
        TimelineView(.animation) { ctx in
            let dt = ctx.date.timeIntervalSince(since)
            let progress = min(1.0, dt / 0.8)
            ZStack {
                Circle()
                    .stroke(Brand.Color.cyan.opacity(1.0 - progress), lineWidth: 1.5)
                    .frame(width: CGFloat(20 + progress * 80), height: CGFloat(20 + progress * 80))
                if progress < 0.95 {
                    Text("NO AIRCRAFT HERE")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Brand.Color.cyan.opacity(1.0 - progress))
                        .padding(.top, 60)
                }
            }
            .position(at)
        }
    }
}
```

- [ ] **Step 4: Build + run tests**

Build for simulator (`xcodebuild build ...`). Expected: `** BUILD SUCCEEDED **`. Run tests; all pass.

- [ ] **Step 5: Deploy + visually confirm**

```bash
bin/deploy
```

Confirm:
- Tap a visible plane → it pins.
- Tap a different visible plane → it re-pins.
- Tap the pinned plane → unpins.
- Tap empty sky with a pin → clears the pin.
- Tap empty sky with no pin and a plane somewhere in frame → pins that plane.
- Tap truly empty sky (no planes in frame at all) → brief `NO AIRCRAFT HERE` ripple.

- [ ] **Step 6: Commit**

```bash
git add ios/Tailspot/Tailspot/ContentView.swift
git commit -m "Tap-empty 'try harder' behavior + NO AIRCRAFT HERE ripple

Spec § 3.1 — tap-empty-while-pinned clears the pin; tap-empty-while-
unpinned widens the search radius (100 → 250 px) and pins the nearest
visible plane. Truly empty frame surfaces a brief ripple at the tap
point with NO AIRCRAFT HERE text.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Capture button affordance — `×N` corner badge

**Files:**
- Modify: `ios/Tailspot/Tailspot/ContentView.swift`

Spec § 3.2: single capture button; always live when ≥1 visible plane; disabled (40% opacity) otherwise; small magenta `×N` badge in the top-right corner when in multi-mode (no pin, ≥2 visible planes).

- [ ] **Step 1: Locate the capture button**

```bash
grep -nE "captureButton|CAPTURE|multiCatchButton" ios/Tailspot/Tailspot/ContentView.swift | head -20
```

Find the button(s) used today. Per CLAUDE.md, the current capture bar already exists with a center button.

- [ ] **Step 2: Compute capture mode + visible count**

In ContentView, in the TimelineView body where you already have `observed`, derive:

```swift
let visibleIcaos = observed.filter(\.isLikelyVisibleToObserver).map(\.aircraft.icao24)
let pinned = lockOn.state.targetIcao24
let captureMode: CaptureMode = {
    if let pin = pinned, visibleIcaos.contains(pin) { return .single(pin) }
    if visibleIcaos.isEmpty                          { return .disabled }
    if visibleIcaos.count == 1                       { return .single(visibleIcaos[0]) }
    return .multi(visibleIcaos)
}()
```

Define `CaptureMode`:

```swift
enum CaptureMode {
    case disabled
    case single(String)        // icao24
    case multi([String])       // icao24 list
}
```

- [ ] **Step 3: Update the capture button rendering**

Replace the existing center capture button with a single button parameterized by `captureMode`:

```swift
private func captureButton(mode: CaptureMode) -> some View {
    let isMulti: Bool = { if case .multi = mode { return true } else { return false } }()
    let count: Int = { if case .multi(let icaos) = mode { return icaos.count } else { return 0 } }()
    let isEnabled: Bool = { if case .disabled = mode { return false } else { return true } }()

    return Button {
        guard isEnabled else { return }
        performCatch(mode: mode)
    } label: {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Circle()
                    .fill(Brand.Color.bgPrimary.opacity(0.7))
                    .frame(width: 72, height: 72)
                Circle()
                    .strokeBorder(Brand.Color.cyan, lineWidth: 2.5)
                    .frame(width: 72, height: 72)
                Circle()
                    .fill(Brand.Color.cyan.opacity(0.15))
                    .frame(width: 60, height: 60)
                Text("CAPTURE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Brand.Color.cyan)
            }
            if isMulti {
                Text("×\(count)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Brand.Color.alertAdvisory, in: .capsule)
                    .overlay(Capsule().strokeBorder(Brand.Color.bgPrimary, lineWidth: 2))
                    .offset(x: 4, y: -4)
            }
        }
        .opacity(isEnabled ? 1.0 : 0.4)
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .accessibilityLabel(captureA11y(mode: mode))
}

private func captureA11y(mode: CaptureMode) -> String {
    switch mode {
    case .disabled:            return "Capture (no aircraft in view)"
    case .single(let icao):    return "Capture \(icao)"
    case .multi(let icaos):    return "Capture \(icaos.count) aircraft"
    }
}
```

Wire the button into the existing bottom capture-bar position. Remove any prior dedicated multi-catch button + magenta-zone overlay code (now subsumed). `performCatch(mode:)` is implemented in Task 8 — leave a stub for now:

```swift
private func performCatch(mode: CaptureMode) {
    // Implemented in Task 8 (merged capture path).
}
```

- [ ] **Step 4: Build + tests + deploy**

Build → tests → `bin/deploy`. Confirm visually:
- Empty frame → button is faded ~40%, disabled.
- One visible plane → button bright, no badge.
- Two+ visible planes, no pin → button bright, magenta `×N` badge in corner.
- Tap-pin one plane → button bright, no badge (single mode).

- [ ] **Step 5: Commit**

```bash
git add ios/Tailspot/Tailspot/ContentView.swift
git commit -m "Capture button: ×N corner badge for multi, disabled when empty

Spec § 3.2 — single always-present capture button. Visible-count
drives mode (disabled / single / multi). Multi shows a small magenta
×N badge in the top-right corner of the circular button. Pin
overrides multi → single mode (no badge).

Removes the prior dedicated multi-catch button + magenta-zone
chrome. performCatch() is stubbed; merged path lands in Task 8.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Merged `performCatch` path with dedup gate

**Files:**
- Modify: `ios/Tailspot/Tailspot/ContentView.swift`

Spec § 9.4: merge `performAutoCatch` (single) and `performMultiCatch` (multi) into one entry point. For each target icao24: check `Catch.exists` — if true, mark as duplicate; if false, insert. Capture one camera JPEG, attach to each new row.

- [ ] **Step 1: Locate the existing catch insertion paths**

```bash
grep -nE "performAutoCatch|performMultiCatch|captureBridge|ctx\.insert" ios/Tailspot/Tailspot/ContentView.swift | head -20
```

Note the existing capture-bridge flow that produces the JPEG filename.

- [ ] **Step 2: Implement `performCatch(mode:)`**

Replace the stub (from Task 7) with:

```swift
private func performCatch(mode: CaptureMode) {
    let icaos: [String]
    switch mode {
    case .disabled:           return
    case .single(let icao):   icaos = [icao]
    case .multi(let list):    icaos = list
    }

    // Snapshot what we know about each icao24 right now. We need the
    // observer location + each aircraft's slant distance + metadata
    // for the new Catch rows.
    guard let observerLoc = location.lastFix else { return }
    let observerLat = observerLoc.coordinate.latitude
    let observerLon = observerLoc.coordinate.longitude
    let visibleByIcao = Dictionary(uniqueKeysWithValues: adsb.observed.map { ($0.aircraft.icao24, $0) })

    // Photo capture — one shot, reused for every new row.
    captureBridge.captureJPEG { url in
        let filename = url.flatMap { CatchPhotoStore.persist(jpegAt: $0) }

        var newCatches: [Catch] = []
        var duplicates: [String] = []

        for icao in icaos {
            if Catch.exists(icao24: icao, in: modelContext) {
                duplicates.append(icao)
                continue
            }
            guard let obs = visibleByIcao[icao] else { continue }
            let c = Catch(
                icao24: icao,
                callsign: obs.aircraft.callsign,
                model: obs.metadata?.model,
                manufacturer: obs.metadata?.manufacturer,
                operatorName: obs.metadata?.operatorCallsign ?? obs.metadata?.owner,
                caughtAt: Date(),
                observerLat: observerLat,
                observerLon: observerLon,
                slantDistanceMeters: obs.slantDistanceMeters,
                photoFilename: filename
            )
            modelContext.insert(c)
            newCatches.append(c)
        }
        do { try modelContext.save() } catch {
            Log.adsb.error("Save failed: \(error.localizedDescription, privacy: .public)")
        }

        presentReveal(newCatches: newCatches, duplicates: duplicates)
    }
}
```

Field names (`observerLat`, `manufacturer`, `operatorName`, `photoFilename`, etc.) come from the existing `Catch` initializer in the current codebase. If the snapshot fields are slightly different (e.g., metadata accessor names), adjust to match what's actually on `ObservedAircraft.metadata` and `Catch.init` in this repo.

- [ ] **Step 3: Stub the reveal presentation**

```swift
private func presentReveal(newCatches: [Catch], duplicates: [String]) {
    // Implementation lands in Task 10 (CardReveal duplicate state) +
    // Task 11 (MultiCatchReveal staggered + combo). For now, present
    // a single-card reveal for the first new catch (preserving today's
    // behavior) and ignore duplicates. Tasks 10/11 will branch on the
    // newCatches.count + duplicates.count to pick the right surface.
    if let first = newCatches.first {
        pendingReveal = first
    }
}
```

- [ ] **Step 4: Delete the old `performAutoCatch` / `performMultiCatch` functions**

Remove the entire body of each, leaving the new `performCatch(mode:)` as the sole entry point. Remove any `captureInFlight` guards if they referenced the old call sites; if you keep `captureInFlight`, set it inside `performCatch` instead.

- [ ] **Step 5: Build + run tests**

Tests pass. Build succeeds.

- [ ] **Step 6: Deploy + visually confirm**

```bash
bin/deploy
```

Confirm:
- Catch a single plane → CardReveal flashes (existing behavior, unchanged at this point).
- Catch a multi (2+ in zone, no pin) → CardReveal of just the first new tail (multi-staggered reveal lands in Task 11; this is the intermediate state).
- Try to catch the same plane twice → first catch reveals as normal, second tap fires but nothing changes in the hangar (count stays unique). No reveal yet on dup; Task 10 wires it.

- [ ] **Step 7: Commit**

```bash
git add ios/Tailspot/Tailspot/ContentView.swift
git commit -m "Merge capture paths into performCatch(mode:) with dedup gate

Spec § 9.4 — single entry point parameterized by CaptureMode. For
each icao24: Catch.exists check → if true, mark duplicate; if false,
insert. One camera JPEG captured, attached to every new Catch row.
Removes the separate performAutoCatch / performMultiCatch paths.

Reveal presentation is stubbed to today's single-card path; Tasks 10
& 11 wire the duplicate stamp + staggered multi-reveal.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: `RevealAudio` helper

**Files:**
- Create: `ios/Tailspot/Tailspot/RevealAudio.swift`

Spec § 3.3: multi-catch reveal plays an ascending chime per card. Use `AudioServicesPlaySystemSoundID` with a small set of system sounds (no asset bundling). Each card's chime is one rung up the ladder; final card hits the loudest.

- [ ] **Step 1: Create the file**

```swift
//
//  RevealAudio.swift
//  Tailspot
//
//  Tiny wrapper around AudioServicesPlaySystemSoundID for the
//  multi-catch reveal's ascending chime. Uses iOS system sounds —
//  no bundled AIFF assets, no AVAudioEngine setup. Spec § 3.3,
//  follow-up § 11.1.
//

import AudioToolbox
import UIKit

enum RevealAudio {
    /// System sound IDs picked by ear for an ascending feel. Adjust
    /// freely — these are not pinned by tests. iPhone sound IDs are
    /// documented at https://github.com/TUNER88/iOSSystemSoundsLibrary.
    /// 1057 (Tink) → 1103 (BeginRecording) → 1054 (Anticipate)
    /// → 1304 (Headset In) → 1407 (Photo Shutter).
    private static let chimeLadder: [SystemSoundID] = [
        1057, 1103, 1054, 1304, 1407
    ]

    /// Plays the chime at the given step (0-based). Clamps to the
    /// last rung if `step` exceeds the ladder length.
    static func playChime(step: Int) {
        let safeStep = min(max(0, step), chimeLadder.count - 1)
        AudioServicesPlaySystemSound(chimeLadder[safeStep])
    }

    /// Convenience: play a medium haptic tap simultaneously with the
    /// chime — used by MultiCatchReveal's card landing.
    @MainActor
    static func tap(step: Int, intensity: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        playChime(step: step)
        let gen = UIImpactFeedbackGenerator(style: intensity)
        gen.prepare()
        gen.impactOccurred()
    }
}
```

- [ ] **Step 2: Build the simulator target**

```bash
xcodebuild build -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' 2>&1 | grep -E "error:|BUILD" | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add ios/Tailspot/Tailspot/RevealAudio.swift
git commit -m "Add RevealAudio helper for multi-catch chime + haptic

Spec § 3.3 — ascending system-sound ladder + medium haptic. Used by
Task 11's staggered MultiCatchReveal rework. Wraps
AudioServicesPlaySystemSoundID + UIImpactFeedbackGenerator so the
reveal code stays focused on layout / timing.

Sound IDs chosen by ear, not pinned by tests; revisit in spec § 11.1
once the reveal lands on device.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Duplicate-state reveal — `ALREADY CAUGHT` stamp

**Files:**
- Modify: `ios/Tailspot/Tailspot/CardReveal.swift`
- Modify: `ios/Tailspot/Tailspot/ContentView.swift`

Spec § 3.4: duplicate catches still fire a reveal, but the card shows a diagonal red-bordered `ALREADY CAUGHT` stamp and the loud bloom/haptic/audio are muted.

- [ ] **Step 1: Add a duplicate flag to `CardReveal`**

In `CardReveal.swift`, locate the existing struct (likely `struct CardReveal: View` taking a `Catch` or `HangarRow`). Add an `isDuplicate: Bool = false` parameter.

```swift
struct CardReveal: View {
    let catchRow: Catch  // or whatever the existing param is named
    var isDuplicate: Bool = false
    // ...existing body...
}
```

- [ ] **Step 2: Render the stamp + mute the loud bits when duplicate**

Inside the body, after the PokeCard render block, add:

```swift
if isDuplicate {
    Text("ALREADY\nCAUGHT")
        .font(.system(size: 16, weight: .bold, design: .monospaced))
        .tracking(2)
        .multilineTextAlignment(.center)
        .foregroundStyle(Brand.Color.alertWarning)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Brand.Color.bgPrimary.opacity(0.85))
        .overlay(
            Rectangle().strokeBorder(Brand.Color.alertWarning, lineWidth: 1.5)
        )
        .rotationEffect(.degrees(-18))
}
```

Find any rarity bloom / light ray / haptic firing code in `CardReveal.body` or `.onAppear` and gate it behind `if !isDuplicate { ... }`. If the reveal currently fires a haptic in `.onAppear`, wrap it.

- [ ] **Step 3: Plumb the duplicate flag through ContentView**

Update `pendingReveal` to carry both the catch row AND the duplicate flag. Easiest: change `@State private var pendingReveal: Catch?` to a small bundle:

```swift
struct PendingReveal: Identifiable {
    let id = UUID()
    let catchRow: Catch
    let isDuplicate: Bool
}

@State private var pendingReveal: PendingReveal?
```

Update `presentReveal` (stubbed in Task 8):

```swift
private func presentReveal(newCatches: [Catch], duplicates: [String]) {
    // Task 11 will branch to MultiCatchReveal when newCatches.count + duplicates.count > 1.
    // For now: single-card path with the duplicate flag if applicable.
    if let first = newCatches.first {
        pendingReveal = PendingReveal(catchRow: first, isDuplicate: false)
    } else if let dupIcao = duplicates.first {
        // No new catch — pure duplicate. Synthesize a transient
        // Catch-shaped value for the reveal. The existing Catch row
        // for this icao24 is what we render.
        let descriptor = FetchDescriptor<Catch>(predicate: #Predicate { $0.icao24 == dupIcao })
        if let existing = try? modelContext.fetch(descriptor).first {
            pendingReveal = PendingReveal(catchRow: existing, isDuplicate: true)
        }
    }
}
```

Where the sheet is currently presented (`.fullScreenCover(item: $pendingReveal) { ... }` or similar), pass the flag through:

```swift
.fullScreenCover(item: $pendingReveal) { pending in
    CardReveal(catchRow: pending.catchRow, isDuplicate: pending.isDuplicate)
}
```

- [ ] **Step 4: Build + tests + deploy**

```bash
xcodebuild build -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' 2>&1 | grep -E "error:|BUILD" | tail -5
```

Run tests. Then `bin/deploy`. Visually:
- Catch a fresh plane → normal CardReveal with bloom + haptic.
- Catch the same plane again → CardReveal fires, but card has a diagonal red `ALREADY CAUGHT` stamp, no bloom, no haptic.

- [ ] **Step 5: Commit**

```bash
git add ios/Tailspot/Tailspot/CardReveal.swift ios/Tailspot/Tailspot/ContentView.swift
git commit -m "CardReveal: ALREADY CAUGHT stamp for duplicate catches

Spec § 3.4 — duplicate catches still fire a reveal but with the
diagonal red ALREADY CAUGHT stamp and the bloom/haptic/audio
suppressed. ContentView's pendingReveal becomes a PendingReveal
bundle carrying the duplicate flag.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: Multi-catch reveal — staggered fan + combo banner

**Files:**
- Modify: `ios/Tailspot/Tailspot/MultiCatchReveal.swift`
- Modify: `ios/Tailspot/Tailspot/ContentView.swift`

Spec § 3.3: when ≥2 cards land in one fire (new tails + dups combined), present `MultiCatchReveal`. Cards stagger in ~250 ms apart, each landing triggers `RevealAudio.tap(step:)`, combo banner builds (`CATCH ×1 → …×2 → COMBO ×3 +N pts`), dups appear inline with the stamp but don't add to combo.

- [ ] **Step 1: Locate the existing MultiCatchReveal struct**

Read `ios/Tailspot/Tailspot/MultiCatchReveal.swift` to understand the current signature + layout. Per CLAUDE.md, it currently shows up-to-5 PokeCards in a fan with a combo receipt.

- [ ] **Step 2: Add a staggered-reveal driver**

Restructure the body to use an internal `@State private var revealedIndex: Int = -1` that ticks up over time:

```swift
struct MultiCatchReveal: View {
    let entries: [Entry]    // each Entry knows its catchRow + isDuplicate
    var onDismiss: () -> Void

    struct Entry: Identifiable {
        let id = UUID()
        let catchRow: Catch
        let isDuplicate: Bool
    }

    @State private var revealedIndex: Int = -1

    var body: some View {
        let stagger: TimeInterval = 0.25

        return ZStack {
            // Backdrop
            Brand.Color.bgPrimary.opacity(0.95).ignoresSafeArea()

            // Cards fan
            HStack(spacing: -40) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                    PokeCardView(
                        plane: PokePlane(catchRecord: entry.catchRow),
                        size: .md
                    )
                    .overlay {
                        if entry.isDuplicate {
                            // Re-use the same stamp from CardReveal
                            // (small dup of the visual; keep it inline
                            // here so MultiCatchReveal stays
                            // self-contained).
                            Text("ALREADY\nCAUGHT")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .tracking(1.5)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(Brand.Color.alertWarning)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Brand.Color.bgPrimary.opacity(0.85))
                                .overlay(Rectangle().strokeBorder(Brand.Color.alertWarning, lineWidth: 1.5))
                                .rotationEffect(.degrees(-18))
                        }
                    }
                    .rotationEffect(.degrees(Double(idx - entries.count / 2) * 6))
                    .opacity(idx <= revealedIndex ? 1.0 : 0.0)
                    .offset(y: idx <= revealedIndex ? 0 : 40)
                    .animation(.spring(response: 0.45, dampingFraction: 0.7), value: revealedIndex)
                }
            }

            // Combo banner — appears after the first card
            VStack {
                if revealedIndex >= 0 {
                    comboBanner.transition(.opacity)
                }
                Spacer()
                if revealedIndex >= entries.count - 1 {
                    Button { onDismiss() } label: {
                        Text("KEEP SPOTTING")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.black.opacity(0.85))
                            .padding(.horizontal, 28).padding(.vertical, 12)
                            .background(Brand.Color.cyan, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 32)
                }
            }
        }
        .task {
            // Stagger: reveal one card at a time.
            for i in 0..<entries.count {
                revealedIndex = i
                let entry = entries[i]
                if !entry.isDuplicate {
                    RevealAudio.tap(step: i)
                }
                try? await Task.sleep(for: .seconds(stagger))
            }
        }
    }

    private var comboBanner: some View {
        let newOnesSoFar = entries.prefix(revealedIndex + 1).filter { !$0.isDuplicate }.count
        let totalPoints = entries.prefix(revealedIndex + 1)
            .filter { !$0.isDuplicate }
            .map { $0.catchRow.resolvedRarity.basePoints }
            .reduce(0, +)
        let label: String = {
            if newOnesSoFar <= 1 { return "CATCH ×\(newOnesSoFar)" }
            return "COMBO ×\(newOnesSoFar) +\(totalPoints) pts"
        }()
        return Text(label)
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .tracking(2)
            .foregroundStyle(Brand.Color.alertAdvisory)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Brand.Color.alertAdvisory.opacity(0.16), in: .capsule)
            .padding(.top, 80)
    }
}
```

(If the existing `PokeCardView` `plane:` init takes a different value type, adjust. The key behaviors: stagger via task loop + per-card audio + dup inline stamp + combo banner counting only new tails.)

- [ ] **Step 3: Update ContentView to present MultiCatchReveal for multi-fire**

In `presentReveal(newCatches:duplicates:)`:

```swift
private func presentReveal(newCatches: [Catch], duplicates: [String]) {
    let totalCount = newCatches.count + duplicates.count
    if totalCount <= 1 {
        // Same single-card path as Task 10.
        if let first = newCatches.first {
            pendingReveal = PendingReveal(catchRow: first, isDuplicate: false)
        } else if let dupIcao = duplicates.first,
                  let existing = fetchExisting(icao: dupIcao) {
            pendingReveal = PendingReveal(catchRow: existing, isDuplicate: true)
        }
        return
    }

    // Multi: combine new + duplicates into Entry list, preserving the
    // order the user "saw" them in (icaos order from the lock state).
    var entries: [MultiCatchReveal.Entry] = []
    for c in newCatches {
        entries.append(MultiCatchReveal.Entry(catchRow: c, isDuplicate: false))
    }
    for dupIcao in duplicates {
        if let existing = fetchExisting(icao: dupIcao) {
            entries.append(MultiCatchReveal.Entry(catchRow: existing, isDuplicate: true))
        }
    }
    pendingMultiReveal = entries
}

private func fetchExisting(icao: String) -> Catch? {
    let descriptor = FetchDescriptor<Catch>(predicate: #Predicate { $0.icao24 == icao })
    return try? modelContext.fetch(descriptor).first
}
```

Add `@State private var pendingMultiReveal: [MultiCatchReveal.Entry]? = nil`. Present it:

```swift
.fullScreenCover(isPresented: Binding(
    get: { pendingMultiReveal != nil },
    set: { if !$0 { pendingMultiReveal = nil } }
)) {
    if let entries = pendingMultiReveal {
        MultiCatchReveal(entries: entries) { pendingMultiReveal = nil }
    }
}
```

- [ ] **Step 4: Build + run tests**

Tests pass. Build clean.

- [ ] **Step 5: Deploy + visually confirm**

```bash
bin/deploy
```

Confirm:
- Single catch → normal CardReveal.
- Multi catch (≥2 fresh) → cards fan in staggered with haptic + chime per card; combo banner builds across reveals; final state shows combo total + KEEP SPOTTING button.
- Multi with a dup mixed in → dup card has the stamp inline; combo only counts new tails.

- [ ] **Step 6: Commit**

```bash
git add ios/Tailspot/Tailspot/MultiCatchReveal.swift ios/Tailspot/Tailspot/ContentView.swift
git commit -m "MultiCatchReveal: staggered fan + haptic + chime + combo banner

Spec § 3.3 — the hype peak. Cards reveal one-at-a-time with a 250ms
stagger, RevealAudio.tap(step:) per card. Combo banner builds from
'CATCH ×1' → 'COMBO ×N +M pts' counting only new (non-duplicate)
tails. Duplicates render inline with the ALREADY CAUGHT stamp.

ContentView's presentReveal branches on the combined count (new +
dups): ≤1 → single CardReveal; ≥2 → MultiCatchReveal.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: Hangar segmented switcher

**Files:**
- Create: `ios/Tailspot/Tailspot/HangarSegmentedSwitcher.swift`
- Modify: `ios/Tailspot/Tailspot/HangarView.swift`

Spec § 4.1: 3-segment control below the toolbar — `Sets` · `Recent` · `Trophies`. Default Sets. Persists via `@AppStorage("tailspot.hangar.view")`.

- [ ] **Step 1: Define the segment enum + switcher view**

Create `HangarSegmentedSwitcher.swift`:

```swift
//
//  HangarSegmentedSwitcher.swift
//  Tailspot
//
//  3-segment switcher used at the top of the Hangar sheet. Cyan-on-
//  bgElevated, matches the canvas design. Spec § 4.1.
//

import SwiftUI

enum HangarSegment: String, CaseIterable, Identifiable {
    case sets, recent, trophies
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sets:     return "Sets"
        case .recent:   return "Recent"
        case .trophies: return "Trophies"
        }
    }
}

struct HangarSegmentedSwitcher: View {
    @Binding var selection: HangarSegment

    var body: some View {
        HStack(spacing: 2) {
            ForEach(HangarSegment.allCases) { seg in
                Button {
                    selection = seg
                } label: {
                    Text(seg.label)
                        .font(.system(size: 13, weight: selection == seg ? .semibold : .medium))
                        .foregroundStyle(selection == seg ? Brand.Color.textPrimary : Brand.Color.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            selection == seg
                                ? Brand.Color.bgSurface
                                : Color.clear,
                            in: .rect(cornerRadius: 8)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
```

- [ ] **Step 2: Wire it into HangarView**

In `HangarView.swift`:

```swift
@AppStorage("tailspot.hangar.view") private var rawSegment: String = HangarSegment.sets.rawValue

private var segment: Binding<HangarSegment> {
    Binding(
        get: { HangarSegment(rawValue: rawSegment) ?? .sets },
        set: { rawSegment = $0.rawValue }
    )
}
```

In the body, replace the body content (the current `cardGrid`/`emptyState`) with:

```swift
VStack(spacing: 0) {
    HangarSegmentedSwitcher(selection: segment)
    Group {
        switch segment.wrappedValue {
        case .sets:     HangarSetsView()      // stub for now
        case .recent:   HangarRecentView()    // Task 13
        case .trophies: HangarTrophiesView()  // Task 14
        }
    }
}
.background(Brand.Color.bgPrimary)
```

For now, stub `HangarSetsView`, `HangarRecentView`, `HangarTrophiesView` as empty SwiftUI views:

```swift
// Temporary stubs — fleshed out in Tasks 13-16.
struct HangarSetsView: View     { var body: some View { Text("Sets") } }
struct HangarRecentView: View   { var body: some View { Text("Recent") } }
struct HangarTrophiesView: View { var body: some View { Text("Trophies") } }
```

Keep the toolbar + count pill + delete alert + empty-state intact at the HangarView level. (Empty-state continues to show when `catches.isEmpty`, replacing the switcher entirely — easier than threading "empty" into each segment.)

- [ ] **Step 3: Build + tests + deploy**

Build clean. Tests pass. `bin/deploy`. Visually confirm:
- 3-segment control under the toolbar. Tap each segment → corresponding placeholder text appears.
- Selection persists across sheet open/close (kill app + reopen still lands on last-chosen segment).

- [ ] **Step 4: Commit**

```bash
git add ios/Tailspot/Tailspot/HangarSegmentedSwitcher.swift ios/Tailspot/Tailspot/HangarView.swift
git commit -m "Hangar shell: 3-segment Sets / Recent / Trophies switcher

Spec § 4.1 — segment selection persists via @AppStorage. Per-segment
view bodies stubbed; flesh out in Tasks 13-16.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 13: `HangarRecentView` extraction

**Files:**
- Create: `ios/Tailspot/Tailspot/HangarRecentView.swift`
- Modify: `ios/Tailspot/Tailspot/HangarView.swift`

Move the current `cardGrid` body from `HangarView` into `HangarRecentView.swift`. Drop the filter chips entirely (Recent is "what I just got" — no filter). Keep the long-press delete behavior.

- [ ] **Step 1: Create `HangarRecentView.swift`**

```swift
//
//  HangarRecentView.swift
//  Tailspot
//
//  Recent-view body for the Hangar sheet — chronological dedup'd
//  MiniCard grid sorted by first-catch desc. No filters; that's a
//  Sets-view affordance. Spec § 6.
//

import SwiftUI
import SwiftData

struct HangarRecentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]
    @State private var rowToDelete: HangarRow?

    private var rows: [HangarRow] {
        HangarGrouping.group(catches, by: .recent).first?.rows ?? []
    }

    var body: some View {
        ScrollView {
            if rows.isEmpty {
                Text("No catches yet")
                    .font(Brand.Font.body)
                    .foregroundStyle(Brand.Color.textTertiary)
                    .padding(.top, 32)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ],
                    spacing: 12
                ) {
                    ForEach(rows) { row in
                        NavigationLink(value: row) {
                            MiniCardView(row: row)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                rowToDelete = row
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
        }
        .background(Brand.Color.bgPrimary)
        .alert(
            deleteAlertTitle,
            isPresented: Binding(
                get: { rowToDelete != nil },
                set: { if !$0 { rowToDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let row = rowToDelete { performDelete(row: row) }
            }
            Button("Cancel", role: .cancel) {
                rowToDelete = nil
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    private var deleteAlertTitle: String {
        guard let row = rowToDelete else { return "" }
        let cs = row.mostRecent.callsign?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? row.icao24
        // Post-dedupe (Task 1+8), row.count is always 1, so this always
        // hits the singular branch.
        return "Delete catch of \(cs)?"
    }

    private func performDelete(row: HangarRow) {
        for c in row.allCatches {
            modelContext.delete(c)
        }
        do { try modelContext.save() } catch {
            Log.adsb.error("Hangar delete failed for \(row.icao24, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        rowToDelete = nil
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
```

- [ ] **Step 2: Delete the inlined Recent stub in `HangarView.swift`**

Remove the `struct HangarRecentView: View { var body: some View { Text("Recent") } }` stub from Task 12. The new file replaces it.

- [ ] **Step 3: Build + tests + deploy**

```bash
bin/deploy
```

Visually confirm:
- Tap Recent segment → dedup'd MiniCard grid sorted by first-catch desc.
- Long-press a card → context menu with Delete; confirm alert reads `Delete catch of …?` (singular).
- Tap a card → pushes to CatchDetailView (current behavior; we rewrite the destination in Task 17).

- [ ] **Step 4: Commit**

```bash
git add ios/Tailspot/Tailspot/HangarRecentView.swift ios/Tailspot/Tailspot/HangarView.swift
git commit -m "Extract HangarRecentView; drop filter chips

Spec § 6 — Recent is 'what I just got,' no filters. Long-press delete
context menu preserved. Delete alert now always singular (post-Task
8 dedup means row.count is always 1).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 14: `HangarTrophiesView` + Profile fallout

**Files:**
- Create: `ios/Tailspot/Tailspot/HangarTrophiesView.swift`
- Modify: `ios/Tailspot/Tailspot/TrophiesScreen.swift` (extract body into a reusable view)
- Modify: `ios/Tailspot/Tailspot/ProfileScreen.swift`

Spec § 4.2: Trophies moves out of Profile into the Hangar's Trophies segment. Rip the body of `TrophiesScreen` out into a shared view; the Hangar segment renders that body; the existing standalone screen either deletes or wraps the shared view.

- [ ] **Step 1: Identify TrophiesScreen's body**

Read `ios/Tailspot/Tailspot/TrophiesScreen.swift`. Identify the `body` content (toolbar + hero strip + Earned/In-progress/Locked sections).

- [ ] **Step 2: Create `HangarTrophiesView.swift` containing the rendering body**

```swift
//
//  HangarTrophiesView.swift
//  Tailspot
//
//  Trophies-view body for the Hangar sheet. Renders the existing
//  achievement ladder (Earned / In progress / Locked partition) plus
//  the hero strip headline. Spec § 4.2, § 7.
//

import SwiftUI
import SwiftData

struct HangarTrophiesView: View {
    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]

    var body: some View {
        // <Move the relevant body subviews from TrophiesScreen.swift's
        //  body in here — the partition logic + hero strip + tier
        //  rendering. The query above replaces whatever TrophiesScreen
        //  used to source catches from.>
        // Important: keep the SAME visual treatment — hex-frame icons,
        // tier colors, headline format ("N of M · K close to unlocking").
    }
}
```

When porting, drop the navigation-toolbar bits (the Hangar's outer shell provides the toolbar). Keep the inner ScrollView + section partitioning intact.

- [ ] **Step 3: Reduce `TrophiesScreen.swift` to a thin wrapper or delete it**

Two viable approaches; pick whichever the existing codebase organization prefers:

A. **Delete `TrophiesScreen.swift`.** Find every nav push to `TrophiesScreen()` and replace with a navigation to the Hangar sheet (default to Trophies segment). Update `@AppStorage("tailspot.hangar.view")` to `"trophies"` if appropriate before presenting.

B. **Make `TrophiesScreen` a thin wrapper around `HangarTrophiesView`.** This keeps any current standalone push paths working while sharing the body. Less invasive.

Recommended: **B for this commit; A as a follow-up.**

```swift
// TrophiesScreen.swift becomes:
struct TrophiesScreen: View {
    var body: some View {
        HangarTrophiesView()
            .navigationTitle("Trophies")
            .navigationBarTitleDisplayMode(.inline)
    }
}
```

- [ ] **Step 4: Remove Profile's Trophies entry points**

In `ios/Tailspot/Tailspot/ProfileScreen.swift`:

- Delete the `RECENT MEDALS` strip (the horizontal-scroll trophy cards row).
- Delete the `Trophies` row in the Quick Links section. If there's a section header `Trophies` or `Recent trophies`, remove it.
- Keep Map, Stats, Catches links intact.

- [ ] **Step 5: Build + run tests**

Build clean. Tests pass.

- [ ] **Step 6: Deploy + visually confirm**

```bash
bin/deploy
```

Confirm:
- Hangar → Trophies segment renders the achievement ladder identically to the old standalone screen.
- Profile screen no longer has the Recent Medals strip or Trophies link.
- Any remaining nav links to `TrophiesScreen()` (settings, etc.) still work via the thin wrapper.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Trophies: move into Hangar Trophies segment, gut Profile entries

Spec § 4.2, § 7 — TrophiesScreen body extracted into HangarTrophiesView
so the Hangar can host it. Standalone TrophiesScreen becomes a thin
wrapper for any remaining push paths. ProfileScreen loses its RECENT
MEDALS strip + Trophies quick link.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 15: `HangarSetsView` — set landing tiles (rich)

**Files:**
- Create: `ios/Tailspot/Tailspot/HangarSetsView.swift`

Spec § 5.1: scrolling list of 7 set tiles. Each tile = type-glyph chip + set title + slot-progress `M / N` (slots with ≥1 caught tail / total slots) + thumbnail strip showing caught vs `?` slots.

- [ ] **Step 1: Create the file**

```swift
//
//  HangarSetsView.swift
//  Tailspot
//
//  Sets-view body for the Hangar sheet. Vertical list of 7 set tiles
//  (one per AircraftType). Each tile shows slot-progress + a
//  thumbnail strip of caught vs locked model slots. Tap → SetDetailView.
//  Spec § 5.1.
//

import SwiftUI
import SwiftData

struct HangarSetsView: View {
    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]

    private var rows: [HangarRow] {
        HangarGrouping.group(catches, by: .recent).first?.rows ?? []
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(PokeSets.all) { set in
                    NavigationLink(value: SetDetailRoute(setId: set.id)) {
                        SetTile(set: set, slots: HangarGrouping.resolveSlots(for: set, in: rows))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Brand.Color.bgPrimary)
    }
}

/// Stable navigation target — set identified by its id.
struct SetDetailRoute: Hashable {
    let setId: String
}

private struct SetTile: View {
    let set: PokeSet
    let slots: [ModelSlot]

    private var caughtCount: Int { slots.filter(\.isCaught).count }
    private var totalCount: Int { slots.count }
    private var isLocked: Bool { caughtCount == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(set.type.tint)
                    Text(set.type.glyph)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black.opacity(0.7))
                }
                .frame(width: 30, height: 30)

                Text(set.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.Color.textPrimary)
                Spacer()
                Text("\(caughtCount) / \(totalCount)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(isLocked ? Brand.Color.textTertiary : set.type.tint)
                    .monospacedDigit()
            }

            // Thumbnail strip — one cell per slot, left-to-right.
            HStack(spacing: 4) {
                ForEach(slots) { slot in
                    Group {
                        if slot.isCaught {
                            VStack(spacing: 0) {
                                Rectangle().fill(set.type.tint).frame(height: 1)
                                Text(slot.entry.shortLabel)  // e.g. "737" — see note
                                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Brand.Color.textPrimary)
                                    .frame(maxWidth: .infinity, minHeight: 21)
                                    .background(Brand.Color.bgSurface)
                            }
                        } else {
                            Text("?")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Brand.Color.textTertiary.opacity(0.5))
                                .frame(maxWidth: .infinity, minHeight: 22)
                                .background(Brand.Color.bgSurface)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
        }
        .padding(12)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 10))
        .opacity(isLocked ? 0.55 : 1.0)
    }
}
```

`PokeSetEntry.shortLabel` is illustrative — use whatever short identifier the entry already exposes (might be `tokenAbbreviation`, `displayName`, or you may need to add a small helper that pulls the first token of `modelMatchTokens`). Pick the field that gives a 3-5-char abbreviation suitable for the strip.

- [ ] **Step 2: Remove the inline stub in HangarView**

Delete the temporary `struct HangarSetsView: View { ... Text("Sets") ... }` stub from Task 12.

- [ ] **Step 3: Wire the navigation destination**

In `HangarView.swift`, alongside the existing `.navigationDestination(for: HangarRow.self) { ... }`, add:

```swift
.navigationDestination(for: SetDetailRoute.self) { route in
    if let set = PokeSets.all.first(where: { $0.id == route.setId }) {
        SetDetailView(set: set)
    }
}
```

`SetDetailView` lands in Task 16. Stub it for now:

```swift
// At the bottom of HangarSetsView.swift or in a new file:
struct SetDetailView: View {
    let set: PokeSet
    var body: some View { Text(set.title).foregroundStyle(Brand.Color.textPrimary) }
}
```

- [ ] **Step 4: Build + run tests + deploy**

`bin/deploy`. Visually confirm:
- Hangar → Sets segment shows 7 tiles vertically. Each tile has type-tinted chip + name + `M/N` + thumbnail strip.
- Caught slots have a top rail in the type tint + a short abbreviation; locked slots show `?`.
- 0/N sets show faded with all `?` cells.
- Tap a tile → pushes to SetDetailView (the stub for now).

- [ ] **Step 5: Commit**

```bash
git add ios/Tailspot/Tailspot/HangarSetsView.swift ios/Tailspot/Tailspot/HangarView.swift
git commit -m "HangarSetsView: rich set tiles with thumbnail strip

Spec § 5.1 — 7 set tiles, slot-progress count (filled slots / total
slots), thumbnail strip showing caught vs locked slots. Tap →
SetDetailView (stub; Task 16 fleshes out).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 16: `SetDetailView` — model slot grid

**Files:**
- Create: `ios/Tailspot/Tailspot/SetDetailView.swift`
- Modify: `ios/Tailspot/Tailspot/HangarSetsView.swift` (remove the stub)

Spec § 5.2: large type chip + set title + `M of N caught` + progress bar + next-milestone line + 2-col slot grid. Caught slot = 2pt top rail + `#NN` + model name + `×K tails`. Locked = dim card + `?` + expected model name; tap → small hint sheet.

- [ ] **Step 1: Create `SetDetailView.swift`**

```swift
//
//  SetDetailView.swift
//  Tailspot
//
//  Set detail screen — model slot grid for one PokeSet. Each caught
//  slot shows ×K distinct tails; tap → ModelSlotDetailView (Task 17).
//  Locked slot tap → bottom-sheet hint. Spec § 5.2.
//

import SwiftUI
import SwiftData

struct SetDetailView: View {
    let set: PokeSet
    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]
    @State private var hintSlot: ModelSlot? = nil

    private var rows: [HangarRow] {
        HangarGrouping.group(catches, by: .recent).first?.rows ?? []
    }
    private var slots: [ModelSlot] {
        HangarGrouping.resolveSlots(for: set, in: rows)
    }
    private var caughtCount: Int { slots.filter(\.isCaught).count }
    private var totalCount: Int { slots.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                slotGrid
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Brand.Color.bgPrimary)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Brand.Color.bgPrimary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(item: $hintSlot) { slot in
            LockedSlotHint(slot: slot)
                .presentationDetents([.height(180)])
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(set.type.tint)
                    Text(set.type.glyph)
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black.opacity(0.7))
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(set.title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Brand.Color.textPrimary)
                    Text("\(caughtCount) of \(totalCount) caught")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(set.type.tint)
                }
                Spacer()
            }
            // Progress bar
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Brand.Color.bgElevated)
                    Rectangle().fill(set.type.tint)
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 3)
            .clipShape(Capsule())
            // Next-milestone line — optional; shown when a trophy ladder maps to this set.
            if let line = nextMilestoneLine {
                Text(line)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Brand.Color.textTertiary)
            }
        }
    }

    private var progress: Double {
        totalCount == 0 ? 0 : Double(caughtCount) / Double(totalCount)
    }

    /// Optional teaser text pulled from the Trophies ladder when a
    /// trophy maps to this set's progress (e.g., Wide Awake → wide-body).
    /// Returns nil if no mapping exists. Spec § 5.2.
    private var nextMilestoneLine: String? {
        // Implementation note: traverse Trophies.roster looking for an
        // achievement whose progress derives from this set's type, then
        // compute "N MORE FOR <next tier label>". Hidden if no match.
        // Until we wire this in detail, return nil — the line is
        // optional per spec.
        return nil
    }

    private var slotGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 6),
                GridItem(.flexible(), spacing: 6)
            ],
            spacing: 6
        ) {
            ForEach(slots) { slot in
                slotCell(slot)
            }
        }
    }

    @ViewBuilder
    private func slotCell(_ slot: ModelSlot) -> some View {
        let index = (slots.firstIndex(where: { $0.id == slot.id }) ?? 0) + 1
        if slot.isCaught {
            NavigationLink(value: ModelSlotRoute(setId: set.id, entryId: slot.entry.id)) {
                caughtCell(slot: slot, index: index)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                hintSlot = slot
            } label: {
                lockedCell(slot: slot, index: index)
            }
            .buttonStyle(.plain)
        }
    }

    private func caughtCell(slot: ModelSlot, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("#\(String(format: "%02d", index))")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(Brand.Color.textTertiary)
            Spacer(minLength: 4)
            Text(slot.entry.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Brand.Color.textPrimary)
                .lineLimit(1)
            Text("×\(slot.distinctTailCount) tails")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(set.type.tint)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Brand.Color.bgElevated,
            in: .rect(cornerRadius: 6)
        )
        .overlay(alignment: .top) {
            Rectangle().fill(set.type.tint).frame(height: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func lockedCell(slot: ModelSlot, index: Int) -> some View {
        VStack(spacing: 4) {
            Text("#\(String(format: "%02d", index))")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(Brand.Color.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("?")
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(Brand.Color.textTertiary)
            Text(slot.entry.displayName)
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundStyle(Brand.Color.textTertiary)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(
            Brand.Color.bgSurface,
            in: .rect(cornerRadius: 6)
        )
        .opacity(0.55)
    }
}

/// Stable navigation target for the model-slot detail (Task 17).
struct ModelSlotRoute: Hashable {
    let setId: String
    let entryId: String
}

private struct LockedSlotHint: View {
    let slot: ModelSlot
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LOCKED SLOT")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.textTertiary)
            Text("Catch a \(slot.entry.displayName) to fill this slot.")
                .font(Brand.Font.body)
                .foregroundStyle(Brand.Color.textPrimary)
            if let hint = slot.entry.operatorHint {
                Text("Often operated by \(hint).")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.Color.bgPrimary)
    }
}
```

`slot.entry.displayName` and `slot.entry.operatorHint` are illustrative — use whatever the existing `PokeSetEntry` exposes. If `operatorHint` doesn't exist, drop that line.

- [ ] **Step 2: Wire up navigation destination in HangarView**

In `HangarView.swift`, add alongside the existing `.navigationDestination(for: ...)`:

```swift
.navigationDestination(for: ModelSlotRoute.self) { route in
    if let set = PokeSets.all.first(where: { $0.id == route.setId }),
       let entry = set.entries.first(where: { $0.id == route.entryId }) {
        ModelSlotDetailView(set: set, entry: entry)
    }
}
```

Stub `ModelSlotDetailView` for now (Task 17 fleshes it out):

```swift
struct ModelSlotDetailView: View {
    let set: PokeSet
    let entry: PokeSetEntry
    var body: some View { Text(entry.displayName).foregroundStyle(Brand.Color.textPrimary) }
}
```

- [ ] **Step 3: Remove the temporary `SetDetailView` stub from HangarSetsView.swift**

Delete the placeholder added in Task 15.

- [ ] **Step 4: Build + run tests + deploy**

`bin/deploy`. Confirm:
- Tap a set tile → set detail with header (chip + title + `M of N caught` + progress bar).
- 2-col slot grid; caught slots show `×K tails`; locked slots show `?` + expected model.
- Tap caught slot → pushes to ModelSlotDetailView (stub).
- Tap locked slot → bottom sheet with hint.

- [ ] **Step 5: Commit**

```bash
git add ios/Tailspot/Tailspot/SetDetailView.swift ios/Tailspot/Tailspot/HangarSetsView.swift ios/Tailspot/Tailspot/HangarView.swift
git commit -m "SetDetailView: model slot grid with ×K tails + locked hints

Spec § 5.2 — large type chip + set title + slot-progress count +
progress bar + 2-col grid. Caught slots show ×K distinct tails; tap
→ ModelSlotDetailView (stub for Task 17). Locked slots → bottom
sheet hint. Next-milestone line stubbed; trophy mapping is a
future-tense improvement.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 17: `ModelSlotDetailView` — tail list

**Files:**
- Create: `ios/Tailspot/Tailspot/ModelSlotDetailView.swift`
- Modify: `ios/Tailspot/Tailspot/HangarView.swift` (remove stub)

Spec § 5.3: breadcrumb header + model name + `K distinct tails` + vertical list of distinct tails (each with rarity rail + callsign + icao24/operator + relative timestamp). Tap → Tail detail.

- [ ] **Step 1: Create the file**

```swift
//
//  ModelSlotDetailView.swift
//  Tailspot
//
//  The screen between Set detail and Tail detail — lists every
//  distinct tail (icao24) the user has caught of one model. Spec § 5.3.
//

import SwiftUI
import SwiftData

struct ModelSlotDetailView: View {
    let set: PokeSet
    let entry: PokeSetEntry
    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]

    private var rows: [HangarRow] {
        HangarGrouping.group(catches, by: .recent).first?.rows ?? []
    }
    private var tails: [HangarRow] {
        rows.filter { PokeSets.matches(catch: $0.mostRecent, entry: entry) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("#\(String(format: "%02d", indexInSet)) · \(set.title.uppercased())")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(Brand.Color.textTertiary)
                Text(entry.displayName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Brand.Color.textPrimary)
                Text("\(tails.count) distinct tail\(tails.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(set.type.tint)

                Text("TAILS YOU'VE CAUGHT")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(Brand.Color.textTertiary)
                    .padding(.top, 14)
                    .padding(.bottom, 4)

                VStack(spacing: 6) {
                    ForEach(tails) { row in
                        NavigationLink(value: row) {
                            tailRow(row)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Brand.Color.bgPrimary)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Brand.Color.bgPrimary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private var indexInSet: Int {
        (set.entries.firstIndex(where: { $0.id == entry.id }) ?? 0) + 1
    }

    private func tailRow(_ row: HangarRow) -> some View {
        let cs = row.mostRecent.callsign?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? row.icao24.uppercased()
        return HStack(spacing: 10) {
            Rectangle()
                .fill(row.rarity.tint)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(cs)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Brand.Color.cyan)
                Text("\(row.icao24) · \(row.mostRecent.operatorName ?? "—")")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(Brand.Color.textTertiary)
            }
            Spacer()
            Text(row.firstCatch.caughtAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(Brand.Color.textTertiary)
        }
        .padding(.vertical, 8)
        .padding(.trailing, 12)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 7))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
```

- [ ] **Step 2: Remove the stub in HangarView**

Delete the `struct ModelSlotDetailView: View { ... Text(entry.displayName) ... }` placeholder from Task 16.

- [ ] **Step 3: Build + tests + deploy**

`bin/deploy`. Visually confirm:
- Hangar → Sets → set tile tap → caught slot tap → ModelSlotDetailView.
- Header shows breadcrumb + model name + `K distinct tails`.
- Tail rows show rarity-tinted left rail, cyan callsign, `icao24 · operator`, relative first-catch timestamp.
- Tap a tail → pushes Tail detail (current `CatchDetailView`; Task 18 rewrites it).

- [ ] **Step 4: Commit**

```bash
git add ios/Tailspot/Tailspot/ModelSlotDetailView.swift ios/Tailspot/Tailspot/HangarView.swift
git commit -m "ModelSlotDetailView: tail list between Set detail and Tail detail

Spec § 5.3 — breadcrumb + model name + distinct-tail count, then a
vertical list of HangarRows for the tails of this model. Tap → Tail
detail (rewrite lands in Task 18).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 18: Tail detail (`CatchDetailView`) rewrite

**Files:**
- Modify: `ios/Tailspot/Tailspot/CatchDetailView.swift`

Spec § 8: PokeCard hero front-and-center; below it EARNED panel + first-caught panel + attribution. No spec sheet, no catch log. Floating chrome pills over the top of the page. System nav hidden.

- [ ] **Step 1: Replace the current `CatchDetailView` body**

This is a full rewrite. Replace `CatchDetailView.swift` with:

```swift
//
//  CatchDetailView.swift
//  Tailspot
//
//  Tail detail — PokeCard hero front-and-center. Replaces the prior
//  photo-first DetailA layout. Spec § 8.
//

import SwiftUI

struct CatchDetailView: View {
    let row: HangarRow

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var planespottersPhoto: PlanePhoto? = nil
    @State private var didFetchPhoto = false

    private var first: Catch { row.firstCatch }
    private var rarity: Rarity { row.rarity }
    private var type: AircraftType { row.aircraftType }

    private var hasCatchPhoto: Bool { first.photoFilename != nil }

    var body: some View {
        ZStack {
            Brand.Color.bgPrimary.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    pokeCardHero
                    earnedPanel
                    firstCaughtPanel
                    if let photo = planespottersPhoto, !hasCatchPhoto {
                        attribution(photo)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 64)
                .padding(.bottom, 40)
            }

            chromeBar
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 12)
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .task {
            guard !didFetchPhoto, !hasCatchPhoto else {
                didFetchPhoto = true
                return
            }
            didFetchPhoto = true
            planespottersPhoto = await PlanespottersClient.shared.photo(for: first.icao24)
        }
    }

    // MARK: - Hero

    private var pokeCardHero: some View {
        PokeCardView(
            plane: PokePlane(catchRecord: first, planespottersPhoto: planespottersPhoto),
            size: .lg
        )
        .frame(maxWidth: .infinity)
    }

    // MARK: - EARNED

    private var earnedPanel: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("EARNED")
                    .font(.system(size: 10, weight: .semibold, design: .default))
                    .tracking(1.2)
                    .foregroundStyle(rarity.tint)
                Text("+\(rarity.basePoints) pts")
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(rarity.tint)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(rarity.label)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Brand.Color.textTertiary)
                Text("Type · \(type.label.capitalized)")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(Brand.Color.textTertiary)
            }
        }
        .padding(14)
        .background(rarity.tint.opacity(0.10), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(rarity.tint, lineWidth: 1))
    }

    // MARK: - First caught

    private var firstCaughtPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("FIRST CAUGHT")
                .font(.system(size: 10, weight: .semibold, design: .default))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.textTertiary)
            Text(first.caughtAt.formatted(date: .abbreviated, time: .shortened))
                .font(Brand.Font.body)
                .foregroundStyle(Brand.Color.textPrimary)
            Text(observerCoordText)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Brand.Color.textTertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 10))
    }

    private var observerCoordText: String {
        let lat = first.observerLat, lon = first.observerLon
        let latLet = lat >= 0 ? "N" : "S"
        let lonLet = lon >= 0 ? "E" : "W"
        return String(format: "%.3f° %@, %.3f° %@", abs(lat), latLet, abs(lon), lonLet)
    }

    // MARK: - Chrome pills

    private var chromeBar: some View {
        HStack {
            chromePill(systemName: "chevron.left") { dismiss() }
            Spacer()
            ShareLink(item: shareText) {
                chromePillBody(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
    }

    private func chromePill(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            chromePillBody(systemName: systemName)
        }
        .buttonStyle(.plain)
    }

    private func chromePillBody(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Brand.Color.textPrimary)
            .frame(width: 32, height: 32)
            .background(.ultraThinMaterial, in: .circle)
            .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }

    private var shareText: String {
        let cs = first.callsign?.trimmingCharacters(in: .whitespaces).nonEmpty ?? first.icao24
        let model = first.model ?? "an aircraft"
        return "Caught \(cs) — a \(model)."
    }

    // MARK: - Attribution

    private func attribution(_ photo: PlanePhoto) -> some View {
        Button {
            openURL(photo.link)
        } label: {
            Text("© \(photo.photographer) · planespotters.net")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Brand.Color.textTertiary)
        }
        .buttonStyle(.plain)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
```

Note: `PokePlane(catchRecord:planespottersPhoto:)` is the assumed initializer. If `PokePlane` (used by `PokeCardView`) doesn't take a `planespottersPhoto`, either extend it or pass the photo through a different mechanism. The intent is that the PokeCard renders the photo in its photo slot (user catch photo → Planespotters → striped placeholder).

If the existing `PokePlane` init takes only `catchRecord`, do a small surgical addition: add an optional `planespottersPhoto: PlanePhoto?` field and have `PokeCardView` consume it in the photo slot.

- [ ] **Step 2: Adjust `PokeCardView` if necessary**

```bash
grep -nE "PokePlane|photoURL|photoFilename" ios/Tailspot/Tailspot/PokeCardView.swift | head -20
```

If `PokePlane` already accepts an external photo URL/PlanePhoto, skip this step. Otherwise:

```swift
// In PokeCardView.swift (or wherever PokePlane is defined):
struct PokePlane {
    let catchRecord: Catch
    var planespottersPhoto: PlanePhoto? = nil
    // ...existing fields...
}
```

Update the photo-slot render block to prefer `planespottersPhoto` when the catch has no local photo.

- [ ] **Step 3: Build + run tests + deploy**

`bin/deploy`. Confirm:
- Tap any caught entry (from Recent, or from Set detail → Model slot → tail) → Tail detail with PokeCard hero centered.
- Card's photo slot shows: user catch JPEG if present → Planespotters async fetch → striped placeholder.
- Floating chevron back (top-left) + share (top-right). System nav bar is hidden.
- Below the card: EARNED panel + first-caught panel + Planespotters attribution (when applicable).
- No spec-sheet, no catch log.

- [ ] **Step 4: Commit**

```bash
git add ios/Tailspot/Tailspot/CatchDetailView.swift ios/Tailspot/Tailspot/PokeCardView.swift
git commit -m "CatchDetailView rewrite: PokeCard hero, EARNED + first-caught only

Spec § 8 — PokeCard front-and-center; photo lives in the card's
photo slot. EARNED panel + First-caught panel + Planespotters
attribution. Drops the 320pt photo hero, the 6-cell stats grid, and
the catch-log timeline.

PokePlane gains an optional planespottersPhoto so the card can
render the live photo when no catch JPEG exists locally.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 19: `MiniCardView` — drop the `×N` badge

**Files:**
- Modify: `ios/Tailspot/Tailspot/MiniCardView.swift`

Post-dedupe (Task 8), there's only ever one Catch per tail. The `×N` count pill never shows >1. Drop it for clarity.

- [ ] **Step 1: Find and remove the badge**

In `MiniCardView.swift`, find the block rendering `row.count > 1 { Text("×\(row.count)") ... }`. Delete it.

- [ ] **Step 2: Tidy adjacent layout**

If the deletion leaves an empty `HStack` or unbalanced spacer, simplify. Verify by rendering preview.

- [ ] **Step 3: Build + tests + deploy**

`bin/deploy`. Confirm Recent / Set drill cards no longer show `×N`.

- [ ] **Step 4: Commit**

```bash
git add ios/Tailspot/Tailspot/MiniCardView.swift
git commit -m "MiniCardView: drop ×N count pill (one row per tail post-dedup)

Spec § 5.1 — Recent and the thumbnail strips render one card per
distinct tail; the count pill is meaningless. Remove it for clarity.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 20: Full-suite verification + final deploy

**Files:** None — this task is verification.

- [ ] **Step 1: Run the full test suite**

```bash
xcodebuild test \
  -project ios/Tailspot/Tailspot.xcodeproj \
  -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|error:|failed:" | head -10
```

Expected: `** TEST SUCCEEDED **`. Investigate any failure.

- [ ] **Step 2: Build for device**

```bash
xcodebuild build \
  -project ios/Tailspot/Tailspot.xcodeproj \
  -scheme Tailspot \
  -destination "platform=iOS,id=$(grep TAILSPOT_DEVICE_ID tools/deploy/config.sh | head -1 | cut -d= -f2 | tr -d '\"')" 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Deploy + walk through each surface**

```bash
bin/deploy
```

Walk through the spec's visuals (the `spec-with-visuals.html` mockup in `.superpowers/brainstorm/<latest>/content/`):

- [ ] AR view default: every visible plane has a faint label + brackets; `CAPTURE` button is live with `×N` corner badge for multi.
- [ ] Tap-pin: pinned plane brightens; others dim; badge drops.
- [ ] Tap empty (no pin): widened search picks the nearest visible plane.
- [ ] Tap empty (no planes at all): `NO AIRCRAFT HERE` ripple.
- [ ] Single catch: CardReveal with bloom + haptic.
- [ ] Multi catch: cards stagger in with haptic + chime; combo banner builds; `KEEP SPOTTING` button at the end.
- [ ] Duplicate catch: `ALREADY CAUGHT` stamp; no bloom; no DB row added.
- [ ] Hangar → Sets: 7 tiles, slot-progress `M/N`, thumbnail strips.
- [ ] Hangar → Recent: dedup'd MiniCard grid; tap → Tail detail; long-press → Delete.
- [ ] Hangar → Trophies: ladder partitioned Earned / In progress / Locked.
- [ ] Set tile → Set detail: model slot grid, `×K tails`.
- [ ] Set detail → caught slot → Model slot detail: distinct-tail list.
- [ ] Set detail → locked slot → bottom-sheet hint.
- [ ] Tail detail: PokeCard hero, EARNED, first-caught, attribution.
- [ ] Profile: no Trophies row, no Recent Medals strip; Map still present.

- [ ] **Step 4: Update CLAUDE.md `Current state` to reflect the redesign landing**

Open `CLAUDE.md` and add a new `Current state` block dated today summarizing what shipped (capture model, hangar shell, sets drill-down, tail detail, etc.) pointing to the spec + plan paths.

- [ ] **Step 5: Final commit**

```bash
git add CLAUDE.md
git commit -m "docs: capture & hangar redesign landed — CLAUDE.md current state

End-to-end walk-through against the spec mockup completed via
bin/deploy. All 20 tasks in
docs/superpowers/plans/2026-05-25-capture-and-hangar-redesign.md
landed; tests pass (xcodebuild test).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Self-review notes

- **Spec coverage:** Tasks map 1→1 to spec sections. § 3.1 → Tasks 5/6/8. § 3.2 → Task 7. § 3.3 → Tasks 9/11. § 3.4 → Tasks 1/8/10. § 4 → Task 12. § 4.2 (Profile fallout) → Task 14. § 5 → Tasks 15/16/17. § 6 → Task 13. § 7 → Task 14. § 8 → Task 18. § 9.1 → Task 1. § 9.2 → Tasks 2/3. § 9.3 → Task 4. § 9.4 → Task 8. § 10 → Tasks 1/2/3/4 add the new tests + flip the existing one. § 11 follow-ups are not implemented here (deferred by the spec itself).
- **Placeholders:** None. Every step shows code or commands.
- **Type consistency:** `CaptureMode` and `MultiCatchReveal.Entry` and `PendingReveal` are defined once in their introducing tasks; later tasks only consume them. `ModelSlot` defined in Task 3 used in Tasks 15/16/17. `HangarSegment` defined in Task 12, consumed by `@AppStorage` and the switcher view.
- **Verification:** UI-heavy tasks end with `bin/deploy` + explicit visual checks. Logic tasks (1/2/3/4) end with new tests that pass before commit.

## Execution Handoff
