//
//  WikipediaSummaryClientTests.swift
//  TailspotTests
//
//  Parsing, title escaping, sentence trimming and the cache for the
//  Wikipedia REST summary client. No network: `parse(_:)` and
//  `url(forTitle:baseURL:)` are pure, and fixtures stand in for payloads.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Wikipedia summary client")
struct WikipediaSummaryClientTests {

    private let base = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/")!

    private func payload(type: String = "standard",
                         extract: String,
                         mobile: String? = "https://en.m.wikipedia.org/wiki/Boeing_737",
                         desktop: String? = "https://en.wikipedia.org/wiki/Boeing_737") -> Data {
        var urls: [String: Any] = [:]
        if let mobile { urls["mobile"] = ["page": mobile] }
        if let desktop { urls["desktop"] = ["page": desktop] }
        let obj: [String: Any] = [
            "type": type,
            "title": "Boeing 737",
            "extract": extract,
            "content_urls": urls,
        ]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    // MARK: parse

    @Test func parsesStandardPageAndKeepsFirstTwoSentences() {
        let data = payload(extract: "The Boeing 737 is an American narrow-body aircraft. It was developed in the 1960s. It is the most-produced jetliner.")
        let s = WikipediaSummaryClient.parse(data)
        #expect(s?.extract == "The Boeing 737 is an American narrow-body aircraft. It was developed in the 1960s.")
        // The sheet gets the whole intro, unedited.
        #expect(s?.intro == "The Boeing 737 is an American narrow-body aircraft. It was developed in the 1960s. It is the most-produced jetliner.")
        #expect(s?.pageURL.absoluteString == "https://en.m.wikipedia.org/wiki/Boeing_737")
    }

    @Test func parsesRealShapedPayload() {
        let json = """
        {
          "type": "standard",
          "title": "Cessna 172",
          "displaytitle": "<span class=\\"mw-page-title-main\\">Cessna 172</span>",
          "extract": "The Cessna 172 Skyhawk is an American four-seat, single-engine, high wing, fixed-wing aircraft made by the Cessna Aircraft Company. First flown in 1955, more 172s have been built than any other aircraft. It is a development of the 170.",
          "content_urls": {
            "desktop": {"page": "https://en.wikipedia.org/wiki/Cessna_172"},
            "mobile": {"page": "https://en.m.wikipedia.org/wiki/Cessna_172"}
          }
        }
        """.data(using: .utf8)!
        let s = WikipediaSummaryClient.parse(json)
        #expect(s?.extract == "The Cessna 172 Skyhawk is an American four-seat, single-engine, high wing, fixed-wing aircraft made by the Cessna Aircraft Company. First flown in 1955, more 172s have been built than any other aircraft.")
        #expect(s?.pageURL.host == "en.m.wikipedia.org")
    }

    @Test func skipsDisambiguationPages() {
        let data = payload(type: "disambiguation",
                           extract: "Boeing 717 may refer to: Boeing 717, a jet airliner. KC-135, a tanker.")
        #expect(WikipediaSummaryClient.parse(data) == nil)
    }

    @Test func rejectsNonHTTPSPageURLs() {
        for bad in ["http://en.m.wikipedia.org/wiki/Boeing_737", "tel:+15555550100", "otherapp://x", ""] {
            let data = payload(extract: "A plane. Another sentence.", mobile: bad, desktop: bad)
            #expect(WikipediaSummaryClient.parse(data) == nil, "accepted \(bad)")
        }
    }

    @Test func fallsBackToDesktopWhenMobileIsMissingOrInsecure() {
        let missing = payload(extract: "A plane.", mobile: nil)
        #expect(WikipediaSummaryClient.parse(missing)?.pageURL.absoluteString == "https://en.wikipedia.org/wiki/Boeing_737")
        let insecure = payload(extract: "A plane.", mobile: "http://en.m.wikipedia.org/wiki/Boeing_737")
        #expect(WikipediaSummaryClient.parse(insecure)?.pageURL.absoluteString == "https://en.wikipedia.org/wiki/Boeing_737")
    }

    @Test func emptyExtractOrGarbageIsNil() {
        #expect(WikipediaSummaryClient.parse(payload(extract: "   ")) == nil)
        #expect(WikipediaSummaryClient.parse(Data("not json".utf8)) == nil)
        #expect(WikipediaSummaryClient.parse(Data("{}".utf8)) == nil)
    }

    // MARK: firstSentences

    @Test func abbreviationsDoNotEndASentence() {
        let text = "The C-130 is a U.S. military transport built by Lockheed Corp. and others. It flew in 1954. It is still built."
        #expect(WikipediaSummaryClient.firstSentences(text, count: 2)
                == "The C-130 is a U.S. military transport built by Lockheed Corp. and others. It flew in 1954.")
    }

