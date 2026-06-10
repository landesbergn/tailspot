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

  it("returns { status: 'ok', version: <string> }", async () => {
    const res = await app.inject({ method: "GET", url: "/healthz" });
    const body = res.json<{ status: string; version: string }>();
    expect(body.status).toBe("ok");
    expect(typeof body.version).toBe("string");
    expect(body.version.length).toBeGreaterThan(0);
  });
});
