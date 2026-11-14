/**
 * Operator tool: declare (or undo) a FORGIVEN DAY for catch streaks, and
 * optionally announce it with one broadcast push.
 *
 * WHY THIS EXISTS. Streaks are "consecutive local days with a catch", computed
 * on the phone. When nobody could reasonably have caught a plane — an FAA
 * ground stop — a broken streak is the app punishing people for the weather.
 * Declaring the day forgiven writes one row to `streak_forgiveness`; the app
 * fetches the public list (GET /v1/streak-forgiveness) and a missed catch on
 * that day no longer breaks a streak.
 *
 * THE ROW IS THE PROTECTION; THE PUSH IS ONLY THE ANNOUNCEMENT. A phone that
 * never gets the notification is still protected the next time it reads the
 * list. That ordering is why the row is written first and why a push failure
 * never undoes it.
 *
 * WHY --min-build IS REQUIRED TO PUSH, WITH NO DEFAULT. App versions from
 * before streak forgiveness ignore the list. Telling one of them "your streak
 * is safe" would be a lie it then proves by breaking the streak. So the
 * broadcast goes only to devices whose recorded build (`devices.app_build`,
 * stored at push-token registration) is at least `--min-build` — which must be
 * the FIRST build that shipped streak forgiveness — and a device with no
 * recorded build is left out. There is no safe default, so there is none.
 *
 * Run (the server must already be deployed with migration
 * `0012_streak-forgiveness` applied):
 *
 *   DATABASE_URL=… npm run streak:forgive -- --day 2026-11-13 --reason "FAA ground stop" --dry-run
 *   DATABASE_URL=… npm run streak:forgive -- --day 2026-11-13 --reason "FAA ground stop"
 *   DATABASE_URL=… APNS_KEY_P8=… APNS_KEY_ID=… APNS_TEAM_ID=… npm run streak:forgive -- \
 *       --day 2026-11-13 --reason "FAA ground stop" \
 *       --push-title "Streak safe today" --push-body "Ground stop — today won't break your streak." \
 *       --min-build 121
 *   DATABASE_URL=… npm run streak:forgive -- --day 2026-11-13 --remove
 *
 * Re-running with a new `--reason` updates the row. Re-running WITH the push
 * flags pushes everyone again — the script keeps no record of who was told.
 * `--remove` deletes the day (for a mistake) and never pushes.
 */

import { and, eq, gte, isNotNull, isNull } from "drizzle-orm";
import { sendWithDeadline } from "../challenges/overtaken.js";
import { type Database, closeDb, getDb } from "../db/client.js";
import { devices } from "../db/schema.js";
import { CLEARED_PUSH_TOKEN } from "../identity/store.js";
import {
  type ApnsEnvironment,
  type ApnsResponse,
  type ApnsTransport,
  Http2ApnsTransport,
  PUSH_DISABLED_REASON,
  apnsConfigFromEnv,
  createApnsTransport,
  isApnsEnvironment,
  isDeadTokenResponse,
  isProviderTokenFailure,
} from "../push/apns.js";
import { DrizzleStreakForgivenessStore, isValidDayLabel } from "../streaks/forgiveness.js";

// ── Arguments ────────────────────────────────────────────────────────────────

/** Longest `--reason` accepted. It is a phrase on a small card, not a sentence. */
export const MAX_REASON_LENGTH = 80;
/** Push copy ceilings — well inside what a banner shows and APNs' 4 KB payload. */
export const MAX_PUSH_TITLE_LENGTH = 100;
export const MAX_PUSH_BODY_LENGTH = 300;

export const USAGE =
  'usage: npm run streak:forgive -- --day yyyy-MM-dd --reason "…" [--push-title "…" --push-body "…" --min-build N] [--dry-run]\n' +
  "       npm run streak:forgive -- --day yyyy-MM-dd --remove [--dry-run]";

