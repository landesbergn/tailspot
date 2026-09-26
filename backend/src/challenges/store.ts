/**
 * The challenge store (Challenges v1, spec §10).
 *
 * Same seam pattern as `IdentityStore` / `CatchStore`: the routes depend only
 * on the `ChallengeStore` interface, the Drizzle implementation is injected
 * (tests: PGlite; production: the shared Postgres handle). Scoring is
 * delegated to a `ChallengeScorer` (see scorer.ts) so a future quest kind
 * changes the scorer, not this file.
 *
 * Rules implemented here (all from the spec, all decided):
 *   - Status is DERIVED from the clock, never stored.
 *   - Join until `endsAt`; a joiner's earlier in-window catches count (D3).
 *   - Ties share placement (competition ranking); No Contest when fewer than
 *     two active participants remain or nobody scored (D4).
 *   - Cancel: creator only, before start (D5). Creator leaving before start
 *     cancels (D6). Leaving is allowed until `endsAt`.
 *   - No upload grace (D9) — see scorer.ts.
 *   - Finalization is decide-on-read: the first read after `endsAt` freezes
 *     results in one transaction; idempotent, so two concurrent readers
 *     can't double-freeze or disagree.
 *   - Growth attribution (D19): a device that registered within 7 days and
 *     had never joined before is marked `joined_as_new_device` and gets
 *     `devices.referred_by_challenge_id` stamped once.
 *   - Disabled devices are invisible everywhere (participants, standings,
 *     logs) and cannot join — the same posture as the leaderboard.
 */

import { and, asc, desc, eq, gt, isNotNull, isNull, lte, or, sql } from "drizzle-orm";
import { alias } from "drizzle-orm/pg-core";
import type { Database } from "../db/client.js";
import { withDbRetry } from "../db/retry.js";
import {
  catches,
  challengeParticipants,
  challengeResults,
  challenges,
  devices,
  typecodes,
} from "../db/schema.js";
import { generateInviteCode } from "./codes.js";
import { type Outcome, assignPlacements, decideOutcome } from "./placement.js";
import { type ChallengeScorer, type Executor, inWindow } from "./scorer.js";

// ── Types ─────────────────────────────────────────────────────────────────────

export type DurationPreset = "1h" | "24h" | "3d" | "7d";

export const DURATION_MS: Record<DurationPreset, number> = {
  "1h": 60 * 60 * 1000,
  "24h": 24 * 60 * 60 * 1000,
  "3d": 3 * 24 * 60 * 60 * 1000,
  "7d": 7 * 24 * 60 * 60 * 1000,
};

export function isDurationPreset(v: unknown): v is DurationPreset {
  return v === "1h" || v === "24h" || v === "3d" || v === "7d";
}

export type ChallengeStatus = "upcoming" | "live" | "finished" | "cancelled";

export interface Challenge {
  id: string;
  kind: string;
  code: string | null;
  name: string;
  creatorDeviceId: string;
  creatorHandle: string | null;
  startsAt: Date;
  endsAt: Date;
  durationPreset: string;
  maxParticipants: number;
  cancelledAt: Date | null;
  finalizedAt: Date | null;
  outcome: Outcome | null;
  createdAt: Date;
}

/** Derived, never stored (spec §10.1). */
export function challengeStatus(c: Challenge, now: Date): ChallengeStatus {
  if (c.cancelledAt) return "cancelled";
  if (now.getTime() < c.startsAt.getTime()) return "upcoming";
  if (now.getTime() < c.endsAt.getTime()) return "live";
  return "finished";
}

export interface Participant {
  deviceId: string;
  handle: string;
  joinedAt: Date;
}

export interface Standing {
  deviceId: string;
  handle: string;
  placement: number;
  points: number;
  catches: number;
  rarityBreakdown: Record<string, number>;
}

export interface StandingsResult {
  standings: Standing[];
  /** Live outcome projection (what finalization WOULD decide right now). */
  outcome: Outcome;
}

export interface CatchLogRow {
  /** "Boeing 737-800" — make + model only, never callsign/registration/hex. */
  aircraft: string;
  rarity: string | null;
  points: number;
  caughtAt: Date;
}

