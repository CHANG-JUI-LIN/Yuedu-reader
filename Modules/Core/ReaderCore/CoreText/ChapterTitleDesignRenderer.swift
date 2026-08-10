import CoreText
import UIKit

/// An immutable, fully-resolved snapshot that the paginator can carry without
/// consulting mutable settings or the asset store while drawing.
struct ChapterTitleRenderPlan: Equatable, @unchecked Sendable {
    let accessibilityText: String
    let canvasSize: CGSize
    let layers: [ChapterTitleRenderedLayer]
}

/// Maps the editor's logical horizontal canvas into a reader surface. Vertical
/// layouts swap the logical axes and pin the title to the right-to-left block
/// start instead of rotating the complete page context.
enum ChapterTitleCanvasGeometry {
    static func resolve(
        canvasSize: CGSize,
        container: CGRect,
        writingMode: ReaderWritingMode
    ) -> CGRect {
        guard canvasSize.width.isFinite, canvasSize.height.isFinite,
              canvasSize.width > 0, canvasSize.height > 0,
              container.width.isFinite, container.height.isFinite,
              container.width > 0, container.height > 0 else {
            return .zero
        }

        let resolvedSize = writingMode.isVertical
            ? CGSize(width: canvasSize.height, height: canvasSize.width)
            : canvasSize
        let scale = min(
            1,
            container.width / resolvedSize.width,
            container.height / resolvedSize.height
        )
        let size = CGSize(
            width: resolvedSize.width * scale,
            height: resolvedSize.height * scale
        )
        return CGRect(
            x: writingMode.isVertical ? container.maxX - size.width : container.minX,
            y: container.minY,
            width: size.width,
            height: size.height
        )
    }
}

struct ChapterTitleRenderedLayer: Equatable, @unchecked Sendable {
    let id: UUID
    let frame: CGRect
    let rotationRadians: CGFloat
    let attributedText: NSAttributedString?
    let image: UIImage?
    let backgroundImage: UIImage?
    let shape: ChapterTitleRenderedShape?
    let style: ChapterTitleLayerStyle
    let text: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.frame == rhs.frame
            && lhs.rotationRadians == rhs.rotationRadians
            && attributedStringsEqual(lhs.attributedText, rhs.attributedText)
            && imagesEqual(lhs.image, rhs.image)
            && imagesEqual(lhs.backgroundImage, rhs.backgroundImage)
            && lhs.shape == rhs.shape
            && lhs.style == rhs.style
            && lhs.text == rhs.text
    }

    private static func attributedStringsEqual(
        _ lhs: NSAttributedString?,
        _ rhs: NSAttributedString?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return lhs.isEqual(to: rhs)
        default: return false
        }
    }

    private static func imagesEqual(_ lhs: UIImage?, _ rhs: UIImage?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return lhs.isEqual(rhs)
        default: return false
        }
    }
}

enum ChapterTitleRenderedShape: Equatable, Sendable {
    case line(ChapterTitleLineStyle)
    case rectangle
}

enum ChapterTitleDesignRendererError: Error, Equatable, Sendable {
    case unsupportedDesignVersion(Int)
    case legacySourceRequiresMigration
    case missingAsset(UUID)
    case invalidAsset(UUID)
    case invalidCanvasSize
}

