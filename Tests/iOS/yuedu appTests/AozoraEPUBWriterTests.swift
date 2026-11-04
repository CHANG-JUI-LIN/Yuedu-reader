import Foundation
import ReadiumShared
import ReadiumZIPFoundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Aozora EPUB writer", .serialized)
struct AozoraEPUBWriterTests {
    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/TXTEncodings/aozora-neko-jijo.txt")

    @Test("the public-domain download packages as an EPUB that Readium opens as planned")
    func publicDomainDownload() async throws {
        let text = try TXTFileReader.readTextFile(url: Self.fixture)
        let written = try await write(text, images: [:])
        let session = try await PublicationSession.open(sourceURL: written.url)
        #expect(session.bookTitle == "『吾輩は猫である』中篇自序")
        #expect(session.author == "夏目漱石")
        #expect(session.language == "ja")
        #expect(session.chapters.count == written.chapters.count)

        // The table of contents is the planned navigation, nested by level.
        var planned: [(title: String, level: Int, href: String)] = []
        for (index, chapter) in written.chapters.enumerated() {
            let file = String(format: "text/c%04d.xhtml", index + 1)
            for entry in chapter.navigation {
                planned.append((entry.title, entry.level, entry.anchor.map { "\(file)#\($0)" } ?? file))
            }
        }
        #expect(session.tocEntries.map(\.title) == planned.map(\.title))
        #expect(session.tocEntries.map(\.level) == AozoraEPUBWriter.nestingDepths(planned.map(\.level)))
        for (entry, expected) in zip(session.tocEntries, planned) {
            #expect(entry.href.hasSuffix(expected.href), "\(entry.href) vs \(expected.href)")
        }
    }

    @Test("mimetype comes first, stored, and the manifest pins every chapter's text")
    func packageAndManifest() async throws {
        let text = try TXTFileReader.readTextFile(url: Self.fixture)
        let written = try await write(text, images: [:])
        let archive = try await Archive(url: written.url, accessMode: .read)
        let entries = try await archive.entries()
        let first = try #require(entries.first)
        #expect(first.path == "mimetype")
        #expect(!first.isCompressed)
        #expect(String(decoding: try await data(of: first, in: archive), as: UTF8.self) == "application/epub+zip")

        let manifestEntry = try #require(entries.first { $0.path == AozoraEPUBWriter.manifestPath })
        let manifest = try JSONDecoder().decode(AozoraEPUBManifest.self, from: try await data(of: manifestEntry, in: archive))
        #expect(manifest == written.manifest)
        #expect(manifest.converterVersion == AozoraEPUBWriter.converterVersion)
        #expect(manifest.textVersion == AozoraEPUBWriter.textVersion)
        #expect(manifest.chapters.count == written.chapters.count)
        for (recorded, chapter) in zip(manifest.chapters, written.chapters) {
            #expect(recorded.length == chapter.text.utf16.count)
            #expect(recorded.sha256 == AozoraEPUBWriter.sha256(Data(chapter.text.utf8)))
            #expect(recorded.sourceMap.count == chapter.sourceMap.runs.count * 5)
        }
    }

    @Test("a figure goes into the package and its src resolves from the chapter")
    func figure() async throws {
        let png = try Self.png()
        let text = "題\n著者\n\n本文\n［＃挿絵１（fig1.png、横10×縦10）入る］\n"
        let written = try await write(text, images: ["fig1.png": png, "unused.png": png])
        let archive = try await Archive(url: written.url, accessMode: .read)
        let entries = try await archive.entries()
        let images = entries.map(\.path).filter { $0.hasPrefix("OPS/images/") }
        #expect(images == ["OPS/images/1-fig1.png"])
        let chapter = try #require(entries.first { $0.path == "OPS/text/c0002.xhtml" })
        let xhtml = String(decoding: try await data(of: chapter, in: archive), as: UTF8.self)
        #expect(xhtml.contains(#"src="../images/1-fig1.png""#))
        let session = try await PublicationSession.open(sourceURL: written.url)
        #expect(session.chapters.count == 2)
    }

