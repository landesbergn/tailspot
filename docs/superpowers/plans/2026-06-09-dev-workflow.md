# Dev Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `main` an enforced production-ready release line — feature branches → PR → green GitHub Actions test gate → squash-merge → Xcode Cloud → TestFlight — so WIP can't reach testers and parallel features release independently.

**Architecture:** GitHub Flow. A free GitHub Actions workflow runs the hermetic `TailspotTests` suite on every PR to `main`; branch protection (enforced on admins) requires that check; the existing "push to `main` → Xcode Cloud → TestFlight" trigger is unchanged. The process is captured in a new `CONTRIBUTING.md` and the CLAUDE.md/PLAN.md docs.

**Tech Stack:** GitHub Actions (macOS runner, `xcodebuild test`), `gh` CLI (PR + branch-protection + repo settings via REST), Xcode Cloud (unchanged), `bin/deploy` (unchanged).

**Spec:** `docs/superpowers/specs/2026-06-09-dev-workflow-design.md`

---

## Preconditions (already done)

- On branch `chore/dev-workflow` (off `main`).
- Spec committed (`c195d8f`).
- Verified: repo is **public**; `TailspotTests` is hermetic (no network/secrets); the shared `Tailspot.xcscheme` has a working Test action; the two stale branches have **0** unmerged commits.

All deliverable file content lives on this branch; the branch becomes the first PR (which itself bootstraps the gate before protection is turned on).

---

## Task 1: Add the GitHub Actions PR test workflow

**Files:**
- Create: `.github/workflows/tests.yml`

- [ ] **Step 1: Write the workflow file**

Create `.github/workflows/tests.yml` with exactly:

```yaml
name: tests

on:
  pull_request:
    branches: [main]

# Newer pushes to the same PR cancel in-flight runs.
concurrency:
  group: tests-${{ github.head_ref || github.ref }}
  cancel-in-progress: true

jobs:
  test:
    name: Unit tests
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4

      - name: Select latest stable Xcode
        uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: latest-stable

      # Prints the toolchain + the simulators this runner image actually
      # has, so if 'iPhone 17' is absent the log tells us what to switch to.
      - name: Show toolchain
        run: |
          xcodebuild -version
          xcrun simctl list devices available | grep -i iphone || true

      - name: Run TailspotTests
        run: |
          set -o pipefail
          xcodebuild test \
            -project ios/Tailspot/Tailspot.xcodeproj \
            -scheme Tailspot \
            -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
            -only-testing:TailspotTests \
            CODE_SIGNING_ALLOWED=NO
```

Rationale baked in: hermetic tests → no `secrets:` block; `CODE_SIGNING_ALLOWED=NO` because the simulator destination needs no signing; `latest-stable` Xcode is self-healing and a break shows up as a red check (caught at the gate, never shipped); the "Show toolchain" step makes the first-run device-name fix a one-liner.

- [ ] **Step 2: Validate the YAML parses locally**

Run:
```bash
python3 -c "import sys,yaml; yaml.safe_load(open('.github/workflows/tests.yml')); print('yaml ok')"
```
Expected: `yaml ok` (if PyYAML is absent, skip — CI will parse it).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/tests.yml
git commit -m "CI: run TailspotTests on every PR to main

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Write CONTRIBUTING.md (canonical human-readable workflow)

**Files:**
- Create: `CONTRIBUTING.md`

- [ ] **Step 1: Write the file**

Create `CONTRIBUTING.md` with exactly:

```markdown
# Contributing to Tailspot

Tailspot ships to real TestFlight testers from `main`: **every push to `main`
triggers an Xcode Cloud build → external TestFlight** (and Beta App Review). So
`main` must always be production-ready. This document is how we keep it that way.

## TL;DR

```bash
git checkout -b feat/my-thing main      # branch off main
# ...code; field-test on your iPhone with bin/deploy; commit...
git push -u origin feat/my-thing
gh pr create --fill --base main         # GitHub Actions runs the tests
gh pr merge --auto --squash --delete-branch   # merges itself once the check is green
```

## The model: branch → PR → CI gate → merge → ship

```
feat branch ─▶ PR (tests must pass) ─▶ squash-merge to main ─▶ Xcode Cloud ─▶ TestFlight
     │
     └─▶ bin/deploy to your iPhone  (instant local loop — any branch, no review, no CI wait)
