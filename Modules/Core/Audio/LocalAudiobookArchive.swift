import AVFoundation
import Foundation
import ReadiumZIPFoundation

struct LocalAudiobookChapterSeed: Equatable {
    let title: String
    let audioStartSeconds: Double?
    let audioDurationSeconds: Double?
}

struct LocalAudiobookImportInfo {
    let title: String
    let author: String
    let chapterSeeds: [LocalAudiobookChapterSeed]
    let totalDurationSeconds: Double?
    let coverImageData: Data?
    let isArchive: Bool

    var chapterCount: Int { chapterSeeds.count }
}

struct LocalAudiobookExtractedChapter: Equatable {
    let title: String
    let filename: String
}

enum LocalAudiobookArchiveError: LocalizedError {
    case invalidFileType
    case cannotReadArchive
    case noAudioFound
    case extractionFailed

    var errorDescription: String? {
        switch self {
        case .invalidFileType:
            return localized("不支援的音訊格式")
        case .cannotReadArchive:
            return localized("無法讀取音訊壓縮檔")
        case .noAudioFound:
            return localized("壓縮檔中未找到音訊檔案")
        case .extractionFailed:
            return localized("音訊解壓失敗")
        }
    }
}

enum LocalAudiobookArchive {
    static let allowedAudioExtensions = Set(["mp3", "m4a", "m4b", "aac", "flac", "wav"])
    private static let allowedArchiveExtensions = Set(["zip"])
    private static let allowedCoverImageExtensions = Set(["jpg", "jpeg", "png", "webp", "heic"])

    static func supports(_ url: URL) -> Bool {
        allowedAudioExtensions.contains(url.pathExtension.lowercased())
    }

    static func zipContainsAudio(_ url: URL) async -> Bool {
        guard allowedArchiveExtensions.contains(url.pathExtension.lowercased()),
              let paths = try? await audioEntryPaths(in: url)
        else { return false }
        return !paths.isEmpty
    }

    static func inspect(url: URL) async throws -> LocalAudiobookImportInfo {
        if allowedArchiveExtensions.contains(url.pathExtension.lowercased()) {
            return try await inspectZip(url: url)
        }
        return try await inspectSingleFile(url: url)
    }

    static func inspectSingleFile(url: URL) async throws -> LocalAudiobookImportInfo {
        guard supports(url) else { throw LocalAudiobookArchiveError.invalidFileType }

        let asset = AVURLAsset(url: url)
        let durationTime = try await asset.load(.duration)
        let totalDuration = finiteSeconds(durationTime)
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        let fallbackTitle = cleanChapterTitle(url.deletingPathExtension().lastPathComponent)
        let title = firstNonEmpty(
            stringValue(in: metadata, commonKey: .commonKeyTitle),
            fallbackTitle
        )
        let author = firstNonEmpty(
            stringValue(in: metadata, commonKey: .commonKeyArtist),
            localized("未知作者")
        )
        let groups = try await chapterMetadataGroups(for: asset)
        let seeds = chapterSeeds(
            fromGroups: groups,
            totalDurationSeconds: totalDuration,
            fallbackTitle: title
        )

        return LocalAudiobookImportInfo(
            title: title,
            author: author,
            chapterSeeds: seeds,
            totalDurationSeconds: totalDuration,
            coverImageData: artworkData(in: metadata),
            isArchive: false
        )
    }

    static func inspectZip(url: URL) async throws -> LocalAudiobookImportInfo {
        let archive = try await openArchive(url)
        let entries = try await namedEntries(in: archive, archiveURL: url)
        let audio = audioEntries(entries)
        guard let firstAudio = audio.first else { throw LocalAudiobookArchiveError.noAudioFound }

        let coverData: Data?
        if let imageData = await coverImageData(in: archive, entries: entries) {
            coverData = imageData
        } else {
            coverData = await artworkData(of: firstAudio, in: archive)
        }
        let fallbackTitle = cleanChapterTitle(url.deletingPathExtension().lastPathComponent)
        let seeds = audio.map { item in
            LocalAudiobookChapterSeed(
                title: chapterTitle(forEntryPath: item.path),
                audioStartSeconds: nil,
                audioDurationSeconds: nil
            )
        }

        return LocalAudiobookImportInfo(
            title: fallbackTitle,
            author: localized("未知作者"),
            chapterSeeds: seeds,
            totalDurationSeconds: nil,
            coverImageData: coverData,
            isArchive: true
        )
    }

    static func extractAudioEntries(from archiveURL: URL, to directory: URL) async throws -> [LocalAudiobookExtractedChapter] {
        let archive = try await openArchive(archiveURL)
        let audio = audioEntries(try await namedEntries(in: archive, archiveURL: archiveURL))
        guard !audio.isEmpty else { throw LocalAudiobookArchiveError.noAudioFound }

        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw LocalAudiobookArchiveError.extractionFailed
        }

