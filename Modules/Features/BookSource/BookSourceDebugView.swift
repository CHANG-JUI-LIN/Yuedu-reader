import SwiftUI
import UIKit

/// 書源除錯大師 — the HTTP exchanges behind one book source.
///
/// Presented as a sheet from the book-source editor and the login sheet, so
/// `.inline` title mode and `xmark` leading (docs/design.md §2.2).
struct BookSourceDebugView: View {
    @ObservedObject private var debugger = WebCrawlerDebugger.shared
    @Environment(\.dismiss) private var dismiss
    @State private var typeFilter: WebCrawlerDebugger.LogEntry.LogType?
    @State private var showCopiedAlert = false

    private var filteredLogs: [WebCrawlerDebugger.LogEntry] {
        guard let typeFilter else { return debugger.logs.reversed() }
        return debugger.logs.reversed().filter { $0.type == typeFilter }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(localized("啟用網路除錯錄製"), isOn: $debugger.isRecording)
                    Toggle(localized("包含規則比對"), isOn: $debugger.includesParseEvents)
                        .disabled(!debugger.isRecording)
                } header: {
                    Text(localized("錄製"))
                } footer: {
                    Text(localized("開啟後重新搜索或開啟章節，就會記下每一次請求與回應。規則比對數量遠多於網路請求，預設不收。"))
                }
                .interfaceSectionSurface()

                Section {
                    Picker(localized("類型"), selection: $typeFilter) {
                        Text(localized("全部")).tag(WebCrawlerDebugger.LogEntry.LogType?.none)
                        ForEach(WebCrawlerDebugger.LogEntry.LogType.allCases, id: \.self) { type in
                            Text(type.localizedName)
                                .tag(WebCrawlerDebugger.LogEntry.LogType?.some(type))
                        }
                    }
                } header: {
                    Text(localized("篩選"))
                }
                .interfaceSectionSurface()

                Section {
                    ShareLink(
                        item: BookSourceDebugExportFile(
                            filename: BookSourceDebugExportFile.filename(),
                            entries: debugger.logs
                        ),
                        preview: SharePreview(localized("書源除錯大師"))
                    ) {
                        Label(localized("匯出紀錄"), systemImage: "square.and.arrow.up")
                    }
                    .disabled(debugger.logs.isEmpty)
                } header: {
                    Text(localized("操作"))
                }
                .interfaceSectionSurface()

                Section {
                    if filteredLogs.isEmpty {
                        emptyState
                    } else {
                        ForEach(filteredLogs) { entry in
                            BookSourceDebugLogRow(entry: entry)
                        }
                    }
                } header: {
                    Text(localized("紀錄"))
                }
                .interfaceSectionSurface()
            }
            .navigationTitle(localized("書源除錯大師"))
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .settings)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel(localized("關閉"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // 匯出紀錄 is deliberately NOT here: a `ShareLink` inside a `Menu`
                    // loses its share sheet to the menu's own dismissal before iOS 18
                    // (`MenuShareLinkPresentationPolicy`). It lives in the 操作 section
                    // instead, exactly like 診斷與回報's export link. Only non-presenting
                    // actions belong in this menu.
                    Menu {
                        Button {
                            UIPasteboard.general.string = exportText
                            showCopiedAlert = true
                        } label: {
                            Label(localized("複製全部"), systemImage: "doc.on.doc")
                        }
                        Divider()
                        Button(role: .destructive) {
                            debugger.clear()
                        } label: {
                            Label(localized("清空紀錄"), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel(localized("更多動作"))
                    .disabled(debugger.logs.isEmpty)
                }
            }
            .alert(localized("已複製"), isPresented: $showCopiedAlert) {
                Button(localized("好"), role: .cancel) {}
            } message: {
                Text(localized("除錯紀錄已複製到剪貼簿。"))
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(localized("沒有紀錄"), systemImage: "antenna.radiowaves.left.and.right.slash")
        } description: {
            Text(debugger.isRecording
                 ? localized("錄製中。回到書源做一次搜索或開啟章節，請求就會出現在這裡。")
                 : localized("先打開上面的錄製開關，再回到書源操作一次。"))
        }
    }

    /// Built on demand — this is only read inside 複製全部's action closure, so the
    /// formatting cost is paid on tap and never on a layout pass. The share export
    /// renders through the same function; see `BookSourceDebugExportFile`.
    private var exportText: String {
        BookSourceDebugExportFile.render(entries: debugger.logs)
    }
}

/// Its own `View` struct so `List`/`Form` defers building the expanded detail until
/// the row scrolls in — see the note at the top of `BookSourceRowViews.swift`.
struct BookSourceDebugLogRow: View {
    let entry: WebCrawlerDebugger.LogEntry
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasDetail: Bool { entry.detail != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
                Image(systemName: entry.type.symbolName)
                    .font(DSFont.footnote)
                    .foregroundStyle(entry.type.tint)
                    .accessibilityHidden(true)

                Text(entry.message)
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textPrimary)
                    .lineLimit(isExpanded ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(entry.timestamp, style: .time)
                    .font(DSFont.caption2)
                    .foregroundStyle(DSColor.textSecondary)
            }

            if let url = entry.url {
                Text(url)
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.accent)
                    .lineLimit(isExpanded ? nil : 1)
            }

            if isExpanded, let detail = entry.detail {
                detailView(detail)
                    .padding(.top, DSSpacing.xs)
            }
        }
        .padding(.vertical, DSSpacing.xs)
        .contentShape(Rectangle())
        .onTapGesture {
            guard hasDetail else { return }
            if reduceMotion {
                isExpanded.toggle()
            } else {
                withAnimation(DSAnimation.fast) { isExpanded.toggle() }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.type.localizedName)，\(entry.message)")
        .accessibilityValue(entry.url ?? "")
        .accessibilityHint(hasDetail ? localized("點兩下展開詳細內容") : "")
        .accessibilityAddTraits(hasDetail ? .isButton : [])
    }

    @ViewBuilder
    private func detailView(_ detail: WebCrawlerDebugger.LogEntry.Detail) -> some View {
        switch detail {
        case .headers(let headers):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(headers.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    Text("\(key): \(value)")
                        .font(DSFont.monospaced(size: 11))
                        .foregroundStyle(DSColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .body(let text), .text(let text):
            Text(text)
                .font(DSFont.monospaced(size: 11))
                .foregroundStyle(DSColor.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension WebCrawlerDebugger.LogEntry.LogType {
    var localizedName: String {
        switch self {
        case .info:       return localized("資訊")
        case .request:    return localized("請求")
        case .response:   return localized("回應")
        case .parseEvent: return localized("規則比對")
        case .error:      return localized("錯誤")
        }
    }

    /// SF Symbol rather than an emoji: emoji do not follow Dynamic Type or the
    /// accent tint, and VoiceOver reads them aloud as their CLDR name.
    var symbolName: String {
        switch self {
        case .info:       return "info.circle"
        case .request:    return "arrow.up.circle"
        case .response:   return "arrow.down.circle"
        case .parseEvent: return "scope"
        case .error:      return "xmark.octagon"
        }
    }

    var tint: Color {
        switch self {
        case .info:       return DSColor.textSecondary
        case .request:    return DSColor.accent
        case .response:   return DSColor.success
        case .parseEvent: return DSColor.warning
        case .error:      return DSColor.destructive
        }
    }
}

#Preview {
    BookSourceDebugView()
}
