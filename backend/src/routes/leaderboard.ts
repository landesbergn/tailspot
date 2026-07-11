/**
 * Leaderboard (WP 1.5; windows + weekly champions in dynamic-leaderboards PR1).
 *
 *   GET /v1/leaderboard?window=week|month|all&limit=50   (auth OPTIONAL)
 *     → 200 {
 *         entries:   [{ rank, handle, points, catches }…],   // in-window
 *         me:        { rank, points, weeklyWins, everToppedAllTime } | null,
 *         window:    "week" | "month" | "all",
 *         resetsAt:  ISO-8601 of the next boundary | null (all-time),
 *         champions: [{ handle, points, weekStart }…] | null (week window only)
 *       }
 *
 * Windows are CALENDAR windows in UTC (locked design, Noah 2026-07-09): week =
 * Monday 00:00 UTC, month = 1st 00:00 UTC. `window` absent or unrecognized →
 * "all", so pre-windows clients see the all-time board with the exact fields
 * they already parse (the new top-level fields are additive-only).
 *
 * Only devices WITH a claimed handle appear in `entries` — anonymous devices
 * accrue points invisibly (and still occupy ranks, so a handled device's rank
 * reflects its TRUE standing among everyone). `me` is present whenever a valid
 * token is sent, even if that device has no handle (so a player can see their
 * rank before choosing a public name); null otherwise. `me.weeklyWins` /
 * `me.everToppedAllTime` are LIFETIME trophy counters (not window-scoped) and
 * ride along on every window for simplicity.
 *
 * `champions` is the LAST CLOSED week's champion(s) — plural on shared crowns
 * (a points tie crowns everyone), empty when that week had zero catches (the
 * only champion-less case; there is NO winner floor), and null off the week
 * window. Champions are decided lazily on read (`ensureWeeksDecided`): the
 * first week-window request after a Monday boundary freezes the previous
 * week's crown(s), backfilling any older never-decided weeks along the way.
 *
 * Points are a SQL aggregate (sum of in-window catch points per device) — no
 * materialized rank table at this scale. Tie-break: points DESC, then
 * registration time ASC (deterministic — earlier registrants win ties).
 */

import type { FastifyInstance } from "fastify";
import { resolveDevice } from "../identity/auth.js";
import type { CatchStore, ChampionEntry, IdentityStore } from "../identity/store.js";
import {
  addDaysUtc,
  monthStartUtc,
  nextMonthStartUtc,
  nextWeekStartUtc,
  parseWindow,
  utcDateString,
  weekStartUtc,
} from "../identity/windows.js";

export interface LeaderboardRouteOptions {
  identityStore: IdentityStore;
  catchStore: CatchStore;
  /** Injectable clock for deterministic window tests. Defaults to wall time. */
  now?: () => Date;
}

const DEFAULT_LIMIT = 50;
const MAX_LIMIT = 200;

/** Parse the limit query param, clamped to [1, MAX_LIMIT], defaulting on absent/bad. */
function parseLimit(v: unknown): number {
  const n = typeof v === "string" ? Number.parseInt(v, 10) : typeof v === "number" ? v : Number.NaN;
  if (!Number.isFinite(n) || n < 1) return DEFAULT_LIMIT;
  return Math.min(Math.floor(n), MAX_LIMIT);
}

export function registerLeaderboardRoute(
  app: FastifyInstance,
  opts: LeaderboardRouteOptions,
): void {
  const { identityStore, catchStore } = opts;
  const clock = opts.now ?? (() => new Date());

  app.get("/v1/leaderboard", async (request, reply) => {
    const q = request.query as Record<string, unknown>;
    const limit = parseLimit(q.limit);
    const window = parseWindow(q.window);
    const now = clock();

    // Window scoping: `since` bounds the point sums/ranks; `resetsAt` tells
    // the client when this board rolls over (null = never, the all-time board).
    let since: Date | undefined;
    let resetsAt: string | null = null;
    let champions: ChampionEntry[] | null = null;

    if (window === "week") {
      since = weekStartUtc(now);
      resetsAt = nextWeekStartUtc(now).toISOString();
      // Decide-on-read: freeze any closed-but-undecided weeks, then serve the
      // last closed week's champion(s).
      await catchStore.ensureWeeksDecided(now);
      champions = await catchStore.champions(utcDateString(addDaysUtc(since, -7)));
    } else if (window === "month") {
      since = monthStartUtc(now);
      resetsAt = nextMonthStartUtc(now).toISOString();
    }

    const entries = await catchStore.leaderboard(limit, since);

    // Serving the all-time board just computed the all-time #1 — observe it
    // into the topper ledger (first sighting wins) before `me` reads the flag,
    // so a player who IS #1 sees `everToppedAllTime: true` on this very
    // response.
    if (window === "all") {
      await catchStore.recordAlltimeTopper(now);
    }

    // `me` is best-effort: a valid token → the caller's standing; no/invalid
    // token → null. Auth is OPTIONAL here, so a missing token is not an error.
    const device = await resolveDevice(identityStore, request.headers.authorization);
    let me: {
      rank: number;
      points: number;
      weeklyWins: number;
      everToppedAllTime: boolean;
    } | null = null;
    if (device) {
      const standing = await catchStore.myStanding(device.id, since);
      if (standing) {
        me = {
          rank: standing.rank,
          points: standing.points,
          weeklyWins: await catchStore.weeklyWins(device.id),
          everToppedAllTime: await catchStore.everToppedAllTime(device.id),
        };
      }
    }

    return reply.code(200).send({ entries, me, window, resetsAt, champions });
  });
}
