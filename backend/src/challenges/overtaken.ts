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
 * THREE PHASES, AND THE NETWORK IS NOT IN THE LOCKED ONE.
 *
 *   1. Under `SELECT … FOR UPDATE` on the challenge row — the same lock `join`,
 *      `leave` and finalization take — read the roster, decide who gets a
 *      notification, write EVERYONE's new `last_placement` and stamp
 *      `overtaken_notified_at` for the recipients, then COMMIT. No I/O but the
 *      database. Two phones uploading in the same second are serialised here,
 *      so they cannot both read a stale board, both push the same person inside
 *      what each thinks is a fresh cooldown, and then clobber each other's
 *      placements.
 *   2. Outside any transaction, send to all recipients IN PARALLEL, each capped
 *      at `SEND_DEADLINE_MS`. An earlier version sent inside the lock, which
 *      was a real outage waiting to happen: nine recipients × a 5 s APNs
 *      timeout is a 45 s lock, and `db/client.ts` sets `statement_timeout` to
 *      5 s — so every concurrent join, leave, finalize and standings read on
 *      that challenge would have 500'd while we waited on Apple.
 *   3. In a second, short transaction, undo phase 1 for the sends that failed
 *      in a retryable way: restore those participants' previous
 *      `last_placement` and `overtaken_notified_at`, so the next catch sees the
 *      slip again and tries once more. Optimistic write, compensating undo —
 *      the alternative (write after sending) would leave the lock open across
 *      the network again.
 *
 * THE WINDOW THE OPTIMISM OPENS, HONESTLY. Phase 3 takes no lock and its UPDATE
 * is unconditional — last write wins — so an evaluation that ran in between and
 * recorded a fresher placement can have it overwritten with the pre-round one.
 * That asymmetry is deliberate and it only ever errs LOUD:
 *   - Nobody is pushed twice inside a live cooldown. The decision and the
 *     `overtaken_notified_at` stamp both happen in phase 1, under the row lock,
 *     so two concurrent evaluations are serialised and the second sees the
 *     stamp the first wrote.
 *   - A revert restores a baseline from BEFORE the slip, which is never worse
 *     (numerically larger) than the placement that triggered the push, so a
 *     later real slip can't be hidden by it. No notification is lost this way.
 *   - The price is at most one DUPLICATE: a 5xx that actually delivered, or a
 *     concurrent evaluation's push whose cooldown stamp our revert erased, can
 *     produce a second "you got passed" on the next catch. One repeat beats a
 *     silence, which is the trade the whole retryable path is making.
 * And if the process dies between phase 1 and phase 3, a participant silently
 * misses one notification. All of it beats a 45-second lock on a live challenge.
 *
 * WHAT IT WILL NOT DO:
 *   - notify the uploader about their own catch,
 *   - fire for an upcoming, finished or cancelled challenge (only `live`),
 *   - reach a disabled device, or one that has left (they are invisible in
 *     standings, as everywhere),
 *   - notify the same person twice within 30 minutes in the same challenge
 *     (a lead that changes hands five times is one notification, not five) —
 *     the one exception being the reverted-cooldown case above, which can
 *     repeat a notification that was reported as failed but actually landed,
 *   - lose a notification to a blip: a transient send failure has that
 *     participant's baseline and cooldown RESTORED in phase 3, so the next
 *     catch sees the slip again and tries once more,
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
import { CLEARED_PUSH_TOKEN } from "../identity/store.js";
import {
  type ApnsEnvironment,
  type ApnsResponse,
  type ApnsTransport,
  PUSH_DISABLED_REASON,
  isApnsEnvironment,
  isDeadTokenResponse,
  isProviderTokenFailure,
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

/**
 * Hard ceiling on one APNs send. Sends run outside every transaction (phase 2),
 * so this no longer guards a lock — it bounds how long a catch upload's
 * after-work stays alive, since the whole batch is awaited together.
 */
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
}

/** What phase 3 puts back when a send failed in a retryable way. */
export interface RevertRow {
  deviceId: string;
  lastPlacement: number | null;
  overtakenNotifiedAt: Date | null;
}

