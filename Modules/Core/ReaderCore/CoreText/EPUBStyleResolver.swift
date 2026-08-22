import CoreGraphics
import UIKit
import ReadiumShared

/// EPUB style resolver: encapsulates CSS @import inlining, @font-face fetching, and font registration logic.
/// Keeps CoreTextPageEngine focused on layout without directly handling CSS or font downloads.
@MainActor
final class EPUBStyleResolver {

    private struct FontFaceDefinition {
        let alias: String
        let weight: Int
        let italic: Bool
        let resolvedURL: String
    }

    struct RegisteredFontFace {
        let alias: String
        let familyName: String
        let postScriptName: String
        var weight: Int = 400
        var isItalic: Bool = false
    }

    private let resourceProvider: any BookResourceProvider
    private let fontRegistrationService: any FontRegistrationServicing
    /// Representative face per alias (the first registered), used for CSS `font-family` rewriting.
    private(set) var registeredFontFaces: [String: RegisteredFontFace] = [:]
    /// Every registered variant per alias — one entry per `@font-face` weight/style. Lets resolution
    /// pick the closest match instead of collapsing a multi-face family (separate light / bold /
    /// italic `@font-face` blocks) down to whichever happened to register first.
    private(set) var registeredFontVariants: [String: [RegisteredFontFace]] = [:]
    private var registeredFontFileURLs: [String: URL] = [:]
    private var registeredFontAssets: [String: FontRegistrationResult] = [:]
    private var pendingFontFaces: [String: [FontFaceDefinition]] = [:]
    private var failedFontResourceURLs: Set<String> = []
    private var processedStylesheetCache: [String: String] = [:]

    init(
        resourceProvider: any BookResourceProvider,
        fontRegistrationService: any FontRegistrationServicing
    ) {
        self.resourceProvider = resourceProvider
        self.fontRegistrationService = fontRegistrationService
    }

