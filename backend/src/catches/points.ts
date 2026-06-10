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
