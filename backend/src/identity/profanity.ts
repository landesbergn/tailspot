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
 * True when `handle` contains a banned substring. The handle is lowercased
 * before matching; callers pass the raw handle.
 */
export function containsProfanity(handle: string): boolean {
  const lower = handle.toLowerCase();
  return BLOCKLIST.some((word) => lower.includes(word));
}
