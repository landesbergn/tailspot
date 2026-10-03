import { describe, expect, it } from "vitest";
import {
  type PublicInvite,
  escapeHtml,
  formatWindow,
  inviteDescription,
  renderInviteCard,
} from "../src/challenges/inviteCard.js";

const base: PublicInvite = {
  name: "Weekend Flyoff",
  creatorHandle: "noah",
  startsAt: "2026-10-05T18:00:00.000Z",
  endsAt: "2026-10-12T18:00:00.000Z",
  durationPreset: "7d",
  participantCount: 3,
  maxParticipants: 10,
  status: "upcoming",
};

describe("invite card", () => {
  it("escapes all five HTML-significant characters", () => {
    expect(escapeHtml(`<a href="x" title='y'>&</a>`)).toBe(
      "&lt;a href=&quot;x&quot; title=&#39;y&#39;&gt;&amp;&lt;/a&gt;",
    );
  });

  it("formats the window in UTC", () => {
    expect(formatWindow(new Date(base.startsAt), new Date(base.endsAt))).toBe("Oct 5 – Oct 12");
    // 23:30 UTC + 24 h crosses midnight in UTC regardless of the host's zone.
    expect(formatWindow(new Date("2026-10-05T23:30:00Z"), new Date("2026-10-06T23:30:00Z"))).toBe(
      "Oct 5 – Oct 6",
    );
    expect(formatWindow(new Date("2026-10-05T09:05:00Z"), new Date("2026-10-05T10:05:00Z"))).toBe(
      "Oct 5, 09:05–10:05 UTC",
    );
  });

  it("describes open, full and handle-less challenges", () => {
    expect(inviteDescription(base)).toBe(
      "@noah invited you to a plane-spotting challenge · Oct 5 – Oct 12 · 3 spotters",
    );
    expect(inviteDescription({ ...base, status: "live", participantCount: 10 })).toBe(
      "@noah invited you to a plane-spotting challenge · Oct 5 – Oct 12 · 10 spotters (full)",
    );
    expect(inviteDescription({ ...base, creatorHandle: null, participantCount: 1 })).toBe(
      "You're invited to a plane-spotting challenge · Oct 5 – Oct 12 · 1 spotter",
    );
  });

  it("escapes the name in every place it appears and keeps the markup intact", () => {
    const html = renderInviteCard(
      { ...base, name: `x" onload="alert(1)` },
      { inviteURL: "https://tailspot.app/c/ABCDEF", appStoreURL: "https://example.test/?a=1&b=2" },
    );
    expect(html).not.toContain(`" onload="`);
    // <title>, og:title and twitter:title.
    expect(html.match(/x&quot; onload=&quot;alert\(1\)/g)?.length).toBe(3);
    expect(html).toContain('content="0;url=https://example.test/?a=1&amp;b=2"');
  });
});
