import Foundation
import JavaScriptCore
import UIKit
import iosMath

enum MathMLLatexConverter {
    static func latex(from element: HTMLAttributedStringBuilder.ElementNode) -> String? {
        guard localName(element.tag) == "math" else { return nil }
        if let tableLatex = MathMLTableLatexConverter.latex(from: element) {
            let normalized = normalizeLatex(tableLatex)
            return normalized.isEmpty ? nil : normalized
        }
        let mathML = MathMLSerializer.markup(from: element)
        guard let converted = MathMLToLatexJSBridge.shared.convert(mathML) else { return nil }
        let normalized = normalizeLatex(converted)
        return normalized.isEmpty ? nil : normalized
    }

    static func normalizeLatex(_ latex: String) -> String {
        var result = latex
        result = result.replacingOccurrences(of: "−", with: "-")
        result = result.replacingOccurrences(of: "∕", with: "/")
        result = result.replacingOccurrences(of: "\\hdots", with: "\\ldots")
        result = result.replacingOccurrences(of: "\\blacksquare", with: "\\square")
        result = result.replacingOccurrences(of: "\\subsetneq", with: "\\subset")
        result = replacing(pattern: #"\\overset\{̂\}\{([^{}]+)\}"#, in: result, template: #"\\hat{$1}"#)
        result = replacing(pattern: #"\\underset\{([^{}]+)\}\{\\prod\}"#, in: result, template: #"\\prod_{$1}"#)
        result = replacing(pattern: #"\\left〈"#, in: result, template: #"\\left\\langle "#)
        result = replacing(pattern: #"\\right〉"#, in: result, template: #"\\right\\rangle "#)
        result = replacing(pattern: #"\s+"#, in: result, template: " ")
        result = result
            .replacingOccurrences(of: " {", with: "{")
            .replacingOccurrences(of: "{ ", with: "{")
            .replacingOccurrences(of: " }", with: "}")
            .replacingOccurrences(of: "} ", with: "}")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func fallbackText(alt: String?, latex: String?) -> String {
        let trimmedAlt = alt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedAlt.isEmpty,
           trimmedAlt.range(of: "alternative text not available", options: .caseInsensitive) == nil,
           trimmedAlt.count <= 80 {
            return "[\(trimmedAlt)]"
        }
        return "[math]"
    }

    private static func replacing(pattern: String, in string: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return string }
        let range = NSRange(string.startIndex..., in: string)
        return regex.stringByReplacingMatches(in: string, range: range, withTemplate: template)
    }

    fileprivate static func localName(_ tag: String) -> String {
        tag.split(separator: ":").last.map(String.init) ?? tag
    }
}

private enum MathMLSerializer {
    static func markup(from element: HTMLAttributedStringBuilder.ElementNode) -> String {
        serialize(element, forceMathNamespace: true)
    }

    static func markup(wrapping nodes: [HTMLAttributedStringBuilder.ASTNode]) -> String {
        let children = nodes.map(serialize(node:)).joined()
        return #"<math xmlns="http://www.w3.org/1998/Math/MathML"><mrow>\#(children)</mrow></math>"#
    }

    private static func serialize(
        _ element: HTMLAttributedStringBuilder.ElementNode,
        forceMathNamespace: Bool = false
    ) -> String {
        var attributes = element.attributes
        if forceMathNamespace, attributes["xmlns"] == nil {
            attributes["xmlns"] = "http://www.w3.org/1998/Math/MathML"
        }
        let attributeString = attributes
            .sorted { $0.key < $1.key }
            .map { key, value in " \(key)=\"\(escapeAttribute(value))\"" }
            .joined()
        let children = element.children.map(serialize(node:)).joined()
        return "<\(element.tag)\(attributeString)>\(children)</\(element.tag)>"
    }

    private static func serialize(node: HTMLAttributedStringBuilder.ASTNode) -> String {
        switch node {
        case .text(let text):
            return escapeText(text.text)
        case .lineBreak, .pageBreak:
            return ""
        case .element(let element):
            return serialize(element)
        }
    }

    private static func escapeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ value: String) -> String {
        escapeText(value)
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private enum MathMLTableLatexConverter {
    static func latex(from math: HTMLAttributedStringBuilder.ElementNode) -> String? {
        guard let table = directTable(in: math.children) else { return nil }
        return latex(fromTable: table)
    }

    private static func directTable(
        in nodes: [HTMLAttributedStringBuilder.ASTNode]
    ) -> HTMLAttributedStringBuilder.ElementNode? {
        var visible: [HTMLAttributedStringBuilder.ElementNode] = []
        for node in nodes {
            switch node {
            case .element(let element):
                visible.append(element)
            case .text(let text):
                if !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return nil
                }
            case .lineBreak, .pageBreak:
                continue
            }
        }
        guard visible.count == 1, let element = visible.first else { return nil }
        let tag = MathMLLatexConverter.localName(element.tag)
        if tag == "mtable" {
            return element
        }
        if tag == "mrow" || tag == "semantics" {
            return directTable(in: element.children)
        }
        return nil
    }

    private static func latex(fromTable table: HTMLAttributedStringBuilder.ElementNode) -> String? {
        let rows = table.children.compactMap { node -> [String]? in
            guard case .element(let row) = node else { return nil }
            let tag = MathMLLatexConverter.localName(row.tag)
            guard tag == "mtr" || tag == "mlabeledtr" else { return nil }
            let cells = row.children.compactMap { child -> String? in
                guard case .element(let cell) = child,
                      MathMLLatexConverter.localName(cell.tag) == "mtd",
                      hasVisibleMathContent(in: cell.children)
                else { return nil }
                let markup = MathMLSerializer.markup(wrapping: cell.children)
                guard let converted = MathMLToLatexJSBridge.shared.convert(markup) else { return nil }
                let latex = MathMLLatexConverter.normalizeLatex(converted)
                return latex.isEmpty ? nil : latex
            }
            return cells.isEmpty ? nil : cells
        }
        guard !rows.isEmpty else { return nil }

        if rows.count == 1, let row = rows.first {
            return row.joined(separator: #" \quad "#)
        }

        let columnCounts = Set(rows.map(\.count))
        if columnCounts == Set([1]) {
            return environment("displaylines", rows: rows)
        }
        if columnCounts == Set([2]) {
            return environment("aligned", rows: rows)
        }
        if columnCounts == Set([3]) {
            return environment("eqnarray", rows: rows)
        }

        let flattenedRows = rows.map { [$0.joined(separator: #" \quad "#)] }
        return environment("displaylines", rows: flattenedRows)
    }

    private static func environment(_ name: String, rows: [[String]]) -> String {
        let body = rows
            .map { $0.joined(separator: " & ") }
            .joined(separator: #" \\ "#)
        return #"\begin{\#(name)}\#(body)\end{\#(name)}"#
    }

    private static func hasVisibleMathContent(in nodes: [HTMLAttributedStringBuilder.ASTNode]) -> Bool {
        nodes.contains { node in
            switch node {
            case .text(let text):
                return !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .lineBreak, .pageBreak:
                return false
            case .element(let element):
                let tag = MathMLLatexConverter.localName(element.tag)
                if tag == "mspace" || tag == "malignmark" {
                    return false
                }
                return tag == "mi"
                    || tag == "mn"
                    || tag == "mo"
                    || tag == "ms"
                    || tag == "mtext"
                    || hasVisibleMathContent(in: element.children)
            }
        }
    }
}

private final class MathMLToLatexJSBridge {
    static let shared = MathMLToLatexJSBridge()

    private let queue = DispatchQueue(label: "com.yuedu.mathml-to-latex")
    private var context: JSContext?
    private var loadFailed = false

    func convert(_ mathML: String) -> String? {
        queue.sync {
            guard let context = preparedContext() else { return nil }
            context.exception = nil
            let namespace = context.objectForKeyedSubscript("MathMLToLaTeX")
            let converter = namespace?.objectForKeyedSubscript("MathMLToLaTeX")
            let value = converter?.invokeMethod("convert", withArguments: [mathML])
            guard context.exception == nil,
                  let latex = value?.toString(),
                  !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return latex
        }
    }

    private func preparedContext() -> JSContext? {
        if let context {
            return context
        }
        guard !loadFailed,
              let script = loadBundleScript()
        else {
            loadFailed = true
            return nil
        }
        let newContext = JSContext()
        newContext?.exceptionHandler = { context, exception in
            context?.exception = exception
        }
        newContext?.evaluateScript("var console = { error: function(){}, warn: function(){}, log: function(){} };")
        newContext?.evaluateScript(script)
        guard newContext?.exception == nil,
              newContext?.objectForKeyedSubscript("MathMLToLaTeX").isUndefined == false
        else {
            loadFailed = true
            return nil
        }
        context = newContext
        return newContext
    }

    private func loadBundleScript() -> String? {
        let bundles = [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks
        for bundle in bundles {
            let url = bundle.url(
                forResource: "MathMLToLaTeX.bundle.min",
                withExtension: "js",
                subdirectory: "Assets"
            ) ?? bundle.url(
                forResource: "MathMLToLaTeX.bundle.min",
                withExtension: "js"
            )
            guard let url,
                  let script = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            return script
        }
        return nil
    }
}

@MainActor
enum MathMLImageRenderer {
    /// A rasterised equation plus the metric needed to align it inline with surrounding text.
    final class Rendered {
        let image: UIImage
        /// Absolute height above/below the math baseline in image points. The bitmap is rendered at
        /// exactly `ascent + descent` tall (no label padding), so these map 1:1 onto the raster.
        let ascent: CGFloat
        let descent: CGFloat
        /// Height below the math baseline as a fraction of the image height (0...1). Multiply by the
        /// drawn image height to recover the inline descent, so the math baseline lands on the text
        /// baseline regardless of any later width-scaling the caller applies.
        var descentFraction: CGFloat {
            let total = ascent + descent
            return total > 0 ? max(0, min(1, descent / total)) : 0
        }

        init(image: UIImage, ascent: CGFloat, descent: CGFloat) {
            self.image = image
            self.ascent = ascent
            self.descent = descent
        }
    }

    private static let cache = NSCache<NSString, Rendered>()

    static func render(
        latex: String,
        fontSize: CGFloat,
        textColor: UIColor,
        displayMode: ImageRunInfo.DisplayMode,
        targetWidth: CGFloat
    ) -> Rendered? {
        let mode: MTMathUILabelMode = displayMode == .block ? .display : .text
        let cacheKey = "\(latex)|\(fontSize)|\(textColor.cacheKey)|\(mode.rawValue)|\(targetWidth)" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        let label = MTMathUILabel()
        label.backgroundColor = .clear
        label.displayErrorInline = false
        label.fontSize = fontSize
        label.textColor = textColor
        label.mode = mode
        label.latex = latex
        guard label.error == nil else { return nil }

        // Force a layout pass so the label materialises its MTMathListDisplay; we then bypass the
        // label entirely for rasterisation. `MTMathUILabel.layoutSubviews` vertically centres the
        // display list and pads short formulas up to a minimum height of fontSize/2, so a `label.draw`
        // screenshot embeds padding the declared baseline metrics know nothing about — short inline
        // formulas would sit visibly below the surrounding text baseline.
        label.frame = CGRect(origin: .zero, size: CGSize(width: 1, height: 1))
        label.setNeedsLayout()
        label.layoutIfNeeded()
        guard let display = label.displayList else { return nil }
        display.textColor = textColor

        let naturalWidth = ceil(max(1, display.width))
        let naturalHeight = max(1, display.ascent + display.descent)
        guard naturalWidth.isFinite, naturalHeight.isFinite else { return nil }

        let widthLimit = max(1, targetWidth)
        let scaleFactor = min(1, widthLimit / naturalWidth)
        let ascent = display.ascent * scaleFactor
        let descent = display.descent * scaleFactor
        let imageSize = CGSize(
            width: ceil(naturalWidth * scaleFactor),
            height: ceil(naturalHeight * scaleFactor)
        )
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: imageSize, format: format)
        let image = renderer.image { context in
            let cg = context.cgContext
            UIColor.clear.setFill()
            UIRectFill(CGRect(origin: .zero, size: imageSize))
            cg.saveGState()
            // MTMathListDisplay lays its CoreText glyphs out in a y-up coordinate system (`position`
            // is the baseline origin). UIGraphicsImageRenderer hands us a y-down context, so flip it;
            // the equation would otherwise come out vertically mirrored (upside down).
            cg.translateBy(x: 0, y: imageSize.height)
            cg.scaleBy(x: 1, y: -1)
            cg.scaleBy(x: scaleFactor, y: scaleFactor)
            // Baseline sits exactly `descent` points above the bitmap's bottom edge — matching the
            // ascent/descent this Rendered reports, with no centering padding.
            display.position = CGPoint(x: 0, y: display.descent)
            display.draw(cg)
            cg.restoreGState()
        }
        let rendered = Rendered(image: image, ascent: ascent, descent: descent)
        cache.setObject(rendered, forKey: cacheKey)
        return rendered
    }
}

private extension UIColor {
    var cacheKey: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return "\(red),\(green),\(blue),\(alpha)"
        }
        return description
    }
}
