import {
  type Bbox,
  type NormalizedAircraft,
  type PositionProvider,
  type ProviderSnapshot,
  UpstreamError,
} from "./types.js";

/**
 * OpenSky provider (FALLBACK, config-selected via POSITION_PROVIDER=opensky).
 *
 * OpenSky's REST API:
 *   GET /api/states/all?lamin=&lomin=&lamax=&lomax=
 * is already bbox-shaped and already SI (altitudes in METERS, velocity in m/s),
 * so the normalization is mostly de-tupling the positional-array rows.
 *
 * Auth is OAuth2 client-credentials. The token endpoint is on the OLDER
 * Keycloak path WITH the `/auth/` prefix — the modern path without it 404s.
 * This is empirically verified in this project (see OpenSkyClient.swift):
 *   https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token
 * Credentials come from env (OPENSKY_CLIENT_ID / OPENSKY_CLIENT_SECRET).
 * Tokens are cached until ~30 s before expiry.
 *
 * states/all positional-array layout (index → field), per
 * https://openskynetwork.github.io/opensky-api/rest.html :
 *   0  icao24            (string, lowercase hex)
 *   1  callsign          (string, may be padded / empty)
 *   2  origin_country    (string)
 *   3  time_position     (unix seconds of last position, or null)
 *   5  longitude         (deg)
 *   6  latitude          (deg)
 *   7  baro_altitude     (meters)
 *   8  on_ground         (bool)
 *   9  velocity          (m/s)
 *  10  true_track        (deg)
 *  13  geo_altitude      (meters)
 */

const TOKEN_URL =
  "https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token";
const DEFAULT_BASE_URL = "https://opensky-network.org";
const DEFAULT_TIMEOUT_MS = 12000;
/** Refresh the token this many seconds before it actually expires. */
const TOKEN_REFRESH_SKEW_S = 30;

/** A single OpenSky state vector (positional array). */
export type OpenSkyState = [
  icao24: string,
  callsign: string | null,
  origin_country: string | null,
  time_position: number | null,
  last_contact: number | null,
  longitude: number | null,
  latitude: number | null,
  baro_altitude: number | null,
  on_ground: boolean,
  velocity: number | null,
  true_track: number | null,
  vertical_rate: number | null,
  sensors: number[] | null,
  geo_altitude: number | null,
  ...rest: unknown[],
];

export interface OpenSkyStatesResponse {
  /** snapshot time, unix seconds (already SI — no /1000 needed). */
  time?: number;
  states?: OpenSkyState[] | null;
}

/**
 * Pure normalizer: OpenSky states response → normalized aircraft. Exported for
 * fixture tests (no network). OpenSky is already SI, so this is mostly index
 * extraction + lossy drop of rows with no lat/lon.
 */
export function normalizeOpenSky(resp: OpenSkyStatesResponse): NormalizedAircraft[] {
  const states = resp.states ?? [];
  const out: NormalizedAircraft[] = [];
  for (const s of states) {
    const normalized = normalizeOne(s);
    if (normalized !== null) out.push(normalized);
  }
  return out;
}

function normalizeOne(s: OpenSkyState): NormalizedAircraft | null {
  const rawIcao = s[0];
  if (typeof rawIcao !== "string" || rawIcao.length === 0) return null;
  const icao24 = rawIcao.trim().toLowerCase();

  const longitude = s[5];
  const latitude = s[6];
  if (typeof longitude !== "number" || typeof latitude !== "number") return null;
  if (!Number.isFinite(longitude) || !Number.isFinite(latitude)) return null;

  const onGround = s[8] === true;
  const geoAlt = s[13];
  const baroAlt = s[7];
  let altitudeMeters = 0;
  if (!onGround) {
    if (typeof geoAlt === "number" && Number.isFinite(geoAlt)) {
      altitudeMeters = geoAlt;
    } else if (typeof baroAlt === "number" && Number.isFinite(baroAlt)) {
      altitudeMeters = baroAlt;
    }
  }

  const velocity = s[9];
  const track = s[10];
  const timePosition = s[3];
  const country = s[2];

  return {
    icao24,
    callsign: trimCallsign(s[1]),
    originCountry: typeof country === "string" && country.length > 0 ? country : null,
    longitude,
    latitude,
    altitudeMeters,
    velocityMps: typeof velocity === "number" && Number.isFinite(velocity) ? velocity : null,
    trackDeg: typeof track === "number" && Number.isFinite(track) ? track : null,
    onGround,
    positionTimestamp:
      typeof timePosition === "number" && Number.isFinite(timePosition)
        ? Math.round(timePosition)
        : null,
  };
}

function trimCallsign(callsign: string | null | undefined): string | null {
  if (typeof callsign !== "string") return null;
  const t = callsign.trim();
  return t.length > 0 ? t : null;
}

