import CoreText
import SwiftUI
import UIKit

// MARK: - Row content

/// What a book row on the 搜索 page says: its title, the grey tag after the title, the
/// author, and one line of detail. Decided once from the book, outside `body`.
struct SearchBookListRowContent: Equatable {
    let title: String
    /// The grey tag after the title — 有聲書 — or nil for every other book.
    let titleTag: String?
    let author: String
    let detail: String
    /// The detail as VoiceOver reads it, when its parts are joined for the eye (「在書架上 · 3 源」
    /// is heard as 「在書架上，3 源」); nil reads `detail`.
    var spokenDetail: String? = nil

    /// The whole row as VoiceOver reads it.
    var accessibilityLabel: String {
        [title, titleTag ?? "", author, spokenDetail ?? detail]
            .filter { !$0.isEmpty }
            .joined(separator: "，")
    }
}

extension SearchBookListRowContent {
    /// A search result, its detail where Apple Books puts a result's format and rating:
    /// what kind of book it is and how many sources carry it — 「小說 · 3 源」. An
    /// audiobook's tag already names its kind, so its detail is the count alone — 「1 源」.
    @MainActor
    init(result book: SearchBook) {
        let kind = book.inferredContentKind()
        let titleTag = Self.titleTag(for: kind)
        let sourceCount = String(format: localized("%d 源"), book.origins.count)
        self.init(
            title: book.displayName,
            titleTag: titleTag,
            author: book.author,
            detail: titleTag == nil
                ? [Self.kindTitle(kind), sourceCount].joined(separator: " · ")
                : sourceCount
        )
    }

    /// A book on the shelf, its detail how far it has been read — 「已讀 37%」.
    init(shelfBook book: ReadingBook) {
        self.init(
            title: book.title,
            titleTag: book.resolvedPipelineKind == .audio ? localized("有聲書") : nil,
            author: book.author,
            detail: book.currentPosition >= 0.99
                ? localized("已讀完")
                : String(format: localized("已讀 %d%%"), Int(book.currentPosition * 100))
        )
    }

    /// A book read that is not on the shelf: only its name, author and cover were kept, so
    /// its detail is when it was last read — 「2 小時前」.
    init(offShelfRecord record: OffShelfReadRecords.Record) {
        self.init(
            title: record.title,
            titleTag: nil,
            author: record.author,
            detail: record.lastRead.formatted(.relative(presentation: .named))
        )
    }

    static func kindTitle(_ kind: OnlineBookContentKind) -> String {
        switch kind {
        case .text: localized("小說")
        case .audio: localized("有聲書")
        case .manga: localized("漫畫")
        }
    }

    /// Audiobooks carry the tag, where the cover used to carry a headphones badge.
    static func titleTag(for kind: OnlineBookContentKind) -> String? {
        kind == .audio ? localized("有聲書") : nil
    }
}

// MARK: - Row

/// One book in the 搜索 page's lists, as Apple Books lists one in its search: a small
/// shadowed cover, and beside it, centred on the cover, the title (with its grey tag),
/// the author, and a line of detail in grey. The row's separator runs from the text to
/// the trailing margin. `IOS17SearchResultTableCell` draws the same row in UIKit.
struct SearchBookListRow<Cover: View>: View {
    let content: SearchBookListRowContent
    let cover: Cover

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale

    init(content: SearchBookListRowContent, @ViewBuilder cover: () -> Cover) {
        self.content = content
        self.cover = cover()
    }

    var body: some View {
        HStack(alignment: .center, spacing: DSLayout.searchListCoverTextSpacing) {
            SearchListCover { cover }
            VStack(alignment: .leading, spacing: 0) {
                titleText
                    .font(DSFont.footnote.weight(.semibold))
                    .foregroundStyle(DSColor.textPrimary)
                    .lineLimit(titleLineLimit)
                if !content.author.isEmpty {
                    Text(content.author)
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.textPrimary)
                        .lineLimit(detailLineLimit)
                }
                Text(content.detail)
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(detailLineLimit)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        .padding(.vertical, DSSpacing.sm)
        .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityLabel)
    }

    /// The title with its tag flowing after it, on the title's last line. A title long
    /// enough to truncate loses the tag with its end; the detail line still names the
    /// kind of book.
    private var titleText: Text {
        let title = Text(content.title)
        guard let tag = content.titleTag else { return title }
        let mark = SearchTitleTag.mark(
            for: tag,
            contentSize: UIContentSizeCategory(dynamicTypeSize),
            scale: displayScale
        )
        return title
            + Text(" ")
            + Text(Image(uiImage: mark.image).renderingMode(.template))
                .foregroundStyle(DSColor.textSecondary)
                .baselineOffset(mark.baselineOffset)
    }

