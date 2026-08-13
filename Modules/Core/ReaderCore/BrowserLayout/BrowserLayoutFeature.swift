import Foundation

/// Debug engine modes for the browser-layout engine. Release builds are
/// compiled to `.legacy` — the mode cannot change at runtime in release.
/// No user-facing setting exists; these are developer diagnostics only.
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

/// Feature gate for the browser-style box layout engine.
///
/// `.browserAuto` is the shipping mode: the browser engine renders a chapter
/// only when `BrowserLayoutCapabilityScanner` says every layout feature the
/// chapter uses is implemented, and ANY other outcome — an unsupported
/// property, a resource failure, a layout error, a timeout — hands that WHOLE
/// chapter to the legacy `CoreTextPageEngine`. The fallback is per chapter and
/// atomic: a chapter never renders half in each engine.
///
/// Three things stay legacy regardless of this gate, because the browser engine
/// has no implementation for them yet (see `EPUBPageRenderer.load`):
/// vertical-rl writing mode, pre-paginated (fixed-layout) publications, and
/// scroll mode — `CoreTextScrollEngine` is the only `ScrollReaderEngine`.
///
/// `.browserForced` is a DEBUG diagnostic only: it refuses to fall back, so an
/// unsupported chapter shows the engine's own diagnostic page instead of
/// silently rendering correctly via legacy and hiding the gap.
enum BrowserLayoutFeature {
    #if DEBUG
    static var mode: EPUBLayoutEngineMode = .browserAuto
    /// When true, the reader shows a small per-chapter engine badge
    /// (`[browser]` / `[legacy: reason]`). DEBUG-only.
    static var showDebugOverlay = false
    #else
    static let mode: EPUBLayoutEngineMode = .browserAuto
    static let showDebugOverlay = false
    #endif

    /// Whether the browser engine is permitted to run at all.
    static var browserEnabled: Bool {
        mode == .browserAuto || mode == .browserForced
    }
}
