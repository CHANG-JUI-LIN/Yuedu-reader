import SwiftUI
import UIKit

/// 評論列表's style, as a comment card wears it: the switches and sliders over the stylesheet
/// over the App's own look (`CommentListStyle`). The one place the three meet — the card
/// reads only `Resolved`.
struct CommentListLook: Equatable {
    var style: CommentListStyle
    var sheet: CommentListCSS.Sheet

    /// The App's own look: what 作品詳情, and a list nobody styled, draw.
    static let app = CommentListLook(style: CommentListStyle(), sheet: CommentListCSS.Sheet())

    /// One part's text: its face and its colour.
    struct TextLook {
        var font: Font
        var color: Color
        /// Its size in points, for what is measured against it (a line height in `em`).
        var pointSize: CGFloat
    }

    struct Resolved {
        var cardFill: AnyShapeStyle
        var cornerRadius: CGFloat
        var padding: CGFloat
        var avatarSize: CGFloat
        /// Nil draws a circle.
        var avatarCornerRadius: CGFloat?
        var name: TextLook
        var text: TextLook
        var textLineSpacing: CGFloat
        var textTracking: CGFloat
        var textLineLimit: Int?
        var meta: TextLook
        var floor: TextLook
        var likes: TextLook
        var quote: TextLook
        var quoteFill: Color?
        var quoteBar: Color
        var quoteBarWidth: CGFloat
        var badgeText: Color
        var badgeFill: Color
        var authorText: Color
        var authorFill: Color
        var reply: TextLook
        var replyFill: Color
        var inlineReplies: Int
        var hidden: Set<CommentListPart>

        func shows(_ part: CommentListPart) -> Bool { !hidden.contains(part) }
    }

    /// The look on a dark or a light reading background, with text sizes grown by `fontScale`
    /// (the reader's Dynamic Type, from the card's `@ScaledMetric`).
    @MainActor
    func resolved(isDark: Bool, fontScale: CGFloat) -> Resolved {
        func css(_ element: CommentListCSS.Element) -> CommentListCSS.Declarations {
            sheet.declarations(for: element, isDark: isDark)
        }
        let card = css(.card)
        let baseColor = card.color.map(Self.color)

        func text(_ element: CommentListCSS.Element, size param: Double?, style: UIFont.TextStyle, font: Font,
                  weight defaultWeight: Font.Weight? = nil, color defaultColor: Color) -> TextLook {
            let declared = css(element)
            let weight = declared.fontWeight.map(Self.weight) ?? defaultWeight
            let color = declared.color.map(Self.color) ?? baseColor ?? defaultColor
            if let size = param ?? declared.fontSize {
                let scaled = CGFloat(size) * fontScale
                return TextLook(font: .system(size: scaled, weight: weight ?? .regular), color: color, pointSize: scaled)
            }
            let pointSize = UIFont.preferredFont(forTextStyle: style).pointSize
            return TextLook(font: weight.map { font.weight($0) } ?? font, color: color, pointSize: pointSize)
        }

        let fill: AnyShapeStyle
        if let opacity = style.cardOpacity {
            fill = AnyShapeStyle(DSColor.textPrimary.opacity(opacity))
        } else if card.glass == true {
            fill = AnyShapeStyle(.regularMaterial)
        } else if let background = card.background {
            fill = AnyShapeStyle(Self.color(background))
        } else {
            fill = AnyShapeStyle(DSColor.quietCardFill)
        }

        let body = text(.text, size: style.contentFontSize, style: .subheadline, font: DSFont.subheadline,
                        color: DSColor.textPrimary)
        let lineSpacing: CGFloat
        if let points = style.lineSpacing {
            lineSpacing = CGFloat(points)
        } else {
            switch css(.text).lineHeight {
            case .multiple(let multiple): lineSpacing = max(0, (CGFloat(multiple) - 1) * body.pointSize)
            case .points(let points): lineSpacing = max(0, CGFloat(points) * fontScale - body.pointSize)
            case nil: lineSpacing = 0
            }
        }
        let meta = text(.meta, size: style.metaFontSize, style: .footnote, font: DSFont.footnote,
                        color: DSColor.textSecondary)
        let quote = css(.quote)
        let badge = css(.badge)
        let author = css(.author)
        let reply = css(.reply)
        let avatar = css(.avatar)

        var hidden = style.hiddenParts ?? []
        let elements: [(CommentListPart, CommentListCSS.Element)] = [
            (.avatar, .avatar), (.badge, .badge), (.author, .author), (.floor, .floor), (.quote, .quote),
            (.meta, .meta), (.likes, .likes),
        ]
        for (part, element) in elements where css(element).isHidden == true { hidden.insert(part) }

        return Resolved(
            cardFill: fill,
            cornerRadius: CGFloat(style.cornerRadius ?? card.cornerRadius ?? Double(DSRadius.xl)),
            padding: CGFloat(card.padding ?? Double(DSSpacing.lg)),
            avatarSize: CGFloat(style.avatarSize ?? avatar.size ?? Double(DSLayout.commentAvatarSize)),
            avatarCornerRadius: avatar.cornerRadius.map { CGFloat($0) },
            name: text(.name, size: style.nameFontSize, style: .footnote, font: DSFont.footnote, weight: .semibold,
                       color: DSColor.textPrimary),
            text: body,
            textLineSpacing: lineSpacing,
            textTracking: css(.text).letterSpacing.map { CGFloat($0.points(fontSize: Double(body.pointSize))) } ?? 0,
            textLineLimit: css(.text).lineClamp,
            meta: meta,
            floor: text(.floor, size: css(.floor).fontSize == nil ? style.metaFontSize : nil, style: .caption1,
                        font: DSFont.caption, color: DSColor.textTertiary),
            likes: text(.likes, size: style.metaFontSize, style: .footnote, font: DSFont.footnote,
                        color: meta.color),
            quote: text(.quote, size: nil, style: .footnote, font: DSFont.footnote, color: DSColor.textSecondary),
            quoteFill: quote.background.map(Self.color),
            quoteBar: quote.barColor.map(Self.color) ?? DSColor.separator,
            quoteBarWidth: CGFloat(quote.barWidth ?? Double(DSLayout.commentQuoteBarWidth)),
            badgeText: badge.color.map(Self.color) ?? DSColor.accent,
            badgeFill: badge.background.map(Self.color) ?? DSColor.accentLight,
            authorText: author.color.map(Self.color) ?? DSColor.accent,
            authorFill: author.background.map(Self.color) ?? DSColor.accentLight,
            reply: text(.reply, size: nil, style: .footnote, font: DSFont.footnote, color: DSColor.textSecondary),
            replyFill: reply.background.map(Self.color) ?? DSColor.quietCardFill,
            inlineReplies: style.inlineReplies ?? DSLayout.commentInlineReplies,
            hidden: hidden
        )
    }

    static func color(_ value: CommentListCSS.Color) -> Color {
        Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: value.alpha)
    }

    static func weight(_ value: Int) -> Font.Weight {
        switch value {
        case ..<200: return .ultraLight
        case ..<300: return .thin
        case ..<400: return .light
        case ..<500: return .regular
        case ..<600: return .medium
        case ..<700: return .semibold
        case ..<800: return .bold
        case ..<900: return .heavy
        default: return .black
        }
    }
}

extension EnvironmentValues {
    /// The look the comment cards under it wear; the App's own unless a list styled it.
    @Entry var commentListLook: CommentListLook = .app
}

extension GlobalSettings {
    /// 評論列表's style as the cards wear it.
    var commentListLook: CommentListLook {
        CommentListLook(style: commentListStyle, sheet: commentListSheet)
    }
}
