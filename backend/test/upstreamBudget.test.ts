import { describe, expect, it } from "vitest";
import { UpstreamBudget } from "../src/providers/upstreamBudget.js";

/** A clock the test moves by hand, and a sleep that advances it. */
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

describe("UpstreamBudget", () => {
  it("grants one request immediately, then refuses until the interval passes", () => {
    const clock = fakeTime();
    const budget = new UpstreamBudget({ ratePerSecond: 1, now: clock.now, sleep: clock.sleep });
    expect(budget.tryTake()).toBe(true);
    expect(budget.tryTake()).toBe(false);
    clock.advance(999);
    expect(budget.tryTake()).toBe(false);
    clock.advance(1);
    expect(budget.tryTake()).toBe(true);
    expect(budget.granted).toBe(2);
    expect(budget.refused).toBe(2);
  });

  it("never exceeds the rate over a long run of tryTake calls", () => {
    const clock = fakeTime();
    const budget = new UpstreamBudget({ ratePerSecond: 0.8, now: clock.now, sleep: clock.sleep });
    let granted = 0;
    // Hammer it every 100 ms for 60 s.
    for (let i = 0; i < 600; i++) {
      if (budget.tryTake()) granted++;
      clock.advance(100);
    }
    // 0.8/s for 60 s is 48, plus the first slot at t=0.
    expect(granted).toBeLessThanOrEqual(49);
    expect(granted).toBeGreaterThanOrEqual(47);
  });

  it("take() waits for the next slot when it is within maxWaitMs", async () => {
    const clock = fakeTime();
    const budget = new UpstreamBudget({ ratePerSecond: 1, now: clock.now, sleep: clock.sleep });
    expect(await budget.take(0)).toBe(true);
    expect(await budget.take(2000)).toBe(true);
    expect(clock.sleeps).toEqual([1000]);
  });

  it("take() refuses without reserving when the slot is too far away", async () => {
    const clock = fakeTime();
    const budget = new UpstreamBudget({ ratePerSecond: 1, now: clock.now, sleep: clock.sleep });
    expect(budget.tryTake()).toBe(true);
    expect(await budget.take(500)).toBe(false);
    // The refused call did not push the schedule out.
    clock.advance(1000);
    expect(budget.tryTake()).toBe(true);
  });

  it("queued waiters get slots in order and make tryTake yield to them", async () => {
    const clock = fakeTime();
    const budget = new UpstreamBudget({ ratePerSecond: 1, now: clock.now, sleep: async () => {} });
    expect(budget.tryTake()).toBe(true);
    // Two cold requests reserve the next two slots.
    const a = budget.take(5000);
    const b = budget.take(5000);
    await Promise.all([a, b]);
    // One second later the first waiter's slot has come; tryTake must not
    // jump ahead of the second waiter, whose slot is still a second away.
    clock.advance(1000);
    expect(budget.tryTake()).toBe(false);
  });

  it("take(intervalMs) waits out a near miss but not a queued waiter", async () => {
    const clock = fakeTime();
    const budget = new UpstreamBudget({ ratePerSecond: 1, now: clock.now, sleep: async () => {} });
    expect(budget.tryTake()).toBe(true);
    clock.advance(400);
    // The last request went out 400 ms ago: the next slot is 600 ms away.
    expect(await budget.take(budget.intervalMs)).toBe(true);
    // That caller now holds the next slot, so a second one would be two
    // slots out and is refused without reserving anything.
    expect(await budget.take(budget.intervalMs)).toBe(false);
    expect(budget.granted).toBe(2);
  });

  it("rejects a non-positive rate", () => {
    expect(() => new UpstreamBudget({ ratePerSecond: 0 })).toThrow();
    expect(() => new UpstreamBudget({ ratePerSecond: Number.NaN })).toThrow();
  });
});
