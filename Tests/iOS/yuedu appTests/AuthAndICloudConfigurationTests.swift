import Foundation
import Testing
@testable import yuedu_app

@Suite("Auth and iCloud configuration")
struct AuthAndICloudConfigurationTests {
    @Test("main app entitlements enable Apple sign-in and CloudKit")
    func mainAppEntitlementsEnableAppleSignInAndCloudKit() throws {
        let entitlements = try loadMainAppEntitlements()

        #expect(entitlements["com.apple.developer.applesignin"] as? [String] == ["Default"])
        #expect(entitlements["com.apple.developer.icloud-services"] as? [String] == ["CloudKit"])
        #expect(entitlements["com.apple.developer.icloud-container-identifiers"] as? [String] == [
            "iCloud.com.zhangruilin.yuedureader"
        ])
    }

    @Test("iCloud payload covers existing sync data files")
    func iCloudPayloadCoversExistingSyncDataFiles() {
        let documentsDirectory = URL(fileURLWithPath: "/tmp/yuedu-documents", isDirectory: true)
        let libraryDirectory = URL(fileURLWithPath: "/tmp/yuedu-library", isDirectory: true)

        let files = ICloudSyncPayload.defaultFiles(
            documentsDirectory: documentsDirectory,
            libraryDirectory: libraryDirectory
        )

        #expect(files.map(\.recordName) == [
            "book_sources",
            "books_meta",
            "replace_rules"
        ])
        #expect(files.map(\.localURL.lastPathComponent) == [
            "book_sources.json",
            "books_meta.json",
            "replace_rules.json"
        ])
        #expect(files.map { $0.localURL.deletingLastPathComponent() } == [
            documentsDirectory,
            documentsDirectory,
            libraryDirectory
        ])
    }

    @Test("sign-in sync waits for choice before overwriting remote backup")
    func signInSyncWaitsForChoiceBeforeOverwritingRemoteBackup() {
        let remoteManifest = ICloudSyncManifest(
            deviceId: "other-device",
            deviceName: "Other iPhone",
            backupDate: Date(timeIntervalSince1970: 100),
            appVersion: "1.0"
        )

        #expect(ICloudSyncManager.signInAction(
            remoteManifest: nil,
            hasLocalData: true,
            currentDeviceId: "this-device"
        ) == .backup)
        #expect(ICloudSyncManager.signInAction(
            remoteManifest: remoteManifest,
            hasLocalData: false,
            currentDeviceId: "this-device"
        ) == .restore)
        #expect(ICloudSyncManager.signInAction(
            remoteManifest: remoteManifest,
            hasLocalData: true,
            currentDeviceId: "this-device"
        ) == .waitForUserChoice)
        #expect(ICloudSyncManager.signInAction(
            remoteManifest: remoteManifest,
            hasLocalData: true,
            currentDeviceId: "other-device"
        ) == .backup)
    }

    private func loadMainAppEntitlements() throws -> [String: Any] {
        let fileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = try #require(findRepoRoot(from: fileURL))
        let entitlementsURL = repoRoot.appendingPathComponent("Resources/Yuedu-Reader.entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any])
    }

    private func findRepoRoot(from fileURL: URL) -> URL? {
        var candidate = fileURL.deletingLastPathComponent()
        while candidate.path != "/" {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("Yuedu-Reader.xcodeproj").path
            ) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }
}
