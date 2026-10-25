import { AdsbFiProvider } from "./adsbfi.js";
import { AdsbLolProvider } from "./adsblol.js";
import { AdsbLolReApiProvider } from "./adsblolReapi.js";
import { AirplanesLiveProvider } from "./airplaneslive.js";
import { type CircuitBreakerOptions, CircuitBreakerProvider } from "./circuitBreaker.js";
import { FallbackProvider, type FallbackProviderOptions } from "./fallback.js";
import type { PositionProvider } from "./types.js";

export * from "./types.js";
export { AdsbLolProvider, normalizeAdsbLol } from "./adsblol.js";
export { AdsbLolReApiProvider } from "./adsblolReapi.js";
export { AirplanesLiveProvider } from "./airplaneslive.js";
export { AdsbFiProvider } from "./adsbfi.js";
export { FallbackProvider } from "./fallback.js";
export { CircuitBreakerProvider, CircuitOpenError } from "./circuitBreaker.js";
export { UpstreamBudget } from "./upstreamBudget.js";
export { countryForIcao24 } from "./icaoCountry.js";
export {
  validateBbox,
  bboxCenter,
  bboxCoveringRadiusNm,
  haversineNm,
  isInsideBbox,
} from "./geo.js";

/**
 * True when an adsb.lol feed is anywhere in the chain, which turns on route
 * enrichment. A composite's name is its members joined by "+", and adsb.lol
 * runs as "adsblol" (public) or "adsblolreapi" (keyed), hence the prefix.
 */
export function chainIncludesAdsbLol(providerName: string): boolean {
  return providerName.split("+").some((member) => member.startsWith("adsblol"));
}

/**
 * Select the active position provider from config. Read ONCE at app build time
 * (the result is captured in buildApp's closure), so flipping the env mid-run
 * has no effect — restart to change providers.
 *
 *   (unset)                          — adsb.fi primary, adsb.lol fallback
 *                                      (adsb.lol was primary until 2026-10-20:
 *                                      it now caps a client at 500 requests a
 *                                      DAY, which one polling phone exhausts
 *                                      in ~80 min; adsb.fi publishes 1 req/s
 *                                      and no daily cap — see adsbfi.ts.
 *                                      airplanes.live 403s Fly's network.)
 *                                      With ADSBLOL_REAPI_KEY set, the
 *                                      fallback is the keyed adsb.lol re-api
 *                                      instead (2026-10-24, adsblolReapi.ts).
 *   POSITION_PROVIDER=adsblol       — adsb.lol only (pre-2026-07 behavior)
 *   POSITION_PROVIDER=adsbfi        — adsb.fi only (debugging a feed)
 *   POSITION_PROVIDER=adsblolreapi  — keyed adsb.lol re-api only (needs the key)
 *   POSITION_PROVIDER=airplaneslive — airplanes.live only (if they grant access)
 *
 * In the default pair, each feed sits behind its own CircuitBreakerProvider
 * (`breakerOptions` carries the alert hooks): a feed that 429s, 403s or keeps
 * failing is skipped for a cooldown instead of being retried on every poll.
 *
 * Any other value (e.g. the long-removed "opensky") throws at startup rather
 * than silently degrading to the fallback pair — a misconfigured deploy should
 * fail loudly, not quietly change providers.
 */
export function selectProvider(
  env: NodeJS.ProcessEnv = process.env,
  fallbackOptions: FallbackProviderOptions = {},
  breakerOptions: CircuitBreakerOptions = {},
): PositionProvider {
  const choice = (env.POSITION_PROVIDER ?? "").toLowerCase();
  const reApiKey = env.ADSBLOL_REAPI_KEY?.trim() || undefined;
  switch (choice) {
    case "adsblol":
      return new AdsbLolProvider();
    case "adsbfi":
      return new AdsbFiProvider();
    case "adsblolreapi":
      if (!reApiKey) {
        throw new Error("POSITION_PROVIDER=adsblolreapi needs ADSBLOL_REAPI_KEY.");
      }
      return new AdsbLolReApiProvider({ apiKey: reApiKey });
    case "airplaneslive":
      return new AirplanesLiveProvider();
    case "":
      return new FallbackProvider(
        new CircuitBreakerProvider(new AdsbFiProvider(), breakerOptions),
        new CircuitBreakerProvider(
          reApiKey ? new AdsbLolReApiProvider({ apiKey: reApiKey }) : new AdsbLolProvider(),
          breakerOptions,
        ),
        fallbackOptions,
      );
    default:
      throw new Error(
        `Unknown POSITION_PROVIDER "${env.POSITION_PROVIDER}" — use "adsblol", "adsbfi", "adsblolreapi", "airplaneslive", or leave unset for the fallback pair.`,
      );
  }
}
