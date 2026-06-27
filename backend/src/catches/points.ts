/**
 * Rarity → points mapping (WP 1.5).
 *
 * A faithful mirror of the iOS `GameSystem.Rarity.points` ladder
 * (ios/Tailspot/Tailspot/GameSystem.swift): common 10, uncommon 25, rare 100,
 * epic 500, legendary 2000. An unknown/unresolved rarity scores the common
 * floor (10) — when the metadata service can't resolve a typecode, we still
 * accept the catch and award the baseline rather than rejecting it.
 *
 * Points are ALWAYS computed server-side from server-resolved rarity. The wire
 * contract carries no client points/rarity by design — never trust the client.
 */

export type Rarity = "common" | "uncommon" | "rare" | "epic" | "legendary";

const POINTS: Record<Rarity, number> = {
  common: 10,
  uncommon: 25,
  rare: 100,
  epic: 500,
  legendary: 2000,
};

/** The baseline awarded for an unknown/unresolved rarity. */
export const UNKNOWN_RARITY_POINTS = 10;

/**
 * The current scoring REGIME. Stamped onto every catch as `scoringVersion` so a
 * re-score can find rows scored under an older regime and re-derive them.
 *
 * BUMP THIS when the scoring LOGIC changes — the `POINTS` ladder below, the
 * `UNKNOWN_RARITY_POINTS` floor, or the icao24→typecode→rarity resolution chain
 * (`DrizzleCatchStore.resolveRarity`). After bumping, run `npm run rescore`
 * (see catches/rescore.ts) to bring every older-regime catch up to the new one.
 *
 * Do NOT bump for reference-DATA growth (the registry learning a new airframe):
 * those catches are still version-current, just resolved against better data —
 * `rescore` picks them up via their still-null `rarity`, not their version.
 */
export const CURRENT_SCORING_VERSION = 1;

/** Type guard for a known rarity tier string. */
export function isRarity(value: string | null | undefined): value is Rarity {
  return (
    value === "common" ||
    value === "uncommon" ||
    value === "rare" ||
    value === "epic" ||
    value === "legendary"
  );
}

/**
 * Points for a (possibly null / unknown) rarity string. Unresolved rarity →
 * UNKNOWN_RARITY_POINTS (10). Mirrors the iOS tiers exactly.
 */
export function pointsForRarity(rarity: string | null | undefined): number {
  return isRarity(rarity) ? POINTS[rarity] : UNKNOWN_RARITY_POINTS;
}
