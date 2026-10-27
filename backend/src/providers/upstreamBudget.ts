/**
 * Backend-wide request budget for the position feed.
 *
 * WHY: adsb.fi (primary since 2026-10-20) allows 1 request per second per IP,
 * and its terms say 4xx answers count toward a temporary IP ban. The tile
 * cache makes at most one fetch per tile per 10 s, but nothing capped the
 * number of TILES: ten phones in ten different places is already 1 req/s, and
 * the eleventh tips us into 429s, then a ban, then the adsb.lol fallback,
 * whose 500-a-day quota lasts about an hour. This class is the cap.
 *
 * HOW: a token bucket of capacity 1 implemented as "virtual scheduling"
 * (GCRA): `nextFreeAt` is the earliest moment the next request may go out.
 * Every grant pushes it one interval further, so the long-run rate never
 * exceeds `ratePerSecond` and there are no bursts (capacity 1), which is how a
 * "1 req/s" limit is usually enforced.
 *
 * Two classes of caller share the slots:
 *   - `take()` is for callers with nothing to fall back on (a cold tile). It
 *     reserves the next free slot on the spot, so these are served in arrival
 *     order, ahead of everything in the line below.
 *   - `takeLowPriority()` is for callers that can make do without (a tile
 *     refresh can serve its cache). They join a FIFO line that gets each slot
 *     nobody reserved, and leave it with `false` once they can no longer be
 *     served within their wait. A refresh is never starved by a near miss
 *     with another request, and never pushes a cold tile back.
 *
 * The 2026-10-26 lesson: refreshes used to take a slot only if one was free
 * that instant. Phones polling on the same 10 s rhythm less than a slot apart
 * collided on every poll, and the later tile refreshed only every 30 s.
 *
 * The budget covers whichever feed answers: it is checked before the
 * composite provider runs, so a request that fails over to adsb.lol spends the
 * same slot. adsb.lol allows 60 a minute, so the adsb.fi rate keeps it legal
 * too.
 *
 * Per process: two Fly machines would each get the full rate. The second
 * machine only starts under 100 concurrent requests (fly.toml), and the
 * circuit breaker backs off on any 429, so the overshoot is bounded.
 */

export interface UpstreamBudgetOptions {
  /** Requests per second. Default 0.8, under adsb.fi's 1/s with headroom. */
  ratePerSecond?: number;
  /** Injectable clock (unix ms). */
  now?: () => number;
  /** Injectable sleep, so tests can resolve waits without real time. */
  sleep?: (ms: number) => Promise<void>;
}

export const DEFAULT_UPSTREAM_RATE_PER_SECOND = 0.8;

interface LowPriorityWaiter {
  /** Latest unix ms at which this waiter may still be granted a slot. */
  deadline: number;
  resolve: (granted: boolean) => void;
}

export class UpstreamBudget {
  readonly intervalMs: number;
  private readonly now: () => number;
  private readonly sleep: (ms: number) => Promise<void>;
  /** Earliest unix ms at which the next request may be sent. */
  private nextFreeAt = Number.NEGATIVE_INFINITY;
  private grantedCount = 0;
  private refusedCount = 0;
  /** The low-priority line, oldest first. */
  private readonly line: LowPriorityWaiter[] = [];
  /** True while a wake-up for the line is pending. */
  private pumpPending = false;

  constructor(options: UpstreamBudgetOptions = {}) {
    const rate = options.ratePerSecond ?? DEFAULT_UPSTREAM_RATE_PER_SECOND;
    if (!(rate > 0) || !Number.isFinite(rate)) {
      throw new Error(`UpstreamBudget rate must be a positive number, got ${rate}`);
    }
    this.intervalMs = 1000 / rate;
    this.now = options.now ?? Date.now;
    this.sleep = options.sleep ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
  }

  /** Requests granted since start (for logs and tests). */
  get granted(): number {
    return this.grantedCount;
  }

  /** Requests refused since start (for logs and tests). */
  get refused(): number {
    return this.refusedCount;
  }

  /**
   * Take the next free slot, waiting up to `maxWaitMs` for it. Resolves true
   * once the slot has arrived, false (without reserving anything) when the
   * next slot is further away than `maxWaitMs`. Goes ahead of the
   * low-priority line.
   */
  async take(maxWaitMs: number): Promise<boolean> {
    const delay = this.reserve(maxWaitMs);
    if (delay === undefined) return false;
    // This reservation may have pushed someone in the line past their deadline.
    this.dropUnreachable(this.now());
    if (delay > 0) await this.sleep(delay);
    return true;
  }

  /**
   * Join the low-priority line and resolve true when a slot nobody reserved
   * comes up within `maxWaitMs`, false otherwise. Refuses at once when the
   * line ahead already makes `maxWaitMs` unreachable, and leaves the line as
   * soon as `take()` callers push its turn past the deadline, so a caller
   * that loses does not also wait out its full allowance.
   */
  takeLowPriority(maxWaitMs: number): Promise<boolean> {
    const now = this.now();
    // Clear out anyone already out of reach first, so they don't count against us.
    this.dropUnreachable(now);
    const turnAt = Math.max(now, this.nextFreeAt) + this.line.length * this.intervalMs;
    if (turnAt - now > maxWaitMs) {
      this.refusedCount++;
      return Promise.resolve(false);
    }
    return new Promise((resolve) => {
      this.line.push({ deadline: now + maxWaitMs, resolve });
      this.pump();
    });
  }

  /**
   * Settle the line: drop waiters whose turn now falls past their deadline,
   * grant the head if a slot is free, and otherwise sleep until the next
   * free slot and look again. Waking early or finding the slot taken just
   * means looking again, so no timer precision is assumed.
   */
  private pump(): void {
    if (this.pumpPending) return;
    for (;;) {
      const now = this.now();
      this.dropUnreachable(now);
      const head = this.line[0];
      if (!head) return;
      if (this.nextFreeAt > now) {
        this.pumpPending = true;
        // Whatever happens to the sleep, the line must be looked at again, or
        // everyone in it would wait forever.
        void this.sleep(this.nextFreeAt - now)
          .catch(() => {})
          .then(() => {
            this.pumpPending = false;
            this.pump();
          });
        return;
      }
      this.line.shift();
      this.reserve(0);
      head.resolve(true);
    }
  }

  /** Resolve false for every waiter whose turn now falls past its deadline. */
  private dropUnreachable(now: number): void {
    let turnAt = Math.max(now, this.nextFreeAt);
    for (let i = 0; i < this.line.length; ) {
      const waiter = this.line[i];
      if (turnAt > waiter.deadline) {
        this.line.splice(i, 1);
        this.refusedCount++;
        waiter.resolve(false);
      } else {
        turnAt += this.intervalMs;
        i++;
      }
    }
  }

  /**
   * Reserve the next slot if it starts within `maxWaitMs`. Returns the wait
   * in ms (0 = go now), or undefined when refused.
   */
  private reserve(maxWaitMs: number): number | undefined {
    const now = this.now();
    const slot = Math.max(now, this.nextFreeAt);
    const delay = slot - now;
    if (delay > maxWaitMs) {
      this.refusedCount++;
      return undefined;
    }
    this.nextFreeAt = slot + this.intervalMs;
    this.grantedCount++;
    return delay;
  }
}