    private var titleLineLimit: Int { dynamicTypeSize.isAccessibilitySize ? 4 : 2 }
    private var detailLineLimit: Int { dynamicTypeSize.isAccessibilitySize ? 2 : 1 }
}

/// A cover as Apple Books' search draws one: 2:3, nearly square corners, and a short
/// soft shadow under it. Decorative — the row reads the book.
struct SearchListCover<Artwork: View>: View {
    let artwork: Artwork

    init(@ViewBuilder artwork: () -> Artwork) {
        self.artwork = artwork()
    }

    var body: some View {
        artwork
            .frame(width: DSLayout.searchListCoverWidth, height: DSLayout.searchListCoverHeight)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.searchListCover, style: .continuous))
            .shadow(
                color: DSColor.searchListCoverShadow,
                radius: DSLayout.searchListCoverShadowRadius,
                y: DSLayout.searchListCoverShadowY
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Title tag

/// The grey tag after a title — Apple Books' language tag (「ZH」), here 有聲書: a rounded
/// box with its text cut out, so the page shows through as the text colour, white on
/// the grey in light mode as Apple's is. Drawn once per text and size as a template
/// image, which SwiftUI's `Text` and UIKit's labels both flow inline after the title and
/// tint with the secondary text colour.
@MainActor
enum SearchTitleTag {
    struct Mark {
        let image: UIImage
        /// Where the tag sits against the title's baseline: centred on the title's cap
        /// height, as Apple Books centres its tag.
        let baselineOffset: CGFloat
    }

    /// The tag for a row whose title is footnote semibold at `contentSize`.
    static func mark(for text: String, contentSize: UIContentSizeCategory, scale: CGFloat) -> Mark {
        let traits = UITraitCollection(preferredContentSizeCategory: contentSize)
        let postScriptName = GlobalAppTypography.activePostScriptName
        return mark(
            for: text,
            titleFont: GlobalAppTypography.uiFont(
                .footnote,
                postScriptName: postScriptName,
                weight: .semibold,
                compatibleWith: traits
            ),
            tagFont: GlobalAppTypography.uiFont(
                .caption2,
                postScriptName: postScriptName,
                weight: .semibold,
                compatibleWith: traits
            ),
            scale: scale
        )
    }

    static func mark(for text: String, titleFont: UIFont, tagFont: UIFont, scale: CGFloat) -> Mark {
        let key = "\(text)|\(tagFont.fontName)|\(tagFont.pointSize)|\(titleFont.capHeight)|\(scale)" as NSString
        if let cached = cache.object(forKey: key) { return cached.mark }
        let image = draw(text, font: tagFont, scale: scale)
        let mark = Mark(
            image: image,
            baselineOffset: -(image.size.height - titleFont.capHeight) / 2
        )
        cache.setObject(CachedMark(mark), forKey: key)
        return mark
    }

    private final class CachedMark {
        let mark: Mark
        init(_ mark: Mark) { self.mark = mark }
    }

    private static let cache = NSCache<NSString, CachedMark>()

    private static func draw(_ text: String, font: UIFont, scale: CGFloat) -> UIImage {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font])
        )
        // The glyphs' own outline around the baseline (y up), fallback fonts included,
        // so CJK and Latin text alike sit in the middle of the box.
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let size = CGSize(
            width: ceil(ink.width + DSLayout.titleTagHorizontalPadding * 2),
            height: ceil(font.capHeight + DSLayout.titleTagVerticalPadding * 2)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            UIBezierPath(
                roundedRect: CGRect(origin: .zero, size: size),
                cornerRadius: DSRadius.titleTag
            ).fill()
            let cg = context.cgContext
            cg.saveGState()
            // Core Text draws with y up, from the bottom of the box.
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
            cg.setBlendMode(.destinationOut)
            cg.textPosition = CGPoint(
                x: (size.width - ink.width) / 2 - ink.minX,
                y: (size.height - ink.height) / 2 - ink.minY
            )
            CTLineDraw(line, cg)
            cg.restoreGState()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }
}

#Preview("搜索列") {
    List {
        SearchBookListRow(content: SearchBookListRowContent(
            title: "斗羅大陸",
            titleTag: nil,
            author: "唐家三少",
            detail: "小說 · 3 源"
        )) {
            BookCoverImage(coverURL: "", title: "斗羅大陸", author: "唐家三少")
        }
        SearchBookListRow(content: SearchBookListRowContent(
            title: "三體：地球往事・黑暗森林・死神永生（廣播劇全集）",
            titleTag: "有聲書",
            author: "劉慈欣",
            detail: "有聲書 · 1 源"
        )) {
            BookCoverImage(coverURL: "", title: "三體", author: "劉慈欣")
        }
    }
    .listStyle(.plain)
}
