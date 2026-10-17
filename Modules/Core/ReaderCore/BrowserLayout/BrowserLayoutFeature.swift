import Foundation

/// EPUB layout selection. Normal reading uses BrowserAuto; tests can force a mode.
enum EPUBLayoutEngineMode: CustomStringConvertible {
    case legacy
    case browserAuto
    case browserForced

    var description: String {
        switch self {
        case .legacy: return "legacy"
        case .browserAuto: return "browserAuto"
        case .browserForced: return "browserForced"
        }
    }
}

/// Normal EPUB reading evaluates each chapter with BrowserAuto.
enum BrowserLayoutFeature {
    static let mode: EPUBLayoutEngineMode = .browserAuto
    #if DEBUG
    /// The `-browser-overlay` launch argument draws the DEBUG geometry probe. Launch arguments
    /// are fixed for the life of the process, so this is decided once, on first read.
    static let showDebugOverlay = ProcessInfo.processInfo.arguments.contains("-browser-overlay")
    #else
    static let showDebugOverlay = false
    #endif

    static let browserEnabled = true
}
