/**
 * Handle-suggestion generator (onboarding "always available" fix).
 *
 * The onboarding handle step used to offer four HARDCODED chips to every user.
 * Because handles are case-insensitively unique, the first person to tap each
 * one claimed it and everyone after got a 409 "taken" — the suggestions were
 * never available. This generates aviation-flavoured candidates like
 * `contrail_4821`; the suggestions route over-generates, filters out the ones
 * already claimed (IdentityStore.takenHandles) and any profanity, and returns
 * the survivors, so the chips a new user sees are free to claim.
 *
 * Pure + injectable RNG so the route stays deterministic under test.
 */

import { containsProfanity } from "./profanity.js";

/**
 * Clean, aviation-themed stems. All lowercase [a-z], short enough that
 * `<stem>_<4 digits>` stays within the 3–20 char handle limit. None contain a
 * profanity-blocklist substring (the generated handle is screened anyway).
 */
const STEMS: readonly string[] = [
  "spotter",
  "contrail",
  "approach",
  "skyhawk",
  "vapor",
  "heading",
  "tailwind",
  "redeye",
  "jetwash",
  "flightpath",
  "mach",
  "cleared",
  "downwind",
  "skylane",
  "cruise",
  "beacon",
];

/** Inclusive 4-digit numeric suffix — 9000 options per stem keeps collisions rare. */
const SUFFIX_MIN = 1000;
const SUFFIX_MAX = 9999;

/**
 * Generate up to `batchSize` candidate handles of the form `<stem>_<4-digit>`,
 * drawn with the injected `rng` (defaults to Math.random). Results are
 * de-duplicated and profanity-screened here; the caller still checks DB
 * availability. May return fewer than `batchSize` after de-dup — the caller
 * over-generates to compensate. The iteration cap stops a pathological rng from
 * spinning forever.
 */
export function generateHandleCandidates(
  batchSize: number,
  rng: () => number = Math.random,
): string[] {
  const out = new Set<string>();
  const maxIters = Math.max(0, batchSize) * 10;
  for (let i = 0; i < maxIters && out.size < batchSize; i++) {
    const stem = STEMS[Math.floor(rng() * STEMS.length)] ?? STEMS[0];
    const suffix = SUFFIX_MIN + Math.floor(rng() * (SUFFIX_MAX - SUFFIX_MIN + 1));
    const handle = `${stem}_${suffix}`;
    if (!containsProfanity(handle)) out.add(handle);
  }
  return [...out];
}
