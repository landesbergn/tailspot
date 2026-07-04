import type { FastifyInstance } from "fastify";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type { Database } from "../src/db/client.js";
import { registry, typecodes } from "../src/db/schema.js";
import { DrizzleCatchStore, DrizzleIdentityStore } from "../src/identity/store.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

/**
 * Leaderboard aggregation end to end. Seeds three airframes of distinct rarity
 * so a device's total points are predictable, then registers devices, claims
 * handles for some, posts catches, and asserts ordering / hiding / `me`.
 */

const NOW = 1_700_000_000;
const OBS = { lat: 37.8, lon: -122.27 };
const AC = { lat: 37.9, lon: -122.27, altitudeMeters: 3000 };

// Three icao24s (valid 6-hex) mapped to common / rare / legendary (base 10 / 50
// / 500). Each device here catches a given type at most once, so every catch is
// FIRST-of-type and earns the +50%-of-base bonus → effective 15 / 75 / 750.
const COMMON = "c0c0c0";
const RARE = "a4a4a4";
const LEGEND = "1e6e7d";

function catchBody(icao24: string, catchUuid: string) {
  return {
    catchUuid,
    icao24,
    callsign: null,
    caughtAt: NOW,
    observer: {
      lat: OBS.lat,
      lon: OBS.lon,
      headingDeg: 0,
      elevationDeg: 15.05,
      headingAccuracyDeg: 5,
    },
    aircraft: {
      lat: AC.lat,
      lon: AC.lon,
      altitudeMeters: AC.altitudeMeters,
      positionTimestamp: NOW,
    },
  };
}

