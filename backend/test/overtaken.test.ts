import { and, eq } from "drizzle-orm";
import { beforeEach, describe, expect, it } from "vitest";
import {
  DrizzleOvertakenStore,
  evaluateOvertaken,
  ordinal,
  overtakenPayload,
} from "../src/challenges/overtaken.js";
import { PrivatePointsScorer } from "../src/challenges/scorer.js";
import { DrizzleChallengeStore } from "../src/challenges/store.js";
import type { Database } from "../src/db/client.js";
import { catches, challengeParticipants, devices } from "../src/db/schema.js";
import type { ApnsEnvironment, ApnsResponse, ApnsTransport } from "../src/push/apns.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

/**
 * "Someone passed you" detection, over PGlite with a fake APNs transport.
 *
 * Everything the feature promises is a NEGATIVE as much as a positive: exactly
 * one push when somebody is actually passed, and none for the uploader, the
 * token-less, the cooled-down, or a challenge that isn't live. Each of those is
 * a test below, because each is a way the feature turns into spam.
 */

const T0 = new Date(Date.UTC(2026, 8, 26, 12, 0, 0));
const HOUR_MS = 3_600_000;
const TOKEN_B = "b".repeat(64);
const TOKEN_C = "c".repeat(64);

interface Sent {
  env: ApnsEnvironment;
  token: string;
  payload: unknown;
}

/** Records every send; `reply` lets a test make APNs answer 410. */
class FakeTransport implements ApnsTransport {
  readonly sent: Sent[] = [];
  reply: (token: string) => ApnsResponse = () => ({ status: 200 });

  async send(env: ApnsEnvironment, token: string, payload: unknown): Promise<ApnsResponse> {
    this.sent.push({ env, token, payload });
    return this.reply(token);
  }
}

const silentLog = { debug: () => {}, info: () => {}, warn: () => {} };

