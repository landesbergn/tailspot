import { describe, expect, it } from "vitest";
import { normalizeCode } from "../src/challenges/codes.js";
import { assignPlacements, decideOutcome, winners } from "../src/challenges/placement.js";
import { aircraftName } from "../src/challenges/store.js";

describe("competition placement", () => {
  it("shares placement on ties and skips the next (1, 1, 3)", () => {
    const placed = assignPlacements([
      { handle: "c", points: 60 },
      { handle: "a", points: 100 },
      { handle: "b", points: 100 },
    ]);
    expect(placed.map((p) => [p.handle, p.placement])).toEqual([
      ["a", 1],
      ["b", 1],
      ["c", 3],
    ]);
  });

  it("is deterministic regardless of input order", () => {
    const a = assignPlacements([
      { handle: "Zed", points: 10 },
      { handle: "amy", points: 10 },
    ]);
    const b = assignPlacements([
      { handle: "amy", points: 10 },
      { handle: "Zed", points: 10 },
    ]);
    expect(a).toEqual(b);
    expect(a[0].handle).toBe("amy");
  });

  it("everyone at placement 1 wins; No Contest has no winners", () => {
    const rows = [
      { handle: "a", points: 100 },
      { handle: "b", points: 100 },
      { handle: "c", points: 5 },
    ];
    const placed = assignPlacements(rows);
    expect(winners(placed, "decided").map((w) => w.handle)).toEqual(["a", "b"]);
    expect(winners(placed, "no_contest")).toEqual([]);
  });

  it("No Contest when fewer than two participants or nobody scored", () => {
    expect(decideOutcome([{ handle: "solo", points: 500 }])).toBe("no_contest");
    expect(
      decideOutcome([
        { handle: "a", points: 0 },
        { handle: "b", points: 0 },
      ]),
    ).toBe("no_contest");
    expect(
      decideOutcome([
        { handle: "a", points: 10 },
        { handle: "b", points: 0 },
      ]),
    ).toBe("decided");
  });
});

describe("invite codes", () => {
  it("folds lowercase, spaces and dashes; rejects lookalikes and bad lengths", () => {
    expect(normalizeCode("k7m4 qd2x")).toBe("K7M4QD2X");
    expect(normalizeCode("K7M4-QD2X")).toBe("K7M4QD2X");
    expect(normalizeCode("K7M4QD2")).toBeNull();
    expect(normalizeCode("K7M4QD2O")).toBeNull(); // O is not in the alphabet
    expect(normalizeCode("K7M4QD21")).toBeNull(); // 1 is not in the alphabet
    expect(normalizeCode(42)).toBeNull();
  });
});

describe("catch-log aircraft name", () => {
  it("is make + model, falling back to the typecode then a neutral label", () => {
    expect(aircraftName("Boeing", "737-800", "B738")).toBe("Boeing 737-800");
    expect(aircraftName(null, "737-800", "B738")).toBe("737-800");
    expect(aircraftName(null, null, "B738")).toBe("B738");
    expect(aircraftName(null, null, null)).toBe("Unknown aircraft");
  });
});
