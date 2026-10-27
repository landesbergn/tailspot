/**
 * Test helper: a clock the test moves by hand, for `UpstreamBudget`.
 *
 * `sleep` parks each wait until the test steps the clock, so several waits
 * genuinely overlap, which a sleep that advances the clock on the spot can't
 * show. `step()` moves the clock to the earliest parked wake-up, wakes every
 * wait due then, and lets their callbacks run before returning.
 */
export function manualClock(start = 1_000_000_000) {
  let t = start;
  const parked: { ms: number; until: number; resolve: () => void }[] = [];
  const flush = () => new Promise<void>((resolve) => setImmediate(resolve));
  const step = async (): Promise<boolean> => {
    if (parked.length === 0) return false;
    const until = Math.min(...parked.map((p) => p.until));
    t = Math.max(t, until);
    for (let i = 0; i < parked.length; ) {
      if (parked[i].until <= t) parked.splice(i, 1)[0].resolve();
      else i++;
    }
    await flush();
    return true;
  };
  return {
    now: () => t,
    advance: (ms: number) => {
      t += ms;
    },
    sleep: (ms: number) =>
      new Promise<void>((resolve) => {
        parked.push({ ms, until: t + ms, resolve });
      }),
    /** Lengths of the waits parked right now, in the order they started. */
    parkedWaits: () => parked.map((p) => p.ms),
    step,
    /** Step until nothing is parked (bounded, so a spin fails loudly). */
    runAll: async () => {
      for (let i = 0; i < 1_000; i++) if (!(await step())) return;
      throw new Error("manualClock: waits never settled");
    },
  };
}
