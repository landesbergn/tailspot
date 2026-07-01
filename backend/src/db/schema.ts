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
import {
  boolean,
  doublePrecision,
  index,
  integer,
  jsonb,
  pgTable,
  text,
  timestamp,
  uniqueIndex,
  uuid,
} from "drizzle-orm/pg-core";

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

/**
 * Identity + catches (WP 1.5).
 *
 * `devices` — one row per anonymous install. There is NO username/password and
 *   no PII: a device registers, gets a random 256-bit token shown ONCE, and we
 *   store only the token's SHA-256 hash. A device can optionally claim a public
 *   `handle` (the only thing that ever appears on the leaderboard). The
 *   case-insensitive uniqueness of handles is enforced by a unique index on
 *   `lower(handle)`, NOT on the raw column, so "Maverick" and "maverick" collide
 *   while we still preserve the user's preferred casing for display.
 *
 * `catches` — one row per ingested catch. `catchUuid` is a CLIENT-generated
 *   idempotency key (unique): a retried upload with the same uuid returns the
 *   original result instead of creating a duplicate. Server-resolved facts
 *   (typecode, rarity, points) are stored — never the client's claims (the wire
 *   contract carries none). The anti-cheat `validation` verdict + reasons are
 *   stored as jsonb for later analysis but NEVER gate the response.
 */

/** Anonymous device identities. The token is never stored — only its SHA-256 hash. */
export const devices = pgTable(
  "devices",
  {
    /** Server-generated surrogate id (the public deviceId in the wire contract). */
    id: uuid("id").primaryKey().defaultRandom(),
    /**
     * SHA-256 (hex) of the bearer token. The token itself is shown once at
     * registration and never persisted: a leaked DB row can't be replayed as a
     * credential. Unique so the auth lookup is a single point-read.
     */
    tokenHash: text("token_hash").notNull().unique(),
    /**
     * Optional public handle. Stored with the user's chosen casing; uniqueness
     * is case-insensitive via the `lower(handle)` index below.
     */
    handle: text("handle"),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().default(sql`now()`),
  },
  (t) => ({
    /**
     * Case-insensitive handle uniqueness. A partial index (WHERE handle IS NOT
     * NULL) so the many handle-less devices don't all collide on NULL — and
     * Postgres treats NULLs as distinct anyway, but the predicate documents
     * intent and keeps the index small.
     */
    handleLowerUnique: uniqueIndex("devices_handle_lower_unique")
      .on(sql`lower(${t.handle})`)
      .where(sql`${t.handle} is not null`),
  }),
);

/** Ingested catches. One row per (server-accepted) catch; idempotent on catchUuid. */
export const catches = pgTable(
  "catches",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    /** Client idempotency key — a retried upload with this uuid is a no-op
     *  replay. Uniqueness is PER DEVICE (composite index below), not global:
     *  idempotency is a contract between one client and the server, and a
     *  global key would let one device's submission interact with another's
     *  (replay-leaking the original row, or squatting a uuid another device
     *  legitimately generated). Security-review fix, 2026-06-10. */
    catchUuid: uuid("catch_uuid").notNull(),
    /** Owning device. */
    deviceId: uuid("device_id")
      .notNull()
      .references(() => devices.id),
    /** Lowercase hex Mode-S 24-bit address of the caught aircraft. */
    icao24: text("icao24").notNull(),
    /** Callsign as the client observed it (trimmed); null if none. */
    callsign: text("callsign"),
    /** Server-resolved ICAO type designator (from metadata); null if unresolved. */
    typecode: text("typecode"),
    /** Server-resolved rarity tier; null when the airframe/type is unknown. */
    rarity: text("rarity"),
    /** Server-computed points (rarity→points; default 10 for unknown). NEVER client-supplied. */
    points: integer("points").notNull(),
    /**
     * Which scoring REGIME produced the current `typecode`/`rarity`/`points`.
     * `points` is a re-derivable PROJECTION of (icao24 → reference tables →
     * scoring ladder), not an immutable fact — so we stamp the regime that
     * scored it. Bump `CURRENT_SCORING_VERSION` (catches/points.ts) whenever the
     * scoring LOGIC changes (the rarity→points ladder, the resolution chain, the
     * unknown floor); a `rescore` then finds every row scored under an older
     * regime and re-derives it. Reference-DATA growth (the registry learning a
     * new airframe) does NOT bump the version — those rows are found by their
     * still-null `rarity` instead. Existing rows default to 1 (the launch regime).
     */
    scoringVersion: integer("scoring_version").notNull().default(1),
    /**
     * Whether this was the OWNING DEVICE's first-ever catch of its resolved
     * typecode — earns a +50%-of-base bonus (applied by the ONE canonical
     * scorer). Computed SERVER-SIDE at upload (the ingest path checks "does this
     * device already hold a catch of this typecode?" before inserting), so it's
     * un-spoofable. FROZEN once written: a later re-score re-derives the base
     * (so the bonus floats with a re-tiering) but READS this flag rather than
     * recomputing it from history — deleting an earlier catch must NOT
     * retroactively promote a later one to "first". Existing rows default false:
     * the bonus is going-forward only (no historical first-of-type). A null
     * typecode (unresolved airframe) is never first-of-type — there's no type
     * identity to be first of.
     */
    firstOfType: boolean("first_of_type").notNull().default(false),
    /** When the client says it was caught. */
    caughtAt: timestamp("caught_at", { withTimezone: true }).notNull(),
    observerLat: doublePrecision("observer_lat").notNull(),
    observerLon: doublePrecision("observer_lon").notNull(),
    /** Compass heading the user was facing (deg true), null if unknown. */
    headingDeg: doublePrecision("heading_deg"),
    /** Camera elevation above horizon (deg), null if unknown. */
    elevationDeg: doublePrecision("elevation_deg"),
    /** Reported heading accuracy (deg), widens the anti-cheat tolerance; null if unknown. */
    headingAccuracyDeg: doublePrecision("heading_accuracy_deg"),
    /**
     * Aircraft position is NULLABLE (made so in migration 0003): iOS `Catch`
     * rows recorded before WP 1.7 never stored the aircraft's position, and they
     * must still be backfillable to the leaderboard. A catch with a null aircraft
     * position skips angular validation → verdict "unverifiable" but is accepted
     * and scored normally (rarity comes from the icao24, not the position).
     */
    aircraftLat: doublePrecision("aircraft_lat"),
    aircraftLon: doublePrecision("aircraft_lon"),
    aircraftAltitudeMeters: doublePrecision("aircraft_altitude_meters"),
    /** Upstream position timestamp of the aircraft fix; null if unknown. */
    aircraftPositionTimestamp: timestamp("aircraft_position_timestamp", { withTimezone: true }),
    /** Instrumented anti-cheat verdict + reasons. Stored, never enforced. */
    validation: jsonb("validation"),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().default(sql`now()`),
  },
  (t) => ({
    byDevice: index("catches_device_idx").on(t.deviceId),
    byIcao: index("catches_icao_idx").on(t.icao24),
    /** Idempotency scope: one catchUuid per device (see column comment). */
    deviceCatchUuidUnique: uniqueIndex("catches_device_catch_uuid_unique").on(
      t.deviceId,
      t.catchUuid,
    ),
  }),
);

export type DeviceRow = typeof devices.$inferSelect;
export type DeviceInsert = typeof devices.$inferInsert;
export type CatchRow = typeof catches.$inferSelect;
export type CatchInsert = typeof catches.$inferInsert;
