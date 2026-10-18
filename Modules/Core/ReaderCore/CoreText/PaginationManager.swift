import YueduCoreText
import UIKit

struct PaginationRequest: Sendable {
    let spineIndex: Int
    @LayoutShared var attributedString: NSAttributedString
    let imagePage: HTMLAttributedStringBuilder.ImagePage?
    let pageBackgroundImage: UIImage?
    let pageBackgroundColor: UIColor?
    let darkPageBackgroundColor: UIColor?
    let anchorOffsets: [String: Int]
    let renderSize: CGSize
    let fontSize: CGFloat
    let paragraphSpacing: CGFloat
    let letterSpacing: CGFloat
    let contentInsets: UIEdgeInsets
    let revision: ContentRevision
    var writingMode: ReaderWritingMode = .horizontal
    var bottomJustify: Bool = false
}

struct PaginationResult: Sendable {
    let layout: CoreTextPaginator.ChapterLayout
}

@MainActor
final class PaginationManager {
    private let paginator: CoreTextPaginator

    init(paginator: CoreTextPaginator = CoreTextPaginator()) {
        self.paginator = paginator
    }

    func paginate(_ request: PaginationRequest) async -> PaginationResult {
        let layout = await paginator.paginate(
            spineIndex: request.spineIndex,
            attrStr: request.attributedString,
            imagePage: request.imagePage,
            pageBackgroundImage: request.pageBackgroundImage,
            pageBackgroundColor: request.pageBackgroundColor,
            darkPageBackgroundColor: request.darkPageBackgroundColor,
            anchorOffsets: request.anchorOffsets,
            renderSize: request.renderSize,
            fontSize: request.fontSize,
            paragraphSpacing: request.paragraphSpacing,
            letterSpacing: request.letterSpacing,
            contentInsets: request.contentInsets,
            writingMode: request.writingMode,
            bottomJustify: request.bottomJustify,
            revision: request.revision
        )
        return PaginationResult(layout: layout)
    }

    /// First-page-only pass for the two-phase chapter open. nil when a partial
    /// pass isn't applicable (image page); a cached full layout is returned as-is.
    func paginateFirstPage(_ request: PaginationRequest) async -> PaginationResult? {
        let layout = await paginator.paginateFirstPage(
            spineIndex: request.spineIndex,
            attrStr: request.attributedString,
            imagePage: request.imagePage,
            pageBackgroundImage: request.pageBackgroundImage,
            pageBackgroundColor: request.pageBackgroundColor,
            darkPageBackgroundColor: request.darkPageBackgroundColor,
            anchorOffsets: request.anchorOffsets,
            renderSize: request.renderSize,
            fontSize: request.fontSize,
            paragraphSpacing: request.paragraphSpacing,
            letterSpacing: request.letterSpacing,
            contentInsets: request.contentInsets,
            writingMode: request.writingMode,
            bottomJustify: request.bottomJustify,
            revision: request.revision
        )
        return layout.map { PaginationResult(layout: $0) }
    }

    func invalidate(reason: CoreTextPaginator.InvalidationReason) {
        paginator.invalidate(reason: reason)
    }
}
