import Combine
import Foundation
import Testing
@testable import yuedu_app

/// Unified library Phase 3d: when the filler runs.
@MainActor
@Suite("Metadata fill coordinator", .serialized)
struct MetadataFillCoordinatorTests {
    @Test("nothing is asked until the app is active, on Wi-Fi, with the setting on and Low Power Mode off")
    func conditions() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.saveReadingBook(book("三體"))
        let provider = CountingProvider()
        let network = StubNetwork(allowed: false)
        var enabled = true
        var lowPower = false
        let coordinator = MetadataFillCoordinator(store: store, makeProviders: { [provider] }, network: network,
                                                  isEnabled: { enabled }, isLowPower: { lowPower })

        coordinator.setActive(true)
        await coordinator.waitUntilIdleForTesting()
        #expect(provider.titles.isEmpty, "not on Wi-Fi")

        enabled = false
        network.allowed = true
        await coordinator.waitUntilIdleForTesting()
        #expect(provider.titles.isEmpty, "setting off")

        enabled = true
        lowPower = true
        coordinator.conditionsChanged()
        await coordinator.waitUntilIdleForTesting()
        #expect(provider.titles.isEmpty, "Low Power Mode")

        lowPower = false
        coordinator.conditionsChanged()
        await coordinator.waitUntilIdleForTesting()
        #expect(provider.titles == ["三體"])
    }

    @Test("leaving the foreground stops a pass")
    func backgroundStops() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.saveReadingBook(book("三體"))
        let coordinator = MetadataFillCoordinator(store: store, makeProviders: { [CountingProvider()] }, network: StubNetwork(allowed: true),
                                                  isEnabled: { true }, isLowPower: { false })

        coordinator.setActive(true)
        #expect(coordinator.isRunning)
        coordinator.setActive(false)
        #expect(!coordinator.isRunning)
    }

    @Test("a book joining the shelf is looked up; one already asked is not asked again")
    func newBook() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.saveReadingBook(book("三體"))
        let provider = CountingProvider()
        let coordinator = MetadataFillCoordinator(store: store, makeProviders: { [provider] }, network: StubNetwork(allowed: true),
                                                  isEnabled: { true }, isLowPower: { false })
        coordinator.setActive(true)
        await coordinator.waitUntilIdleForTesting()

        store.saveReadingBook(book("球狀閃電"))
        await coordinator.waitUntilIdleForTesting()

        #expect(provider.titles == ["三體", "球狀閃電"])
    }

    @Test("an ISBN written after the copy joined the shelf sets off another pass; the filler's own writes do not")
    func laterSidecar() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = book("Fantastic Mr Fox")
        store.saveReadingBook(copy)
        let provider = CountingProvider(answer: [.intro: .text("A fox.")], needsISBN: true)
        let coordinator = MetadataFillCoordinator(store: store, makeProviders: { [provider] }, network: StubNetwork(allowed: true),
                                                  isEnabled: { true }, isLowPower: { false })
        coordinator.setActive(true)
        await coordinator.waitUntilIdleForTesting()
        #expect(provider.titles.isEmpty, "no ISBN yet")

        let isbn = ExternalIdentifier.normalized(.isbn13, "9780140328721")!
        let announced = store.importedMetadata.announcedWrites.values.makeAsyncIterator()
        var iterator = announced
        store.importedMetadata.write(ImportedMetadata(copyID: copy.id, sourceItem: .copy(copy.id), identifiers: [isbn], values: []))
        _ = await iterator.next()
        await coordinator.waitUntilIdleForTesting()
        #expect(provider.titles == ["Fantastic Mr Fox"])
        #expect(!coordinator.isRunning, "its own write did not start another pass")
    }

    @Test("book sources imported or turned on set off a pass: a copy that had nothing to ask is asked")
    func sourcesChanged() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.saveReadingBook(book("斗罗大陆"))
        let provider = CountingProvider()
        provider.available = false
        let sources = PassthroughSubject<Void, Never>()
        let coordinator = MetadataFillCoordinator(store: store, makeProviders: { [provider] },
                                                  sourcesChanged: sources.eraseToAnyPublisher(),
                                                  network: StubNetwork(allowed: true), isEnabled: { true }, isLowPower: { false })
        coordinator.setActive(true)
        await coordinator.waitUntilIdleForTesting()
        #expect(provider.titles.isEmpty)

        provider.available = true
        sources.send()
        await coordinator.waitUntilIdleForTesting()

        #expect(provider.titles == ["斗罗大陆"])
    }

    @Test("every sidecar write is told, the filler's too, so an open 作品詳情 reads the filled values")
    func everyWriteIsTold() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = book("斗罗大陆")
        store.saveReadingBook(copy)
        var writes = store.importedMetadata.writes.values.makeAsyncIterator()
        store.importedMetadata.write(ImportedMetadata(copyID: copy.id, sourceItem: .copy(copy.id), identifiers: [],
                                                      values: [MetadataValue(field: .intro, value: .text("簡介"), provider: OpenLibrary.key,
                                                                             sourceItem: nil, fetchedAt: Date())]),
                                     announces: false)
        #expect(await writes.next() == copy.id)
        #expect(store.importedMetadata.read(copyID: copy.id)?.values.first?.value == .text("簡介"), "told after the write")
    }

    @Test("a filled cover reaches the shelf's index at once")
    func coverReachesIndex() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = book("三體")
        store.saveReadingBook(copy)
        let provider = CountingProvider(answer: [.cover: .text("ol-1.jpg")])
        let coordinator = MetadataFillCoordinator(store: store, makeProviders: { [provider] }, network: StubNetwork(allowed: true),
                                                  isEnabled: { true }, isLowPower: { false })

        coordinator.setActive(true)
        await coordinator.waitUntilIdleForTesting()

        #expect(store.filledCovers.path(for: copy) == FilledMetadata.coverDirectory.appendingPathComponent("ol-1.jpg").path)
    }

    // MARK: - Helpers

    private func makeStore() throws -> (BookStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FillCoordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json")), directory)
    }

    private func book(_ title: String) -> ReadingBook {
        ReadingBook(title: title, author: "劉慈欣", source: "local", contentFilename: "\(title).txt")
    }
}

@MainActor
private final class CountingProvider: MetadataFillProvider {
    let key = OpenLibrary.key
    let grade: MetadataMatchGrade = .a
    let answer: [MetadataField: MetadataPayload]
    let needsISBN: Bool
    var titles: [String] = []
    /// Whether there is anything to ask, as a book source provider with no source.
    var available = true

    init(answer: [MetadataField: MetadataPayload] = [:], needsISBN: Bool = false) {
        self.answer = answer
        self.needsISBN = needsISBN
    }

    func canLookUp(_ query: MetadataFillQuery) -> Bool {
        available && (!needsISBN || query.identifiers.contains { $0.scheme == .isbn13 })
    }

    func lookUp(_ query: MetadataFillQuery) async throws -> MetadataFillResult {
        titles.append(query.title)
        return MetadataFillResult(values: answer)
    }
}

@MainActor
private final class StubNetwork: NetworkPathProviding {
    private let subject: CurrentValueSubject<Bool, Never>
    var allowed: Bool {
        get { subject.value }
        set { subject.send(newValue) }
    }
    var allowsBackgroundWork: Bool { subject.value }
    var allowsBackgroundWorkPublisher: AnyPublisher<Bool, Never> { subject.removeDuplicates().eraseToAnyPublisher() }

    init(allowed: Bool) { subject = CurrentValueSubject(allowed) }
}
