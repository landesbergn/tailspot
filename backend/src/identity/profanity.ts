/**
 * A small embedded profanity blocklist for handle validation (WP 1.5).
 *
 * Intentionally minimal and self-contained — no third-party "bad words"
 * dependency (those are large, noisy, and a supply-chain surface for a list we
 * want to read at a glance). The check is a SUBSTRING match on the lowercased
 * handle, so "fucker" is rejected via "fuck". That deliberately over-blocks
 * (the classic "Scunthorpe problem": an innocent handle containing a banned
 * substring is rejected) — for a kids-adjacent public leaderboard, erring
 * toward over-blocking is the right call, and the user simply picks another
 * handle. Tune the list here; it's the single source of truth.
 *
 * Lives in its own module so the list is easy to find, audit, and extend
 * without touching validation logic.
 */

/** Lowercased banned substrings. Keep alphabetical for easy auditing. */
const BLOCKLIST: readonly string[] = [
  "anal",
  "anus",
  "ass",
  "bastard",
  "bitch",
  "boner",
  "boob",
  "clit",
  "cock",
  "cum",
  "cunt",
  "dick",
  "dildo",
  "douche",
  "fag",
  "fuck",
  "jizz",
  "kike",
  "nazi",
  "nigg",
  "penis",
  "porn",
  "pussy",
  "rape",
  "retard",
  "semen",
  "sex",
  "shit",
  "slut",
  "spic",
  "tit",
  "twat",
  "vagina",
  "wank",
  "whore",
];

/**
 * Leetspeak substitutions folded before the second matching pass, so
 * `sh1t`, `fvck`-style spellings don't sail past a plain-substring list
 * (GA hardening, 2026-07-20). Only characters the handle charset allows
 * ([A-Za-z0-9_]) need mapping; underscores are stripped in the same pass
 * so separators can't split a banned word (f_u_c_k).
 */
const LEET_MAP: Readonly<Record<string, string>> = {
  "0": "o",
  "1": "i",
  "3": "e",
  "4": "a",
  "5": "s",
  "6": "g",
  "7": "t",
  "8": "b",
  "9": "g",
};

/** Lowercase, strip underscores, and fold leet digits to letters. */
function normalizeForMatching(handle: string): string {
  return handle
    .toLowerCase()
    .replace(/_/g, "")
    .replace(/[0-9]/g, (c) => LEET_MAP[c] ?? c);
}

/**
 * True when `handle` contains a banned substring — checked against BOTH the
 * plain lowercased handle and its leet-normalized form. Callers pass the raw
 * handle. The normalized pass widens the over-block surface slightly (a
 * digit-bearing innocent handle can fold into a banned word); that is the
 * same Scunthorpe trade-off as the base list — the user picks another handle.
 */
export function containsProfanity(handle: string): boolean {
  const lower = handle.toLowerCase();
  if (BLOCKLIST.some((word) => lower.includes(word))) return true;
  const folded = normalizeForMatching(handle);
  return BLOCKLIST.some((word) => folded.includes(word));
}
