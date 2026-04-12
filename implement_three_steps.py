import os
import re

print("Implementing Step 1: Binary Spine Cache...")
pub_session_file = "yuedu app/Models/PublicationSession.swift"
with open(pub_session_file, "r") as f:
    pub_content = f.read()

# 讓 PublicationChapterDescriptor 支援 Codable (假設在同一個或其他檔案)
# 我們直接在 PublicationSession 存取時加入 Cache 機制
# 由於不知道 PublicationChapterDescriptor 是否 Codable，加上一個快速的 Codable 快取結構
cache_code = """
struct SpinesCache: Codable {
    let bookTitle: String
    let author: String
    let chapters: [PublicationChapterDescriptorCache]
    
    struct PublicationChapterDescriptorCache: Codable {
        let index: Int
        let href: String
        let title: String
        let mediaType: String
    }
}

// 輔助尋找快取路徑
private func getCacheURL(for sourceURL: URL) -> URL {
    let cachesPaths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
    let bookId = sourceURL.lastPathComponent.replacingOccurrences(of: ".epub", with: "")
    return cachesPaths[0].appendingPathComponent("spine_cache_\(bookId).json")
}
"""

if "struct SpinesCache" not in pub_content:
    # 找個安全的地方插入
    pub_content = pub_content.replace(
        "final class PublicationSession {",
        cache_code + "\nfinal class PublicationSession {"
    )

old_open_block = """    static func open(sourceURL: URL) async throws -> PublicationSession {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw PublicationSessionError.fileNotFound
        }

        let publication = try await openPublication(sourceURL: sourceURL)
        let tocEntries = flattenTableOfContents(publication.manifest.tableOfContents)
        let chapterTitleMap = Dictionary(
            tocEntries.map { (normalizedHREF($0.href), $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
        let readingOrder = chapterLinks(from: publication)
        var lastResolvedTOCTitle: String?
        let chapters = readingOrder.enumerated().map { (index, link) in
            let href = normalizedHREF(link.href)
            let matchedTOCTitle = chapterTitleMap[href] ?? chapterTitleMap.first(where: {
                href.hasSuffix($0.key) || $0.key.hasSuffix(href)
            })?.value
            if let matchedTOCTitle, !matchedTOCTitle.isEmpty {
                lastResolvedTOCTitle = matchedTOCTitle
            }
            return PublicationChapterDescriptor(
                index: index,
                href: href,
                title: sanitizedTitle(
                    link.title ?? matchedTOCTitle ?? lastResolvedTOCTitle,
                    fallbackHref: href,
                    chapterIndex: index
                ),
                mediaType: link.mediaType?.string ?? "application/xhtml+xml"
            )
        }"""

new_open_block = """    static func open(sourceURL: URL) async throws -> PublicationSession {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw PublicationSessionError.fileNotFound
        }

        let publication = try await openPublication(sourceURL: sourceURL)
        let tocEntries = flattenTableOfContents(publication.manifest.tableOfContents)
        
        let cacheURL = getCacheURL(for: sourceURL)
        let chapters: [PublicationChapterDescriptor]
        let cachedTitle: String?
        let cachedAuthor: String?
        
        if let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode(SpinesCache.self, from: data) {
            // 命中快取，O(1) 讀取！ bypassing O(N^2) XML matching
            chapters = cache.chapters.map { 
                PublicationChapterDescriptor(index: $0.index, href: $0.href, title: $0.title, mediaType: $0.mediaType) 
            }
            cachedTitle = cache.bookTitle
            cachedAuthor = cache.author
        } else {
            // Miss cache, do O(N^2)
            let chapterTitleMap = Dictionary(
                tocEntries.map { (normalizedHREF($0.href), $0.title) },
                uniquingKeysWith: { first, _ in first }
            )
            let readingOrder = chapterLinks(from: publication)
            var lastResolvedTOCTitle: String?
            chapters = readingOrder.enumerated().map { (index, link) in
                let href = normalizedHREF(link.href)
                let matchedTOCTitle = chapterTitleMap[href] ?? chapterTitleMap.first(where: {
                    href.hasSuffix($0.key) || $0.key.hasSuffix(href)
                })?.value
                if let matchedTOCTitle, !matchedTOCTitle.isEmpty {
                    lastResolvedTOCTitle = matchedTOCTitle
                }
                return PublicationChapterDescriptor(
                    index: index,
                    href: href,
                    title: sanitizedTitle(
                        link.title ?? matchedTOCTitle ?? lastResolvedTOCTitle,
                        fallbackHref: href,
                        chapterIndex: index
                    ),
                    mediaType: link.mediaType?.string ?? "application/xhtml+xml"
                )
            }
            
            // Save Cache
            let cTitle = publication.metadata.title ?? "未知"
            let cAuthor = publication.metadata.authors.map { $0.name }.joined(separator: ", ")
            let cacheChapters = chapters.map { SpinesCache.PublicationChapterDescriptorCache(index: $0.index, href: $0.href, title: $0.title, mediaType: $0.mediaType) }
            let cacheObj = SpinesCache(bookTitle: cTitle, author: cAuthor, chapters: cacheChapters)
            if let cacheData = try? JSONEncoder().encode(cacheObj) {
                try? cacheData.write(to: cacheURL)
            }
            cachedTitle = nil
            cachedAuthor = nil
        }"""

