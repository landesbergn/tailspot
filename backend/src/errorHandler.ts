/**
 * Never send a 5xx's error message to the client (security fix, 2026-10-24).
 *
 * Fastify's default error handler answers every thrown error with
 * `{ statusCode, code, error, message: err.message }` — including 5xx. For a
 * database failure that message is drizzle's `DrizzleQueryError` text:
 * "Failed query: <full SQL>\nparams: <bound values>". So any DB hiccup (the
 * 2026-10-16 CONNECT_TIMEOUT run, a unique-index race) handed the caller our
 * schema, query shapes and other users' bound parameters — for POST
 * /v1/catches, an observer's coordinates.
 *
 * 4xx errors are deliberate, client-facing (validation, body too large, bad
 * JSON) and safe, so they fall through to Fastify's default handler unchanged.
 * 5xx keep the same JSON keys clients already parse, with a generic message;
 * the real error is logged server-side, and Sentry's onError hook (which runs
 * before any error handler) still captures it.
 */

import type { FastifyError, FastifyInstance } from "fastify";

export function installErrorHandler(app: FastifyInstance): void {
  app.setErrorHandler((error: FastifyError, request, reply) => {
    const status = statusFor(error, reply.statusCode);
    if (status < 500) {
      // Inside a custom handler, send(error) defers to the parent (default)
      // handler: same status, headers, body and log line as before.
      return reply.send(error);
    }
    request.log.error({ err: error }, error.message);
    return reply.code(status).send({
      statusCode: status,
      error: "Internal Server Error",
      message: "Internal Server Error",
    });
  });
}

/** Mirrors Fastify's own status resolution for a thrown error. */
function statusFor(error: FastifyError, replyStatus: number): number {
  const fromError = error.statusCode ?? (error as { status?: number }).status;
  if (typeof fromError === "number" && fromError >= 400) return fromError;
  if (replyStatus >= 400) return replyStatus;
  return 500;
}
