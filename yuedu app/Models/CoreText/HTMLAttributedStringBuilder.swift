import CoreText
import SwiftSoup
import UIKit

final class HTMLAttributedStringBuilder {
    struct Config {
        var fontSize: CGFloat
        var lineSpacing: CGFloat
        var paragraphSpacing: CGFloat
        var firstLineIndent: CGFloat
        var textColor: UIColor
        var backgroundColor: UIColor
        var fontFamilyName: String?
        /// 頁面可用寬度（含邊距），用於圖片等比縮放計算
        var renderWidth: CGFloat = UIScreen.main.bounds.width - 32
    }

    /// 圖片資源回調：src href → UIImage?（背景執行緒呼叫）
    var imageLoader: ((String) async -> UIImage?)?

    func build(html: String, config: Config) async -> NSAttributedString {
        let result = NSMutableAttributedString()
        guard let doc = try? SwiftSoup.parse(html),
              let body = doc.body() else {
            return result
        }
        await appendChildren(body.children().array(), to: result, config: config, inheritedBold: false, inheritedItalic: false)
        return result
    }

    // MARK: - DOM 遍歷

    private func appendChildren(
        _ elements: [Element],
        to result: NSMutableAttributedString,
        config: Config,
        inheritedBold: Bool,
        inheritedItalic: Bool
    ) async {
        for el in elements {
            await appendElement(el, to: result, config: config,
                                inheritedBold: inheritedBold,
                                inheritedItalic: inheritedItalic)
        }
    }

    private func appendElement(
        _ el: Element,
        to result: NSMutableAttributedString,
        config: Config,
        inheritedBold: Bool,
        inheritedItalic: Bool
    ) async {
        let tag = el.tagName().lowercased()

        switch tag {
        case "p", "div", "section", "article":
            let para = NSMutableAttributedString()
            await appendChildren(el.children().array(), to: para, config: config,
                                 inheritedBold: inheritedBold, inheritedItalic: inheritedItalic)
            if para.length == 0, let text = try? el.text(), !text.isEmpty {
                para.append(makeText(text, config: config, bold: inheritedBold, italic: inheritedItalic))
            }
            applyParagraphStyle(to: para, config: config)
            result.append(para)
            result.append(NSAttributedString(string: "\n"))

        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(tag.dropFirst()) ?? 1
            let scale: CGFloat = max(1.0, 1.6 - CGFloat(level - 1) * 0.1)
            var headingConfig = config
            headingConfig.fontSize = config.fontSize * scale
            headingConfig.firstLineIndent = 0
            headingConfig.paragraphSpacing = config.paragraphSpacing * 1.5
            let text = (try? el.text()) ?? ""
            let para = makeText(text, config: headingConfig, bold: true, italic: inheritedItalic)
            applyParagraphStyle(to: para, config: headingConfig)
            result.append(para)
            result.append(NSAttributedString(string: "\n"))

        case "strong", "b":
            let inline = NSMutableAttributedString()
            await appendChildren(el.children().array(), to: inline, config: config,
                                 inheritedBold: true, inheritedItalic: inheritedItalic)
            if inline.length == 0, let text = try? el.text(), !text.isEmpty {
                inline.append(makeText(text, config: config, bold: true, italic: inheritedItalic))
            }
            result.append(inline)

        case "em", "i":
            let inline = NSMutableAttributedString()
            await appendChildren(el.children().array(), to: inline, config: config,
                                 inheritedBold: inheritedBold, inheritedItalic: true)
            if inline.length == 0, let text = try? el.text(), !text.isEmpty {
                inline.append(makeText(text, config: config, bold: inheritedBold, italic: true))
            }
            result.append(inline)

        case "a":
            let text = (try? el.text()) ?? ""
            let attr = makeText(text, config: config, bold: inheritedBold, italic: inheritedItalic)
            attr.addAttribute(.foregroundColor,
                              value: UIColor.systemBlue,
                              range: NSRange(location: 0, length: attr.length))
            result.append(attr)

        case "br":
            result.append(NSAttributedString(string: "\n"))

        case "img":
            let src = (try? el.attr("src")) ?? ""
            await appendImage(src: src, to: result, config: config)

        case "table":
            if let tableImage = await renderTableAsImage(el, config: config) {
                await appendImage(image: tableImage, to: result, config: config)
            }

        default:
            await appendChildren(el.children().array(), to: result, config: config,
                                 inheritedBold: inheritedBold, inheritedItalic: inheritedItalic)
            if el.children().isEmpty(), let text = try? el.text(), !text.isEmpty {
                result.append(makeText(text, config: config, bold: inheritedBold, italic: inheritedItalic))
            }
        }
    }

