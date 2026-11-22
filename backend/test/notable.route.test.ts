/**
 * Notable planes end to end: the `notable` wire field on /v1/aircraft, the
 * claim-and-confirm upload (`notableClaim`), the +50% bonus frozen on the
 * catch row (and how it stacks), and a rescore that reads the frozen flag.
 * Every directory here is an in-memory fake built from a Map; nothing touches
 * the network or the committed snapshot except the one test that says so.
 */
import { eq } from "drizzle-orm";
import type { FastifyInstance } from "fastify";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import { CURRENT_SCORING_VERSION, NOTABLE_BONUS_FRACTION } from "../src/catches/points.js";
import { rescoreCatches } from "../src/catches/rescore.js";
import type { Database } from "../src/db/client.js";
import { catches, devices, registry, typecodes } from "../src/db/schema.js";
import { DrizzleCatchStore, DrizzleIdentityStore } from "../src/identity/store.js";
import { NotableDirectory, loadNotableSnapshot } from "../src/notable/directory.js";
import { type Notable, makeNotable } from "../src/notable/mapping.js";
import type {
  Bbox,
  NormalizedAircraft,
  PositionProvider,
  ProviderSnapshot,
} from "../src/providers/types.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

const NOW = 1_786_536_000; // 2026-08-12T12:00Z, as in catches.route.test.ts
const VALID_QS = "lamin=37.6&lomin=-122.5&lamax=37.9&lomax=-122.2";

// Fixture airframes. aaaaaa and bababa are rare (base 50); cccccc is unknown
// to the registry (the common floor, base 10).
const JET = "aaaaaa"; // notable, named
const AIRLINER = "bababa"; // not notable
const WARBIRD = "cccccc"; // notable, no name, unresolved type

const JET_NOTABLE: Notable = { kind: "celebrity", label: "Celebrity", name: "Test Person" };
const WARBIRD_NOTABLE: Notable = { kind: "special", label: "Historic and special" };

function directory(): NotableDirectory {
  return new NotableDirectory(
    new Map([
      [JET, makeNotable("celebrity", "Test Person")],
      [WARBIRD, makeNotable("special")],
    ]),
  );
}

function plane(icao24: string): NormalizedAircraft {
  return {
    icao24,
    callsign: "TEST123",
    originCountry: "United States",
    longitude: -122.35,
    latitude: 37.75,
    altitudeMeters: 3000,
    velocityMps: 200,
    trackDeg: 90,
    onGround: false,
    positionTimestamp: 1_700_000_000,
  };
}

class StubProvider implements PositionProvider {
  readonly name = "stub";
  calls = 0;
  constructor(private readonly icaos: string[]) {}
  async aircraftInBbox(_bbox: Bbox): Promise<ProviderSnapshot> {
    this.calls += 1;
    return { fetchedAt: 1_700_000_100, aircraft: this.icaos.map(plane) };
  }
}

describe("GET /v1/aircraft: the notable field", () => {
  let app: FastifyInstance | undefined;
  afterEach(async () => {
    await app?.close();
    app = undefined;
  });

  const get = (a: FastifyInstance) => a.inject({ method: "GET", url: `/v1/aircraft?${VALID_QS}` });
  const byIcao = (body: ProviderSnapshot) => new Map(body.aircraft.map((ac) => [ac.icao24, ac]));

  it("is present on a notable plane and ABSENT (no key) on every other", async () => {
    app = await buildApp({
      provider: new StubProvider([JET, AIRLINER, WARBIRD]),
      notableDirectory: directory(),
    });
    const res = await get(app);
    expect(res.statusCode).toBe(200);
    const planes = byIcao(res.json<ProviderSnapshot>());
    expect(planes.get(JET)?.notable).toEqual(JET_NOTABLE);
    // No name upstream → no `name` key, not a null.
    expect(planes.get(WARBIRD)?.notable).toEqual(WARBIRD_NOTABLE);
    expect(Object.keys(planes.get(WARBIRD)?.notable ?? {})).toEqual(["kind", "label"]);
    expect(planes.get(AIRLINER)).not.toHaveProperty("notable");
    // The raw body carries exactly two notable objects.
    expect(res.body.match(/"notable"/g)).toHaveLength(2);
  });

  it("is present on a tile-cache hit too, not only on the fetch that filled the tile", async () => {
    const provider = new StubProvider([JET, AIRLINER]);
    app = await buildApp({ provider, notableDirectory: directory(), now: () => 1_700_000_100_000 });
    const first = await get(app);
    const second = await get(app);
    expect(provider.calls).toBe(1); // the second answer came from the cache
    expect(byIcao(second.json<ProviderSnapshot>()).get(JET)?.notable).toEqual(JET_NOTABLE);
    expect(second.body).toBe(first.body);
  });

  it("with no directory injected the app serves the committed snapshot", async () => {
    const [hex, expected] = [...loadNotableSnapshot().entries()][0];
    app = await buildApp({ provider: new StubProvider([hex, AIRLINER]) });
    const planes = byIcao((await get(app)).json<ProviderSnapshot>());
    expect(planes.get(hex)?.notable).toEqual(expected);
    expect(planes.get(AIRLINER)).not.toHaveProperty("notable");
  });
});

