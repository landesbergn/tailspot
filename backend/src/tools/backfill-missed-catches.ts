/**
 * One-off operator backfill: credit catches the client recorded but the
 * server never received.
 *
 * WHY THIS EXISTS (2026-07-31). Two catches by device
 * efb375ca-bd56-53af-9437-337feb1ec197 (handle `jtflcntmltstlbms`) fired
 * `catch_performed` locally and never produced a `catch_uploaded`:
 *
 *   1. ae0584 — a Lockheed C-5M Super Galaxy (USAF 87-0039, RCH2067),
 *      tap-revealed 2026-06-30T23:13:37Z at 39.0 deg off-axis. The reveal cone
 *      (`emptySkyTapMaxOffsetDeg` = 40) is WIDER than the camera frame
 *      (56 deg H x 72 deg V, i.e. 28/36 deg half-angles), so the plane was
 *      pinned + force-locked while being structurally impossible to project on
 *      screen — and the capture button only targets a pin when
 *      `onScreenIcaos.contains(pin)`. The shutter could never fire on it.
 *      C5M is epic/mil: the single biggest catch this device would have held.
 *   2. a3bef1 — a Cessna 340 (N340SU), caught 2026-07-18T12:20:48Z. Plain
 *      upload gap; no gate, no delete, no suspect-discard. It just never left
 *      the phone.
 *
 * This script is NOT a general repair tool and is NOT wired into
 * package.json — it names two specific rows and is expected to run exactly
 * once. It is kept in-tree as the audit record of a manual credit.
 *
 * WHAT IT GUARANTEES
 *   - Scoring goes through the ONE canonical scorer (`scoreCatch`) and the
 *     real first-of-type check (`isFirstOfType`), so the awarded points are
 *     byte-identical to what the organic upload path would have paid. Nothing
 *     is hardcoded; a later rescore reproduces it.
 *   - Insertion goes through `insertOrGet`, which is idempotent on
 *     (deviceId, catchUuid) — re-running writes nothing. The catchUuids below
 *     are FIXED (not random) precisely so a second run is a provable no-op.
 *   - `caughtAt` is the REAL observed time, not now. That keeps the record
 *     honest and lands each row in a long-closed leaderboard week;
 *     `ensureWeeksDecided` treats row presence as decided and never
 *     re-decides, so no frozen crown can be retroactively rewritten.
 *   - The observer position is copied from the device's nearest-in-time
 *     existing catch (the columns are NOT NULL and the client never sent us
 *     coordinates for these two). The delta is logged so the borrow is visible.
 *   - `validation` records the manual provenance, so these rows are
 *     distinguishable from organic ones forever.
 *   - The device's handle is asserted before ANY write. A wrong device id
 *     would silently gift points to a stranger.
 *
 * Run:  cd backend && npm run build \
 *         && DATABASE_URL=... node dist/tools/backfill-missed-catches.js [--apply]
 *
 * Defaults to a DRY RUN. Pass --apply to write.
 */

import { and, eq, sql } from "drizzle-orm";
import { type Database, closeDb, getDb } from "../db/client.js";
import { catches, devices } from "../db/schema.js";
import { DrizzleCatchStore } from "../identity/store.js";

/** The device being credited, and the handle that must match before we write. */
const DEVICE_ID = "efb375ca-bd56-53af-9437-337feb1ec197";
const EXPECTED_HANDLE = "jtflcntmltstlbms";

interface BackfillTarget {
  /** FIXED uuid — makes a re-run idempotent rather than duplicating. */
  catchUuid: string;
  icao24: string;
  callsign: string | null;
  /** The real observed catch instant, from the client's `catch_performed`. */
  caughtAt: Date;
  /** Operator note stored on the row's validation blob. */
  note: string;
}