export interface OvertakenStore {
  /** Ids of challenges LIVE right now that `deviceId` is an active participant of. */
  liveChallengeIdsForDevice(deviceId: string, now: Date): Promise<string[]>;
  /**
   * Run `body` under `SELECT … FOR UPDATE` on the challenge row. Resolves to
   * null — without calling `body` — when the challenge has vanished, been
   * cancelled, been finalized, or stopped being live since it was listed.
   *
   * Nothing slow belongs in `body`: the lock is held for its whole duration and
   * `statement_timeout` is 5 s for everyone else on this challenge.
   */
  withLiveChallenge<T>(
    challengeId: string,
    now: Date,
    body: (session: OvertakenSession) => Promise<T>,
  ): Promise<T | null>;
  /**
   * Phase 3: put back the pre-round baseline and cooldown for participants
   * whose notification didn't make it. Its own short transaction and NO lock,
   * so it is a blind last-write-wins UPDATE: it can stamp the pre-round values
   * over a fresher placement a concurrent evaluation wrote. That is the
   * accepted cost (see the header) — it can cost a duplicate push, never a
   * lost one — and taking the lock again would cost everyone else on this
   * challenge their 5-second statement timeout.
   */
  revertRound(challengeId: string, rows: readonly RevertRow[]): Promise<void>;
  /** Forget a token APNs told us is dead, wherever it is. Outside the lock. */
  clearToken(token: string): Promise<void>;
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

/** One recipient, decided under the lock and sent after it. */
interface Recipient {
  deviceId: string;
  token: string;
  environment: ApnsEnvironment;
  payload: Record<string, unknown>;
  /** What to put back if the send fails retryably (phase 3). */
  previous: RevertRow;
}

async function evaluateOne(
  deps: OvertakenDeps,
  challengeId: string,
  uploaderId: string,
  now: Date,
): Promise<OneResult | null> {
  // ── Phase 1: decide and write, under the lock, with no network in sight ───
  const plan = await deps.store.withLiveChallenge(challengeId, now, async (session) => {
    const { challenge } = session;
    const roster = await session.roster();
    if (roster.length === 0) return null;

    const uploader = roster.find((r) => r.deviceId === uploaderId);
    // A placement is SHARED when more than one row holds it — the copy says
    // "tied for 2nd" rather than claiming a rank nobody has alone.
    const perPlacement = new Map<number, number>();
    for (const r of roster) perPlacement.set(r.placement, (perPlacement.get(r.placement) ?? 0) + 1);

    const recipients: Recipient[] = [];
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

      recipients.push({
        deviceId: row.deviceId,
        token: row.apnsToken,
        environment: row.apnsEnvironment,
        payload: overtakenPayload({
          challengeId: challenge.id,
          challengeName: challenge.name,
          // ATTRIBUTE ONLY WHEN WE CAN PROVE IT. The uploader is not
          // necessarily the person who passed this participant: the baseline
          // can predate somebody else's catch (a transient failure held it, an
          // evaluation was skipped, the seed is older than the board), and
          // naming the wrong competitor is worse than naming none.
          byHandle: crossedThisRound(uploader, row) ? (uploader?.handle ?? null) : null,
          placement: row.placement,
          tied: (perPlacement.get(row.placement) ?? 1) > 1,
        }),
        previous: {
          deviceId: row.deviceId,
          lastPlacement: row.lastPlacement,
          overtakenNotifiedAt: row.overtakenNotifiedAt,
        },
      });
    }

    // Optimistic writes: everyone's placement moves forward (the uploader's
    // included — otherwise the person who did the passing would be "overtaken"
    // the moment they slipped back to a placement they'd never been recorded
    // at), and every recipient's cooldown is stamped now so a simultaneous
    // upload can't double-notify. Phase 3 undoes the ones that don't land.
    await session.recordPlacements(
      roster.map((r) => ({ deviceId: r.deviceId, placement: r.placement })),
    );
    if (recipients.length > 0) {
      await session.markNotified(
        recipients.map((r) => r.deviceId),
        now,
      );
    }
    return { challenge, recipients, overtaken };
  });

  if (plan === null) return null;
  const { challenge, recipients, overtaken } = plan;
  if (recipients.length === 0) return { overtaken, pushes: 0, retryable: 0 };

  // ── Phase 2: send, outside every transaction, all at once ────────────────
  const results = await Promise.all(
    recipients.map(async (recipient) => ({
      recipient,
      res: await sendWithDeadline(
        deps.transport,
        recipient.environment,
        recipient.token,
        recipient.payload,
      ),
    })),
  );

