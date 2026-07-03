import { AdsbLolProvider, type AdsbLolProviderOptions } from "./adsblol.js";

/**
 * airplanes.live provider (FALLBACK).
 *
 * airplanes.live exposes the same readsb/ADS-B-Exchange-v2-compatible REST API
 * as adsb.lol (GET /v2/point/{lat}/{lon}/{radius}, radius in NM), with the same
 * per-aircraft field shape — so this is the adsb.lol client pointed at a
 * different aggregator, nothing more. Confirmed live 2026-07-03: identical
 * response shape; at every point sampled airplanes.live was a superset of or
 * equal to adsb.lol (Singapore 14 vs 9 with all 9 shared; Berkeley ~even).
 *
 * Docs: https://airplanes.live/api-guide/ — anonymous REST access, please-be-
 * reasonable limit of ~1 request/second. We sit far under it: this provider is
 * only queried when adsb.lol errors (see FallbackProvider), and the tile cache
 * already caps genuine upstream fetches at one per tile per TTL.
 */

const DEFAULT_BASE_URL = "https://api.airplanes.live";

export class AirplanesLiveProvider extends AdsbLolProvider {
  override readonly name: string = "airplaneslive";

  constructor(opts: AdsbLolProviderOptions = {}) {
    super({ baseUrl: DEFAULT_BASE_URL, ...opts });
  }
}
