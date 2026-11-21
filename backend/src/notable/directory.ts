/**
 * The in-memory directory of notable airframes, and how it stays current.
 *
 * ZERO MAINTENANCE BY DESIGN: no table, no migration, no ingest step.
 *
 *   1. BOOT. Load the committed snapshot (`data/notable-airframes.json`,
 *      already filtered and mapped). The server is useful from the first
 *      request with no network. A missing or corrupt snapshot is logged and
 *      leaves the directory empty; it never stops the boot.
 *   2. REFRESH. Shortly after boot and every 24 h, fetch plane-alert-db's CSV
 *      from GitHub, map it (mapping.ts), and swap the whole map in one
 *      assignment. A failed or implausibly small result keeps the old data.
 *
 * Nothing here can throw into a request: `lookup` is a Map read, and
 * `refresh` reports every failure as an outcome.
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  NOTABLE_KINDS,
  type Notable,
  type NotableKind,
  type NotableLookup,
  isNotableKind,
  makeNotable,
  parsePlaneAlertCsv,
} from "./mapping.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

/** The committed snapshot, relative to this module (src/ or dist/ alike). */
export const DEFAULT_NOTABLE_SNAPSHOT_PATH = join(__dirname, "../../data/notable-airframes.json");

/** The upstream file the refresh reads. */
export const PLANE_ALERT_DB_CSV_URL =
  "https://raw.githubusercontent.com/sdr-enthusiasts/plane-alert-db/main/plane-alert-db.csv";

/**
 * The fewest entries a refresh must produce when there is no snapshot to
 * compare against (the snapshot failed to load). With a snapshot the floor is
 * half its size.
 */
export const MIN_ENTRIES_WITHOUT_SNAPSHOT = 1000;

/**
 * The largest upstream body a refresh will read. The real file is about
 * 2.4 MB; this leaves room for years of growth while keeping a wrong or
 * hostile response from filling a 256 MB machine.
 */
export const MAX_UPSTREAM_CSV_BYTES = 20 * 1024 * 1024;

const ICAO24_RE = /^[0-9a-f]{6}$/;

/** Airframes per kind. Every kind is present, zero included. */
export type NotableKindCounts = Record<NotableKind, number>;

export function countNotableKinds(entries: ReadonlyMap<string, Notable>): NotableKindCounts {
  const counts = Object.fromEntries(NOTABLE_KINDS.map((k) => [k, 0])) as NotableKindCounts;
  for (const n of entries.values()) counts[n.kind] += 1;
  return counts;
}

// ── Snapshot file ────────────────────────────────────────────────────────────

/**
 * The snapshot's shape. One `[icao24, kind]` or `[icao24, kind, name]` tuple
 * per airframe, sorted by icao24 and written one per line so a regenerated
 * file diffs row by row. Labels are not stored: they derive from the kind.
 */
export interface NotableSnapshotFile {
  source: string;
  license: string;
  generatedAt: string;
  count: number;
  airframes: [string, string, string?][];
}

/** Serialize a mapped directory as the committed snapshot. */
export function serializeNotableSnapshot(
  entries: ReadonlyMap<string, Notable>,
  generatedAt: string,
): string {
  const rows = [...entries.entries()]
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([icao24, n]) =>
      JSON.stringify(n.name === undefined ? [icao24, n.kind] : [icao24, n.kind, n.name]),
    );
  const head = {
    source: "https://github.com/sdr-enthusiasts/plane-alert-db",
    license: "ODbL-1.0 (see NOTICE.md)",
    generatedAt,
    count: rows.length,
  };
  return `${JSON.stringify(head).slice(0, -1)},"airframes":[\n${rows.join(",\n")}\n]}\n`;
}

/** Parse snapshot JSON text. Throws on a malformed file; skips malformed rows. */
export function parseNotableSnapshot(jsonText: string): Map<string, Notable> {
  const parsed = JSON.parse(jsonText) as Partial<NotableSnapshotFile>;
  if (!Array.isArray(parsed.airframes)) throw new Error("notable snapshot has no airframes array");
  const out = new Map<string, Notable>();
  for (const row of parsed.airframes) {
    if (!Array.isArray(row)) continue;
    const [icao24, kind, name] = row as unknown[];
    if (typeof icao24 !== "string" || !ICAO24_RE.test(icao24) || !isNotableKind(kind)) continue;
    out.set(icao24, makeNotable(kind, typeof name === "string" && name !== "" ? name : undefined));
  }
  return out;
}

let cachedDefaultSnapshot: Map<string, Notable> | undefined;

/**
 * Read the snapshot from disk. The default path is memoized (the test suite
 * builds the app hundreds of times); the returned map is shared and must be
 * treated as read-only, which `NotableDirectory` does (a refresh replaces its
 * map, it never edits one).
 */
