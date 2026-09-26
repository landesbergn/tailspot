import type { FastifyInstance } from "fastify";
import { describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import { DrizzleOvertakenStore } from "../src/challenges/overtaken.js";
import { PrivatePointsScorer } from "../src/challenges/scorer.js";
import { DrizzleChallengeStore } from "../src/challenges/store.js";
import type { Database } from "../src/db/client.js";
import { catches, registry, typecodes } from "../src/db/schema.js";
import { DrizzleCatchStore, DrizzleIdentityStore } from "../src/identity/store.js";
import type { ApnsEnvironment, ApnsResponse, ApnsTransport } from "../src/push/apns.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

/**
 * The wiring, end to end: a real `POST /v1/catches` through the app, with the
 * challenge store and a fake APNs transport injected.
 *
 * overtaken.test.ts drives `evaluateOvertaken` directly; this file is the only
 * place that proves the hook is actually CONNECTED — that the route schedules
 * it after the reply, and that `CHALLENGES_ENABLED=false` turns the whole thing
 * off rather than merely hiding the routes.
 */

const T0 = new Date(Date.UTC(2026, 8, 26, 12, 0, 0));
const T0_SEC = Math.floor(T0.getTime() / 1000);
const TOKEN_B = "b".repeat(64);

class FakeTransport implements ApnsTransport {
  readonly sent: { env: ApnsEnvironment; token: string; payload: unknown }[] = [];
  async send(env: ApnsEnvironment, token: string, payload: unknown): Promise<ApnsResponse> {
    this.sent.push({ env, token, payload });
    return { status: 200 };
  }
}

interface Rig {
  app: FastifyInstance;
  db: Database;
  challengeStore: DrizzleChallengeStore;
  transport: FakeTransport;
}

async function setup(enabled: boolean): Promise<Rig> {
  const db = await makeTestDb();
  await db.insert(typecodes).values({
    typecode: "B738",
    manufacturer: "Boeing",
    model: "737-800",
    type: "narrow",
    rarity: "rare",
  });
  // The uploaded catch resolves through the registry, so it scores 75 (rare 50
  // + first-of-type 25) and genuinely passes the rival's 10.
  await db.insert(registry).values({ icao24: "aaaaaa", registration: "N123AA", typecode: "B738" });
  const challengeStore = new DrizzleChallengeStore(db, new PrivatePointsScorer(db));
  const transport = new FakeTransport();
  const app = await buildApp({
    identityStore: new DrizzleIdentityStore(db),
    catchStore: new DrizzleCatchStore(db),
    challengeStore,
    overtakenStore: new DrizzleOvertakenStore(db, challengeStore),
    apnsTransport: transport,
    challengesEnabled: () => enabled,
    nowSeconds: () => T0_SEC + 600,
    rateLimitNow: () => T0.getTime(),
  });
  return { app, db, challengeStore, transport };
}

/** Register through the real routes, claim a handle, optionally register a push token. */
async function newDevice(
  app: FastifyInstance,
  handle: string,
  pushToken?: string,
): Promise<{ deviceId: string; deviceToken: string }> {
  const reg = await app.inject({ method: "POST", url: "/v1/devices" });
  const { deviceId, deviceToken } = reg.json();
  const claim = await app.inject({
    method: "PUT",
    url: "/v1/devices/me/handle",
    headers: { authorization: `Bearer ${deviceToken}` },
    payload: { handle },
  });
  expect(claim.statusCode).toBe(200);
  if (pushToken) {
    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/push-token",
      headers: { authorization: `Bearer ${deviceToken}` },
      payload: { token: pushToken, environment: "production" },
    });
    expect(res.statusCode).toBe(204);
  }
  return { deviceId, deviceToken };
}

function catchBody(catchUuid: string) {
  return {
    catchUuid,
    icao24: "aaaaaa",
    callsign: "UAL123",
    caughtAt: T0_SEC + 600,
    observer: { lat: 37.8, lon: -122.27, headingDeg: 0, elevationDeg: 15, headingAccuracyDeg: 5 },
    aircraft: null,
  };
}

/**
 * Wait for the `setImmediate`-scheduled evaluation to finish. It awaits several
 * PGlite round trips, so draining the microtask queue isn't enough — we poll
 * until the expected number of sends has landed, then drain once more so a
 * "should send nothing" assertion still gets a fair chance to fail.
 */
