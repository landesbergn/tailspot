/**
 * Uptime probe for the marketing site, run from the API process.
 *
 * WHY: tailspot.app is unmonitored. Sentry's free plan has one uptime slot,
 * and it watches the API's /readyz. The site matters more than it looks: it
 * serves the apple-app-site-association file that makes challenge invite
 * links open the app, and the public catch counter.
 *
 * Every `intervalMs` it GETs each URL. A URL is down when it fails to answer
 * 2xx within `timeoutMs`. After `failuresToAlert` failed rounds in a row it
 * alerts, then at most once per `minIntervalMs` while it stays down, and logs
 * once when it comes back. If the API itself is down the probe is too, but
 * then the /readyz monitor is already paging.
 */

export interface SiteProbeAlert {
  url: string;
  consecutiveFailures: number;
  error: string;
}

export interface SiteProbeOptions {
  urls: string[];
  intervalMs?: number;
  timeoutMs?: number;
  failuresToAlert?: number;
  minIntervalMs?: number;
  fetchFn?: typeof fetch;
  now?: () => number;
  onAlert?: (alert: SiteProbeAlert) => void;
  onRecovered?: (url: string, downForRounds: number) => void;
}

export const DEFAULT_SITE_PROBE_URLS = [
  "https://tailspot.app/",
  "https://tailspot.app/.well-known/apple-app-site-association",
];

interface UrlState {
  failures: number;
  lastAlertAt: number | undefined;
}

export class SiteProbe {
  private readonly intervalMs: number;
  private readonly timeoutMs: number;
  private readonly failuresToAlert: number;
  private readonly minIntervalMs: number;
  private readonly fetchFn: typeof fetch;
  private readonly now: () => number;
  private readonly state = new Map<string, UrlState>();
  private timer: ReturnType<typeof setInterval> | undefined;

  constructor(private readonly options: SiteProbeOptions) {
    this.intervalMs = options.intervalMs ?? 60_000;
    this.timeoutMs = options.timeoutMs ?? 10_000;
    this.failuresToAlert = options.failuresToAlert ?? 3;
    this.minIntervalMs = options.minIntervalMs ?? 60 * 60_000;
    this.fetchFn = options.fetchFn ?? fetch;
    this.now = options.now ?? Date.now;
    for (const url of options.urls) this.state.set(url, { failures: 0, lastAlertAt: undefined });
  }

  /** Start probing on an interval. The timer never keeps the process alive. */
  start(): void {
    if (this.timer !== undefined) return;
    this.timer = setInterval(() => void this.checkAll(), this.intervalMs);
    this.timer.unref();
  }

  stop(): void {
    if (this.timer !== undefined) clearInterval(this.timer);
    this.timer = undefined;
  }

  /** One round over every URL. Never throws. */
  async checkAll(): Promise<void> {
    await Promise.all(this.options.urls.map((url) => this.check(url)));
  }

  private async check(url: string): Promise<void> {
    const state = this.state.get(url);
    if (state === undefined) return;
    const error = await this.probe(url);
    if (error === undefined) {
      if (state.failures >= this.failuresToAlert) {
        try {
          this.options.onRecovered?.(url, state.failures);
        } catch {
          /* listener errors must not stop probing */
        }
      }
      state.failures = 0;
      state.lastAlertAt = undefined;
      return;
    }
    state.failures++;
    if (state.failures < this.failuresToAlert) return;
    const now = this.now();
    if (state.lastAlertAt !== undefined && now - state.lastAlertAt < this.minIntervalMs) return;
    state.lastAlertAt = now;
    try {
      this.options.onAlert?.({ url, consecutiveFailures: state.failures, error });
    } catch {
      /* listener errors must not stop probing */
    }
  }

  /** Undefined when healthy, else a short description of the failure. */
  private async probe(url: string): Promise<string | undefined> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const res = await this.fetchFn(url, {
        method: "GET",
        headers: { "user-agent": "tailspot-api-site-probe" },
        signal: controller.signal,
        redirect: "follow",
      });
      // Drain the body so the socket is released.
      await res.arrayBuffer().catch(() => undefined);
      return res.ok ? undefined : `HTTP ${res.status}`;
    } catch (err) {
      if (controller.signal.aborted) return `no answer within ${this.timeoutMs} ms`;
      return err instanceof Error ? err.message : String(err);
    } finally {
      clearTimeout(timer);
    }
  }
}
