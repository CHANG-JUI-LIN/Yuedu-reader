import Foundation

/// How much a diagnostic line matters.
///
/// `AppLogger` has never carried a level — the level was implied by *which*
/// category function you called, so all 151 `AppLogger.render` call sites read as
/// errors even though most of them are `[FlipTrace]` breadcrumbs. This type makes
/// the level explicit so the diagnostics screen can separate "the reader narrating
/// what it did" from "something is wrong".
enum DiagnosticSeverity: Int, Codable, CaseIterable, Comparable, Sendable {
    /// Step-by-step narration. Off unless the user turns verbose on.
    case trace = 0
    /// Milestones worth keeping: book opened, sync finished.
    case info = 1
    /// A structured probe (`⟐`) — interesting when reading backwards from a bug,
    /// not a problem by itself.
    case notice = 2
    /// Degraded but handled: a retry, a cancelled fetch that was re-requested.
    case warning = 3
    /// An operation failed.
    case error = 4
    /// An invariant the code guarantees did not hold. This is the category the
    /// "report this" banner counts, and the only one the user is asked to act on.
    case anomaly = 5
    /// A crash, hang, or security fault.
    case fault = 6

    static func < (lhs: DiagnosticSeverity, rhs: DiagnosticSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Short tag used in the exported text file. ASCII on purpose — the export is
    /// read in whatever the recipient has, including a terminal.
    var exportTag: String {
        switch self {
        case .trace:   return "TRACE"
        case .info:    return "INFO "
        case .notice:  return "NOTE "
        case .warning: return "WARN "
        case .error:   return "ERROR"
        case .anomaly: return "ANOM "
        case .fault:   return "FAULT"
        }
    }

    var localizedName: String {
        switch self {
        case .trace:   return localized("追蹤")
        case .info:    return localized("資訊")
        case .notice:  return localized("提示")
        case .warning: return localized("警告")
        case .error:   return localized("錯誤")
        case .anomaly: return localized("異常")
        case .fault:   return localized("嚴重")
        }
    }

    /// SF Symbol for the row badge. Paired with `localizedName` in the UI so the
    /// state is never carried by colour alone (design.md H6).
    var symbolName: String {
        switch self {
        case .trace:   return "point.3.connected.trianglepath.dotted"
        case .info:    return "info.circle"
        case .notice:  return "eye"
        case .warning: return "exclamationmark.triangle"
        case .error:   return "xmark.octagon"
        case .anomaly: return "bolt.trianglebadge.exclamationmark"
        case .fault:   return "exclamationmark.octagon.fill"
        }
    }

    /// True for the two levels the user is asked to report.
    var isReportable: Bool { self >= .anomaly }
}

/// Which subsystem produced the line.
enum DiagnosticCategory: String, Codable, CaseIterable, Sendable {
    case reader
    case network
    case parse
    case cache
    case tts
    case sync
    case security
    case crash
    case general

    var localizedName: String {
        switch self {
        case .reader:   return localized("閱讀器")
        case .network:  return localized("網路")
        case .parse:    return localized("解析")
        case .cache:    return localized("快取")
        case .tts:      return localized("朗讀")
        case .sync:     return localized("同步")
        case .security: return localized("安全")
        case .crash:    return localized("崩潰")
        // Deliberately not the 一般 key: that one is already the font weight
        // Regular in 閱讀器排版, and this category inherited its English
        // translation, rendering the catch-all category as "Regular".
        case .general:  return localized("其他")
        }
    }
}

/// One line in the log.
///
/// `sequence` rather than `timestamp` is the sort key: several lines routinely land
/// inside the same millisecond during a page turn, and the order they were emitted
/// in is exactly what makes a trace readable.
struct DiagnosticEntry: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let sequence: UInt64
    let timestamp: Date
    let severity: DiagnosticSeverity
    let category: DiagnosticCategory
    let message: String
    /// Call stacks, MetricKit metadata, position trails — anything too long for the
    /// row itself. Shown when the row is expanded.
    let detail: String?

    init(
        id: UUID = UUID(),
        sequence: UInt64,
        timestamp: Date = Date(),
        severity: DiagnosticSeverity,
        category: DiagnosticCategory,
        message: String,
        detail: String? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.timestamp = timestamp
        self.severity = severity
        self.category = category
        self.message = message
        self.detail = detail
    }
}

/// One app launch.
///
/// `endedCleanly` is written `false` when the session starts and flipped to `true`
/// on an orderly termination. A session still reading `false` on the next launch is
/// how the app knows the previous run died — MetricKit's crash payload arrives
/// separately and is matched against it.
struct DiagnosticSession: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let startedAt: Date
    let appVersion: String
    let build: String
    let osVersion: String
    let deviceModel: String
    var endedCleanly: Bool

    static func current() -> DiagnosticSession {
        let info = Bundle.main.infoDictionary
        return DiagnosticSession(
            id: UUID(),
            startedAt: Date(),
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: Self.hardwareModel(),
            endedCleanly: false
        )
    }

    /// `iPhone16,2` rather than the marketing name: it is what a crash report and a
    /// device-specific bug report need, and it needs no lookup table to stay
    /// correct as new devices ship.
    private static func hardwareModel() -> String {
        // In the Simulator `uname` reports the Mac's architecture ("arm64"), which
        // would put a meaningless model on every report produced during development.
        // The simulated device is in the environment instead.
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "\(simulated) (Simulator)"
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let model = mirror.children.reduce(into: "") { partial, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            partial.append(Character(UnicodeScalar(UInt8(bitPattern: value))))
        }
        return model.isEmpty ? "unknown" : model
    }
}
