/**
 * Catch re-scoring (the lever behind the "points are a re-derivable projection"
 * pattern).
 *
 * `points`/`rarity`/`typecode` on a catch are NOT immutable facts — they're a
 * projection of (icao24 → registry/typecodes reference tables → scoring ladder).
 * That projection goes stale two ways:
 *
 *   1. Reference DATA grows. The registry learns an airframe it didn't know at
 *      upload time (e.g. a foreign widebody added after the US-only seed), so a
 *      catch frozen at the unknown floor (10) can now resolve to its real tier.
 *      These rows are found by their still-null `rarity`.
 *   2. Scoring LOGIC changes. The rarity→points ladder or the resolution chain
 *      is reworked and `CURRENT_SCORING_VERSION` is bumped. Older-regime rows are
 *      found by `scoringVersion < CURRENT_SCORING_VERSION`.
 *
 * `rescoreCatches` re-runs the ONE canonical scorer (`CatchStore.scoreCatch`,
 * the same call the upload path uses) over the affected rows and rewrites their
 * projection, stamping the current regime. It is:
 *   - IDEMPOTENT — a second run over settled data changes nothing.
 *   - DRY-RUNNABLE — `{ dryRun: true }` computes the full delta and writes nothing,
 *     so a public-leaderboard re-score's blast radius is reviewable before it lands.
 *   - BATCHED — resolves each distinct icao24 once, writes once per airframe.
 *
 * Run as a script:  npm run rescore -- [--all] [--dry-run]
 *   (default targets only stale rows: unresolved OR older-regime.)
 */

import { eq, inArray, isNull, lt, or } from "drizzle-orm";
import { type Database, getDb } from "../db/client.js";
import { catches } from "../db/schema.js";
import { DrizzleCatchStore, type ScoredCatch } from "../identity/store.js";
import { CURRENT_SCORING_VERSION } from "./points.js";

export interface RescoreOptions {
  /** Re-score EVERY catch, not just the stale set. Default false. */
  all?: boolean;
  /** Compute the delta and report it, but write NOTHING. Default false. */
  dryRun?: boolean;
}

/** One rarity movement, aggregated across the catches that made it. */
export interface RarityTransition {
  /** As-stored tier before re-scoring ("unknown" when null). */
  from: string;
  /** Re-resolved tier ("unknown" when still null). */
  to: string;
  /** How many catches made this exact move. */
  catches: number;
  /** Total points delta across those catches (can be negative on a downward rebalance). */
  pointsDelta: number;
}

export interface RescoreReport {
  /** Catches considered (the stale set, or all). */
  scanned: number;
  /** Distinct airframes (icao24s) resolved — one scorer call each. */
  distinctIcaos: number;
  /** Catches whose typecode/rarity/points actually changed. */
  changed: number;
  /** Catches written (changed projection OR a version-only restamp). */
  written: number;
  /** Summed `points` over `scanned`, before and after. */
  pointsBefore: number;
  pointsAfter: number;
  /** Rarity movements, most catches first. Excludes no-op (from === to) moves. */
  transitions: RarityTransition[];
  /** False on a dry run — the report reflects what WOULD change. */
  applied: boolean;
}

const tierLabel = (r: string | null): string => r ?? "unknown";

/**
 * Re-derive catch scoring for the target set and (unless dry-run) persist it.
 * Pure-ish: all DB access goes through `db`; the only "logic" is the canonical
 * scorer, shared with upload.
 */
