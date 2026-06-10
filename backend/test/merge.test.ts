import { describe, expect, it } from "vitest";
import { mergeMetadata } from "../src/metadata/merge.js";

/**
 * Pure merge-semantics tests — no database. Exercises every branch of the
 * frozen contract: both sources, FAA-only, DOC 8643-only, and neither.
 */
describe("mergeMetadata", () => {
  it("merges both sources, with DOC 8643 names winning over raw FAA strings", () => {
    const r = mergeMetadata(
      {
        registration: "N12345",
        manufacturerRaw: "BOEING",
        modelRaw: "737-800",
        typecode: "B738",
      },
      { typecode: "B738", manufacturer: "Boeing", model: "737-800" },
    );
    expect(r).toEqual({
      registration: "N12345",
      manufacturer: "Boeing", // DOC 8643, not the raw "BOEING"
      model: "737-800",
      typecode: "B738",
      operatorName: null,
      source: "merged",
    });
  });

  it("prefers DOC 8643's clean name even when FAA's raw string differs in case/format", () => {
    const r = mergeMetadata(
      {
        registration: "N67890",
        manufacturerRaw: "CIRRUS DESIGN CORP",
        modelRaw: "SR22",
        typecode: "SR22",
      },
      { typecode: "SR22", manufacturer: "Cirrus", model: "SR-22" },
    );
    expect(r?.source).toBe("merged");
    expect(r?.manufacturer).toBe("Cirrus");
    expect(r?.model).toBe("SR-22");
    // Registration always comes from the FAA row.
    expect(r?.registration).toBe("N67890");
  });

  it("returns source=faa with raw names when the typecode is unknown to DOC 8643", () => {
    const r = mergeMetadata(
      {
        registration: "N00001",
        manufacturerRaw: "PIPER",
        modelRaw: "PA-28-181",
        typecode: "PA28", // present on the FAA row, but no DOC 8643 row passed
      },
      null,
    );
    expect(r).toEqual({
      registration: "N00001",
      manufacturer: "PIPER",
      model: "PA-28-181",
      typecode: "PA28",
      operatorName: null,
      source: "faa",
    });
  });

  it("returns source=faa with a null typecode for a registration-only FAA row", () => {
    const r = mergeMetadata(
      {
        registration: "N99999",
        manufacturerRaw: null,
        modelRaw: null,
        typecode: null,
      },
      null,
    );
    expect(r?.source).toBe("faa");
    expect(r?.registration).toBe("N99999");
    expect(r?.typecode).toBeNull();
    expect(r?.manufacturer).toBeNull();
  });

  it("returns source=doc8643 when only the typecode table knows the airframe", () => {
    const r = mergeMetadata(null, {
      typecode: "A388",
      manufacturer: "Airbus",
      model: "A-380",
    });
    expect(r).toEqual({
      registration: null,
      manufacturer: "Airbus",
      model: "A-380",
      typecode: "A388",
      operatorName: null,
      source: "doc8643",
    });
  });

  it("returns null when neither source knows the airframe", () => {
    expect(mergeMetadata(null, null)).toBeNull();
  });

  it("always leaves operatorName null (community lookup is a later seam)", () => {
    const merged = mergeMetadata(
      { registration: "N1", manufacturerRaw: "BOEING", modelRaw: "747", typecode: "B744" },
      { typecode: "B744", manufacturer: "Boeing", model: "747-400" },
    );
    expect(merged?.operatorName).toBeNull();
  });
});