```

### 1. Branch
- Branch off `main`. Naming (readability only, not enforced): `feat/…`, `fix/…`, `docs/…`, `chore/…`.
- One feature per branch, short-lived (merge in days, not weeks).
- Run as many feature branches in parallel as you like — they don't interfere, and each releases independently when its PR merges.

### 2. Iterate + field-test locally
- `bin/deploy` builds whatever branch is checked out and installs it on your iPhone. This is your instant loop — no PR, no CI wait, no review. Use it freely.
- Before opening the PR, run the suite locally:
  ```bash
  xcodebuild test \
    -project ios/Tailspot/Tailspot.xcodeproj \
    -scheme Tailspot \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
    -only-testing:TailspotTests
  ```

### 3. Open a PR
- `git push -u origin <branch>` then `gh pr create --fill --base main`.
- GitHub Actions runs `TailspotTests` on the PR. The **Unit tests** check must pass before the PR can merge. It's free (public repo) and needs no secrets — the tests are hermetic.

### 4. Merge
- `main` is protected: a PR plus a green **Unit tests** check are required — for everyone, admins included.
- Prefer `gh pr merge --auto --squash --delete-branch`: it merges the moment CI is green and deletes the branch.
- Squash-merge keeps `main` one-feature-per-commit, which also means one TestFlight build per feature instead of one per WIP commit.

### 5. Ship
- The merge to `main` triggers Xcode Cloud → external TestFlight automatically. Nothing else to do.

## Releasing & versions
- Keep `MARKETING_VERSION` the same for routine builds — Apple clears builds under an already-approved version faster. Bump it (in `ios/Tailspot/Tailspot.xcodeproj/project.pbxproj`) only for notable releases worth flagging to testers.
- Build numbers auto-increment in CI (`ci_pre_xcodebuild.sh`). Never edit `CURRENT_PROJECT_VERSION` by hand.
- Tag notable releases on `main`: `git tag v0.3.0 && git push origin v0.3.0`. Tags don't trigger builds — they're a git anchor per version.
- Update docs (CLAUDE.md "Current state", PLAN.md §9) **in the feature's PR**, so code and docs land on `main` together.

## Emergency override
If GitHub Actions is down and you must ship a hotfix, lift protection, push, then restore it:
```bash
# 1. Lift protection
gh api -X DELETE repos/landesbergn/tailspot/branches/main/protection
# 2. Push the fix (branch + PR still preferred; direct push now possible if truly necessary)
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
This is the exception, not the habit.

## Two features at once
Either keep two branches and `git checkout` between them, or add a second worktree:
```bash
git worktree add ../tailspot-featB feat/featB
```
Caveat: `bin/deploy` uses one fixed build directory, so deploy from one worktree at a time.

## What runs where
- **GitHub Actions** (`.github/workflows/tests.yml`) — runs `TailspotTests` on every PR to `main`. Free, no secrets.
- **Xcode Cloud** — archives every `main` push → external TestFlight. Reads OpenSky secrets from workflow env vars (see CLAUDE.md). Configured in App Store Connect, not the repo. A docs-only-change filter skips builds when only documentation changed.
- **`bin/deploy`** — your local device loop, any branch.
```

- [ ] **Step 2: Commit**

```bash
git add CONTRIBUTING.md
git commit -m "Docs: add CONTRIBUTING.md — canonical dev workflow

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Update CLAUDE.md and PLAN.md to point at the new flow

**Files:**
- Modify: `CLAUDE.md:366` (the "main is shippable" bullet)
- Modify: `PLAN.md` §9 (add a workflow entry at the top of the section body, after line 357)

- [ ] **Step 1: Replace the CLAUDE.md "main is shippable" bullet**

Find this line (currently `CLAUDE.md:366`):
```
- **`main` is shippable.** Don't push WIP. For changes that take more than a day, work on a feature branch and merge to main only when the change is tested locally. Single-commit fixes can go to main if tested first.
```
Replace it with:
```
- **`main` is shippable, and now enforced.** All changes reach `main` via a PR with a green **Unit tests** check (GitHub Actions); branch protection blocks direct pushes, admins included. Branch → field-test with `bin/deploy` → PR → squash-merge → ships. Autonomous commit + `bin/deploy` still happen freely *on feature branches*; the PR merge is the one deliberate checkpoint. **Canonical process: `CONTRIBUTING.md`** — read it before changing the release flow.
```

- [ ] **Step 2: Add a note to the "Run tests before pushing" bullet**

Find this line (currently `CLAUDE.md:369`):
```
- **Run tests before pushing.** `xcodebuild test ...` (see Tests section). When touching Geo / Aircraft / ADSBManager / OpenSky / Mock / their tests, a green local run is non-negotiable — failing tests waste a 5-15 minute CI cycle.
```
Replace it with:
```
- **Run tests before pushing.** `xcodebuild test ...` (see Tests section). When touching Geo / Aircraft / ADSBManager / OpenSky / Mock / their tests, a green local run is non-negotiable. The PR's GitHub Actions **Unit tests** check is the backstop — but catch failures locally first; a red PR check just slows the merge.
```

