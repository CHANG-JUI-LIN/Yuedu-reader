import CoreText
import Foundation
import ReadiumZIPFoundation
import Testing
import UIKit
@testable import yuedu_app

enum EPUBTestFixtures {
    struct Sample {
        let entries: [String: Data]
    }

    static func makeArchive(entries: [String: Data]) async throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let archiveURL = root.appendingPathComponent("sample-\(UUID().uuidString).epub")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let archive = try await Archive(url: archiveURL, accessMode: .create)
        for (path, data) in entries {
            let fileURL = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL)
            try await archive.addEntry(with: path, fileURL: fileURL)
        }
        return archiveURL
    }

    static func xhtml(title: String, body: String, head: String = "", bodyAttributes: String = "") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"
              xmlns:epub="http://www.idpf.org/2007/ops"
              xmlns:ssml="http://www.w3.org/2001/10/synthesis">
          <head><title>\(title)</title>\(head)</head>
          <body \(bodyAttributes)>\(body)</body>
        </html>
        """
    }

    static func renderSettings(
        fontSize: CGFloat = 17,
        lineHeightMultiple: CGFloat = 1.5,
        paragraphSpacing: CGFloat = 8,
        writingMode: ReaderWritingMode = .horizontal
    ) -> ReaderRenderSettings {
        ReaderRenderSettings(
            theme: "test",
            textColor: .black,
            backgroundColor: .white,
            fontSize: fontSize,
            lineHeightMultiple: lineHeightMultiple,
            lineSpacing: 0,
            paragraphSpacing: paragraphSpacing,
            letterSpacing: 0,
            marginH: 0,
            marginV: 0,
            footerHeight: 0,
            contentInsets: .zero,
            writingMode: writingMode
        )
    }

    static func htmlConfig(
        renderWidth: CGFloat = 320,
        fontSize: CGFloat = 17,
        lineHeightMultiple: CGFloat = 1.5,
        paragraphSpacing: CGFloat = 8
    ) -> HTMLAttributedStringBuilder.Config {
        HTMLAttributedStringBuilder.Config(
            fontSize: fontSize,
            lineHeightMultiple: lineHeightMultiple,
            lineSpacing: 0,
            paragraphSpacing: paragraphSpacing,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            fontFamilyName: nil,
            renderWidth: renderWidth,
            writingMode: .horizontal
        )
    }

    /// Renders raw HTML through the unified IR pipeline (buildStyledAST → RenderableNode →
    /// NodeAttributedStringRenderer), the same path production uses for every chapter.
    @MainActor
    static func renderIR(
        html: String,
        config: HTMLAttributedStringBuilder.Config,
        builder: HTMLAttributedStringBuilder = HTMLAttributedStringBuilder()
    ) async -> NSAttributedString {
        await builder.build(html: html, config: config).attributedString
    }

    static func imageRunInfos(in attributedString: NSAttributedString) -> [(range: NSRange, info: ImageRunInfo)] {
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        var runs: [(NSRange, ImageRunInfo)] = []
        attributedString.enumerateAttribute(
            delegateKey,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, range, _ in
            guard let value else { return }
            let delegate = value as! CTRunDelegate
            let pointer = CTRunDelegateGetRefCon(delegate)
            let info = Unmanaged<ImageRunInfo>.fromOpaque(pointer).takeUnretainedValue()
            guard info.image != nil else { return }
            runs.append((range, info))
        }
        return runs
    }

    @MainActor
    static func makeJPEG(width: CGFloat = 256, height: CGFloat = 192) -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
            UIColor.systemTeal.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }

    static func linearAlgebra() -> Sample {
        Sample(entries: makeBaseEntries(
            title: "Linear Algebra",
            language: "en",
            body: """
            <p>Let
              <math xmlns="http://www.w3.org/1998/Math/MathML" display="inline" alttext="x">
                <mi>x</mi>
              </math>
              be a vector.</p>
            """,
            extraManifest: "",
            extraEntries: [:]
        ))
    }

    @MainActor
    static func israelSailing() -> Sample {
        Sample(entries: makeBaseEntries(
            title: "מפליגים בישראל",
            language: "he",
            pageProgression: "rtl",
            bodyAttributes: #"dir="rtl""#,
            body: """
            <p class="regular">אבישי נכנס לבניין מנהלת המרינה.</p>
            <p class="regular">
            <img src="pic65.jpg" style="width:90%" alt="מרינה הרצליה"/><br/>
            </p>
            <p class="regular">לפני מספר חודשים הרס וירוס אימתני את מרבית מחשבי העולם בשנת 2014.</p>
            """,
            extraManifest: #"<item id="pic65" href="pic65.jpg" media-type="image/jpeg"/>"#,
            extraEntries: ["OPS/pic65.jpg": makeJPEG()]
        ))
    }

    static func georgia() -> Sample {
        var entries = makeBaseEntries(
            title: "Georgia",
            language: "en",
            body: """
            <p id="d10e42">Georgia starts here.
              <span id="d10e85" ssml:alphabet="ipa" ssml:ph="ˈθɜrti dɪˈgriz">30°</span>
              <span id="d10e93">north latitude</span>
            </p>
            """,
            navBody: """
            <nav epub:type="toc"><ol>
              <li><a href="georgia.xhtml#d10e85">Fragment</a></li>
              <li><a href="package.opf#epubcfi(/6/4[ct]!/4/2[d10e42]/12[d10e85]/6[d10e93]/1:1552[...])">CFI</a></li>
            </ol></nav>
            """,
            chapterHref: "georgia.xhtml",
            extraManifest: #"<item id="lexicon" href="lexicon/en.pls" media-type="application/pls+xml"/>"#,
            extraSpine: #"<itemref id="cover" linear="no"/>"#,
            extraEntries: [
                "OPS/lexicon/en.pls": Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <lexicon version="1.0" alphabet="ipa" xml:lang="en" xmlns="http://www.w3.org/2005/01/pronunciation-lexicon">
                  <lexeme><grapheme>30°</grapheme><phoneme>ˈθɜrti dɪˈgriz</phoneme></lexeme>
                </lexicon>
                """.utf8)
            ]
        )
        entries["OPS/package.opf"] = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" unique-identifier="bookid" xmlns="http://www.idpf.org/2007/opf">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">urn:uuid:georgia</dc:identifier>
            <dc:title>Georgia</dc:title>
            <dc:language>en</dc:language>
            <link rel="pronunciation" href="lexicon/en.pls" type="application/pls+xml"/>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>
            <item id="intro" href="intro.xhtml" media-type="application/xhtml+xml"/>
            <item id="ct" href="georgia.xhtml" media-type="application/xhtml+xml"/>
            <item id="lexicon" href="lexicon/en.pls" media-type="application/pls+xml"/>
          </manifest>
          <spine>
            <itemref idref="cover" linear="no"/>
            <itemref idref="intro"/>
            <itemref id="ct" idref="ct"/>
          </spine>
        </package>
        """.utf8)
        entries["OPS/cover.xhtml"] = Data(xhtml(title: "Cover", body: "<p>Cover</p>").utf8)
        entries["OPS/intro.xhtml"] = Data(xhtml(title: "Intro", body: "<p>Intro</p>").utf8)
        return Sample(entries: entries)
    }

    static func quizBindings() -> Sample {
        Sample(entries: makeBaseEntries(
            title: "Quiz",
            language: "en",
            body: """
            <object type="application/x-epub-quiz">
              <p>Gas Giants</p>
            </object>
            """,
            extraManifest: #"<item id="quiz" href="quiz.xhtml" media-type="application/xhtml+xml" properties="scripted"/>"#,
            extraPackageChildren: """
            <bindings>
              <mediaType media-type="application/x-epub-quiz" handler="quiz"/>
            </bindings>
            """,
            extraEntries: [:]
        ))
    }

    static func proseSmoke() -> Sample {
        Sample(entries: makeBaseEntries(
            title: "Prose",
            language: "en",
            body: "<h1>Start</h1><p id=\"p1\">Simple prose paragraph.</p>",
            extraManifest: "",
            extraEntries: [:]
        ))
    }

    static func makeBaseEntries(
        title: String,
        language: String,
        pageProgression: String = "ltr",
        bodyAttributes: String = "",
        body: String,
        navBody: String? = nil,
        chapterHref: String = "chapter1.xhtml",
        extraManifest: String,
        extraSpine: String = "",
        extraPackageChildren: String = "",
        extraEntries: [String: Data]
    ) -> [String: Data] {
        var entries: [String: Data] = [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8),
            "OPS/package.opf": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package version="3.0" unique-identifier="bookid" xmlns="http://www.idpf.org/2007/opf">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="bookid">urn:uuid:\(title)</dc:identifier>
                <dc:title>\(title)</dc:title>
                <dc:language>\(language)</dc:language>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="ch1" href="\(chapterHref)" media-type="application/xhtml+xml"/>
                \(extraManifest)
              </manifest>
              <spine page-progression-direction="\(pageProgression)">
                \(extraSpine)
                <itemref idref="ch1"/>
              </spine>
              \(extraPackageChildren)
            </package>
            """.utf8),
            "OPS/nav.xhtml": Data(xhtml(
                title: "Nav",
                body: navBody ?? #"<nav epub:type="toc"><ol><li><a href="\#(chapterHref)">Start</a></li></ol></nav>"#
            ).utf8),
            "OPS/\(chapterHref)": Data(xhtml(title: title, body: body, bodyAttributes: bodyAttributes).utf8)
        ]
        for (path, data) in extraEntries {
            entries[path] = data
        }
        return entries
    }
}

