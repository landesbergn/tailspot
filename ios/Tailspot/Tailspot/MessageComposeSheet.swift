//
//  MessageComposeSheet.swift
//  Tailspot
//
//  Apple's Messages composer with an image already attached, for the share
//  sheet's one-tap Messages button.
//
//  Explain-as-we-go: `MFMessageComposeViewController` is MessageUI's
//  in-app Messages draft. The app fills the body and attachments, the user
//  picks recipients and taps send. Only the user can send; the app just
//  learns the result through the delegate. `canSendText()` is false on
//  devices without Messages set up (and on the simulator), so callers hide
//  the button then.
//

import MessageUI
import SwiftUI

struct MessageComposeSheet: UIViewControllerRepresentable {
    let image: UIImage
    let message: String
    /// How the composer ended: sent, cancelled or failed.
    var onFinish: (MessageComposeResult) -> Void = { _ in }

    static var isAvailable: Bool {
        MFMessageComposeViewController.canSendText()
            && MFMessageComposeViewController.canSendAttachments()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.messageComposeDelegate = context.coordinator
        controller.body = message
        if let png = image.pngData() {
            controller.addAttachmentData(png, typeIdentifier: "public.png",
                                         filename: "tailspot-catch.png")
        }
        return controller
    }

    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: (MessageComposeResult) -> Void

        init(onFinish: @escaping (MessageComposeResult) -> Void) {
            self.onFinish = onFinish
        }

        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) {
            onFinish(result)
            controller.dismiss(animated: true)
        }
    }
}
