import type { AircraftRoute, NormalizedAircraft } from "./types.js";

/**
 * Opportunistic origin → destination enrichment from adsb.lol's route DB.
 *
 * The live position feed (`/v2/point`) carries hex/callsign/type/registration
 * but NOT the flight's route — adsb.lol exposes that through a *separate*
 * lookup: `GET /api/0/route/<callsign>`, which returns a route object whose
 * `airport_codes` is the "-"-joined ICAO codes (e.g. "KSFO-EGLL") and whose
 * `_airports` array carries per-airport name/city. (The batch
 * `POST /api/0/routeset` was used until 2026-07, when it began returning an
 * empty `201` for every plane; the per-callsign GET returns the same data and
 * works.) Source: https://github.com/adsblol/api.
 *
 * Because that's a second network round-trip, route is enriched *opportunis-
 * tically* and NEVER blocks the position response:
 *
 *   - `enrich(aircraft)` attaches `route` to any aircraft whose callsign is
 *     already cached (a synchronous map read), and fires a background routeset
 *     lookup for the rest. The current response ships immediately; the route
 *     rides along on a subsequent poll (~20 s later) once the cache is warm.
 *   - Routes are cached by callsign (positive + negative), so the per-callsign
 *     GET rate is bounded by *distinct active callsigns per TTL*, not volume.
 *   - A lookup failure NEVER throws and NEVER caches — a missing route is the
 *     normal case (not every flight has one), so it's simply absent and retried.
 *
 * Mirrors the fire-and-forget spirit of `ingest/feedEnrich.ts`, except the
 * result is attached to the served snapshot rather than written to the DB.
 *
 * ## Multi-leg disambiguation + plausibility (2026-07-19; supersedes the
 * ## round-trip-only leg pick of 2026-07-11)
 *
 * A callsign's filing is often MULTI-LEG: an out-and-back "KLGA-KPIT-KLGA", or
 * a through-flight "KONT-KSFO-KORD" (UAL1375). The old parser collapsed a
 * multi-leg filing to first → last — which showed "ONT → ORD" on a plane
 * descending into SFO (field report 2026-07-19). No collapsed pair is ever a
 * journey anyone flies, so the cache now stores the *parsed candidates* (a
 * fixed 2-code route, the per-leg list of a multi-leg filing with airport
 * coordinates, or none) and `enrich` picks the leg the plane is actually ON:
 *
 *   - CORRIDOR check: the plane must lie near the great-circle corridor of a
 *     leg (`corridorDistanceKm` ≤ a tolerance scaled to leg length) for that
 *     leg to be a candidate.
 *   - TRACK check: among plausible legs, the plane's ground `track` must point
 *     at the leg's destination (within `MAX_TRACK_ERR_DEG`, beating the
 *     runner-up by `MIN_TRACK_MARGIN_DEG`). A single plausible leg with no
 *     reported track is accepted on the corridor alone — the filing admits no
 *     other direction; several plausible legs with no track stay `null`.
 *
 * The SAME corridor check gates a plain 2-code route: adsb.lol's route DB is
 * keyed by callsign and can be STALE — SWA1067 was on file as "KMAF-KDAL"
 * while the flight actually flew BWI → SFO (Southwest reuses flight numbers;
 * field report 2026-07-19). A plane observed 1,900 km from the filed corridor
 * is not flying that filing: better no route than a fabricated one.
 *
 * The backfill resolver (`GET /v1/routes/:callsign`) may now carry the
 * caller's position (+ optional track) as query params and applies the same
 * picks; with no position a multi-leg filing resolves to `null` (never a
 * first→last collapse) and a 2-code route is returned un-gated.
 */

const DEFAULT_BASE_URL = "https://api.adsb.lol";
/** adsb.lol's standing-data host — the API's own (deprecated-marked) redirect
 *  target, hit directly because the API hop is what stalls (see `getRoute`). */
const DEFAULT_STANDING_DATA_BASE_URL = "https://vrs-standing-data.adsb.lol";
const DEFAULT_TIMEOUT_MS = 4000;
/** Positive cache: routes are static for a callsign's scheduled life. */
const DEFAULT_TTL_MS = 30 * 60_000;
/** Negative cache: re-check "no route" callsigns occasionally (data syncs in). */
const DEFAULT_NEGATIVE_TTL_MS = 10 * 60_000;
/** Max concurrent per-callsign route GETs (be polite to adsb.lol). */
const ROUTE_CONCURRENCY = 8;

