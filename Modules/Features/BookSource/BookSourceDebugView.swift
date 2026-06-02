import SwiftUI

struct BookSourceDebugView: View {
    @StateObject private var debugger = WebCrawlerDebugger.shared
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var gs = GlobalSettings.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Toolbar
                HStack {
                    Toggle(localized("啟用網路除錯錄製"), isOn: $debugger.isRecording)
                        .padding()
                    Spacer()
                    Button(localized("清空紀錄")) {
                        debugger.clear()
                    }
                    .padding()
                    .foregroundColor(.red)
                }
                .background(Color(.systemGray6))

                List {
                    ForEach(debugger.logs) { log in
                        LogEntryRow(entry: log)
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle(localized("書源除錯大師"))
            .navigationBarItems(trailing: Button(localized("關閉")) { dismiss() })
        }
    }
}

struct LogEntryRow: View {
    let entry: WebCrawlerDebugger.LogEntry
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(icon(for: entry.type))
                    .font(.headline)

                VStack(alignment: .leading) {
                    Text(entry.message)
                        .font(.subheadline)
                        .bold()
                        .lineLimit(isExpanded ? nil : 2)

                    if let url = entry.url {
                        Text(url)
                            .font(.caption)
                            .foregroundColor(.blue)
                            .lineLimit(isExpanded ? nil : 1)
                    }
                }
                Spacer()

                Text(entry.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation { isExpanded.toggle() }
            }

            if isExpanded, let meta = entry.metadata {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(meta.keys.sorted(), id: \.self) { key in
                        if let dict = meta[key] as? [String: String] {
                            Text("\(key):").font(.caption).bold()
                            ForEach(dict.keys.sorted(), id: \.self) { hKey in
                                Text("  \(hKey): \(dict[hKey] ?? "")")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.gray)
                            }
                        } else if let str = meta[key] as? String {
                            Text("\(key):").font(.caption).bold()
                            Text(str)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.gray)
                                .lineLimit(10)
                        } else {
                            Text("\(key): \(String(describing: meta[key]!))")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                }
                .padding(.leading, 24)
            }
        }
        .padding(.vertical, 4)
    }

    private func icon(for type: WebCrawlerDebugger.LogEntry.LogType) -> String {
        switch type {
        case .info: return "ℹ️"
        case .request: return "🌐"
        case .response: return "📄"
        case .parseEvent: return "🔍"
        case .error: return "❌"
        }
    }
}

struct BookSourceDebugView_Previews: PreviewProvider {
    static var previews: some View {
        BookSourceDebugView()
    }
}
