import SwiftUI
import UIKit

// MARK: - Stable seed hashing

/// Picks a stable slot for a book across launches.
///
/// FNV-1a rather than `hashValue`, which is seeded per process and would hand the
/// same book a different cover on every relaunch. Legado has the same problem in
/// `BookCover.newDefaultDrawable` (it uses Kotlin's `hashCode()`, stable only
/// because the JVM's String hash is specified); ours has to be written out.
enum StableSeedHash {
    static func index(for seed: String, count: Int) -> Int {
        guard count > 1 else { return 0 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return Int(hash % UInt64(count))
    }
}

// MARK: - Palette

/// One generated cover's colour scheme. `ink` is guaranteed to read against
/// `top`/`bottom`, so a cover never depends on the app's accent — which the user
/// can retint per appearance theme and which would clash on some paper tones.
struct GeneratedCoverTone {
    let top: UIColor
    let bottom: UIColor
    let line: UIColor
    let ink: UIColor
}

/// Muted paper tones, one picked per book by title hash.
///
/// Legado ships a single illustrated cover and lets the user add more; the shelf
/// then hashes the book name to pick one. Here the same hash picks a tone instead,
/// so a shelf of cover-less books is legible at a glance without shipping art.
enum GeneratedCoverPalette {
    /// Warm, low-saturation papers. Every `ink` is dark enough to carry a title
    /// at small sizes on its own `bottom`.
    static let light: [GeneratedCoverTone] = [
        tone(top: 0xF7F2E8, bottom: 0xEDE3D1, line: 0xB9A88A, ink: 0x6B5836),  // 米白
        tone(top: 0xEDF2F0, bottom: 0xDCE8E3, line: 0x93B0A6, ink: 0x3F6459),  // 淡青
        tone(top: 0xF8F0F0, bottom: 0xEEDEDE, line: 0xC2A0A0, ink: 0x7A4B4B),  // 淺藕
        tone(top: 0xEEF2F7, bottom: 0xDCE5EF, line: 0x9FB2CA, ink: 0x42587A),  // 霧藍
        tone(top: 0xF2F5EB, bottom: 0xE3E9D7, line: 0xA9B98C, ink: 0x556438),  // 淺豆    
        tone(top: 0xF5EFF5, bottom: 0xE7DCE8, line: 0xB09EB6, ink: 0x63496C),  // 淡紫
    ]

    /// Ink tones for dark mode. Kept genuinely dark so a shelf doesn't glow, with
    /// `ink` lifted well above the background instead of the light set's inverse.
    static let dark: [GeneratedCoverTone] = [
        tone(top: 0x2A2A2E, bottom: 0x1A1A1D, line: 0x50525A, ink: 0xD8CDB6),  // 墨黑
        tone(top: 0x22272F, bottom: 0x14181F, line: 0x46536A, ink: 0xB9CBE4),  // 深靛
        tone(top: 0x2B2521, bottom: 0x1A1614, line: 0x57493D, ink: 0xE0C8A8),  // 深褐
        tone(top: 0x1F2724, bottom: 0x131A17, line: 0x3E5349, ink: 0xB0D2C2),  // 深松
        tone(top: 0x272230, bottom: 0x18141F, line: 0x4E4463, ink: 0xCEBEE2),  // 深紫
        tone(top: 0x2C2422, bottom: 0x1B1615, line: 0x5C4740, ink: 0xE6BFB2),  // 深赭
    ]

    static func tone(seed: String, colorScheme: ColorScheme) -> GeneratedCoverTone {
        let set = colorScheme == .dark ? dark : light
        return set[StableSeedHash.index(for: seed, count: set.count)]
    }

    private static func tone(top: UInt32, bottom: UInt32, line: UInt32, ink: UInt32) -> GeneratedCoverTone {
        GeneratedCoverTone(top: rgb(top), bottom: rgb(bottom), line: rgb(line), ink: rgb(ink))
    }

