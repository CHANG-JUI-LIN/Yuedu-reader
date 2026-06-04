import Foundation
import UIKit

public struct HTMLTableCell: Equatable, Sendable {
    let text: String
    let columnSpan: Int
    let rowSpan: Int
    let isHeader: Bool
}

public struct HTMLTableRow: Equatable, Sendable {
    let cells: [HTMLTableCell]
}

public struct HTMLTableModel: Equatable, Sendable {
    let caption: String?
    let rows: [HTMLTableRow]

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
}

extension HTMLTableModel {
    static func from(element: HTMLAttributedStringBuilder.ElementNode) -> HTMLTableModel? {
        guard element.tag == "table" else { return nil }
        let caption = firstDescendantElement(in: element.children, tag: "caption")
            .map { normalizedText(from: $0) }
            .flatMap { $0.isEmpty ? nil : $0 }

        let rows = tableRows(in: element.children).compactMap { rowElement -> HTMLTableRow? in
            let cells = rowElement.children.compactMap { node -> HTMLTableCell? in
                guard case .element(let cellElement) = node,
                      cellElement.tag == "td" || cellElement.tag == "th"
                else { return nil }
                let text = normalizedText(from: cellElement)
                return HTMLTableCell(
                    text: text,
                    columnSpan: positiveSpan(cellElement.attributes["colspan"]),
                    rowSpan: positiveSpan(cellElement.attributes["rowspan"]),
                    isHeader: cellElement.tag == "th"
                )
            }
            return cells.isEmpty ? nil : HTMLTableRow(cells: cells)
        }

        guard !rows.isEmpty else { return nil }
        return HTMLTableModel(caption: caption, rows: rows)
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

        let width = max(120, min(maxWidth, 900))
        let outerPadding: CGFloat = 8
        let cellPadding = CGSize(width: 8, height: 6)
        let borderWidth: CGFloat = 1 / max(UIScreen.main.scale, 1)
        let contentWidth = max(1, width - outerPadding * 2)
        let columnWidth = contentWidth / CGFloat(columns)

        let bodyFont = baseFont
        let headerFont = UIFont.systemFont(ofSize: max(10, baseFont.pointSize * 0.92), weight: .semibold)
        let captionFont = UIFont.systemFont(ofSize: max(10, baseFont.pointSize * 0.88), weight: .medium)

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
            for cell in row.cells {
                let spanWidth = max(columnWidth, columnWidth * CGFloat(max(1, cell.columnSpan)))
                let font = cell.isHeader ? headerFont : bodyFont
                let measured = measuredHeight(
                    text: cell.text.isEmpty ? " " : cell.text,
                    font: font,
                    width: max(1, spanWidth - cellPadding.width * 2)
                )
                maxCellHeight = max(maxCellHeight, measured + cellPadding.height * 2)
            }
            rowHeights.append(max(30, ceil(maxCellHeight)))
        }

        let tableHeight = rowHeights.reduce(0, +)
        let height = min(max(44, outerPadding * 2 + captionHeight + tableHeight), maxWidth * 1.75)
        let visibleRows = rowsFitting(rowHeights: rowHeights, availableHeight: max(0, height - outerPadding * 2 - captionHeight))

        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            let bounds = CGRect(origin: .zero, size: CGSize(width: width, height: height))
            backgroundColor.setFill()
            context.fill(bounds)

            let gridColor = UIColor.separator.resolvedColor(with: UITraitCollection.current)
            let headerFill = textColor.withAlphaComponent(0.08)
            let captionColor = textColor.withAlphaComponent(0.75)

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

            for rowIndex in 0..<visibleRows {
                let row = table.rows[rowIndex]
                let rowHeight = rowHeights[rowIndex]
                var cursorX = outerPadding
                for cell in row.cells {
                    let span = max(1, cell.columnSpan)
                    let cellWidth = min(width - outerPadding - cursorX, columnWidth * CGFloat(span))
                    let rect = CGRect(x: cursorX, y: cursorY, width: cellWidth, height: rowHeight)
                    if cell.isHeader {
                        headerFill.setFill()
                        context.fill(rect)
                    }
                    gridColor.setStroke()
                    context.cgContext.setLineWidth(borderWidth)
                    context.cgContext.stroke(rect)
                    drawText(
                        cell.text,
                        in: rect.insetBy(dx: cellPadding.width, dy: cellPadding.height),
                        font: cell.isHeader ? headerFont : bodyFont,
                        color: textColor,
                        alignment: cell.isHeader ? .center : .natural
                    )
                    cursorX += cellWidth
                }
                cursorY += rowHeight
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
        paragraph.lineBreakMode = .byTruncatingTail
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