export interface NewChallenge {
  name: string;
  creatorDeviceId: string;
  startsAt: Date;
  durationPreset: DurationPreset;
}

export type JoinResult =
  | { ok: true; alreadyIn: boolean; newDevice: boolean }
  | { ok: false; reason: "full" | "closed" | "disabled" };

export type LeaveResult = "left" | "cancelled" | "not_participant" | "closed";

export type ListScope = "open" | "history" | "both";

export interface MyResult {
  placement: number;
  points: number;
  catches: number;
}

/** One hub row: the challenge plus what the list needs, in one read. */
export interface ChallengeListRow {
  challenge: Challenge;
  participantCount: number;
  /** Frozen result for the caller; null while open or when No Contest left no rows. */
  myResult: MyResult | null;
}

export interface ChallengeList {
  open: ChallengeListRow[];
  history: ChallengeListRow[];
}

export interface ChallengeStore {
  create(input: NewChallenge, now: Date): Promise<Challenge>;
  findByCode(code: string): Promise<Challenge | null>;
  findById(id: string): Promise<Challenge | null>;
  /** Active (not left), non-disabled participants, joined_at ASC. */
  participants(challengeId: string): Promise<Participant[]>;
  isActiveParticipant(challengeId: string, deviceId: string): Promise<boolean>;
  join(challenge: Challenge, deviceId: string, now: Date): Promise<JoinResult>;
  leave(challenge: Challenge, deviceId: string, now: Date): Promise<LeaveResult>;
  /** Creator-only, before start. Returns false when not allowed. */
  cancel(challenge: Challenge, now: Date): Promise<boolean>;
  /**
   * Standings: frozen results when finalized, else a live projection. Calls
   * `finalizeIfDue` first, so a finished challenge is always frozen by the
   * time anyone sees its standings. Returns the (possibly updated) challenge.
   */
  standings(challenge: Challenge, now: Date): Promise<{ challenge: Challenge } & StandingsResult>;
  finalizeIfDue(challenge: Challenge, now: Date): Promise<Challenge>;
  /**
   * The hub's list read: challenges this device is an active participant of,
   * split into open (upcoming + live, soonest end first) and history
   * (finished + cancelled, newest first), each capped at `limit`, with the
   * creator handle, active participant count and the caller's frozen result
   * batched into the same query (no N+1). Due-but-unfinalized challenges are
   * finalized first so every history row carries a placement.
   */
  listForDevice(
    deviceId: string,
    now: Date,
    opts: { scope: ListScope; limit: number },
  ): Promise<ChallengeList>;
  catchLog(challenge: Challenge, deviceId: string): Promise<CatchLogRow[]>;
  /** Count of active participants (for previews). */
  participantCount(challengeId: string): Promise<number>;
}

// ── Drizzle implementation ───────────────────────────────────────────────────

const REFERRAL_WINDOW_MS = 7 * 24 * 60 * 60 * 1000;

/** How many fresh codes to try before giving up on a unique-index collision. */
const CODE_ATTEMPTS = 5;

type ChallengeRow = typeof challenges.$inferSelect;

/** Just enough of Fastify's logger for the store's best-effort warnings. */
export interface ChallengeStoreLogger {
  warn(obj: Record<string, unknown>, msg: string): void;
}

export class DrizzleChallengeStore implements ChallengeStore {
  constructor(
    private readonly db: Database,
    private readonly scorer: ChallengeScorer,
    /** Optional: where best-effort failures (push-baseline seeding) are reported. */
    private readonly log?: ChallengeStoreLogger,
  ) {}

  private async hydrate(row: ChallengeRow): Promise<Challenge> {
    const creator = await withDbRetry(() =>
      this.db
        .select({ handle: devices.handle })
        .from(devices)
        .where(eq(devices.id, row.creatorDeviceId))
        .limit(1),
    );
    return this.fromRow(row, creator[0]?.handle ?? null);
  }

