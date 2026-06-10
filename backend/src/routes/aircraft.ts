import type { FastifyInstance } from "fastify";
import { validateBbox } from "../providers/geo.js";
import type { Bbox, PositionProvider } from "../providers/types.js";
import { NoFreshDataError, TileCache, type TileCacheConfig } from "./tileCache.js";

/**
 * GET /v1/aircraft?lamin=&lomin=&lamax=&lomax=
 *
 * Returns the normalized snapshot for the requested bbox, served through the
 * tile cache (fresh hit / single-flight / last-good fallback). The wire
 * contract (frozen — the iOS client is built against it):
 *
 *   200 { fetchedAt, aircraft: [...] }   // fetchedAt = upstream snapshot time
 *   400 { error }                        // missing/invalid/oversized/inverted bbox
 *   503 { error: "upstream unavailable" } // upstream down AND no fresh cache
 */

export interface AircraftRouteOptions {
  provider: PositionProvider;
  cacheConfig?: Partial<TileCacheConfig>;
  /** Injectable clock (unix ms) for deterministic tests. */
  now?: () => number;
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

export function registerAircraftRoute(app: FastifyInstance, opts: AircraftRouteOptions): void {
  const cache = new TileCache(opts.provider, opts.cacheConfig, opts.now);

  app.get("/v1/aircraft", async (request, reply) => {
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

    try {
      const { snapshot } = await cache.get(bbox as Bbox);
      // fetchedAt is the upstream snapshot time (possibly stale on fallback) —
      // never the serve time. Clients reason about freshness from it.
      return reply.code(200).send({
        fetchedAt: snapshot.fetchedAt,
        aircraft: snapshot.aircraft,
      });
    } catch (err) {
      if (err instanceof NoFreshDataError) {
        request.log.warn({ err }, "no fresh position data for bbox");
        return reply.code(503).send({ error: "upstream unavailable" });
      }
      // Unexpected — never let it become a 500-storm; log and 503.
      request.log.error({ err }, "unexpected error serving /v1/aircraft");
      return reply.code(503).send({ error: "upstream unavailable" });
    }
  });
}