        var extracted: [LocalAudiobookExtractedChapter] = []
        for (index, item) in audio.enumerated() {
            let ext = (item.path as NSString).pathExtension.lowercased()
            let filename = String(format: "%03d.%@", index, ext)
            let outputURL = directory.appendingPathComponent(filename)
            do {
                _ = try await archive.extract(item.entry, to: outputURL, skipCRC32: true)
            } catch {
                throw LocalAudiobookArchiveError.extractionFailed
            }
            extracted.append(
                LocalAudiobookExtractedChapter(
                    title: chapterTitle(forEntryPath: item.path),
                    filename: filename
                )
            )
        }
        return extracted
    }

    /// The archive's audio files by their decoded names, in natural order.
    static func audioEntryPaths(in archiveURL: URL) async throws -> [String] {
        let archive = try await openArchive(archiveURL)
        return audioEntries(try await namedEntries(in: archive, archiveURL: archiveURL)).map(\.path)
    }

    private static func openArchive(_ archiveURL: URL) async throws -> Archive {
        guard allowedArchiveExtensions.contains(archiveURL.pathExtension.lowercased()) else {
            throw LocalAudiobookArchiveError.invalidFileType
        }
        do {
            return try await Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw LocalAudiobookArchiveError.cannotReadArchive
        }
    }

    /// Every entry with its name decoded as the archive was written (see `ZipEntryNames`).
    /// Entries are extracted as they are, never looked up again by the decoded name.
    private static func namedEntries(in archive: Archive, archiveURL: URL) async throws -> [(entry: Entry, path: String)] {
        do {
            return ZipEntryNames.decode(try await archive.entries(), archiveName: archiveURL.lastPathComponent)
        } catch {
            AppLogger.parse(
                "Audiobook archive entries could not be read",
                error: error,
                context: ["archive": archiveURL.lastPathComponent]
            )
            throw LocalAudiobookArchiveError.cannotReadArchive
        }
    }

    private static func audioEntries(_ entries: [(entry: Entry, path: String)]) -> [(entry: Entry, path: String)] {
        entries
            .filter { isAudioEntryPath($0.path) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func chapterTitle(forEntryPath path: String) -> String {
        cleanChapterTitle(((path as NSString).deletingPathExtension as NSString).lastPathComponent)
    }

    static func chapterSeeds(
        fromGroups groups: [AVTimedMetadataGroup],
        totalDurationSeconds: Double?,
        fallbackTitle: String
    ) -> [LocalAudiobookChapterSeed] {
        let sorted = groups
            .compactMap { group -> (group: AVTimedMetadataGroup, start: Double)? in
                guard let start = finiteSeconds(group.timeRange.start) else { return nil }
                return (group, max(0, start))
            }
            .sorted { $0.start < $1.start }

        guard !sorted.isEmpty else {
            return [
                LocalAudiobookChapterSeed(
                    title: cleanChapterTitle(fallbackTitle),
                    audioStartSeconds: nil,
                    audioDurationSeconds: nil
                )
            ]
        }

        return sorted.enumerated().map { index, entry in
            let nextStart = sorted.indices.contains(index + 1) ? sorted[index + 1].start : nil
            let rawDuration = finiteSeconds(entry.group.timeRange.duration)
            let unclampedEnd = rawDuration.map { entry.start + $0 }
                ?? nextStart
                ?? totalDurationSeconds
            let end = minPositive(unclampedEnd, totalDurationSeconds) ?? unclampedEnd
            let duration = end.map { max(0, $0 - entry.start) }
            let title = firstNonEmpty(
                stringValue(in: entry.group.items, commonKey: .commonKeyTitle),
                String(format: localized("章節 %d"), index + 1)
            )

            return LocalAudiobookChapterSeed(
                title: cleanChapterTitle(title),
                audioStartSeconds: entry.start,
                audioDurationSeconds: duration.flatMap { $0 > 0 ? $0 : nil }
            )
        }
    }

    static func cleanChapterTitle(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n-,"))
        return cleaned.isEmpty ? localized("標題：章節") : cleaned
    }

    private static func chapterMetadataGroups(for asset: AVAsset) async throws -> [AVTimedMetadataGroup] {
        let locales = (try? await asset.load(.availableChapterLocales)) ?? []
        guard let locale = locales.first else { return [] }
        return try await asset.loadChapterMetadataGroups(
            withTitleLocale: locale,
            containingItemsWithCommonKeys: []
        )
    }

    private static func coverImageData(in archive: Archive, entries: [(entry: Entry, path: String)]) async -> Data? {
        guard let cover = entries
            .filter({ isCoverImageEntryPath($0.path) })
            .min(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
        else { return nil }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard (try? await archive.extract(cover.entry, to: tempURL, skipCRC32: true)) != nil else {
            return nil
        }
        return try? Data(contentsOf: tempURL)
    }

    private static func artworkData(of audio: (entry: Entry, path: String), in archive: Archive) async -> Data? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension((audio.path as NSString).pathExtension)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard (try? await archive.extract(audio.entry, to: tempURL, skipCRC32: true)) != nil,
              let info = try? await inspectSingleFile(url: tempURL)
        else { return nil }
        return info.coverImageData
    }

    private static func isAudioEntryPath(_ path: String) -> Bool {
        isVisibleFile(path) && allowedAudioExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    private static func isCoverImageEntryPath(_ path: String) -> Bool {
        isVisibleFile(path) && allowedCoverImageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    private static func isVisibleFile(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard let filename = components.last, !filename.hasPrefix(".") else { return false }
        guard !components.contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) else {
            return false
        }
        return !(path as NSString).pathExtension.isEmpty
    }

    private static func stringValue(in metadata: [AVMetadataItem], commonKey: AVMetadataKey) -> String? {
        guard let item = metadata.first(where: { $0.commonKey?.rawValue == commonKey.rawValue }) else {
            return nil
        }
        return item.value(forKey: "stringValue") as? String
    }

    private static func artworkData(in metadata: [AVMetadataItem]) -> Data? {
        guard let item = metadata.first(where: {
            $0.commonKey?.rawValue == AVMetadataKey.commonKeyArtwork.rawValue
        }) else { return nil }
        return item.value(forKey: "dataValue") as? Data
    }

    private static func finiteSeconds(_ time: CMTime) -> Double? {
        let seconds = time.seconds
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    private static func minPositive(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case let (.some(a), .some(b)):
            return min(a, b)
        case let (.some(a), .none):
            return a
        case let (.none, .some(b)):
            return b
        case (.none, .none):
            return nil
        }
    }
}