  private fromRow(row: ChallengeRow, creatorHandle: string | null): Challenge {
    return {
      id: row.id,
      kind: row.kind,
      code: row.code,
      name: row.name,
      creatorDeviceId: row.creatorDeviceId,
      creatorHandle,
      startsAt: new Date(row.startsAt),
      endsAt: new Date(row.endsAt),
      durationPreset: row.durationPreset,
      maxParticipants: row.maxParticipants,
      cancelledAt: row.cancelledAt ? new Date(row.cancelledAt) : null,
      finalizedAt: row.finalizedAt ? new Date(row.finalizedAt) : null,
      outcome: (row.outcome as Outcome | null) ?? null,
      createdAt: new Date(row.createdAt),
    };
  }

  async create(input: NewChallenge, now: Date): Promise<Challenge> {
    const endsAt = new Date(input.startsAt.getTime() + DURATION_MS[input.durationPreset]);
    let lastError: unknown;
    for (let attempt = 0; attempt < CODE_ATTEMPTS; attempt++) {
      const code = generateInviteCode();
      try {
        // Not retried (a plain INSERT is non-idempotent); the creator is the
        // first participant, written in the same transaction so a challenge
        // can never exist with nobody in it.
        const created = await this.db.transaction(async (tx) => {
          const rows = await tx
            .insert(challenges)
            .values({
              kind: "private",
              code,
              name: input.name,
              creatorDeviceId: input.creatorDeviceId,
              startsAt: input.startsAt,
              endsAt,
              durationPreset: input.durationPreset,
              createdAt: now,
            })
            .returning();
          await tx.insert(challengeParticipants).values({
            challengeId: rows[0].id,
            deviceId: input.creatorDeviceId,
            joinedAt: now,
          });
          return rows[0];
        });
        const challenge = await this.hydrate(created);
        // Seed the push baseline AFTER the challenge exists, never as a column
        // in the INSERT above: `last_placement` arrived in migration 0011, and
        // writing it inside the creating transaction would make an
        // un-migrated deploy fail CREATE outright. Best-effort — see
        // `seedPlacement`.
        await this.seedCreatorPlacement(challenge);
        return challenge;
      } catch (err) {
        // A unique-index collision on `code` (≈1 in 8e11 per attempt) → try
        // another code. Anything else is a real failure.
        if (isUniqueViolation(err)) {
          lastError = err;
          continue;
        }
        throw err;
      }
    }
    throw lastError instanceof Error ? lastError : new Error("could not allocate an invite code");
  }

  async findByCode(code: string): Promise<Challenge | null> {
    const rows = await withDbRetry(() =>
      this.db.select().from(challenges).where(eq(challenges.code, code)).limit(1),
    );
    return rows[0] ? this.hydrate(rows[0]) : null;
  }

  async findById(id: string): Promise<Challenge | null> {
    const rows = await withDbRetry(() =>
      this.db.select().from(challenges).where(eq(challenges.id, id)).limit(1),
    );
    return rows[0] ? this.hydrate(rows[0]) : null;
  }

  async participants(challengeId: string): Promise<Participant[]> {
    return withDbRetry(() => this.participantsWith(this.db, challengeId));
  }

  /** The participants read on a given executor (a transaction inside finalization). */
  private async participantsWith(exec: Executor, challengeId: string): Promise<Participant[]> {
    const rows = await exec
      .select({
        deviceId: challengeParticipants.deviceId,
        handle: devices.handle,
        joinedAt: challengeParticipants.joinedAt,
      })
      .from(challengeParticipants)
      .innerJoin(devices, eq(devices.id, challengeParticipants.deviceId))
      .where(
        and(
          eq(challengeParticipants.challengeId, challengeId),
          isNull(challengeParticipants.leftAt),
          // Disabled devices vanish from every challenge surface, exactly as
          // they vanish from the public leaderboard.
          isNull(devices.disabledAt),
        ),
      )
      .orderBy(asc(challengeParticipants.joinedAt));
    // A participant always has a handle (joining requires one); the fallback
    // only guards a hand-edited row.
    return rows.map((r) => ({
      deviceId: r.deviceId,
      handle: r.handle ?? "spotter",
      joinedAt: new Date(r.joinedAt),
    }));
  }

