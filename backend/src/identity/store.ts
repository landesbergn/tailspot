/**
 * The identity store seam (WP 1.5).
 *
 * Mirrors the metadata store pattern: the routes depend only on these
 * interfaces, never on Drizzle directly, so storage is swappable and tests can
 * inject a PGlite-backed implementation. Production injects the Drizzle stores
 * built over the Postgres connection.
 *
 * Two stores live here because identity and catches are distinct concerns that
 * happen to share a database: `IdentityStore` owns devices + handles;
 * `CatchStore` owns catch ingestion + the leaderboard aggregate + the
 * typecode→rarity resolution catches need.
 */

import { and, desc, eq, isNotNull, sql } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { catches, devices, registry, typecodes } from "../db/schema.js";

// ── Identity (devices + handles) ─────────────────────────────────────────────

/** A device as the auth/handle layer needs it. */
export interface DeviceIdentity {
  id: string;
  handle: string | null;
}

/** The outcome of a handle-claim attempt. */
export type HandleClaimResult = { ok: true; handle: string } | { ok: false; reason: "taken" };

export interface IdentityStore {
  /** Insert a new device with the given token hash; returns its generated id. */
  createDevice(tokenHash: string): Promise<{ id: string }>;
  /** Find a device by its token hash (the auth point-lookup). Null if none. */
  findByTokenHash(tokenHash: string): Promise<DeviceIdentity | null>;
  /**
   * Claim/replace `deviceId`'s handle. Case-insensitive uniqueness: returns
   * { ok:false, reason:"taken" } if another device holds the lowercased handle.
   * Re-claiming the same handle the device already holds succeeds (idempotent).
   */
  claimHandle(deviceId: string, handle: string): Promise<HandleClaimResult>;
}

export class DrizzleIdentityStore implements IdentityStore {
  constructor(private readonly db: Database) {}

  async createDevice(tokenHash: string): Promise<{ id: string }> {
    const rows = await this.db.insert(devices).values({ tokenHash }).returning({ id: devices.id });
    return { id: rows[0].id };
  }

  async findByTokenHash(tokenHash: string): Promise<DeviceIdentity | null> {
    const rows = await this.db
      .select({ id: devices.id, handle: devices.handle })
      .from(devices)
      .where(eq(devices.tokenHash, tokenHash))
      .limit(1);
    return rows[0] ?? null;
  }

  async claimHandle(deviceId: string, handle: string): Promise<HandleClaimResult> {
    const lower = handle.toLowerCase();
    // Is the lowercased handle held by a DIFFERENT device? (Re-claiming your own
    // handle, even with different casing, is allowed.)
    const conflict = await this.db
      .select({ id: devices.id })
      .from(devices)
      .where(and(eq(sql`lower(${devices.handle})`, lower), sql`${devices.id} <> ${deviceId}`))
      .limit(1);
    if (conflict.length > 0) {
      return { ok: false, reason: "taken" };
    }
    await this.db.update(devices).set({ handle }).where(eq(devices.id, deviceId));
    return { ok: true, handle };
  }
}

// ── Catches + leaderboard ────────────────────────────────────────────────────

/** What a catch needs from the metadata layer to score itself. */
export interface RarityResolution {
  typecode: string | null;
  rarity: string | null;
}

/** The fields the route hands the store to persist a new catch. */
export interface NewCatch {
  catchUuid: string;
  deviceId: string;
  icao24: string;
  callsign: string | null;
  typecode: string | null;
  rarity: string | null;
  points: number;
  caughtAt: Date;
  observerLat: number;
  observerLon: number;
  headingDeg: number | null;
  elevationDeg: number | null;
  headingAccuracyDeg: number | null;
  aircraftLat: number;
  aircraftLon: number;
  aircraftAltitudeMeters: number;
  aircraftPositionTimestamp: Date | null;
  validation: unknown;
}

/** What the route echoes back after a catch is stored (or replayed). */
export interface StoredCatchResult {
  catchId: string;
  points: number;
  rarity: string | null;
  typecode: string | null;
}

/** One leaderboard row. */
export interface LeaderboardEntry {
  rank: number;
  handle: string;
  points: number;
  catches: number;
}

/** The caller's own standing (present whenever a valid token is sent). */
export interface MyStanding {
  rank: number;
  points: number;
}

export interface CatchStore {
  /**
   * Resolve typecode + rarity for an icao24 from the metadata tables. Returns
   * { typecode:null, rarity:null } when unknown — the catch is still accepted
   * and scored at the common floor.
   */
  resolveRarity(icao24: string): Promise<RarityResolution>;
  /**
   * Insert a catch, or — if THIS DEVICE already ingested `catchUuid` — return
   * the ORIGINAL stored result (idempotent replay). The boolean says which
   * happened. Idempotency is scoped per device: another device submitting the
   * same uuid is a normal, independent insert (security-review fix).
   */
  insertOrGet(c: NewCatch): Promise<{ result: StoredCatchResult; duplicate: boolean }>;
  /** Top-N devices WITH a handle, by total points. */
  leaderboard(limit: number): Promise<LeaderboardEntry[]>;
  /**
   * The given device's rank + total points — computed over ALL devices
   * (handle-less devices accrue points and occupy ranks invisibly). Null if the
   * device has no catches (it has 0 points and no meaningful rank yet).
   */
  myStanding(deviceId: string): Promise<MyStanding | null>;
}

export class DrizzleCatchStore implements CatchStore {
  constructor(private readonly db: Database) {}

