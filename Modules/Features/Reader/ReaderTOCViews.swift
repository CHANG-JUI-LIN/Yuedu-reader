import SwiftUI
import UIKit



// MARK: - Combined Bookmarks & TOC Panel

private enum VerticalTOCLayout {
    static let columnWidth: CGFloat = 46
    static let textWidth: CGFloat = 24
    static let fontSize: CGFloat = 17
    static let glyphHeight: CGFloat = 21
    static let glyphSpacing: CGFloat = 0
    static let columnSpacing: CGFloat = 3
    static let topPadding: CGFloat = 20
    static let bottomPadding: CGFloat = 18
    static let selectedCornerRadius: CGFloat = 8
    static let selectedBarWidth: CGFloat = 3
}

private struct VerticalTOCText: View {
    let text: String
    var isSelected: Bool = false
    var maxCharacters: Int = 24

    private var chars: [String] {
        let cleaned = text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{3000}", with: "")

        let raw = Array(cleaned)
        let limited = raw.count > maxCharacters
            ? Array(raw.prefix(maxCharacters - 1)) + ["\u{2026}"]
            : raw

        return limited.map(String.init)
    }

    var body: some View {
        VStack(spacing: VerticalTOCLayout.glyphSpacing) {
            ForEach(Array(chars.enumerated()), id: \.offset) { _, ch in
                glyph(ch)
            }
        }
        .frame(width: VerticalTOCLayout.textWidth, alignment: .top)
    }

    @ViewBuilder
    private func glyph(_ ch: String) -> some View {
        switch VerticalGlyphClassifier.classify(Character(ch)) {
        case .cjk(let s),
             .verticalPunctuation(let s):
            cjkGlyph(s)
        case .compressedPunctuation(let s):
            compressedGlyph(s)
        case .rotatedLatin(let s):
            rotatedLatinGlyph(s)
        case .uprightLatin(let s):
            cjkGlyph(s)
        }
    }

    private func cjkGlyph(_ s: String) -> some View {
        Text(s)
            .font(DSFont.fixed(size: VerticalTOCLayout.fontSize, weight: .semibold))
            .frame(width: VerticalTOCLayout.textWidth, height: VerticalTOCLayout.glyphHeight)
    }

    private func compressedGlyph(_ s: String) -> some View {
        Text(s)
            .font(DSFont.fixed(size: VerticalTOCLayout.fontSize * 0.82, weight: .semibold))
            .frame(
                width: VerticalTOCLayout.textWidth,
                height: VerticalTOCLayout.glyphHeight * 0.55,
                alignment: .topTrailing
            )
            .offset(x: 3, y: -2)
    }

    private func rotatedLatinGlyph(_ s: String) -> some View {
        Text(s)
            .font(DSFont.fixed(size: 12, weight: .semibold))
            .rotationEffect(.degrees(90))
            .frame(width: VerticalTOCLayout.textWidth, height: VerticalTOCLayout.glyphHeight)
    }
}

private struct VerticalTOCColumn: View {
    let title: String
    let page: Int
    let isSelected: Bool
    let showsPageNumber: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                VerticalTOCText(
                    text: title,
                    isSelected: isSelected,
                    maxCharacters: 24
                )
                .foregroundStyle(isSelected ? DSColor.accent : Color.primary)
                .frame(width: VerticalTOCLayout.textWidth, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)

                Spacer(minLength: 8)

