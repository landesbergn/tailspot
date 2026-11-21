/**
 * Notable planes, unit level: the CSV parser, the row mapping and its
 * exclusion rules, the snapshot file, and the refresh (accept / reject /
 * fallback). No test here touches the network: every fetcher is injected.
 */
import { afterEach, describe, expect, it, vi } from "vitest";
import { parseCsv } from "../src/notable/csv.js";
import {
  MAX_UPSTREAM_CSV_BYTES,
  MIN_ENTRIES_WITHOUT_SNAPSHOT,
  NotableDirectory,
  type NotableRefreshOutcome,
  PLANE_ALERT_DB_CSV_URL,
  countNotableKinds,
  loadNotableSnapshot,
  makePlaneAlertCsvFetcher,
  notableRefreshEnabled,
  parseNotableSnapshot,
  readCappedText,
  serializeNotableSnapshot,
  startNotableRefresh,
} from "../src/notable/directory.js";
import {
  CATEGORY_KINDS,
  NOTABLE_LABELS,
  NOTABLE_NAME_MAX_LENGTH,
  type Notable,
  type NotableKind,
  makeNotable,
  mapPlaneAlertRow,
  notableName,
  parsePlaneAlertCsv,
} from "../src/notable/mapping.js";

const HEADER =
  "$ICAO,$Registration,$Operator,$Type,$ICAO Type,#CMPG,$Tag 1,$#Tag 2,$#Tag 3,Category,$#Link";

/** One upstream CSV line. Fields are quoted only when the test passes quotes. */
function line(icao: string, operator: string, cmpg: string, category: string, reg = "N1"): string {
  return `${icao},${reg},${operator},Some Type,B738,${cmpg},Tag One,Tag Two,Tag Three,${category},https://example.invalid/x`;
}

/** A CSV of `n` mapped rows (hex 100000 upward), for refresh-size tests. */
function csvOf(n: number, category = "Bizjets"): string {
  const rows = [HEADER];
  for (let i = 0; i < n; i++) {
    rows.push(line((0x100000 + i).toString(16), `Operator ${i}`, "Civ", category));
  }
  return `${rows.join("\n")}\n`;
}

describe("parseCsv", () => {
  it("splits plain rows and skips blank lines", () => {
    expect(parseCsv("a,b,c\n\n1,2,3\n")).toEqual([
      ["a", "b", "c"],
      ["1", "2", "3"],
    ]);
  });

  it("keeps commas, doubled quotes and line breaks inside quoted fields", () => {
    const text = 'id,name,note\n1,"Smith, John","said ""hi"""\n2,"two\nlines",x\n';
    expect(parseCsv(text)).toEqual([
      ["id", "name", "note"],
      ["1", "Smith, John", 'said "hi"'],
      ["2", "two\nlines", "x"],
    ]);
  });

  it("handles CRLF, a byte-order mark and a missing final newline", () => {
    expect(parseCsv("﻿a,b\r\n1,2")).toEqual([
      ["a", "b"],
      ["1", "2"],
    ]);
  });

  it("keeps empty fields, including a trailing one and a quoted empty one", () => {
    expect(parseCsv('a,,c\nx,y,\n"",z\n')).toEqual([
      ["a", "", "c"],
      ["x", "y", ""],
      ["", "z"],
    ]);
  });

  it("does not throw on an unterminated quote (a truncated download)", () => {
    expect(parseCsv('a,b\n1,"never closed\n2,3')).toEqual([
      ["a", "b"],
      ["1", "never closed\n2,3"],
    ]);
  });
});

