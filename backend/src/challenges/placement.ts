/**
 * Placement + outcome for a challenge — pure functions, no I/O.
 *
 * Competition ranking (spec §5 "Ties"): equal points SHARE a placement and the
 * next placement is skipped — 100 / 100 / 60 → 1, 1, 3. Everyone at placement 1
 * is a winner. This deliberately differs from the global leaderboard, which
 * orders ties by registration date for DISPLAY; a race between friends has no
 * arbitrary tiebreak.
 *
 * Outcome (spec §5 "No Contest", D4): a challenge with fewer than two active
 * participants at the end, or where nobody scored a point, is No Contest —
 * nobody wins and it appears in history as such.
 */

export interface Scored {
  points: number;
  /** Display handle; used only as a stable secondary sort so output is deterministic. */
  handle: string;
}

export type Placed<T> = T & { placement: number };

/**
 * Assign competition placements. Input order is irrelevant; output is sorted
 * by points DESC then handle ASC (case-insensitive) so equal inputs always
 * yield equal output.
 */
export function assignPlacements<T extends Scored>(rows: readonly T[]): Placed<T>[] {
  const sorted = [...rows].sort(
    (a, b) => b.points - a.points || a.handle.toLowerCase().localeCompare(b.handle.toLowerCase()),
  );
  let placement = 0;
  let lastPoints: number | undefined;
  return sorted.map((row, i) => {
    if (row.points !== lastPoints) {
      placement = i + 1; // 1 + number of rows with strictly more points
      lastPoints = row.points;
    }
    return { ...row, placement };
  });
}

export type Outcome = "decided" | "no_contest";

/** No Contest when fewer than two participants remain or nobody has any points. */
export function decideOutcome(rows: readonly Scored[]): Outcome {
  if (rows.length < 2) return "no_contest";
  const max = Math.max(...rows.map((r) => r.points));
  return max > 0 ? "decided" : "no_contest";
}

/** Handles at placement 1 — empty when the outcome is No Contest. */
export function winners<T extends Scored>(placed: readonly Placed<T>[], outcome: Outcome): T[] {
  if (outcome !== "decided") return [];
  return placed.filter((r) => r.placement === 1);
}
