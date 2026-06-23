import type { FastifyInstance } from "fastify";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type { Database } from "../src/db/client.js";
import { DrizzleCatchStore, DrizzleIdentityStore } from "../src/identity/store.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

/**
 * GET /v1/handles/suggestions, end to end via app.inject() with a PGlite-backed
 * store. The rate-limit clock is frozen so a test's calls never trip the limiter
 * incidentally — the limiter has its own behaviour test below.
 */
const HANDLE_RE = /^[A-Za-z0-9_]{3,20}$/;

describe("GET /v1/handles/suggestions", () => {
  let app: FastifyInstance;
  let db: Database;

  beforeEach(async () => {
    db = await makeTestDb();
    app = await buildApp({
      identityStore: new DrizzleIdentityStore(db),
      catchStore: new DrizzleCatchStore(db),
      rateLimitNow: () => 0, // frozen clock; per-test calls stay under capacity
    });
  });

  afterEach(async () => {
    await app.close();
  });

  it("returns the requested number of valid, distinct suggestions by default", async () => {
    const res = await app.inject({ method: "GET", url: "/v1/handles/suggestions" });
    expect(res.statusCode).toBe(200);
    const { suggestions } = res.json() as { suggestions: string[] };
    expect(suggestions).toHaveLength(4); // default count
    expect(new Set(suggestions).size).toBe(4); // distinct
    for (const h of suggestions) expect(h, h).toMatch(HANDLE_RE);
  });

  it("honors count, clamped to [1, 10]", async () => {
    const one = await app.inject({ method: "GET", url: "/v1/handles/suggestions?count=1" });
    expect((one.json() as { suggestions: string[] }).suggestions).toHaveLength(1);

    const many = await app.inject({ method: "GET", url: "/v1/handles/suggestions?count=50" });
    expect((many.json() as { suggestions: string[] }).suggestions).toHaveLength(10); // clamped

    // Garbage count falls back to the default.
    const garbage = await app.inject({ method: "GET", url: "/v1/handles/suggestions?count=abc" });
    expect((garbage.json() as { suggestions: string[] }).suggestions).toHaveLength(4);
  });

  it("never suggests an already-claimed handle (case-insensitive)", async () => {
    // Claim "Taken_1234" on the shared db.
    const reg = await app.inject({ method: "POST", url: "/v1/devices" });
    const { deviceToken } = reg.json() as { deviceToken: string };
    const claim = await app.inject({
      method: "PUT",
      url: "/v1/devices/me/handle",
      headers: { authorization: `Bearer ${deviceToken}` },
      payload: { handle: "Taken_1234" },
    });
    expect(claim.statusCode).toBe(200);

    // An app whose generator always offers the taken handle (different casing)
    // plus one free name. The route must filter the taken one out.
    const app2 = await buildApp({
      identityStore: new DrizzleIdentityStore(db),
      catchStore: new DrizzleCatchStore(db),
      rateLimitNow: () => 0,
      handleCandidateGenerator: () => ["taken_1234", "free_5678"],
    });
    const res = await app2.inject({ method: "GET", url: "/v1/handles/suggestions?count=2" });
    await app2.close();

    const { suggestions } = res.json() as { suggestions: string[] };
    expect(suggestions).toEqual(["free_5678"]);
  });

  it("per-IP limiter returns 429 with Retry-After after the cap", async () => {
    // capacity is 30/min; with the clock frozen, the 31st call is denied.
    let last = await app.inject({ method: "GET", url: "/v1/handles/suggestions" });
    for (let i = 0; i < 31; i++) {
      last = await app.inject({ method: "GET", url: "/v1/handles/suggestions" });
    }
    expect(last.statusCode).toBe(429);
    expect(last.json()).toEqual({ error: "rate limited" });
    expect(last.headers["retry-after"]).toBeTruthy();
  });
});
