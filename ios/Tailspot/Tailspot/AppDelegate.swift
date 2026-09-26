//
//  AppDelegate.swift
//  Tailspot
//
//  The app's first `UIApplicationDelegate`. It exists for exactly one job:
//  APNs device-token registration, which SwiftUI has no equivalent of —
//  `didRegisterForRemoteNotificationsWithDeviceToken` is a UIKit delegate
//  callback and nothing else delivers it.
//
//  Explain-as-we-go (`@UIApplicationDelegateAdaptor`): a SwiftUI `App` has
//  no delegate of its own. Declaring
//
//      @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
//
//  in `TailspotApp` tells SwiftUI to create ONE instance of this class, hand
//  it to UIKit as the real application delegate, and keep it alive for the
//  process. It does NOT replace the SwiftUI lifecycle — `body`, `scenePhase`
//  and `.onOpenURL` all keep working exactly as before; this only adds the
//  UIKit callbacks SwiftUI never surfaced. Note what it is NOT used for:
//  notification delivery and taps still go through
//  `UNUserNotificationCenterDelegate` (StreakReminderCenter), which is a
//  different protocol on a different object.
//
//  Why remote notifications at all, when challenge reminders are local: a
//  local reminder can only know what this phone knows. "Someone just passed
//  you in Weekend Flyoff" is a fact only the server has, so the `overtaken`
//  moment is a push. The backend half of this is being built in parallel —
//  the contract it implements is written down in
//  `ChallengeNotificationRouting`, and nothing here should change without
//  changing that.
//

import Foundation
import UIKit
import UserNotifications
import os

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Re-register on every launch when permission is already granted.
        // APNs tokens are not forever: they change on restore-from-backup,
        // on some OS updates, and whenever the user reinstalls. Asking again
        // at launch is the documented way to stay current, and it is cheap —
        // iOS answers from cache when nothing changed.
        Task { @MainActor in
            await PushRegistration.registerIfAuthorized()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // APNs hands the token over as raw bytes; every server API on earth
        // wants the lowercase hex string.
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard let environment = PushEnvironment.current() else {
            Log.ui.notice("APNs token received with no aps-environment — not uploading")
            return
        }
        Log.ui.notice("APNs token received (\(environment, privacy: .public))")
        Task {
            await PushTokenClient().registerIfChanged(token: hex, environment: environment)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Log.ui.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
        Analytics.capture("push_registration_failed", [
            "reason": .string(error.localizedDescription),
        ])
    }
}

// MARK: - Registration

/// The "should we even ask iOS for a token?" gate, shared by the launch
/// path above and `ChallengeReminderScheduler`'s permission ask.
@MainActor
enum PushRegistration {

    /// Ask iOS for an APNs device token — unless this build could not
    /// possibly have one. The simulator has no APNs, and a build with no
    /// `aps-environment` entitlement would only ever reach
    /// `didFailToRegister`, so both skip silently rather than logging a
    /// failure that means nothing.
    static func registerForRemoteNotifications() {
        guard PushEnvironment.current() != nil else {
            Log.ui.debug("Skipping APNs registration: no aps-environment")
            return
        }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Register only when the user has already granted notification
    /// permission. Registering without it is legal (it yields a token for
    /// silent pushes) but pointless here: every push this app sends is a
    /// visible alert, and asking iOS for a token we cannot use is noise in
    /// the logs and a row in the backend that never fires.
    static func registerIfAuthorized() async {
        let status = await UNUserNotificationCenter.current().notificationSettings()
            .authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        registerForRemoteNotifications()
    }
}

// MARK: - Environment

/// Which APNs environment this build's token belongs to — the thing the
/// backend must know to pick the right APNs host, and the single most
/// common reason a push silently never arrives (a sandbox token sent to the
/// production gateway is simply dropped).
///
/// Explain-as-we-go — reading the provisioning profile: the answer is not in
/// Info.plist and there is no API for it. It is in the app's code-signing
/// ENTITLEMENTS, and the only copy of those readable at runtime lives in
/// `embedded.mobileprovision`, a file Xcode drops into every signed .app
/// bundle. That file is a CMS (PKCS#7) signature blob with an XML property
/// list embedded in the middle of it. Parsing the CMS container properly
/// would mean Security-framework work for one string, so the standard
/// approach — and the one used here — is to find the `<plist` … `</plist>`
/// window inside the bytes and hand that to `PropertyListSerialization`.
/// A Debug/TestFlight build says "development", which APNs calls "sandbox";
/// an App Store build says "production". The simulator has no profile at
/// all, which is exactly the case where registration must not happen.
nonisolated enum PushEnvironment {
    /// What the backend expects in the `environment` field.
    static let sandbox = "sandbox"
    static let production = "production"

    /// The entitlement key Xcode writes into the profile.
    static let entitlementKey = "aps-environment"

    /// The environment for the running build, or nil when this build can
    /// have no APNs token (simulator, or an unsigned build with no profile).
    static func current(bundle: Bundle = .main) -> String? {
        #if targetEnvironment(simulator)
        // The simulator has no APNs and no embedded profile. Bail before
        // touching the bundle so the intent is unmistakable.
        return nil
        #else
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return environment(fromProvisioningProfile: data)
        #endif
    }

    /// The pure half: profile bytes in, environment string out. Separated so
    /// the parser is testable without a signed bundle.
    static func environment(fromProvisioningProfile data: Data) -> String? {
        guard let plist = embeddedPlist(in: data),
              let entitlements = plist["Entitlements"] as? [String: Any],
              let raw = entitlements[entitlementKey] as? String
        else { return nil }
        return mapped(apsEnvironment: raw)
    }

    /// `"development"` is what the profile says; `"sandbox"` is what APNs
    /// (and the backend) call the same thing. Everything else passes
    /// through, so a future Apple value is not silently turned into the
    /// wrong gateway.
    static func mapped(apsEnvironment raw: String) -> String? {
        switch raw {
        case "development": return sandbox
        case "production":  return production
        case let other where other.isEmpty: return nil
        case let other:     return other
        }
    }

    /// The `<plist …>` … `</plist>` window inside the CMS blob, decoded.
    static func embeddedPlist(in data: Data) -> [String: Any]? {
        guard let start = data.range(of: Data("<plist".utf8)),
              let end = data.range(of: Data("</plist>".utf8),
                                   in: start.lowerBound..<data.endIndex)
        else { return nil }
        let slice = data[start.lowerBound..<end.upperBound]
        return (try? PropertyListSerialization.propertyList(
            from: slice, options: [], format: nil)) as? [String: Any]
    }
}
