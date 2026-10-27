import { describe, expect, it } from "vitest";
import { UpstreamBudget } from "../src/providers/upstreamBudget.js";
import { manualClock } from "./helpers/manualClock.js";

/** A clock the test moves by hand, and a sleep that advances it on the spot. */
function fakeTime(start = 1_000_000) {
  let t = start;
  const sleeps: number[] = [];
  return {
    now: () => t,
    advance: (ms: number) => {
      t += ms;
    },
    sleep: async (ms: number) => {
      sleeps.push(ms);
      t += ms;
    },
    sleeps,
  };
}

function budgetOn(clock: { now: () => number; sleep: (ms: number) => Promise<void> }, rate = 1) {
  return new UpstreamBudget({ ratePerSecond: rate, now: clock.now, sleep: clock.sleep });
}

describe("UpstreamBudget", () => {
  it("grants one request immediately, then refuses a no-wait take until the interval passes", async () => {
    const clock = fakeTime();
    const budget = budgetOn(clock);
    expect(await budget.take(0)).toBe(true);
    expect(await budget.take(0)).toBe(false);
    clock.advance(999);
    expect(await budget.take(0)).toBe(false);
    clock.advance(1);
    expect(await budget.take(0)).toBe(true);
    expect(budget.granted).toBe(2);
    expect(budget.refused).toBe(2);
  });

  it("never exceeds the rate over a long run of no-wait takes", async () => {
    const clock = fakeTime();
    const budget = budgetOn(clock, 0.8);
    let granted = 0;
    // Hammer it every 100 ms for 60 s.
    for (let i = 0; i < 600; i++) {
      if (await budget.take(0)) granted++;
      clock.advance(100);
    }
    // 0.8/s for 60 s is 48, plus the first slot at t=0.
    expect(granted).toBeLessThanOrEqual(49);
    expect(granted).toBeGreaterThanOrEqual(47);
  });

  it("take() waits for the next slot when it is within maxWaitMs", async () => {
    const clock = fakeTime();
    const budget = budgetOn(clock);
    expect(await budget.take(0)).toBe(true);
    expect(await budget.take(2000)).toBe(true);
    expect(clock.sleeps).toEqual([1000]);
  });

  it("take() refuses without reserving when the slot is too far away", async () => {
    const clock = fakeTime();
    const budget = budgetOn(clock);
    expect(await budget.take(0)).toBe(true);
    expect(await budget.take(500)).toBe(false);
    // The refused call did not push the schedule out.
    clock.advance(1000);
    expect(await budget.take(0)).toBe(true);
  });

  it("take() serves queued callers in arrival order", async () => {
    const clock = manualClock();
    const budget = budgetOn(clock);
    expect(await budget.take(0)).toBe(true);
    const a = budget.take(5000);
    const b = budget.take(5000);
    expect(clock.parkedWaits()).toEqual([1000, 2000]);
    await clock.runAll();
    expect(await a).toBe(true);
    expect(await b).toBe(true);
  });

  describe("takeLowPriority", () => {
    it("waits out a near miss and takes the next slot", async () => {
      const clock = manualClock();
      const budget = budgetOn(clock);
      expect(await budget.take(0)).toBe(true);
      clock.advance(400);
      // The last request went out 400 ms ago: the next slot is 600 ms away.
      const refresh = budget.takeLowPriority(2000);
      expect(clock.parkedWaits()).toEqual([600]);
      await clock.runAll();
      expect(await refresh).toBe(true);
      expect(budget.granted).toBe(2);
    });

    it("serves several callers in arrival order, one slot each", async () => {
      // Review of #393: three tiles inside one slot window. When refreshes
      // aimed at the same unreserved slot, only the first ever won.
      const clock = manualClock();
      const budget = budgetOn(clock);
      expect(await budget.take(0)).toBe(true); // t0
      clock.advance(300);
      const second = budget.takeLowPriority(2000); // turn at t0+1000
      clock.advance(300);
      const third = budget.takeLowPriority(2000); // turn at t0+2000, 1.4 s away
      await clock.runAll();
      expect(await second).toBe(true);
      expect(await third).toBe(true);
      expect(budget.granted).toBe(3);
    });

    it("lets take() go first and gives up at once when that pushes its turn past the deadline", async () => {
      const clock = manualClock();
      const budget = budgetOn(clock);
      expect(await budget.take(0)).toBe(true); // next slot at t0+1000
      clock.advance(400);
      const refresh = budget.takeLowPriority(1500); // deadline t0+1900
      const cold = budget.take(2000); // reserves t0+1000; refresh's turn becomes t0+2000
      // The cold caller got the slot the refresh was waiting for...
      expect(clock.parkedWaits()).toContain(600);
      // ...and the refresh left the line straight away rather than waiting it out.
      expect(await refresh).toBe(false);
      await clock.runAll();
      expect(await cold).toBe(true);
      expect(budget.granted).toBe(2);
    });

    it("still gets a later slot when take() goes first but its deadline allows it", async () => {
      const clock = manualClock();
      const budget = budgetOn(clock);
      expect(await budget.take(0)).toBe(true);
      clock.advance(400);
      const refresh = budget.takeLowPriority(2000); // deadline t0+2400
      const cold = budget.take(2000); // takes t0+1000; refresh moves to t0+2000
      await clock.runAll();
      expect(await cold).toBe(true);
      expect(await refresh).toBe(true);
      expect(clock.now()).toBe(1_000_000_000 + 2000);
    });

    it("refuses at once when the line ahead already rules out its deadline", async () => {
      const clock = manualClock();
      const budget = budgetOn(clock);
      expect(await budget.take(0)).toBe(true);
      const first = budget.takeLowPriority(2000); // turn at +1000
      expect(await budget.takeLowPriority(1500)).toBe(false); // turn would be +2000
      expect(clock.parkedWaits()).toEqual([1000]); // only the first one waits
      await clock.runAll();
      expect(await first).toBe(true);
    });

    it("does not depend on timers firing exactly on time", async () => {
      // A sleep that wakes up to 30 ms early: the line looks again and waits
      // the remainder instead of refusing or jumping the gun.
      let t = 0;
      const budget = new UpstreamBudget({
        ratePerSecond: 1,
        now: () => t,
        sleep: async (ms) => {
          t += Math.max(1, ms - 30);
        },
      });
      expect(await budget.take(0)).toBe(true);
      t = 400;
      expect(await budget.takeLowPriority(2000)).toBe(true);
      expect(t).toBeGreaterThanOrEqual(1000);
    });
  });

  it("rejects a non-positive rate", () => {
    expect(() => new UpstreamBudget({ ratePerSecond: 0 })).toThrow();
    expect(() => new UpstreamBudget({ ratePerSecond: Number.NaN })).toThrow();
  });
});