export interface PushRequest {
  title: string;
  body: string;
  /** Lowest `devices.app_build` that receives the push. */
  minBuild: number;
}

export interface ForgiveStreakDayOptions {
  day: string;
  /** Empty only with `remove`. */
  reason: string;
  /** Present only when BOTH --push-title and --push-body were given. */
  push?: PushRequest;
  dryRun: boolean;
  remove: boolean;
}

export type ParsedArgs =
  | { ok: true; options: ForgiveStreakDayOptions }
  | { ok: false; error: string };

const VALUE_FLAGS = new Set(["--day", "--reason", "--push-title", "--push-body", "--min-build"]);
const BOOLEAN_FLAGS = new Set(["--dry-run", "--remove"]);

/**
 * Parse and validate the command line. Pure: no I/O, no process access — every
 * rule the operator can trip is decided here and reported as one message.
 * Accepts `--flag value` and `--flag=value`.
 */
export function parseArgs(argv: readonly string[]): ParsedArgs {
  const values = new Map<string, string>();
  const flags = new Set<string>();

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const eqAt = arg.indexOf("=");
    const name = arg.startsWith("--") && eqAt !== -1 ? arg.slice(0, eqAt) : arg;
    if (BOOLEAN_FLAGS.has(name)) {
      if (name !== arg) return fail(`${name} takes no value`);
      flags.add(name);
      continue;
    }
    if (!VALUE_FLAGS.has(name)) return fail(`unknown argument ${JSON.stringify(arg)}`);
    if (values.has(name)) return fail(`${name} was given more than once`);
    if (name !== arg) {
      values.set(name, arg.slice(eqAt + 1));
      continue;
    }
    const next = argv[i + 1];
    // A following flag means the value was forgotten; don't swallow it.
    if (next === undefined || VALUE_FLAGS.has(next) || BOOLEAN_FLAGS.has(next)) {
      return fail(`${name} needs a value`);
    }
    values.set(name, next);
    i++;
  }

  const dryRun = flags.has("--dry-run");
  const remove = flags.has("--remove");

  const day = values.get("--day");
  if (day === undefined) return fail("--day is required");
  if (!isValidDayLabel(day)) {
    return fail(`--day must be a real calendar date as yyyy-MM-dd (got ${JSON.stringify(day)})`);
  }

  const hasTitle = values.has("--push-title");
  const hasBody = values.has("--push-body");

  if (remove) {
    // Removing is the "I made a mistake" path. It never pushes, and saying so
    // loudly beats silently ignoring flags the operator thought would do
    // something.
    if (hasTitle || hasBody || values.has("--min-build")) {
      return fail("--remove never pushes; drop --push-title / --push-body / --min-build");
    }
    if (values.has("--reason")) return fail("--remove takes no --reason");
    return { ok: true, options: { day, reason: "", dryRun, remove: true } };
  }

  const reason = (values.get("--reason") ?? "").trim();
  if (reason === "") return fail("--reason is required and must not be empty");
  if (reason.length > MAX_REASON_LENGTH) {
    return fail(`--reason must be at most ${MAX_REASON_LENGTH} characters (got ${reason.length})`);
  }

  if (hasTitle !== hasBody) {
    return fail("--push-title and --push-body must be given together (or neither)");
  }
  if (!hasTitle) {
    if (values.has("--min-build")) {
      return fail("--min-build only applies to a push; add --push-title and --push-body");
    }
    return { ok: true, options: { day, reason, dryRun, remove: false } };
  }

  const title = (values.get("--push-title") ?? "").trim();
  const body = (values.get("--push-body") ?? "").trim();
  if (title === "" || body === "") return fail("--push-title and --push-body must not be empty");
  if (title.length > MAX_PUSH_TITLE_LENGTH) {
    return fail(`--push-title must be at most ${MAX_PUSH_TITLE_LENGTH} characters`);
  }
  if (body.length > MAX_PUSH_BODY_LENGTH) {
    return fail(`--push-body must be at most ${MAX_PUSH_BODY_LENGTH} characters`);
  }

  const rawMinBuild = values.get("--min-build");
  if (rawMinBuild === undefined) {
    return fail(
      "--min-build is required when pushing: pass the FIRST build that shipped streak forgiveness (older builds ignore it, so telling them their streak is safe would be untrue)",
    );
  }
  if (!/^\d+$/.test(rawMinBuild.trim())) {
    return fail(`--min-build must be a positive whole number (got ${JSON.stringify(rawMinBuild)})`);
  }
  const minBuild = Number(rawMinBuild.trim());
  if (!Number.isSafeInteger(minBuild) || minBuild < 1 || minBuild > 2_147_483_647) {
    return fail(`--min-build must be a positive whole number (got ${JSON.stringify(rawMinBuild)})`);
  }

  return {
    ok: true,
    options: { day, reason, push: { title, body, minBuild }, dryRun, remove: false },
  };
}

