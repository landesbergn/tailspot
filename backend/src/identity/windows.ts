/**
 * Leaderboard window math (dynamic leaderboards PR1).
 *
 * All boundaries are CALENDAR boundaries in **UTC** — a locked design call
 * (Noah, 2026-07-09): weeks start Monday 00:00 UTC, months start on the 1st
 * 00:00 UTC. UTC has no DST, so a "week" is always exactly 7×24h and the
 * arithmetic below can be plain day math with no timezone library. Every
 * function is pure (Date in → Date out, inputs never mutated) so the whole
 * module is trivially unit-testable.
 */

/** The leaderboard windows the API accepts. */
export type LeaderboardWindow = "week" | "month" | "all";

/**
 * Parse the `window` query param. Absent or unrecognized values fall back to
 * "all" — old clients send no param and must see the all-time board unchanged.
 */
export function parseWindow(v: unknown): LeaderboardWindow {
  return v === "week" || v === "month" ? v : "all";
}

/** Milliseconds in one UTC day (no DST in UTC, so this is exact). */
const DAY_MS = 24 * 60 * 60 * 1000;

/** `d` shifted by `days` whole UTC days (negative allowed). Pure. */
export function addDaysUtc(d: Date, days: number): Date {
  return new Date(d.getTime() + days * DAY_MS);
}

/**
 * The Monday 00:00:00.000 UTC that starts the calendar week containing `d`.
 * JS `getUTCDay()` numbers Sunday 0 … Saturday 6; `(day + 6) % 7` re-bases
 * that to Monday 0 … Sunday 6, i.e. "days since Monday".
 */
export function weekStartUtc(d: Date): Date {
  const daysSinceMonday = (d.getUTCDay() + 6) % 7;
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() - daysSinceMonday));
}

/** The NEXT Monday 00:00 UTC after `d` — the week window's `resetsAt`. */
export function nextWeekStartUtc(d: Date): Date {
  return addDaysUtc(weekStartUtc(d), 7);
}

/** The 1st 00:00:00.000 UTC of the calendar month containing `d`. */
export function monthStartUtc(d: Date): Date {
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), 1));
}

/**
 * The 1st 00:00 UTC of the FOLLOWING month — the month window's `resetsAt`.
 * `Date.UTC` normalizes month 12 into January of the next year, so the year
 * wrap needs no special case.
 */
export function nextMonthStartUtc(d: Date): Date {
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 1));
}

/**
 * `d` as a UTC calendar-date string ("YYYY-MM-DD") — the wire/DB format for
 * `weekly_champions.week_start`. Callers pass midnight-UTC Dates (the week
 * math above only produces those), so the time-of-day truncation is lossless.
 */
export function utcDateString(d: Date): string {
  return d.toISOString().slice(0, 10);
}
