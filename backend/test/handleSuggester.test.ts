import { describe, expect, it } from "vitest";
import { generateHandleCandidates } from "../src/identity/handleSuggester.js";
import { containsProfanity } from "../src/identity/profanity.js";

/** The handle format the backend enforces on claim (devices route). */
const HANDLE_RE = /^[A-Za-z0-9_]{3,20}$/;

/** Tiny deterministic LCG so "same seed → same output" is testable. */
function makeRng(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 0x1_0000_0000;
  };
}

describe("generateHandleCandidates", () => {
  it("produces valid, distinct, profanity-free handles", () => {
    const out = generateHandleCandidates(20);
    expect(out.length).toBeGreaterThan(0);
    expect(new Set(out).size).toBe(out.length); // all distinct
    for (const h of out) {
      expect(h, h).toMatch(HANDLE_RE);
      expect(containsProfanity(h), h).toBe(false);
    }
  });

  it("is deterministic for a given rng seed", () => {
    const a = generateHandleCandidates(8, makeRng(42));
    const b = generateHandleCandidates(8, makeRng(42));
    expect(a).toEqual(b);
  });

  it("returns nothing for a non-positive batch size", () => {
    expect(generateHandleCandidates(0)).toEqual([]);
    expect(generateHandleCandidates(-5)).toEqual([]);
  });
});