  async participantCount(challengeId: string): Promise<number> {
    return (await this.participants(challengeId)).length;
  }

  async isActiveParticipant(challengeId: string, deviceId: string): Promise<boolean> {
    const rows = await withDbRetry(() =>
      this.db
        .select({ deviceId: challengeParticipants.deviceId })
        .from(challengeParticipants)
        .where(
          and(
            eq(challengeParticipants.challengeId, challengeId),
            eq(challengeParticipants.deviceId, deviceId),
            isNull(challengeParticipants.leftAt),
          ),
        )
        .limit(1),
    );
    return rows.length > 0;
  }

  async join(challenge: Challenge, deviceId: string, now: Date): Promise<JoinResult> {
    const status = challengeStatus(challenge, now);
    if (status === "finished" || status === "cancelled") return { ok: false, reason: "closed" };

    const result = await this.db.transaction<JoinResult>(async (tx) => {
      // ROW LOCK FIRST. Two joins racing at 9/10 would both read 9 and both
      // insert; `SELECT … FOR UPDATE` on the challenge serialises every join
      // (and every finalization) for this challenge behind one lock, so the
      // capacity count below is read under it. The re-read also re-derives
      // "is this still open?" from the LOCKED row rather than the caller's
      // snapshot: cancellation, finalization and the end of the window can
      // all have landed since the route read the challenge, and a join that
      // slips in after the results froze would never be scored.
      const locked = await tx
        .select({
          id: challenges.id,
          cancelledAt: challenges.cancelledAt,
          finalizedAt: challenges.finalizedAt,
          endsAt: challenges.endsAt,
        })
        .from(challenges)
        .where(eq(challenges.id, challenge.id))
        .for("update");
      if (!locked[0]) return { ok: false, reason: "closed" };
      if (
        locked[0].cancelledAt ||
        locked[0].finalizedAt ||
        now.getTime() >= new Date(locked[0].endsAt).getTime()
      ) {
        return { ok: false, reason: "closed" };
      }

      // Disabled devices can't join OR rejoin — checked before any branch, so
      // no path below can resurrect a revoked device's row (defence in depth:
      // the bearer lookup already 401s them, this is the second fence).
      //
      // The device row is LOCKED too, for a second reason: the growth
      // attribution below ("has this device ever joined anything?") is only
      // serialised per CHALLENGE by the lock above, so one brand-new device
      // joining two DIFFERENT challenges at once could have both transactions
      // read zero prior rows and both claim the first-join credit. `FOR
      // UPDATE` on the device makes those joins queue behind each other. Lock
      // order is always challenge → device (nothing takes them the other way
      // round), so this cannot deadlock.
      const dev = await tx
        .select({ createdAt: devices.createdAt, disabledAt: devices.disabledAt })
        .from(devices)
        .where(eq(devices.id, deviceId))
        .limit(1)
        .for("update");
      if (!dev[0] || dev[0].disabledAt) return { ok: false, reason: "disabled" };

      const existing = await tx
        .select({ leftAt: challengeParticipants.leftAt })
        .from(challengeParticipants)
        .where(
          and(
            eq(challengeParticipants.challengeId, challenge.id),
            eq(challengeParticipants.deviceId, deviceId),
          ),
        )
        .limit(1);
      if (existing[0] && existing[0].leftAt === null) {
        return { ok: true, alreadyIn: true, newDevice: false };
      }

      // Capacity counts ACTIVE rows only, so a leaver frees a seat — and it
      // must count exactly what `participants()` / `participantCount()` count,
      // disabled devices excluded. Those are the numbers the invite preview
      // shows ("9/10", canJoin true); a capacity check that also counted the
      // disabled row would answer 409 full to a sheet that had just promised
      // a free seat.
      const countRows = await tx
        .select({ n: sql<number>`count(*)` })
        .from(challengeParticipants)
        .innerJoin(devices, eq(devices.id, challengeParticipants.deviceId))
        .where(
          and(
            eq(challengeParticipants.challengeId, challenge.id),
            isNull(challengeParticipants.leftAt),
            isNull(devices.disabledAt),
          ),
        );
      if (Number(countRows[0]?.n ?? 0) >= challenge.maxParticipants) {
        return { ok: false, reason: "full" };
      }

      if (existing[0]) {
        // Rejoin: flip the row back. Attribution never re-fires — the device
        // has a participation row already, so it was not a first join.
        await tx
          .update(challengeParticipants)
          .set({ leftAt: null, joinedAt: now })
          .where(
            and(
              eq(challengeParticipants.challengeId, challenge.id),
              eq(challengeParticipants.deviceId, deviceId),
            ),
          );
        return { ok: true, alreadyIn: false, newDevice: false };
      }

      // Growth attribution (D19): registered within 7 days AND never joined
      // any challenge before (including ones they later left — that row still
      // exists). Stamp the device once; the `is null` guard keeps it first-touch.
      const registeredRecently =
        now.getTime() - new Date(dev[0].createdAt).getTime() <= REFERRAL_WINDOW_MS;
      const prior = await tx
        .select({ challengeId: challengeParticipants.challengeId })
        .from(challengeParticipants)
        .where(eq(challengeParticipants.deviceId, deviceId))
        .limit(1);
      const newDevice = registeredRecently && prior.length === 0;

      await tx.insert(challengeParticipants).values({
        challengeId: challenge.id,
        deviceId,
        joinedAt: now,
        joinedAsNewDevice: newDevice,
      });
      if (newDevice) {
        await tx
          .update(devices)
          .set({ referredByChallengeId: challenge.id })
          .where(and(eq(devices.id, deviceId), isNull(devices.referredByChallengeId)));
      }
      return { ok: true, alreadyIn: false, newDevice };
    });
    // Seed the push baseline AFTER the join has committed, outside its
    // transaction. Inside it, a failure (notably a missing `last_placement`
    // column on an un-migrated deploy) would abort the whole join — Postgres
    // discards everything after the first error, so a try/catch in there buys
    // nothing. A re-joiner is re-seeded too: their remembered placement is from
    // before they left.
    if (result.ok && !result.alreadyIn) await this.seedPlacement(challenge, deviceId);
    return result;
  }