interface CachedToken {
  accessToken: string;
  /** unix seconds at which we should stop trusting this token. */
  expiresAt: number;
}

export interface OpenSkyProviderOptions {
  clientId?: string;
  clientSecret?: string;
  baseUrl?: string;
  tokenUrl?: string;
  timeoutMs?: number;
  /** Injectable for tests; defaults to global fetch. */
  fetchFn?: typeof fetch;
  /** Injectable clock (unix ms) for deterministic token-expiry tests. */
  now?: () => number;
}

export class OpenSkyProvider implements PositionProvider {
  readonly name = "opensky";
  private readonly clientId: string;
  private readonly clientSecret: string;
  private readonly baseUrl: string;
  private readonly tokenUrl: string;
  private readonly timeoutMs: number;
  private readonly fetchFn: typeof fetch;
  private readonly now: () => number;
  private token: CachedToken | null = null;
  /** In-flight token fetch, so concurrent calls share one refresh. */
  private tokenInFlight: Promise<CachedToken> | null = null;

  constructor(opts: OpenSkyProviderOptions = {}) {
    this.clientId = opts.clientId ?? process.env.OPENSKY_CLIENT_ID ?? "";
    this.clientSecret = opts.clientSecret ?? process.env.OPENSKY_CLIENT_SECRET ?? "";
    this.baseUrl = (opts.baseUrl ?? DEFAULT_BASE_URL).replace(/\/+$/, "");
    this.tokenUrl = opts.tokenUrl ?? TOKEN_URL;
    this.timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    this.fetchFn = opts.fetchFn ?? fetch;
    this.now = opts.now ?? Date.now;
  }

  async aircraftInBbox(bbox: Bbox): Promise<ProviderSnapshot> {
    const token = await this.getToken();
    const params = new URLSearchParams({
      lamin: String(bbox.lamin),
      lomin: String(bbox.lomin),
      lamax: String(bbox.lamax),
      lomax: String(bbox.lomax),
    });
    const url = `${this.baseUrl}/api/states/all?${params.toString()}`;

    const resp = await this.fetchStates(url, token);
    const fetchedAt =
      typeof resp.time === "number" && Number.isFinite(resp.time)
        ? Math.floor(resp.time)
        : Math.floor(this.now() / 1000);

    return {
      fetchedAt,
      aircraft: normalizeOpenSky(resp),
    };
  }

  private async fetchStates(url: string, token: string): Promise<OpenSkyStatesResponse> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const res = await this.fetchFn(url, {
        method: "GET",
        headers: { accept: "application/json", authorization: `Bearer ${token}` },
        signal: controller.signal,
      });
      if (!res.ok) {
        throw new UpstreamError(`OpenSky returned HTTP ${res.status}`);
      }
      return (await res.json()) as OpenSkyStatesResponse;
    } catch (err) {
      if (err instanceof UpstreamError) throw err;
      throw new UpstreamError("OpenSky request failed", err);
    } finally {
      clearTimeout(timer);
    }
  }

  /** Return a valid access token, refreshing (once, shared) when near expiry. */
  private async getToken(): Promise<string> {
    const nowSec = Math.floor(this.now() / 1000);
    if (this.token && this.token.expiresAt > nowSec) {
      return this.token.accessToken;
    }
    // Coalesce concurrent refreshes into one request.
    if (!this.tokenInFlight) {
      this.tokenInFlight = this.fetchToken().finally(() => {
        this.tokenInFlight = null;
      });
    }
    this.token = await this.tokenInFlight;
    return this.token.accessToken;
  }

  private async fetchToken(): Promise<CachedToken> {
    if (!this.clientId || !this.clientSecret) {
      throw new UpstreamError("OpenSky credentials not configured");
    }
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const body = new URLSearchParams({
        grant_type: "client_credentials",
        client_id: this.clientId,
        client_secret: this.clientSecret,
      });
      const res = await this.fetchFn(this.tokenUrl, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: body.toString(),
        signal: controller.signal,
      });
      if (!res.ok) {
        throw new UpstreamError(`OpenSky token endpoint returned HTTP ${res.status}`);
      }
      const json = (await res.json()) as { access_token?: string; expires_in?: number };
      if (!json.access_token) {
        throw new UpstreamError("OpenSky token response missing access_token");
      }
      const expiresInS = typeof json.expires_in === "number" ? json.expires_in : 300;
      const nowSec = Math.floor(this.now() / 1000);
      return {
        accessToken: json.access_token,
        expiresAt: nowSec + Math.max(0, expiresInS - TOKEN_REFRESH_SKEW_S),
      };
    } catch (err) {
      if (err instanceof UpstreamError) throw err;
      throw new UpstreamError("OpenSky token request failed", err);
    } finally {
      clearTimeout(timer);
    }
  }
}