    private static func rgb(_ value: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Vertical name / author layout

/// One character placed on a generated cover. `x` is the glyph's horizontal
/// centre and `y` its baseline, matching the Android `Canvas.drawText` model this
/// layout is ported from.
struct GeneratedCoverGlyph: Equatable {
    let text: String
    let x: CGFloat
    let y: CGFloat
    let fontSize: CGFloat
    let strokeWidth: CGFloat
    let isAuthor: Bool
}

/// Where the vertical title and author sit on a cover-less book's artwork.
///
/// A port of Legado's `computeCoverTextLayout` (itself lifted out of the older
/// `CoverImageView.drawNameAuthor`), kept as pure geometry so it can be tested
/// without a graphics context. The constants below are Legado's, unchanged —
/// they are what makes a two-character title and a twelve-character title both
/// land sensibly on the same canvas.
enum GeneratedCoverTextLayout {

    /// Column pitch as a multiple of the outgoing column's font size.
    ///
    /// Legado advances by exactly the font size, and gets its gutter for free
    /// from the wrap shrinking `width/6` to `width/10`. Once the font is floored
    /// both columns are the same size, the pitch equals the glyph width, and the
    /// columns touch — 我师兄实在太稳健了 read as 我在 / 师太 across the rows
    /// instead of down them. The extra 15% is the gutter, and it reads better at
    /// full size too.
    private static let columnPitch: CGFloat = 1.15

    /// - Parameter minimumFontSize: floor under Legado's `width/6` and `width/10`.
    ///   Those fractions are right on a 104pt cover and unreadable on a 45pt shelf
    ///   row (7.5pt, then 4.5pt after a wrap). Flooring them keeps one algorithm
    ///   for every cover instead of a second layout for thumbnails — which is
    ///   what produced "苟在武道世界成圣" as 苟在武… on a shelf row.
    /// - Parameter lineHeight: line advance for a font size, per role. Legado
    ///   measures `descent - ascent + leading`; `UIFont.lineHeight` is the same
    ///   quantity.
    static func glyphs(
        width: CGFloat,
        height: CGFloat,
        name: String?,
        author: String?,
        drawName: Bool,
        drawAuthor: Bool,
        minimumFontSize: CGFloat = 0,
        lineHeight: (_ fontSize: CGFloat, _ isAuthor: Bool) -> CGFloat
    ) -> [GeneratedCoverGlyph] {
        guard width > 0, height > 0 else { return [] }
        let nameChars = drawName ? characters(of: name) : []
        let authorChars = drawAuthor ? characters(of: author) : []
        guard !nameChars.isEmpty || !authorChars.isEmpty else { return [] }

        var out: [GeneratedCoverGlyph] = []
        let topMargin = height * 0.05
        let bottomMargin = height * 0.95

        // ── Title: top-left, running down, wrapping rightwards into at most
        // three columns. The second column onward is narrower (width/10), so a
        // long title shrinks rather than overflowing the art.
        if !nameChars.isEmpty {
            var fontSize = max(minimumFontSize, width / 6)
            let wrappedFontSize = max(minimumFontSize, width / 10)
            var advance = lineHeight(fontSize, false)
            var columnX = width * 0.1 + fontSize / 2
            var y = topMargin + advance
            var column = 1
            for (index, char) in nameChars.enumerated() {
                let isLast = index == nameChars.count - 1
                let fillsColumn = y + advance > bottomMargin
                // Legado caps at three columns. A floored font can also run out
                // of width before that — a 45pt cover fits three 11pt columns
                // and no more — so the cap is whichever comes first.
                let nextColumnOverflows =
                    columnX + fontSize * columnPitch + wrappedFontSize / 2 > width
                if fillsColumn, !isLast, column == 3 || nextColumnOverflows {
                    out.append(glyph("…", columnX, y, fontSize, false))
                    break
                }
                out.append(glyph(char, columnX, y, fontSize, false))
                if isLast { continue }
                if fillsColumn {
                    column += 1
                    columnX += fontSize * columnPitch  // the *outgoing* column's pitch
                    fontSize = wrappedFontSize
                    advance = lineHeight(fontSize, false)
                    let remaining = CGFloat(nameChars.count - index - 1)
                    let needed = remaining * advance
                    y = needed < (bottomMargin - topMargin)
                        ? (height - needed) / 2 + advance
                        : topMargin + advance
                } else {
                    y += advance
                }
            }
        }

        // ── Author: a single column down the right edge, bottom-aligned, never
        // climbing past the title's top margin.
        if !authorChars.isEmpty {
            let fontSize = max(minimumFontSize, width / 10)
            let advance = lineHeight(fontSize, true)
            let columnX = width * 0.85
            let needed = CGFloat(authorChars.count) * advance
            var y = max(height * 0.95 - needed, height * 0.2)
            for char in authorChars {
                y = max(y, topMargin + advance)
                if y > height * 0.98 { break }
                out.append(glyph(char, columnX, y, fontSize, true))
                y += advance
            }
        }
        return out
    }

    private static func glyph(
        _ text: String, _ x: CGFloat, _ y: CGFloat, _ fontSize: CGFloat, _ isAuthor: Bool
    ) -> GeneratedCoverGlyph {
        // Legado's halo is textSize/5, sized to punch through a photographic
        // cover illustration. Ours sits on a flat gradient, where that width
        // reads as an outline around every glyph, so it is thinner here — the
        // job left is separating the text from the frame and corner motif.
        GeneratedCoverGlyph(
            text: text, x: x, y: y, fontSize: fontSize,
            strokeWidth: fontSize / 8, isAuthor: isAuthor
        )
    }

    /// Whether this title should be set vertically at all.
    ///
    /// Legado stacks every code point, Latin included, which turns "Norwegian
    /// Wood" into a column of single letters — CJK vertical typesetting doesn't
    /// do that to Latin script, and it reads as a bug. A title carrying Han
    /// characters or kana is set vertically; anything else goes horizontal.
    /// Mixed titles stay vertical, since the CJK is what sets the measure.
    static func prefersVerticalLayout(_ title: String) -> Bool {
        title.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF,      // hiragana, katakana
                 0x3400...0x4DBF,      // CJK ext A
                 0x4E00...0x9FFF,      // CJK unified
                 0xF900...0xFAFF,      // CJK compatibility
                 0x20000...0x2FA1F:    // CJK ext B and beyond
                return true
            default:
                return false
            }
        }
    }

