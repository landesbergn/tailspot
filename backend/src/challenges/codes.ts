/**
 * Invite codes (spec §9): 8 characters from a 31-symbol alphabet with the
 * lookalikes removed (no 0/O, no 1/I/L), so a code can be read aloud at an
 * airport fence and typed back without ambiguity. 31^8 ≈ 8.5e11 ≈ 40 bits,
 * which together with the per-IP lookup limiter makes enumeration
 * impractical. `normalizeCode` folds what people actually type (lowercase,
 * spaces, dashes) back onto the alphabet; anything else is not a code.
 */

import { randomInt } from "node:crypto";

export const CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";
export const CODE_LENGTH = 8;

const CODE_RE = new RegExp(`^[${CODE_ALPHABET}]{${CODE_LENGTH}}$`);

/** A fresh random code. Uniqueness is the caller's job (unique index + retry). */
export function generateInviteCode(): string {
  let out = "";
  for (let i = 0; i < CODE_LENGTH; i++) {
    out += CODE_ALPHABET[randomInt(CODE_ALPHABET.length)];
  }
  return out;
}

/**
 * Uppercase, strip whitespace and dashes, then require exactly eight alphabet
 * characters. Returns null for anything that is not a well-formed code — the
 * excluded lookalikes (0, O, 1, I, L) have nothing to fold onto and are simply
 * rejected; the client never shows them, so a typed one is a misread.
 */
export function normalizeCode(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const folded = raw.toUpperCase().replace(/[\s-]/g, "");
  return CODE_RE.test(folded) ? folded : null;
}
