import SwiftUI
import UIKit

/// One tap a detail page hands its book source (`SourceCallBackService.tap`), and what the page
/// does itself when the source's script does not take it — legado's own action for that tap.
struct SourceCallBackTapRequest: Identifiable, Equatable {
    let id = UUID()
    let event: SourceCallBackEvent
    let source: BookSource
    let book: ReaderHTMLUtilities.LegadoSourceActionContext.BookSnapshot
    let runtimeVariables: [String: String]
    let result: String?
    let fallback: (@MainActor () -> Void)?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// What a detail page needs to offer a listening source its taps. Built per body pass from the
/// page's current book; every tap becomes a `SourceCallBackTapRequest` for `sourceCallBackTaps`.
@MainActor
struct BookDetailSourceCallBacks {
    let source: BookSource
    let book: ReaderHTMLUtilities.LegadoSourceActionContext.BookSnapshot
    let runtimeVariables: [String: String]
    let labels: [String]
    /// The shelf record whose cached chapters 清除快取 removes; nil before it is on the shelf.
    let shelfBookId: UUID?
    let bookStore: BookStore
    let send: (SourceCallBackTapRequest) -> Void

    /// Only for a source that listens; otherwise the page stays as it was.
    init?(
        source: BookSource?,
        book: ReaderHTMLUtilities.LegadoSourceActionContext.BookSnapshot,
        runtimeVariables: [String: String],
        labels: [String],
        shelfBookId: UUID?,
        bookStore: BookStore,
        send: @escaping (SourceCallBackTapRequest) -> Void
    ) {
        guard let source, SourceCallBackService.isListening(source) else { return nil }
        self.source = source
        self.book = book
        self.runtimeVariables = runtimeVariables
        self.labels = labels
        self.shelfBookId = shelfBookId
        self.bookStore = bookStore
        self.send = send
    }

    private func request(_ event: SourceCallBackEvent, result: String?, fallback: (@MainActor () -> Void)?) {
        send(SourceCallBackTapRequest(
            event: event, source: source, book: book,
            runtimeVariables: runtimeVariables, result: result, fallback: fallback
        ))
    }

    var gestures: BookDetailSourceGestures {
        let name = book.name
        let author = book.author
        let sourceKey = SearchSourceScope.sourceKey(for: source)
        return BookDetailSourceGestures(
            labels: labels,
            tapName: { request(.clickBookName, result: name) { SourceCallBackService.requestSearch(keyword: name) } },
            longPressName: { request(.longClickBookName, result: name) { SourceCallBackService.requestSearch(keyword: name) } },
            tapAuthor: { request(.clickAuthor, result: author) { SourceCallBackService.requestSearch(keyword: author) } },
            longPressAuthor: { request(.longClickAuthor, result: author) { SourceCallBackService.requestSearch(keyword: author) } },
            tapLabel: { label in
                request(.clickBookLabel, result: label) {
                    SourceCallBackService.requestSearch(keyword: label, sourceURL: sourceKey)
                }
            },
            // legado has no action of its own for a long-pressed label.
            longPressLabel: { label in request(.longClickBookLabel, result: label, fallback: nil) }
        )
    }

    var menuActions: BookDetailSourceMenuActions {
        let bookURL = book.bookURL
        let tocURL = book.tocURL
        let shelfBookId = shelfBookId
        let bookStore = bookStore
        return BookDetailSourceMenuActions(
            showsCustomButton: SourceCallBackService.showsCustomButton(source),
            onCustomButton: { request(.clickCustomButton, result: nil, fallback: nil) },
            onShare: { request(.clickShareBook, result: bookURL) { Self.share(bookURL) } },
            onCopyBookURL: { request(.clickCopyBookUrl, result: bookURL) { Self.copy(bookURL) } },
            onCopyTOCURL: { request(.clickCopyTocUrl, result: tocURL) { Self.copy(tocURL) } },
            onClearCache: {
                request(.clickClearCache, result: nil) {
                    guard let shelfBookId else { return }
                    BookSourceFetcher.shared.clearAllChapterCache(bookId: shelfBookId)
                    bookStore.clearAllCachedChapterFilenames(bookId: shelfBookId)
                }
            }
        )
    }

    private static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        BookSourceFormLoginView.presentToastAlert(message: localized("已複製"))
    }

    /// legado shares the book's URL; the system share sheet from the top of the stack, since
    /// the request can arrive from a menu that is still dismissing.
    private static func share(_ text: String) {
        guard !text.isEmpty, let presenter = BookSourceFormLoginView.topViewController() else { return }
        let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = presenter.view
        controller.popoverPresentationController?.sourceRect = CGRect(
            x: presenter.view.bounds.midX, y: presenter.view.bounds.minY + 44, width: 1, height: 1
        )
        presenter.present(controller, animated: true)
    }
}

extension View {
    /// Runs the source tap in `request`, shows a page its script builds, and does the page's
    /// own action when the script does not take the tap (legado `callBackBtn`'s `noCall`).
    func sourceCallBackTaps(_ request: Binding<SourceCallBackTapRequest?>) -> some View {
        modifier(SourceCallBackTapHost(request: request))
    }
}

private struct SourceCallBackTapHost: ViewModifier {
    @Binding var request: SourceCallBackTapRequest?
    @State private var page: ReaderHTMLUtilities.ReviewTarget?

    func body(content: Content) -> some View {
        content
            .task(id: request?.id) {
                guard let request else { return }
                let outcome = await SourceCallBackService.tap(
                    request.event, source: request.source, book: request.book,
                    runtimeVariables: request.runtimeVariables, result: request.result
                )
                if let target = outcome.page {
                    BookSourceFormLoginView.dismissToastAlert { page = target }
                }
                if SourceCallBackService.shouldFallBack(outcome) {
                    request.fallback?()
                }
                self.request = nil
            }
            .sheet(item: $page) { target in
                LegadoReviewBrowserView(target: target) { _ in page = nil }
                    .presentationDetents([.medium, .large])
            }
    }
}
