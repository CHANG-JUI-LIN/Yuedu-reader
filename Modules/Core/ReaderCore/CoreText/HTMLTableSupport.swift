import Foundation
import UIKit

public struct HTMLTableTextRun: Equatable, Sendable {
    let text: String
    let fontScale: CGFloat
    let fontFamilies: [String]
    let fontWeight: Int
    let isItalic: Bool
    let textColor: RenderColor?
    let linkHref: String?
    let imageSource: String?
    let imageAlt: String?
    let imageWidth: CGFloat?
    let imageHeight: CGFloat?
}

public enum HTMLTableCellVerticalAlignment: Equatable, Sendable {
    case top
    case middle
    case bottom
}

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
    var fontFamilies: [String] = []
    var fontWeight: Int = 400
    var isItalic: Bool = false
    var verticalAlignment: HTMLTableCellVerticalAlignment = .top
    var paddingTop: CGFloat = 0
    var paddingLeft: CGFloat = 0
    var paddingBottom: CGFloat = 0
    var paddingRight: CGFloat = 0
    var lineHeight: CGFloat? = nil
    /// Styled inline runs inside the cell. This preserves nested spans (dates, emphasis, custom
    /// fonts) instead of flattening the complete cell to one color and font.
    var textRuns: [HTMLTableTextRun] = []
    /// CSS width in points when declared (`td.a { width: 6em }`).
    var explicitWidth: CGFloat? = nil
    /// Per-side border widths — duokan tables separate columns with right-only rules.
    var borderTop: CGFloat = 0
    var borderLeft: CGFloat = 0
    var borderBottom: CGFloat = 0
    var borderRight: CGFloat = 0
    var borderTopColor: RenderColor? = nil
    var borderLeftColor: RenderColor? = nil
    var borderBottomColor: RenderColor? = nil
    var borderRightColor: RenderColor? = nil

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
    var borderTop: CGFloat = 0
    var borderLeft: CGFloat = 0
    var borderBottom: CGFloat = 0
    var borderRight: CGFloat = 0
    var borderTopColor: RenderColor? = nil
    var borderLeftColor: RenderColor? = nil
    var borderBottomColor: RenderColor? = nil
    var borderRightColor: RenderColor? = nil
    /// CSS table backgrounds are authored; absent means transparent, not reader-theme colored.
    var backgroundColor: RenderColor? = nil
    /// Authored table width as a % of the column (`table { width: 90% }`).
    var widthPercent: CGFloat? = nil
    /// Authored absolute/relative width after CSS length resolution. Percentages use widthPercent.
    var explicitWidth: CGFloat? = nil

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

    /// Whether the table supplies any line work. Borderless author layouts remain borderless.
    var usesAuthoredBorders: Bool {
        borderTop > 0 || borderLeft > 0 || borderBottom > 0 || borderRight > 0
            || borderWidth > 0
            || rows.contains { row in row.cells.contains(where: \.hasAuthoredBorder) }
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
                cell.backgroundColor = cellStyle.backgroundFillColor.flatMap { RenderColor(uiColor: $0) }
                cell.fontScale = max(0.5, min(2, cellStyle.fontSize / tableFontSize))
                cell.fontFamilies = cellStyle.fontFamilies
                cell.fontWeight = cellStyle.fontWeight
                cell.isItalic = cellStyle.isItalic
                switch cellStyle.verticalAlign {
                case .middle:
                    cell.verticalAlignment = .middle
                case .bottom, .sub:
                    cell.verticalAlignment = .bottom
                case .baseline, .super, .top:
                    cell.verticalAlignment = .top
                }
                cell.paddingTop = cellStyle.paddingTop
                cell.paddingLeft = cellStyle.paddingLeft
                cell.paddingBottom = cellStyle.paddingBottom
                cell.paddingRight = cellStyle.paddingRight
                cell.lineHeight = cellStyle.lineHeight > 0 ? cellStyle.lineHeight : nil
                cell.textRuns = textRuns(from: cellElement, tableFontSize: tableFontSize)
                cell.explicitWidth = cellStyle.width
                cell.borderTop = cellStyle.borderTopWidth
                cell.borderLeft = cellStyle.borderLeftWidth
                cell.borderBottom = cellStyle.borderBottomWidth
                cell.borderRight = cellStyle.borderRightWidth
                cell.borderTopColor = cellStyle.borderTopColor.flatMap { RenderColor(uiColor: $0) }
                cell.borderLeftColor = cellStyle.borderLeftColor.flatMap { RenderColor(uiColor: $0) }
                cell.borderBottomColor = cellStyle.borderBottomColor.flatMap { RenderColor(uiColor: $0) }
                cell.borderRightColor = cellStyle.borderRightColor.flatMap { RenderColor(uiColor: $0) }
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
        ).flatMap { RenderColor(uiColor: $0) }
        model.borderTop = tableStyle.borderTopWidth
        model.borderLeft = tableStyle.borderLeftWidth
        model.borderBottom = tableStyle.borderBottomWidth
        model.borderRight = tableStyle.borderRightWidth
        model.borderTopColor = tableStyle.borderTopColor.flatMap { RenderColor(uiColor: $0) }
        model.borderLeftColor = tableStyle.borderLeftColor.flatMap { RenderColor(uiColor: $0) }
        model.borderBottomColor = tableStyle.borderBottomColor.flatMap { RenderColor(uiColor: $0) }
        model.borderRightColor = tableStyle.borderRightColor.flatMap { RenderColor(uiColor: $0) }
        model.backgroundColor = tableStyle.backgroundFillColor.flatMap { RenderColor(uiColor: $0) }
        model.widthPercent = tableStyle.rawWidthPercent
        model.explicitWidth = tableStyle.width
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

    private static func textRuns(
        from element: HTMLAttributedStringBuilder.ElementNode,
        tableFontSize: CGFloat
    ) -> [HTMLTableTextRun] {
        var runs = textRuns(
            from: element.children,
            inheritedStyle: element.resolvedStyle,
            inheritedLinkHref: nil,
            tableFontSize: tableFontSize
        ).filter { !$0.text.isEmpty || $0.imageSource != nil }
        guard !runs.isEmpty else { return [] }

        runs[0] = replacingText(
            in: runs[0],
            with: runs[0].text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let last = runs.count - 1
        runs[last] = replacingText(
            in: runs[last],
            with: runs[last].text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return runs.filter { !$0.text.isEmpty || $0.imageSource != nil }
    }

    private static func textRuns(
        from nodes: [HTMLAttributedStringBuilder.ASTNode],
        inheritedStyle: HTMLAttributedStringBuilder.ResolvedStyle,
        inheritedLinkHref: String?,
        tableFontSize: CGFloat
    ) -> [HTMLTableTextRun] {
        nodes.flatMap { node -> [HTMLTableTextRun] in
            switch node {
            case .text(let text):
                let normalized = text.text.replacingOccurrences(
                    of: #"[\t\r\n ]+"#,
                    with: " ",
                    options: .regularExpression
                )
                return [makeTextRun(
                    normalized,
                    style: inheritedStyle,
                    linkHref: inheritedLinkHref,
                    tableFontSize: tableFontSize
                )]
            case .lineBreak(let lineBreak):
                return [makeTextRun(
                    "\n",
                    style: lineBreak.resolvedStyle,
                    linkHref: inheritedLinkHref,
                    tableFontSize: tableFontSize
                )]
            case .pageBreak:
                return []
            case .element(let child):
                if child.tag == "a",
                   child.classes.contains("duokan-footnote"),
                   let image = firstImage(in: child.children) {
                    return [makeImageRun(
                        from: image,
                        fallbackText: "◦",
                        linkHref: child.attributes["href"] ?? inheritedLinkHref,
                        tableFontSize: tableFontSize
                    )]
                }
                guard child.tag != "table" else { return [] }
                if child.tag == "img" || child.tag == "image" {
                    return [makeImageRun(
                        from: child,
                        fallbackText: "",
                        linkHref: inheritedLinkHref,
                        tableFontSize: tableFontSize
                    )]
                }
                return textRuns(
                    from: child.children,
                    inheritedStyle: child.resolvedStyle,
                    inheritedLinkHref: child.tag == "a"
                        ? (child.attributes["href"] ?? inheritedLinkHref)
                        : inheritedLinkHref,
                    tableFontSize: tableFontSize
                )
            }
        }
    }

    private static func firstImage(
        in nodes: [HTMLAttributedStringBuilder.ASTNode]
    ) -> HTMLAttributedStringBuilder.ElementNode? {
        for node in nodes {
            guard case .element(let element) = node else { continue }
            if element.tag == "img" || element.tag == "image" { return element }
            if let nested = firstImage(in: element.children) { return nested }
        }
        return nil
    }

    private static func makeTextRun(
        _ text: String,
        style: HTMLAttributedStringBuilder.ResolvedStyle,
        linkHref: String?,
        tableFontSize: CGFloat
    ) -> HTMLTableTextRun {
        HTMLTableTextRun(
            text: text,
            fontScale: max(0.5, min(2, style.fontSize / max(tableFontSize, 1))),
            fontFamilies: style.fontFamilies,
            fontWeight: style.fontWeight,
            isItalic: style.isItalic,
            textColor: style.hasCSSColor ? RenderColor(uiColor: style.textColor) : nil,
            linkHref: linkHref,
            imageSource: nil,
            imageAlt: nil,
            imageWidth: nil,
            imageHeight: nil
        )
    }

    private static func makeImageRun(
        from element: HTMLAttributedStringBuilder.ElementNode,
        fallbackText: String,
        linkHref: String?,
        tableFontSize: CGFloat
    ) -> HTMLTableTextRun {
        let style = element.resolvedStyle
        return HTMLTableTextRun(
            text: fallbackText,
            fontScale: max(0.5, min(2, style.fontSize / max(tableFontSize, 1))),
            fontFamilies: style.fontFamilies,
            fontWeight: style.fontWeight,
            isItalic: style.isItalic,
            textColor: style.hasCSSColor ? RenderColor(uiColor: style.textColor) : nil,
            linkHref: linkHref,
            imageSource: element.attributes["src"]
                ?? element.attributes["xlink:href"]
                ?? element.attributes["href"],
            imageAlt: element.attributes["alt"],
            imageWidth: style.width,
            imageHeight: style.height
        )
    }

    private static func replacingText(
        in run: HTMLTableTextRun,
        with text: String
    ) -> HTMLTableTextRun {
        HTMLTableTextRun(
            text: text,
            fontScale: run.fontScale,
            fontFamilies: run.fontFamilies,
            fontWeight: run.fontWeight,
            isItalic: run.isItalic,
            textColor: run.textColor,
            linkHref: run.linkHref,
            imageSource: run.imageSource,
            imageAlt: run.imageAlt,
            imageWidth: run.imageWidth,
            imageHeight: run.imageHeight
        )
    }

    private static func normalizedText(from nodes: [HTMLAttributedStringBuilder.ASTNode]) -> String {
        let raw = nodes.map { node -> String in
            switch node {
            case .text(let text):
                return text.text
            case .lineBreak:
                return "\n"
            case .pageBreak:
                return ""
            case .element(let element):
                guard element.tag != "table" else { return "" }
                return normalizedText(from: element.children)
            }
        }.joined(separator: " ")
        return raw.components(separatedBy: "\n")
            .map { line in
                line.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func positiveSpan(_ raw: String?) -> Int {
        guard let raw,
              let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return 1 }
        return min(max(value, 1), 20)
    }
}

struct HTMLTableRasterLinkRegion: Sendable {
    let rect: CGRect
    let href: String
}

struct HTMLTableRasterPage: @unchecked Sendable {
    let image: UIImage
    let rowRange: Range<Int>
    let linkRegions: [HTMLTableRasterLinkRegion]
}

enum HTMLTableRasterizer {
    private static let linkAttribute = NSAttributedString.Key("ReaderTableRasterLink")

    @MainActor
    static func render(
        table: HTMLTableModel,
        maxWidth: CGFloat,
        baseFont: UIFont,
        textColor: UIColor,
        backgroundColor: UIColor,
        resolvedFont: (([String], Int, Bool, CGFloat) -> UIFont?)? = nil,
        imagesBySource: [String: UIImage] = [:]
    ) -> UIImage? {
        renderPages(
            table: table,
            maxWidth: maxWidth,
            maxPageHeight: nil,
            baseFont: baseFont,
            textColor: textColor,
            backgroundColor: backgroundColor,
            resolvedFont: resolvedFont,
            imagesBySource: imagesBySource
        ).first?.image
    }

    @MainActor
    static func renderPages(
        table: HTMLTableModel,
        maxWidth: CGFloat,
        maxPageHeight: CGFloat? = nil,
        baseFont: UIFont,
        textColor: UIColor,
        backgroundColor _: UIColor,
        resolvedFont: (([String], Int, Bool, CGFloat) -> UIFont?)? = nil,
        imagesBySource: [String: UIImage] = [:]
    ) -> [HTMLTableRasterPage] {
        let columns = max(1, table.columnCount)
        guard columns > 0, !table.rows.isEmpty else { return [] }

        let maximumWidth = max(1, min(maxWidth, 900))
        var width = maximumWidth
        let outerPadding: CGFloat = 8
        let captionPadding = CGSize(width: 8, height: 6)
        var contentWidth = max(1, width - outerPadding * 2)

        func horizontalPadding(_ cell: HTMLTableCell) -> CGFloat {
            max(0, cell.paddingLeft) + max(0, cell.paddingRight)
        }

        func verticalPadding(_ cell: HTMLTableCell) -> CGFloat {
            max(0, cell.paddingTop) + max(0, cell.paddingBottom)
        }

        func contentRect(for cell: HTMLTableCell, in rect: CGRect) -> CGRect {
            let left = max(0, cell.paddingLeft)
            let right = max(0, cell.paddingRight)
            let top = max(0, cell.paddingTop)
            let bottom = max(0, cell.paddingBottom)
            return CGRect(
                x: rect.minX + left,
                y: rect.minY + top,
                width: max(1, rect.width - left - right),
                height: max(1, rect.height - top - bottom)
            )
        }

        // Authored cell typography (duokan `td { font-size: .8em }`) — the reference rendering
        // (多看) keeps table text a step smaller than the surrounding body text.
        func styledFont(
            scale: CGFloat,
            families: [String],
            weight: Int,
            italic: Bool,
            isHeader: Bool
        ) -> UIFont {
            let size = max(9, baseFont.pointSize * scale)
            let effectiveWeight = isHeader && families.isEmpty ? max(weight, 600) : weight
            var font = (!families.isEmpty
                ? resolvedFont?(families, effectiveWeight, italic, size)
                : nil) ?? baseFont.withSize(size)
            var requestedTraits = font.fontDescriptor.symbolicTraits
            if effectiveWeight >= 600 { requestedTraits.insert(.traitBold) }
            if italic { requestedTraits.insert(.traitItalic) }
            if requestedTraits != font.fontDescriptor.symbolicTraits,
               let descriptor = font.fontDescriptor.withSymbolicTraits(requestedTraits) {
                font = UIFont(descriptor: descriptor, size: size)
            }
            return font
        }

        func cellFont(_ cell: HTMLTableCell) -> UIFont {
            styledFont(
                scale: cell.fontScale,
                families: cell.fontFamilies,
                weight: cell.fontWeight,
                italic: cell.isItalic,
                isHeader: cell.isHeader
            )
        }

        func resolvedRuns(for cell: HTMLTableCell) -> [HTMLTableTextRun] {
            if !cell.textRuns.isEmpty { return cell.textRuns }
            return [HTMLTableTextRun(
                text: cell.text,
                fontScale: cell.fontScale,
                fontFamilies: cell.fontFamilies,
                fontWeight: cell.fontWeight,
                isItalic: cell.isItalic,
                textColor: cell.textColor,
                linkHref: nil,
                imageSource: nil,
                imageAlt: nil,
                imageWidth: nil,
                imageHeight: nil
            )]
        }

        func resolvedImageSize(for run: HTMLTableTextRun, image: UIImage) -> CGSize {
            let intrinsic = CGSize(width: max(1, image.size.width), height: max(1, image.size.height))
            if let width = run.imageWidth, let height = run.imageHeight {
                return CGSize(width: max(1, width), height: max(1, height))
            }
            if let width = run.imageWidth {
                return CGSize(width: max(1, width), height: max(1, width * intrinsic.height / intrinsic.width))
            }
            if let height = run.imageHeight {
                return CGSize(width: max(1, height * intrinsic.width / intrinsic.height), height: max(1, height))
            }
            let maximumWidth = max(baseFont.pointSize, baseFont.pointSize * 4)
            let width = min(intrinsic.width, maximumWidth)
            return CGSize(width: width, height: max(1, width * intrinsic.height / intrinsic.width))
        }

        func attributedText(for cell: HTMLTableCell) -> NSMutableAttributedString {
            let output = NSMutableAttributedString()
            for run in resolvedRuns(for: cell) {
                let font = styledFont(
                    scale: run.fontScale,
                    families: run.fontFamilies,
                    weight: run.fontWeight,
                    italic: run.isItalic,
                    isHeader: cell.isHeader
                )
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: run.textColor?.uiColor ?? cell.textColor?.uiColor ?? textColor,
                ]
                if let href = run.linkHref, !href.isEmpty {
                    attributes[linkAttribute] = href
                }
                if let source = run.imageSource,
                   let image = imagesBySource[source] {
                    let attachment = NSTextAttachment()
                    attachment.image = image
                    let size = resolvedImageSize(for: run, image: image)
                    attachment.bounds = CGRect(
                        x: 0,
                        y: (font.capHeight - size.height) / 2,
                        width: size.width,
                        height: size.height
                    )
                    let imageString = NSMutableAttributedString(
                        attributedString: NSAttributedString(attachment: attachment)
                    )
                    imageString.addAttributes(
                        attributes,
                        range: NSRange(location: 0, length: imageString.length)
                    )
                    output.append(imageString)
                } else {
                    output.append(NSAttributedString(
                        string: run.text,
                        attributes: attributes
                    ))
                }
            }
            return output
        }

        func naturalTextWidth(for cell: HTMLTableCell) -> CGFloat {
            var currentLineWidth: CGFloat = 0
            var maximumLineWidth: CGFloat = 0
            for run in resolvedRuns(for: cell) {
                if let source = run.imageSource,
                   let image = imagesBySource[source] {
                    let imageWidth = resolvedImageSize(for: run, image: image).width
                    currentLineWidth += imageWidth
                    continue
                }
                let font = styledFont(
                    scale: run.fontScale,
                    families: run.fontFamilies,
                    weight: run.fontWeight,
                    italic: run.isItalic,
                    isHeader: cell.isHeader
                )
                let pieces = run.text.components(separatedBy: "\n")
                for (index, piece) in pieces.enumerated() {
                    currentLineWidth += piece.size(withAttributes: [.font: font]).width
                    if index < pieces.count - 1 {
                        maximumLineWidth = max(maximumLineWidth, currentLineWidth)
                        currentLineWidth = 0
                    }
                }
            }
            return max(maximumLineWidth, currentLineWidth)
        }

        func measuredCellHeight(_ cell: HTMLTableCell, width: CGFloat) -> CGFloat {
            let attributed = attributedText(for: cell)
            if attributed.length == 0 {
                attributed.append(NSAttributedString(string: " ", attributes: [.font: cellFont(cell)]))
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            if let lineHeight = cell.lineHeight, lineHeight > 0 {
                paragraph.minimumLineHeight = lineHeight
            }
            attributed.addAttribute(
                .paragraphStyle,
                value: paragraph,
                range: NSRange(location: 0, length: attributed.length)
            )
            return ceil(attributed.boundingRect(
                with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).height)
        }

        func drawCellText(
            _ cell: HTMLTableCell,
            in rect: CGRect,
            alignment: NSTextAlignment
        ) -> [HTMLTableRasterLinkRegion] {
            let attributed = attributedText(for: cell)
            guard attributed.length > 0 else { return [] }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            paragraph.lineBreakMode = .byWordWrapping
            if let lineHeight = cell.lineHeight, lineHeight > 0 {
                paragraph.minimumLineHeight = lineHeight
            }
            attributed.addAttribute(
                .paragraphStyle,
                value: paragraph,
                range: NSRange(location: 0, length: attributed.length)
            )
            attributed.draw(
                with: rect,
                options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
                context: nil
            )

            let textStorage = NSTextStorage(attributedString: attributed)
            let layoutManager = NSLayoutManager()
            let textContainer = NSTextContainer(size: rect.size)
            textContainer.lineFragmentPadding = 0
            textContainer.maximumNumberOfLines = 0
            textContainer.lineBreakMode = .byWordWrapping
            layoutManager.addTextContainer(textContainer)
            textStorage.addLayoutManager(layoutManager)
            layoutManager.ensureLayout(for: textContainer)

            var linkRegions: [HTMLTableRasterLinkRegion] = []
            textStorage.enumerateAttribute(
                linkAttribute,
                in: NSRange(location: 0, length: textStorage.length)
            ) { value, characterRange, _ in
                guard let href = value as? String, !href.isEmpty else { return }
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: characterRange,
                    actualCharacterRange: nil
                )
                guard glyphRange.length > 0 else { return }
                let localRect = layoutManager.boundingRect(
                    forGlyphRange: glyphRange,
                    in: textContainer
                )
                guard !localRect.isNull, !localRect.isEmpty else { return }
                linkRegions.append(HTMLTableRasterLinkRegion(
                    rect: localRect.offsetBy(dx: rect.minX, dy: rect.minY),
                    href: href
                ))
            }
            return linkRegions
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
                    demand = explicit + horizontalPadding(cell)
                } else {
                    demand = ceil(naturalTextWidth(for: cell)) + horizontalPadding(cell)
                }
                naturalWidths[columnIndex] = max(naturalWidths[columnIndex], demand)
            }
        }
        if table.widthPercent == nil {
            let captionDemand = table.caption.map {
                ceil($0.size(withAttributes: [.font: captionFont]).width)
                    + captionPadding.width * 2
            } ?? 0
            let intrinsicDemand = max(
                naturalWidths.reduce(0, +) + outerPadding * 2,
                captionDemand + outerPadding * 2
            )
            if let explicitWidth = table.explicitWidth {
                width = min(maximumWidth, max(44, explicitWidth + outerPadding * 2))
            } else {
                width = min(maximumWidth, max(44, intrinsicDemand))
            }
            contentWidth = max(1, width - outerPadding * 2)
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
                width: contentWidth - captionPadding.width * 2
            ) + captionPadding.height * 2
        }()

        var rowHeights: [CGFloat] = []
        for row in table.rows {
            var maxCellHeight: CGFloat = 0
            var columnIndex = 0
            for cell in row.cells {
                let span = max(1, cell.columnSpan)
                let spanWidth = spannedWidth(fromColumn: columnIndex, span: span)
                columnIndex += span
                let measured = measuredCellHeight(
                    cell,
                    width: max(1, spanWidth - horizontalPadding(cell))
                )
                maxCellHeight = max(maxCellHeight, measured + verticalPadding(cell))
            }
            rowHeights.append(max(30, ceil(maxCellHeight)))
        }

        // Split only against the actual reader content height. The previous width-derived cap
        // (`maxWidth * 1.75`) cut 洪武大帝's character profile into two raster images even though
        // the complete table fits one page, leaving a visible gap and broken outer border.
        let maximumPageHeight = max(44, maxPageHeight ?? .greatestFiniteMagnitude)
        var rowRanges: [Range<Int>] = []
        var start = 0
        while start < rowHeights.count {
            let pageCaptionHeight = start == 0 ? captionHeight : 0
            let availableHeight = max(30, maximumPageHeight - outerPadding * 2 - pageCaptionHeight)
            var usedHeight: CGFloat = 0
            var end = start
            while end < rowHeights.count {
                let nextHeight = rowHeights[end]
                if end > start, usedHeight + nextHeight > availableHeight { break }
                usedHeight += nextHeight
                end += 1
                if usedHeight >= availableHeight { break }
            }
            if end == start { end = min(start + 1, rowHeights.count) }
            rowRanges.append(start..<end)
            start = end
        }
        AppLogger.render("⟐ table", context: [
            "width": "\(Int(width))",
            "cols": columnWidths.map { Int($0) }.description,
            "rows": rowHeights.map { Int($0) }.description,
            "pages": "\(rowRanges.count)",
        ])

        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = false
        return rowRanges.map { rowRange in
            let pageCaptionHeight = rowRange.lowerBound == 0 ? captionHeight : 0
            let rowsHeight = rowRange.reduce(CGFloat(0)) { $0 + rowHeights[$1] }
            let height = max(44, outerPadding * 2 + pageCaptionHeight + rowsHeight)
            var pageLinkRegions: [HTMLTableRasterLinkRegion] = []
            let image = UIGraphicsImageRenderer(
                size: CGSize(width: width, height: height),
                format: format
            ).image { context in
            let bounds = CGRect(origin: .zero, size: CGSize(width: width, height: height))
            if let authoredBackground = table.backgroundColor?.uiColor {
                authoredBackground.setFill()
                context.fill(bounds)
            }

            let gridColor = UIColor.separator.resolvedColor(with: UITraitCollection.current)
            let usesAuthoredBorders = table.usesAuthoredBorders
            let authoredLineColor = table.borderColor?.uiColor ?? gridColor
            let captionColor = textColor.withAlphaComponent(0.75)

            func strokeLine(from: CGPoint, to: CGPoint, lineWidth: CGFloat, color: UIColor) {
                color.setStroke()
                context.cgContext.setLineWidth(lineWidth)
                context.cgContext.move(to: from)
                context.cgContext.addLine(to: to)
                context.cgContext.strokePath()
            }

            var cursorY = outerPadding
            if rowRange.lowerBound == 0,
               let caption = table.caption,
               !caption.isEmpty,
               captionHeight > 0 {
                drawText(
                    caption,
                    in: CGRect(
                        x: outerPadding + captionPadding.width,
                        y: cursorY + captionPadding.height,
                        width: contentWidth - captionPadding.width * 2,
                        height: captionHeight - captionPadding.height * 2
                    ),
                    font: captionFont,
                    color: captionColor,
                    alignment: .center
                )
                cursorY += captionHeight
            }
            let tableTop = cursorY

            for rowIndex in rowRange {
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
                    }

                    if usesAuthoredBorders {
                        // Authored line work only (duokan: `td { border-width: 0 1px 0 0 }` =
                        // column rules, no row lines; the header band declares no borders).
                        if cell.borderTop > 0 {
                            strokeLine(
                                from: CGPoint(x: rect.minX, y: rect.minY),
                                to: CGPoint(x: rect.maxX, y: rect.minY),
                                lineWidth: cell.borderTop,
                                color: cell.borderTopColor?.uiColor ?? authoredLineColor
                            )
                        }
                        if cell.borderBottom > 0 {
                            strokeLine(
                                from: CGPoint(x: rect.minX, y: rect.maxY),
                                to: CGPoint(x: rect.maxX, y: rect.maxY),
                                lineWidth: cell.borderBottom,
                                color: cell.borderBottomColor?.uiColor ?? authoredLineColor
                            )
                        }
                        if cell.borderLeft > 0 {
                            strokeLine(
                                from: CGPoint(x: rect.minX, y: rect.minY),
                                to: CGPoint(x: rect.minX, y: rect.maxY),
                                lineWidth: cell.borderLeft,
                                color: cell.borderLeftColor?.uiColor ?? authoredLineColor
                            )
                        }
                        if cell.borderRight > 0, rect.maxX < width - outerPadding - 0.5 {
                            // The table's own right edge is drawn by the outer border below.
                            strokeLine(
                                from: CGPoint(x: rect.maxX, y: rect.minY),
                                to: CGPoint(x: rect.maxX, y: rect.maxY),
                                lineWidth: cell.borderRight,
                                color: cell.borderRightColor?.uiColor ?? authoredLineColor
                            )
                        }
                    }

                    let resolvedAlignment: NSTextAlignment = {
                        if cell.alignment != .natural && cell.alignment != .justified { return cell.alignment }
                        // Reference (多看) sets the header band's title flush left.
                        if cell.isHeader { return usesAuthoredBorders ? .natural : .center }
                        return .natural
                    }()
                    var textRect = contentRect(for: cell, in: rect)
                    let textHeight = min(
                        textRect.height,
                        measuredCellHeight(cell, width: textRect.width)
                    )
                    switch cell.verticalAlignment {
                    case .top:
                        textRect.size.height = textHeight
                    case .middle:
                        textRect.origin.y += max(0, (textRect.height - textHeight) / 2)
                        textRect.size.height = textHeight
                    case .bottom:
                        textRect.origin.y += max(0, textRect.height - textHeight)
                        textRect.size.height = textHeight
                    }
                    pageLinkRegions.append(contentsOf: drawCellText(
                        cell,
                        in: textRect,
                        alignment: resolvedAlignment
                    ))
                    cursorX += cellWidth
                }
                cursorY += rowHeight
            }

            if usesAuthoredBorders {
                let tableBottom = cursorY
                if rowRange.lowerBound == 0, table.borderTop > 0 {
                    strokeLine(
                        from: CGPoint(x: outerPadding, y: tableTop),
                        to: CGPoint(x: outerPadding + contentWidth, y: tableTop),
                        lineWidth: table.borderTop,
                        color: table.borderTopColor?.uiColor ?? authoredLineColor
                    )
                }
                if rowRange.upperBound == table.rows.count, table.borderBottom > 0 {
                    strokeLine(
                        from: CGPoint(x: outerPadding, y: tableBottom),
                        to: CGPoint(x: outerPadding + contentWidth, y: tableBottom),
                        lineWidth: table.borderBottom,
                        color: table.borderBottomColor?.uiColor ?? authoredLineColor
                    )
                }
                if table.borderLeft > 0 {
                    strokeLine(
                        from: CGPoint(x: outerPadding, y: tableTop),
                        to: CGPoint(x: outerPadding, y: tableBottom),
                        lineWidth: table.borderLeft,
                        color: table.borderLeftColor?.uiColor ?? authoredLineColor
                    )
                }
                if table.borderRight > 0 {
                    strokeLine(
                        from: CGPoint(x: outerPadding + contentWidth, y: tableTop),
                        to: CGPoint(x: outerPadding + contentWidth, y: tableBottom),
                        lineWidth: table.borderRight,
                        color: table.borderRightColor?.uiColor ?? authoredLineColor
                    )
                }
            }
            }
            return HTMLTableRasterPage(
                image: image,
                rowRange: rowRange,
                linkRegions: pageLinkRegions
            )
        }
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
