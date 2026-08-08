# Contributing to Tailspot

Tailspot is **live on the App Store** (v1.0.0, build 83, approved 2026-08-08).
That changed what this document is for. Before GA there was one audience —
TestFlight testers Noah could message — and one real gate. Now code moves
through **four rings**, each with a different audience and a different cost of
being wrong, and the last one has **no rollback**.

This document is the canonical process. `CLAUDE.md` carries the durable
conventions; `PLAN.md` §9 carries what's being built.

## The four rings

| Ring | Where | Audience | Gate | Cost of a mistake |
|---|---|---|---|---|
| 0 | `bin/deploy` | Noah's iPhone | none | redeploy, seconds |
| 1 | `main` | nobody | PR + green **Unit tests** | revert a commit |
| 2 | TestFlight | invited testers | manual Start Build | message the testers |
| 3 | App Store | the public | App Review, 24–48 h | **none — you cannot un-ship** |

```
feat branch ─▶ PR (CI green) ─▶ squash-merge to main ─▶ accumulates on main
     │                                                        │
     │                                    manual Start Build ─▶ Xcode Cloud ─▶ TestFlight  (Ring 2: soak)
     │                                                                              │
     │                                                        submit for review ────▶ App Store  (Ring 3: public)
     └─▶ bin/deploy to the iPhone   (Ring 0: instant loop, any branch)
```

**Merging does not ship. Cutting a TestFlight build does not ship.** Only
submitting a build to App Review and releasing it reaches the public. Each
promotion between rings is a deliberate, manual act — and Ring 2 → Ring 3 is
**Noah's call alone**.

## TL;DR for a normal change

```bash
git checkout -b feat/my-thing main      # branch off main
# ...code; field-test on the iPhone with bin/deploy; commit...
git push -u origin feat/my-thing
gh pr create --fill --base main         # GitHub Actions runs the tests
gh pr merge --auto --squash --delete-branch   # merges itself once the check is green
```

