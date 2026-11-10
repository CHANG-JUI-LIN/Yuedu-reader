import Foundation

/// Keeps the user's book files readable while the device is locked.
///
/// A book is read long after it was opened, and often behind the lock screen: 朗讀 builds the
/// next chapter from the file minutes after the screen went dark. That only works for a file in
/// the data-protection class the app's own files get by default (until first unlock).
///
/// An imported book does not get that class. `FileManager.copyItem` is `copyfile(3)`, which
/// opens the destination in the **source's** class (`GET_PROT_CLASS(src)` →
/// `open_dprotected_np`), and a clone shares it outright. A file handed over by an app that
/// stores under complete protection (Mail attachments, most chat and cloud-drive apps) therefore
/// lands in Documents still locked with the device: ten seconds after the screen locks its key
/// is gone, and the next page fault on its memory mapping is a SIGBUS — the 3.0.0 (143) crash in
/// `TXTMappedTextFile.string(in:)`, three times in a row about two minutes after the app went to
/// the background with 朗讀 playing.
///
/// So every copy into the library goes through `copy(from:to:)`, and `relaxExistingFiles` gives
/// the files imported before this the same class once.
enum BookFileProtection {
    /// The class a book file must have: readable from the first unlock after a restart.
    static let required: FileProtectionType = .completeUntilFirstUserAuthentication

    /// The three file operations this needs, so a test can stand in a volume that stores
    /// protection classes — the simulator's does not (`attributesOfItem` reports none).
    struct Volume: Sendable {
        var copy: @Sendable (_ source: URL, _ destination: URL) throws -> Void
        var protection: @Sendable (URL) -> FileProtectionType?
        var setProtection: @Sendable (FileProtectionType, URL) throws -> Void

        static let live = Volume(
            copy: { try FileManager.default.copyItem(at: $0, to: $1) },
            protection: { url in
                do {
                    return try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
                        as? FileProtectionType
                } catch {
                    AppLogger.error("Book file protection unreadable", error: error,
                                    context: ["file": url.lastPathComponent])
                    return nil
                }
            },
            setProtection: { protection, url in
                try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
            }
        )
    }

    /// Copies a file the user is importing into the library, in the library's own class
    /// instead of the one it had where it came from.
    static func copy(from source: URL, to destination: URL, volume: Volume = .live) throws {
        try volume.copy(source, destination)
        try volume.setProtection(required, destination)
    }

    /// Whether a file in this class stops being readable when the device locks.
    static func locksWithDevice(_ protection: FileProtectionType) -> Bool {
        if #available(iOS 17.0, *), protection == .completeWhenUserInactive { return true }
        return protection == .complete || protection == .completeUnlessOpen
    }

    /// The protection class as a word for a log line.
    static func name(_ protection: FileProtectionType?) -> String {
        guard let protection else { return "unreported" }
        return protection.rawValue.replacingOccurrences(of: "NSFileProtection", with: "")
    }

    // MARK: - Files imported before `copy(from:to:)`

    static let migrationCompletedKey = "yd_book_file_protection_v1_completed"

    /// Gives every file under Documents that locks with the device the library's class, once.
    ///
    /// A file's class cannot be changed while its key is unavailable, so a launch behind the
    /// lock screen (background fetch) fails here; the flag then stays unset and the next launch
    /// tries again.
    static func relaxExistingFiles(
        in root: URL = StorageLocations.documents,
        userDefaults: UserDefaults = .standard,
        volume: Volume = .live
    ) {
        guard !userDefaults.bool(forKey: migrationCompletedKey) else { return }

        var failures = 0
        var relaxed: [String: Int] = [:]
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: []
        ) { url, error in
            failures += 1
            AppLogger.error("Book file protection: cannot list", error: error,
                            context: ["file": url.lastPathComponent])
            return true
        }
        guard let enumerator else {
            AppLogger.error("Book file protection: cannot enumerate Documents")
            return
        }
        for case let url as URL in enumerator {
            guard let protection = volume.protection(url), locksWithDevice(protection) else { continue }
            do {
                try volume.setProtection(required, url)
                relaxed[name(protection), default: 0] += 1
            } catch {
                failures += 1
                AppLogger.error("Book file protection: cannot change class", error: error,
                                context: ["file": url.lastPathComponent, "protection": name(protection)])
            }
        }

        // Named in the next crash report too: which classes the user's books were in is the
        // one fact the SIGBUS reports could not carry.
        let summary = relaxed.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        CrashContext.breadcrumb(
            "book file protection: relaxed \(summary.isEmpty ? "none" : summary) failures=\(failures)"
        )
        if failures == 0 {
            userDefaults.set(true, forKey: migrationCompletedKey)
        }
    }
}
