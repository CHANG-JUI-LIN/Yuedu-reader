import Foundation
import UIKit

public struct HTMLTableCell: Equatable, Sendable {
    let text: String
    let columnSpan: Int
    let rowSpan: Int
    let isHeader: Bool
    // ── Authored CSS, carried from the resolved style so the rasterizer reproduces the
    // book's table design (duokan character-info tables: dark header band, centered label
    // column, right-only column rules) instead of a generic grey grid. ──
    var alignment: NSTextAlignment = .natural
    var textColor: RenderColor? = nil
    var backgroundColor: RenderColor? = nil
    /// Cell font size relative to the table's font size (`td.a { font-size: 0.8em }` → 0.8).
    var fontScale: CGFloat = 1
    /// CSS width in points when declared (`td.a { width: 6em }`).
    var explicitWidth: CGFloat? = nil
    /// Per-side border widths — duokan tables separate columns with right-only rules.
    var borderTop: CGFloat = 0
    var borderLeft: CGFloat = 0
    var borderBottom: CGFloat = 0
    var borderRight: CGFloat = 0

    var hasAuthoredBorder: Bool {
        borderTop > 0 || borderLeft > 0 || borderBottom > 0 || borderRight > 0
    }
}

public struct HTMLTableRow: Equatable, Sendable {
    let cells: [HTMLTableCell]
}

public struct HTMLTableModel: Equatable, Sendable {
    let caption: String?
    let rows: [HTMLTableRow]
    /// Authored table border (`table { border: 1px solid #433624 }`).
    var borderWidth: CGFloat = 0
    var borderColor: RenderColor? = nil
    /// Authored table width as a % of the column (`table { width: 90% }`).
    var widthPercent: CGFloat? = nil