const TARGETS: BackfillTarget[] = [
  {
    catchUuid: "bacf0000-0000-4000-8000-0000000000c5",
    icao24: "ae0584",
    callsign: "RCH2067",
    caughtAt: new Date("2026-06-30T23:13:37.164Z"),
    note: "tap-revealed C-5M at 39.0deg off-axis; reveal cone wider than camera frame, capture button could not target the pin",
  },
  {
    catchUuid: "bacf0000-0000-4000-8000-00000000c340",
    icao24: "a3bef1",
    callsign: null,
    caughtAt: new Date("2026-07-18T12:20:48.796Z"),
    note: "catch_performed with no catch_uploaded; upload never left the device",
  },
];

interface PlannedRow {
  target: BackfillTarget;
  typecode: string | null;
  rarity: string | null;
  points: number;
  /** The regime the canonical scorer stamped — carried so apply never re-scores. */
  scoringVersion: number;
  firstOfType: boolean;
  observerLat: number;
  observerLon: number;
  /** Seconds between the backfilled catch and the row we borrowed a position from. */
  positionBorrowedFromDeltaSeconds: number;
  /** True when the row already exists (a re-run) — nothing will be written. */
  alreadyPresent: boolean;
}

/**
 * The observer position for a backfilled catch: copied from whichever of this
 * device's existing catches sits nearest in time. These two catches never
 * reached the server, so no coordinates for them exist anywhere — and
 * observer_lat/observer_lon are NOT NULL. The nearest-in-time row is the most
 * defensible stand-in (same session, same place), and the returned delta is
 * printed so the borrow is never silent.
 */
async function borrowObserverPosition(
  db: Database,
  deviceId: string,
  at: Date,
): Promise<{ lat: number; lon: number; deltaSeconds: number }> {
  const rows = await db
    .select({
      lat: catches.observerLat,
      lon: catches.observerLon,
      caughtAt: catches.caughtAt,
    })
    .from(catches)
    .where(eq(catches.deviceId, deviceId))
    .orderBy(sql`abs(extract(epoch from (${catches.caughtAt} - ${at.toISOString()}::timestamptz)))`)
    .limit(1);

  const nearest = rows[0];
  if (!nearest) {
    throw new Error(
      `device ${deviceId} has no existing catches to borrow an observer position from`,
    );
  }
  return {
    lat: nearest.lat,
    lon: nearest.lon,
    deltaSeconds: Math.round(Math.abs(new Date(nearest.caughtAt).getTime() - at.getTime()) / 1000),
  };
}

/** Plan every target: resolve scoring through the canonical path, no writes. */
async function plan(db: Database, store: DrizzleCatchStore): Promise<PlannedRow[]> {
  const planned: PlannedRow[] = [];

  for (const target of TARGETS) {
    // The real first-of-type check against this device's history — never
    // assumed. If a later rescore or a manual row already gave them this
    // typecode, the bonus correctly does not apply.
    const { typecode } = await store.resolveRarity(target.icao24);
    const firstOfType = await store.isFirstOfType(DEVICE_ID, typecode);

    // The ONE canonical scorer — same call the upload route makes.
    const scored = await store.scoreCatch(target.icao24, { firstOfType });

    const position = await borrowObserverPosition(db, DEVICE_ID, target.caughtAt);

    const existing = await db
      .select({ id: catches.id })
      .from(catches)
      .where(and(eq(catches.deviceId, DEVICE_ID), eq(catches.catchUuid, target.catchUuid)))
      .limit(1);

    planned.push({
      target,
      typecode: scored.typecode,
      rarity: scored.rarity,
      points: scored.points,
      scoringVersion: scored.scoringVersion,
      firstOfType: scored.firstOfType,
      observerLat: position.lat,
      observerLon: position.lon,
      positionBorrowedFromDeltaSeconds: position.deltaSeconds,
      alreadyPresent: existing.length > 0,
    });
  }

  return planned;
}

/** Assert the device is who we think it is. Throws rather than writing blind. */
async function assertDevice(db: Database): Promise<void> {
  const rows = await db
    .select({ handle: devices.handle })
    .from(devices)
    .where(eq(devices.id, DEVICE_ID))
    .limit(1);

  const found = rows[0];
  if (!found) {
    throw new Error(`device ${DEVICE_ID} does not exist — refusing to write`);
  }
  if ((found.handle ?? "").toLowerCase() !== EXPECTED_HANDLE) {
    throw new Error(
      `device ${DEVICE_ID} has handle ${JSON.stringify(found.handle)}, expected ` +
        `${JSON.stringify(EXPECTED_HANDLE)} — refusing to write`,
    );
  }
}

