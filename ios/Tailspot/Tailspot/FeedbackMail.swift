//
//  FeedbackMail.swift
//  Tailspot
//
//  Settings → "Send feedback": a mail draft to support@tailspot.app with
//  the Settings footer's version line already in it, so a report arrives
//  with the exact build attached.
//
//  Three routes, best first (`FeedbackMail.Route`):
//    1. MessageUI's in-app composer, when Mail has an account set up.
//    2. A `mailto:` URL, for people whose mail app isn't Apple Mail (Gmail,
//       Outlook... register as mailto handlers; MFMailComposeViewController
//       only knows about Apple Mail).
//    3. Neither worked: copy the address and say so in a toast.
//
//  Explain-as-we-go: `MFMailComposeViewController` is the Mail draft
//  sheet, the email twin of MessageComposeSheet. The app fills recipient,
//  subject and body; only the user can send. `canSendMail()` is false when
//  no Mail account exists (and always on the simulator).
//

import MessageUI
import SwiftUI

nonisolated enum FeedbackMail {
    static let address = "support@tailspot.app"
    static let subject = "Tailspot feedback"

    /// Room to write at the top, the version line at the bottom.
    static func body(versionLine: String) -> String {
        "\n\n\n\(versionLine)"
    }

    /// The `mailto:` fallback with subject and body prefilled.
    /// URLComponents percent-encodes spaces and newlines in the query.
    static func mailtoURL(versionLine: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body(versionLine: versionLine)),
        ]
        return components.url
    }

    /// Which route a tap took. Raw values are the telemetry `route`.
    enum Route: String, Sendable {
        case mailCompose = "mail_compose"
        case mailto = "mailto"
        case copiedAddress = "copied_address"
    }

    /// The toast after the copy fallback.
    static let copiedToast = "Copied \(address)"
}

/// The in-app Mail draft (route 1).
struct MailComposeSheet: UIViewControllerRepresentable {
    let versionLine: String

    static var isAvailable: Bool { MFMailComposeViewController.canSendMail() }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([FeedbackMail.address])
        controller.setSubject(FeedbackMail.subject)
        controller.setMessageBody(FeedbackMail.body(versionLine: versionLine), isHTML: false)
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            controller.dismiss(animated: true)
        }
    }
}
