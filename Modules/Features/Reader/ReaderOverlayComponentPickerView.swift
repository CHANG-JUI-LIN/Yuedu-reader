import SwiftUI

struct ReaderOverlayComponentPickerSection: Identifiable, Equatable {
    let titleKey: String
    let kinds: [ReaderOverlayComponentKind]

    var id: String { titleKey }

    static let all: [ReaderOverlayComponentPickerSection] = [
        ReaderOverlayComponentPickerSection(
            titleKey: "基本",
            kinds: [.bookTitle, .chapterTitle, .customText]
        ),
        ReaderOverlayComponentPickerSection(
            titleKey: "進度",
            kinds: [.chapterPage, .totalProgressText, .progressBar]
        ),
        ReaderOverlayComponentPickerSection(
            titleKey: "時間",
            kinds: [.currentTime, .currentDate, .weekday]
        ),
        ReaderOverlayComponentPickerSection(
            titleKey: "狀態",
            kinds: [.battery]
        ),
        ReaderOverlayComponentPickerSection(
            titleKey: "統計",
            kinds: [.readingDuration, .remainingTime]
        )
    ]
}

enum ReaderOverlayDefaultPlacement {
    private static let candidates: [ReaderOverlayNormalizedPoint] = [
        ReaderOverlayNormalizedPoint(x: 0.5, y: 0.5),
        ReaderOverlayNormalizedPoint(x: 0.5, y: 0.36),
        ReaderOverlayNormalizedPoint(x: 0.5, y: 0.64),
        ReaderOverlayNormalizedPoint(x: 0.36, y: 0.5),
        ReaderOverlayNormalizedPoint(x: 0.64, y: 0.5),
        ReaderOverlayNormalizedPoint(x: 0.36, y: 0.36),
        ReaderOverlayNormalizedPoint(x: 0.64, y: 0.36),
        ReaderOverlayNormalizedPoint(x: 0.36, y: 0.64),
        ReaderOverlayNormalizedPoint(x: 0.64, y: 0.64),
        ReaderOverlayNormalizedPoint(x: 0.5, y: 0.22),
        ReaderOverlayNormalizedPoint(x: 0.5, y: 0.78),
        ReaderOverlayNormalizedPoint(x: 0.22, y: 0.5),
        ReaderOverlayNormalizedPoint(x: 0.78, y: 0.5)
    ]
    private static let minimumDistance = 0.1

    static func position(
        existing: [ReaderOverlayNormalizedPoint]
    ) -> ReaderOverlayNormalizedPoint {
        let existing = existing.map(\.clamped)
        if let openCandidate = candidates.first(where: { candidate in
            existing.allSatisfy { distance(candidate, $0) >= minimumDistance }
        }) {
            return openCandidate
        }

        return candidates.max { lhs, rhs in
            nearestDistance(from: lhs, to: existing)
                < nearestDistance(from: rhs, to: existing)
        } ?? ReaderOverlayNormalizedPoint(x: 0.5, y: 0.5)
    }

    private static func nearestDistance(
        from candidate: ReaderOverlayNormalizedPoint,
        to existing: [ReaderOverlayNormalizedPoint]
    ) -> Double {
        existing.map { distance(candidate, $0) }.min() ?? .greatestFiniteMagnitude
    }

    private static func distance(
        _ lhs: ReaderOverlayNormalizedPoint,
        _ rhs: ReaderOverlayNormalizedPoint
    ) -> Double {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}

enum ReaderOverlayComponentEditing {
    static func compatibleFormats(
        for kind: ReaderOverlayComponentKind
    ) -> [ReaderOverlayDisplayFormat] {
        switch kind {
        case .chapterPage:
            [.automatic, .compact, .fraction]
        case .currentTime:
            [.automatic, .hourMinute24, .hourMinute12]
        case .currentDate, .weekday, .readingDuration, .remainingTime:
            [.automatic, .compact, .detailed]
        case .bookTitle, .chapterTitle, .totalProgressText, .progressBar,
             .battery, .customText:
            []
        }
    }
}

extension ReaderOverlayComponentKind {
    var localizedTitle: String {
        switch self {
        case .bookTitle: localized("書名")
        case .chapterTitle: localized("章節名")
        case .chapterPage: localized("本章頁碼")
        case .totalProgressText: localized("總進度文字")
        case .progressBar: localized("進度條")
        case .currentTime: localized("目前時間")
        case .currentDate: localized("目前日期")
        case .weekday: localized("星期")
        case .battery: localized("電量")
        case .readingDuration: localized("本次閱讀時長")
        case .remainingTime: localized("預估剩餘時間")
        case .customText: localized("自訂文字")
        }
    }

    var systemImage: String {
        switch self {
        case .bookTitle: "book.closed"
        case .chapterTitle: "text.book.closed"
        case .chapterPage: "doc.text"
        case .totalProgressText: "percent"
        case .progressBar: "chart.bar.fill"
        case .currentTime: "clock"
        case .currentDate: "calendar"
        case .weekday: "calendar.day.timeline.leading"
        case .battery: "battery.100"
        case .readingDuration: "hourglass"
        case .remainingTime: "timer"
        case .customText: "textformat"
        }
    }
}

struct ReaderOverlayComponentPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let onSelect: (ReaderOverlayComponentKind) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(ReaderOverlayComponentPickerSection.all) { section in
                    Section(localized(section.titleKey)) {
                        ForEach(section.kinds, id: \.rawValue) { kind in
                            Button {
                                onSelect(kind)
                                dismiss()
                            } label: {
                                Label(kind.localizedTitle, systemImage: kind.systemImage)
                                    .font(DSFont.body)
                                    .foregroundStyle(DSColor.textPrimary)
                                    .frame(minHeight: DSLayout.readerAppleBooksControlSize)
                            }
                        }
                    }
                }
            }
            .themedAppSurface()
            .navigationTitle(localized("新增組件"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localized("取消")) { dismiss() }
                }
            }
        }
    }
}

#Preview {
    ReaderOverlayComponentPickerView { _ in }
}
