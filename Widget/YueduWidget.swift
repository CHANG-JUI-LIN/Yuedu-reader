import WidgetKit
import SwiftUI

// MARK: - Data Models

struct BookProgress: Codable {
    var title: String
    var author: String
    var progress: Double          // 0.0 – 1.0
    var coverImagePath: String?
    var lastReadDate: Date
}

// MARK: - App Group shared store

private let appGroupID = "group.com.mumu.yuedu"

func loadLastBook() -> BookProgress? {
    guard let defaults = UserDefaults(suiteName: appGroupID),
          let data = defaults.data(forKey: "widget_last_book"),
          let book = try? JSONDecoder().decode(BookProgress.self, from: data)
    else { return nil }
    return book
}

// MARK: - Provider

struct BookProgressEntry: TimelineEntry {
    let date: Date
    let book: BookProgress?
}

struct BookProgressProvider: TimelineProvider {
    func placeholder(in context: Context) -> BookProgressEntry {
        BookProgressEntry(date: Date(), book: BookProgress(
            title: "示例書名", author: "示例作者", progress: 0.6,
            coverImagePath: nil, lastReadDate: Date()
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (BookProgressEntry) -> Void) {
        completion(BookProgressEntry(date: Date(), book: loadLastBook()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BookProgressEntry>) -> Void) {
        let entry = BookProgressEntry(date: Date(), book: loadLastBook())
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}

// MARK: - Widget Views

struct BookProgressWidgetView: View {
    let entry: BookProgressEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        Group {
            if let book = entry.book {
                VStack(alignment: .leading, spacing: 4) {
                    Spacer()
                    Text(book.title)
                        .font(.headline).fontWeight(.bold)
                        .foregroundColor(.white)
                        .lineLimit(2)
                    Text(book.author)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(1)
                    ProgressView(value: book.progress)
                        .tint(.white)
                        .scaleEffect(y: 1.5)
                    Text("\(Int(book.progress * 100))% · \(book.lastReadDate, style: .relative)前")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(12)
                .containerBackground(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.8), Color.black.opacity(0.6)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    for: .widget
                )
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text("尚無閱讀記錄")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .containerBackground(.fill.tertiary, for: .widget)
            }
        }
    }
}

// MARK: - Widget Configuration

@main
struct YueduWidget: Widget {
    let kind: String = "BookProgressWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BookProgressProvider()) { entry in
            BookProgressWidgetView(entry: entry)
        }
        .configurationDisplayName("閱讀進度")
        .description("顯示目前閱讀書籍的進度。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
