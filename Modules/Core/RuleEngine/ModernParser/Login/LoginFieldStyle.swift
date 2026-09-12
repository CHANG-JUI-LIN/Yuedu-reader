// Layout hints for a login form row, mirroring the `style` object of Legado's `RowUi`.
//
// Two generations of the field exist in the wild and both have to resolve onto the same
// 12-column grid (see `LoginGridPacker`):
//
// - New (legado-upstream, the author's current rule spec): `cols` 1–4 — 1=full row,
//   2=half, 3=third, 4=quarter. `rows` spans vertically. `layout_flexBasisPercent` is
//   still parsed as a fallback; `layout_flexGrow / layout_flexShrink / layout_alignSelf /
//   layout_wrapBefore` are documented as no longer effective there.
// - Legacy (legado-E / legado-md3, Android Flexbox): `layout_flexGrow`,
//   `layout_flexBasisPercent`, `layout_wrapBefore`, `layout_justifySelf`. Those sources
//   are still imported by users, so the attributes are approximated onto the grid
//   rather than dropped: a positive `flexGrow` resolves to half width, matching the
//   MD3 fork's `calculateFlexRows` (`flexGrow > 0f -> span 3` of 6), and `wrapBefore`
//   forces a new row.

import Foundation

/// A login form row's raw `style` object, parsed leniently — malformed properties are
/// ignored individually (scalar values are accepted as strings or numbers, as in
/// `ModernParserBridge.DiscoverItem.style`).
struct LoginFieldStyle: Equatable {
    /// Items per row, 1...4. Clamped when it exceeds the supported range.
    var cols: Int?
    /// Vertical span in grid rows.
    var rows: Int?
    /// Legacy Flexbox basis, 0...1; `-1` means unset in Legado-authored sources.
    var basisPercent: Double?
    /// Legacy Flexbox grow factor.
    var flexGrow: Double?
    /// Legacy: start a new row before this item.
    var wrapBefore: Bool
    /// Legacy alignment inside the cell: `flex_start` / `center` / `flex_end` / `right`.
    var justifySelf: String?

    init(
        cols: Int? = nil,
        rows: Int? = nil,
        basisPercent: Double? = nil,
        flexGrow: Double? = nil,
        wrapBefore: Bool = false,
        justifySelf: String? = nil
    ) {
        self.cols = cols
        self.rows = rows
        self.basisPercent = basisPercent
        self.flexGrow = flexGrow
        self.wrapBefore = wrapBefore
        self.justifySelf = justifySelf
    }

    /// Returns `nil` when the value is not a style object or carries no usable property,
    /// so an unusable `style` behaves exactly like an absent one.
    static func parse(_ raw: Any?) -> LoginFieldStyle? {
        guard let dict = raw as? [String: Any] else { return nil }
        let style = LoginFieldStyle(
            cols: intValue(dict["cols"]),
            rows: intValue(dict["rows"]),
            basisPercent: doubleValue(dict["layout_flexBasisPercent"]),
            flexGrow: doubleValue(dict["layout_flexGrow"]),
            wrapBefore: boolValue(dict["layout_wrapBefore"]) ?? false,
            justifySelf: stringValue(dict["layout_justifySelf"])
        )
        return style.isEmpty ? nil : style
    }

    private var isEmpty: Bool {
        cols == nil && rows == nil && basisPercent == nil && flexGrow == nil
            && !wrapBefore && justifySelf == nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.intValue
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.doubleValue
        case let string as String:
            return Double(string.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            switch string.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}

// MARK: - Grid spec

/// One login row resolved onto the 12-column grid.
struct LoginGridSpec: Equatable {
    /// 1...12 columns wide.
    var colSpan: Int
    /// 1 or more rows tall.
    var rowSpan: Int
    /// Force a new grid row before this item.
    var wrapBefore: Bool

    /// Legado's grid base — 12 is the least common multiple of 1/2/3/4 columns.
    static let columnCount = 12
}

extension LoginField {
    /// Accessibility text sizes get the full line without changing the source data.
    func gridSpec(accessibilityLayout: Bool) -> LoginGridSpec {
        guard accessibilityLayout else { return gridSpec }
        return LoginGridSpec(colSpan: LoginGridSpec.columnCount, rowSpan: 1, wrapBefore: true)
    }

    /// Resolve this row's `style` onto the grid.
    ///
    /// Priority matches upstream's `FlexChildStyle.resolveCols`: `cols` first, then the
    /// legacy `layout_flexBasisPercent`, then (legacy approximation) a positive
    /// `layout_flexGrow` as half width. Without any style, text/password rows are full
    /// width and every other row takes half — Legado's login UI defaults.
    var gridSpec: LoginGridSpec {
        let resolvedCols: Int
        if let cols = style?.cols {
            resolvedCols = min(max(cols, 1), 4)
        } else if let basis = style?.basisPercent, basis > 0 {
            // 1.001f tolerates float imprecision on 1/3-style values, as upstream does.
            resolvedCols = min(max(Int(1.001 / basis), 1), 4)
        } else if let grow = style?.flexGrow, grow > 0 {
            resolvedCols = 2
        } else {
            resolvedCols = (type == .text || type == .password) ? 1 : 2
        }
        let percentForcesRow = (style?.basisPercent ?? 0) >= 1
        return LoginGridSpec(
            colSpan: LoginGridSpec.columnCount / resolvedCols,
            rowSpan: max(style?.rows ?? 1, 1),
            wrapBefore: (style?.wrapBefore ?? false) || percentForcesRow
        )
    }
}

// MARK: - Packing

/// A placed cell: top-left grid position plus its span.
struct LoginGridCell: Equatable {
    let row: Int
    let column: Int
    let rowSpan: Int
    let colSpan: Int
}

/// Packs resolved specs into cells the way Android's `GridLayout` does — first come,
/// first placed, cursor only moves forward. A port of Legado-upstream's `packGridCells`
/// (`GridPackLayout.kt`) with the legacy `wrapBefore` row break added.
enum LoginGridPacker {
    static func pack(
        specs: [LoginGridSpec],
        columnCount: Int = LoginGridSpec.columnCount
    ) -> [LoginGridCell] {
        // highWater[c]: the first free row in column c.
        var highWater = [Int](repeating: 0, count: columnCount)
        var row = 0
        var column = 0
        return specs.map { spec in
            let colSpan = min(max(spec.colSpan, 1), columnCount)
            let rowSpan = max(spec.rowSpan, 1)
            if spec.wrapBefore, column > 0 {
                row += 1
                column = 0
            }
            while !fits(highWater, row: row, start: column, end: column + colSpan) {
                column += 1
                if column + colSpan > columnCount {
                    column = 0
                    row += 1
                }
            }
            let cell = LoginGridCell(
                row: row, column: column, rowSpan: rowSpan, colSpan: colSpan
            )
            if column < columnCount {
                for index in column..<min(column + colSpan, columnCount) {
                    highWater[index] = row + rowSpan
                }
            }
            column += colSpan
            return cell
        }
    }

    private static func fits(_ highWater: [Int], row: Int, start: Int, end: Int) -> Bool {
        guard end <= highWater.count else { return false }
        for column in start..<end where highWater[column] > row {
            return false
        }
        return true
    }
}
