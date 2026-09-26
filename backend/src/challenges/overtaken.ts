/**
 * "Someone passed you" pushes for a LIVE challenge.
 *
 * THE TRIGGER is a successful catch upload. After the reply has been sent, the
 * catches route schedules `evaluateOvertaken` for the uploading device
 * (fire-and-forget): for every live challenge that device is still in, we
 * re-derive the standings and compare each participant's new placement against
 * the one they held at the previous evaluation
 * (`challenge_participants.last_placement`). A numerically WORSE placement means
 * somebody went past them, and the person who just uploaded is who to name.
 *
 * WHY A STORED last_placement AND NOT A DIFF OF TWO LIVE READS. The standings
 * before the catch aren't available by the time we run — the row is already
 * committed — and re-scoring "as of a moment ago" would be a second, more
 * expensive query that still couldn't see a join or a leave. A remembered
 * placement is one integer, it survives a restart, and it makes the rule
 * legible: you are told when the number on your screen got worse since the last
 * time anything happened. A null is always "no opinion", never placement 0 —
 * which is also what an un-migrated or unseeded row looks like, so an
 * unseeded participant is silent rather than spammed.
 *
 * ONE EVALUATION AT A TIME PER CHALLENGE. Two phones uploading within the same
 * second would otherwise both read the standings before either wrote them back,
 * and both would push the same person (inside what each thinks is a fresh
 * cooldown) and then clobber each other's placements. So the whole read →
 * decide → send → write cycle runs inside a transaction holding the SAME
 * `SELECT … FOR UPDATE` on the challenge row that `join`, `leave` and
 * finalization take. The sends are inside that lock, which is why each one is
 * bounded at `SEND_DEADLINE_MS` — a stuck APNs stream must not park somebody
 * else's join for longer than a couple of seconds.
 *
 * WHAT IT WILL NOT DO:
 *   - notify the uploader about their own catch,
 *   - fire for an upcoming, finished or cancelled challenge (only `live`),
 *   - reach a disabled device, or one that has left (they are invisible in
 *     standings, as everywhere),
 *   - notify the same person twice within 30 minutes in the same challenge
 *     (a lead that changes hands five times is one notification, not five),
 *   - lose a notification to a blip: a transient send failure KEEPS that
 *     participant's baseline, so the next catch tries again,
 *   - throw. Every failure is logged and swallowed: a catch upload has already
 *     been answered 201 by the time this runs, and push is a garnish.
 *
 * COST is one locked participant read plus one scoring query per live challenge
 * the uploader is in (capped at `MAX_LIVE_CHALLENGES_PER_EVALUATION`), and one
 * batched placement write. It all runs off the request path.
 */

import { type SQL, and, asc, eq, gt, inArray, isNull, lte, sql } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { withDbRetry } from "../db/retry.js";
import { challengeParticipants, challenges, devices } from "../db/schema.js";
import {
  type ApnsEnvironment,
  type ApnsResponse,
  type ApnsTransport,
  PUSH_DISABLED_REASON,
  isApnsEnvironment,
  isDeadTokenResponse,
} from "../push/apns.js";
import { assignPlacements } from "./placement.js";
import type { ChallengeScorer } from "./scorer.js";

/** How long after telling someone they were passed we stay quiet in that challenge. */
export const OVERTAKEN_COOLDOWN_MS = 30 * 60 * 1000;

/** The push title. Casual, no exclamation mark (see the copy rules in CLAUDE.md). */
export const OVERTAKEN_TITLE = "You got passed";

/**
 * Most a single upload will evaluate. Nothing caps how many challenges a person
 * joins (D15), and the work happens under a row lock, so an outlier with 200
 * live challenges must not turn one catch into 200 locked transactions. The
 * soonest-ending ones win, which are the ones anyone is watching.
 */
export const MAX_LIVE_CHALLENGES_PER_EVALUATION = 20;

/** Hard ceiling on one APNs send, because sends happen inside the challenge lock. */
export const SEND_DEADLINE_MS = 5_000;

/** The locked challenge an evaluation runs against. */
export interface LockedChallenge {
  id: string;
  name: string;
  startsAt: Date;
  endsAt: Date;
}