    var accessibilityText: String {
        let body = rows
            .map { row in
                row.cells.map(\.text).filter { !$0.isEmpty }.joined(separator: ", ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard let caption, !caption.isEmpty else { return body }
        return body.isEmpty ? caption : caption + "\n" + body
    }

    var columnCount: Int {
        rows
            .map { row in row.cells.reduce(0) { $0 + max(1, $1.columnSpan) } }
            .max() ?? 0
    }

    /// Any authored border on the table or its cells switches drawing from the generic
    /// full grid to the authored line work.
    var usesAuthoredBorders: Bool {
        borderWidth > 0 || rows.contains { row in row.cells.contains(where: \.hasAuthoredBorder) }
    }
}

extension HTMLTableModel {
    static func from(element: HTMLAttributedStringBuilder.ElementNode) -> HTMLTableModel? {
        guard element.tag == "table" else { return nil }
        let tableStyle = element.resolvedStyle
        let tableFontSize = max(1, tableStyle.fontSize)
        let caption = firstDescendantElement(in: element.children, tag: "caption")
            .map { normalizedText(from: $0) }
            .flatMap { $0.isEmpty ? nil : $0 }

        let rows = tableRows(in: element.children).compactMap { rowElement -> HTMLTableRow? in
            let cells = rowElement.children.compactMap { node -> HTMLTableCell? in
                guard case .element(let cellElement) = node,
                      cellElement.tag == "td" || cellElement.tag == "th"
                else { return nil }
                let cellStyle = cellElement.resolvedStyle
                var cell = HTMLTableCell(
                    text: normalizedText(from: cellElement),
                    columnSpan: positiveSpan(cellElement.attributes["colspan"]),
                    rowSpan: positiveSpan(cellElement.attributes["rowspan"]),
                    isHeader: cellElement.tag == "th"
                )
                cell.alignment = cellStyle.textAlign
                cell.textColor = cellStyle.hasCSSColor ? RenderColor(uiColor: cellStyle.textColor) : nil
                cell.backgroundColor = cellStyle.backgroundFillColor.map { RenderColor(uiColor: $0) }
                cell.fontScale = max(0.5, min(2, cellStyle.fontSize / tableFontSize))
                cell.explicitWidth = cellStyle.width
                cell.borderTop = cellStyle.borderTopWidth
                cell.borderLeft = cellStyle.borderLeftWidth
                cell.borderBottom = cellStyle.borderBottomWidth
                cell.borderRight = cellStyle.borderRightWidth
                return cell
            }
            return cells.isEmpty ? nil : HTMLTableRow(cells: cells)
        }

        guard !rows.isEmpty else { return nil }
        var model = HTMLTableModel(caption: caption, rows: rows)
        model.borderWidth = max(
            max(tableStyle.borderTopWidth, tableStyle.borderBottomWidth),
            max(tableStyle.borderLeftWidth, tableStyle.borderRightWidth)
        )
        model.borderColor = (
            tableStyle.borderTopColor
                ?? tableStyle.borderLeftColor
                ?? tableStyle.borderRightColor
                ?? tableStyle.borderBottomColor
        ).map { RenderColor(uiColor: $0) }
        model.widthPercent = tableStyle.rawWidthPercent
        return model
    }

    private static func tableRows(in nodes: [HTMLAttributedStringBuilder.ASTNode]) -> [HTMLAttributedStringBuilder.ElementNode] {
        var rows: [HTMLAttributedStringBuilder.ElementNode] = []
        for node in nodes {
            guard case .element(let element) = node else { continue }
            if element.tag == "tr" {
                rows.append(element)
            } else if element.tag != "table" {
                rows.append(contentsOf: tableRows(in: element.children))
            }
        }
        return rows
    }

    private static func firstDescendantElement(
        in nodes: [HTMLAttributedStringBuilder.ASTNode],
        tag: String
    ) -> HTMLAttributedStringBuilder.ElementNode? {
        for node in nodes {
            guard case .element(let element) = node else { continue }
            if element.tag == tag { return element }
            if let nested = firstDescendantElement(in: element.children, tag: tag) {
                return nested
            }
        }
        return nil
    }

    private static func normalizedText(from element: HTMLAttributedStringBuilder.ElementNode) -> String {
        normalizedText(from: element.children)
    }

    private static func normalizedText(from nodes: [HTMLAttributedStringBuilder.ASTNode]) -> String {
        let raw = nodes.map { node -> String in
            switch node {
            case .text(let text):
                return text.text
            case .lineBreak:
                return " "
            case .pageBreak:
                return ""
            case .element(let element):
                guard element.tag != "table" else { return "" }
                return normalizedText(from: element.children)
            }
        }.joined(separator: " ")
        return raw
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func positiveSpan(_ raw: String?) -> Int {
        guard let raw,
              let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return 1 }
        return min(max(value, 1), 20)
    }
}

enum HTMLTableRasterizer {
    @MainActor
    static func render(
        table: HTMLTableModel,
        maxWidth: CGFloat,
        baseFont: UIFont,
        textColor: UIColor,
        backgroundColor: UIColor
    ) -> UIImage? {
        let columns = max(1, table.columnCount)
        guard columns > 0, !table.rows.isEmpty else { return nil }

        // Honor the authored table width (`table { width: 90% }`); the placeholder centers it.
        let authoredFraction = table.widthPercent.map { max(0.3, min(1, $0 / 100)) }
        let width = max(120, min(maxWidth * (authoredFraction ?? 1), 900))
        let outerPadding: CGFloat = 8
        let cellPadding = CGSize(width: 8, height: 6)
        let hairline: CGFloat = 1 / max(UIScreen.main.scale, 1)
        let contentWidth = max(1, width - outerPadding * 2)

        func cellFont(_ cell: HTMLTableCell) -> UIFont {
            let size = max(9, baseFont.pointSize * cell.fontScale)
            return cell.isHeader
                ? UIFont.systemFont(ofSize: size, weight: .semibold)
                : baseFont.withSize(size)
        }

        let captionFont = UIFont.systemFont(ofSize: max(10, baseFont.pointSize * 0.88), weight: .medium)

        // Column widths follow content instead of a rigid 1/columns split: duokan tables pair a
        // short label column (`td.a` 姓名：, often with an authored `width: 6em`) with a long
        // prose column, and an even split starves the prose column. Width per column = its
        // authored width, else its widest single-line cell, floored for readability, then
        // scaled (or slack-fed to the widest column) to fill the table width.
        var naturalWidths = [CGFloat](repeating: 0, count: columns)
        for row in table.rows {
            var columnIndex = 0
            for cell in row.cells {
                let span = max(1, cell.columnSpan)
                defer { columnIndex += span }
                guard span == 1, columnIndex < columns else { continue }
                let demand: CGFloat
                if let explicit = cell.explicitWidth {
                    demand = explicit + cellPadding.width * 2
                } else {
                    demand = ceil(
                        (cell.text.isEmpty ? " " : cell.text)
                            .size(withAttributes: [.font: cellFont(cell)]).width
                    ) + cellPadding.width * 2
                }
                naturalWidths[columnIndex] = max(naturalWidths[columnIndex], demand)
            }
        }
        let minColumnWidth = min(contentWidth / CGFloat(columns), contentWidth * 0.18)
        var columnWidths = naturalWidths.map { max($0, minColumnWidth) }
        let naturalTotal = columnWidths.reduce(0, +)
        if naturalTotal <= contentWidth {
            // Everything fits on one line per cell; the widest (prose) column takes the slack.
            if let widest = columnWidths.indices.max(by: { columnWidths[$0] < columnWidths[$1] }) {
                columnWidths[widest] += contentWidth - naturalTotal
            }
        } else {
            // Shrink only the wide (prose) columns — they can wrap. Label columns at or below
            // the even share keep their natural width (`td.a 姓名：` must not fold in half).
            let fairShare = contentWidth / CGFloat(columns)
            let keptTotal = columnWidths.filter { $0 <= fairShare }.reduce(0, +)
            let wideTotal = columnWidths.filter { $0 > fairShare }.reduce(0, +)
            let available = max(0, contentWidth - keptTotal)
            if wideTotal > 0, available > 0 {
                columnWidths = columnWidths.map { columnWidth in
                    columnWidth <= fairShare
                        ? columnWidth
                        : max(minColumnWidth, columnWidth / wideTotal * available)
                }
            }
            // Normalize rounding/floor drift so the grid exactly fills the table width.
            let total = columnWidths.reduce(0, +)
            if total > 0, abs(total - contentWidth) > 0.5 {
                let scale = contentWidth / total
                columnWidths = columnWidths.map { $0 * scale }
            }
        }

        func spannedWidth(fromColumn columnIndex: Int, span: Int) -> CGFloat {
            let upper = min(columns, columnIndex + max(1, span))
            guard columnIndex < upper else { return columnWidths.last ?? contentWidth }
            return columnWidths[columnIndex..<upper].reduce(0, +)
        }

        let captionHeight: CGFloat = {
            guard let caption = table.caption, !caption.isEmpty else { return 0 }
            return measuredHeight(
                text: caption,
                font: captionFont,
                width: contentWidth - cellPadding.width * 2
            ) + cellPadding.height * 2
        }()

        var rowHeights: [CGFloat] = []
        for row in table.rows {
            var maxCellHeight: CGFloat = 0
            var columnIndex = 0
            for cell in row.cells {
                let span = max(1, cell.columnSpan)
                let spanWidth = spannedWidth(fromColumn: columnIndex, span: span)
                columnIndex += span
                let measured = measuredHeight(
                    text: cell.text.isEmpty ? " " : cell.text,
                    font: cellFont(cell),
                    width: max(1, spanWidth - cellPadding.width * 2)
                )
                maxCellHeight = max(maxCellHeight, measured + cellPadding.height * 2)
            }
            rowHeights.append(max(30, ceil(maxCellHeight)))
        }

        let tableHeight = rowHeights.reduce(0, +)
        let height = min(max(44, outerPadding * 2 + captionHeight + tableHeight), maxWidth * 1.75)
        let visibleRows = rowsFitting(rowHeights: rowHeights, availableHeight: max(0, height - outerPadding * 2 - captionHeight))
        AppLogger.render("⟐ table", context: [
            "size": "\(Int(width))x\(Int(height))",
            "cols": columnWidths.map { Int($0) }.description,
            "rows": rowHeights.map { Int($0) }.description,
            "visible": "\(visibleRows)/\(table.rows.count)",
            "authored": table.usesAuthoredBorders,
        ])

        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            let bounds = CGRect(origin: .zero, size: CGSize(width: width, height: height))
            backgroundColor.setFill()
            context.fill(bounds)

            let gridColor = UIColor.separator.resolvedColor(with: UITraitCollection.current)
            let authoredLineColor = table.borderColor?.uiColor ?? gridColor
            let headerFill = textColor.withAlphaComponent(0.08)
            let captionColor = textColor.withAlphaComponent(0.75)
            let usesAuthoredBorders = table.usesAuthoredBorders

            func strokeLine(from: CGPoint, to: CGPoint, lineWidth: CGFloat) {
                authoredLineColor.setStroke()
                context.cgContext.setLineWidth(lineWidth)
                context.cgContext.move(to: from)
                context.cgContext.addLine(to: to)
                context.cgContext.strokePath()
            }

            var cursorY = outerPadding
            if let caption = table.caption, !caption.isEmpty, captionHeight > 0 {
                drawText(
                    caption,
                    in: CGRect(
                        x: outerPadding + cellPadding.width,
                        y: cursorY + cellPadding.height,
                        width: contentWidth - cellPadding.width * 2,
                        height: captionHeight - cellPadding.height * 2
                    ),
                    font: captionFont,
                    color: captionColor,
                    alignment: .center
                )
                cursorY += captionHeight
            }
            let tableTop = cursorY

            for rowIndex in 0..<visibleRows {
                let row = table.rows[rowIndex]
                let rowHeight = rowHeights[rowIndex]
                var cursorX = outerPadding
                var columnIndex = 0
                for cell in row.cells {
                    let span = max(1, cell.columnSpan)
                    let cellWidth = min(
                        width - outerPadding - cursorX,
                        spannedWidth(fromColumn: columnIndex, span: span)
                    )
                    columnIndex += span
                    let rect = CGRect(x: cursorX, y: cursorY, width: cellWidth, height: rowHeight)

                    if let fill = cell.backgroundColor?.uiColor {
                        fill.setFill()
                        context.fill(rect)
                    } else if cell.isHeader, !usesAuthoredBorders {
                        headerFill.setFill()
                        context.fill(rect)
                    }

                    if usesAuthoredBorders {
                        // Authored line work only (duokan: `td { border-width: 0 1px 0 0 }`
                        // draws just the column rule; the header band has no borders at all).
                        if cell.borderTop > 0 {
                            strokeLine(from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.minY), lineWidth: cell.borderTop)
                        }
                        if cell.borderBottom > 0 {
                            strokeLine(from: CGPoint(x: rect.minX, y: rect.maxY), to: CGPoint(x: rect.maxX, y: rect.maxY), lineWidth: cell.borderBottom)
                        }
                        if cell.borderLeft > 0 {
                            strokeLine(from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.minX, y: rect.maxY), lineWidth: cell.borderLeft)
                        }
                        if cell.borderRight > 0, rect.maxX < width - outerPadding - 0.5 {
                            // Skip the rule on the table's right edge — the outer border owns it.
                            strokeLine(from: CGPoint(x: rect.maxX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY), lineWidth: cell.borderRight)
                        }
                    } else {
                        gridColor.setStroke()
                        context.cgContext.setLineWidth(hairline)
                        context.cgContext.stroke(rect)
                    }

                    let resolvedAlignment: NSTextAlignment = {
                        if cell.alignment != .natural && cell.alignment != .justified { return cell.alignment }
                        return cell.isHeader ? .center : .natural
                    }()
                    drawText(
                        cell.text,
                        in: rect.insetBy(dx: cellPadding.width, dy: cellPadding.height),
                        font: cellFont(cell),
                        color: cell.textColor?.uiColor ?? textColor,
                        alignment: resolvedAlignment
                    )
                    cursorX += cellWidth
                }
                cursorY += rowHeight
            }

            if usesAuthoredBorders, table.borderWidth > 0 {
                authoredLineColor.setStroke()
                context.cgContext.setLineWidth(table.borderWidth)
                context.cgContext.stroke(CGRect(
                    x: outerPadding,
                    y: tableTop,
                    width: contentWidth,
                    height: cursorY - tableTop
                ))
            }

            if visibleRows < table.rows.count {
                let notice = "…"
                drawText(
                    notice,
                    in: CGRect(x: outerPadding, y: height - 22, width: contentWidth, height: 16),
                    font: captionFont,
                    color: captionColor,
                    alignment: .center
                )
            }
        }
    }

    private static func rowsFitting(rowHeights: [CGFloat], availableHeight: CGFloat) -> Int {
        var used: CGFloat = 0
        var count = 0
        for height in rowHeights {
            guard used + height <= availableHeight else { break }
            used += height
            count += 1
        }
        return max(1, min(count, rowHeights.count))
    }

    private static func measuredHeight(text: String, font: UIFont, width: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: font,
                .paragraphStyle: paragraph,
            ],
            context: nil
        )
        return ceil(rect.height)
    }

    private static func drawText(
        _ text: String,
        in rect: CGRect,
        font: UIFont,
        color: UIColor,
        alignment: NSTextAlignment
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        // Must match measuredHeight's wrapping mode: with a truncating lineBreakMode,
        // NSStringDrawing lays out a SINGLE line — cells sized for wrapped text then drew
        // one truncated line ("被压缩" duokan character-info tables). `.truncatesLastVisibleLine`
        // still ellipsizes the final line if the rect genuinely runs out of height.
        paragraph.lineBreakMode = .byWordWrapping
        (text as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ],
            context: nil
        )
    }
}
