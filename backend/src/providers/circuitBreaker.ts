import { type Bbox, type PositionProvider, type ProviderSnapshot, UpstreamError } from "./types.js";

/**
 * Circuit breaker around one position feed.
 *
 * WHY: without it, a failing feed is retried on every request. During an
 * adsb.fi outage each phone poll waited up to the 8 s timeout before the
 * fallback even started, and each retried 429 deepened the hole: adsb.fi's
 * terms count 4xx answers toward a temporary IP ban, and adsb.lol's 429s
 * all come out of the same 500-a-day quota.
 *
 * States:
 *   - CLOSED: requests pass through. A 429 or 403 opens the circuit at once
 *     (the upstream has said "stop"); any other failure opens it after
 *     `failureThreshold` failures in a row.
 *   - OPEN: requests fail immediately with CircuitOpenError, no network. The
 *     FallbackProvider then goes straight to the other feed.
 *   - HALF-OPEN: once the cooldown has passed, exactly one request is let
 *     through as a trial. Success closes the circuit; failure reopens it with
 *     the cooldown doubled (capped at `maxCooldownMs`).
 *
 * The cooldown is the upstream's own Retry-After when it sent one, clamped to
 * [`minCooldownMs`, `maxCooldownMs`]: a day-long adsb.lol reset still gets
 * re-tried every `maxCooldownMs`, which costs one request, not hundreds.
 */

export interface CircuitBreakerOptions {
  /** Consecutive non-429/403 failures that open the circuit. Default 3. */
  failureThreshold?: number;
  /** First cooldown after opening, when the upstream gave no Retry-After. Default 30 s. */
  baseCooldownMs?: number;
  /** Floor for any cooldown. Default 10 s. */
  minCooldownMs?: number;
  /** Ceiling for any cooldown, including doubled ones. Default 10 min. */
  maxCooldownMs?: number;
  /** Injectable clock (unix ms). */
  now?: () => number;
  /** Fired when the circuit opens (or re-opens after a failed trial). */
  onOpen?: (event: CircuitOpenEvent) => void;
  /** Fired when a trial succeeds and the circuit closes. */
  onClose?: (event: { provider: string; openForMs: number }) => void;
}

export interface CircuitOpenEvent {
  provider: string;
  /** How long until the next trial request (ms). */
  cooldownMs: number;
  /** The failure that opened it. */
  error: unknown;
  /** True when the upstream itself said stop (HTTP 429 or 403). */
  rejected: boolean;
}

/** The circuit is open: the feed was not called. */
export class CircuitOpenError extends UpstreamError {
  constructor(provider: string, retryInMs: number, lastError: unknown) {
    const why = lastError instanceof Error ? lastError.message : String(lastError);
    super(
      `${provider} circuit open, next try in ${Math.ceil(retryInMs / 1000)} s (after: ${why})`,
      lastError,
    );
    this.name = "CircuitOpenError";
  }
}

type State = "closed" | "open" | "half-open";

export class CircuitBreakerProvider implements PositionProvider {
  readonly name: string;
  private readonly failureThreshold: number;
  private readonly baseCooldownMs: number;
  private readonly minCooldownMs: number;
  private readonly maxCooldownMs: number;
  private readonly now: () => number;

  private state: State = "closed";
  private consecutiveFailures = 0;
  private openUntil = 0;
  private openedAt = 0;
  /** Cooldown used for the most recent opening; doubles on a failed trial. */
  private lastCooldownMs = 0;
  private lastError: unknown;

  constructor(
    private readonly inner: PositionProvider,
    private readonly options: CircuitBreakerOptions = {},
  ) {
    this.name = inner.name;
    this.failureThreshold = options.failureThreshold ?? 3;
    this.baseCooldownMs = options.baseCooldownMs ?? 30_000;
    this.minCooldownMs = options.minCooldownMs ?? 10_000;
    this.maxCooldownMs = options.maxCooldownMs ?? 10 * 60_000;
    this.now = options.now ?? Date.now;
  }

  /** Current state, for /readyz-style reporting and tests. */
  get currentState(): State {
    if (this.state === "open" && this.now() >= this.openUntil) return "half-open";
    return this.state;
  }

  async aircraftInBbox(bbox: Bbox): Promise<ProviderSnapshot> {
    const now = this.now();
    if (this.state === "half-open") {
      // A trial is already in flight; everyone else keeps failing fast.
      throw new CircuitOpenError(this.name, 0, this.lastError);
    }
    if (this.state === "open") {
      if (now < this.openUntil) {
        throw new CircuitOpenError(this.name, this.openUntil - now, this.lastError);
      }
      this.state = "half-open";
    }
    const trial = this.state === "half-open";

    let snapshot: ProviderSnapshot;
    try {
      snapshot = await this.inner.aircraftInBbox(bbox);
    } catch (err) {
      this.recordFailure(err, trial);
      throw err;
    }
    this.recordSuccess(trial);
    return snapshot;
  }

  private recordSuccess(trial: boolean): void {
    this.consecutiveFailures = 0;
    if (trial) {
      const openForMs = this.now() - this.openedAt;
      this.state = "closed";
      this.lastCooldownMs = 0;
      try {
        this.options.onClose?.({ provider: this.name, openForMs });
      } catch {
        /* a broken listener must not fail a good response */
      }
    }
  }

  private recordFailure(err: unknown, trial: boolean): void {
    this.lastError = err;
    const status = err instanceof UpstreamError ? err.status : undefined;
    const rejected = status === 429 || status === 403;
    this.consecutiveFailures++;
    if (!trial && !rejected && this.consecutiveFailures < this.failureThreshold) return;

    const asked =
      err instanceof UpstreamError && err.retryAfterSeconds !== undefined
        ? err.retryAfterSeconds * 1000
        : undefined;
    const backoff =
      trial && this.lastCooldownMs > 0 ? this.lastCooldownMs * 2 : this.baseCooldownMs;
    const cooldownMs = clamp(asked ?? backoff, this.minCooldownMs, this.maxCooldownMs);

    const now = this.now();
    if (this.state === "closed") this.openedAt = now;
    this.state = "open";
    this.openUntil = now + cooldownMs;
    this.lastCooldownMs = cooldownMs;
    try {
      this.options.onOpen?.({ provider: this.name, cooldownMs, error: err, rejected });
    } catch {
      /* a broken listener must not mask the upstream error */
    }
  }
}

function clamp(v: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, v));
}
