import type { FastifyInstance } from "fastify";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";

describe("GET /healthz", () => {
  let app: FastifyInstance;

  beforeAll(async () => {
    // buildApp() returns a configured instance without binding to a port.
    // app.inject() fires requests over Fastify's in-process transport —
    // no network socket is opened, so tests are fast and port-collision-free.
    app = await buildApp();
  });

  afterAll(async () => {
    await app.close();
  });

  it("responds 200", async () => {
    const res = await app.inject({ method: "GET", url: "/healthz" });
    expect(res.statusCode).toBe(200);
  });

  it("returns exactly { status: 'ok' }", async () => {
    const res = await app.inject({ method: "GET", url: "/healthz" });
    expect(res.json()).toEqual({ status: "ok" });
  });

  it("does not leak the build version to unauthenticated callers", async () => {
    // The version used to be in this body. It told anyone who asked which
    // build is running, which is the first step in matching a dependency CVE
    // to a live target — and nothing consumed it. Asserted, not just deleted,
    // so a future "handy for debugging" re-add trips a test.
    const res = await app.inject({ method: "GET", url: "/healthz" });
    expect(Object.keys(res.json<Record<string, unknown>>())).toEqual(["status"]);
    expect(res.body).not.toMatch(/\d+\.\d+\.\d+/);
  });
});
