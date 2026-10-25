import { describe, expect, it } from "vitest";
import { type ErrorRateAlert, ErrorRateAlerter } from "../src/monitoring/errorRate.js";

function setup() {
  let t = 0;
  const alerts: ErrorRateAlert[] = [];
  const alerter = new ErrorRateAlerter({ now: () => t, onAlert: (a) => alerts.push(a) });
  return {
    alerter,
    alerts,
    advance: (ms: number) => {
      t += ms;
    },
  };
}

describe("ErrorRateAlerter", () => {
  it("stays quiet below ten errors", () => {
    const s = setup();
    for (let i = 0; i < 9; i++) s.alerter.record(503, "/v1/aircraft");
    expect(s.alerts).toHaveLength(0);
  });

  it("stays quiet when errors are under 5% of traffic", () => {
    const s = setup();
    for (let i = 0; i < 400; i++) s.alerter.record(200, "/v1/aircraft");
    for (let i = 0; i < 12; i++) s.alerter.record(500, "/v1/catches");
    expect(s.alerts).toHaveLength(0);
  });

  it("alerts once with the worst routes first, then waits an hour", () => {
    const s = setup();
    for (let i = 0; i < 20; i++) s.alerter.record(200, "/v1/aircraft");
    for (let i = 0; i < 7; i++) s.alerter.record(503, "/v1/aircraft");
    for (let i = 0; i < 3; i++) s.alerter.record(500, "/v1/catches");
    expect(s.alerts).toHaveLength(1);
    expect(s.alerts[0]).toMatchObject({ errors: 10, total: 30 });
    expect(s.alerts[0]?.routes[0]).toEqual({ route: "/v1/aircraft", errors: 7 });
    for (let i = 0; i < 50; i++) s.alerter.record(503, "/v1/aircraft");
    expect(s.alerts).toHaveLength(1);
    s.advance(60 * 60_000);
    for (let i = 0; i < 10; i++) s.alerter.record(503, "/v1/aircraft");
    expect(s.alerts).toHaveLength(2);
  });

  it("forgets errors older than the five minute window", () => {
    const s = setup();
    for (let i = 0; i < 9; i++) s.alerter.record(503, "/v1/aircraft");
    s.advance(6 * 60_000);
    s.alerter.record(503, "/v1/aircraft");
    expect(s.alerts).toHaveLength(0);
  });
});
