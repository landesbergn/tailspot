import type { FastifyInstance } from "fastify";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";

/**
 * The Fastify-level resource ceilings from app.ts. Timeouts can't be asserted
 * through `app.inject()` (there is no real socket), so they're covered by
 * reading them back off the server options; the body limit is real behaviour
 * and is exercised end to end.
 */
describe("server resource limits", () => {
  let app: FastifyInstance;

  beforeAll(async () => {
    app = await buildApp();
  });

  afterAll(async () => {
    await app.close();
  });

  it("rejects a body over 64 KB with 413, before the handler or the DB", async () => {
    // 100 KB of padding. This never reaches the route handler, which matters:
    // POST /v1/devices would otherwise need a database, and there isn't one in
    // this suite. Rejecting oversized uploads at the parser is the whole point.
    const res = await app.inject({
      method: "POST",
      url: "/v1/devices",
      headers: { "content-type": "application/json" },
      payload: JSON.stringify({ pad: "x".repeat(100_000) }),
    });
    expect(res.statusCode).toBe(413);
  });

  it("still accepts a realistically sized body", async () => {
    // ~1 KB — comfortably larger than the biggest real request (a catch is
    // ~300–400 bytes) and comfortably under the limit. A 400/401/500 here is
    // fine; anything but 413 proves the limit didn't fire.
    const res = await app.inject({
      method: "POST",
      url: "/v1/devices",
      headers: { "content-type": "application/json" },
      payload: JSON.stringify({ pad: "x".repeat(1_000) }),
    });
    expect(res.statusCode).not.toBe(413);
  });

  it("configures request and connection timeouts on the underlying server", () => {
    // Fastify copies these onto the Node HTTP server. Asserted so a future
    // options edit can't quietly drop the ceilings that keep a slow-loris
    // client from parking connections on a 256 MB VM.
    const server = app.server as unknown as {
      requestTimeout: number;
      // Node calls the connection/idle ceiling `headersTimeout` + the socket
      // timeout; Fastify's connectionTimeout maps to server.timeout.
      timeout: number;
    };
    expect(server.requestTimeout).toBe(15_000);
    expect(server.timeout).toBe(30_000);
  });
});
