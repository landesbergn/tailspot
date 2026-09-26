import { createPublicKey, generateKeyPairSync, verify } from "node:crypto";
import { describe, expect, it } from "vitest";
import {
  type ApnsConfig,
  ApnsJwtProvider,
  DEFAULT_BUNDLE_ID,
  NoopApnsTransport,
  apnsConfigFromEnv,
  createApnsTransport,
  isApnsEnvironment,
  isDeadTokenResponse,
  mintApnsJwt,
  normalizePem,
} from "../src/push/apns.js";

/**
 * The sender's testable half: config parsing, the ES256 provider JWT, the
 * dead-token rule, and the "no credentials → no-op" posture. The HTTP/2
 * transport itself is deliberately untested here — it is a thin wrapper around
 * `http2.connect`, and everything with a decision in it lives above it behind
 * the `ApnsTransport` seam (see overtaken.test.ts, which drives a fake).
 */

/** A throwaway P-256 key, generated per run — nothing secret is committed. */
function testConfig(): ApnsConfig {
  const { privateKey } = generateKeyPairSync("ec", {
    namedCurve: "prime256v1",
    privateKeyEncoding: { type: "pkcs8", format: "pem" },
    publicKeyEncoding: { type: "spki", format: "pem" },
  });
  return { keyP8: privateKey, keyId: "ABC1234567", teamId: "TEAM123456", bundleId: "com.example" };
}

describe("APNs config", () => {
  it("is null unless the key, key id and team id are all present", () => {
    const key = testConfig().keyP8;
    expect(apnsConfigFromEnv({})).toBeNull();
    expect(apnsConfigFromEnv({ APNS_KEY_P8: key })).toBeNull();
    expect(apnsConfigFromEnv({ APNS_KEY_P8: key, APNS_KEY_ID: "K" })).toBeNull();
    expect(apnsConfigFromEnv({ APNS_KEY_ID: "K", APNS_TEAM_ID: "T" })).toBeNull();
    expect(
      apnsConfigFromEnv({ APNS_KEY_P8: "   ", APNS_KEY_ID: "K", APNS_TEAM_ID: "T" }),
    ).toBeNull();
  });

  it("defaults the bundle id to the shipping app", () => {
    const config = apnsConfigFromEnv({
      APNS_KEY_P8: testConfig().keyP8,
      APNS_KEY_ID: "K",
      APNS_TEAM_ID: "T",
    });
    expect(config?.bundleId).toBe(DEFAULT_BUNDLE_ID);
    expect(DEFAULT_BUNDLE_ID).toBe("com.landesberg.Tailspot");
  });

  it("normalises a key whose newlines arrived as literal backslash-n", () => {
    const real = testConfig().keyP8;
    const escaped = real.replace(/\n/g, "\\n");
    expect(normalizePem(escaped)).toBe(real.trim());
    const config = apnsConfigFromEnv({
      APNS_KEY_P8: escaped,
      APNS_KEY_ID: "K",
      APNS_TEAM_ID: "T",
      APNS_BUNDLE_ID: "com.example",
    });
    // A null config must FAIL here, not quietly fall back to a fresh key that
    // would sign fine and prove nothing.
    if (config === null) throw new Error("expected an escaped key to parse");
    expect(config.keyP8).toBe(real.trim());
    // The proof it really normalised: the mangled key loads and signs.
    expect(() => mintApnsJwt(config, 0)).not.toThrow();
  });
});

describe("the provider JWT", () => {
  it("is a verifiable ES256 token carrying kid, iss and iat", () => {
    const config = testConfig();
    const nowMs = Date.UTC(2026, 8, 26, 12, 0, 0);
    const jwt = mintApnsJwt(config, nowMs);
    const [header, claims, signature] = jwt.split(".");

    expect(JSON.parse(Buffer.from(header, "base64url").toString())).toEqual({
      alg: "ES256",
      kid: config.keyId,
    });
    expect(JSON.parse(Buffer.from(claims, "base64url").toString())).toEqual({
      iss: config.teamId,
      iat: Math.floor(nowMs / 1000),
    });

    // The signature must be the raw r‖s pair (64 bytes for P-256), not DER —
    // Apple rejects a DER signature with InvalidProviderToken.
    const raw = Buffer.from(signature, "base64url");
    expect(raw).toHaveLength(64);
    const ok = verify(
      "sha256",
      Buffer.from(`${header}.${claims}`),
      { key: createPublicKey(config.keyP8), dsaEncoding: "ieee-p1363" },
      raw,
    );
    expect(ok).toBe(true);
  });

  it("is cached for 50 minutes and re-minted after", () => {
    const config = testConfig();
    let now = 0;
    const provider = new ApnsJwtProvider(config, () => now);
    const first = provider.token();
    now += 49 * 60_000;
    expect(provider.token()).toBe(first);
    now += 2 * 60_000; // 51 minutes in
    const second = provider.token();
    expect(second).not.toBe(first);
  });
});

describe("dead-token detection", () => {
  it("treats 410 and BadDeviceToken/Unregistered as dead, and nothing else", () => {
    expect(isDeadTokenResponse({ status: 410 })).toBe(true);
    expect(isDeadTokenResponse({ status: 410, reason: "Unregistered" })).toBe(true);
    expect(isDeadTokenResponse({ status: 400, reason: "BadDeviceToken" })).toBe(true);
    expect(isDeadTokenResponse({ status: 400, reason: "Unregistered" })).toBe(true);

    expect(isDeadTokenResponse({ status: 200 })).toBe(false);
    expect(isDeadTokenResponse({ status: 400, reason: "BadTopic" })).toBe(false);
    expect(isDeadTokenResponse({ status: 429, reason: "TooManyRequests" })).toBe(false);
    expect(isDeadTokenResponse({ status: 503, reason: "ServiceUnavailable" })).toBe(false);
    expect(isDeadTokenResponse({ status: 0, reason: "push disabled" })).toBe(false);
  });
});

describe("the transport factory", () => {
  it("is a no-op that logs 'push disabled' once when the env is unset", async () => {
    const logged: string[] = [];
    const transport = createApnsTransport({ env: {}, log: (m) => logged.push(m) });
    expect(transport).toBeInstanceOf(NoopApnsTransport);
    expect(logged).toEqual(["push disabled"]);

    // Sending through it is safe and says nothing went out.
    const res = await transport.send("production", "a".repeat(64), { aps: {} });
    expect(res).toEqual({ status: 0, reason: "push disabled" });
    expect(logged).toEqual(["push disabled"]); // still once — no per-send noise
  });

  it("builds a real transport and says so when the env is complete", () => {
    const config = testConfig();
    const logged: string[] = [];
    const transport = createApnsTransport({
      env: {
        APNS_KEY_P8: config.keyP8,
        APNS_KEY_ID: config.keyId,
        APNS_TEAM_ID: config.teamId,
        APNS_BUNDLE_ID: config.bundleId,
      },
      log: (m) => logged.push(m),
    });
    expect(transport).not.toBeInstanceOf(NoopApnsTransport);
    expect(logged).toEqual(["push enabled"]);
    // No network is touched until a send, so nothing to close here beyond this.
    (transport as { close?: () => void }).close?.();
  });
});

describe("environment guard", () => {
  it("accepts only the two APNs hosts", () => {
    expect(isApnsEnvironment("sandbox")).toBe(true);
    expect(isApnsEnvironment("production")).toBe(true);
    expect(isApnsEnvironment("prod")).toBe(false);
    expect(isApnsEnvironment(null)).toBe(false);
    expect(isApnsEnvironment(undefined)).toBe(false);
  });
});
