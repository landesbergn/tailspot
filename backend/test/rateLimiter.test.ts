import { describe, expect, it } from "vitest";
import { RateLimiter } from "../src/identity/rateLimiter.js";

/**
 * Unit tests for the token-bucket RateLimiter with a FAKE clock — no real time
 * passes, so the suite is deterministic and instant.
 */
describe("RateLimiter (fake clock)", () => {
  /** A controllable clock: `now` is mutable; tests advance it explicitly. */
  function fakeClock() {
    const state = { ms: 0 };
    function advance(ms: number) {
      state.ms += ms;
    }
    return { now: () => state.ms, advance, state };
  }

  it("allows up to capacity, then denies", () => {
    const clk = fakeClock();
    const rl = new RateLimiter({ capacity: 3, windowMs: 60_000 }, clk.now);
    expect(rl.take("k").allowed).toBe(true);
    expect(rl.take("k").allowed).toBe(true);
    expect(rl.take("k").allowed).toBe(true);
    const denied = rl.take("k");
    expect(denied.allowed).toBe(false);
    expect(denied.retryAfterSeconds).toBeGreaterThan(0);
  });

  it("keys are independent buckets", () => {
    const clk = fakeClock();
    const rl = new RateLimiter({ capacity: 1, windowMs: 60_000 }, clk.now);
    expect(rl.take("a").allowed).toBe(true);
    expect(rl.take("a").allowed).toBe(false);
    // A different key still has a full bucket.
    expect(rl.take("b").allowed).toBe(true);
  });

  it("refills continuously over the window", () => {
    const clk = fakeClock();
    // 60 tokens / 60s = 1 token/sec.
    const rl = new RateLimiter({ capacity: 60, windowMs: 60_000 }, clk.now);
    for (let i = 0; i < 60; i++) expect(rl.take("k").allowed).toBe(true);
    expect(rl.take("k").allowed).toBe(false); // empty
    clk.advance(1_000); // 1s → 1 token back
    expect(rl.take("k").allowed).toBe(true);
    expect(rl.take("k").allowed).toBe(false); // and empty again
  });

  it("never overfills past capacity after a long idle", () => {
    const clk = fakeClock();
    const rl = new RateLimiter({ capacity: 2, windowMs: 1_000 }, clk.now);
    rl.take("k"); // 1 left
    clk.advance(10_000); // idle 10× the window
    // Bucket caps at capacity (2), not 1 + 10 windows' worth.
    expect(rl.take("k").allowed).toBe(true);
    expect(rl.take("k").allowed).toBe(true);
    expect(rl.take("k").allowed).toBe(false);
  });

  it("retryAfter is whole seconds, at least 1, and waiting that long unblocks", () => {
    const clk = fakeClock();
    const rl = new RateLimiter({ capacity: 1, windowMs: 10_000 }, clk.now); // 1 per 10s
    expect(rl.take("k").allowed).toBe(true);
    const denied = rl.take("k");
    expect(denied.allowed).toBe(false);
    expect(denied.retryAfterSeconds).toBe(10);
    clk.advance(denied.retryAfterSeconds * 1_000);
    expect(rl.take("k").allowed).toBe(true);
  });
});
