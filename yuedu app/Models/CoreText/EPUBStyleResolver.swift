import CoreGraphics
import UIKit
import ReadiumShared

/// EPUB 樣式解析器：封裝 CSS @import 內聯、@font-face 抓取與字型注冊邏輯。
/// 讓 CoreTextPageEngine 專注於排版，不必直接處理 CSS 或字型下載。
@MainActor
final class EPUBStyleResolver {

    struct RegisteredFontFace {
        let alias: String
        let familyName: String
        let postScriptName: String
    }

    private let resourceProvider: any BookResourceProvider
    private let fontRegistrationService: any FontRegistrationServicing
    private(set) var registeredFontFaces: [String: RegisteredFontFace] = [:]
    private var registeredFontFileURLs: [String: URL] = [:]

    init(
        resourceProvider: any BookResourceProvider,
        fontRegistrationService: any FontRegistrationServicing
    ) {
        self.resourceProvider = resourceProvider
        self.fontRegistrationService = fontRegistrationService
    }

    nonisolated func cleanupFontFiles() {
        // Note: called from deinit which runs on main actor for @MainActor classes.
        // fontRegistrationService.cleanupTemporaryFile is file I/O and safe to call here.
        let service = fontRegistrationService
        // Cannot access @MainActor registeredFontFileURLs here; instead EPUBStyleResolver
        // makes the URLs available via a nonisolated snapshot taken at init.
        // For simplicity, schedule cleanup on MainActor.
        Task { @MainActor [weak self] in
            guard let self else { return }
            for url in self.registeredFontFileURLs.values {
                service.cleanupTemporaryFile(at: url)
            }
        }
    }

    // MARK: - 主入口

    func processStylesheet(_ cssText: String, cssHref: String, chapterHref: String) async -> String {
        let withImports = await inlineLocalImports(
            from: cssText, cssHref: cssHref, chapterHref: chapterHref, visited: [cssHref]
        )
        let fontFaces = extractFontFaces(from: withImports, cssHref: cssHref, chapterHref: chapterHref)
        if !fontFaces.isEmpty {
            print("[EPUBStyleResolver] discovered font faces: \(fontFaces.map { $0.alias })")
        }

        for fontFace in fontFaces {
            if registeredFontFaces[fontFace.alias] != nil { continue }
            guard
                let fontURL = URL(string: fontFace.resolvedURL),
                let response = try? await resourceProvider.response(for: fontURL),
                let registeredFont = fontRegistrationService.registerFont(
                    data: response.data,
                    alias: fontFace.alias,
                    existingTempURL: registeredFontFileURLs[fontFace.alias]
                )
            else {
                print("[EPUBStyleResolver] font registration FAILED alias=\(fontFace.alias)")
                continue
            }
            if let tempFileURL = registeredFont.tempFileURL {
                registeredFontFileURLs[fontFace.alias] = tempFileURL
            }
            registeredFontFaces[fontFace.alias] = RegisteredFontFace(
                alias: fontFace.alias,
                familyName: registeredFont.familyName,
                postScriptName: registeredFont.postScriptName
            )
            print("[EPUBStyleResolver] registered font alias=\(fontFace.alias) -> family=\(registeredFont.familyName) ps=\(registeredFont.postScriptName)")
        }

        let stripped = stripFontFaceBlocks(from: withImports)
        let withRewrittenURLs = rewriteResourceURLs(in: stripped, cssHref: cssHref)
        return rewriteFontFamilies(in: withRewrittenURLs)
    }

    func resolveRegisteredFont(
        families: [String],
        weight: Int,
        italic: Bool,
        size: CGFloat
    ) -> UIFont? {
        let normalizedFamilies = families
            .map(Self.normalizeFontName)
            .filter { !$0.isEmpty }

        for family in normalizedFamilies {
            let matchedFace = registeredFontFaces[family]
                ?? registeredFontFaces.values.first(where: {
                    Self.normalizeFontName($0.familyName) == family
                        || Self.normalizeFontName($0.postScriptName) == family
                })
            guard let matchedFace else { continue }

            let baseFont =
                UIFont(name: matchedFace.postScriptName, size: size)
                ?? UIFont(name: matchedFace.familyName, size: size)
            guard let baseFont else { continue }

            var descriptor = baseFont.fontDescriptor
            var traits = descriptor.symbolicTraits
            if italic { traits.insert(.traitItalic) }
            if weight >= 600 { traits.insert(.traitBold) }
            if let styledDescriptor = descriptor.withSymbolicTraits(traits) {
                descriptor = styledDescriptor
            }
            descriptor = descriptor.addingAttributes([.cascadeList: fontCascadeDescriptors()])
            return UIFont(descriptor: descriptor, size: size)
        }

        return nil
    }

