/**
 * PostHog HogQL client for the real-catches template.
 *
 *   POST https://us.i.posthog.com/api/projects/@current/query/
 *   { "query": { "kind": "HogQLQuery", "query": "select …" } }
 *
 * Auth: in the cloud agent environment the egress proxy injects PostHog
 * credentials, so no key lives in code or config. If POSTHOG_PERSONAL_API_KEY
 * is set (e.g. on a Mac), it is sent as a Bearer token; otherwise no
 * Authorization header at all.
 *
 * The response is { columns: string[], results: unknown[][], … }. Callers get
 * only { columns, results }, never the rest (it echoes the compiled SQL,
 * team id and cache keys, none of which a fixture needs).
 */

export const POSTHOG_QUERY_URL = "https://us.i.posthog.com/api/projects/@current/query/";
const USER_AGENT = "tailspot-content-engine/0.1 (+https://tailspot.app)";

export interface HogQLResult {
  columns: string[];
  results: unknown[][];
}

export interface HogQLOptions {
  timeoutMs?: number;
  fetchFn?: typeof fetch;
}

export async function hogql(query: string, opts: HogQLOptions = {}): Promise<HogQLResult> {
  const { timeoutMs = 30_000, fetchFn = fetch } = opts;
  const headers: Record<string, string> = { "content-type": "application/json", accept: "application/json", "user-agent": USER_AGENT };
  const key = process.env.POSTHOG_PERSONAL_API_KEY?.trim();
  if (key) headers.authorization = `Bearer ${key}`;
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const res = await fetchFn(POSTHOG_QUERY_URL, {
      method: "POST",
      headers,
      body: JSON.stringify({ query: { kind: "HogQLQuery", query } }),
      signal: ctl.signal,
    });
    if (!res.ok) throw new Error(`HTTP ${res.status} from PostHog query API`);
    const body = (await res.json()) as Partial<HogQLResult> & { error?: unknown };
    if (body.error) throw new Error(`PostHog query error: ${String(body.error)}`);
    if (!Array.isArray(body.columns) || !Array.isArray(body.results)) throw new Error("PostHog query API: unexpected response shape");
    return { columns: body.columns, results: body.results };
  } finally {
    clearTimeout(timer);
  }
}
