import SwiftUI
import UIKit

struct ReaderOverlayResolvedStyle: Equatable {
    var font: UIFont
    var color: UIColor
    var opacity: Double
}

struct ReaderOverlayReaderStyle: Equatable {
    var font: UIFont
    var textColor: UIColor
    var availablePostScriptNames: Set<String>

    init(
        font: UIFont,
        textColor: UIColor,
        availablePostScriptNames: Set<String>
    ) {
        self.font = font
        self.textColor = textColor
        self.availablePostScriptNames = availablePostScriptNames
    }
}

enum ReaderOverlayResolvedContent: Equatable, Sendable {
    case text(String)
    case progress(value: Double)
    case systemBattery(iconName: String, percentage: String?)
    case importedBattery(assetID: UUID, percentage: String?)
}

struct ReaderOverlayResolvedPresentation: Equatable, Sendable {
    var content: ReaderOverlayResolvedContent
    var accessibilityLabel: String
    var accessibilityValue: String
}

enum ReaderOverlayPresentationResolver {
    static func resolveStyle(
        _ style: ReaderOverlayComponentStyle,
        readerFont: UIFont,
        readerTextColor: UIColor,
        availablePostScriptNames: Set<String>
    ) -> ReaderOverlayResolvedStyle {
        let normalized = style.normalized
        let size = CGFloat(normalized.fontSize)
        let weight = uiFontWeight(normalized.fontWeight)
        let systemFallback = UIFont.systemFont(ofSize: size, weight: weight)

        let resolvedFont: UIFont
        switch normalized.font.kind {
        case .system:
            resolvedFont = systemFallback
        case .reader:
            let resized = UIFont(descriptor: readerFont.fontDescriptor, size: size)
            resolvedFont = font(resized, applying: normalized.fontWeight, size: size)
        case .imported:
            guard let postScriptName = normalized.font.postScriptName,
                  availablePostScriptNames.contains(postScriptName),
                  let imported = UIFont(name: postScriptName, size: size) else {
                resolvedFont = systemFallback
                break
            }
            resolvedFont = font(imported, applying: normalized.fontWeight, size: size)
        }

        let resolvedColor: UIColor
        switch normalized.color.source {
        case .readerText:
            resolvedColor = readerTextColor
        case .custom:
            resolvedColor = normalized.color.hexRGBA.map(color(hexRGBA:)) ?? readerTextColor
        }

        return ReaderOverlayResolvedStyle(
            font: resolvedFont,
            color: resolvedColor,
            opacity: normalized.opacity
        )
    }

    static func resolve(
        component: ReaderOverlayComponent,
        snapshot: ReaderOverlayContentSnapshot,
        availableSVGAssetIDs: Set<UUID> = [],
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent
    ) -> ReaderOverlayResolvedPresentation {
        let configuration = component.configuration.normalized
        let label = accessibilityLabel(for: component.kind)
        let formattedValue = snapshot.text(
            for: component.kind,
            format: configuration.displayFormat,
            locale: locale,
            calendar: calendar
        )

        let content: ReaderOverlayResolvedContent
        let accessibilityValue: String
        switch component.kind {
        case .progressBar:
            let progress = normalizedProgress(snapshot.totalProgress)
            content = .progress(value: progress)
            accessibilityValue = formattedValue
        case .battery:
            let battery = ReaderBatteryValueResolver.resolve(
                rawLevel: snapshot.batteryLevel ?? -1,
                isCharging: snapshot.isCharging
            )
            let percentage = configuration.showsBatteryPercentage ? formattedValue : nil
            if configuration.batteryVisual == .importedSVG,
               let assetID = configuration.svgAssetID,
               availableSVGAssetIDs.contains(assetID) {
                content = .importedBattery(assetID: assetID, percentage: percentage)
            } else {
                content = .systemBattery(iconName: battery.iconName, percentage: percentage)
            }
            accessibilityValue = formattedValue
        case .customText:
            content = .text(configuration.customText)
            accessibilityValue = configuration.customText
        case .bookTitle, .chapterTitle, .chapterPage, .totalProgressText,
             .currentTime, .currentDate, .weekday, .readingDuration, .remainingTime:
            content = .text(formattedValue)
            accessibilityValue = formattedValue
        }

        return ReaderOverlayResolvedPresentation(
            content: content,
            accessibilityLabel: label,
            accessibilityValue: accessibilityValue
        )
    }

