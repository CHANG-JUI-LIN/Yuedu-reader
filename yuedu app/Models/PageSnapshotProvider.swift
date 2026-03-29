import Combine
import UIKit

@MainActor
final class PageSnapshotProvider: ObservableObject {
    @Published private(set) var version: Int = 0

    private weak var renderer: EPUBPageRenderer?
    private let cache = NSCache<NSNumber, UIImage>()
    private var subscriptions: Set<AnyCancellable> = []
    private var pendingCallbacks: [Int: [(UIImage?) -> Void]] = [:]
    private var queuedPriorities: [Int: Int] = [:]
    private var activePage: Int?
    private var lastRenderSessionID: Int?
    private var lastLayoutGeneration: Int?

    init() {
        cache.countLimit = 8
    }

    func attach(renderer: EPUBPageRenderer) {
        guard self.renderer !== renderer else { return }
        subscriptions.removeAll()
        self.renderer = renderer
        cache.removeAllObjects()
        pendingCallbacks.removeAll()
        queuedPriorities.removeAll()
        activePage = nil
        lastRenderSessionID = renderer.renderSessionID
        lastLayoutGeneration = renderer.layoutGeneration
        version &+= 1

        renderer.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.version &+= 1
            }
            .store(in: &subscriptions)
    }

    func invalidate() {
        cache.removeAllObjects()
        pendingCallbacks.removeAll()
        queuedPriorities.removeAll()
        activePage = nil
        version &+= 1
    }

    private func syncGenerationIfNeeded() {
        guard let renderer else { return }
        if lastRenderSessionID == nil || lastLayoutGeneration == nil {
            lastRenderSessionID = renderer.renderSessionID
            lastLayoutGeneration = renderer.layoutGeneration
            return
        }
        guard lastRenderSessionID != renderer.renderSessionID || lastLayoutGeneration != renderer.layoutGeneration else {
            return
        }
        invalidate()
        lastRenderSessionID = renderer.renderSessionID
        lastLayoutGeneration = renderer.layoutGeneration
    }

    func cachedSnapshot(for page: Int) -> UIImage? {
        syncGenerationIfNeeded()
        let key = NSNumber(value: page)
        if let image = cache.object(forKey: key) {
            return image
        }
        guard let renderer else { return nil }
        guard let image = renderer.snapshot(forPage: page) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    func pageState(for page: Int) -> PageRenderState {
        syncGenerationIfNeeded()
        return renderer?.pageSnapshotState(forPage: page) ?? .missing
    }

    func warmWindow(around page: Int, radius: Int = 1) {
        guard let renderer else { return }
        syncGenerationIfNeeded()
        guard renderer.totalPages > 0 else { return }
        let lower = max(0, page - radius)
        let upper = min(renderer.totalPages - 1, page + radius)
        for candidate in lower...upper {
            let priority: Int = (candidate == page) ? -2 : 0
            requestSnapshot(for: candidate, priority: priority) { _ in }
        }
    }

    func requestSnapshot(for page: Int, priority: Int = 0, completion: @escaping (UIImage?) -> Void) {
        syncGenerationIfNeeded()
        if let image = cachedSnapshot(for: page) {
            completion(image)
            return
        }
        guard let renderer else {
            completion(nil)
            return
        }
        guard page >= 0, page < renderer.totalPages else {
            completion(nil)
            return
        }

        pendingCallbacks[page, default: []].append(completion)
        let existingPriority = queuedPriorities[page] ?? Int.max
        queuedPriorities[page] = min(existingPriority, priority)

        processQueueIfNeeded()
    }

    func cancelPendingRequest(for page: Int) {
        queuedPriorities.removeValue(forKey: page)
        if activePage == page {
            renderer?.cancelSnapshotRequest(for: page)
            activePage = nil
        }
        let callbacks = pendingCallbacks.removeValue(forKey: page) ?? []
        for callback in callbacks {
            callback(nil)
        }
        version &+= 1
        processQueueIfNeeded()
    }

    private func processQueueIfNeeded() {
        guard activePage == nil else { return }
        guard let renderer else { return }
        guard !queuedPriorities.isEmpty else { return }

        let sortedPages = queuedPriorities.keys.sorted { lhs, rhs in
            let lp = queuedPriorities[lhs] ?? 0
            let rp = queuedPriorities[rhs] ?? 0
            if lp == rp {
                return abs(lhs - renderer.currentEpubPage) < abs(rhs - renderer.currentEpubPage)
            }
            return lp < rp
        }
        guard let page = sortedPages.first else { return }
        queuedPriorities.removeValue(forKey: page)
        activePage = page

        renderer.requestSnapshot(for: page) { [weak self] image in
            guard let self else { return }
            if let image {
                self.cache.setObject(image, forKey: NSNumber(value: page))
            }
            let callbacks = self.pendingCallbacks.removeValue(forKey: page) ?? []
            for callback in callbacks {
                callback(image)
            }
            self.activePage = nil
            self.version &+= 1
            self.processQueueIfNeeded()
        }
    }
}
