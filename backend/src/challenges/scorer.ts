/**
 * The scorer seam (spec §2.1, D18).
 *
 * A challenge is a window plus a scorer. The ONLY implementation in v1 is
 * `PrivatePointsScorer`: standard Tailspot points summed over each active
 * participant's catches inside the window. A future public quest plugs in a
 * predicate scorer ("catches whose type bucket is narrow ≥ 3") behind the same
 * interface, and the routes, placement, results freeze and history never learn
 * the difference.
 *
 * WHAT COUNTS (spec §5, D9 — no grace): a catch counts for a participant when
 *   caught_at ∈ [starts_at, ends_at)   — the client's claimed moment, and
 *   created_at <= ends_at              — it REACHED THE SERVER before the end.
 * A catch that uploads after the end never counts, whatever its caught_at.
 * Catching needs a network for ADS-B anyway, so uploads land within seconds.
 */

import { and, eq, gte, inArray, lt, lte, sql } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { withDbRetry } from "../db/retry.js";
import { catches } from "../db/schema.js";

/** The slice of a challenge a scorer needs. */
export interface ScoringWindow {
  startsAt: Date;
  endsAt: Date;
}

/** One participant's score inside the window. */
export interface ParticipantScore {
  deviceId: string;
  points: number;
  catches: number;
  /** `{ "<rarity tier>": count }`; unknown-rarity catches count under "unknown". */
  rarityBreakdown: Record<string, number>;
}

export interface ChallengeScorer {
  /**
   * Score every device in `deviceIds` over the window. Every requested device
   * gets a row (zero-scored when it has no in-window catches), so the caller
   * never has to reconcile a missing participant.
   */
  score(window: ScoringWindow, deviceIds: readonly string[]): Promise<ParticipantScore[]>;
}

export class PrivatePointsScorer implements ChallengeScorer {
  constructor(private readonly db: Database) {}

  async score(window: ScoringWindow, deviceIds: readonly string[]): Promise<ParticipantScore[]> {
    const byDevice = new Map<string, ParticipantScore>();
    for (const id of deviceIds) {
      byDevice.set(id, { deviceId: id, points: 0, catches: 0, rarityBreakdown: {} });
    }
    if (deviceIds.length === 0) return [];

    // One grouped read per (device, rarity); folded in JS. Grouping by rarity
    // here (rather than a jsonb aggregate) keeps the SQL portable across the
    // PGlite test driver and production postgres-js.
    const rows = await withDbRetry(() =>
      this.db
        .select({
          deviceId: catches.deviceId,
          rarity: catches.rarity,
          points: sql<number>`coalesce(sum(${catches.points}), 0)`.as("points"),
          count: sql<number>`count(${catches.id})`.as("count"),
        })
        .from(catches)
        .where(
          and(
            inArray(catches.deviceId, [...deviceIds]),
            gte(catches.caughtAt, window.startsAt),
            lt(catches.caughtAt, window.endsAt),
            lte(catches.createdAt, window.endsAt),
          ),
        )
        .groupBy(catches.deviceId, catches.rarity),
    );

    for (const r of rows) {
      const entry = byDevice.get(r.deviceId);
      if (!entry) continue; // cannot happen (WHERE inArray), defensive
      const n = Number(r.count);
      entry.points += Number(r.points);
      entry.catches += n;
      const tier = r.rarity ?? "unknown";
      entry.rarityBreakdown[tier] = (entry.rarityBreakdown[tier] ?? 0) + n;
    }
    return [...byDevice.values()];
  }
}

// Re-exported so the store can build the same predicate for catch logs
// without restating the window rule in two places.
export function inWindow(window: ScoringWindow, deviceId: string) {
  return and(
    eq(catches.deviceId, deviceId),
    gte(catches.caughtAt, window.startsAt),
    lt(catches.caughtAt, window.endsAt),
    lte(catches.createdAt, window.endsAt),
  );
}
