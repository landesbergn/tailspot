//
//  WikipediaSummaryClient.swift
//  Tailspot
//
//  Article-summary lookup against Wikipedia's public REST API
//  (`/api/rest_v1/page/summary/{title}`), used by the back of the catch
//  card ("about this plane"). Unauthenticated; Wikimedia asks only for an
//  identifying User-Agent with a contact URL.
//
//  Structure mirrors PlanespottersClient.swift on purpose:
//  - a pure static `parse(_:)` the tests hit with fixture JSON,
//  - an injectable URLSession + baseURL,
//  - an in-process actor cache (per session, never persisted, capped).
//
//  Content rules baked in:
//  - The extract is shown UNEDITED, just cut to its first two sentences
//    (`firstSentences(_:count:)`). The UI credits "From Wikipedia ·
//    CC BY-SA 4.0" and links the article (`pageURL`).
//  - Disambiguation pages ("Boeing 717 may refer to…") are skipped — their
//    extract isn't about the plane.
//  - Only https page URLs are accepted: the link is opened on tap, and
//    third-party JSON must not be able to hand us another scheme.
//

import Foundation
import os

// Private logger — nonisolated so it's callable from the nonisolated client.
// Mirrors the subsystem/category convention in Log.swift.
private nonisolated let wikipediaLog = Logger(
    subsystem: "com.landesberg.tailspot",
    category: "wikipedia"
)

// MARK: - Domain value type

/// The first couple of sentences of a Wikipedia article + where to read more.
nonisolated struct WikipediaSummary: Equatable, Sendable {
    /// First 2 sentences of the REST extract, unedited text.
    let extract: String
    /// The article page (`content_urls.mobile.page`, https). Opened from the
    /// "Read more on Wikipedia" link.
    let pageURL: URL
}

// MARK: - Client

