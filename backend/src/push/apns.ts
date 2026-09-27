/**
 * APNs sender — token-based auth, HTTP/2, no dependencies.
 *
 * WHY NO LIBRARY. Everything APNs needs is in Node's standard library: an
 * ES256 JWT is `crypto.sign` over two base64url segments, and the wire protocol
 * is one HTTP/2 POST. `node-apn` and friends bring a dependency (and a
 * transitive tree) into a service whose whole dependency list is four packages.
 * The implementation below is ~150 lines and the interesting half of it is the
 * JWT.
 *
 * THE SEAM. `ApnsTransport` is the one thing the rest of the codebase knows
 * about: `send(env, token, payload) → { status, reason? }`. Tests inject a fake
 * and assert on the exact payload; production injects `Http2ApnsTransport`,
 * which is deliberately thin (connect, POST, read `:status` + the JSON body's
 * `reason`). Anything with judgement in it — who to notify, what to say, when
 * to stop — lives in `src/challenges/overtaken.ts`, not here.
 *
 * NEVER THROWS. Every public entry point resolves to a status; a transport
 * failure comes back as `status: 0` with a reason. Push is a garnish on a catch
 * upload, and a dead APNs connection must never turn into a failed catch.
 *
 * CONFIGURATION is four env vars (`APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`,
 * `APNS_BUNDLE_ID`). When any of the first three is missing the factory returns
 * a no-op transport and logs "push disabled" ONCE at startup — the same posture
 * as the PostHog key in the iOS app: absent credentials degrade to silence, not
 * to an error.
 */

import { createPrivateKey, sign } from "node:crypto";
import { constants, type ClientHttp2Session, type ClientHttp2Stream, connect } from "node:http2";

/** Which APNs host a token is valid against. A token minted in one is rejected by the other. */
export type ApnsEnvironment = "sandbox" | "production";

export function isApnsEnvironment(v: unknown): v is ApnsEnvironment {
  return v === "sandbox" || v === "production";
}

const HOSTS: Record<ApnsEnvironment, string> = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
};

/**
 * What a send came back as. `status` is the HTTP status APNs answered with
 * (200 = delivered to Apple), or `0` when the request never got that far
 * (transport failure, or a no-op sender). `reason` is APNs' own machine-readable
 * string ("BadDeviceToken", "Unregistered", …) when it sent one.
 */
export interface ApnsResponse {
  status: number;
  reason?: string;
}

/** The seam. One method, so a fake is three lines. */
export interface ApnsTransport {
  send(env: ApnsEnvironment, token: string, payload: unknown): Promise<ApnsResponse>;
}

/**
 * Does this response mean the token is DEAD (the app was deleted, or the token
 * belongs to the other environment) rather than "try again later"? Apple's
 * contract: 410 Gone / "Unregistered" means stop sending to it, and a 400 with
 * "BadDeviceToken" means it was never valid here. Both are grounds to clear the
 * token — a device that reinstalls simply registers a new one.
 */
export function isDeadTokenResponse(res: ApnsResponse): boolean {
  if (res.status === 410) return true;
  if (res.status === 400 && (res.reason === "BadDeviceToken" || res.reason === "Unregistered"))
    return true;
  return res.reason === "Unregistered";
}

/**
 * Reasons APNs gives when it rejected our PROVIDER token (the JWT), not the
 * device token. They are 403s and they are OUR fault — an expired cached JWT, a
 * clock skew, a key that was revoked. Crucially they are RETRYABLE: the
 * notification is fine, the credential isn't, so the caller must not treat the
 * notification as delivered-and-done, and we must stop serving the rejected JWT
 * (see `Http2ApnsTransport.send`, which invalidates the cache on sight).
 */
const PROVIDER_TOKEN_REASONS = new Set([
  "ExpiredProviderToken",
  "InvalidProviderToken",
  "MissingProviderToken",
]);

/** Did APNs reject our signing credential rather than the device token? */
export function isProviderTokenFailure(res: ApnsResponse): boolean {
  return res.status === 403 && res.reason !== undefined && PROVIDER_TOKEN_REASONS.has(res.reason);
}