describe("mapPlaneAlertRow", () => {
  const row = (category: string, cmpg = "Civ", operator = "Acme Air", icao = "A1B2C3") =>
    mapPlaneAlertRow({ icao, operator, cmpg, category });

  it("maps every listed category to its kind and that kind's fixed label", () => {
    const expected: Record<NotableKind, string[]> = {
      government: ["Governments", "Dictator Alert", "Head of State", "Royal Aircraft"],
      celebrity: ["Don't you know who I am?"],
      business: ["As Seen on TV", "Bizjets", "Vanity Plate", "Climate Crisis", "Oligarch"],
      team: ["Football"],
      special: [
        "Historic",
        "Distinctive",
        "Aerobatic Teams",
        "Big Hello",
        "Gas Bags",
        "Nuclear",
        "Radiohead",
        "Jump Johnny Jump",
        "You came here in that thing?",
        "Zoomies",
      ],
      working: [
        "Coastguard",
        "Aerial Firefighter",
        "Hired Gun",
        "Ptolemy would be proud",
        "Dogs with Jobs",
        "Perfectly Serviceable Aircraft",
        "Oxcart",
        "Special Forces",
        "CAP",
        "Fire Fighting",
        "Quango",
      ],
    };
    for (const [kind, categories] of Object.entries(expected) as [NotableKind, string[]][]) {
      for (const category of categories) {
        expect(row(category), category).toEqual({
          icao24: "a1b2c3",
          notable: { kind, label: NOTABLE_LABELS[kind], name: "Acme Air" },
        });
      }
    }
    // The table above IS the whole allow-list: nothing is mapped that isn't pinned here.
    expect(Object.keys(CATEGORY_KINDS).sort()).toEqual(Object.values(expected).flat().sort());
  });

  it("uses the fixed user-facing labels", () => {
    expect(NOTABLE_LABELS).toEqual({
      government: "Head of state and government",
      celebrity: "Celebrity",
      business: "Business jet",
      team: "Team plane",
      special: "Historic and special",
      working: "Special mission",
    });
  });

  it("excludes the always-excluded categories and anything unmapped", () => {
    for (const category of [
      "Flying Doctors",
      "Police Forces",
      "UK National Police Air Service",
      "PIA",
      "USAF",
      "Other Air Forces",
      "Joe Cool",
      "Da Comrade",
      "A Category Upstream Adds Next Year",
      "",
      // A category that is a prototype key must not slip through the lookup.
      "constructor",
      "toString",
    ]) {
      expect(row(category), category).toBeNull();
    }
  });

  it("matches categories exactly (case and wording), after trimming", () => {
    expect(row("  Bizjets  ")?.notable.kind).toBe("business");
    expect(row("bizjets")).toBeNull();
    expect(row("Bizjet")).toBeNull();
  });

  it("drops military and police rows, except in the six kept categories", () => {
    for (const cmpg of ["Mil", "Pol", " mil ", "POL"]) {
      for (const dropped of ["Distinctive", "Oxcart", "Special Forces", "Coastguard", "Nuclear"]) {
        expect(row(dropped, cmpg), `${dropped}/${cmpg}`).toBeNull();
      }
      for (const kept of [
        "Governments",
        "Dictator Alert",
        "Head of State",
        "Royal Aircraft",
        "Historic",
        "Aerobatic Teams",
      ]) {
        expect(row(kept, cmpg), `${kept}/${cmpg}`).not.toBeNull();
      }
    }
    // Civ and Gov rows are kept everywhere a category is mapped.
    expect(row("Distinctive", "Gov")).not.toBeNull();
    expect(row("Oxcart", "Civ")).not.toBeNull();
    // The exception never rescues an excluded category.
    expect(row("Police Forces", "Civ")).toBeNull();
    expect(row("USAF", "Gov")).toBeNull();
  });

  it("lowercases the hex and skips malformed ones", () => {
    expect(row("Bizjets", "Civ", "Acme", " ADFDF8 ")?.icao24).toBe("adfdf8");
    for (const bad of ["10166", "", "zzzzzz", "abcdef0", "~abcde", "ab cd1"]) {
      expect(row("Bizjets", "Civ", "Acme", bad), bad).toBeNull();
    }
  });

  it("never exposes the tags or the raw category", () => {
    const [mapped] = [
      ...parsePlaneAlertCsv(
        `${HEADER}\n${line("a1b2c3", "Gov of Somewhere", "Gov", "Dictator Alert")}\n`,
      ).values(),
    ];
    expect(mapped).toEqual({
      kind: "government",
      label: "Head of state and government",
      name: "Gov of Somewhere",
    });
    expect(JSON.stringify(mapped)).not.toMatch(/Dictator|Tag /);
  });
});

