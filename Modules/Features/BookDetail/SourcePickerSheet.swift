import SwiftUI

// MARK: - Source picker (換源 among a search result's origins)

/// The sources a search result was found in, as a plain list with the current one
/// checked — the way iOS marks the selected row of a choice list.
struct SourcePickerSheet: View {
    let searchBook: SearchBook
    let currentOrigin: BookOrigin?
    let onSelectOrigin: (BookOrigin) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(searchBook.origins) { origin in
                SourceOriginRow(
                    origin: origin,
                    kind: searchBook.contentKind(for: origin) ?? .text,
                    isCurrent: origin.id == currentOrigin?.id,
                    action: {
                        onSelectOrigin(origin)
                        dismiss()
                    }
                )
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .softScrollEdges()
            .background(PageBackgroundView(scope: .global).ignoresSafeArea())
            .pageBackgroundToolbar(for: .global)
            .navigationTitle(
                String(format: localized("選擇來源（%d 個）"), searchBook.origins.count)
            )
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SourceSheetCloseButton { dismiss() }
                }
            }
        }
    }
}

// MARK: - Shared pieces

/// One source in a 換源 list: its name and latest chapter, the content kind when it
/// is not plain text (a different kind asks before switching), and a checkmark on
/// the source the page currently shows.
struct SourceOriginRow: View {
    let origin: BookOrigin
    let kind: OnlineBookContentKind
    let isCurrent: Bool
    let action: () -> Void

    private var kindLabel: String? {
        switch kind {
        case .text: nil
        case .audio: localized("有聲書")
        case .manga: localized("漫畫")
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DSSpacing.md) {
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    HStack(spacing: DSSpacing.sm) {
                        Text(origin.sourceName)
                            .font(DSFont.body)
                            .foregroundStyle(DSColor.textPrimary)
                            .lineLimit(1)
                        if let kindLabel {
                            Text(kindLabel)
                                .font(DSFont.caption)
                                .foregroundStyle(DSColor.textSecondary)
                                .padding(.horizontal, DSSpacing.sm)
                                .padding(.vertical, DSSpacing.xs)
                                .background(DSColor.surfaceTertiary, in: Capsule())
                        }
                    }
                    if !origin.lastChapter.isEmpty {
                        Text(origin.lastChapter)
                            .font(DSFont.footnote)
                            .foregroundStyle(DSColor.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: DSSpacing.sm)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(DSFont.body.weight(.semibold))
                        .foregroundStyle(DSColor.accent)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: DSLayout.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(kindLabel ?? "")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// Leading close button of the 換源 sheets.
struct SourceSheetCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(localized("關閉"), systemImage: "xmark")
                .labelStyle(.iconOnly)
        }
    }
}

#Preview("選擇來源") {
    let sourceId = UUID()
    let origins = ["示範來源配置", "另一個來源配置"].enumerated().map { index, name in
        BookOrigin(
            sourceId: index == 0 ? sourceId : UUID(), sourceName: name,
            bookUrl: "https://example.com/\(index)", tocUrl: "", coverUrl: "",
            intro: "", lastChapter: "第 1450 章 終章", wordCount: "", kind: "",
            runtimeVariables: nil
        )
    }
    let book = SearchBook(name: "斗羅大陸", author: "唐家三少", origins: origins)
    return SourcePickerSheet(searchBook: book, currentOrigin: origins.first, onSelectOrigin: { _ in })
}