/** Leg pick (`pickLeg`): the ground track must point within this many degrees
 *  of the chosen leg's destination for the pick to be credible. */
const MAX_TRACK_ERR_DEG = 55;
/** ...and the chosen leg must beat the runner-up by at least this margin, so a
 *  plane maneuvering near a shared endpoint (both bearings similar) stays
 *  `null`. */
const MIN_TRACK_MARGIN_DEG = 40;
/** Corridor plausibility: the plane must be within this distance of the leg's
 *  great-circle corridor (or the leg's endpoints)... */
const CORRIDOR_BASE_TOLERANCE_KM = 250;
/** ...widened to this fraction of the leg length for long legs, where real
 *  routings (jet streams, weather) bow far off the great circle. */
const CORRIDOR_TOLERANCE_FRACTION = 0.15;

/** One airport in a routeset row's `_airports` array — only the fields we use.
 *  `location` is the city/municipality ("San Francisco"); `name` the full
 *  airport name ("San Francisco International Airport"); `iata` the 3-letter
 *  display code ("SFO") travelers actually read; `lat`/`lon` the position (used
 *  to disambiguate a round-trip filing's leg from the plane's track). */
interface RoutesetAirport {
  icao?: string;
  iata?: string;
  name?: string;
  location?: string;
  lat?: number;
  lon?: number;
}

/** One row of the `/api/0/routeset` response — only the fields we consume. */
interface RoutesetRow {
  callsign?: string;
  /** ICAO airport codes, "-"-joined (e.g. "KSFO-EGLL"); "unknown" if no route. */
  airport_codes?: string;
  /** Per-airport detail (name/city/coords) for the codes in `airport_codes`. */
  _airports?: RoutesetAirport[];
}

/** A geographic point (airport coordinates from a routeset row's `_airports`). */
interface LatLon {
  lat: number;
  lon: number;
}

/** One leg of a multi-leg filing: the directed route plus both endpoint
 *  coordinates, so `pickLeg` can corridor-check the plane against it and
 *  compare the plane's track to the bearing toward the leg's destination. */
interface RouteLeg {
  route: AircraftRoute;
  from: LatLon;
  to: LatLon;
}

/**
 * A callsign's route parsed from adsb.lol, *before* a direction is chosen:
 *   - `fixed` — a one-way A → B (the common case). Endpoint coordinates ride
 *               along when the row carries them, so a per-plane corridor check
 *               can reject a stale filing (see `resolveDirection`).
 *   - `legs`  — a multi-leg filing (out-and-back A-B-A, through-flight A-B-C,
 *               or longer): the current leg is picked per-aircraft from its
 *               position + track (`pickLeg`).
 *   - `none`  — no usable route on file (negative-cached).
 * Caching the candidates rather than a resolved direction lets the same cached
 * callsign yield a different leg as the plane progresses, without a re-lookup.
 */
type ParsedRoute =
  | { kind: "fixed"; route: AircraftRoute; from?: LatLon; to?: LatLon }
  | { kind: "legs"; legs: RouteLeg[] }
  | { kind: "none" };

/** Cache entry: the parsed route candidates (`none` = "known to have no route",
 *  a negative cache so we don't re-query a routeless callsign every poll). */
interface CacheEntry {
  parsed: ParsedRoute;
  expiresAt: number;
}

/** A plane the route lookup needs: callsign + position (for the plausible check). */
interface RoutePlane {
  callsign: string;
  lat: number;
  lng: number;
}

/** The subset of a plane the leg-pick reads: position + reported ground track. */
interface TrackedPlane {
  latitude: number;
  longitude: number;
  trackDeg: number | null;
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

/**
 * The seam the `GET /v1/routes/:callsign` backfill endpoint calls — unlike
 * `enrich`, this AWAITS the upstream lookup (the caller is a one-shot heal,
 * not the hot position path). Implemented by `AdsbLolRouteService` over the
 * same cache the enricher fills; tests inject a trivial fake.
 */
export interface RouteResolver {
  /** The route for one callsign, or null when none is on file. Never throws
   *  for "no route"; transport errors reject (the endpoint maps them). When
   *  the caller supplies the plane's observed position (+ optional track),
   *  the resolver leg-picks a multi-leg filing and corridor-gates a fixed
   *  one, exactly like `enrich`; without a position a multi-leg filing
   *  resolves to null — the leg can't be disambiguated (see `pickLeg`). */
  resolve(callsign: string, plane?: TrackedPlane): Promise<AircraftRoute | null>;
}

export interface AdsbLolRouteServiceOptions {
  baseUrl?: string;
  /** Base URL of adsb.lol's standing-data host (the primary lookup path —
   *  see `getRoute`). Injectable for tests. */
  standingDataBaseUrl?: string;
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

export class AdsbLolRouteService implements RouteEnricher, RouteResolver {
  private readonly baseUrl: string;
  private readonly standingDataBaseUrl: string;
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
    this.standingDataBaseUrl = (opts.standingDataBaseUrl ?? DEFAULT_STANDING_DATA_BASE_URL).replace(
      /\/+$/,
      "",
    );
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
        // Fresh hit → resolve a direction for THIS plane (a round trip picks
        // its leg from the plane's track; a fixed route ignores it). null = no
        // route (or an ambiguous round trip) → attach nothing.
        const route = resolveDirection(hit, a);
        if (route) a.route = route;
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
      await this.fetchBatch(batch);
    } finally {
      for (const p of batch) this.inFlight.delete(p.callsign);
    }
  }

