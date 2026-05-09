import SwiftUI

// MARK: - Online Book Detail + TOC

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
    @State private var detailInfo: OnlineBook? = nil
    private var source: BookSource? {
        sourceStore.sources.first(where: { $0.id == book.sourceId })
    }

    private var displayName: String {
        let d = detailInfo?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = book.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = d, !d.isEmpty { return d }
        return b.isEmpty ? localized("未知書名") : b
    }

    private var displayAuthor: String {
        let d = detailInfo?.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = book.author.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = d, !d.isEmpty { return d }
        if !b.isEmpty { return b }
        let candidates = [
            detailInfo?.intro ?? "",
            book.intro,
            detailInfo?.kind ?? "",
            book.kind
        ].joined(separator: "\n")
        if let extracted = Self.extractAuthorFromText(candidates), !extracted.isEmpty {
            return extracted
        }
        return localized("未知作者")
    }

    private static func extractAuthorFromText(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let pattern = "作者[：:]\\s*([^\\s|、，,]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayCoverUrl: String {
        let d = detailInfo?.coverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = book.coverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = d, !d.isEmpty { return d }
        return b
    }

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
                        bookHeader
                            .padding()

                        Divider()

                        actionButtons
                            .padding()

                        Divider()

                        tocSection
                    }
                }
            }
            .navigationTitle(localized("書籍詳情"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(localized("關閉")) { dismiss.wrappedValue.dismiss() }
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

    // MARK: Book Header
    private var bookHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
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

    // MARK: Action Buttons
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
                        openingReader ? localized("打開中…") : (alreadyInShelf ? "繼續閱讀" : "閱讀"),
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
                    Text(alreadyInShelf ? localized("已加入書架") : (addingToShelf ? localized("加入中…") : localized("加入書架")))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(alreadyInShelf ? Color(.systemGray4) : (chapters.isEmpty ? Color.gray : Color.blue))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(chapters.isEmpty || addingToShelf || alreadyInShelf)
        }
        .environment(\.locale, Locale(identifier: gs.localeIdentifier))
    }

    // MARK: TOC Section
    private var tocSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(localized("目錄"))
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
                HStack { Spacer(); ProgressView(localized("載入目錄…")); Spacer() }
                    .padding(.vertical, 32)
            } else if let err = tocError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
                    Text(err).font(DSFont.caption).foregroundColor(DSColor.textSecondary).multilineTextAlignment(.center)
                    Button(localized("重試")) { loadTOC() }
                        .font(DSFont.caption).foregroundColor(DSColor.accent)
                }
                .padding()
            } else if chapters.isEmpty {
                Text(localized("目錄為空")).font(DSFont.caption).foregroundColor(DSColor.textSecondary).padding()
            } else {
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
                    Text("…" + localized("共") + " \(chapters.count) " + localized("章"))
                        .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
        }
    }

    // MARK: Logic

    private func checkAlreadyInShelf() {
        alreadyInShelf = bookStore.books.contains(where: { $0.bookInfoURL == book.bookUrl })
        if alreadyInShelf {
            addedBookId = bookStore.books.first(where: { $0.bookInfoURL == book.bookUrl })?.id
        }
    }

    private func loadTOC() {
        guard let source else {
            tocError = localized("書源已被刪除")
            return
        }

        loadingTOC = true
        tocError = nil

        Task {
            do {
                var finalTocURL = book.bookUrl
                var currentRuntimeVariables = book.runtimeVariables
                // Always fetch the detail page to get full info (author, title, etc.) and extract the real TOC URL
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
                    runtimeVariables: currentRuntimeVariables,
                    onFirstPageReady: { firstChapters in
                        // First page ready — show immediately, don't wait for multi-page fetch
                        Task { @MainActor in
                            if self.chapters.isEmpty {
                                self.chapters = firstChapters
                                self.loadingTOC = false
                            }
                            if let bookId = self.addedBookId {
                                self.bookStore.updateOnlineChapters(bookId: bookId, chapters: firstChapters)
                            }
                        }
                    }
                )
                await MainActor.run {
                    chapters = tocPackage.chapters
                    loadingTOC = false
                    if let bookId = addedBookId {
                        bookStore.updateOnlineChapters(bookId: bookId, chapters: tocPackage.chapters)
                    }
                }
            } catch {
                await MainActor.run {
                    tocError = error.localizedDescription
                    loadingTOC = false
                }
            }
        }
    }

    /// Add to shelf without opening the reader.
    private func addToShelfOnly() {
        guard !alreadyInShelf, !chapters.isEmpty, let source else { return }
        addingToShelf = true
        let newBook = bookStore.addOnlineBook(
            name: displayName,
            author: displayAuthor == localized("未知作者") ? "" : displayAuthor,
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

    /// Ensure the book is on the shelf before opening, so the reader has a valid bookId.
    private func openReader() {
        guard !chapters.isEmpty, let source, !openingReader else { return }
        openingReader = true

        if alreadyInShelf, let existingId = addedBookId,
            let existing = bookStore.books.first(where: { $0.id == existingId })
        {
            if existing.onlineChapters?.isEmpty != false, !chapters.isEmpty {
                bookStore.updateOnlineChapters(bookId: existingId, chapters: chapters)
            }
            temporaryReaderBookId = nil
        } else {
            let tempBook = bookStore.addOnlineBook(
                name: displayName,
                author: displayAuthor == localized("未知作者") ? "" : displayAuthor,
                sourceId: source.id,
                bookInfoURL: book.bookUrl,
                tocURL: resolvedTOCURL,
                runtimeVariables: detailInfo?.runtimeVariables ?? book.runtimeVariables,
                chapters: chapters
            )
            addedBookId = tempBook.id
            temporaryReaderBookId = tempBook.id
        }

        openingReader = false
        showReader = true
    }

    // MARK: Cover Placeholder
    private func placeholderCover(size: CGSize) -> some View {
        Text(displayName)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(DSColor.textSecondary)
            .multilineTextAlignment(.leading)
            .lineLimit(6)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}
