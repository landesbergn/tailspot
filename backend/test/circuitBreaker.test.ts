import { describe, expect, it } from "vitest";
import { retryAfterSeconds } from "../src/providers/adsblol.js";
import {
  CircuitBreakerProvider,
  CircuitOpenError,
  type CircuitOpenEvent,
} from "../src/providers/circuitBreaker.js";
import { FallbackProvider } from "../src/providers/fallback.js";
import {
  type Bbox,
  type PositionProvider,
  type ProviderSnapshot,
  UpstreamError,
} from "../src/providers/types.js";

const BBOX: Bbox = { lamin: 37.5, lomin: -122.5, lamax: 38, lomax: -122 };

class ScriptedProvider implements PositionProvider {
  calls = 0;
  /** Each entry is the next outcome; the last repeats. */
  constructor(
    readonly name: string,
    private readonly outcomes: Array<"ok" | UpstreamError | Error>,
  ) {}
  async aircraftInBbox(): Promise<ProviderSnapshot> {
    const outcome = this.outcomes[Math.min(this.calls, this.outcomes.length - 1)];
    this.calls++;
    if (outcome === "ok") return { fetchedAt: 1, aircraft: [], provider: this.name };
    throw outcome;
  }
}

const http = (status: number, retryAfter?: number) =>
  new UpstreamError(`HTTP ${status}`, undefined, { status, retryAfterSeconds: retryAfter });

function harness(inner: ScriptedProvider, opts: { failureThreshold?: number } = {}) {
  let t = 0;
  const opened: CircuitOpenEvent[] = [];
  const closed: number[] = [];
  const breaker = new CircuitBreakerProvider(inner, {
    ...opts,
    now: () => t,
    onOpen: (e) => opened.push(e),
    onClose: (e) => closed.push(e.openForMs),
  });
  return {
    breaker,
    opened,
    closed,
    advance: (ms: number) => {
      t += ms;
    },
  };
}