/** One participant: their notification state and where they stand right now. */
export interface RosterRow {
  deviceId: string;
  handle: string;
  /** Placement this evaluation computed (competition ranking; ties share). */
  placement: number;
  points: number;
  /** Placement remembered from the previous evaluation; null = never evaluated. */
  lastPlacement: number | null;
  overtakenNotifiedAt: Date | null;
  apnsToken: string | null;
  apnsEnvironment: ApnsEnvironment | null;
}

/**
 * The reads and writes of one evaluation, all on the transaction that holds the
 * challenge row lock. Nothing here escapes that transaction.
 */
export interface OvertakenSession {
  challenge: LockedChallenge;
  /** Active, non-disabled participants, scored and placed. One read + one score. */
  roster(): Promise<RosterRow[]>;
  markNotified(deviceIds: readonly string[], now: Date): Promise<void>;
  recordPlacements(rows: readonly { deviceId: string; placement: number }[]): Promise<void>;
  clearToken(token: string): Promise<void>;
}

export interface OvertakenStore {
  /** Ids of challenges LIVE right now that `deviceId` is an active participant of. */
  liveChallengeIdsForDevice(deviceId: string, now: Date): Promise<string[]>;
  /**
   * Run `body` under `SELECT … FOR UPDATE` on the challenge row. Resolves to
   * null — without calling `body` — when the challenge has vanished, been
   * cancelled, been finalized, or stopped being live since it was listed.
   */
  withLiveChallenge<T>(
    challengeId: string,
    now: Date,
    body: (session: OvertakenSession) => Promise<T>,
  ): Promise<T | null>;
}

/** Just enough of Fastify's logger to be satisfied by a plain object in tests. */
export interface OvertakenLogger {
  debug(obj: Record<string, unknown>, msg: string): void;
  info(obj: Record<string, unknown>, msg: string): void;
  warn(obj: Record<string, unknown>, msg: string): void;
}

export interface OvertakenDeps {
  store: OvertakenStore;
  transport: ApnsTransport;
  log: OvertakenLogger;
  now?: () => Date;
}

export interface OvertakenSummary {
  /** Challenges evaluated. */
  challenges: number;
  /** Participants found to have slipped a place. */
  overtaken: number;
  /** Notifications APNs accepted. */
  pushes: number;
  /** Participants whose send failed transiently and whose baseline was kept for a retry. */
  retryable: number;
}

/**
 * Evaluate every live challenge `deviceId` is in and notify whoever they passed.
 * Resolves with a summary; never rejects.
 */
export async function evaluateOvertaken(
  deps: OvertakenDeps,
  deviceId: string,
  nowArg?: Date,
): Promise<OvertakenSummary> {
  const now = nowArg ?? deps.now?.() ?? new Date();
  const summary: OvertakenSummary = { challenges: 0, overtaken: 0, pushes: 0, retryable: 0 };
  try {
    const live = await deps.store.liveChallengeIdsForDevice(deviceId, now);
    for (const challengeId of live) {
      try {
        const result = await evaluateOne(deps, challengeId, deviceId, now);
        if (result === null) continue; // no longer live by the time we locked it
        summary.challenges++;
        summary.overtaken += result.overtaken;
        summary.pushes += result.pushes;
        summary.retryable += result.retryable;
      } catch (err) {
        // One bad challenge must not cost the others their evaluation.
        deps.log.warn({ err, challengeId }, "overtaken evaluation failed");
      }
    }
    deps.log.info({ deviceId, ...summary }, "overtaken evaluation");
  } catch (err) {
    deps.log.warn({ err, deviceId }, "overtaken evaluation failed");
  }
  return summary;
}

interface OneResult {
  overtaken: number;
  pushes: number;
  retryable: number;
}