/**
 * A valid catch body. `caughtAt` shared by two bodies makes them one press.
 * `claim` is what a 1.2.7+ app sends for a catch it showed as notable.
 */
function catchBody(icao24: string, catchUuid: string, caughtAt = NOW, claim = false) {
  return {
    catchUuid,
    icao24,
    callsign: "UAL123",
    caughtAt,
    observer: {
      lat: 37.8,
      lon: -122.27,
      headingDeg: 0,
      elevationDeg: 15.05,
      headingAccuracyDeg: 5,
    },
    aircraft: { lat: 37.9, lon: -122.27, altitudeMeters: 3000, positionTimestamp: caughtAt },
    ...(claim ? { notableClaim: true } : {}),
  };
}
/** The same body with the notable claim a 1.2.7+ app sends. */
const claimed = (icao24: string, catchUuid: string, caughtAt = NOW) =>
  catchBody(icao24, catchUuid, caughtAt, true);

const uuid = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

async function seedAirframes(db: Database): Promise<void> {
  await db.insert(typecodes).values([
    { typecode: "GLF6", manufacturer: "Gulfstream", model: "G650", type: "biz", rarity: "rare" },
    { typecode: "B738", manufacturer: "Boeing", model: "737-800", type: "narrow", rarity: "rare" },
  ]);
  await db.insert(registry).values([
    { icao24: JET, registration: "N1TP", typecode: "GLF6", source: "faa" },
    { icao24: AIRLINER, registration: "N54321", typecode: "B738", source: "faa" },
  ]);
}

