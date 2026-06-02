import Foundation
import Combine
import UIKit

// MARK: - WebDAV Error Types

enum WebDAVError: LocalizedError {
    case invalidURL
    case authenticationFailed
    case connectionFailed(Int)
    case noData
    case fileNotFound

    var errorDescription: String? {
        switch self {
        case .invalidURL:           return "伺服器網址格式無效"
        case .authenticationFailed: return "認證失敗，請確認帳號和密碼"
        case .connectionFailed(let code): return "連線失敗（HTTP \(code)）"
        case .noData:               return "伺服器未返回資料"
        case .fileNotFound:         return "雲端找不到備份檔案"
        }
    }
}

// MARK: - Sync Manifest (uploaded to /yuedu/manifest.json with each backup)

struct SyncManifest: Codable {
    var deviceId: String
    var deviceName: String
    var backupDate: Date
    var appVersion: String
}

// MARK: - Conflict Info

struct SyncConflict {
    let remote: SyncManifest
    let localLastSync: Date
}

// MARK: - WebDAV Manager

final class WebDAVManager: ObservableObject {

    static let shared = WebDAVManager()

    // MARK: Settings (persisted to UserDefaults)

    @Published var serverUrl: String {
        didSet { UserDefaults.standard.set(serverUrl, forKey: "webdav_url") }
    }
    @Published var username: String {
        didSet { UserDefaults.standard.set(username, forKey: "webdav_username") }
    }
    @Published var password: String {
        didSet { UserDefaults.standard.set(password, forKey: "webdav_password") }
    }

    // MARK: State

    @Published var isSyncing: Bool = false
    @Published var lastSyncDate: Date? {
        didSet {
            if let date = lastSyncDate {
                UserDefaults.standard.set(date, forKey: "webdav_last_sync")
            }
        }
    }
    @Published var statusMessage: String = ""
    /// Non-nil when a cross-device conflict is detected; the view observes and shows a selection dialog.
    @Published var pendingConflict: SyncConflict?

    // MARK: Private

