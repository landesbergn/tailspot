/**
 * The streak-forgiveness operator tool (src/tools/forgive-streak-day.ts).
 *
 * It writes a row every phone will act on and can push every device at once,
 * so its contract is pinned here against a real PGlite Postgres and a fake
 * APNs transport before it is ever run for real:
 *
 *   - argument validation (real dates only, a short non-empty reason, push
 *     flags only as a pair, `--min-build` mandatory for a push),
 *   - upsert / update / remove of the row, and that a dry run writes nothing,
 *   - the broadcast's audience (build ≥ min-build; null build, no token and
 *     disabled devices excluded), per-token APNs host, the exact payload,
 *     dead-token cleanup, and that one failure never stops the rest.
 */

import { eq, sql } from "drizzle-orm";
import { beforeEach, describe, expect, it } from "vitest";
import type { Database } from "../src/db/client.js";
import { devices, streakForgiveness } from "../src/db/schema.js";
import { DrizzleIdentityStore } from "../src/identity/store.js";
import type { ApnsEnvironment, ApnsResponse, ApnsTransport } from "../src/push/apns.js";
import {
  type BroadcastStore,
  DrizzleBroadcastStore,
  broadcastStreakForgiveness,
  forgiveStreakDay,
  parseArgs,
  streakForgivenessPayload,
} from "../src/tools/forgive-streak-day.js";
import { makeTestDb } from "./helpers/pgliteDb.js";

const DAY = "2026-11-13";
const REASON = "FAA ground stop";
const MIN_BUILD = 121;
const PUSH = { title: "Streak safe today", body: "Today won't break your streak." };

/** Records every send; answers per token from `responses` (default 200). */
class FakeTransport implements ApnsTransport {
  sent: { env: ApnsEnvironment; token: string; payload: unknown }[] = [];
  responses = new Map<string, ApnsResponse | (() => Promise<ApnsResponse>)>();
  inFlight = 0;
  maxInFlight = 0;

  async send(env: ApnsEnvironment, token: string, payload: unknown): Promise<ApnsResponse> {
    this.sent.push({ env, token, payload });
    this.inFlight++;
    this.maxInFlight = Math.max(this.maxInFlight, this.inFlight);
    try {
      await Promise.resolve();
      const canned = this.responses.get(token);
      if (typeof canned === "function") return await canned();
      return canned ?? { status: 200 };
    } finally {
      this.inFlight--;
    }
  }
}

function tok(n: number): string {
  return n.toString(16).padStart(64, "0");
}

