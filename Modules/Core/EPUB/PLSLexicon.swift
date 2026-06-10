import Foundation

struct PLSLexicon: Equatable {
    struct Lexeme: Equatable {
        let grapheme: String
        let phoneme: String
    }

    let href: String
    let language: String?
    let alphabet: String?
    let lexemes: [Lexeme]

    static func parse(data: Data, href: String) -> PLSLexicon? {
        let delegate = PLSLexiconParserDelegate(href: href)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), !delegate.lexemes.isEmpty else { return nil }
        return PLSLexicon(
            href: href,
            language: delegate.language,
            alphabet: delegate.alphabet,
            lexemes: delegate.lexemes
        )
    }
}

private final class PLSLexiconParserDelegate: NSObject, XMLParserDelegate {
    let href: String
    var language: String?
    var alphabet: String?
    var lexemes: [PLSLexicon.Lexeme] = []

    private var currentElement = ""
    private var currentGrapheme = ""
    private var currentPhoneme = ""
    private var characterBuffer = ""

    init(href: String) {
        self.href = href
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = Self.localName(elementName)
        currentElement = name
        characterBuffer = ""

        if name == "lexicon" {
            alphabet = attributeDict["alphabet"]?.lowercased()
            language = attributeDict["xml:lang"] ?? attributeDict["lang"]
        } else if name == "lexeme" {
            currentGrapheme = ""
            currentPhoneme = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        characterBuffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = characterBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch Self.localName(elementName) {
        case "grapheme":
            currentGrapheme = value
        case "phoneme":
            currentPhoneme = value
        case "lexeme":
            if !currentGrapheme.isEmpty, !currentPhoneme.isEmpty {
                lexemes.append(.init(grapheme: currentGrapheme, phoneme: currentPhoneme))
            }
            currentGrapheme = ""
            currentPhoneme = ""
        default:
            break
        }
        currentElement = ""
        characterBuffer = ""
    }

    private static func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}
