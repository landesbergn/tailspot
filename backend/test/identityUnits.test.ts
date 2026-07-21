import { describe, expect, it } from "vitest";
import { pointsForRarity } from "../src/catches/points.js";
import { containsProfanity } from "../src/identity/profanity.js";
import { bearerFromAuthHeader, generateDeviceToken, hashToken } from "../src/identity/token.js";

describe("containsProfanity (substring on lowercased handle)", () => {
  it("flags banned words case-insensitively", () => {
    expect(containsProfanity("shithead")).toBe(true);
    expect(containsProfanity("ShItHeAd")).toBe(true);
    expect(containsProfanity("xXx_fuck_xXx")).toBe(true);
  });
  it("passes clean handles", () => {
    expect(containsProfanity("Maverick")).toBe(false);
    expect(containsProfanity("plane_nerd_99")).toBe(false);
    expect(containsProfanity("SpotterNoah")).toBe(false);
  });
  it("flags leetspeak spellings (GA hardening, 2026-07-20)", () => {
    expect(containsProfanity("sh1thead")).toBe(true); // 1 → i
    expect(containsProfanity("a55hat")).toBe(true); // 5 → s
    expect(containsProfanity("c0ckpit_fan")).toBe(true); // 0 → o (over-block, accepted)
    expect(containsProfanity("n1gg4")).toBe(true); // 1 → i, 4 → a
    expect(containsProfanity("ni66a")).toBe(true); // 6 → g
    expect(containsProfanity("b8stard")).toBe(false); // 8 → b gives "bbstard" — not matched, documents the limit
    expect(containsProfanity("f_u_c_k")).toBe(true); // underscore separators stripped
    expect(containsProfanity("8itch")).toBe(true); // 8 → b
  });
  it("leet folding does not break the suggester vocabulary", () => {
    expect(containsProfanity("heading_1996")).toBe(false);
    expect(containsProfanity("vapor_6564")).toBe(false);
    expect(containsProfanity("redeye_1297")).toBe(false);
  });
});

describe("pointsForRarity (mirror of iOS GameSystem tiers)", () => {
  it("maps each tier", () => {
    expect(pointsForRarity("common")).toBe(10);
    expect(pointsForRarity("uncommon")).toBe(20);
    expect(pointsForRarity("rare")).toBe(50);
    expect(pointsForRarity("epic")).toBe(100);
    expect(pointsForRarity("legendary")).toBe(500);
  });
  it("unknown/null rarity scores the common floor (10)", () => {
    expect(pointsForRarity(null)).toBe(10);
    expect(pointsForRarity(undefined)).toBe(10);
    expect(pointsForRarity("bogus")).toBe(10);
  });
});

describe("device token", () => {
  it("generates a high-entropy token and a stable SHA-256 hex hash", () => {
    const t1 = generateDeviceToken();
    const t2 = generateDeviceToken();
    expect(t1).not.toBe(t2); // random
    expect(t1.length).toBeGreaterThan(20);
    const h = hashToken(t1);
    expect(h).toMatch(/^[0-9a-f]{64}$/); // 256-bit hex
    expect(hashToken(t1)).toBe(h); // deterministic
    expect(hashToken(t2)).not.toBe(h);
  });
});

describe("bearerFromAuthHeader", () => {
  it("extracts the token from a well-formed header (scheme case-insensitive)", () => {
    expect(bearerFromAuthHeader("Bearer abc123")).toBe("abc123");
    expect(bearerFromAuthHeader("bearer abc123")).toBe("abc123");
    expect(bearerFromAuthHeader("  Bearer   abc123  ")).toBe("abc123");
  });
  it("returns null for missing or malformed headers", () => {
    expect(bearerFromAuthHeader(undefined)).toBeNull();
    expect(bearerFromAuthHeader("")).toBeNull();
    expect(bearerFromAuthHeader("Basic abc123")).toBeNull();
    expect(bearerFromAuthHeader("Bearer")).toBeNull();
    expect(bearerFromAuthHeader("abc123")).toBeNull();
  });
});