    /// Splits into one string per rendered cell, dropping punctuation first.
    ///
    /// Legado strips it with `AppPattern.bdRegex` = `(\p{P})+` before drawing:
    /// stacked vertically, 《》（）—— sit orphaned in the middle of their own
    /// cell and read as gaps. `CharacterSet.punctuationCharacters` is the same
    /// Unicode general category P.
    static func characters(of text: String?) -> [String] {
        guard let text else { return [] }
        let stripped = String(
            String.UnicodeScalarView(
                text.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }
            )
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.map(String.init)
    }
}

// MARK: - Renderer

/// Draws the artwork a cover-less book shows: a toned paper ground, a double
/// frame with a corner motif, and the vertical title / author over it.
///
/// Legado composites the same two layers — a bundled `image_cover_default.jpg`
/// plus text drawn onto the canvas — but the bundled art can't come with us (GPL
/// project, unclear provenance for the illustration), so the ground is drawn.
///
/// Bitmaps are cached: a shelf re-evaluates these bodies on every scroll frame,
/// and `UIGraphicsImageRenderer` at cover size is far too expensive to run there.
enum GeneratedBookCoverRenderer {

    /// A cover this close to square is not a cover: it is the reader's 34pt
    /// toolbar button or the 56pt now-playing artwork, both clipped to a circle
    /// that would cut a rectangular frame's corners off. Those get one large
    /// initial. Everything portrait is a book and always shows its title —
    /// a 45pt shelf row reduced to a single character reads as a broken cover,
    /// not as a small one.
    private static let squareAspectRatio: CGFloat = 0.85

