# Dev workflow: branch → PR → CI gate → merge → ship

**Date:** 2026-06-09
**Status:** Design (awaiting review)
**Author:** Noah + Claude

## Problem

`main` is the only live branch and every push to it triggers an Xcode Cloud
archive → TestFlight (external) build. Today nothing enforces that what lands on
`main` is tested or complete:

- The "don't push WIP / run tests first" rules in `CLAUDE.md` are conventions,
  not enforced gates. A bad commit reaches real testers.
- There is no automated test run before code hits `main` — tests are run by hand.
- Developing two features at once risks one's WIP riding along when the other
  merges.

## Goals

- **(a) Production-ready `main`.** Every push to `main` is well-tested and
  complete, because a push to `main` ships to TestFlight testers (external group,
  so it also goes through Beta App Review).
- **(b) Independent, parallel features.** Multiple features can be developed and
  field-tested at once, then released independently, without WIP from one mixing
  into another.

## Non-goals

- No `develop`/`release` branches (GitFlow). Ceremony a solo dev will regret.
- No monorepo / path-filtered CI for `backend/` or `shared/` — those dirs don't
  exist yet.
- No second TestFlight track. One external track stays (Noah's choice).
- No change to the local `bin/deploy` device loop or the OpenSky credential setup.

## Decisions locked during brainstorming

| Question | Decision |
| --- | --- |
| Branching model | GitHub Flow: short-lived feature branches → PR → squash-merge to `main` |
| Merge vs. ship | **Every `main` merge ships.** No tag/release-branch indirection. |
| CI build trigger | Unchanged: push to `main` → Xcode Cloud → TestFlight external |
| TestFlight tracks | Single external track (unchanged) |
| PR test gate | **GitHub Actions** (repo is public → macOS runners are free; gate lives in version control) |
| Branch protection on admins | **Enforced** (true gate; emergency override = temporarily disable protection) |
| Stale branches | **Delete both** (`ar-recall-and-elevation-fixes`, `claude/plane-detection-box-overlay-rL41R`) — verified 0 unmerged commits |
| Docs-only builds | **Skip** via Xcode Cloud start-condition file filter |

## The model

```
feature branch ──▶ PR (GHA tests must pass) ──▶ squash-merge to main ──▶ Xcode Cloud ──▶ TestFlight (external)
      │
      └─▶ bin/deploy to iPhone  (instant local loop, any branch, no review, no CI wait)
```

- `main` is the release line — always green, always shippable.
- A feature lives on its own short-lived branch (`feat/…`, `fix/…`, `docs/…`,
  `chore/…`). Iterate and field-test on the branch with `bin/deploy`.
- Merge only when the feature is complete and tested. WIP physically cannot reach
  `main` — it sits on the branch until the PR merges. → goals (a) and (b).
- "Release independently" = merge each feature's PR when it is ready.

### Why the local loop is unchanged

`bin/deploy` builds whatever is checked out, so it already works on any branch.
It is the instant, no-review, no-CI iteration loop. The PR/CI gate applies *only*
at the merge into `main`. This preserves the existing "autonomous commit + deploy
during iteration" preference: autonomy happens on branches; the one deliberate
checkpoint is the merge.

## The merge gate (component: GitHub Actions test workflow)

**What it does:** Runs the `TailspotTests` suite on every PR targeting `main`, and
reports a required status check.

**How:** `.github/workflows/tests.yml` — on `pull_request` to `main`, on a
GitHub-hosted `macos-*` runner, run:

```
xcodebuild test \
  -project ios/Tailspot/Tailspot.xcodeproj \
  -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests
```

**Dependencies / why it is simple:**
- Tests are hermetic — `FixedSource` + in-memory SwiftData, no network, **no
  OpenSky secrets**. Verified: the only OpenSky/URLSession token in `TailspotTests`
  is a doc comment. So the workflow needs no secrets.
- Simulator destination → no code signing required.
- The shared `Tailspot.xcscheme` already has a Test action with both test bundles
  enabled, so `xcodebuild test` works as-is.
- Repo is **public** → GitHub-hosted macOS runners are free. This is why GHA wins
  over an Xcode Cloud "PR Test" workflow: free, version-controlled, and it leaves
  the Xcode Cloud compute budget for release archives.

**Pin the runner image / Xcode version** so a runner upgrade can't silently break
the build. The workflow selects a known-good Xcode via `xcode-select`/`xcodes` or
the runner's `XCODE_VERSION`, and names the simulator that exists on that image
(adjust `iPhone 17` if the pinned image lacks it).

**Risk — runner Xcode drift:** GitHub rotates the Xcode versions on macOS images.
Mitigation: pin explicitly and treat a runner-image bump as a deliberate change.

## Branch protection (component: GitHub repo config)

On `main`:
- Require a pull request before merging.
- Require the GHA test status check to pass.
- Require the branch to be up to date before merging.
- Do **not** require human review (solo dev).
- **Enforce on administrators** (true gate).

**Emergency override** (documented, expected to be rare): temporarily disable
branch protection in repo Settings (or via `gh api -X DELETE
repos/landesbergn/tailspot/branches/main/protection`), push the hotfix, re-enable.

**Sequencing constraint:** A status check can only be marked "required" after it
has run at least once on the repo. So the order is:
1. Land `tests.yml` and open a PR so the check runs once.
2. *Then* enable branch protection requiring that check.

This means the very first PR (the one that introduces this workflow) merges before
protection is on — that is expected and fine.

## TestFlight + versioning (unchanged, documented + tied in)

- Single external track. Keep `MARKETING_VERSION` stable for routine builds —
  Apple reviews the first build of a new version string; later builds under the
  same string generally clear external testing without full re-review, so a stable
  version string makes "every merge ships" fast after the first review. Bump
  `MARKETING_VERSION` only for notable releases. Build number auto-increments in CI
  (`ci_pre_xcodebuild.sh`).
- The version bump (when needed) rides along in the feature's PR.
- **Tag notable releases** on `main` (`git tag v0.3.0`) for a git anchor per
  version. Tags do not trigger builds in this model — they are bookkeeping.

**Known cost (accepted):** because every `main` merge ships to an external group,
each merge can incur a Beta App Review cycle. Mitigations baked into this design:
batch a feature's work into one squash-merge (not many small main merges); the
docs-only build-skip filter; and the stable-`MARKETING_VERSION` fast path above.

### Docs-only build skip (component: Xcode Cloud start condition)

The doc-staleness Stop hook guarantees frequent `*.md` churn. There is no reason a
docs-only merge burns a TestFlight/review build. Add a **Files and Folders** filter
to the Xcode Cloud "push to `main`" start condition so a build is skipped when only
documentation paths changed (e.g. `**/*.md`, `docs/`). This is a one-time setting
in App Store Connect → Xcode Cloud → Manage Workflows (UI only; not in the repo).
Manual step for Noah; exact clicks documented in the plan.

## Housekeeping

- Delete the two stale remote branches (verified 0 unmerged commits).
- Enable "Automatically delete head branches" on merge (currently off).
- Branch naming convention: `feat/…`, `fix/…`, `docs/…`, `chore/…` (readability
  only; not enforced).
- **Optional, not core:** parallel features via `git worktree add ../tailspot-X
  <branch>`. Caveat: `bin/deploy` uses one fixed build dir
  (`TAILSPOT_BUILD_DIR`), so deploy from one worktree at a time unless we
  parameterize the build dir. Documented as optional.

## What gets written down

1. **`CONTRIBUTING.md`** — the canonical, human-readable workflow (branch → deploy
   → PR → merge → ship; emergency override; release/version conventions). One
   place a future contributor (or a fresh Claude session) reads to learn the flow.
2. **`.github/workflows/tests.yml`** — the PR test gate.
3. **`CLAUDE.md` "Workflow notes" update** — supersede the "single-commit fixes can
   go to `main` if tested" line with "everything reaches `main` via PR + green CI";
   point to `CONTRIBUTING.md` as canonical; note the doc-update-rides-in-the-PR
   convention and that the doc-staleness hook is now a backstop.
4. **`PLAN.md` §9** — note the workflow change in the backlog/state as appropriate.

## Out of scope / future

- Parameterizing `bin/deploy`'s build dir for true parallel-worktree deploys.
- A second (internal, instant) TestFlight track — revisit if external-review
  latency becomes painful.
- Per-package CI when `backend/`/`shared/` land.

## Implementation order (preview; detailed plan follows)

1. Add `.github/workflows/tests.yml`; verify it runs green (open this branch's PR).
2. Write `CONTRIBUTING.md`; update `CLAUDE.md` + `PLAN.md`.
3. Merge this PR (protection not yet on — bootstrap).
4. Enable branch protection on `main` requiring the now-existing check + enforce on
   admins.
5. Enable "auto-delete head branches"; delete the two stale branches.
6. Noah: add the Xcode Cloud docs-only path filter in App Store Connect.