describe("notableName", () => {
  it("trims, collapses whitespace and caps the length", () => {
    expect(notableName("  Acme   Air  ")).toBe("Acme Air");
    const long = `${"x".repeat(NOTABLE_NAME_MAX_LENGTH - 1)} yz`;
    const capped = notableName(long);
    expect(capped).toBe("x".repeat(NOTABLE_NAME_MAX_LENGTH - 1));
    expect(capped?.length).toBeLessThanOrEqual(NOTABLE_NAME_MAX_LENGTH);
  });

  it("omits empty values and placeholders", () => {
    for (const v of ["", "   ", "Private", "private", "PRIVATE OWNER", "Unknown", "Corporate"]) {
      expect(notableName(v), v).toBeUndefined();
    }
    for (const v of ["Unknown Owner", "Operator Unknown", "TBC", "N/A"]) {
      expect(notableName(v), v).toBeUndefined();
    }
    // A real name that merely contains a placeholder word is kept.
    expect(notableName("Wheels Up Private Jets")).toBe("Wheels Up Private Jets");
  });

  it("caps by code point and never splits a surrogate pair", () => {
    const plane = "\u{1F6E9}"; // one code point, two UTF-16 units
    // 59 letters then two planes: the cap of 60 lands between the pair's halves
    // if you count UTF-16 units.
    const capped = notableName(`${"x".repeat(NOTABLE_NAME_MAX_LENGTH - 1)}${plane}${plane}`);
    expect(capped).toBe(`${"x".repeat(NOTABLE_NAME_MAX_LENGTH - 1)}${plane}`);
    expect(Array.from(capped ?? "")).toHaveLength(NOTABLE_NAME_MAX_LENGTH);
    // No lone surrogate anywhere: it survives a UTF-8 round trip unchanged.
    expect(Buffer.from(capped ?? "", "utf8").toString("utf8")).toBe(capped);
    // 60 astral characters are 120 UTF-16 units and still fit whole.
    expect(notableName(plane.repeat(NOTABLE_NAME_MAX_LENGTH + 5))).toBe(
      plane.repeat(NOTABLE_NAME_MAX_LENGTH),
    );
    // Exactly at the cap: untouched.
    expect(notableName("y".repeat(NOTABLE_NAME_MAX_LENGTH))).toBe(
      "y".repeat(NOTABLE_NAME_MAX_LENGTH),
    );
  });

  it("strips control, bidi and zero-width characters before trimming", () => {
    // Bidi overrides and isolates (the "Trojan Source" set).
    for (const cp of [0x202a, 0x202b, 0x202c, 0x202d, 0x202e, 0x2066, 0x2067, 0x2068, 0x2069]) {
      const ch = String.fromCodePoint(cp);
      expect(notableName(`Acme${ch} Air${ch}`), cp.toString(16)).toBe("Acme Air");
    }
    // Zero-width characters, directional marks, BOM, soft hyphen.
    for (const cp of [0x200b, 0x200c, 0x200d, 0x2060, 0xfeff, 0x200e, 0x200f, 0x00ad, 0x061c]) {
      const ch = String.fromCodePoint(cp);
      expect(notableName(`${ch}Ac${ch}me Air${ch}`), cp.toString(16)).toBe("Acme Air");
    }
    // C0 and C1 controls and DEL are removed; tabs and line breaks are
    // whitespace, so they become a space rather than gluing words together.
    expect(notableName("Ac\u0000me\u0007 A\u001bir\u007f\u0085\u009f")).toBe("Acme Air");
    expect(notableName("Acme\tAir\r\nLtd")).toBe("Acme Air Ltd");
    // Stripping happens BEFORE the trim and the placeholder check.
    expect(notableName("\u200b \u202e ")).toBeUndefined();
    expect(notableName(" \u202ePrivate\u202c ")).toBeUndefined();
    expect(notableName("\u200bN101YK", "N101YK")).toBeUndefined();
    // A removed character between two spaces does not leave a double space.
    expect(notableName("Acme \u200b Air")).toBe("Acme Air");
    // Ordinary non-ASCII names are left alone.
    expect(notableName("Société Aérienne Ōsaka")).toBe("Société Aérienne Ōsaka");
  });

  it("omits an operator that just repeats the registration", () => {
    expect(notableName("N101YK", "N101YK")).toBeUndefined();
    expect(notableName("Acme", "N101YK")).toBe("Acme");
  });

  it("a row with no usable name has no `name` key at all", () => {
    const mapped = mapPlaneAlertRow({
      icao: "a1b2c3",
      operator: "Private",
      cmpg: "Civ",
      category: "Historic",
    });
    expect(mapped?.notable).toEqual({ kind: "special", label: "Historic and special" });
    expect(Object.keys(mapped?.notable ?? {})).toEqual(["kind", "label"]);
  });
});

