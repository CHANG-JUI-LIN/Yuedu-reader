import CryptoKit
import Foundation
import UIKit
import UserNotifications

/// 回饋中心 push on this device: hands the APNs token to the Gateway, which files it under
/// the inbox (`feedbackInboxes/{inbox}/pushDevices/{installId}`) for
/// `onFeedbackThreadUpdated` (functions/src/feedbackPush.ts) to send to.
///
/// Only an inbox that has reports registers. Every launch asks iOS for a token
/// (`RSSNotificationManager.start`) and hands it here, but the token goes up only once this
/// inbox is known to be in use — a report sent from this device, or 我的回饋 listing one
/// (an inbox shared over iCloud Keychain with a device that sent them) — and then only when
/// the token, its APNs environment or the inbox changed since the last upload.
@MainActor
final class FeedbackPushRegistration {
    static let shared = FeedbackPushRegistration()

    private enum Keys {
        static let inboxInUse = "yd_feedback_push_inbox_in_use"
        static let uploaded = "yd_feedback_push_uploaded"
    }

    private let defaults: UserDefaults
    private var token: String?
    private var uploading = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// From `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    func didRegister(deviceToken: Data) {
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
        uploadIfNeeded()
    }

    /// A report went out, or 我的回饋 listed one. The first time, this is when the person is
    /// asked for notification permission (maintainer, 2026-10-19: after the first report) —
    /// unless they have answered already, which RSS's launch-time request usually means.
    func inboxInUse() {
        let firstTime = !defaults.bool(forKey: Keys.inboxInUse)
        defaults.set(true, forKey: Keys.inboxInUse)
        if token != nil {
            uploadIfNeeded()
            return
        }
        guard firstTime else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                do {
                    guard try await center.requestAuthorization(options: [.alert, .sound, .badge]) else { return }
                } catch {
                    AppLogger.network("Feedback push: authorization request failed", error: error)
                    return
                }
            case .denied:
                return
            default:
                break
            }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    private func uploadIfNeeded() {
        guard defaults.bool(forKey: Keys.inboxInUse), let token, !uploading else { return }
        guard let environment = Self.apnsEnvironment else {
            AppLogger.anomaly("Feedback push: this build is not signed for push", category: .network)
            return
        }
        let signature = Self.signature(token: token, environment: environment, inbox: FeedbackInbox.key)
        guard defaults.string(forKey: Keys.uploaded) != signature else { return }
        uploading = true
        Task {
            defer { uploading = false }
            do {
                try await FeedbackService.shared.registerPushDevice(token: token, environment: environment)
                defaults.set(signature, forKey: Keys.uploaded)
            } catch {
                // The next launch's token hands it here again.
                AppLogger.network("Feedback push: registering the device failed", error: error)
            }
        }
    }

    /// Hashed: the inbox key is what grants access to the inbox, and it stays in the Keychain.
    private static func signature(token: String, environment: String, inbox: String) -> String {
        let digest = SHA256.hash(data: Data("\(token)|\(environment)|\(inbox)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Which APNs host serves this build's tokens: the `aps-environment` it was signed with.
    /// An App Store build carries no provisioning profile and is always production; a
    /// development or TestFlight build reads it from its profile. `nil` for a build whose
    /// profile has no push entitlement — APNs would refuse its tokens on either host.
    static let apnsEnvironment: String? = {
        #if targetEnvironment(simulator)
        return "development"
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else {
            return "production"
        }
        do {
            return try provisionedAPNsEnvironment(profile: Data(contentsOf: url))
        } catch {
            AppLogger.network("Feedback push: provisioning profile unreadable", error: error)
            return nil
        }
        #endif
    }()

    /// The profile is CMS-signed; the plist it carries sits in the clear between its XML
    /// prologue and `</plist>`.
    nonisolated static func provisionedAPNsEnvironment(profile: Data) throws -> String? {
        guard let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex)
        else { return nil }
        let plist = try PropertyListSerialization.propertyList(
            from: profile.subdata(in: start.lowerBound..<end.upperBound), format: nil
        )
        let entitlements = (plist as? [String: Any])?["Entitlements"] as? [String: Any]
        return entitlements?["aps-environment"] as? String
    }
}