export async function rescoreCatches(
  db: Database,
  opts: RescoreOptions = {},
): Promise<RescoreReport> {
  const store = new DrizzleCatchStore(db);

  // Target rows. Default = stale: unresolved (`rarity IS NULL`, may now resolve)
  // OR scored under an older regime (`scoringVersion < CURRENT`). `--all` forces
  // the whole table (e.g. to verify a no-op, or a belt-and-suspenders sweep).
  const baseSelect = db
    .select({
      id: catches.id,
      icao24: catches.icao24,
      typecode: catches.typecode,
      rarity: catches.rarity,
      points: catches.points,
      scoringVersion: catches.scoringVersion,
    })
    .from(catches);
  const rows = opts.all
    ? await baseSelect
    : await baseSelect.where(
        or(isNull(catches.rarity), lt(catches.scoringVersion, CURRENT_SCORING_VERSION)),
      );

  const report: RescoreReport = {
    scanned: rows.length,
    distinctIcaos: 0,
    changed: 0,
    written: 0,
    pointsBefore: 0,
    pointsAfter: 0,
    transitions: [],
    applied: !opts.dryRun,
  };
  if (rows.length === 0) return report;

  // Resolve each distinct airframe ONCE (many catches share an icao24).
  const distinct = [...new Set(rows.map((r) => r.icao24))];
  report.distinctIcaos = distinct.length;
  const scoredByIcao = new Map<string, ScoredCatch>();
  for (const icao24 of distinct) {
    scoredByIcao.set(icao24, await store.scoreCatch(icao24));
  }

  // Tally deltas + bucket the ids that need a write, grouped by icao24 (all rows
  // of one airframe get the same new projection → one UPDATE per airframe).
  const transitions = new Map<string, RarityTransition>();
  const writesByIcao = new Map<string, { score: ScoredCatch; ids: string[] }>();
  for (const row of rows) {
    const scored = scoredByIcao.get(row.icao24);
    if (!scored) continue; // unreachable — every icao24 was resolved above
    report.pointsBefore += row.points;
    report.pointsAfter += scored.points;

    const projectionChanged =
      scored.points !== row.points ||
      scored.rarity !== row.rarity ||
      scored.typecode !== row.typecode;
    const needsRestamp = row.scoringVersion !== scored.scoringVersion;

    if (projectionChanged) {
      report.changed += 1;
      const key = `${tierLabel(row.rarity)}→${tierLabel(scored.rarity)}`;
      const t = transitions.get(key) ?? {
        from: tierLabel(row.rarity),
        to: tierLabel(scored.rarity),
        catches: 0,
        pointsDelta: 0,
      };
      t.catches += 1;
      t.pointsDelta += scored.points - row.points;
      transitions.set(key, t);
    }

    if (projectionChanged || needsRestamp) {
      const bucket = writesByIcao.get(row.icao24) ?? { score: scored, ids: [] };
      bucket.ids.push(row.id);
      writesByIcao.set(row.icao24, bucket);
    }
  }
  report.written = [...writesByIcao.values()].reduce((n, b) => n + b.ids.length, 0);
  report.transitions = [...transitions.values()].sort((a, b) => b.catches - a.catches);

  if (opts.dryRun) return report;

  // Apply: one UPDATE per airframe, all within a single transaction so a
  // re-score is all-or-nothing.
  await db.transaction(async (tx) => {
    for (const { score, ids } of writesByIcao.values()) {
      await tx
        .update(catches)
        .set({
          typecode: score.typecode,
          rarity: score.rarity,
          points: score.points,
          scoringVersion: score.scoringVersion,
        })
        .where(ids.length === 1 ? eq(catches.id, ids[0]) : inArray(catches.id, ids));
    }
  });

  return report;
}

/** Pretty-print a report for the CLI. */
function formatReport(report: RescoreReport, opts: RescoreOptions): string {
  const mode = opts.all ? "all" : "stale";
  const delta = report.pointsAfter - report.pointsBefore;
  const sign = delta >= 0 ? "+" : "";
  const restamp =
    report.written > report.changed
      ? `  (+${report.written - report.changed} version restamp)`
      : "";
  const lines = [
    `rescore: scanned ${report.scanned} catch(es) across ${report.distinctIcaos} airframe(s) [mode: ${mode}, ${report.applied ? "APPLY" : "DRY RUN"}]`,
    `  changed: ${report.changed} catch(es)${restamp}`,
    `  points:  ${report.pointsBefore} → ${report.pointsAfter}  (Δ ${sign}${delta})`,
  ];
  if (report.transitions.length > 0) {
    lines.push("  transitions:");
    for (const t of report.transitions) {
      const d = t.pointsDelta >= 0 ? `+${t.pointsDelta}` : `${t.pointsDelta}`;
      lines.push(
        `    ${t.from.padEnd(10)} → ${t.to.padEnd(10)} ${String(t.catches).padStart(5)} catch(es)  ${d.padStart(7)}`,
      );
    }
  }
  lines.push(
    report.applied ? `  applied: wrote ${report.written} row(s)` : "  DRY RUN — no rows written",
  );
  return lines.join("\n");
}

/** Script entrypoint:  node dist/catches/rescore.js [--all] [--dry-run] */
async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const opts: RescoreOptions = {
    all: args.includes("--all"),
    dryRun: args.includes("--dry-run"),
  };
  const db = getDb();
  const report = await rescoreCatches(db, opts);
  console.log(formatReport(report, opts));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
