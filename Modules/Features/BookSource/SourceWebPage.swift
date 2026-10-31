import SwiftUI
import UIKit

/// 開啟網頁 and the copies of a source's URLs, from wherever a book of that source is shown:
/// the detail page's 「更多」 and the reader's. A reader debugging one rule of a source
/// (#84, #102, #104) starts from the page the rule reads, so every online book offers it.
@MainActor
enum SourceWebPage {
    /// Opens `url` with the source's headers and cookies the way Legado's reading menu opens
    /// its chapter URL. This is where a reader gets past a Cloudflare check or a login —
    /// nothing opens one by itself — and the cookies the page leaves serve the source's next
    /// requests.
    static func open(_ url: String, title: String, source: BookSource?) {
        guard !url.isEmpty else { return }
        // Resolving the source's headers can run its JS (`@js:` header rules), on its host.
        Task {
            var urlRequest: URLRequest?
            if let source {
                urlRequest = await BookSourceSession.session(for: source).host.run {
                    $0.sourceBrowserRequest(urlString: url)
                }
            }
            urlRequest = urlRequest ?? URL(string: url).map { URLRequest(url: $0) }
            let request = SourceBrowserRequest(
                url: url, title: title, urlRequest: urlRequest, awaitsResult: false)
            SourceBrowserPresenter.present(request) { _ in }
        }
    }

    /// Puts `url` on the pasteboard and says so. The detail page and the reader copy URLs as the
    /// source wrote them — Legado `,{options}` included, which is what 調試規則 takes.
    static func copy(_ url: String) {
        guard !url.isEmpty else { return }
        UIPasteboard.general.string = url
        BookSourceFormLoginView.presentToastAlert(message: localized("已複製"))
    }
}

/// What the reader's 「更多」 adds for debugging the chapter on screen: 複製正文網址 and
/// 調試正文 (調試規則 on its 正文 tab with the chapter's URL filled in). Both need the chapter's
/// URL and the source that reads it; a local book, or an online one whose source is gone, has
/// neither.
enum ReaderSourceDebugActions {
    static func ids(chapterURL: String?, hasSource: Bool) -> [ReaderSecondaryAction.ID] {
        guard hasSource, let chapterURL, !chapterURL.isEmpty else { return [] }
        return [.copyChapterURL, .debugContent]
    }
}

/// 調試正文's sheet: the source's 調試規則 with the chapter's URL already in 正文.
struct ReaderContentDebugTarget: Identifiable {
    let id = UUID()
    let source: BookSource
    let chapterURL: String
}
