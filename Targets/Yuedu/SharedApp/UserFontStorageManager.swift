import CoreText
import Foundation

struct UserFontInfo: Codable, Equatable, Identifiable {
    let id: UUID
    let fileName: String
    let displayName: String
    let familyName: String
    let postScriptName: String
    let addedAt: Date
}

enum UserFontStorageError: LocalizedError {
    case unsupportedFileType
    case invalidFontFile
    case missingDocumentsDirectory

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
            return localized("僅支援 TTF 或 OTF 字體")
        case .invalidFontFile:
            return localized("無法讀取字體檔案")
        case .missingDocumentsDirectory:
            return localized("無法存取文件資料夾")
        }
    }
}

final class UserFontStorageManager {
    static let shared = UserFontStorageManager()

    private let fileManager: FileManager

    private struct FontMetadata {
        let familyName: String
        let postScriptName: String
        let styleName: String
    }

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Copies a font into the library. A font in `existingFonts` with the same
    /// PostScript name is the version this one replaces: its file is unregistered and
    /// deleted before the new file registers, so the name resolves to the new file and
    /// no copy is left behind. Re-importing an appearance pack re-imports its font, and
    /// before this every import kept another 13–28 MB copy (a device reached 1 GB).
    func importFont(fileURL: URL, replacing existingFonts: [UserFontInfo] = []) throws -> UserFontInfo {
        let sourceExtension = fileURL.pathExtension.lowercased()
        guard ["ttf", "otf"].contains(sourceExtension) else {
            throw UserFontStorageError.unsupportedFileType
        }

        let directory = try fontsDirectoryURL()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let id = UUID()
        let destination = directory
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension(sourceExtension)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: fileURL, to: destination)

        guard let metadata = Self.fontMetadata(from: destination) else {
            try? fileManager.removeItem(at: destination)
            throw UserFontStorageError.invalidFontFile
        }

        for replaced in existingFonts
        where replaced.postScriptName == metadata.postScriptName
            && replaced.fileName != destination.lastPathComponent {
            delete(replaced)
        }
        Self.registerFont(at: destination)

        return UserFontInfo(
            id: id,
            fileName: destination.lastPathComponent,
            displayName: metadata.familyName,
            familyName: metadata.familyName,
            postScriptName: metadata.postScriptName,
            addedAt: Date()
        )
    }

    func registerAllOnLaunch() {
        guard let directory = try? fontsDirectoryURL(),
              let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              )
        else { return }

        for url in urls where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            Self.registerFont(at: url)
        }
    }

    /// Deletes the copies that re-imports left behind before `importFont` replaced the
    /// old file. Only provable duplicates go: an unlisted file whose PostScript name a
    /// listed font already owns. An unlisted file with a name of its own stays — this
    /// directory is visible in the Files app, so it may have been put there by hand.
    ///
    /// One-time migration, run every launch because it is a directory listing once the
    /// copies are gone. Delete once no install from before 2026-10-12 is left.
    func removeSupersededCopies(keeping listedFonts: [UserFontInfo]) {
        let listedNames = Set(listedFonts.map(\.postScriptName))
        guard !listedNames.isEmpty else { return }
        let listedFiles = Set(listedFonts.map(\.fileName))

        let urls: [URL]
        do {
            let directory = try fontsDirectoryURL()
            guard fileManager.fileExists(atPath: directory.path) else { return }
            urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            AppLogger.error("UserFontStorage could not list the fonts directory", error: error)
            return
        }

        for url in urls
        where ["ttf", "otf"].contains(url.pathExtension.lowercased())
            && !listedFiles.contains(url.lastPathComponent) {
            guard let metadata = Self.fontMetadata(from: url),
                  listedNames.contains(metadata.postScriptName) else { continue }
            removeFile(at: url)
        }
    }

    func delete(_ font: UserFontInfo) {
        do {
            removeFile(at: try fileURL(for: font))
        } catch {
            AppLogger.error("UserFontStorage could not resolve \(font.fileName)", error: error)
        }
    }

    func fileURL(for font: UserFontInfo) throws -> URL {
        try fontsDirectoryURL().appendingPathComponent(font.fileName)
    }

    private func fontsDirectoryURL() throws -> URL {
        guard let documentsURL = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw UserFontStorageError.missingDocumentsDirectory
        }
        return documentsURL.appendingPathComponent("fonts", isDirectory: true)
    }

    private func removeFile(at url: URL) {
        Self.unregisterFont(at: url)
        do {
            try fileManager.removeItem(at: url)
        } catch {
            AppLogger.error("UserFontStorage could not delete \(url.lastPathComponent)", error: error)
        }
    }

    /// Undoes `registerFont(at:)` in whichever scope it took. The other scope reports
    /// the URL as not registered, which is the expected outcome, not a failure.
    private static func unregisterFont(at url: URL) {
        CTFontManagerUnregisterFontsForURL(url as CFURL, .persistent, nil)
        CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
    }

    private static func registerFont(at url: URL) {
        var persistentError: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .persistent, &persistentError) {
            return
        }

        var processError: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &processError) {
            if let error = processError?.takeRetainedValue() ?? persistentError?.takeRetainedValue() {
                print("[UserFontStorage] register font failed: \(error)")
            }
        }
    }

    private static func fontMetadata(from url: URL) -> (familyName: String, postScriptName: String)? {
        guard
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
            let metadata = preferredMetadata(from: descriptors)
        else { return nil }

        return (
            familyName: metadata.familyName,
            postScriptName: metadata.postScriptName
        )
    }

    private static func preferredMetadata(from descriptors: [CTFontDescriptor]) -> FontMetadata? {
        let candidates = descriptors.compactMap { metadata(from: $0) }
        guard !candidates.isEmpty else { return nil }

        return candidates.first { $0.styleName.localizedCaseInsensitiveCompare("Regular") == .orderedSame }
            ?? candidates.first { $0.postScriptName.localizedCaseInsensitiveContains("Regular") }
            ?? candidates.first
    }

    private static func metadata(from descriptor: CTFontDescriptor) -> FontMetadata? {
        let postScriptName = CTFontDescriptorCopyAttribute(
            descriptor,
            kCTFontNameAttribute
        ) as? String ?? ""
        let familyName = CTFontDescriptorCopyAttribute(
            descriptor,
            kCTFontFamilyNameAttribute
        ) as? String ?? ""
        let styleName = CTFontDescriptorCopyAttribute(
            descriptor,
            kCTFontStyleNameAttribute
        ) as? String ?? ""

        guard !postScriptName.isEmpty || !familyName.isEmpty else {
            return nil
        }

        return FontMetadata(
            familyName: familyName.isEmpty ? postScriptName : familyName,
            postScriptName: postScriptName.isEmpty ? familyName : postScriptName,
            styleName: styleName
        )
    }
}
