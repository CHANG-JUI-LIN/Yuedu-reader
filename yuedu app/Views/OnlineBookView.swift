import SwiftUI

// MARK: - 線上書籍詳情 + 目錄

struct OnlineBookView: View {
    let book: OnlineBook
    @EnvironmentObject var bookStore: BookStore
    @Environment(\.appDependencies) private var dependencies
    @ObservedObject private var sourceStore = BookSourceStore.shared
    @ObservedObject private var gs = GlobalSettings.shared
    @Environment(\.presentationMode) var dismiss

    @State private var chapters: [OnlineChapterRef] = []
    @State private var loadingTOC = false
    @State private var tocError: String? = nil
    @State private var addingToShelf = false
    @State private var openingReader = false
    @State private var addedBookId: UUID? = nil
    @State private var showReader = false
    @State private var alreadyInShelf = false
    @State private var temporaryReaderBookId: UUID? = nil
    /// 從詳情頁抓取的完整資訊（作者等），優先於搜尋結果
    @State private var detailInfo: OnlineBook? = nil
    private var source: BookSource? {
        sourceStore.sources.first(where: { $0.id == book.sourceId })
    }

    /// 顯示用書名：詳情頁有則用詳情，否則用搜尋結果
    private var displayName: String {
        let d = detailInfo?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = book.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = d, !d.isEmpty { return d }
        return b.isEmpty ? gs.t("未知書名") : b
    }

    /// 顯示用作者：詳情頁有則用詳情，否則用搜尋結果；若皆空則從 intro/kind 提取「作者:XXX」
    private var displayAuthor: String {
        let d = detailInfo?.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = book.author.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = d, !d.isEmpty { return d }
        if !b.isEmpty { return b }
        // 備援：從 intro 或 kind 提取「作者:XXX」或「作者：XXX」
        let candidates = [
            detailInfo?.intro ?? "",
            book.intro,
            detailInfo?.kind ?? "",
            book.kind
        ].joined(separator: "\n")
        if let extracted = Self.extractAuthorFromText(candidates), !extracted.isEmpty {
            return extracted
        }
        return gs.t("未知作者")
    }

    /// 從文字中提取「作者:XXX」或「作者：XXX」格式
    private static func extractAuthorFromText(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let pattern = "作者[：:]\\s*([^\\s|、，,]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 顯示用封面：詳情頁優先
    private var displayCoverUrl: String {
        let d = detailInfo?.coverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = book.coverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = d, !d.isEmpty { return d }
        return b
    }

    /// 顯示用簡介：詳情頁優先
    private var displayIntro: String {
        let d = detailInfo?.intro.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = book.intro.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = d, !d.isEmpty { return d }
        return b
    }

    private var resolvedTOCURL: String? {
        let detailed = detailInfo?.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if let detailed, !detailed.isEmpty { return detailed }
        let fallback = book.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? nil : fallback
    }

    var body: some View {
        NavigationView {
            AdaptiveSheetContainer(maxWidth: 920) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // 書籍頭部資訊
                        bookHeader
                            .padding()

                        Divider()

                        // 操作按鈕
                        actionButtons
                            .padding()

                        Divider()

                        // 目錄
                        tocSection
                    }
                }
            }
            .navigationTitle(gs.t("書籍詳情"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(gs.t("關閉")) { dismiss.wrappedValue.dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showReader, onDismiss: {
                if let tempId = temporaryReaderBookId {
                    bookStore.delete(bookId: tempId)
                    temporaryReaderBookId = nil
                    if addedBookId == tempId {
                        addedBookId = nil
                    }
                    checkAlreadyInShelf()
                }
            }) {
                if let bid = addedBookId {
                    ReaderView(bookId: bid)
                        .environmentObject(bookStore)
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            checkAlreadyInShelf()
            if chapters.isEmpty { loadTOC() }
        }
    }

    // MARK: 書籍頭部
    private var bookHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                // 封面
                AsyncImage(url: URL(string: displayCoverUrl)) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                            .frame(width: 90, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .shadow(radius: 4)
                    default:
                        placeholderCover(size: CGSize(width: 90, height: 120))
                    }
                }
                .frame(width: 90, height: 120)

                VStack(alignment: .leading, spacing: 8) {
                    Text(displayName)
                        .font(.title2.weight(.bold)).lineLimit(2).foregroundColor(.primary)
                    HStack(spacing: 6) {
                        Image(systemName: "person.fill")
                            .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                        Text(displayAuthor)
                            .font(.subheadline.weight(.medium)).foregroundColor(.primary)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                            .font(DSFont.caption).foregroundColor(DSColor.accent)
                        Text(book.sourceName)
                            .font(DSFont.caption).foregroundColor(DSColor.accent)
                    }
                    // 僅當 intro 為空時顯示 wordCount/lastChapter，避免與 intro 重複
                    if displayIntro.isEmpty {
                        if !book.wordCount.isEmpty {
                            Label(book.wordCount, systemImage: "text.word.spacing")
                                .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                        }
                        if !book.lastChapter.isEmpty {
                            Label(book.lastChapter, systemImage: "bookmark")
                                .font(DSFont.caption).foregroundColor(DSColor.textSecondary).lineLimit(1)
                        }
                    }
                }
            }

