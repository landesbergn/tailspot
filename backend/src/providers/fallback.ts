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
}

export class FallbackProvider implements PositionProvider {
  readonly name: string;

  constructor(
    private readonly primary: PositionProvider,
    private readonly secondary: PositionProvider,
    private readonly options: FallbackProviderOptions = {},
  ) {
    this.name = `${primary.name}+${secondary.name}`;
  }

  async aircraftInBbox(bbox: Bbox): Promise<ProviderSnapshot> {
    let primaryError: unknown;
    try {
      return await this.primary.aircraftInBbox(bbox);
    } catch (err) {
      primaryError = err;
    }
    this.options.onFallback?.(primaryError);
    try {
      return await this.secondary.aircraftInBbox(bbox);
    } catch (secondaryError) {
      throw new UpstreamError(
        `both providers failed: ${this.primary.name} (${describe(primaryError)}); ` +
          `${this.secondary.name} (${describe(secondaryError)})`,
        secondaryError,
      );
    }
  }
}

function describe(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
