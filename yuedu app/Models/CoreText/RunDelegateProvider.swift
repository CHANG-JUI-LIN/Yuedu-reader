import CoreText
import UIKit

/// Holds image layout metadata used by CTRunDelegate callbacks.
final class ImageRunInfo {
    enum DisplayMode {
        case inline
        case block
    }

    let image: UIImage?
    let width: CGFloat
    let height: CGFloat
    let drawWidth: CGFloat
    let drawHeight: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    let paddingLeft: CGFloat
    let paddingRight: CGFloat
    let source: String
    let displayMode: DisplayMode
    let opacity: CGFloat

    init(
        image: UIImage?,
        width: CGFloat,
        height: CGFloat,
        drawWidth: CGFloat,
        drawHeight: CGFloat,
        ascent: CGFloat,
        descent: CGFloat,
        paddingLeft: CGFloat,
        paddingRight: CGFloat,
        source: String,
        displayMode: DisplayMode,
        opacity: CGFloat
    ) {
        self.image = image
        self.width = width
        self.height = height
        self.drawWidth = drawWidth
        self.drawHeight = drawHeight
        self.ascent = ascent
        self.descent = descent
        self.paddingLeft = paddingLeft
        self.paddingRight = paddingRight
        self.source = source
        self.displayMode = displayMode
        self.opacity = opacity
    }
}

enum RunDelegateProvider {
    static func makeImagePlaceholder(
        image: UIImage?,
        font: UIFont,
        textColor: UIColor,
        totalWidth: CGFloat,
        drawWidth: CGFloat,
        drawHeight: CGFloat,
        ascent: CGFloat,
        descent: CGFloat,
        paddingLeft: CGFloat,
        paddingRight: CGFloat,
        imageSource: String,
        displayMode: ImageRunInfo.DisplayMode,
        opacity: CGFloat
    ) -> NSAttributedString {
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateCurrentVersion,
            dealloc: { pointer in
                Unmanaged<ImageRunInfo>.fromOpaque(pointer).release()
            },
            getAscent: { pointer in
                Unmanaged<ImageRunInfo>.fromOpaque(pointer).takeUnretainedValue().ascent
            },
            getDescent: { pointer in
                Unmanaged<ImageRunInfo>.fromOpaque(pointer).takeUnretainedValue().descent
            },
            getWidth: { pointer in
                Unmanaged<ImageRunInfo>.fromOpaque(pointer).takeUnretainedValue().width
            }
        )

        let info = ImageRunInfo(
            image: image,
            width: totalWidth,
            height: drawHeight,
            drawWidth: drawWidth,
            drawHeight: drawHeight,
            ascent: ascent,
            descent: descent,
            paddingLeft: paddingLeft,
            paddingRight: paddingRight,
            source: imageSource,
            displayMode: displayMode,
            opacity: opacity
        )

        let retained = Unmanaged.passRetained(info).toOpaque()
        guard let delegate = CTRunDelegateCreate(&callbacks, retained) else {
            return NSAttributedString(
                string: "\u{FFFC}",
                attributes: [
                    .font: font,
                    .foregroundColor: textColor,
                ]
            )
        }

        let string = NSMutableAttributedString(
            string: "\u{FFFC}",
            attributes: [
                .font: font,
                .foregroundColor: textColor,
            ]
        )
        string.addAttribute(
            NSAttributedString.Key(kCTRunDelegateAttributeName as String),
            value: delegate,
            range: NSRange(location: 0, length: string.length)
        )
        return string
    }
}
