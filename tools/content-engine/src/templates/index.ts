import type { Template } from "../types.ts";
import { guessPlane } from "./guessPlane.ts";
import { overCity } from "./overCity.ts";
import { rareNow } from "./rareNow.ts";

/** Rotation order: day N uses TEMPLATES[N % 3]. */
export const TEMPLATES: readonly Template<any>[] = [rareNow, overCity, guessPlane];

export function templateById(id: string): Template<any> {
  const t = TEMPLATES.find((x) => x.id === id);
  if (!t) throw new Error(`unknown --template "${id}" (have: ${TEMPLATES.map((x) => x.id).join(", ")})`);
  return t;
}

export function templateForDay(dayIndex: number): Template<any> {
  return TEMPLATES[((dayIndex % TEMPLATES.length) + TEMPLATES.length) % TEMPLATES.length];
}

/** Used when the rotated template can't get live data: always works offline. */
export const FALLBACK_TEMPLATE = guessPlane;
