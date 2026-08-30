//
//  SetsCoverageTests.swift
//  TailspotTests
//
//  Pins FAMILY-SET COVERAGE against the maintained aircraft catalog: every
//  type in the coverage fixture must land in at least one family set. The
//  fixture contains public ICAO typecode and aircraft-taxonomy facts only.
//
//  Each row is (typecode, DOC 8643 manufacturer, DOC 8643 model) exactly as
//  the backend resolves them — i.e. what `Catch.typecode` / `.manufacturer` /
//  `.model` carry after backfill. If a future set reshuffle orphans one of
//  these, this fails with the specific type that lost its home.
//
//  When an audit identifies another public typecode that needs coverage, add
//  it here without including any catch-level or user-activity data.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Sets coverage")
struct SetsCoverageTests {

    /// (typecode, manufacturer, model) — public coverage catalog.
    private static let coverageCatalog: [(String, String, String)] = [
        ("B738", "Boeing", "737-800"), ("E75L", "Embraer", "175"),
        ("CRJ9", "Bombardier", "CRJ-900"), ("A321", "Airbus", "A321"),
        ("A320", "Airbus", "A320"), ("B739", "Boeing", "737-900"),
        ("A21N", "Airbus", "A321neo"), ("BCS3", "Airbus", "A220-300"),
        ("B737", "Boeing", "737-700"), ("C172", "Cessna", "172"),
        ("B77W", "Boeing", "777-300ER"), ("E170", "Embraer", "170"),
        ("B763", "Boeing", "767-300"), ("B407", "Bell", "407"),
        ("A319", "Airbus", "A319"), ("B789", "Boeing", "787-9 Dreamliner"),
        ("PC12", "Pilatus", "PC-12"), ("P28A", "Piper", "PA-28 Cherokee"),
        ("A333", "Airbus", "A330-300"), ("A20N", "Airbus", "A320neo"),
        ("B38M", "Boeing", "737 MAX 8"), ("B772", "Boeing", "777-200"),
        ("B06", "Bell", "406"), ("B752", "Boeing", "757-200"),
        ("C208", "Cessna", "208 Caravan"), ("E55P", "Embraer", "EMB-505 Phenom 300"),
        ("CRJ7", "Bombardier", "CRJ-700"), ("S76", "Sikorsky", "S-76"),
        ("A359", "Airbus", "A350-900"), ("CL30", "Bombardier", "BD-100 Challenger 300"),
        ("B744", "Boeing", "747-400"), ("B764", "Boeing", "767-400"),
        ("B77L", "Boeing", "777-200LR"), ("B788", "Boeing", "787-8 Dreamliner"),
        ("E145", "Embraer", "ERJ-145"), ("C68A", "Cessna", "680A Citation Latitude"),
        ("C56X", "Cessna", "560XL Citation XLS"), ("CL60", "Bombardier", "Challenger 604"),
        ("C182", "Cessna", "182 Skylane"), ("A388", "Airbus", "A380-800"),
        ("SR22", "Cirrus", "SR-22"), ("DH8D", "Bombardier", "DHC-8-400 Dash 8"),
        ("C402", "Cessna", "402"), ("A339", "Airbus", "A330-900"),
        ("GLEX", "Bombardier", "BD-700 Global Express"), ("C700", "Cessna", "700 Citation Longitude"),
        ("A332", "Airbus", "A330-200"), ("A35K", "Airbus", "A350-1000"),
        ("AS50", "Airbus Helicopters", "H-125 Fennec"), ("GLF4", "Gulfstream", "IV"),
        ("SR20", "Cirrus", "SR20"), ("E190", "Embraer", "190"),
        ("BCS1", "Airbus", "A220-100"), ("H25B", "Hawker", "800XP"),
        ("E545", "Embraer", "EMB-545 Legacy 450"), ("B753", "Boeing", "757-300"),
        ("GLF6", "Gulfstream", "G650"), ("S22T", "Cirrus", "SR-22T"),
        ("GLF5", "Gulfstream", "G550"), ("A139", "AgustaWestland", "AW-139"),
        ("R44", "Robinson", "R44"), ("B78X", "Boeing", "787-10 Dreamliner"),
        ("AT76", "ATR", "ATR-72-600"), ("B748", "Boeing", "747-8"),
        ("E75S", "Embraer", "175"), ("BE20", "Beechcraft", "200 Super King Air"),
        ("E295", "Embraer", "E195-E2"), ("B350", "Beechcraft", "350 Super King Air"),
        ("TBM7", "Socata", "TBM-700A"), ("B712", "Boeing", "717-200"),
        ("DA40", "Diamond", "DA-40 Katana"), ("C750", "Cessna", "750 Citation 10"),
        ("C150", "Cessna", "150"), ("AA5", "Grumman American", "AA-5 Tiger"),
        ("P28R", "Piper", "PA-28R-201 Arrow"), ("B429", "Bell", "429 GlobalRanger"),
        ("F2TH", "Dassault", "Falcon 2000"), ("C17", "Boeing", "C-17 Globemaster 3"),
        ("A109", "Agusta", "A-109"), ("PA18", "Piper", "PA-18 Super Cub"),
        ("CRJ2", "Bombardier", "CRJ-200"), ("EC45", "Airbus Helicopters-Kawasaki", "H-145"),
        ("C25C", "Cessna", "525C Citation CJ4"), ("LJ60", "Learjet", "60"),
        ("EC35", "Airbus Helicopters", "H-135"), ("C25B", "Cessna", "525B Citation CJ3"),
        ("BE36", "Beechcraft", "36 Bonanza 36"), ("C560", "Cessna", "560 Citation V"),
        ("SF50", "Cirrus", "SF50 Vision Jet"), ("PA46", "Piper", "PA-46-350P M350"),
        ("P32R", "Piper", "PA-32R-300 Lance"), ("A346", "Airbus", "A340-600"),
        ("LJ35", "Learjet", "35"), ("BE58", "Beechcraft", "58 Baron"),
        ("AS65", "Aerospatiale", "HH-65 Dolphin"), ("RV12", "Van's", "RV-12"),
        ("E135", "Embraer", "ERJ-135"), ("B734", "Boeing", "737-400"),
        ("PC24", "Pilatus", "PC-24"), ("B773", "Boeing", "777-300"),
        ("C206", "Cessna", "206 Stationair"), ("RV8", "Van's", "RV-8"),
        ("K100", "Daher", "Kodiak 100"), ("G280", "Gulfstream", "G280"),
        ("P212", "Tecnam", "P-2012 Traveller"), ("C310", "Cessna", "310"),
        ("C152", "Cessna", "152"), ("H160", "Airbus Helicopters", "H-160"),
        ("C25A", "Cessna", "525A Citation CJ2"), ("EC30", "Airbus Helicopters", "H-130"),
        ("GL7T", "Bombardier", "BD-700 Global 7000"), ("BN2P", "Britten-Norman", "BN-2 Islander"),
        ("ST75", "Boeing", "75 Kaydet"), ("DHC2", "De Havilland Canada", "DHC-2 Beaver"),
        ("PA25", "Piper", "PA-25 Pawnee"), ("BE30", "Beechcraft", "300 Super King Air"),
        ("B736", "Boeing", "737-600"), ("B39M", "Boeing", "737 MAX 9"),
        ("C07T", "Cessna", "207"), ("C5M", "Lockheed", "C-5 Super Galaxy"),
        ("BE76", "Beechcraft", "76 Duchess"), ("PA23", "Piper", "PA-23-150 Apache"),
        ("AT75", "ATR", "ATR-72-500"), ("HDJT", "Honda", "HA-420 HondaJet"),
        ("C551", "Cessna", "551 Citation 2SP"), ("CL35", "Bombardier", "BD-100 Challenger 350"),
        ("C77R", "Cessna", "177RG Cardinal"), ("E550", "Embraer", "EMB-550 Legacy 500"),
        ("AT45", "ATR", "ATR-42-500"), ("L410", "Let", "L-410 Turbolet"),
        ("B735", "Boeing", "737-500"), ("BE33", "Beechcraft", "33 Bonanza"),
        ("P28B", "Piper", "PA-28-236 Dakota"), ("PA32", "Piper", "PA-32 6X"),
        ("M20T", "Mooney", "M-20K 231"), ("H60", "Sikorsky", "S-70"),
        ("ASTO", "Tecnam", "Astore"), ("GA6C", "Gulfstream", "G600"),
        ("BE10", "Beechcraft", "100 King Air"), ("GALX", "Gulfstream", "G200"),
        ("H47", "Boeing Vertol", "114"), ("C185", "Cessna", "185 Skywagon"),
        ("PA34", "Piper", "PA-34 Seneca"), ("E195", "Embraer", "195"),
        ("F900", "Dassault", "Falcon 900"), ("DH8C", "De Havilland Canada", "DHC-8-300 Dash 8"),
        ("C550", "Cessna", "550 Citation II"), ("C680", "Cessna", "680 Citation Sovereign"),
        ("BE99", "Beechcraft", "99 Airliner"), ("GA7C", "Gulfstream", "G700"),
        ("BE95", "Beechcraft", "95 Travel Air"), ("BE24", "Beechcraft", "24 Sierra"),
        ("SF34", "Saab", "340"), ("MD11", "Boeing", "MD-11"),
        ("A5", "Icon", "A-5"),
        // Newly observed since the 2026-08-24 snapshot. Five required new
        // slots (A306/C210/EPIC/H500/SB91); the rest exercise existing broad
        // family tokens or exact typecode entries.
        ("A306", "Airbus", "A300B4-600"),
        ("A343", "Airbus", "A340-300"),
        ("B762", "Boeing", "767-200"),
        ("BE35", "Beechcraft", "35 Bonanza"),
        ("C170", "Cessna", "170"),
        ("C210", "Cessna", "210"),
        ("C30J", "Lockheed Martin", "C-130J Super Hercules"),
        ("EPIC", "Epic Aircraft", "Epic LT / E1000"),
        ("FA7X", "Dassault", "Falcon 7X"),
        ("H500", "MD Helicopters", "MD 500 / 530"),
        ("SB91", "Saab", "91 Safir"),
        ("T206", "Cessna", "T206 Stationair TC"),
        // Public catalog coverage additions validated 2026-08-30. Eight
        // require exact family slots; the rest exercise existing rules.
        ("BE23", "Beechcraft", "23 Musketeer"),
        ("BE9L", "Beechcraft", "90 King Air"),
        ("BN2T", "Britten-Norman", "BN-2T Defender 4000"),
        ("C177", "Cessna", "177"),
        ("C525", "Cessna", "525 CitationJet"),
        ("CLON", "Autogyro", "Cavalon"),
        ("DA42", "Diamond", "DA-42 Guardian"),
        ("DC3T", "Professional Aviation", "Jet Prop DC-3"),
        ("FA50", "Dassault", "Falcon 50"),
        ("G2CA", "Guimbal", "G-2 Cabri"),
        ("GL5T", "Bombardier", "BD-700 Global 5000"),
        ("M20P", "Mooney", "M20"),
        ("NG5", "Brm Aero", "Bristell HD"),
        ("P210", "Cessna", "P210 Centurion"),
        ("P28S", "Piper", "PA-28R-201T Turbo Arrow"),
        ("PA12", "Piper", "PA-12 Super Cruiser"),
        ("PAY2", "Piper", "PA-31T-620 Cheyenne"),
        ("RV9", "Van's", "RV-9"),
        ("T34P", "Beechcraft", "45 Mentor"),
    ]

