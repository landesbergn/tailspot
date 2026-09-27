import { and, eq } from "drizzle-orm";
import { beforeEach, describe, expect, it } from "vitest";
import { DrizzleOvertakenStore, evaluateOvertaken } from "../src/challenges/overtaken.js";
import { PrivatePointsScorer } from "../src/challenges/scorer.js";
import { DrizzleChallengeStore } from "../src/challenges/store.js";
import type { Database } from "../src/db/client.js";
import { catches, challengeParticipants, devices } from "../src/db/schema.js";
import type { ApnsEnvironment, ApnsResponse, ApnsTransport } from "../src/push/apns.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

/**
 * The two properties that only show up under a query log or a race:
 *
 *   1. **No JS `Date` ever reaches the driver as a bound parameter.** Drizzle's
 *      column helpers run the timestamp encoder and hand over an ISO string; a
 *      `Date` interpolated into a raw `sql` template does NOT — it gets the noop
 *      encoder, PGlite serialises it happily, and postgres.js crashes on the
 *      bind in production only ("string argument must be of type string…
 *      Received an instance of Date"). Since the whole evaluation is wrapped in
 *      a catch-and-log, that bug would have been invisible: zero pushes ever,
 *      every test green. This asserts on the actual parameter list.
 *
 *   2. **One evaluation at a time per challenge.** PGlite runs a single session,
 *      so two genuinely concurrent transactions can't be exercised (the second
 *      queues behind the first) — which is exactly what lets us assert the
 *      OUTCOME of serialisation. What proves the locking itself is statement
 *      order: `select … for update` on `challenges` must be the first statement
 *      of the evaluation, before anything is read or decided. Same technique as
 *      challengesStore.test.ts.
 */

const T0 = new Date(Date.UTC(2026, 8, 26, 12, 0, 0));
const TOKEN_B = "b".repeat(64);

class FakeTransport implements ApnsTransport {
  readonly sent: { env: ApnsEnvironment; token: string; payload: unknown }[] = [];
  /** How many database transactions were open at the moment of each send. */
  readonly depthAtSend: number[] = [];
  /** Set by the test rig so a send can observe the transaction depth. */
  observeDepth: () => number = () => 0;
  reply: (token: string) => ApnsResponse = () => ({ status: 200 });

  async send(env: ApnsEnvironment, token: string, payload: unknown): Promise<ApnsResponse> {
    this.sent.push({ env, token, payload });
    this.depthAtSend.push(this.observeDepth());
    return this.reply(token);
  }
}

/**
 * Wrap a handle so we can see whether a transaction is open. The overtaken
 * evaluation must NOT be holding one while it talks to Apple: the lock it takes
 * is the challenge row's `FOR UPDATE`, everyone else's `statement_timeout` is
 * 5 s (db/client.ts), and a single slow send would blow through that for every
 * concurrent join, leave, finalize and standings read on that challenge.
 */
function trackTransactions(db: Database): { db: Database; depth: () => number } {
  let depth = 0;
  const proxy = new Proxy(db, {
    get(target, prop, receiver) {
      if (prop === "transaction") {
        return (fn: unknown, config?: unknown) => {
          depth++;
          return (target.transaction as (f: unknown, c?: unknown) => Promise<unknown>)
            .call(target, fn, config)
            .finally(() => {
              depth--;
            });
        };
      }
      return Reflect.get(target, prop, receiver);
    },
  }) as Database;
  return { db: proxy, depth: () => depth };
}

const silentLog = { debug: () => {}, info: () => {}, warn: () => {} };

