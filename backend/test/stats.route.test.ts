import type { FastifyInstance } from "fastify";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type { Database } from "../src/db/client.js";
import { registry, typecodes } from "../src/db/schema.js";
import { DrizzleCatchStore, DrizzleIdentityStore } from "../src/identity/store.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

/**
 * GET /v1/stats — the marketing site's "planes caught" counter. Asserts the
 * Origin fence (allowlisted → 200 + CORS echo; anything else → 404), the
 * count itself against real inserted catches, and the in-process memo (a
 * catch posted inside the TTL is invisible until the memo expires).
 */

const NOW = 1_700_000_000;
const SITE = "https://tailspot.app";
const ICAO = "c0c0c0";

function catchBody(catchUuid: string) {
  return {
    catchUuid,
    icao24: ICAO,
    callsign: null,
    caughtAt: NOW,
    observer: {
      lat: 37.8,
      lon: -122.27,
      headingDeg: 0,
      elevationDeg: 15.05,
      headingAccuracyDeg: 5,
    },
    aircraft: { lat: 37.9, lon: -122.27, altitudeMeters: 3000, positionTimestamp: NOW },
  };
}

describe("GET /v1/stats", () => {
  let app: FastifyInstance;
  let db: Database;
  let clockMs = 0;
  let uuidSeq = 0;

  function nextUuid(): string {
    uuidSeq += 1;
    return `00000000-0000-4000-8000-${uuidSeq.toString(16).padStart(12, "0")}`;
  }

  beforeEach(async () => {
    clockMs = 0;
    uuidSeq = 0;
    db = await makeTestDb();
    await db
      .insert(typecodes)
      .values([
        { typecode: "C172", manufacturer: "Cessna", model: "172", type: "ga", rarity: "common" },
      ]);
    await db.insert(registry).values([{ icao24: ICAO, typecode: "C172", source: "faa" }]);
    app = await buildApp({
      identityStore: new DrizzleIdentityStore(db),
      catchStore: new DrizzleCatchStore(db),
      nowSeconds: () => NOW,
      rateLimitNow: () => clockMs,
      statsAllowedOrigins: [SITE, "https://www.tailspot.app"],
    });
  });

  afterEach(async () => {
    await app.close();
  });

  async function postCatch(): Promise<void> {
    const reg = await app.inject({ method: "POST", url: "/v1/devices" });
    const token = reg.json().deviceToken as string;
    const res = await app.inject({
      method: "POST",
      url: "/v1/catches",
      headers: { authorization: `Bearer ${token}` },
      payload: catchBody(nextUuid()),
    });
    expect([200, 201]).toContain(res.statusCode);
  }

  function stats(origin?: string) {
    return app.inject({
      method: "GET",
      url: "/v1/stats",
      headers: origin === undefined ? {} : { origin },
    });
  }

  it("404s without an Origin header (curl, other scripts)", async () => {
    const res = await stats();
    expect(res.statusCode).toBe(404);
    expect(res.headers["access-control-allow-origin"]).toBeUndefined();
  });

  it("404s for a non-allowlisted origin", async () => {
    const res = await stats("https://evil.example");
    expect(res.statusCode).toBe(404);
    expect(res.headers["access-control-allow-origin"]).toBeUndefined();
  });

  it("returns the catch count with CORS + cache headers for the site", async () => {
    await postCatch();
    await postCatch();
    const res = await stats(SITE);
    expect(res.statusCode).toBe(200);
    const body = res.json<{ catches: number; asOf: string }>();
    expect(body.catches).toBe(2);
    expect(new Date(body.asOf).getTime()).toBe(0); // clock is at 0 ms
    expect(res.headers["access-control-allow-origin"]).toBe(SITE);
    expect(res.headers.vary).toBe("Origin");
    expect(res.headers["cache-control"]).toBe("public, max-age=300");
  });

  it("echoes whichever allowlisted origin asked", async () => {
    const res = await stats("https://www.tailspot.app");
    expect(res.statusCode).toBe(200);
    expect(res.headers["access-control-allow-origin"]).toBe("https://www.tailspot.app");
  });

  it("allows the preview site by default (no allowlist override)", async () => {
    const plain = await buildApp({
      identityStore: new DrizzleIdentityStore(db),
      catchStore: new DrizzleCatchStore(db),
      nowSeconds: () => NOW,
      rateLimitNow: () => 0,
    });
    try {
      const res = await plain.inject({
        method: "GET",
        url: "/v1/stats",
        headers: { origin: "https://tailspot-www-preview.fly.dev" },
      });
      expect(res.statusCode).toBe(200);
      expect(res.headers["access-control-allow-origin"]).toBe(
        "https://tailspot-www-preview.fly.dev",
      );
    } finally {
      await plain.close();
    }
  });

  it("memoises the count until the TTL elapses", async () => {
    expect((await stats(SITE)).json().catches).toBe(0);
    await postCatch();
    clockMs = 59_000;
    expect((await stats(SITE)).json().catches).toBe(0); // still memoised
    clockMs = 60_000;
    expect((await stats(SITE)).json().catches).toBe(1); // recomputed
  });
});