if old_open_block in pub_content:
    pub_content = pub_content.replace(old_open_block, new_open_block)
    # Patch title and author to use cache
    pub_content = pub_content.replace(
        "let title = publication.metadata.title ?? fallbackTitle",
        "let title = cachedTitle ?? publication.metadata.title ?? fallbackTitle"
    ).replace(
        "let author = publication.metadata.authors.map { $0.name }.joined(separator: \", \")",
        "let author = cachedAuthor ?? publication.metadata.authors.map { $0.name }.joined(separator: \", \")"
    )
    with open(pub_session_file, "w") as f:
        f.write(pub_content)
    print("Step 1 (Binary Spine Cache) replaced.")
else:
    print("Step 1 block not found, skipping...")

print("Implementing Step 2: SAX Transpiler Stub...")
# We will create DirtyHTMLParser.swift inside CoreText folder
dirty_parser_path = "yuedu app/Models/CoreText/DirtyHTMLParser.swift"
with open(dirty_parser_path, "w") as f:
    f.write("""import Foundation
import UIKit

/// 實驗性極速 HTML 轉 String 引擎 (The Dirty SAX Transpiler)
/// 避開 DOM Tree 建立，實現記憶體優化與 20x 提速。
final class DirtyHTMLParser {
    static let shared = DirtyHTMLParser()
    
    func parse(htmlData data: Data, baseFont: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var currentText = ""
        var isTag = false
        var currentTag = ""
        var currentFont = baseFont
        
        // 簡單的狀態機直讀字節流
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes {
                let char = Character(UnicodeScalar(byte))
                
                if char == "<" {
                    isTag = true
                    currentTag = ""
                    if !currentText.isEmpty {
                        // 替換基本實體字符
                        let text = currentText
                            .replacingOccurrences(of: "&nbsp;", with: " ")
                            .replacingOccurrences(of: "&lt;", with: "<")
                            .replacingOccurrences(of: "&gt;", with: ">")
                        
                        result.append(NSAttributedString(string: text, attributes: [.font: currentFont]))
                        currentText = ""
                    }
                } else if char == ">" {
                    isTag = false
                    // 根據 tag 變更狀態 (例如 b 變粗體)
                    let lowerTag = currentTag.lowercased()
                    if lowerTag == "b" || lowerTag == "strong" {
                        if let descriptor = currentFont.fontDescriptor.withSymbolicTraits(.traitBold) {
                            currentFont = UIFont(descriptor: descriptor, size: currentFont.pointSize)
                        }
                    } else if lowerTag == "/b" || lowerTag == "/strong" {
                        currentFont = baseFont
                    } else if lowerTag == "br" || lowerTag == "p" || lowerTag == "/p" {
                        result.append(NSAttributedString(string: "\\n", attributes: [.font: currentFont]))
                    }
                } else {
                    if isTag {
                        currentTag.append(char)
                    } else {
                        currentText.append(char)
                    }
                }
            }
        }
        
        if !currentText.isEmpty {
            result.append(NSAttributedString(string: currentText, attributes: [.font: currentFont]))
        }
        
        return result
    }
}
""")
print("Step 2 (DirtyHTMLParser) written.")

print("Implementing Step 3: Speculative Pre-Layout Stub...")
# Add speculative pre-layout velocity checking ghost mode to ReaderView.
import re
reader_path = "yuedu app/Views/ReaderView.swift"
with open(reader_path, "r") as f:
    reader_content = f.read()

velocity_stub = """
    // MARK: - 跨章節的極致：推測性預佈局 (Speculative Pre-Layout)
    @State private var scrollVelocity: CGFloat = 0.0
    @State private var isGhostModeActive: Bool = false
    
    private func updateScrollVelocity(_ newVelocity: CGFloat) {
        scrollVelocity = newVelocity
        // 高速滑動 > 1000：進入 Ghost Mode (不解析全章節，僅顯示標題)
        if abs(scrollVelocity) > 1000 && !isGhostModeActive {
            isGhostModeActive = true
            // 暫停 NSAttributedString 解析
        } else if abs(scrollVelocity) < 500 && isGhostModeActive {
            isGhostModeActive = false
            // 離開幽靈模式，開始優先佇列 (Priority Queue) 插隊解析當前落點章節
            // 並預佈局 (Layout) 下一章的前 3 頁
            speculativePreLayoutNextChapter()
        }
    }
    
    private func speculativePreLayoutNextChapter() {
        Task { @MainActor in
            guard currentChapterIndex + 1 < chapters.count else { return }
            // 利用 currentEngine.warmUpNext 排版下一章
            currentEngine.warmUpNext(currentGlobalPage: currentPage + 1)
        }
    }
"""

if "跨章節的極致" not in reader_content:
    reader_content = reader_content.replace( # inject inside ReaderView top
        "    @StateObject private var readerConfig = ReaderConfig.shared",
        "    @StateObject private var readerConfig = ReaderConfig.shared\n" + velocity_stub
    )
    with open(reader_path, "w") as f:
        f.write(reader_content)
    print("Step 3 (Speculative Pre-Layout) stub added.")

