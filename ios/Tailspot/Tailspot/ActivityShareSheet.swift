//
//  ActivityShareSheet.swift
//  Tailspot
//
//  The system share sheet, wrapped so the app can learn what the user
//  actually did with it.
//
//  Explain-as-we-go: SwiftUI's `ShareLink` presents the same sheet but
//  reports nothing back — you know the button was tapped, never whether
//  anything was shared. `UIViewControllerRepresentable` is SwiftUI's
//  adapter for a UIKit view controller: `makeUIViewController` builds the
//  UIKit object once, `updateUIViewController` would push new state into it
//  (nothing to push here — the sheet is configured at birth). UIKit's
//  `UIActivityViewController` has a `completionWithItemsHandler`, which
//  fires with `completed == true` and the chosen activity type only when a
//  share really happened; a dismissed sheet reports `completed == false`.
//  That is what makes `challenge_invite_shared` mean "shared" rather than
//  "opened the sheet".
//
//  Presented via `.sheet { ActivityShareSheet(...) }`, so SwiftUI owns the
//  presentation and the representable only supplies the controller.
//

import SwiftUI
import UIKit

struct ActivityShareSheet: UIViewControllerRepresentable {
    /// Anything `UIActivityViewController` accepts: strings, URLs, images.
    let items: [Any]
    /// `nil` when the user dismissed without sharing; otherwise the chosen
    /// activity's raw type ("com.apple.UIKit.activity.PostToFacebook",
    /// "com.apple.MobileSMS.Share…"), or "share_sheet" when iOS reports a
    /// completed share without naming the activity.
    let onComplete: (String?) -> Void

    /// Fallback `method` for a completed share iOS didn't attribute.
    static let unknownMethod = "share_sheet"

    /// UIKit's completion arguments as the one value the caller cares
    /// about: nil for "nothing was shared", otherwise the `method` to
    /// report. Pure, so the mapping is testable without presenting a sheet.
    static func method(activityType: UIActivity.ActivityType?, completed: Bool) -> String? {
        guard completed else { return nil }
        let raw = activityType?.rawValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? unknownMethod : raw
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { activityType, completed, _, _ in
            onComplete(Self.method(activityType: activityType, completed: completed))
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
