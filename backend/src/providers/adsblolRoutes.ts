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
 * ## Round-trip leg disambiguation (2026-07-11)
 *
 * A flight filed as an out-and-back under one callsign has `airport_codes` like
 * "KLGA-KPIT-KLGA" — origin == destination once collapsed to first→last. A card
 * reading "LGA → LGA" is worse than nothing, so historically these resolved to
 * `null` (route dropped). But which leg the plane is *on* is recoverable from
 * live flight data: its ground `track` points at the airport it's heading
 * toward. So the cache now stores the *parsed candidates* (a fixed route, an
 * A↔B round trip with airport coordinates, or none), and `enrich` picks the leg
 * per-aircraft from its position + track — attaching "LGA → PIT" outbound and
 * "PIT → LGA" inbound. The pick is gated on confidence (`pickRoundTripLeg`): a
 * plane maneuvering near the turnaround, or with no reported track, falls back
 * to `null` rather than guessing a direction no one observed. The backfill
 * resolver (`GET /v1/routes/:callsign`) has no live position, so a round trip
 * still resolves to `null` there.
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

/** Round-trip leg pick (`pickRoundTripLeg`): the ground track must point within
 *  this many degrees of the chosen airport for the pick to be credible. */
const MAX_TRACK_ERR_DEG = 55;
/** ...and the chosen airport must beat the other by at least this margin, so a
 *  plane maneuvering near the turnaround (both bearings similar) stays `null`. */
const MIN_TRACK_MARGIN_DEG = 40;

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

/**
 * A callsign's route parsed from adsb.lol, *before* a direction is chosen:
 *   - `fixed`     — a one-way A → B (the common case); route is final.
 *   - `roundTrip` — an out-and-back A ⇄ B; the leg is picked per-aircraft from
 *                   its position + track (`away` = A→B, `back` = B→A, with the
 *                   destination coordinate of each so `pickRoundTripLeg` can
 *                   compare the plane's track to the bearing toward each end).
 *   - `none`      — no usable route on file (negative-cached).
 * Caching the candidates rather than a resolved direction lets the same cached
 * callsign yield "outbound" or "inbound" as the plane turns around, without a
 * re-lookup.
 */
