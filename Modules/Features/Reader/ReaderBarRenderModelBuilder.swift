import SwiftUI
import UIKit

/// Turns a `ReaderBarLayout` plus a content snapshot into something
/// `ReaderBarRenderer` can draw.
///
/// Everything that needs the main actor happens here — the presentation resolver,
/// the SVG asset store, symbol rasterization — so that the model handed to
/// `CoreTextPageView.renderPage` is inert and can be drawn on the snapshot thread.
///
/// Owns the image cache because imported batteries rasterize asynchronously. A
/// field whose template has not landed yet resolves to the system symbol rather
/// than a gap, exactly as the SwiftUI bar did, and `onAssetLoaded` asks the reader
/// to redraw once the real one arrives.
@MainActor
final class ReaderBarRenderModelBuilder {

    /// Fired when an imported battery finishes rasterizing, so pages that drew the
    /// system fallback can be redrawn. Set by `ReaderView`.
    var onAssetLoaded: (() -> Void)?

    private struct ImportedKey: Hashable {
        let assetID: UUID
        let levelBucket: Int
        let isCharging: Bool
        let colorHex: String
        let pixelWidth: Int
        let pixelHeight: Int
    }

    private struct SymbolKey: Hashable {
        let name: String
        let pointSize: CGFloat
        let colorHex: String
    }

    private var importedBatteries: [ImportedKey: UIImage] = [:]
    private var inFlightImports: Set<ImportedKey> = []
    private var symbols: [SymbolKey: UIImage] = [:]

    // MARK: - Building

    func model(
        for bar: ReaderBar,
        layout: ReaderBarLayout,
        content: ReaderOverlayContentSnapshot,
        readerTextColor: UIColor,
        horizontalPadding: CGFloat,
        svgAssetStore: ReaderOverlaySVGAssetStore?,
        userInterfaceStyle: UIUserInterfaceStyle,
        displayScale: CGFloat
    ) -> ReaderBarRenderModel {
        let style = ReaderBarStyleResolver.resolve(layout.style, readerTextColor: readerTextColor)
        let colorHex = ReaderOverlayPresentationResolver.rgbaHex(
            style.color,
            userInterfaceStyle: userInterfaceStyle
        ) ?? "#000000FF"

        let barSlots = ReaderBarSlot.slots(in: bar)
        let slots = barSlots.map { slot in
            layout.fields(in: slot).compactMap { field in
                self.field(
                    field,
                    content: content,
                    style: style,
                    colorHex: colorHex,
                    svgAssetStore: svgAssetStore,
                    displayScale: displayScale
                )
            }
        }

        return ReaderBarRenderModel(
            bar: bar,
            slots: slots,
            font: style.font,
            color: style.color,
            opacity: style.opacity,
            horizontalPadding: horizontalPadding,
            showsDivider: bar == .header ? layout.showsHeaderDivider : layout.showsFooterDivider,
            accessibilityValue: Self.accessibilityValue(
                slots: barSlots,
                layout: layout,
                content: content
            )
        )
    }

    /// Reads the bar the way it looks: slot order, then field order within a slot.
    private static func accessibilityValue(
        slots: [ReaderBarSlot],
        layout: ReaderBarLayout,
        content: ReaderOverlayContentSnapshot
    ) -> String {
        slots
            .flatMap { layout.fields(in: $0) }
            .compactMap { field in
                let presentation = ReaderOverlayPresentationResolver.resolve(
                    kind: field.kind,
                    configuration: field.configuration,
                    snapshot: content
                )
                guard !presentation.accessibilityValue.isEmpty else { return nil }
                return "\(presentation.accessibilityLabel) \(presentation.accessibilityValue)"
            }
            .joined(separator: localized("、"))
    }