  /**
   * Resolve + cache each callsign's route via a bounded-concurrency pool of
   * per-callsign GETs. (adsb.lol's batch `POST /api/0/routeset` started
   * returning an empty `201` for every plane ~2026-07; the single
   * `GET /api/0/route/<callsign>` returns the same `airport_codes` + `_airports`
   * and works.) A per-callsign failure is isolated — onError, no cache, retried.
   */
  private async fetchBatch(batch: RoutePlane[]): Promise<void> {
    const posExpiry = this.now() + this.ttlMs;
    const negExpiry = this.now() + this.negativeTtlMs;
    let cursor = 0;
    const worker = async (): Promise<void> => {
      while (cursor < batch.length) {
        const p = batch[cursor++];
        let row: RoutesetRow | null;
        try {
          row = await this.getRoute(p.callsign);
        } catch (err) {
          this.onError(err); // leave uncached → retried on the next poll
          continue;
        }
        const parsed = parseRouteCandidates(row?.airport_codes, row?._airports);
        this.cache.set(p.callsign, {
          parsed,
          // A `none` uses the shorter negative TTL (data may sync in); a real
          // route (fixed or round trip) is static for the flight's life.
          expiresAt: parsed.kind === "none" ? negExpiry : posExpiry,
        });
      }
    };
    const pool = Array.from({ length: Math.min(ROUTE_CONCURRENCY, batch.length) }, () => worker());
    await Promise.all(pool);
  }

  /**
   * GET one callsign's route. Returns the row, or null for "no route on file"
   * (404).
   *
   * Primary: adsb.lol's STANDING-DATA host, hit directly at the same URL the
   * (deprecated-marked) API route 302s to — `routes/<CS[0:2]>/<CS>.json`.
   * Measured from Fly sjc (2026-07-04): the API hop alone took ~6 s to serve
   * its redirect (IPv6 path stalls before the v4 fallback) — longer than the
   * lookup timeout, which had silently broken ALL route enrichment in prod —
   * while the standing-data host answers in ~100 ms. Fallback: the API URL,
   * on TRANSPORT errors only (a 404 from standing data IS the authoritative
   * "no route on file"; both hosts serve the same JSON shape).
   */
  private async getRoute(callsign: string): Promise<RoutesetRow | null> {
    const cs = callsign.toUpperCase();
    const primary = `${this.standingDataBaseUrl}/routes/${encodeURIComponent(cs.slice(0, 2))}/${encodeURIComponent(cs)}.json`;
    try {
      return await this.getRouteFrom(primary);
    } catch (err) {
      this.onError(err);
      return await this.getRouteFrom(`${this.baseUrl}/api/0/route/${encodeURIComponent(cs)}`);
    }
  }

