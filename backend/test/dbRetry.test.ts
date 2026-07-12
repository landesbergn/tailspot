import { DrizzleQueryError } from "drizzle-orm/errors";
import { describe, expect, it, vi } from "vitest";
import type { Database } from "../src/db/client.js";
import { defaultBackoffMs, isTransientConnectionError, withDbRetry } from "../src/db/retry.js";
import { registry } from "../src/db/schema.js";
import { DrizzleCatchStore } from "../src/identity/store.js";
import { DrizzleMetadataStore } from "../src/metadata/store.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

/**
 * Regression coverage for Sentry BROKEN-DARKNESS-5055-3/-5/-7: a pooled Postgres
 * connection closed / connect-timed-out under an in-flight query, which drizzle
 * re-wrapped as a `DrizzleQueryError` and surfaced as a 500. Idempotent reads
 * (and ON CONFLICT DO NOTHING writes) are wrapped in `withDbRetry`, which now
 * BACKS OFF between attempts so a fresh connection has time to open.
 */

/** Never actually sleep in tests that don't care about the backoff timing. */
const NO_SLEEP = async () => {};

/** The exact error shape the driver throws when the socket dies mid-query. */
function connectionClosedError(): Error {
  return Object.assign(new Error("write CONNECTION_CLOSED tailspot-db.flycast:5432"), {
    code: "CONNECTION_CLOSED",
  });
}

/** How drizzle re-wraps the driver error before it reaches our code. */
function drizzleWrapped(cause: Error): DrizzleQueryError {
  return new DrizzleQueryError("select ... from registry", ["71c575", 1], cause);
}

/**
 * Wrap a real PGlite `Database` so the FIRST `select()` fails exactly the way
 * production did — a `DrizzleQueryError` around `CONNECTION_CLOSED` — and every
 * later call delegates to the real db. The rejecting stub covers the chain
 * shapes our point-reads use (`.from().where().limit()`), rejecting at `.limit`.
 */
function failFirstSelect(realDb: Database): Database {
  let failed = false;
  return new Proxy(realDb, {
    get(target, prop, receiver) {
      if (prop === "select") {
        return (...args: unknown[]) => {
          if (!failed) {
            failed = true;
            const rejecting = {
              from: () => rejecting,
              where: () => rejecting,
              limit: () => Promise.reject(drizzleWrapped(connectionClosedError())),
            };
            return rejecting;
          }
          return (target.select as (...a: unknown[]) => unknown)(...args);
        };
      }
      return Reflect.get(target, prop, receiver);
    },
  }) as Database;
}

describe("isTransientConnectionError", () => {
  it("recognizes a bare postgres.js connection error by code", () => {
    expect(isTransientConnectionError(connectionClosedError())).toBe(true);
  });

  it("unwraps the DrizzleQueryError cause chain (the shape seen in prod)", () => {
    expect(isTransientConnectionError(drizzleWrapped(connectionClosedError()))).toBe(true);
  });

  it.each(["CONNECTION_DESTROYED", "CONNECTION_ENDED", "CONNECT_TIMEOUT", "ECONNRESET", "EPIPE"])(
    "treats %s as transient",
    (code) => {
      expect(isTransientConnectionError(Object.assign(new Error(code), { code }))).toBe(true);
    },
  );

  it("does NOT treat a real query error (SQLSTATE code) as transient", () => {
    // e.g. a unique-violation — retrying would be wrong.
    expect(isTransientConnectionError(Object.assign(new Error("dup"), { code: "23505" }))).toBe(
      false,
    );
  });

  it("does not treat a plain error or non-error as transient", () => {
    expect(isTransientConnectionError(new Error("boom"))).toBe(false);
    expect(isTransientConnectionError(null)).toBe(false);
    expect(isTransientConnectionError("CONNECTION_CLOSED")).toBe(false);
  });

  it("terminates on a self-referential cause cycle", () => {
    const a = new Error("a") as Error & { cause?: unknown };
    const b = new Error("b") as Error & { cause?: unknown };
    a.cause = b;
    b.cause = a;
    expect(isTransientConnectionError(a)).toBe(false);
  });
});

