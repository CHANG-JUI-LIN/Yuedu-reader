import Foundation

extension EPUBTestFixtures {
    @MainActor
    static func mixedLayout() -> Sample {
        let beforeParagraphs = (0..<48).map { index in
            "<p>Reflowable prose paragraph \(index) before the painting, long enough to exercise the composite page map.</p>"
        }.joined()
        return Sample(entries: [
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
                <dc:identifier id="id">urn:yuedu:mixed-layout</dc:identifier>
                <dc:title>Mixed Layout</dc:title><dc:language>en</dc:language>
                <meta property="rendition:layout">reflowable</meta>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="before" href="before.xhtml" media-type="application/xhtml+xml"/>
                <item id="painting" href="painting.xhtml" media-type="application/xhtml+xml"/>
                <item id="after" href="after.xhtml" media-type="application/xhtml+xml"/>
                <item id="image" href="painting.jpg" media-type="image/jpeg"/>
              </manifest>
              <spine>
                <itemref idref="before"/>
                <itemref idref="painting" properties="rendition:layout-pre-paginated"/>
                <itemref idref="after"/>
              </spine>
            </package>
            """.utf8),
            "EPUB/nav.xhtml": Data(xhtml(
                title: "Contents",
                body: #"<nav epub:type="toc"><ol><li><a href="before.xhtml">Before</a></li><li><a href="painting.xhtml">Painting</a></li><li><a href="after.xhtml">After</a></li></ol></nav>"#
            ).utf8),
            "EPUB/before.xhtml": Data(xhtml(
                title: "Before",
                body: "<h1>Before</h1>\(beforeParagraphs)"
            ).utf8),
            "EPUB/painting.xhtml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
              <head><title>Painting</title><meta name="viewport" content="width=1200,height=800"/></head>
              <body style="margin:0"><img src="painting.jpg" alt="A fixture painting" style="width:100%;height:100%"/></body>
            </html>
            """.utf8),
            "EPUB/after.xhtml": Data(xhtml(
                title: "After",
                body: "<h1>After</h1><p>Reflowable prose after the painting.</p>"
            ).utf8),
            "EPUB/painting.jpg": makeJPEG(width: 1200, height: 800),
        ])
    }
}