    /// A field that resolves to empty text is dropped rather than drawn, so a book
    /// with no title or a chapter with no name does not leave a separator dot
    /// hanging with nothing on one side of it.
    private func field(
        _ field: ReaderBarField,
        content: ReaderOverlayContentSnapshot,
        style: ReaderOverlayResolvedStyle,
        colorHex: String,
        svgAssetStore: ReaderOverlaySVGAssetStore?,
        displayScale: CGFloat
    ) -> ReaderBarRenderModel.Field? {
        let importedKey = importedBatteryKey(
            for: field,
            content: content,
            style: style,
            colorHex: colorHex,
            displayScale: displayScale
        )
        if let importedKey, importedBatteries[importedKey] == nil {
            requestImportedBattery(importedKey, svgAssetStore: svgAssetStore, style: style)
        }

        let available: Set<UUID> = importedKey.flatMap {
            importedBatteries[$0] != nil ? Set([$0.assetID]) : nil
        } ?? []

        let presentation = ReaderOverlayPresentationResolver.resolve(
            kind: field.kind,
            configuration: field.configuration,
            snapshot: content,
            availableSVGAssetIDs: available
        )

        switch presentation.content {
        case .text(let value):
            return value.isEmpty ? nil : .text(value)
        case .progress(let value):
            return .progress(value)
        case .systemBattery(let iconName, let percentage):
            guard let image = symbol(named: iconName, style: style, colorHex: colorHex) else { return nil }
            return .image(image, percentage: percentage)
        case .importedBattery(_, let percentage):
            guard let importedKey, let image = importedBatteries[importedKey] else { return nil }
            return .image(image, percentage: percentage)
        }
    }

    // MARK: - Battery images

    private func importedBatteryKey(
        for field: ReaderBarField,
        content: ReaderOverlayContentSnapshot,
        style: ReaderOverlayResolvedStyle,
        colorHex: String,
        displayScale: CGFloat
    ) -> ImportedKey? {
        guard field.kind == .battery,
              field.configuration.normalized.batteryVisual == .importedSVG,
              let assetID = field.configuration.normalized.svgAssetID,
              displayScale.isFinite, displayScale >= 0.5, displayScale <= 4
        else {
            return nil
        }

        let level = ReaderBatteryValueResolver.resolve(
            rawLevel: content.batteryLevel ?? -1,
            isCharging: content.isCharging
        ).level ?? 0
        let size = ReaderBarRenderer.imageSize(font: style.font)
        let pixels = CGSize(width: size.width * displayScale, height: size.height * displayScale)
        guard pixels.width.isFinite, pixels.height.isFinite,
              pixels.width > 0, pixels.height > 0,
              pixels.width <= 4096, pixels.height <= 4096
        else {
            return nil
        }

        return ImportedKey(
            assetID: assetID,
            levelBucket: Int((level * 100).rounded()),
            isCharging: content.isCharging,
            colorHex: colorHex,
            pixelWidth: Int(pixels.width.rounded()),
            pixelHeight: Int(pixels.height.rounded())
        )
    }

    private func requestImportedBattery(
        _ key: ImportedKey,
        svgAssetStore: ReaderOverlaySVGAssetStore?,
        style: ReaderOverlayResolvedStyle
    ) {
        guard let svgAssetStore, !inFlightImports.contains(key) else { return }
        inFlightImports.insert(key)
        Task { @MainActor [weak self] in
            defer { self?.inFlightImports.remove(key) }
            do {
                let resolution = try await svgAssetStore.resolveTemplate(for: key.assetID)
                guard case .template(let template) = resolution else { return }
                let image = try await SVGWebViewRasterizer.shared.renderBattery(
                    template: template,
                    level: Double(key.levelBucket) / 100,
                    isCharging: key.isCharging,
                    colorHex: key.colorHex,
                    pixelSize: CGSize(width: key.pixelWidth, height: key.pixelHeight),
                    displayScale: CGFloat(key.pixelWidth) / max(1, ReaderBarRenderer.imageSize(font: style.font).width)
                )
                guard let image, let self else { return }
                self.importedBatteries[key] = image
                self.onAssetLoaded?()
            } catch {
                // Missing, corrupt or unrenderable templates deliberately keep the
                // system battery. An unreadable asset must not blank the bar.
            }
        }
    }

    private func symbol(named name: String, style: ReaderOverlayResolvedStyle, colorHex: String) -> UIImage? {
        let key = SymbolKey(name: name, pointSize: style.font.pointSize, colorHex: colorHex)
        if let cached = symbols[key] { return cached }
        let configuration = UIImage.SymbolConfiguration(pointSize: style.font.pointSize)
        guard let image = UIImage(systemName: name, withConfiguration: configuration) else { return nil }
        // Baked to `.alwaysOriginal` because the drawing side is a bare CGContext
        // with no tint colour of its own.
        let tinted = image.withTintColor(style.color, renderingMode: .alwaysOriginal)
        symbols[key] = tinted
        return tinted
    }

    /// Colour and font changes invalidate every cached image.
    func invalidate() {
        importedBatteries.removeAll()
        symbols.removeAll()
    }
}
