import FirebaseAuth
import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// 回饋中心 push: a token goes to the APNs host its build was signed for, read from the
/// provisioning profile's `aps-environment`.
struct FeedbackPushRegistrationTests {
    /// A profile is a CMS envelope with the plist in the clear inside it.
    private func profile(entitlements: String) -> Data {
        var data = Data([0x30, 0x80, 0x06, 0x09, 0x2a, 0x86, 0x48])
        data.append(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Name</key><string>Yuedu</string>
            <key>Entitlements</key>
            <dict>\(entitlements)</dict>
        </dict>
        </plist>
        """.utf8))
        data.append(Data([0xa0, 0x82, 0x0e, 0x00, 0xff]))
        return data
    }

    @Test func readsTheEnvironmentTheProfileGrants() throws {
        let development = profile(entitlements: "<key>aps-environment</key><string>development</string>")
        #expect(try FeedbackPushRegistration.provisionedAPNsEnvironment(profile: development) == "development")
        let production = profile(entitlements: "<key>aps-environment</key><string>production</string>")
        #expect(try FeedbackPushRegistration.provisionedAPNsEnvironment(profile: production) == "production")
    }

    @Test func aProfileWithoutPushGivesNoEnvironment() throws {
        let noPush = profile(entitlements: "<key>get-task-allow</key><true/>")
        #expect(try FeedbackPushRegistration.provisionedAPNsEnvironment(profile: noPush) == nil)
        #expect(try FeedbackPushRegistration.provisionedAPNsEnvironment(profile: Data([0x00, 0x01])) == nil)
    }

    /// The token iOS hands the app delegate reaches this app with FirebaseAuth running.
    /// Auth's app-delegate proxy (GoogleUtilities) isa-swizzles SwiftUI's AppDelegate and
    /// passes the token on only to an implementation on that class, while SwiftUI forwards
    /// it to the `@UIApplicationDelegateAdaptor` dynamically — so with the proxy on, no
    /// device ever registered (10-19 to 10-25).
    @MainActor @Test func theAPNsTokenReachesTheAppWithFirebaseAuthRunning() throws {
        _ = Auth.auth() // installs Auth's proxy, as launch does through FirebaseAuthManager
        // Keeps the test token from going up to the Gateway.
        UserDefaults.standard.removeObject(forKey: "yd_feedback_push_inbox_in_use")
        let delegate = try #require(UIApplication.shared.delegate)
        let token = Data((0..<32).map { UInt8($0) })

        delegate.application?(UIApplication.shared, didRegisterForRemoteNotificationsWithDeviceToken: token)

        #expect(FeedbackPushRegistration.shared.token == token.map { String(format: "%02x", $0) }.joined())
    }
}