  /**
   * Record the placement `deviceId` holds right now, as the baseline the
   * "someone passed you" push compares against
   * (`challenge_participants.last_placement`, see challenges/overtaken.ts).
   *
   * BEST-EFFORT, BY DESIGN. A null baseline means "never evaluated" and simply
   * never notifies, so the worst case of a failed seed is that this participant
   * misses the first overtake of their race — whereas a seed that could fail
   * the JOIN would make an un-migrated deploy break joining, which is a real
   * feature. Push is a garnish; joining is not.
   *
   * Runs after the join transaction has committed, for the same reason: inside
   * it, any error aborts the join.
   */
  private async seedPlacement(challenge: Challenge, deviceId: string): Promise<void> {
    try {
      const live = await this.liveStandings(challenge);
      const placement = live.standings.find((s) => s.deviceId === deviceId)?.placement ?? 1;
      await this.db
        .update(challengeParticipants)
        .set({ lastPlacement: placement })
        .where(
          and(
            eq(challengeParticipants.challengeId, challenge.id),
            eq(challengeParticipants.deviceId, deviceId),
          ),
        );
    } catch (err) {
      this.log?.warn(
        { err, challengeId: challenge.id, deviceId },
        "could not seed the challenge push baseline (last_placement); pushes stay silent for this participant",
      );
    }
  }

  /** The creator is alone in a brand-new challenge, so the baseline is 1 — no scoring needed. */
  private async seedCreatorPlacement(challenge: Challenge): Promise<void> {
    try {
      await this.db
        .update(challengeParticipants)
        .set({ lastPlacement: 1 })
        .where(
          and(
            eq(challengeParticipants.challengeId, challenge.id),
            eq(challengeParticipants.deviceId, challenge.creatorDeviceId),
          ),
        );
    } catch (err) {
      this.log?.warn(
        { err, challengeId: challenge.id },
        "could not seed the challenge push baseline (last_placement) for the creator",
      );
    }
  }

