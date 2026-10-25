import { bboxCenter, bboxCoveringRadiusNm, isInsideBbox } from "./geo.js";
import { countryForIcao24 } from "./icaoCountry.js";
import {
  type Bbox,
  type NormalizedAircraft,
  type PositionProvider,
  type ProviderSnapshot,
  UpstreamError,
} from "./types.js";

/**
 * adsb.lol provider (PRIMARY).
 *
 * adsb.lol exposes the readsb/ADS-B-Exchange-v2-compatible REST API at
 * https://api.adsb.lol. The only geographic query is point+radius, not bbox:
 *
 *   GET /v2/point/{lat}/{lon}/{radius}     (radius in nautical miles, max 250)
 *
 * Confirmed live + against the OpenAPI spec at https://api.adsb.lol/api/openapi.json
 * (radius is an integer 0–250). Docs: https://www.adsb.lol/docs/open-data/api/
 * ("compatible with the ADSBExchange Rapid API. It is a drop-in replacement").
 * Field reference: https://www.adsbexchange.com/version-2-api/
 *
 * Because the upstream is a circle, we compute the smallest circle covering
 * the requested bbox (center + corner distance), fetch that, and filter the
 * results back down to the rectangle server-side. Slightly over-fetches; keeps
 * the wire contract honest (clients asked for a bbox, get a bbox).
 *
 * Unit conversions (locked by fixture tests):
 *   - alt_baro / alt_geom: FEET (or the string "ground") → meters.
 *   - gs: KNOTS → m/s.
 *   - seen_pos: seconds-ago → positionTimestamp = fetchedAt - seen_pos.
 *   - hex: lowercase; a leading "~" marks a non-ICAO (TIS-B/ADS-R) synthetic
 *     address — we DROP those entries (no stable identity to catch, and the
 *     country table can't resolve them). Documented choice.
 *   - flight: space-padded callsign → trimmed, null if empty.
 *   - originCountry: derived from icao24 via the ICAO allocation table (readsb
 *     feeds don't carry origin_country).
 */

const FEET_TO_METERS = 0.3048;
const KNOTS_TO_MPS = 0.514444;
/** adsb.lol /v2/point radius hard cap (OpenAPI: integer, max 250 NM). */
const MAX_RADIUS_NM = 250;
const DEFAULT_BASE_URL = "https://api.adsb.lol";
const DEFAULT_TIMEOUT_MS = 8000;

/** The readsb/ADSBExchange-v2 per-aircraft shape — only the fields we consume. */
export interface AdsbLolAircraft {
  hex?: string;
  flight?: string | null;
  /** number (feet) or the string "ground". */
  alt_baro?: number | "ground" | null;
  alt_geom?: number | null;
  /** ground speed, knots. */
  gs?: number | null;
  /** true track, degrees. */
  track?: number | null;
  lat?: number | null;
  lon?: number | null;
  /** seconds since this position was last updated. */
  seen_pos?: number | null;
  /** ICAO type designator from the readsb aircraft DB (e.g. "A359"). */
  t?: string | null;
  /** registration / tail number from the readsb aircraft DB (e.g. "9V-SMH"). */
  r?: string | null;
  /**
   * ADS-B emitter category broadcast by the airframe itself, e.g. "A1"
   * (light) … "A5" (heavy) … "A7" (rotorcraft), "B1" (glider), "B6" (UAV).
   * This is the only field that *authoritatively* says "this is a helicopter"
   * — DO-260B category A7 — without guessing from the manufacturer string.
   */
  category?: string | null;
}

/** Top-level /v2/point response wrapper. */
export interface AdsbLolResponse {
  ac?: AdsbLolAircraft[] | null;
  /** The same rows under readsb's own key: re-api (and adsb.fi's deprecated
   *  v2) answer `aircraft` instead of the ADSBExchange-style `ac`. */
  aircraft?: AdsbLolAircraft[] | null;
  /** Snapshot generation time: milliseconds since unix epoch on /v2/point,
   *  SECONDS on re-api (see `nowIsSeconds`). */
  now?: number;
  total?: number;
}

