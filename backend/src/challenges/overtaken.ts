/**
 * "Someone passed you" pushes for a LIVE challenge.
 *
 * THE TRIGGER is a successful catch upload. After the reply has been sent, the
 * catches route schedules `evaluateOvertaken` for the uploading device
 * (`setImmediate`, fire-and-forget): for every live challenge that device is
 * still in, we re-derive the standings and compare each participant's new
 * placement against the one they held at the previous evaluation
 * (`challenge_participants.last_placement`). A numerically WORSE placement means
 * somebody went past them, and the person who just uploaded is who to name.
 *
 * WHY A STORED last_placement AND NOT A DIFF OF TWO LIVE READS. The standings
 * before the catch aren't available by the time we run — the row is already
 * committed — and re-scoring "as of a moment ago" would be a second, more
 * expensive query that still couldn't see a join or a leave. A remembered
 * placement is one integer, it survives a restart, and it makes the rule
 * legible: you are told when the number on your screen got worse since the last
 * time anything happened. It is seeded at join (and at create, for the creator)
 * so the very first evaluation compares against something real; a null is
 * always treated as "no opinion", never as placement 0.
 *
 * WHAT IT WILL NOT DO:
 *   - notify the uploader about their own catch,
 *   - fire for an upcoming, finished or cancelled challenge (only `live`),
 *   - reach a disabled device (they are invisible in standings, as everywhere),
 *   - notify the same person twice within 30 minutes in the same challenge
 *     (a lead that changes hands five times is one notification, not five),
 *   - throw. Every failure is logged and swallowed: a catch upload has already
 *     been answered 201 by the time this runs, and push is a garnish.
 *
 * COST is one standings query per live challenge the uploader is in, plus one
 * participant read and one batched placement write. A device is in a handful of
 * challenges at most (D15 sets no cap, but the hub shows 50), and the whole
 * thing runs off the request path.
 */

import { type SQL, and, eq, inArray, isNull, lte, sql } from "drizzle-orm";
import type { Database } from "../db/client.js";
import { withDbRetry } from "../db/retry.js";
import { challengeParticipants, challenges, devices } from "../db/schema.js";
import {
  type ApnsEnvironment,
  type ApnsTransport,
  isApnsEnvironment,
  isDeadTokenResponse,
} from "../push/apns.js";
import type { ChallengeStore, Standing } from "./store.js";

/** How long after telling someone they were passed we stay quiet in that challenge. */
export const OVERTAKEN_COOLDOWN_MS = 30 * 60 * 1000;

/** The push title. Casual, no exclamation mark (see the copy rules in CLAUDE.md). */
export const OVERTAKEN_TITLE = "You got passed";

/** A live challenge the uploader is in — the only fields the evaluation needs. */
export interface LiveChallengeRef {
  id: string;
  name: string;
}

/** One participant's notification state. */
export interface NotifyState {
  deviceId: string;
  handle: string;
  lastPlacement: number | null;
  overtakenNotifiedAt: Date | null;
  apnsToken: string | null;
  apnsEnvironment: ApnsEnvironment | null;
}

export interface OvertakenStore {
  /** Challenges that are LIVE right now and that `deviceId` is an active participant of. */
  liveChallengesForDevice(deviceId: string, now: Date): Promise<LiveChallengeRef[]>;
  /** The current standings for a live challenge (the challenge store's live projection). */
  standingsFor(challengeId: string, now: Date): Promise<Standing[]>;
  /** Notification state for every active, non-disabled participant. */
  notifyStateFor(challengeId: string): Promise<NotifyState[]>;
  /** Write the placements everyone holds right now. One statement. */
  recordPlacements(
    challengeId: string,
    rows: readonly { deviceId: string; placement: number }[],
  ): Promise<void>;
  /** Stamp the cooldown for the devices we just notified. */
  markNotified(challengeId: string, deviceIds: readonly string[], now: Date): Promise<void>;
  /** Forget a token APNs told us is dead, wherever it is. */
  clearToken(token: string): Promise<void>;
}

