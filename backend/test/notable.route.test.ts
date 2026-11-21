/**
 * Notable planes end to end: the `notable` wire field on /v1/aircraft and the
 * catch routes, the +50% bonus in the canonical scorer (and how it stacks),
 * and the v10→v11 rescore. Every directory here is an in-memory fake built
 * from a Map; nothing touches the network or the committed snapshot except
 * the one test that says so.
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

  it("follows a directory refresh on the next serve of a cached tile, both ways", async () => {
    const provider = new StubProvider([JET, AIRLINER]);
    const dir = directory();
    app = await buildApp({ provider, notableDirectory: dir, now: () => 1_700_000_100_000 });
    expect(byIcao((await get(app)).json<ProviderSnapshot>()).get(JET)?.notable).toEqual(
      JET_NOTABLE,
    );

    // Upstream drops the jet and adds the airliner. The other two rows keep
    // one celebrity and one special, as this directory's snapshot has (each
    // kind must hold half its snapshot count).
    const csv = [
      "$ICAO,$Registration,$Operator,$Type,$ICAO Type,#CMPG,$Tag 1,$#Tag 2,$#Tag 3,Category,$#Link",
      `${AIRLINER},N1,Some Club,B738,B738,Civ,t,t,t,Football,x`,
      "dddddd,N2,Private,B738,B738,Civ,t,t,t,Historic,x",
      "eeeeee,N3,Someone Else,GLF6,GLF6,Civ,t,t,t,Don't you know who I am?,x",
    ].join("\n");
    expect((await dir.refresh(async () => csv)).status).toBe("updated");

    const after = await get(app);
    expect(provider.calls).toBe(1); // still the cached tile
    const planes = byIcao(after.json<ProviderSnapshot>());
    expect(planes.get(JET)).not.toHaveProperty("notable");
    expect(planes.get(AIRLINER)?.notable).toEqual({
      kind: "team",
      label: "Team plane",
      name: "Some Club",
    });
  });

  it("with no directory injected the app serves the committed snapshot", async () => {
    const [hex, expected] = [...loadNotableSnapshot().entries()][0];
    app = await buildApp({ provider: new StubProvider([hex, AIRLINER]) });
    const planes = byIcao((await get(app)).json<ProviderSnapshot>());
    expect(planes.get(hex)?.notable).toEqual(expected);
    expect(planes.get(AIRLINER)).not.toHaveProperty("notable");
  });
});

/** A valid catch body. `caughtAt` shared by two bodies makes them one press. */
function catchBody(icao24: string, catchUuid: string, caughtAt = NOW) {
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
  };
}

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