/**
 * Pure normalizer: readsb response + fetchedAt (unix seconds) + the requested
 * bbox → normalized aircraft, filtered to the bbox.
 *
 * Exported so fixture tests exercise the conversions without any network. The
 * `bbox` arg lets the function drop the circle-vs-rectangle overhang; pass
 * `null` to skip the geo filter (e.g. when the caller already filtered).
 */
export function normalizeAdsbLol(
  resp: AdsbLolResponse,
  fetchedAt: number,
  bbox: Bbox | null,
): NormalizedAircraft[] {
  const rows = resp.ac ?? resp.aircraft ?? [];
  const out: NormalizedAircraft[] = [];
  for (const a of rows) {
    const normalized = normalizeOne(a, fetchedAt);
    if (normalized === null) continue;
    if (bbox && !isInsideBbox(normalized.latitude, normalized.longitude, bbox)) continue;
    out.push(normalized);
  }
  return out;
}

/** Normalize a single readsb row, or null to drop it (lossy-per-element). */
function normalizeOne(a: AdsbLolAircraft, fetchedAt: number): NormalizedAircraft | null {
  const rawHex = a.hex;
  if (typeof rawHex !== "string" || rawHex.length === 0) return null;
  // "~" prefix = non-ICAO synthetic (TIS-B/ADS-R) address. Drop: no stable
  // catchable identity and no country mapping.
  if (rawHex.startsWith("~")) return null;
  const icao24 = rawHex.toLowerCase();

  // No position → drop (mirrors iOS FailableDecodable; a contract requirement).
  if (typeof a.lat !== "number" || typeof a.lon !== "number") return null;
  if (!Number.isFinite(a.lat) || !Number.isFinite(a.lon)) return null;

  const onGround = a.alt_baro === "ground";

  // Altitude: geometric preferred, barometric fallback, 0 if unknown/on-ground.
  let altitudeMeters = 0;
  if (!onGround) {
    if (typeof a.alt_geom === "number" && Number.isFinite(a.alt_geom)) {
      altitudeMeters = a.alt_geom * FEET_TO_METERS;
    } else if (typeof a.alt_baro === "number" && Number.isFinite(a.alt_baro)) {
      altitudeMeters = a.alt_baro * FEET_TO_METERS;
    }
  }

  const velocityMps =
    typeof a.gs === "number" && Number.isFinite(a.gs) ? a.gs * KNOTS_TO_MPS : null;
  const trackDeg = typeof a.track === "number" && Number.isFinite(a.track) ? a.track : null;

  // seen_pos is "seconds ago"; absolute timestamp = fetchedAt - seen_pos.
  const positionTimestamp =
    typeof a.seen_pos === "number" && Number.isFinite(a.seen_pos)
      ? Math.round(fetchedAt - a.seen_pos)
      : null;

  const callsign = trimCallsign(a.flight);

  return {
    icao24,
    callsign,
    originCountry: countryForIcao24(icao24),
    longitude: a.lon,
    latitude: a.lat,
    altitudeMeters,
    velocityMps,
    trackDeg,
    onGround,
    positionTimestamp,
    // Pass the readsb DB's type/registration straight through. `undefined`
    // (missing or blank upstream) is dropped by JSON.stringify, so the wire
    // omits the key and the iOS client sees nil — never an empty string.
    typecode: trimField(a.t),
    registration: trimField(a.r),
    // Emitter category passes through with the same omit-when-blank semantics.
    // Uppercased so the iOS interpreter can compare against canonical codes
    // ("A7") without re-casing; feeds occasionally emit lowercase.
    category: trimField(a.category)?.toUpperCase(),
  };
}

function trimCallsign(flight: string | null | undefined): string | null {
  if (typeof flight !== "string") return null;
  const t = flight.trim();
  return t.length > 0 ? t : null;
}

/** Trim an optional string field; undefined for missing/blank so the JSON key
 *  is omitted entirely (vs. emitting `null`/`""` for every position-only row). */
function trimField(v: string | null | undefined): string | undefined {
  if (typeof v !== "string") return undefined;
  const t = v.trim();
  return t.length > 0 ? t : undefined;
}

/**
 * Render the IETF RateLimit headers (and Retry-After) a readsb aggregator
 * sends, for log/alert text. Null when none are present. Exported for tests.
 */
