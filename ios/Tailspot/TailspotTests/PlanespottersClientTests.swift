//
//  PlanespottersClientTests.swift
//  TailspotTests
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Planespotters decoding")
struct PlanespottersClientTests {

    @Test func decodesFullPayload() throws {
        let json = """
        {
          "photos": [
            {
              "id": "1883011",
              "thumbnail": {
                "src": "https://t.plnspttrs.net/20292/1883011_t.jpg",
                "size": {"width": 200, "height": 133}
              },
              "thumbnail_large": {
                "src": "https://t.plnspttrs.net/20292/1883011_280.jpg",
                "size": {"width": 420, "height": 280}
              },
              "link": "https://www.planespotters.net/photo/1883011/example",
              "photographer": "Jay Huang"
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(PlanespottersResponse.self, from: json)
        #expect(response.photos.count == 1)
        let p = response.photos[0]
        #expect(p.id == "1883011")
        #expect(p.photographer == "Jay Huang")
        #expect(p.thumbnail.src.contains("_t.jpg"))
        #expect(p.thumbnail_large.src.contains("_280.jpg"))
    }

    @Test func emptyPhotosOnMiss() throws {
        let json = #"{"photos": []}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(PlanespottersResponse.self, from: json)
        #expect(response.photos.isEmpty)
    }

    @Test func planePhotoBuildsFromWireFormat() {
        let wire = PlanespottersPhoto(
            id: "42",
            thumbnail: PhotoVariant(src: "https://example.com/t.jpg"),
            thumbnail_large: PhotoVariant(src: "https://example.com/280.jpg"),
            link: "https://www.planespotters.net/photo/42",
            photographer: "Test Photographer"
        )
        let photo = PlanePhoto(wire)
        #expect(photo != nil)
        #expect(photo?.photographer == "Test Photographer")
        #expect(photo?.thumbnailURL.absoluteString == "https://example.com/t.jpg")
        #expect(photo?.thumbnailLargeURL.absoluteString == "https://example.com/280.jpg")
    }

    @Test func planePhotoReturnsNilOnBadURL() {
        let wire = PlanespottersPhoto(
            id: "x",
            thumbnail: PhotoVariant(src: ""),
            thumbnail_large: PhotoVariant(src: "https://example.com/280.jpg"),
            link: "https://example.com/p/x",
            photographer: "X"
        )
        #expect(PlanePhoto(wire) == nil)
    }

    @Test func cacheDistinguishesNotFetchedFromMiss() async {
        let cache = PlanespottersCache()
        if case .notFetched = await cache.get(key: "abc") {} else {
            Issue.record("Expected .notFetched for unknown key")
        }
        await cache.set(key: "abc", value: nil)
        if case .hit(let v) = await cache.get(key: "abc") {
            #expect(v == nil)
        } else {
            Issue.record("Expected .hit(nil) after set-nil")
        }
    }
}