describe("catch routes: the notable field and bonus", () => {
  let app: FastifyInstance;
  let db: Database;
  let token: string;

  beforeEach(async () => {
    db = await makeTestDb();
    await seedAirframes(db);
    // One directory for the store (scoring) and the routes (the field), as in
    // production.
    const dir = directory();
    app = await buildApp({
      identityStore: new DrizzleIdentityStore(db),
      catchStore: new DrizzleCatchStore(db, dir),
      notableDirectory: dir,
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
  const storedPoints = async (catchUuid: string) =>
    (await db.select().from(catches).where(eq(catches.catchUuid, catchUuid)))[0].points;

  it("POST: a notable catch carries `notable` and points that include the +50%", async () => {
    const res = await post(catchBody(JET, uuid(1)));
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
    expect(await storedPoints(uuid(1))).toBe(100);
    const row = (
      await db
        .select()
        .from(catches)
        .where(eq(catches.catchUuid, uuid(1)))
    )[0];
    expect(row.scoringVersion).toBe(CURRENT_SCORING_VERSION);
    expect(CURRENT_SCORING_VERSION).toBe(11);
  });

  it("POST: an ordinary catch has an explicit `notable: null` and no bonus", async () => {
    const res = await post(catchBody(AIRLINER, uuid(1)));
    expect(res.statusCode).toBe(201);
    expect(res.json()).toEqual({
      catchId: expect.stringMatching(/^[0-9a-f-]{36}$/),
      points: 75, // rare base 50 + first-of-type 25
      rarity: "rare",
      typecode: "B738",
      firstOfType: true,
      guessCorrect: false,
      pressSize: 1,
      notable: null,
      duplicate: false,
    });
    // The key is on the wire as a JSON null, not dropped.
    expect(res.body).toContain('"notable":null');
    expect(Object.keys(res.json())).toContain("notable");
  });

  it("POST: a replay of an ordinary catch also carries `notable: null`", async () => {
    await post(catchBody(AIRLINER, uuid(1)));
    const replay = await post(catchBody(AIRLINER, uuid(1)));
    expect(replay.statusCode).toBe(200);
    expect(replay.json()).toMatchObject({ points: 75, notable: null, duplicate: true });
    expect(replay.body).toContain('"notable":null');
  });

  it("POST: a notable plane that completes a press reports the lifted points WITH the object", async () => {
    await post(catchBody(AIRLINER, uuid(1)));
    // The jet arrives second, so its returned points come from the press
    // re-score, not from the upload's first scoring: 50 + 25 first-of-type +
    // 13 double + 25 notable.
    const jet = await post(catchBody(JET, uuid(2)));
    expect(jet.json()).toMatchObject({ points: 113, pressSize: 2, notable: JET_NOTABLE });
    expect(await storedPoints(uuid(2))).toBe(113);
  });

  it("POST: a replay returns the stored points and the notable object again", async () => {
    await post(catchBody(JET, uuid(1)));
    const replay = await post(catchBody(JET, uuid(1)));
    expect(replay.statusCode).toBe(200);
    expect(replay.json()).toMatchObject({ points: 100, notable: JET_NOTABLE, duplicate: true });
  });

  it("POST: the icao24 is matched case-insensitively", async () => {
    const res = await post(catchBody(JET.toUpperCase(), uuid(1)));
    expect(res.json()).toMatchObject({ points: 100, notable: JET_NOTABLE });
  });

  it("the bonus is on the BASE: an unresolved notable airframe earns half the floor", async () => {
    const res = await post(catchBody(WARBIRD, uuid(1)));
    // Unknown type → base 10, no first-of-type (no type identity), notable +5.
    expect(res.json()).toMatchObject({
      points: 15,
      rarity: null,
      firstOfType: false,
      notable: WARBIRD_NOTABLE,
    });
  });

  it("without first-of-type the notable bonus stands alone", async () => {
    await post(catchBody(JET, uuid(1)));
    const second = await post(catchBody(JET, uuid(2), NOW + 60));
    expect(second.json()).toMatchObject({ points: 75, firstOfType: false, notable: JET_NOTABLE });
  });

  it("stacks additively with first-of-type, a correct guess and a multi-catch", async () => {
    // One press: the notable jet (with a correct type guess) and an airliner.
    const jet = await post({
      ...catchBody(JET, uuid(1)),
      guess: { kind: "type", value: "GLF6" },
    });
    expect(jet.json()).toMatchObject({ points: 113, pressSize: 1, guessCorrect: true });
    // 50 base + 25 first-of-type + 13 type guess (round 12.5) + 25 notable.

    const airliner = await post(catchBody(AIRLINER, uuid(2)));
    // The airliner completes the double: 50 + 25 first-of-type + 13 double.
    expect(airliner.json()).toMatchObject({ points: 88, pressSize: 2, notable: null });

    // The jet's row was lifted through the same scorer and KEPT its notable
    // bonus: 50 + 25 + 13 + 13 (double) + 25 (notable) = 126. Each bonus is a
    // fraction of the base, never of another bonus.
    expect(await storedPoints(uuid(1))).toBe(126);
    expect(await storedPoints(uuid(2))).toBe(88);
    const base = 50;
    expect(126).toBe(base + 25 + 13 + 13 + Math.round(base * NOTABLE_BONUS_FRACTION));
  });

  it("GET: every item carries `notable`: the object when notable, null otherwise", async () => {
    await post(catchBody(JET, uuid(1)));
    await post(catchBody(AIRLINER, uuid(2), NOW + 60));
    await post(catchBody(WARBIRD, uuid(3), NOW + 120));

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
    expect(body.catches[1]).toEqual({
      catchUuid: uuid(2),
      icao24: AIRLINER,
      callsign: "UAL123",
      typecode: "B738",
      rarity: "rare",
      points: 75,
      firstOfType: true,
      guessKind: null,
      guessValue: null,
      guessCorrect: false,
      caughtAt: NOW + 60,
      observerLat: 37.8,
      observerLon: -122.27,
      aircraftAltitudeMeters: 3000,
      registration: "N54321",
      manufacturer: "Boeing",
      model: "737-800",
      notable: null,
    });
    expect(body.catches[2]).toMatchObject({
      icao24: WARBIRD,
      points: 15,
      notable: WARBIRD_NOTABLE,
    });
    // Three items, three keys: two objects and one explicit null.
    expect(res.body.match(/"notable":/g)).toHaveLength(3);
    expect(res.body.match(/"notable":null/g)).toHaveLength(1);
    for (const item of body.catches) expect(Object.keys(item)).toContain("notable");
  });

  it("a store built without a directory awards no bonus (the pre-v11 behaviour)", async () => {
    const plain = new DrizzleCatchStore(db);
    expect(await plain.scoreCatch(JET, { firstOfType: true })).toMatchObject({
      points: 75,
      notable: null,
    });
    // The scorer hands back the directory's object with the points it priced.
    expect(await new DrizzleCatchStore(db, directory()).scoreCatch(JET)).toMatchObject({
      points: 75, // 50 + notable 25, no first-of-type
      notable: JET_NOTABLE,
      scoringVersion: 11,
    });
    expect(await new DrizzleCatchStore(db, directory()).scoreCatch(AIRLINER)).toMatchObject({
      points: 50,
      notable: null,
    });
  });
});

describe("POST /v1/catches: points and `notable` come from ONE decision", () => {
  // The two directories are deliberately made to disagree, which production
  // never does (one instance feeds both). It is the only way to see which one
  // a response reads.
  async function appWith(
    storeDirectory: NotableDirectory | undefined,
    routeDirectory: NotableDirectory,
  ) {
    const db = await makeTestDb();
    await seedAirframes(db);
    const app = await buildApp({
      identityStore: new DrizzleIdentityStore(db),
      catchStore: new DrizzleCatchStore(db, storeDirectory),
      notableDirectory: routeDirectory,
      nowSeconds: () => NOW,
      rateLimitNow: () => 0,
    });
    const token = (await app.inject({ method: "POST", url: "/v1/devices" })).json().deviceToken;
    const post = (body: unknown) =>
      app.inject({
        method: "POST",
        url: "/v1/catches",
        headers: { authorization: `Bearer ${token}` },
        payload: body as object,
      });
    return { app, post };
  }

  it("fresh insert: the scorer said notable, so the response does, whatever the route's directory says", async () => {
    const { app, post } = await appWith(directory(), new NotableDirectory());
    try {
      const fresh = await post(catchBody(JET, uuid(1)));
      expect(fresh.statusCode).toBe(201);
      // Bonus paid AND flagged: both from the scored result.
      expect(fresh.json()).toMatchObject({ points: 100, notable: JET_NOTABLE });

      // A replay scores nothing: stored points, and the directory's answer
      // now. The route's directory here is EMPTY, which cannot vouch for
      // "not notable", so the key is omitted.
      const replay = await post(catchBody(JET, uuid(1)));
      expect(replay.json()).toMatchObject({ points: 100, duplicate: true });
      expect(replay.body).not.toContain('"notable"');
    } finally {
      await app.close();
    }
  });

  it("fresh insert: the scorer said not notable, so no bonus and `notable: null`", async () => {
    const { app, post } = await appWith(undefined, directory());
    try {
      const fresh = await post(catchBody(JET, uuid(1)));
      // A second lookup in the route's directory would have flagged this
      // catch while its points carry no bonus.
      expect(fresh.json()).toMatchObject({ points: 75, notable: null });
      expect(fresh.body).toContain('"notable":null');

      const replay = await post(catchBody(JET, uuid(1)));
      expect(replay.json()).toMatchObject({ points: 75, notable: JET_NOTABLE, duplicate: true });
    } finally {
      await app.close();
    }
  });
});

describe("catch routes with an empty directory", () => {
  it("omit `notable` everywhere: no data is not the same as not notable", async () => {
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
        payload: catchBody(JET, uuid(1)),
      });
      expect(posted.json().points).toBe(75);
      expect(posted.body).not.toContain('"notable"');
      const listed = await app.inject({ method: "GET", url: "/v1/catches", headers });
      expect(listed.json().catches).toHaveLength(1);
      expect(listed.body).not.toContain('"notable"');
    } finally {
      await app.close();
    }
  });
});

describe("rescore: notable planes (scoring v11, retroactive)", () => {
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
        // Staggered: rows sharing an instant would be re-counted as one press.
        caughtAt: new Date(Date.parse("2026-09-01T00:00:00Z") + seq * 1000),
        observerLat: 37.8,
        observerLon: -122.3,
      })
      .returning({ id: catches.id });
    return rows[0].id;
  }
  const pointsOf = async (id: string) =>
    (await db.select().from(catches).where(eq(catches.id, id)))[0];

  beforeEach(async () => {
    seq = 0;
    db = await makeTestDb();
    await seedAirframes(db);
    deviceId = (await db.insert(devices).values({ tokenHash: "hash-1" }).returning())[0].id;
  });

  it("pays the bonus on old catches of a notable airframe and only restamps the rest", async () => {
    const jetPlain = await insertCatch({ icao24: JET, points: 50 });
    const jetFirst = await insertCatch({ icao24: JET, points: 75, firstOfType: true });
    const jetDouble = await insertCatch({ icao24: JET, points: 63, pressSize: 2 });
    const airliner = await insertCatch({ icao24: AIRLINER, points: 50, typecode: "B738" });
    const warbird = await insertCatch({
      icao24: WARBIRD,
      points: 10,
      rarity: null,
      typecode: null,
    });

    const dry = await rescoreCatches(db, { dryRun: true, notable: directory() });
    expect(dry.scanned).toBe(5);
    expect(dry.distinctIcaos).toBe(3);
    expect(dry.changed).toBe(4); // three jet rows + the warbird
    expect(dry.pointsBefore).toBe(248);
    expect(dry.pointsAfter).toBe(248 + 25 * 3 + 5);
    expect(dry.applied).toBe(false);
    expect((await pointsOf(jetPlain)).points).toBe(50); // dry run wrote nothing

    const applied = await rescoreCatches(db, { notable: directory() });
    expect(applied.written).toBe(5); // 4 changed + the airliner's version restamp
    // Rows of ONE airframe with different frozen flags each keep their own
    // bonuses and all gain the notable one (the batching key holds).
    expect((await pointsOf(jetPlain)).points).toBe(75); // 50 + 25
    expect((await pointsOf(jetFirst)).points).toBe(100); // 50 + 25 + 25
    expect((await pointsOf(jetDouble)).points).toBe(88); // 50 + 13 + 25
    expect((await pointsOf(airliner)).points).toBe(50);
    expect((await pointsOf(warbird)).points).toBe(15); // floor 10 + 5
    for (const id of [jetPlain, jetFirst, jetDouble, airliner, warbird]) {
      expect((await pointsOf(id)).scoringVersion).toBe(11);
    }

    // Idempotent: nothing is stale now, and a forced full pass changes nothing.
    expect((await rescoreCatches(db, { notable: directory() })).scanned).toBe(1); // the warbird: rarity still null
    const again = await rescoreCatches(db, { all: true, notable: directory() });
    expect(again.changed).toBe(0);
    expect(again.written).toBe(0);
  });

  it("with no notable airframes caught, the v10→v11 rescore is a pure restamp", async () => {
    await insertCatch({ icao24: AIRLINER, points: 50, typecode: "B738" });
    await insertCatch({ icao24: AIRLINER, points: 75, typecode: "B738", firstOfType: true });
    const report = await rescoreCatches(db, { notable: directory() });
    expect(report).toMatchObject({ scanned: 2, changed: 0, written: 2 });
    expect(report.pointsAfter).toBe(report.pointsBefore);
  });

  it("re-asks the directory: a full pass follows what the directory says NOW", async () => {
    const id = await insertCatch({ icao24: JET, points: 75, scoringVersion: 11 });
    // Scored notable at upload; a directory that no longer lists the airframe
    // takes the bonus back on a forced pass (points are a projection)...
    await rescoreCatches(db, { all: true, notable: new NotableDirectory() });
    expect((await pointsOf(id)).points).toBe(50);
    // ...and the default (stale-only) pass never revisits a current-version row.
    expect((await rescoreCatches(db, { notable: directory() })).scanned).toBe(0);
    await rescoreCatches(db, { all: true, notable: directory() });
    expect((await pointsOf(id)).points).toBe(75);
  });
});
