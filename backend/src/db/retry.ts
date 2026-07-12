/**
 * Transient-connection retry for idempotent database work.
 *
 * Pooled Postgres connections get closed out from under us: Fly's `.flycast`
 * proxy and the Postgres server both drop idle TCP connections, and postgres.js
 * can hand a stale one to a query before it notices the socket is dead. The
 * in-flight query then fails with a connection-level error (CONNECTION_CLOSED /
 * CONNECTION_DESTROYED / ECONNRESET / CONNECT_TIMEOUT / …) even though the
 * database is healthy — the same query on a fresh connection succeeds.
 * postgres.js deliberately does NOT retry an in-flight query itself (it can't
 * prove the server didn't already apply it), so we retry at the application
 * layer — but ONLY for work we know is idempotent. See Sentry
 * BROKEN-DARKNESS-5055-3.
 *
 * The `idle_timeout` / `max_lifetime` settings in `client.ts` make this rare by
 * recycling connections before the proxy kills them; this helper covers the
 * residual race where a connection is dropped between checks.
 *
 * **The retries back off** (see {@link defaultBackoffMs}) — this matters. The
 * first `-3` fix retried *immediately*, and an ECONNRESET still surfaced (Sentry
 * BROKEN-DARKNESS-5055-5/-7). postgres.js only begins reconnecting a dead socket
 * ~15–30ms after it closes, and a DB-wide blip (a Fly `.flycast` recycle, a
 * Postgres restart/OOM) drops several of the pool's connections at once — so an
 * *immediate* retry just grabs another still-dead socket and every attempt
 * exhausts in the same sub-millisecond window. A short jittered wait lets the
 * pool notice the dead sockets and open a fresh one before we try again. (It
 * still can't paper over a multi-second outage — nothing at this layer can; that
 * is a DB-capacity problem, not a retry problem.)
 */

/**
 * postgres.js connection-error codes plus the raw Node socket codes they wrap.
 * Every one means "the connection died", never "the server rejected this
 * query" — so re-running the same statement on a fresh connection is safe.
 * (A real query error — bad SQL, a constraint violation — has a Postgres
 * SQLSTATE code instead and is NOT in this set, so it rethrows immediately.)
 */
const TRANSIENT_CONNECTION_CODES = new Set([
  "CONNECTION_CLOSED",
  "CONNECTION_DESTROYED",
  "CONNECTION_ENDED",
  "CONNECT_TIMEOUT",
  "ECONNRESET",
  "EPIPE",
]);

/**
 * True when `err`, or any error it wraps as `.cause`, is a transient connection
 * failure. Drizzle re-wraps the driver error in a `DrizzleQueryError` (the
 * original postgres.js error becomes `.cause`), so we walk the cause chain
 * rather than only inspecting the top-level error. The walk is depth-bounded to
 * stay cheap and to guard against a self-referential cause cycle.
 */
export function isTransientConnectionError(err: unknown): boolean {
  let current: unknown = err;
  for (let depth = 0; current != null && depth < 10; depth++) {
    const code = (current as { code?: unknown }).code;
    if (typeof code === "string" && TRANSIENT_CONNECTION_CODES.has(code)) {
      return true;
    }
    current = (current as { cause?: unknown }).cause;
  }
  return false;
}

/**
 * Default backoff before the retry that follows a failed attempt: exponential
 * from 50ms (≈50ms, ≈100ms, …) with ±50% jitter. The jitter keeps a burst of
 * concurrent requests from retrying in lockstep after a DB-wide event, and the
 * base comfortably clears postgres.js's ~15–30ms first-reconnect delay so a
 * fresh connection is usually ready by the next attempt.
 */
export function defaultBackoffMs(failedAttempt: number): number {
  const base = 50 * 2 ** (failedAttempt - 1);
  return base * (0.5 + Math.random());
}

/** Wait `ms`, yielding a macrotask so a fresh connection can open. */
function defaultSleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export interface DbRetryOptions {
  /** Total attempts including the first. Default 3. */
  attempts?: number;
  /**
   * Called just after a transient failure that will be retried. `attempt` is
   * the 1-based number of the attempt that just failed. Handy for logging how
   * often a retry saved a request.
   */
  onRetry?: (attempt: number, err: unknown) => void;
  /**
   * Delay (ms) before the retry that follows the given 1-based failed attempt.
   * Defaults to {@link defaultBackoffMs}; return 0 to skip the wait.
   */
  backoffMs?: (failedAttempt: number) => number;
  /**
   * The wait itself, injected by tests so they never sleep on a real timer.
   * Production uses `setTimeout`.
   */
  sleep?: (ms: number) => Promise<void>;
}

/**
 * Run `op`, retrying it up to `attempts` times when — and only when — it fails
 * with a transient connection error (see {@link isTransientConnectionError}),
 * backing off between attempts. Any other error (a real query error, a bug)
 * rethrows immediately: we paper over dead sockets, nothing else.
 *
 * `op` MUST be idempotent — a read, or a write keyed by a unique column
 * (ON CONFLICT DO NOTHING). A retried non-idempotent write could double-apply.
 * `op` may return a drizzle query builder directly (a PromiseLike), not just a
 * Promise, so call sites can wrap a `this.db.select()…` chain without an
 * `async` shim.
 */
export async function withDbRetry<T>(
  op: () => PromiseLike<T>,
  options: DbRetryOptions = {},
): Promise<T> {
  const attempts = options.attempts ?? 3;
  const backoffMs = options.backoffMs ?? defaultBackoffMs;
  const sleep = options.sleep ?? defaultSleep;
  let lastErr: unknown;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      return await op();
    } catch (err) {
      lastErr = err;
      if (attempt >= attempts || !isTransientConnectionError(err)) throw err;
      options.onRetry?.(attempt, err);
      const delay = backoffMs(attempt);
      if (delay > 0) await sleep(delay);
    }
  }
  // Unreachable — the loop always returns or throws — but TS needs a terminal.
  throw lastErr;
}