    /// Aozora plan, Task 19: the colophon in the package, where Readium reads it and the import
    /// keeps it in the copy's sidecar (`ImportedMetadataCapture.EPUBColophon`).
    @Test("the colophon's 底本, 入力 and 校正 go into the package and come back as sidecar values")
    func colophon() async throws {
        let text = try TXTFileReader.readTextFile(url: Self.fixture)
        let written = try await write(text, images: [:])
        let archive = try await Archive(url: written.url, accessMode: .read)
        let package = try #require(try await archive.entries().first { $0.path == "OPS/package.opf" })
        let opf = String(decoding: try await data(of: package, in: archive), as: UTF8.self)
        let source = "「筑摩全集類聚版　夏目漱石全集第十巻」筑摩書房 1972（昭和47）年1月10日第1刷発行"
        // U+3000 goes in as a character reference, as everywhere the writer writes text.
        #expect(opf.contains("<dc:source>\(AozoraXHTMLWriter.escaped(source))</dc:source>"))
        #expect(!opf.contains("bibliographicCitation"), "the fixture has no 初出")

        let session = try await PublicationSession.open(sourceURL: written.url)
        let metadata = session.publication.metadata
        #expect(metadata.authors.map(\.name) == ["夏目漱石"], "入力 and 校正 are not authors")
        let colophon = try #require(ImportedMetadataCapture.EPUBColophon(metadata))
        #expect(colophon == .init(source: source, citation: nil, transcribers: ["Nana ohbe"], proofreaders: ["米田進"]))

        let copy = ReadingBook(title: "題", author: "夏目漱石", source: "local_epub", contentFilename: "x.epub")
        let values = ImportedMetadataCapture.epub(
            copy: copy, sourceItem: .copy(copy.id), identifiers: [], languages: [], description: nil, subjects: [],
            publishers: [], published: nil, colophon: colophon).values
        func value(_ field: MetadataField) -> MetadataPayload? { values.first { $0.field == field }?.value }
        #expect(value(.printedSource) == .text(source))
        #expect(value(.firstAppearance) == nil)
        #expect(value(.transcribers) == .texts(["Nana ohbe"]))
        #expect(value(.proofreaders) == .texts(["米田進"]))
    }

    @Test("初出 is a citation; a field over several lines is one")
    func firstPublished() async throws {
        let text = "題\n著者\n\n本文\n\n底本：「題」架空書房\n初出：「雑誌」\n　　　1900年1月号\n入力：誰か\n"
        let written = try await write(text, images: [:])
        let session = try await PublicationSession.open(sourceURL: written.url)
        let colophon = try #require(ImportedMetadataCapture.EPUBColophon(session.publication.metadata))
        #expect(colophon == .init(source: "「題」架空書房", citation: "「雑誌」 1900年1月号", transcribers: ["誰か"], proofreaders: []))
    }

    @Test("the table of contents nests one step at a time")
    func nesting() {
        #expect(AozoraEPUBWriter.nestingDepths([1, 3, 2, 1]) == [0, 1, 1, 0])
        #expect(AozoraEPUBWriter.nestingDepths([2, 2, 3]) == [0, 0, 1])
        #expect(AozoraEPUBWriter.nestingDepths([2, 1, 2]) == [0, 0, 1])
        #expect(AozoraEPUBWriter.nestingDepths([]) == [])
    }

    // MARK: Helpers

    private struct Written {
        let url: URL
        let chapters: [AozoraChapter]
        let manifest: AozoraEPUBManifest
    }

    private func write(_ text: String, images: [String: URL]) async throws -> Written {
        let document = AozoraDocumentParser.parse(text)
        let chapters = AozoraChapterPlanner.plan(document, source: text)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aozora-\(UUID().uuidString).epub")
        let source = AozoraEPUBManifest.Source(sha256: AozoraEPUBWriter.sha256(Data(text.utf8)),
                                               encoding: String.Encoding.utf8.rawValue, length: text.utf16.count)
        let manifest = try await AozoraEPUBWriter.write(document, chapters: chapters, images: images, source: source,
                                                        identifier: "urn:uuid:\(UUID().uuidString)", to: url)
        return Written(url: url, chapters: chapters, manifest: manifest)
    }

    private func data(of entry: Entry, in archive: Archive) async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = try await archive.extract(entry, to: url)
        return try Data(contentsOf: url)
    }

    private static func png() throws -> URL {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try #require(image.pngData()).write(to: url)
        return url
    }
}