enum ChapterTitleDesignRenderer {
    static func compile(
        title: String,
        design: ChapterTitleDesign,
        appearance: ReaderStyleAppearance,
        writingMode: ReaderWritingMode,
        renderWidth: CGFloat,
        assetStore: ReaderStyleAssetStore
    ) async throws -> ChapterTitleRenderPlan {
        guard design.version == ChapterTitleDesign.currentVersion else {
            throw ChapterTitleDesignRendererError.unsupportedDesignVersion(design.version)
        }
        guard !design.layers.isEmpty || design.legacySource == nil else {
            throw ChapterTitleDesignRendererError.legacySourceRequiresMigration
        }
        guard renderWidth.isFinite, renderWidth > 0,
              design.canvasHeight.isFinite, design.canvasHeight > 0,
              design.canvasAspectRatio.isFinite, design.canvasAspectRatio > 0 else {
            throw ChapterTitleDesignRendererError.invalidCanvasSize
        }

        let resolvedDesign = design.resolved(for: writingMode)
        let horizontalCanvas = CGSize(
            width: renderWidth,
            height: CGFloat(resolvedDesign.canvasHeight)
        )
        let canvasSize = writingMode.isVertical
            ? CGSize(width: horizontalCanvas.height, height: horizontalCanvas.width)
            : horizontalCanvas
        guard canvasSize.width.isFinite, canvasSize.height.isFinite,
              canvasSize.width > 0, canvasSize.height > 0 else {
            throw ChapterTitleDesignRendererError.invalidCanvasSize
        }

        // Split exactly once so every dynamic field is derived from one stable
        // interpretation of the original source title.
        let splitTitle = ChapterTitleSplitter.split(title)
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let visibleLayers = resolvedDesign.layers.filter(\.isVisible)
        let requiredIDs = Set(visibleLayers.flatMap { layer in
            let style = appearance == .light ? layer.lightStyle : layer.darkStyle
            return requiredAssetIDs(for: layer, style: style)
        })
        var resolvedImages: [UUID: UIImage] = [:]
        resolvedImages.reserveCapacity(requiredIDs.count)
        for assetID in requiredIDs {
            resolvedImages[assetID] = try await loadImage(
                id: assetID,
                from: assetStore
            )
        }

        let layers = visibleLayers.map { layer -> ChapterTitleRenderedLayer in
            let style = appearance == .light ? layer.lightStyle : layer.darkStyle
            let text = resolvedText(
                for: layer.content,
                originalTitle: title,
                splitTitle: splitTitle
            )
            let attributedText = text.map {
                makeAttributedText(
                    $0,
                    layerKind: layer.kind,
                    style: style,
                    appearance: appearance
                )
            }
            let contentImageID = contentImageID(for: layer.content)
                ?? style.imagePresentation?.assetID
            let backgroundImageID = style.ruleStyle.decoration.backgroundImage?.assetID

            return ChapterTitleRenderedLayer(
                id: layer.id,
                frame: layer.frame.denormalized(in: canvas),
                rotationRadians: CGFloat(layer.rotation.degrees * .pi / 180),
                attributedText: attributedText,
                image: contentImageID.flatMap { resolvedImages[$0] },
                backgroundImage: backgroundImageID.flatMap { resolvedImages[$0] },
                shape: resolvedShape(for: layer),
                style: style,
                text: text
            )
        }

        return ChapterTitleRenderPlan(
            accessibilityText: title,
            canvasSize: canvasSize,
            layers: layers
        )
    }

    private static func requiredAssetIDs(
        for layer: ChapterTitleLayer,
        style: ChapterTitleLayerStyle
    ) -> [UUID] {
        var result: [UUID] = []
        if let id = contentImageID(for: layer.content) {
            result.append(id)
        }
        if let id = style.imagePresentation?.assetID {
            result.append(id)
        }
        if let id = style.ruleStyle.decoration.backgroundImage?.assetID {
            result.append(id)
        }
        return result
    }

    private static func loadImage(
        id: UUID,
        from assetStore: ReaderStyleAssetStore
    ) async throws -> UIImage {
        if let cached = await assetStore.cachedImage(for: id) {
            return cached
        }

        let data: Data
        do {
            // The process-local UIImage cache is intentionally not authoritative:
            // after app launch the manifest can be warm while this cache is empty.
            data = try await assetStore.imageData(for: id)
        } catch let error as ReaderStyleAssetStoreError {
            switch error {
            case .assetNotFound:
                throw ChapterTitleDesignRendererError.missingAsset(id)
            default:
                throw ChapterTitleDesignRendererError.invalidAsset(id)
            }
        } catch {
            throw ChapterTitleDesignRendererError.invalidAsset(id)
        }

        guard let image = UIImage(data: data) else {
            throw ChapterTitleDesignRendererError.invalidAsset(id)
        }
        return image
    }

    private static func contentImageID(for content: ChapterTitleLayerContent) -> UUID? {
        guard case let .image(id) = content else { return nil }
        return id
    }

    private static func resolvedText(
        for content: ChapterTitleLayerContent,
        originalTitle: String,
        splitTitle: (number: String?, name: String)
    ) -> String? {
        switch content {
        case let .dynamic(field):
            switch field {
            case .number: return splitTitle.number ?? ""
            case .name: return splitTitle.name
            case .title: return originalTitle
            }
        case let .text(text):
            return text
        case .line, .image, .none:
            return nil
        }
    }

    private static func resolvedShape(for layer: ChapterTitleLayer) -> ChapterTitleRenderedShape? {
        switch layer.content {
        case let .line(style): return .line(style)
        case .none where layer.kind == .colorBlock: return .rectangle
        default: return nil
        }
    }

