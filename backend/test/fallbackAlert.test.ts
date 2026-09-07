import { describe, expect, it } from "vitest";
import { FallbackProvider } from "../src/providers/fallback.js";
import {
  type SustainedFallbackAlert,
  SustainedFallbackAlerter,
} from "../src/providers/fallbackAlert.js";
import type { Bbox, PositionProvider, ProviderSnapshot } from "../src/providers/types.js";

const MINUTE = 60_000;

/**
 * The alerter has no timers — it evaluates on each event against an injected
 * clock — so every test here is just "move the clock, fire an event, assert".
 */
function harness(options: { sustainedForMs?: number; minIntervalMs?: number } = {}) {
  let now = 1_000_000;
  const alerts: SustainedFallbackAlert[] = [];
  const alerter = new SustainedFallbackAlerter({
    ...options,
    now: () => now,
    onAlert: (alert) => alerts.push(alert),
  });
  return {
    alerts,
    alerter,
    advance(ms: number) {
      now += ms;
    },
  };
}

describe("SustainedFallbackAlerter", () => {
  it("stays silent for a brief blip", () => {
    const { alerter, alerts, advance } = harness();
    alerter.recordFallback(new Error("boom"));
    advance(10_000);
    alerter.recordFallback(new Error("boom"));
    advance(10_000);
    alerter.recordRecovery();
    expect(alerts).toEqual([]);
  });

  it("alerts once the fallback has been engaged for more than 5 minutes", () => {
    const { alerter, alerts, advance } = harness();
    alerter.recordFallback(new Error("first"));
    advance(4 * MINUTE);
    alerter.recordFallback(new Error("still down"));
    expect(alerts).toEqual([]); // 4 min — not yet

    advance(2 * MINUTE);
    const err = new Error("still down at 6 min");
    alerter.recordFallback(err);
    expect(alerts).toHaveLength(1);
    expect(alerts[0]?.engagedForMs).toBe(6 * MINUTE);
    expect(alerts[0]?.primaryError).toBe(err); // the freshest error, for the alert body
  });

  it("rate-limits to one alert per hour through a long outage", () => {
    const { alerter, alerts, advance } = harness();
    alerter.recordFallback(new Error("down"));
    // Poll every 10 s for three hours, as the iOS clients actually would.
    for (let elapsed = 0; elapsed < 3 * 60 * MINUTE; elapsed += 10_000) {
      advance(10_000);
      alerter.recordFallback(new Error("down"));
    }
    expect(alerts).toHaveLength(3);
  });

  it("resets the clock when the primary serves again", () => {
    const { alerter, alerts, advance } = harness();
    alerter.recordFallback(new Error("down"));
    advance(4 * MINUTE);
    alerter.recordRecovery();

    // A new failure right after recovery starts from zero — the earlier four
    // minutes must not accumulate into an alert one minute later.
    alerter.recordFallback(new Error("down again"));
    advance(2 * MINUTE);
    alerter.recordFallback(new Error("down again"));
    expect(alerts).toEqual([]);
  });

  it("does not re-arm the hourly limit on recovery (one flapping incident, one alert)", () => {
    const { alerter, alerts, advance } = harness();
    // Sustain past the threshold to spend the first alert.
    alerter.recordFallback(new Error("down"));
    advance(6 * MINUTE);
    alerter.recordFallback(new Error("down"));
    expect(alerts).toHaveLength(1);

    // Now flap: recover, fail, sustain 6 min, repeatedly, all inside the hour.
    for (let i = 0; i < 5; i++) {
      alerter.recordRecovery();
      alerter.recordFallback(new Error("down"));
      advance(6 * MINUTE);
      alerter.recordFallback(new Error("down"));
    }
    expect(alerts).toHaveLength(1);
  });

  it("reports engagement state", () => {
    const { alerter } = harness();
    expect(alerter.isEngaged).toBe(false);
    alerter.recordFallback(new Error("down"));
    expect(alerter.isEngaged).toBe(true);
    alerter.recordRecovery();
    expect(alerter.isEngaged).toBe(false);
  });

  it("honours custom thresholds", () => {
    const { alerter, alerts, advance } = harness({ sustainedForMs: 1_000, minIntervalMs: 5_000 });
    alerter.recordFallback(new Error("down"));
    advance(1_500);
    alerter.recordFallback(new Error("down"));
    advance(1_500);
    alerter.recordFallback(new Error("down")); // inside the 5 s rate limit
    expect(alerts).toHaveLength(1);
    advance(5_000);
    alerter.recordFallback(new Error("down"));
    expect(alerts).toHaveLength(2);
  });
});

/** Stub provider that flips between throwing and succeeding on demand. */
function flakyPrimary() {
  let failing = false;
  const provider: PositionProvider = {
    name: "primary",
    async aircraftInBbox(): Promise<ProviderSnapshot> {
      if (failing) throw new Error("primary down");
      return { fetchedAt: 1, aircraft: [] };
    },
  };
  return {
    provider,
    fail() {
      failing = true;
    },
    heal() {
      failing = false;
    },
  };
}

const BBOX: Bbox = { lamin: 37, lomin: -123, lamax: 38, lomax: -122 };

describe("FallbackProvider onRecovered", () => {
  const secondary: PositionProvider = {
    name: "secondary",
    async aircraftInBbox() {
      return { fetchedAt: 2, aircraft: [] };
    },
  };

  it("fires on the first primary success after a fallback, and only then", async () => {
    const primary = flakyPrimary();
    const events: string[] = [];
    const fallback = new FallbackProvider(primary.provider, secondary, {
      onFallback: () => events.push("fallback"),
      onRecovered: () => events.push("recovered"),
    });

    await fallback.aircraftInBbox(BBOX); // healthy — no events
    primary.fail();
    await fallback.aircraftInBbox(BBOX);
    await fallback.aircraftInBbox(BBOX);
    primary.heal();
    await fallback.aircraftInBbox(BBOX); // the recovery edge
    await fallback.aircraftInBbox(BBOX); // still healthy — silent

    expect(events).toEqual(["fallback", "fallback", "recovered"]);
  });

  it("never fires for a provider that has always been healthy", async () => {
    const events: string[] = [];
    const fallback = new FallbackProvider(flakyPrimary().provider, secondary, {
      onRecovered: () => events.push("recovered"),
    });
    await fallback.aircraftInBbox(BBOX);
    await fallback.aircraftInBbox(BBOX);
    expect(events).toEqual([]);
  });
});
