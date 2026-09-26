import { sql } from "drizzle-orm";
import { beforeEach, describe, expect, it } from "vitest";
import { PrivatePointsScorer } from "../src/challenges/scorer.js";
import { DrizzleChallengeStore } from "../src/challenges/store.js";
import type { Database } from "../src/db/client.js";
import { challengeParticipants, devices } from "../src/db/schema.js";
import { DrizzleIdentityStore } from "../src/identity/store.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

/**
 * Two things about migration 0011 and the code that reads it.
 *
 * 1. **Seeding the push baseline is best-effort.** It happens in its own
 *    statement after the create/join transaction has committed, so a failure
 *    costs one participant their first overtake notification (a null baseline
 *    never notifies) and nothing else. It must never cost somebody their join.
 *
 * 2. **The migration is still mandatory before the deploy**, and for a bigger
 *    reason than push: Drizzle names EVERY column of a table in its INSERT
 *    statements, whatever the values object contains. So the moment
 *    `apns_token` and `last_placement` exist in `src/db/schema.ts`, an
 *    un-migrated database fails device registration, challenge creation and
 *    joining — not just notifications. The second test pins that, so the
 *    warning in backend/README.md can never quietly become untrue.
 */

const T0 = new Date(Date.UTC(2026, 8, 26, 12, 0, 0));

/**
 * A handle whose TOP-LEVEL `update(challenge_participants)` always fails —
 * which is exactly and only the two baseline seeds. Everything else, including
 * every update issued inside a transaction (`leave`, `markNotified`), goes
 * through untouched, because a transaction handle doesn't come through this
 * proxy.
 */
function seedsAlwaysFail(db: Database): Database {
  return new Proxy(db, {
    get(target, prop, receiver) {
      if (prop === "update") {
        return (table: unknown) => {
          if (table === challengeParticipants) {
            return {
              set: () => ({
                where: () => Promise.reject(new Error('column "last_placement" does not exist')),
              }),
            };
          }
          return (target.update as (t: unknown) => unknown)(table);
        };
      }
      return Reflect.get(target, prop, receiver);
    },
  }) as Database;
}

describe("push-baseline seeding is best-effort", () => {
  let db: Database;
  let warnings: string[];
  let store: DrizzleChallengeStore;

  beforeEach(async () => {
    db = await makeTestDb();
    warnings = [];
    store = new DrizzleChallengeStore(seedsAlwaysFail(db), new PrivatePointsScorer(db), {
      warn: (_obj, msg) => warnings.push(msg),
    });
  });

  async function device(handle: string): Promise<string> {
    const rows = await db
      .insert(devices)
      .values({ tokenHash: `hash-${handle}`, handle, createdAt: T0 })
      .returning({ id: devices.id });
    return rows[0].id;
  }

  it("a failing seed costs the notification, never the create or the join", async () => {
    const a = await device("ada");
    const b = await device("bex");
    const challenge = await store.create(
      { name: "Seedless", creatorDeviceId: a, startsAt: T0, durationPreset: "24h" },
      T0,
    );
    expect(challenge.id).toBeTypeOf("string");
    expect(await store.join(challenge, b, T0)).toEqual({
      ok: true,
      alreadyIn: false,
      newDevice: true,
    });

    // Both participants really are in: the writes committed, only the seeds failed.
    expect((await store.participants(challenge.id)).map((p) => p.handle).sort()).toEqual([
      "ada",
      "bex",
    ]);
    // The baseline is null, which is "never evaluated" — silence, not a wrong push.
    const rows = await db
      .select({ p: challengeParticipants.lastPlacement })
      .from(challengeParticipants);
    expect(rows.map((r) => r.p)).toEqual([null, null]);
    // And it said so, once per failed seed, rather than failing silently.
    expect(warnings).toHaveLength(2);
    expect(warnings.every((w) => w.includes("last_placement"))).toBe(true);
  });

  it("standings, leaving and cancelling are unaffected by a failed seed", async () => {
    const a = await device("ada");
    const b = await device("bex");
    const challenge = await store.create(
      { name: "Seedless", creatorDeviceId: a, startsAt: T0, durationPreset: "24h" },
      T0,
    );
    await store.join(challenge, b, T0);
    const { standings } = await store.standings(challenge, new Date(T0.getTime() + 60_000));
    expect(standings).toHaveLength(2);
    expect(await store.leave(challenge, b, new Date(T0.getTime() + 60_000))).toBe("left");
  });
});

describe("migration 0011 is mandatory before the deploy", () => {
  it("an un-migrated database fails device registration and challenge joins outright", async () => {
    const db = await makeTestDb();
    // Roll the database back to the pre-0011 shape.
    await db.execute(sql`alter table "devices" drop column "apns_token"`);
    await db.execute(sql`alter table "challenge_participants" drop column "last_placement"`);

    // Drizzle lists every schema column in an INSERT — including ones the
    // values object never mentions — so these fail on the missing column, and
    // no amount of best-effort seeding can rescue them. This is why
    // backend/README.md says apply 0011 FIRST, and why the honest description
    // of an un-migrated deploy is "registration and challenges break", not
    // "pushes don't work".
    const identity = new DrizzleIdentityStore(db);
    await expect(identity.createDevice("hash-nope")).rejects.toThrow(/apns_token/);

    const store = new DrizzleChallengeStore(db, new PrivatePointsScorer(db));
    await expect(
      store.create(
        { name: "Nope", creatorDeviceId: crypto.randomUUID(), startsAt: T0, durationPreset: "1h" },
        T0,
      ),
    ).rejects.toThrow();
  });
});
