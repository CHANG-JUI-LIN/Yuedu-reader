import Foundation
import CoreGraphics
import Combine

/// Protocol for the storage of EPUB Locators
protocol EPUBLocatorStore {
    func saveLocator(chapter: Int, progress: Double, text: String?)
    func loadLocator() -> (chapter: Int, progress: Double, text: String?)?
}

struct EPUBGlobalPageMap: CustomStringConvertible, Equatable {
    let chapter: Int
    let page: Int
    
    var description: String {
        return "Ch \(chapter) Pg \(page)"
    }
}

@MainActor
final class EPUBProgressManager: ObservableObject {
    
    // MARK: - Published State
    @Published private(set) var globalPageMap: [EPUBGlobalPageMap] = []
    @Published private(set) var currentEpubPage: Int = 0
    @Published private(set) var totalPages: Int = 1
    
    // MARK: - Internal Metrics
    private var chapterPageCounts: [Int: Int] = [:]
    private var chapterPageOffsets: [Int: [CGFloat]] = [:]
    private let store: EPUBLocatorStore?
    
    init(store: EPUBLocatorStore? = nil) {
        self.store = store
    }
    
    // MARK: - Layout Processing
    func resetMetrics() {
        chapterPageCounts.removeAll()
        chapterPageOffsets.removeAll()
        buildGlobalPageMap()
    }
    
    func setMetrics(forChapter chapterIndex: Int, pageCount: Int, pageOffsets: [CGFloat]?) {
        chapterPageCounts[chapterIndex] = pageCount
        if let offsets = pageOffsets {
            chapterPageOffsets[chapterIndex] = offsets
        }
        buildGlobalPageMap()
    }
    
    private func buildGlobalPageMap() {
        guard !chapterPageCounts.isEmpty else {
            self.globalPageMap = []
            self.totalPages = 1
            return
        }
        var newMap = [EPUBGlobalPageMap]()
        let sortedChapters = chapterPageCounts.keys.sorted()
        for ch in sortedChapters {
            let count = chapterPageCounts[ch] ?? 1
            for p in 0..<count {
                newMap.append(EPUBGlobalPageMap(chapter: ch, page: p))
            }
        }
        self.globalPageMap = newMap
        self.totalPages = max(newMap.count, 1)
        
        // Ensure bounds
        if self.currentEpubPage >= self.totalPages {
            self.currentEpubPage = self.totalPages - 1
        }
    }
    
    // MARK: - Progress Tracking & Restoring
    func setCurrentGlobalPage(_ page: Int) {
        guard page >= 0 && page < totalPages else { return }
        self.currentEpubPage = page
        
        let map = globalPageMap[page]
        let pct = Double(map.page) / Double(max(1, (chapterPageCounts[map.chapter] ?? 1)))
        store?.saveLocator(chapter: map.chapter, progress: pct, text: nil)
    }
    
    func applyRestoredLocator() -> (chapter: Int, page: Int)? {
        guard let loc = store?.loadLocator() else { return nil }
        
        let targetChapter = loc.chapter
        let count = chapterPageCounts[targetChapter] ?? 1
        let targetPage = min(max(0, Int(round(Double(count) * loc.progress))), count - 1)
        
        if let globalIndex = globalPageMap.firstIndex(where: { $0.chapter == targetChapter && $0.page == targetPage }) {
            self.currentEpubPage = globalIndex
        }
        
        return (targetChapter, targetPage)
    }
}