function fail(error: string): ParsedArgs {
  return { ok: false, error };
}

// ── The push ─────────────────────────────────────────────────────────────────

/**
 * The exact APNs payload. An ordinary alert plus two top-level custom keys the
 * client reads: `kind: "streak_forgiveness"` and the forgiven `day`.
 *
 * It deliberately carries NO `challengeId` and no `thread-id`. The client's
 * challenge routing (`ChallengeNotificationRouting`) claims any notification
 * that has a `challengeId`, whatever its `kind`, and opens that challenge — so
 * the absence of that key is what keeps this from being mistaken for a
 * challenge push. Changing any key here is a client-visible contract change.
 */
export function streakForgivenessPayload(input: {
  day: string;
  title: string;
  body: string;
}): Record<string, unknown> {
  return {
    aps: {
      alert: { title: input.title, body: input.body },
      sound: "default",
    },
    kind: "streak_forgiveness",
    day: input.day,
  };
}

/** One device the broadcast will reach. */
export interface PushTarget {
  deviceId: string;
  token: string;
  environment: ApnsEnvironment;
}

/** The database side of the broadcast, injected so tests can fake or PGlite it. */
export interface BroadcastStore {
  /**
   * Every device to push: not disabled, holding an APNs token with a known
   * environment, and with a recorded build ≥ `minBuild`. A null build is
   * EXCLUDED — unknown is not "new enough".
   */
  pushTargets(minBuild: number): Promise<PushTarget[]>;
  /** Forget a token APNs told us is dead, wherever it is. */
  clearToken(token: string): Promise<void>;
}

export class DrizzleBroadcastStore implements BroadcastStore {
  constructor(private readonly db: Database) {}

  async pushTargets(minBuild: number): Promise<PushTarget[]> {
    const rows = await this.db
      .select({
        deviceId: devices.id,
        token: devices.apnsToken,
        environment: devices.apnsEnvironment,
      })
      .from(devices)
      .where(
        and(
          isNotNull(devices.apnsToken),
          isNull(devices.disabledAt),
          // `>=` against NULL is NULL, so a device with no recorded build
          // drops out here without a separate IS NOT NULL.
          gte(devices.appBuild, minBuild),
        ),
      );
    const targets: PushTarget[] = [];
    const seen = new Set<string>();
    for (const row of rows) {
      // A token belongs to one install (setPushToken enforces it), but one
      // phone must never get the announcement twice, so de-duplicate anyway.
      if (!row.token || !isApnsEnvironment(row.environment) || seen.has(row.token)) continue;
      seen.add(row.token);
      targets.push({ deviceId: row.deviceId, token: row.token, environment: row.environment });
    }
    return targets;
  }

  async clearToken(token: string): Promise<void> {
    // The same cleanup the overtaken sender uses (`CLEARED_PUSH_TOKEN`).
    await this.db.update(devices).set(CLEARED_PUSH_TOKEN).where(eq(devices.apnsToken, token));
  }
}