describe("parseArgs", () => {
  const error = (argv: string[]) => {
    const parsed = parseArgs(argv);
    return parsed.ok ? null : parsed.error;
  };

  it("parses the plain forgive form", () => {
    expect(parseArgs(["--day", DAY, "--reason", REASON])).toEqual({
      ok: true,
      options: { day: DAY, reason: REASON, dryRun: false, remove: false },
    });
  });

  it("parses the full push form, --flag=value included", () => {
    expect(
      parseArgs([
        `--day=${DAY}`,
        "--reason",
        `  ${REASON}  `,
        "--push-title",
        PUSH.title,
        "--push-body",
        PUSH.body,
        "--min-build=121",
        "--dry-run",
      ]),
    ).toEqual({
      ok: true,
      options: {
        day: DAY,
        reason: REASON,
        push: { ...PUSH, minBuild: 121 },
        dryRun: true,
        remove: false,
      },
    });
  });

  it("parses --remove, which needs only the day", () => {
    expect(parseArgs(["--day", DAY, "--remove"])).toEqual({
      ok: true,
      options: { day: DAY, reason: "", dryRun: false, remove: true },
    });
  });

  it("rejects days that are not real yyyy-MM-dd dates", () => {
    for (const bad of ["2026-02-30", "2026-13-01", "2026-1-3", "tomorrow", "11/13/2026"]) {
      expect(error(["--day", bad, "--reason", REASON]), bad).toMatch(/--day must be a real/);
    }
    expect(error(["--reason", REASON])).toMatch(/--day is required/);
  });

  it("rejects a missing, blank or over-long reason", () => {
    expect(error(["--day", DAY])).toMatch(/--reason is required/);
    expect(error(["--day", DAY, "--reason", "   "])).toMatch(/--reason is required/);
    expect(error(["--day", DAY, "--reason", "x".repeat(81)])).toMatch(/at most 80/);
    expect(error(["--day", DAY, "--reason", "x".repeat(80)])).toBeNull();
  });

  it("requires --min-build whenever a push is requested", () => {
    const push = ["--push-title", PUSH.title, "--push-body", PUSH.body];
    expect(error(["--day", DAY, "--reason", REASON, ...push])).toMatch(/--min-build is required/);
    for (const bad of ["0", "-5", "12.5", "abc", "", "99999999999"]) {
      expect(error(["--day", DAY, "--reason", REASON, ...push, `--min-build=${bad}`]), bad).toMatch(
        /--min-build must be a positive whole number/,
      );
    }
  });

  it("parses --only-device as a single-device test send with no min-build", () => {
    const id = "0B1C2D3E-1111-4222-8333-444455556666";
    const push = ["--push-title", PUSH.title, "--push-body", PUSH.body];
    expect(parseArgs(["--day", DAY, "--reason", REASON, ...push, "--only-device", id])).toEqual({
      ok: true,
      options: {
        day: DAY,
        reason: REASON,
        push: { ...PUSH, onlyDevice: id.toLowerCase() },
        dryRun: false,
        remove: false,
      },
    });
    expect(
      error(["--day", DAY, "--reason", REASON, ...push, "--only-device", id, "--min-build=121"]),
    ).toMatch(/cannot be combined/);
    for (const bad of ["maverick", "1234", `${id}0`, ""]) {
      expect(
        error(["--day", DAY, "--reason", REASON, ...push, `--only-device=${bad}`]),
        bad,
      ).toMatch(/--only-device must be a device uuid/);
    }
    // Only meaningful with a push, and never with --remove.
    expect(error(["--day", DAY, "--reason", REASON, "--only-device", id])).toMatch(
      /only applies to a push/,
    );
    expect(
      error(["--day", DAY, "--reason", REASON, "--push-title", "x", "--only-device", id]),
    ).toMatch(/together/);
    expect(error(["--day", DAY, "--remove", "--only-device", id])).toMatch(/--remove never pushes/);
  });

  it("requires the push title and body as a pair", () => {
    expect(error(["--day", DAY, "--reason", REASON, "--push-title", "x"])).toMatch(/together/);
    expect(
      error(["--day", DAY, "--reason", REASON, "--push-body", "x", "--min-build", "121"]),
    ).toMatch(/together/);
    expect(
      error([
        "--day",
        DAY,
        "--reason",
        REASON,
        "--push-title",
        " ",
        "--push-body",
        "x",
        "--min-build",
        "121",
      ]),
    ).toMatch(/must not be empty/);
    // A stray --min-build means the operator thinks a push is going out.
    expect(error(["--day", DAY, "--reason", REASON, "--min-build", "121"])).toMatch(
      /only applies to a push/,
    );
  });

  it("refuses to combine --remove with push flags or a reason", () => {
    expect(
      error(["--day", DAY, "--remove", "--push-title", "a", "--push-body", "b", "--min-build=1"]),
    ).toMatch(/--remove never pushes/);
    expect(error(["--day", DAY, "--remove", "--reason", REASON])).toMatch(/takes no --reason/);
  });

  it("rejects unknown arguments, duplicates and a flag with its value missing", () => {
    expect(error(["--day", DAY, "--reason", REASON, "--apply"])).toMatch(/unknown argument/);
    expect(error([DAY, "--reason", REASON])).toMatch(/unknown argument/);
    expect(error(["--day", DAY, "--day", DAY, "--reason", REASON])).toMatch(/more than once/);
    expect(error(["--day", DAY, "--reason", "--dry-run"])).toMatch(/--reason needs a value/);
    expect(error(["--day", DAY, "--reason"])).toMatch(/--reason needs a value/);
    expect(error(["--day", DAY, "--reason", REASON, "--dry-run=yes"])).toMatch(/takes no value/);
  });
});

describe("streakForgivenessPayload", () => {
  it("is a plain alert plus kind and day, with nothing a challenge push carries", () => {
    const payload = streakForgivenessPayload({ day: DAY, ...PUSH });
    expect(payload).toEqual({
      aps: { alert: { title: PUSH.title, body: PUSH.body }, sound: "default" },
      kind: "streak_forgiveness",
      day: DAY,
    });
    // The client routes anything with a `challengeId` to that challenge.
    expect(payload).not.toHaveProperty("challengeId");
    expect(payload.aps).not.toHaveProperty("thread-id");
  });
});