  // ── Phase 3: compensate ──────────────────────────────────────────────────
  const revert: RevertRow[] = [];
  const deadTokens: string[] = [];
  let pushes = 0;
  for (const { recipient, res } of results) {
    const detail = {
      challengeId: challenge.id,
      deviceId: recipient.deviceId,
      status: res.status,
      reason: res.reason,
    };
    if (res.status === 200) {
      pushes++;
      continue;
    }
    if (isDeadTokenResponse(res)) {
      // The app was deleted, or the token belongs to the other APNs
      // environment. Forget it — a reinstall registers a fresh one — and leave
      // the baseline advanced: there is nobody to retry for.
      deadTokens.push(recipient.token);
      deps.log.info(detail, "cleared a dead APNs token");
      continue;
    }
    if (isTransientFailure(res)) {
      revert.push(recipient.previous);
      deps.log.warn(
        detail,
        "overtaken push failed transiently; restoring the baseline so the next catch retries",
      );
      continue;
    }
    // Permanent, but not a dead token (a bad topic) — or push simply isn't
    // configured, which is normal and must not shout on every catch.
    if (res.reason === PUSH_DISABLED_REASON) deps.log.debug(detail, "push disabled; not sent");
    else deps.log.warn(detail, "overtaken push not delivered");
  }

  if (revert.length > 0) await deps.store.revertRound(challenge.id, revert);
  for (const token of new Set(deadTokens)) await deps.store.clearToken(token);
  return { overtaken, pushes, retryable: revert.length };
}

/**
 * Did the uploader personally cross this participant in THIS round?
 *
 * Placements are golf scores — lower is better. The uploader crossed `row` when
 * they were level with or behind them at the last evaluation and are ahead of
 * them now. With no remembered placement for the uploader we cannot tell, so we
 * don't claim.
 */
function crossedThisRound(uploader: RosterRow | undefined, row: RosterRow): boolean {
  if (!uploader || uploader.lastPlacement === null || row.lastPlacement === null) return false;
  return uploader.lastPlacement >= row.lastPlacement && uploader.placement < row.placement;
}

/**
 * Is this failure worth retrying on the next catch? Rate limiting and server
 * errors are; so is a transport that never answered (status 0) — unless it is
 * the no-op sender, which means push is switched off, not broken.
 *
 * So is a rejected PROVIDER token (a 403 `ExpiredProviderToken` and friends):
 * that is our signing credential being refused, not the recipient's address.
 * The notification is perfectly good and will go through once the JWT is
 * re-minted — which the transport does the moment it sees one of these — so
 * treating it as permanent would throw away a real notification over a
 * self-inflicted, self-healing problem.
 */
export function isTransientFailure(res: ApnsResponse): boolean {
  if (res.status === 200 || isDeadTokenResponse(res)) return false;
  if (res.status === 429 || res.status >= 500) return true;
  if (isProviderTokenFailure(res)) return true;
  return res.status === 0 && res.reason !== PUSH_DISABLED_REASON;
}

/**
 * Bound one send, whatever the transport does. `Http2ApnsTransport` has its own
 * deadline, but the transport is an injected seam: a fake that never resolves
 * would hang phase 2's `Promise.all` forever, and with it the compensating
 * phase 3 that puts the failed recipients' baselines back.
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
  /**
   * The handle of whoever just went past, without the "@" — or null when we
   * can't prove who it was, which produces the nameless variant. Naming a
   * competitor who didn't actually pass anyone is a worse notification than
   * naming nobody.
   */
  byHandle: string | null;
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
  const place = placementPhrase(input.placement, input.tied);
  const body =
    input.byHandle === null
      ? `You've dropped to ${place} in ${input.challengeName}.`
      : `@${input.byHandle} just passed you in ${input.challengeName}. You're now ${place}.`;
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

  async revertRound(challengeId: string, rows: readonly RevertRow[]): Promise<void> {
    if (rows.length === 0) return;
    // Deliberately NOT under the challenge lock, and deliberately unconditional
    // — this runs after the network, and re-taking the lock to compare would
    // cost everyone else on this challenge their 5-second statement timeout for
    // a write whose only job is to make a retry possible. So it is last-write-
    // wins: if a concurrent evaluation recorded a fresher placement in the
    // meantime, these pre-round values land on top of it. The restored baseline
    // is from before the slip, so it can only make the next evaluation MORE
    // willing to notify — at worst a duplicate push, never a lost one.
    await this.db.transaction(async (tx) => {
      for (const row of rows) {
        await tx
          .update(challengeParticipants)
          .set({
            lastPlacement: row.lastPlacement,
            overtakenNotifiedAt: row.overtakenNotifiedAt,
          })
          .where(
            and(
              eq(challengeParticipants.challengeId, challengeId),
              eq(challengeParticipants.deviceId, row.deviceId),
            ),
          );
      }
    });
  }

  async clearToken(token: string): Promise<void> {
    await this.db.update(devices).set(CLEARED_PUSH_TOKEN).where(eq(devices.apnsToken, token));
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
}
