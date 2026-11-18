import Foundation

/// The stylesheet dialect of 評論列表 — the one comment-panel CSS of Cay (孤島) packs is
/// written in: declarations at the top dress the card, `.user {}`, `.text {}`, `.time {}`,
/// `.quote {}`, `.label {}` dress its parts, and `@dark {}` / `@light {}` hold what changes
/// with the reading background.
///
/// It is read onto the App's own list, never onto a 來源配置's web page: the page's markup is
/// the site's, and nothing says which of its elements is a name or a comment's words. What the
/// list has no counterpart for is listed in `Sheet.ignored`, so 評論列表 can say so.
enum CommentListCSS {
    /// A part of a comment card a selector names.
    enum Element: String, CaseIterable, Hashable, Sendable {
        case card, name, text, meta, quote, badge, avatar, floor, reply, author, likes
    }

    struct Color: Hashable, Sendable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double
    }

    enum Length: Hashable, Sendable {
        case points(Double)
        /// Times the part's own font size.
        case em(Double)

        func points(fontSize: Double) -> Double {
            switch self {
            case .points(let value): return value
            case .em(let value): return value * fontSize
            }
        }
    }

    enum LineHeight: Hashable, Sendable {
        /// Times the font size (`1.6`, `160%`, `1.6em`).
        case multiple(Double)
        case points(Double)
    }

    /// What one part wears. A value it does not set is nil: the layer under it decides.
    struct Declarations: Hashable, Sendable {
        var color: Color?
        var background: Color?
        var fontSize: Double?
        var fontWeight: Int?
        var lineHeight: LineHeight?
        var letterSpacing: Length?
        var lineClamp: Int?
        var cornerRadius: Double?
        var padding: Double?
        /// The avatar's side.
        var size: Double?
        /// A quote's leading bar.
        var barColor: Color?
        var barWidth: Double?
        /// `display: none`.
        var isHidden: Bool?
        /// Cay's `glass`: the card is frosted material instead of a fill.
        var glass: Bool?

        /// These, with `other`'s values over them wherever it sets one.
        func overlaid(with other: Declarations) -> Declarations {
            Declarations(
                color: other.color ?? color, background: other.background ?? background,
                fontSize: other.fontSize ?? fontSize, fontWeight: other.fontWeight ?? fontWeight,
                lineHeight: other.lineHeight ?? lineHeight, letterSpacing: other.letterSpacing ?? letterSpacing,
                lineClamp: other.lineClamp ?? lineClamp, cornerRadius: other.cornerRadius ?? cornerRadius,
                padding: other.padding ?? padding, size: other.size ?? size, barColor: other.barColor ?? barColor,
                barWidth: other.barWidth ?? barWidth, isHidden: other.isHidden ?? isHidden, glass: other.glass ?? glass)
        }
    }

    struct Sheet: Hashable, Sendable {
        var base: [Element: Declarations] = [:]
        var dark: [Element: Declarations] = [:]
        var light: [Element: Declarations] = [:]
        /// What was written but has no counterpart in the list, as written (`.user transform`).
        var ignored: [String] = []

        /// The part's declarations on a dark or a light reading background.
        func declarations(for element: Element, isDark: Bool) -> Declarations {
            let base = base[element] ?? Declarations()
            guard let scheme = (isDark ? dark : light)[element] else { return base }
            return base.overlaid(with: scheme)
        }

        var isEmpty: Bool { base.isEmpty && dark.isEmpty && light.isEmpty }
    }

    /// Reads `text`, at most `CommentListStyle.cssLimit` of it.
    static func parse(_ text: String) -> Sheet {
        let characters = Array(stripComments(String(text.prefix(CommentListStyle.cssLimit))))
        var index = 0
        let items = items(characters, at: &index, depth: 0)
        var sheet = Sheet()
        read(items, scheme: nil, into: &sheet)
        return sheet
    }

    // MARK: - Blocks

    private indirect enum Item {
        case declaration(property: String, value: String)
        case block(name: String, items: [Item])
    }

    /// Blocks nest at most this deep (`@dark { .user {} }` is two); a theme pack is someone
    /// else's file, and a stack of unclosed braces must not recurse without end.
    private static let depthLimit = 4

    private static func items(_ chars: [Character], at index: inout Int, depth: Int) -> [Item] {
        var found: [Item] = []
        var buffer = ""
        func flush() {
            let statement = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = ""
            guard let colon = statement.firstIndex(of: ":") else { return }
            let property = statement[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = statement[statement.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !property.isEmpty, !value.isEmpty else { return }
            found.append(.declaration(property: property, value: value))
        }
        while index < chars.count {
            let char = chars[index]
            index += 1
            switch char {
            case "{":
                let name = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                buffer = ""
                if depth < depthLimit {
                    found.append(.block(name: name, items: items(chars, at: &index, depth: depth + 1)))
                } else {
                    skipBlock(chars, at: &index)
                }
            case "}":
                flush()
                return found
            case ";":
                flush()
            default:
                buffer.append(char)
            }
        }
        flush()
        return found
    }

    /// Past the `}` that closes a block whose `{` was just read.
    private static func skipBlock(_ chars: [Character], at index: inout Int) {
        var open = 1
        while index < chars.count, open > 0 {
            if chars[index] == "{" { open += 1 } else if chars[index] == "}" { open -= 1 }
            index += 1
        }
    }

    private static func stripComments(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let start = rest.range(of: "/*") {
            result += rest[..<start.lowerBound]
            guard let end = rest[start.upperBound...].range(of: "*/") else { return result }
            rest = rest[end.upperBound...]
        }
        return result + rest
    }

    // MARK: - Meaning

    private enum Scheme { case dark, light }

    private static func read(_ items: [Item], scheme: Scheme?, into sheet: inout Sheet) {
        for item in items {
            switch item {
            case .declaration(let property, let value):
                apply(property, value, to: .card, label: "", scheme: scheme, into: &sheet)
            case .block(let name, let inner):
                if let blockScheme = self.scheme(of: name) {
                    guard scheme == nil else {
                        sheet.ignored.append(name)
                        continue
                    }
                    read(inner, scheme: blockScheme, into: &sheet)
                    continue
                }
                let elements = name.split(separator: ",").compactMap { element(of: String($0)) }
                guard !elements.isEmpty else {
                    sheet.ignored.append(name)
                    continue
                }
                for case .declaration(let property, let value) in inner {
                    for element in elements {
                        apply(property, value, to: element, label: name, scheme: scheme, into: &sheet)
                    }
                }
                for case .block(let nested, _) in inner {
                    sheet.ignored.append("\(name) \(nested)")
                }
            }
        }
    }

    private static func scheme(of name: String) -> Scheme? {
        let lowered = name.lowercased().replacingOccurrences(of: " ", with: "")
        if lowered == "@dark" || lowered.contains("prefers-color-scheme:dark") { return .dark }
        if lowered == "@light" || lowered.contains("prefers-color-scheme:light") { return .light }
        return nil
    }

    /// The part a selector names, by its last class: `.comment .user` is the name.
    private static func element(of selector: String) -> Element? {
        let last = selector
            .split(whereSeparator: { $0 == " " || $0 == ">" || $0 == "\n" || $0 == "\t" })
            .last.map(String.init) ?? ""
        let bare = last.split(separator: ":").first.map(String.init) ?? ""
        let name = bare.hasPrefix(".") ? String(bare.dropFirst()).lowercased() : bare.lowercased()
        switch name {
        case "*", "comment", "card", "item", "panel": return .card
        case "user", "name", "nick", "nickname": return .name
        case "text", "content", "body": return .text
        case "time", "meta", "date", "info": return .meta
        case "quote", "cite", "blockquote": return .quote
        case "label", "badge", "tag", "fans": return .badge
        case "avatar", "face": return .avatar
        case "floor", "level": return .floor
        case "reply", "replies": return .reply
        case "author", "author-tag": return .author
        case "likes", "like", "zan": return .likes
        default: return nil
        }
    }

    /// What each part draws: a property the list reads for one part is not read for another
    /// (`.user { padding }` has nothing to pad), and is listed as not applied.
    static let honoured: [Element: Set<String>] = {
        let text: Set<String> = ["color", "font-size", "font-weight"]
        let fill: Set<String> = ["background", "background-color"]
        let hide: Set<String> = ["display"]
        return [
            .card: Set(["color", "border-radius", "padding", "glass"]).union(fill),
            .name: text,
            .text: text.union(["line-height", "letter-spacing", "line-clamp", "-webkit-line-clamp"]),
            .meta: text.union(hide),
            .quote: text.union(fill).union(hide).union(["border-left", "border-left-color", "border-color"]),
            .badge: Set(["color"]).union(fill).union(hide),
            .author: Set(["color"]).union(fill).union(hide),
            .avatar: Set(["width", "height", "size", "border-radius"]).union(hide),
            .floor: text.union(hide),
            .reply: text.union(fill),
            .likes: text.union(hide),
        ]
    }()

    private static func apply(_ property: String, _ value: String, to element: Element, label: String,
                              scheme: Scheme?, into sheet: inout Sheet) {
        guard honoured[element]?.contains(property) == true else {
            let place = label.isEmpty ? "" : "\(label) "
            sheet.ignored.append("\(place)\(property): \(value)")
            return
        }
        var declarations = Declarations()
        let read: Bool
        switch property {
        case "color":
            declarations.color = color(value); read = declarations.color != nil
        case "background", "background-color":
            declarations.background = color(value); read = declarations.background != nil
        case "font-size":
            declarations.fontSize = points(value); read = declarations.fontSize != nil
        case "font-weight":
            declarations.fontWeight = weight(value); read = declarations.fontWeight != nil
        case "line-height":
            declarations.lineHeight = lineHeight(value); read = declarations.lineHeight != nil
        case "letter-spacing":
            declarations.letterSpacing = length(value); read = declarations.letterSpacing != nil
        case "line-clamp", "-webkit-line-clamp":
            declarations.lineClamp = Int(value).flatMap { $0 > 0 ? $0 : nil }; read = declarations.lineClamp != nil
        case "border-radius":
            declarations.cornerRadius = points(firstToken(value)); read = declarations.cornerRadius != nil
        case "padding":
            declarations.padding = points(firstToken(value)); read = declarations.padding != nil
        case "width", "height", "size":
            declarations.size = points(value); read = declarations.size != nil
        case "border-left", "border-left-color", "border-color":
            let tokens = value.split(separator: " ").map(String.init)
            declarations.barColor = tokens.lazy.compactMap(color).first ?? color(value)
            declarations.barWidth = property == "border-left" ? tokens.lazy.compactMap(points).first : nil
            read = declarations.barColor != nil || declarations.barWidth != nil
        case "display":
            declarations.isHidden = value.lowercased() == "none"; read = true
        case "glass":
            declarations.glass = ["true", "1", "on", "yes"].contains(value.lowercased()); read = true
        default:
            read = false
        }
        guard read else {
            let place = label.isEmpty ? "" : "\(label) "
            sheet.ignored.append("\(place)\(property): \(value)")
            return
        }
        switch scheme {
        case nil: sheet.base[element] = (sheet.base[element] ?? Declarations()).overlaid(with: declarations)
        case .dark: sheet.dark[element] = (sheet.dark[element] ?? Declarations()).overlaid(with: declarations)
        case .light: sheet.light[element] = (sheet.light[element] ?? Declarations()).overlaid(with: declarations)
        }
    }

    // MARK: - Values

    private static func firstToken(_ value: String) -> String {
        value.split(separator: " ").first.map(String.init) ?? value
    }

    /// `14px`, `14pt`, `14`: points, the list's own unit. Bounded: a pack's `9999px` is not a
    /// size anything here draws.
    static func points(_ value: String) -> Double? {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        let number = text.hasSuffix("px") || text.hasSuffix("pt") ? String(text.dropLast(2)) : text
        guard let parsed = Double(number.trimmingCharacters(in: .whitespaces)), parsed.isFinite,
              (0...200).contains(parsed) else { return nil }
        return parsed
    }

    static func length(_ value: String) -> Length? {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasSuffix("em"), let em = Double(text.dropLast(2)), em.isFinite, abs(em) <= 2 { return .em(em) }
        guard let parsed = Double(text.hasSuffix("px") || text.hasSuffix("pt") ? String(text.dropLast(2)) : text),
              parsed.isFinite, abs(parsed) <= 20 else { return nil }
        return .points(parsed)
    }

    static func lineHeight(_ value: String) -> LineHeight? {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasSuffix("%"), let percent = Double(text.dropLast()), (50...400).contains(percent) {
            return .multiple(percent / 100)
        }
        if text.hasSuffix("em"), let em = Double(text.dropLast(2)), (0.5...4).contains(em) { return .multiple(em) }
        if text.hasSuffix("px") || text.hasSuffix("pt") {
            return points(text).map(LineHeight.points)
        }
        guard let multiple = Double(text), (0.5...4).contains(multiple) else { return nil }
        return .multiple(multiple)
    }

    static func weight(_ value: String) -> Int? {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "normal": return 400
        case "bold", "bolder": return 700
        case "lighter": return 300
        case let number:
            guard let weight = Int(number), (100...900).contains(weight) else { return nil }
            return weight
        }
    }

    /// `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb()` / `rgba()`, `transparent`, and the CSS
    /// colour names (`CommentBubbleSVGRecognizer.cssNamedColors`, the one table of them).
    static func color(_ value: String) -> Color? {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        if text == "transparent" { return Color(red: 0, green: 0, blue: 0, alpha: 0) }
        if text.hasPrefix("#") {
            var digits = String(text.dropFirst())
            if digits.count == 3 || digits.count == 4 { digits = digits.map { "\($0)\($0)" }.joined() }
            guard digits.count == 6 || digits.count == 8, let raw = UInt64(digits, radix: 16) else { return nil }
            let hasAlpha = digits.count == 8
            let rgb = hasAlpha ? raw >> 8 : raw
            return Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                         blue: Double(rgb & 0xFF) / 255, alpha: hasAlpha ? Double(raw & 0xFF) / 255 : 1)
        }
        if text.hasPrefix("rgb"), let open = text.firstIndex(of: "("), text.hasSuffix(")") {
            let inner = text[text.index(after: open)..<text.index(before: text.endIndex)]
            let parts = inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).map(String.init)
            guard parts.count == 3 || parts.count == 4 else { return nil }
            func channel(_ part: String) -> Double? {
                if part.hasSuffix("%") { return Double(part.dropLast()).map { $0 / 100 } }
                return Double(part).map { $0 / 255 }
            }
            func alpha(_ part: String) -> Double? {
                if part.hasSuffix("%") { return Double(part.dropLast()).map { $0 / 100 } }
                return Double(part)
            }
            guard let red = channel(parts[0]), let green = channel(parts[1]), let blue = channel(parts[2]) else { return nil }
            let opacity = parts.count == 4 ? alpha(parts[3]) : 1
            guard let opacity else { return nil }
            func unit(_ value: Double) -> Double { min(max(value, 0), 1) }
            return Color(red: unit(red), green: unit(green), blue: unit(blue), alpha: unit(opacity))
        }
        guard let rgb = CommentBubbleSVGRecognizer.cssNamedColors[text] else { return nil }
        return Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                     blue: Double(rgb & 0xFF) / 255, alpha: 1)
    }
}

