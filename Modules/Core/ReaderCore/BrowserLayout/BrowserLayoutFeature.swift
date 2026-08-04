import Foundation

/// Debug engine modes for the browser-layout engine. Release builds are
/// compiled to `.legacy` — the mode cannot change at runtime in release.
/// No user-facing setting exists; these are developer diagnostics only.
enum EPUBLayoutEngineMode {
    case legacy
    case browserAuto
    case browserForced
}

/// Phase-2A feature gate for the browser-style box layout engine.
///
/// Release is ALWAYS `.legacy` (the `#else` branch); only DEBUG builds can
/// switch engines. The legacy `CoreTextPaginator` pipeline stays the only
/// release reader path.
enum BrowserLayoutFeature {
    #if DEBUG
    static var mode: EPUBLayoutEngineMode = .legacy
    /// When true, the reader shows a small per-chapter engine badge
    /// (`[browser]` / `[legacy: reason]`). DEBUG-only.
    static var showDebugOverlay = false
    #else
    static let mode: EPUBLayoutEngineMode = .legacy
    static let showDebugOverlay = false
    #endif

    /// Whether the browser engine is permitted to run at all.
    static var browserEnabled: Bool {
        mode == .browserAuto || mode == .browserForced
    }
}