    /// Under this width a cover is a thumbnail: it keeps the same title layout,
    /// but drops the author and the inner rule / corner motif.
    ///
    /// The author goes because at 45pt it would sit at `width * 0.85` and
    /// collide with the title's third column; the ornament goes because at
    /// thumbnail size a dashed rule and an arc read as dirt.
    private static let thumbnailWidth: CGFloat = 80

    /// Floor under Legado's `width/6` title and `width/10` author. Chosen at the
    /// bottom of iOS's own readable range (caption2 is 11pt) — below it CJK
    /// glyphs on a shelf row stop resolving.
    private static let minimumReadableFontSize: CGFloat = 11

    /// Measured on an iPhone 17 Pro Max simulator: a cold render costs 0.8 ms
    /// (a short Latin title) to 4.2 ms (a title long enough to fill three
    /// columns), a cache hit 0.5 µs. So the cache size is the whole performance
    /// story — every miss while a shelf is scrolling is main-thread work.
    /// 24 MB holds roughly 45 covers at the bookshelf's 104×138 @3x, several
    /// screenfuls of an all-coverless shelf; NSCache still drops the lot under
    /// memory pressure.
    /// The three ways a cover is drawn, and which one a slot of this shape gets.
    /// Exposed so the dispatch can be asserted per slot size rather than
    /// inferred from a screenshot.
    enum Layout: Equatable {
        /// One large character. Square, circle-clipped slots only.
        case initial
        /// The same title layout as `.full`, without the author or the ornament.
        case thumbnail
        /// Title plus author, with the double frame and corner motif.
        case full