    nonisolated func cleanupFontFiles() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let service = self.fontRegistrationService
            for url in self.registeredFontFileURLs.values {
                service.cleanupTemporaryFile(at: url)
            }
        }
    }

    // MARK: - Main Entry Point

    func processStylesheet(_ cssText: String, cssHref: String, chapterHref: String) async -> String {
        let cacheKey = cssHref.isEmpty ? "inline:\(chapterHref)" : cssHref
        if let cached = processedStylesheetCache[cacheKey] {
            return cached
        }

        let withImports = await inlineLocalImports(
            from: cssText, cssHref: cssHref, chapterHref: chapterHref, visited: [cssHref]
        )
        let fontFaces = extractFontFaces(from: withImports, cssHref: cssHref, chapterHref: chapterHref)
        if !fontFaces.isEmpty {
            AppLogger.parse("[EPUBStyleResolver] discovered font faces: \(fontFaces.map { $0.alias })")
        }
        for fontFace in fontFaces {
            let definitions = pendingFontFaces[fontFace.alias] ?? []
            if !definitions.contains(where: {
                $0.weight == fontFace.weight
                    && $0.italic == fontFace.italic
                    && $0.resolvedURL == fontFace.resolvedURL
            }) {
                pendingFontFaces[fontFace.alias, default: []].append(fontFace)
            }
        }

        let stripped = stripFontFaceBlocks(from: withImports)
        let processed = rewriteResourceURLs(in: stripped, cssHref: cssHref)
        processedStylesheetCache[cacheKey] = processed
        return processed
    }

    /// Browser-style lazy font loading: stylesheet parsing only records `@font-face` descriptors.
    /// Once cascade matching has produced the chapter AST, fetch and register the families that the
    /// chapter actually references. Local publication resources are immutable, so failed URLs are
    /// negatively cached for the lifetime of this resolver.
    func registerFontFaces(requests: Set<ResolvedFontRequest>) async {
        for request in requests.sorted(by: Self.fontRequestSort) {            let alias = Self.normalizeFontName(request.family)
            guard !alias.isEmpty else { continue }

            let definitions = (pendingFontFaces[alias] ?? []).sorted {
                Self.fontMatchScore(weight: $0.weight, italic: $0.italic, request: request)
                    < Self.fontMatchScore(weight: $1.weight, italic: $1.italic, request: request)
            }
            guard !definitions.isEmpty else { continue }

            var registeredScore = (registeredFontVariants[alias] ?? []).map {
                Self.fontMatchScore(weight: $0.weight, italic: $0.isItalic, request: request)
            }.min()

            for fontFace in definitions {
                let candidateScore = Self.fontMatchScore(
                    weight: fontFace.weight,
                    italic: fontFace.italic,
                    request: request
                )
                if let registeredScore, registeredScore <= candidateScore {
                    break
                }
                guard !failedFontResourceURLs.contains(fontFace.resolvedURL),
                      let fontURL = URL(string: fontFace.resolvedURL),
                      resourceProvider.resourceAvailability(for: fontURL) != false
                else {
                    failedFontResourceURLs.insert(fontFace.resolvedURL)
                    continue
                }

                let registeredFont: FontRegistrationResult
                if let cached = registeredFontAssets[fontFace.resolvedURL] {
                    registeredFont = cached
                } else {
                    let variantDetail = "\(alias)|\(fontFace.weight)|\(fontFace.italic ? "i" : "n")"
                    let response = try? await SourcePerfTrace.spanAsync(
                        "epub.font.fetch",
                        variantDetail
                    ) {
                        try await resourceProvider.response(for: fontURL)
                    }
                    guard let response else {
                        failedFontResourceURLs.insert(fontFace.resolvedURL)
                        AppLogger.parse("[EPUBStyleResolver] font resource FAILED alias=\(variantDetail)")
                        continue
                    }
                    let assetKey = Self.fontAssetKey(for: fontFace.resolvedURL)
                    let result = SourcePerfTrace.span(
                        "epub.font.register",
                        variantDetail
                    ) {
                        fontRegistrationService.registerFont(
                            data: response.data,
                            alias: assetKey,
                            existingTempURL: registeredFontFileURLs[fontFace.resolvedURL]
                        )
                    }
                    guard let result else {
                        failedFontResourceURLs.insert(fontFace.resolvedURL)
                        AppLogger.parse("[EPUBStyleResolver] font registration FAILED alias=\(variantDetail)")
                        continue
                    }
                    registeredFontAssets[fontFace.resolvedURL] = result
                    if let tempFileURL = result.tempFileURL {
                        registeredFontFileURLs[fontFace.resolvedURL] = tempFileURL
                    }
                    registeredFont = result
                }

                let face = RegisteredFontFace(
                    alias: alias,
                    familyName: registeredFont.familyName,
                    postScriptName: registeredFont.postScriptName,
                    weight: fontFace.weight,
                    isItalic: fontFace.italic
                )
                if !(registeredFontVariants[alias] ?? []).contains(where: {
                    $0.weight == face.weight && $0.isItalic == face.isItalic
                }) {
                    registeredFontVariants[alias, default: []].append(face)
                }
                if registeredFontFaces[alias] == nil {
                    registeredFontFaces[alias] = face
                }
                registeredScore = candidateScore
                AppLogger.parse("[EPUBStyleResolver] registered font alias=\(alias) weight=\(fontFace.weight) italic=\(fontFace.italic) -> family=\(registeredFont.familyName) ps=\(registeredFont.postScriptName)")
                break
            }
        }
    }

    /// Registers every pending `@font-face` family discovered so far (default
    /// weight/italic requests). Used by the browser-layout adapter, which has no
    /// AST to enumerate referenced fonts from — it registers everything and lets
    /// `resolveRegisteredFont` pick the closest variant.
    func registerAllPendingFontFaces() async {
        let aliases = Array(pendingFontFaces.keys)
        var requests = Set<ResolvedFontRequest>()
        for alias in aliases {
            requests.insert(ResolvedFontRequest(family: alias, weight: 400, italic: false))
            requests.insert(ResolvedFontRequest(family: alias, weight: 700, italic: false))
        }
        await registerFontFaces(requests: requests)
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
        // No CSS font-family means "use the reader default", not a failed embedded
        // font lookup. Logging this normal path produced hundreds of false ERROR
        // entries per chapter in exported diagnostics.
        guard !normalizedFamilies.isEmpty else { return nil }

        for family in normalizedFamilies {
            guard let matchedFace = bestVariant(for: family, weight: weight, italic: italic) else { continue }

            let baseFont =
                UIFont(name: matchedFace.postScriptName, size: size)
                ?? UIFont(name: matchedFace.familyName, size: size)
            guard let baseFont else {
                AppLogger.parse("[EPUBStyleResolver] resolveRegisteredFont matched variant but UIFont init FAILED family=\(family) ps=\(matchedFace.postScriptName) fam=\(matchedFace.familyName)")
                continue
            }

            var descriptor = baseFont.fontDescriptor
            var traits = descriptor.symbolicTraits
            let wantBold = weight >= 600
            if italic { traits.insert(.traitItalic) }
            if wantBold { traits.insert(.traitBold) }
            let traitApplied = descriptor.withSymbolicTraits(traits)
            if let styledDescriptor = traitApplied {
                descriptor = styledDescriptor
            }
            descriptor = descriptor.addingAttributes([.cascadeList: fontCascadeDescriptors()])
            let result = UIFont(descriptor: descriptor, size: size)
            let finalTraits = result.fontDescriptor.symbolicTraits
            // Did the bold/italic request actually land on a face? `withSymbolicTraits` returns nil when
            // the embedded family has no matching face (e.g. only an upright file registered). Compare
            // requested vs. delivered so we can see whether the embedded font silently dropped the trait.
            AppLogger.parse("[EPUBStyleResolver] resolveRegisteredFont req families=\(families) weight=\(weight) italic=\(italic) -> picked alias=\(family) pickedFaceWeight=\(matchedFace.weight) pickedFaceItalic=\(matchedFace.isItalic) ps=\(matchedFace.postScriptName) | withTraitsOK=\(traitApplied != nil) finalFont=\(result.fontName) finalBold=\(finalTraits.contains(.traitBold)) finalItalic=\(finalTraits.contains(.traitItalic)) (wantedBold=\(wantBold) wantedItalic=\(italic))", level: .trace)
            return addFontFallbacks(to: result, size: size)
        }

        AppLogger.parse("[EPUBStyleResolver] resolveRegisteredFont NO VARIANT families=\(families) weight=\(weight) italic=\(italic) registeredAliases=\(registeredFontVariants.keys.sorted()) variantsPerAlias=\(registeredFontVariants.mapValues { $0.map { "w\($0.weight)\($0.isItalic ? "i" : "n")/\($0.familyName)" } })", level: .trace)
        return nil
    }

    /// Picks the registered variant closest to the requested weight/style — weight distance first,
    /// then a style (italic) tiebreak. With one registered face this just returns it; with several
    /// (separate light / bold / italic `@font-face` blocks) it returns the right file instead of
    /// whichever registered first.
    private func bestVariant(for family: String, weight: Int, italic: Bool) -> RegisteredFontFace? {
        let variants: [RegisteredFontFace]
        if let direct = registeredFontVariants[family], !direct.isEmpty {
            variants = direct
        } else {
            variants = registeredFontVariants.values.flatMap { $0 }.filter {
                Self.normalizeFontName($0.familyName) == family
                    || Self.normalizeFontName($0.postScriptName) == family
            }
        }
        guard !variants.isEmpty else {
            // Fall back to the legacy representative-face map if variants weren't recorded.
            return registeredFontFaces[family]
                ?? registeredFontFaces.values.first {
                    Self.normalizeFontName($0.familyName) == family
                        || Self.normalizeFontName($0.postScriptName) == family
                }
        }
        return variants.min { lhs, rhs in
            let l = (abs(lhs.weight - weight), lhs.isItalic == italic ? 0 : 1)
            let r = (abs(rhs.weight - weight), rhs.isItalic == italic ? 0 : 1)
            return l.0 != r.0 ? l.0 < r.0 : l.1 < r.1
        }
    }

    // MARK: - Static EPUB Path Resolution (shared externally)

    /// Resolves an HTML img src (possibly relative) to an absolute EPUB path relative to the chapter href.
    /// Absolute URLs of any scheme (http, data, reader-book, …) pass through unchanged.
    static func resolveImageHref(_ src: String, chapterHref: String) -> String {
        guard !src.isEmpty,
              !src.contains("://"),
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

    private static func fontRequestSort(
        _ lhs: ResolvedFontRequest,
        _ rhs: ResolvedFontRequest
    ) -> Bool {
        let leftFamily = normalizeFontName(lhs.family)
        let rightFamily = normalizeFontName(rhs.family)
        if leftFamily != rightFamily { return leftFamily < rightFamily }
        if lhs.weight != rhs.weight { return lhs.weight < rhs.weight }
        return lhs.italic == false && rhs.italic == true
    }

    private static func fontMatchScore(
        weight: Int,
        italic: Bool,
        request: ResolvedFontRequest
    ) -> Int {
        abs(weight - request.weight) * 2 + (italic == request.italic ? 0 : 1)
    }

    /// Stable publication-resource identity for the temporary file name. Descriptor aliases are
    /// deliberately excluded because several aliases may point at the same underlying font asset.
    private static func fontAssetKey(for resolvedURL: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in resolvedURL.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "asset-\(String(hash, radix: 16))"
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
                AppLogger.parse("[EPUBStyleResolver] ignoring remote @import \(rawHref)")
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
                AppLogger.parse("[EPUBStyleResolver] local @import FAILED \(resolved)")
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
    ) -> [FontFaceDefinition] {
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
                AppLogger.parse("[EPUBStyleResolver] unable to parse @font-face block: \(block)")
                return nil
            }
            let alias = Self.normalizeFontName(nsBlock.substring(with: familyMatch.range(at: 1)))
            let rawURL = nsBlock.substring(with: srcMatch.range(at: 1))
            let resolvedHref = Self.resolveCSSHref(rawURL, cssHref: cssHref, chapterHref: chapterHref)
            let resolvedURL = resourceProvider.resourceURL(for: resolvedHref).absoluteString
            let weight = Self.fontDescriptorValue(in: block, property: "font-weight").map(Self.cssFontWeightValue) ?? 400
            let style = Self.fontDescriptorValue(in: block, property: "font-style") ?? "normal"
            let italic = style == "italic" || style == "oblique"
            return alias.isEmpty ? nil : FontFaceDefinition(
                alias: alias,
                weight: weight,
                italic: italic,
                resolvedURL: resolvedURL
            )
        }
    }

    /// Reads a single descriptor value (e.g. `font-weight: 700`) from an `@font-face` block, lowercased.
    private static func fontDescriptorValue(in block: String, property: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "\(property)\\s*:\\s*([a-z0-9]+)",
            options: [.caseInsensitive]
        ) else { return nil }
        let ns = block as NSString
        guard let match = regex.firstMatch(in: block, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1)).lowercased()
    }

    /// Maps a CSS `font-weight` keyword/number to a numeric weight (100–900). `@font-face` descriptors
    /// only carry absolute values, so `bolder`/`lighter` are treated as bold/normal.
    private static func cssFontWeightValue(_ raw: String) -> Int {
        switch raw {
        case "normal", "lighter": return 400
        case "bold", "bolder": return 700
        default: return Int(raw).map { min(900, max(100, $0)) } ?? 400
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
        ReaderFontCascade.descriptors()
    }

    private func addFontFallbacks(to font: UIFont, size: CGFloat) -> UIFont {
        ReaderFontCascade.preservingPrimary(font, size: size)
    }
}