export interface ApnsConfig {
  /** Contents of the .p8 key (NOT a path). Literal `\n` sequences are normalised. */
  keyP8: string;
  /** The key's 10-character id (the `kid` JWT header). */
  keyId: string;
  /** The Apple Developer team id (the `iss` JWT claim). */
  teamId: string;
  /** The app's bundle id (the `apns-topic` header). */
  bundleId: string;
}

export const DEFAULT_BUNDLE_ID = "com.landesberg.Tailspot";

/**
 * Read the config from the environment, or null when push isn't configured.
 *
 * `APNS_KEY_P8` holds the key's PEM contents. Fly secrets, CI env files and
 * shell exports all mangle real newlines differently, so a key pasted as one
 * line with literal `\n` between the armour and the body is the common case —
 * we normalise it rather than making the operator get it exactly right.
 */
export function apnsConfigFromEnv(env: NodeJS.ProcessEnv = process.env): ApnsConfig | null {
  const keyP8 = normalizePem(env.APNS_KEY_P8 ?? "");
  const keyId = (env.APNS_KEY_ID ?? "").trim();
  const teamId = (env.APNS_TEAM_ID ?? "").trim();
  const bundleId = (env.APNS_BUNDLE_ID ?? "").trim() || DEFAULT_BUNDLE_ID;
  if (keyP8 === "" || keyId === "" || teamId === "") return null;
  return { keyP8, keyId, teamId, bundleId };
}

/** Literal `\n` → real newlines, CRLF → LF, trimmed. */
export function normalizePem(raw: string): string {
  return raw.replace(/\\n/g, "\n").replace(/\r\n/g, "\n").trim();
}

// ── The JWT ──────────────────────────────────────────────────────────────────

const TOKEN_TTL_MS = 50 * 60 * 1000; // Apple rejects tokens older than 1 h; refresh at 50 min.

/** Idle ceiling on a cached HTTP/2 session. Apple keeps them open far longer; this reaps ours. */
const IDLE_SESSION_MS = 60_000;

function base64url(input: Buffer | string): string {
  return Buffer.from(input).toString("base64url");
}

/**
 * Mint the provider authentication token: `ES256({ alg, kid }, { iss, iat })`.
 *
 * Node's `sign` with `dsaEncoding: "ieee-p1363"` emits the raw r‖s pair JOSE
 * wants; the default DER encoding would produce a token Apple rejects with
 * InvalidProviderToken, which is a miserable thing to debug.
 */
export function mintApnsJwt(config: ApnsConfig, nowMs: number): string {
  const header = base64url(JSON.stringify({ alg: "ES256", kid: config.keyId }));
  const claims = base64url(JSON.stringify({ iss: config.teamId, iat: Math.floor(nowMs / 1000) }));
  const signingInput = `${header}.${claims}`;
  const signature = sign("sha256", Buffer.from(signingInput), {
    key: createPrivateKey(config.keyP8),
    dsaEncoding: "ieee-p1363",
  });
  return `${signingInput}.${base64url(signature)}`;
}

/** Caches the JWT for 50 minutes (Apple's limit is an hour; re-minting per send is throttled). */
export class ApnsJwtProvider {
  private cached: { token: string; mintedAt: number } | undefined;

  constructor(
    private readonly config: ApnsConfig,
    private readonly now: () => number = Date.now,
  ) {}

  token(): string {
    const nowMs = this.now();
    if (this.cached && nowMs - this.cached.mintedAt < TOKEN_TTL_MS) return this.cached.token;
    const token = mintApnsJwt(this.config, nowMs);
    this.cached = { token, mintedAt: nowMs };
    return token;
  }

  /**
   * Throw the cached JWT away so the next send mints a fresh one. Called when
   * APNs tells us the token is expired or invalid — otherwise we would keep
   * presenting the rejected credential for the rest of its 50-minute cache
   * window and every notification in that window would fail.
   */
  invalidate(): void {
    this.cached = undefined;
  }
}

// ── Transports ───────────────────────────────────────────────────────────────

/**
 * The reason the no-op sender reports. Callers distinguish it from a real
 * transport failure: "push is switched off" is not something to retry, and it
 * must not be logged as an error on every catch.
 */
export const PUSH_DISABLED_REASON = "push disabled";