export function loadNotableSnapshot(
  path: string = DEFAULT_NOTABLE_SNAPSHOT_PATH,
): Map<string, Notable> {
  if (path === DEFAULT_NOTABLE_SNAPSHOT_PATH && cachedDefaultSnapshot) return cachedDefaultSnapshot;
  const map = parseNotableSnapshot(readFileSync(path, "utf8"));
  if (path === DEFAULT_NOTABLE_SNAPSHOT_PATH) cachedDefaultSnapshot = map;
  return map;
}

// ── Directory ────────────────────────────────────────────────────────────────

/**
 * Fetches the upstream CSV text. Injectable so tests never touch the network.
 * Must reject on any failure (transport, non-2xx); should honour `signal`.
 */
export type NotableCsvFetcher = (signal: AbortSignal) => Promise<string>;

export type NotableRefreshOutcome =
  /** The new data replaced the old. `kinds` counts the NEW data. */
  | { status: "updated"; entries: number; previous: number; kinds: NotableKindCounts }
  /**
   * Parsed, but too small to be believed, in total or in one kind; the old
   * data stays. `kinds` counts what was REJECTED and `minimumKinds` is the
   * floor each kind was held to, so the log line shows which one fell short.
   */
  | {
      status: "rejected";
      reason: string;
      entries: number;
      minimum: number;
      kinds: NotableKindCounts;
      minimumKinds: NotableKindCounts;
      kept: number;
    }
  /** The fetch failed or timed out; the old data stays. */
  | { status: "failed"; error: string; kept: number };

export class NotableDirectory implements NotableLookup {
  private entries: ReadonlyMap<string, Notable>;
  /** The snapshot's size at construction: the yardstick a refresh is held to. */
  private readonly baseline: number;
  /** The snapshot's per-kind sizes at construction. */
  private readonly baselineKinds: NotableKindCounts;

  constructor(entries: ReadonlyMap<string, Notable> = new Map()) {
    this.entries = entries;
    this.baseline = entries.size;
    this.baselineKinds = countNotableKinds(entries);
  }

  /**
   * A directory over the committed snapshot. Never throws: if the file is
   * missing or unreadable, `onError` hears about it and the directory starts
   * empty (no plane is notable until the first refresh lands).
   */
  static fromSnapshot(
    opts: { path?: string; onError?: (err: unknown) => void } = {},
  ): NotableDirectory {
    try {
      return new NotableDirectory(loadNotableSnapshot(opts.path));
    } catch (err) {
      opts.onError?.(err);
      return new NotableDirectory();
    }
  }

  get size(): number {
    return this.entries.size;
  }

  /** The fewest entries a refresh must produce to be accepted. */
  get minimumRefreshEntries(): number {
    return this.baseline > 0 ? Math.ceil(this.baseline / 2) : MIN_ENTRIES_WITHOUT_SNAPSHOT;
  }

  /**
   * The fewest entries of each kind a refresh must produce: half of what the
   * snapshot holds of that kind (so zero for a kind the snapshot lacks, and
   * zero for every kind when there is no snapshot).
   */
  get minimumRefreshKinds(): NotableKindCounts {
    return Object.fromEntries(
      NOTABLE_KINDS.map((k) => [k, Math.ceil(this.baselineKinds[k] / 2)]),
    ) as NotableKindCounts;
  }

  lookup(icao24: string): Notable | undefined {
    return this.entries.get(icao24) ?? this.entries.get(icao24.trim().toLowerCase());
  }

  /**
   * Fetch, map and swap. Never throws. A result with fewer than half the
   * snapshot's entries is rejected: that is what an upstream reorganisation, a
   * truncated download or an HTML error page served with a 200 looks like, and
   * silently dropping most notable planes is worse than serving day-old data.
   *
   * The same half-the-snapshot floor is applied to EACH kind the snapshot
   * holds. The total alone would wave through an upstream category rename
   * that empties one small kind (all 22 team planes, say) while the other
   * five thousand rows look healthy.
   */
  async refresh(
    fetchCsv: NotableCsvFetcher,
    opts: { timeoutMs?: number } = {},
  ): Promise<NotableRefreshOutcome> {
    const timeoutMs = opts.timeoutMs ?? 20_000;
    const controller = new AbortController();
    let timer: NodeJS.Timeout | undefined;
    try {
      // Raced as well as aborted, so a fetcher that ignores the signal still
      // can't hold a refresh open.
      const deadline = new Promise<never>((_, reject) => {
        timer = setTimeout(() => {
          controller.abort();
          reject(new Error(`no answer within ${timeoutMs} ms`));
        }, timeoutMs);
      });
      const text = await Promise.race([
        Promise.resolve().then(() => fetchCsv(controller.signal)),
        deadline,
      ]);
      const next = parsePlaneAlertCsv(text);
      const minimum = this.minimumRefreshEntries;
      const kinds = countNotableKinds(next);
      const minimumKinds = this.minimumRefreshKinds;
      const short = NOTABLE_KINDS.filter((k) => kinds[k] < minimumKinds[k]);
      const reason =
        next.size < minimum
          ? `${next.size} airframes, fewer than the minimum of ${minimum}`
          : short.length > 0
            ? short.map((k) => `${k}: ${kinds[k]}, minimum ${minimumKinds[k]}`).join("; ")
            : undefined;
      if (reason !== undefined) {
        return {
          status: "rejected",
          reason,
          entries: next.size,
          minimum,
          kinds,
          minimumKinds,
          kept: this.entries.size,
        };
      }
      const previous = this.entries.size;
      this.entries = next;
      return { status: "updated", entries: next.size, previous, kinds };
    } catch (err) {
      return {
        status: "failed",
        error: err instanceof Error ? err.message : String(err),
        kept: this.entries.size,
      };
    } finally {
      clearTimeout(timer);
    }
  }
}