/** Current all-time points for the device, so the report can show the swing. */
async function totalPoints(db: Database): Promise<number> {
  const rows = await db
    .select({ total: sql<number>`coalesce(sum(${catches.points}), 0)` })
    .from(catches)
    .where(eq(catches.deviceId, DEVICE_ID));
  return Number(rows[0]?.total ?? 0);
}

function formatPlan(planned: PlannedRow[], before: number, apply: boolean): string {
  const lines = [
    `backfill-missed-catches [${apply ? "APPLY" : "DRY RUN"}]`,
    `  device: ${DEVICE_ID} (${EXPECTED_HANDLE})`,
    "",
  ];

  let delta = 0;
  for (const p of planned) {
    const skip = p.alreadyPresent ? "  [ALREADY PRESENT — skipping]" : "";
    if (!p.alreadyPresent) delta += p.points;
    lines.push(
      `  ${p.target.icao24}  ${(p.typecode ?? "unknown").padEnd(6)} ` +
        `${(p.rarity ?? "unknown").padEnd(10)} ` +
        `${String(p.points).padStart(4)} pts` +
        `${p.firstOfType ? "  (incl. first-of-type)" : ""}${skip}`,
    );
    lines.push(`      caughtAt:  ${p.target.caughtAt.toISOString()}`);
    lines.push(
      `      observer:  ${p.observerLat.toFixed(4)}, ${p.observerLon.toFixed(4)} ` +
        `(borrowed from a catch ${p.positionBorrowedFromDeltaSeconds}s away)`,
    );
    lines.push(`      why:       ${p.target.note}`);
  }

  lines.push("");
  lines.push(`  points: ${before} → ${before + delta}  (Δ +${delta})`);
  lines.push(apply ? "  applied." : "  DRY RUN — no rows written. Re-run with --apply to commit.");
  return lines.join("\n");
}

export async function backfillMissedCatches(
  db: Database,
  opts: { apply?: boolean } = {},
): Promise<{ planned: PlannedRow[]; written: number }> {
  const store = new DrizzleCatchStore(db);

  await assertDevice(db);
  const before = await totalPoints(db);
  const planned = await plan(db, store);

  console.log(formatPlan(planned, before, opts.apply === true));

  if (opts.apply !== true) return { planned, written: 0 };

  let written = 0;
  for (const p of planned) {
    if (p.alreadyPresent) continue;
    const { duplicate } = await store.insertOrGet({
      catchUuid: p.target.catchUuid,
      deviceId: DEVICE_ID,
      icao24: p.target.icao24,
      callsign: p.target.callsign,
      typecode: p.typecode,
      rarity: p.rarity,
      points: p.points,
      scoringVersion: p.scoringVersion,
      firstOfType: p.firstOfType,
      guessKind: null,
      guessValue: null,
      guessCorrect: false,
      caughtAt: p.target.caughtAt,
      observerLat: p.observerLat,
      observerLon: p.observerLon,
      headingDeg: null,
      elevationDeg: null,
      headingAccuracyDeg: null,
      aircraftLat: null,
      aircraftLon: null,
      aircraftAltitudeMeters: null,
      aircraftPositionTimestamp: null,
      // Provenance: these rows are operator-created, and must stay
      // distinguishable from organic catches under any later audit.
      validation: {
        verdict: "unverifiable",
        reasons: ["manual-backfill", `operator-note: ${p.target.note}`],
      },
    });
    if (!duplicate) written += 1;
  }

  const after = await totalPoints(db);
  console.log(`  wrote ${written} row(s); device total is now ${after}`);
  return { planned, written };
}

async function main(): Promise<void> {
  const apply = process.argv.slice(2).includes("--apply");
  const db = getDb();
  try {
    await backfillMissedCatches(db, { apply });
  } finally {
    await closeDb();
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
