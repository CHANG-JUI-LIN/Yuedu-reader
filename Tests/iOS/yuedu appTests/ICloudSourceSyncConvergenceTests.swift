import Foundation
import Testing
@testable import yuedu_app

/// Offline passes of the book-source step of an iCloud sync, run through the same static
/// functions `mergeType` runs: download → `resolveMerge` → upload decision → apply → shadow
/// commit. MetricKit reports from 3.0.0 (143) sampled the two whole-file writes this step
/// can cause — `book_sources.json` (`BookSourceStore.writeLibrary`) and the upload's
/// temporary file (`uploadData`) — past 1 GB in 24 hours. A sync runs on every trip to and
/// from the background, so a pass that keeps finding something to apply or upload is that
/// gigabyte. These hold the step to: once settled, a pass applies and uploads nothing.
@Suite("iCloud book-source sync convergence")
struct ICloudSourceSyncConvergenceTests {
    /// One device's side of the sync: its source library and its merge shadow.
    struct Device {
        var local: [BookSource]
        var shadow: [String: SyncShadowEntry] = [:]
        var uploads = 0
        var applies = 0
    }

    /// The `sync_file_book_sources` record.
    final class Cloud {
        var blob: Data?
    }

    static func id(_ source: BookSource) -> String { source.id.uuidString }
    static func hash(_ source: BookSource) -> String { ICloudSyncManager.stableHash(source) }
    static func fallback(_ source: BookSource) -> Date {
        Date(timeIntervalSince1970: TimeInterval(max(source.lastUpdateTime, 0)) / 1000)
    }

    static func remote(_ cloud: Cloud) throws -> (records: [FirestoreSyncRecord<BookSource>], payloadHash: String?) {
        guard let blob = cloud.blob else { return ([], nil) }
        return try ICloudSyncManager.decodeCloudSyncBlob(
            blob, recordName: "book_sources", id: id, fallbackUpdatedAt: fallback
        )
    }

    /// One `mergeType` pass for book sources, with the arguments `performSyncPass` gives it.
    static func pass(_ device: inout Device, cloud: Cloud, now: Date) throws {
        let remote = try remote(cloud)
        let result = ICloudSyncManager.resolveMerge(
            local: device.local, remote: remote.records, shadow: device.shadow,
            id: id, hash: hash, fallbackUpdatedAt: fallback,
            kept: BookSourceStore.dedupedByURL, now: now
        )
        let records = ICloudSyncManager.cloudSyncRecords(values: result.values, shadow: result.shadow, id: id)
        if try ICloudSyncManager.shouldUploadCloudSyncRecords(records, remotePayloadHash: remote.payloadHash) {
            cloud.blob = try ICloudSyncManager.encodeCloudSyncRecords(records)
            device.uploads += 1
        }
        let before = device.local
        if result.shouldApplyLocally {
            // What `replaceSourcesFromSync` keeps.
            device.local = BookSourceStore.dedupedByURL(result.values)
            device.applies += 1
        }
        let committed = ICloudSyncManager.shadowToCommit(
            previous: device.shadow, merge: result, local: before, appliedLocally: true, id: id, hash: hash
        )
        // `SyncShadowStore` keeps it as JSON in UserDefaults.
        device.shadow = try JSONDecoder().decode(
            [String: SyncShadowEntry].self, from: JSONEncoder().encode(committed)
        )
    }

    /// A relaunch: the library is read back from its file (`BookSourceStore.readLibrary`).
    static func relaunch(_ device: inout Device) throws {
        let data = try JSONEncoder().encode(device.local)
        device.local = BookSourceStore.dedupedByURL(try JSONDecoder().decode([BookSource].self, from: data))
    }

    /// A Legado pack with the quirks the tolerant decoder exists for: numbers as strings,
    /// a rule encoded twice, `respondTime` 0, Double weights, an empty `callBackJs`.
    static func legadoPack(count: Int) -> String {
        let items = (0..<count).map { i in
            """
            {"bookSourceName":"測試源\(i)","bookSourceUrl":"https://s\(i).example.com","bookSourceGroup":"組\(i % 7)",\
            "bookSourceType":"\(i % 3)","enabled":\(i % 2),"enabledExplore":"true","respondTime":0,\
            "lastUpdateTime":"1700000000000","weight":3.0,"customOrder":"\(i)",\
            "header":"{\\"User-Agent\\":\\"Mozilla/5.0\\"}","searchUrl":"/search?q={{key}}&p={{page}}",\
            "exploreUrl":"排行::/rank\\n新書::/new","loginUrl":"","jsLib":"function f(){return 1}",\
            "ruleSearch":"{\\"bookList\\":\\"$.data[*]\\",\\"name\\":\\"$.title\\",\\"author\\":\\"$.author\\"}",\
            "ruleBookInfo":{"init":"@js:result","name":"h1@text","tocUrl":"a.toc@href"},\
            "ruleToc":{"chapterList":"ul li","chapterName":"a@text","chapterUrl":"a@href","isVip":"0"},\
            "ruleContent":{"content":"@css:div#content@html","callBackJs":"","replaceRegex":"##廣告"},\
            "ruleExplore":{"bookList":"div.item"},"ruleReview":{}}
            """
        }
        return "[" + items.joined(separator: ",") + "]"
    }

