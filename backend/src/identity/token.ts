/**
 * Device-token issuance + hashing (WP 1.5).
 *
 * The security model (deliberate, documented):
 *
 *  - A device token is a 256-bit (32-byte) cryptographically-random secret,
 *    base64url-encoded. 256 bits is well beyond brute-force; there is no
 *    structure to attack.
 *  - We store ONLY the SHA-256 hash of the token, never the token itself. The
 *    token is returned to the client exactly once (at registration) and is the
 *    only copy. Consequences:
 *      • A leaked `devices` table row cannot be replayed as a credential — the
 *        attacker has the hash, not the token, and SHA-256 is preimage-resistant.
 *      • We can never "recover" a lost token; the device must re-register. That's
 *        acceptable for an anonymous-identity model with no account recovery.
 *  - Auth is a single point-lookup: hash the presented bearer, SELECT the device
 *    whose `token_hash` equals it. We do NOT need a constant-time compare here:
 *    the comparison is done by the database's index/equality on a 256-bit hash
 *    of a high-entropy secret. A timing side-channel on a B-tree lookup leaks at
 *    most which prefix bytes matched — and since the input to the hash is the
 *    full secret (not attacker-chosen plaintext that maps predictably to hash
 *    bytes), an attacker can't iteratively probe the secret byte-by-byte. (A
 *    constant-time compare matters when you compare a SECRET to attacker INPUT
 *    directly; here the secret is hashed first, destroying that relationship.)
 */

import { createHash, randomBytes } from "node:crypto";

/** Number of random bytes in a device token. 32 bytes = 256 bits. */
const TOKEN_BYTES = 32;

/** Generate a fresh 256-bit device token, base64url-encoded (URL/header-safe). */
export function generateDeviceToken(): string {
  return randomBytes(TOKEN_BYTES).toString("base64url");
}

/** SHA-256 (lowercase hex) of a token. The only form we ever persist. */
export function hashToken(token: string): string {
  return createHash("sha256").update(token, "utf8").digest("hex");
}

/**
 * Extract a bearer token from an Authorization header value.
 * Returns the token string, or null if the header is absent/malformed.
 * Case-insensitive on the "Bearer " scheme; tolerates extra surrounding
 * whitespace but the token itself must be non-empty.
 */
export function bearerFromAuthHeader(header: string | undefined): string | null {
  if (!header) return null;
  const match = /^Bearer\s+(\S+)\s*$/i.exec(header.trim());
  return match ? match[1] : null;
}
