/**
 * Drizzle schema for the metadata service (WP 1.4).
 *
 * Two tables, both keyed by a natural primary key (no surrogate ids — the
 * domain keys are stable and we look up by them):
 *
 *   `registry`  — one row per known airframe, keyed by `icao24` (the Mode-S
 *                 24-bit address, lowercase hex). Sourced from the FAA
 *                 Releasable Aircraft Database (US tails only, for now).
 *                 The make/model strings are the FAA's raw ALL-CAPS values —
 *                 we keep them raw and let the merge layer prefer DOC 8643's
 *                 canonical names when the typecode is known there.
 *
 *   `typecodes` — one row per ICAO DOC 8643 type designator (e.g. "B738",
 *                 "A320"), keyed by `typecode`. Sourced from the repo's
 *                 `AircraftTypes.json` (the same table the iOS client bundles).
 *                 Carries the clean manufacturer/model names plus the app's
 *                 derived `type` bucket and `rarity` tier.
 *
 * Why Postgres + Drizzle (vs. the iOS client's bundled binary blobs): the
 * backend is the strategic home for this data (see the FAA-registry script's
 * header comment) — it can refresh daily without shipping a new app build, and
 * a relational store lets the merge query join registry→typecode in one place.
 */

import { sql } from "drizzle-orm";
import { pgTable, text, timestamp } from "drizzle-orm/pg-core";

/**
 * Per-airframe registry rows (FAA Releasable Aircraft DB → one row per US tail).
 * `manufacturerRaw` / `modelRaw` are the FAA's messy ALL-CAPS strings, kept
 * verbatim; the merge layer cleans them via DOC 8643 when the typecode is known.
 */
export const registry = pgTable("registry", {
  /** Lowercase hex Mode-S 24-bit address (the icao24). Natural PK. */
  icao24: text("icao24").primaryKey(),
  /** Tail number / registration (e.g. "N12345"). */
  registration: text("registration"),
  /** Raw FAA manufacturer string (ALL-CAPS, messy). */
  manufacturerRaw: text("manufacturer_raw"),
  /** Raw FAA model string (ALL-CAPS, messy). */
  modelRaw: text("model_raw"),
  /** ICAO type designator if the FAA row carries one (joins to `typecodes`). */
  typecode: text("typecode"),
  /** Provenance tag for the row ("faa"); future seam for other registries. */
  source: text("source").notNull().default("faa"),
  /** Last upsert time — lets a refresh job reason about staleness. */
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().default(sql`now()`),
});

/**
 * ICAO DOC 8643 type designators (loaded from `AircraftTypes.json`).
 * Authoritative for clean manufacturer/model names + the app's type/rarity.
 */
export const typecodes = pgTable("typecodes", {
  /** ICAO type designator, uppercase (e.g. "B738"). Natural PK. */
  typecode: text("typecode").primaryKey(),
  /** Canonical manufacturer name (e.g. "Boeing"). */
  manufacturer: text("manufacturer"),
  /** Canonical model name (e.g. "737-800"). */
  model: text("model"),
  /** App type bucket ("narrow" | "wide" | "regional" | "biz" | "ga" | "mil" | …). */
  type: text("type"),
  /** App rarity tier ("common" | "uncommon" | "rare" | "epic" | "legendary"). */
  rarity: text("rarity"),
});

export type RegistryRow = typeof registry.$inferSelect;
export type RegistryInsert = typeof registry.$inferInsert;
export type TypecodeRow = typeof typecodes.$inferSelect;
export type TypecodeInsert = typeof typecodes.$inferInsert;
