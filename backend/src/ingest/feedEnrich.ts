/**
 * Opportunistic registry enrichment from the live position feed.
 *
 * Every genuine upstream fetch the position proxy makes already carries the
 * ICAO typecode + registration for essentially every visible airframe —
 * including the foreign tails the FAA-only registry can't resolve. This module
 * turns each fresh snapshot into non-destructive registry upserts, so the
 * `/v1/metadata` endpoint (and the iOS Hangar backfill that calls it) gradually
 * gains coverage of every airframe that has flown through a user's viewport —
 * complementing the one-shot mictronics bulk import.
 *
 * The write is FIRE-AND-FORGET and non-destructive: it can never affect the
 * `/v1/aircraft` response, and it only fills NULL columns (see
 * `upsertRegistryFillMissing`), so it never degrades FAA or mictronics data.
 *
 * Throttling comes for free from the tile cache: the hook fires only on a
 * cache-miss upstream fetch, which the cache already limits to ~once per TTL
 * per active tile — so the write rate is bounded by active airspace, not by
 * request volume.
 */

import type { Database } from "../db/client.js";
import type { RegistryInsert } from "../db/schema.js";
import type { ProviderSnapshot } from "../providers/types.js";
import { upsertRegistryFillMissing } from "./registryUpsert.js";

/**
 * Extract registry rows from a fresh snapshot: one per aircraft that carries a
 * typecode (a position-only contact adds no registry signal worth a write).
 * Pure — no I/O. `source` is tagged "adsblol".
 */
export function registryRowsFromSnapshot(snapshot: ProviderSnapshot): RegistryInsert[] {
  const rows: RegistryInsert[] = [];
  for (const a of snapshot.aircraft) {
    const typecode = a.typecode?.trim().toUpperCase() || null;
    if (!typecode) continue; // the typecode is the thing the FAA registry lacks
    const registration = a.registration?.trim() || null;
    rows.push({
      icao24: a.icao24,
      registration,
      manufacturerRaw: null,
      modelRaw: null,
      typecode,
      source: "adsblol",
    });
  }
  return rows;
}

/**
 * Build the fire-and-forget enrichment sink wired into the tile cache's
 * `onFreshSnapshot`. Resolves the DB lazily (so the connection is only touched
 * when a snapshot actually arrives) and swallows any DB error through `onError`
 * — best-effort background work must never surface to the request path.
 */
export function makeRegistryEnrichSink(
  getDb: () => Database,
  onError: (err: unknown) => void = () => {},
): (snapshot: ProviderSnapshot) => void {
  return (snapshot) => {
    const rows = registryRowsFromSnapshot(snapshot);
    if (rows.length === 0) return;
    try {
      void upsertRegistryFillMissing(getDb(), rows).catch(onError);
    } catch (err) {
      // getDb() itself can throw (no DATABASE_URL) — swallow, don't break fetch.
      onError(err);
    }
  };
}
