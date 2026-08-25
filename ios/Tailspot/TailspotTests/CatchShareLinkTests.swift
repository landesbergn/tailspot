//
//  CatchShareLinkTests.swift
//  TailspotTests
//
//  Pins the App Store link that rides in every catch share — the app's one
//  organic install loop. The URL's shape is load-bearing three ways: the
//  geo-neutral path (no /us/ storefront segment — availability is worldwide
//  and Apple redirects per visitor), the account provider token `pt` (must
//  match the website's badge links or App Analytics splits the account), and
//  a campaign name `ct` distinct from the website's, so in-app shares and
//  tailspot.app installs read separately in App Analytics.
//

import Foundation
import Testing
@testable import Tailspot

@Suite struct CatchShareLinkTests {

    private var components: URLComponents {
        URLComponents(url: CatchShare.storeURL, resolvingAgainstBaseURL: false)!
    }

    private func queryValue(_ name: String) -> String? {
        components.queryItems?.first(where: { $0.name == name })?.value
    }

    @Test func storeURLIsGeoNeutralCampaignForm() {
        #expect(components.scheme == "https")
        #expect(components.host == "apps.apple.com")
        // Campaign links use the /app/apple-store/id… path; a storefront
        // segment like /us/ would pin every recipient to one country.
        #expect(components.path == "/app/apple-store/id6773470079")
    }

    @Test func storeURLCarriesCampaignAttribution() {
        // Provider token: account-level, same value the website's badge
        // links use (web/ pages) — a mismatch would split App Analytics.
        #expect(queryValue("pt") == "119286625")
        // Campaign name: this surface's own, NOT the website's
        // "Tailspot Website", so the two install sources read separately.
        #expect(queryValue("ct") == "Tailspot Catch Share")
        #expect(queryValue("mt") == "8")
    }
}
