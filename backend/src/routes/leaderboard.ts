/**
 * Leaderboard (WP 1.5).
 *
 *   GET /v1/leaderboard?limit=50   (auth OPTIONAL)
 *     → 200 { entries: [{ rank, handle, points, catches }…], me: { rank, points } | null }
 *
 * Only devices WITH a claimed handle appear in `entries` — anonymous devices
 * accrue points invisibly (and still occupy ranks, so a handled device's rank
 * reflects its TRUE standing among everyone). `me` is present whenever a valid
 * token is sent, even if that device has no handle (so a player can see their
 * rank before choosing a public name); null otherwise.
 *
 * Points are a SQL aggregate (sum of catch points per device) — no materialized
 * rank table at this scale. Tie-break: points DESC, then registration time ASC
 * (deterministic — earlier registrants win ties).
 */

import type { FastifyInstance } from "fastify";
import { resolveDevice } from "../identity/auth.js";
import type { CatchStore, IdentityStore } from "../identity/store.js";

export interface LeaderboardRouteOptions {
  identityStore: IdentityStore;
  catchStore: CatchStore;
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

  app.get("/v1/leaderboard", async (request, reply) => {
    const q = request.query as Record<string, unknown>;
    const limit = parseLimit(q.limit);

    const entries = await catchStore.leaderboard(limit);

    // `me` is best-effort: a valid token → the caller's standing; no/invalid
    // token → null. Auth is OPTIONAL here, so a missing token is not an error.
    const device = await resolveDevice(identityStore, request.headers.authorization);
    const me = device ? await catchStore.myStanding(device.id) : null;

    return reply.code(200).send({ entries, me });
  });
}
