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
 *   - the clock only resets once the primary has stayed healthy for
 *     `quietMs` (2 min). An isolated blip still ends cleanly, but a FLAPPING
 *     feed (mostly failing, with the odd success) is one continuous incident.
 *     The first version reset on any single success, so on 2026-10-17 adsb.lol
 *     failed most requests for hours and Sentry never heard about it: every
 *     stray success restarted the five-minute clock.
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
  /** How long the primary must stay healthy before a run ends. Default 2 min. */
  quietMs?: number;
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
const TWO_MINUTES_MS = 2 * 60_000;

export class SustainedFallbackAlerter {
  private readonly sustainedForMs: number;
  private readonly minIntervalMs: number;
  private readonly quietMs: number;
  private readonly now: () => number;
  private readonly onAlert?: (alert: SustainedFallbackAlert) => void;

  /** When the current run of fallback engagements started (unix ms). */
  private engagedAt: number | undefined;
  /** When the primary last came back during this run; undefined while failing. */
  private recoveredAt: number | undefined;
  /** When we last emitted an alert (unix ms) — drives the rate limit. */
  private lastAlertAt: number | undefined;

  constructor(options: SustainedFallbackAlerterOptions = {}) {
    this.sustainedForMs = options.sustainedForMs ?? FIVE_MINUTES_MS;
    this.minIntervalMs = options.minIntervalMs ?? ONE_HOUR_MS;
    this.quietMs = options.quietMs ?? TWO_MINUTES_MS;
    this.now = options.now ?? Date.now;
    this.onAlert = options.onAlert;
  }

  /** True while the primary is believed to be failing (exposed for tests/log context). */
  get isEngaged(): boolean {
    return this.engagedAt !== undefined && this.recoveredAt === undefined;
  }

  /** Record one fallback engagement, and alert if it has now been sustained. */
  recordFallback(primaryError: unknown): void {
    const now = this.now();
    // A recovery that held for the quiet window ended the previous run; one
    // that didn't is just a gap inside the same incident.
    if (this.recoveredAt !== undefined && now - this.recoveredAt >= this.quietMs) {
      this.engagedAt = undefined;
    }
    this.recoveredAt = undefined;
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

  /**
   * Record a successful primary response. The run ends only if no further
   * fallback arrives within `quietMs`; see the header.
   */
  recordRecovery(): void {
    if (this.engagedAt !== undefined && this.recoveredAt === undefined) {
      this.recoveredAt = this.now();
    }
  }
}

/**
 * Rate-limited alert for the BACKUP feed failing.
 *
 * The sustained-fallback alert above watches the primary. Nothing watched the
 * secondary, so when airplanes.live started answering HTTP 403 (2026-10-17) the
 * fallback was dead and no one knew until adsb.lol wobbled and users saw empty
 * skies. Any secondary failure is worth knowing about the same day, so there
 * is no sustain threshold here, only the hourly rate limit.
 */
export interface FeedFailureAlerterOptions {
  /** Minimum gap between alerts. Default 1 h. */
  minIntervalMs?: number;
  /** Injectable clock (unix ms). */
  now?: () => number;
  /** Alert sink; production wires this to Sentry. */
  onAlert?: (error: unknown) => void;
}

export class FeedFailureAlerter {
  private readonly minIntervalMs: number;
  private readonly now: () => number;
  private readonly onAlert?: (error: unknown) => void;
  private lastAlertAt: number | undefined;

  constructor(options: FeedFailureAlerterOptions = {}) {
    this.minIntervalMs = options.minIntervalMs ?? ONE_HOUR_MS;
    this.now = options.now ?? Date.now;
    this.onAlert = options.onAlert;
  }

  recordFailure(error: unknown): void {
    const now = this.now();
    if (this.lastAlertAt !== undefined && now - this.lastAlertAt < this.minIntervalMs) return;
    this.lastAlertAt = now;
    this.onAlert?.(error);
  }
}
