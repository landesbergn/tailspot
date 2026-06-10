/**
 * Bearer-token authentication helper (WP 1.5).
 *
 * A pure-ish resolver shared by the authenticated routes: pull the bearer from
 * the Authorization header, hash it, and point-look up the device. Returns the
 * device identity or null. The route decides what a null means (401 when auth is
 * required; just "no me" when auth is optional, as on the leaderboard).
 *
 * Why hash-then-lookup and not a constant-time compare: see token.ts. The secret
 * is hashed before it ever touches the DB, so the equality is between two
 * SHA-256 digests of a 256-bit secret — no byte-by-byte probing path exists.
 */

import type { DeviceIdentity, IdentityStore } from "./store.js";
import { bearerFromAuthHeader, hashToken } from "./token.js";

/**
 * Resolve the authenticated device from an Authorization header value, or null
 * if the header is missing/malformed or the token matches no device.
 */
export async function resolveDevice(
  store: IdentityStore,
  authHeader: string | undefined,
): Promise<DeviceIdentity | null> {
  const token = bearerFromAuthHeader(authHeader);
  if (!token) return null;
  return store.findByTokenHash(hashToken(token));
}
