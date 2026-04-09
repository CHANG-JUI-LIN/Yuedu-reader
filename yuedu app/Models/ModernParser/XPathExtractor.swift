import Foundation
#if canImport(Fuzi)
import Fuzi
#endif

struct XPathExtractor: RuleExtractor {
    func canHandle(rule: String) -> Bool {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        return lowered.hasPrefix("@xpath:") || trimmed.hasPrefix("//")
    }

    func extractList(from content: String, rule: String, baseURL: String) throws -> [String] {
        let normalizedRule = normalizeRule(rule)
        let (xpath, accessor) = splitXPathAndAccessor(normalizedRule)
        guard !xpath.isEmpty else { return [] }

        #if canImport(Fuzi)
        guard let document = try? HTMLDocument(string: content, encoding: .utf8) else {
            return RuleEngine.extractValueList(fromHTML: content, rule: rule, baseURL: baseURL)
        }

        let nodes = document.xpath(xpath)
        return nodes.compactMap { node in
            resolvedValue(from: node, accessor: accessor, baseURL: baseURL)
        }
        #else
        return RuleEngine.extractValueList(fromHTML: content, rule: rule, baseURL: baseURL)
        #endif
    }

    func extractValue(from content: String, rule: String, baseURL: String) throws -> String {
        try extractList(from: content, rule: rule, baseURL: baseURL).first ?? ""
    }

    private func normalizeRule(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("@xpath:") {
            return String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private func splitXPathAndAccessor(_ rule: String) -> (xpath: String, accessor: String?) {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let atIndex = trimmed.lastIndex(of: "@") else {
            return (trimmed, nil)
        }

        let prefix = String(trimmed[..<atIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = String(trimmed[trimmed.index(after: atIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty, !suffix.isEmpty else {
            return (trimmed, nil)
        }

        let lowered = suffix.lowercased()
        let supported = lowered == "text"
            || lowered == "html"
            || lowered == "outerhtml"
            || lowered == "href"
            || lowered == "src"
            || lowered.hasPrefix("attr(")
        return supported ? (prefix, suffix) : (trimmed, nil)
    }

    #if canImport(Fuzi)
    private func resolvedValue(from node: XMLElement, accessor: String?, baseURL: String) -> String? {
        guard let accessor, !accessor.isEmpty else {
            let text = node.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        let lowered = accessor.lowercased()
        switch lowered {
        case "text":
            let text = node.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        case "html", "outerhtml":
            let raw = node.rawXML.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? nil : raw
        default:
            let attributeName: String
            if lowered.hasPrefix("attr("), lowered.hasSuffix(")") {
                attributeName = String(accessor.dropFirst(5).dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                attributeName = accessor
            }
            guard !attributeName.isEmpty else { return nil }
            let raw = (node.attr(attributeName) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            if attributeName.lowercased() == "href" || attributeName.lowercased() == "src" {
                return RuleEngine.resolveURL(raw, base: baseURL)
            }
            return raw
        }
    }
    #endif
}
