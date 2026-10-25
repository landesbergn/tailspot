/**
 * Alert on a high share of 5xx responses.
 *
 * WHY: Sentry only hears about 5xx answers that come from a thrown exception.
 * Most of ours are deliberate replies (a 503 when the feed has nothing to
 * serve, a 503 when the database is down), so a burst of them used to be
 * invisible unless one specific in-process alerter happened to cover it.
 * This counts every response, whatever produced it.
 *
 * Counting is per minute in a ring of buckets covering `windowMs`. An alert
 * needs BOTH at least `minErrors` 5xx answers and at least `minRatio` of all
 * answers in the window, so one failed request at 3 a.m. is not a page and a
 * busy minute with a handful of errors is not either. Alerts are rate limited
 * to one per `minIntervalMs`.
 */

export interface ErrorRateAlert {
  errors: number;
  total: number;
  windowMs: number;
  /** Routes that produced the 5xx answers, most first. */
  routes: Array<{ route: string; errors: number }>;
}

export interface ErrorRateAlerterOptions {
  windowMs?: number;
  minErrors?: number;
  minRatio?: number;
  minIntervalMs?: number;
  now?: () => number;
  onAlert?: (alert: ErrorRateAlert) => void;
}

interface Bucket {
  minute: number;
  total: number;
  errors: number;
  routes: Map<string, number>;
}

export class ErrorRateAlerter {
  private readonly windowMs: number;
  private readonly minErrors: number;
  private readonly minRatio: number;
  private readonly minIntervalMs: number;
  private readonly now: () => number;
  private readonly onAlert?: (alert: ErrorRateAlert) => void;
  private readonly buckets: Bucket[] = [];
  private lastAlertAt: number | undefined;

  constructor(options: ErrorRateAlerterOptions = {}) {
    this.windowMs = options.windowMs ?? 5 * 60_000;
    this.minErrors = options.minErrors ?? 10;
    this.minRatio = options.minRatio ?? 0.05;
    this.minIntervalMs = options.minIntervalMs ?? 60 * 60_000;
    this.now = options.now ?? Date.now;
    this.onAlert = options.onAlert;
  }

  /** Record one response. `route` is the route pattern, not the raw URL. */
  record(statusCode: number, route: string): void {
    const now = this.now();
    const minute = Math.floor(now / 60_000);
    let bucket = this.buckets[this.buckets.length - 1];
    if (bucket === undefined || bucket.minute !== minute) {
      bucket = { minute, total: 0, errors: 0, routes: new Map() };
      this.buckets.push(bucket);
    }
    const oldest = Math.floor((now - this.windowMs) / 60_000);
    while (this.buckets.length > 0 && (this.buckets[0]?.minute ?? minute) <= oldest)
      this.buckets.shift();

    bucket.total++;
    if (statusCode < 500) return;
    bucket.errors++;
    bucket.routes.set(route, (bucket.routes.get(route) ?? 0) + 1);
    this.evaluate(now);
  }

  private evaluate(now: number): void {
    let total = 0;
    let errors = 0;
    const routes = new Map<string, number>();
    for (const b of this.buckets) {
      total += b.total;
      errors += b.errors;
      for (const [r, n] of b.routes) routes.set(r, (routes.get(r) ?? 0) + n);
    }
    if (errors < this.minErrors || errors / total < this.minRatio) return;
    if (this.lastAlertAt !== undefined && now - this.lastAlertAt < this.minIntervalMs) return;
    this.lastAlertAt = now;
    this.onAlert?.({
      errors,
      total,
      windowMs: this.windowMs,
      routes: [...routes.entries()]
        .map(([route, n]) => ({ route, errors: n }))
        .sort((a, b) => b.errors - a.errors),
    });
  }
}
