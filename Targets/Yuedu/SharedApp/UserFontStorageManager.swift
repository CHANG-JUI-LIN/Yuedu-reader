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

final class UserFontStorageManager: @unchecked Sendable {
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

    func importFont(fileURL: URL) throws -> UserFontInfo {
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

    func delete(_ font: UserFontInfo) {
        guard let url = try? fileURL(for: font) else { return }
        try? fileManager.removeItem(at: url)
    }

    func fileURL(for font: UserFontInfo) throws -> URL {
        try fontsDirectoryURL().appendingPathComponent(font.fileName)
    }

    /// PostScript names backed by files in Yuedu's managed font directory.
    /// Overlay styles use this list to distinguish a still-installed import from
    /// an unavailable saved reference without rewriting the saved reference.
    func availablePostScriptNames() -> Set<String> {
        guard let directory = try? fontsDirectoryURL(),
              let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return Set(urls.compactMap { url in
            guard ["ttf", "otf"].contains(url.pathExtension.lowercased()) else {
                return nil
            }
            return Self.fontMetadata(from: url)?.postScriptName
        })
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