        init(size: CGSize) {
            guard size.width > 0, size.height > 0 else { self = .thumbnail; return }
            if size.width / size.height >= squareAspectRatio {
                self = .initial
            } else if size.width < thumbnailWidth {
                self = .thumbnail
            } else {
                self = .full
            }
        }
    }

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 96
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    static func image(
        title: String,
        author: String?,
        size: CGSize,
        colorScheme: ColorScheme,
        drawsName: Bool,
        drawsAuthor: Bool,
        scale: CGFloat
    ) -> UIImage? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        let author = displayableAuthor(author)
        let width = size.width.rounded()
        let height = size.height.rounded()
        let key = [
            title, author ?? "", "\(Int(width))x\(Int(height))",
            colorScheme == .dark ? "d" : "l",
            drawsName ? "1" : "0", drawsAuthor ? "1" : "0", "\(scale)",
        ].joined(separator: "|") as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let tone = GeneratedCoverPalette.tone(seed: title, colorScheme: colorScheme)
        let canvas = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            let cg = context.cgContext
            drawGround(in: cg, size: canvas, tone: tone)
            let layout = Layout(size: canvas)
            if layout == .initial {
                drawInitial(title: title, in: canvas, tone: tone)
            } else {
                let isFull = layout == .full
                drawFrame(in: cg, size: canvas, tone: tone, includesInnerRule: isFull)
                if isFull { drawCornerMotif(in: cg, size: canvas, tone: tone) }
                if GeneratedCoverTextLayout.prefersVerticalLayout(title) {
                    drawVerticalText(
                        title: title, author: author, size: canvas, tone: tone,
                        drawsName: drawsName, drawsAuthor: drawsAuthor && isFull
                    )
                } else {
                    drawHorizontalText(
                        title: title, author: author, size: canvas, tone: tone,
                        drawsName: drawsName, drawsAuthor: drawsAuthor && isFull
                    )
                }
            }
        }
        cache.setObject(image, forKey: key, cost: Int(width * height * scale * scale * 4))
        return image
    }

    /// Drops every cached bitmap. Called when the toggles or the tone set could
    /// have changed underneath a cover that is still on screen.
    static func invalidateCache() {
        cache.removeAllObjects()
    }

    /// Nil for an author worth nothing on a cover.
    ///
    /// Local imports carry the literal string 未知作者 rather than an empty
    /// author — `LocalPDFArchive`, `LocalMangaArchive`, `LocalAudiobookArchive`
    /// and `SharedImportQueueDrainer` all set it — so a TXT the user just added
    /// would otherwise get "未知作者" printed down its cover.
    private static func displayableAuthor(_ author: String?) -> String? {
        guard let trimmed = author?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed != localized("未知作者"),
              trimmed != "Unknown Author" else { return nil }
        return trimmed
    }

    // MARK: Layers

    private static func drawGround(in cg: CGContext, size: CGSize, tone: GeneratedCoverTone) {
        let colors = [tone.top.cgColor, tone.bottom.cgColor] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]
        ) else {
            tone.bottom.setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            return
        }
        cg.drawLinearGradient(
            gradient,
            start: CGPoint(x: size.width * 0.15, y: 0),
            end: CGPoint(x: size.width * 0.85, y: size.height),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    /// The double rule Legado's artwork has printed into it: a solid outer frame
    /// and a dashed inner one.
    private static func drawFrame(
        in cg: CGContext, size: CGSize, tone: GeneratedCoverTone, includesInnerRule: Bool
    ) {
        let outer = CGRect(origin: .zero, size: size).insetBy(
            dx: size.width * 0.055, dy: size.width * 0.055
        )
        cg.setStrokeColor(tone.line.withAlphaComponent(0.55).cgColor)
        cg.setLineWidth(max(0.5, size.width * 0.006))
        cg.setLineDash(phase: 0, lengths: [])
        cg.stroke(outer)

        guard includesInnerRule else { return }
        let inner = outer.insetBy(dx: size.width * 0.03, dy: size.width * 0.03)
        guard inner.width > 0, inner.height > 0 else { return }
        cg.setStrokeColor(tone.line.withAlphaComponent(0.38).cgColor)
        cg.setLineWidth(max(0.5, size.width * 0.004))
        cg.setLineDash(phase: 0, lengths: [size.width * 0.016, size.width * 0.014])
        cg.stroke(inner)
        cg.setLineDash(phase: 0, lengths: [])
    }

    /// Concentric quarter-arcs in the top-right and bottom-left, standing in for
    /// the cloud motif in the corners of Legado's artwork.
    private static func drawCornerMotif(in cg: CGContext, size: CGSize, tone: GeneratedCoverTone) {
        let inset = size.width * 0.055
        let topRight = CGPoint(x: size.width - inset, y: inset)
        let bottomLeft = CGPoint(x: inset, y: size.height - inset)
        cg.setStrokeColor(tone.line.withAlphaComponent(0.3).cgColor)
        cg.setLineWidth(max(0.5, size.width * 0.005))
        for step in 0..<3 {
            let radius = size.width * (0.10 + 0.055 * CGFloat(step))
            cg.addArc(
                center: topRight, radius: radius,
                startAngle: .pi / 2, endAngle: .pi, clockwise: false
            )
            cg.strokePath()
            cg.addArc(
                center: bottomLeft, radius: radius,
                startAngle: .pi * 1.5, endAngle: .pi * 2, clockwise: false
            )
            cg.strokePath()
        }
    }

    private static func drawVerticalText(
        title: String,
        author: String?,
        size: CGSize,
        tone: GeneratedCoverTone,
        drawsName: Bool,
        drawsAuthor: Bool
    ) {
        let glyphs = GeneratedCoverTextLayout.glyphs(
            width: size.width, height: size.height,
            name: title, author: author,
            drawName: drawsName, drawAuthor: drawsAuthor,
            minimumFontSize: minimumReadableFontSize,
            lineHeight: { fontSize, isAuthor in font(fontSize, isAuthor: isAuthor).lineHeight }
        )
        for glyph in glyphs {
            draw(
                glyph.text,
                centeredAt: glyph.x,
                baseline: glyph.y,
                font: font(glyph.fontSize, isAuthor: glyph.isAuthor),
                tone: tone,
                halo: glyph.strokeWidth / glyph.fontSize * 100
            )
        }
    }

    /// One glyph, `x` its horizontal centre and `baseline` its baseline — the
    /// Android `Canvas.drawText` model the layout is expressed in, which
    /// `NSAttributedString.draw(at:)` (top-left anchored) does not share.
    ///
    /// `halo` is a percentage of the font size, as `.strokeWidth` wants it; 0
    /// skips the pass. Two passes, as Legado does: halo first, ink over it. A
    /// single negative `.strokeWidth` would stroke *over* the fill and eat into
    /// the glyph instead.
    private static func draw(
        _ text: String,
        centeredAt x: CGFloat,
        baseline: CGFloat,
        font: UIFont,
        tone: GeneratedCoverTone,
        halo: CGFloat
    ) {
        var passes: [[NSAttributedString.Key: Any]] = []
        if halo > 0 {
            passes.append([
                .font: font,
                .strokeColor: tone.top.withAlphaComponent(0.9),
                .strokeWidth: halo,
            ])
        }
        passes.append([.font: font, .foregroundColor: tone.ink])
        for attributes in passes {
            let string = NSAttributedString(string: text, attributes: attributes)
            string.draw(at: CGPoint(x: x - string.size().width / 2, y: baseline - font.ascender))
        }
    }

    /// Latin, Cyrillic, Hangul and the rest: a normal horizontal title block near
    /// the top, author along the bottom — a plain title page rather than CJK
    /// vertical setting, which these scripts are not written in.
    ///
    /// Punctuation survives here, unlike the vertical path: it is only dropped
    /// there because a stacked 《 sits alone in its own cell. "Fahrenheit 451:
    /// A Novel" needs its colon.
    private static func drawHorizontalText(
        title: String,
        author: String?,
        size: CGSize,
        tone: GeneratedCoverTone,
        drawsName: Bool,
        drawsAuthor: Bool
    ) {
        let left = size.width * 0.135
        let contentWidth = size.width * 0.73
        guard contentWidth > 0 else { return }

        if drawsName {
            let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                // A narrow cover needs more of its height for the title: at
                // 45pt wide the type is already at the floor, so the only room
                // left to fit words in is vertical.
                let ceiling = size.height * (size.width < thumbnailWidth ? 0.74 : 0.52)
                let fitted = fittedTitle(text, width: contentWidth, maxHeight: ceiling, tone: tone)
                fitted.draw(with: CGRect(x: left, y: size.height * 0.13, width: contentWidth, height: ceiling),
                            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            }
        }

        guard drawsAuthor,
              let author = author?.trimmingCharacters(in: .whitespacesAndNewlines),
              !author.isEmpty else { return }
        let font = font(size.width / 13, isAuthor: true)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let string = NSAttributedString(string: author, attributes: [
            .font: font,
            .foregroundColor: tone.ink.withAlphaComponent(0.75),
            .paragraphStyle: paragraph,
        ])
        string.draw(with: CGRect(
            x: left, y: size.height * 0.87 - font.lineHeight,
            width: contentWidth, height: font.lineHeight
        ), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }

    /// Largest size at which the title still fits the block, stepping down from
    /// the vertical layout's own `width/6` and truncating if even the floor
    /// overflows.
    private static func fittedTitle(
        _ text: String, width: CGFloat, maxHeight: CGFloat, tone: GeneratedCoverTone
    ) -> NSAttributedString {
        // Word wrapping, not `.byTruncatingTail`: truncation makes TextKit lay
        // out a single line and clip it, which turned "Norwegian Wood" into
        // "Norw…" instead of wrapping onto a second line.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .natural
        func candidate(_ fontSize: CGFloat) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [
                .font: font(fontSize, isAuthor: false),
                .foregroundColor: tone.ink,
                .paragraphStyle: paragraph,
            ])
        }
        // Word wrapping breaks *inside* a word when the word alone is wider than
        // the column, which is how "Norwegian Wood" first came out as
        // "Norwegia / n Wood". Fitting the height is therefore not enough: the
        // longest word has to fit a line too.
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        func longestWordFits(_ fontSize: CGFloat) -> Bool {
            let font = font(fontSize, isAuthor: false)
            return words.allSatisfy { word in
                (word as NSString).size(withAttributes: [.font: font]).width <= width
            }
        }

        let floor = max(9, width / 9)
        var fontSize = max(floor, width / 4.5)
        let step = max(0.5, width / 40)
        while fontSize > floor {
            let attributed = candidate(fontSize)
            let bounds = attributed.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            if bounds.height <= maxHeight, longestWordFits(fontSize) { return attributed }
            fontSize -= step
        }
        // A single word longer than the column at even the floor size (a German
        // compound, a URL-ish title) still has to break — better than vanishing.
        return candidate(floor)
    }

    /// One large initial for slots too small for the vertical layout.    /// One large initial for slots too small for the vertical layout.
    private static func drawInitial(title: String, in size: CGSize, tone: GeneratedCoverTone) {
        guard let initial = GeneratedCoverTextLayout.characters(of: title).first else { return }
        let font = font(min(size.width, size.height) * 0.46, isAuthor: false)
        let string = NSAttributedString(
            string: initial, attributes: [.font: font, .foregroundColor: tone.ink]
        )
        let bounds = string.size()
        string.draw(at: CGPoint(
            x: (size.width - bounds.width) / 2,
            y: (size.height - bounds.height) / 2
        ))
    }

    /// Legado uses `DEFAULT_BOLD` for the title and `DEFAULT` for the author.
    /// Semibold is the iOS equivalent weight — full bold on PingFang closes up
    /// dense CJK glyphs at cover sizes.
    private static func font(_ size: CGFloat, isAuthor: Bool) -> UIFont {
        UIFont.systemFont(ofSize: size, weight: isAuthor ? .regular : .semibold)
    }
}

