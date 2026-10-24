import type { FastifyInstance } from "fastify";
import { ipKey } from "../identity/clientIp.js";
import type { RateLimiter } from "../identity/rateLimiter.js";
import type { RouteEnricher } from "../providers/adsblolRoutes.js";
import { validateBbox } from "../providers/geo.js";
import type { Bbox, PositionProvider, ProviderSnapshot } from "../providers/types.js";
import {
  FetchRateLimitedError,
  NoFreshDataError,
  TileCache,
  type TileCacheConfig,
  type TileCacheThrottle,
  type UpstreamFetchEvent,
} from "./tileCache.js";

/**
 * GET /v1/aircraft?lamin=&lomin=&lamax=&lomax=
 *
 * Returns the normalized snapshot for the requested bbox, served through the
 * tile cache (fresh hit / single-flight / last-good fallback). The wire
 * contract (frozen — the iOS client is built against it):
 *
 *   200 { fetchedAt, aircraft: [...], provider }   // fetchedAt = upstream snapshot time
 *                                        // provider = "adsbfi" | "adsblol" — the
 *                                        // feed that produced it; additive 2026-10-20,
 *                                        // old clients ignore the key
 *   400 { error }                        // missing/invalid/oversized/inverted bbox
 *   429 { error: "rate limited" }        // per-IP flood control (+ Retry-After)
 *   503 { error: "upstream unavailable" } // upstream down AND no fresh cache
 */

export interface AircraftRouteOptions {
  provider: PositionProvider;
  cacheConfig?: Partial<TileCacheConfig>;
  /** Injectable clock (unix ms) for deterministic tests. */
  now?: () => number;
  /**
   * Best-effort hook fired once per genuine upstream fetch (not cache hits /
   * last-good). Production wires this to the registry-enrich sink so each fresh
   * snapshot opportunistically fills the airframe registry from the feed's
   * type/registration. Omitted (e.g. DB-less tests) → no enrichment.
   */
  onFreshSnapshot?: (snapshot: ProviderSnapshot) => void;
  /**
   * Fired once per genuine upstream fetch with the feed that answered, the
   * tile, the aircraft count and the upstream latency. Production logs it, so
   * the Fly log says which feed served when — the question nobody could answer
   * during the 2026-10-20 outage. Omitted → silent.
   */
  onUpstreamFetch?: (event: UpstreamFetchEvent) => void;
  /**
   * Opportunistic origin → destination enricher. When supplied, every served
   * snapshot is passed through it so each aircraft with a *cached* route gets a
   * `route` field on `/v1/aircraft` (additive — old clients ignore it). It never
   * blocks: cache misses trigger a background routeset lookup that surfaces on a
   * later poll. Omitted (route tests, non-adsblol provider) → no `route` field.
   */
  routeEnricher?: RouteEnricher;
  /**
   * Per-IP limiter. This is the hottest endpoint in the product — every phone
   * polls it on a timer — and until 2026-09-06 it was completely unmetered, so
   * a single loop could pin the machine and (worse) push our upstream quota.
   * Optional so a bare registration in a future tool/test can skip it; app.ts
   * always supplies one.
   */
  ipLimiter?: RateLimiter;
  /**
   * Per-IP limiter on requests that would SPEND upstream budget (a cold or
   * expired tile), separate from `ipLimiter`, which every request pays. The
   * hit limit (2 rps) is above the whole process's upstream budget (0.8 rps),
   * so without this one IP walking cold tiles could starve everyone.
   */
  fetchLimiter?: RateLimiter;
  /** Upstream request cap (see providers/upstreamBudget.ts). Omitted → none. */
  throttle?: TileCacheThrottle;
}

/** Parse a query value to a finite number, or undefined if absent/non-numeric. */
function parseCoord(v: unknown): number | undefined {
  if (typeof v === "number") return Number.isFinite(v) ? v : undefined;
  if (typeof v === "string" && v.trim().length > 0) {
    const n = Number(v);
    return Number.isFinite(n) ? n : undefined;
  }
  return undefined;
}

/**
 * Registers GET /v1/aircraft and returns the tile cache it serves from, so the
 * readiness canary (GET /readyz, see routes/feedProbe.ts) can ask the SAME
 * cache the phones use — one shared fetch per tile per TTL, never a second
 * upstream code path that could be healthy while the real one is not.
 */
export function registerAircraftRoute(app: FastifyInstance, opts: AircraftRouteOptions): TileCache {
  const cache = new TileCache(
    opts.provider,
    opts.cacheConfig,
    opts.now,
    opts.onFreshSnapshot,
    opts.onUpstreamFetch,
    opts.throttle,
  );

  app.get("/v1/aircraft", async (request, reply) => {
    // Meter before parsing: a flood shouldn't get any work out of us at all.
    const rl = opts.ipLimiter?.take(ipKey(request));
    if (rl && !rl.allowed) {
      reply.header("Retry-After", String(rl.retryAfterSeconds));
      return reply.code(429).send({ error: "rate limited" });
    }

    const q = request.query as Record<string, unknown>;
    const bbox: Partial<Bbox> = {
      lamin: parseCoord(q.lamin),
      lomin: parseCoord(q.lomin),
      lamax: parseCoord(q.lamax),
      lomax: parseCoord(q.lomax),
    };

    const invalid = validateBbox(bbox);
    if (invalid) {
      return reply.code(400).send({ error: invalid.reason });
    }

    // Retry-After for the 429 below. Most refused fetches are served from
    // cache as a 200, which must not carry it.
    let fetchRetryAfter: number | undefined;
    try {
      const fetchLimiter = opts.fetchLimiter;
      const { snapshot } = await cache.get(bbox as Bbox, {
        mayFetch: fetchLimiter
          ? () => {
              const r = fetchLimiter.take(ipKey(request));
              if (!r.allowed) fetchRetryAfter = r.retryAfterSeconds;
              return r.allowed;
            }
          : undefined,
      });
      // Attach known routes from the cache (sync, never blocking) and kick a
      // background lookup for the rest. Mutates the snapshot's aircraft in place
      // so a tile-cache hit also carries routes once the route cache is warm.
      opts.routeEnricher?.enrich(snapshot.aircraft);
      // fetchedAt is the upstream snapshot time (possibly stale on fallback) —
      // never the serve time. Clients reason about freshness from it.
      // `provider` names the feed that produced the snapshot (stale serves
      // keep the ORIGINAL producer's name — it is the data's origin, not the
      // current primary). Omitted only for a provider that never stamped.
      return reply.code(200).send({
        fetchedAt: snapshot.fetchedAt,
        aircraft: snapshot.aircraft,
        ...(snapshot.provider !== undefined ? { provider: snapshot.provider } : {}),
      });
    } catch (err) {
      if (err instanceof FetchRateLimitedError) {
        if (fetchRetryAfter !== undefined) reply.header("Retry-After", String(fetchRetryAfter));
        return reply.code(429).send({ error: "rate limited" });
      }
      if (err instanceof NoFreshDataError) {
        request.log.warn({ err }, "no fresh position data for bbox");
        return reply.code(503).send({ error: "upstream unavailable" });
      }
      // Unexpected — never let it become a 500-storm; log and 503.
      request.log.error({ err }, "unexpected error serving /v1/aircraft");
      return reply.code(503).send({ error: "upstream unavailable" });
    }
  });

  return cache;
}
