import SwiftUI
import SafariServices
import WebKit

struct RSSArticleReaderView: View {
    let articleID: String

    @StateObject private var store = RSSStore.shared
    @State private var readerMode: RSSArticleReaderMode = .reader
    @State private var isLoadingFullText = false
    @State private var fullTextError: String?
    @State private var selectedURL: URL?
    @State private var findRequestID: UUID?
    @State private var sourceFaviconURLs: [URL] = []

    private var article: RSSArticleRecord? {
        store.article(id: articleID)
    }

    private var source: RSSSource? {
        guard let article else { return nil }
        return store.sources.first { $0.id == article.sourceId }
    }

    var body: some View {
        Group {
            if let article {
                RSSArticleWebReaderView(
                    document: document(for: article),
                    restoreScrollY: article.readerScrollY,
                    findRequestID: $findRequestID,
                    onScrollYChange: { scrollY in
                        store.updateReaderScrollY(articleId: article.id, scrollY: scrollY)
                    },
                    onOpenURL: { url in
                        selectedURL = url
                    }
                )
                .ignoresSafeArea(.container, edges: .bottom)
                .navigationTitle(navigationTitle(for: article))
                .toolbarTitleDisplayMode(.large)
                .pageBackgroundToolbar(for: .rss)
                .toolbar(.hidden, for: .tabBar)
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button {
                            store.toggleFavorite(articleId: article.id)
                        } label: {
                            Label(
                                article.isFavorite ? localized("取消收藏") : localized("收藏"),
                                systemImage: article.isFavorite ? "star.fill" : "star"
                            )
                        }

                        Button {
                            findRequestID = UUID()
                        } label: {
                            Label(localized("搜尋文章"), systemImage: "magnifyingglass")
                        }

                        Menu {
                            Button {
                                toggleReaderMode()
                            } label: {
                                Label(readerModeToggleTitle, systemImage: readerModeToggleIcon)
                            }

                            if let url = URL(string: article.link) {
                                ShareLink(item: url) {
                                    Label(localized("分享"), systemImage: "square.and.arrow.up")
                                }

                                Button {
                                    selectedURL = url
                                } label: {
                                    Label(localized("原文"), systemImage: "safari")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                    }
                }
                .task(id: article.id) {
                    store.markRead(articleId: article.id, isRead: true)
                    await loadFullTextIfNeeded(article)
                }
                .task(id: sourceFaviconLoadKey(for: article)) {
                    await loadSourceFaviconURLs()
                }
            } else {
                ContentUnavailableView(
                    localized("目前沒有文章"),
                    systemImage: "newspaper",
                    description: Text(localized("重新載入"))
                )
            }
        }
        .sheet(item: $selectedURL) { url in
            SafariView(url: url)
        }
    }

    private var readerModeToggleTitle: String {
        switch readerMode {
        case .feed:
            return localized("Reader View")
        case .reader:
            return localized("顯示摘要")
        }
    }

    private var readerModeToggleIcon: String {
        switch readerMode {
        case .feed:
            return "doc.plaintext"
        case .reader:
            return "doc.text"
        }
    }

    private func document(for article: RSSArticleRecord) -> RSSArticleHTMLDocument {
        RSSArticleHTMLRenderer.render(
            article: article,
            source: source,
            mode: readerMode,
            bodyHTML: bodyHTML(for: article),
            fallbackText: fallbackText(for: article),
            sourceFaviconURLs: sourceFaviconURLs,
            isLoading: readerMode == .reader && isLoadingFullText,
            errorMessage: readerMode == .reader ? fullTextError : nil
        )
    }

    private func navigationTitle(for article: RSSArticleRecord) -> String {
        let title = article.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }
        return source?.name ?? localized("RSS 訂閱")
    }

    private func bodyHTML(for article: RSSArticleRecord) -> String {
        switch readerMode {
        case .feed:
            return article.contentHTML
        case .reader:
            if shouldPreferFeedContent(article) {
                return article.contentHTML
            }
            if let html = article.fullTextHTML?.trimmingCharacters(in: .whitespacesAndNewlines), !html.isEmpty {
                return html
            }
            return article.contentHTML
        }
    }

    private func fallbackText(for article: RSSArticleRecord) -> String {
        switch readerMode {
        case .feed:
            return article.summary
        case .reader:
            if let fullText = article.fullText?.trimmingCharacters(in: .whitespacesAndNewlines), !fullText.isEmpty {
                return fullText
            }
            return article.summary
        }
    }

    private func toggleReaderMode() {
        readerMode = readerMode == .reader ? .feed : .reader
        if readerMode == .reader, let article {
            Task { await loadFullTextIfNeeded(article) }
        }
    }

    private func loadFullTextIfNeeded(_ article: RSSArticleRecord) async {
        guard readerMode == .reader,
              !shouldPreferFeedContent(article),
              article.fullTextHTML?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              !isLoadingFullText else {
            return
        }

        isLoadingFullText = true
        fullTextError = nil
        defer { isLoadingFullText = false }

        do {
            // Legado sources with ruleContent extract the article body from the
            // article page using the source's own rule (Rss.getContent semantics).
            if let source, source.isLegadoRuleBased,
               source.ruleContent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
               !article.link.isEmpty,
               let html = try await LegadoRSSScraper.fetchArticleContent(source: source, articleLink: article.link) {
                store.updateFullText(
                    articleId: article.id,
                    text: RSSContentSanitizer.cleanText(html),
                    html: html
                )
                return
            }

            let extracted = try await RSSArticleContentLoader.loadFullText(for: article)
            store.updateFullText(articleId: article.id, text: extracted.text, html: extracted.html)
        } catch {
            fullTextError = fullTextErrorMessage(for: error)
        }
    }

