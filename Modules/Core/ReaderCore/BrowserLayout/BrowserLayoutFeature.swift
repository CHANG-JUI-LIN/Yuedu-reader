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
/// `.legacy` is the shipping mode: EVERY EPUB chapter renders through
/// `CoreTextPageEngine`, and the browser engine is never constructed (see
/// `EPUBPageRenderer.load`). The browser engine is feature-incomplete — it was
/// switched off on 2026-08-17 and stays off until the gaps are finished. The
/// engine sources and their tests are kept in the tree so development can
/// continue; do not treat them as live rendering code.
///
/// To exercise the browser engine during development, launch a DEBUG build with
/// `-browser-mode browserAuto` (or `browserForced`); see `yuedu_appApp.init`.
/// Tests must pass `mode:` explicitly to `BrowserLayoutPageEngine.init` rather
/// than rely on this default, which is now `.legacy`.
///
/// When the engine is re-enabled, `.browserAuto` is the mode to ship: the
/// browser engine renders a chapter only when `BrowserLayoutCapabilityScanner`
/// says every layout feature the chapter uses is implemented, and ANY other
/// outcome — an unsupported property, a resource failure, a layout error, a
/// timeout — hands that WHOLE chapter to the legacy `CoreTextPageEngine`. The
/// fallback is per chapter and atomic: a chapter never renders half in each
/// engine.
///
/// Three things stay legacy regardless of this gate, because the browser engine
/// has no implementation for them yet: vertical-rl writing mode, pre-paginated
/// (fixed-layout) publications, and scroll mode — `CoreTextScrollEngine` is the
/// only `ScrollReaderEngine`.
///
/// `.browserForced` is a DEBUG diagnostic only: it refuses to fall back, so an
/// unsupported chapter shows the engine's own diagnostic page instead of
/// silently rendering correctly via legacy and hiding the gap.
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
