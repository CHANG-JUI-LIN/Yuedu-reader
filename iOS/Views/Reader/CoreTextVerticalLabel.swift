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

        let attr = NSMutableAttributedString(
            string: text,
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: ctFont,
                kCTForegroundColorAttributeName as NSAttributedString.Key: textColor.cgColor,
                kCTVerticalFormsAttributeName as NSAttributedString.Key: true
            ]
        )

        let framesetter = CTFramesetterCreateWithAttributedString(attr)

        let columnWidth = fontSize + 8
        let drawRect = CGRect(
            x: bounds.width - columnWidth,
            y: 0,
            width: columnWidth,
            height: bounds.height
        )

        let path = CGMutablePath()
        path.addRect(drawRect)

        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attr.length),
            path,
            nil
        )

        CTFrameDraw(frame, context)
    }
}