    @Test func eGAndInitialsAreNotBoundaries() {
        let text = "Designed by J. H. Smith, e.g. for trainers. It has a 10.9 m wingspan. Third."
        #expect(WikipediaSummaryClient.firstSentences(text, count: 2)
                == "Designed by J. H. Smith, e.g. for trainers. It has a 10.9 m wingspan.")
    }

    @Test func decimalsAreNotBoundaries() {
        let text = "Its wingspan is 35.8 m and length 39.5 m. It seats 189. More text."
        #expect(WikipediaSummaryClient.firstSentences(text, count: 2)
                == "Its wingspan is 35.8 m and length 39.5 m. It seats 189.")
    }

    @Test func closingQuotesAndOtherTerminators() {
        let text = "It was nicknamed the \"Queen of the Skies.\" Why? Because it was big! Fourth."
        #expect(WikipediaSummaryClient.firstSentences(text, count: 2)
                == "It was nicknamed the \"Queen of the Skies.\" Why?")
    }

    @Test func shortTextIsReturnedWhole() {
        #expect(WikipediaSummaryClient.firstSentences("  One sentence only.  ", count: 2) == "One sentence only.")
        #expect(WikipediaSummaryClient.firstSentences("No terminator at all", count: 2) == "No terminator at all")
        #expect(WikipediaSummaryClient.firstSentences("", count: 2) == "")
    }

    @Test func newlinesCountAsSentenceSpacing() {
        let text = "First sentence.\nSecond sentence.\nThird."
        #expect(WikipediaSummaryClient.firstSentences(text, count: 2) == "First sentence.\nSecond sentence.")
    }

    // MARK: URL building

    @Test func escapesTitlesIntoOnePathSegment() {
        #expect(WikipediaSummaryClient.url(forTitle: "Boeing 737", baseURL: base)?.absoluteString
                == "https://en.wikipedia.org/api/rest_v1/page/summary/Boeing_737")
        #expect(WikipediaSummaryClient.url(forTitle: "Airbus A320 family", baseURL: base)?.absoluteString
                == "https://en.wikipedia.org/api/rest_v1/page/summary/Airbus_A320_family")
        #expect(WikipediaSummaryClient.url(forTitle: "AC/DC", baseURL: base)?.absoluteString
                == "https://en.wikipedia.org/api/rest_v1/page/summary/AC%2FDC")
        #expect(WikipediaSummaryClient.url(forTitle: "What? #1", baseURL: base)?.absoluteString
                == "https://en.wikipedia.org/api/rest_v1/page/summary/What%3F_%231")
        #expect(WikipediaSummaryClient.url(forTitle: "Aérospatiale Alouette III", baseURL: base)?.absoluteString
                == "https://en.wikipedia.org/api/rest_v1/page/summary/A%C3%A9rospatiale_Alouette_III")
        #expect(WikipediaSummaryClient.url(forTitle: "Talk:Foo", baseURL: base)?.absoluteString
                == "https://en.wikipedia.org/api/rest_v1/page/summary/Talk%3AFoo")
    }

    @Test func refusesInsecureBaseOrEmptyTitle() {
        #expect(WikipediaSummaryClient.url(forTitle: "Boeing 737",
                                           baseURL: URL(string: "http://en.wikipedia.org/api/rest_v1/page/summary/")!) == nil)
        #expect(WikipediaSummaryClient.url(forTitle: "   ", baseURL: base) == nil)
    }

    // MARK: cache

    @Test func cacheDistinguishesNotFetchedFromMiss() async {
        let cache = WikipediaSummaryCache()
        if case .notFetched = await cache.get(key: "Boeing 737") {} else {
            Issue.record("Expected .notFetched for unknown key")
        }
        await cache.set(key: "Boeing 737", value: nil)
        if case .hit(let v) = await cache.get(key: "Boeing 737") {
            #expect(v == nil)
        } else {
            Issue.record("Expected .hit(nil) after set-nil")
        }
    }

    @Test func cacheIsBounded() async {
        let cache = WikipediaSummaryCache(capacity: 2)
        let s = WikipediaSummary(extract: "x", pageURL: URL(string: "https://en.wikipedia.org/wiki/X")!)
        await cache.set(key: "a", value: s)
        await cache.set(key: "b", value: s)
        await cache.set(key: "c", value: s)
        var hits = 0
        for key in ["a", "b", "c"] {
            if case .hit = await cache.get(key: key) { hits += 1 }
        }
        #expect(hits == 2)
        if case .hit(let v) = await cache.get(key: "c") { #expect(v == s) } else {
            Issue.record("newest entry should survive eviction")
        }
    }
}

