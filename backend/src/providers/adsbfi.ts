import { AdsbLolProvider, type AdsbLolProviderOptions } from "./adsblol.js";

/**
 * adsb.fi provider (FALLBACK since 2026-10-19).
 *
 * adsb.fi's open-data API returns the same readsb per-aircraft rows as
 * adsb.lol (`ac[]` with hex/flight/r/t/category/alt_baro/alt_geom/gs/track/
 * lat/lon/seen_pos, `now` in milliseconds) — only the path differs:
 *
 *   GET https://opendata.adsb.fi/api/v3/lat/{lat}/lon/{lon}/dist/{nm}
 *
 * (`/api/v2/lat/.../lon/.../dist/...` is deprecated upstream and returns the
 * rows under `aircraft` instead of `ac`; v3 is the documented shape.) Source:
 * https://github.com/adsbfi/opendata. Confirmed from the production machine
 * 2026-10-19: 200 with 50 aircraft over the Bay Area.
 *
 * Why it replaced airplanes.live as the fallback: airplanes.live answers Fly's
 * network with HTTP 403 and a body asking projects to email
 * contact@airplanes.live for access — a policy block, not a rate limit, and
 * it survived the move to a dedicated egress IP. A fallback that cannot be
 * reached is not a fallback. The class is kept (POSITION_PROVIDER=
 * airplaneslive) in case that email is answered.
 *
 * Terms (adsbfi/opendata README): public endpoints are limited to 1 request
 * per second, 4xx responses count toward a temporary IP restriction, "for
 * personal, non-commercial use only", and "You must cite adsb.fi and include a
 * link to our home page". Tailspot is free and this provider is queried only
 * when adsb.lol fails, through the tile cache (≤ 1 fetch per tile per 10 s),
 * so the rate holds; the attribution lives next to adsb.lol's.
 */

const DEFAULT_BASE_URL = "https://opendata.adsb.fi";

export class AdsbFiProvider extends AdsbLolProvider {
  override readonly name: string = "adsbfi";

  constructor(opts: AdsbLolProviderOptions = {}) {
    super({ baseUrl: DEFAULT_BASE_URL, ...opts });
  }

  protected override pointUrl(lat: number, lon: number, radiusNm: number): string {
    return `${this.baseUrl}/api/v3/lat/${lat}/lon/${lon}/dist/${radiusNm}`;
  }
}
