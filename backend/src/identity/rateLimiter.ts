/**
 * In-memory token-bucket rate limiter (WP 1.5).
 *
 * MULTI-INSTANCE CAVEAT (read this): the buckets live in this process's heap.
 * We run TWO Fly machines (fly.toml: min_machines_running = 1, so one or two are
 * awake), which means the limits are PER MACHINE: a client spreading requests
 * across both gets up to 2× the configured rate, and a device can land on the
 * other machine and find a fresh bucket. That 2× is ACCEPTED at this scale —
 * these limits exist to stop runaway loops and cheap abuse, not to meter a paid
 * quota, and every limit below is set with the 2× in mind. (The header comment
 * used to claim a SINGLE instance; that stopped being true when we scaled to 2,
 * corrected 2026-09-06.) If we ever need exactness, move this behind a shared
 * store (Redis INCR+EXPIRE, or Postgres). The interface (`take`) is
 * intentionally narrow so the backing store can be swapped without touching
 * call sites.
 *
 * MEMORY BOUND: the bucket map is keyed by ATTACKER-CHOSEN strings (client IPs),
 * on a 256 MB VM. Left alone it only ever grows — a spray of requests from many
 * source addresses is a slow OOM. Two cheap defences, both below: buckets that
 * have refilled to capacity are evicted (a full bucket is indistinguishable from
 * a never-seen key, so dropping it changes NO behaviour), and the map is hard
 * capped at `maxKeys` with oldest-first eviction as the backstop. Both run
 * lazily inside `take`, on the injected clock, so there is no timer to leak in
 * tests and the whole thing stays deterministic.
 *
 * Token-bucket semantics: each key has a bucket that holds up to `capacity`
 * tokens and refills continuously at `capacity` tokens per `windowMs`. A request
 * `take(key)`s one token; granted when ≥1 is available, else denied with the
 * milliseconds until the next token refills (→ Retry-After). Continuous refill
 * (vs. a fixed window) avoids the boundary burst where a fixed window lets 2×
 * the limit through across a window edge.
 */

export interface RateLimiterConfig {
  /** Max tokens in the bucket (also the per-window allowance). */
  capacity: number;
  /** Window the capacity refills over, in milliseconds. */
  windowMs: number;
  /**
   * Sweep for refilled-to-full buckets once every N `take`s. Amortizes an O(n)
   * scan over N calls; the default keeps the scan rare while bounding how long
   * garbage can sit. Tests lower it to make the sweep observable.
   */
  sweepEveryTakes?: number;
  /**
   * Hard cap on distinct keys. Reached only under a deliberate spray (a normal
   * hour is thousands of IPs at most); past it we evict oldest-first, which can
   * hand an attacker a fresh bucket — accepted, because the alternative is
   * running the machine out of memory for everyone. Enforced at the top of
   * `take`, so the map can transiently hold one key over the cap.
   */
  maxKeys?: number;
}

/** Scan for evictable buckets every 1000 takes (see `sweepEveryTakes`). */
const DEFAULT_SWEEP_EVERY_TAKES = 1_000;

/**
 * 50k keys ≈ a few MB of Map overhead — comfortably survivable on the 256 MB VM
 * while being far above any honest traffic pattern.
 */
const DEFAULT_MAX_KEYS = 50_000;

/** The result of attempting to take a token. */
export interface RateLimitResult {
  allowed: boolean;
  /** When denied, whole seconds until a token is available (for Retry-After). 0 when allowed. */
  retryAfterSeconds: number;
}

interface Bucket {
  /** Fractional tokens currently available. */
  tokens: number;
  /** Last time (ms) the bucket was refilled. */
  lastRefillMs: number;
}

export class RateLimiter {
  private readonly buckets = new Map<string, Bucket>();
  private readonly refillPerMs: number;
  private readonly sweepEveryTakes: number;
  private readonly maxKeys: number;
  /** Takes since the last sweep; drives the amortized O(n) scan. */
  private takesSinceSweep = 0;

  /**
   * @param config capacity + window (+ optional eviction knobs).
   * @param now injectable clock (unix ms). Defaults to Date.now; tests pass a fake.
   */
  constructor(
    private readonly config: RateLimiterConfig,
    private readonly now: () => number = () => Date.now(),
  ) {
    this.refillPerMs = config.capacity / config.windowMs;
    this.sweepEveryTakes = config.sweepEveryTakes ?? DEFAULT_SWEEP_EVERY_TAKES;
    this.maxKeys = config.maxKeys ?? DEFAULT_MAX_KEYS;
  }

  /** How many buckets are currently held. Exposed for tests + future metrics. */
  get size(): number {
    return this.buckets.size;
  }

  /**
   * Attempt to consume one token for `key`. A previously-unseen key starts with
   * a full bucket (so a device's first request is always allowed).
   */
  take(key: string): RateLimitResult {
    const t = this.now();
    this.maybeEvict(t);
    let bucket = this.buckets.get(key);
    if (!bucket) {
      bucket = { tokens: this.config.capacity, lastRefillMs: t };
      this.buckets.set(key, bucket);
    } else {
      // Continuous refill since the last touch, capped at capacity.
      const elapsed = t - bucket.lastRefillMs;
      if (elapsed > 0) {
        bucket.tokens = Math.min(this.config.capacity, bucket.tokens + elapsed * this.refillPerMs);
        bucket.lastRefillMs = t;
      }
    }

    if (bucket.tokens >= 1) {
      bucket.tokens -= 1;
      return { allowed: true, retryAfterSeconds: 0 };
    }

    // Denied: time until the bucket reaches 1 token. Round UP so a client that
    // waits exactly Retry-After seconds is guaranteed to have a token.
    const deficit = 1 - bucket.tokens;
    const msUntilToken = deficit / this.refillPerMs;
    return { allowed: false, retryAfterSeconds: Math.max(1, Math.ceil(msUntilToken / 1000)) };
  }

  /**
   * Amortized garbage collection, called at the top of every `take`.
   *
   * Runs a full scan once per `sweepEveryTakes` calls (or immediately whenever
   * the map is over its cap, so a spray can't outrun the counter). The scan
   * drops every bucket that has refilled to capacity: such a bucket holds no
   * information — `take` gives a brand-new key a full bucket anyway — so
   * eviction is behaviour-preserving, and it means an idle key costs us memory
   * for at most one window plus one sweep interval.
   *
   * The hard cap is the backstop for the case the sweep can't help with: a
   * spray of DISTINCT keys arriving faster than they refill, all of them
   * legitimately non-full. There we evict oldest-first (Map iteration is
   * insertion order) — the honest cost is that a key can get an early fresh
   * bucket, which beats the machine dying.
   */
  private maybeEvict(nowMs: number): void {
    this.takesSinceSweep++;
    const over = this.buckets.size > this.maxKeys;
    if (!over && this.takesSinceSweep < this.sweepEveryTakes) return;
    this.takesSinceSweep = 0;

    for (const [key, bucket] of this.buckets) {
      const elapsed = nowMs - bucket.lastRefillMs;
      if (elapsed > 0 && bucket.tokens + elapsed * this.refillPerMs >= this.config.capacity) {
        this.buckets.delete(key);
      }
    }

    // Still over after the sweep → drop the oldest entries until we fit.
    // (Deleting during iteration of the same Map is well-defined in JS.)
    if (this.buckets.size > this.maxKeys) {
      for (const key of this.buckets.keys()) {
        if (this.buckets.size <= this.maxKeys) break;
        this.buckets.delete(key);
      }
    }
  }
}
