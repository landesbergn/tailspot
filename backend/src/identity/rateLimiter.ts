/**
 * In-memory token-bucket rate limiter (WP 1.5).
 *
 * MULTI-INSTANCE CAVEAT (read this): the buckets live in this process's heap.
 * At beta scale we run a SINGLE Fly instance (see the plan's stack decisions),
 * so one process sees every request and the limits are exact. The moment we
 * scale to >1 instance the limits become per-instance — a client can get up to
 * N× the configured rate by spreading requests across N instances, and a device
 * pinned to one instance via sticky sessions gets a fresh bucket if it lands on
 * another. When that day comes, move this behind a shared store (Redis
 * INCR+EXPIRE, or Postgres). The interface (`take`) is intentionally narrow so
 * the backing store can be swapped without touching call sites.
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
}

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

  /**
   * @param config capacity + window.
   * @param now injectable clock (unix ms). Defaults to Date.now; tests pass a fake.
   */
  constructor(
    private readonly config: RateLimiterConfig,
    private readonly now: () => number = () => Date.now(),
  ) {
    this.refillPerMs = config.capacity / config.windowMs;
  }

  /**
   * Attempt to consume one token for `key`. A previously-unseen key starts with
   * a full bucket (so a device's first request is always allowed).
   */
  take(key: string): RateLimitResult {
    const t = this.now();
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
}