  async leave(challenge: Challenge, deviceId: string, now: Date): Promise<LeaveResult> {
    const status = challengeStatus(challenge, now);
    if (status === "finished" || status === "cancelled") return "closed";

    // Leaving takes the SAME challenge row lock as `join` and finalization.
    // Without it a leave could interleave with the freeze — finalization
    // reads the participant roster inside its transaction, so a leave landing
    // mid-freeze either vanishes from a board it should have left or mutates
    // the roster a frozen result was derived from. Under the lock a leave
    // either happens entirely before the freeze or is refused as "closed",
    // and open-ness is re-derived from the LOCKED row (cancelled / finalized /
    // ended), never from the caller's possibly stale snapshot.
    return this.db.transaction(async (tx) => {
      const locked = await tx
        .select({
          startsAt: challenges.startsAt,
          endsAt: challenges.endsAt,
          cancelledAt: challenges.cancelledAt,
          finalizedAt: challenges.finalizedAt,
        })
        .from(challenges)
        .where(eq(challenges.id, challenge.id))
        .for("update");
      if (!locked[0]) return "closed";
      if (
        locked[0].cancelledAt ||
        locked[0].finalizedAt ||
        now.getTime() >= new Date(locked[0].endsAt).getTime()
      ) {
        return "closed";
      }

      const active = await tx
        .select({ deviceId: challengeParticipants.deviceId })
        .from(challengeParticipants)
        .where(
          and(
            eq(challengeParticipants.challengeId, challenge.id),
            eq(challengeParticipants.deviceId, deviceId),
            isNull(challengeParticipants.leftAt),
          ),
        )
        .limit(1);
      if (active.length === 0) return "not_participant";

      // D6: the creator walking out of an UPCOMING challenge cancels it — an
      // upcoming challenge with no creator is a zombie. Inlined rather than
      // calling `cancel()` so the cancellation lands under the same lock, in
      // the same transaction, as the leave that triggered it.
      const upcoming = now.getTime() < new Date(locked[0].startsAt).getTime();
      if (upcoming && deviceId === challenge.creatorDeviceId) {
        await tx
          .update(challenges)
          .set({ cancelledAt: now })
          .where(and(eq(challenges.id, challenge.id), isNull(challenges.cancelledAt)));
        return "cancelled";
      }

      await tx
        .update(challengeParticipants)
        .set({ leftAt: now })
        .where(
          and(
            eq(challengeParticipants.challengeId, challenge.id),
            eq(challengeParticipants.deviceId, deviceId),
            isNull(challengeParticipants.leftAt),
          ),
        );
      return "left";
    });
  }

  async cancel(challenge: Challenge, now: Date): Promise<boolean> {
    if (challengeStatus(challenge, now) !== "upcoming") return false;
    const rows = await this.db
      .update(challenges)
      .set({ cancelledAt: now })
      .where(and(eq(challenges.id, challenge.id), isNull(challenges.cancelledAt)))
      .returning({ id: challenges.id });
    return rows.length > 0;
  }

  /** Live projection over the CURRENT active participants. */
  private async liveStandings(challenge: Challenge, exec?: Executor): Promise<StandingsResult> {
    const parts = exec
      ? await this.participantsWith(exec, challenge.id)
      : await this.participants(challenge.id);
    const scores = await this.scorer.score(
      { startsAt: challenge.startsAt, endsAt: challenge.endsAt },
      parts.map((p) => p.deviceId),
      exec,
    );
    const byDevice = new Map(scores.map((s) => [s.deviceId, s]));
    const scored = parts.map((p) => {
      const s = byDevice.get(p.deviceId);
      return {
        deviceId: p.deviceId,
        handle: p.handle,
        points: s?.points ?? 0,
        catches: s?.catches ?? 0,
        rarityBreakdown: s?.rarityBreakdown ?? {},
      };
    });
    return { standings: assignPlacements(scored), outcome: decideOutcome(scored) };
  }