    private static func makeAttributedText(
        _ text: String,
        layerKind: ChapterTitleLayerKind,
        style: ChapterTitleLayerStyle,
        appearance: ReaderStyleAppearance
    ) -> NSAttributedString {
        let textStyle = style.ruleStyle.text
        let fontSize = max(
            CGFloat(textStyle.fontSize ?? defaultFontSize(for: layerKind)),
            0.01
        )
        let weight = chapterWeight(from: textStyle.fontWeight ?? 400)
        var font = UserReaderFontResolver.titleFont(
            size: fontSize,
            weight: weight,
            postScriptName: textStyle.fontPostScriptName
        )
        if textStyle.italic == true,
           !font.fontDescriptor.symbolicTraits.contains(.traitItalic) {
            if let descriptor = font.fontDescriptor.withSymbolicTraits(
                font.fontDescriptor.symbolicTraits.union(.traitItalic)
            ) {
                let candidate = UIFont(descriptor: descriptor, size: fontSize)
                font = candidate.familyName == font.familyName
                    ? candidate
                    : HTMLAttributedStringBuilder.synthesizedObliqueFont(from: font)
            } else {
                font = HTMLAttributedStringBuilder.synthesizedObliqueFont(from: font)
            }
        }
        font = UIFontMetrics.default.scaledFont(for: font)
        font = ReaderFontCascade.preservingPrimary(font, size: font.pointSize)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.textAlignment.nsTextAlignment
        if let lineHeight = textStyle.lineHeight, lineHeight > 0 {
            paragraph.minimumLineHeight = CGFloat(lineHeight)
            paragraph.maximumLineHeight = CGFloat(lineHeight)
        }

        let colorHex = textStyle.colorHex ?? defaultTextColor(for: appearance)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: GlobalSettings.uiColor(rgbHex: colorHex),
            .paragraphStyle: paragraph,
        ]
        if let letterSpacing = textStyle.letterSpacing {
            attributes[.kern] = CGFloat(letterSpacing) as NSNumber
        }
        if textStyle.underline == true {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if textStyle.strikethrough == true {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if style.writingDirection == .vertical {
            attributes[NSAttributedString.Key(kCTVerticalFormsAttributeName as String)] = true
        }
        attributes.merge(
            UserReaderFontResolver.syntheticBoldAttributes(
                for: font,
                isBoldRequested: (textStyle.fontWeight ?? 400) >= 600
            )
        ) { _, new in new }
        return NSAttributedString(string: text, attributes: attributes)
    }

    private static func defaultFontSize(for kind: ChapterTitleLayerKind) -> Double {
        switch kind {
        case .chapterNumber: return 16
        case .chapterName, .originalTitle: return 28
        case .customText, .ornament: return 20
        case .line, .colorBlock, .image: return 16
        }
    }

    private static func defaultTextColor(for appearance: ReaderStyleAppearance) -> UInt32 {
        appearance == .light ? 0x1C1C1E : 0xF2F2F7
    }

    private static func chapterWeight(from cssWeight: Int) -> ChapterTitleWeight {
        switch cssWeight {
        case ..<350: return .light
        case 350..<450: return .regular
        case 450..<550: return .medium
        case 550..<650: return .semibold
        default: return .bold
        }
    }
}

/// The single painter for reader pages, scroll chunks and the designer preview.
/// Plans are already appearance-, writing-mode- and asset-resolved, so drawing
/// performs no I/O and never consults mutable settings.
enum ChapterTitleCanvasPainter {
    static func draw(
        _ plan: ChapterTitleRenderPlan,
        in rect: CGRect,
        writingMode: ReaderWritingMode,
        context: CGContext
    ) {
        guard plan.canvasSize.width.isFinite, plan.canvasSize.height.isFinite,
              plan.canvasSize.width > 0, plan.canvasSize.height > 0,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else { return }

        let scale = min(
            rect.width / plan.canvasSize.width,
            rect.height / plan.canvasSize.height
        )
        let drawSize = CGSize(
            width: plan.canvasSize.width * scale,
            height: plan.canvasSize.height * scale
        )
        let origin = CGPoint(
            x: rect.minX + (rect.width - drawSize.width) / 2,
            y: rect.minY + (rect.height - drawSize.height) / 2
        )

        context.saveGState()
        UIGraphicsPushContext(context)
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: scale, y: scale)
        for layer in plan.layers {
            draw(
                layer,
                canvasHeight: plan.canvasSize.height,
                writingMode: writingMode,
                context: context
            )
        }
        UIGraphicsPopContext()
        context.restoreGState()
    }

