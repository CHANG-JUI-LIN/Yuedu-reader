import Foundation
import CoreGraphics
import ReadiumZIPFoundation

struct ReaderLayoutPreset {
    let name: String?
    let fontSize: CGFloat?
    let isBold: Bool?
    let lineHeightMultiple: CGFloat?
    let letterSpacing: CGFloat?
    let paragraphSpacingMultiplier: CGFloat?
    let pageMarginH: CGFloat?
    let pageMarginV: CGFloat?
    let footerBottomPadding: CGFloat?
    let footerTextGap: CGFloat?
    let titleVisible: Bool?
    let titleSize: CGFloat?
    let titleTopSpacing: CGFloat?
    let titleBottomSpacing: CGFloat?
    let pageTurnStyle: PageTurnStyle?
    let scrollMode: Bool?
    let readerOverlayLayout: ReaderOverlayLayout?
}

enum ReaderLayoutPresetImportError: LocalizedError {
    case unsupportedFile
    case cannotReadFile
    case missingReadConfig
    case invalidReadConfig

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            return localized("不支援的排版檔案格式")
        case .cannotReadFile:
            return localized("無法讀取排版檔案")
        case .missingReadConfig:
            return localized("壓縮檔中未找到 readConfig.json")
        case .invalidReadConfig:
            return localized("排版參數格式不正確")
        }
    }
}

enum ReaderLayoutPresetImporter {
    static func importPreset(from url: URL) async throws -> ReaderLayoutPreset {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "json":
            do {
                return try decode(data: Data(contentsOf: url))
            } catch let error as ReaderLayoutPresetImportError {
                throw error
            } catch {
                throw ReaderLayoutPresetImportError.cannotReadFile
            }
        case "zip":
            let data = try await readConfigData(in: url)
            return try decode(data: data)
        default:
            throw ReaderLayoutPresetImportError.unsupportedFile
        }
    }

    static func decode(data: Data) throws -> ReaderLayoutPreset {
        do {
            let config = try JSONDecoder().decode(LegadoReadConfig.self, from: data)
            let overlayLayout = validOverlayLayout(in: data) ?? config.migratedLegacyOverlayLayout
            return config.readerLayoutPreset(overlayLayout: overlayLayout)
        } catch {
            throw ReaderLayoutPresetImportError.invalidReadConfig
        }
    }

    private static func validOverlayLayout(in data: Data) -> ReaderOverlayLayout? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["readerOverlayLayout"] as? [String: Any],
              let rawVersion = payload["version"] as? Int,
              payload["components"] is [Any],
              rawVersion < 2 || payload["chapterOpeningComponents"] is [Any],
              payload["contentReservations"] is [String: Any],
              JSONSerialization.isValidJSONObject(payload),
              let payloadData = try? JSONSerialization.data(withJSONObject: payload),
              let layout = try? JSONDecoder().decode(ReaderOverlayLayout.self, from: payloadData),
              layout.version == rawVersion,
              (0...ReaderOverlayLayout.currentVersion).contains(layout.version),
              Set(layout.components.map(\.id)).count == layout.components.count else {
            return nil
        }
        return ReaderOverlayLayoutMigration.upgrade(layout)
    }

    private static func readConfigData(in archiveURL: URL) async throws -> Data {
        let archive: Archive
        do {
            archive = try await Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw ReaderLayoutPresetImportError.cannotReadFile
        }

        let entries = (try? await archive.entries()) ?? []
        guard let entry = entries.first(where: { ($0.path as NSString).lastPathComponent == "readConfig.json" })
            ?? entries.first(where: { ($0.path as NSString).pathExtension.lowercased() == "json" })
        else {
            throw ReaderLayoutPresetImportError.missingReadConfig
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-layout-\(UUID().uuidString)", isDirectory: true)
        let outputURL = directory.appendingPathComponent("readConfig.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            _ = try await archive.extract(entry, to: outputURL, skipCRC32: true)
            return try Data(contentsOf: outputURL)
        } catch {
            throw ReaderLayoutPresetImportError.cannotReadFile
        }
    }
}

private struct LegadoReadConfig: Decodable {
    let name: String?
    let textSize: CGFloat?
    let textBold: Int?
    let lineSpacingExtra: CGFloat?
    let letterSpacing: CGFloat?
    let paragraphSpacing: CGFloat?
    let paddingLeft: CGFloat?
    let paddingRight: CGFloat?
    let paddingTop: CGFloat?
    let paddingBottom: CGFloat?
    let footerPaddingBottom: CGFloat?
    let footerPaddingTop: CGFloat?
    let headerMode: Int?
    let titleSize: CGFloat?
    let titleTopSpacing: CGFloat?
    let titleBottomSpacing: CGFloat?
    let pageAnim: Int?

    // Yuedu's fixed header/footer schema, retained for importing older presets.
    let readerHeaderVisible: Bool?
    let readerFooterVisible: Bool?
    let readerHeaderFieldPositions: [String: String]?
    let readerHeaderTopPadding: CGFloat?
    let readerHeaderTextGap: CGFloat?
    let readerHeaderHorizontalPadding: CGFloat?
    let footerBottomPadding: CGFloat?
    let footerTextGap: CGFloat?
    let readerFooterHorizontalPadding: CGFloat?
    let topContentReservation: CGFloat?
    let bottomContentReservation: CGFloat?

