import Foundation
import UIKit

/// The 設備資訊 a report carries, shown on the form before it is sent so the person sees
/// exactly what goes with it.
struct FeedbackDeviceInfo: Equatable, Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        /// The field name in the thread's `deviceInfo` map.
        let id: String
        let title: String
        let value: String
    }

    let rows: [Row]

    /// `deviceInfo` as stored on the thread: field name → shown value.
    var fields: [String: String] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.value) })
    }

    var modelIdentifier: String { rows.first { $0.id == "model" }?.value ?? "" }

    @MainActor
    static func current() -> FeedbackDeviceInfo {
        let device = UIDevice.current
        let wasMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        let batteryState = device.batteryState
        let batteryLevel = device.batteryLevel
        device.isBatteryMonitoringEnabled = wasMonitoring

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""

        return FeedbackDeviceInfo(rows: [
            Row(id: "deviceName", title: localized("裝置名稱"), value: device.name),
            Row(id: "model", title: localized("設備型號"), value: modelIdentifier()),
            Row(id: "systemName", title: localized("系統名稱"), value: device.systemName),
            Row(id: "systemVersion", title: localized("系統版本"), value: device.systemVersion),
            Row(id: "appVersion", title: localized("應用版本"), value: build.isEmpty ? version : "\(version) (\(build))"),
            Row(id: "batteryState", title: localized("電池狀態"), value: batteryStateText(batteryState)),
            Row(id: "batteryLevel", title: localized("電池電量"), value: batteryLevelText(batteryLevel)),
            Row(id: "memory", title: localized("總記憶體"), value: byteText(Int64(ProcessInfo.processInfo.physicalMemory))),
            Row(id: "freeDisk", title: localized("可用磁碟空間"), value: freeDiskText()),
        ])
    }

    /// `iPhone18,2`, not the marketing name: it is what crash reports are keyed by.
    static func modelIdentifier() -> String {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        #endif
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func batteryStateText(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .charging: localized("充電中")
        case .full: localized("已充滿")
        case .unplugged: localized("未充電")
        case .unknown: localized("未知")
        @unknown default: localized("未知")
        }
    }

    private static func batteryLevelText(_ level: Float) -> String {
        guard level >= 0 else { return localized("未知") }
        return Double(level).formatted(.percent.precision(.fractionLength(0)))
    }

    private static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }

    private static func freeDiskText() -> String {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        do {
            let values = try home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            guard let capacity = values.volumeAvailableCapacityForImportantUsage else { return localized("未知") }
            return ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file)
        } catch {
            AppLogger.error("Free disk space could not be read", error: error)
            return localized("未知")
        }
    }
}