describe("parsePlaneAlertCsv", () => {
  it("parses rows, including a quoted operator with a comma, and applies the rules", () => {
    const csv = [
      HEADER,
      line("A00001", '"Smith, Jones & Co"', "Civ", "Bizjets"),
      line("a00002", "Some Air Force", "Mil", "Distinctive"), // dropped: Mil
      line("a00003", "Some Air Force", "Mil", "Governments"), // kept: exception
      line("a00004", "Metro Police", "Pol", "Police Forces"), // dropped
      line("10166", "Short Hex", "Civ", "Bizjets"), // dropped: malformed
      line("a00006", "Private", "Civ", "Football"),
      line("a00001", "Duplicate", "Civ", "Football"), // first row wins
    ].join("\r\n");
    expect([...parsePlaneAlertCsv(csv).entries()]).toEqual([
      ["a00001", { kind: "business", label: "Business jet", name: "Smith, Jones & Co" }],
      [
        "a00003",
        { kind: "government", label: "Head of state and government", name: "Some Air Force" },
      ],
      ["a00006", { kind: "team", label: "Team plane" }],
    ]);
  });

  it("finds columns by header name, so a reordered file still parses", () => {
    const csv = "Category,#CMPG,$Operator,$ICAO\nFootball,Civ,Some Club,abc123\n";
    expect([...parsePlaneAlertCsv(csv).entries()]).toEqual([
      ["abc123", { kind: "team", label: "Team plane", name: "Some Club" }],
    ]);
  });

  it("returns nothing when a needed column is missing, or the text is not the CSV", () => {
    expect(parsePlaneAlertCsv("$ICAO,$Operator,Category\nabc123,X,Football\n").size).toBe(0);
    expect(parsePlaneAlertCsv("<html><body>404: Not Found</body></html>").size).toBe(0);
    expect(parsePlaneAlertCsv("").size).toBe(0);
  });
});

describe("the committed snapshot", () => {
  const snapshot = loadNotableSnapshot();

  it("loads, and every entry is well formed", () => {
    expect(snapshot.size).toBeGreaterThan(4000);
    for (const [icao24, n] of snapshot) {
      expect(icao24).toMatch(/^[0-9a-f]{6}$/);
      expect(n.label).toBe(NOTABLE_LABELS[n.kind]);
      if (n.name !== undefined) {
        expect(n.name.length).toBeGreaterThan(0);
        expect(n.name.length).toBeLessThanOrEqual(NOTABLE_NAME_MAX_LENGTH);
      }
    }
  });

  it("covers all six kinds", () => {
    expect(new Set([...snapshot.values()].map((n) => n.kind))).toEqual(
      new Set(Object.keys(NOTABLE_LABELS)),
    );
  });

  it("round-trips through serialize and parse", () => {
    const entries = new Map<string, Notable>([
      ["bbbbbb", makeNotable("team")],
      ["aaaaaa", makeNotable("celebrity", 'A "Quoted", Name')],
    ]);
    const text = serializeNotableSnapshot(entries, "2026-11-21");
    expect(JSON.parse(text)).toMatchObject({ count: 2, generatedAt: "2026-11-21" });
    // Sorted by hex, one airframe per line.
    expect(text.split("\n")[1]).toContain('"aaaaaa"');
    expect([...parseNotableSnapshot(text).entries()]).toEqual([
      ["aaaaaa", { kind: "celebrity", label: "Celebrity", name: 'A "Quoted", Name' }],
      ["bbbbbb", { kind: "team", label: "Team plane" }],
    ]);
  });

  it("parse skips malformed rows and rejects a file with no airframes", () => {
    const text = JSON.stringify({
      airframes: [["aaaaaa", "team"], ["XYZ", "team"], ["bbbbbb", "not-a-kind"], "junk", []],
    });
    expect([...parseNotableSnapshot(text).keys()]).toEqual(["aaaaaa"]);
    expect(() => parseNotableSnapshot("{}")).toThrow();
  });
});

/** Zero for every kind, to spread into an expected per-kind count. */
const NO_KINDS = { government: 0, celebrity: 0, business: 0, team: 0, special: 0, working: 0 };