  async finalizeIfDue(challenge: Challenge, now: Date): Promise<Challenge> {
    if (challenge.finalizedAt || challenge.cancelledAt) return challenge;
    if (now.getTime() < challenge.endsAt.getTime()) return challenge;

    // One transaction, one snapshot: lock the challenge row (the same lock
    // `join` takes, so no participant can slip in mid-freeze), re-check that
    // nobody finalized it first, then score the participants and freeze
    // every row and the header together. The header UPDATE is guarded by
    // `finalized_at is null` and the result INSERTs are ON CONFLICT DO
    // NOTHING as a belt to the lock's braces.
    await this.db.transaction(async (tx) => {
      const locked = await tx
        .select({ finalizedAt: challenges.finalizedAt, cancelledAt: challenges.cancelledAt })
        .from(challenges)
        .where(eq(challenges.id, challenge.id))
        .for("update");
      if (!locked[0] || locked[0].finalizedAt || locked[0].cancelledAt) return;
      const live = await this.liveStandings(challenge, tx);
      if (live.standings.length > 0) {
        await tx
          .insert(challengeResults)
          .values(
            live.standings.map((s) => ({
              challengeId: challenge.id,
              deviceId: s.deviceId,
              placement: s.placement,
              points: s.points,
              catches: s.catches,
              rarityBreakdown: s.rarityBreakdown,
            })),
          )
          .onConflictDoNothing();
      }
      await tx
        .update(challenges)
        .set({ finalizedAt: now, outcome: live.outcome })
        .where(and(eq(challenges.id, challenge.id), isNull(challenges.finalizedAt)));
    });
    // Re-read so a concurrent finalizer's values (not ours) are what we return.
    return (await this.findById(challenge.id)) ?? challenge;
  }

  async standings(
    challenge: Challenge,
    now: Date,
  ): Promise<{ challenge: Challenge } & StandingsResult> {
    const c = await this.finalizeIfDue(challenge, now);
    if (!c.finalizedAt) {
      const live = await this.liveStandings(c);
      return { challenge: c, ...live };
    }
    const rows = await withDbRetry(() =>
      this.db
        .select({
          deviceId: challengeResults.deviceId,
          handle: devices.handle,
          placement: challengeResults.placement,
          points: challengeResults.points,
          catches: challengeResults.catches,
          rarityBreakdown: challengeResults.rarityBreakdown,
        })
        .from(challengeResults)
        .innerJoin(devices, eq(devices.id, challengeResults.deviceId))
        // A device disabled AFTER the freeze vanishes from the frozen board
        // too, matching the live path and the public leaderboard. The row
        // stays in challenge_results (history is never rewritten), so
        // re-enabling puts them straight back.
        .where(and(eq(challengeResults.challengeId, c.id), isNull(devices.disabledAt)))
        .orderBy(asc(challengeResults.placement), asc(devices.handle)),
    );
    return {
      challenge: c,
      outcome: c.outcome ?? "no_contest",
      standings: rows.map((r) => ({
        deviceId: r.deviceId,
        handle: r.handle ?? "spotter",
        placement: r.placement,
        points: r.points,
        catches: r.catches,
        rarityBreakdown: (r.rarityBreakdown as Record<string, number>) ?? {},
      })),
    };
  }

