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

import { and, desc, eq, gte, inArray, isNotNull, lt, sql } from "drizzle-orm";
import {
  CURRENT_SCORING_VERSION,
  type GuessKind,
  firstOfTypeBonus,
  guessBonus,
  pointsForRarity,
} from "../catches/points.js";
import type { Database } from "../db/client.js";
import {
  alltimeToppers,
  catches,
  devices,
  registry,
  typecodes,
  weeklyChampions,
} from "../db/schema.js";
import { addDaysUtc, utcDateString, weekStartUtc } from "./windows.js";

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
  /**
   * Of the given handles, return the set of LOWERCASED handles already held by
   * some device (compared case-insensitively). Drives onboarding suggestion
   * filtering — the route offers only candidates NOT in this set. Empty input →
   * empty set (no query). A returned name is free at query time only; the claim
   * itself still races the 409 path, so this is freshness, not a reservation.
   */
  takenHandles(handles: string[]): Promise<Set<string>>;
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

  async takenHandles(handles: string[]): Promise<Set<string>> {
    if (handles.length === 0) return new Set();
    const lowers = [...new Set(handles.map((h) => h.toLowerCase()))];
    const rows = await this.db
      .select({ handle: devices.handle })
      .from(devices)
      .where(and(isNotNull(devices.handle), inArray(sql`lower(${devices.handle})`, lowers)));
    return new Set(rows.map((r) => (r.handle as string).toLowerCase()));
  }
}

// ── Catches + leaderboard ────────────────────────────────────────────────────

/** What a catch needs from the metadata layer to score itself. */
export interface RarityResolution {
  typecode: string | null;
  rarity: string | null;
}

/**
 * A server-verified guess VERDICT, handed to the scorer the same way
 * `firstOfType` is: the caller (upload path or re-score) establishes it, the
 * scorer only turns it into points. `correct` is the server's own verification
 * — the wire never carries a client verdict.
 */
export interface GuessVerdict {
  kind: GuessKind;
  correct: boolean;
}

/**
 * A fully-scored catch: resolved airframe identity, its rarity tier, the awarded
 * points, and the scoring regime that produced them. The output of the ONE
 * canonical scorer (`CatchStore.scoreCatch`) — the upload path and the re-score
 * job both consume this, so they can never drift.
 */
export interface ScoredCatch {
  typecode: string | null;
  rarity: string | null;
  points: number;
  scoringVersion: number;
  /**
   * Whether the first-of-type bonus is baked into `points` (echoes the flag
   * handed to the scorer). Persisted on the row and surfaced in the catch
   * response so the iOS client can show the bonus.
   */
  firstOfType: boolean;
  /**
   * Whether a correct-guess bonus is baked into `points` (echoes the verdict
   * handed to the scorer; false when no guess was made). Persisted on the row
   * and surfaced in the catch response.
   */
  guessCorrect: boolean;
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
  /** The scoring regime that produced points/rarity (CURRENT_SCORING_VERSION at upload). */
  scoringVersion: number;
  /** Whether this is the device's first-ever catch of its typecode (drives the +50% bonus). */
  firstOfType: boolean;
  /** Bonus-round guess, frozen at upload: what was asked, what the user said,
   *  and the SERVER's verdict (see the schema column comments). Null/false when
   *  no guess was made. */
  guessKind: GuessKind | null;
  guessValue: string | null;
  guessCorrect: boolean;
  caughtAt: Date;
  observerLat: number;
  observerLon: number;
  headingDeg: number | null;
  elevationDeg: number | null;
  headingAccuracyDeg: number | null;
  /** Aircraft position is nullable — a backfilled pre-WP-1.7 catch sends none. */
  aircraftLat: number | null;
  aircraftLon: number | null;
  aircraftAltitudeMeters: number | null;
  aircraftPositionTimestamp: Date | null;
  validation: unknown;
}

/** What the route echoes back after a catch is stored (or replayed). */
export interface StoredCatchResult {
  catchId: string;
  points: number;
  rarity: string | null;
  typecode: string | null;
  /** Whether the first-of-type bonus was awarded (read back on a replay too). */
  firstOfType: boolean;
  /** Whether a correct-guess bonus was awarded (read back on a replay too). */
  guessCorrect: boolean;
}

