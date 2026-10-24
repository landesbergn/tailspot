import type { ErrorEvent } from "@sentry/node";
import Fastify, { type FastifyInstance } from "fastify";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import {
  CAUGHT_AT_FLOOR,
  CAUGHT_AT_MAX_FUTURE_SECONDS,
  clampToFloor,
  isPlausibleCaughtAt,
} from "../src/catches/caughtAtBounds.js";
import type { Database } from "../src/db/client.js";
import { catches, devices } from "../src/db/schema.js";
import { installErrorHandler } from "../src/errorHandler.js";
import { rateLimitPrefix } from "../src/identity/clientIp.js";
import { DrizzleCatchStore, DrizzleIdentityStore } from "../src/identity/store.js";
import { scrubEvent, stripSqlParams } from "../src/instrument.js";
import type { Bbox, PositionProvider, ProviderSnapshot } from "../src/providers/types.js";
import { FetchRateLimitedError, TileCache } from "../src/routes/tileCache.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

/**
 * Regression tests for the 2026-10-24 security audit. Each block names the
 * finding it pins; the fix rationale lives next to the code it tests.
 */

const DRIZZLE_MESSAGE =
  'Failed query: insert into "catches" ("observer_lat", "observer_lon") values ($1, $2)\nparams: 37.8012,-122.2711';

describe("5xx responses never carry the error message", () => {
  let app: FastifyInstance;

  beforeEach(async () => {
    app = Fastify({ logger: false });
    installErrorHandler(app);
    app.get("/db-fail", async () => {
      throw new Error(DRIZZLE_MESSAGE);
    });
    app.get("/bad-request", async () => {
      const err = new Error("limit must be a number") as Error & { statusCode: number };
      err.statusCode = 400;
      throw err;
    });
    await app.ready();
  });

  afterEach(async () => {
    await app.close();
  });

  it("a thrown DB error answers a generic 500 with no SQL or params", async () => {
    const res = await app.inject({ method: "GET", url: "/db-fail" });
    expect(res.statusCode).toBe(500);
    expect(res.json()).toEqual({
      statusCode: 500,
      error: "Internal Server Error",
      message: "Internal Server Error",
    });
    expect(res.body).not.toContain("Failed query");
    expect(res.body).not.toContain("37.8012");
  });

  it("4xx errors still pass their message through unchanged", async () => {
    const res = await app.inject({ method: "GET", url: "/bad-request" });
    expect(res.statusCode).toBe(400);
    expect(res.json().message).toBe("limit must be a number");
  });

  it("Fastify's own 4xx (malformed JSON) keeps its default body", async () => {
    app = Fastify({ logger: false });
    installErrorHandler(app);
    app.post("/echo", async (req) => req.body);
    const res = await app.inject({
      method: "POST",
      url: "/echo",
      headers: { "content-type": "application/json" },
      payload: "{not json",
    });
    expect(res.statusCode).toBe(400);
    expect(res.json().code).toBe("FST_ERR_CTP_INVALID_JSON_BODY");
  });
});

describe("Sentry scrub drops bound SQL params from exception text", () => {
  it("stripSqlParams keeps the query, redacts the values", () => {
    const out = stripSqlParams(DRIZZLE_MESSAGE);
    expect(out).toContain('insert into "catches"');
    expect(out).not.toContain("37.8012");
    expect(out.endsWith("\nparams: [redacted]")).toBe(true);
  });

  it("leaves messages without a params tail alone", () => {
    expect(stripSqlParams("connect ETIMEDOUT")).toBe("connect ETIMEDOUT");
  });

  it("scrubEvent rewrites every exception value", () => {
    const event = {
      exception: { values: [{ type: "DrizzleQueryError", value: DRIZZLE_MESSAGE }] },
    } as unknown as ErrorEvent;
    const out = scrubEvent(event);
    expect(out.exception?.values?.[0].value).not.toContain("-122.2711");
  });
});

describe("per-IP limiter keys collapse IPv6 to /64", () => {
  it("passes IPv4 through", () => {
    expect(rateLimitPrefix("203.0.113.7")).toBe("203.0.113.7");
  });

  it("unwraps IPv4-mapped IPv6", () => {
    expect(rateLimitPrefix("::ffff:203.0.113.7")).toBe("203.0.113.7");
  });

  it("every address in one /64 shares a key", () => {
    const a = rateLimitPrefix("2001:db8:abcd:12:1:2:3:4");
    const b = rateLimitPrefix("2001:0db8:abcd:0012:ffff:ffff:ffff:ffff");
    const c = rateLimitPrefix("2001:db8:abcd:12::99");
    expect(a).toBe("2001:db8:abcd:12::/64");
    expect(b).toBe(a);
    expect(c).toBe(a);
  });

  it("different /64s stay distinct", () => {
    expect(rateLimitPrefix("2001:db8:abcd:13::1")).not.toBe(rateLimitPrefix("2001:db8:abcd:12::1"));
  });

  it("handles leading :: and zone ids", () => {
    expect(rateLimitPrefix("::1")).toBe("0:0:0:0::/64");
    expect(rateLimitPrefix("fe80::1%en0")).toBe("fe80:0:0:0::/64");
  });

  it("returns garbage unchanged rather than inventing a prefix", () => {
    expect(rateLimitPrefix("1:2:3")).toBe("1:2:3");
    expect(rateLimitPrefix("zz::1")).toBe("zz::1");
    expect(rateLimitPrefix("1::2::3")).toBe("1::2::3");
  });
});