// MARK: - IR build shim
//
// The legacy `HTMLAttributedStringBuilder.build(html:config:)` render path was deleted when the
// pipelines were unified onto the RenderableNode IR. A large body of tests was written against
// that entry point; this shim keeps their call sites intact while routing every one of them
// through the production IR pipeline, so they now act as IR regression tests.
extension HTMLAttributedStringBuilder {
    struct IRShimBuildResult {
        let attributedString: NSAttributedString
        let imagePage: HTMLAttributedStringBuilder.ImagePage?
        let pageBackgroundImage: UIImage?
        let pageBackgroundImageSource: String?
        let anchorOffsets: [String: Int]
    }

    @MainActor
    func build(html: String, config: Config) async -> IRShimBuildResult {
        guard let ast = await buildStyledAST(html: html, config: config) else {
            return IRShimBuildResult(
                attributedString: NSAttributedString(),
                imagePage: nil,
                pageBackgroundImage: nil,
                pageBackgroundImageSource: nil,
                anchorOffsets: [:]
            )
        }
        let nodes = HTMLStyledASTRenderableNodeConverter.convert(body: ast)
        let settings = ReaderRenderSettings(
            theme: "test",
            textColor: config.textColor,
            backgroundColor: config.backgroundColor,
            fontSize: config.fontSize,
            lineHeightMultiple: config.lineHeightMultiple,
            lineSpacing: config.lineSpacing,
            paragraphSpacing: config.paragraphSpacing,
            letterSpacing: 0,
            marginH: 0,
            marginV: 0,
            footerHeight: 0,
            contentInsets: .zero,
            writingMode: config.writingMode
        )
        // Mirror the legacy font delegation: prefer the builder's resolvedFont hook, then fall
        // back to the resolvedFontFamily alias map (EPUB embedded-font aliases in production).
        let resolvedFontHook = resolvedFont
        let resolvedFamilyHook = resolvedFontFamily
        let rendererConfig = NodeAttributedStringRenderer.Config(
            from: settings,
            textColor: config.textColor,
            fontFamily: config.fontFamilyName,
            renderWidth: config.renderWidth,
            resolvedFont: { families, weight, italic, size in
                if let font = resolvedFontHook?(families, weight, italic, size) {
                    return font
                }
                guard let resolvedFamilyHook else { return nil }
                for raw in families {
                    let normalized = raw
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                        .lowercased()
                    guard !normalized.isEmpty,
                          let mapped = resolvedFamilyHook(normalized),
                          let font = UIFont(name: mapped, size: size)
                    else { continue }
                    return font
                }
                return nil
            },
            imageLoader: imageLoader,
            mediaURLResolver: mediaURLResolver,
            baseWritingDirection: config.baseWritingDirection
        )
        let attributed = NSMutableAttributedString(
            attributedString: await NodeAttributedStringRenderer(config: rendererConfig).render(nodes)
        )
        let background = await pageBackgroundImage(from: ast)
        // The legacy build() stamped the reader background across the whole chapter (minus block
        // backgrounds, and not at all under a page background image); several render tests sample
        // pixels relying on it.
        if attributed.length > 0 {
            let fullRange = NSRange(location: 0, length: attributed.length)
            if background == nil {
                attributed.addAttribute(.backgroundColor, value: config.backgroundColor, range: fullRange)
                attributed.enumerateAttribute(
                    HTMLAttributedStringBuilder.blockBackgroundColorAttribute,
                    in: fullRange
                ) { value, range, _ in
                    if value != nil {
                        attributed.removeAttribute(.backgroundColor, range: range)
                    }
                }
            }
        }
        return IRShimBuildResult(
            attributedString: attributed,
            imagePage: background == nil ? await imagePage(from: ast) : nil,
            pageBackgroundImage: background,
            pageBackgroundImageSource: backgroundImageSource(from: ast),
            anchorOffsets: anchorOffsets(in: attributed)
        )
    }
}
