/**
 * adsb.lol public API client (no key). Endpoints verified against the
 * service's source (github.com/adsblol/api, src/adsb_api/utils/api_v2.py):
 *
 *   GET /v2/mil                          all aircraft flagged military
 *   GET /v2/type/{ICAO type}             all aircraft of one type, e.g. A388
 *   GET /v2/point/{lat}/{lon}/{radius}   circle, radius in NM (0–250)
 *
 * All three return the readsb "re-api" JSON: { ac: [...], now: <ms>, total,
 * msg, ctime, ptime }. Per-aircraft fields are the ADSBExchange v2 set
 * (https://www.adsbexchange.com/version-2-api/); altitudes in feet, speed in
 * knots, `seen_pos` in seconds-ago, `dbFlags` bit 0 = military, bit 2 = PIA,
 * bit 3 = LADD. Rate limits are "dynamic based on load", so calls are paced
 * and retried with backoff; a template that can't get data fails cleanly.
 */

import { countryForIcao24 } from "../../../backend/src/providers/icaoCountry.ts";

export const ADSB_LOL_BASE = "https://api.adsb.lol";
const USER_AGENT = "tailspot-content-engine/0.1 (+https://tailspot.app)";

/** The raw readsb row — only fields we read. Everything optional: feeds vary. */
export interface ReadsbAircraft {
  hex?: string;
  flight?: string | null;
  r?: string | null;
  t?: string | null;
  desc?: string | null;
  ownOp?: string | null;
  dbFlags?: number | null;
  alt_baro?: number | "ground" | null;
  alt_geom?: number | null;
  gs?: number | null;
  track?: number | null;
  lat?: number | null;
  lon?: number | null;
  seen_pos?: number | null;
  category?: string | null;
}

export interface ReadsbResponse {
  ac?: ReadsbAircraft[] | null;
  now?: number;
  total?: number;
  msg?: string;
}

export interface Plane {
  hex: string;
  callsign: string | null;
  registration: string | null;
  typecode: string | null;
  /** readsb DB free-text description, e.g. "BOEING 747-8". */
  desc: string | null;
  /** readsb DB owner/operator (often blank). */
  operator: string | null;
  /** Country of registration, derived from the ICAO 24-bit address block. */
  regCountry: string | null;
  lat: number;
  lon: number;
  altFt: number | null;
  onGround: boolean;
  gsKt: number | null;
  track: number | null;
  seenPosS: number | null;
  category: string | null;
  military: boolean;
  /** Privacy ICAO Address / FAA LADD: the owner asked not to be displayed. */
  privacyListed: boolean;
}

const str = (v: unknown): string | null => {
  if (typeof v !== "string") return null;
  const t = v.trim();
  return t.length ? t : null;
};
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);

/** Normalise one readsb row; null when it has no usable identity/position. */
export function normalize(a: ReadsbAircraft): Plane | null {
  const hexRaw = str(a.hex);
  // "~" = non-ICAO (TIS-B / ADS-R) synthetic address: no stable identity.
  if (!hexRaw || hexRaw.startsWith("~")) return null;
  const lat = num(a.lat);
  const lon = num(a.lon);
  if (lat === null || lon === null) return null;
  const onGround = a.alt_baro === "ground";
  const altFt = onGround ? 0 : (num(a.alt_baro) ?? num(a.alt_geom));
  const flags = num(a.dbFlags) ?? 0;
  const hex = hexRaw.toLowerCase();
  return {
    hex,
    callsign: str(a.flight),
    registration: str(a.r),
    typecode: str(a.t)?.toUpperCase() ?? null,
    desc: str(a.desc),
    operator: str(a.ownOp),
    regCountry: countryForIcao24(hex),
    lat,
    lon,
    altFt,
    onGround,
    gsKt: num(a.gs),
    track: num(a.track),
    seenPosS: num(a.seen_pos),
    category: str(a.category)?.toUpperCase() ?? null,
    military: (flags & 1) === 1,
    privacyListed: (flags & 4) === 4 || (flags & 8) === 8,
  };
}

export function normalizeAll(resp: ReadsbResponse | null | undefined): Plane[] {
  const out: Plane[] = [];
  for (const a of resp?.ac ?? []) {
    const p = normalize(a);
    if (p) out.push(p);
  }
  return out;
}

export interface FetchOptions {
  timeoutMs?: number;
  retries?: number;
  fetchFn?: typeof fetch;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** GET JSON with timeout + bounded retry on network errors, 429 and 5xx. */
export async function getJson<T>(url: string, headers: Record<string, string> = {}, opts: FetchOptions = {}): Promise<T> {
  const { timeoutMs = 15_000, retries = 2, fetchFn = fetch } = opts;
  let lastErr: unknown;
  for (let attempt = 0; attempt <= retries; attempt++) {
    if (attempt > 0) await sleep(1500 * 2 ** (attempt - 1));
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), timeoutMs);
    try {
      const res = await fetchFn(url, {
        headers: { accept: "application/json", "user-agent": USER_AGENT, ...headers },
        signal: ctl.signal,
      });
      if (res.status === 429 || res.status >= 500) {
        lastErr = new Error(`HTTP ${res.status} from ${url}`);
        continue;
      }
      if (!res.ok) throw new FatalHttpError(`HTTP ${res.status} from ${url}`);
      return (await res.json()) as T;
    } catch (err) {
      if (err instanceof FatalHttpError) throw err;
      lastErr = err;
    } finally {
      clearTimeout(timer);
    }
  }
  throw new Error(`GET ${url} failed after ${retries + 1} attempts: ${(lastErr as Error)?.message ?? lastErr}`);
}

class FatalHttpError extends Error {}

/** Polite pacing between adsb.lol calls (rate limits are load-dependent). */
export const PACE_MS = 1100;

export async function fetchMil(opts?: FetchOptions): Promise<ReadsbResponse> {
  return getJson<ReadsbResponse>(`${ADSB_LOL_BASE}/v2/mil`, {}, opts);
}

export async function fetchType(code: string, opts?: FetchOptions): Promise<ReadsbResponse> {
  return getJson<ReadsbResponse>(`${ADSB_LOL_BASE}/v2/type/${encodeURIComponent(code)}`, {}, opts);
}

export async function fetchPoint(lat: number, lon: number, radiusNm: number, opts?: FetchOptions): Promise<ReadsbResponse> {
  const r = Math.max(1, Math.min(250, Math.round(radiusNm)));
  return getJson<ReadsbResponse>(`${ADSB_LOL_BASE}/v2/point/${lat}/${lon}/${r}`, {}, opts);
}

export { sleep };
