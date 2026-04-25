import SwiftUI
import SafariServices

// MARK: - SafariView

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

// MARK: - RSSFeedView

struct RSSFeedView: View {
    let source: RSSSource

    @StateObject private var fetcher = RSSFetcher()
    @ObservedObject private var gs = GlobalSettings.shared

    @State private var selectedURL: URL? = nil

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Group {
            if fetcher.isLoading && fetcher.items.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMsg = fetcher.error, fetcher.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(DSColor.textSecondary)
                    Text(errorMsg)
                        .foregroundColor(DSColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button(localized("重試")) {
                        Task { await fetcher.fetchItems(from: source) }
                    }
                    .foregroundColor(DSColor.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(fetcher.items) { item in
                    Button {
                        if let url = URL(string: item.link) {
                            selectedURL = url
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title)
                                .font(.headline)
                                .foregroundColor(DSColor.textPrimary)
                                .multilineTextAlignment(.leading)

                            if let date = item.pubDate {
                                Text(dateFormatter.string(from: date))
                                    .font(.caption)
                                    .foregroundColor(DSColor.textSecondary)
                            }

                            if !item.description.isEmpty {
                                Text(item.description.stripHTML())
                                    .font(.subheadline)
                                    .foregroundColor(DSColor.textSecondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
                .refreshable {
                    await fetcher.fetchItems(from: source)
                }
            }
        }
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await fetcher.fetchItems(from: source)
        }
        .sheet(item: $selectedURL) { url in
            SafariView(url: url)
        }
    }
}

// MARK: - URL Identifiable conformance for sheet(item:)

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

// MARK: - HTML strip helper

private extension String {
    func stripHTML() -> String {
        guard let data = data(using: .utf8) else { return self }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        if let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            return attributed.string
        }
        // Fallback: simple regex-style strip
        return replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}
