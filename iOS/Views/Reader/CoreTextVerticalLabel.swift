import SwiftUI
import UIKit
import CoreText

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
        if let maxCharacters, text.count > maxCharacters {
            view.text = String(text.prefix(max(0, maxCharacters - 1))) + "\u{2026}"
        } else {
            view.text = text
        }

        view.fontSize = fontSize
        view.weight = weight
        view.textColor = textColor
        view.setNeedsDisplay()
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

        let centerX = bounds.midX
        var y = bounds.height - fontSize

        let normalAdvance = ceil(fontSize * 1.15)
        let punctuationAdvance = ceil(fontSize * 0.65)

        for ch in text.map(String.init) {
            let attr = NSAttributedString(
                string: ch,
                attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: ctFont,
                    kCTForegroundColorAttributeName as NSAttributedString.Key: textColor.cgColor
                ]
            )

            let line = CTLineCreateWithAttributedString(attr)
            let lineBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])

            let x = centerX - lineBounds.width / 2 - lineBounds.origin.x

            if isCornerPunctuation(ch) {
                let px = centerX + fontSize * 0.15
                let py = y + fontSize * 0.25
                context.textPosition = CGPoint(x: px, y: py)
                CTLineDraw(line, context)
                y -= punctuationAdvance
            } else if isASCII(ch) {
                context.saveGState()
                context.translateBy(x: centerX, y: y + fontSize * 0.35)
                context.rotate(by: .pi / 2)
                context.textPosition = CGPoint(x: -lineBounds.width / 2, y: 0)
                CTLineDraw(line, context)
                context.restoreGState()
                y -= normalAdvance
            } else {
                context.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(line, context)
                y -= normalAdvance
            }

            if y < 0 {
                break
            }
        }
    }

    private func isCornerPunctuation(_ s: String) -> Bool {
        ["\u{FF0C}", "\u{3002}", "\u{3001}", "\u{FF0E}", "\u{FF61}", "\u{FF64}"].contains(s)
    }

    private func isASCII(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { $0.isASCII }
    }
}