nonisolated struct WikipediaSummaryClient: Sendable {
    private let session: URLSession
    private let baseURL: URL
    private let cache: WikipediaSummaryCache
    private let userAgent: String

    /// Wikimedia's User-Agent policy asks API clients to identify the app
    /// and give a contact URL — same string Planespotters gets.
    static let defaultUserAgent = "Tailspot/1.0 (+https://tailspot.app)"

    init(session: URLSession = .shared,
         baseURL: URL = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/")!,
         cache: WikipediaSummaryCache = WikipediaSummaryCache(),
         userAgent: String = WikipediaSummaryClient.defaultUserAgent) {
        self.session = session
        self.baseURL = baseURL
        self.cache = cache
        self.userAgent = userAgent
    }

    /// Fetches the summary for an English Wikipedia article title, or nil on
    /// any failure (no article, disambiguation page, network error, bad
    /// payload). Never throws. Successful answers — including "no usable
    /// summary" — are cached for the rest of the session; transport errors
    /// and non-2xx/404 responses are not, so a later turn-over retries.
    func summary(forTitle title: String) async -> WikipediaSummary? {
        let key = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if case .hit(let cached) = await cache.get(key: key) {
            return cached
        }
        guard let url = Self.url(forTitle: key, baseURL: baseURL) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status == 404 {
                // No such article — a stable answer, safe to remember.
                await cache.set(key: key, value: nil)
                return nil
            }
            guard (200..<300).contains(status) else {
                wikipediaLog.notice("Wikipedia HTTP \(status) for \(key, privacy: .public)")
                return nil
            }
            let summary = Self.parse(data)
            await cache.set(key: key, value: summary)
            return summary
        } catch {
            wikipediaLog.error("Wikipedia fetch failed for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

nonisolated extension WikipediaSummaryClient {
    /// Shared singleton so the detail screen and the reveal share one cache.
    static let shared = WikipediaSummaryClient()

    /// Builds the request URL for a title. Wikipedia titles use underscores
    /// for spaces; everything outside the unreserved path characters is
    /// percent-encoded — including "/" (so "AC/DC" stays one path segment),
    /// "?" / "#", and ":" (harmless to Wikipedia, and keeps the string from
    /// ever reading as a scheme). Returns nil for a non-https base.
    static func url(forTitle title: String, baseURL: URL) -> URL? {
        guard baseURL.scheme?.lowercased() == "https" else { return nil }
        let underscored = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
        guard !underscored.isEmpty else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/:?#;%")
        guard let escaped = underscored.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        var base = baseURL.absoluteString
        if !base.hasSuffix("/") { base += "/" }
        return URL(string: base + escaped)
    }

    /// Wire JSON → app value. nil when the page is a disambiguation page, the
    /// extract is empty, or no https page URL is present. Pure — the tests
    /// drive it with fixture payloads.
    static func parse(_ data: Data) -> WikipediaSummary? {
        guard let wire = try? JSONDecoder().decode(WikipediaSummaryResponse.self, from: data) else {
            return nil
        }
        if wire.type?.lowercased() == "disambiguation" { return nil }
        let extract = firstSentences(wire.extract ?? "", count: 2)
        guard !extract.isEmpty else { return nil }
        // Mobile page first (the spec's pick — it reads better on a phone),
        // desktop as a fallback. Either must be https.
        let candidates = [wire.content_urls?.mobile?.page, wire.content_urls?.desktop?.page]
        guard let pageURL = candidates
            .compactMap({ $0.flatMap(URL.init(string:)) })
            .first(where: { $0.scheme?.lowercased() == "https" && $0.host != nil })
        else { return nil }
        return WikipediaSummary(extract: extract, pageURL: pageURL)
    }

    /// Lowercased abbreviations whose trailing period never ends a sentence.
    /// Dotted forms with an INTERNAL period ("U.S.", "e.g.") and single-letter
    /// initials ("J.") are caught by rule, not by this list.
    static let abbreviations: Set<String> = [
        "mr.", "mrs.", "ms.", "dr.", "st.", "jr.", "sr.", "inc.", "co.", "corp.",
        "ltd.", "vs.", "etc.", "approx.", "no.", "nos.", "mt.", "ft.", "lt.",
        "col.", "gen.", "capt.", "sgt.", "c.", "ca.", "fig.", "vol.",
    ]

    /// The first `count` sentences of `text`, trimmed, otherwise unedited.
    /// Deliberately simple: a sentence ends at ". ", "! " or "? " (optionally
    /// after a closing quote/bracket) or at the end of the text — except when
    /// the word before a period is an abbreviation (`U.S.`, `e.g.`, `Inc.`,
    /// an initial like `J.`). Decimals ("3.5 m") never qualify because the
    /// period isn't followed by whitespace. A missed boundary just means a
    /// slightly longer extract, which the card truncates anyway.
    static func firstSentences(_ text: String, count: Int) -> String {
        let chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard count > 0, !chars.isEmpty else { return "" }
        let closers: Set<Character> = [")", "]", "\"", "'", "\u{201D}", "\u{2019}"]
        var found = 0
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            guard ch == "." || ch == "!" || ch == "?" else { i += 1; continue }
            // Swallow closing quotes/brackets right after the terminator.
            var end = i
            while end + 1 < chars.count, closers.contains(chars[end + 1]) { end += 1 }
            let atEnd = end + 1 >= chars.count
            let followedBySpace = !atEnd && chars[end + 1].isWhitespace
            guard atEnd || followedBySpace else { i = end + 1; continue }
            if ch == "." && isAbbreviation(chars, periodAt: i) { i = end + 1; continue }
            if !atEnd {
                // The next sentence should start with something other than a
                // lowercase letter ("… 3 ft. long" style false stops).
                var j = end + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j].isLowercase { i = end + 1; continue }
            }
            found += 1
            if found == count {
                return String(chars[0...end]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            i = end + 1
        }
        return String(chars)
    }

    /// True when the period at `periodAt` closes an abbreviation rather than
    /// a sentence.
    private static func isAbbreviation(_ chars: [Character], periodAt index: Int) -> Bool {
        var start = index
        while start > 0, !chars[start - 1].isWhitespace { start -= 1 }
        var token = String(chars[start...index])
        while let first = token.first, "([\"'\u{201C}\u{2018}".contains(first) { token.removeFirst() }
        let body = token.dropLast()   // without the final period
        if body.isEmpty { return false }
        if body.contains(".") { return true }                         // U.S. / e.g. / i.e.
        if body.count == 1, body.first?.isUppercase == true { return true } // initial: "J." (not a unit like "m.")
        return abbreviations.contains(token.lowercased())
    }
}

// MARK: - Wire format

/// The subset of the REST summary payload we read. Everything optional:
/// a missing field degrades to "no summary", never a decode crash.
nonisolated struct WikipediaSummaryResponse: Decodable, Sendable {
    let type: String?
    let title: String?
    let extract: String?
    // swiftlint:disable:next identifier_name
    let content_urls: ContentURLs?

    nonisolated struct ContentURLs: Decodable, Sendable {
        let desktop: Page?
        let mobile: Page?
    }

    nonisolated struct Page: Decodable, Sendable {
        let page: String?
    }
}

// MARK: - In-session cache

/// Per-session memoization keyed on the trimmed title. Bounded; never
/// persisted past app termination.
actor WikipediaSummaryCache {
    /// Distinguishes "not asked yet" from "asked, no usable summary".
    enum Lookup: Sendable {
        case notFetched
        case hit(value: WikipediaSummary?)
    }

    private var store: [String: WikipediaSummary?] = [:]
    private let capacity: Int

    init(capacity: Int = 200) {
        self.capacity = capacity
    }

    func get(key: String) -> Lookup {
        guard store.keys.contains(key) else { return .notFetched }
        return .hit(value: store[key] ?? nil)
    }

    func set(key: String, value: WikipediaSummary?) {
        if store[key] == nil, store.count >= capacity {
            // Cheap eviction, same trade-off as PlanespottersCache.
            if let drop = store.keys.first { store.removeValue(forKey: drop) }
        }
        store[key] = value
    }
}
