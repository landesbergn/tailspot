/**
 * Operator kill switch: disable (or re-enable) ONE device.
 *
 * WHY THIS EXISTS. Tailspot identity is anonymous — a device registers, gets a
 * 256-bit bearer token once, and that's the whole account. There is no email,
 * no password, and therefore no "reset the password" or "ban the account"
 * lever. When one device needs to be switched off — a token leaked and being
 * replayed, a handle-squatter, someone cheating their way up the public board —
 * the tempting move is to DELETE its rows, and that is the wrong move:
 * `catches`, `weekly_champions`, `monthly_champions` and `alltime_toppers` all
 * reference `devices.id`, so a delete either fails on the FK or takes real
 * history with it and silently rewrites frozen crowns other players already saw.
 *
 * So we disable instead. Setting `devices.disabled_at` makes the device's token
 * resolve to nothing (`DrizzleIdentityStore.findByTokenHash` filters on it), so
 * every bearer route answers 401 and the leaderboard answers "no me", and drops
 * the device from live leaderboard entries — while every row it ever wrote stays
 * exactly where it is. It is fully reversible (`--enable`), which matters
 * because an anonymous user has no way to appeal a mistake: if you disable the
 * wrong device, re-enabling it restores them completely.
 *
 * The device is addressed by its uuid OR by its handle (handles are matched
 * case-insensitively, the same way the unique index treats them) — in practice
 * a report names the handle, not the id.
 *
 * Run:
 *   cd backend && npm run build
 *   DATABASE_URL=… node dist/tools/disable-device.js <uuid|handle>            # dry run
 *   DATABASE_URL=… node dist/tools/disable-device.js <uuid|handle> --apply    # disable
 *   DATABASE_URL=… node dist/tools/disable-device.js <uuid|handle> --enable --apply
 *
 * Or via the npm script: `npm run device:disable -- <uuid|handle> --apply`.
 *
 * Defaults to a DRY RUN: it prints the device it matched and what it would do,
 * and writes nothing. Pass `--apply` to actually write. Nothing in the request
 * path ever writes this column — only this script does.
 */

import { eq, sql } from "drizzle-orm";
import { type Database, closeDb, getDb } from "../db/client.js";
import { devices } from "../db/schema.js";

/** A uuid v4-ish shape — enough to tell "this is an id" from "this is a handle". */
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface DisableDeviceOptions {
  /** Clear `disabled_at` (turn the device back ON) instead of setting it. */
  enable?: boolean;
  /** Write. Default false — compute + report only. */
  apply?: boolean;
  /** Injectable clock so tests get a deterministic `disabled_at`. */
  now?: () => Date;
}

export interface DisableDeviceResult {
  /** "not-found" when the selector matched no device; "ambiguous" when >1 handle matched. */
  outcome: "disabled" | "enabled" | "already" | "not-found" | "ambiguous" | "dry-run";
  deviceId?: string;
  handle?: string | null;
  /** The device's `disabled_at` BEFORE this run (null = it was active). */
  wasDisabledAt?: Date | null;
}

/**
 * Look the device up by uuid or handle, then set/clear `disabled_at`.
 * Exported (rather than inlined into `main`) so the behavior is testable
 * against PGlite without shelling out to a built script.
 */
export async function disableDevice(
  db: Database,
  selector: string,
  opts: DisableDeviceOptions = {},
): Promise<DisableDeviceResult> {
  const { enable = false, apply = false, now = () => new Date() } = opts;

  // Handles are unique case-insensitively (the `lower(handle)` index), so a
  // handle lookup should match at most one row — but we select without a LIMIT
  // and check the count rather than silently acting on the first of several.
  // Disabling the wrong stranger is the failure mode worth being loud about.
  const matches = UUID_RE.test(selector)
    ? await db
        .select({ id: devices.id, handle: devices.handle, disabledAt: devices.disabledAt })
        .from(devices)
        .where(eq(devices.id, selector))
    : await db
        .select({ id: devices.id, handle: devices.handle, disabledAt: devices.disabledAt })
        .from(devices)
        .where(eq(sql`lower(${devices.handle})`, selector.toLowerCase()));

  if (matches.length === 0) {
    console.log(`no device matches ${JSON.stringify(selector)} — nothing to do`);
    return { outcome: "not-found" };
  }
  if (matches.length > 1) {
    console.error(
      `${matches.length} devices match ${JSON.stringify(selector)} — refusing to guess. Re-run with a device id: ${matches.map((m) => m.id).join(", ")}`,
    );
    return { outcome: "ambiguous" };
  }

  const device = matches[0];
  const wasDisabledAt = device.disabledAt ?? null;
  const label = `device ${device.id} (handle ${device.handle === null ? "<none>" : device.handle})`;
  const verb = enable ? "enable" : "disable";

  // Already in the requested state → say so and write nothing. Re-disabling
  // would otherwise stomp the original `disabled_at`, losing when it happened.
  if (enable ? wasDisabledAt === null : wasDisabledAt !== null) {
    console.log(
      enable
        ? `${label} is already enabled — nothing to do`
        : `${label} was already disabled at ${wasDisabledAt?.toISOString()} — nothing to do`,
    );
    return { outcome: "already", deviceId: device.id, handle: device.handle, wasDisabledAt };
  }

  if (!apply) {
    console.log(`DRY RUN — would ${verb} ${label}. Re-run with --apply to write.`);
    return { outcome: "dry-run", deviceId: device.id, handle: device.handle, wasDisabledAt };
  }

  const disabledAt = enable ? null : now();
  await db.update(devices).set({ disabledAt }).where(eq(devices.id, device.id));

  if (enable) {
    console.log(`ENABLED ${label} — its token authenticates again and it is back on the board.`);
    return { outcome: "enabled", deviceId: device.id, handle: device.handle, wasDisabledAt };
  }
  console.log(
    `DISABLED ${label} at ${disabledAt?.toISOString()} — its token now 401s on every bearer route and it is hidden from the leaderboard. Its catches were NOT deleted; re-run with --enable --apply to undo.`,
  );
  return { outcome: "disabled", deviceId: device.id, handle: device.handle, wasDisabledAt };
}

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  const flags = new Set(argv.filter((a) => a.startsWith("--")));
  const selector = argv.find((a) => !a.startsWith("--"));
  if (selector === undefined) {
    console.error(
      "usage: node dist/tools/disable-device.js <device-uuid|handle> [--enable] [--apply]",
    );
    process.exit(2);
    return;
  }

  const db = getDb();
  try {
    const result = await disableDevice(db, selector, {
      enable: flags.has("--enable"),
      apply: flags.has("--apply"),
    });
    // A selector that matched nothing (or matched ambiguously) is an operator
    // error, not a successful no-op — exit non-zero so a script notices.
    if (result.outcome === "not-found" || result.outcome === "ambiguous") process.exitCode = 1;
  } finally {
    await closeDb();
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