- [ ] **Step 3: Add a workflow entry to PLAN.md §9**

Insert immediately after the §9 header blank line (currently after `PLAN.md:357`), as a new first entry in the section body:
```
**Dev workflow formalized 2026-06-09 (branch → PR → CI gate → merge → ship).** `main` is now an *enforced* production-ready release line, not a convention. Feature branches → PR → a free GitHub Actions run of `TailspotTests` (hermetic; public repo → no-cost macOS runners) → squash-merge → existing Xcode Cloud → external TestFlight trigger (unchanged). Branch protection requires the **Unit tests** check and is **enforced on admins** (emergency override = lift protection, push, restore — see `CONTRIBUTING.md`). `bin/deploy` stays the instant per-branch device loop; autonomy lives on branches, the PR merge is the one checkpoint. Housekeeping: auto-delete merged branches on; two stale branches removed; a docs-only Xcode Cloud build-skip filter avoids burning external-review builds on `.md`-only merges (manual App Store Connect step). Spec/plan: `docs/superpowers/specs|plans/2026-06-09-dev-workflow*`. Canonical human doc: `CONTRIBUTING.md`.

```

- [ ] **Step 4: Verify the edits landed**

Run:
```bash
grep -n "enforced" CLAUDE.md | head; grep -n "Dev workflow formalized" PLAN.md
```
Expected: a hit in CLAUDE.md for the new bullet and one in PLAN.md for the new §9 entry.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md PLAN.md
git commit -m "Docs: point CLAUDE.md + PLAN.md at the enforced PR workflow

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Push the branch, open the PR, drive CI green (observe-and-fix loop)

**Files:** none (CI + GitHub).

- [ ] **Step 1: (Optional) confirm tests green locally**

No Swift changed on this branch, so the suite is at `main`'s last-green state (321 tests). Optional quick confirm:
```bash
xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -only-testing:TailspotTests 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 2: Push the branch**

```bash
git push -u origin chore/dev-workflow
```
**If push is rejected with a workflow-scope error** (`refusing to allow ... to create or update workflow`):
```bash
gh auth refresh -h github.com -s workflow
git push -u origin chore/dev-workflow
```

- [ ] **Step 3: Open the PR**

```bash
gh pr create --base main --fill \
  --title "Dev workflow: enforce PR + CI gate before main/TestFlight"
```

- [ ] **Step 4: Watch the check run, and fix if needed**

```bash
gh pr checks --watch
```
Expected: the **Unit tests** check goes green.

If it fails, read the run log:
```bash
gh run view --log-failed
```
Most likely fix — the runner image lacks the `iPhone 17` simulator. The "Show toolchain" step lists the iPhones it *does* have. Edit `.github/workflows/tests.yml`'s `-destination` to a listed device (e.g. `name=iPhone 16`), commit, push, and the check re-runs:
```bash
git add .github/workflows/tests.yml
git commit -m "CI: target an available simulator on the runner image"
git push
```
Repeat until green. (Less likely: `runs-on: macos-latest` lacks an Xcode new enough to build the iOS 26 project — if so, change `runs-on` to a specific newer image label shown to be available, and re-push.)

- [ ] **Step 5: Capture the exact check name for Task 6**

```bash
gh pr checks | cat
```
Note the check name in the first column (expected: `Unit tests`). Task 6's protection payload must use this exact string.

---

## Task 5: CHECKPOINT — confirm, then merge to `main` (this ships a build)

**Files:** none (GitHub).

- [ ] **Step 1: Confirm with Noah before merging**

Merging to `main` triggers an Xcode Cloud archive → external TestFlight build (Beta App Review). This PR changes no app code, so it's a functionally-identical "no-op app" build — but it is a real build/review cycle. **Do not merge without Noah's go-ahead.** (Optional: Noah can set up the Task 7 docs/CI build-skip filter *first* to avoid even this build — but `.github/` paths won't match a docs-only filter, so the simplest path is to accept one build here.)

- [ ] **Step 2: Squash-merge and delete the branch**

```bash
gh pr merge --squash --delete-branch
```
Expected: PR merged; `chore/dev-workflow` deleted on origin.

- [ ] **Step 3: Sync local main**

```bash
git checkout main && git pull origin main
```

---

## Task 6: Enable branch protection on `main` (the check now exists)

**Files:** none (GitHub REST via `gh`).

- [ ] **Step 1: Apply protection**

Use the exact check name from Task 4 Step 5 (shown here as `Unit tests`):
```bash
gh api -X PUT repos/landesbergn/tailspot/branches/main/protection --input - <<'JSON'
{
  "required_status_checks": { "strict": true, "contexts": ["Unit tests"] },
  "enforce_admins": true,
  "required_pull_request_reviews": { "required_approving_review_count": 0 },
  "restrictions": null
}
JSON
```
What each field does: `required_status_checks.strict` = branch must be up to date before merge; `contexts` = the GHA check that must pass; `enforce_admins` = the gate applies to admins too; `required_pull_request_reviews` present (with 0 approvals) = a PR is required but no human reviewer needed; `restrictions: null` = no push allowlist (required for a user-owned repo).

- [ ] **Step 2: Verify protection read-back (config is stored)**

```bash
gh api repos/landesbergn/tailspot/branches/main/protection \
  --jq '{strict: .required_status_checks.strict, checks: .required_status_checks.contexts, admins: .enforce_admins.enabled, pr_required: (.required_pull_request_reviews != null)}'
