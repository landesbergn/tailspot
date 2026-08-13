import type { FastifyInstance } from "fastify";
import { afterEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";

describe("GET /readyz", () => {
  let app: FastifyInstance;

  afterEach(async () => {
    await app.close();
  });

  it("responds 200 { status: 'ok' } when the readiness probe succeeds", async () => {
    app = await buildApp({ readyProbe: async () => {} });
    const res = await app.inject({ method: "GET", url: "/readyz" });
    expect(res.statusCode).toBe(200);
    expect(res.json<{ status: string }>().status).toBe("ok");
  });

  it("responds 503 { status: 'unavailable' } when the probe rejects", async () => {
    app = await buildApp({
      readyProbe: async () => {
        throw new Error("connection refused");
      },
    });
    const res = await app.inject({ method: "GET", url: "/readyz" });
    expect(res.statusCode).toBe(503);
    expect(res.json<{ status: string }>().status).toBe("unavailable");
  });

  it("responds 503 with no probe injected and no DATABASE_URL (default probe can't reach a DB)", async () => {
    // The default probe calls getDb(), which throws without DATABASE_URL —
    // /readyz must report that as 503-not-ready, never crash the process.
    app = await buildApp();
    const res = await app.inject({ method: "GET", url: "/readyz" });
    expect(res.statusCode).toBe(503);
  });

  it("responds 503 when the probe hangs past the 3 s cap (fake timers)", async () => {
    // A hung DB socket must not drag /readyz past the uptime monitor's own
    // request timeout — the Promise.race turns "hanging" into a fast 503.
    const { vi } = await import("vitest");
    vi.useFakeTimers();
    try {
      app = await buildApp({ readyProbe: () => new Promise(() => {}) });
      const pending = app.inject({ method: "GET", url: "/readyz" });
      await vi.advanceTimersByTimeAsync(3_100);
      const res = await pending;
      expect(res.statusCode).toBe(503);
    } finally {
      vi.useRealTimers();
    }
  });
});