    func readerLayoutPreset(overlayLayout: ReaderOverlayLayout?) -> ReaderLayoutPreset {
        let baseFontSize = sanitized(textSize ?? 18, range: 12...32)
        let fontSizeForRatio = max(baseFontSize, 1)
        let lineHeight = lineSpacingExtra.map { value in
            sanitized(1 + max(0, value) / fontSizeForRatio, range: 1.0...2.4)
        }
        let paragraph = paragraphSpacing.map { value in
            sanitized(max(0, value) / fontSizeForRatio, range: 0.3...1.2)
        }
        let horizontalInset = average(paddingLeft, paddingRight).map {
            sanitized($0, range: 8...48)
        }
        let verticalInset = average(paddingTop, paddingBottom).map {
            sanitized($0, range: 0...48)
        }
        let footerBottom = footerPaddingBottom.map {
            sanitized($0, range: 0...36)
        }
        let footerGap = footerPaddingTop.map {
            sanitized($0, range: 0...48)
        }
        let importedTitleSize = (titleSize ?? 0) > 0 ? titleSize : nil

        return ReaderLayoutPreset(
            name: name,
            fontSize: baseFontSize,
            isBold: textBold.map { $0 != 0 },
            lineHeightMultiple: lineHeight,
            letterSpacing: letterSpacing.map { sanitized($0, range: 0...12) },
            paragraphSpacingMultiplier: paragraph,
            pageMarginH: horizontalInset,
            pageMarginV: verticalInset,
            footerBottomPadding: footerBottom,
            footerTextGap: footerGap,
            titleVisible: headerMode.map { $0 != 0 },
            titleSize: importedTitleSize.map { sanitized($0, range: 10...24) },
            titleTopSpacing: titleTopSpacing.map { sanitized($0, range: 0...28) },
            titleBottomSpacing: titleBottomSpacing.map { sanitized($0, range: 0...28) },
            pageTurnStyle: pageTurnStyle(from: pageAnim),
            scrollMode: pageAnim.map { $0 == 3 },
            readerOverlayLayout: overlayLayout
        )
    }

    var migratedLegacyOverlayLayout: ReaderOverlayLayout? {
        guard containsLegacyOverlayFields else { return nil }

        let headerVisible = readerHeaderVisible ?? headerMode.map { $0 != 0 } ?? true
        let footerVisible = readerFooterVisible ?? true
        let headerTopPadding = Double(readerHeaderTopPadding ?? ReaderLayoutMetrics.defaultHeaderTopPadding)
        let headerTextGap = Double(readerHeaderTextGap ?? ReaderLayoutMetrics.defaultHeaderTextGap)
        let footerBottomPadding = Double(
            self.footerBottomPadding
                ?? self.footerPaddingBottom
                ?? ReaderLayoutMetrics.defaultFooterBottomPadding
        )
        let footerTextGap = Double(
            self.footerTextGap
                ?? footerPaddingTop
                ?? ReaderLayoutMetrics.defaultFooterTextGap
        )
        let topReservation = topContentReservation.map(Double.init) ?? Double(
            ReaderLayoutMetrics.topInset(
                safeTop: 0,
                headerVisible: headerVisible,
                headerTopPadding: CGFloat(headerTopPadding),
                headerTextGap: CGFloat(headerTextGap)
            )
        )
        let bottomReservation = bottomContentReservation.map(Double.init) ?? Double(
            ReaderLayoutMetrics.bottomInset(
                safeBottom: 0,
                footerVisible: footerVisible,
                footerBottomPadding: CGFloat(footerBottomPadding),
                footerTextGap: CGFloat(footerTextGap)
            )
        )

        return ReaderOverlayLayoutMigration.migrate(
            ReaderLegacyOverlaySettings(
                headerVisible: headerVisible,
                footerVisible: footerVisible,
                headerFieldPositions: readerHeaderFieldPositions ?? ["chapterTitle": "left"],
                headerTopPadding: headerTopPadding,
                headerHorizontalPadding: Double(
                    readerHeaderHorizontalPadding ?? ReaderLayoutMetrics.defaultHeaderHorizontalPadding
                ),
                footerBottomPadding: footerBottomPadding,
                footerHorizontalPadding: Double(
                    readerFooterHorizontalPadding ?? ReaderLayoutMetrics.defaultFooterHorizontalPadding
                ),
                topContentReservation: topReservation,
                bottomContentReservation: bottomReservation
            )
        )
    }

    private var containsLegacyOverlayFields: Bool {
        readerHeaderVisible != nil
            || readerFooterVisible != nil
            || readerHeaderFieldPositions != nil
            || readerHeaderTopPadding != nil
            || readerHeaderTextGap != nil
            || readerHeaderHorizontalPadding != nil
            || footerBottomPadding != nil
            || footerTextGap != nil
            || footerPaddingBottom != nil
            || footerPaddingTop != nil
            || readerFooterHorizontalPadding != nil
            || topContentReservation != nil
            || bottomContentReservation != nil
    }

    private func pageTurnStyle(from value: Int?) -> PageTurnStyle? {
        guard let value else { return nil }
        switch value {
        case 0: return .slide
        case 1: return .cover
        case 2: return .curl
        default: return nil
        }
    }

    private func average(_ left: CGFloat?, _ right: CGFloat?) -> CGFloat? {
        switch (left, right) {
        case let (left?, right?): return (left + right) / 2
        case let (left?, nil): return left
        case let (nil, right?): return right
        default: return nil
        }
    }

    private func sanitized(_ value: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