  /** One route GET against a specific URL, with the lookup timeout. Returns
   *  the row, or null for a 404 ("no route on file" → negative-cache). */
  private async getRouteFrom(url: string): Promise<RoutesetRow | null> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const res = await this.fetchFn(url, {
        headers: { accept: "application/json", "user-agent": "tailspot-backend" },
        signal: controller.signal,
      });
      if (res.status === 404) return null; // no route on file → negative-cache
      if (!res.ok) throw new Error(`adsb.lol route HTTP ${res.status}`);
      const json = (await res.json()) as RoutesetRow | undefined;
      return json && typeof json === "object" ? json : null;
    } finally {
      clearTimeout(timer);
    }
  }

  /**
   * Await-resolve one callsign's route, cache-first (RouteResolver — the
   * `GET /v1/routes/:callsign` backfill endpoint). Shares the enricher's
   * cache, so a hot flight is a map read and a cold one costs a single
   * upstream GET. If the callsign is already in-flight from a concurrent
   * `enrich`, `prefetch` skips it and this returns null rather than waiting —
   * the client's next backfill pass picks up the by-then-cached answer.
   *
   * With a `plane` (the endpoint's optional lat/lng/track params) the same
   * corridor + track picks as `enrich` apply; without one, a multi-leg filing
   * resolves to null (never a first→last collapse).
   */
  async resolve(callsign: string, plane?: TrackedPlane): Promise<AircraftRoute | null> {
    const hit = this.lookupCache(callsign);
    if (hit !== undefined) return resolveDirection(hit, plane);
    await this.prefetch([{ callsign, lat: 0, lng: 0 }]);
    const after = this.lookupCache(callsign);
    return after !== undefined ? resolveDirection(after, plane) : null;
  }

  /** Fresh cache value: the parsed candidates (`fixed`/`roundTrip`/`none`), or
   *  `undefined` when absent/expired → needs a lookup. */
  private lookupCache(callsign: string): ParsedRoute | undefined {
    const e = this.cache.get(callsign);
    if (!e) return undefined;
    if (e.expiresAt <= this.now()) {
      this.cache.delete(callsign);
      return undefined;
    }
    return e.parsed;
  }
}

/**
 * Choose the concrete `AircraftRoute` for a plane from its parsed candidates:
 *   - `fixed` → the route — corridor-gated against the plane's position when
 *               both the position and the endpoint coordinates are known (a
 *               plane far off the filed corridor is not flying that filing —
 *               the route DB is keyed by callsign and can be stale). With no
 *               plane (the position-less backfill resolver) the route is
 *               returned un-gated.
 *   - `none`  → null.
 *   - `legs`  → the leg the plane is flying (`pickLeg`), or null when there is
 *               no plane at all or the geometry is ambiguous.
 */
function resolveDirection(
  parsed: ParsedRoute,
  plane: TrackedPlane | undefined,
): AircraftRoute | null {
  switch (parsed.kind) {
    case "fixed":
      if (plane && parsed.from && parsed.to) {
        const p = { lat: plane.latitude, lon: plane.longitude };
        if (!isOnCorridor(p, parsed.from, parsed.to)) return null;
      }
      return parsed.route;
    case "none":
      return null;
    case "legs":
      return plane ? pickLeg(parsed.legs, plane) : null;
  }
}

/**
 * Pick the leg of a multi-leg filing the plane is actually flying, from its
 * position + ground track — or null when the answer is ambiguous.
 *
 * Two tests, in order:
 *   1. CORRIDOR — keep only legs whose great-circle corridor the plane is near
 *      (`isOnCorridor`). A plane over the Bay Area is not on any leg of a
 *      Texas out-and-back.
 *   2. TRACK — the plane's `track` points at the airport it's heading toward:
 *      compare it to the bearing from the plane to each surviving leg's
 *      destination. The winner must be *credible* (within `MAX_TRACK_ERR_DEG`)
 *      and *decisive* (beating the runner-up by `MIN_TRACK_MARGIN_DEG` — two
 *      legs sharing a nearby endpoint have similar corridors but opposite
 *      destination bearings, which is exactly what this separates).
 *
 * A single corridor-plausible leg with NO reported track is accepted — the
 * filing offers no other direction the plane could be flying. Several
 * plausible legs with no track, or a track that points cleanly at no
 * surviving leg (vectoring near a turnaround), return null — the codebase's
 * rule is to never fabricate a journey no one observed.
 */
function pickLeg(legs: RouteLeg[], plane: TrackedPlane): AircraftRoute | null {
  const p = { lat: plane.latitude, lon: plane.longitude };
  const track = plane.trackDeg;
  const plausible = legs.filter((leg) => isOnCorridor(p, leg.from, leg.to));
  if (plausible.length === 0) return null;
  if (track == null) {
    return plausible.length === 1 ? plausible[0].route : null;
  }
  const scored = plausible
    .map((leg) => ({
      leg,
      err: angularDelta(track, initialBearing(p.lat, p.lon, leg.to.lat, leg.to.lon)),
    }))
    .sort((a, b) => a.err - b.err);
  const best = scored[0];
  if (best.err > MAX_TRACK_ERR_DEG) return null;
  if (scored.length > 1 && scored[1].err - best.err < MIN_TRACK_MARGIN_DEG) return null;
  return best.leg.route;
}

