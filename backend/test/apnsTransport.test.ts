import { generateKeyPairSync } from "node:crypto";
import { EventEmitter } from "node:events";
import type { ClientHttp2Session } from "node:http2";
import { describe, expect, it } from "vitest";
import { type ApnsConfig, Http2ApnsTransport } from "../src/push/apns.js";

/**
 * The HTTP/2 transport, against a stubbed session.
 *
 * `connect` is injectable purely for this. The request SHAPE — path, topic,
 * push-type, priority, expiration, the bearer — is a contract with Apple that
 * nothing else can see, and getting `apns-expiration` or the path wrong fails in
 * the worst way: Apple accepts the request and quietly drops the notification.
 * The teardown cases matter just as much now that a send happens inside the
 * challenge row lock: a promise that never settles would park a transaction.
 */

const NOW_MS = Date.UTC(2026, 8, 26, 12, 0, 0);

function testConfig(): ApnsConfig {
  const { privateKey } = generateKeyPairSync("ec", {
    namedCurve: "prime256v1",
    privateKeyEncoding: { type: "pkcs8", format: "pem" },
    publicKeyEncoding: { type: "spki", format: "pem" },
  });
  return { keyP8: privateKey, keyId: "ABC1234567", teamId: "TEAM123456", bundleId: "com.example" };
}

class StubStream extends EventEmitter {
  ended: Buffer | undefined;
  destroyed = false;
  end(body: Buffer) {
    this.ended = body;
  }
  close() {
    this.destroyed = true;
  }
  destroy() {
    this.destroyed = true;
    this.emit("close");
  }
  /** Play back an APNs answer. */
  answer(status: number, body = "") {
    this.emit("response", { ":status": status });
    if (body !== "") this.emit("data", Buffer.from(body));
    this.emit("end");
    this.emit("close");
  }
}

class StubSession extends EventEmitter {
  readonly requests: Record<string, unknown>[] = [];
  readonly streams: StubStream[] = [];
  closed = false;
  destroyed = false;
  request(headers: Record<string, unknown>): StubStream {
    this.requests.push(headers);
    const stream = new StubStream();
    this.streams.push(stream);
    return stream;
  }
  close() {
    this.closed = true;
  }
}

function transportWith(timeoutMs?: number): {
  transport: Http2ApnsTransport;
  sessions: StubSession[];
} {
  const sessions: StubSession[] = [];
  const transport = new Http2ApnsTransport({
    config: testConfig(),
    now: () => NOW_MS,
    timeoutMs,
    connect: () => {
      const session = new StubSession();
      sessions.push(session);
      return session as unknown as ClientHttp2Session;
    },
  });
  return { transport, sessions };
}

describe("Http2ApnsTransport", () => {
  it("POSTs /3/device/<token> with the alert headers and a one-hour expiration", async () => {
    const { transport, sessions } = transportWith();
    const token = "f".repeat(64);
    const payload = { aps: { alert: { title: "t", body: "b" } } };
    const pending = transport.send("production", token, payload);

    const session = sessions[0];
    const headers = session.requests[0];
    expect(headers[":method"]).toBe("POST");
    expect(headers[":path"]).toBe(`/3/device/${token}`);
    expect(headers["apns-topic"]).toBe("com.example");
    expect(headers["apns-push-type"]).toBe("alert");
    expect(headers["apns-priority"]).toBe("10");
    expect(headers["apns-expiration"]).toBe(String(Math.floor(NOW_MS / 1000) + 3600));
    expect(String(headers.authorization)).toMatch(/^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
    expect(headers["content-type"]).toBe("application/json");

    const stream = session.streams[0];
    expect(stream.ended && JSON.parse(stream.ended.toString())).toEqual(payload);

    stream.answer(200);
    expect(await pending).toEqual({ status: 200 });
    transport.close();
  });

  it("reports the status and APNs reason from a rejection", async () => {
    const { transport, sessions } = transportWith();
    const pending = transport.send("sandbox", "a".repeat(64), {});
    sessions[0].streams[0].answer(410, JSON.stringify({ reason: "Unregistered" }));
    expect(await pending).toEqual({ status: 410, reason: "Unregistered" });
    transport.close();
  });

  it("reuses one session per environment, and close() shuts them", async () => {
    const { transport, sessions } = transportWith();
    const first = transport.send("production", "a".repeat(64), {});
    sessions[0].streams[0].answer(200);
    await first;
    const second = transport.send("production", "b".repeat(64), {});
    sessions[0].streams[1].answer(200);
    await second;
    expect(sessions).toHaveLength(1);

    const other = transport.send("sandbox", "c".repeat(64), {});
    sessions[1].streams[0].answer(200);
    await other;
    expect(sessions).toHaveLength(2);

    transport.close();
    expect(sessions.every((s) => s.closed)).toBe(true);
  });

  it("resolves when a stream is torn down without a response (GOAWAY / RST)", async () => {
    const { transport, sessions } = transportWith();
    const pending = transport.send("production", "a".repeat(64), {});
    // No 'response', no 'end', no 'error' — just gone. This used to leave the
    // promise pending forever, which would now hold the challenge row lock.
    sessions[0].streams[0].emit("close");
    expect(await pending).toEqual({ status: 0, reason: "stream closed" });
    transport.close();
  });

  it("gives up after the deadline and destroys the stream", async () => {
    const { transport, sessions } = transportWith(10);
    const pending = transport.send("production", "a".repeat(64), {});
    expect(await pending).toEqual({ status: 0, reason: "timeout" });
    expect(sessions[0].streams[0].destroyed).toBe(true);
    transport.close();
  });

  it("turns a stream error into a status 0, never a rejection", async () => {
    const { transport, sessions } = transportWith();
    const pending = transport.send("production", "a".repeat(64), {});
    sessions[0].streams[0].emit("error", new Error("socket hang up"));
    expect(await pending).toEqual({ status: 0, reason: "socket hang up" });
    transport.close();
  });
});
