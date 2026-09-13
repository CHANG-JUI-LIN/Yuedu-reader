import CoreText
import SwiftSoup
import Testing
import UIKit
import YueduCoreText
@testable import yuedu_app

/// Private local corpus; no book text or resource bytes are checked into Git.
@Suite("English EPUB production typography", .serialized)
@MainActor
struct EnglishEPUBTypographyTests {
    nonisolated static var corpus: URL {
        if let path = ProcessInfo.processInfo.environment["YUEDU_ENGLISH_EPUB_DIR"] { return URL(fileURLWithPath:path) }
        var desktop = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { desktop.deleteLastPathComponent() }
        return desktop.appendingPathComponent("Test document/EPUB Format")
    }
    @Test(arguments: ["Project Hail Mary", "The Deal"])
    func authorTypographyThroughPagedAndScroll(_ prefix: String) async throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.corpus, includingPropertiesForKeys:nil)
        let book = try #require(files.first { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "epub" })
        let publication = try await PublicationSession.open(sourceURL:book)
        let resource = EPUBBrowserLayoutResourceAdapter(session:publication)
        var target: Int?
        for i in publication.chapters.indices {
            let html = try await resource.chapterHTML(at:i)
            if prefix == "Project Hail Mary" ? html.contains("Something about the question") : html.contains("Elle Kennedy engages your senses") {
                target = i; break
            }
        }
        let index = try #require(target)
        let html = try await resource.chapterHTML(at:index)
        let input = await resource.cssFrontendInput(forChapter:index,html:html)
        let scan = BrowserLayoutCapabilityScanner.scan(input:input)
        #expect(scan.supported, "Unsupported: \(scan.unsupportedFeatures)")
        let settings = ReaderRenderSettings(theme:"paper",textColor:.black,backgroundColor:.white,fontSize:20,
            lineHeightMultiple:1.2,lineSpacing:0,paragraphSpacing:0,letterSpacing:0,marginH:18,marginV:18,footerHeight:24,
            contentInsets:UIEdgeInsets(top:30,left:18,bottom:30,right:18))
        let renderer = EPUBPageRenderer()
        renderer.load(publicationSession:publication,bookIdentifier:UUID().uuidString,
                      renderSize:CGSize(width:390,height:740),settings:settings)
        let engine = try #require(renderer.engine as? BrowserLayoutPageEngine)
        defer { engine.cancelPendingWork() }
        #expect(await engine.preloadChapter(at:index).isReady)
        #expect(engine.choice(for:index)?.isBrowser == true)
        let page = try #require(engine.pageViewController(for:.init(spineIndex:index,charOffset:0)) as? BrowserLayoutPageViewController)
        let texts = page.pageView.displayList.items.compactMap { if case .text(let text) = $0 { return text }; return nil }
        #expect(!texts.isEmpty)
        #expect(texts.allSatisfy { $0.writingMode == .horizontal })
        if prefix == "Project Hail Mary" {
            #expect(texts.contains { $0.font.pointSize > 50 && $0.text.contains("W") })
            #expect(texts.contains { $0.font.pointSize == 20 })
        }
        let scroll = try #require(renderer.scrollEngine)
        #expect(scroll.browserAutoEngine === engine)
        await scroll.start(initialChapter:index,contentWidth:354,viewportExtent:680,loadAdjacentChapters:false)
        #expect(!scroll.chunks.isEmpty)
        #expect(scroll.chunks.allSatisfy { if case .browser = $0 { return true }; return false })
        guard case .browser(let tile) = try #require(scroll.chunks.first) else { return }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("EnglishTypographyAcceptance")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let slug = prefix == "The Deal" ? "deal" : "hail-mary"
        let format = UIGraphicsImageRendererFormat(); format.scale = 2
        let bitmap = UIGraphicsImageRenderer(size:CGSize(width:390,height:740),format:format).image {
            UIColor.white.setFill(); $0.fill(CGRect(x:0,y:0,width:390,height:740))
            page.pageView.displayList.draw(in:$0.cgContext)
        }
        try bitmap.pngData()?.write(to:output.appendingPathComponent("\(slug)-paged.png"))
        var geometry: [[String:Any]] = []
        for text in texts {
            geometry.append(["node":text.nodeID,"sourceLocation":text.sourceRange.location,"sourceLength":text.sourceRange.length,
                "rect":NSCoder.string(for:text.rect.rawValue),"baseline":text.baselineY,"font":text.font.fontName,
                "size":text.font.pointSize,"ascent":text.font.ascender,"descent":text.font.descender])
        }
        let assets = await resource.prefetchImages(forChapter:index,html:html,renderWidth:354)
        var diagnostics: [String] = []
        let diagnosticConfig = BrowserLayoutConfig(renderWidth:354,renderHeight:680,rootFontSize:20,lineHeight:1.2,
            defaultTextAlignment:.justified,fontResolver:resource.fontResolver(),
            onDiagnostic:{ event in diagnostics.append("\(event.stage) \(event.stylesheet?.label ?? "") \(event.semanticPath ?? "") \(event.message)") })
        let measured = HTMLLayoutDocument(input:input,configuration:diagnosticConfig,imageLoader:{assets[$0]})
        _ = try measured.prepareContinuous()
        try diagnostics.joined(separator:"\n").write(to:output.appendingPathComponent("\(slug)-trace.txt"),atomically:true,encoding:.utf8)
        let scrollImage = UIGraphicsImageRenderer(size:CGSize(width:354,height:680),format:format).image {
            UIColor.white.setFill(); $0.fill(CGRect(x:0,y:0,width:354,height:680))
            tile.chapter.document.items(in:CGRect(x:0,y:0,width:354,height:680)).draw(in:$0.cgContext)
        }
        try scrollImage.pngData()?.write(to:output.appendingPathComponent("\(slug)-scroll.png"))
        let report: [String:Any] = ["spine":index,"backend":"browser","writingMode":"horizontal", "geometry":geometry,
            "sheets":input.activeAuthorStylesheets.map { ["order":$0.sourceOrder,"id":$0.identity.label] as [String:Any] },
            "continuousSize":NSCoder.string(for:tile.chapter.document.contentSize)]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("\(slug).json"))
        print("EnglishTypographyAcceptance case=\(slug) spine=\(index) route=browser horizontal sheets=\(input.activeAuthorStylesheets.count) continuous=\(tile.chapter.document.contentSize) output=\(output.path)")
    }
}