/** Whether point `p` lies within the corridor tolerance of the great-circle
 *  SEGMENT from → to. Mid-corridor, the cross-track tolerance scales with leg
 *  length (long-haul routings bow far off the great circle for jet streams /
 *  weather); beyond an endpoint only the BASE tolerance applies — being
 *  "near SFO" must not grow with how far away the other end is. */
function isOnCorridor(p: LatLon, from: LatLon, to: LatLon): boolean {
  const legKm = haversineKm(from, to);
  const m = corridorMetrics(p, from, to);
  const tolKm = m.onSegment
    ? Math.max(CORRIDOR_BASE_TOLERANCE_KM, CORRIDOR_TOLERANCE_FRACTION * legKm)
    : CORRIDOR_BASE_TOLERANCE_KM;
  return m.distanceKm <= tolKm;
}

/**
 * Parse adsb.lol's "-"-joined ICAO `airport_codes` into route CANDIDATES.
 *
 * Exactly two codes A-B (A != B) is a `fixed` route, with endpoint coordinates
 * when the row carries them (so the per-plane corridor gate can apply). Three
 * or more codes — an out-and-back A-B-A or a through-flight A-B-C(-…) — become
 * `legs`, one per consecutive pair, when every airport's coordinates are
 * present, so the current leg can be picked from the plane's position + track.
 * (The old parser collapsed a multi-leg filing to first → last — a pair no
 * one flies; UAL1375 "KONT-KSFO-KORD" rendered as ONT → ORD, 2026-07-19.)
 * Everything else — the "unknown" sentinel, a blank string, a single code, a
 * same-airport A-A, degenerate repeated legs, or a multi-leg filing missing
 * coordinates — is `none`. Exported for unit tests.
 */
export function parseRouteCandidates(
  airportCodes: string | undefined,
  airports?: RoutesetAirport[],
): ParsedRoute {
  if (typeof airportCodes !== "string") return { kind: "none" };
  const trimmed = airportCodes.trim();
  if (trimmed === "" || trimmed.toLowerCase() === "unknown") return { kind: "none" };
  const parts = trimmed
    .split("-")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  if (parts.length < 2) return { kind: "none" };

  const byIcao = new Map<string, RoutesetAirport>();
  if (airports) for (const a of airports) if (a.icao) byIcao.set(a.icao, a);

  // Exactly two codes: a plain one-way filing.
  if (parts.length === 2) {
    const [origin, dest] = parts;
    if (origin === dest) return { kind: "none" }; // degenerate A-A
    return {
      kind: "fixed",
      route: buildDirectedRoute(origin, dest, byIcao),
      from: coordOf(byIcao.get(origin)),
      to: coordOf(byIcao.get(dest)),
    };
  }

  // Three or more codes: one leg per consecutive pair, dropping degenerate
  // same-airport legs (A-A inside a longer filing). Every kept leg needs both
  // endpoint coordinates — without them neither the corridor check nor the
  // track bearing works, and a leg that can't be checked can't be picked.
  const legs: RouteLeg[] = [];
  for (let i = 0; i < parts.length - 1; i++) {
    const origin = parts[i];
    const dest = parts[i + 1];
    if (origin === dest) continue; // degenerate leg (A-A) → skip
    const from = coordOf(byIcao.get(origin));
    const to = coordOf(byIcao.get(dest));
    if (!from || !to) return { kind: "none" }; // no coords → can't pick legs
    legs.push({ route: buildDirectedRoute(origin, dest, byIcao), from, to });
  }
  if (legs.length === 0) return { kind: "none" }; // all legs degenerate (A-A-A)
  return { kind: "legs", legs };
}

/**
 * Parse adsb.lol's `airport_codes` into a single origin → destination, or null.
 *
 * The position-less contract (also used widely in tests): a plain two-code
 * one-way route, else null — the "unknown"/blank/single-code cases and EVERY
 * multi-leg filing (round trip or through-flight) collapse to null, since
 * which leg the plane is on is unknowable without its position. Exported for
 * unit tests.
 */
export function parseRoute(
  airportCodes: string | undefined,
  airports?: RoutesetAirport[],
): AircraftRoute | null {
  const parsed = parseRouteCandidates(airportCodes, airports);
  return parsed.kind === "fixed" ? parsed.route : null;
}

/** Build a directed origin → destination `AircraftRoute`, enriched with IATA
 *  display codes + human-readable city names from the routeset `_airports` map
 *  when present. */