describe("overtaken evaluation: parameters and serialisation", () => {
  let db: Database;
  let store: DrizzleChallengeStore;
  let overtaken: DrizzleOvertakenStore;
  let transport: FakeTransport;
  let log: { sql: string; params: unknown[] }[];

  beforeEach(async () => {
    log = [];
    db = await makeTestDb({
      onQuery: (sql, params) => log.push({ sql: sql.toLowerCase(), params }),
    });
    store = new DrizzleChallengeStore(db, new PrivatePointsScorer(db));
    overtaken = new DrizzleOvertakenStore(db, new PrivatePointsScorer(db));
    transport = new FakeTransport();
  });

  async function device(handle: string, push?: string): Promise<string> {
    const rows = await db
      .insert(devices)
      .values({
        tokenHash: `hash-${handle}`,
        handle,
        createdAt: T0,
        apnsToken: push ?? null,
        apnsEnvironment: push ? "production" : null,
      })
      .returning({ id: devices.id });
    return rows[0].id;
  }

  async function seedCatch(deviceId: string, points: number, at: Date) {
    await db.insert(catches).values({
      catchUuid: crypto.randomUUID(),
      deviceId,
      icao24: "abc123",
      points,
      caughtAt: at,
      createdAt: at,
      observerLat: 0,
      observerLon: 0,
    });
  }

  /** A live challenge where B leads and A is about to pass them. */
  async function race() {
    const a = await device("ada");
    const b = await device("bex", TOKEN_B);
    const challenge = await store.create(
      { name: "Weekend Flyoff", creatorDeviceId: a, startsAt: T0, durationPreset: "24h" },
      T0,
    );
    await seedCatch(b, 100, new Date(T0.getTime() + 60_000));
    expect((await store.join(challenge, b, new Date(T0.getTime() + 120_000))).ok).toBe(true);
    return { a, b, challenge };
  }

  function lastPlacement(challengeId: string, deviceId: string) {
    return db
      .select({ p: challengeParticipants.lastPlacement })
      .from(challengeParticipants)
      .where(
        and(
          eq(challengeParticipants.challengeId, challengeId),
          eq(challengeParticipants.deviceId, deviceId),
        ),
      )
      .then((rows) => rows[0]?.p ?? null);
  }

  it("binds no JS Date as a query parameter, anywhere in an evaluation", async () => {
    const { a } = await race();
    const t1 = new Date(T0.getTime() + 10 * 60_000);
    await seedCatch(a, 150, t1);
    log.length = 0;

    const summary = await evaluateOvertaken({ store: overtaken, transport, log: silentLog }, a, t1);
    expect(summary.pushes).toBe(1); // the evaluation really ran

    const offenders = log
      .flatMap((entry) => entry.params.map((param) => ({ param, sql: entry.sql })))
      .filter((p) => p.param instanceof Date);
    expect(
      offenders,
      `a JS Date reached the driver: ${offenders.map((o) => o.sql).join(" | ")}`,
    ).toEqual([]);
    // And the time comparisons really were parameterised, not inlined — a
    // Date stringified into the SQL text would also dodge the check above.
    expect(log.some((e) => e.params.some((p) => typeof p === "string" && p.includes("2026")))).toBe(
      true,
    );
  });

  it("takes the challenge row lock before reading anything", async () => {
    const { a } = await race();
    const t1 = new Date(T0.getTime() + 10 * 60_000);
    await seedCatch(a, 150, t1);
    log.length = 0;
    await evaluateOvertaken({ store: overtaken, transport, log: silentLog }, a, t1);

    // First: the list of live challenges (no lock needed, it's just a lookup).
    // Then, per challenge, the FOR UPDATE must precede the roster read and
    // every write — that is what serialises two concurrent evaluations, and
    // what keeps a join from landing mid-evaluation.
    const lock = log.findIndex(
      (e) => e.sql.includes('from "challenges"') && e.sql.includes("for update"),
    );
    const roster = log.findIndex(
      (e) => e.sql.includes('from "challenge_participants"') && e.sql.includes('"devices"'),
    );
    const write = log.findIndex(
      (e) => e.sql.includes("update") && e.sql.includes("last_placement"),
    );
    expect(lock).toBeGreaterThanOrEqual(0);
    expect(roster).toBeGreaterThan(lock);
    expect(write).toBeGreaterThan(roster);
  });

  it("has released the challenge lock before it talks to APNs", async () => {
    const { db: tracked, depth } = trackTransactions(db);
    const lockAware = new DrizzleOvertakenStore(tracked, new PrivatePointsScorer(db));
    transport.observeDepth = depth;

    const { a } = await race();
    const t1 = new Date(T0.getTime() + 10 * 60_000);
    await seedCatch(a, 150, t1);
    log.length = 0;

    const summary = await evaluateOvertaken({ store: lockAware, transport, log: silentLog }, a, t1);
    expect(summary.pushes).toBe(1);
    // Zero open transactions at send time. This is the whole point: nine
    // recipients × a 5 s APNs deadline used to mean a 45 s row lock.
    expect(transport.depthAtSend).toEqual([0]);
    expect(depth()).toBe(0);

    // And the writes really did land BEFORE the send, not after — the phase-1
    // transaction is what stops a simultaneous upload double-notifying.
    const write = log.findIndex((e) => e.sql.includes("last_placement"));
    const stamp = log.findIndex((e) => e.sql.includes("overtaken_notified_at"));
    expect(write).toBeGreaterThanOrEqual(0);
    expect(stamp).toBeGreaterThanOrEqual(0);
  });

  it("restores the baseline and the cooldown when a send fails transiently", async () => {
    const { db: tracked, depth } = trackTransactions(db);
    const revertStore = new DrizzleOvertakenStore(tracked, new PrivatePointsScorer(db));
    transport.observeDepth = depth;
    transport.reply = () => ({ status: 503, reason: "ServiceUnavailable" });

    const { a, b, challenge } = await race();
    const t1 = new Date(T0.getTime() + 10 * 60_000);
    await seedCatch(a, 150, t1);

    const summary = await evaluateOvertaken(
      { store: revertStore, transport, log: silentLog },
      a,
      t1,
    );
    expect(summary).toEqual({ challenges: 1, overtaken: 1, pushes: 0, retryable: 1 });

    // Phase 1 wrote optimistically; phase 3 put both fields back, so the next
    // catch sees the slip again.
    const rows = await db
      .select({
        deviceId: challengeParticipants.deviceId,
        placement: challengeParticipants.lastPlacement,
        notified: challengeParticipants.overtakenNotifiedAt,
      })
      .from(challengeParticipants)
      .where(eq(challengeParticipants.challengeId, challenge.id));
    const bex = rows.find((r) => r.deviceId === b);
    expect(bex?.placement).toBe(1);
    expect(bex?.notified).toBeNull();
    // The uploader was never a recipient, so their advance stands.
    expect(rows.find((r) => r.deviceId === a)?.placement).toBe(1);
    expect(depth()).toBe(0);
  });

  it("two uploads racing on the same challenge push the loser exactly once", async () => {
    const { a, b, challenge } = await race();
    // A and a third spotter both upload at the same instant, both passing B.
    const c = await device("cyd");
    expect((await store.join(challenge, c, new Date(T0.getTime() + 130_000))).ok).toBe(true);
    const t1 = new Date(T0.getTime() + 10 * 60_000);
    await seedCatch(a, 150, t1);
    await seedCatch(c, 140, t1);

    const deps = { store: overtaken, transport, log: silentLog };
    const [first, second] = await Promise.all([
      evaluateOvertaken(deps, a, t1),
      evaluateOvertaken(deps, c, t1),
    ]);

    // Whichever ran first pushed; the other found the baseline already advanced
    // (and the cooldown stamped) and stayed quiet.
    expect(first.pushes + second.pushes).toBe(1);
    expect(transport.sent).toHaveLength(1);
    expect(transport.sent[0].token).toBe(TOKEN_B);
    expect(await lastPlacement(challenge.id, b)).toBe(3);
  });

  it("someone who left mid-challenge is neither notified nor placed", async () => {
    const { a, b, challenge } = await race();
    expect(await store.leave(challenge, b, new Date(T0.getTime() + 5 * 60_000))).toBe("left");

    const t1 = new Date(T0.getTime() + 10 * 60_000);
    await seedCatch(a, 150, t1);
    const summary = await evaluateOvertaken({ store: overtaken, transport, log: silentLog }, a, t1);

    expect(summary.overtaken).toBe(0);
    expect(transport.sent).toHaveLength(0);
    // Their last_placement is left exactly as it was when they walked out.
    expect(await lastPlacement(challenge.id, b)).toBe(1);
    expect(await lastPlacement(challenge.id, a)).toBe(1);
  });
});
