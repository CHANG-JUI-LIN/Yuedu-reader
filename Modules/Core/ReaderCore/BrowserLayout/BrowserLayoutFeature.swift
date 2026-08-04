import Foundation

/// Phase-1 feature gate for the browser-style box layout engine.
///
/// Default `false` keeps the legacy `CoreTextPaginator` pipeline as the only
/// reader path. This flag exists so integration work later can switch a
/// chapter to the new engine without touching the legacy renderer.
enum BrowserLayoutFeature {
    static var isEnabled = false
}