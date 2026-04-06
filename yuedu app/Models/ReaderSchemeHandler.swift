/* DISABLED: WebView rendering path temporarily removed pending CoreText migration

import Foundation
import WebKit

final class ReaderSchemeHandler: NSObject, WKURLSchemeHandler {
    private final class CachedResource: NSObject {
        let data: Data
        let mimeType: String
        let textEncodingName: String?

        init(data: Data, mimeType: String, textEncodingName: String?) {
            self.data = data
            self.mimeType = mimeType
            self.textEncodingName = textEncodingName
        }
    }

    private var runningTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let lock = NSLock()
    private let responseCache = NSCache<NSURL, CachedResource>()

    override init() {
        super.init()
        responseCache.countLimit = 256
        responseCache.totalCostLimit = 48 * 1024 * 1024
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        let task = Task {
            do {
                guard self.isTaskActive(identifier), !Task.isCancelled else {
                    self.removeTask(for: identifier)
                    return
                }

                guard let url = urlSchemeTask.request.url,
                      let sessionID = url.host,
                      let session = PublicationSessionRegistry.shared.session(for: sessionID)
                else {
                    throw PublicationSessionError.resourceNotFound(urlSchemeTask.request.url?.absoluteString ?? "")
                }

                if let cached = responseCache.object(forKey: url as NSURL) {
                    guard self.consumeTaskIfActive(identifier), !Task.isCancelled else {
                        return
                    }
                    let urlResponse = URLResponse(
                        url: url,
                        mimeType: cached.mimeType,
                        expectedContentLength: cached.data.count,
                        textEncodingName: cached.textEncodingName
                    )
                    urlSchemeTask.didReceive(urlResponse)
                    urlSchemeTask.didReceive(cached.data)
                    urlSchemeTask.didFinish()
                    return
                }

                let response = try await session.response(for: url)
                guard self.consumeTaskIfActive(identifier), !Task.isCancelled else {
                    return
                }
                let cached = CachedResource(
                    data: response.data,
                    mimeType: response.mimeType,
                    textEncodingName: response.textEncodingName
                )
                responseCache.setObject(cached, forKey: url as NSURL, cost: response.data.count)
                let urlResponse = URLResponse(
                    url: url,
                    mimeType: response.mimeType,
                    expectedContentLength: response.data.count,
                    textEncodingName: response.textEncodingName
                )
                urlSchemeTask.didReceive(urlResponse)
                urlSchemeTask.didReceive(response.data)
                urlSchemeTask.didFinish()
            } catch {
                // WKURLSchemeTask 在 stop 後再次 didFail/didFinish 會觸發
                // "This task has already been stopped" 例外。
                guard !Task.isCancelled else {
                    self.removeTask(for: identifier)
                    return
                }
                guard self.consumeTaskIfActive(identifier) else {
                    return
                }
                urlSchemeTask.didFailWithError(error)
            }
        }
        store(task, for: identifier)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        lock.lock()
        let task = runningTasks.removeValue(forKey: identifier)
        lock.unlock()
        task?.cancel()
    }

    private func store(_ task: Task<Void, Never>, for identifier: ObjectIdentifier) {
        lock.lock()
        runningTasks[identifier] = task
        lock.unlock()
    }

    private func removeTask(for identifier: ObjectIdentifier) {
        lock.lock()
        runningTasks.removeValue(forKey: identifier)
        lock.unlock()
    }

    private func isTaskActive(_ identifier: ObjectIdentifier) -> Bool {
        lock.lock()
        let isActive = runningTasks[identifier] != nil
        lock.unlock()
        return isActive
    }

    @discardableResult
    private func consumeTaskIfActive(_ identifier: ObjectIdentifier) -> Bool {
        lock.lock()
        let task = runningTasks.removeValue(forKey: identifier)
        lock.unlock()
        return task != nil
    }
}
*/