    /// An import as `importSources` does it for sources new to the library: fresh ids from
    /// the decoder, the import moment on `lastUpdateTime`.
    static func imported(_ json: String, at millis: Int64) throws -> [BookSource] {
        let parsed = try #require(BookSourceStore.parseSources(json))
        return parsed.map { var s = $0; s.lastUpdateTime = millis; return s }
    }

    private let start = Date(timeIntervalSince1970: 1_761_000_000)

    @Test func oneDeviceSettlesAfterItsFirstUpload() throws {
        let cloud = Cloud()
        var phone = Device(local: try Self.imported(Self.legadoPack(count: 60), at: 1_760_000_000_000))
        try Self.relaunch(&phone)
        try Self.pass(&phone, cloud: cloud, now: start)
        #expect(phone.uploads == 1)
        for round in 1...6 {
            try Self.relaunch(&phone)
            try Self.pass(&phone, cloud: cloud, now: start.addingTimeInterval(Double(round) * 600))
        }
        #expect(phone.uploads == 1)
        #expect(phone.applies == 0)
    }

    /// The cloud holds another device's copy of every source this device has — the same
    /// `bookSourceUrl` under another id, older. The merge carries both copies; the store
    /// keeps only this device's, so there is nothing to apply. Until 3.0.0 (143) the apply
    /// ran anyway and rewrote the whole library to what it already held.
    @Test func aMergeThatOnlyAddsAnotherCopyIsNotApplied() throws {
        let cloud = Cloud()
        let pack = Self.legadoPack(count: 40)
        var phone = Device(local: try Self.imported(pack, at: 1_760_000_000_000))
        var pad = Device(local: try Self.imported(pack, at: 1_760_000_500_000))
        try Self.pass(&phone, cloud: cloud, now: start)

        let merged = ICloudSyncManager.resolveMerge(
            local: pad.local, remote: try Self.remote(cloud).records, shadow: pad.shadow,
            id: Self.id, hash: Self.hash, fallbackUpdatedAt: Self.fallback, now: start
        )
        #expect(merged.values.count == 80)
        #expect(merged.shouldApplyLocally, "compared without what the store keeps, it is a change")

        let padLibrary = pad.local
        try Self.pass(&pad, cloud: cloud, now: start.addingTimeInterval(300))
        #expect(pad.applies == 0)
        #expect(pad.uploads == 1, "the cloud still learns of this device's copies")
        #expect(pad.local.map(\.id) == padLibrary.map(\.id))

        // The other way round the copies are newer, and they are applied.
        try Self.pass(&phone, cloud: cloud, now: start.addingTimeInterval(600))
        #expect(phone.applies == 1)
        #expect(phone.local.map(\.id) == padLibrary.map(\.id))
    }

    /// Two devices that each imported the same pack: the same `bookSourceUrl` under two
    /// random ids. Alternating passes, as foreground/background trips on both would run them.
    @Test func twoDevicesWithTheSamePackSettle() throws {
        let cloud = Cloud()
        let pack = Self.legadoPack(count: 40)
        var phone = Device(local: try Self.imported(pack, at: 1_760_000_000_000))
        var pad = Device(local: try Self.imported(pack, at: 1_760_000_500_000))
        var settledRounds = 0
        for round in 0..<10 {
            let t = start.addingTimeInterval(Double(round) * 600)
            let before = (phone.uploads + phone.applies, pad.uploads + pad.applies)
            try Self.relaunch(&phone)
            try Self.pass(&phone, cloud: cloud, now: t)
            try Self.relaunch(&pad)
            try Self.pass(&pad, cloud: cloud, now: t.addingTimeInterval(300))
            settledRounds = (phone.uploads + phone.applies, pad.uploads + pad.applies) == before ? settledRounds + 1 : 0
        }
        #expect(settledRounds >= 5, "phone \(phone.uploads)u \(phone.applies)a, pad \(pad.uploads)u \(pad.applies)a")
        #expect(phone.applies <= 1, "phone takes the pad's newer copies once")
        #expect(pad.applies == 0, "the pad already holds the copies it keeps")
        #expect(Set(phone.local.map(\.bookSourceUrl)).count == 40, "phone keeps every source")
        #expect(Set(pad.local.map(\.bookSourceUrl)).count == 40, "pad keeps every source")
    }
}
