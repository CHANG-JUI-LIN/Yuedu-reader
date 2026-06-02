import SwiftUI
import UIKit

private struct TOCBookHeader: View {
    let coverImagePath: String?
    let bookTitle: String
    let currentPage: Int
    let totalPages: Int
    let tocLayoutMode: TOCLayoutMode
    let onClose: () -> Void

    private var isVertical: Bool { tocLayoutMode == .verticalRTLColumns }

    private var coverSize: CGSize {
        CGSize(width: 48, height: 72)
    }

    private var titleFont: Font {
        .system(size: 16, weight: .semibold)
    }

    private var progressFont: Font {
        .system(size: 14, weight: .regular)
    }

    private var headerBottomPadding: CGFloat {
        28
    }

    private var closeButtonSize: CGFloat {
        50
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let coverPath = coverImagePath,
               let image = loadCoverImage(filename: coverPath) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: coverSize.width, height: coverSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .shadow(color: .black.opacity(0.16), radius: 6, x: 0, y: 3)
            } else {
                TitleCardPlaceholder(title: bookTitle)
                    .frame(width: coverSize.width, height: coverSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .shadow(color: .black.opacity(0.16), radius: 6, x: 0, y: 3)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(bookTitle)
                    .font(titleFont)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if totalPages > 0 {
                    HStack(spacing: 6) {
                        Text(localized("頁面"))
                            .foregroundColor(.secondary)

                        Text(String(format: localized("第 %d 頁（共 %d 頁）"), currentPage + 1, totalPages))
                            .foregroundColor(.primary)
                    }
                    .font(progressFont)
                }
            }

            Spacer(minLength: 12)

            Button(role: .cancel, action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color(uiColor: .systemGray))
                    .frame(width: closeButtonSize, height: closeButtonSize)
                    .background(
                        Circle()
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localized("關閉"))
        }
        .padding(.horizontal, 30)
        .padding(.bottom, headerBottomPadding)
        .padding(.top,15)

    }

    private func loadCoverImage(filename: String) -> UIImage? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}

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
            .font(.system(size: VerticalTOCLayout.fontSize, weight: .semibold))
            .frame(width: VerticalTOCLayout.textWidth, height: VerticalTOCLayout.glyphHeight)
    }

    private func compressedGlyph(_ s: String) -> some View {
        Text(s)
            .font(.system(size: VerticalTOCLayout.fontSize * 0.82, weight: .semibold))
            .frame(
                width: VerticalTOCLayout.textWidth,
                height: VerticalTOCLayout.glyphHeight * 0.55,
                alignment: .topTrailing
            )
            .offset(x: 3, y: -2)
    }

    private func rotatedLatinGlyph(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12, weight: .semibold))
            .rotationEffect(.degrees(90))
            .frame(width: VerticalTOCLayout.textWidth, height: VerticalTOCLayout.glyphHeight)
    }
}

private struct VerticalTOCColumn: View {
    let title: String
    let page: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                VerticalTOCText(
                    text: title,
                    isSelected: isSelected,
                    maxCharacters: 24
                )
                .foregroundStyle(isSelected ? Color.blue : Color.primary)
                .frame(width: VerticalTOCLayout.textWidth, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)

                Spacer(minLength: 8)

                Text("\(page)")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
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
                        .fill(Color.blue)
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
                            isSelected: chapter.id == currentChapterID
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
    let currentIndex: Int
    let currentChapterID: UUID?
    let onSelectChapter: (BookChapter) -> Void

    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            TOCBookHeader(
                coverImagePath: coverImagePath,
                bookTitle: bookTitle,
                currentPage: currentPage,
                totalPages: totalPages,
                tocLayoutMode: tocLayoutMode,
                onClose: { isPresented = false }
            )

            if tocLayoutMode == .verticalRTLColumns {
                VerticalTOCView(
                    chapters: chapters,
                    currentIndex: currentIndex,
                    currentChapterID: currentChapterID,
                    pageOffsets: pageOffsets,
                    onSelectChapter: { chapter in
                        onSelectChapter(chapter)
                        isPresented = false
                    }
                )
            } else {
                tocContent
            }
        }
        .background(Color(uiColor: .systemBackground))
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

                        Text("\(pageNumber(for: chapter))")
                            .font(.system(size: 18, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
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
