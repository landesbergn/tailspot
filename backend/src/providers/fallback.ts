import { type Bbox, type PositionProvider, type ProviderSnapshot, UpstreamError } from "./types.js";

/**
 * Composite provider: serve the primary; if it THROWS, serve the secondary.
 *
 * Scope is deliberately narrow — this is transport-failure insurance, not a
 * coverage merge:
 *
 *   - An empty-but-successful primary response does NOT fall back. Zero
 *     aircraft is a legitimate answer (a real coverage desert looks the same
 *     in every hobbyist feed — confirmed for Bali/Lombok 2026-07-03, both
 *     feeds zero), and double-querying every quiet tile would burn the
 *     secondary's goodwill for no recall gain.
 *   - Results are never merged. One snapshot, one `fetchedAt`, one upstream's
 *     dedupe semantics — merging two feeds' views of the same sky invites
 *     duplicate icao24s with conflicting positions.
 *
 * The client-side lesson still holds (a SILENT failover once hid backend
 * problems mid-session — see the 2026-06-21 cutover): every engagement is
 * reported through `onFallback` so it lands in the server logs, and the
 * served data is identical in shape either way.
 */
export interface FallbackProviderOptions {
  /** Called once per engaged fallback with the primary's error. Wire this to
   *  the app logger; without visibility a dead primary looks like a healthy
   *  system. */
  onFallback?: (primaryError: unknown) => void;
  /**
   * Called on the first primary success AFTER one or more fallbacks — the
   * "primary recovered" edge. `onFallback` alone can't tell a five-minute
   * outage from five scattered blips, because nothing reports the good news;
   * this is the other half of that signal (see SustainedFallbackAlerter).
   * Edge-triggered, not level: a primary that never failed never fires it.
   */
  onRecovered?: () => void;
  /**
   * Called when the secondary serves a request — i.e. the fallback actually
   * worked. Level-triggered (every such request), because it is the "all
   * clear" for `onBothFailed` below: a hard outage ends the moment EITHER feed
   * answers, and onRecovered only reports the primary.
   */
  onSecondaryServed?: () => void;
  /**
   * Called when BOTH feeds failed for a request, with the composite error that
   * is about to be thrown. This is the signal that matters most and that
   * `onFallback` alone cannot express: with the secondary dead too there is no
   * fallback, the tile cache is all that stands between the phone and a 503.
   * For sixteen days in 2026-10 the hourly Sentry message read "still serving
   * the fallback" while nobody was being served anything.
   */
  onBothFailed?: (error: UpstreamError) => void;
}

export class FallbackProvider implements PositionProvider {
  readonly name: string;

  /** True once a fallback has engaged, until the primary serves again. */
  private engaged = false;

  constructor(
    private readonly primary: PositionProvider,
    private readonly secondary: PositionProvider,
    private readonly options: FallbackProviderOptions = {},
  ) {
    this.name = `${primary.name}+${secondary.name}`;
  }

  async aircraftInBbox(bbox: Bbox): Promise<ProviderSnapshot> {
    let primaryError: unknown;
    let snapshot: ProviderSnapshot | undefined;
    try {
      snapshot = await this.primary.aircraftInBbox(bbox);
    } catch (err) {
      primaryError = err;
    }
    if (snapshot !== undefined) {
      // The recovery notice runs OUTSIDE the try (same as onFallback below) so
      // a broken listener can't masquerade as a failed primary and silently
      // send every request to the secondary.
      if (this.engaged) {
        this.engaged = false;
        this.options.onRecovered?.();
      }
      return snapshot;
    }
    this.engaged = true;
    this.options.onFallback?.(primaryError);
    let secondaryError: unknown;
    let fallbackSnapshot: ProviderSnapshot | undefined;
    try {
      fallbackSnapshot = await this.secondary.aircraftInBbox(bbox);
    } catch (err) {
      secondaryError = err;
    }
    // Listeners run outside the try blocks for the same reason as above: a
    // throwing listener must never be mistaken for a failed feed, nor replace
    // the composite error a caller is about to receive.
    if (fallbackSnapshot !== undefined) {
      this.options.onSecondaryServed?.();
      return fallbackSnapshot;
    }
    const bothFailed = new UpstreamError(
      `both providers failed: ${this.primary.name} (${describe(primaryError)}); ` +
        `${this.secondary.name} (${describe(secondaryError)})`,
      secondaryError,
    );
    this.options.onBothFailed?.(bothFailed);
    throw bothFailed;
  }
}

function describe(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
