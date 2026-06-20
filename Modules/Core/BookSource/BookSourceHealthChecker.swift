import Combine
import Foundation

enum BookSourceCheckResult: Equatable {
    case notTested
    case testing
    case success(timeMs: Int64)
    case failure(message: String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var isTesting: Bool {
        if case .testing = self { return true }
        return false
    }
}

struct BookSourceCheckItem: Identifiable {
    let id = UUID()
    let source: BookSource
    var connectivity: BookSourceCheckResult = .notTested
    var search: BookSourceCheckResult = .notTested
    var overallPass: Bool {
        connectivity.isSuccess && (source.searchUrl.isEmpty || search.isSuccess)
    }
}

@MainActor
final class BookSourceHealthChecker: ObservableObject {
    @Published var items: [BookSourceCheckItem] = []
    @Published var isRunning = false

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    private var cancelled = false

    func prepare(sources: [BookSource]) {
        cancelled = false
        items = sources.map { BookSourceCheckItem(source: $0) }
    }

    func runAll() async {
        guard !items.isEmpty else { return }
        isRunning = true
        cancelled = false
        defer {
            isRunning = false
            cancelled = false
        }

        await withTaskGroup(of: Void.self) { group in
            for index in items.indices {
                group.addTask { [weak self] in
                    await self?.checkItem(at: index)
                }
            }
        }
    }

    func runSingle(at index: Int) async {
        guard !cancelled else { return }
        await checkItem(at: index)
    }

    private func checkItem(at index: Int) async {
        guard items.indices.contains(index), !cancelled else { return }

        items[index].connectivity = .testing
        items[index].search = .testing

        let source = items[index].source

        if !source.bookSourceUrl.isEmpty {
            items[index].connectivity = await checkURL(source.bookSourceUrl)
        } else {
            items[index].connectivity = .failure(message: localized("書源地址為空"))
        }

        guard !cancelled else { return }

        if !source.searchUrl.isEmpty {
            items[index].search = await checkSearch(source: source)
        } else {
            items[index].search = .success(timeMs: 0)
        }
    }

    private func checkURL(_ urlString: String) async -> BookSourceCheckResult {
        guard !cancelled else { return .failure(message: localized("已取消")) }
        guard let url = safeURL(string: urlString) else {
            return .failure(message: localized("無效的 URL"))
        }

        let start = CFAbsoluteTimeGetCurrent()
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            let (_, response) = try await session.data(for: request)
            let elapsed = Int64((CFAbsoluteTimeGetCurrent() - start) * 1000)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(message: localized("非 HTTP 響應"))
            }
            if (200..<400).contains(httpResponse.statusCode) {
                return .success(timeMs: elapsed)
            } else {
                return .failure(message: "HTTP \(httpResponse.statusCode)")
            }
        } catch {
            let err = error.localizedDescription
            if (error as? URLError)?.code == .timedOut {
                return .failure(message: localized("超時"))
            }
            return .failure(message: err)
        }
    }

    private func checkSearch(source: BookSource) async -> BookSourceCheckResult {
        guard !cancelled else { return .failure(message: localized("已取消")) }
        guard !source.searchUrl.isEmpty else {
            return .success(timeMs: 0)
        }

        let (urlString, method, body) = source.renderSearchURL(query: "测试", page: 1)
        guard let url = safeURL(string: urlString) else {
            return .failure(message: localized("搜索 URL 格式錯誤"))
        }

        let start = CFAbsoluteTimeGetCurrent()
        do {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            if method == "POST", let body, let bodyData = body.data(using: .utf8) {
                request.httpBody = bodyData
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await session.data(for: request)
            let elapsed = Int64((CFAbsoluteTimeGetCurrent() - start) * 1000)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(message: localized("非 HTTP 響應"))
            }
            guard (200..<400).contains(httpResponse.statusCode) else {
                return .failure(message: "HTTP \(httpResponse.statusCode)")
            }
            guard !data.isEmpty else {
                return .failure(message: localized("空響應"))
            }
            return .success(timeMs: elapsed)
        } catch {
            let err = error.localizedDescription
            if (error as? URLError)?.code == .timedOut {
                return .failure(message: localized("超時"))
            }
            return .failure(message: err)
        }
    }

    func cancel() {
        cancelled = true
        isRunning = false
    }
}