```
Expected: `{"strict":true,"checks":["Unit tests"],"admins":true,"pr_required":true}`.

- [ ] **Step 3: Behavioral test — prove a direct push is actually blocked**

Reading back config is not proof; this is. Attempt to push an empty commit straight to `main` and confirm the server rejects it (a correct protection config rejects it pre-receive, so nothing lands):
```bash
git checkout main
git commit --allow-empty -m "verify protection (expect rejection)"
git push origin main          # EXPECTED: rejected — "protected branch hook declined" / "Changes must be made through a pull request"
git reset --hard origin/main  # discard the local empty commit either way
```
Expected: the push is **rejected**. If it somehow succeeds, protection is misconfigured — the empty commit is a no-op to investigate, and you've learned exactly that. This is the one step that proves goal (a).

---

## Task 7: Repo housekeeping

**Files:** none (GitHub).

- [ ] **Step 1: Enable auto-merge + auto-delete merged branches**

Both are repo-level settings that default to **false**. Auto-merge must be on for the `gh pr merge --auto` happy path that `CONTRIBUTING.md` documents:
```bash
gh api -X PATCH repos/landesbergn/tailspot \
  -F allow_auto_merge=true -F delete_branch_on_merge=true \
  --jq '{auto_merge: .allow_auto_merge, delete_on_merge: .delete_branch_on_merge}'
```
Expected: `{"auto_merge":true,"delete_on_merge":true}`.

- [ ] **Step 2: Delete the two stale branches (verified 0 unmerged commits)**

```bash
git push origin --delete ar-recall-and-elevation-fixes
git push origin --delete claude/plane-detection-box-overlay-rL41R
```

- [ ] **Step 3: Verify they're gone**

```bash
git ls-remote --heads origin | grep -E 'ar-recall|plane-detection-box' || echo "both stale branches deleted"
```
Expected: `both stale branches deleted`.

---

## Task 8: Noah-only — Xcode Cloud docs-only build-skip filter

**Files:** none (App Store Connect UI; cannot be automated).

- [ ] **Step 1: Add the start-condition file filter**

In App Store Connect → Xcode Cloud → **Manage Workflows** → the workflow that builds on push to `main` → **Start Conditions** → the "Branch Changes / push to `main`" condition → **Files and Folders**: add a rule so the build is **not** triggered when only documentation changed. Add patterns:
- `**/*.md`
- `docs/`

Save the workflow. From then on, a merge that touches only those paths won't burn a TestFlight/review build. (Code or `.github/` changes still build, by design.)

- [ ] **Step 2: Confirm the test-action question from the spec**

While in Manage Workflows, also confirm whether the build workflow runs a **Test** action (the spec left this as "Noah to check"). If it does and you'd rather not double-run tests (GHA already gates them), you can leave it — Xcode Cloud tests on `main` are a harmless second safety net. No code change either way; just note the answer.

---

## Self-review (completed by author)

- **Spec coverage:** model (Tasks 1–5), merge gate / GHA (Task 1, 4), branch protection enforce-on-admins (Task 6), TestFlight/versioning doc (Task 2), docs-only skip (Task 8), housekeeping incl. stale-branch delete + auto-delete (Task 7), written docs CONTRIBUTING/CLAUDE/PLAN (Tasks 2–3), bootstrap sequencing "merge first then protect" (Tasks 5→6). All spec sections map to a task.
- **Placeholder scan:** none — every file's full content and every command is inline.
- **Name consistency:** the GHA job `name: Unit tests` is the check context required verbatim in Task 6 and referenced in CONTRIBUTING + CLAUDE; Task 4 Step 5 verifies the actual string before Task 6 uses it.
- **Sequencing:** protection (Task 6) follows the first green run + merge (Tasks 4–5), satisfying "a check must run once before it can be required."
```
