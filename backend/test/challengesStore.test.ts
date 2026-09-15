import { eq } from "drizzle-orm";
import { beforeEach, describe, expect, it } from "vitest";
import { PrivatePointsScorer } from "../src/challenges/scorer.js";
import { type Challenge, DrizzleChallengeStore } from "../src/challenges/store.js";
import type { Database } from "../src/db/client.js";
import { catches, challengeResults, devices } from "../src/db/schema.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

/**
 * Store-level concurrency guards (review of PR #276).
 *
 * PGlite runs ONE session, so two genuinely concurrent transactions cannot be
 * exercised here — a second `transaction()` on the same handle would queue
 * behind the first, which proves nothing about locking. What CAN be pinned is
 * the statement ORDER inside each transaction: the challenge row lock
 * (`select … for update`) must be issued before the capacity count in `join`,
 * and before the standings scoring in finalization, so that under real
 * Postgres the count and the scores are read under the lock. The query log
 * from `makeTestDb({ onQuery })` is the witness.
 */

const T0 = new Date(Date.UTC(2026, 8, 15, 12, 0, 0));
const HOUR_MS = 3_600_000;

describe("DrizzleChallengeStore locking + frozen standings", () => {
  let db: Database;
  let store: DrizzleChallengeStore;
  let log: string[];

  beforeEach(async () => {
    log = [];
    db = await makeTestDb({ onQuery: (q) => log.push(q.toLowerCase()) });
    store = new DrizzleChallengeStore(db, new PrivatePointsScorer(db));
  });

  async function device(handle: string): Promise<string> {
    const rows = await db
      .insert(devices)
      .values({ tokenHash: `hash-${handle}`, handle, createdAt: T0 })
      .returning({ id: devices.id });
    return rows[0].id;
  }

  async function seedCatch(deviceId: string, points: number, caughtAt: Date, createdAt = caughtAt) {
    await db.insert(catches).values({
      catchUuid: crypto.randomUUID(),
      deviceId,
      icao24: "abc123",
      points,
      caughtAt,
      createdAt,
      observerLat: 0,
      observerLon: 0,
      rarity: "rare",
      typecode: "B738",
    });
  }

  function indexOfFirst(pred: (q: string) => boolean, from = 0): number {
    for (let i = from; i < log.length; i++) if (pred(log[i])) return i;
    return -1;
  }

  it("join takes the challenge row lock before counting participants", async () => {
    const noah = await device("noah");
    const eli = await device("eli");
    const c = await store.create(
      { name: "Lock", creatorDeviceId: noah, startsAt: T0, durationPreset: "1h" },
      T0,
    );
    log.length = 0;
    const result = await store.join(c, eli, T0);
    expect(result).toEqual({ ok: true, alreadyIn: false, newDevice: true });

    // Drizzle's BEGIN/COMMIT bypass the query logger, so order is judged from
    // the first logged statement of the join.
    const lock = indexOfFirst((q) => q.includes('from "challenges"') && q.includes("for update"));
    const count = indexOfFirst(
      (q) => q.includes("count(*)") && q.includes('from "challenge_participants"'),
    );
    expect(lock).toBe(0);
    expect(count).toBeGreaterThan(lock);
  });

  it("join refuses the 11th active participant even when the count is read under the lock", async () => {
    const noah = await device("noah");
    const c = await store.create(
      { name: "Full", creatorDeviceId: noah, startsAt: T0, durationPreset: "1h" },
      T0,
    );
    for (let i = 1; i <= 9; i++) {
      expect((await store.join(c, await device(`s${i}`), T0)).ok).toBe(true);
    }
    const late = await device("late");
    expect(await store.join(c, late, T0)).toEqual({ ok: false, reason: "full" });
    // A leaver frees the seat, and the lock path is what re-counts it.
    await store.leave(c, await lookup("s3"), T0);
    expect((await store.join(c, late, T0)).ok).toBe(true);

    async function lookup(handle: string): Promise<string> {
      const rows = await db
        .select({ id: devices.id })
        .from(devices)
        .where(eq(devices.handle, handle));
      return rows[0].id;
    }
  });

  it("join checks the disabled flag before the rejoin branch", async () => {
    const noah = await device("noah");
    const eli = await device("eli");
    const c = await store.create(
      { name: "Rejoin", creatorDeviceId: noah, startsAt: T0, durationPreset: "1h" },
      T0,
    );
    expect((await store.join(c, eli, T0)).ok).toBe(true);
    expect(await store.leave(c, eli, T0)).toBe("left");
    await db.update(devices).set({ disabledAt: T0 }).where(eq(devices.id, eli));
    expect(await store.join(c, eli, T0)).toEqual({ ok: false, reason: "disabled" });
    expect(await store.isActiveParticipant(c.id, eli)).toBe(false);
  });

  it("finalization locks the challenge row, then scores inside the same transaction", async () => {
    const noah = await device("noah");
    const eli = await device("eli");
    const c = await store.create(
      { name: "Freeze", creatorDeviceId: noah, startsAt: T0, durationPreset: "1h" },
      T0,
    );
    await store.join(c, eli, T0);
    await seedCatch(eli, 50, new Date(T0.getTime() + 60_000));
    const end = new Date(T0.getTime() + HOUR_MS);
    log.length = 0;
    const frozen = await store.finalizeIfDue(c, end);
    expect(frozen.finalizedAt).not.toBeNull();
    expect(frozen.outcome).toBe("decided");

    const lock = indexOfFirst((q) => q.includes('from "challenges"') && q.includes("for update"));
    const score = indexOfFirst((q) => q.includes('from "catches"') && q.includes("group by"));
    const freeze = indexOfFirst((q) => q.includes('insert into "challenge_results"'));
    const header = indexOfFirst((q) => q.includes('update "challenges"'));
    expect(lock).toBe(0);
    expect(score).toBeGreaterThan(lock);
    expect(freeze).toBeGreaterThan(score);
    expect(header).toBeGreaterThan(freeze);

    // Idempotent: a second call issues no further freeze.
    log.length = 0;
    const again = await store.finalizeIfDue(frozen, end);
    expect(again.finalizedAt?.getTime()).toBe(frozen.finalizedAt?.getTime());
    expect(indexOfFirst((q) => q.includes('insert into "challenge_results"'))).toBe(-1);
  });

  it("a catch created exactly at endsAt counts (inclusive), one second later does not", async () => {
    const noah = await device("noah");
    const eli = await device("eli");
    const c = await store.create(
      { name: "Edge", creatorDeviceId: noah, startsAt: T0, durationPreset: "1h" },
      T0,
    );
    await store.join(c, eli, T0);
    const end = new Date(T0.getTime() + HOUR_MS);
    const inside = new Date(end.getTime() - 60_000);
    await seedCatch(eli, 50, inside, end); // created_at == ends_at → counts
    await seedCatch(noah, 500, inside, new Date(end.getTime() + 1000)); // +1 s → out
    const { standings, outcome } = await store.standings(c, end);
    expect(outcome).toBe("decided");
    expect(standings.map((s) => [s.handle, s.points, s.placement])).toEqual([
      ["eli", 50, 1],
      ["noah", 0, 2],
    ]);
  });

  it("a device disabled after the freeze vanishes from frozen standings but keeps its row", async () => {
    const noah = await device("noah");
    const eli = await device("eli");
    const zoe = await device("zoe");
    const c = await store.create(
      { name: "Hide", creatorDeviceId: noah, startsAt: T0, durationPreset: "1h" },
      T0,
    );
    await store.join(c, eli, T0);
    await store.join(c, zoe, T0);
    await seedCatch(eli, 100, new Date(T0.getTime() + 60_000));
    await seedCatch(zoe, 10, new Date(T0.getTime() + 60_000));
    const end = new Date(T0.getTime() + HOUR_MS);
    const before = await store.standings(c, end);
    expect(before.standings.map((s) => s.handle)).toEqual(["eli", "zoe", "noah"]);

    await db.update(devices).set({ disabledAt: end }).where(eq(devices.id, eli));
    const after = await store.standings(before.challenge, end);
    expect(after.standings.map((s) => [s.handle, s.placement])).toEqual([
      ["zoe", 2],
      ["noah", 3],
    ]);
    expect(await store.participantCount(c.id)).toBe(2);
    // History is not rewritten: the frozen row is still there.
    const rows = await db.select().from(challengeResults).where(eq(challengeResults.deviceId, eli));
    expect(rows).toHaveLength(1);
    expect(rows[0].placement).toBe(1);
  });

  it("listForDevice caps each bucket at the limit, batches the row fields, and honours scope", async () => {
    const noah = await device("noah");
    const eli = await device("eli");
    const openChallenges: Challenge[] = [];
    for (let i = 0; i < 60; i++) {
      // Stagger the ends so the ordering is observable: i minutes of extra length.
      const c = await store.create(
        { name: `Open ${i}`, creatorDeviceId: eli, startsAt: T0, durationPreset: "7d" },
        new Date(T0.getTime() + i * 60_000),
      );
      await store.join(c, noah, T0);
      openChallenges.push(c);
    }
    for (let i = 0; i < 60; i++) {
      const c = await store.create(
        {
          name: `Old ${i}`,
          creatorDeviceId: eli,
          startsAt: new Date(T0.getTime() - 3 * HOUR_MS),
          durationPreset: "1h",
        },
        new Date(T0.getTime() - 3 * HOUR_MS),
      );
      await store.join(c, noah, new Date(T0.getTime() - 3 * HOUR_MS));
    }
    await seedCatch(noah, 50, new Date(T0.getTime() - 3 * HOUR_MS + 60_000));

    const both = await store.listForDevice(noah, T0, { scope: "both", limit: 50 });
    expect(both.open).toHaveLength(50);
    expect(both.history).toHaveLength(50);
    for (const row of [...both.open, ...both.history]) {
      expect(row.challenge.creatorHandle).toBe("eli");
      expect(row.participantCount).toBe(2);
    }
    expect(both.open.every((r) => r.myResult === null)).toBe(true);
    // Every history row was finalized on the way through and carries my placement.
    expect(both.history.every((r) => r.challenge.finalizedAt !== null)).toBe(true);
    expect(both.history.every((r) => r.myResult?.placement === 1 && r.myResult.points === 50)).toBe(
      true,
    );
    // Open is soonest-end-first: "Open 0" ends first.
    expect(both.open[0].challenge.name).toBe("Open 0");

    const onlyOpen = await store.listForDevice(noah, T0, { scope: "open", limit: 50 });
    expect(onlyOpen.open).toHaveLength(50);
    expect(onlyOpen.history).toEqual([]);
    const onlyHistory = await store.listForDevice(noah, T0, { scope: "history", limit: 5 });
    expect(onlyHistory.open).toEqual([]);
    expect(onlyHistory.history).toHaveLength(5);
  });
});