    static func rgbaHex(
        _ color: UIColor,
        userInterfaceStyle: UIUserInterfaceStyle
    ) -> String? {
        let resolved = color.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: userInterfaceStyle)
        )
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        return String(
            format: "#%02X%02X%02X%02X",
            byte(red),
            byte(green),
            byte(blue),
            byte(alpha)
        )
    }

    private static func accessibilityLabel(for kind: ReaderOverlayComponentKind) -> String {
        switch kind {
        case .bookTitle: localized("書名")
        case .chapterTitle: localized("章節名")
        case .chapterPage: localized("本章頁碼")
        case .totalProgressText, .progressBar: localized("總進度")
        case .currentTime: localized("目前時間")
        case .currentDate: localized("目前日期")
        case .weekday: localized("星期")
        case .battery: localized("電量")
        case .readingDuration: localized("本次閱讀時長")
        case .remainingTime: localized("預估剩餘時間")
        case .customText: localized("自訂文字")
        }
    }

    private static func normalizedProgress(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private static func color(hexRGBA value: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((value >> 24) & 0xFF) / 255,
            green: CGFloat((value >> 16) & 0xFF) / 255,
            blue: CGFloat((value >> 8) & 0xFF) / 255,
            alpha: CGFloat(value & 0xFF) / 255
        )
    }

    private static func uiFontWeight(_ value: ReaderOverlayFontWeight) -> UIFont.Weight {
        switch value {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }

    private static func font(
        _ source: UIFont,
        applying weight: ReaderOverlayFontWeight,
        size: CGFloat
    ) -> UIFont {
        var traits = source.fontDescriptor.symbolicTraits
        traits.remove(.traitBold)
        let unboldedDescriptor = source.fontDescriptor.withSymbolicTraits(traits)
            ?? source.fontDescriptor
        let base = UIFont(descriptor: unboldedDescriptor, size: size)

        if weight == .bold {
            var boldTraits = base.fontDescriptor.symbolicTraits
            boldTraits.insert(.traitBold)
            if let descriptor = base.fontDescriptor.withSymbolicTraits(boldTraits) {
                return UIFont(descriptor: descriptor, size: size)
            }
        }

        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: uiFontWeight(weight)]
        ])
        return UIFont(descriptor: descriptor, size: size)
    }

    private static func byte(_ value: CGFloat) -> Int {
        Int((min(max(value, 0), 1) * 255).rounded())
    }
}

struct ReaderOverlayComponentView: View {
    let component: ReaderOverlayComponent
    let content: ReaderOverlayContentSnapshot
    let readerStyle: ReaderOverlayReaderStyle
    let isEditing: Bool
    let isSelected: Bool
    let svgAssetStore: ReaderOverlaySVGAssetStore

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var loadedBattery: LoadedBattery?