describe("catch routes: the notable claim, field and bonus", () => {
  let app: FastifyInstance;
  let db: Database;
  let token: string;

  beforeEach(async () => {
    db = await makeTestDb();
    await seedAirframes(db);
    app = await buildApp({
      identityStore: new DrizzleIdentityStore(db),
      catchStore: new DrizzleCatchStore(db),
      notableDirectory: directory(),
      nowSeconds: () => NOW,
      rateLimitNow: () => 0,
    });
    token = (await app.inject({ method: "POST", url: "/v1/devices" })).json().deviceToken;
  });

  afterEach(async () => {
    await app.close();
  });

  const auth = () => ({ authorization: `Bearer ${token}` });
  const post = (body: unknown) =>
    app.inject({ method: "POST", url: "/v1/catches", headers: auth(), payload: body as object });
  const list = () => app.inject({ method: "GET", url: "/v1/catches", headers: auth() });
  const storedRow = async (catchUuid: string) =>
    (await db.select().from(catches).where(eq(catches.catchUuid, catchUuid)))[0];
  const storedPoints = async (catchUuid: string) => (await storedRow(catchUuid)).points;

  it("POST: a claimed notable catch is paid the +50% and frozen on the row", async () => {
    const res = await post(claimed(JET, uuid(1)));
    expect(res.statusCode).toBe(201);
    expect(res.json()).toEqual({
      catchId: expect.stringMatching(/^[0-9a-f-]{36}$/),
      points: 100, // rare base 50 + first-of-type 25 + notable 25
      rarity: "rare",
      typecode: "GLF6",
      firstOfType: true,
      guessCorrect: false,
      pressSize: 1,
      notable: JET_NOTABLE,
      duplicate: false,
    });
    const row = await storedRow(uuid(1));
    expect(row).toMatchObject({
      points: 100,
      notableKind: "celebrity",
      notableName: "Test Person",
    });
    expect(row.scoringVersion).toBe(CURRENT_SCORING_VERSION);
    expect(CURRENT_SCORING_VERSION).toBe(11);
  });

  it("POST: WITHOUT the claim a notable airframe is an ordinary catch (older app versions)", async () => {
    const res = await post(catchBody(JET, uuid(1)));
    expect(res.statusCode).toBe(201);
    expect(res.json()).toMatchObject({ points: 75, notable: null }); // 50 + first-of-type 25
    // The key is on the wire as a JSON null, not dropped.
    expect(res.body).toContain('"notable":null');
    expect(await storedRow(uuid(1))).toMatchObject({
      points: 75,
      notableKind: null,
      notableName: null,
    });
  });

  it("POST: a claim on an airframe the directory does not list earns nothing", async () => {
    const res = await post(claimed(AIRLINER, uuid(1)));
    expect(res.statusCode).toBe(201);
    expect(res.json()).toMatchObject({ points: 75, notable: null });
    expect((await storedRow(uuid(1))).notableKind).toBeNull();
  });

  it("POST: `notableClaim: false` is no claim; a non-boolean is a 422", async () => {
    const no = await post({ ...catchBody(JET, uuid(1)), notableClaim: false });
    expect(no.json()).toMatchObject({ points: 75, notable: null });
    const bad = await post({ ...catchBody(JET, uuid(2)), notableClaim: "yes" });
    expect(bad.statusCode).toBe(422);
  });

  it("POST: a replay reports the ORIGINAL decision, whatever the retry claims", async () => {
    await post(claimed(JET, uuid(1)));
    const replay = await post(catchBody(JET, uuid(1))); // retry without the claim
    expect(replay.statusCode).toBe(200);
    expect(replay.json()).toMatchObject({ points: 100, notable: JET_NOTABLE, duplicate: true });

    // And the other way round: first stored by an older app, re-sent by a
    // newer one with a claim. The row keeps what it was stored with.
    await post(catchBody(JET, uuid(2), NOW + 60));
    const late = await post(claimed(JET, uuid(2), NOW + 60));
    expect(late.json()).toMatchObject({ points: 50, notable: null, duplicate: true });
    expect(late.body).toContain('"notable":null');
  });

  it("POST: a notable plane that completes a press keeps its bonus through the lift", async () => {
    await post(catchBody(AIRLINER, uuid(1)));
    // 50 + 25 first-of-type + 13 double + 25 notable.
    const jet = await post(claimed(JET, uuid(2)));
    expect(jet.json()).toMatchObject({ points: 113, pressSize: 2, notable: JET_NOTABLE });
    expect(await storedPoints(uuid(2))).toBe(113);
  });

  it("POST: the icao24 is matched case-insensitively", async () => {
    const res = await post(claimed(JET.toUpperCase(), uuid(1)));
    expect(res.json()).toMatchObject({ points: 100, notable: JET_NOTABLE });
  });

  it("the bonus is on the BASE: an unresolved notable airframe earns half the floor", async () => {
    const res = await post(claimed(WARBIRD, uuid(1)));
    // Unknown type → base 10, no first-of-type (no type identity), notable +5.
    expect(res.json()).toMatchObject({
      points: 15,
      rarity: null,
      firstOfType: false,
      notable: WARBIRD_NOTABLE,
    });
    // No name upstream → nothing stored for it, and no `name` key on the wire.
    expect(await storedRow(uuid(1))).toMatchObject({ notableKind: "special", notableName: null });
    expect(Object.keys(res.json().notable)).toEqual(["kind", "label"]);
  });

  it("without first-of-type the notable bonus stands alone", async () => {
    await post(claimed(JET, uuid(1)));
    const second = await post(claimed(JET, uuid(2), NOW + 60));
    expect(second.json()).toMatchObject({ points: 75, firstOfType: false, notable: JET_NOTABLE });
  });

  it("stacks additively with first-of-type, a correct guess and a multi-catch", async () => {
    // One press: the notable jet (with a correct type guess) and an airliner.
    const jet = await post({
      ...claimed(JET, uuid(1)),
      guess: { kind: "type", value: "GLF6" },
    });
    expect(jet.json()).toMatchObject({ points: 113, pressSize: 1, guessCorrect: true });
    // 50 base + 25 first-of-type + 13 type guess (round 12.5) + 25 notable.

    const airliner = await post(catchBody(AIRLINER, uuid(2)));
    // The airliner completes the double: 50 + 25 first-of-type + 13 double.
    expect(airliner.json()).toMatchObject({ points: 88, pressSize: 2, notable: null });

    // The jet's row was lifted through the same scorer and KEPT its frozen
    // notable bonus: 50 + 25 + 13 + 13 (double) + 25 (notable) = 126. Each
    // bonus is a fraction of the base, never of another bonus.
    expect(await storedPoints(uuid(1))).toBe(126);
    expect(await storedPoints(uuid(2))).toBe(88);
    const base = 50;
    expect(126).toBe(base + 25 + 13 + 13 + Math.round(base * NOTABLE_BONUS_FRACTION));
  });

  it("a late guess re-credit keeps the frozen notable bonus", async () => {
    await post(claimed(JET, uuid(1)));
    const { deviceId } = await storedRow(uuid(1));
    const result = await new DrizzleCatchStore(db).recreditGuess(
      deviceId,
      uuid(1),
      { kind: "type", value: "GLF6", localCorrect: true },
      new Date(Date.now() + 86_400_000), // a cutover still in the future
    );
    // 50 + 25 first-of-type + 13 type guess + 25 notable.
    expect(result).toMatchObject({ status: "applied", state: { points: 113 } });
  });

  it("GET: every item carries what its row stores: the object, or null", async () => {
    await post(claimed(JET, uuid(1)));
    await post(catchBody(JET, uuid(2), NOW + 60)); // same airframe, no claim
    await post(claimed(WARBIRD, uuid(3), NOW + 120));

    const res = await list();
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.total).toBe(3);
    expect(body.catches[0]).toEqual({
      catchUuid: uuid(1),
      icao24: JET,
      callsign: "UAL123",
      typecode: "GLF6",
      rarity: "rare",
      points: 100,
      firstOfType: true,
      guessKind: null,
      guessValue: null,
      guessCorrect: false,
      caughtAt: NOW,
      observerLat: 37.8,
      observerLon: -122.27,
      aircraftAltitudeMeters: 3000,
      registration: "N1TP",
      manufacturer: "Gulfstream",
      model: "G650",
      notable: JET_NOTABLE,
    });
    // The unclaimed catch of the SAME airframe is not notable.
    expect(body.catches[1]).toMatchObject({ icao24: JET, points: 50, notable: null });
    expect(body.catches[2]).toMatchObject({
      icao24: WARBIRD,
      points: 15,
      notable: WARBIRD_NOTABLE,
    });
    // Three items, three keys: two objects and one explicit null.
    expect(res.body.match(/"notable":/g)).toHaveLength(3);
    expect(res.body.match(/"notable":null/g)).toHaveLength(1);
  });

  it("the scorer pays the bonus only when told to, never from the airframe", async () => {
    const store = new DrizzleCatchStore(db);
    expect(await store.scoreCatch(JET, { firstOfType: true })).toMatchObject({
      points: 75,
      notable: false,
    });
    expect(await store.scoreCatch(JET, { notable: true })).toMatchObject({
      points: 75, // 50 + notable 25, no first-of-type
      notable: true,
      scoringVersion: 11,
    });
  });
});

