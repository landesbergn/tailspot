//
//  AppStoreListing.swift
//  Tailspot
//
//  The one place the App Store listing URL is built. Every share surface
//  links the listing in geo-neutral campaign form — /app/apple-store/id…
//  with no /us/ storefront segment (availability is worldwide; Apple
//  redirects each visitor to their own storefront) — so installs are
//  attributed in App Analytics. `pt` is the account-level provider token
//  (the same one tailspot.app's badge links carry); each surface passes its
//  own `ct` campaign name so its installs read as a separate row, next to
//  the website's "Tailspot Website" campaign.
//

import Foundation

enum AppStoreListing {
    /// Account-level App Analytics provider token — must match the
    /// website's badge links (web/) or attribution splits across accounts.
    static let providerToken = "119286625"

    /// Campaign-attributed listing URL for one share surface.
    static func url(campaign: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "apps.apple.com"
        components.path = "/app/apple-store/id6773470079"
        components.queryItems = [
            URLQueryItem(name: "pt", value: providerToken),
            URLQueryItem(name: "ct", value: campaign),
            URLQueryItem(name: "mt", value: "8"),
        ]
        return components.url!
    }
}
