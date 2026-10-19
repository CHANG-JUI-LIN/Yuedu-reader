import os
import UIKit

/// The device identifier source scripts see (`java.deviceID()`, and `java.androidId()` derived
/// from it), read once on the main actor at launch.
///
/// `UIDevice` is main-actor-only, while source JS calls `deviceID()` on its engine's queue. The
/// value can't change while the app runs, so `yuedu_appApp.init` captures it before any source
/// script can run, and the bridge reads the captured string from any thread.
enum DeviceIdentity {
    private static let captured = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Called once from app launch, before any source script runs.
    @MainActor
    static func captureAtLaunch() {
        // "ios-device" when the vendor id is unavailable (before first unlock), as before.
        let id = UIDevice.current.identifierForVendor?.uuidString ?? "ios-device"
        captured.withLock { $0 = id }
    }

    static var vendorID: String {
        guard let id = captured.withLock({ $0 }) else {
            // Launch order guarantees the capture; reaching here means a script ran before
            // `yuedu_appApp.init`, which is a bug to fix at the call site.
            AppLogger.error("DeviceIdentity read before captureAtLaunch()")
            assertionFailure("DeviceIdentity read before captureAtLaunch()")
            return "ios-device"
        }
        return id
    }
}
