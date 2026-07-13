import SwiftUI

struct ReaderBookSearchItem: Identifiable, Hashable {
    let pageIndex: Int
    let chapterTitle: String
    let text: String

    var id: Int { pageIndex }
}

struct ReaderBookSearchView: View {
    let items: [ReaderBookSearchItem]
    let onSelect: (ReaderBookSearchItem) -> Void
    let onClose: () -> Void

    @State private var query = ""

    private var matches: [ReaderBookSearchItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return items.filter {
            $0.text.localizedCaseInsensitiveContains(trimmed)
                || $0.chapterTitle.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        localized("搜尋書籍"),
                        systemImage: "magnifyingglass",
                        description: Text(localized("輸入關鍵字搜尋目前已載入的章節與頁面。"))
                    )
                } else if matches.isEmpty {
                    ContentUnavailableView(
                        localized("無搜尋結果"),
                        systemImage: "doc.text.magnifyingglass",
                        description: Text(localized("換個關鍵字再試一次。"))
                    )
                } else {
                    List(matches) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                                Text(item.chapterTitle)
                                    .font(DSFont.subheadline.weight(.semibold))
                                    .foregroundStyle(DSColor.textPrimary)
                                    .lineLimit(1)
                                Text(snippet(for: item))
                                    .font(DSFont.caption)
                                    .foregroundStyle(DSColor.textSecondary)
                                    .lineLimit(2)
                                Text(String(format: localized("第 %d 頁"), item.pageIndex + 1))
                                    .font(DSFont.caption2)
                                    .foregroundStyle(DSColor.textSecondary)
                                    .monospacedDigit()
                            }
                            .padding(.vertical, DSSpacing.xs)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(PageBackgroundView(scope: .settings).ignoresSafeArea())
            .pageBackgroundToolbar(for: .settings)
            .navigationTitle(localized("搜尋書籍"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(localized("關閉"))
                }
            }
        }
        .searchable(text: $query, prompt: Text(localized("Search Book")))
    }

    private func snippet(for item: ReaderBookSearchItem) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let range = item.text.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive])
        else {
            return String(item.text.prefix(90))
        }
        let lower = item.text.index(range.lowerBound, offsetBy: -40, limitedBy: item.text.startIndex) ?? item.text.startIndex
        let upper = item.text.index(range.upperBound, offsetBy: 70, limitedBy: item.text.endIndex) ?? item.text.endIndex
        return String(item.text[lower..<upper])
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#Preview {
    ReaderBookSearchView(
        items: [
            ReaderBookSearchItem(
                pageIndex: 0,
                chapterTitle: "第一章",
                text: "這是一段用於預覽搜尋結果的閱讀內容。"
            ),
        ],
        onSelect: { _ in },
        onClose: {}
    )
}
