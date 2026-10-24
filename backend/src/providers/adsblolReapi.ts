import { AdsbLolProvider, type AdsbLolProviderOptions } from "./adsblol.js";

/**
 * adsb.lol re-api provider, keyed (FALLBACK since 2026-10-24, when
 * ADSBLOL_REAPI_KEY is set).
 *
 * re-api is readsb's own query interface, which adsb.lol serves at
 * https://re-api.adsb.lol and documents as its replacement for the deprecated
 * public /v2 API (https://www.adsb.lol/docs/feeders-only/re-api/). Until
 * 2026-10 it answered only the IP addresses of active feeders; adsb.lol now
 * issues API keys for it (Noah's was approved 2026-10-23), sent as the
 * `x-api-key` header. The query is a circle, radius in nautical miles:
 *
 *   GET https://re-api.adsb.lol/?circle={lat},{lon},{nm}
 *
 * Same per-aircraft readsb rows as /v2/point (hex/flight/r/t/category/
 * alt_baro/alt_geom/gs/track/lat/lon/seen_pos), with two wrapper differences,
 * confirmed live 2026-10-24 (Bay Area, 25 NM, 84 rows): rows sit under
 * `aircraft`, not `ac`, and `now` is unix SECONDS (1792881555.296), not ms.
 *
 * Why it exists: the public api.adsb.lol caps a client at 500 requests a DAY
 * (2026-10-20 incident), so adsb.lol could only be a thin fallback. The key's
 * limits are on the private request page, not in the API; read the
 * x-ratelimit headers from the Fly machine before promoting this to primary.
 * Route lookups (AdsbLolRouteService) still go to the public api.adsb.lol.
 */

const DEFAULT_BASE_URL = "https://re-api.adsb.lol";
const DEFAULT_STALL_RETRY_AFTER_MS = 3000;

export interface AdsbLolReApiProviderOptions extends AdsbLolProviderOptions {
  apiKey: string;
  /** First-attempt limit before the stall retry (default 3000 ms). */
  stallRetryAfterMs?: number;
}

export class AdsbLolReApiProvider extends AdsbLolProvider {
  override readonly name: string = "adsblolreapi";
  protected override readonly nowIsSeconds = true;
  protected override readonly requiresAircraftArray = true;
  // A healthy answer takes ~0.6 s cold and 0.2–0.5 s warm from Fly. On
  // 2026-10-24 one call in ~30 stalled for 8.9 s (cause unknown; a retry on
  // a fresh connection went straight through), so give up on an attempt at
  // 3 s and retry once inside the 8 s budget. Cheap here: the quota is per
  // key, not adsb.lol's 500/day per IP.
  protected override readonly stallRetryAfterMs: number;

  constructor({ apiKey, stallRetryAfterMs, ...opts }: AdsbLolReApiProviderOptions) {
    super({
      baseUrl: DEFAULT_BASE_URL,
      ...opts,
      headers: { ...opts.headers, "x-api-key": apiKey },
    });
    this.stallRetryAfterMs = stallRetryAfterMs ?? DEFAULT_STALL_RETRY_AFTER_MS;
  }

  protected override pointUrl(lat: number, lon: number, radiusNm: number): string {
    return `${this.baseUrl}/?circle=${lat},${lon},${radiusNm}`;
  }
}
