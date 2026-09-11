import Foundation
import ReadiumShared

/// The original EPUB container, before Readium's resource transforms. Both local
/// ZIPs and HTTP range-backed ZIPs use this same path for package metadata and
/// obfuscated fonts. Retaining it also retains the injected HTTP client.
struct EPUBPackageResources {
    let container: any Container
    let opfPath: String
    let opfXML: String

    init(container: any Container) async throws {
        self.container = container
        let containerXML = try await Self.readText("META-INF/container.xml", from: container)
        let parserDelegate = EPUBContainerDocumentParser()
        let parser = XMLParser(data: Data(containerXML.utf8))
        parser.delegate = parserDelegate
        guard parser.parse(), let opfPath = parserDelegate.packagePath else {
            throw PublicationSessionError.parsingFailed("Invalid EPUB container.xml")
        }
        self.opfPath = opfPath
        self.opfXML = try await Self.readText(opfPath, from: container)
    }

    func read(_ href: String) async throws -> Data {
        guard let resource = Self.resource(href, in: container) else {
            throw PublicationSessionError.resourceNotFound(href)
        }
        return try await resource.read().get()
    }

    /// Missing optional metadata is valid. A present entry which cannot be read
    /// is an error, particularly when a remote connection is lost mid-open.
    func optionalText(_ href: String) async throws -> String? {
        guard Self.resource(href, in: container) != nil else { return nil }
        return try await Self.readText(href, from: container)
    }

    private static func readText(_ href: String, from container: any Container) async throws -> String {
        guard let resource = resource(href, in: container) else {
            throw PublicationSessionError.resourceNotFound(href)
        }
        let data = try await resource.read().get()
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw PublicationSessionError.parsingFailed("Invalid text encoding: \(href)")
        }
        return text
    }

    private static func resource(_ href: String, in container: any Container) -> (any Resource)? {
        let path = href.hasPrefix("/") ? String(href.dropFirst()) : href
        // OPF hrefs can be URL-encoded while ZIP entry names are decoded paths.
        // Preserve literal percent signs by checking the exact path first.
        for candidate in [path, path.removingPercentEncoding ?? path] {
            if let url = AnyURL(path: candidate), let resource = container[url] {
                return resource
            }
        }
        return nil
    }
}

private final class EPUBContainerDocumentParser: NSObject, XMLParserDelegate {
    var packagePath: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        guard elementName.split(separator: ":").last == "rootfile", packagePath == nil else { return }
        packagePath = attributeDict["full-path"]
    }
}