    private func mk(_ row: (String, String, String)) -> Catch {
        Catch(icao24: "cov\(row.0.lowercased())",
              callsign: nil, model: row.2, manufacturer: row.1,
              caughtAt: Date(), observerLat: 0, observerLon: 0,
              slantDistanceMeters: 0, typecode: row.0)
    }

    /// The load-bearing assertion: every audited public typecode has a family.
    @Test func everyCoverageTypeFillsAtLeastOneFamilySlot() {
        for row in Self.coverageCatalog {
            let c = mk(row)
            let key = CardSets.matchKey(for: c)
            let slotted = CardSets.families.contains { set in
                set.entries.contains { CardSets.matches(key: key, entry: $0) }
            }
            #expect(slotted,
                    "\(row.0) (\(row.1) \(row.2)) matches NO family set")
        }
    }

    @Test func newlyCoveredTypesFillTheirIntendedFamilySlots() {
        let assignments: [((String, String, String), String, String)] = [
            (("CLON", "Autogyro", "Cavalon"), "fam-sport-classics", "fsc-cavalon"),
            (("FA50", "Dassault", "Falcon 50"), "fam-falcon", "ffa50"),
            (("G2CA", "Guimbal", "G-2 Cabri"), "fam-heli", "fh-g2ca"),
            (("GL5T", "Bombardier", "BD-700 Global 5000"), "fam-bombardier-biz", "fgl5t"),
            (("NG5", "Brm Aero", "Bristell HD"), "fam-sport-classics", "fsc-bristell"),
            (("PA12", "Piper", "PA-12 Super Cruiser"), "fam-piper", "fpa12"),
            (("PAY2", "Piper", "PA-31T-620 Cheyenne"), "fam-piper", "fpay2"),
            (("T34P", "Beechcraft", "45 Mentor"), "fam-beech", "fbt34"),
        ]

        for (row, setID, entryID) in assignments {
            let key = CardSets.matchKey(for: mk(row))
            let set = CardSets.families.first { $0.id == setID }!
            let entry = set.entries.first { $0.id == entryID }!
            #expect(CardSets.matches(key: key, entry: entry),
                    "\(row.0) must fill \(setID)/\(entryID)")
        }
    }

    /// Guard the known bleed traps the token audit found: substring tokens
    /// must not let a look-alike fill the wrong slot.
    @Test func lookAlikeTokensDoNotBleed() {
        // An Airbus A310 must not fill the Cessna 310 slot.
        let a310 = mk(("A310", "Airbus", "A310"))
        let a310Key = CardSets.matchKey(for: a310)
        let cessnaSet = CardSets.families.first { $0.id == "fam-cessna" }!
        let c310Entry = cessnaSet.entries.first { $0.id == "fc310" }!
        #expect(!CardSets.matches(key: a310Key, entry: c310Entry),
                "An Airbus A310 must not fill the Cessna 310 slot")

        // A Lockheed C-130 (EC-130 variants included) must not fill the
        // Airbus H130 helicopter slot.
        let herc = mk(("C130", "Lockheed", "EC-130 Aya"))
        let hercKey = CardSets.matchKey(for: herc)
        let heliSet = CardSets.families.first { $0.id == "fam-heli" }!
        let h130Entry = heliSet.entries.first { $0.id == "fh-h130" }!
        #expect(!CardSets.matches(key: hercKey, entry: h130Entry),
                "A C-130 Hercules must not fill the H130 helicopter slot")

        // A P-51 (canonical "A-36 Mustang") must not fill Citation Mustang,
        // and a Citation Mustang must not fill the P-51 warbird slot.
        let p51 = mk(("P51", "North American", "A-36 Mustang"))
        let p51Key = CardSets.matchKey(for: p51)
        let citationSet = CardSets.families.first { $0.id == "fam-citation" }!
        let citMustang = citationSet.entries.first { $0.id == "fc-mustang" }!
        #expect(!CardSets.matches(key: p51Key, entry: citMustang),
                "A P-51 must not fill the Citation Mustang slot")
        let c510 = mk(("C510", "Cessna", "510 Citation Mustang"))
        let c510Key = CardSets.matchKey(for: c510)
        let vintageSet = CardSets.families.first { $0.id == "fam-vintage" }!
        let p51Entry = vintageSet.entries.first { $0.id == "fv-p51" }!
        #expect(!CardSets.matches(key: c510Key, entry: p51Entry),
                "A Citation Mustang must not fill the P-51 slot")

        // Exact Cessna tokens keep the C170 piston single and Embraer E170
        // regional jet in their own families despite their shared model number.
        let c170 = mk(("C170", "Cessna", "170"))
        let c170Key = CardSets.matchKey(for: c170)
        let c170Entry = cessnaSet.entries.first { $0.id == "fc170" }!
        let eJetSet = CardSets.families.first { $0.id == "fam-ejet" }!
        let e170Entry = eJetSet.entries.first { $0.id == "fe170" }!
        #expect(CardSets.matches(key: c170Key, entry: c170Entry))
        #expect(!CardSets.matches(key: c170Key, entry: e170Entry))

        // A Cessna 406 Caravan II must not fill the Bell 206 slot (DOC 8643
        // names the Bell 206 series "406" — the slot is typecode-driven).
        let c406 = mk(("F406", "Cessna", "406 Caravan 2"))
        let c406Key = CardSets.matchKey(for: c406)
        let b206Entry = heliSet.entries.first { $0.id == "fh-b206" }!
        #expect(!CardSets.matches(key: c406Key, entry: b206Entry),
                "A Cessna 406 must not fill the Bell 206 slot")
    }

    /// The healed FlyNYON tour helicopter (a4b0e2 / N401FN → B06) — the
    /// airframe four different users caught as "Unknown" pre-heal — must
    /// resolve into the Bell 206 slot via its typecode.
    @Test func healedBell206LandsInHeliSet() {
        let c = mk(("B06", "Bell", "406"))
        let key = CardSets.matchKey(for: c)
        let heliSet = CardSets.families.first { $0.id == "fam-heli" }!
        let b206 = heliSet.entries.first { $0.id == "fh-b206" }!
        #expect(CardSets.matches(key: key, entry: b206))
        // ...and never the Bell 407 slot next door.
        let b407 = heliSet.entries.first { $0.id == "fh-b407" }!
        #expect(!CardSets.matches(key: key, entry: b407))
    }
}
