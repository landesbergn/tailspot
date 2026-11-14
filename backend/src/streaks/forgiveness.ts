/**
 * Streak forgiveness: the list of operator-declared "forgiven days".
 *
 * Catch streaks live entirely on the phone. When something outside a player's
 * control makes catching impossible (an FAA ground stop, say), the operator
 * declares that day forgiven for everyone; the app fetches this list and a
 * missed catch on a listed day does not break a streak. The server never
 * computes a streak — it only publishes the list.
 *
 * A day is a ZONE-FREE "yyyy-MM-dd" label. Each phone reads it as its own
 * local calendar day, so there is deliberately no timezone anywhere here.
 *
 * The read side (`listDays`) is the seam the public route depends on; the
 * write side is used only by the operator script
 * (`src/tools/forgive-streak-day.ts`).
 */

import { asc, eq } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { withDbRetry } from "../db/retry.js";
import { streakForgiveness } from "../db/schema.js";

/** One forgiven day, exactly as the public endpoint serves it. */
export interface ForgivenDay {
  /** "yyyy-MM-dd", zone-free. */
  day: string;
  /** Short user-facing phrase, e.g. "FAA ground stop". */
  reason: string;
}

/** The read seam for GET /v1/streak-forgiveness. */
export interface StreakForgivenessStore {
  /** Every forgiven day, ascending by day. The list stays tiny, so no paging. */
  listDays(): Promise<ForgivenDay[]>;
}

const DAY_RE = /^(\d{4})-(\d{2})-(\d{2})$/;

/**
 * Is `value` a real calendar date written as "yyyy-MM-dd"? The shape alone is
 * not enough — "2026-02-30" has it — so the parts are round-tripped through a
 * UTC date and must come back unchanged. UTC is only the arithmetic here; the
 * label itself stays zone-free.
 */
export function isValidDayLabel(value: string): boolean {
  const m = DAY_RE.exec(value);
  if (!m) return false;
  const [year, month, day] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const d = new Date(Date.UTC(year, month - 1, day));
  return d.getUTCFullYear() === year && d.getUTCMonth() === month - 1 && d.getUTCDate() === day;
}

export class DrizzleStreakForgivenessStore implements StreakForgivenessStore {
  constructor(private readonly db: Database) {}

  async listDays(): Promise<ForgivenDay[]> {
    // "yyyy-MM-dd" sorts lexically in calendar order, so a text ORDER BY is
    // the chronological one.
    return withDbRetry(() =>
      this.db
        .select({ day: streakForgiveness.day, reason: streakForgiveness.reason })
        .from(streakForgiveness)
        .orderBy(asc(streakForgiveness.day)),
    );
  }

  /** The row for `day`, or null. */
  async get(day: string): Promise<ForgivenDay | null> {
    const rows = await this.db
      .select({ day: streakForgiveness.day, reason: streakForgiveness.reason })
      .from(streakForgiveness)
      .where(eq(streakForgiveness.day, day));
    return rows[0] ?? null;
  }

  /** Insert the day, or update its reason when it is already forgiven. */
  async upsert(day: string, reason: string): Promise<void> {
    await this.db
      .insert(streakForgiveness)
      .values({ day, reason })
      .onConflictDoUpdate({ target: streakForgiveness.day, set: { reason } });
  }

  /** Delete the day. Resolves to whether a row was there to delete. */
  async remove(day: string): Promise<boolean> {
    const rows = await this.db
      .delete(streakForgiveness)
      .where(eq(streakForgiveness.day, day))
      .returning({ day: streakForgiveness.day });
    return rows.length > 0;
  }
}
