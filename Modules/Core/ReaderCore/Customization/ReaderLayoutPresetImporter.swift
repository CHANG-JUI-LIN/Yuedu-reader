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
            return config.readerLayoutPreset
        } catch {
            throw ReaderLayoutPresetImportError.invalidReadConfig
        }
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

    var readerLayoutPreset: ReaderLayoutPreset {
        let baseFontSize = sanitized(textSize ?? 18, range: 12...32)
        let fontSizeForRatio = max(baseFontSize ?? 18, 1)
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
            scrollMode: pageAnim.map { $0 == 3 }
        )
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