describe("NotableDirectory", () => {
  const seed = () =>
    new NotableDirectory(
      new Map(
        Array.from({ length: 10 }, (_, i) => [
          (0xa00000 + i).toString(16),
          makeNotable("business", `Seed ${i}`),
        ]),
      ),
    );

  it("looks up by lowercase hex, tolerating case and whitespace", () => {
    const dir = seed();
    expect(dir.lookup("a00003")).toEqual({
      kind: "business",
      label: "Business jet",
      name: "Seed 3",
    });
    expect(dir.lookup(" A00003 ")).toEqual(dir.lookup("a00003"));
    expect(dir.lookup("ffffff")).toBeUndefined();
    expect(dir.size).toBe(10);
  });

  it("fromSnapshot never throws: a missing file reports the error and starts empty", () => {
    const errors: unknown[] = [];
    const dir = NotableDirectory.fromSnapshot({
      path: "/nonexistent/notable-airframes.json",
      onError: (err) => errors.push(err),
    });
    expect(dir.size).toBe(0);
    expect(errors).toHaveLength(1);
    expect(dir.minimumRefreshEntries).toBe(MIN_ENTRIES_WITHOUT_SNAPSHOT);
  });

  it("fromSnapshot with no arguments loads the committed file", () => {
    expect(NotableDirectory.fromSnapshot().size).toBe(loadNotableSnapshot().size);
  });

  it("refresh ACCEPTS a plausible result and swaps the data", async () => {
    const dir = seed();
    const outcome = await dir.refresh(async () => csvOf(7));
    expect(outcome).toEqual({
      status: "updated",
      entries: 7,
      previous: 10,
      kinds: { ...NO_KINDS, business: 7 },
    });
    expect(dir.size).toBe(7);
    expect(dir.lookup("100000")).toEqual({
      kind: "business",
      label: "Business jet",
      name: "Operator 0",
    });
    // An airframe upstream dropped is no longer notable.
    expect(dir.lookup("a00003")).toBeUndefined();
  });

  it("refresh accepts exactly half the snapshot and REJECTS one fewer", async () => {
    const dir = seed();
    expect(dir.minimumRefreshEntries).toBe(5);
    expect(await dir.refresh(async () => csvOf(4))).toEqual({
      status: "rejected",
      reason: "4 airframes, fewer than the minimum of 5",
      entries: 4,
      minimum: 5,
      kinds: { ...NO_KINDS, business: 4 },
      minimumKinds: { ...NO_KINDS, business: 5 },
      kept: 10,
    });
    expect(dir.size).toBe(10);
    expect(dir.lookup("a00003")?.name).toBe("Seed 3");
    expect((await dir.refresh(async () => csvOf(5))).status).toBe("updated");
  });

  it("the size floor stays pinned to the SNAPSHOT, not to the last refresh", async () => {
    const dir = seed();
    await dir.refresh(async () => csvOf(100));
    expect(dir.size).toBe(100);
    // 5 is half the snapshot's 10; it is not held to half of 100.
    expect((await dir.refresh(async () => csvOf(5))).status).toBe("updated");
    expect((await dir.refresh(async () => csvOf(4))).status).toBe("rejected");
  });

  it("refresh rejects an error page served as text, and an empty body", async () => {
    const dir = seed();
    for (const body of ["<html>503 Service Unavailable</html>", "", HEADER]) {
      expect((await dir.refresh(async () => body)).status).toBe("rejected");
    }
    expect(dir.size).toBe(10);
  });

  it("refresh FALLS BACK to the current data when the fetch fails, and never throws", async () => {
    const dir = seed();
    expect(
      await dir.refresh(async () => {
        throw new Error("HTTP 503");
      }),
    ).toEqual({ status: "failed", error: "HTTP 503", kept: 10 });
    // A fetcher that throws synchronously, or throws a non-Error.
    expect(
      (
        await dir.refresh(() => {
          throw "boom";
        })
      ).status,
    ).toBe("failed");
    expect(dir.size).toBe(10);
    expect(dir.lookup("a00003")?.name).toBe("Seed 3");
  });

  it("refresh times out a fetch that never answers, and aborts it", async () => {
    const dir = seed();
    let aborted = false;
    const outcome = await dir.refresh(
      (signal) =>
        new Promise<string>(() => {
          signal.addEventListener("abort", () => {
            aborted = true;
          });
        }),
      { timeoutMs: 20 },
    );
    expect(outcome).toEqual({ status: "failed", error: "no answer within 20 ms", kept: 10 });
    expect(aborted).toBe(true);
    expect(dir.size).toBe(10);
  });

  describe("per-kind floor", () => {
    // A snapshot of 20 business jets, 6 team planes and 1 celebrity.
    const mixed = () => {
      const entries = new Map<string, Notable>();
      let n = 0xb00000;
      const add = (kind: NotableKind, count: number) => {
        for (let i = 0; i < count; i++) entries.set((n++).toString(16), makeNotable(kind));
      };
      add("business", 20);
      add("team", 6);
      add("celebrity", 1);
      return new NotableDirectory(entries);
    };
    /** An upstream CSV with the given number of rows per category. */
    const csvWith = (counts: Record<string, number>) => {
      const rows = [HEADER];
      let n = 0x200000;
      for (const [category, count] of Object.entries(counts)) {
        for (let i = 0; i < count; i++) rows.push(line((n++).toString(16), "Op", "Civ", category));
      }
      return rows.join("\n");
    };
    const CELEB = "Don't you know who I am?";

    it("each kind in the snapshot is held to half its own count", () => {
      expect(mixed().minimumRefreshKinds).toEqual({
        ...NO_KINDS,
        business: 10,
        team: 3,
        celebrity: 1,
      });
      // No snapshot: no per-kind floor at all.
      expect(new NotableDirectory().minimumRefreshKinds).toEqual(NO_KINDS);
    });

    it("REJECTS a refresh that clears the total but empties one kind, and says which", async () => {
      const dir = mixed();
      // 27 in the snapshot → total floor 14. This has 40, but no team planes:
      // what an upstream rename of the Football category would look like.
      const outcome = await dir.refresh(async () => csvWith({ Bizjets: 39, [CELEB]: 1 }));
      expect(outcome).toEqual({
        status: "rejected",
        reason: "team: 0, minimum 3",
        entries: 40,
        minimum: 14,
        kinds: { ...NO_KINDS, business: 39, celebrity: 1 },
        minimumKinds: { ...NO_KINDS, business: 10, team: 3, celebrity: 1 },
        kept: 27,
      });
      expect(dir.size).toBe(27);
      expect(dir.lookup("b00014")?.kind).toBe("team"); // the old data still serves
    });

    it("rejects one below a kind's floor and accepts exactly on it", async () => {
      const dir = mixed();
      const below = await dir.refresh(async () =>
        csvWith({ Bizjets: 20, Football: 2, [CELEB]: 1 }),
      );
      expect(below).toMatchObject({ status: "rejected", reason: "team: 2, minimum 3" });
      const on = await dir.refresh(async () => csvWith({ Bizjets: 10, Football: 3, [CELEB]: 1 }));
      expect(on).toEqual({
        status: "updated",
        entries: 14,
        previous: 27,
        kinds: { ...NO_KINDS, business: 10, team: 3, celebrity: 1 },
      });
    });

    it("names every kind that fell short", async () => {
      const outcome = await mixed().refresh(async () => csvWith({ Bizjets: 30 }));
      expect(outcome).toMatchObject({
        status: "rejected",
        reason: "celebrity: 0, minimum 1; team: 0, minimum 3",
      });
    });

    it("a kind the snapshot lacks has no floor, and a new kind is welcome", async () => {
      const dir = mixed();
      const outcome = await dir.refresh(async () =>
        csvWith({ Bizjets: 20, Football: 6, [CELEB]: 1, Historic: 50 }),
      );
      expect(outcome).toMatchObject({ status: "updated", kinds: { special: 50, working: 0 } });
    });

    it("the per-kind floor stays pinned to the snapshot across refreshes", async () => {
      const dir = mixed();
      await dir.refresh(async () => csvWith({ Bizjets: 20, Football: 100, [CELEB]: 1 }));
      // Team is held to 3 (half the snapshot's 6), not to half of 100.
      expect(
        (await dir.refresh(async () => csvWith({ Bizjets: 20, Football: 3, [CELEB]: 1 }))).status,
      ).toBe("updated");
    });

    it("the committed snapshot sets a floor for all six kinds", () => {
      const floors = NotableDirectory.fromSnapshot().minimumRefreshKinds;
      for (const kind of Object.keys(NOTABLE_LABELS) as NotableKind[]) {
        expect(floors[kind], kind).toBeGreaterThan(0);
      }
      expect(floors).toEqual(
        Object.fromEntries(
          Object.entries(countNotableKinds(loadNotableSnapshot())).map(([k, n]) => [
            k,
            Math.ceil(n / 2),
          ]),
        ),
      );
    });
  });

  it("with no snapshot, a refresh must clear the absolute floor", async () => {
    const dir = new NotableDirectory();
    expect((await dir.refresh(async () => csvOf(MIN_ENTRIES_WITHOUT_SNAPSHOT - 1))).status).toBe(
      "rejected",
    );
    expect((await dir.refresh(async () => csvOf(MIN_ENTRIES_WITHOUT_SNAPSHOT))).status).toBe(
      "updated",
    );
  });
});

