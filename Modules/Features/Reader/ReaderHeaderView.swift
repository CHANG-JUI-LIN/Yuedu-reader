import SwiftUI

// MARK: - Header Fields

/// Info fields the reader header (頁眉) can display. `allCases` order is the
/// rendering order when several fields share one position.
enum ReaderHeaderField: String, CaseIterable, Identifiable {
    case bookTitle
    case chapterTitle
    case page
    case progress
    case time
    case battery

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bookTitle: return localized("書名")
        case .chapterTitle: return localized("章節名")
        case .page: return localized("頁碼")
        case .progress: return localized("進度")
        case .time: return localized("時間")
        case .battery: return localized("電量")
        }
    }
}

/// Where a header field sits. Every field independently picks a slot, so all
/// of them can be stacked into the same slot (e.g. everything centered).
enum ReaderHeaderFieldPosition: String, CaseIterable, Identifiable {
    case hidden
    case left
    case center
    case right

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hidden: return localized("隱藏")
        case .left: return localized("靠左")
        case .center: return localized("置中")
        case .right: return localized("靠右")
        }
    }
}

enum ReaderHeaderLayout {
    static let defaultFieldPositions: [String: String] = [
        ReaderHeaderField.chapterTitle.rawValue: ReaderHeaderFieldPosition.left.rawValue
    ]

    static func fields(
        at position: ReaderHeaderFieldPosition,
        in positions: [String: String]
    ) -> [ReaderHeaderField] {
        ReaderHeaderField.allCases.filter { field in
            let raw = positions[field.rawValue] ?? ""
            return (ReaderHeaderFieldPosition(rawValue: raw) ?? .hidden) == position
        }
    }
}

// MARK: - Top Overlay Header

/// The info band above the text in paged mode; counterpart of
/// `ReaderOverlayFooter`. Full-bleed and self-offset by `safeAreaTop`, so it
/// lines up with the band `ReaderLayoutMetrics.topInset(safeTop:headerVisible:…)`
/// reserves during pagination.
struct ReaderOverlayHeader: View {
    let bookTitle: String
    let chapterTitle: String
    let pageInfo: String
    let progress: String
    let textColor: Color
    let safeAreaTop: CGFloat
    let topPadding: CGFloat
    let horizontalPadding: CGFloat

    @ObservedObject private var settings = GlobalSettings.shared
    @StateObject private var clock = ClockBatteryModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                fieldGroup(.left)
                    .frame(maxWidth: .infinity, alignment: .leading)
                fieldGroup(.center)
                    .layoutPriority(1)
                fieldGroup(.right)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: ReaderLayoutMetrics.headerHeight)
            .padding(.horizontal, horizontalPadding)
            .padding(.top, topPadding)
            Spacer(minLength: 0)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func fieldGroup(_ position: ReaderHeaderFieldPosition) -> some View {
        let fields = ReaderHeaderLayout.fields(at: position, in: settings.readerHeaderFieldPositions)
            .filter { isRenderable($0) }
        HStack(spacing: 6) {
            ForEach(fields.indices, id: \.self) { index in
                if index > 0 {
                    Text("·")
                }
                fieldView(fields[index])
            }
        }
        .font(DSFont.fixed(size: 10).monospacedDigit())
        .foregroundColor(textColor.opacity(0.4))
        .lineLimit(1)
    }

    @ViewBuilder
    private func fieldView(_ field: ReaderHeaderField) -> some View {
        switch field {
        case .battery:
            Image(systemName: clock.batteryIcon)
                .font(DSFont.fixed(size: 10))
        default:
            Text(textValue(of: field) ?? "")
                .truncationMode(.tail)
        }
    }

    private func isRenderable(_ field: ReaderHeaderField) -> Bool {
        switch field {
        case .battery:
            return true
        default:
            return textValue(of: field)?.isEmpty == false
        }
    }

    private func textValue(of field: ReaderHeaderField) -> String? {
        switch field {
        case .bookTitle: return bookTitle
        case .chapterTitle: return chapterTitle
        case .page: return pageInfo
        case .progress: return progress
        case .time: return clock.displayTime
        case .battery: return nil
        }
    }
}

// MARK: - ReaderView Hook

extension ReaderView {
    @ViewBuilder
    var topHeader: some View {
        if readerConfig.readerHeaderVisible {
            ReaderOverlayHeader(
                bookTitle: book?.title ?? snapshotBook?.title ?? "",
                chapterTitle: currentChapterTitle,
                pageInfo: chapterPageInfo,
                progress: totalProgressPercent,
                textColor: readerTheme.textColor,
                safeAreaTop: effectiveReaderSafeTop,
                topPadding: readerConfig.readerHeaderTopPadding,
                horizontalPadding: readerConfig.readerHeaderHorizontalPadding
            )
        }
    }
}

#Preview("ReaderOverlayHeader") {
    ZStack {
        Color(uiColor: ReaderTheme.sepia.uiBackgroundColor)
            .ignoresSafeArea()
        ReaderOverlayHeader(
            bookTitle: "示例書名",
            chapterTitle: "第一章 風雪山神廟",
            pageInfo: "3/12",
            progress: "45.23%",
            textColor: Color(uiColor: ReaderTheme.sepia.uiTextColor),
            safeAreaTop: 59,
            topPadding: ReaderLayoutMetrics.defaultHeaderTopPadding,
            horizontalPadding: ReaderLayoutMetrics.defaultHeaderHorizontalPadding
        )
    }
}
