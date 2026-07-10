/**
 * Transient-connection retry for idempotent database work.
 *
 * Pooled Postgres connections get closed out from under us: Fly's `.flycast`
 * proxy and the Postgres server both drop idle TCP connections, and postgres.js
 * can hand a stale one to a query before it notices the socket is dead. The
 * in-flight query then fails with a connection-level error (CONNECTION_CLOSED /
 * CONNECTION_DESTROYED / ECONNRESET / …) even though the database is perfectly
 * healthy — the same query on a fresh connection succeeds. postgres.js
 * deliberately does NOT retry an in-flight query itself (it can't prove the
 * server didn't already apply it), so we retry at the application layer — but
 * ONLY for work we know is idempotent. See Sentry BROKEN-DARKNESS-5055-3.
 *
 * The `idle_timeout` / `max_lifetime` settings in `client.ts` make this rare by
 * recycling connections before the proxy kills them; this helper covers the
 * residual race where a connection is dropped between checks.
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

export interface DbRetryOptions {
  /** Total attempts including the first. Default 3. */
  attempts?: number;
  /**
   * Called just after a transient failure that will be retried. `attempt` is
   * the 1-based number of the attempt that just failed. Handy for logging how
   * often a retry saved a request.
   */
  onRetry?: (attempt: number, err: unknown) => void;
}

/**
 * Run `op`, retrying it up to `attempts` times when — and only when — it fails
 * with a transient connection error (see {@link isTransientConnectionError}).
 * Any other error (a real query error, a bug) rethrows immediately: we paper
 * over dead sockets, nothing else.
 *
 * `op` MUST be idempotent — a read, or a write keyed by a unique column. A
 * retried non-idempotent write could double-apply.
 */
export async function withDbRetry<T>(
  op: () => Promise<T>,
  options: DbRetryOptions = {},
): Promise<T> {
  const attempts = options.attempts ?? 3;
  let lastErr: unknown;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      return await op();
    } catch (err) {
      lastErr = err;
      if (attempt >= attempts || !isTransientConnectionError(err)) throw err;
      options.onRetry?.(attempt, err);
    }
  }
  // Unreachable — the loop always returns or throws — but TS needs a terminal.
  throw lastErr;
}