export function rateLimitSummary(headers: Headers): string | null {
  const parts: string[] = [];
  const limit = headers.get("x-ratelimit-limit") ?? headers.get("ratelimit-limit");
  const remaining = headers.get("x-ratelimit-remaining") ?? headers.get("ratelimit-remaining");
  const reset = headers.get("x-ratelimit-reset") ?? headers.get("ratelimit-reset");
  const retryAfter = headers.get("retry-after");
  if (limit) parts.push(`ratelimit-limit=${limit}`);
  if (remaining) parts.push(`remaining=${remaining}`);
  if (reset) parts.push(`reset=${reset}s`);
  if (retryAfter) parts.push(`retry-after=${retryAfter}`);
  return parts.length > 0 ? parts.join(" ") : null;
}

/**
 * How long an error response asks us to wait, in seconds: `Retry-After`
 * (delta-seconds or an HTTP date), else the RateLimit reset header. adsb.lol
 * sends one reset per window ("1, 60, 41000"); without knowing which window
 * tripped, the longest is the safe reading. Undefined when absent or garbled.
 * Exported for tests.
 */
export function retryAfterSeconds(
  headers: Headers,
  nowMs: number = Date.now(),
): number | undefined {
  const retryAfter = headers.get("retry-after")?.trim();
  if (retryAfter) {
    if (/^\d+$/.test(retryAfter)) return Number(retryAfter);
    const at = Date.parse(retryAfter);
    if (Number.isFinite(at)) return Math.max(0, Math.ceil((at - nowMs) / 1000));
  }
  const reset = headers.get("x-ratelimit-reset") ?? headers.get("ratelimit-reset");
  if (reset) {
    const values = reset
      .split(",")
      .map((v) => Number.parseFloat(v.split(";")[0] ?? ""))
      .filter((v) => Number.isFinite(v) && v >= 0);
    if (values.length > 0) {
      const v = Math.max(...values);
      // Some servers send an epoch timestamp instead of a delta.
      return v > 1e9 ? Math.max(0, Math.ceil(v - nowMs / 1000)) : Math.ceil(v);
    }
  }
  return undefined;
}

export interface AdsbLolProviderOptions {
  baseUrl?: string;
  timeoutMs?: number;
  /** Injectable for tests; defaults to global fetch. */
  fetchFn?: typeof fetch;
  /** Extra request headers (re-api's `x-api-key`). Never logged. */
  headers?: Record<string, string>;
}

export class AdsbLolProvider implements PositionProvider {
  // Widened to `string` (not the literal type) so AirplanesLiveProvider — a
  // thin subclass pointing the same readsb client at a different aggregator —
  // can override it.
  readonly name: string = "adsblol";
  protected readonly baseUrl: string;
  private readonly timeoutMs: number;
  private readonly fetchFn: typeof fetch;
  // An ES private field, not TS `private`: it holds re-api's key, and a `#`
  // field is invisible to JSON.stringify and pino if the provider is logged.
  readonly #headers: Record<string, string>;
  /** True when the upstream's `now` is unix seconds (readsb re-api) rather
   *  than the /v2/point milliseconds. Overridden by AdsbLolReApiProvider. */
  protected readonly nowIsSeconds: boolean = false;
  /**
   * When true, a 200 body without an `aircraft` array is an UpstreamError
   * rather than an empty sky. readsb's re-api always sends the array (empty
   * when no planes), so its absence means an error body. Off for the /v2
   * feeds, whose empty-area shape isn't pinned down; an error there would
   * turn a quiet coverage desert into a fallback.
   */
  protected readonly requiresAircraftArray: boolean = false;

  constructor(opts: AdsbLolProviderOptions = {}) {
    this.baseUrl = (opts.baseUrl ?? DEFAULT_BASE_URL).replace(/\/+$/, "");
    this.timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    this.fetchFn = opts.fetchFn ?? fetch;
    this.#headers = opts.headers ?? {};
  }

