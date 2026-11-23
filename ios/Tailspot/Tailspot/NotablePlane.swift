//
//  NotablePlane.swift
//  Tailspot
//
//  A "notable" airframe: one specific plane the server has flagged as worth
//  remarking on (a head-of-state transport, a team charter, a celebrity or
//  business jet, a historic or special-mission aircraft). The server is the
//  only source: the flag rides on `GET /v1/aircraft` as an optional
//  `notable` object (absent means "not notable").
//
//  Going forward only: a catch is notable when the feed said so at the
//  press. The upload then sends `notableClaim: true`, the server stores its
//  answer on the catch row, and the `POST /v1/catches` response and each
//  `GET /v1/catches` row carry that stored answer (`NotableVerdict`).
//  Nothing ever looks up an existing catch to flag it after the fact.
//
//  Not to be confused with `Rarity.isNotable` (SetsScreen.swift), which
//  means "rare or better" and is about the TYPE. This is about one airframe.
//
//  Product rule: before the catch the app shows only that a plane is notable
//  (a gold star on its label), never who it is. The name and category are
//  the reveal's surprise. Nothing here points a user at a notable plane
//  elsewhere in the sky.
//

import Foundation

nonisolated struct NotablePlane: Equatable, Hashable, Sendable {
    /// Machine category. An OPEN string: the server may add kinds, and an
    /// unknown one must render fine from `label`. Lowercased and trimmed.
    /// Today: government, celebrity, business, team, special, working.
    let kind: String
    /// User-facing category text from the server ("Team plane", "Head of
    /// state and government", "Business jet"). Never empty.
    let label: String
    /// Who or what it is ("Air Force One", "Golden State Warriors"), when
    /// the server knows. nil is normal.
    let name: String?

    /// Build from raw parts, as they arrive on the wire or sit on a `Catch`
    /// row. Returns nil when there is nothing to show (no kind and no
    /// label), so a half-empty object never renders as a blank plate.
    init?(kind: String?, label: String?, name: String?) {
        let k = Self.clean(kind)?.lowercased()
        let l = Self.clean(label)
        guard k != nil || l != nil else { return nil }
        self.kind = k ?? "other"
        // A label-less object still gets readable text from its kind.
        self.label = l ?? (k.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Notable")
        self.name = Self.clean(name)
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// The gold plate's headline: "NOTABLE · TEAM PLANE".
    /// The kind the Debug wrench switch stamps (`NotableDebug`). Declared
    /// in every build so a test flag left on a catch by a Debug build is
    /// inert in a Release build installed over it: never shown, never
    /// claimed, never counted toward a trophy.
    static let testKind = "test"
    var isDebugTest: Bool { kind == Self.testKind }

    var plateTitle: String { "NOTABLE · \(label.uppercased())" }

    /// One line for secondary text (Hangar row, card back): the name when
    /// there is one, else the category.
    var shortText: String { name ?? label }

    /// Spoken form: "Notable plane, Team plane, Golden State Warriors".
    var accessibilityText: String {
        var parts = ["Notable plane", label]
        if let name { parts.append(name) }
        return parts.joined(separator: ", ")
    }
}

/// The wire form of the optional `notable` object. Decoding NEVER throws:
/// this rides on the live aircraft feed and on the upload response, and a
/// malformed flag (wrong type, missing label) must cost only the flag, never
/// the whole poll or the upload acknowledgement.
nonisolated struct NotablePlaneWire: Decodable, Sendable {
    let value: NotablePlane?

    private enum CodingKeys: String, CodingKey { case kind, label, name }

    init(_ value: NotablePlane?) { self.value = value }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            value = nil
            return
        }
        let kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        let label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? nil
        let name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        value = NotablePlane(kind: kind, label: label, name: name)
    }
}