    // MARK: - Static EPUB 路徑解算（供外部共用）

    /// 將 HTML img src（可能是相對路徑）解析成相對於章節 href 的絕對 EPUB 路徑。
    static func resolveImageHref(_ src: String, chapterHref: String) -> String {
        guard !src.isEmpty,
              !src.hasPrefix("http://"),
              !src.hasPrefix("https://"),
              !src.hasPrefix("data:") else { return src }
        if src.hasPrefix("/") { return String(src.dropFirst()) }

        let dir = (chapterHref as NSString).deletingLastPathComponent
        let combined = dir.isEmpty ? src : dir + "/" + src

        var stack: [String] = []
        for seg in combined.components(separatedBy: "/") {
            switch seg {
            case "", ".": break
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(seg)
            }
        }
        return stack.joined(separator: "/")
    }

    static func resolveCSSHref(_ href: String, cssHref: String, chapterHref: String) -> String {
        cssHref.isEmpty
            ? resolveImageHref(href, chapterHref: chapterHref)
            : resolveCSSRelativePath(href, cssHref: cssHref)
    }

    static func resolveCSSRelativePath(_ href: String, cssHref: String) -> String {
        guard !href.isEmpty,
              !href.hasPrefix("http://"),
              !href.hasPrefix("https://"),
              !href.hasPrefix("data:") else { return href }
        if href.hasPrefix("/") { return String(href.dropFirst()) }

        let dir = (cssHref as NSString).deletingLastPathComponent
        let combined = dir.isEmpty ? href : dir + "/" + href
        var stack: [String] = []
        for segment in combined.components(separatedBy: "/") {
            switch segment {
            case "", ".": break
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(segment)
            }
        }
        return stack.joined(separator: "/")
    }

