import type { ErrorEvent } from "@sentry/node";
import { describe, expect, it } from "vitest";
import { scrubEvent } from "../src/instrument.js";

/**
 * These assert the LAST line of defence before an event leaves the process.
 * Importing instrument.ts runs its module body, which is safe here: with no
 * SENTRY_DSN in the test env it takes the "disabled" branch and calls no init.
 */
function event(request: ErrorEvent["request"]): ErrorEvent {
  return { type: undefined, request } as ErrorEvent;
}

describe("scrubEvent", () => {
  it("redacts the authorization header whatever case the client sent", () => {
    for (const name of ["authorization", "Authorization", "AUTHORIZATION"]) {
      const scrubbed = scrubEvent(
        event({ headers: { [name]: "Bearer tsp_live_secret", "user-agent": "Tailspot/1.1.0" } }),
      );
      expect(scrubbed.request?.headers?.[name]).toBe("[redacted]");
      // Everything else survives — the point is to keep the event useful.
      expect(scrubbed.request?.headers?.["user-agent"]).toBe("Tailspot/1.1.0");
      expect(JSON.stringify(scrubbed)).not.toContain("tsp_live_secret");
    }
  });

  it("redacts the observer coordinates from a catch body but keeps the rest", () => {
    const scrubbed = scrubEvent(
      event({
        data: {
          icao24: "a1b2c3",
          caughtAt: 1_780_000_000,
          observer: { lat: 37.8715, lon: -122.273, headingDeg: 190 },
        },
      }),
    );
    const data = scrubbed.request?.data as Record<string, unknown>;
    expect(data.observer).toBe("[redacted: observer coordinates]");
    expect(data.icao24).toBe("a1b2c3");
    expect(JSON.stringify(scrubbed)).not.toContain("37.87");
    expect(JSON.stringify(scrubbed)).not.toContain("-122.27");
  });

  it("leaves events without request data alone", () => {
    expect(() => scrubEvent(event(undefined))).not.toThrow();
    expect(scrubEvent(event({ data: "raw string body" })).request?.data).toBe("raw string body");
    expect(scrubEvent(event({ headers: {} })).request?.headers).toEqual({});
  });
});