/// What the server stored about one CATCH's notable flag (`POST /v1/catches`
/// response, each `GET /v1/catches` row). A notable-aware server always
/// sends the key: an object when it paid the notable bonus, an explicit
/// JSON `null` when it did not. So the three states mean different things
/// to the upload response (`Catch.applyNotable`):
///
///   `.unknown`     key absent: the server predates the feature and has said
///                  nothing. Also a malformed object (it says nothing usable).
///                  Leave the row alone.
///   `.notNotable`  explicit null: the server did not pay the bonus. Clear
///                  the row's notable fields.
///   `.notable`     set or correct the row's notable fields.
///
/// The Hangar restore only reads `plane` (an object or nothing).
///
/// (`GET /v1/aircraft` is different: there the key is simply omitted for an
/// ordinary plane, so the feed keeps the two-state `NotablePlaneWire`.)
nonisolated enum NotableVerdict: Equatable, Sendable {
    case unknown
    case notNotable
    case notable(NotablePlane)

    /// The flag when the server sent one.
    var plane: NotablePlane? {
        if case .notable(let plane) = self { return plane }
        return nil
    }
}

nonisolated extension NotableVerdict: Decodable {
    /// Decoding the value itself (the key was present). Never throws.
    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), single.decodeNil() {
            self = .notNotable
            return
        }
        let wire = try? NotablePlaneWire(from: decoder)
        self = wire?.value.map(NotableVerdict.notable) ?? .unknown
    }
}

nonisolated extension KeyedDecodingContainer {
    /// Picked up by the synthesized `Decodable` of any struct with a
    /// `NotableVerdict` property, in place of the standard `decode`, which
    /// would throw on a missing key. This is what tells an absent key
    /// (`.unknown`) from an explicit null (`.notNotable`). Never throws.
    func decode(_ type: NotableVerdict.Type, forKey key: Key) throws -> NotableVerdict {
        guard contains(key) else { return .unknown }
        if (try? decodeNil(forKey: key)) == true { return .notNotable }
        guard let wire = try? decode(NotablePlaneWire.self, forKey: key),
              let plane = wire.value else { return .unknown }
        return .notable(plane)
    }
}

#if DEBUG
/// Wrench-panel test switch (Debug builds only; Release never compiles it).
/// When on, every plane the feed returns that is not already notable is
/// stamped with a clearly fake entry, so the star, the plate, the ledger
/// row, the Hangar row and Star Sighting can be seen without waiting for a
/// real one. Applied at the ONE place feed aircraft enter the app
/// (`ADSBManager`), so everything downstream runs its real code.
///
/// The server never confirms these (the airframes are not on its list), so
/// the leaderboard pays nothing. `Catch.applyNotable` keeps a test flag
/// through that "no", and turning the switch off clears every test flag.
nonisolated enum NotableDebug {
    static let forceKey = "tailspot.debug.notable.forceAll"
    /// Marks a fake entry. Never sent by the server.
    static let testKind = NotablePlane.testKind
    static let testPlane = NotablePlane(kind: testKind, label: "Team plane", name: "Wrench Test Team")

    static var isForced: Bool { UserDefaults.standard.bool(forKey: forceKey) }

    static func apply(to aircraft: [Aircraft], forced: Bool = isForced) -> [Aircraft] {
        guard forced else { return aircraft }
        return aircraft.map { plane in
            guard plane.notable == nil else { return plane }
            var copy = plane
            copy.notable = testPlane
            return copy
        }
    }

    /// What a new catch records: the test stamp only while the switch is
    /// on. The feed keeps stamped planes until its next poll, so a catch
    /// made just after switching off must not pick one up.
    static func catchFlag(_ plane: NotablePlane?) -> NotablePlane? {
        guard let plane, plane.isDebugTest, !isForced else { return plane }
        return nil
    }

    /// Remove the fake flag from every catch that carries it. Returns how
    /// many rows changed.
    @MainActor
    static func clearTestFlags(in catches: [Catch]) -> Int {
        var changed = 0
        for row in catches where row.notableKind == testKind {
            if row.setNotable(nil) { changed += 1 }
        }
        return changed
    }
}
#endif
