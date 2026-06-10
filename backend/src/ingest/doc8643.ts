/**
 * DOC 8643 typecode import (WP 1.4).
 *
 * Loads the repo's `AircraftTypes.json` — the SAME table the iOS client bundles
 * (2,612 entries: typecode → { make, model, type, rarity }) — and upserts it
 * into the `typecodes` table.
 *
 * The JSON file is the SINGLE SOURCE OF TRUTH; we deliberately do NOT copy it
 * into backend/. The path is supplied as an argument so a deploy can mount the
 * file (see the README for the build-time copy note). `parseDoc8643Json` is a
 * pure function (string in → rows out) so it's unit-tested without a database;
 * `importDoc8643` does the I/O + upsert.
 *
 * Run as a script:  npm run ingest:doc8643 -- <path-to-AircraftTypes.json>
 */

import { readFile } from "node:fs/promises";
import { sql } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { getDb } from "../db/client.js";
import { type TypecodeInsert, typecodes } from "../db/schema.js";

/** The shape of one entry in `AircraftTypes.json` (extra fields like
 *  lengthFt/wingspanFt are present on some rows and ignored here). */
interface RawType {
  make?: string;
  model?: string;
  type?: string;
  rarity?: string;
}

/**
 * Parse the `AircraftTypes.json` text into typecode rows. The JSON is an object
 * keyed by typecode; the key is normalized to uppercase (DOC 8643 designators
 * are uppercase) so the registry's typecode joins reliably. Entries that aren't
 * objects are skipped defensively (lossy-but-resilient, like the iOS decoder).
 */
export function parseDoc8643Json(jsonText: string): TypecodeInsert[] {
  const parsed = JSON.parse(jsonText) as Record<string, unknown>;
  const rows: TypecodeInsert[] = [];
  for (const [rawCode, rawValue] of Object.entries(parsed)) {
    if (typeof rawValue !== "object" || rawValue === null) continue;
    const v = rawValue as RawType;
    const typecode = rawCode.trim().toUpperCase();
    if (typecode === "") continue;
    rows.push({
      typecode,
      manufacturer: v.make ?? null,
      model: v.model ?? null,
      type: v.type ?? null,
      rarity: v.rarity ?? null,
    });
  }
  return rows;
}

/**
 * Upsert typecode rows into the `typecodes` table, in batches (one big multi-row
 * VALUES with ON CONFLICT DO UPDATE so re-runs are idempotent — a changed
 * AircraftTypes.json overwrites the prior row's fields). Returns the count
 * upserted. The db handle is injectable so tests pass a PGlite-backed Drizzle.
 */
export async function upsertTypecodes(db: Database, rows: TypecodeInsert[]): Promise<number> {
  if (rows.length === 0) return 0;
  const BATCH = 500;
  for (let i = 0; i < rows.length; i += BATCH) {
    const chunk = rows.slice(i, i + BATCH);
    await db
      .insert(typecodes)
      .values(chunk)
      .onConflictDoUpdate({
        target: typecodes.typecode,
        set: {
          manufacturer: sqlExcluded("manufacturer"),
          model: sqlExcluded("model"),
          type: sqlExcluded("type"),
          rarity: sqlExcluded("rarity"),
        },
      });
  }
  return rows.length;
}

/** Reference the would-be-inserted value in an ON CONFLICT update (`excluded.col`). */
function sqlExcluded(col: string) {
  return sql.raw(`excluded.${col}`);
}

/** Read the JSON file at `path`, parse, and upsert. Returns the count. */
export async function importDoc8643(db: Database, path: string): Promise<number> {
  const text = await readFile(path, "utf8");
  const rows = parseDoc8643Json(text);
  return upsertTypecodes(db, rows);
}

/** Script entrypoint:  node dist/ingest/doc8643.js <path-to-AircraftTypes.json> */
async function main(): Promise<void> {
  const path = process.argv[2];
  if (!path) {
    console.error(
      "usage: ingest:doc8643 <path-to-AircraftTypes.json>\n" +
        "  e.g. npm run ingest:doc8643 -- ../ios/Tailspot/Tailspot/AircraftTypes.json",
    );
    process.exit(2);
  }
  const db = getDb();
  const n = await importDoc8643(db, path);
  console.log(`doc8643: upserted ${n} typecodes from ${path}`);
}

// Run main() only when invoked directly (not when imported by tests).
if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