// ── Refresh wiring ───────────────────────────────────────────────────────────

/**
 * Read a response body as UTF-8 text, refusing anything over `maxBytes`.
 * Never buffers unbounded: a declared `content-length` over the cap is
 * refused before a byte is read, and otherwise the body is read chunk by
 * chunk against a running count (the header can be absent or wrong, and a
 * compressed response declares its compressed size), cancelling the stream
 * the moment the count passes the cap.
 */
export async function readCappedText(res: Response, maxBytes: number): Promise<string> {
  const declared = Number(res.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maxBytes) {
    await res.body?.cancel().catch(() => undefined);
    throw new Error(`response too large: content-length ${declared} exceeds ${maxBytes} bytes`);
  }
  if (!res.body) return "";
  const reader = res.body.getReader();
  const decoder = new TextDecoder("utf-8");
  let received = 0;
  let text = "";
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    received += value.byteLength;
    if (received > maxBytes) {
      await reader.cancel().catch(() => undefined);
      throw new Error(`response too large: more than ${maxBytes} bytes`);
    }
    text += decoder.decode(value, { stream: true });
  }
  return text + decoder.decode();
}

/**
 * Build a fetcher for the upstream CSV. `fetchFn` and `maxBytes` are
 * injectable for tests; production uses `fetchPlaneAlertCsv` below.
 */
export function makePlaneAlertCsvFetcher(
  opts: { fetchFn?: typeof fetch; maxBytes?: number; url?: string } = {},
): NotableCsvFetcher {
  const fetchFn = opts.fetchFn ?? fetch;
  const maxBytes = opts.maxBytes ?? MAX_UPSTREAM_CSV_BYTES;
  return async (signal) => {
    const res = await fetchFn(opts.url ?? PLANE_ALERT_DB_CSV_URL, {
      headers: { "user-agent": "tailspot-api-notable-refresh" },
      signal,
      redirect: "follow",
    });
    if (!res.ok) {
      await res.body?.cancel().catch(() => undefined); // release the socket
      throw new Error(`HTTP ${res.status}`);
    }
    return readCappedText(res, maxBytes);
  };
}

/** The production fetcher: one GET to GitHub's raw host, capped at 20 MB. */
export const fetchPlaneAlertCsv: NotableCsvFetcher = makePlaneAlertCsvFetcher();

/**
 * Whether the periodic refresh should run. Off under test, and off when
 * `NOTABLE_REFRESH` says so (`off`, `false`, `0`, `no`); the server then
 * serves the committed snapshot only.
 */
export function notableRefreshEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  if (env.NODE_ENV === "test") return false;
  const flag = (env.NOTABLE_REFRESH ?? "").trim().toLowerCase();
  return !(flag === "off" || flag === "false" || flag === "0" || flag === "no");
}

export interface NotableRefreshOptions {
  fetchCsv?: NotableCsvFetcher;
  /** Delay before the first refresh, so it never competes with boot. Default 30 s. */
  initialDelayMs?: number;
  /** Time between refreshes. Default 24 h. */
  intervalMs?: number;
  /** Fetch deadline. Default 20 s. */
  timeoutMs?: number;
  /** Hears every outcome (production logs it). Errors it throws are swallowed. */
  onOutcome?: (outcome: NotableRefreshOutcome) => void;
}

/**
 * Start the background refresh: once after `initialDelayMs`, then every
 * `intervalMs`. Both timers are unref'd, so they never keep the process alive.
 * Returns a stop function.
 */
export function startNotableRefresh(
  directory: NotableDirectory,
  opts: NotableRefreshOptions = {},
): () => void {
  const fetchCsv = opts.fetchCsv ?? fetchPlaneAlertCsv;
  const run = async () => {
    const outcome = await directory.refresh(fetchCsv, { timeoutMs: opts.timeoutMs });
    try {
      opts.onOutcome?.(outcome);
    } catch {
      /* listener errors must not stop the refresh */
    }
  };
  const first = setTimeout(() => void run(), opts.initialDelayMs ?? 30_000);
  first.unref();
  const every = setInterval(() => void run(), opts.intervalMs ?? 24 * 60 * 60_000);
  every.unref();
  return () => {
    clearTimeout(first);
    clearInterval(every);
  };
}
