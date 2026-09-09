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
    static var showDebugOverlay = false
    #else
    static let showDebugOverlay = false
    #endif

    static let browserEnabled = true
}
