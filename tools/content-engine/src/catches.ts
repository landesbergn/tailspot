/**
 * Noah's own real catches — the ONLY photos this engine may use.
 *
 * Copied by hand from marketing/catch-photos/README.md (the recorded ADS-B
 * for each shot). Only fields the README states are filled in; nothing is
 * inferred. Excluded on purpose:
 *   - c560_uncommon (N561SR): a privately operated jet flying under its tail
 *     number — privacy rule 2 (src/privacy.ts) applies to Noah's photos too.
 *   - a320, b777_with_route, 175, bd100_uncommon: the plane is a speck at
 *     slide scale; the README says not to lead with them.
 */

export interface CatchRecord {
  id: string;
  file: string;
  callsign: string;
  typecode: string;
  operator: string;
  route?: [string, string];
  altitudeFt?: number;
  speedKt?: number;
  distanceKm?: number;
  /** Is it the plane itself, or only its contrail, that shows? */
  visible: "plane" | "contrail";
}

export const CATCHES: readonly CatchRecord[] = [
  { id: "b737", file: "b737.jpg", callsign: "SWA1598", typecode: "B738", operator: "Southwest", distanceKm: 2.1, visible: "plane" },
  { id: "b767", file: "b767_with_route.jpg", callsign: "DAL405", typecode: "B763", operator: "Delta", route: ["SFO", "JFK"], visible: "plane" },
  { id: "a321", file: "a321_with_route_first.jpg", callsign: "JBU1770", typecode: "A21N", operator: "JetBlue", route: ["GYE", "JFK"], visible: "plane" },
  { id: "a220", file: "a220_with_route_uncommon.jpg", callsign: "ACA568", typecode: "BCS3", operator: "Air Canada", route: ["YVR", "SFO"], visible: "plane" },
  {
    id: "bd700",
    file: "bd700_rare.jpg",
    callsign: "WWI21",
    typecode: "GLEX",
    operator: "Worldwide Jet Charter",
    altitudeFt: 43225,
    speedKt: 546,
    distanceKm: 27.1,
    visible: "contrail",
  },
];

export function catchById(id: unknown): CatchRecord {
  const c = CATCHES.find((x) => x.id === id);
  if (!c) throw new Error(`unknown catch "${id}" (have: ${CATCHES.map((x) => x.id).join(", ")})`);
  return c;
}