describe("caughtAt bounds", () => {
  const now = 1_790_000_000;
  const floorSec = CAUGHT_AT_FLOOR.getTime() / 1000;

  it("accepts now, the floor itself, and a day of clock skew", () => {
    expect(isPlausibleCaughtAt(now, now)).toBe(true);
    expect(isPlausibleCaughtAt(floorSec, now)).toBe(true);
    expect(isPlausibleCaughtAt(now + CAUGHT_AT_MAX_FUTURE_SECONDS, now)).toBe(true);
  });

  it("rejects pre-launch, ancient, far-future and out-of-Date-range values", () => {
    expect(isPlausibleCaughtAt(floorSec - 1, now)).toBe(false);
    expect(isPlausibleCaughtAt(-6e10, now)).toBe(false);
    expect(isPlausibleCaughtAt(now + CAUGHT_AT_MAX_FUTURE_SECONDS + 1, now)).toBe(false);
    expect(isPlausibleCaughtAt(9e12, now)).toBe(false);
  });

  it("clampToFloor bounds the decide-on-read backfill start", () => {
    expect(clampToFloor(new Date(-6e13))).toEqual(CAUGHT_AT_FLOOR);
    const later = new Date("2026-08-01T00:00:00Z");
    expect(clampToFloor(later)).toEqual(later);
  });
});

describe("POST /v1/catches input bounds", () => {
  const NOW = 1_790_000_000;
  let app: FastifyInstance;
  let db: Database;
  let token: string;

  beforeEach(async () => {
    db = await makeTestDb();
    app = await buildApp({
      identityStore: new DrizzleIdentityStore(db),
      catchStore: new DrizzleCatchStore(db),
      nowSeconds: () => NOW,
      rateLimitNow: () => 0,
    });
    token = (await app.inject({ method: "POST", url: "/v1/devices" })).json().deviceToken;
  });

  afterEach(async () => {
    await app.close();
  });

  function body(overrides: Record<string, unknown>) {
    return {
      catchUuid: "11111111-1111-4111-8111-111111111111",
      icao24: "abcdef",
      callsign: "UAL123",
      caughtAt: NOW,
      observer: {
        lat: 37.8,
        lon: -122.27,
        headingDeg: null,
        elevationDeg: null,
        headingAccuracyDeg: null,
      },
      aircraft: null,
      ...overrides,
    };
  }

  function post(payload: object) {
    return app.inject({
      method: "POST",
      url: "/v1/catches",
      headers: { authorization: `Bearer ${token}` },
      payload,
    });
  }

  it("rejects a backdated or far-future caughtAt with 422", async () => {
    for (const caughtAt of [-6e10, CAUGHT_AT_FLOOR.getTime() / 1000 - 60, NOW + 2 * 86_400, 9e12]) {
      const res = await post(body({ caughtAt }));
      expect(res.statusCode, `caughtAt=${caughtAt}`).toBe(422);
      expect(res.json()).toEqual({ error: "caughtAt out of range" });
    }
    expect(await db.select().from(catches)).toHaveLength(0);
  });

  it("truncates an oversized callsign instead of storing it whole", async () => {
    const res = await post(body({ callsign: `UAL${"9".repeat(4000)}` }));
    expect(res.statusCode).toBe(201);
    const [row] = await db.select({ callsign: catches.callsign }).from(catches);
    expect(row.callsign).toHaveLength(16);
  });
});

describe("TileCache per-client fetch gate", () => {
  const bbox: Bbox = { lamin: 37.6, lomin: -122.5, lamax: 37.7, lomax: -122.4 };

  function countingProvider(): { provider: PositionProvider; calls: () => number } {
    let n = 0;
    const provider: PositionProvider = {
      name: "stub",
      async aircraftInBbox(): Promise<ProviderSnapshot> {
        n += 1;
        return { fetchedAt: 1_790_000_000, aircraft: [] };
      },
    };
    return { provider, calls: () => n };
  }

  it("a cold tile with the allowance spent throws FetchRateLimitedError, no upstream call", async () => {
    const { provider, calls } = countingProvider();
    const cache = new TileCache(provider, {}, () => 0);
    await expect(cache.get(bbox, { mayFetch: () => false })).rejects.toBeInstanceOf(
      FetchRateLimitedError,
    );
    expect(calls()).toBe(0);
  });

  it("an expired-but-servable tile serves stale cache instead of fetching", async () => {
    const { provider, calls } = countingProvider();
    let nowMs = 0;
    const cache = new TileCache(provider, {}, () => nowMs);
    await cache.get(bbox);
    nowMs = 20_000; // past the 10 s TTL, inside the 60 s stale window
    const res = await cache.get(bbox, { mayFetch: () => false });
    expect(res.stale).toBe(true);
    expect(calls()).toBe(1);
  });

  it("a fresh cache hit never charges the allowance", async () => {
    const { provider } = countingProvider();
    const cache = new TileCache(provider, {}, () => 0);
    await cache.get(bbox);
    let charged = 0;
    await cache.get(bbox, {
      mayFetch: () => {
        charged += 1;
        return true;
      },
    });
    expect(charged).toBe(0);
  });
});

describe("handle claim race", () => {
  it("two devices claiming one handle at once: one wins, one gets 'taken', nothing throws", async () => {
    const db = await makeTestDb();
    const store = new DrizzleIdentityStore(db);
    const a = await store.createDevice("a".repeat(64));
    const b = await store.createDevice("b".repeat(64));
    const results = await Promise.all([
      store.claimHandle(a.id, "Skywatcher"),
      store.claimHandle(b.id, "skywatcher"),
    ]);
    expect(results.filter((r) => r.ok)).toHaveLength(1);
    expect(results.filter((r) => !r.ok)).toEqual([{ ok: false, reason: "taken" }]);
    const held = await db.select({ handle: devices.handle }).from(devices);
    expect(held.filter((r) => r.handle !== null)).toHaveLength(1);
  });
});