function buildDirectedRoute(
  origin: string,
  dest: string,
  byIcao: Map<string, RoutesetAirport>,
): AircraftRoute {
  const route: AircraftRoute = { originIcao: origin, destIcao: dest };
  const originAirport = byIcao.get(origin);
  const destAirport = byIcao.get(dest);
  const originIata = originAirport?.iata?.trim();
  const destIata = destAirport?.iata?.trim();
  if (originIata) route.originIata = originIata.toUpperCase();
  if (destIata) route.destIata = destIata.toUpperCase();
  const originName = airportName(originAirport);
  const destName = airportName(destAirport);
  if (originName) route.originName = originName;
  if (destName) route.destName = destName;
  return route;
}

/** A usable `LatLon` from a routeset airport, or undefined when coords are
 *  missing/non-finite (→ the round trip can't be disambiguated). */
function coordOf(a: RoutesetAirport | undefined): LatLon | undefined {
  if (!a || typeof a.lat !== "number" || typeof a.lon !== "number") return undefined;
  if (!Number.isFinite(a.lat) || !Number.isFinite(a.lon)) return undefined;
  return { lat: a.lat, lon: a.lon };
}

/** Prefer the city/municipality (short, clean — "San Francisco") over the full
 *  airport name ("San Francisco International Airport") for the reveal subline. */
function airportName(a: RoutesetAirport | undefined): string | undefined {
  const loc = a?.location?.trim();
  if (loc) return loc;
  const name = a?.name?.trim();
  return name && name.length > 0 ? name : undefined;
}

const EARTH_RADIUS_KM = 6371;

/** Great-circle distance between two points, km (haversine). */
function haversineKm(a: LatLon, b: LatLon): number {
  const dLat = toRad(b.lat - a.lat);
  const dLon = toRad(b.lon - a.lon);
  const s =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLon / 2) ** 2;
  return 2 * EARTH_RADIUS_KM * Math.asin(Math.min(1, Math.sqrt(s)));
}

/**
 * Distance (km) from point `p` to the great-circle SEGMENT from → to — the
 * cross-track distance where `p` projects between the endpoints (`onSegment`),
 * else the distance to the nearer endpoint. Standard spherical cross-track /
 * along-track construction (e.g. Movable Type's aviation formulary).
 */
function corridorMetrics(
  p: LatLon,
  from: LatLon,
  to: LatLon,
): { distanceKm: number; onSegment: boolean } {
  const d12 = haversineKm(from, to) / EARTH_RADIUS_KM; // angular leg length
  if (d12 === 0) return { distanceKm: haversineKm(p, from), onSegment: false };
  const d13 = haversineKm(from, p) / EARTH_RADIUS_KM; // angular from → p
  const theta12 = toRad(initialBearing(from.lat, from.lon, to.lat, to.lon));
  const theta13 = toRad(initialBearing(from.lat, from.lon, p.lat, p.lon));
  const crossTrack = Math.asin(Math.sin(d13) * Math.sin(theta13 - theta12));
  // Signed along-track distance of p's projection from the start point.
  const alongTrack =
    Math.acos(clamp(Math.cos(d13) / Math.max(Math.cos(crossTrack), 1e-12), -1, 1)) *
    Math.sign(Math.cos(theta13 - theta12));
  if (alongTrack < 0) return { distanceKm: haversineKm(p, from), onSegment: false };
  if (alongTrack > d12) return { distanceKm: haversineKm(p, to), onSegment: false };
  return { distanceKm: Math.abs(crossTrack) * EARTH_RADIUS_KM, onSegment: true };
}

function clamp(v: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, v));
}

/** Initial great-circle bearing from (lat1,lon1) to (lat2,lon2), degrees true
 *  in [0, 360). */
function initialBearing(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const phi1 = toRad(lat1);
  const phi2 = toRad(lat2);
  const dLon = toRad(lon2 - lon1);
  const y = Math.sin(dLon) * Math.cos(phi2);
  const x = Math.cos(phi1) * Math.sin(phi2) - Math.sin(phi1) * Math.cos(phi2) * Math.cos(dLon);
  return (toDeg(Math.atan2(y, x)) + 360) % 360;
}

/** Smallest absolute angle between two bearings, degrees in [0, 180]. */
function angularDelta(a: number, b: number): number {
  const d = Math.abs(a - b) % 360;
  return d > 180 ? 360 - d : d;
}

function toRad(deg: number): number {
  return (deg * Math.PI) / 180;
}

function toDeg(rad: number): number {
  return (rad * 180) / Math.PI;
}