    private static func draw(
        _ layer: ChapterTitleRenderedLayer,
        canvasHeight: CGFloat,
        writingMode: ReaderWritingMode,
        context: CGContext
    ) {
        context.saveGState()
        context.translateBy(x: layer.frame.midX, y: layer.frame.midY)
        context.rotate(by: layer.rotationRadians)
        context.translateBy(x: -layer.frame.midX, y: -layer.frame.midY)

        let decoration = layer.style.ruleStyle.decoration
        context.setAlpha(CGFloat(decoration.opacity ?? 1))
        let radius = min(
            CGFloat(decoration.cornerRadius ?? 0),
            min(layer.frame.width, layer.frame.height) / 2
        )
        let path = UIBezierPath(
            roundedRect: layer.frame,
            cornerRadius: radius
        ).cgPath

        drawShadows(decoration.shadows, path: path, context: context)
        context.saveGState()
        context.addPath(path)
        context.clip()
        if let colorHex = decoration.backgroundColorHex {
            context.setFillColor(color(colorHex).cgColor)
            context.fill(layer.frame)
        }
        if let gradient = decoration.backgroundGradient {
            draw(gradient, in: layer.frame, context: context)
        }
        if let image = layer.backgroundImage,
           let presentation = decoration.backgroundImage {
            draw(image, presentation: presentation, in: layer.frame, context: context)
        }
        context.restoreGState()

        if case let .line(style) = layer.shape {
            context.setStrokeColor(color(style.colorHex).cgColor)
            context.setLineWidth(CGFloat(style.width))
            if style.isDashed {
                let unit = max(CGFloat(style.width), 1)
                context.setLineDash(phase: 0, lengths: [unit * 3, unit * 2])
            }
            if writingMode.isVertical {
                context.move(to: CGPoint(x: layer.frame.midX, y: layer.frame.minY))
                context.addLine(to: CGPoint(x: layer.frame.midX, y: layer.frame.maxY))
            } else {
                context.move(to: CGPoint(x: layer.frame.minX, y: layer.frame.midY))
                context.addLine(to: CGPoint(x: layer.frame.maxX, y: layer.frame.midY))
            }
            context.strokePath()
        }

        if let image = layer.image {
            if let presentation = layer.style.imagePresentation {
                draw(image, presentation: presentation, in: layer.frame, context: context)
            } else if image.size.width > 0, image.size.height > 0 {
                let scale = min(
                    layer.frame.width / image.size.width,
                    layer.frame.height / image.size.height
                )
                let size = CGSize(
                    width: image.size.width * scale,
                    height: image.size.height * scale
                )
                image.draw(in: CGRect(
                    x: layer.frame.midX - size.width / 2,
                    y: layer.frame.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                ))
            }
        }

        drawBorders(
            decoration.borders,
            rect: layer.frame,
            radius: radius,
            context: context
        )
        if let attributedText = layer.attributedText {
            draw(
                attributedText,
                in: layer.frame,
                canvasHeight: canvasHeight,
                writingMode: writingMode,
                context: context
            )
        }
        context.restoreGState()
    }

