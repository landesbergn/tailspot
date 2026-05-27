#!/bin/bash
#
# ci_pre_xcodebuild.sh — Xcode Cloud pre-xcodebuild hook.
#
# Runs after ci_post_clone, before xcodebuild archive/test/build.
# Bumps CFBundleVersion (via project.pbxproj's CURRENT_PROJECT_VERSION
# build setting) to match Apple's CI_BUILD_NUMBER, so each CI archive
# ships with a unique build number.
#
# WHY:
# App Store Connect dedupes by (CFBundleShortVersionString,
# CFBundleVersion) — i.e. (MARKETING_VERSION, CURRENT_PROJECT_VERSION).
# Without this script every CI archive ships with CURRENT_PROJECT_VERSION=1
# (the value committed in pbxproj), App Store Connect accepts the
# first upload and silently drops every subsequent one with the same
# tuple. Result: Xcode Cloud reports "build succeeded" but TestFlight
# only ever has the very first build.
#
# CI_BUILD_NUMBER is Apple's monotonic counter (incremented on every
# CI run regardless of what the project's CURRENT_PROJECT_VERSION
# says). Mapping CFBundleVersion := CI_BUILD_NUMBER gives us a
# strictly-increasing build number per CI run, which is what App
# Store Connect requires for uniqueness.
#
# WHY sed AND NOT agvtool:
# `agvtool new-version -all` would be the Apple-blessed way, but it
# requires VERSIONING_SYSTEM = "apple-generic" in build settings and
# we don't use Apple-Generic Versioning elsewhere. A targeted sed
# avoids adding that build setting just for CI. The sed is anchored
# enough that it only touches CURRENT_PROJECT_VERSION lines (which
# are simple integers, not multi-line); no risk of clobbering other
# settings.
#
# LOCAL BUILDS:
# This script only runs under Xcode Cloud (Apple invokes it from the
# ci_scripts/ directory). Your local `xcodebuild ...` or Xcode Run
# never invokes it. So CURRENT_PROJECT_VERSION stays at whatever the
# committed pbxproj says (currently 1) for local builds. If you ever
# need to upload a manual Archive from your Mac, you'll want to bump
# CURRENT_PROJECT_VERSION in pbxproj by hand first to avoid the
# duplicate-build-number rejection.

set -euo pipefail

echo "ci_pre_xcodebuild: starting (CI_BUILD_NUMBER=${CI_BUILD_NUMBER:-unset})"

# Apple sets CI_BUILD_NUMBER for every CI run. If it's missing we're
# not in Xcode Cloud — bail rather than guess at a value.
if [ -z "${CI_BUILD_NUMBER:-}" ]; then
    echo "ci_pre_xcodebuild: CI_BUILD_NUMBER not set, not in Xcode Cloud — skipping"
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PBXPROJ="$PROJECT_DIR/Tailspot.xcodeproj/project.pbxproj"

if [ ! -f "$PBXPROJ" ]; then
    echo "ci_pre_xcodebuild: pbxproj not found at $PBXPROJ — aborting" >&2
    exit 1
fi

# Capture the current values so we can log the before/after.
BEFORE="$(grep -c '^[[:space:]]*CURRENT_PROJECT_VERSION = [0-9]*;' "$PBXPROJ" || true)"
echo "ci_pre_xcodebuild: rewriting $BEFORE CURRENT_PROJECT_VERSION line(s) to $CI_BUILD_NUMBER"

# In-place sed. `-i ''` is BSD/macOS syntax (the runner is macOS). The
# pattern matches lines like `				CURRENT_PROJECT_VERSION = 1;`
# (tab-indented assignment in pbxproj's dictionary literal form).
sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $CI_BUILD_NUMBER;/g" "$PBXPROJ"

# Sanity: confirm the rewrite landed.
AFTER="$(grep -c "CURRENT_PROJECT_VERSION = $CI_BUILD_NUMBER;" "$PBXPROJ" || true)"
echo "ci_pre_xcodebuild: $AFTER line(s) now read CURRENT_PROJECT_VERSION = $CI_BUILD_NUMBER"

if [ "$AFTER" -lt "$BEFORE" ]; then
    echo "ci_pre_xcodebuild: ERROR — fewer matches after sed than before. Aborting so we don't ship a half-rewritten pbxproj." >&2
    exit 1
fi

echo "ci_pre_xcodebuild: done"
