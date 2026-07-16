import Foundation

extension EPUBTestFixtures {
    static func nonASCIIResourceIRI() -> Sample {
        Sample(entries: [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8),
            "OPS/package.opf": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package version="3.0" unique-identifier="id" xmlns="http://www.idpf.org/2007/opf">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="id">urn:yuedu:non-ascii-iri</dc:identifier>
                <dc:title>草枕 fixture</dc:title><dc:language>ja</dc:language>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="one" href="xhtml/一.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="one"/></spine>
            </package>
            """.utf8),
            "OPS/nav.xhtml": Data(xhtml(
                title: "目次",
                body: #"<nav epub:type="toc"><ol><li><a href="xhtml/一.xhtml">一</a></li></ol></nav>"#
            ).utf8),
            "OPS/xhtml/一.xhtml": Data(xhtml(
                title: "一",
                body: "<h1>一</h1><p>山路を登りながら、こう考えた。</p>"
            ).utf8),
        ])
    }
}
