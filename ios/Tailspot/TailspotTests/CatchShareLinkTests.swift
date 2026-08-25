//
//  CatchShareLinkTests.swift
//  TailspotTests
//
//  Pins the App Store links behind the app's share surfaces — its one
//  organic install loop. The URL shape is load-bearing three ways: the
//  geo-neutral path (no /us/ storefront segment — availability is worldwide
//  and Apple redirects per visitor), the account provider token `pt` (must
//  match the website's badge links or App Analytics splits the account), and
//  a distinct campaign name `ct` per surface, so catch shares, profile
//  shares, and tailspot.app installs each read as their own App Analytics
//  row.
//

import Foundation
import Testing
@testable import Tailspot

// MainActor because ProfileScreen (a View type) is MainActor-isolated, and
// its static inviteURL inherits that isolation.
@MainActor
@Suite struct CatchShareLinkTests {

    private func components(_ url: URL) -> URLComponents {
        URLComponents(url: url, resolvingAgainstBaseURL: false)!
    }

    private func queryValue(_ url: URL, _ name: String) -> String? {
        components(url).queryItems?.first(where: { $0.name == name })?.value
    }

    @Test func listingURLIsGeoNeutralCampaignForm() {
        let c = components(AppStoreListing.url(campaign: "Test"))
        #expect(c.scheme == "https")
        #expect(c.host == "apps.apple.com")
        // Campaign links use the /app/apple-store/id… path; a storefront
        // segment like /us/ would pin every recipient to one country.
        #expect(c.path == "/app/apple-store/id6773470079")
    }

    @Test func listingURLCarriesCampaignAttribution() {
        let url = AppStoreListing.url(campaign: "Test Campaign")
        // Provider token: account-level, same value the website's badge
        // links use (web/ pages) — a mismatch would split App Analytics.
        #expect(queryValue(url, "pt") == "119286625")
        #expect(queryValue(url, "ct") == "Test Campaign")
        #expect(queryValue(url, "mt") == "8")
    }

    @Test func shareSurfacesUseDistinctCampaigns() {
        // Each surface's installs must read separately in App Analytics —
        // and neither may collide with the website's "Tailspot Website".
        #expect(queryValue(CatchShare.storeURL, "ct") == "Tailspot Catch Share")
        #expect(queryValue(ProfileScreen.inviteURL, "ct") == "Tailspot Profile Share")
        #expect(CatchShare.storeURL != ProfileScreen.inviteURL)
    }
}
