import SwiftUI

/// The origin a 單章換源 opens the 目錄 of — `BookOrigin` itself is not `Hashable`, and its
/// `id` is all a pushed page needs to keep its identity.
struct ChangeChapterSourcePick: Hashable {
    let origin: BookOrigin

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.origin.id == rhs.origin.id }
    func hash(into hasher: inout Hasher) { hasher.combine(origin.id) }
}

/// 單章換源's second step (Legado `ChangeChapterSourceDialog`'s 目錄): one origin's 目錄,
/// opened on the chapter that matches the one being read. A tap replaces the text of the
/// chapter being read with the chosen one (`onPick`); the book keeps its own 來源配置.
///
/// Pushed inside the 換源 sheet's own `NavigationStack`, never a second sheet.
struct ChangeChapterSourcePage: View {
    @ObservedObject var search: ChangeSourceSearch
    let origin: BookOrigin
    let onPick: (OnlineChapterRef, TOCPackage) async throws -> Void

    @State private var phase: Phase = .loading
    @State private var replacingOffset: Int?
    @State private var pickTask: Task<Void, Never>?
    @State private var pickError: String?

    enum Phase {
        case loading
        case loaded(TOCPackage, suggested: Int?)
        case failed(String)
    }

    var body: some View {
        content
            .scrollContentBackground(.hidden)
            .background(PageBackgroundView(scope: .settings).ignoresSafeArea())
            .navigationTitle(origin.sourceName)
            .toolbarTitleDisplayMode(.inline)
            .task { await load() }
            .onDisappear { pickTask?.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView(localized("正在載入目錄…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                UnavailableLabel(localized("載入失敗"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(localized("重試")) {
                    Task { await load() }
                }
            }
        case .loaded(let toc, let suggested):
            chapterList(toc, suggested: suggested)
        }
    }

    private func chapterList(_ toc: TOCPackage, suggested: Int?) -> some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(Array(toc.chapters.enumerated()), id: \.offset) { offset, ref in
                        row(offset: offset, ref: ref, toc: toc, isSuggested: offset == suggested)
                            .id(offset)
                    }
                } header: {
                    Text(localized("選擇要換上的章節"))
                        .foregroundStyle(DSColor.textSecondary)
                } footer: {
                    if let pickError {
                        Label(pickError, systemImage: "exclamationmark.triangle")
                            .dsSectionFooter(color: DSColor.destructive)
                    }
                }
                .interfaceSectionSurface()
            }
            .softScrollEdges()
            .onAppear {
                if let suggested { proxy.scrollTo(suggested, anchor: .center) }
            }
        }
    }

    private func row(offset: Int, ref: OnlineChapterRef, toc: TOCPackage, isSuggested: Bool) -> some View {
        Button {
            pick(offset: offset, ref: ref, toc: toc)
        } label: {
            HStack(spacing: DSSpacing.sm) {
                VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                    Text(ref.title)
                        .foregroundStyle(DSColor.textPrimary)
                    if isSuggested {
                        Text(localized("對應本章"))
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.accent)
                    }
                }
                Spacer()
                if replacingOffset == offset {
                    ProgressView()
                        .accessibilityLabel(localized("正在載入"))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(replacingOffset != nil)
    }

    private func load() async {
        phase = .loading
        do {
            let toc = try await search.prepareTOCPackage(for: origin)
            let suggested = search.target?.readingChapter.map { reading in
                ChapterAlignment.alignedIndex(
                    oldIndex: reading.index,
                    oldTitle: reading.title,
                    oldCount: reading.count,
                    newTitles: toc.chapters.map(\.title)
                )
            }
            phase = .loaded(toc, suggested: suggested)
        } catch {
            guard !Task.isCancelled else { return }
            AppLogger.network("⟐ changeChapterSource toc failed", error: error,
                              context: ["source": origin.sourceName])
            phase = .failed(error.localizedDescription)
        }
    }

    private func pick(offset: Int, ref: OnlineChapterRef, toc: TOCPackage) {
        pickTask?.cancel()
        pickError = nil
        replacingOffset = offset
        pickTask = Task { @MainActor in
            defer { replacingOffset = nil }
            do {
                try await onPick(ref, toc)
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.network("⟐ changeChapterSource replace failed", error: error,
                                  context: ["source": origin.sourceName, "chapter": ref.title])
                let message = String(format: localized("換章節失敗：%@"), error.localizedDescription)
                pickError = message
                UIAccessibility.post(notification: .announcement, argument: message)
            }
        }
    }
}

#if DEBUG
#Preview("單章換源，選章節") {
    NavigationStack {
        ChangeChapterSourcePage(
            search: .preview(origins: [ChangeSourceSearch.previewOrigin("示範來源配置")]),
            origin: ChangeSourceSearch.previewOrigin("示範來源配置"),
            onPick: { _, _ in }
        )
    }
}
#endif