/// Stylesheets 評論列表 offers as a start. Written for this list: each names only what it
/// reads.
enum CommentListTemplates {
    struct Template: Identifiable, Hashable, Sendable {
        var id: String
        var titleKey: String
        var css: String
    }

    static let all: [Template] = [
        Template(id: "plain", titleKey: "無卡片", css: """
        background: transparent;
        padding: 4px;
        .text { line-height: 1.6; }
        .time { font-size: 12px; }
        """),
        Template(id: "glass", titleKey: "毛玻璃", css: """
        glass: true;
        border-radius: 18px;
        .user { font-weight: 600; }
        .quote { border-left: 3px solid #E0A33A; }
        """),
        Template(id: "paper", titleKey: "紙張", css: """
        background: #F6F1E7;
        border-radius: 10px;
        color: #3B3127;
        .user { color: #8A5A2B; font-weight: 700; }
        .text { line-height: 1.7; letter-spacing: 0.3px; }
        .time { color: #9C8C78; }
        .quote { background: #EFE6D4; border-left: 3px solid #C9A46A; }
        .label { color: #FFFFFF; background: #C9A46A; }
        @dark {
          background: #2A251F;
          color: #E8DDCB;
          .user { color: #D9A86C; }
          .quote { background: #3A3229; }
        }
        """),
    ]
}
