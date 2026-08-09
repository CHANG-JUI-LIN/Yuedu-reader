import Foundation

func readerStyleTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("reader-style-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func readerStyleFixtureUUID(_ value: Int) -> UUID {
    let suffix = String(format: "%012d", value)
    return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
}