    /// Unique per-device ID stored in UserDefaults on first generation.
    private static var deviceId: String {
        let key = "sync_device_id"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    // MARK: Initialization

    private init() {
        serverUrl    = UserDefaults.standard.string(forKey: "webdav_url") ?? ""
        username     = UserDefaults.standard.string(forKey: "webdav_username") ?? ""
        password     = UserDefaults.standard.string(forKey: "webdav_password") ?? ""
        lastSyncDate = UserDefaults.standard.object(forKey: "webdav_last_sync") as? Date
    }

    // MARK: - Authentication

    private var authHeader: String {
        let credentials = "\(username):\(password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    // MARK: - Public Interface

    /// Test WebDAV connection; returns whether successful.
    func testConnection() async -> Bool {
        do {
            return try await propfind(path: "/")
        } catch {
            return false
        }
    }

    /// Back up three local data files to WebDAV, along with a manifest.json containing device info.
    ///
    /// File reading strategy:
    /// - If a file does not exist (not yet generated before first use), silently skip it.
    /// - If a file exists but fails to read (permission error, disk failure), throw an error
    ///   and abort the backup to avoid displaying a false "backup successful" message.
    func backup() async throws {
        await setSync(true, message: "備份中…")
        defer { Task { @MainActor in self.isSyncing = false } }

        try? await mkcol(path: "/yuedu/")

        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let libDir  = FileManager.default.urls(for: .libraryDirectory,  in: .userDomainMask).first!

        // 1. book_sources.json
        let bookSourcesURL = docsDir.appendingPathComponent("book_sources.json")
        try await backupFileIfExists(at: bookSourcesURL, to: "/yuedu/book_sources.json")

        // 2. books.json — read from the file-based store (mirrors BookStore.booksMetaFileURL)
        let booksMetaURL = docsDir.appendingPathComponent("books_meta.json")
        try await backupFileIfExists(at: booksMetaURL, to: "/yuedu/books.json")

        // 3. replace_rules.json
        let replaceURL = libDir.appendingPathComponent("replace_rules.json")
        try await backupFileIfExists(at: replaceURL, to: "/yuedu/replace_rules.json")

        // 4. manifest.json (for conflict detection)
        let deviceName = await MainActor.run { UIDevice.current.name }
        let manifest = SyncManifest(
            deviceId: Self.deviceId,
            deviceName: deviceName,
            backupDate: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        )
        if let manifestData = try? JSONEncoder().encode(manifest) {
            try await put(data: manifestData, path: "/yuedu/manifest.json")
        }

        await MainActor.run {
            self.lastSyncDate = Date()
            self.statusMessage = "備份成功"
        }
    }

    /// If the file at `localURL` exists, read and upload it; skip if the file does not exist.
    /// If the file exists but fails to read, an error is thrown to prevent silently ignoring real failures.
    private func backupFileIfExists(at localURL: URL, to remotePath: String) async throws {
        guard FileManager.default.fileExists(atPath: localURL.path) else { return }
        let data = try Data(contentsOf: localURL)
        try await put(data: data, path: remotePath)
    }

    /// Download backup from WebDAV and overwrite local data (includes conflict detection).
    /// If a cross-device conflict is detected, sets `pendingConflict` and returns early;
    /// the UI decides whether to proceed.
    func restore() async throws {
        try await performRestore(skipConflictCheck: false)
    }

    /// Called after user confirmation: forcefully overwrite local data with the cloud backup.
    func resolveConflict(keepRemote: Bool) async throws {
        await MainActor.run { pendingConflict = nil }
        if keepRemote {
            try await performRestore(skipConflictCheck: true)
        }
        // keepRemote == false: keep local, do nothing
    }

    // MARK: - Private Restore Implementation

    private func performRestore(skipConflictCheck: Bool) async throws {
        await setSync(true, message: "還原中…")
        defer { Task { @MainActor in self.isSyncing = false } }

        // ── Conflict Detection ──────────────────────────────────────────────────────
        if !skipConflictCheck {
            if let manifestData = try? await get(path: "/yuedu/manifest.json"),
               let remote = try? JSONDecoder().decode(SyncManifest.self, from: manifestData) {
                let isOtherDevice = remote.deviceId != Self.deviceId
                // Local has synced before → cloud may be an older backup from another device,
                // potentially overwriting newer local data.
                if isOtherDevice, let localSync = lastSyncDate {
                    await MainActor.run {
                        self.pendingConflict = SyncConflict(remote: remote, localLastSync: localSync)
                        self.statusMessage = "偵測到衝突，請選擇要使用哪個版本"
                    }
                    return
                }
            }
        }

        // ── Perform Restore ─────────────────────────────────────────────────────────
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let libDir  = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!

        if let sourcesData = try? await get(path: "/yuedu/book_sources.json") {
            let url = docsDir.appendingPathComponent("book_sources.json")
            try sourcesData.write(to: url, options: .atomic)
            if let decoded = try? JSONDecoder().decode([BookSource].self, from: sourcesData) {
                await MainActor.run { BookSourceStore.shared.sources = decoded }
            }
        }

        if let booksData = try? await get(path: "/yuedu/books.json") {
            let booksMetaURL = docsDir.appendingPathComponent("books_meta.json")
            try booksData.write(to: booksMetaURL, options: .atomic)
            // Clean up any legacy UserDefaults entry from before the file migration.
            UserDefaults.standard.removeObject(forKey: "yd_books_meta")
        }

        if let rulesData = try? await get(path: "/yuedu/replace_rules.json") {
            let url = libDir.appendingPathComponent("replace_rules.json")
            try rulesData.write(to: url, options: .atomic)
        }

        await MainActor.run {
            self.lastSyncDate = Date()
            self.statusMessage = "還原成功，書庫和替換規則需重啟 App 後完全生效"
        }
    }

    // MARK: - Private HTTP Methods

    /// PROPFIND: Check if path exists (HTTP 200 or 207).
    private func propfind(path: String) async throws -> Bool {
        var request = try makeRequest(path: path)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200 || http.statusCode == 207
    }

    /// MKCOL: Create directory (ignore 405 = already exists).
    private func mkcol(path: String) async throws {
        var request = try makeRequest(path: path)
        request.httpMethod = "MKCOL"

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode != 201 && http.statusCode != 405 && http.statusCode != 200 {
            throw WebDAVError.connectionFailed(http.statusCode)
        }
    }

    /// PUT: Upload data to the specified path.
    private func put(data: Data, path: String) async throws {
        var request = try makeRequest(path: path)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 { throw WebDAVError.authenticationFailed }
        if !(200...299).contains(http.statusCode) {
            throw WebDAVError.connectionFailed(http.statusCode)
        }
    }

    /// GET: Download data from the specified path.
    private func get(path: String) async throws -> Data {
        var request = try makeRequest(path: path)
        request.httpMethod = "GET"

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.noData }
        if http.statusCode == 401 { throw WebDAVError.authenticationFailed }
        if http.statusCode == 404 { throw WebDAVError.fileNotFound }
        if !(200...299).contains(http.statusCode) {
            throw WebDAVError.connectionFailed(http.statusCode)
        }
        return data
    }

    // MARK: - Utilities

    private func makeRequest(path: String) throws -> URLRequest {
        let base = serverUrl.hasSuffix("/") ? String(serverUrl.dropLast()) : serverUrl
        guard !base.isEmpty, let url = URL(string: base + path) else {
            throw WebDAVError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        return request
    }

    @MainActor
    private func setSync(_ syncing: Bool, message: String) {
        isSyncing = syncing
        statusMessage = message
    }
}
