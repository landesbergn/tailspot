import type { TailspotStats } from "./tailspot.ts";

export interface DataSource {
  name: string;
  url: string;
  fetchedAt: string;
  license?: string;
}

/** Saved inputs for one template run. `--fixture` replays these offline. */
export interface Fixture<Raw = unknown> {
  template: string;
  /** When the raw data was captured (ISO). Slides say "right now" relative to this. */
  capturedAt: string;
  /**
   * True when the fixture is NOT a capture of real live data (hand-built test
   * data). Every slide rendered from it carries a SAMPLE DATA stamp and
   * post.json says postable: false. Never post one.
   */
  synthetic?: boolean;
  note?: string;
  /** Free-form per-template selector, e.g. { city: "london" }. */
  params?: Record<string, unknown>;
  raw: Raw;
  sources: DataSource[];
  tailspotStats?: TailspotStats | null;
}

export interface BuildContext {
  /** Post date (YYYY-MM-DD) — drives rotation + the deterministic seed. */
  date: string;
  dayIndex: number;
  seed: string;
  /** Time the data describes. */
  capturedAt: Date;
  stats: TailspotStats | null;
  /** Synthetic fixture → stamp slides, mark not postable. */
  sample: boolean;
  params: Record<string, unknown>;
}

export interface Slide {
  /** Short id for the file name, e.g. "hook". */
  name: string;
  /** Inner HTML of the 1080×1920 slide (wrapped by render.ts). */
  html: string;
}

export interface Post {
  template: string;
  /** Slide 1's line, also the first line of the caption. */
  hook: string;
  caption: string;
  hashtags: string[];
  slides: Slide[];
  /** What the post is about, machine-readable (goes in post.json). */
  subject: Record<string, unknown>;
  /** Alt text per slide for accessibility (IG supports it). */
  altText: string[];
}

export interface Template<Raw = unknown> {
  id: string;
  label: string;
  /** Does `fetch` need the network? (guess-plane doesn't.) */
  needsNetwork: boolean;
  /** Choose per-run params (e.g. which city) from the date. */
  params(dayIndex: number): Record<string, unknown>;
  fetch(params: Record<string, unknown>): Promise<{ raw: Raw; sources: DataSource[] }>;
  /** Pure: data in, post out. Throws NoSubjectError when nothing qualifies. */
  build(raw: Raw, ctx: BuildContext): Post;
}

export class NoSubjectError extends Error {}
