import type { AircraftRoute, NormalizedAircraft } from "./types.js";

/**
 * Opportunistic origin → destination enrichment from adsb.lol's route DB.
 *
 * The live position feed (`/v2/point`) carries hex/callsign/type/registration
 * but NOT the flight's route — adsb.lol exposes that through a *separate*
 * lookup: `POST /api/0/routeset` with `{ planes: [{ callsign, lat, lng }] }`,
 * which returns one row per callsign whose `airport_codes` is the "-"-joined
 * ICAO codes (e.g. "KSFO-EGLL", or the sentinel "unknown" for no route). Source:
 * https://github.com/adsblol/api (utils/api_routes.py + utils/provider.py).
 *
 * Because that's a second network round-trip, route is enriched *opportunis-
 * tically* and NEVER blocks the position response:
 *
 *   - `enrich(aircraft)` attaches `route` to any aircraft whose callsign is
 *     already cached (a synchronous map read), and fires a background routeset
 *     lookup for the rest. The current response ships immediately; the route
 *     rides along on a subsequent poll (~20 s later) once the cache is warm.
 *   - Routes are cached by callsign (positive + negative), so the routeset POST
 *     rate is bounded by *distinct active callsigns per TTL*, not request volume.
 *   - A lookup failure NEVER throws and NEVER caches — a missing route is the
 *     normal case (not every flight has one), so it's simply absent and retried.
 *
 * Mirrors the fire-and-forget spirit of `ingest/feedEnrich.ts`, except the
 * result is attached to the served snapshot rather than written to the DB.
 */

const DEFAULT_BASE_URL = "https://api.adsb.lol";
const DEFAULT_TIMEOUT_MS = 4000;
/** Positive cache: routes are static for a callsign's scheduled life. */
const DEFAULT_TTL_MS = 30 * 60_000;
/** Negative cache: re-check "no route" callsigns occasionally (data syncs in). */
const DEFAULT_NEGATIVE_TTL_MS = 10 * 60_000;
/** adsb.lol rejects a routeset POST with > 100 planes (HTTP 400). */
const ROUTESET_MAX_BATCH = 100;

/** One airport in a routeset row's `_airports` array — only the fields we use.
 *  `location` is the city/municipality ("San Francisco"); `name` the full
 *  airport name ("San Francisco International Airport"). */
interface RoutesetAirport {
  icao?: string;
  name?: string;
  location?: string;
}

/** One row of the `/api/0/routeset` response — only the fields we consume. */
interface RoutesetRow {
  callsign?: string;
  /** ICAO airport codes, "-"-joined (e.g. "KSFO-EGLL"); "unknown" if no route. */
  airport_codes?: string;
  /** Per-airport detail (name/city/coords) for the codes in `airport_codes`. */
  _airports?: RoutesetAirport[];
}

/** Cache entry: a resolved route, or `null` = "known to have no route"
 *  (negative cache, so we don't re-query a routeless callsign every poll). */
interface CacheEntry {
  route: AircraftRoute | null;
  expiresAt: number;
}

/** A plane the route lookup needs: callsign + position (for the plausible check). */
interface RoutePlane {
  callsign: string;
  lat: number;
  lng: number;
}

/**
 * The seam the aircraft route calls. Implemented by `AdsbLolRouteService`;
 * tests inject a trivial fake. Omitted entirely (route tests, non-adsblol
 * provider) → no `route` field on the wire.
 */
export interface RouteEnricher {
  /** Attach `route` to each aircraft with a cached route, and opportunistically
   *  kick a background lookup for the rest. Synchronous + never throws. */
  enrich(aircraft: NormalizedAircraft[]): void;
}

export interface AdsbLolRouteServiceOptions {
  baseUrl?: string;
  timeoutMs?: number;
  /** Injectable for tests; defaults to global fetch. */
  fetchFn?: typeof fetch;
  /** Unix-ms clock (injectable for deterministic cache-TTL tests). */
  now?: () => number;
  /** Positive-cache TTL (ms). */
  ttlMs?: number;
  /** Negative-cache TTL (ms) for callsigns with no known route. */
  negativeTtlMs?: number;
  /** Best-effort error sink; lookups never surface to the request path. */
  onError?: (err: unknown) => void;
}

export class AdsbLolRouteService implements RouteEnricher {
  private readonly baseUrl: string;
  private readonly timeoutMs: number;
  private readonly fetchFn: typeof fetch;
  private readonly now: () => number;
  private readonly ttlMs: number;
  private readonly negativeTtlMs: number;
  private readonly onError: (err: unknown) => void;
  private readonly cache = new Map<string, CacheEntry>();
  /** Callsigns with a routeset POST in flight — deduped so overlapping polls
   *  never issue duplicate lookups for the same flight. */
  private readonly inFlight = new Set<string>();

  constructor(opts: AdsbLolRouteServiceOptions = {}) {
    this.baseUrl = (opts.baseUrl ?? DEFAULT_BASE_URL).replace(/\/+$/, "");
    this.timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    this.fetchFn = opts.fetchFn ?? fetch;
    this.now = opts.now ?? Date.now;
    this.ttlMs = opts.ttlMs ?? DEFAULT_TTL_MS;
    this.negativeTtlMs = opts.negativeTtlMs ?? DEFAULT_NEGATIVE_TTL_MS;
    this.onError = opts.onError ?? (() => {});
  }

