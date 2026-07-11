import { describe, expect, it } from "vitest";
import {
  addDaysUtc,
  monthStartUtc,
  nextMonthStartUtc,
  nextWeekStartUtc,
  parseWindow,
  utcDateString,
  weekStartUtc,
} from "../src/identity/windows.js";

/**
 * Pure UTC window math. Weeks start Monday 00:00 UTC, months on the 1st
 * 00:00 UTC (locked design). UTC has no DST, so the interesting edges are the
 * day-of-week re-basing (JS weeks start Sunday), month lengths, and year
 * wraps — all covered here.
 */

/** Shorthand: a UTC instant. */
function utc(
  y: number,
  m1: number, // 1-based month, like a human reads a date
  d: number,
  h = 0,
  min = 0,
): Date {
  return new Date(Date.UTC(y, m1 - 1, d, h, min));
}

describe("parseWindow", () => {
  it("accepts the two named windows and falls back to all on anything else", () => {
    expect(parseWindow("week")).toBe("week");
    expect(parseWindow("month")).toBe("month");
    expect(parseWindow("all")).toBe("all");
    expect(parseWindow(undefined)).toBe("all"); // old clients: no param
    expect(parseWindow("WEEK")).toBe("all"); // case-sensitive by contract
    expect(parseWindow("fortnight")).toBe("all");
    expect(parseWindow(7)).toBe("all");
  });
});

describe("weekStartUtc", () => {
  it("maps every day of a week to its Monday (incl. the Sunday edge, JS day 0)", () => {
    const monday = utc(2026, 7, 6); // Mon 2026-07-06
    // Mon..Sun of that calendar week, at an arbitrary time of day.
    for (let offset = 0; offset < 7; offset++) {
      const day = utc(2026, 7, 6 + offset, 15, 30);
      expect(weekStartUtc(day).toISOString()).toBe(monday.toISOString());
    }
    // The next Monday starts a NEW week.
    expect(weekStartUtc(utc(2026, 7, 13)).toISOString()).toBe(utc(2026, 7, 13).toISOString());
  });

  it("is exact at the boundary: Monday 00:00:00.000 belongs to the new week", () => {
    expect(weekStartUtc(utc(2026, 7, 6, 0, 0)).toISOString()).toBe("2026-07-06T00:00:00.000Z");
    // One millisecond earlier is still the old week.
    const justBefore = new Date(utc(2026, 7, 6).getTime() - 1);
    expect(weekStartUtc(justBefore).toISOString()).toBe("2026-06-29T00:00:00.000Z");
  });

  it("wraps the year: early-January days belong to a December Monday", () => {
    // Fri 2027-01-01 → week started Mon 2026-12-28.
    expect(weekStartUtc(utc(2027, 1, 1)).toISOString()).toBe("2026-12-28T00:00:00.000Z");
    // Sun 2027-01-03 too.
    expect(weekStartUtc(utc(2027, 1, 3, 23, 59)).toISOString()).toBe("2026-12-28T00:00:00.000Z");
  });
});

describe("nextWeekStartUtc", () => {
  it("is the following Monday 00:00 UTC (the week window's resetsAt)", () => {
    expect(nextWeekStartUtc(utc(2026, 7, 11, 12)).toISOString()).toBe("2026-07-13T00:00:00.000Z");
    // Year wrap: from Thu 2026-12-31 the next reset is Mon 2027-01-04.
    expect(nextWeekStartUtc(utc(2026, 12, 31)).toISOString()).toBe("2027-01-04T00:00:00.000Z");
  });
});

describe("monthStartUtc / nextMonthStartUtc", () => {
  it("clamps to the 1st and rolls to the next 1st across month lengths", () => {
    expect(monthStartUtc(utc(2026, 7, 11, 12)).toISOString()).toBe("2026-07-01T00:00:00.000Z");
    expect(nextMonthStartUtc(utc(2026, 7, 11)).toISOString()).toBe("2026-08-01T00:00:00.000Z");
    // 28-day February (2027 is not a leap year)…
    expect(nextMonthStartUtc(utc(2027, 2, 28, 23, 59)).toISOString()).toBe(
      "2027-03-01T00:00:00.000Z",
    );
    // …and 29-day February (2028 is).
    expect(monthStartUtc(utc(2028, 2, 29)).toISOString()).toBe("2028-02-01T00:00:00.000Z");
    expect(nextMonthStartUtc(utc(2028, 2, 29)).toISOString()).toBe("2028-03-01T00:00:00.000Z");
    // 30-day month.
    expect(nextMonthStartUtc(utc(2026, 4, 30)).toISOString()).toBe("2026-05-01T00:00:00.000Z");
  });

  it("wraps the year: December's next month is January of the next year", () => {
    expect(nextMonthStartUtc(utc(2026, 12, 15)).toISOString()).toBe("2027-01-01T00:00:00.000Z");
  });
});

describe("addDaysUtc / utcDateString", () => {
  it("shifts by whole UTC days and formats midnight dates as YYYY-MM-DD", () => {
    expect(addDaysUtc(utc(2026, 7, 6), -7).toISOString()).toBe("2026-06-29T00:00:00.000Z");
    expect(utcDateString(utc(2026, 6, 29))).toBe("2026-06-29");
    expect(utcDateString(addDaysUtc(utc(2027, 1, 4), -7))).toBe("2026-12-28");
  });
});
