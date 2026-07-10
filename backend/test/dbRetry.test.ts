import { DrizzleQueryError } from "drizzle-orm/errors";
import { describe, expect, it, vi } from "vitest";
import type { Database } from "../src/db/client.js";
import { isTransientConnectionError, withDbRetry } from "../src/db/retry.js";
import { registry } from "../src/db/schema.js";
import { DrizzleMetadataStore } from "../src/metadata/store.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

/**
 * Regression coverage for Sentry BROKEN-DARKNESS-5055-3: a pooled Postgres
 * connection closed out from under an in-flight query (`CONNECTION_CLOSED`),
 * which drizzle re-wrapped as a `DrizzleQueryError` and surfaced as a 500 on
 * `GET /v1/metadata/:icao24`. The lookup is an idempotent read, so retrying it
 * on a fresh connection must recover transparently.
 */

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
    await expect(withDbRetry(op)).resolves.toBe("ok");
    expect(op).toHaveBeenCalledTimes(2);
  });

  it("rethrows a non-transient error immediately, without a second attempt", async () => {
    const queryError = Object.assign(new Error("dup"), { code: "23505" });
    const op = vi.fn<() => Promise<never>>().mockRejectedValue(queryError);
    await expect(withDbRetry(op)).rejects.toBe(queryError);
    expect(op).toHaveBeenCalledTimes(1);
  });

  it("gives up after `attempts` transient failures and rethrows the last one", async () => {
    const last = connectionClosedError();
    const op = vi
      .fn<() => Promise<never>>()
      .mockRejectedValueOnce(connectionClosedError())
      .mockRejectedValueOnce(last);
    await expect(withDbRetry(op, { attempts: 2 })).rejects.toBe(last);
    expect(op).toHaveBeenCalledTimes(2);
  });

  it("invokes onRetry for each retried failure (not the terminal one)", async () => {
    const onRetry = vi.fn();
    const op = vi
      .fn<() => Promise<string>>()
      .mockRejectedValueOnce(connectionClosedError())
      .mockResolvedValueOnce("ok");
    await withDbRetry(op, { onRetry });
    expect(onRetry).toHaveBeenCalledTimes(1);
    expect(onRetry).toHaveBeenCalledWith(1, expect.any(Error));
  });
});

describe("DrizzleMetadataStore.lookup survives a dropped connection", () => {
  /**
   * Wrap a real PGlite `Database` so the FIRST `select()` fails exactly the way
   * production did — a `DrizzleQueryError` around `CONNECTION_CLOSED` — and
   * every later call delegates to the real db. Proves the lookup recovers on
   * retry instead of 500ing.
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
