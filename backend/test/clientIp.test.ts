import type { FastifyInstance, FastifyRequest } from "fastify";
import { afterEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import { clientIp, ipKey } from "../src/identity/clientIp.js";
import type { DeviceIdentity, IdentityStore } from "../src/identity/store.js";

/**
 * The rate-limit identity of a request (security fix, 2026-09-06).
 *
 * The regression these guard is real and was reproduced against production:
 * with `trustProxy: true`, `request.ip` was the leftmost `X-Forwarded-For`
 * entry, so any client could mint itself an unlimited supply of fresh rate-limit
 * buckets by inventing a header value. The integration cases below drive a real
 * limiter through app.inject() and assert the two halves of the fix: a forged
 * X-Forwarded-For changes NOTHING, and the Fly-Proxy-set Fly-Client-IP is what
 * actually separates buckets.
 */

/** A minimal FastifyRequest for the unit cases — only the two fields we read. */
function fakeRequest(headers: Record<string, string | string[]>, ip = "10.0.0.1"): FastifyRequest {
  return { headers, ip } as unknown as FastifyRequest;
}

describe("clientIp", () => {
  it("prefers Fly-Client-IP (the proxy sets it from the real peer)", () => {
    expect(clientIp(fakeRequest({ "fly-client-ip": "203.0.113.7" }))).toBe("203.0.113.7");
  });

  it("falls back to the socket peer when Fly-Client-IP is absent", () => {
    expect(clientIp(fakeRequest({}, "198.51.100.4"))).toBe("198.51.100.4");
  });

  it("never reads X-Forwarded-For, however it is shaped", () => {
    const req = fakeRequest({ "x-forwarded-for": "10.9.8.1, 172.16.0.1" }, "198.51.100.4");
    expect(clientIp(req)).toBe("198.51.100.4");
  });

  it("ignores a blank or absurdly long Fly-Client-IP rather than keying on it", () => {
    // A too-long value isn't an address; letting it through would make the
    // bucket map's keys attacker-sized as well as attacker-chosen.
    expect(clientIp(fakeRequest({ "fly-client-ip": "   " }, "198.51.100.4"))).toBe("198.51.100.4");
    expect(clientIp(fakeRequest({ "fly-client-ip": "x".repeat(200) }, "198.51.100.4"))).toBe(
      "198.51.100.4",
    );
  });

  it("takes the first value of a repeated header (Fly sets exactly one)", () => {
    expect(clientIp(fakeRequest({ "fly-client-ip": ["203.0.113.7", "10.9.8.1"] }))).toBe(
      "203.0.113.7",
    );
  });

  it("prefixes the bucket key so IP and device keys can never collide", () => {
    expect(ipKey(fakeRequest({ "fly-client-ip": "203.0.113.7" }))).toBe("ip:203.0.113.7");
  });
});

describe("per-IP buckets are not client-controlled (end to end)", () => {
  let app: FastifyInstance | undefined;

  /** No DB: suggestions only needs `takenHandles`, and nothing is ever taken. */
  const identityStore: IdentityStore = {
    createDevice: async () => ({ id: "unused" }),
    findByTokenHash: async (): Promise<DeviceIdentity | null> => null,
    claimHandle: async () => ({ ok: true as const, handle: "unused" }),
    takenHandles: async () => new Set<string>(),
  };

  async function build(): Promise<FastifyInstance> {
    app = await buildApp({
      identityStore,
      // Frozen clock: no tokens ever refill, so "the 31st call" is exact.
      rateLimitNow: () => 0,
      handleCandidateGenerator: (n) => Array.from({ length: n }, (_, i) => `Pilot${i}`),
    });
    return app;
  }

  afterEach(async () => {
    await app?.close();
    app = undefined;
  });

  /** The anonymous, per-IP-limited endpoint used as the probe (30/min). */
  const SUGGESTIONS = "/v1/handles/suggestions";

  it("a spoofed X-Forwarded-For does NOT buy a fresh bucket", async () => {
    const a = await build();

    // Burn the 30/min bucket for this (single, real) peer.
    for (let i = 0; i < 30; i++) {
      const res = await a.inject({ method: "GET", url: SUGGESTIONS });
      expect(res.statusCode).toBe(200);
    }
    expect((await a.inject({ method: "GET", url: SUGGESTIONS })).statusCode).toBe(429);

    // The exact production bypass: invent an X-Forwarded-For, get a new bucket.
    // Every one of these must stay 429 — a different invented value each time,
    // so a limiter that keyed on the header would hand out 200s forever.
    for (const forged of ["10.9.8.1", "10.9.8.2", "1.1.1.1, 10.9.8.3", "not-an-ip"]) {
      const res = await a.inject({
        method: "GET",
        url: SUGGESTIONS,
        headers: { "x-forwarded-for": forged },
      });
      expect(res.statusCode, `X-Forwarded-For: ${forged}`).toBe(429);
      expect(res.headers["retry-after"]).toBeTruthy();
    }
  });

  it("Fly-Client-IP DOES key the bucket, so real peers stay independent", async () => {
    const a = await build();

    // Exhaust one Fly-observed client…
    for (let i = 0; i < 30; i++) {
      const res = await a.inject({
        method: "GET",
        url: SUGGESTIONS,
        headers: { "fly-client-ip": "203.0.113.7" },
      });
      expect(res.statusCode).toBe(200);
    }
    const denied = await a.inject({
      method: "GET",
      url: SUGGESTIONS,
      headers: { "fly-client-ip": "203.0.113.7" },
    });
    expect(denied.statusCode).toBe(429);

    // …a genuinely different client is unaffected (this is why we read the
    // header at all: without it every user behind Fly shares one bucket).
    const other = await a.inject({
      method: "GET",
      url: SUGGESTIONS,
      headers: { "fly-client-ip": "203.0.113.8" },
    });
    expect(other.statusCode).toBe(200);
  });
});