describe("broadcast + forgiveStreakDay (PGlite)", () => {
  let db: Database;
  let transport: FakeTransport;
  let out: string[];
  let err: string[];

  beforeEach(async () => {
    db = await makeTestDb();
    transport = new FakeTransport();
    out = [];
    err = [];
  });

  const deps = (t: ApnsTransport | null = transport) => ({
    db,
    transport: t,
    out: (m: string) => out.push(m),
    err: (m: string) => err.push(m),
  });

  async function device(
    name: string,
    opts: {
      token?: string | null;
      environment?: string | null;
      build?: number | null;
      disabled?: boolean;
    } = {},
  ): Promise<string> {
    const rows = await db
      .insert(devices)
      .values({
        tokenHash: `hash-${name}`,
        apnsToken: opts.token ?? null,
        apnsEnvironment: opts.environment === undefined ? "production" : opts.environment,
        appBuild: opts.build ?? null,
        disabledAt: opts.disabled ? new Date() : null,
      })
      .returning({ id: devices.id });
    return rows[0].id;
  }

  const tokenOf = async (id: string) =>
    (
      await db
        .select({
          apnsToken: devices.apnsToken,
          apnsEnvironment: devices.apnsEnvironment,
          appBuild: devices.appBuild,
        })
        .from(devices)
        .where(eq(devices.id, id))
    )[0];

  const rows = () =>
    db
      .select({ day: streakForgiveness.day, reason: streakForgiveness.reason })
      .from(streakForgiveness);

  /** The standard cast: three eligible devices and every kind of ineligible one. */
  async function seedAudience() {
    return {
      prodNew: await device("prod-new", { token: tok(1), build: 121 }),
      prodNewer: await device("prod-newer", { token: tok(2), build: 140 }),
      sandboxNew: await device("sandbox-new", {
        token: tok(3),
        environment: "sandbox",
        build: 121,
      }),
      tooOld: await device("too-old", { token: tok(4), build: 120 }),
      nullBuild: await device("null-build", { token: tok(5), build: null }),
      disabled: await device("disabled", { token: tok(6), build: 130, disabled: true }),
      noToken: await device("no-token", { build: 130 }),
      badEnvironment: await device("bad-env", { token: tok(7), environment: null, build: 130 }),
    };
  }

  it("creates the row, and re-running with a new reason updates it", async () => {
    const first = await forgiveStreakDay(deps(), {
      day: DAY,
      reason: REASON,
      dryRun: false,
      remove: false,
    });
    expect(first).toEqual({ outcome: "created", previousReason: null });
    expect(await rows()).toEqual([{ day: DAY, reason: REASON }]);

    const second = await forgiveStreakDay(deps(), {
      day: DAY,
      reason: "Nationwide ground stop",
      dryRun: false,
      remove: false,
    });
    expect(second).toEqual({ outcome: "updated", previousReason: REASON });
    expect(await rows()).toEqual([{ day: DAY, reason: "Nationwide ground stop" }]);

    const third = await forgiveStreakDay(deps(), {
      day: DAY,
      reason: "Nationwide ground stop",
      dryRun: false,
      remove: false,
    });
    expect(third.outcome).toBe("unchanged");
    expect(transport.sent).toHaveLength(0);
    expect(out.join("\n")).toContain("No push requested");
  });

  it("pushes only non-disabled devices with a token and a build >= min-build", async () => {
    const d = await seedAudience();
    const result = await forgiveStreakDay(deps(), {
      day: DAY,
      reason: REASON,
      push: { ...PUSH, minBuild: MIN_BUILD },
      dryRun: false,
      remove: false,
    });

    expect(await rows()).toEqual([{ day: DAY, reason: REASON }]);
    expect(result.outcome).toBe("created");
    expect(result.push).toEqual({
      targets: { sandbox: 1, production: 2 },
      attempted: 3,
      delivered: 3,
      deadTokensCleared: 0,
      failed: 0,
    });
    // Old build, null build, disabled, token-less and environment-less are out.
    expect(transport.sent.map((s) => s.token).sort()).toEqual([tok(1), tok(2), tok(3)]);
    // The APNs host follows each token's own environment.
    const envByToken = new Map(transport.sent.map((s) => [s.token, s.env]));
    expect(envByToken.get(tok(1))).toBe("production");
    expect(envByToken.get(tok(2))).toBe("production");
    expect(envByToken.get(tok(3))).toBe("sandbox");
    for (const s of transport.sent) {
      expect(s.payload).toEqual({
        aps: { alert: { title: PUSH.title, body: PUSH.body }, sound: "default" },
        kind: "streak_forgiveness",
        day: DAY,
      });
    }
    // Nobody's token was touched.
    expect((await tokenOf(d.tooOld)).apnsToken).toBe(tok(4));
    expect(out.join("\n")).toMatch(
      /3 attempted \(2 production, 1 sandbox\) — 3 delivered, 0 dead token\(s\) cleared, 0 failed/,
    );
  });

  it("clears dead tokens, counts failures, and never lets one stop the rest", async () => {
    const gone = await device("gone", { token: tok(1), build: 121 });
    const bad = await device("bad", { token: tok(2), environment: "sandbox", build: 121 });
    const unregistered = await device("unregistered", { token: tok(3), build: 121 });
    const flaky = await device("flaky", { token: tok(4), build: 121 });
    const badTopic = await device("bad-topic", { token: tok(5), build: 121 });
    const throwing = await device("throwing", { token: tok(6), build: 121 });
    const fine = await device("fine", { token: tok(7), build: 121 });

    transport.responses.set(tok(1), { status: 410, reason: "Unregistered" });
    transport.responses.set(tok(2), { status: 400, reason: "BadDeviceToken" });
    transport.responses.set(tok(3), { status: 400, reason: "Unregistered" });
    transport.responses.set(tok(4), { status: 503 });
    transport.responses.set(tok(5), { status: 400, reason: "TopicDisallowed" });
    transport.responses.set(tok(6), async () => {
      throw new Error("socket exploded");
    });

    const summary = await broadcastStreakForgiveness(
      { store: new DrizzleBroadcastStore(db), transport, log: (m) => err.push(m) },
      { day: DAY, ...PUSH, minBuild: MIN_BUILD },
    );

    expect(summary).toEqual({
      targets: { sandbox: 1, production: 6 },
      attempted: 7,
      delivered: 1,
      deadTokensCleared: 3,
      failed: 3,
    });
    // Dead tokens are cleared whole (token, environment and build together).
    for (const id of [gone, bad, unregistered]) {
      expect(await tokenOf(id)).toEqual({
        apnsToken: null,
        apnsEnvironment: null,
        appBuild: null,
      });
    }
    // A failure that isn't a dead token keeps its token.
    for (const [id, token] of [
      [flaky, tok(4)],
      [badTopic, tok(5)],
      [throwing, tok(6)],
      [fine, tok(7)],
    ] as const) {
      expect((await tokenOf(id)).apnsToken).toBe(token);
    }
    // Transient failures (503, a thrown transport) got exactly one retry; the
    // permanent ones did not.
    const sends = (token: string) => transport.sent.filter((s) => s.token === token).length;
    expect(sends(tok(4))).toBe(2);
    expect(sends(tok(6))).toBe(2);
    expect(sends(tok(5))).toBe(1);
    expect(sends(tok(1))).toBe(1);
    expect(sends(tok(7))).toBe(1);
    // Failures are reported by device id, never by token.
    expect(err).toHaveLength(3);
    expect(err.join("\n")).toContain(flaky);
    expect(err.join("\n")).not.toContain(tok(4));
  });

  it("a transient failure that succeeds on the retry counts as delivered", async () => {
    await device("flaky", { token: tok(1), build: 121 });
    let calls = 0;
    transport.responses.set(tok(1), async () =>
      ++calls === 1 ? { status: 429, reason: "TooManyRequests" } : { status: 200 },
    );
    const summary = await broadcastStreakForgiveness(
      { store: new DrizzleBroadcastStore(db), transport },
      { day: DAY, ...PUSH, minBuild: MIN_BUILD },
    );
    expect(summary.delivered).toBe(1);
    expect(summary.failed).toBe(0);
  });

  it("bounds a send that never settles and carries on", async () => {
    await device("hung", { token: tok(1), build: 121 });
    await device("fine", { token: tok(2), build: 121 });
    transport.responses.set(tok(1), () => new Promise<ApnsResponse>(() => {}));
    const summary = await broadcastStreakForgiveness(
      { store: new DrizzleBroadcastStore(db), transport, log: (m) => err.push(m) },
      { day: DAY, ...PUSH, minBuild: MIN_BUILD, sendDeadlineMs: 20 },
    );
    expect(summary.delivered).toBe(1);
    expect(summary.failed).toBe(1);
    expect(err.join("\n")).toContain("timeout");
  });

  it("keeps concurrency modest and survives a failing token cleanup", async () => {
    const targets = Array.from({ length: 50 }, (_, i) => ({
      deviceId: `device-${i}`,
      token: tok(i + 1),
      environment: "production" as const,
    }));
    transport.responses.set(tok(1), { status: 410 });
    transport.responses.set(tok(2), { status: 410 });
    const cleared: string[] = [];
    const store: BroadcastStore = {
      pushTargets: async () => targets,
      deviceTarget: async () => ({ ok: false, problem: "not-found" }),
      clearToken: async (token) => {
        if (token === tok(1)) throw new Error("db hiccup");
        cleared.push(token);
      },
    };
    const summary = await broadcastStreakForgiveness(
      { store, transport, log: (m) => err.push(m) },
      { day: DAY, ...PUSH, minBuild: MIN_BUILD, concurrency: 5 },
    );
    expect(transport.maxInFlight).toBeLessThanOrEqual(5);
    expect(transport.maxInFlight).toBeGreaterThan(1);
    expect(summary).toEqual({
      targets: { sandbox: 0, production: 50 },
      attempted: 50,
      delivered: 48,
      deadTokensCleared: 1,
      failed: 1,
    });
    expect(cleared).toEqual([tok(2)]);
  });

  it("a dry run writes nothing and sends nothing, but counts the audience", async () => {
    const d = await seedAudience();
    transport.responses.set(tok(1), { status: 410 });
    const result = await forgiveStreakDay(deps(), {
      day: DAY,
      reason: REASON,
      push: { ...PUSH, minBuild: MIN_BUILD },
      dryRun: true,
      remove: false,
    });
    expect(result.outcome).toBe("dry-run");
    expect(result.push).toEqual({
      targets: { sandbox: 1, production: 2 },
      attempted: 0,
      delivered: 0,
      deadTokensCleared: 0,
      failed: 0,
    });
    expect(await rows()).toEqual([]);
    expect(transport.sent).toHaveLength(0);
    expect((await tokenOf(d.prodNew)).apnsToken).toBe(tok(1));
    expect(out.join("\n")).toMatch(/DRY RUN/);
    expect(out.join("\n")).toMatch(/Would push 3 device\(s\).*2 production, 1 sandbox/);
  });

  it("a dry run needs no APNs configuration", async () => {
    await device("a", { token: tok(1), build: 121 });
    const result = await forgiveStreakDay(deps(null), {
      day: DAY,
      reason: REASON,
      push: { ...PUSH, minBuild: MIN_BUILD },
      dryRun: true,
      remove: false,
    });
    expect(result.push?.targets).toEqual({ sandbox: 0, production: 1 });
  });

  it("refuses, before writing, when a push is asked for and APNs is not configured", async () => {
    await device("a", { token: tok(1), build: 121 });
    const result = await forgiveStreakDay(deps(null), {
      day: DAY,
      reason: REASON,
      push: { ...PUSH, minBuild: MIN_BUILD },
      dryRun: false,
      remove: false,
    });
    expect(result.outcome).toBe("push-unavailable");
    expect(await rows()).toEqual([]);
    expect(err.join("\n")).toMatch(/APNs is not configured/);
  });

  describe("--only-device", () => {
    const only = (onlyDevice: string, dryRun = false) => ({
      day: "2000-01-01",
      reason: "Test",
      push: { ...PUSH, onlyDevice },
      dryRun,
      remove: false,
    });

    it("pushes exactly that device, ignoring the build filter", async () => {
      const d = await seedAudience();
      // Build 1 (a Debug build) and a null build are both fine for a test send.
      const debug = await device("debug", { token: tok(20), environment: "sandbox", build: 1 });
      const result = await forgiveStreakDay(deps(), only(debug));
      expect(result.outcome).toBe("created");
      expect(result.push).toEqual({
        targets: { sandbox: 1, production: 0 },
        attempted: 1,
        delivered: 1,
        deadTokensCleared: 0,
        failed: 0,
      });
      expect(transport.sent).toEqual([
        {
          env: "sandbox",
          token: tok(20),
          payload: {
            aps: { alert: { title: PUSH.title, body: PUSH.body }, sound: "default" },
            kind: "streak_forgiveness",
            day: "2000-01-01",
          },
        },
      ]);
      expect(await rows()).toEqual([{ day: "2000-01-01", reason: "Test" }]);
      expect(out.join("\n")).toMatch(/test send to device .* no build filter\): 1 attempted/);

      transport.sent = [];
      const nullBuild = await forgiveStreakDay(deps(), only(d.nullBuild));
      expect(nullBuild.push?.delivered).toBe(1);
      expect(transport.sent.map((s) => s.token)).toEqual([tok(5)]);
    });

    it("refuses an unknown, disabled or token-less device without writing or sending", async () => {
      const d = await seedAudience();
      const cases: [string, RegExp][] = [
        ["00000000-0000-4000-8000-00000000dead", /no device has id/],
        [d.disabled, /is disabled/],
        [d.noToken, /has no push token/],
        [d.badEnvironment, /has no push token/],
      ];
      for (const [id, message] of cases) {
        err = [];
        const result = await forgiveStreakDay(deps(), only(id));
        expect(result, id).toEqual({ outcome: "target-unavailable", previousReason: null });
        expect(err.join("\n"), id).toMatch(message);
        expect(err.join("\n")).toMatch(/Nothing was written and nothing was sent/);
      }
      expect(await rows()).toEqual([]);
      expect(transport.sent).toHaveLength(0);
    });

    it("a dry run reports the one target, or why there is none", async () => {
      const d = await seedAudience();
      const ok = await forgiveStreakDay(deps(null), only(d.tooOld, true));
      expect(ok.outcome).toBe("dry-run");
      expect(ok.push?.targets).toEqual({ sandbox: 0, production: 1 });
      expect(ok.push?.targetProblem).toBeUndefined();
      expect(out.join("\n")).toContain(
        `Would push 1 device (test send, no build filter): ${d.tooOld} (production)`,
      );

      out = [];
      const none = await forgiveStreakDay(deps(null), only(d.disabled, true));
      expect(none.outcome).toBe("dry-run");
      expect(none.push).toMatchObject({
        targets: { sandbox: 0, production: 0 },
        attempted: 0,
        targetProblem: "disabled",
      });
      expect(out.join("\n")).toMatch(/Would push NOBODY: device .* is disabled/);
      expect(await rows()).toEqual([]);
      expect(transport.sent).toHaveLength(0);
    });

    it("clears the token when the one device turns out to be dead", async () => {
      const gone = await device("gone", { token: tok(30), build: 1 });
      transport.responses.set(tok(30), { status: 410 });
      const summary = await broadcastStreakForgiveness(
        { store: new DrizzleBroadcastStore(db), transport },
        { day: DAY, ...PUSH, onlyDevice: gone },
      );
      expect(summary).toEqual({
        targets: { sandbox: 0, production: 1 },
        attempted: 1,
        delivered: 0,
        deadTokensCleared: 1,
        failed: 0,
      });
      expect((await tokenOf(gone)).apnsToken).toBeNull();
    });
  });

  it("--remove deletes the day and never pushes", async () => {
    await device("a", { token: tok(1), build: 121 });
    await db.insert(streakForgiveness).values([
      { day: DAY, reason: REASON },
      { day: "2026-11-14", reason: "Still stopped" },
    ]);

    const dry = await forgiveStreakDay(deps(), {
      day: DAY,
      reason: "",
      dryRun: true,
      remove: true,
    });
    expect(dry).toEqual({ outcome: "dry-run", previousReason: REASON });
    expect(await rows()).toHaveLength(2);

    const removed = await forgiveStreakDay(deps(), {
      day: DAY,
      reason: "",
      dryRun: false,
      remove: true,
    });
    expect(removed).toEqual({ outcome: "removed", previousReason: REASON });
    expect(await rows()).toEqual([{ day: "2026-11-14", reason: "Still stopped" }]);
    expect(transport.sent).toHaveLength(0);

    const again = await forgiveStreakDay(deps(), {
      day: DAY,
      reason: "",
      dryRun: false,
      remove: true,
    });
    expect(again).toEqual({ outcome: "not-found", previousReason: null });
  });
});

describe("migration 0012 is mandatory before the deploy", () => {
  it("an un-migrated database fails device registration outright", async () => {
    const db = await makeTestDb();
    // Roll `devices` back to its pre-0012 shape.
    await db.execute(sql`alter table "devices" drop column "app_build"`);
    // Drizzle names every schema column in an INSERT, so the new nullable
    // column breaks POST /v1/devices on a database that doesn't have it yet —
    // the reason backend/README.md says to apply 0012 BEFORE deploying.
    await expect(new DrizzleIdentityStore(db).createDevice("hash-nope")).rejects.toThrow(
      /app_build/,
    );
  });
});