/**
 * One catch as GET /v1/catches serves it — the fields a reinstalled client
 * needs to reconstruct a Hangar row. Everything comes from what the server
 * actually stores: the catch row itself plus two cheap joins (registration
 * from `registry` by icao24; clean manufacturer/model names from `typecodes`
 * by the row's frozen typecode). No photo — photos are never uploaded, so
 * they are unrecoverable by design.
 */
export interface RestorableCatch {
  /** The client-generated idempotency uuid — doubles as the RESTORE key
   *  (a re-run skips uuids already present locally). */
  catchUuid: string;
  icao24: string;
  callsign: string | null;
  typecode: string | null;
  rarity: string | null;
  points: number;
  firstOfType: boolean;
  guessKind: string | null;
  guessValue: string | null;
  guessCorrect: boolean;
  /** Unix seconds (matching the POST wire format). */
  caughtAt: number;
  observerLat: number;
  observerLon: number;
  /** Null for nearly every row — the iOS uploader sends `aircraft: null`. */
  aircraftAltitudeMeters: number | null;
  /** Joined from `registry` by icao24 (null for unregistered airframes). */
  registration: string | null;
  /** Joined from `typecodes` by the row's typecode (clean DOC 8643 names). */
  manufacturer: string | null;
  model: string | null;
}

