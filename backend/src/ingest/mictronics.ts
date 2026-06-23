/**
 * Global aircraft-registry import (mictronics "standing-data" / basic-ac-db).
 *
 * WHY: the metadata endpoint's only registry source is the FAA database, which
 * covers US (N-) tails ONLY — so `/v1/metadata/{hex}` 404s for every foreign
 * airframe (a Singapore A350, a German A340, …), and those catches show as
 * "Unknown aircraft". This import fills the gap with the community ODbL aircraft
 * database that adsb.lol / readsb / tar1090 themselves bundle: a hex →
 * (registration, ICAO type designator) table covering the whole world. The type
 * designator joins to the DOC 8643 `typecodes` table in the merge layer, so
 * "A359" → "Airbus A350-900" for free — no manufacturer/model strings needed
 * from this source.
 *
 * CONCRETE SOURCE (verified against the live file 2026-06-23):
 *   https://downloads.adsbexchange.com/downloads/basic-ac-db.json.gz
 * — the daily "basic aircraft database" (FAA + community/mictronics lineage),
 * gzip-compressed NDJSON, one aircraft per line. Real records look like:
 *   {"icao":"ac738e","reg":"N901GW","icaotype":null,"year":null,
 *    "manufacturer":null,"model":null,"ownop":"…","mil":false}
 * Only three fields are consumed (`icao`, `reg`, `icaotype`); extras are ignored
 * and `icaotype` is frequently null (a registration-only row — kept for the tail
 * number). If a future artifact renames keys, adjust `recordToRegistry` only;
 * the streaming/batching/upsert path is format-stable.
 *
 * LICENSING: confirm ADSB Exchange's data terms + the required attribution
 * before any App Store distribution (tracked in PLAN.md Track 3 legal). The
 * aircraft-fact data is largely FAA public-domain + community contributions.
 *
 * NON-DESTRUCTIVE: rows upsert via `upsertRegistryFillMissing`, which inserts
 * new airframes and fills only NULL registration/typecode on existing ones —
 * so the richer FAA data for a US tail is never overwritten, and a re-run is
 * idempotent. `source` is "mictronics" on rows this import creates.
 *
 * MEMORY: the file is large (~500k rows), so we STREAM-parse line by line into
 * batched upserts (transparently gunzipping a `.gz` path) and never hold the
 * whole file in memory.
 *
 * Run as a script (the `.gz` is read directly — no manual gunzip):
 *   npm run ingest:mictronics -- basic-ac-db.json.gz [--limit N]
 * Download is a manual / cron step. This task ships only the parser + a
 * fixture-backed test, never the real download.
 */

import { createReadStream } from "node:fs";
import { createInterface } from "node:readline";
import { createGunzip } from "node:zlib";
import type { Database } from "../db/client.js";
import { getDb } from "../db/client.js";
import type { RegistryInsert } from "../db/schema.js";
import { upsertRegistryFillMissing } from "./registryUpsert.js";

/** The subset of a mictronics/basic-ac-db record we consume. */
export interface MictronicsRecord {
  /** ICAO 24-bit Mode-S address, hex. */
  icao?: string;
  /** Registration / tail number. */
  reg?: string | null;
  /** ICAO type designator (e.g. "A359"). */
  icaotype?: string | null;
}

/**
 * Map one parsed record to a registry row, or null to drop it. icao24 is
 * normalized to lowercase hex and validated; a record with neither a
 * registration nor a typecode carries nothing the live feed doesn't already
 * give us, so it's dropped. `source` is tagged "mictronics".
 */
export function recordToRegistry(rec: MictronicsRecord): RegistryInsert | null {
  const icao24 = (rec.icao ?? "").trim().toLowerCase();
  if (!/^[0-9a-f]{6}$/.test(icao24)) return null;
  const registration = (rec.reg ?? "").trim() || null;
  const typecode = (rec.icaotype ?? "").trim().toUpperCase() || null;
  if (!registration && !typecode) return null;
  return {
    icao24,
    registration,
    manufacturerRaw: null,
    modelRaw: null,
    typecode,
    source: "mictronics",
  };
}

/** Parse one NDJSON line into a registry row, or null (blank/garbled/no-signal). */
export function parseLine(line: string): RegistryInsert | null {
  const trimmed = line.trim();
  if (trimmed === "") return null;
  let rec: MictronicsRecord;
  try {
    rec = JSON.parse(trimmed) as MictronicsRecord;
  } catch {
    return null; // a malformed line is skipped, never fatal (lossy-per-line)
  }
  return recordToRegistry(rec);
}

/**
 * Parse a whole NDJSON blob into registry rows. Pure (string in → rows out) for
 * unit testing; the streaming import below uses `parseLine` line-by-line for the
 * large download.
 */
export function parseMictronics(text: string, limit?: number): RegistryInsert[] {
  const rows: RegistryInsert[] = [];
  for (const line of text.split(/\r?\n/)) {
    if (limit !== undefined && rows.length >= limit) break;
    const row = parseLine(line);
    if (row) rows.push(row);
  }
  return rows;
}

/**
 * Stream the NDJSON file (transparently gunzipping a `.gz` path) line-by-line
 * into batched non-destructive upserts. Returns the count of rows upserted.
 */
export async function importMictronics(
  db: Database,
  path: string,
  opts: { limit?: number } = {},
): Promise<number> {
  const raw = createReadStream(path);
  const input = path.endsWith(".gz") ? raw.pipe(createGunzip()) : raw;
  const rl = createInterface({ input, crlfDelay: Number.POSITIVE_INFINITY });

  let batch: RegistryInsert[] = [];
  let total = 0;
  const BATCH = 1000;

  for await (const line of rl) {
    if (opts.limit !== undefined && total + batch.length >= opts.limit) break;
    const row = parseLine(line);
    if (!row) continue;
    batch.push(row);
    if (batch.length >= BATCH) {
      total += await upsertRegistryFillMissing(db, batch);
      batch = [];
    }
  }
  if (batch.length > 0) total += await upsertRegistryFillMissing(db, batch);
  return total;
}

/** Script entrypoint:  node dist/ingest/mictronics.js <basic-ac-db.json[.gz]> [--limit N] */
async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const path = args.find((a) => !a.startsWith("--"));
  if (!path) {
    console.error(
      "usage: ingest:mictronics <basic-ac-db.json[.gz]> [--limit N]\n" +
        "  NDJSON of { icao, reg, icaotype } records (download is a manual/cron step).",
    );
    process.exit(2);
  }
  const limitIx = args.indexOf("--limit");
  const limit = limitIx >= 0 ? Number(args[limitIx + 1]) : undefined;
  const db = getDb();
  const n = await importMictronics(db, path, { limit });
  console.log(`mictronics: upserted ${n} registry rows from ${path}`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
