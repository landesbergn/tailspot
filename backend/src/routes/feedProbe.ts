import { validateBbox } from "../providers/geo.js";
import type { Bbox } from "../providers/types.js";
import type { TileCache } from "./tileCache.js";

/**
 * The position-feed canary behind GET /readyz.
 *
 * Until 2026-10-19, /readyz proved only that the process was up and Postgres
 * answered. The product's one job — "show me the planes over my head" — was
 * unmonitored: adsb.lol rate-limited Fly's shared egress IP (HTTP 429) and
 * airplanes.live refused it (HTTP 403) for sixteen days, every /v1/aircraft
 * call 503'd, the uptime monitor stayed green, and the first reports came from
 * users. This probe closes that gap by asking the SAME tile cache and provider
 * chain that serves phones for one fixed, busy bbox:
 *
 *   - It goes through `TileCache.get`, so a hit within the fresh TTL (10 s) is
 *     a map read, a miss is ONE upstream fetch shared with any phone looking at
 *     the same tile, and the 60 s last-good window applies. An external monitor
 *     probing once a minute therefore costs at most one upstream request per
 *     minute, usually zero over a metro where people are already playing.
 *   - It does NOT require aircraft in the snapshot. A quiet sky is a legitimate
 *     answer (the same rule FallbackProvider applies); only a failed fetch with
 *     no servable cache is an outage.
 *   - The default bbox is the Bay Area (SFO/OAK/SJC — the field-test home base
 *     and the densest user cluster). `CANARY_BBOX=lamin,lomin,lamax,lomax`
 *     moves it; a malformed value fails the boot, like a bad POSITION_PROVIDER,
 *     because a canary that silently probes the wrong sky is worse than none.
 */

/** SFO / OAK / SJC. 0.4° × 0.4°, inside the route's 4 sq-deg limit. */
export const DEFAULT_CANARY_BBOX: Bbox = {
  lamin: 37.5,
  lomin: -122.6,
  lamax: 37.9,
  lomax: -122.2,
};

/**
 * What the canary saw, as reported on /readyz's `checks.feed`:
 *   - `ok`          fresh upstream data (or a fresh cache hit)
 *   - `stale`       upstream failed, served last-good inside the stale window
 *   - `fallback`    fresh data, but the primary feed is down (app.ts upgrades
 *                   `ok` to this while the fallback alerter is engaged)
 *   - `unavailable` upstream failed and nothing servable — phones get 503
 *   - `timeout`     the probe did not answer inside the readiness budget
 * The first three are "ready" (users are getting planes); the last two are not.
 */
export type FeedStatus = "ok" | "stale" | "fallback" | "unavailable" | "timeout";

export interface FeedProbeResult {
  status: FeedStatus;
  /** Aircraft in the served snapshot, when one was served. */
  aircraft?: number;
  /** Upstream snapshot time (unix seconds), when one was served. */
  fetchedAt?: number;
  /** The failure, when `status` is `unavailable`. */
  error?: unknown;
}

/**
 * Parse `CANARY_BBOX` ("lamin,lomin,lamax,lomax" in decimal degrees). Absent or
 * blank → the default. Anything else that is not four finite numbers forming a
 * valid, non-inverted bbox of at most 4 sq deg throws — this runs once at app
 * build time, so the deploy fails instead of the canary quietly watching
 * nothing.
 */
export function parseCanaryBbox(raw: string | undefined): Bbox {
  if (raw === undefined || raw.trim() === "") return DEFAULT_CANARY_BBOX;
  const parts = raw.split(",").map((p) => p.trim());
  if (parts.length !== 4) {
    throw new Error(`CANARY_BBOX must be "lamin,lomin,lamax,lomax", got "${raw}"`);
  }
  const nums = parts.map((p) => (p === "" ? Number.NaN : Number(p)));
  const bbox: Partial<Bbox> = {
    lamin: finiteOrUndefined(nums[0]),
    lomin: finiteOrUndefined(nums[1]),
    lamax: finiteOrUndefined(nums[2]),
    lomax: finiteOrUndefined(nums[3]),
  };
  const invalid = validateBbox(bbox);
  if (invalid) throw new Error(`CANARY_BBOX invalid (${invalid.reason}): "${raw}"`);
  return bbox as Bbox;
}

function finiteOrUndefined(n: number): number | undefined {
  return Number.isFinite(n) ? n : undefined;
}

/**
 * Build the probe over the live tile cache. Never throws: an upstream failure
 * with no servable cache is reported as `unavailable` with the cause attached,
 * so /readyz can log it and answer 503 without an exception path.
 */
export function makeFeedProbe(cache: TileCache, bbox: Bbox): () => Promise<FeedProbeResult> {
  return async () => {
    try {
      const { snapshot, stale } = await cache.get(bbox);
      return {
        status: stale ? "stale" : "ok",
        aircraft: snapshot.aircraft.length,
        fetchedAt: snapshot.fetchedAt,
      };
    } catch (err) {
      return { status: "unavailable", error: err };
    }
  };
}
