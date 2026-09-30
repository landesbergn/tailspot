/**
 * Invite codes (spec §9): characters from a 31-symbol alphabet with the
 * lookalikes removed (no 0/O, no 1/I/L), so a code can be read aloud at an
 * airport fence and typed back without ambiguity.
 *
 * New codes are 6 characters (2026-09-26, down from 8 — easier to read out
 * and type). 31^6 ≈ 8.9e8 ≈ 30 bits: with the per-IP lookup limiter and only
 * a handful of open challenges at a time, a blind guess is still hopeless,
 * and a correct one only gets you into a friendly race. Codes issued before
 * the switch are 8 characters and stay valid, so `normalizeCode` accepts
 * both lengths. It folds what people actually type (lowercase, spaces,
 * dashes) back onto the alphabet; anything else is not a code.
 */

import { randomInt } from "node:crypto";

export const CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";
/** Length of newly generated codes. */
export const CODE_LENGTH = 6;
/** Lengths `normalizeCode` accepts: current codes plus legacy 8-character ones. */
export const ACCEPTED_CODE_LENGTHS = [6, 8] as const;

const CODE_RE = new RegExp(
  `^(?:${ACCEPTED_CODE_LENGTHS.map((n) => `[${CODE_ALPHABET}]{${n}}`).join("|")})$`,
);

/** A fresh random code. Uniqueness is the caller's job (unique index + retry). */
export function generateInviteCode(): string {
  let out = "";
  for (let i = 0; i < CODE_LENGTH; i++) {
    out += CODE_ALPHABET[randomInt(CODE_ALPHABET.length)];
  }
  return out;
}

/**
 * Uppercase, strip whitespace and dashes, then require six or eight alphabet
 * characters. Returns null for anything that is not a well-formed code — the
 * excluded lookalikes (0, O, 1, I, L) have nothing to fold onto and are simply
 * rejected; the client never shows them, so a typed one is a misread.
 */
export function normalizeCode(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const folded = raw.toUpperCase().replace(/[\s-]/g, "");
  return CODE_RE.test(folded) ? folded : null;
}