describe("withDbRetry", () => {
  it("retries a transient failure and returns the eventual success", async () => {
    const op = vi
      .fn<() => Promise<string>>()
      .mockRejectedValueOnce(drizzleWrapped(connectionClosedError()))
      .mockResolvedValueOnce("ok");
    await expect(withDbRetry(op, { sleep: NO_SLEEP })).resolves.toBe("ok");
    expect(op).toHaveBeenCalledTimes(2);
  });

  it("rethrows a non-transient error immediately, without a second attempt", async () => {
    const queryError = Object.assign(new Error("dup"), { code: "23505" });
    const op = vi.fn<() => Promise<never>>().mockRejectedValue(queryError);
    await expect(withDbRetry(op, { sleep: NO_SLEEP })).rejects.toBe(queryError);
    expect(op).toHaveBeenCalledTimes(1);
  });

  it("gives up after `attempts` transient failures and rethrows the last one", async () => {
    const last = connectionClosedError();
    const op = vi
      .fn<() => Promise<never>>()
      .mockRejectedValueOnce(connectionClosedError())
      .mockRejectedValueOnce(last);
    await expect(withDbRetry(op, { attempts: 2, sleep: NO_SLEEP })).rejects.toBe(last);
    expect(op).toHaveBeenCalledTimes(2);
  });

  it("invokes onRetry for each retried failure (not the terminal one)", async () => {
    const onRetry = vi.fn();
    const op = vi
      .fn<() => Promise<string>>()
      .mockRejectedValueOnce(connectionClosedError())
      .mockResolvedValueOnce("ok");
    await withDbRetry(op, { onRetry, sleep: NO_SLEEP });
    expect(onRetry).toHaveBeenCalledTimes(1);
    expect(onRetry).toHaveBeenCalledWith(1, expect.any(Error));
  });

  it("backs off before each retry, on the configured schedule", async () => {
    const waited: number[] = [];
    const op = vi
      .fn<() => Promise<string>>()
      .mockRejectedValueOnce(connectionClosedError())
      .mockRejectedValueOnce(connectionClosedError())
      .mockResolvedValueOnce("ok");
    // attempts=3 → two retries → two waits, one per failed-but-retried attempt.
    await withDbRetry(op, {
      backoffMs: (failedAttempt) => failedAttempt * 10,
      sleep: async (ms) => {
        waited.push(ms);
      },
    });
    expect(waited).toEqual([10, 20]);
  });

  it("does not sleep when the error is non-transient", async () => {
    const sleep = vi.fn(async () => {});
    const op = vi.fn(async () => {
      throw Object.assign(new Error("dup"), { code: "23505" });
    });
    await expect(withDbRetry(op, { sleep })).rejects.toThrow("dup");
    expect(sleep).not.toHaveBeenCalled();
  });

  it("default backoff is a positive, growing (jittered) delay", () => {
    // Exponential-from-50ms with ±50% jitter: attempt N ∈ [0.5, 1.5) × 50·2^(N-1).
    for (let n = 1; n <= 4; n++) {
      const base = 50 * 2 ** (n - 1);
      const d = defaultBackoffMs(n);
      expect(d).toBeGreaterThanOrEqual(base * 0.5);
      expect(d).toBeLessThan(base * 1.5);
    }
  });
});

describe("DrizzleMetadataStore.lookup survives a dropped connection", () => {
  it("retries past a CONNECTION_CLOSED and returns the record", async () => {
    const db = await makeTestDb();
    await db.insert(registry).values({
      icao24: "71c575",
      registration: "N550TS",
      manufacturerRaw: "CESSNA",
      modelRaw: "550",
      typecode: null,
      source: "faa",
    });

    const store = new DrizzleMetadataStore(failFirstSelect(db));
    const rec = await store.lookup("71c575");

    expect(rec).not.toBeNull();
    expect(rec?.registration).toBe("N550TS");
    expect(rec?.source).toBe("faa");
  });
});

describe("DrizzleCatchStore reads survive a dropped connection", () => {
  // Regression for BROKEN-DARKNESS-5055-7: the leaderboard/topper reads had no
  // retry, so a CONNECT_TIMEOUT during a DB blip 500'd. everToppedAllTime is a
  // representative point-read now wrapped in withDbRetry — a first-select drop
  // must recover on retry rather than throw.
  it("everToppedAllTime retries past a dropped connection", async () => {
    const db = await makeTestDb();
    const store = new DrizzleCatchStore(failFirstSelect(db));
    await expect(store.everToppedAllTime("00000000-0000-0000-0000-000000000000")).resolves.toBe(
      false,
    );
  });
});
