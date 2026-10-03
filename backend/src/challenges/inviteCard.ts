/**
 * The link-preview card for an invite link (`GET /v1/invites/:code/card`).
 *
 * WhatsApp, Slack, Discord, Telegram, X, Facebook and LinkedIn fetch a pasted
 * link themselves and render its Open Graph tags. `tailspot.app/c/CODE` is a
 * 302 to the App Store, so they used to show the generic App Store listing.
 * The www nginx now hands those crawlers (by User-Agent) this page instead;
 * people still never see it — the meta refresh sends any browser that lands
 * here on to the App Store, and there is no landing page by design.
 *
 * Everything user-written (challenge name, creator handle) goes through
 * `escapeHtml` before it touches the markup: a challenge name is free text
 * typed by anyone with a handle, and this page is served to third parties.
 */

import type { ChallengeStatus } from "./store.js";

/** The public, participant-free view of a challenge both preview routes serve. */
export interface PublicInvite {
  name: string;
  creatorHandle: string | null;
  startsAt: string;
  endsAt: string;
  durationPreset: string;
  participantCount: number;
  maxParticipants: number;
  status: ChallengeStatus;
}

/** Static for now; a per-code rendered card is the later step (PLAN §9). */
export const INVITE_CARD_IMAGE_URL = "https://tailspot.app/img/og-image.jpg";

/** Escapes the five characters that matter in HTML text AND quoted attributes. */
export function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function day(d: Date): string {
  return `${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}`;
}

function hhmm(d: Date): string {
  return `${String(d.getUTCHours()).padStart(2, "0")}:${String(d.getUTCMinutes()).padStart(2, "0")}`;
}

/**
 * The window in UTC — the crawler renders one card for every reader, so there
 * is no "their" time zone to use. "Oct 5 – Oct 12"; a window inside one UTC
 * day (the 1 h preset) reads "Sep 15, 12:00–13:00 UTC".
 */
export function formatWindow(startsAt: Date, endsAt: Date): string {
  if (day(startsAt) === day(endsAt) && startsAt.getUTCFullYear() === endsAt.getUTCFullYear()) {
    return `${day(startsAt)}, ${hhmm(startsAt)}–${hhmm(endsAt)} UTC`;
  }
  return `${day(startsAt)} – ${day(endsAt)}`;
}

function spotters(n: number): string {
  return n === 1 ? "1 spotter" : `${n} spotters`;
}

/** Plain text (unescaped) — `renderInviteCard` escapes it. */
export function inviteDescription(p: PublicInvite): string {
  const by = p.creatorHandle ? ` by @${p.creatorHandle}` : "";
  const window = formatWindow(new Date(p.startsAt), new Date(p.endsAt));
  if (p.status === "cancelled") {
    return `This plane-spotting challenge${by} was cancelled · Get Tailspot to start your own`;
  }
  if (p.status === "finished") {
    return `This plane-spotting challenge${by} has ended · ${window} · ${spotters(p.participantCount)} · Get Tailspot to start your own`;
  }
  const who = p.creatorHandle
    ? `@${p.creatorHandle} invited you to a plane-spotting challenge`
    : "You're invited to a plane-spotting challenge";
  const full = p.participantCount >= p.maxParticipants ? " (full)" : "";
  return `${who} · ${window} · ${spotters(p.participantCount)}${full}`;
}

export function renderInviteCard(
  p: PublicInvite,
  opts: { inviteURL: string; appStoreURL: string },
): string {
  const title = escapeHtml(`${p.name} · Tailspot challenge`);
  const description = escapeHtml(inviteDescription(p));
  const url = escapeHtml(opts.inviteURL);
  const store = escapeHtml(opts.appStoreURL);
  const image = escapeHtml(INVITE_CARD_IMAGE_URL);
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${title}</title>
<meta name="description" content="${description}">
<meta name="robots" content="noindex">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Tailspot">
<meta property="og:title" content="${title}">
<meta property="og:description" content="${description}">
<meta property="og:url" content="${url}">
<meta property="og:image" content="${image}">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${title}">
<meta name="twitter:description" content="${description}">
<meta name="twitter:image" content="${image}">
<meta http-equiv="refresh" content="0;url=${store}">
</head>
<body>
<p><a href="${store}">Get Tailspot on the App Store</a></p>
</body>
</html>
`;
}