  enrich(aircraft: NormalizedAircraft[]): void {
    const toLookup: RoutePlane[] = [];
    const scheduled = new Set<string>();
    for (const a of aircraft) {
      const cs = a.callsign;
      if (!cs) continue; // no callsign → no route to resolve
      const hit = this.lookupCache(cs);
      if (hit !== undefined) {
        if (hit) a.route = hit; // fresh positive hit → attach; null = no route
        continue;
      }
      // Cache miss → schedule a background lookup, deduped per callsign.
      if (this.inFlight.has(cs) || scheduled.has(cs)) continue;
      scheduled.add(cs);
      toLookup.push({ callsign: cs, lat: a.latitude, lng: a.longitude });
    }
    // Fire-and-forget: prefetch never throws and never blocks the response.
    if (toLookup.length > 0) void this.prefetch(toLookup);
  }

  /**
   * POST the callsigns to `/api/0/routeset` and populate the cache. Public and
   * awaitable so tests are deterministic; in production `enrich` calls it as a
   * detached background task. NEVER throws — a failed lookup leaves the callsign
   * uncached for a later retry (it does NOT negative-cache transport errors).
   */
  async prefetch(planes: RoutePlane[]): Promise<void> {
    // Dedup by callsign + skip in-flight, then mark in-flight up front so a
    // concurrent enrich in the same tick won't re-issue the same lookup.
    const unique = new Map<string, RoutePlane>();
    for (const p of planes) {
      if (!this.inFlight.has(p.callsign)) unique.set(p.callsign, p);
    }
    const batch = [...unique.values()];
    if (batch.length === 0) return;
    for (const p of batch) this.inFlight.add(p.callsign);
    try {
      for (let i = 0; i < batch.length; i += ROUTESET_MAX_BATCH) {
        await this.fetchBatch(batch.slice(i, i + ROUTESET_MAX_BATCH));
      }
    } finally {
      for (const p of batch) this.inFlight.delete(p.callsign);
    }
  }

  /** Fetch + cache one ≤100-plane batch. Transport failure → onError, no cache. */
  private async fetchBatch(batch: RoutePlane[]): Promise<void> {
    let rows: RoutesetRow[];
    try {
      rows = await this.postRouteset(batch);
    } catch (err) {
      this.onError(err); // leave uncached → retried on the next poll
      return;
    }
    const byCallsign = new Map<string, RoutesetRow>();
    for (const r of rows) {
      if (typeof r.callsign === "string") byCallsign.set(r.callsign, r);
    }
    const posExpiry = this.now() + this.ttlMs;
    const negExpiry = this.now() + this.negativeTtlMs;
    for (const p of batch) {
      const row = byCallsign.get(p.callsign);
      const route = parseRoute(row?.airport_codes, row?._airports);
      this.cache.set(
        p.callsign,
        route ? { route, expiresAt: posExpiry } : { route: null, expiresAt: negExpiry },
      );
    }
  }

  private async postRouteset(batch: RoutePlane[]): Promise<RoutesetRow[]> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const res = await this.fetchFn(`${this.baseUrl}/api/0/routeset`, {
        method: "POST",
        headers: {
          accept: "application/json",
          "content-type": "application/json",
          "user-agent": "tailspot-backend",
        },
        body: JSON.stringify({
          planes: batch.map((p) => ({ callsign: p.callsign, lat: p.lat, lng: p.lng })),
        }),
        signal: controller.signal,
      });
      if (!res.ok) throw new Error(`adsb.lol routeset HTTP ${res.status}`);
      const json = (await res.json()) as unknown;
      return Array.isArray(json) ? (json as RoutesetRow[]) : [];
    } finally {
      clearTimeout(timer);
    }
  }

  /** Fresh cache value: an `AircraftRoute` (positive), `null` (negative — don't
   *  re-query), or `undefined` (absent/expired → needs a lookup). */
  private lookupCache(callsign: string): AircraftRoute | null | undefined {
    const e = this.cache.get(callsign);
    if (!e) return undefined;
    if (e.expiresAt <= this.now()) {
      this.cache.delete(callsign);
      return undefined;
    }
    return e.route;
  }
}

/**
 * Parse adsb.lol's "-"-joined ICAO `airport_codes` into origin → destination.
 * Returns null for the "unknown" sentinel, a blank string, or anything with
 * fewer than two codes (no usable journey). Multi-leg routes collapse to
 * first → last. Exported for unit tests.
 */
export function parseRoute(
  airportCodes: string | undefined,
  airports?: RoutesetAirport[],
): AircraftRoute | null {
  if (typeof airportCodes !== "string") return null;
  const trimmed = airportCodes.trim();
  if (trimmed === "" || trimmed.toLowerCase() === "unknown") return null;
  const parts = trimmed
    .split("-")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  const origin = parts[0];
  const dest = parts[parts.length - 1];
  if (!origin || !dest || parts.length < 2) return null;
  const route: AircraftRoute = { originIcao: origin, destIcao: dest };
  // Enrich with human-readable names when the routeset row carried `_airports`.
  if (airports && airports.length > 0) {
    const byIcao = new Map<string, RoutesetAirport>();
    for (const a of airports) if (a.icao) byIcao.set(a.icao, a);
    const originName = airportName(byIcao.get(origin));
    const destName = airportName(byIcao.get(dest));
    if (originName) route.originName = originName;
    if (destName) route.destName = destName;
  }
  return route;
}

/** Prefer the city/municipality (short, clean — "San Francisco") over the full
 *  airport name ("San Francisco International Airport") for the reveal subline. */
function airportName(a: RoutesetAirport | undefined): string | undefined {
  const loc = a?.location?.trim();
  if (loc) return loc;
  const name = a?.name?.trim();
  return name && name.length > 0 ? name : undefined;
}