function evaluateOne(
  deps: OvertakenDeps,
  challengeId: string,
  uploaderId: string,
  now: Date,
): Promise<OneResult | null> {
  return deps.store.withLiveChallenge(challengeId, now, async (session) => {
    const { challenge } = session;
    const roster = await session.roster();
    if (roster.length === 0) return { overtaken: 0, pushes: 0, retryable: 0 };

    const uploaderHandle = roster.find((r) => r.deviceId === uploaderId)?.handle ?? "someone";
    // A placement is SHARED when more than one row holds it — the copy says
    // "tied for 2nd" rather than claiming a rank nobody has alone.
    const perPlacement = new Map<number, number>();
    for (const r of roster) perPlacement.set(r.placement, (perPlacement.get(r.placement) ?? 0) + 1);

    const notified: string[] = [];
    /**
     * Participants whose baseline must NOT move: they really were passed, and
     * the send failed in a way worth retrying. Advancing them would mean the
     * next evaluation sees no slip and the notification is lost for good. A
     * dead token, a missing token, the cooldown and a disabled sender all DO
     * advance — there is nothing to retry in any of those.
     */
    const keepBaseline = new Set<string>();
    let overtaken = 0;

    for (const row of roster) {
      if (row.deviceId === uploaderId) continue; // never push the uploader
      if (row.lastPlacement === null) continue; // never evaluated → no opinion
      if (row.placement <= row.lastPlacement) continue;
      overtaken++;

      if (!row.apnsToken || !row.apnsEnvironment) continue; // no push address
      if (
        row.overtakenNotifiedAt &&
        now.getTime() - row.overtakenNotifiedAt.getTime() < OVERTAKEN_COOLDOWN_MS
      ) {
        continue; // inside the cooldown
      }

      const payload = overtakenPayload({
        challengeId: challenge.id,
        challengeName: challenge.name,
        byHandle: uploaderHandle,
        placement: row.placement,
        tied: (perPlacement.get(row.placement) ?? 1) > 1,
      });
      const res = await sendWithDeadline(
        deps.transport,
        row.apnsEnvironment,
        row.apnsToken,
        payload,
      );

      if (res.status === 200) {
        notified.push(row.deviceId);
        continue;
      }
      if (isDeadTokenResponse(res)) {
        // The app was deleted, or the token belongs to the other APNs
        // environment. Forget it — a reinstall registers a fresh one — and let
        // the baseline advance: there is nobody to retry for.
        await session.clearToken(row.apnsToken);
        deps.log.info(
          { challengeId: challenge.id, deviceId: row.deviceId, reason: res.reason },
          "cleared a dead APNs token",
        );
        continue;
      }
      if (isTransientFailure(res)) {
        keepBaseline.add(row.deviceId);
        deps.log.warn(
          {
            challengeId: challenge.id,
            deviceId: row.deviceId,
            status: res.status,
            reason: res.reason,
          },
          "overtaken push failed transiently; keeping the baseline so the next catch retries",
        );
        continue;
      }
      // Permanent, but not a dead token (a bad topic, a rejected JWT) — or push
      // simply isn't configured, which is normal and must not shout on every
      // catch.
      const detail = {
        challengeId: challenge.id,
        deviceId: row.deviceId,
        status: res.status,
        reason: res.reason,
      };
      if (res.reason === PUSH_DISABLED_REASON) deps.log.debug(detail, "push disabled; not sent");
      else deps.log.warn(detail, "overtaken push not delivered");
    }

    if (notified.length > 0) await session.markNotified(notified, now);
    // Everyone's placement moves forward, the uploader included — otherwise the
    // person who did the passing would be "overtaken" the moment they slipped
    // back to a placement they'd never been recorded at. Except the retryables.
    const advance = roster
      .filter((r) => !keepBaseline.has(r.deviceId))
      .map((r) => ({ deviceId: r.deviceId, placement: r.placement }));
    await session.recordPlacements(advance);
    return { overtaken, pushes: notified.length, retryable: keepBaseline.size };
  });
}

/**
 * Is this failure worth retrying on the next catch? Rate limiting and server
 * errors are; so is a transport that never answered (status 0) — unless it is
 * the no-op sender, which means push is switched off, not broken.
 */
export function isTransientFailure(res: ApnsResponse): boolean {
  if (res.status === 200 || isDeadTokenResponse(res)) return false;
  if (res.status === 429 || res.status >= 500) return true;
  return res.status === 0 && res.reason !== PUSH_DISABLED_REASON;
}

/**
 * Bound one send, whatever the transport does. `Http2ApnsTransport` has its own
 * deadline, but the transport is an injected seam and a send now happens inside
 * the challenge row lock — a transport that never resolves would hold that lock
 * until the connection pool gave up.
 */
