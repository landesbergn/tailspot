---
title: Tailspot v1.1 Release Scope - Plan
type: feat
date: 2026-08-17
topic: v1-1-release-scope
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
execution: code
---

# Tailspot v1.1 Release Scope - Plan

## Goal Capsule

- **Objective:** Ship v1.1 "Habits & housekeeping": nine small/medium items that build a daily habit loop, fix the first-catch activation leak, and open the app's only organic install loop. Everything is client-side or additive; no APNs, no schema breaks.
- **Product authority:** Noah's 2026-08-17 verdicts on the Flight Plan prioritization board (29/29 items decided). v1.2, v1.3+, and the marketing lane are context only, not active scope here.
- **Open blockers:** none. The stale funnel figure is deferred to planning (see Outstanding Questions).

---

## Product Contract

### Summary

v1.1 adds daily catch streaks with guardrailed local reminders, a scoped first-catch onboarding moment, an in-app review prompt, an App Store link in catch shares, catch-photo zoom, a narrowed duplicate-catch rule, and two deferred battery fixes. All items are S/M effort. The release is a fast follow, not a platform build.

### Problem Frame

Three problems drove the 2026-08-17 re-prioritization. The download-to-first-catch funnel leaks badly (roughly 36 openers to 5 catchers over 30 days, as of July). Nothing brings a user back daily, and the global leaderboard rewards obsessive catching, which leaves casual spotters without a game. And the app has no organic install loop: shared catch cards carry no link, and no user is ever asked for a rating.

### Key Decisions

- KD1. **Push alerts move to v1.2.** (session-settled: user-approved — chosen over the 2026-07-21 plan's v1.1 headline: local reminders and client-side mechanics cover the habit loop without APNs, a backend scheduler, or a privacy-policy change; push's unique value is server-known events, which grow with the install base.) Governs R2, R3.
- KD2. **Account deletion is off the critical path.** (session-settled: user-directed — chosen over the prior "compliance rides v1.1" stance: identity is an anonymous device token plus an optional handle, and Apple approved v1.0 with handle claiming live. Residual review risk accepted; parked as a delete-my-data control.)
- KD3. **Streak reminders ship guardrailed and on by default.** (session-settled: user-directed — chosen over opt-in-default-off and cut-from-v1.1.) Governs R2, R3.
- KD4. **v1.2 stays one long train** holding quests, push alerts, and head-to-head challenges. (session-settled: user-directed — chosen over splitting into two trains.)
- KD5. **Trophy roster round, Home Screen widget, and the wrong-ID report loop are parked.** (session-settled: user-directed — chosen against their v1.1 recommendation.)
- KD6. **The duplicate window narrows from lifetime-per-airframe to same-flight-same-day.** (session-settled: user-directed — added 2026-08-17 after the board export; callsign chosen over route as the flight key because route data is late or missing at catch time.) Governs R11, R12.

### Requirements

**Habit loop**

- R1. The Profile shows a current streak and a longest streak, counted as consecutive local-calendar days with at least one catch.
- R2. A local streak-protection reminder fires only when all of these hold: a live streak of 2+ days, no catch yet that day, and no reminder already sent that day. It arrives in the early evening, cancels for the day once a catch lands, and never fires for a broken or absent streak. **Amended 2026-08-19 (Noah): the threshold is 2 days, not 3** — two days is the first moment a streak exists to protect, and the permission ask reads strongest as "you have a 2-day streak, protect it?". One constant, `StreakReminders.minimumStreak`, shared by the reminder, the reveal chip and the ask so all three agree on when a streak exists. **Re-amended 2026-08-25 (Noah, from the field): the threshold is 1 day, and the reminder hour is 17:00 local (was 18:00)** — his own day-1 streak sat silently at risk with no nudge, so a single catch day now counts as a streak worth protecting. The shared constant means the reveal chip shows from the first catch and the permission ask lands on the first reveal.
- R3. Reminders are on by default, gated by the system notification permission requested with context (not at cold launch), and can be muted in Settings.

**First-catch activation**

- R4. A first-run onboarding moment orients the user to live nearby traffic — what is overhead now, or the nearest catchable plane — before their first catch attempt.
- R5. When nearby traffic is quiet, onboarding says so honestly instead of implying the app is broken.

**Organic installs**

- R6. The catch share payload includes the geo-neutral App Store listing link alongside the card image.
- R7. The app requests an App Store rating via the system review sheet at a high moment (a trophy unlock or a rare catch reveal), never during capture, within Apple's frequency limits.

**Collection polish**

- R8. Tapping the photo on a catch card opens the full-resolution photo with pinch-zoom. It no longer dismisses the card.
- R11. A catch counts as a duplicate only when the same airframe was already caught with the same callsign on the same local calendar day; if the callsign is missing on either side, a same-day repeat of the airframe compares as a duplicate. **Sequencing, settled 2026-08-19 (Noah): R11/R12 ship in the SAME PR as the streak (R1/R2), not after it.** The streak counts days that have a `Catch` row, and under the old lifetime-per-airframe gate a day of re-sighted planes wrote no row — so shipping the streak first would have needed a side-channel record of catch actions purely to bridge the gap.
- R12. Any other repeat sighting is a full catch with its own record, photo, points, and upload; the duplicate reveal (existing catch, "ALREADY CAUGHT", no points) applies only within R11's window. Existing rows are untouched.

