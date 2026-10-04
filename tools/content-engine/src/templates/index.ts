import type { Template } from "../types.ts";
import { guessPlane } from "./guessPlane.ts";
import { overCity } from "./overCity.ts";
import { rareNow } from "./rareNow.ts";
import { realCatches } from "./realCatches.ts";

/** Every template, by id. */
export const TEMPLATES: readonly Template<any>[] = [realCatches, rareNow, overCity, guessPlane];

/**
 * Seven-day rotation: day N uses ROTATION[N % 7]. real-catches is the primary
 * format (4 of 7 days); the other three get one day each.
 */
export const ROTATION: readonly Template<any>[] = [realCatches, rareNow, realCatches, overCity, realCatches, guessPlane, realCatches];

export function templateById(id: string): Template<any> {
  const t = TEMPLATES.find((x) => x.id === id);
  if (!t) throw new Error(`unknown --template "${id}" (have: ${TEMPLATES.map((x) => x.id).join(", ")})`);
  return t;
}

export function templateForDay(dayIndex: number): Template<any> {
  return ROTATION[((dayIndex % ROTATION.length) + ROTATION.length) % ROTATION.length];
}

/** Used when the rotated template can't get live data: always works offline. */
export const FALLBACK_TEMPLATE = guessPlane;

/**
 * What to try, in order, when a rotated template can't fetch or finds nothing
 * worth posting. real-catches → rare-now → guess-plane; the live ones → guess-plane.
 */
export function fallbackChain(id: string): Template<any>[] {
  if (id === FALLBACK_TEMPLATE.id) return [];
  if (id === realCatches.id) return [rareNow, FALLBACK_TEMPLATE];
  return [FALLBACK_TEMPLATE];
}
