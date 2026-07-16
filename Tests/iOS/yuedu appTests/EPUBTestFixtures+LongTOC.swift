import Foundation

extension EPUBTestFixtures {
    static func longTOC(chapterCount: Int = 80) -> Sample {
        precondition(chapterCount > 1)
        let manifest = (0..<chapterCount).map {
            #"<item id="c\#($0)" href="text/c\#($0).xhtml" media-type="application/xhtml+xml"/>"#
        }.joined(separator: "\n")
        let spine = (0..<chapterCount).map {
            #"<itemref idref="c\#($0)"/>"#
        }.joined(separator: "\n")
        let navItems = (0..<chapterCount).map {
            #"<li><a href="text/c\#($0).xhtml">Chapter \#($0 + 1)</a></li>"#
        }.joined(separator: "\n")

        var entries: [String: Data] = [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8),
            "EPUB/package.opf": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package version="3.0" unique-identifier="id" xmlns="http://www.idpf.org/2007/opf">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="id">urn:yuedu:long-toc</dc:identifier>
                <dc:title>Long TOC</dc:title><dc:language>en</dc:language>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                \(manifest)
              </manifest>
              <spine>\(spine)</spine>
            </package>
            """.utf8),
            "EPUB/nav.xhtml": Data(xhtml(
                title: "Contents",
                body: #"<nav epub:type="toc"><ol>\#(navItems)</ol></nav>"#
            ).utf8),
        ]
        for index in 0..<chapterCount {
            entries["EPUB/text/c\(index).xhtml"] = Data(xhtml(
                title: "Chapter \(index + 1)",
                body: "<h1>Chapter \(index + 1)</h1><p>Body \(index + 1)</p>"
            ).utf8)
        }
        return Sample(entries: entries)
    }
}