describe("CircuitBreakerProvider", () => {
  it("passes successes through and keeps the inner name", async () => {
    const inner = new ScriptedProvider("adsbfi", ["ok"]);
    const { breaker } = harness(inner);
    expect(breaker.name).toBe("adsbfi");
    await breaker.aircraftInBbox(BBOX);
    await breaker.aircraftInBbox(BBOX);
    expect(inner.calls).toBe(2);
    expect(breaker.currentState).toBe("closed");
  });

  it("opens at once on a 429 and honours Retry-After", async () => {
    const inner = new ScriptedProvider("adsbfi", [http(429, 120), "ok"]);
    const { breaker, opened, advance } = harness(inner);
    await expect(breaker.aircraftInBbox(BBOX)).rejects.toThrow("HTTP 429");
    expect(opened).toHaveLength(1);
    expect(opened[0]?.rejected).toBe(true);
    expect(opened[0]?.cooldownMs).toBe(120_000);
    // While open, the feed is not called.
    await expect(breaker.aircraftInBbox(BBOX)).rejects.toBeInstanceOf(CircuitOpenError);
    expect(inner.calls).toBe(1);
    advance(119_999);
    await expect(breaker.aircraftInBbox(BBOX)).rejects.toBeInstanceOf(CircuitOpenError);
    advance(1);
    await breaker.aircraftInBbox(BBOX);
    expect(inner.calls).toBe(2);
    expect(breaker.currentState).toBe("closed");
  });

  it("opens on a 403 without a Retry-After using the base cooldown", async () => {
    const inner = new ScriptedProvider("airplaneslive", [http(403)]);
    const { breaker, opened } = harness(inner);
    await expect(breaker.aircraftInBbox(BBOX)).rejects.toThrow();
    expect(opened[0]?.cooldownMs).toBe(30_000);
  });

  it("clamps a day-long Retry-After to the 10 minute ceiling", async () => {
    const inner = new ScriptedProvider("adsblol", [http(429, 40_000)]);
    const { breaker, opened } = harness(inner);
    await expect(breaker.aircraftInBbox(BBOX)).rejects.toThrow();
    expect(opened[0]?.cooldownMs).toBe(600_000);
  });

  it("tolerates isolated timeouts and opens after three in a row", async () => {
    const timeout = new UpstreamError("adsbfi request failed");
    const inner = new ScriptedProvider("adsbfi", [timeout, "ok", timeout, timeout, timeout]);
    const { breaker, opened } = harness(inner);
    await expect(breaker.aircraftInBbox(BBOX)).rejects.toThrow();
    await breaker.aircraftInBbox(BBOX); // resets the streak
    await expect(breaker.aircraftInBbox(BBOX)).rejects.toThrow();
    await expect(breaker.aircraftInBbox(BBOX)).rejects.toThrow();
    expect(opened).toHaveLength(0);
    await expect(breaker.aircraftInBbox(BBOX)).rejects.toThrow("request failed");
    expect(opened).toHaveLength(1);
    expect(opened[0]?.rejected).toBe(false);
  });

  it("lets exactly one trial through when half-open, and doubles the cooldown if it fails", async () => {
    let release: () => void = () => {};
    const gate = new Promise<void>((r) => {
      release = r;
    });
    const fails = http(500);
    let calls = 0;
    const inner: PositionProvider = {
      name: "adsbfi",
      async aircraftInBbox() {
        calls++;
        if (calls === 1) throw http(429);
        await gate;
        throw fails;
      },
    };
    let t = 0;
    const opened: CircuitOpenEvent[] = [];
    const breaker = new CircuitBreakerProvider(inner, {
      now: () => t,
      onOpen: (e) => opened.push(e),
    });
    await expect(breaker.aircraftInBbox(BBOX)).rejects.toThrow();
    t += 30_000;
    const trial = breaker.aircraftInBbox(BBOX);
    // A second caller during the trial fails fast without calling the feed.
    await expect(breaker.aircraftInBbox(BBOX)).rejects.toBeInstanceOf(CircuitOpenError);
    expect(calls).toBe(2);
    release();
    await expect(trial).rejects.toThrow("HTTP 500");
    expect(opened.map((e) => e.cooldownMs)).toEqual([30_000, 60_000]);
  });

  it("reports how long it was open when a trial succeeds", async () => {
    const inner = new ScriptedProvider("adsbfi", [http(429), "ok"]);
    const { breaker, closed, advance } = harness(inner);
    await expect(breaker.aircraftInBbox(BBOX)).rejects.toThrow();
    advance(45_000);
    await breaker.aircraftInBbox(BBOX);
    expect(closed).toEqual([45_000]);
  });

  it("sends the fallback straight to the secondary while the primary is open", async () => {
    const primary = new ScriptedProvider("adsbfi", [http(429)]);
    const secondary = new ScriptedProvider("adsblol", ["ok"]);
    const composite = new FallbackProvider(new CircuitBreakerProvider(primary), secondary);
    for (let i = 0; i < 5; i++) {
      const snap = await composite.aircraftInBbox(BBOX);
      expect(snap.provider).toBe("adsblol");
    }
    expect(primary.calls).toBe(1);
    expect(secondary.calls).toBe(5);
  });
});

describe("retryAfterSeconds", () => {
  const h = (init: Record<string, string>) => new Headers(init);
  it("reads delta-seconds Retry-After", () => {
    expect(retryAfterSeconds(h({ "retry-after": "42" }))).toBe(42);
  });
  it("reads an HTTP-date Retry-After", () => {
    const now = Date.parse("2026-10-21T12:00:00Z");
    expect(retryAfterSeconds(h({ "retry-after": "Wed, 21 Oct 2026 12:01:30 GMT" }), now)).toBe(90);
  });
  it("falls back to the longest RateLimit reset", () => {
    expect(retryAfterSeconds(h({ "x-ratelimit-reset": "1, 60, 41000" }))).toBe(41000);
    expect(retryAfterSeconds(h({ "ratelimit-reset": "17" }))).toBe(17);
  });
  it("treats an epoch reset as a time to wait until", () => {
    const now = 1_792_000_000_000;
    expect(retryAfterSeconds(h({ "x-ratelimit-reset": "1792000300" }), now)).toBe(300);
  });
  it("is undefined when nothing usable is present", () => {
    expect(retryAfterSeconds(h({}))).toBeUndefined();
    expect(retryAfterSeconds(h({ "x-ratelimit-reset": "soon" }))).toBeUndefined();
  });
});
