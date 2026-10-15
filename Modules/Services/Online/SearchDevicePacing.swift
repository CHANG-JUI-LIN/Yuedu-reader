import Foundation

/// How hard a search's later pages may push the phone (search 9e, maintainer 2026-10-15:
/// 「能請求多少就請求多少，但是根據手機性能請求」 — no freeze, no hot phone).
///
/// Page 1 always runs at the configured width (網路設定 → 並發數). The pages after it run
/// at half that width while the phone is warm (`.fair`) or in Low Power Mode, and wait while
/// it is hot (`.serious`, `.critical`) until the system says it has cooled. Every iPhone that
/// runs iOS 17 has six cores, so the processor count tells phones apart by nothing; the
/// thermal state is the signal that a phone is working too hard.
struct SearchDevicePacing: Equatable, Sendable {
    var thermalState: ProcessInfo.ThermalState
    var isLowPower: Bool

    /// Later pages wait for the phone to cool.
    var holdsLaterPages: Bool {
        thermalState == .serious || thermalState == .critical
    }

    /// The width a later page's fan-out runs at.
    func laterPageConcurrency(configured: Int) -> Int {
        let halved = thermalState != .nominal || isLowPower
        return halved ? max(1, configured / 2) : max(1, configured)
    }
}

/// Where a search reads the phone's state, and hears it change: live from `ProcessInfo`,
/// or driven by a test.
struct SearchDeviceConditions: Sendable {
    var current: @Sendable () -> SearchDevicePacing
    /// A stream that yields whenever the thermal state or Low Power Mode changes. It is
    /// subscribed when made, so nothing posted after the call is missed, and it ends when the
    /// task iterating it is cancelled.
    var changes: @Sendable () -> AsyncStream<Void>

    static let live = SearchDeviceConditions(
        current: {
            SearchDevicePacing(thermalState: ProcessInfo.processInfo.thermalState,
                               isLowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        },
        changes: {
            AsyncStream { continuation in
                let center = NotificationCenter.default
                let names = [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange]
                // Observer tokens are not Sendable; they are only read again to be removed.
                nonisolated(unsafe) let observers = names.map { name in
                    center.addObserver(forName: name, object: nil, queue: nil) { _ in continuation.yield() }
                }
                continuation.onTermination = { _ in
                    for observer in observers { center.removeObserver(observer) }
                }
            }
        }
    )

    /// Returns once later pages may run, or when the calling task is cancelled.
    func waitUntilLaterPagesMayRun() async {
        let changes = changes()
        var iterator = changes.makeAsyncIterator()
        while current().holdsLaterPages {
            guard await iterator.next() != nil else { return }
        }
    }
}
