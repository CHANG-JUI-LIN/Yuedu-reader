import SwiftUI

/// Full per-rule book source debugger.
/// Shows 4 parsing stages: Search / Detail / TOC / Content.
/// Each stage lets you enter the relevant input, run it against the real engine,
/// and see timestamped, color-coded log entries with expandable detail.
struct BookSourceRuleDebugView: View {

    let source: BookSource

    @StateObject private var engine: BookSourceDebugEngine
    @State private var selectedTab: DebugTab = .search
    @State private var keyword: String = ""
    @State private var inputURL: String = ""
    @State private var page: Int = 1
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var gs = GlobalSettings.shared

    enum DebugTab: String, CaseIterable, Identifiable {
        case search  = "搜索"
        case detail  = "詳情"
        case toc     = "目錄"
        case content = "正文"
        var id: String { rawValue }
    }

    init(source: BookSource) {
        self.source = source
        _engine = StateObject(wrappedValue: BookSourceDebugEngine(source: source))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab picker
                Picker(localized("解析段落"), selection: $selectedTab) {
                    ForEach(DebugTab.allCases) {
                        Text(localized($0.rawValue)).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .onChange(of: selectedTab) { _, _ in engine.clear() }

                // Input area
                VStack(spacing: 8) {
                    if selectedTab == .search {
                        HStack {
                            TextField(localized("搜索關鍵字"), text: $keyword)
                                .textFieldStyle(.roundedBorder)
                            Stepper("P\(page)", value: $page, in: 1...999)
                                .fixedSize()
                        }
                    } else {
                        TextField(localized("URL"), text: $inputURL)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .keyboardType(.URL)
                    }

                    HStack {
                        Button {
                            engine.clear()
                        } label: {
                            Label(localized("清空"), systemImage: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button {
                            Task { await runCurrentTab() }
                        } label: {
                            if engine.isRunning {
                                ProgressView()
                                    .padding(.horizontal, 12)
                            } else {
                                Label(localized("執行"), systemImage: "play.fill")
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(engine.isRunning)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
                .background(Color(.systemGray6))

                Divider()

                // Log list
                if engine.logs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text(localized("輸入資料後按「執行」開始調試"))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(engine.logs) { entry in
                        DebugLogRow(entry: entry)
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(source.bookSourceName.isEmpty ? localized("書源調試") : source.bookSourceName)
            .toolbarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(localized("關閉")) { dismiss() }
                }
            }
        }
    }

    private func runCurrentTab() async {
        switch selectedTab {
        case .search:  await engine.runSearch(keyword: keyword, page: page)
        case .detail:  await engine.runBookInfo(url: inputURL)
        case .toc:     await engine.runTOC(url: inputURL)
        case .content: await engine.runContent(url: inputURL)
        }
    }
}

// MARK: - Log Row

private struct DebugLogRow: View {

    let entry: DebugLogEntry
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text(icon)
                    .font(.body)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.step)
                        .font(.caption)
                        .foregroundColor(color.opacity(0.8))
                        .bold()

                    Text(entry.summary)
                        .font(.subheadline)
                        .foregroundColor(color)
                        .lineLimit(isExpanded ? nil : 2)
                }

                Spacer()

                Text(entry.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard entry.detail != nil else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }

            if isExpanded, let detail = entry.detail {
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.leading, 28)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Color(.systemGray6))
                    .cornerRadius(6)
            }

            if entry.detail != nil {
                HStack {
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch entry.level {
        case .info:     return "ℹ️"
        case .success:  return "✅"
        case .warning:  return "⚠️"
        case .error:    return "❌"
        case .pipeline: return "🔍"
        }
    }

    private var color: Color {
        switch entry.level {
        case .info:     return .primary
        case .success:  return .green
        case .warning:  return .orange
        case .error:    return .red
        case .pipeline: return .secondary
        }
    }
}
