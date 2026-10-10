import Foundation
import Testing
@testable import yuedu_app

/// Unified library, Phase 0d: a custom explore page file that cannot be read is never
/// written over before its bytes are safe. A file that does not decode is kept aside as
/// `…corrupt-<stamp>.json`, then the store writes as usual; one that cannot be read, or
/// cannot be copied, blocks writes for that launch.
@MainActor
@Suite("Custom explore page store write guard", .serialized)
struct CustomExplorePageStoreWriteGuardTests {
    @Test("a file that does not decode is kept aside, then the store writes a fresh one")
    func undecodableFileIsKeptAsideThenWritten() throws {
        let (directory, fileURL) = try makeLocation()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data("{ not json".utf8)
        try original.write(to: fileURL)

        let store = CustomExplorePageStore(fileURL: fileURL)
        #expect(store.pages.isEmpty)
        let backups = try corruptCopies(in: directory)
        #expect(backups.count == 1)
        #expect(try backups.first.map { try Data(contentsOf: $0) } == original)

        store.createPage(named: "新頁")

        #expect(CustomExplorePageStore(fileURL: fileURL).pages.map(\.name) == ["新頁"])
        #expect(try corruptCopies(in: directory).map { try Data(contentsOf: $0) } == [original])
    }

    @Test("opening the same undecodable file twice keeps one copy")
    func openingTwiceKeepsOneCopy() throws {
        let (directory, fileURL) = try makeLocation()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{ not json".utf8).write(to: fileURL)

        _ = CustomExplorePageStore(fileURL: fileURL)
        _ = CustomExplorePageStore(fileURL: fileURL)

        #expect(try corruptCopies(in: directory).count == 1)
    }

    @Test("a file that cannot be read is never written over")
    func unreadableFileBlocksWrites() throws {
        let (directory, fileURL) = try makeLocation()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let original = try JSONEncoder().encode([CustomExplorePage(name: "原本的頁")])
        try original.write(to: fileURL)
        // Unreadable but replaceable: an atomic write would rename a new file over it,
        // so only the store's own guard keeps it.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        let refusalsBefore = refusalCount(for: fileURL)

        let store = CustomExplorePageStore(fileURL: fileURL)
        let page = store.createPage(named: "新頁")
        store.renamePage(id: page.id, to: "改名")
        store.saveComponent(CustomExploreComponent(kind: .ranking, categories: []), inPage: page.id)
        store.deletePage(id: page.id)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        #expect(try Data(contentsOf: fileURL) == original)
        #expect(try corruptCopies(in: directory).isEmpty)
        #expect(refusalCount(for: fileURL) - refusalsBefore == 4)
    }

    @Test("a file that cannot be kept aside is never written over")
    func uncopyableFileBlocksWrites() throws {
        let (directory, fileURL) = try makeLocation()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let original = Data("{ not json".utf8)
        try original.write(to: fileURL)
        // A read-only folder: the copy cannot be created there.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        let refusalsBefore = refusalCount(for: fileURL)

        let store = CustomExplorePageStore(fileURL: fileURL)
        store.createPage(named: "新頁")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        #expect(try Data(contentsOf: fileURL) == original)
        #expect(try corruptCopies(in: directory).isEmpty)
        #expect(refusalCount(for: fileURL) - refusalsBefore == 1)
    }

    @Test("with no file yet, the store saves as usual")
    func missingFileSavesNormally() throws {
        let (directory, fileURL) = try makeLocation()
        defer { try? FileManager.default.removeItem(at: directory) }

        CustomExplorePageStore(fileURL: fileURL).createPage(named: "第一頁")

        #expect(CustomExplorePageStore(fileURL: fileURL).pages.map(\.name) == ["第一頁"])
        #expect(try corruptCopies(in: directory).isEmpty)
    }

    // MARK: - Helpers

    /// A fresh folder and a file name unique to this test, so the refusal log lines of one
    /// test can be told from another's.
    private func makeLocation() throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-explore-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("pages-\(UUID().uuidString).json"))
    }

    private func corruptCopies(in directory: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("corrupt") }
    }

    private func refusalCount(for fileURL: URL) -> Int {
        DiagnosticLog.shared.snapshot().filter {
            $0.message.contains("custom explore pages not saved") && $0.message.contains(fileURL.lastPathComponent)
        }.count
    }
}
