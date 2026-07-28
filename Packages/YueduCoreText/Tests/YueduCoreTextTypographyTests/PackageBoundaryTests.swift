import Foundation
import Testing

@Suite("Package dependency boundary")
struct PackageBoundaryTests {
    @Test("Typography sources stay independent from app and third-party layers")
    func sourceImportsAndSymbols() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = packageRoot
            .appendingPathComponent("Sources/YueduCoreTextTypography", isDirectory: true)
        let forbiddenFragments = [
            "import Readium",
            "import SwiftSoup",
            "import WebKit",
            "import Firebase",
            "import RealmSwift",
            "AppLogger",
            "GlobalSettings",
            "BookSourceSession",
        ]

        let files = try FileManager.default.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }

        #expect(!files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for fragment in forbiddenFragments {
                #expect(
                    !source.contains(fragment),
                    "Forbidden dependency '\(fragment)' found in \(file.lastPathComponent)"
                )
            }
        }
    }
}