/** One page of a device's catches, for the restore endpoint. */
export interface CatchPage {
  /** TOTAL catches this device holds (not the page size) — lets the client
   *  size the restore prompt ("we found N catches") and page to completion. */
  total: number;
  catches: RestorableCatch[];
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

/**
 * One champion of a closed week, as the leaderboard response serves it.
 * `handle` is null for an anonymous champion (a handle-less device CAN win —
 * it occupies a real rank; the client renders "anonymous spotter").
 * `weekStart` is the won week's Monday as "YYYY-MM-DD" (UTC calendar date).
 */
export interface ChampionEntry {
  handle: string | null;
  points: number;
  weekStart: string;
}

export interface CatchStore {
  /**
   * Resolve typecode + rarity for an icao24 from the metadata tables. Returns
   * { typecode:null, rarity:null } when unknown — the catch is still accepted
   * and scored at the common floor.
   */
  resolveRarity(icao24: string): Promise<RarityResolution>;
  /**
   * The single canonical scorer: resolve an icao24's airframe and award points
   * under the CURRENT scoring regime. Both the catch-upload path AND the
   * re-score job call THIS (never `resolveRarity` + `pointsForRarity` inline),
   * so scoring lives in exactly one place and a re-score reproduces an upload's
   * result identically.
   *
   * `firstOfType` is supplied by the caller — the scorer NEVER queries history
   * itself. When true, the +50%-of-base first-of-type bonus is added on top of
   * the resolved base. Upload computes the flag with `isFirstOfType`; re-score
   * reads the frozen flag off the row.
   *
   * `guess` follows the same pattern: the caller supplies the server-verified
   * VERDICT (upload verifies the wire's guess value against registry/route
   * truth; re-score reads the frozen `guess_kind`/`guess_correct` off the row),
   * and a correct guess adds `guessBonus(base, kind)` on top.
   */
  scoreCatch(
    icao24: string,
    opts?: { firstOfType?: boolean; guess?: GuessVerdict },
  ): Promise<ScoredCatch>;
  /**
   * Whether `deviceId` has NO existing catch of `typecode` — i.e. a new catch of
   * it would be the device's first-of-type. A null typecode (unresolved
   * airframe) is never first-of-type and returns false without a query. This is
   * the un-spoofable server-side determination the upload path feeds into
   * `scoreCatch`; it is NOT used by re-score (which reads the stored flag).
   */
  isFirstOfType(deviceId: string, typecode: string | null): Promise<boolean>;
  /**
   * Insert a catch, or — if THIS DEVICE already ingested `catchUuid` — return
   * the ORIGINAL stored result (idempotent replay). The boolean says which
   * happened. Idempotency is scoped per device: another device submitting the
   * same uuid is a normal, independent insert (security-review fix).
   */
  insertOrGet(c: NewCatch): Promise<{ result: StoredCatchResult; duplicate: boolean }>;
  /**
   * One page of `deviceId`'s catches (oldest first, deterministic order:
   * caughtAt ASC then id ASC), with the airframe joins the client needs to
   * rebuild Hangar rows. `total` is the device's FULL catch count regardless
   * of the page bounds. Powers GET /v1/catches (Hangar restore, issue #58).
   */
  listCatches(deviceId: string, limit: number, offset: number): Promise<CatchPage>;
  /**
   * Top-N devices WITH a handle AND at least one IN-WINDOW catch, by total
   * in-window points. `since` scopes the window: only catches with
   * `caughtAt >= since` count (omit for the all-time board — the pre-windows
   * behavior, unchanged).
   */
  leaderboard(limit: number, since?: Date): Promise<LeaderboardEntry[]>;
  /**
   * The given device's rank + total points — computed over ALL devices
   * (handle-less devices accrue points and occupy ranks invisibly). `since`
   * scopes both my points AND everyone's, so the rank is the in-window rank.
   * Null only for an unknown device id.
   */
  myStanding(deviceId: string, since?: Date): Promise<MyStanding | null>;
  /**
   * DECIDE-ON-READ: make sure every closed week (Monday-00:00-UTC boundaries)
   * since the earliest catch has its champion(s) frozen in `weekly_champions`.
   * Called on every `window=week` request; the fast path (most recent closed
   * week already decided) is a single point-read. When it does decide, ties
   * share the crown (one row per tied device), a zero-catch week gets no rows,
   * and each week's insert is one atomic INSERT…SELECT with ON CONFLICT DO
   * NOTHING — concurrent requests double-deciding is harmless. Also records
   * the current all-time #1 into the topper ledger (a decide is a natural
   * observation point). Returns how many weeks were decided (0 on the fast
   * path; >1 only on the first request after a backfill-worthy gap).
   */
  ensureWeeksDecided(now: Date): Promise<number>;
  /** The champion(s) of the week starting `weekStart` ("YYYY-MM-DD"). Empty if none. */
  champions(weekStart: string): Promise<ChampionEntry[]>;
  /** Total weekly crowns this device has ever won (all weeks, shared crowns count). */
  weeklyWins(deviceId: string): Promise<number>;
  /** Whether this device has EVER held all-time #1 (per the topper ledger). */
  everToppedAllTime(deviceId: string): Promise<boolean>;
  /**
   * Observe the CURRENT all-time #1 and upsert it into the topper ledger
   * (first observation wins; ON CONFLICT DO NOTHING). Called by every
   * `window=all` leaderboard request and by the week-decide pass. No-op while
   * no device has a catch.
   */
  recordAlltimeTopper(now: Date): Promise<void>;
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

  async scoreCatch(
    icao24: string,
    opts: { firstOfType?: boolean; guess?: GuessVerdict } = {},
  ): Promise<ScoredCatch> {
    const { typecode, rarity } = await this.resolveRarity(icao24);
    const firstOfType = opts.firstOfType ?? false;
    const guessCorrect = opts.guess?.correct ?? false;
    const base = pointsForRarity(rarity);
    const points =
      base +
      (firstOfType ? firstOfTypeBonus(base) : 0) +
      (opts.guess?.correct ? guessBonus(base, opts.guess.kind) : 0);
    return {
      typecode,
      rarity,
      points,
      scoringVersion: CURRENT_SCORING_VERSION,
      firstOfType,
      guessCorrect,
    };
  }

  async isFirstOfType(deviceId: string, typecode: string | null): Promise<boolean> {
    // An unresolved airframe has no type identity — it can't be "first of type".
    if (typecode === null) return false;
    const existing = await this.db
      .select({ id: catches.id })
      .from(catches)
      .where(and(eq(catches.deviceId, deviceId), eq(catches.typecode, typecode)))
      .limit(1);
    return existing.length === 0;
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
        scoringVersion: c.scoringVersion,
        firstOfType: c.firstOfType,
        guessKind: c.guessKind,
        guessValue: c.guessValue,
        guessCorrect: c.guessCorrect,
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
        firstOfType: catches.firstOfType,
        guessCorrect: catches.guessCorrect,
      });

