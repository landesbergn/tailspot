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

  it("takeIfStillFree waits out a near miss and takes the slot", async () => {
    const clock = fakeTime();
    const budget = new UpstreamBudget({ ratePerSecond: 1, now: clock.now, sleep: clock.sleep });
    expect(budget.tryTake()).toBe(true);
    clock.advance(400);
    // The last request went out 400 ms ago: the next slot is 600 ms away.
    expect(await budget.takeIfStillFree(1000)).toBe(true);
    expect(clock.sleeps).toEqual([600]);
    expect(budget.granted).toBe(2);
  });

  it("takeIfStillFree refuses at once when the next free slot is too far", async () => {
    const clock = fakeTime();
    const budget = new UpstreamBudget({ ratePerSecond: 1, now: clock.now, sleep: clock.sleep });
    expect(budget.tryTake()).toBe(true);
    expect(await budget.takeIfStillFree(500)).toBe(false);
    expect(clock.sleeps).toEqual([]);
  });

  it("takeIfStillFree gives way to a caller that reserves while it waits", async () => {
    // Sleeps that the test releases, so the two waits genuinely overlap.
    let t = 0;
    const sleepers: { ms: number; wake: () => void }[] = [];
    const budget = new UpstreamBudget({
      ratePerSecond: 1,
      now: () => t,
      sleep: (ms) =>
        new Promise<void>((resolve) => {
          const until = t + ms;
          sleepers.push({
            ms,
            wake: () => {
              t = Math.max(t, until);
              resolve();
            },
          });
        }),
    });
    expect(budget.tryTake()).toBe(true); // next slot at 1000
    t = 400;
    const refresh = budget.takeIfStillFree(1000); // waits for 1000, unreserved
    const cold = budget.take(2000); // reserves 1000 itself
    // The cold caller got the slot the refresh was waiting for, not the one after.
    expect(sleepers.map((s) => s.ms)).toEqual([600, 600]);
    for (const s of sleepers) s.wake();
    expect(await cold).toBe(true);
    expect(await refresh).toBe(false);
    expect(budget.granted).toBe(2);
  });

  it("rejects a non-positive rate", () => {
    expect(() => new UpstreamBudget({ ratePerSecond: 0 })).toThrow();
    expect(() => new UpstreamBudget({ ratePerSecond: Number.NaN })).toThrow();
  });
});
