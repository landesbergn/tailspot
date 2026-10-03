/**
 * Tailspot's own public aggregate: the total catch count the homepage shows
 * ("N planes caught so far"). GET https://api.tailspot.app/v1/stats answers
 * only when Origin is the marketing site; backend/README.md documents that a
 * non-browser caller sending that Origin is expected and fine ("the number is
 * printed on the homepage anyway"). We send it, cache nothing, and treat any
 * failure as "no number" — the CTA slide simply omits the line, never a 0.
 *
 * Deliberately NOT used: the leaderboard. Handles are public in the app, but
 * putting a player's handle in a public TikTok is a different kind of
 * exposure that no one opted into.
 */

import { getJson, type FetchOptions } from "./adsb.ts";

export const TAILSPOT_STATS_URL = "https://api.tailspot.app/v1/stats";

export interface TailspotStats {
  catches: number;
  asOf: string;
}

export async function fetchStats(opts?: FetchOptions): Promise<TailspotStats | null> {
  try {
    const s = await getJson<TailspotStats>(TAILSPOT_STATS_URL, { origin: "https://tailspot.app" }, { retries: 1, timeoutMs: 8000, ...opts });
    return typeof s?.catches === "number" && s.catches > 0 ? s : null;
  } catch {
    return null;
  }
}

/** "5,812" → "5,800+" so the slide doesn't go stale by tomorrow. */
export function roundedCatchCount(n: number): string {
  const step = n >= 10_000 ? 1000 : n >= 1000 ? 100 : 10;
  return `${(Math.floor(n / step) * step).toLocaleString("en-US")}+`;
}