/** Parallel sends in flight at once. APNs allows far more; a broadcast doesn't need them. */
export const BROADCAST_CONCURRENCY = 20;

/** How many devices would be / were targeted, by APNs environment. */
export interface TargetCounts {
  sandbox: number;
  production: number;
}

export interface BroadcastSummary {
  /** Devices matching the filter, split by environment. Filled in for a dry run too. */
  targets: TargetCounts;
  /** Devices a send was attempted for (0 on a dry run). */
  attempted: number;
  /** Sends APNs accepted (HTTP 200). */
  delivered: number;
  /** Dead tokens (410 / BadDeviceToken / Unregistered) removed from `devices`. */
  deadTokensCleared: number;
  /** Everything else: transient or permanent failures, after the one retry. */
  failed: number;
}

export interface BroadcastDeps {
  store: BroadcastStore;
  transport: ApnsTransport;
  /** Where failure detail goes. Defaults to console.error. */
  log?: (message: string) => void;
}

export interface BroadcastOptions {
  day: string;
  title: string;
  body: string;
  minBuild: number;
  /** Count the targets and send nothing. */
  dryRun?: boolean;
  concurrency?: number;
  /** Per-send ceiling; defaults to the overtaken sender's 5 s. */
  sendDeadlineMs?: number;
}

/**
 * Send the announcement to every eligible device.
 *
 * The same conventions as the overtaken sender: the APNs host is chosen per
 * token by its stored environment, every send is bounded by a deadline, a dead
 * token is cleared, and one device's failure — a bad response, a thrown
 * transport, a failed cleanup — is counted and never stops the rest.
 * Concurrency is a small worker pool, not one stream per device.
 *
 * A failure worth retrying (429, 5xx, no answer, our own JWT rejected) gets
 * ONE more attempt after the first pass. A timed-out send that actually landed
 * can therefore show up twice on a phone; one duplicate beats a missed
 * announcement, the same trade the overtaken push makes.
 */
export async function broadcastStreakForgiveness(
  deps: BroadcastDeps,
  options: BroadcastOptions,
): Promise<BroadcastSummary> {
  const log = deps.log ?? ((message: string) => console.error(message));
  const targets = await deps.store.pushTargets(options.minBuild);
  const summary: BroadcastSummary = {
    targets: {
      sandbox: targets.filter((t) => t.environment === "sandbox").length,
      production: targets.filter((t) => t.environment === "production").length,
    },
    attempted: 0,
    delivered: 0,
    deadTokensCleared: 0,
    failed: 0,
  };
  if (options.dryRun || targets.length === 0) return summary;

  const payload = streakForgivenessPayload(options);
  const concurrency = Math.max(1, options.concurrency ?? BROADCAST_CONCURRENCY);
  const send = (target: PushTarget) =>
    sendWithDeadline(
      deps.transport,
      target.environment,
      target.token,
      payload,
      options.sendDeadlineMs,
    );

  summary.attempted = targets.length;
  const first = await mapPool(targets, concurrency, send);

  // One retry for the failures that are about us or the network, not the token.
  const retryIndexes = first.flatMap((res, i) => (isRetryable(res) ? [i] : []));
  const second = await mapPool(
    retryIndexes.map((i) => targets[i]),
    concurrency,
    send,
  );
  const results = [...first];
  retryIndexes.forEach((targetIndex, i) => {
    results[targetIndex] = second[i];
  });

  for (let i = 0; i < targets.length; i++) {
    const target = targets[i];
    const res = results[i];
    if (res.status === 200) {
      summary.delivered++;
      continue;
    }
    if (isDeadTokenResponse(res)) {
      try {
        await deps.store.clearToken(target.token);
        summary.deadTokensCleared++;
      } catch (err) {
        summary.failed++;
        log(`could not clear the dead token of device ${target.deviceId}: ${describe(err)}`);
      }
      continue;
    }
    summary.failed++;
    // The device id, never the token.
    log(
      `push to device ${target.deviceId} (${target.environment}) failed: status ${res.status}${res.reason ? ` ${res.reason}` : ""}`,
    );
  }
  return summary;
}

