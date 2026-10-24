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
 * FLOOR is the day this repo was created: no real catch can predate it.
 * The ceiling allows a generous day of phone clock skew. A rejected upload is
 * a 422, which the iOS uploader leaves pending until the next launch (no hot
 * retry loop).
 */

export const CAUGHT_AT_FLOOR = new Date("2026-05-01T00:00:00Z");

/** Max seconds `caughtAt` may run ahead of the server clock. */
export const CAUGHT_AT_MAX_FUTURE_SECONDS = 86_400;

export function isPlausibleCaughtAt(caughtAtSeconds: number, nowSeconds: number): boolean {
  return (
    caughtAtSeconds >= CAUGHT_AT_FLOOR.getTime() / 1000 &&
    caughtAtSeconds <= nowSeconds + CAUGHT_AT_MAX_FUTURE_SECONDS
  );
}

/** Backfill start for the decide-on-read walkers: never before the floor. */
export function clampToFloor(earliest: Date): Date {
  return earliest.getTime() < CAUGHT_AT_FLOOR.getTime() ? CAUGHT_AT_FLOOR : earliest;
}
