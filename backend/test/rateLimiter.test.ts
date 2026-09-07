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

  /**
   * Memory bounds (hardening, 2026-09-06). The bucket map is keyed by client
   * IP — an attacker-chosen string — on a 256 MB VM, so "it only ever grows"
   * was a slow out-of-memory. Both defences run lazily inside `take` on the
   * injected clock, which is exactly why they are testable without timers.
   */
  describe("bucket eviction", () => {
    it("evicts buckets that have refilled to capacity", () => {
      const clk = fakeClock();
      // sweepEveryTakes: 3 makes the sweep observable without 1000 calls.
      const rl = new RateLimiter({ capacity: 2, windowMs: 1_000, sweepEveryTakes: 3 }, clk.now);
      rl.take("a");
      rl.take("b");
      expect(rl.size).toBe(2);

      // Both buckets refill completely over one window…
      clk.advance(5_000);
      // …and the next sweep (3rd take since the last one) drops them. The take
      // that triggers the sweep re-creates its own key, so one survives.
      rl.take("c");
      expect(rl.size).toBe(1);
    });

    it("evicting a full bucket cannot change an answer", () => {
      const clk = fakeClock();
      const rl = new RateLimiter({ capacity: 2, windowMs: 1_000, sweepEveryTakes: 1 }, clk.now);
      rl.take("k");
      rl.take("k"); // empty now
      expect(rl.take("k").allowed).toBe(false);

      clk.advance(1_000); // fully refilled → sweepable
      rl.take("other"); // triggers a sweep that drops "k"
      // A dropped-because-full bucket and a never-seen key are the same thing:
      // capacity fresh takes, then denial. No free tokens were handed out.
      expect(rl.take("k").allowed).toBe(true);
      expect(rl.take("k").allowed).toBe(true);
      expect(rl.take("k").allowed).toBe(false);
    });

    it("does NOT evict a bucket that is still draining", () => {
      const clk = fakeClock();
      const rl = new RateLimiter({ capacity: 10, windowMs: 60_000, sweepEveryTakes: 1 }, clk.now);
      for (let i = 0; i < 10; i++) rl.take("attacker"); // bucket empty
      clk.advance(6_000); // only 1 token back — nowhere near full
      rl.take("someone-else"); // sweeps
      // The attacker's bucket survived: it still owes 9 tokens.
      expect(rl.take("attacker").allowed).toBe(true); // the 1 refilled token
      expect(rl.take("attacker").allowed).toBe(false);
    });

    it("hard-caps the map, evicting oldest-first, under a spray of fresh keys", () => {
      const clk = fakeClock();
      const rl = new RateLimiter(
        // capacity 1 → every key stays non-full (un-sweepable) after its take,
        // so only the hard cap can bound this.
        { capacity: 1, windowMs: 60_000, sweepEveryTakes: 1_000, maxKeys: 10 },
        clk.now,
      );
      for (let i = 0; i < 500; i++) rl.take(`ip:${i}`);
      // The cap is enforced at the TOP of take(), so the map can be holding the
      // one key the current call just added when we look — bounded, which is
      // the whole point. Without the cap this would be 500 and climbing.
      expect(rl.size).toBeLessThanOrEqual(11);
      // The most recent key is the one that survived; the oldest is gone.
      expect(rl.take("ip:499").allowed).toBe(false); // still its own drained bucket
    });
  });
});