describe("the upstream fetcher: body cap", () => {
  const signal = new AbortController().signal;
  /** A streamed body of `chunks` chunks of `size` bytes, with pull/cancel counters. */
  function streamed(chunks: number, size: number, headers: Record<string, string> = {}) {
    const state = { pulled: 0, cancelled: false };
    const body = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (state.pulled >= chunks) return controller.close();
        state.pulled += 1;
        controller.enqueue(new Uint8Array(size).fill(0x61));
      },
      cancel() {
        state.cancelled = true;
      },
    });
    return { state, res: new Response(body, { headers }) };
  }

  it("reads a body under the cap, across chunks, including a split multi-byte character", async () => {
    expect(await readCappedText(new Response("a,b\n1,2\n"), 100)).toBe("a,b\n1,2\n");
    const bytes = new TextEncoder().encode("Société ✈ Aérienne");
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        for (const b of bytes) controller.enqueue(Uint8Array.of(b)); // one byte per chunk
        controller.close();
      },
    });
    expect(await readCappedText(new Response(body), 100)).toBe("Société ✈ Aérienne");
    // Exactly at the cap is allowed.
    expect(await readCappedText(streamed(4, 25).res, 100)).toHaveLength(100);
    expect(await readCappedText(new Response(null), 100)).toBe("");
  });

  it("refuses on content-length alone, before reading a byte", async () => {
    const over = MAX_UPSTREAM_CSV_BYTES + 1;
    const { state, res } = streamed(1000, 1024, { "content-length": String(over) });
    await expect(readCappedText(res, MAX_UPSTREAM_CSV_BYTES)).rejects.toThrow(
      `response too large: content-length ${over} exceeds ${MAX_UPSTREAM_CSV_BYTES} bytes`,
    );
    expect(state.pulled).toBeLessThanOrEqual(1); // at most the stream's own prefetch
    expect(state.cancelled).toBe(true);
    expect(MAX_UPSTREAM_CSV_BYTES).toBe(8 * 1024 * 1024);
  });

  it("aborts a stream that runs past the cap, whatever content-length claimed", async () => {
    // No header at all, and a header that lies low: both are counted, not trusted.
    for (const headers of [{}, { "content-length": "10" }] as Record<string, string>[]) {
      const { state, res } = streamed(1_000_000, 1024, headers);
      await expect(readCappedText(res, 10 * 1024)).rejects.toThrow(
        "response too large: more than 10240 bytes",
      );
      // It stopped just past the cap instead of draining a gigabyte.
      expect(state.pulled).toBeLessThanOrEqual(12);
      expect(state.cancelled).toBe(true);
    }
  });

  it("the fetcher applies the cap, sends no user data, and rejects a non-2xx", async () => {
    const calls: { url: string; init: RequestInit | undefined }[] = [];
    const ok = makePlaneAlertCsvFetcher({
      fetchFn: (async (url: string, init?: RequestInit) => {
        calls.push({ url, init });
        return new Response(csvOf(2));
      }) as typeof fetch,
    });
    expect(await ok(signal)).toBe(csvOf(2));
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe(PLANE_ALERT_DB_CSV_URL);
    expect(calls[0].init?.signal).toBe(signal);
    expect(calls[0].init?.headers).toEqual({ "user-agent": "tailspot-api-notable-refresh" });

    const tooBig = makePlaneAlertCsvFetcher({
      maxBytes: 64,
      fetchFn: (async () => new Response(csvOf(50))) as typeof fetch,
    });
    await expect(tooBig(signal)).rejects.toThrow("response too large");

    const down = makePlaneAlertCsvFetcher({
      fetchFn: (async () => new Response("nope", { status: 503 })) as typeof fetch,
    });
    await expect(down(signal)).rejects.toThrow("HTTP 503");
  });

  it("an oversized upstream body is a FAILED refresh that keeps the current data", async () => {
    const dir = new NotableDirectory(new Map([["a00000", makeNotable("business", "Seed")]]));
    const outcome = await dir.refresh(
      makePlaneAlertCsvFetcher({
        maxBytes: 64,
        fetchFn: (async () => new Response(csvOf(50))) as typeof fetch,
      }),
    );
    expect(outcome).toEqual({
      status: "failed",
      error: "response too large: more than 64 bytes",
      kept: 1,
    });
    expect(dir.lookup("a00000")?.name).toBe("Seed");
  });
});

