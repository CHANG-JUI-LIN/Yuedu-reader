import Foundation
import UIKit
import WebKit

enum SnapshotPriority: Int, Comparable {
    case background = 0
    case onDemand = 1
    case immediate = 2
    
    static func < (lhs: SnapshotPriority, rhs: SnapshotPriority) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

struct SnapshotRequest: Equatable, Hashable {
    let chapterIndex: Int
    let pageIndex: Int
    var priority: SnapshotPriority
}

@MainActor
final class EPUBSnapshotManager {
    static let shared = EPUBSnapshotManager()
    
    private var workers: [EPUBSnapshotWorker] = []
    private var idleWorkers: Set<EPUBSnapshotWorker> = []
    
    private let memoryCache = NSCache<NSString, UIImage>()
    
    // Disk cache URL
    private let diskCacheURL: URL = {
        let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        let dir = urls[0].appendingPathComponent("EPUBSnapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    
    private var requestQueue: [SnapshotRequest] = []
    private var activeContinuations: [SnapshotRequest: [CheckedContinuation<UIImage?, Never>]] = [:]
    
    init(workerCount: Int = 2) {
        memoryCache.countLimit = 6 // Suggestion from user: memory LRU limit (e.g., 6 pages)
        
        for _ in 0..<workerCount {
            let worker = EPUBSnapshotWorker()
            workers.append(worker)
            idleWorkers.insert(worker)
        }
    }
    
    private func cacheKey(chapter: Int, page: Int) -> NSString {
        return "\(chapter)_\(page)" as NSString
    }
    
    private func diskURL(chapter: Int, page: Int) -> URL {
        return diskCacheURL.appendingPathComponent("\(chapter)_\(page).png")
    }
    
    func requestSnapshot(chapter: Int, page: Int, priority: SnapshotPriority) async -> UIImage? {
        let key = cacheKey(chapter: chapter, page: page)
        
        if let cached = memoryCache.object(forKey: key) {
            return cached
        }
        
        // Disk Cache check
        let fileURL = diskURL(chapter: chapter, page: page)
        if let data = try? Data(contentsOf: fileURL), let image = UIImage(data: data) {
            memoryCache.setObject(image, forKey: key)
            return image
        }
        
        let request = SnapshotRequest(chapterIndex: chapter, pageIndex: page, priority: priority)
        
        return await withCheckedContinuation { continuation in
            if activeContinuations[request] != nil {
                activeContinuations[request]?.append(continuation)
                // Optionally bump priority
                if let idx = requestQueue.firstIndex(where: { $0.chapterIndex == chapter && $0.pageIndex == page }) {
                    if requestQueue[idx].priority < priority {
                        requestQueue[idx].priority = priority
                        requestQueue.sort { $0.priority > $1.priority }
                    }
                }
            } else {
                activeContinuations[request] = [continuation]
                requestQueue.append(request)
                requestQueue.sort { $0.priority > $1.priority }
                dispatchNext()
            }
        }
    }
    
    func prefetchRange(chapter: Int, centerPage: Int, radius: Int) {
        let start = max(0, centerPage - radius)
        let end = centerPage + radius
        
        for p in start...end {
            // Background priority
            let req = SnapshotRequest(chapterIndex: chapter, pageIndex: p, priority: .background)
            if memoryCache.object(forKey: cacheKey(chapter: chapter, page: p)) == nil {
                if !requestQueue.contains(where: { $0.chapterIndex == chapter && $0.pageIndex == p }) {
                    requestQueue.append(req)
                }
            }
        }
        requestQueue.sort { $0.priority > $1.priority }
        dispatchNext()
    }
    
    func cancelRequests(forChapter chapter: Int) {
        requestQueue.removeAll { $0.chapterIndex == chapter }
    }
    
    func clearCache(forChapter chapter: Int) {
        // Implementation for clearing disk/memory cache for specific chapter
    }
    
    private func dispatchNext() {
        guard let worker = idleWorkers.first, !requestQueue.isEmpty else { return }
        let request = requestQueue.removeFirst()
        idleWorkers.remove(worker)
        
        Task {
            let image = await worker.takeSnapshot(forPage: request.pageIndex)
            
            if let img = image {
                let key = cacheKey(chapter: request.chapterIndex, page: request.pageIndex)
                memoryCache.setObject(img, forKey: key)
                let url = diskURL(chapter: request.chapterIndex, page: request.pageIndex)
                if let data = img.pngData() {
                    try? data.write(to: url)
                }
            }
            
            let continuations = activeContinuations.removeValue(forKey: request) ?? []
            for c in continuations {
                c.resume(returning: image)
            }
            
            idleWorkers.insert(worker)
            dispatchNext()
        }
    }
}