/** The unconfigured sender: reports `status: 0, reason: "push disabled"`, sends nothing. */
export class NoopApnsTransport implements ApnsTransport {
  async send(): Promise<ApnsResponse> {
    return { status: 0, reason: PUSH_DISABLED_REASON };
  }
}

export interface Http2TransportOptions {
  config: ApnsConfig;
  /** Injectable clock for the JWT cache (tests). */
  now?: () => number;
  /**
   * Hard per-send ceiling. APNs answers in tens of milliseconds; this exists
   * only to bound a hang, and it is deliberately short (5 s) because a send
   * happens inside the challenge row lock — a stuck stream would make somebody
   * else's join wait.
   */
  timeoutMs?: number;
  /**
   * How to dial APNs. Defaults to `http2.connect`; tests pass a stub session so
   * the request shape (path, headers, expiration) can be asserted without a
   * network.
   */
  connect?: (authority: string) => ClientHttp2Session;
}

/**
 * The real thing: one HTTP/2 session per environment, reused across sends and
 * rebuilt when it dies. `POST /3/device/<token>` with the alert headers; the
 * response's `:status` and (on failure) the JSON body's `reason` are the whole
 * result.
 */
export class Http2ApnsTransport implements ApnsTransport {
  private readonly jwt: ApnsJwtProvider;
  private readonly sessions = new Map<ApnsEnvironment, ClientHttp2Session>();
  private readonly timeoutMs: number;

  private readonly dial: (authority: string) => ClientHttp2Session;

  constructor(private readonly options: Http2TransportOptions) {
    this.jwt = new ApnsJwtProvider(options.config, options.now);
    this.timeoutMs = options.timeoutMs ?? 5_000;
    this.dial = options.connect ?? connect;
  }

  /** Close any open sessions (process shutdown / tests). */
  close(): void {
    for (const session of this.sessions.values()) session.close();
    this.sessions.clear();
  }

  /** Forget `session` if it is still the cached one for `env`, and tear it down. */
  private evict(env: ApnsEnvironment, session: ClientHttp2Session): void {
    if (this.sessions.get(env) !== session) return;
    this.sessions.delete(env);
    if (!session.destroyed) session.destroy();
  }

  private session(env: ApnsEnvironment): ClientHttp2Session {
    const existing = this.sessions.get(env);
    if (existing && !existing.closed && !existing.destroyed) return existing;
    const session = this.dial(HOSTS[env]);
    // A session-level error must not become an unhandled 'error' event (which
    // would take the process down). Drop it from the cache and let the next
    // send dial again — but ONLY if it is still the cached one: a stale
    // session's late error would otherwise evict the healthy replacement and
    // leak the connection it was evicting.
    session.on("error", () => this.evict(env, session));
    session.on("close", () => this.evict(env, session));
    // Reap an idle session rather than letting a middlebox half-close it and
    // leave us holding a socket that accepts streams and never answers.
    session.setTimeout?.(IDLE_SESSION_MS, () => session.destroy());
    this.sessions.set(env, session);
    return session;
  }