  async aircraftInBbox(bbox: Bbox): Promise<ProviderSnapshot> {
    const center = bboxCenter(bbox);
    // Ceil so we never under-cover; clamp to the API's 250 NM hard cap. The
    // route already rejects bboxes > 4 sq deg, so the covering radius is small
    // in practice and the clamp is just a defensive guard.
    const radiusNm = Math.min(MAX_RADIUS_NM, Math.max(1, Math.ceil(bboxCoveringRadiusNm(bbox))));
    const url = this.pointUrl(center.lat, center.lon, radiusNm);

    const resp = await this.fetchJson(url);
    if (this.requiresAircraftArray && !Array.isArray(resp.aircraft)) {
      throw new UpstreamError(`${this.name} returned no aircraft array`);
    }
    // /v2/point `now` is milliseconds, re-api's is seconds; the contract is
    // unix seconds.
    const fetchedAt =
      typeof resp.now === "number" && Number.isFinite(resp.now)
        ? Math.floor(this.nowIsSeconds ? resp.now : resp.now / 1000)
        : Math.floor(Date.now() / 1000);

    return {
      fetchedAt,
      aircraft: normalizeAdsbLol(resp, fetchedAt, bbox),
      provider: this.name,
    };
  }

  /**
   * The point+radius URL for this aggregator. adsb.lol and airplanes.live use
   * the ADSBExchange-v2 path; adsb.fi serves the identical response from a
   * different path, so the subclass overrides only this (see adsbfi.ts).
   */
  protected pointUrl(lat: number, lon: number, radiusNm: number): string {
    return `${this.baseUrl}/v2/point/${lat}/${lon}/${radiusNm}`;
  }

  /**
   * One request, retried ONCE if the connection is dropped (ECONNRESET and
   * friends) before an answer arrives. On 2026-10-17 adsb.lol was resetting
   * connections under load, and a second attempt often got through. Both
   * attempts share one `timeoutMs` deadline, so a retry never makes the
   * caller wait longer than before. HTTP errors (403, 429, 5xx) and timeouts
   * are NOT retried: those are answers, not dropped connections — and a
   * retried 429 would spend adsb.lol's daily quota twice for nothing.
   */
  private async fetchJson(url: string): Promise<AdsbLolResponse> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      try {
        return await this.fetchOnce(url, controller.signal);
      } catch (err) {
        if (!isDroppedConnection(err) || controller.signal.aborted) throw err;
        return await this.fetchOnce(url, controller.signal);
      }
    } catch (err) {
      if (err instanceof UpstreamError) throw err;
      throw new UpstreamError(`${this.name} request failed`, err);
    } finally {
      clearTimeout(timer);
    }
  }

  private async fetchOnce(url: string, signal: AbortSignal): Promise<AdsbLolResponse> {
    const res = await this.fetchFn(url, {
      method: "GET",
      headers: { accept: "application/json", "user-agent": "tailspot-backend", ...this.#headers },
      signal,
    });
    if (!res.ok) {
      // Quota headers travel in the message so the Fly log and Sentry show
      // WHICH bucket said no. adsb.lol publishes `x-ratelimit-limit: 4,
      // 4;w=1, 60;w=60, 500;w=86400` — per second, per minute, per DAY —
      // and on 2026-10-20 the daily one was inferred from timing because
      // nothing had recorded it.
      const quota = rateLimitSummary(res.headers);
      throw new UpstreamError(
        `${this.name} returned HTTP ${res.status}${quota ? ` (${quota})` : ""}`,
        undefined,
        { status: res.status, retryAfterSeconds: retryAfterSeconds(res.headers) },
      );
    }
    return (await res.json()) as AdsbLolResponse;
  }
}

/** Socket-level codes meaning "the connection died", as opposed to an answer. */
const DROPPED_CONNECTION_CODES = new Set(["ECONNRESET", "EPIPE", "ECONNREFUSED", "UND_ERR_SOCKET"]);

/**
 * True when `err` (or a `.cause` it wraps) is a dropped connection. Node's
 * fetch reports these as `TypeError: fetch failed` with the socket error as
 * `.cause`, so walk the chain, depth-bounded like `isTransientConnectionError`.
 */
function isDroppedConnection(err: unknown): boolean {
  let current: unknown = err;
  for (let depth = 0; current != null && depth < 5; depth++) {
    const code = (current as { code?: unknown }).code;
    if (typeof code === "string" && DROPPED_CONNECTION_CODES.has(code)) return true;
    current = (current as { cause?: unknown }).cause;
  }
  return false;
}