/** Just enough of Fastify's logger to be satisfied by a plain object in tests. */
export interface OvertakenLogger {
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
  const summary: OvertakenSummary = { challenges: 0, overtaken: 0, pushes: 0 };
  try {
    const live = await deps.store.liveChallengesForDevice(deviceId, now);
    for (const challenge of live) {
      try {
        summary.challenges++;
        const result = await evaluateOne(deps, challenge, deviceId, now);
        summary.overtaken += result.overtaken;
        summary.pushes += result.pushes;
      } catch (err) {
        // One bad challenge must not cost the others their evaluation.
        deps.log.warn({ err, challengeId: challenge.id }, "overtaken evaluation failed");
      }
    }
    deps.log.info({ deviceId, ...summary }, "overtaken evaluation");
  } catch (err) {
    deps.log.warn({ err, deviceId }, "overtaken evaluation failed");
  }
  return summary;
}

async function evaluateOne(
  deps: OvertakenDeps,
  challenge: LiveChallengeRef,
  uploaderId: string,
  now: Date,
): Promise<{ overtaken: number; pushes: number }> {
  const standings = await deps.store.standingsFor(challenge.id, now);
  if (standings.length === 0) return { overtaken: 0, pushes: 0 };
  const state = new Map(
    (await deps.store.notifyStateFor(challenge.id)).map((s) => [s.deviceId, s]),
  );

  const uploaderHandle =
    standings.find((s) => s.deviceId === uploaderId)?.handle ??
    state.get(uploaderId)?.handle ??
    "someone";
  // A placement is SHARED when more than one row holds it — the copy says
  // "tied for 2nd" rather than claiming a rank nobody has alone.
  const perPlacement = new Map<number, number>();
  for (const s of standings)
    perPlacement.set(s.placement, (perPlacement.get(s.placement) ?? 0) + 1);

  const notified: string[] = [];
  let overtaken = 0;
  for (const standing of standings) {
    if (standing.deviceId === uploaderId) continue; // never push the uploader
    const p = state.get(standing.deviceId);
    // `last_placement` null = never evaluated (a row from before this feature,
    // or a seed that never landed). Seeding is the join path's job; here it is
    // simply "no opinion", and no opinion never notifies.
    if (!p || p.lastPlacement === null) continue;
    if (standing.placement <= p.lastPlacement) continue;
    overtaken++;

    if (!p.apnsToken || !p.apnsEnvironment) continue; // no push address
    if (
      p.overtakenNotifiedAt &&
      now.getTime() - p.overtakenNotifiedAt.getTime() < OVERTAKEN_COOLDOWN_MS
    ) {
      continue; // inside the cooldown
    }

    const payload = overtakenPayload({
      challengeId: challenge.id,
      challengeName: challenge.name,
      byHandle: uploaderHandle,
      placement: standing.placement,
      tied: (perPlacement.get(standing.placement) ?? 1) > 1,
    });
    const res = await deps.transport.send(p.apnsEnvironment, p.apnsToken, payload);
    if (res.status === 200) {
      notified.push(standing.deviceId);
      continue;
    }
    if (isDeadTokenResponse(res)) {
      // The app was deleted, or the token belongs to the other APNs
      // environment. Forget it — a reinstall registers a fresh one.
      await deps.store.clearToken(p.apnsToken);
      deps.log.info(
        { challengeId: challenge.id, deviceId: standing.deviceId, reason: res.reason },
        "cleared a dead APNs token",
      );
      continue;
    }
    deps.log.warn(
      {
        challengeId: challenge.id,
        deviceId: standing.deviceId,
        status: res.status,
        reason: res.reason,
      },
      "overtaken push not delivered",
    );
  }

  if (notified.length > 0) await deps.store.markNotified(challenge.id, notified, now);
  // Everyone's placement moves forward, the uploader included — otherwise the
  // person who did the passing would be "overtaken" the moment they slipped
  // back to a placement they'd never been recorded at.
  await deps.store.recordPlacements(
    challenge.id,
    standings.map((s) => ({ deviceId: s.deviceId, placement: s.placement })),
  );
  return { overtaken, pushes: notified.length };
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

export class DrizzleOvertakenStore implements OvertakenStore {
  constructor(
    private readonly db: Database,
    private readonly challenges: Pick<ChallengeStore, "findById" | "standings">,
  ) {}

  async liveChallengesForDevice(deviceId: string, now: Date): Promise<LiveChallengeRef[]> {
    const rows = await withDbRetry(() =>
      this.db
        .select({ id: challenges.id, name: challenges.name })
        .from(challengeParticipants)
        .innerJoin(challenges, eq(challenges.id, challengeParticipants.challengeId))
        .where(
          and(
            eq(challengeParticipants.deviceId, deviceId),
            isNull(challengeParticipants.leftAt),
            isNull(challenges.cancelledAt),
            // LIVE: started, not yet ended. `finalized_at` is null by
            // construction for those, but the guard costs nothing and keeps a
            // clock-skewed row out.
            isNull(challenges.finalizedAt),
            lte(challenges.startsAt, now),
            sql`${challenges.endsAt} > ${now}`,
          ),
        ),
    );
    return rows;
  }

  async standingsFor(challengeId: string, now: Date): Promise<Standing[]> {
    const challenge = await this.challenges.findById(challengeId);
    if (!challenge) return [];
    return (await this.challenges.standings(challenge, now)).standings;
  }

  async notifyStateFor(challengeId: string): Promise<NotifyState[]> {
    const rows = await withDbRetry(() =>
      this.db
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
            eq(challengeParticipants.challengeId, challengeId),
            isNull(challengeParticipants.leftAt),
            isNull(devices.disabledAt),
          ),
        ),
    );
    return rows.map((r) => ({
      deviceId: r.deviceId,
      handle: r.handle ?? "spotter",
      lastPlacement: r.lastPlacement,
      overtakenNotifiedAt: r.overtakenNotifiedAt ? new Date(r.overtakenNotifiedAt) : null,
      apnsToken: r.apnsToken,
      apnsEnvironment: isApnsEnvironment(r.apnsEnvironment) ? r.apnsEnvironment : null,
    }));
  }

  async recordPlacements(
    challengeId: string,
    rows: readonly { deviceId: string; placement: number }[],
  ): Promise<void> {
    if (rows.length === 0) return;
    // One UPDATE … FROM (VALUES …) rather than a loop: the roster is small but
    // this runs after every catch, and a round trip per participant is the
    // kind of thing that quietly becomes the slowest part of an upload.
    const values: SQL[] = rows.map((r) => sql`(${r.deviceId}::uuid, ${r.placement}::integer)`);
    await this.db.execute(sql`
      update "challenge_participants" as p
      set "last_placement" = v.placement
      from (values ${sql.join(values, sql`, `)}) as v(device_id, placement)
      where p."challenge_id" = ${challengeId}::uuid and p."device_id" = v.device_id
    `);
  }

  async markNotified(challengeId: string, deviceIds: readonly string[], now: Date): Promise<void> {
    if (deviceIds.length === 0) return;
    await this.db
      .update(challengeParticipants)
      .set({ overtakenNotifiedAt: now })
      .where(
        and(
          eq(challengeParticipants.challengeId, challengeId),
          inArray(challengeParticipants.deviceId, [...deviceIds]),
        ),
      );
  }

  async clearToken(token: string): Promise<void> {
    await this.db
      .update(devices)
      .set({ apnsToken: null, apnsEnvironment: null })
      .where(eq(devices.apnsToken, token));
  }
}
