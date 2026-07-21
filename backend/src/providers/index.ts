import { AdsbLolProvider } from "./adsblol.js";
import { AirplanesLiveProvider } from "./airplaneslive.js";
import { FallbackProvider, type FallbackProviderOptions } from "./fallback.js";
import type { PositionProvider } from "./types.js";

export * from "./types.js";
export { AdsbLolProvider, normalizeAdsbLol } from "./adsblol.js";
export { AirplanesLiveProvider } from "./airplaneslive.js";
export { FallbackProvider } from "./fallback.js";
export { countryForIcao24 } from "./icaoCountry.js";
export {
  validateBbox,
  bboxCenter,
  bboxCoveringRadiusNm,
  haversineNm,
  isInsideBbox,
} from "./geo.js";

/**
 * Select the active position provider from config. Read ONCE at app build time
 * (the result is captured in buildApp's closure), so flipping the env mid-run
 * has no effect — restart to change providers.
 *
 *   (unset)                          — adsb.lol primary, airplanes.live fallback
 *   POSITION_PROVIDER=adsblol       — adsb.lol only (pre-2026-07 behavior)
 *   POSITION_PROVIDER=airplaneslive — airplanes.live only (debugging a feed)
 *
 * Any other value (e.g. the long-removed "opensky") throws at startup rather
 * than silently degrading to the fallback pair — a misconfigured deploy should
 * fail loudly, not quietly change providers.
 */
export function selectProvider(
  env: NodeJS.ProcessEnv = process.env,
  fallbackOptions: FallbackProviderOptions = {},
): PositionProvider {
  const choice = (env.POSITION_PROVIDER ?? "").toLowerCase();
  switch (choice) {
    case "adsblol":
      return new AdsbLolProvider();
    case "airplaneslive":
      return new AirplanesLiveProvider();
    case "":
      return new FallbackProvider(
        new AdsbLolProvider(),
        new AirplanesLiveProvider(),
        fallbackOptions,
      );
    default:
      throw new Error(
        `Unknown POSITION_PROVIDER "${env.POSITION_PROVIDER}" — ` +
          `use "adsblol", "airplaneslive", or leave unset for the fallback pair.`,
      );
  }
}