// MARK: - Network path (URLProtocol stub)

/// Canned responses for `summary(forTitle:)`. Static state, so the suite
/// below is `.serialized`.
final class WikipediaStubProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var transportError: Error?
    nonisolated(unsafe) static var recorded: [URLRequest] = []

    static func reset() {
        status = 200
        body = Data()
        transportError = nil
        recorded = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recorded.append(request)
        if let error = Self.transportError {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Wikipedia summary client network path", .serialized)
struct WikipediaSummaryClientNetworkTests {

    private let okBody = try! JSONSerialization.data(withJSONObject: [
        "type": "standard",
        "title": "Boeing 737",
        "extract": "The Boeing 737 is an American narrow-body aircraft. It was developed in the 1960s. It is the most-produced jetliner.",
        "content_urls": ["mobile": ["page": "https://en.m.wikipedia.org/wiki/Boeing_737"]],
    ] as [String: Any])

    /// A client on a stubbed session with its own (empty) cache.
    private func makeClient() -> WikipediaSummaryClient {
        WikipediaStubProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WikipediaStubProtocol.self]
        return WikipediaSummaryClient(session: URLSession(configuration: config),
                                      cache: WikipediaSummaryCache())
    }

    @Test func okIsParsedCachedAndSentWithTheUserAgent() async throws {
        let client = makeClient()
        WikipediaStubProtocol.body = okBody
        let first = await client.summary(forTitle: "Boeing 737")
        #expect(first?.extract == "The Boeing 737 is an American narrow-body aircraft. It was developed in the 1960s.")
        let req = try #require(WikipediaStubProtocol.recorded.first)
        #expect(req.value(forHTTPHeaderField: "User-Agent") == WikipediaSummaryClient.defaultUserAgent)
        #expect(req.url?.absoluteString == "https://en.wikipedia.org/api/rest_v1/page/summary/Boeing_737")

        // Second call is served from the cache: no new request.
        let second = await client.summary(forTitle: "Boeing 737")
        #expect(second == first)
        #expect(WikipediaStubProtocol.recorded.count == 1)
    }

    @Test func notFoundIsAMissAndIsCached() async {
        let client = makeClient()
        WikipediaStubProtocol.status = 404
        #expect(await client.summary(forTitle: "No Such Plane") == nil)
        #expect(await client.summary(forTitle: "No Such Plane") == nil)
        #expect(WikipediaStubProtocol.recorded.count == 1)
    }

    @Test func serverErrorIsNotCached() async {
        let client = makeClient()
        WikipediaStubProtocol.status = 503
        WikipediaStubProtocol.body = okBody
        #expect(await client.summary(forTitle: "Boeing 737") == nil)
        // The blip passes: the next call goes back to the network and wins.
        WikipediaStubProtocol.status = 200
        #expect(await client.summary(forTitle: "Boeing 737") != nil)
        #expect(WikipediaStubProtocol.recorded.count == 2)
    }

    @Test func transportErrorIsNotCached() async {
        let client = makeClient()
        WikipediaStubProtocol.transportError = URLError(.notConnectedToInternet)
        #expect(await client.summary(forTitle: "Boeing 737") == nil)
        WikipediaStubProtocol.transportError = nil
        WikipediaStubProtocol.body = okBody
        #expect(await client.summary(forTitle: "Boeing 737") != nil)
        #expect(WikipediaStubProtocol.recorded.count == 2)
    }

    @Test func disambiguationIsAMissAndIsCached() async throws {
        let client = makeClient()
        WikipediaStubProtocol.body = try JSONSerialization.data(withJSONObject: [
            "type": "disambiguation",
            "extract": "Mercury may refer to: a planet. An element.",
            "content_urls": ["mobile": ["page": "https://en.m.wikipedia.org/wiki/Mercury"]],
        ] as [String: Any])
        #expect(await client.summary(forTitle: "Mercury") == nil)
        #expect(await client.summary(forTitle: "Mercury") == nil)
        #expect(WikipediaStubProtocol.recorded.count == 1)
    }
}