    // MARK: - 文字 Attributes

    private func makeText(
        _ text: String,
        config: Config,
        bold: Bool,
        italic: Bool
    ) -> NSMutableAttributedString {
        let font = resolveFont(config: config, bold: bold, italic: italic)
        return NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: config.textColor,
                .backgroundColor: config.backgroundColor,
            ]
        )
    }

    private func resolveFont(config: Config, bold: Bool, italic: Bool) -> UIFont {
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }

        if let familyName = config.fontFamilyName,
           let descriptor = UIFont(name: familyName, size: config.fontSize)?
               .fontDescriptor.withSymbolicTraits(traits) {
            return UIFont(descriptor: descriptor, size: config.fontSize)
        }
        let base = UIFont.systemFont(ofSize: config.fontSize)
        if traits.isEmpty { return base }
        if let descriptor = base.fontDescriptor.withSymbolicTraits(traits) {
            return UIFont(descriptor: descriptor, size: config.fontSize)
        }
        return base
    }

    private func applyParagraphStyle(to attrStr: NSMutableAttributedString, config: Config) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = config.lineSpacing
        style.paragraphSpacing = config.paragraphSpacing
        style.firstLineHeadIndent = config.firstLineIndent
        style.alignment = .justified
        attrStr.addAttribute(.paragraphStyle,
                             value: style,
                             range: NSRange(location: 0, length: attrStr.length))
    }

    // MARK: - 圖片 CTRunDelegate

    private func appendImage(src: String, to result: NSMutableAttributedString, config: Config) async {
        let image = await imageLoader?(src)
        await appendImage(image: image, to: result, config: config)
    }

    private func appendImage(image: UIImage?, to result: NSMutableAttributedString, config: Config) async {
        let maxWidth = config.renderWidth
        let (w, h): (CGFloat, CGFloat)
        if let img = image {
            let ratio = min(1.0, maxWidth / img.size.width)
            w = img.size.width * ratio
            h = img.size.height * ratio
        } else {
            w = maxWidth
            h = maxWidth * 0.5
        }

        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateCurrentVersion,
            dealloc: { ptr in
                Unmanaged<ImageRunInfo>.fromOpaque(ptr).release()
            },
            getAscent: { ptr -> CGFloat in
                Unmanaged<ImageRunInfo>.fromOpaque(ptr).takeUnretainedValue().height
            },
            getDescent: { _ -> CGFloat in 0 },
            getWidth: { ptr -> CGFloat in
                Unmanaged<ImageRunInfo>.fromOpaque(ptr).takeUnretainedValue().width
            }
        )
        let info = ImageRunInfo(image: image, width: w, height: h)
        let retained = Unmanaged.passRetained(info).toOpaque()
        guard let delegate = CTRunDelegateCreate(&callbacks, retained) else { return }

        let placeholder = NSMutableAttributedString(string: "\u{FFFC}")
        placeholder.addAttribute(
            NSAttributedString.Key(kCTRunDelegateAttributeName as String),
            value: delegate,
            range: NSRange(location: 0, length: 1)
        )
        result.append(placeholder)
    }

    // MARK: - Table → UIImage

    private func renderTableAsImage(_ el: Element, config: Config) async -> UIImage? {
        let text = (try? el.text()) ?? ""
        guard !text.isEmpty else { return nil }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: config.renderWidth, height: 200))
        return renderer.image { ctx in
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: config.fontSize * 0.85),
                .foregroundColor: config.textColor
            ]
            text.draw(
                in: CGRect(x: 8, y: 8, width: config.renderWidth - 16, height: 184),
                withAttributes: attrs
            )
        }
    }
}

// MARK: - ImageRunInfo（ARC 管理的圖片元數據）

final class ImageRunInfo {
    let image: UIImage?
    let width: CGFloat
    let height: CGFloat
    init(image: UIImage?, width: CGFloat, height: CGFloat) {
        self.image = image
        self.width = width
        self.height = height
    }
}
