//
//  PathSegment.swift
//  Tailspot
//
//  The one check for server-supplied ids (challenge ids, catch UUIDs) before
//  they're spliced into an AUTHORIZED request path. `URL(string:relativeTo:)`
//  normalizes "." and "..", so an id like "../../devices/me" (tampered push
//  payload, bad server JSON) would re-aim the bearer token at a different
//  route on the same host. Real ids are UUIDs; letters, digits and "-" are
//  all an id may contain.
//

import Foundation

nonisolated enum PathSegment {
    private static let idAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")

    static func isSafeID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.unicodeScalars.allSatisfy(idAllowed.contains)
    }
}
