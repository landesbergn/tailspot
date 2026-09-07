import type { FastifyInstance } from "fastify";
import { afterEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type { CatchStore, DeviceIdentity, IdentityStore } from "../src/identity/store.js";
import { hashToken } from "../src/identity/token.js";
import type { MetadataStore } from "../src/metadata/store.js";
import type { Bbox, PositionProvider, ProviderSnapshot } from "../src/providers/types.js";

/**
 * Rate limits on the endpoints that had NONE until 2026-09-06: the position
 * poll, the metadata lookup, the Hangar-restore read, and — the one that
 * mattered most — the pre-auth path on every bearer route, where a bad token
 * used to cost the caller one request and cost us a database round-trip, with
 * no ceiling at all.
 *
 * Everything here is stubbed (no PGlite): these tests are about the limiter
 * wiring, and a fake store makes "did the request reach the store?" directly
 * observable — which is the actual assertion for the pre-auth limiter.
 */

const VALID_BBOX = "lamin=37.6&lomin=-122.5&lamax=38.1&lomax=-122";
const TOKEN = "a".repeat(64);
/** A well-formed bearer that matches no device — the shape a prober sends. */
const BAD_TOKEN = "f".repeat(64);

/** Counts what reaches the identity store, so we can prove a burst never does. */
function countingIdentityStore(): { store: IdentityStore; lookups: () => number } {
  let lookups = 0;
  const store: IdentityStore = {
    createDevice: async () => ({ id: "device-1" }),
    findByTokenHash: async (hash): Promise<DeviceIdentity | null> => {
      lookups++;
      return hash === hashToken(TOKEN) ? { id: "device-1", handle: null } : null;
    },
    claimHandle: async () => ({ ok: true as const, handle: "Maverick" }),
    takenHandles: async () => new Set<string>(),
  };
  return { store, lookups: () => lookups };
}

const provider: PositionProvider = {
  name: "stub",
  async aircraftInBbox(_bbox: Bbox): Promise<ProviderSnapshot> {
    return { fetchedAt: 1_750_000_000, aircraft: [] };
  },
};

/** Knows no airframe: a 404 is fine, we only care about the 429 boundary. */
const metadataStore: MetadataStore = { lookup: async () => null };

/**
 * Only `listCatches` is exercised (GET /v1/catches); the rest of CatchStore is
 * never called on these paths, so the cast keeps the stub honest about that
 * rather than inventing a dozen unreachable methods.
 */
const catchStore = {
  listCatches: async () => ({ total: 0, catches: [] }),
} as unknown as CatchStore;

describe("per-IP and per-device limits on the previously-unmetered routes", () => {
  let app: FastifyInstance | undefined;

  async function build(): Promise<FastifyInstance> {
    app = await buildApp({
      provider,
      metadataStore,
      identityStore: countingIdentityStore().store,
      catchStore,
      // Frozen clock: no token ever refills, so the Nth call is exact.
      rateLimitNow: () => 0,
    });
    return app;
  }

  afterEach(async () => {
    await app?.close();
    app = undefined;
  });

  it("GET /v1/aircraft is capped at 120/min per IP", async () => {
    const a = await build();
    for (let i = 0; i < 120; i++) {
      const res = await a.inject({ method: "GET", url: `/v1/aircraft?${VALID_BBOX}` });
      expect(res.statusCode).toBe(200);
    }
    const denied = await a.inject({ method: "GET", url: `/v1/aircraft?${VALID_BBOX}` });
    expect(denied.statusCode).toBe(429);
    expect(denied.json()).toEqual({ error: "rate limited" });
    expect(denied.headers["retry-after"]).toBeTruthy();
  });

  it("the /v1/aircraft cap is per IP, so one flooder can't 429 everyone", async () => {
    const a = await build();
    for (let i = 0; i < 121; i++) {
      await a.inject({
        method: "GET",
        url: `/v1/aircraft?${VALID_BBOX}`,
        headers: { "fly-client-ip": "203.0.113.7" },
      });
    }
    const other = await a.inject({
      method: "GET",
      url: `/v1/aircraft?${VALID_BBOX}`,
      headers: { "fly-client-ip": "203.0.113.8" },
    });
    expect(other.statusCode).toBe(200);
  });

  it("GET /v1/metadata/:icao24 is capped at 300/min per IP", async () => {
    const a = await build();
    for (let i = 0; i < 300; i++) {
      const res = await a.inject({ method: "GET", url: "/v1/metadata/abc123" });
      expect(res.statusCode).toBe(404); // the stub store knows nothing — fine
    }
    const denied = await a.inject({ method: "GET", url: "/v1/metadata/abc123" });
    expect(denied.statusCode).toBe(429);
    expect(denied.headers["retry-after"]).toBeTruthy();
  });

  it("GET /v1/catches is capped at 30/min per DEVICE", async () => {
    const a = await build();
    const auth = { authorization: `Bearer ${TOKEN}` };
    for (let i = 0; i < 30; i++) {
      const res = await a.inject({ method: "GET", url: "/v1/catches", headers: auth });
      expect(res.statusCode).toBe(200);
    }
    const denied = await a.inject({ method: "GET", url: "/v1/catches", headers: auth });
    expect(denied.statusCode).toBe(429);
    expect(denied.json()).toEqual({ error: "rate limited" });
    expect(denied.headers["retry-after"]).toBeTruthy();

    // Per-DEVICE, not per-IP: the same peer with no token gets the 401 it
    // deserves rather than the device's 429 (the two limiters are distinct).
    const anon = await a.inject({ method: "GET", url: "/v1/catches" });
    expect(anon.statusCode).toBe(401);
  });
});

describe("bearer routes meter BEFORE the token lookup", () => {
  let app: FastifyInstance | undefined;
  let lookups: () => number = () => 0;

  async function build(): Promise<FastifyInstance> {
    const identity = countingIdentityStore();
    lookups = identity.lookups;
    app = await buildApp({
      provider,
      metadataStore,
      identityStore: identity.store,
      catchStore,
      rateLimitNow: () => 0,
    });
    return app;
  }

  afterEach(async () => {
    await app?.close();
    app = undefined;
  });

  it("a burst of bad tokens gets 429 without reaching the identity store", async () => {
    const a = await build();
    const bad = { authorization: `Bearer ${BAD_TOKEN}` };

    // 120/min per IP, shared across the bearer routes. The first 120 probes are
    // 401s (each one DID hit the store — that's the cost we're bounding)…
    for (let i = 0; i < 120; i++) {
      const res = await a.inject({ method: "GET", url: "/v1/catches", headers: bad });
      expect(res.statusCode).toBe(401);
    }
    expect(lookups()).toBe(120);

    // …and everything after is refused before the store is consulted. Without
    // this, probing was free for the attacker and unbounded work for Postgres.
    for (let i = 0; i < 20; i++) {
      const res = await a.inject({ method: "GET", url: "/v1/catches", headers: bad });
      expect(res.statusCode).toBe(429);
      expect(res.headers["retry-after"]).toBeTruthy();
    }
    expect(lookups()).toBe(120); // unchanged: not one extra DB round-trip
  });

  it("the pre-auth limiter is SHARED across the bearer routes", async () => {
    const a = await build();
    const bad = { authorization: `Bearer ${BAD_TOKEN}` };

    // Spend the whole per-IP budget on one bearer route…
    for (let i = 0; i < 120; i++) {
      await a.inject({ method: "GET", url: "/v1/catches", headers: bad });
    }
    // …and the others are already spent too — a prober can't just rotate paths.
    const put = await a.inject({
      method: "PUT",
      url: "/v1/devices/me/handle",
      headers: bad,
      payload: { handle: "Maverick" },
    });
    expect(put.statusCode).toBe(429);
    const post = await a.inject({ method: "POST", url: "/v1/catches", headers: bad, payload: {} });
    expect(post.statusCode).toBe(429);
    expect(lookups()).toBe(120);
  });
});
