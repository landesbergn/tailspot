/**
 * Batched, idempotent upserts of registry rows. Two variants:
 *
 *  - `upsertRegistry` — FULL OVERWRITE, for the authoritative FAA refresh.
 *  - `upsertRegistryFillMissing` — NON-DESTRUCTIVE enrich, for additive sources
 *    (mictronics global bulk + opportunistic adsb.lol feed) that must not
 *    degrade FAA's richer US data.
 *
 * Split out from `faa.ts` so the parser modules stay free of SQL and the upserts
 * can be unit-tested directly.
 */

import { sql } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { type RegistryInsert, registry } from "../db/schema.js";

/** Reference the would-be-inserted value in an ON CONFLICT update (`excluded.col`). */
function excluded(col: string) {
  return sql.raw(`excluded.${col}`);
}

/** Upsert a batch of registry rows on the icao24 PK. Returns rows.length.
 *
 * FULL OVERWRITE: every field is replaced from the incoming row — correct for
 * the FAA refresh (a fresh download is the source of truth for US tails), but
 * WRONG for additive/foreign sources that carry no manufacturer/model (they'd
 * null out FAA's canonical names). Those use `upsertRegistryFillMissing`. */
export async function upsertRegistry(db: Database, rows: RegistryInsert[]): Promise<number> {
  if (rows.length === 0) return 0;
  await db
    .insert(registry)
    .values(rows)
    .onConflictDoUpdate({
      target: registry.icao24,
      set: {
        registration: excluded("registration"),
        manufacturerRaw: excluded("manufacturer_raw"),
        modelRaw: excluded("model_raw"),
        typecode: excluded("typecode"),
        source: excluded("source"),
        updatedAt: sql`now()`,
      },
    });
  return rows.length;
}

/**
 * Non-destructive enrich-upsert for ADDITIVE sources (the mictronics global
 * bulk import and the opportunistic adsb.lol feed top-up). Inserts brand-new
 * airframes; for one that already exists, fills ONLY the registration / typecode
 * columns that are currently null — via `coalesce(existing, incoming)`. It never
 * overwrites a value already present and never touches `manufacturerRaw` /
 * `modelRaw` / `source`, so the richer FAA data for a US tail survives intact
 * while the foreign-airframe gap (and any registration-only FAA orphan's missing
 * typecode) gets filled. Returns rows.length.
 */
export async function upsertRegistryFillMissing(
  db: Database,
  rows: RegistryInsert[],
): Promise<number> {
  if (rows.length === 0) return 0;
  await db
    .insert(registry)
    .values(rows)
    .onConflictDoUpdate({
      target: registry.icao24,
      set: {
        // coalesce(existing, incoming): keep a present value, fill a null one.
        registration: sql`coalesce(${registry.registration}, ${excluded("registration")})`,
        typecode: sql`coalesce(${registry.typecode}, ${excluded("typecode")})`,
        updatedAt: sql`now()`,
      },
    });
  return rows.length;
}
