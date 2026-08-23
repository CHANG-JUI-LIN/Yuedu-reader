import SwiftUI

/// One cover offered by 封面搜索 / 換封面.
///
/// `sourceId` is the book source the cover came from, and it travels with the
/// URL because that source's headers are what make a hotlink-protected CDN cover
/// download at all. Covers found on the open web have no source (`nil`).
struct CoverCandidate: Identifiable, Equatable {
    let id: String
    let coverUrl: String
    let sourceId: UUID?
    /// Book source name, or the site a web cover came from.
    let providerName: String

    init(id: String? = nil, coverUrl: String, sourceId: UUID?, providerName: String) {
        self.id = id ?? coverUrl
        self.coverUrl = coverUrl
        self.sourceId = sourceId
        self.providerName = providerName
    }
}

/// The cover grid both cover finders present: candidates stream in, the user taps
/// one. Kept in one place so the two screens can't drift on cell size, empty
/// state or VoiceOver wording.
struct CoverCandidateGrid: View {
    /// Book title, used for the placeholder art behind a cover that fails to load.
    let bookTitle: String
    let candidates: [CoverCandidate]
    let isSearching: Bool
    let hasSearched: Bool
    /// What to suggest when nothing was found — the two screens offer different
    /// next steps.
    let emptyHint: String
    let onSelect: (CoverCandidate) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columnCount: Int {
        dynamicTypeSize.isAccessibilitySize ? 2 : 3
    }

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: DSSpacing.md),
                    count: columnCount
                ),
                spacing: DSSpacing.lg
            ) {
                ForEach(candidates) { candidate in
                    coverCell(candidate)
                }
            }
            .padding(DSSpacing.lg)

            statusFooter
                .padding(.horizontal, DSSpacing.lg)
                .padding(.bottom, DSSpacing.xxl)
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        if isSearching {
            HStack(spacing: DSSpacing.sm) {
                ProgressView()
                Text(
                    candidates.isEmpty
                        ? localized("正在搜尋封面…")
                        : localized("正在搜尋更多封面…")
                )
                .font(DSFont.footnote)
                .foregroundStyle(DSColor.textSecondary)
            }
            .frame(maxWidth: .infinity)
        } else if candidates.isEmpty && hasSearched {
            VStack(spacing: DSSpacing.sm) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(DSFont.fixed(size: 36))
                    .foregroundStyle(DSColor.textSecondary.opacity(0.4))
                    // Decorative: the text below says the same thing.
                    .accessibilityHidden(true)
                Text(localized("沒有找到其他封面"))
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
                Text(emptyHint)
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, DSSpacing.xxl)
        }
    }

    private func coverCell(_ candidate: CoverCandidate) -> some View {
        let source = candidate.sourceId.flatMap { id in
            BookSourceStore.shared.sources.first { $0.id == id }
        }

        return Button {
            onSelect(candidate)
        } label: {
            VStack(spacing: DSSpacing.xs) {
                BookCoverImage(
                    coverURL: candidate.coverUrl,
                    title: bookTitle,
                    sourceBaseURL: source?.bookSourceUrl,
                    sourceHeaders: source?.parsedHeaders ?? [:]
                )
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                        .stroke(DSColor.textSecondary.opacity(0.2), lineWidth: 0.5)
                )

                Text(candidate.providerName)
                    .font(DSFont.caption2)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localized("封面") + "，" + candidate.providerName)
        .accessibilityHint(localized("點兩下使用這張封面"))
        .accessibilityAddTraits(.isButton)
    }
}

#Preview {
    CoverCandidateGrid(
        bookTitle: "紅樓夢",
        candidates: [],
        isSearching: true,
        hasSearched: true,
        emptyHint: localized("可以改用相簿裡的圖片，或直接貼上封面網址。"),
        onSelect: { _ in }
    )
}
