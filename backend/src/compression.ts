import { promisify } from "node:util";
import { gzip } from "node:zlib";
import type { FastifyInstance } from "fastify";

const gzipAsync = promisify(gzip);

/**
 * Gzip JSON responses for clients that accept it.
 *
 * WHY: every phone downloads the aircraft list every 10 s, often on one bar of
 * cellular, and readsb-shaped JSON compresses roughly 5:1. URLSession sends
 * `Accept-Encoding: gzip` and inflates transparently, so the app needs no
 * change. Fly's proxy does not compress for us.
 *
 * Done as one onSend hook with node:zlib instead of @fastify/compress: the
 * API only sends small JSON bodies, and this keeps the dependency list short.
 * Bodies under `thresholdBytes` go out as-is (gzip's header would eat the
 * saving). Streams, HEAD requests and already-encoded replies are untouched.
 */
export function registerCompression(app: FastifyInstance, thresholdBytes = 1024): void {
  app.addHook("onSend", async (request, reply, payload) => {
    if (request.method === "HEAD" || reply.hasHeader("content-encoding")) return payload;
    let body: Buffer;
    if (typeof payload === "string") body = Buffer.from(payload);
    else if (Buffer.isBuffer(payload)) body = payload;
    else return payload;
    if (body.length < thresholdBytes) return payload;

    // The answer now depends on Accept-Encoding, so say so to any cache.
    const vary = reply.getHeader("vary");
    if (vary === undefined) reply.header("vary", "Accept-Encoding");
    else if (!/accept-encoding/i.test(String(vary)))
      reply.header("vary", `${vary}, Accept-Encoding`);

    if (!acceptsGzip(request.headers["accept-encoding"])) return payload;
    const compressed = await gzipAsync(body);
    reply.header("content-encoding", "gzip");
    reply.removeHeader("content-length");
    return compressed;
  });
}

/** True when the Accept-Encoding header allows gzip (honours `;q=0`). Exported for tests. */
export function acceptsGzip(header: string | string[] | undefined): boolean {
  if (header === undefined) return false;
  const value = Array.isArray(header) ? header.join(",") : header;
  for (const part of value.split(",")) {
    const [coding, ...params] = part.trim().toLowerCase().split(";");
    if (coding !== "gzip" && coding !== "*") continue;
    const q = params.map((p) => p.trim()).find((p) => p.startsWith("q="));
    if (q !== undefined && Number(q.slice(2)) === 0) return false;
    return true;
  }
  return false;
}