describe("overtaken detection", () => {
  let db: Database;
  let store: DrizzleChallengeStore;
  let overtaken: DrizzleOvertakenStore;
  let transport: FakeTransport;

  beforeEach(async () => {
    db = await makeTestDb();
    store = new DrizzleChallengeStore(db, new PrivatePointsScorer(db));
    overtaken = new DrizzleOvertakenStore(db, new PrivatePointsScorer(db));
    transport = new FakeTransport();
  });

  async function device(
    handle: string,
    push?: { token: string; environment: ApnsEnvironment },
  ): Promise<string> {
    const rows = await db
      .insert(devices)
      .values({
        tokenHash: `hash-${handle}`,
        handle,
        createdAt: T0,
        apnsToken: push?.token ?? null,
        apnsEnvironment: push?.environment ?? null,
        apnsUpdatedAt: push ? T0 : null,
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
      rarity: "rare",
      typecode: "B738",
    });
  }

  function evaluate(deviceId: string, now: Date) {
    return evaluateOvertaken({ store: overtaken, transport, log: silentLog }, deviceId, now);
  }

  async function lastPlacement(challengeId: string, deviceId: string): Promise<number | null> {
    const rows = await db
      .select({ p: challengeParticipants.lastPlacement })
      .from(challengeParticipants)
      .where(
        and(
          eq(challengeParticipants.challengeId, challengeId),
          eq(challengeParticipants.deviceId, deviceId),
        ),
      );
    return rows[0]?.p ?? null;
  }

  /**
   * A live 24h challenge with A (creator) and B, where B leads 100–0.
   * `bPush: null` gives B no push token — explicitly null, not undefined, so
   * the default can't quietly reinstate one.
   */
  async function bLeads(
    bPush: { token: string; environment: ApnsEnvironment } | null = {
      token: TOKEN_B,
      environment: "production",
    },
  ) {
    const a = await device("ada");
    const b = await device("bex", bPush ?? undefined);
    const challenge = await store.create(
      { name: "Weekend Flyoff", creatorDeviceId: a, startsAt: T0, durationPreset: "24h" },
      T0,
    );
    await seedCatch(b, 100, new Date(T0.getTime() + 60_000));
    expect((await store.join(challenge, b, new Date(T0.getTime() + 120_000))).ok).toBe(true);
    return { a, b, challenge };
  }

  it("seeds last_placement at create (the creator is 1st, alone)", async () => {
    const a = await device("ada");
    const c = await store.create(
      { name: "Solo", creatorDeviceId: a, startsAt: T0, durationPreset: "1h" },
      T0,
    );
    expect(await lastPlacement(c.id, a)).toBe(1);
  });

  it("seeds a joiner's last_placement from the board they walk into", async () => {
    const { a, b, challenge } = await bLeads();
    // B joined holding 100 points against A's 0, so B seeds 1st and A keeps 1st
    // from creation (they were alone at the time).
    expect(await lastPlacement(challenge.id, b)).toBe(1);
    expect(await lastPlacement(challenge.id, a)).toBe(1);
  });

  it("A passing B sends exactly one push, with the exact payload and copy", async () => {
    const { a, b, challenge } = await bLeads();
    const t1 = new Date(T0.getTime() + 10 * 60_000);
    await seedCatch(a, 150, t1);

    const summary = await evaluate(a, t1);
    expect(summary).toEqual({ challenges: 1, overtaken: 1, pushes: 1, retryable: 0 });
    expect(transport.sent).toHaveLength(1);
    expect(transport.sent[0].token).toBe(TOKEN_B);
    expect(transport.sent[0].env).toBe("production");
    expect(transport.sent[0].payload).toEqual({
      aps: {
        alert: {
          title: "You got passed",
          body: "@ada just passed you in Weekend Flyoff. You're now 2nd.",
        },
        sound: "default",
        "thread-id": challenge.id,
      },
      challengeId: challenge.id,
      kind: "overtaken",
    });

    // Both placements moved forward, the uploader's included.
    expect(await lastPlacement(challenge.id, a)).toBe(1);
    expect(await lastPlacement(challenge.id, b)).toBe(2);
  });

  it("a second catch inside 30 minutes does not push again", async () => {
    const { a, b, challenge } = await bLeads();
    const t1 = new Date(T0.getTime() + 10 * 60_000);
    await seedCatch(a, 150, t1);
    await evaluate(a, t1);
    expect(transport.sent).toHaveLength(1);

    // B retakes the lead, then A passes them again 20 minutes later.
    const t2 = new Date(t1.getTime() + 5 * 60_000);
    await seedCatch(b, 500, t2);
    await evaluate(b, t2);
    const t3 = new Date(t1.getTime() + 20 * 60_000);
    await seedCatch(a, 500, t3);
    const summary = await evaluate(a, t3);

    expect(summary.overtaken).toBe(1); // detected…
    expect(summary.pushes).toBe(0); // …but inside the cooldown
    expect(transport.sent).toHaveLength(1);
    expect(await lastPlacement(challenge.id, b)).toBe(2);
  });

  it("pushes again once the 30-minute cooldown has expired", async () => {
    const { a, b } = await bLeads();
    const t1 = new Date(T0.getTime() + 10 * 60_000);
    await seedCatch(a, 150, t1);
    await evaluate(a, t1);

    const t2 = new Date(t1.getTime() + 5 * 60_000);
    await seedCatch(b, 500, t2);
    await evaluate(b, t2);
    const t3 = new Date(t1.getTime() + 31 * 60_000);
    await seedCatch(a, 500, t3);
    expect((await evaluate(a, t3)).pushes).toBe(1);
    expect(transport.sent).toHaveLength(2);
  });

  it("never pushes the uploader, even when their own placement is worse than remembered", async () => {
    // A created the challenge alone (seeded 1st) and B joined already holding
    // 100 points, so A is really 2nd while still remembering 1st. A's own
    // small catch doesn't change that — and A must not be told they were
    // passed by themselves.
    const a = await device("ada", { token: TOKEN_C, environment: "sandbox" });
    const b = await device("bex", { token: TOKEN_B, environment: "production" });
    const challenge = await store.create(
      { name: "Weekend Flyoff", creatorDeviceId: a, startsAt: T0, durationPreset: "24h" },
      T0,
    );
    await seedCatch(b, 100, new Date(T0.getTime() + 60_000));
    await store.join(challenge, b, new Date(T0.getTime() + 120_000));
    expect(await lastPlacement(challenge.id, a)).toBe(1);

    const t1 = new Date(T0.getTime() + 10 * 60_000);
    await seedCatch(a, 10, t1);
    const summary = await evaluate(a, t1);
    expect(summary.overtaken).toBe(0);
    expect(transport.sent).toHaveLength(0);
    // The evaluation still corrects A's memory.
    expect(await lastPlacement(challenge.id, a)).toBe(2);
  });

  it("sends nothing when the overtaken participant has no token", async () => {
    const { a } = await bLeads(null);
    const t1 = new Date(T0.getTime() + 10 * 60_000);
    await seedCatch(a, 150, t1);
    const summary = await evaluate(a, t1);
    expect(summary.overtaken).toBe(1);
    expect(summary.pushes).toBe(0);
    expect(transport.sent).toHaveLength(0);
  });

  it("sends nothing for a finished challenge", async () => {
    const { a } = await bLeads();
    const after = new Date(T0.getTime() + 25 * HOUR_MS);
    await seedCatch(a, 150, new Date(T0.getTime() + 10 * 60_000));
    const summary = await evaluate(a, after);
    expect(summary).toEqual({ challenges: 0, overtaken: 0, pushes: 0, retryable: 0 });
    expect(transport.sent).toHaveLength(0);
  });

  it("sends nothing for an upcoming challenge", async () => {
    const a = await device("ada");
    const b = await device("bex", { token: TOKEN_B, environment: "production" });
    const starts = new Date(T0.getTime() + 2 * HOUR_MS);
    const c = await store.create(
      { name: "Later", creatorDeviceId: a, startsAt: starts, durationPreset: "1h" },
      T0,
    );
    await store.join(c, b, T0);
    const summary = await evaluate(a, T0);
    expect(summary.challenges).toBe(0);
    expect(transport.sent).toHaveLength(0);
  });

  it("sends nothing for a cancelled challenge", async () => {
    const a = await device("ada");
    const b = await device("bex", { token: TOKEN_B, environment: "production" });
    const starts = new Date(T0.getTime() + 2 * HOUR_MS);
    const c = await store.create(
      { name: "Called off", creatorDeviceId: a, startsAt: starts, durationPreset: "1h" },
      T0,
    );
    await store.join(c, b, T0);
    expect(await store.cancel(c, T0)).toBe(true);
    const summary = await evaluate(a, new Date(starts.getTime() + 60_000));
    expect(summary.challenges).toBe(0);
    expect(transport.sent).toHaveLength(0);
  });

  it("never reaches a disabled device", async () => {
    const { a, b } = await bLeads();
    await db.update(devices).set({ disabledAt: T0 }).where(eq(devices.id, b));
    const t1 = new Date(T0.getTime() + 10 * 60_000);
    await seedCatch(a, 150, t1);
    const summary = await evaluate(a, t1);
    expect(summary.pushes).toBe(0);
    expect(transport.sent).toHaveLength(0);
  });

  it('says "tied for 2nd" when the new placement is shared', async () => {
    // Three spotters: B and C both on 100, A passes neither until they draw
    // level — then A's catch drops both to a shared 2nd.
    const a = await device("ada");
    const b = await device("bex", { token: TOKEN_B, environment: "production" });
    const c = await device("cyd", { token: TOKEN_C, environment: "sandbox" });
    const challenge = await store.create(
      { name: "Three Up", creatorDeviceId: a, startsAt: T0, durationPreset: "24h" },
      T0,
    );
    await seedCatch(b, 100, new Date(T0.getTime() + 60_000));
    await seedCatch(c, 100, new Date(T0.getTime() + 60_000));
    await store.join(challenge, b, new Date(T0.getTime() + 120_000));
    await store.join(challenge, c, new Date(T0.getTime() + 120_000));
    expect(await lastPlacement(challenge.id, b)).toBe(1);

    const t1 = new Date(T0.getTime() + 10 * 60_000);
    await seedCatch(a, 150, t1);
    const summary = await evaluate(a, t1);
    expect(summary.pushes).toBe(2);
    const bodies = transport.sent.map(
      (s) => (s.payload as { aps: { alert: { body: string } } }).aps.alert.body,
    );
    expect(bodies).toContain("@ada just passed you in Three Up. You're now tied for 2nd.");
    expect(new Set(transport.sent.map((s) => s.token))).toEqual(new Set([TOKEN_B, TOKEN_C]));
    // Each token goes to the environment its own device registered.
    const byToken = new Map(transport.sent.map((s) => [s.token, s.env]));
    expect(byToken.get(TOKEN_B)).toBe("production");
    expect(byToken.get(TOKEN_C)).toBe("sandbox");
  });

  it("a 410 from APNs clears the token and does not mark the cooldown", async () => {
    const { a, b, challenge } = await bLeads();
    transport.reply = () => ({ status: 410, reason: "Unregistered" });
    const t1 = new Date(T0.getTime() + 10 * 60_000);
    await seedCatch(a, 150, t1);
    const summary = await evaluate(a, t1);

    expect(summary.overtaken).toBe(1);
    expect(summary.pushes).toBe(0);
    const row = await db.select().from(devices).where(eq(devices.id, b));
    expect(row[0].apnsToken).toBeNull();
    expect(row[0].apnsEnvironment).toBeNull();
    const parts = await db
      .select({ notified: challengeParticipants.overtakenNotifiedAt })
      .from(challengeParticipants)
      .where(eq(challengeParticipants.deviceId, b));
    expect(parts[0].notified).toBeNull();
    // A dead token is not a blip — there is nobody to retry for, so the
    // baseline advances and we don't re-send on every subsequent catch.
    expect(await lastPlacement(challenge.id, b)).toBe(2);
  });

  it("a 400 BadDeviceToken also clears the token", async () => {
    const { a, b } = await bLeads();
    transport.reply = () => ({ status: 400, reason: "BadDeviceToken" });
    const t1 = new Date(T0.getTime() + 10 * 60_000);
    await seedCatch(a, 150, t1);
    await evaluate(a, t1);
    const row = await db.select().from(devices).where(eq(devices.id, b));
    expect(row[0].apnsToken).toBeNull();
  });

  it("a transient 503 keeps the token AND the baseline, so the next catch retries", async () => {
    const { a, b, challenge } = await bLeads();
    transport.reply = () => ({ status: 503, reason: "ServiceUnavailable" });
    const t1 = new Date(T0.getTime() + 10 * 60_000);
    await seedCatch(a, 150, t1);
    const summary = await evaluate(a, t1);

    expect(summary.pushes).toBe(0);
    expect(summary.retryable).toBe(1);
    const row = await db.select().from(devices).where(eq(devices.id, b));
    expect(row[0].apnsToken).toBe(TOKEN_B);
    // The baseline did NOT advance — B is still remembered as 1st, so the slip
    // is still visible next time. The uploader's own baseline did advance.
    expect(await lastPlacement(challenge.id, b)).toBe(1);
    expect(await lastPlacement(challenge.id, a)).toBe(1);

    // Next catch: APNs is back, and the notification that was nearly lost lands.
    transport.reply = () => ({ status: 200 });
    const t2 = new Date(t1.getTime() + 60_000);
    await seedCatch(a, 10, t2);
    const second = await evaluate(a, t2);
    expect(second.pushes).toBe(1);
    expect(transport.sent).toHaveLength(2);
    expect(await lastPlacement(challenge.id, b)).toBe(2);
  });

  it("a 429 also keeps the baseline; a permanent rejection does not", async () => {
    const { a, b, challenge } = await bLeads();
    transport.reply = () => ({ status: 429, reason: "TooManyRequests" });
    const t1 = new Date(T0.getTime() + 10 * 60_000);
    await seedCatch(a, 150, t1);
    expect((await evaluate(a, t1)).retryable).toBe(1);
    expect(await lastPlacement(challenge.id, b)).toBe(1);

    // A permanent rejection (bad topic — a misconfiguration, not a blip) has
    // nothing to retry: the baseline advances and we stop re-sending.
    transport.reply = () => ({ status: 400, reason: "BadTopic" });
    const t2 = new Date(t1.getTime() + 60_000);
    await seedCatch(a, 10, t2);
    const second = await evaluate(a, t2);
    expect(second.retryable).toBe(0);
    expect(second.pushes).toBe(0);
    expect(await lastPlacement(challenge.id, b)).toBe(2);
  });

  it("a participant who never got a seed (null last_placement) is never notified", async () => {
    const { a, b, challenge } = await bLeads();
    await db
      .update(challengeParticipants)
      .set({ lastPlacement: null })
      .where(eq(challengeParticipants.deviceId, b));
    const t1 = new Date(T0.getTime() + 10 * 60_000);
    await seedCatch(a, 150, t1);
    const summary = await evaluate(a, t1);
    expect(summary.overtaken).toBe(0);
    expect(transport.sent).toHaveLength(0);
    // …but the evaluation still records the placement, so the NEXT pass can.
    expect(await lastPlacement(challenge.id, b)).toBe(2);
  });

  it("a device in no live challenge is a cheap no-op", async () => {
    const a = await device("ada");
    const summary = await evaluate(a, T0);
    expect(summary).toEqual({ challenges: 0, overtaken: 0, pushes: 0, retryable: 0 });
  });

  it("never rejects, even when the store throws", async () => {
    const broken = {
      liveChallengesForDevice: async () => {
        throw new Error("database is on fire");
      },
    } as unknown as DrizzleOvertakenStore;
    const warnings: string[] = [];
    const summary = await evaluateOvertaken(
      {
        store: broken,
        transport,
        log: { debug: () => {}, info: () => {}, warn: (_o, msg) => warnings.push(msg) },
      },
      "some-device",
      T0,
    );
    expect(summary).toEqual({ challenges: 0, overtaken: 0, pushes: 0, retryable: 0 });
    expect(warnings).toContain("overtaken evaluation failed");
  });
});

describe("overtaken copy", () => {
  it("ordinals cover the teens and the twenties", () => {
    expect([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101, 111].map(ordinal)).toEqual([
      "1st",
      "2nd",
      "3rd",
      "4th",
      "11th",
      "12th",
      "13th",
      "21st",
      "22nd",
      "23rd",
      "101st",
      "111th",
    ]);
  });

  it("reads casually, with no exclamation mark", () => {
    const payload = overtakenPayload({
      challengeId: "cid",
      challengeName: "Weekend Flyoff",
      byHandle: "ada",
      placement: 3,
      tied: false,
    });
    const alert = (payload as { aps: { alert: { title: string; body: string } } }).aps.alert;
    expect(alert.title).toBe("You got passed");
    expect(alert.body).toBe("@ada just passed you in Weekend Flyoff. You're now 3rd.");
    expect(JSON.stringify(payload)).not.toContain("!");
  });
});
