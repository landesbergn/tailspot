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