    static func normalizeFontName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            .lowercased()
    }

    // MARK: - Private CSS Helpers

    private func inlineLocalImports(
        from cssText: String, cssHref: String, chapterHref: String, visited: Set<String>
    ) async -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"@import\s+(?:url\()?['"]?([^'")]+)['"]?\)?\s*;"#,
            options: [.caseInsensitive]
        ) else {
            return cssText
        }

        let nsCSS = cssText as NSString
        let matches = regex.matches(in: cssText, range: NSRange(location: 0, length: nsCSS.length))
        var result = cssText

        for match in matches.reversed() {
            let rawHref = nsCSS.substring(with: match.range(at: 1))
            if rawHref.hasPrefix("http://") || rawHref.hasPrefix("https://") {
                print("[EPUBStyleResolver] ignoring remote @import \(rawHref)")
                result = (result as NSString).replacingCharacters(in: match.range, with: "")
                continue
            }

            let resolved = Self.resolveCSSHref(rawHref, cssHref: cssHref, chapterHref: chapterHref)
            if visited.contains(resolved) {
                result = (result as NSString).replacingCharacters(in: match.range, with: "")
                continue
            }

            guard
                let response = try? await resourceProvider.response(for: resourceProvider.resourceURL(for: resolved)),
                let imported = String(data: response.data, encoding: .utf8)
            else {
                print("[EPUBStyleResolver] local @import FAILED \(resolved)")
                result = (result as NSString).replacingCharacters(in: match.range, with: "")
                continue
            }

            let inlined = await inlineLocalImports(
                from: imported, cssHref: resolved, chapterHref: chapterHref,
                visited: visited.union([resolved])
            )
            result = (result as NSString).replacingCharacters(in: match.range, with: inlined)
        }

        return result
    }

    private func rewriteResourceURLs(in cssText: String, cssHref: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"url\(\s*['"]?([^'")]+)['"]?\s*\)"#,
            options: [.caseInsensitive]
        ) else {
            return cssText
        }

        let nsCSS = cssText as NSString
        let matches = regex.matches(in: cssText, range: NSRange(location: 0, length: nsCSS.length))
        var result = cssText
        for match in matches.reversed() {
            let rawHref = nsCSS.substring(with: match.range(at: 1))
            if rawHref.hasPrefix("data:") || rawHref.hasPrefix("http://") || rawHref.hasPrefix("https://") {
                continue
            }
            let resolved = Self.resolveCSSRelativePath(rawHref, cssHref: cssHref)
            let absolute = resourceProvider.resourceURL(for: resolved).absoluteString
            result = (result as NSString).replacingCharacters(in: match.range(at: 1), with: absolute)
        }
        return result
    }

    private func extractFontFaces(
        from cssText: String, cssHref: String, chapterHref: String
    ) -> [(alias: String, resolvedURL: String)] {
        guard
            let blockRegex = try? NSRegularExpression(
                pattern: #"@font-face\s*\{.*?\}"#,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ),
            let familyRegex = try? NSRegularExpression(
                pattern: #"font-family\s*:\s*['"]?([^;'"}]+)['"]?"#,
                options: [.caseInsensitive]
            ),
            let srcRegex = try? NSRegularExpression(
                pattern: #"src\s*:\s*url\(\s*['"]?([^'")]+)['"]?\s*\)"#,
                options: [.caseInsensitive]
            )
        else {
            return []
        }

        let nsCSS = cssText as NSString
        return blockRegex.matches(
            in: cssText, range: NSRange(location: 0, length: nsCSS.length)
        ).compactMap { match in
            let block = nsCSS.substring(with: match.range)
            let nsBlock = block as NSString
            guard
                let familyMatch = familyRegex.firstMatch(
                    in: block, range: NSRange(location: 0, length: nsBlock.length)
                ),
                let srcMatch = srcRegex.firstMatch(
                    in: block, range: NSRange(location: 0, length: nsBlock.length)
                )
            else {
                print("[EPUBStyleResolver] unable to parse @font-face block: \(block)")
                return nil
            }
            let alias = Self.normalizeFontName(nsBlock.substring(with: familyMatch.range(at: 1)))
            let rawURL = nsBlock.substring(with: srcMatch.range(at: 1))
            let resolvedHref = Self.resolveCSSHref(rawURL, cssHref: cssHref, chapterHref: chapterHref)
            let resolvedURL = resourceProvider.resourceURL(for: resolvedHref).absoluteString
            return alias.isEmpty ? nil : (alias, resolvedURL)
        }
    }

    private func stripFontFaceBlocks(from cssText: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"@font-face\s*\{.*?\}"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return cssText
        }
        return regex.stringByReplacingMatches(
            in: cssText,
            range: NSRange(location: 0, length: (cssText as NSString).length),
            withTemplate: ""
        )
    }

    private func rewriteFontFamilies(in cssText: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"font-family\s*:\s*([^;}{]+)"#,
            options: [.caseInsensitive]
        ) else {
            return cssText
        }

        let nsCSS = cssText as NSString
        let matches = regex.matches(in: cssText, range: NSRange(location: 0, length: nsCSS.length))
        var result = cssText
        for match in matches.reversed() {
            let familyList = nsCSS.substring(with: match.range(at: 1))
            let rewritten = familyList
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { part in
                    let normalized = Self.normalizeFontName(String(part))
                    if let registered = registeredFontFaces[normalized] {
                        return "\"\(registered.familyName)\""
                    }
                    return String(part).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .joined(separator: ", ")
            result = (result as NSString).replacingCharacters(in: match.range(at: 1), with: rewritten)
        }
        return result
    }

    private func fontCascadeDescriptors() -> [UIFontDescriptor] {
        ["PingFangSC-Regular", "STHeitiSC-Light", "AppleColorEmoji"]
            .compactMap { UIFontDescriptor(name: $0, size: 0) }
    }
}