async function sendWithDeadline(
  transport: ApnsTransport,
  env: ApnsEnvironment,
  token: string,
  payload: unknown,
): Promise<ApnsResponse> {
  let timer: NodeJS.Timeout | undefined;
  try {
    return await Promise.race([
      transport.send(env, token, payload),
      new Promise<ApnsResponse>((resolve) => {
        timer = setTimeout(() => resolve({ status: 0, reason: "timeout" }), SEND_DEADLINE_MS);
        timer.unref?.();
      }),
    ]);
  } catch (err) {
    // A transport that REJECTS is a transport bug; treat it as transient so the
    // notification isn't silently dropped, and never let it escape.
    return { status: 0, reason: err instanceof Error ? err.message : "send failed" };
  } finally {
    clearTimeout(timer);
  }
}

// ── Copy ─────────────────────────────────────────────────────────────────────

export interface OvertakenCopyInput {
  challengeId: string;
  challengeName: string;
  /** The handle of whoever just went past, without the "@". */
  byHandle: string;
  placement: number;
  tied: boolean;
}

/** "2nd", "3rd", "11th", "21st" — English ordinals, teens included. */
export function ordinal(n: number): string {
  const abs = Math.abs(Math.trunc(n));
  const tens = abs % 100;
  if (tens >= 11 && tens <= 13) return `${n}th`;
  switch (abs % 10) {
    case 1:
      return `${n}st`;
    case 2:
      return `${n}nd`;
    case 3:
      return `${n}rd`;
    default:
      return `${n}th`;
  }
}

/** "You're now 3rd." / "You're now tied for 2nd." */
export function placementPhrase(placement: number, tied: boolean): string {
  return tied ? `tied for ${ordinal(placement)}` : ordinal(placement);
}

/**
 * The exact APNs payload. The iOS client is built against this shape:
 * `thread-id` groups a challenge's notifications, and the top-level
 * `challengeId` / `kind` are what the tap handler routes on. Changing any key
 * here is a client-visible contract change.
 */
export function overtakenPayload(input: OvertakenCopyInput): Record<string, unknown> {
  const body = `@${input.byHandle} just passed you in ${input.challengeName}. You're now ${placementPhrase(
    input.placement,
    input.tied,
  )}.`;
  return {
    aps: {
      alert: { title: OVERTAKEN_TITLE, body },
      sound: "default",
      "thread-id": input.challengeId,
    },
    challengeId: input.challengeId,
    kind: "overtaken",
  };
}

// ── Drizzle implementation ───────────────────────────────────────────────────

/** The transaction handle Drizzle hands `db.transaction(…)`. */
type Tx = Parameters<Parameters<Database["transaction"]>[0]>[0];

export class DrizzleOvertakenStore implements OvertakenStore {
  constructor(
    private readonly db: Database,
    private readonly scorer: ChallengeScorer,
  ) {}

  async liveChallengeIdsForDevice(deviceId: string, now: Date): Promise<string[]> {
    const rows = await withDbRetry(() =>
      this.db
        .select({ id: challenges.id })
        .from(challengeParticipants)
        .innerJoin(challenges, eq(challenges.id, challengeParticipants.challengeId))
        .where(
          and(
            eq(challengeParticipants.deviceId, deviceId),
            isNull(challengeParticipants.leftAt),
            isNull(challenges.cancelledAt),
            // LIVE: started, not yet ended. `finalized_at` is null by
            // construction for those, but the guard keeps a clock-skewed row out.
            isNull(challenges.finalizedAt),
            // `lte`/`gt` and NOT a raw sql template: a JS Date interpolated into
            // `sql\`…\`` is wrapped in Drizzle's noop encoder and reaches
            // postgres.js unconverted, where the bind crashes ("string argument
            // must be of type string… Received an instance of Date"). PGlite
            // serialises it happily, so the failure is production-only — the
            // repo has this scar already (lesson: postgres.js raw-sql Date).
            // The column helpers run the timestamp encoder and hand over an
            // ISO string.
            lte(challenges.startsAt, now),
            gt(challenges.endsAt, now),
          ),
        )
        .orderBy(asc(challenges.endsAt))
        .limit(MAX_LIVE_CHALLENGES_PER_EVALUATION),
    );
    return rows.map((r) => r.id);
  }

