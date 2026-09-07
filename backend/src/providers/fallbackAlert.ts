/**
 * Sustained-fallback alerting.
 *
 * `FallbackProvider` reports EVERY engagement through `onFallback`, and app.ts
 * logs each one. That is the right level of detail for a log, and the wrong
 * level for an alert: adsb.lol blips for a single poll several times a day, and
 * an alert per blip is an alert nobody reads. What actually matters is the
 * *sustained* case — the primary has been down long enough that we are serving
 * every user off the backup feed and nobody has noticed.
 *
 * So this class is a small state machine over the engage/recover events:
 *
 *   - the first engagement after a recovery starts a clock;
 *   - once the fallback has been continuously engaged for `sustainedForMs`
 *     (5 min), ONE alert is emitted;
 *   - `minIntervalMs` (1 h) rate-limits the alerts so a day-long adsb.lol
 *     outage produces roughly one page per hour, not one per poll;
 *   - a successful primary response resets the clock — a flapping feed never
 *     accumulates its way past the threshold.
 *
 * Deliberately NO timers. Evaluation happens on the events themselves, which
 * means nothing keeps the event loop alive and tests need no fake timers (just
 * the injected `now`). The trade-off: with zero traffic there are no events and
 * therefore no alert — acceptable, because with zero traffic there is also no
 * user impact, and total deadness is covered by the /readyz uptime monitor.
 *
 * The rate-limit clock is NOT reset by a recovery. A feed that flaps in and out
 * every few minutes for an hour is one incident, and should read as one alert.
 */

export interface SustainedFallbackAlert {
  /** How long the fallback had been continuously engaged when we alerted (ms). */
  engagedForMs: number;
  /** The primary's most recent error — the "why", for the alert body. */
  primaryError: unknown;
}

export interface SustainedFallbackAlerterOptions {
  /** Continuous engagement before the first alert. Default 5 min. */
  sustainedForMs?: number;
  /** Minimum gap between alerts. Default 1 h. */
  minIntervalMs?: number;
  /** Injectable clock (unix ms) — tests pass a fake; production uses Date.now. */
  now?: () => number;
  /**
   * Alert sink. Production (src/index.ts) wires this to Sentry.captureMessage;
   * app.ts leaves it undefined when nothing is wired, so the whole thing is a
   * no-op in tests and in a DSN-less local run.
   */
  onAlert?: (alert: SustainedFallbackAlert) => void;
}

const FIVE_MINUTES_MS = 5 * 60_000;
const ONE_HOUR_MS = 60 * 60_000;

export class SustainedFallbackAlerter {
  private readonly sustainedForMs: number;
  private readonly minIntervalMs: number;
  private readonly now: () => number;
  private readonly onAlert?: (alert: SustainedFallbackAlert) => void;

  /** When the current unbroken run of fallback engagements started (unix ms). */
  private engagedAt: number | undefined;
  /** When we last emitted an alert (unix ms) — drives the rate limit. */
  private lastAlertAt: number | undefined;

  constructor(options: SustainedFallbackAlerterOptions = {}) {
    this.sustainedForMs = options.sustainedForMs ?? FIVE_MINUTES_MS;
    this.minIntervalMs = options.minIntervalMs ?? ONE_HOUR_MS;
    this.now = options.now ?? Date.now;
    this.onAlert = options.onAlert;
  }

  /** True while the primary is believed to be failing (exposed for tests/log context). */
  get isEngaged(): boolean {
    return this.engagedAt !== undefined;
  }

  /** Record one fallback engagement, and alert if it has now been sustained. */
  recordFallback(primaryError: unknown): void {
    const now = this.now();
    // First failure of this run: start the clock. Note we do NOT alert here even
    // if the threshold were zero — an alert needs a second event to prove the
    // outage persisted, which is exactly the point.
    if (this.engagedAt === undefined) {
      this.engagedAt = now;
      return;
    }
    const engagedForMs = now - this.engagedAt;
    if (engagedForMs < this.sustainedForMs) return;
    if (this.lastAlertAt !== undefined && now - this.lastAlertAt < this.minIntervalMs) return;
    this.lastAlertAt = now;
    this.onAlert?.({ engagedForMs, primaryError });
  }

  /** Record a successful primary response — ends the run and resets the clock. */
  recordRecovery(): void {
    this.engagedAt = undefined;
  }
}