async function settle(transport: FakeTransport, expected = 0): Promise<void> {
  const deadline = Date.now() + 5_000;
  while (transport.sent.length < expected && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  for (let i = 0; i < 50; i++) await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setTimeout(resolve, 50));
}

/** A small in-window catch for the rival, so they hold the lead at 10–0. */
async function seedRival(db: Database, deviceId: string): Promise<void> {
  await db.insert(catches).values({
    catchUuid: crypto.randomUUID(),
    deviceId,
    icao24: "abc123",
    points: 10,
    caughtAt: new Date(T0.getTime() + 60_000),
    createdAt: new Date(T0.getTime() + 60_000),
    observerLat: 0,
    observerLon: 0,
  });
}

describe("overtaken pushes via POST /v1/catches", () => {
  it("a catch that takes the lead pushes the person who lost it", async () => {
    const { app, db, challengeStore, transport } = await setup(true);
    try {
      const a = await newDevice(app, "ada");
      const b = await newDevice(app, "bex", TOKEN_B);
      const challenge = await challengeStore.create(
        {
          name: "Weekend Flyoff",
          creatorDeviceId: a.deviceId,
          startsAt: T0,
          durationPreset: "24h",
        },
        T0,
      );
      await seedRival(db, b.deviceId);
      expect((await challengeStore.join(challenge, b.deviceId, T0)).ok).toBe(true);

      const res = await app.inject({
        method: "POST",
        url: "/v1/catches",
        headers: { authorization: `Bearer ${a.deviceToken}` },
        payload: catchBody("11111111-1111-4111-8111-111111111111"),
      });
      // The reply does not wait for the push, and does not change shape for it.
      expect(res.statusCode).toBe(201);

      await settle(transport, 1);
      expect(transport.sent).toHaveLength(1);
      expect(transport.sent[0].token).toBe(TOKEN_B);
      const alert = (transport.sent[0].payload as { aps: { alert: { body: string } } }).aps.alert;
      expect(alert.body).toBe("@ada just passed you in Weekend Flyoff. You're now 2nd.");
    } finally {
      await app.close();
    }
  });

  it("sends nothing at all when CHALLENGES_ENABLED is off", async () => {
    const { app, db, challengeStore, transport } = await setup(false);
    try {
      const a = await newDevice(app, "ada");
      const b = await newDevice(app, "bex", TOKEN_B);
      const challenge = await challengeStore.create(
        {
          name: "Weekend Flyoff",
          creatorDeviceId: a.deviceId,
          startsAt: T0,
          durationPreset: "24h",
        },
        T0,
      );
      await seedRival(db, b.deviceId);
      await challengeStore.join(challenge, b.deviceId, T0);

      const res = await app.inject({
        method: "POST",
        url: "/v1/catches",
        headers: { authorization: `Bearer ${a.deviceToken}` },
        payload: catchBody("22222222-2222-4222-8222-222222222222"),
      });
      expect(res.statusCode).toBe(201);
      await settle(transport);
      expect(transport.sent).toHaveLength(0);
    } finally {
      await app.close();
    }
  });

  it("a replayed upload (same catchUuid) does not re-evaluate", async () => {
    const { app, db, challengeStore, transport } = await setup(true);
    try {
      const a = await newDevice(app, "ada");
      const b = await newDevice(app, "bex", TOKEN_B);
      const challenge = await challengeStore.create(
        {
          name: "Weekend Flyoff",
          creatorDeviceId: a.deviceId,
          startsAt: T0,
          durationPreset: "24h",
        },
        T0,
      );
      await seedRival(db, b.deviceId);
      await challengeStore.join(challenge, b.deviceId, T0);

      const body = catchBody("33333333-3333-4333-8333-333333333333");
      const auth = { authorization: `Bearer ${a.deviceToken}` };
      expect(
        (await app.inject({ method: "POST", url: "/v1/catches", headers: auth, payload: body }))
          .statusCode,
      ).toBe(201);
      await settle(transport, 1);
      expect(transport.sent).toHaveLength(1);

      const replay = await app.inject({
        method: "POST",
        url: "/v1/catches",
        headers: auth,
        payload: body,
      });
      expect(replay.statusCode).toBe(200);
      expect(replay.json().duplicate).toBe(true);
      await settle(transport, 1);
      expect(transport.sent).toHaveLength(1);
    } finally {
      await app.close();
    }
  });
});
