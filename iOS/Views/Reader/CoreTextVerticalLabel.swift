import SwiftUI
import CoreText
import UIKit

struct CoreTextVerticalLabel: UIViewRepresentable {
    let text: String
    var fontSize: CGFloat = 24
    var weight: UIFont.Weight = .bold
    var textColor: UIColor = .label
    var maxCharacters: Int? = nil

    func makeUIView(context: Context) -> CoreTextVerticalLabelView {
        let view = CoreTextVerticalLabelView()
        view.backgroundColor = .clear
        view.isOpaque = false
        return view
    }

    func updateUIView(_ view: CoreTextVerticalLabelView, context: Context) {
        view.text = maxCharacters.map { truncate(text, maxCount: $0) } ?? text
        view.fontSize = fontSize
        view.weight = weight
        view.textColor = textColor
        view.setNeedsDisplay()
    }

    private func truncate(_ value: String, maxCount: Int) -> String {
        guard value.count > maxCount else { return value }
        return String(value.prefix(max(0, maxCount - 1))) + "\u{2026}"
    }
}

final class CoreTextVerticalLabelView: UIView {
    var text: String = ""
    var fontSize: CGFloat = 24
    var weight: UIFont.Weight = .bold
    var textColor: UIColor = .label

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), !text.isEmpty else { return }

        context.saveGState()
        defer { context.restoreGState() }

        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)

        let font = UIFont.systemFont(ofSize: fontSize, weight: weight)
        let ctFont = font as CTFont

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byCharWrapping

        let attr = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: ctFont,
                .foregroundColor: textColor.cgColor,
                .paragraphStyle: paragraph
            ]
        )

        attr.addAttribute(
            kCTVerticalFormsAttributeName as NSAttributedString.Key,
            value: true,
            range: NSRange(location: 0, length: attr.length)
        )

        let framesetter = CTFramesetterCreateWithAttributedString(attr)

        let path = CGMutablePath()
        path.addRect(bounds)

        let frameAttributes: CFDictionary = [
            kCTFrameProgressionAttributeName: CTFrameProgression.rightToLeft.rawValue
        ] as CFDictionary

        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attr.length),
            path,
            frameAttributes
        )

        CTFrameDraw(frame, context)
    }
}
