import Foundation

/// CSS logical properties for the legacy engine.
///
/// Legacy lays a vertical chapter out as horizontal lines turned on their side, so its
/// own fields are already logical in both writing modes: `marginLeft` becomes the head
/// indent, the inline start, and `margin-top` paragraph spacing before, the block start.
/// A logical declaration therefore maps to the same legacy key in either writing mode.
/// BrowserAuto, which keeps physical properties physical, maps by writing mode instead
/// (YueduCoreText `LogicalGeometry.physicalProperty`); both read a logical stylesheet
/// the same way.
enum LegacyLogicalProperties {
    static let legacyKey: [String: String] = [
        "margin-inline-start": "margin-left",
        "margin-inline-end": "margin-right",
        "margin-block-start": "margin-top",
        "margin-block-end": "margin-bottom",
        "padding-inline-start": "padding-left",
        "padding-inline-end": "padding-right",
        "padding-block-start": "padding-top",
        "padding-block-end": "padding-bottom",
        "inline-size": "width",
    ]

    /// `declarations` with every logical property renamed to its legacy key. `order` is
    /// the block's source order: where a logical and a physical declaration name the same
    /// side, the later one wins, as CSS has it. `max-inline-size` keeps its name (legacy
    /// reads it as a line length limit); `min-inline-size` is dropped, as legacy has no
    /// minimum line length, nor any `min-width`.
    static func resolved(_ declarations: [String: String], order: [String]) -> [String: String] {
        guard declarations.keys.contains(where: { legacyKey[$0] != nil || $0 == "min-inline-size" }) else {
            return declarations
        }
        var result: [String: String] = [:]
        var seen: Set<String> = []
        // `order` lists every property of the block, normal and !important alike; the
        // dictionary holds one band of them. Anything it lacks from `order` keeps its place.
        for key in order + declarations.keys.sorted() where seen.insert(key).inserted {
            guard let value = declarations[key], key != "min-inline-size" else { continue }
            result[legacyKey[key] ?? key] = value
        }
        return result
    }
}
