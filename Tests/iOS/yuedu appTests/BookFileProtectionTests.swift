import Foundation
import Testing
@testable import yuedu_app

/// A volume that stores data-protection classes the way a device's does, which the
/// simulator's does not: a copy takes its source's class (`copyfile(3)` opens the destination
/// with `GET_PROT_CLASS(src)`), and a class cannot be changed while the device is locked.
private final class ProtectedVolume: @unchecked Sendable {
    private let lock = NSLock()
    private var classes: [String: FileProtectionType] = [:]
    private var locked = false

    func set(_ protection: FileProtectionType, _ url: URL) {
        lock.withLock { classes[url.standardizedFileURL.path] = protection }
    }

    func protection(_ url: URL) -> FileProtectionType? {
        lock.withLock { classes[url.standardizedFileURL.path] }
    }

    func setLocked(_ value: Bool) { lock.withLock { locked = value } }

    var volume: BookFileProtection.Volume {
        BookFileProtection.Volume(
            copy: { [self] source, destination in
                try FileManager.default.copyItem(at: source, to: destination)
                if let inherited = protection(source) { set(inherited, destination) }
            },
            protection: { [self] in protection($0) },
            setProtection: { [self] protection, url in
                if lock.withLock({ locked }) { throw CocoaError(.fileWriteNoPermission) }
                set(protection, url)
            }
        )
    }
}

@Suite("Book file protection")
struct BookFileProtectionTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookFileProtectionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDefaults() -> UserDefaults {
        let name = "BookFileProtectionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("A plain copy of a file that locks with the device still locks with the device")
    func plainCopyInheritsTheSourceClass() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ProtectedVolume()
        let source = root.appendingPathComponent("attachment.txt")
        try Data("第一章".utf8).write(to: source)
        disk.set(.complete, source)

        let plain = root.appendingPathComponent("plain.txt")
        try disk.volume.copy(source, plain)

        // The crash: this is what every importer did, and what 朗讀 then read behind the lock.
        #expect(disk.protection(plain) == .complete)
        #expect(BookFileProtection.locksWithDevice(.complete))
    }

    @Test("An imported book is readable while locked, whatever class its source had",
          arguments: [FileProtectionType.complete, .completeUnlessOpen, .completeUntilFirstUserAuthentication])
    func importedCopyGetsTheLibraryClass(sourceClass: FileProtectionType) throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ProtectedVolume()
        let source = root.appendingPathComponent("attachment.txt")
        let bytes = Data("第一章\n正文".utf8)
        try bytes.write(to: source)
        disk.set(sourceClass, source)

        let imported = root.appendingPathComponent("book.txt")
        try BookFileProtection.copy(from: source, to: imported, volume: disk.volume)

        #expect(disk.protection(imported) == .completeUntilFirstUserAuthentication)
        #expect(!BookFileProtection.locksWithDevice(try #require(disk.protection(imported))))
        #expect(try Data(contentsOf: imported) == bytes)
        // The file it came from is the other app's: untouched.
        #expect(disk.protection(source) == sourceClass)
    }

    @Test("The TXT importer's copy goes through the library class")
    func txtPersistenceUsesTheLibraryCopy() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("第一章\n正文".utf8).write(to: source)
        let destination = root.appendingPathComponent("persisted.txt")

        try TXTFilePersistence.persistOriginal(source: source, destination: destination)

        // The simulator stores no class, so the live volume can only show the call was made
        // and accepted; the class itself is the test above.
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("Books imported before the fix are given the library class once")
    func existingFilesAreRelaxedOnce() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ProtectedVolume()
        let defaults = makeDefaults()
        let nested = root.appendingPathComponent("audio-book", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let files: [(URL, FileProtectionType?)] = [
            (root.appendingPathComponent("a.txt"), .complete),
            (root.appendingPathComponent("b.epub"), .completeUnlessOpen),
            (root.appendingPathComponent("c.txt"), .completeUntilFirstUserAuthentication),
            (root.appendingPathComponent("d.md"), nil),
            (nested.appendingPathComponent("01.mp3"), .complete),
        ]
        for (url, protection) in files {
            try Data("x".utf8).write(to: url)
            if let protection { disk.set(protection, url) }
        }

        BookFileProtection.relaxExistingFiles(in: root, userDefaults: defaults, volume: disk.volume)

        for (url, protection) in files {
            #expect(disk.protection(url) == protection.map { _ in FileProtectionType.completeUntilFirstUserAuthentication })
        }
        #expect(defaults.bool(forKey: BookFileProtection.migrationCompletedKey))

        // Once: a file that arrives locked afterwards is the importer's to fix, not a relaunch's.
        let later = root.appendingPathComponent("later.txt")
        try Data("x".utf8).write(to: later)
        disk.set(.complete, later)
        BookFileProtection.relaxExistingFiles(in: root, userDefaults: defaults, volume: disk.volume)
        #expect(disk.protection(later) == .complete)
    }

    @Test("A launch behind the lock screen leaves the migration for the next launch")
    func lockedLaunchRetries() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ProtectedVolume()
        let defaults = makeDefaults()
        let book = root.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: book)
        disk.set(.complete, book)

        disk.setLocked(true)
        BookFileProtection.relaxExistingFiles(in: root, userDefaults: defaults, volume: disk.volume)
        #expect(disk.protection(book) == .complete)
        #expect(!defaults.bool(forKey: BookFileProtection.migrationCompletedKey))

        disk.setLocked(false)
        BookFileProtection.relaxExistingFiles(in: root, userDefaults: defaults, volume: disk.volume)
        #expect(disk.protection(book) == .completeUntilFirstUserAuthentication)
        #expect(defaults.bool(forKey: BookFileProtection.migrationCompletedKey))
    }
}