            if !displayIntro.isEmpty {
                Text(displayIntro)
                    .font(.subheadline)
                    .foregroundColor(DSColor.textSecondary)
                    .lineLimit(6)
            }
        }
    }

    // MARK: 操作按鈕
    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                openReader()
            } label: {
                HStack(spacing: 8) {
                    if openingReader {
                        ProgressView().scaleEffect(0.8).tint(.white)
                    }
                    Label(
                        openingReader ? gs.t("打開中…") : (alreadyInShelf ? "繼續閱讀" : "閱讀"),
                        systemImage: "book.open"
                    )
                }
                    .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(chapters.isEmpty ? Color.gray : Color.green)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(chapters.isEmpty || openingReader || addingToShelf)

            Button {
                addToShelfOnly()
            } label: {
                HStack(spacing: 8) {
                    if addingToShelf {
                        ProgressView().scaleEffect(0.8).tint(.white)
                    }
                    Text(alreadyInShelf ? gs.t("已加入書架") : (addingToShelf ? gs.t("加入中…") : gs.t("加入書架")))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(alreadyInShelf ? Color(.systemGray4) : (chapters.isEmpty ? Color.gray : Color.blue))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(chapters.isEmpty || addingToShelf || alreadyInShelf)
        }
        .environment(\.locale, Locale(identifier: gs.appLanguage.rawValue))
    }

    // MARK: 目錄區
    private var tocSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(gs.t("目錄"))
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                Spacer()
                if !chapters.isEmpty {
                    Text("\(chapters.count) 章")
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                        .padding(.trailing, 16)
                }
            }
            Divider()

            if loadingTOC {
                HStack { Spacer(); ProgressView(gs.t("載入目錄…")); Spacer() }
                    .padding(.vertical, 32)
            } else if let err = tocError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
                    Text(err).font(DSFont.caption).foregroundColor(DSColor.textSecondary).multilineTextAlignment(.center)
                    Button(gs.t("重試")) { loadTOC() }
                        .font(DSFont.caption).foregroundColor(DSColor.accent)
                }
                .padding()
            } else if chapters.isEmpty {
                Text(gs.t("目錄為空")).font(DSFont.caption).foregroundColor(DSColor.textSecondary).padding()
            } else {
                // 顯示前 50 章預覽，點擊章節直接進入閱讀
                let preview = Array(chapters.prefix(50))
                ForEach(preview) { ch in
                    Button {
                        openReader()
                    } label: {
                        HStack {
                            Text(ch.title)
                                .font(.body)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 16)
                }
                if chapters.count > 50 {
                    Text("…" + gs.t("共") + " \(chapters.count) " + gs.t("章"))
                        .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
        }
    }

    // MARK: 邏輯

    private func checkAlreadyInShelf() {
        alreadyInShelf = bookStore.books.contains(where: { $0.bookInfoURL == book.bookUrl })
        if alreadyInShelf {
            addedBookId = bookStore.books.first(where: { $0.bookInfoURL == book.bookUrl })?.id
        }
    }

    private func loadTOC() {
        guard let source else {
            tocError = gs.t("書源已被刪除")
            return
        }

        loadingTOC = true
        tocError = nil

        Task {
            do {
                var finalTocURL = book.bookUrl
                var currentRuntimeVariables = book.runtimeVariables
                // 始終抓取詳情頁：取得作者、書名等完整資訊，並提取真正的目錄 URL
                if !book.bookUrl.isEmpty {
                    let infoPackage = try await dependencies.bookSourceFetcher.fetchBookInfoPackage(
                        url: book.bookUrl,
                        source: source,
                        runtimeVariables: currentRuntimeVariables
                    )
                    currentRuntimeVariables = infoPackage.runtimeVariables
                    await MainActor.run { detailInfo = infoPackage.onlineBook }
                    if !infoPackage.tocUrl.isEmpty {
                        finalTocURL = infoPackage.tocUrl
                    }
                }
                let tocPackage = try await dependencies.bookSourceFetcher.fetchTOCPackage(
                    tocUrl: finalTocURL,
                    source: source,
                    runtimeVariables: currentRuntimeVariables
                )
                await MainActor.run {
                    chapters = tocPackage.chapters
                    loadingTOC = false
                }
            } catch {
                await MainActor.run {
                    tocError = error.localizedDescription
                    loadingTOC = false
                }
            }
        }
    }

    /// 僅加入書架，不開啟閱讀器
    private func addToShelfOnly() {
        guard !alreadyInShelf, !chapters.isEmpty, let source else { return }
        addingToShelf = true
        let newBook = bookStore.addOnlineBook(
            name: displayName,
            author: displayAuthor == gs.t("未知作者") ? "" : displayAuthor,
            sourceId: source.id,
            bookInfoURL: book.bookUrl,
            tocURL: resolvedTOCURL,
            runtimeVariables: detailInfo?.runtimeVariables ?? book.runtimeVariables,
            chapters: chapters
        )
        addedBookId = newBook.id
        addingToShelf = false
        alreadyInShelf = true
    }

    /// 閱讀前確保已在書架，避免閱讀器沒有 bookId 可用
    private func openReader() {
        guard !chapters.isEmpty, let source, !openingReader else { return }
        openingReader = true

        let readingBook: ReadingBook
        if alreadyInShelf, let existingId = addedBookId,
            let existing = bookStore.books.first(where: { $0.id == existingId })
        {
            readingBook = existing
            temporaryReaderBookId = nil
        } else {
            let tempBook = bookStore.addOnlineBook(
                name: displayName,
                author: displayAuthor == gs.t("未知作者") ? "" : displayAuthor,
                sourceId: source.id,
                bookInfoURL: book.bookUrl,
                tocURL: resolvedTOCURL,
                runtimeVariables: detailInfo?.runtimeVariables ?? book.runtimeVariables,
                chapters: chapters
            )
            addedBookId = tempBook.id
            temporaryReaderBookId = tempBook.id
            readingBook = tempBook
        }

        Task {
            await MainActor.run {
                openingReader = false
                showReader = true
            }

            if let firstIndex = readingBook.onlineChapters?.first?.index {
                _ = try? await dependencies.chapterFetcher.fetchChapter(
                    book: readingBook,
                    chapterIndex: firstIndex,
                    priority: .jump,
                    store: bookStore
                )
            }
        }
    }

    // MARK: 封面佔位
    private func placeholderCover(size: CGSize) -> some View {
        Text(displayName)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(DSColor.textSecondary)
            .multilineTextAlignment(.leading)
            .lineLimit(6)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}