  async listForDevice(
    deviceId: string,
    now: Date,
    opts: { scope: ListScope; limit: number },
  ): Promise<ChallengeList> {
    // 1. Finalize anything due. Rare (only the first reader after an end pays),
    //    and it has to happen before the batched read so `myResult` is there.
    const due = await withDbRetry(() =>
      this.db
        .select({ c: challenges })
        .from(challengeParticipants)
        .innerJoin(challenges, eq(challenges.id, challengeParticipants.challengeId))
        .where(
          and(
            eq(challengeParticipants.deviceId, deviceId),
            isNull(challengeParticipants.leftAt),
            isNull(challenges.finalizedAt),
            isNull(challenges.cancelledAt),
            lte(challenges.endsAt, now),
          ),
        ),
    );
    for (const r of due) await this.finalizeIfDue(await this.hydrate(r.c), now);

    // 2. One grouped read per bucket: challenge + creator handle + active
    //    participant count (correlated subquery) + my frozen result (LEFT
    //    JOIN), capped and ordered in SQL. No per-row round trips.
    const creator = alias(devices, "creator");
    const participantCount = sql<number>`(
      select count(*) from challenge_participants p2
      join devices d2 on d2.id = p2.device_id
      where p2.challenge_id = ${challenges.id} and p2.left_at is null and d2.disabled_at is null
    )`.as("participant_count");
    const read = (bucket: "open" | "history") =>
      withDbRetry(() =>
        this.db
          .select({
            c: challenges,
            creatorHandle: creator.handle,
            participantCount,
            placement: challengeResults.placement,
            points: challengeResults.points,
            catches: challengeResults.catches,
          })
          .from(challengeParticipants)
          .innerJoin(challenges, eq(challenges.id, challengeParticipants.challengeId))
          .innerJoin(creator, eq(creator.id, challenges.creatorDeviceId))
          .leftJoin(
            challengeResults,
            and(
              eq(challengeResults.challengeId, challenges.id),
              eq(challengeResults.deviceId, deviceId),
            ),
          )
          .where(
            and(
              eq(challengeParticipants.deviceId, deviceId),
              isNull(challengeParticipants.leftAt),
              bucket === "open"
                ? and(isNull(challenges.cancelledAt), gt(challenges.endsAt, now))
                : or(isNotNull(challenges.cancelledAt), lte(challenges.endsAt, now)),
            ),
          )
          // Open: the one ending soonest is the one you care about. History:
          // newest first.
          .orderBy(bucket === "open" ? asc(challenges.endsAt) : desc(challenges.endsAt))
          .limit(opts.limit),
      );
    const toRow = (r: Awaited<ReturnType<typeof read>>[number]): ChallengeListRow => ({
      challenge: this.fromRow(r.c, r.creatorHandle),
      participantCount: Number(r.participantCount),
      myResult:
        r.placement === null || r.points === null || r.catches === null
          ? null
          : { placement: r.placement, points: r.points, catches: r.catches },
    });
    const wantOpen = opts.scope !== "history";
    const wantHistory = opts.scope !== "open";
    return {
      open: wantOpen ? (await read("open")).map(toRow) : [],
      history: wantHistory ? (await read("history")).map(toRow) : [],
    };
  }

  async catchLog(challenge: Challenge, deviceId: string): Promise<CatchLogRow[]> {
    // The PRIVACY BOUNDARY (spec §9) is this select list: make, model, rarity,
    // points, time. No callsign, no icao24, no registration, no operator, no
    // observer or aircraft position, no verdict. Adding a column here is a
    // privacy decision, not a convenience.
    const rows = await withDbRetry(() =>
      this.db
        .select({
          typecode: catches.typecode,
          manufacturer: typecodes.manufacturer,
          model: typecodes.model,
          rarity: catches.rarity,
          points: catches.points,
          caughtAt: catches.caughtAt,
        })
        .from(catches)
        .leftJoin(typecodes, eq(typecodes.typecode, catches.typecode))
        .where(inWindow({ startsAt: challenge.startsAt, endsAt: challenge.endsAt }, deviceId))
        .orderBy(desc(catches.caughtAt)),
    );
    return rows.map((r) => ({
      aircraft: aircraftName(r.manufacturer, r.model, r.typecode),
      rarity: r.rarity,
      points: r.points,
      caughtAt: new Date(r.caughtAt),
    }));
  }
}

/** "Boeing 737-800" → falls back to the raw typecode, then a neutral label. */
export function aircraftName(
  manufacturer: string | null,
  model: string | null,
  typecode: string | null,
): string {
  const parts = [manufacturer, model].filter((s): s is string => !!s && s.trim() !== "");
  if (parts.length > 0) return parts.join(" ");
  return typecode ?? "Unknown aircraft";
}

/** Postgres unique_violation, as surfaced by postgres-js and PGlite. */
function isUniqueViolation(err: unknown): boolean {
  if (typeof err !== "object" || err === null) return false;
  const e = err as { code?: unknown; cause?: { code?: unknown } };
  return e.code === "23505" || e.cause?.code === "23505";
}