// MARK: - View

/// The shared no-cover artwork. Fills whatever frame the caller gives it, so
/// apply the size and `clipShape` outside:
/// ```swift
/// GeneratedBookCover(title: book.title, author: book.author)
///     .frame(width: 104, height: 138)
///     .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
/// ```
struct GeneratedBookCover: View {
    let title: String
    var author: String?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @ObservedObject private var settings = GlobalSettings.shared

    var body: some View {
        GeometryReader { proxy in
            if let image = GeneratedBookCoverRenderer.image(
                title: title,
                author: author,
                size: proxy.size,
                colorScheme: colorScheme,
                drawsName: settings.defaultCoverDrawsBookName,
                drawsAuthor: settings.defaultCoverDrawsBookAuthor,
                scale: displayScale
            ) {
                Image(uiImage: image)
                    .resizable()
            } else {
                Color(.secondarySystemBackground)
            }
        }
        // Matches what the old title card exposed: one element speaking the
        // book's name. Rows that already announce the title were double-speaking
        // before this change too — not a regression to fix here.
        .accessibilityElement()
        .accessibilityLabel(title)
    }
}

#Preview("生成封面") {
    VStack(spacing: 20) {
        HStack(spacing: 16) {
            GeneratedBookCover(title: "劍燭大荒", author: "青山鶴")
                .frame(width: 104, height: 138)
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
            GeneratedBookCover(title: "宿命之環", author: "愛潛水的烏賊")
                .frame(width: 104, height: 138)
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
            GeneratedBookCover(title: "史記·卷八十七·李斯列傳第二十七", author: "司馬遷")
                .frame(width: 104, height: 138)
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
        }
        HStack(spacing: 16) {
            GeneratedBookCover(title: "活著", author: "余華")
                .frame(width: 62, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.md))
            GeneratedBookCover(title: "百年孤獨", author: "馬奎斯")
                .frame(width: 52, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm))
            GeneratedBookCover(title: "圍城", author: "錢鍾書")
                .frame(width: 34, height: 34)
                .clipShape(Circle())
            GeneratedBookCover(title: "紅樓夢", author: "曹雪芹")
                .frame(width: 56, height: 56)
                .clipShape(Circle())
        }
    }
    .padding()
}