  withLiveChallenge<T>(
    challengeId: string,
    now: Date,
    body: (session: OvertakenSession) => Promise<T>,
  ): Promise<T | null> {
    return this.db.transaction(async (tx) => {
      // The SAME lock `join`, `leave` and finalization take, in the same order,
      // so an evaluation can neither interleave with them nor with another
      // evaluation of this challenge.
      const locked = await tx
        .select({
          id: challenges.id,
          name: challenges.name,
          startsAt: challenges.startsAt,
          endsAt: challenges.endsAt,
          cancelledAt: challenges.cancelledAt,
          finalizedAt: challenges.finalizedAt,
        })
        .from(challenges)
        .where(eq(challenges.id, challengeId))
        .for("update");
      const row = locked[0];
      if (!row || row.cancelledAt || row.finalizedAt) return null;
      const startsAt = new Date(row.startsAt);
      const endsAt = new Date(row.endsAt);
      // Re-derive liveness from the LOCKED row: the window can have closed, or
      // the challenge been cancelled, since it was listed.
      if (now.getTime() < startsAt.getTime() || now.getTime() >= endsAt.getTime()) return null;
      return body(
        new TxOvertakenSession(tx, this.scorer, { id: row.id, name: row.name, startsAt, endsAt }),
      );
    });
  }
}

/** One evaluation's reads and writes, all on the locking transaction. */
class TxOvertakenSession implements OvertakenSession {
  constructor(
    private readonly tx: Tx,
    private readonly scorer: ChallengeScorer,
    readonly challenge: LockedChallenge,
  ) {}

  async roster(): Promise<RosterRow[]> {
    const rows = await this.tx
      .select({
        deviceId: challengeParticipants.deviceId,
        handle: devices.handle,
        lastPlacement: challengeParticipants.lastPlacement,
        overtakenNotifiedAt: challengeParticipants.overtakenNotifiedAt,
        apnsToken: devices.apnsToken,
        apnsEnvironment: devices.apnsEnvironment,
      })
      .from(challengeParticipants)
      .innerJoin(devices, eq(devices.id, challengeParticipants.deviceId))
      .where(
        and(
          eq(challengeParticipants.challengeId, this.challenge.id),
          // Someone who left is not in the race: no placement, no notification.
          isNull(challengeParticipants.leftAt),
          isNull(devices.disabledAt),
        ),
      );
    if (rows.length === 0) return [];

    const scores = await this.scorer.score(
      { startsAt: this.challenge.startsAt, endsAt: this.challenge.endsAt },
      rows.map((r) => r.deviceId),
      this.tx,
    );
    const byDevice = new Map(scores.map((s) => [s.deviceId, s]));
    // The same competition ranking (ties share, next placement skipped) the
    // standings endpoint shows — the number in the push must match the screen.
    return assignPlacements(
      rows.map((r) => ({
        deviceId: r.deviceId,
        handle: r.handle ?? "spotter",
        points: byDevice.get(r.deviceId)?.points ?? 0,
        lastPlacement: r.lastPlacement,
        overtakenNotifiedAt: r.overtakenNotifiedAt ? new Date(r.overtakenNotifiedAt) : null,
        apnsToken: r.apnsToken,
        apnsEnvironment: isApnsEnvironment(r.apnsEnvironment) ? r.apnsEnvironment : null,
      })),
    );
  }

  async markNotified(deviceIds: readonly string[], now: Date): Promise<void> {
    if (deviceIds.length === 0) return;
    await this.tx
      .update(challengeParticipants)
      .set({ overtakenNotifiedAt: now })
      .where(
        and(
          eq(challengeParticipants.challengeId, this.challenge.id),
          inArray(challengeParticipants.deviceId, [...deviceIds]),
        ),
      );
  }

  async recordPlacements(rows: readonly { deviceId: string; placement: number }[]): Promise<void> {
    if (rows.length === 0) return;
    // One UPDATE … FROM (VALUES …) rather than a loop: the roster is small but
    // this runs after every catch, and a round trip per participant is the kind
    // of thing that quietly becomes the slowest part of an upload. Only ids and
    // integers are interpolated — never a Date (see liveChallengeIdsForDevice).
    const values: SQL[] = rows.map((r) => sql`(${r.deviceId}::uuid, ${r.placement}::integer)`);
    await this.tx.execute(sql`
      update "challenge_participants" as p
      set "last_placement" = v.placement
      from (values ${sql.join(values, sql`, `)}) as v(device_id, placement)
      where p."challenge_id" = ${this.challenge.id}::uuid and p."device_id" = v.device_id
    `);
  }

  async clearToken(token: string): Promise<void> {
    await this.tx
      .update(devices)
      .set({ apnsToken: null, apnsEnvironment: null })
      .where(eq(devices.apnsToken, token));
  }
}
