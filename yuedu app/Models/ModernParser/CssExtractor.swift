import Foundation
import SwiftSoup

struct CssExtractor: RuleExtractor {
    func canHandle(rule: String) -> Bool {
        let normalized = rule.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("@css:")
    }

    func extractList(from content: String, rule: String, baseURL: String) throws -> [String] {
        let normalizedRule = normalizeRule(rule)
        let (selector, accessor) = splitSelectorAndAccessor(normalizedRule)
        guard !selector.isEmpty else { return [] }

        let document = try SwiftSoup.parse(content)
        let elements = try document.select(selector).array()
        return elements.compactMap { element in
            resolvedValue(from: element, accessor: accessor, baseURL: baseURL)
        }
    }

    func extractValue(from content: String, rule: String, baseURL: String) throws -> String {
        try extractList(from: content, rule: rule, baseURL: baseURL).first ?? ""
    }

    private func normalizeRule(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("@css:") {
            return String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private func splitSelectorAndAccessor(_ rule: String) -> (selector: String, accessor: String?) {
        guard let atIndex = rule.lastIndex(of: "@") else {
            return (rule, nil)
        }
        let selector = String(rule[..<atIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let accessor = String(rule[rule.index(after: atIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if selector.isEmpty || accessor.isEmpty {
            return (rule, nil)
        }
        return (selector, accessor)
    }

    private func resolvedValue(from element: Element, accessor: String?, baseURL: String) -> String? {
        guard let accessor, !accessor.isEmpty else {
            return (try? element.text())?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let lowered = accessor.lowercased()
        if lowered == "text" {
            return (try? element.text())?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if lowered == "html" {
            return try? element.html()
        }
        if lowered == "outerhtml" {
            return try? element.outerHtml()
        }

        if lowered.hasPrefix("attr("), lowered.hasSuffix(")") {
            let attrName = String(accessor.dropFirst(5).dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !attrName.isEmpty else { return nil }
            let raw = try? element.attr(attrName)
            return normalizeURLIfNeeded(raw ?? "", attrName: attrName, baseURL: baseURL)
        }

        let raw = try? element.attr(accessor)
        return normalizeURLIfNeeded(raw ?? "", attrName: accessor, baseURL: baseURL)
    }

    private func normalizeURLIfNeeded(_ value: String, attrName: String, baseURL: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lowered = attrName.lowercased()
        if lowered == "href" || lowered == "src" {
            return RuleEngine.resolveURL(trimmed, base: baseURL)
        }
        return trimmed
    }
}