    private func fullTextErrorMessage(for error: Error) -> String {
        if let loaderError = error as? RSSArticleContentLoaderError,
           case .httpStatus(403) = loaderError {
            return error.localizedDescription
        }
        return String(format: localized("全文抓取失敗：%@"), error.localizedDescription)
    }

    private func shouldPreferFeedContent(_ article: RSSArticleRecord) -> Bool {
        RSSArticleHTMLSanitizer.hasSubstantialStructuredContent(
            article.contentHTML,
            fallbackText: article.summary
        )
    }

    private func sourceFaviconLoadKey(for article: RSSArticleRecord) -> String {
        [
            article.sourceId,
            source?.url ?? "",
            source?.homepageURL ?? "",
            source?.displayFaviconURL ?? "",
            article.link
        ].joined(separator: "|")
    }

    @MainActor
    private func loadSourceFaviconURLs() async {
        guard let source else {
            sourceFaviconURLs = []
            return
        }
        let articleURL = article.flatMap { URL(string: $0.link)?.upgradedToHTTPS() }
        sourceFaviconURLs = await RSSFaviconResolver.candidateURLs(for: source, fallbackURL: articleURL)
    }
}

private struct RSSArticleWebReaderView: UIViewRepresentable {
    let document: RSSArticleHTMLDocument
    let restoreScrollY: Double
    @Binding var findRequestID: UUID?
    let onScrollYChange: (Double) -> Void
    let onOpenURL: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: "scrollPosition")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.backgroundColor = .clear
        webView.isOpaque = false
        webView.scrollView.backgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = false
        // Native Safari-style find-in-page (find bar, match count, prev/next,
        // highlighting). Also enables ⌘F with a hardware keyboard.
        webView.isFindInteractionEnabled = true
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self

        if context.coordinator.loadedHTML != document.html {
            context.coordinator.loadedHTML = document.html
            context.coordinator.pendingRestoreScrollY = restoreScrollY
            webView.loadHTMLString(document.html, baseURL: document.baseURL)
        }

        if let id = findRequestID, context.coordinator.lastFindRequestID != id {
            context.coordinator.lastFindRequestID = id
            webView.findInteraction?.presentFindNavigator(showingReplace: false)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: RSSArticleWebReaderView
        var loadedHTML: String?
        var pendingRestoreScrollY: Double?
        var lastFindRequestID: UUID?

        init(_ parent: RSSArticleWebReaderView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let scrollY = pendingRestoreScrollY ?? 0
            pendingRestoreScrollY = nil
            webView.evaluateJavaScript("window.yueduRestoreScrollY(\(scrollY));")
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                decisionHandler(.allow)
                return
            }

            parent.onOpenURL(url)
            decisionHandler(.cancel)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "scrollPosition" else { return }
            if let value = message.body as? Double {
                parent.onScrollYChange(value)
            } else if let value = message.body as? Int {
                parent.onScrollYChange(Double(value))
            }
        }
    }
}

#Preview("RSS Article Reader") {
    NavigationStack {
        RSSArticleReaderPreview()
    }
}

private struct RSSArticleReaderPreview: View {
    @StateObject private var store = RSSStore.shared
    private let source = RSSSource(
        id: "preview-source",
        name: "BBC News",
        url: "https://feedx.net/rss/bbc.xml",
        homepageURL: "https://bbc.com/news"
    )
    private let articleID = "https://example.com/rss-preview"

    var body: some View {
        RSSArticleReaderView(articleID: articleID)
            .onAppear {
                if !store.sources.contains(where: { $0.id == source.id }) {
                    store.addSource(source)
                }
                if store.article(id: articleID) == nil {
                    store.mergeFetchedItems([
                        RSSItem(
                            id: articleID,
                            title: "A supercut of context-free intertitles from Adam Curtis",
                            link: articleID,
                            pubDate: Date(),
                            description: "This is a preview summary paragraph.\n\nThe in-app reader renders RSS content as safe themed HTML.",
                            contentHTML: """
                            <p>This is a preview summary paragraph with a <a href="https://example.com/link">working link</a>.</p>
                            <p>The in-app reader renders RSS content as safe themed HTML.</p>
                            """,
                            author: "BBC News",
                            sourceId: source.id
                        )
                    ], for: source.id)
                    store.updateFullText(
                        articleId: articleID,
                        text: "This is extracted reader text.\n\nIt uses WebKit rendering, saved scroll position, toolbar actions, and find-in-article controls.",
                        html: """
                        <p>This is extracted reader text with <a href="https://example.com/full">reader-mode links</a>.</p>
                        <p>It uses WebKit rendering, saved scroll position, toolbar actions, and find-in-article controls.</p>
                        <figure><img src="https://example.com/image.jpg" alt="Preview image"><figcaption>Image captions survive sanitizing.</figcaption></figure>
                        """
                    )
                }
            }
    }
}