**Quality**

- R9. Analytics events flush in batches rather than waking the network per event.
- R10. The camera pipeline powers down while a full-screen sheet covers the viewfinder.

### Key Flows

- F1. Streak reminder day
  - **Trigger:** a day begins with a live 1+ day streak (re-amended 2026-08-25 — see R2).
  - **Steps:** no catch by early evening → one local notification → tapping it opens the app ready to catch. A catch at any point that day cancels the pending reminder.
  - **Covers:** R2, R3.
- F2. First launch to first catch
  - **Trigger:** first app open after install.
  - **Steps:** onboarding → nearby-traffic orientation → the user points at a plane and makes a first catch. With no traffic nearby, the quiet-sky message sets expectations and invites them back.
  - **Covers:** R4, R5.

### Acceptance Examples

- AE1. **Covers R2.** Given a 4-day streak and no catch today, when early evening (17:00, re-amended 2026-08-25) arrives, exactly one reminder fires. Given a catch at 16:00 that day, no reminder fires.
- AE2. **Covers R2.** Given a 1-day streak and no catch today, the evening reminder fires. (Was "no reminder fires" under the 2-day threshold — see R2's 2026-08-25 re-amendment.)
- AE3. **Covers R2.** Given a streak that broke yesterday, or a lapsed user, nothing fires. The reminder protects an active run; it is not a win-back nag.
- AE4. **Covers R3.** Given reminders muted in Settings, no reminder fires regardless of streak.
- AE5. **Covers R7.** Given a trophy unlock, the review sheet may appear after the celebration completes. It never appears during capture or the reveal.
- AE6. **Covers R11, R12.** Given N123AB caught this morning as UA100, catching the same airframe this evening as UA101 creates a new full catch with points. Catching it again tomorrow as UA100 also creates a new full catch.
- AE7. **Covers R11.** Given N123AB caught as UA100 an hour ago, tapping it again while it is still UA100 today shows the duplicate reveal and adds no row.
- AE8. **Covers R11.** Given a same-day repeat where either sighting has no callsign, it is treated as a duplicate.

### Scope Boundaries

- **Deferred to v1.2+:** quests, collection-first emphasis, push alerts (APNs), head-to-head challenges, shareable report card, feature flags + client-version header, leaderboard leagues, trophy roster round, Home Screen widget, wrong-ID report loop.
- **Parked:** delete-my-data control, simulated first catch, daily mystery plane, branded social accounts, merch.
- The marketing lane (ASO, featuring pitch, Reddit and personal social, meetup, illustration outreach) is non-code and runs in parallel. It is not part of this release's definition of done.

### Dependencies / Assumptions

- The streak computation already exists (`ios/Tailspot/Tailspot/Trophies.swift`, `longestDayStreak`). R1 is new surface, not new math.
- No StoreKit and no UserNotifications code exists in the app today. R2/R3 and R7 are net-new but small.
- Any SwiftData change stays additive; the Hangar is local-only and a breaking migration destroys real collections.
- The funnel figure is from July and assumed directionally right.
- Repeat catches earn full points on both client and server with no backend change (the backend already scores every uploaded row). Accepted trade-off: a spotter can re-earn daily on a regular plane.

### Outstanding Questions

- **Resolve Before Planning:** none.
- **Deferred to Planning:**
  - OQ1. Re-pull the activation funnel by version in PostHog before finalizing the R4 cut.
  - OQ2. Reminder hour and copy tone.
  - OQ3. The review-prompt trigger: trophy unlock, rare reveal, or Nth catch.
  - OQ4. Where the streak stat lives on the Profile and whether it joins `ProfileStats`.
  - OQ5. When the notification-permission ask happens (streak day 1 vs day 3).

<!-- ce-section: work-relationships -->
### How This Work Fits Together

This plan owns v1.1 only. The rest of the 2026-08-17 board is the current understanding, not a committed roadmap:

- v1.2 "Reach out" — one train holding quests + collection-first emphasis, push alerts (APNs foundation + three categories), head-to-head challenges, shareable report card, and feature flags.
  - **Depends on** v1.1's streaks (streak-protection push needs a streak to protect).
  - **Still to decide:** whether quests feed leaderboard points or run a separate reward track.
- v1.3+ — leaderboard leagues. **Can proceed independently of** head-to-head, and may reduce the need for it.
- Marketing lane — **can proceed independently of** every train, starting now.

### Sources

- `PLAN.md` §9 — the 2026-08-17 re-prioritization block and the per-item detail table.
- `ios/Tailspot/Tailspot/Trophies.swift` — streak computation and the secret 7-day streak trophy.
- `ios/Tailspot/Tailspot/SettingsScreen.swift` — where the reminder mute lands.
- The Flight Plan board export (2026-08-17, 29/29 decided) — verdicts recorded in PLAN §9.