    private static func draw(
        _ attributedText: NSAttributedString,
        in rect: CGRect,
        canvasHeight: CGFloat,
        writingMode: ReaderWritingMode,
        context: CGContext
    ) {
        guard attributedText.length > 0 else { return }
        guard writingMode.isVertical else {
            attributedText.draw(
                with: rect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            return
        }

        let coreTextRect = CGRect(
            x: rect.minX,
            y: canvasHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        guard coreTextRect.width > 0, coreTextRect.height > 0 else { return }

        let framesetter = CTFramesetterCreateWithAttributedString(
            attributedText as CFAttributedString
        )
        let range = CFRange(location: 0, length: attributedText.length)

        // Horizontal text is drawn with `NSAttributedString.draw(with:)`, which OVERFLOWS its rect
        // rather than clipping — a layer box shorter than its own font still shows the title, so
        // designs are routinely saved that way. Rotated for vertical writing, that box height
        // becomes the column width, and `CTFramesetterCreateFrame` does clip: one point too narrow
        // and it returns zero columns, blanking the title entirely (measured threshold = exactly
        // the font size). Widen the layout path to what CoreText actually needs.
        //
        // The extra width is split evenly around the box instead of being taken off one side, so
        // an overflowing title stays centred on the box the designer shows — an off-centre title
        // reads as a positioning bug rather than as "this box is too narrow". A box that is
        // already wide enough is left completely alone (columns keep starting at its right edge),
        // and `rect` itself is never modified, so backgrounds and borders keep authored geometry.
        let frameAttributes = CoreTextPaginator.frameAttributes(for: writingMode)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            range,
            frameAttributes.isEmpty ? nil : frameAttributes as CFDictionary,
            CGSize(width: .greatestFiniteMagnitude, height: coreTextRect.height),
            nil
        )
        var layoutRect = coreTextRect
        if suggested.width.isFinite, suggested.width > layoutRect.width {
            layoutRect = layoutRect.insetBy(
                dx: -(suggested.width - layoutRect.width) / 2,
                dy: 0
            )
        }

        let frame = CoreTextPaginator.makeFrame(
            framesetter: framesetter,
            range: range,
            path: CGPath(rect: layoutRect, transform: nil),
            writingMode: writingMode
        )
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: canvasHeight)
        context.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private static func drawShadows(
        _ shadows: [ReaderStyleShadow],
        path: CGPath,
        context: CGContext
    ) {
        for shadow in shadows {
            context.saveGState()
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.setShadow(
                offset: CGSize(width: CGFloat(shadow.x), height: CGFloat(shadow.y)),
                blur: CGFloat(shadow.radius),
                color: color(shadow.colorHex).cgColor
            )
            context.setFillColor(UIColor.black.cgColor)
            context.addPath(path)
            context.fillPath()
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.setBlendMode(.destinationOut)
            context.addPath(path)
            context.fillPath()
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    private static func draw(
        _ gradient: ReaderStyleGradient,
        in rect: CGRect,
        context: CGContext
    ) {
        let sorted = gradient.stops.sorted { $0.location < $1.location }
        guard !sorted.isEmpty else { return }
        let stops = sorted.count == 1 ? [sorted[0], sorted[0]] : sorted
        guard let value = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: stops.map { color($0.colorHex).cgColor } as CFArray,
            locations: stops.map { CGFloat($0.location) }
        ) else { return }
        let angle = CGFloat(gradient.angleDegrees) * .pi / 180
        let direction = CGPoint(x: sin(angle), y: cos(angle))
        let length = abs(direction.x) * rect.width / 2
            + abs(direction.y) * rect.height / 2
        context.drawLinearGradient(
            value,
            start: CGPoint(
                x: rect.midX - direction.x * length,
                y: rect.midY - direction.y * length
            ),
            end: CGPoint(
                x: rect.midX + direction.x * length,
                y: rect.midY + direction.y * length
            ),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    private static func draw(
        _ image: UIImage,
        presentation: ReaderStyleImagePresentation,
        in rect: CGRect,
        context: CGContext
    ) {
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setAlpha(CGFloat(presentation.opacity))
        context.clip(to: rect)
        switch presentation.contentMode {
        case .tile:
            color(patternImage: image).setFill()
            context.fill(rect)
        case .fit, .fill, .stretch:
            let destination = RegexHighlightImageGeometry.destination(
                source: image.size,
                bounds: rect,
                mode: presentation.contentMode,
                focalX: CGFloat(presentation.focalX),
                focalY: CGFloat(presentation.focalY)
            )
            image.draw(in: destination)
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private static func drawBorders(
        _ borders: [ReaderStyleEdge: ReaderStyleBorder]?,
        rect: CGRect,
        radius: CGFloat,
        context: CGContext
    ) {
        guard let borders else { return }
        if let first = borders.first?.value,
           borders.count == ReaderStyleEdge.allCases.count,
           borders.values.allSatisfy({ $0 == first }),
           first.width > 0 {
            let width = CGFloat(first.width)
            context.setStrokeColor(color(first.colorHex).cgColor)
            context.setLineWidth(width)
            context.addPath(
                UIBezierPath(
                    roundedRect: rect.insetBy(dx: width / 2, dy: width / 2),
                    cornerRadius: max(0, radius - width / 2)
                ).cgPath
            )
            context.strokePath()
            return
        }

        for edge in ReaderStyleEdge.allCases {
            guard let border = borders[edge], border.width > 0 else { continue }
            let inset = CGFloat(border.width) / 2
            context.setStrokeColor(color(border.colorHex).cgColor)
            context.setLineWidth(CGFloat(border.width))
            switch edge {
            case .top:
                context.move(to: CGPoint(x: rect.minX, y: rect.minY + inset))
                context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + inset))
            case .leading:
                context.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
                context.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
            case .bottom:
                context.move(to: CGPoint(x: rect.minX, y: rect.maxY - inset))
                context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - inset))
            case .trailing:
                context.move(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
                context.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
            }
            context.strokePath()
        }
    }

    private static func color(_ hex: UInt32) -> UIColor {
        GlobalSettings.uiColor(rgbHex: hex)
    }

    private static func color(patternImage: UIImage) -> UIColor {
        UIColor(patternImage: patternImage)
    }
}
