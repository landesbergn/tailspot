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

    /// The app's App Store id (App Store Connect → App Information).
    static let appId = "6773470079"

    /// The listing's write-a-review page, for Settings' "Rate Tailspot"
    /// row. `action=write-review` opens the App Store app straight on the
    /// review composer. It's user-initiated, so unlike the in-app rating
    /// sheet Apple doesn't throttle it.
    static var writeReviewURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "apps.apple.com"
        components.path = "/app/id\(appId)"
        components.queryItems = [URLQueryItem(name: "action", value: "write-review")]
        return components.url!
    }

    /// Campaign-attributed listing URL for one share surface.
    static func url(campaign: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "apps.apple.com"
        components.path = "/app/apple-store/id\(appId)"
        components.queryItems = [
            URLQueryItem(name: "pt", value: providerToken),
            URLQueryItem(name: "ct", value: campaign),
            URLQueryItem(name: "mt", value: "8"),
        ]
        return components.url!
    }
}