type ParsedRoute =
  | { kind: "fixed"; route: AircraftRoute }
  | {
      kind: "roundTrip";
      away: AircraftRoute;
      back: AircraftRoute;
      awayDest: LatLon;
      backDest: LatLon;
    }
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
   *  for "no route"; transport errors reject (the endpoint maps them). A
   *  round-trip filing resolves to null here — with no live position, the leg
   *  can't be disambiguated (see `pickRoundTripLeg`). */
  resolve(callsign: string): Promise<AircraftRoute | null>;
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
   * No live position here, so a round-trip filing resolves to null (its leg is
   * only pickable in `enrich`, from the plane's track).
   */
  async resolve(callsign: string): Promise<AircraftRoute | null> {
    const hit = this.lookupCache(callsign);
    if (hit !== undefined) return resolveDirection(hit, undefined);
    await this.prefetch([{ callsign, lat: 0, lng: 0 }]);
    const after = this.lookupCache(callsign);
    return after !== undefined ? resolveDirection(after, undefined) : null;
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
 *   - `fixed`     → the route, verbatim.
 *   - `none`      → null.
 *   - `roundTrip` → the leg the plane is flying, from its track, or null when
 *                   the plane has no track or the geometry is ambiguous, or when
 *                   there is no plane at all (the backfill resolver).
 */
function resolveDirection(
  parsed: ParsedRoute,
  plane: TrackedPlane | undefined,
): AircraftRoute | null {
  switch (parsed.kind) {
    case "fixed":
      return parsed.route;
    case "none":
      return null;
    case "roundTrip":
      if (!plane || plane.trackDeg == null) return null;
      return pickRoundTripLeg(parsed, plane.latitude, plane.longitude, plane.trackDeg);
  }
}

/**
 * Pick the leg of an out-and-back (A ⇄ B) the plane is actually flying, from
 * its position + ground track — or null when the direction is ambiguous.
 *
 * The plane's `track` points at the airport it's heading toward: compare it to
 * the bearing from the plane to each end. The chosen airport must be both
 * *plausible* (track within `MAX_TRACK_ERR_DEG` of it) and *decisive* (better
 * than the other end by `MIN_TRACK_MARGIN_DEG`). Near the turnaround, or on a
 * vectored terminal leg where the track doesn't point cleanly at either end,
 * neither test passes and we return null — the codebase's rule is to never
 * fabricate a journey no one observed.
 */
function pickRoundTripLeg(
  rt: { away: AircraftRoute; back: AircraftRoute; awayDest: LatLon; backDest: LatLon },
  lat: number,
  lng: number,
  track: number,
): AircraftRoute | null {
  const towardTurnaround = initialBearing(lat, lng, rt.awayDest.lat, rt.awayDest.lon); // toward B
  const towardHome = initialBearing(lat, lng, rt.backDest.lat, rt.backDest.lon); // toward A
  const errAway = angularDelta(track, towardTurnaround);
  const errBack = angularDelta(track, towardHome);
  if (errAway <= MAX_TRACK_ERR_DEG && errBack - errAway >= MIN_TRACK_MARGIN_DEG) return rt.away;
  if (errBack <= MAX_TRACK_ERR_DEG && errAway - errBack >= MIN_TRACK_MARGIN_DEG) return rt.back;
  return null;
}

/**
 * Parse adsb.lol's "-"-joined ICAO `airport_codes` into route CANDIDATES.
 *
 * A one-way A → B (first != last) is a `fixed` route; multi-leg collapses to
 * first → last. An out-and-back A-B-A (first == last, three codes) becomes a
 * `roundTrip` when both airports' coordinates are present — so the leg can be
 * picked from the plane's track. Everything else — the "unknown" sentinel, a
 * blank string, a single code, a same-airport A-A, a longer round trip that
 * doesn't reduce to one leg, or an A-B-A missing coordinates — is `none`.
 * Exported for unit tests.
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
  const origin = parts[0];
  const dest = parts[parts.length - 1];
  if (!origin || !dest || parts.length < 2) return { kind: "none" };

  const byIcao = new Map<string, RoutesetAirport>();
  if (airports) for (const a of airports) if (a.icao) byIcao.set(a.icao, a);

  // One-way (incl. multi-leg collapsed to first → last): route is final.
  if (origin !== dest) {
    return { kind: "fixed", route: buildDirectedRoute(origin, dest, byIcao) };
  }

  // origin === dest → an out-and-back filed under one callsign. Only the
  // simple three-leg A-B-A reduces to a single ambiguous pair of legs; a
  // same-airport A-A or a longer tour (A-B-C-A) can't, so leave them null.
  if (parts.length !== 3) return { kind: "none" };
  const home = origin; // parts[0] === parts[2]
  const turnaround = parts[1];
  if (turnaround === home) return { kind: "none" }; // degenerate A-A-A
  const homeCoord = coordOf(byIcao.get(home));
  const turnaroundCoord = coordOf(byIcao.get(turnaround));
  if (!homeCoord || !turnaroundCoord) return { kind: "none" }; // no coords → can't pick a leg
  return {
    kind: "roundTrip",
    away: buildDirectedRoute(home, turnaround, byIcao), // A → B
    back: buildDirectedRoute(turnaround, home, byIcao), // B → A
    awayDest: turnaroundCoord,
    backDest: homeCoord,
  };
}

/**
 * Parse adsb.lol's `airport_codes` into a single origin → destination, or null.
 *
 * The one-shot resolver's contract (also used widely in tests): a one-way route
 * (incl. multi-leg first → last), else null — the "unknown"/blank/single-code
 * cases and a round trip both collapse to null, since no single direction is
 * known without a live track. Exported for unit tests.
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
