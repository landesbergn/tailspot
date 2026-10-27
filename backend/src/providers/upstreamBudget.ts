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
 * Every grant pushes it one interval further. That gives three properties
 * with no timers and no queue data structure:
 *   - the long-run rate never exceeds `ratePerSecond`, and there are no
 *     bursts (capacity 1), which is how a "1 req/s" limit is usually enforced;
 *   - waiters are served in arrival order, because each reservation takes the
 *     next free slot;
 *   - a caller can cap its wait: `take(intervalMs)` waits out a request that
 *     has just gone out but refuses once anyone else is already waiting,
 *     because a waiter has pushed `nextFreeAt` more than one interval out. A
 *     tile refresh, which can make do with its cache, waits that way, so it
 *     yields to cold tiles under load without losing to a mere near miss.
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

export class UpstreamBudget {
  readonly intervalMs: number;
  private readonly now: () => number;
  private readonly sleep: (ms: number) => Promise<void>;
  /** Earliest unix ms at which the next request may be sent. */
  private nextFreeAt = Number.NEGATIVE_INFINITY;
  private grantedCount = 0;
  private refusedCount = 0;

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

  /** Take a slot only if one is free right now. Never waits. */
  tryTake(): boolean {
    return this.reserve(0) === 0;
  }

  /**
   * Take the next free slot, waiting up to `maxWaitMs` for it. Resolves true
   * once the slot has arrived, false (without reserving anything) when the
   * next slot is further away than `maxWaitMs`.
   */
  async take(maxWaitMs: number): Promise<boolean> {
    const delay = this.reserve(maxWaitMs);
    if (delay === undefined) return false;
    if (delay > 0) await this.sleep(delay);
    return true;
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