/** Worth one more attempt? Mirrors the overtaken sender's notion of transient. */
function isRetryable(res: ApnsResponse): boolean {
  if (res.status === 200 || isDeadTokenResponse(res)) return false;
  if (res.status === 429 || res.status >= 500) return true;
  if (isProviderTokenFailure(res)) return true;
  return res.status === 0 && res.reason !== PUSH_DISABLED_REASON;
}

/** Run `fn` over `items` with at most `limit` in flight; results keep input order. */
async function mapPool<T, R>(
  items: readonly T[],
  limit: number,
  fn: (item: T) => Promise<R>,
): Promise<R[]> {
  const results = new Array<R>(items.length);
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const i = next++;
      results[i] = await fn(items[i]);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return results;
}

function describe(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

// ── The whole operation ──────────────────────────────────────────────────────

export interface ForgiveStreakDayResult {
  /** What happened to the `streak_forgiveness` row. */
  outcome:
    | "created"
    | "updated"
    | "unchanged"
    | "removed"
    | "not-found"
    | "dry-run"
    | "push-unavailable";
  /** The day's reason BEFORE this run (null = it was not forgiven). */
  previousReason: string | null;
  /** Present when a push was requested (and, on a dry run, counted). */
  push?: BroadcastSummary;
}

export interface ForgiveStreakDayDeps {
  db: Database;
  /**
   * The APNs transport, or null when APNs isn't configured in this shell. Only
   * consulted when a push is requested and it is not a dry run.
   */
  transport: ApnsTransport | null;
  /** Override the broadcast's database side (tests). Defaults to Drizzle over `db`. */
  broadcastStore?: BroadcastStore;
  /** Progress + summary sink. Defaults to console.log. */
  out?: (message: string) => void;
  /** Failure-detail sink. Defaults to console.error. */
  err?: (message: string) => void;
}

/**
 * Upsert (or remove) the forgiven day, then broadcast if asked. Exported so
 * the whole behaviour is testable against PGlite and a fake transport without
 * shelling out to a built script.
 */
export async function forgiveStreakDay(
  deps: ForgiveStreakDayDeps,
  options: ForgiveStreakDayOptions,
): Promise<ForgiveStreakDayResult> {
  const out = deps.out ?? ((message: string) => console.log(message));
  const err = deps.err ?? ((message: string) => console.error(message));
  const store = new DrizzleStreakForgivenessStore(deps.db);
  const { day, reason, push, dryRun } = options;
  const previousReason = (await store.get(day))?.reason ?? null;

  if (options.remove) {
    if (previousReason === null) {
      out(`${day} is not a forgiven day — nothing to remove`);
      return { outcome: "not-found", previousReason };
    }
    if (dryRun) {
      out(`DRY RUN — would remove forgiven day ${day} (${JSON.stringify(previousReason)}).`);
      return { outcome: "dry-run", previousReason };
    }
    await store.remove(day);
    out(
      `REMOVED forgiven day ${day} (${JSON.stringify(previousReason)}). No push was sent; phones drop it the next time they read the list.`,
    );
    return { outcome: "removed", previousReason };
  }

  const rowChange =
    previousReason === null
      ? `create forgiven day ${day} with reason ${JSON.stringify(reason)}`
      : previousReason === reason
        ? `leave forgiven day ${day} as it is (reason already ${JSON.stringify(reason)})`
        : `update forgiven day ${day}: reason ${JSON.stringify(previousReason)} → ${JSON.stringify(reason)}`;

  if (dryRun) {
    out(`DRY RUN — nothing written, nothing sent.\nWould ${rowChange}.`);
    if (!push) {
      out("No push requested.");
      return { outcome: "dry-run", previousReason };
    }
    const summary = await broadcastStreakForgiveness(
      { store: deps.broadcastStore ?? new DrizzleBroadcastStore(deps.db), transport: NEVER_SEND },
      { day, ...push, dryRun: true },
    );
    const total = summary.targets.sandbox + summary.targets.production;
    out(
      `Would push ${total} device(s) on build ≥ ${push.minBuild}: ${summary.targets.production} production, ${summary.targets.sandbox} sandbox.\n` +
        `  title: ${JSON.stringify(push.title)}\n  body:  ${JSON.stringify(push.body)}`,
    );
    return { outcome: "dry-run", previousReason, push: summary };
  }

  // Refuse BEFORE writing when the push that was asked for can't be sent from
  // this shell. The row alone would be harmless, but the operator would have
  // to remember to come back for the announcement; failing whole is clearer.
  if (push && deps.transport === null) {
    err(
      "A push was requested but APNs is not configured here (APNS_KEY_P8 / APNS_KEY_ID / APNS_TEAM_ID). Nothing was written. Set them and re-run, or re-run without the push flags to write the row only.",
    );
    return { outcome: "push-unavailable", previousReason };
  }

  await store.upsert(day, reason);
  const outcome =
    previousReason === null ? "created" : previousReason === reason ? "unchanged" : "updated";
  out(
    outcome === "created"
      ? `FORGIVEN ${day} — ${JSON.stringify(reason)}. Row written.`
      : outcome === "updated"
        ? `UPDATED ${day} — reason ${JSON.stringify(previousReason)} → ${JSON.stringify(reason)}. Row written.`
        : `${day} was already forgiven with reason ${JSON.stringify(reason)} — row unchanged.`,
  );

  if (!push || deps.transport === null) {
    out("No push requested.");
    return { outcome, previousReason };
  }

  const summary = await broadcastStreakForgiveness(
    {
      store: deps.broadcastStore ?? new DrizzleBroadcastStore(deps.db),
      transport: deps.transport,
      log: err,
    },
    { day, ...push },
  );
  out(
    `Push (build ≥ ${push.minBuild}): ${summary.attempted} attempted (${summary.targets.production} production, ${summary.targets.sandbox} sandbox) — ${summary.delivered} delivered, ${summary.deadTokensCleared} dead token(s) cleared, ${summary.failed} failed.`,
  );
  return { outcome, previousReason, push: summary };
}

/** The dry run's transport: it is never called, and says so if it somehow is. */
const NEVER_SEND: ApnsTransport = {
  send: async () => ({ status: 0, reason: "dry run" }),
};

async function main(): Promise<void> {
  const parsed = parseArgs(process.argv.slice(2));
  if (!parsed.ok) {
    console.error(`${parsed.error}\n${USAGE}`);
    process.exit(2);
    return;
  }
  const { options } = parsed;

  // Only build a transport when it will be used; `createApnsTransport` falls
  // back to a no-op sender when the key is missing or unusable, which for a
  // one-shot broadcast must be an error rather than a silent zero.
  let transport: ApnsTransport | null = null;
  if (options.push && !options.dryRun && apnsConfigFromEnv() !== null) {
    const created = createApnsTransport({
      log: (message, detail) => console.error(message, detail ?? ""),
    });
    transport = created instanceof Http2ApnsTransport ? created : null;
  }

  const db = getDb();
  try {
    const result = await forgiveStreakDay({ db, transport }, options);
    // Asked-for work that didn't happen is an operator-visible failure.
    if (result.outcome === "not-found" || result.outcome === "push-unavailable") {
      process.exitCode = 1;
    }
    if (result.push && result.push.failed > 0) process.exitCode = 1;
  } finally {
    if (transport instanceof Http2ApnsTransport) transport.close();
    await closeDb();
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
