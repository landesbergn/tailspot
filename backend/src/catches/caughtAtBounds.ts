/**
 * Plausible range for a catch's client-reported `caughtAt` (security fix,
 * 2026-10-24).
 *
 * `caughtAt` used to be any finite number. That let a client:
 *   - backdate catches into empty past weeks/months and collect a weekly or
 *     monthly crown for each one on the next decide-on-read;
 *   - set it to year ~69 AD so `ensureWeeksDecided` walks ~100k weeks, one
 *     query each, inside a leaderboard request, every week;
 *   - future-date it so it counts in every live board forever;
 *   - send a value past JS Date's range, which 500s on serialization.
 *
 * Before FLOOR (the day this repo was created) no real catch can exist, so
 * those are a 422. Too far in the FUTURE is what a real phone with a fast
 * clock sends, and shipped clients retry a 422 on every launch forever — so
 * those are stored at server time instead ("gates flag, never block"); the
 * validator still sees the reported time and records the skew.
 */

export const CAUGHT_AT_FLOOR = new Date("2026-05-01T00:00:00Z");

/** Max seconds `caughtAt` may run ahead of the server clock before clamping. */
export const CAUGHT_AT_MAX_FUTURE_SECONDS = 86_400;

export function isBeforeFloor(caughtAtSeconds: number): boolean {
  return caughtAtSeconds < CAUGHT_AT_FLOOR.getTime() / 1000;
}

/** The time to store and score by: the reported time, or `now` if it's too far ahead. */
export function storedCaughtAt(caughtAtSeconds: number, nowSeconds: number): number {
  return caughtAtSeconds > nowSeconds + CAUGHT_AT_MAX_FUTURE_SECONDS ? nowSeconds : caughtAtSeconds;
}

/** Backfill start for the decide-on-read walkers: never before the floor. */
export function clampToFloor(earliest: Date): Date {
  return earliest.getTime() < CAUGHT_AT_FLOOR.getTime() ? CAUGHT_AT_FLOOR : earliest;
}