describe("GET /v1/leaderboard", () => {
  let app: FastifyInstance;
  let db: Database;
  let uuidSeq = 0;

  /** A fresh deterministic uuid per catch. */
  function nextUuid(): string {
    uuidSeq += 1;
    const n = uuidSeq.toString(16).padStart(12, "0");
    return `00000000-0000-4000-8000-${n}`;
  }

  beforeEach(async () => {
    uuidSeq = 0;
    db = await makeTestDb();
    await db.insert(typecodes).values([
      { typecode: "C172", manufacturer: "Cessna", model: "172", type: "ga", rarity: "common" },
      {
        typecode: "B738",
        manufacturer: "Boeing",
        model: "737-800",
        type: "narrow",
        rarity: "rare",
      },
      {
        typecode: "A388",
        manufacturer: "Airbus",
        model: "A-380",
        type: "wide",
        rarity: "legendary",
      },
    ]);
    await db.insert(registry).values([
      { icao24: COMMON, typecode: "C172", source: "faa" },
      { icao24: RARE, typecode: "B738", source: "faa" },
      { icao24: LEGEND, typecode: "A388", source: "faa" },
    ]);

    app = await buildApp({
      identityStore: new DrizzleIdentityStore(db),
      catchStore: new DrizzleCatchStore(db),
      nowSeconds: () => NOW,
      rateLimitNow: () => 0,
    });
  });

  afterEach(async () => {
    await app.close();
  });

  async function register(): Promise<string> {
    const res = await app.inject({ method: "POST", url: "/v1/devices" });
    return res.json().deviceToken;
  }

  async function claim(token: string, handle: string) {
    const res = await app.inject({
      method: "PUT",
      url: "/v1/devices/me/handle",
      headers: { authorization: `Bearer ${token}` },
      payload: { handle },
    });
    expect(res.statusCode).toBe(200);
  }

  async function postCatch(token: string, icao24: string) {
    const res = await app.inject({
      method: "POST",
      url: "/v1/catches",
      headers: { authorization: `Bearer ${token}` },
      payload: catchBody(icao24, nextUuid()),
    });
    expect([200, 201]).toContain(res.statusCode);
  }

  it("aggregates points per device and orders entries by points DESC", async () => {
    const alice = await register();
    const bob = await register();
    await claim(alice, "Alice");
    await claim(bob, "Bob");

    // Alice: legendary first-of-type (750). Bob: rare (75) + common (15) = 90.
    await postCatch(alice, LEGEND);
    await postCatch(bob, RARE);
    await postCatch(bob, COMMON);

    const res = await app.inject({ method: "GET", url: "/v1/leaderboard" });
    expect(res.statusCode).toBe(200);
    const { entries } = res.json();
    expect(entries).toEqual([
      { rank: 1, handle: "Alice", points: 750, catches: 1 },
      { rank: 2, handle: "Bob", points: 90, catches: 2 },
    ]);
  });

  it("hides handle-less devices from entries, but they still occupy ranks", async () => {
    const ghost = await register(); // no handle, big points
    const named = await register();
    await claim(named, "Named");

    await postCatch(ghost, LEGEND); // 750 (first-of-type legendary), invisible
    await postCatch(named, RARE); // 75 (first-of-type rare), visible

    const res = await app.inject({
      method: "GET",
      url: "/v1/leaderboard",
      headers: { authorization: `Bearer ${named}` },
    });
    const body = res.json();
    // Only the named device appears in entries…
    expect(body.entries).toEqual([{ rank: 1, handle: "Named", points: 75, catches: 1 }]);
    // …but `me` reflects the TRUE rank: the ghost (750 pts) outranks Named, so
    // Named is rank 2 overall even though the ghost is hidden from entries.
    expect(body.me).toEqual({ rank: 2, points: 75 });
  });

  it("hides handle-bearing devices with zero catches (drive-by onboarding claims)", async () => {
    // Onboarding mints a handle for anyone who taps a suggestion chip, so a
    // claimed handle alone must not appear on the public board — one catch is
    // the entry ticket.
    const driveBy = await register();
    await claim(driveBy, "downwind_9346"); // handle, never catches
    const player = await register();
    await claim(player, "Player");
    await postCatch(player, COMMON);

    const res = await app.inject({ method: "GET", url: "/v1/leaderboard" });
    const { entries } = res.json();
    expect(entries).toEqual([{ rank: 1, handle: "Player", points: 15, catches: 1 }]);
  });

  it("`me` is present for a valid token even without a handle; null without a token", async () => {
    const anon = await register(); // no handle
    await postCatch(anon, COMMON); // 15 points (first-of-type common: 10 + 5)

    const withToken = await app.inject({
      method: "GET",
      url: "/v1/leaderboard",
      headers: { authorization: `Bearer ${anon}` },
    });
    expect(withToken.json().me).toEqual({ rank: 1, points: 15 });
    // The anon device is NOT in entries (no handle).
    expect(withToken.json().entries).toEqual([]);

    const noToken = await app.inject({ method: "GET", url: "/v1/leaderboard" });
    expect(noToken.json().me).toBeNull();
  });

  it("breaks point ties deterministically by registration time (earlier device wins)", async () => {
    // Register early FIRST so its createdAt is earlier; both reach 75 points
    // (each device's first-of-type rare).
    const early = await register();
    const late = await register();
    await claim(early, "Early");
    await claim(late, "Late");
    await postCatch(early, RARE);
    await postCatch(late, RARE);

    const res = await app.inject({ method: "GET", url: "/v1/leaderboard" });
    const { entries } = res.json();
    expect(entries.map((e: { handle: string }) => e.handle)).toEqual(["Early", "Late"]);
    expect(entries[0].rank).toBe(1);
    expect(entries[1].rank).toBe(2);
  });

  it("respects the limit query param", async () => {
    for (let i = 0; i < 3; i++) {
      const t = await register();
      await claim(t, `Player${i}`);
      await postCatch(t, COMMON);
    }
    const res = await app.inject({ method: "GET", url: "/v1/leaderboard?limit=2" });
    expect(res.json().entries).toHaveLength(2);
  });
});