  send(env: ApnsEnvironment, token: string, payload: unknown): Promise<ApnsResponse> {
    const body = Buffer.from(JSON.stringify(payload));
    return new Promise<ApnsResponse>((resolve) => {
      let settled = false;
      let stream: ClientHttp2Stream | undefined;
      // THE WHOLE SEND is raced against one timer, not just the stream's own
      // inactivity timeout. An HTTP/2 stream can be torn down by a GOAWAY or an
      // RST without ever emitting 'error' or 'end', and the earlier version
      // left the promise pending forever in exactly that case — which, since
      // sends now happen under the challenge row lock, would have parked a
      // transaction rather than merely losing a notification.
      const timer = setTimeout(() => {
        // Settle FIRST, then tear down: destroying the stream emits 'close',
        // and the caller deserves "timeout" as the reason rather than the
        // "stream closed" our own teardown would produce.
        done({ status: 0, reason: "timeout" });
        stream?.destroy();
      }, this.timeoutMs);
      // Never hold the process open for a notification.
      timer.unref?.();
      const done = (res: ApnsResponse) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        // A timeout or a transport-level error means this SESSION is suspect —
        // a half-open connection accepts streams and never answers them, so
        // reusing it turns one bad send into every later send timing out until
        // the process restarts. Drop it; the next send redials.
        if (res.status === 0) {
          const cached = this.sessions.get(env);
          if (cached) this.evict(env, cached);
        }
        // APNs rejected our JWT, not the device token: stop serving the
        // rejected one for the rest of its cache window.
        if (isProviderTokenFailure(res)) this.jwt.invalidate();
        resolve(res);
      };
      try {
        const expiration = Math.floor((this.options.now?.() ?? Date.now()) / 1000) + 3600;
        const req = this.session(env).request({
          [constants.HTTP2_HEADER_METHOD]: "POST",
          [constants.HTTP2_HEADER_PATH]: `/3/device/${token}`,
          [constants.HTTP2_HEADER_AUTHORIZATION]: `bearer ${this.jwt.token()}`,
          "apns-topic": this.options.config.bundleId,
          "apns-push-type": "alert",
          "apns-priority": "10",
          "apns-expiration": String(expiration),
          [constants.HTTP2_HEADER_CONTENT_TYPE]: "application/json",
          [constants.HTTP2_HEADER_CONTENT_LENGTH]: body.length,
        });
        stream = req;
        let status = 0;
        req.on("response", (headers) => {
          status = Number(headers[constants.HTTP2_HEADER_STATUS] ?? 0);
        });
        const chunks: Buffer[] = [];
        req.on("data", (chunk: Buffer) => chunks.push(chunk));
        req.on("end", () => done({ status, ...parseReason(Buffer.concat(chunks)) }));
        req.on("error", (err: Error) => done({ status: 0, reason: err.message }));
        // The backstop for a stream that goes away silently. 'close' always
        // fires eventually, and it fires AFTER 'end' on a healthy request, so
        // the idempotent `done` keeps the real answer.
        req.on("close", () => done({ status: 0, reason: "stream closed" }));
        req.end(body);
      } catch (err) {
        // connect() itself can throw (bad host, no network at all).
        done({ status: 0, reason: err instanceof Error ? err.message : "send failed" });
      }
    });
  }
}

/** APNs' failure body is `{"reason":"BadDeviceToken"}`; a 200 has an empty body. */
function parseReason(body: Buffer): { reason?: string } {
  if (body.length === 0) return {};
  try {
    const parsed: unknown = JSON.parse(body.toString("utf8"));
    if (typeof parsed === "object" && parsed !== null && "reason" in parsed) {
      const reason = (parsed as { reason?: unknown }).reason;
      if (typeof reason === "string") return { reason };
    }
  } catch {
    // Non-JSON body (a proxy error page); the status alone is the verdict.
  }
  return {};
}

export interface CreateTransportOptions {
  env?: NodeJS.ProcessEnv;
  /** Startup log sink — called exactly once, with "push disabled" or "push enabled". */
  log?: (message: string, detail?: Record<string, unknown>) => void;
  now?: () => number;
}

/**
 * Build the transport the app should use: the HTTP/2 one when APNs is
 * configured, the no-op one otherwise. Logs the decision ONCE (this is called
 * at app build time, not per request) so an operator can tell from the boot log
 * whether pushes are going anywhere.
 */
export function createApnsTransport(options: CreateTransportOptions = {}): ApnsTransport {
  const config = apnsConfigFromEnv(options.env);
  if (!config) {
    options.log?.("push disabled");
    return new NoopApnsTransport();
  }
  // PROVE THE KEY WORKS AT BOOT. `createPrivateKey` only runs on the first
  // send, so a mangled or truncated APNS_KEY_P8 used to boot as "push enabled"
  // and then fail every send with a status-0 error — which the overtaken
  // evaluation quite correctly reads as "transient", so it would hold every
  // baseline open forever, retrying a credential that can never work. One
  // signature at startup turns that into a loud line in the boot log and the
  // honest no-op sender.
  try {
    mintApnsJwt(config, options.now?.() ?? Date.now());
  } catch (err) {
    options.log?.("push disabled: APNS_KEY_P8 is not a usable signing key", {
      err: err instanceof Error ? err.message : String(err),
      keyId: config.keyId,
    });
    return new NoopApnsTransport();
  }
  options.log?.("push enabled", { bundleId: config.bundleId, keyId: config.keyId });
  return new Http2ApnsTransport({ config, now: options.now });
}