    if (inserted.length > 0) {
      const row = inserted[0];
      return {
        result: {
          catchId: row.id,
          points: row.points,
          rarity: row.rarity,
          typecode: row.typecode,
          firstOfType: row.firstOfType,
          guessCorrect: row.guessCorrect,
        },
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
        firstOfType: catches.firstOfType,
        guessCorrect: catches.guessCorrect,
      })
      .from(catches)
      .where(and(eq(catches.deviceId, c.deviceId), eq(catches.catchUuid, c.catchUuid)))
      .limit(1);
    const row = existing[0];
    return {
      result: {
        catchId: row.id,
        points: row.points,
        rarity: row.rarity,
        typecode: row.typecode,
        firstOfType: row.firstOfType,
        guessCorrect: row.guessCorrect,
      },
      duplicate: true,
    };
  }

  async listCatches(deviceId: string, limit: number, offset: number): Promise<CatchPage> {
    // Total first: the client sizes its restore prompt on this, and it must be
    // the device's FULL count even when the page window is smaller.
    const totalRows = await this.db
      .select({ n: sql<number>`count(*)` })
      .from(catches)
      .where(eq(catches.deviceId, deviceId));
    const total = Number(totalRows[0]?.n ?? 0);

    // Page query with the two airframe joins. LEFT joins: a foreign airframe
    // has no registry row, and an unresolved catch has a null typecode — both
    // must still restore (the client's own backfill can heal names later).
    // Ordered oldest-first with the id as a total-order tiebreaker so pages
    // never overlap or skip rows even when timestamps collide.
    const rows = await this.db
      .select({
        catchUuid: catches.catchUuid,
        icao24: catches.icao24,
        callsign: catches.callsign,
        typecode: catches.typecode,
        rarity: catches.rarity,
        points: catches.points,
        firstOfType: catches.firstOfType,
        guessKind: catches.guessKind,
        guessValue: catches.guessValue,
        guessCorrect: catches.guessCorrect,
        caughtAt: catches.caughtAt,
        observerLat: catches.observerLat,
        observerLon: catches.observerLon,
        aircraftAltitudeMeters: catches.aircraftAltitudeMeters,
        registration: registry.registration,
        manufacturer: typecodes.manufacturer,
        model: typecodes.model,
      })
      .from(catches)
      .leftJoin(registry, eq(registry.icao24, catches.icao24))
      .leftJoin(typecodes, eq(typecodes.typecode, catches.typecode))
      .where(eq(catches.deviceId, deviceId))
      .orderBy(catches.caughtAt, catches.id)
      .limit(limit)
      .offset(offset);

    return {
      total,
      catches: rows.map((r) => ({
        catchUuid: r.catchUuid,
        icao24: r.icao24,
        callsign: r.callsign,
        typecode: r.typecode,
        rarity: r.rarity,
        points: r.points,
        firstOfType: r.firstOfType,
        guessKind: r.guessKind,
        guessValue: r.guessValue,
        guessCorrect: r.guessCorrect,
        // Wire format matches POST /v1/catches: unix seconds.
        caughtAt: Math.floor(r.caughtAt.getTime() / 1000),
        observerLat: r.observerLat,
        observerLon: r.observerLon,
        aircraftAltitudeMeters: r.aircraftAltitudeMeters,
        registration: r.registration,
        manufacturer: r.manufacturer,
        model: r.model,
      })),
    };
  }

  async leaderboard(limit: number, since?: Date): Promise<LeaderboardEntry[]> {
    // Aggregate points + catch count per device — only those WITH a handle
    // AND at least one catch.
    // Windowing lives in the JOIN condition, not a WHERE: a LEFT JOIN keeps
    // every device row while only in-window catches contribute to the sums,
    // so the `having count > 0` entry ticket naturally becomes "at least one
    // catch IN THE WINDOW".
    // Ordering: points DESC, then created_at ASC, then device id ASC. The id is
    // the FINAL tiebreaker so the order is TOTAL and DETERMINISTIC even in the
    // (rare) case where two devices share a createdAt timestamp — the same data
    // always yields the same order. Rank is the 1-based row position.
    const joinOn = since
      ? and(eq(catches.deviceId, devices.id), gte(catches.caughtAt, since))
      : eq(catches.deviceId, devices.id);
    const rows = await this.db
      .select({
        handle: devices.handle,
        points: sql<number>`coalesce(sum(${catches.points}), 0)`.as("points"),
        catches: sql<number>`count(${catches.id})`.as("catches"),
        createdAt: devices.createdAt,
      })
      .from(devices)
      .leftJoin(catches, joinOn)
      .where(isNotNull(devices.handle))
      .groupBy(devices.id, devices.handle, devices.createdAt)
      // A claimed handle alone doesn't put you on the public board — onboarding
      // mints handles for drive-by installs (suggestion chips), and those
      // 0-point rows were padding the bottom of the leaderboard. One catch is
      // the entry ticket.
      .having(sql`count(${catches.id}) > 0`)
      .orderBy(desc(sql`points`), devices.createdAt, devices.id)
      .limit(limit);

    return rows.map((r, i) => ({
      rank: i + 1,
      handle: r.handle as string,
      points: Number(r.points),
      catches: Number(r.catches),
    }));
  }

  async myStanding(deviceId: string, since?: Date): Promise<MyStanding | null> {
    // Windowing mirrors `leaderboard`: the filter lives in the LEFT JOIN so a
    // device with no in-window catches still ranks (with 0 points) rather than
    // vanishing.
    const joinOn = since
      ? and(eq(catches.deviceId, devices.id), gte(catches.caughtAt, since))
      : eq(catches.deviceId, devices.id);

    // The device's own total (in-window) points.
    const mine = await this.db
      .select({
        points: sql<number>`coalesce(sum(${catches.points}), 0)`,
        createdAt: devices.createdAt,
      })
      .from(devices)
      .leftJoin(catches, joinOn)
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
      .leftJoin(catches, joinOn)
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

  async ensureWeeksDecided(now: Date): Promise<number> {
    // The most recent CLOSED week is the one before the week containing `now`.
    const lastClosed = addDaysUtc(weekStartUtc(now), -7);
    const lastClosedIso = utcDateString(lastClosed);

    // FAST PATH (the every-request cost): the last closed week already has
    // champion rows → the backfill invariant ("deciding always decides every
    // older undecided week too") guarantees nothing older is pending either.
    // (A zero-catch last week never gets rows, so it re-enters the slow path
    // each request — harmless: the loop below just finds nothing to insert.)
    const already = await this.db
      .select({ weekStart: weeklyChampions.weekStart })
      .from(weeklyChampions)
      .where(eq(weeklyChampions.weekStart, lastClosedIso))
      .limit(1);
    if (already.length > 0) return 0;

    // Backfill bound: the week of the earliest catch ever. No catches → no
    // weeks to decide.
    const minRows = await this.db
      .select({ min: sql<Date | string | null>`min(${catches.caughtAt})` })
      .from(catches);
    const earliest = minRows[0]?.min;
    if (earliest === null || earliest === undefined) return 0;

    // Which weeks are already decided (row presence == decided)?
    const decidedRows = await this.db
      .selectDistinct({ weekStart: weeklyChampions.weekStart })
      .from(weeklyChampions);
    const decided = new Set(decidedRows.map((r) => r.weekStart));

    let decidedCount = 0;
    for (
      let ws = weekStartUtc(new Date(earliest));
      ws.getTime() <= lastClosed.getTime();
      ws = addDaysUtc(ws, 7)
    ) {
      const iso = utcDateString(ws);
      if (decided.has(iso)) continue;
      const we = addDaysUtc(ws, 7);

      // A zero-catch week has NO champion (the one champion-less case — there
      // is otherwise no winner floor). Checked explicitly so `decidedCount`
      // means "weeks that got champions".
      const anyCatch = await this.db
        .select({ id: catches.id })
        .from(catches)
        .where(and(gte(catches.caughtAt, ws), lt(catches.caughtAt, we)))
        .limit(1);
      if (anyCatch.length === 0) continue;

      // Crown the week in ONE atomic INSERT…SELECT: every device whose
      // in-week sum equals the week's max gets a row (ties → shared crowns,
      // points only — no display tie-break here). ON CONFLICT DO NOTHING makes
      // a concurrent double-decide of the same week a no-op, so no explicit
      // transaction/locking is needed.
      //
      // Params are ISO STRINGS with explicit casts, not Date objects: in a
      // raw sql`` execute the postgres.js driver has no column type info and
      // chokes serializing a Date ("must be of type string or Buffer …
      // Received an instance of Date") — a prod-only crash the test harness's
      // driver doesn't reproduce. Drizzle's typed query-builder paths (the
      // gte/lt above, the toppers insert) serialize Dates fine; only raw
      // templates need strings.
      const wsIso = ws.toISOString();
      const weIso = we.toISOString();
      await this.db.execute(sql`
        insert into weekly_champions (week_start, device_id, points, catches, decided_at)
        select ${iso}::date, device_id, sum(points)::int, count(*)::int, ${now.toISOString()}::timestamptz
        from catches
        where caught_at >= ${wsIso}::timestamptz and caught_at < ${weIso}::timestamptz
        group by device_id
        having sum(points) = (
          select max(total) from (
            select sum(points) as total
            from catches
            where caught_at >= ${wsIso}::timestamptz and caught_at < ${weIso}::timestamptz
            group by device_id
          ) as week_totals
        )
        on conflict (week_start, device_id) do nothing
      `);
      decidedCount += 1;
    }

    // A decide is a natural observation point for the all-time board too —
    // record the current #1 so the topper ledger can't miss an era where
    // nobody ever requested `window=all`.
    if (decidedCount > 0) await this.recordAlltimeTopper(now);
    return decidedCount;
  }

  async champions(weekStart: string): Promise<ChampionEntry[]> {
    // All champions share the winning points total, so the order among them is
    // cosmetic — createdAt/id keeps it deterministic (same data, same order).
    const rows = await this.db
      .select({
        handle: devices.handle,
        points: weeklyChampions.points,
        weekStart: weeklyChampions.weekStart,
      })
      .from(weeklyChampions)
      .innerJoin(devices, eq(devices.id, weeklyChampions.deviceId))
      .where(eq(weeklyChampions.weekStart, weekStart))
      .orderBy(devices.createdAt, devices.id);
    return rows.map((r) => ({ handle: r.handle, points: r.points, weekStart: r.weekStart }));
  }

  async weeklyWins(deviceId: string): Promise<number> {
    const rows = await this.db
      .select({ n: sql<number>`count(*)` })
      .from(weeklyChampions)
      .where(eq(weeklyChampions.deviceId, deviceId));
    return Number(rows[0]?.n ?? 0);
  }

  async everToppedAllTime(deviceId: string): Promise<boolean> {
    const rows = await this.db
      .select({ deviceId: alltimeToppers.deviceId })
      .from(alltimeToppers)
      .where(eq(alltimeToppers.deviceId, deviceId))
      .limit(1);
    return rows.length > 0;
  }

  async recordAlltimeTopper(now: Date): Promise<void> {
    // The current all-time #1 under the board's total order (points DESC,
    // createdAt ASC, id ASC), over ALL devices — an anonymous device can top.
    // INNER join = at least one catch; with zero catches anywhere there is no
    // #1 to record.
    const rows = await this.db
      .select({
        deviceId: devices.id,
        points: sql<number>`sum(${catches.points})`.as("points"),
      })
      .from(devices)
      .innerJoin(catches, eq(catches.deviceId, devices.id))
      .groupBy(devices.id, devices.createdAt)
      .orderBy(desc(sql`points`), devices.createdAt, devices.id)
      .limit(1);
    const top = rows[0];
    if (!top) return;
    // First observation wins: the ledger answers "ever topped", so a repeat
    // sighting must not move `firstToppedAt`.
    await this.db
      .insert(alltimeToppers)
      .values({ deviceId: top.deviceId, firstToppedAt: now })
      .onConflictDoNothing();
  }
}
