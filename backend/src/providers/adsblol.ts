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
}

/** Top-level /v2/point response wrapper. */
export interface AdsbLolResponse {
  ac?: AdsbLolAircraft[] | null;
  /** snapshot generation time, milliseconds since unix epoch. */
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
  const rows = resp.ac ?? [];
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

export interface AdsbLolProviderOptions {
  baseUrl?: string;
  timeoutMs?: number;
  /** Injectable for tests; defaults to global fetch. */
  fetchFn?: typeof fetch;
}

export class AdsbLolProvider implements PositionProvider {
  readonly name = "adsblol";
  private readonly baseUrl: string;
  private readonly timeoutMs: number;
  private readonly fetchFn: typeof fetch;

  constructor(opts: AdsbLolProviderOptions = {}) {
    this.baseUrl = (opts.baseUrl ?? DEFAULT_BASE_URL).replace(/\/+$/, "");
    this.timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    this.fetchFn = opts.fetchFn ?? fetch;
  }

  async aircraftInBbox(bbox: Bbox): Promise<ProviderSnapshot> {
    const center = bboxCenter(bbox);
    // Ceil so we never under-cover; clamp to the API's 250 NM hard cap. The
    // route already rejects bboxes > 4 sq deg, so the covering radius is small
    // in practice and the clamp is just a defensive guard.
    const radiusNm = Math.min(MAX_RADIUS_NM, Math.max(1, Math.ceil(bboxCoveringRadiusNm(bbox))));
    const url = `${this.baseUrl}/v2/point/${center.lat}/${center.lon}/${radiusNm}`;

    const resp = await this.fetchJson(url);
    // adsb.lol `now` is milliseconds; the contract is unix seconds.
    const fetchedAt =
      typeof resp.now === "number" && Number.isFinite(resp.now)
        ? Math.floor(resp.now / 1000)
        : Math.floor(Date.now() / 1000);

    return {
      fetchedAt,
      aircraft: normalizeAdsbLol(resp, fetchedAt, bbox),
    };
  }

  private async fetchJson(url: string): Promise<AdsbLolResponse> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const res = await this.fetchFn(url, {
        method: "GET",
        headers: { accept: "application/json", "user-agent": "tailspot-backend" },
        signal: controller.signal,
      });
      if (!res.ok) {
        throw new UpstreamError(`adsb.lol returned HTTP ${res.status}`);
      }
      return (await res.json()) as AdsbLolResponse;
    } catch (err) {
      if (err instanceof UpstreamError) throw err;
      throw new UpstreamError("adsb.lol request failed", err);
    } finally {
      clearTimeout(timer);
    }
  }
}