    private var frameAlignment: Alignment {
        switch ReaderOverlayHorizontalAnchor.resolve(forNormalizedX: component.position.x) {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private var resolvedStyle: ReaderOverlayResolvedStyle {
        ReaderOverlayPresentationResolver.resolveStyle(
            component.style,
            readerFont: readerStyle.font,
            readerTextColor: readerStyle.textColor,
            availablePostScriptNames: readerStyle.availablePostScriptNames
        )
    }

    private var presentation: ReaderOverlayResolvedPresentation {
        ReaderOverlayPresentationResolver.resolve(
            component: component,
            snapshot: content,
            availableSVGAssetIDs: loadedBattery?.key == batteryRenderKey
                ? Set([loadedBattery?.key.assetID].compactMap { $0 })
                : []
        )
    }

    var body: some View {
        renderedContent
            .foregroundStyle(Color(uiColor: resolvedStyle.color))
            .opacity(resolvedStyle.opacity)
            // Runtime and editor must use identical layout geometry. The invisible 44pt frame
            // keeps edge clamping stable; only interaction and selection chrome vary by mode.
            .padding(DSSpacing.xs)
            .frame(
                minWidth: DSLayout.readerOverlayEditorMinimumHitSize,
                minHeight: DSLayout.readerOverlayEditorMinimumHitSize,
                alignment: frameAlignment
            )
            .contentShape(Rectangle())
            .overlay {
                if isEditing && isSelected {
                    RoundedRectangle(cornerRadius: DSRadius.sm)
                        .strokeBorder(
                            DSColor.accent,
                            lineWidth: DSLayout.readerOverlaySelectionLineWidth
                        )
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityValue(presentation.accessibilityValue)
            .accessibilityAddTraits(isEditing && isSelected ? .isSelected : [])
            .task(id: batteryRenderKey) {
                await loadImportedBattery()
            }
    }

    @ViewBuilder
    private var renderedContent: some View {
        switch presentation.content {
        case .text(let value):
            Text(value)
                .font(Font(resolvedStyle.font))
                .lineLimit(1)
        case .progress(let value):
            ProgressView(value: value)
                .progressViewStyle(.linear)
                .tint(Color(uiColor: resolvedStyle.color))
                .frame(width: progressWidth)
        case .systemBattery(let iconName, let percentage):
            batteryLabel(image: Image(systemName: iconName), percentage: percentage)
        case .importedBattery(_, let percentage):
            if let loadedBattery,
               loadedBattery.key == batteryRenderKey {
                batteryLabel(image: Image(uiImage: loadedBattery.image), percentage: percentage)
            } else {
                let fallback = ReaderBatteryValueResolver.resolve(
                    rawLevel: content.batteryLevel ?? -1,
                    isCharging: content.isCharging
                )
                batteryLabel(image: Image(systemName: fallback.iconName), percentage: percentage)
            }
        }
    }

    private func batteryLabel(image: Image, percentage: String?) -> some View {
        HStack(spacing: DSSpacing.xs) {
            image
                .resizable()
                .scaledToFit()
                .frame(width: batterySize.width, height: batterySize.height)
                .accessibilityHidden(true)
            if let percentage {
                Text(percentage)
                    .font(Font(resolvedStyle.font))
                    .lineLimit(1)
            }
        }
    }

    private var progressWidth: CGFloat {
        min(
            max(
                DSLayout.readerOverlayProgressMinimumWidth,
                resolvedStyle.font.lineHeight * DSLayout.readerOverlayProgressWidthScale
            ),
            DSLayout.readerOverlayProgressMaximumWidth
        )
    }

    private var batterySize: CGSize {
        let height = resolvedStyle.font.lineHeight
        return CGSize(
            width: height * DSLayout.readerOverlayBatteryAspectRatio,
            height: height
        )
    }

    private var batteryRenderKey: BatteryRenderKey? {
        guard component.kind == .battery,
              component.configuration.batteryVisual == .importedSVG,
              let assetID = component.configuration.svgAssetID,
              let colorHex = ReaderOverlayPresentationResolver.rgbaHex(
                resolvedStyle.color,
                userInterfaceStyle: colorScheme == .dark ? .dark : .light
              ),
              displayScale.isFinite,
              displayScale >= 0.5,
              displayScale <= 4 else {
            return nil
        }
        let level = ReaderBatteryValueResolver.resolve(
            rawLevel: content.batteryLevel ?? -1,
            isCharging: content.isCharging
        ).level ?? 0
        let pixelSize = CGSize(
            width: batterySize.width * displayScale,
            height: batterySize.height * displayScale
        )
        guard pixelSize.width.isFinite,
              pixelSize.height.isFinite,
              pixelSize.width > 0,
              pixelSize.height > 0,
              pixelSize.width <= CGFloat(Int.max),
              pixelSize.height <= CGFloat(Int.max) else {
            return nil
        }
        return BatteryRenderKey(
            assetID: assetID,
            levelBucket: Int((level * 100).rounded()),
            isCharging: content.isCharging,
            colorHex: colorHex,
            pixelWidth: Int(pixelSize.width.rounded()),
            pixelHeight: Int(pixelSize.height.rounded()),
            displayScaleBits: Double(displayScale).bitPattern
        )
    }

    @MainActor
    private func loadImportedBattery() async {
        loadedBattery = nil
        guard let key = batteryRenderKey else { return }

        do {
            let resolution = try await svgAssetStore.resolveTemplate(for: key.assetID)
            try Task.checkCancellation()
            guard case .template(let template) = resolution else { return }
            let image = try await SVGWebViewRasterizer.shared.renderBattery(
                template: template,
                level: Double(key.levelBucket) / 100,
                isCharging: key.isCharging,
                colorHex: key.colorHex,
                pixelSize: CGSize(width: key.pixelWidth, height: key.pixelHeight),
                displayScale: CGFloat(Double(bitPattern: key.displayScaleBits))
            )
            try Task.checkCancellation()
            guard let image, key == batteryRenderKey else { return }
            loadedBattery = LoadedBattery(key: key, image: image)
        } catch is CancellationError {
            return
        } catch {
            // Missing, corrupt, or unrenderable templates deliberately use the system battery.
        }
    }
}

private struct LoadedBattery {
    let key: BatteryRenderKey
    let image: UIImage
}

private struct BatteryRenderKey: Hashable {
    let assetID: UUID
    let levelBucket: Int
    let isCharging: Bool
    let colorHex: String
    let pixelWidth: Int
    let pixelHeight: Int
    let displayScaleBits: UInt64
}
