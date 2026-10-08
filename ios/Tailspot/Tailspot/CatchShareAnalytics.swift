//
//  CatchShareAnalytics.swift
//  Tailspot
//
//  The catch-share funnel in one place (2026-10-08), so every step is named
//  the same way and carries the same context (`rarity`, `has_photo`):
//
//    catch_share_opened             share pill tapped (the pre-sheet meaning,
//                                   so the series stays comparable)
//    catch_share_format_selected    preview moved to a shape: format + via
//                                   (swipe / chip / destination)
//    catch_share_backdrop_selected  story background changed
//    catch_share_destination_tapped a destination button: destination + format
//    catch_share_completed          the share really happened: + method
//    catch_share_cancelled          system sheet / composer closed unsent
//    catch_share_failed             couldn't complete (Save denied or errored)
//    catch_share_closed             the share sheet went away: shared,
//                                   formats_viewed, last_format
//
//  `method` on completed: the system activity type for share-sheet sends
//  ("com.burbn.instagram.shareextension", "com.apple.UIKit.activity.
//  SaveToCameraRoll", …), "sent" for Messages, "saved", "copied", or
//  "instagram_handoff" for the direct Stories path. That last one only means
//  Instagram's editor opened; whether the story was posted is invisible to us.
//

import Foundation
import MessageUI

struct CatchShareAnalytics {
    let rarity: String
    let hasPhoto: Bool

    init(plane: CardPlane, hasCatchPhoto: Bool) {
        self.rarity = plane.rarity.label
        self.hasPhoto = hasCatchPhoto
    }

    /// How a Messages composer ended, in funnel terms.
    enum Outcome: Equatable {
        case completed, cancelled, failed
    }

    static func outcome(_ result: MessageComposeResult) -> Outcome {
        switch result {
        case .sent: .completed
        case .cancelled: .cancelled
        case .failed: .failed
        @unknown default: .failed
        }
    }

    func sheetOpened() {
        send("catch_share_opened")
    }

    func formatSelected(_ format: SharePage, via: String) {
        send("catch_share_format_selected", ["format": .string(format.rawValue), "via": .string(via)])
    }

    func backdropSelected(_ backdrop: StoryBackdrop) {
        send("catch_share_backdrop_selected", ["backdrop": .string(backdrop.rawValue)])
    }

    func destinationTapped(_ destination: String, format: SharePage) {
        send("catch_share_destination_tapped", step(destination, format))
    }

    func completed(_ destination: String, format: SharePage, method: String) {
        var props = step(destination, format)
        props["method"] = .string(method)
        send("catch_share_completed", props)
    }

    func cancelled(_ destination: String, format: SharePage) {
        send("catch_share_cancelled", step(destination, format))
    }

    func failed(_ destination: String, format: SharePage, reason: String) {
        var props = step(destination, format)
        props["reason"] = .string(reason)
        send("catch_share_failed", props)
    }

    func sheetClosed(shared: Bool, formatsViewed: Int, lastFormat: SharePage) {
        send("catch_share_closed", [
            "shared": .bool(shared),
            "formats_viewed": .int(formatsViewed),
            "last_format": .string(lastFormat.rawValue),
        ])
    }

    private func step(_ destination: String, _ format: SharePage) -> [String: AnalyticsValue] {
        ["destination": .string(destination), "format": .string(format.rawValue)]
    }

    private func send(_ event: String, _ props: [String: AnalyticsValue] = [:]) {
        var all = props
        all["rarity"] = .string(rarity)
        all["has_photo"] = .bool(hasPhoto)
        Analytics.capture(event, all)
    }
}
