import type { FastifyInstance } from "fastify";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type { Database } from "../src/db/client.js";
import { DrizzleCatchStore, DrizzleIdentityStore } from "../src/identity/store.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

/**
 * DELETE /v1/catches/:catchUuid — a Hangar delete reaches the server, so the
 * catch stops counting toward the leaderboard (and challenge scores, which
 * read the same table) and stops coming back on a Hangar restore.
 */

const NOW = 1_700_000_000;

function uuid(n: number) {
  return `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
}

function catchBody(catchUuid: string) {
  return {
    catchUuid,
    icao24: "abc123",
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
  };
}

describe("DELETE /v1/catches/:catchUuid", () => {
  let app: FastifyInstance;
  let db: Database;
  let token: string;
  let otherToken: string;

  beforeEach(async () => {
    db = await makeTestDb();
    app = await buildApp({
      identityStore: new DrizzleIdentityStore(db),
      catchStore: new DrizzleCatchStore(db),
      nowSeconds: () => NOW,
      rateLimitNow: () => 0,
    });
    token = (await app.inject({ method: "POST", url: "/v1/devices" })).json().deviceToken;
    otherToken = (await app.inject({ method: "POST", url: "/v1/devices" })).json().deviceToken;
  });

  afterEach(async () => {
    await app.close();
  });

  const auth = (t: string) => ({ authorization: `Bearer ${t}` });
  const upload = (id: string, t = token) =>
    app.inject({ method: "POST", url: "/v1/catches", headers: auth(t), payload: catchBody(id) });
  const del = (id: string, t = token) =>
    app.inject({ method: "DELETE", url: `/v1/catches/${id}`, headers: auth(t) });
  const list = async (t = token) =>
    (await app.inject({ method: "GET", url: "/v1/catches", headers: auth(t) })).json();
  const myPoints = async (t = token) =>
    (await app.inject({ method: "GET", url: "/v1/leaderboard", headers: auth(t) })).json().me
      .points;

  it("removes the catch: gone from restore and from my leaderboard points", async () => {
    expect((await upload(uuid(1))).statusCode).toBe(201);
    expect((await upload(uuid(2))).statusCode).toBe(201);
    const before = await myPoints();
    const one = (await list()).catches.find((c: { catchUuid: string }) => c.catchUuid === uuid(1));
    expect(before).toBeGreaterThan(0);

    const res = await del(uuid(1));
    expect(res.statusCode).toBe(204);

    const after = await list();
    expect(after.total).toBe(1);
    expect(after.catches.map((c: { catchUuid: string }) => c.catchUuid)).toEqual([uuid(2)]);
    expect(await myPoints()).toBe(before - one.points);
  });

  it("is idempotent: a repeat, or a catch that never uploaded, is still 204", async () => {
    await upload(uuid(3));
    expect((await del(uuid(3))).statusCode).toBe(204);
    expect((await del(uuid(3))).statusCode).toBe(204);
    expect((await del(uuid(99))).statusCode).toBe(204);
  });

  it("only touches the caller's own catch", async () => {
    await upload(uuid(4), otherToken);
    expect((await del(uuid(4), token)).statusCode).toBe(204);
    expect((await list(otherToken)).total).toBe(1);
  });

  it("a deleted catch uploaded again (a lost race) comes back as a fresh insert", async () => {
    // Documents the known edge: the client must not re-upload a deleted row.
    await upload(uuid(5));
    await del(uuid(5));
    expect((await upload(uuid(5))).statusCode).toBe(201);
  });

  it("rejects a malformed uuid and a missing token", async () => {
    expect((await del("not-a-uuid")).statusCode).toBe(400);
    const res = await app.inject({ method: "DELETE", url: `/v1/catches/${uuid(1)}` });
    expect(res.statusCode).toBe(401);
  });
});