describe("the real upstream shape", () => {
  it("the mapped snapshot is what the mapping makes of a real-looking excerpt", () => {
    // Verbatim rows from plane-alert-db (2026-11-21), one per rule.
    const csv = [
      HEADER,
      "000004,FAC1282,Colombian Aerospace Force,CASA C-295 M,C295,Mil,Cargo,Tactical Transport,Marching Powder,Other Air Forces,https://w.wiki/8pa2",
      "ADFDF8,82-8000,US Government,Boeing VC25A,B742,Gov,Air Force One,Government,POTUS,Radiohead,https://en.wikipedia.org/wiki/Boeing_VC-25",
    ].join("\n");
    expect([...parsePlaneAlertCsv(csv).entries()]).toEqual([
      [
        "adfdf8",
        { kind: "government", label: "Head of state and government", name: "US Government" },
      ],
    ]);
    // The committed snapshot is real data that changes when regenerated, so
    // only its shape is checked here, never a particular airframe.
    expect(loadNotableSnapshot().size).toBeGreaterThan(1000);
  });
});

describe("refresh wiring", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it("is off under test and when NOTABLE_REFRESH says so", () => {
    expect(notableRefreshEnabled({ NODE_ENV: "test" })).toBe(false);
    expect(notableRefreshEnabled({ NODE_ENV: "production" })).toBe(true);
    expect(notableRefreshEnabled({})).toBe(true);
    for (const flag of ["off", "OFF", " off ", "false", "0", "no"]) {
      expect(notableRefreshEnabled({ NODE_ENV: "production", NOTABLE_REFRESH: flag }), flag).toBe(
        false,
      );
    }
    expect(notableRefreshEnabled({ NODE_ENV: "production", NOTABLE_REFRESH: "on" })).toBe(true);
    expect(notableRefreshEnabled({ NODE_ENV: "production", NOTABLE_REFRESH: "" })).toBe(true);
    // The suite itself runs with the refresh off.
    expect(notableRefreshEnabled()).toBe(false);
  });

  it("refreshes shortly after start and then daily, reports each outcome, and stops", async () => {
    vi.useFakeTimers();
    const dir = new NotableDirectory(new Map([["a00000", makeNotable("team")]]));
    let fetches = 0;
    const outcomes: NotableRefreshOutcome[] = [];
    const stop = startNotableRefresh(dir, {
      fetchCsv: async () => {
        fetches++;
        if (fetches === 2) throw new Error("HTTP 500");
        return csvOf(3, "Football");
      },
      onOutcome: (o) => {
        outcomes.push(o);
        throw new Error("a listener that throws must not stop the refresh");
      },
    });

    expect(fetches).toBe(0); // nothing at start: boot is never delayed
    await vi.advanceTimersByTimeAsync(30_000);
    expect(fetches).toBe(1);
    expect(dir.size).toBe(3);

    await vi.advanceTimersByTimeAsync(24 * 60 * 60_000);
    expect(fetches).toBe(2); // this one fails: the data stays
    expect(dir.size).toBe(3);

    await vi.advanceTimersByTimeAsync(24 * 60 * 60_000);
    expect(fetches).toBe(3);
    expect(outcomes.map((o) => o.status)).toEqual(["updated", "failed", "updated"]);

    stop();
    await vi.advanceTimersByTimeAsync(3 * 24 * 60 * 60_000);
    expect(fetches).toBe(3);
  });

  it("stop before the first run cancels it", async () => {
    vi.useFakeTimers();
    let fetches = 0;
    const stop = startNotableRefresh(new NotableDirectory(), {
      fetchCsv: async () => {
        fetches++;
        return "";
      },
    });
    stop();
    await vi.advanceTimersByTimeAsync(2 * 24 * 60 * 60_000);
    expect(fetches).toBe(0);
  });
});