                if showsPageNumber {
                    Text("\(page)")
                        .font(DSFont.fixed(size: 15, weight: .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                }
            }
            .frame(width: VerticalTOCLayout.columnWidth, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, VerticalTOCLayout.topPadding)
            .padding(.bottom, VerticalTOCLayout.bottomPadding)
            .background {
                if isSelected {
                    RoundedRectangle(
                        cornerRadius: VerticalTOCLayout.selectedCornerRadius,
                        style: .continuous
                    )
                    .fill(isSelected ? Color.primary.opacity(0.07) : Color.clear)
                }
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle()
                        .fill(DSColor.accent)
                        .frame(width: VerticalTOCLayout.selectedBarWidth)
                }
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: VerticalTOCLayout.selectedCornerRadius,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct VerticalTOCView: View {
    let chapters: [BookChapter]
    let currentIndex: Int
    let currentChapterID: UUID?
    let pageOffsets: [UUID: Int]
    let showsPageNumbers: Bool
    let onSelectChapter: (BookChapter) -> Void

    @State private var didInitialTOCScroll = false

    private var reversedChapters: [BookChapter] {
        Array(chapters.reversed())
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: VerticalTOCLayout.columnSpacing) {
                    ForEach(Array(reversedChapters.enumerated()), id: \.element.id) { _, chapter in
                        let pageNumber: Int = {
                            if let offset = pageOffsets[chapter.id] {
                                return offset + 1
                            }
                            return chapter.index + 1
                        }()
                        VerticalTOCColumn(
                            title: chapter.title,
                            page: pageNumber,
                            isSelected: chapter.id == currentChapterID,
                            showsPageNumber: showsPageNumbers
                        ) {
                            onSelectChapter(chapter)
                        }
                        .id(chapter.index)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
            }
            .onAppear {
                guard !didInitialTOCScroll else { return }
                didInitialTOCScroll = true

                if chapters.first(where: { $0.index == currentIndex }) != nil {
                    proxy.scrollTo(currentIndex, anchor: .trailing)
                }
            }
        }
    }
}

struct ReaderMenuView: View {
    let chapters: [BookChapter]
    let coverImagePath: String?
    let bookTitle: String
    let currentPage: Int
    let totalPages: Int
    let tocLayoutMode: TOCLayoutMode
    let pageOffsets: [UUID: Int]
    let showsPageNumbers: Bool
    let currentIndex: Int
    let currentChapterID: UUID?
    let onSelectChapter: (BookChapter) -> Void

    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if totalPages > 0 {
                    Text(String(format: localized("第 %d 頁（共 %d 頁）"), currentPage + 1, totalPages))
                        .font(DSFont.fixed(size: 14))
                        .foregroundColor(.primary)
                        .padding(.vertical, DSSpacing.md)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                if tocLayoutMode == .verticalRTLColumns {
                    VerticalTOCView(
                        chapters: chapters,
                        currentIndex: currentIndex,
                        currentChapterID: currentChapterID,
                        pageOffsets: pageOffsets,
                        showsPageNumbers: showsPageNumbers,
                        onSelectChapter: { chapter in
                            onSelectChapter(chapter)
                            isPresented = false
                        }
                    )
                } else {
                    tocContent
                }
            }
            .navigationTitle(bookTitle)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel(localized("完成"))
                }
            }
            .background(Color(uiColor: .systemBackground))
        }
    }

    private func pageNumber(for chapter: BookChapter) -> Int {
        if let offset = pageOffsets[chapter.id] {
            return offset + 1
        }
        return chapter.index + 1
    }

    private var tocContent: some View {
        ScrollViewReader { proxy in
            List(chapters) { chapter in
                Button {
                    onSelectChapter(chapter)
                    isPresented = false
                } label: {
                    HStack(spacing: 0) {
                        if chapter.level > 0 {
                            Color.clear
                                .frame(width: CGFloat(chapter.level) * 16)
                        }

                        Text(chapter.title)
                            .font(
                                chapter.level == 0
                                ? .system(size: 14, weight: .semibold)
                                : .system(size: 12, weight: .regular)
                            )
                            .foregroundColor(.primary)
                            .lineLimit(2)

                        Spacer()

                        if showsPageNumbers {
                            Text("\(pageNumber(for: chapter))")
                                .font(DSFont.fixed(size: 18, weight: .regular, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(height: 48)
                    .padding(.horizontal, 30)
                    .background {
                        if chapter.id == currentChapterID {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.primary.opacity(0.07))
                        }
                    }
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden, edges: chapter.id == chapters.first?.id ? .top : [])
                .listRowSeparator(.visible, edges: .bottom)
                .listRowSeparatorTint(Color.secondary.opacity(0.18))
                .id(chapter.index)
            }
            .listStyle(.plain)
            .contentMargins(.top, 0, for: .scrollContent)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if chapters.first(where: { $0.index == currentIndex }) != nil {
                        withAnimation {
                            proxy.scrollTo(currentIndex, anchor: .center)
                        }
                    }
                }
            }
        }
    }
}