  async resolveRarity(icao24: string): Promise<RarityResolution> {
    // Same chain as the metadata store: registry → typecode → DOC 8643 rarity.
    const regRows = await this.db
      .select({ typecode: registry.typecode })
      .from(registry)
      .where(eq(registry.icao24, icao24))
      .limit(1);
    const typecode = regRows[0]?.typecode ?? null;
    if (!typecode) return { typecode: null, rarity: null };

    const tcRows = await this.db
      .select({ rarity: typecodes.rarity })
      .from(typecodes)
      .where(eq(typecodes.typecode, typecode))
      .limit(1);
    return { typecode, rarity: tcRows[0]?.rarity ?? null };
  }

  async insertOrGet(c: NewCatch): Promise<{ result: StoredCatchResult; duplicate: boolean }> {
    // Idempotency: the catch_uuid unique constraint makes ON CONFLICT DO NOTHING
    // a no-op for a replay; an empty `returning` then signals "already existed",
    // and we read the original row back. This is a single round-trip on the
    // happy path and one extra SELECT only on a replay.
    const inserted = await this.db
      .insert(catches)
      .values({
        catchUuid: c.catchUuid,
        deviceId: c.deviceId,
        icao24: c.icao24,
        callsign: c.callsign,
        typecode: c.typecode,
        rarity: c.rarity,
        points: c.points,
        caughtAt: c.caughtAt,
        observerLat: c.observerLat,
        observerLon: c.observerLon,
        headingDeg: c.headingDeg,
        elevationDeg: c.elevationDeg,
        headingAccuracyDeg: c.headingAccuracyDeg,
        aircraftLat: c.aircraftLat,
        aircraftLon: c.aircraftLon,
        aircraftAltitudeMeters: c.aircraftAltitudeMeters,
        aircraftPositionTimestamp: c.aircraftPositionTimestamp,
        validation: c.validation,
      })
      .onConflictDoNothing({ target: [catches.deviceId, catches.catchUuid] })
      .returning({
        id: catches.id,
        points: catches.points,
        rarity: catches.rarity,
        typecode: catches.typecode,
      });

    if (inserted.length > 0) {
      const row = inserted[0];
      return {
        result: { catchId: row.id, points: row.points, rarity: row.rarity, typecode: row.typecode },
        duplicate: false,
      };
    }

    // Replay: return the ORIGINAL stored result (its server-resolved points,
    // rarity, typecode — not anything from this retry).
    const existing = await this.db
      .select({
        id: catches.id,
        points: catches.points,
        rarity: catches.rarity,
        typecode: catches.typecode,
      })
      .from(catches)
      .where(and(eq(catches.deviceId, c.deviceId), eq(catches.catchUuid, c.catchUuid)))
      .limit(1);
    const row = existing[0];
    return {
      result: { catchId: row.id, points: row.points, rarity: row.rarity, typecode: row.typecode },
      duplicate: true,
    };
  }

  async leaderboard(limit: number): Promise<LeaderboardEntry[]> {
    // Aggregate points + catch count per device, only those WITH a handle.
    // Ordering: points DESC, then created_at ASC, then device id ASC. The id is
    // the FINAL tiebreaker so the order is TOTAL and DETERMINISTIC even in the
    // (rare) case where two devices share a createdAt timestamp — the same data
    // always yields the same order. Rank is the 1-based row position.
    const rows = await this.db
      .select({
        handle: devices.handle,
        points: sql<number>`coalesce(sum(${catches.points}), 0)`.as("points"),
        catches: sql<number>`count(${catches.id})`.as("catches"),
        createdAt: devices.createdAt,
      })
      .from(devices)
      .leftJoin(catches, eq(catches.deviceId, devices.id))
      .where(isNotNull(devices.handle))
      .groupBy(devices.id, devices.handle, devices.createdAt)
      .orderBy(desc(sql`points`), devices.createdAt, devices.id)
      .limit(limit);

    return rows.map((r, i) => ({
      rank: i + 1,
      handle: r.handle as string,
      points: Number(r.points),
      catches: Number(r.catches),
    }));
  }

  async myStanding(deviceId: string): Promise<MyStanding | null> {
    // The device's own total points.
    const mine = await this.db
      .select({
        points: sql<number>`coalesce(sum(${catches.points}), 0)`,
        createdAt: devices.createdAt,
      })
      .from(devices)
      .leftJoin(catches, eq(catches.deviceId, devices.id))
      .where(eq(devices.id, deviceId))
      .groupBy(devices.id, devices.createdAt)
      .limit(1);
    if (mine.length === 0) return null; // unknown device
    const myPoints = Number(mine[0].points);
    const myCreatedAt = mine[0].createdAt;

    // Rank = 1 + the number of devices that strictly outrank me under the SAME
    // total order the leaderboard uses (points DESC, createdAt ASC, id ASC). A
    // device outranks me if it has more points; OR equal points and an earlier
    // createdAt; OR equal points and the same createdAt but a smaller id (the id
    // tiebreaker keeps the order total even on identical timestamps). This counts
    // ALL devices (handle-less included), so the rank reflects true standing —
    // the leaderboard ENTRIES hide handle-less devices, but they still occupy ranks.
    const ranked = await this.db
      .select({
        deviceId: devices.id,
        points: sql<number>`coalesce(sum(${catches.points}), 0)`.as("p"),
        createdAt: devices.createdAt,
      })
      .from(devices)
      .leftJoin(catches, eq(catches.deviceId, devices.id))
      .groupBy(devices.id, devices.createdAt);

    let ahead = 0;
    for (const r of ranked) {
      if (r.deviceId === deviceId) continue;
      const p = Number(r.points);
      const outranks =
        p > myPoints ||
        (p === myPoints && r.createdAt < myCreatedAt) ||
        (p === myPoints && +r.createdAt === +myCreatedAt && r.deviceId < deviceId);
      if (outranks) ahead += 1;
    }
    return { rank: ahead + 1, points: myPoints };
  }
}
