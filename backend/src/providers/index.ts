import { AdsbLolProvider } from "./adsblol.js";
import { OpenSkyProvider } from "./opensky.js";
import type { PositionProvider } from "./types.js";

export * from "./types.js";
export { AdsbLolProvider, normalizeAdsbLol } from "./adsblol.js";
export { OpenSkyProvider, normalizeOpenSky } from "./opensky.js";
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
 *   POSITION_PROVIDER=adsblol   (default) — primary
 *   POSITION_PROVIDER=opensky              — OAuth2 fallback
 */
export function selectProvider(env: NodeJS.ProcessEnv = process.env): PositionProvider {
  const choice = (env.POSITION_PROVIDER ?? "adsblol").toLowerCase();
  switch (choice) {
    case "opensky":
      return new OpenSkyProvider();
    default:
      return new AdsbLolProvider();
  }
}
