import Foundation

extension EPUBTestFixtures {
    @MainActor
    static func fixedImageSpine() -> Sample {
        Sample(entries: [
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
                <dc:identifier id="id">urn:yuedu:fixed-image-spine</dc:identifier>
                <dc:title>Fixed Image Spine</dc:title><dc:language>en</dc:language>
                <meta property="rendition:layout">pre-paginated</meta>
                <meta property="rendition:viewport">width=1200, height=800</meta>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="page" href="painting.jpg" media-type="image/jpeg" fallback="fallback"/>
                <item id="fallback" href="fallback.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="page"/></spine>
            </package>
            """.utf8),
            "EPUB/nav.xhtml": Data(xhtml(
                title: "Contents",
                body: #"<nav epub:type="toc"><ol><li><a href="painting.jpg">Painting</a></li></ol></nav>"#
            ).utf8),
            "EPUB/fallback.xhtml": Data(xhtml(
                title: "Painting fallback",
                body: "<p>A fixture painting</p>"
            ).utf8),
            "EPUB/painting.jpg": makeJPEG(width: 1200, height: 800),
        ])
    }
}