That gets you to Ring 1. Rings 2 and 3 happen later, in batches, on Noah's
schedule — see [Cutting a release](#cutting-a-release).

---

## Ring 0 — the local device loop

`bin/deploy` builds whatever branch is checked out and installs it on the
paired iPhone. No PR, no CI wait, no review. Use it constantly — it's the only
ring with a fast feedback loop, so as much correctness as possible should be
established here.

The Simulator can't provide GPS, compass, or camera, so anything touching the
identify path **must** be tested on the phone.

Before opening the PR, run the suite locally:

```bash
xcodebuild test \
  -project ios/Tailspot/Tailspot.xcodeproj \
  -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests
```

## Ring 1 — `main`

`main` is the always-green integration line. Nothing here is visible to any
user, so merge freely and often.

- Branch off `main`. Naming (readability only, not enforced): `feat/…`,
  `fix/…`, `docs/…`, `chore/…`.
- One feature per branch, short-lived — merge in days, not weeks. Long-lived
  branches are the main way a solo dev accidentally ships an untested batch.
- `git push -u origin <branch>` then `gh pr create --fill --base main`.
- GitHub Actions runs `TailspotTests` on every PR; the **Unit tests** check must
  pass before merge. Branch protection enforces PR + green check for everyone,
  admins included. Backend PRs additionally run **Backend tests** (typecheck,
  lint, vitest) — that job only triggers on `backend/**` changes.
- Prefer `gh pr merge --auto --squash --delete-branch`.
- Update `PLAN.md` §9 and `CHANGELOG.md` **in the feature's PR**, so code and
  docs land together. `CLAUDE.md` changes only when durable guidance changes.

Claude may commit, `bin/deploy`, and merge on green CI autonomously. Claude
**may not** promote to Ring 2 or Ring 3.

## Ring 2 — TestFlight (pre-production soak)

**This ring's job changed at GA.** Before, TestFlight *was* the release —
shipping to testers was the point. Now it is the rehearsal: the last place a
bad build can be caught while it still costs a message rather than a review
cycle. It is also the only place the app runs on hardware that isn't Noah's
iPhone 16, which matters — every device-compatibility assumption in this
codebase has exactly one data point behind it.

To cut a build: App Store Connect → Xcode Cloud → the workflow → **Start
Build** on `main` (or Xcode: **Integrate → Start Build**). One build → external
TestFlight, bundling everything merged since the last build, so testers get one
notification per release rather than one per merge.

**Soak before promoting to Ring 3:**

| Change | Minimum soak |
|---|---|
| Copy, colours, static layout | same day |
| Anything touching sensors, camera, ADS-B, or the identify path | 2–3 days, incl. one real outdoor field session |
| SwiftData schema changes | 3+ days on a device with an existing Hangar |
| Backend contract changes | soak the client **after** the server is deployed and stable |

During the soak, watch App Store Connect → Crashes and PostHog for the new
build number. A build with a new crash signature does not get promoted; fix it
and cut another.

## Ring 3 — App Store (production)

The public ring. Assume anything that ships here is **permanent**: there is no
rollback on iOS. Your only levers after the fact are pulling the app from sale
(nuclear, and it hurts ranking), requesting an expedited review for a fix (~24 h
if granted, and it spends goodwill you can only spend occasionally), or pausing
a phased release that is still rolling out.

Because of that, the discipline is entirely front-loaded — the checklist below
*is* the safety mechanism.

### Cutting a release

1. **Open the train.** Bump `MARKETING_VERSION` (see [Versioning](#versioning)).
   This happens *before* the TestFlight builds, not at submission time.
2. **Cut and soak** a TestFlight build (Ring 2), per the soak table above.
3. **Deploy the backend first** if the release depends on a server change, and
   let it run in production before the client that needs it reaches anyone. The
   server must work for *both* the old and new client — see
   [Backend releases](#backend-releases).
4. **Write the release notes** ("What's New"). Real user-facing sentences, not
   a changelog dump. This is the only channel you have to your users.
5. **Re-sync the App Privacy label** if the release changes what data leaves the
   device — check it against `PrivacyInfo.xcprivacy`. (Push notifications will
   trigger this.) Ground truth: `docs/ga/appstore-listing.md`.
6. **Update screenshots** if the UI in them changed — see
   `docs/ga/screenshot-plan.md`.
7. **Submit for review**, selecting the soaked build. Keep the App Review notes
   about needing open sky and passing aircraft — review happens at an indoor
   desk where a catch is impossible, and that note is why v1.0 passed.
8. **Turn on phased release** and choose **manual release**. Phased release
   rolls the update out over 7 days (1% → 100%) and can be paused from App
   Store Connect; it is a free checkbox and the closest thing to a rollback
   that iOS offers. Manual release lets you pick the moment and watch the
   backend during the first hours.
9. **Tag the release commit**: `git tag v1.1.0 && git push origin v1.1.0`. Tags
   trigger nothing — they're the git anchor for "what shipped as 1.1.0".

Items 1–6 are the recurring, per-release work. The **one-time** App Store
Connect setup (app info, age rating, pricing, category) is done and recorded in
`docs/ga/appstore-listing.md`; don't redo it.

### After the release lands

The first 48 hours are when a bad release is still cheap. Check, in order:

- **App Store Connect → Crashes**, filtered to the new version. A crash rate
  materially above the previous version means pause the phased rollout.
- **Sentry** (backend) — new error signatures that correlate with the rollout.
- **PostHog** — the onboarding → first-catch funnel, split by app version. A
  regression here is invisible in crash data and is the failure mode most likely
  to actually matter.
- **App Store ratings and reviews.** New at GA and easy to forget: ratings drive
  discovery, and an unanswered one-star bug report is a product problem, not a
  support one. Respond to reviews from App Store Connect.

Then record the release in `CHANGELOG.md` and update `PLAN.md` §9.

### Hotfixes

A production hotfix is a normal change that skips patience, not process:

1. Branch off `main`, minimal diff — resist bundling anything else in.
2. PR + green CI as usual. **Do not** bypass branch protection for this; the
   emergency override below is for GitHub Actions being down, not for urgency.
3. Bump the patch version (1.1.0 → 1.1.1).
4. Cut a TestFlight build and verify the fix on a device. Even 30 minutes of
   soak beats shipping a blind fix.
5. Submit, and request an expedited review **only if** users are actively broken
   — data loss, a crash on launch, a core flow that fails. Routine bugs wait.

## Versioning

Two numbers, and **the rule for one of them inverted at GA**:

- **`MARKETING_VERSION`** — the release train. `1.0.0`, `1.1.0`, `1.1.1`. Lives
  in `ios/Tailspot/Tailspot.xcodeproj/project.pbxproj`; the app target
  (`com.landesberg.Tailspot`) has it in both the Debug and Release config
  blocks — **edit both, leave the test targets alone**.
- **`CURRENT_PROJECT_VERSION`** — the build number. Stays `1` in the repo;
  `ci_scripts/ci_pre_xcodebuild.sh` rewrites it to Apple's monotonic
  `CI_BUILD_NUMBER` on every Xcode Cloud run. **Never edit it by hand** (except
  before a manual local Archive upload, which you shouldn't be doing).

**The rule that changed.** The old guidance was "keep the same
`MARKETING_VERSION`, let the build number increment" — correct for TestFlight,
where Beta App Review clears additional builds under an already-approved version
faster. It is **wrong for the App Store**: once 1.0.0 is publicly released, a new
public release requires a *new, higher* version string. You cannot ship 1.0.0
build 84 to the App Store on top of 1.0.0 build 83.

So: **one `MARKETING_VERSION` per public release, bumped when you open the
train — not at submission.** Bumping at submission means the binary you ship
carries a version string your testers never soaked. Within a train, cut as many
TestFlight builds as you like; they all share the version and get unique build
numbers automatically.

The price is one Beta App Review per train (the first external TestFlight build
of a new version string needs it, usually ~24 h). That is the correct price now
— the alternative is soaking one version and shipping another.

Semantics: **patch** (1.1.0 → 1.1.1) for fixes only, **minor** (1.0.0 → 1.1.0)
for features. After a release goes live, bump immediately so `main` is always
carrying the version of the *next* train.

## Backend releases

The backend (`backend/`, Fly.io, `fly deploy`) is now half of production, and
it serves clients you can no longer fix. Old app versions stay installed for
months; some users never update.

- **Additive-only with respect to shipped clients.** Same discipline `CLAUDE.md`
  already imposes on SwiftData migrations, extended to the wire contract. Don't
  remove or repurpose a field that a released build reads.
- **Server before client, always.** Deploy the backend, confirm it's healthy
  (`/healthz`), *then* promote the client that depends on it.
- **Snapshot the database before running migrations.** Drizzle migrations now
  run against real users' catches.
- Backend changes still go through a PR and the **Backend tests** check; the
  `fly deploy` is manual and separate from merging.

## Emergency override

If GitHub Actions is down and a hotfix genuinely cannot wait, lift protection,
push, then restore it:

```bash
# 1. Lift protection
gh api -X DELETE repos/landesbergn/tailspot/branches/main/protection
# 2. Push the fix (branch + PR still preferred; direct push now possible)
# 3. Restore protection
gh api -X PUT repos/landesbergn/tailspot/branches/main/protection --input - <<'JSON'
{
  "required_status_checks": { "strict": true, "contexts": ["Unit tests"] },
  "enforce_admins": true,
  "required_pull_request_reviews": { "required_approving_review_count": 0 },
  "restrictions": null
}
JSON
```

This is the exception, not the habit — and it is about CI being unavailable,
never about a release being urgent.

## Two features at once

Either keep two branches and `git checkout` between them, or add a second
worktree:

```bash
git worktree add ../tailspot-featB feat/featB
```

Caveat: `bin/deploy` uses one fixed build directory, so deploy from one worktree
at a time.

## What runs where

- **GitHub Actions** (`.github/workflows/tests.yml`) — `TailspotTests` on every
  PR to `main`. Free, no secrets. `backend-tests.yml` runs typecheck/lint/test
  on `backend/**` changes only.
- **Xcode Cloud** — archives `main` → external TestFlight on a **manual Start
  Build**. Reads the optional PostHog key from workflow env vars (see
  `ci_scripts/ci_post_clone.sh`). Configured in App Store Connect, not the repo.
- **App Review** — gates Ring 2 → Ring 3 (and the first build of each new
  version string into Ring 2). Not automatable; 24–48 h.
- **Fly.io** — `backend/` and `web/`, deployed manually with `fly deploy`.
- **`bin/deploy`** — the local device loop, any branch.