describe("catch routes with no notable directory data", () => {
  it("confirm no claim, and still send an explicit `notable: null`", async () => {
    const db = await makeTestDb();
    await seedAirframes(db);
    const app = await buildApp({
      identityStore: new DrizzleIdentityStore(db),
      catchStore: new DrizzleCatchStore(db),
      notableDirectory: new NotableDirectory(),
      nowSeconds: () => NOW,
      rateLimitNow: () => 0,
    });
    try {
      const token = (await app.inject({ method: "POST", url: "/v1/devices" })).json().deviceToken;
      const headers = { authorization: `Bearer ${token}` };
      const posted = await app.inject({
        method: "POST",
        url: "/v1/catches",
        headers,
        payload: claimed(JET, uuid(1)),
      });
      expect(posted.json()).toMatchObject({ points: 75, notable: null });
      const listed = await app.inject({ method: "GET", url: "/v1/catches", headers });
      expect(listed.json().catches[0].notable).toBeNull();
    } finally {
      await app.close();
    }
  });
});

describe("rescore: notable planes (scoring v11, going forward only)", () => {
  let db: Database;
  let deviceId: string;
  let seq = 0;

  async function insertCatch(opts: {
    icao24: string;
    points: number;
    rarity?: string | null;
    typecode?: string | null;
    scoringVersion?: number;
    firstOfType?: boolean;
    pressSize?: number;
    notableKind?: string | null;
  }): Promise<string> {
    seq += 1;
    const rows = await db
      .insert(catches)
      .values({
        catchUuid: uuid(seq),
        deviceId,
        icao24: opts.icao24,
        typecode: opts.typecode === undefined ? "GLF6" : opts.typecode,
        rarity: opts.rarity === undefined ? "rare" : opts.rarity,
        points: opts.points,
        scoringVersion: opts.scoringVersion ?? 10,
        firstOfType: opts.firstOfType ?? false,
        pressSize: opts.pressSize ?? 1,
        notableKind: opts.notableKind ?? null,
        // Staggered: rows sharing an instant would be re-counted as one press.
        caughtAt: new Date(Date.parse("2026-09-01T00:00:00Z") + seq * 1000),
        observerLat: 37.8,
        observerLon: -122.3,
      })
      .returning({ id: catches.id });
    return rows[0].id;
  }
  const rowOf = async (id: string) =>
    (await db.select().from(catches).where(eq(catches.id, id)))[0];

  beforeEach(async () => {
    seq = 0;
    db = await makeTestDb();
    await seedAirframes(db);
    deviceId = (await db.insert(devices).values({ tokenHash: "hash-1" }).returning())[0].id;
  });

  it("past catches of a notable airframe gain nothing: the v10→v11 pass is a pure restamp", async () => {
    const jetPlain = await insertCatch({ icao24: JET, points: 50 });
    const jetFirst = await insertCatch({ icao24: JET, points: 75, firstOfType: true });
    const airliner = await insertCatch({ icao24: AIRLINER, points: 50, typecode: "B738" });

    const dry = await rescoreCatches(db, { dryRun: true });
    expect(dry).toMatchObject({ scanned: 3, changed: 0 });
    expect(dry.pointsAfter).toBe(dry.pointsBefore);

    const applied = await rescoreCatches(db);
    expect(applied).toMatchObject({ scanned: 3, changed: 0, written: 3 });
    expect((await rowOf(jetPlain)).points).toBe(50);
    expect((await rowOf(jetFirst)).points).toBe(75);
    expect((await rowOf(airliner)).points).toBe(50);
    for (const id of [jetPlain, jetFirst, airliner]) {
      expect(await rowOf(id)).toMatchObject({ scoringVersion: 11, notableKind: null });
    }
  });

  it("a row frozen as notable keeps its bonus, next to an unfrozen row of the same airframe", async () => {
    // Both v11 already; a forced full pass must leave both where they are.
    const frozen = await insertCatch({
      icao24: JET,
      points: 75,
      scoringVersion: 11,
      notableKind: "celebrity",
    });
    const plain = await insertCatch({ icao24: JET, points: 50, scoringVersion: 11 });
    const report = await rescoreCatches(db, { all: true });
    expect(report).toMatchObject({ scanned: 2, changed: 0, written: 0 });
    expect((await rowOf(frozen)).points).toBe(75);
    expect((await rowOf(plain)).points).toBe(50);
  });

  it("the bonus floats with the re-derived base, like the other frozen flags", async () => {
    // Stored under a stale tier (common 10 + 5); the airframe now resolves rare.
    const id = await insertCatch({
      icao24: JET,
      points: 15,
      rarity: "common",
      notableKind: "celebrity",
    });
    await rescoreCatches(db);
    expect(await rowOf(id)).toMatchObject({ points: 75, rarity: "rare", notableKind: "celebrity" });
  });
});
