import Foundation

/// Modes retained for explicit browser-engine regression tests.
/// Production EPUB routing uses Legacy. Simulator interaction acceptance can
/// explicitly inject BrowserAuto without changing this rollout policy.
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

/// EPUB browser rollout is disabled until pagination and rendering parity are
/// verified. Production routing in EPUBPageRenderer uses legacy directly;
/// browser tests opt in by passing a mode to BrowserLayoutPageEngine.init.
enum BrowserLayoutFeature {
    static let mode: EPUBLayoutEngineMode = .legacy
    #if DEBUG
    static var showDebugOverlay = false
    #else
    static let showDebugOverlay = false
    #endif

    static let browserEnabled = false
}
