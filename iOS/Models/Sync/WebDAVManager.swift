import Foundation
import Combine
import UIKit

// MARK: - WebDAV 錯誤類型

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

// MARK: - 同步清單（隨每次備份上傳至 /yuedu/manifest.json）

struct SyncManifest: Codable {
    var deviceId: String
    var deviceName: String
    var backupDate: Date
    var appVersion: String
}

// MARK: - 衝突資訊

struct SyncConflict {
    let remote: SyncManifest
    let localLastSync: Date
}

// MARK: - WebDAV 管理器

final class WebDAVManager: ObservableObject {

    static let shared = WebDAVManager()

    // MARK: 設定（持久化至 UserDefaults）

    @Published var serverUrl: String {
        didSet { UserDefaults.standard.set(serverUrl, forKey: "webdav_url") }
    }
    @Published var username: String {
        didSet { UserDefaults.standard.set(username, forKey: "webdav_username") }
    }
    @Published var password: String {
        didSet { UserDefaults.standard.set(password, forKey: "webdav_password") }
    }

    // MARK: 狀態

    @Published var isSyncing: Bool = false
    @Published var lastSyncDate: Date? {
        didSet {
            if let date = lastSyncDate {
                UserDefaults.standard.set(date, forKey: "webdav_last_sync")
            }
        }
    }
    @Published var statusMessage: String = ""
    /// 偵測到跨裝置衝突時非 nil；View 監聽並彈出選擇對話框。
    @Published var pendingConflict: SyncConflict?

    // MARK: 私有

    /// 每台裝置唯一 ID，首次產生後存入 UserDefaults。
    private static var deviceId: String {
        let key = "sync_device_id"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    // MARK: 初始化

    private init() {
        serverUrl    = UserDefaults.standard.string(forKey: "webdav_url") ?? ""
        username     = UserDefaults.standard.string(forKey: "webdav_username") ?? ""
        password     = UserDefaults.standard.string(forKey: "webdav_password") ?? ""
        lastSyncDate = UserDefaults.standard.object(forKey: "webdav_last_sync") as? Date
    }

    // MARK: - 認證

    private var authHeader: String {
        let credentials = "\(username):\(password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    // MARK: - 公開介面

    /// 測試 WebDAV 連線，回傳是否成功。
    func testConnection() async -> Bool {
        do {
            return try await propfind(path: "/")
        } catch {
            return false
        }
    }

    /// 將三份本地資料備份至 WebDAV，同時上傳包含裝置資訊的 manifest.json。
    ///
    /// 檔案讀取策略：
    /// - 若檔案不存在（首次使用前尚未產生），靜默略過該項目。
    /// - 若檔案存在但讀取失敗（權限錯誤、磁碟故障），拋出錯誤並中斷備份，
    ///   避免顯示不實的「備份成功」訊息。
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

        // 4. manifest.json（衝突偵測用）
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

    /// 若 `localURL` 指向的檔案存在，讀取並上傳；若檔案不存在則略過。
    /// 檔案存在但讀取失敗時會拋出錯誤，防止靜默略過真實故障。
    private func backupFileIfExists(at localURL: URL, to remotePath: String) async throws {
        guard FileManager.default.fileExists(atPath: localURL.path) else { return }
        let data = try Data(contentsOf: localURL)
        try await put(data: data, path: remotePath)
    }

    /// 從 WebDAV 下載備份並覆寫本地資料（含衝突偵測）。
    /// 若偵測到跨裝置衝突，設定 `pendingConflict` 並提前返回，由 UI 決定是否繼續。
    func restore() async throws {
        try await performRestore(skipConflictCheck: false)
    }

    /// 使用者確認後呼叫：強制以雲端備份覆蓋本地。
    func resolveConflict(keepRemote: Bool) async throws {
        await MainActor.run { pendingConflict = nil }
        if keepRemote {
            try await performRestore(skipConflictCheck: true)
        }
        // keepRemote == false：保留本地，什麼都不做
    }

    // MARK: - 私有還原實作

    private func performRestore(skipConflictCheck: Bool) async throws {
        await setSync(true, message: "還原中…")
        defer { Task { @MainActor in self.isSyncing = false } }

        // ── 衝突偵測 ────────────────────────────────────────────────────────────
        if !skipConflictCheck {
            if let manifestData = try? await get(path: "/yuedu/manifest.json"),
               let remote = try? JSONDecoder().decode(SyncManifest.self, from: manifestData) {
                let isOtherDevice = remote.deviceId != Self.deviceId
                // 本地曾同步過 → 雲端可能是另一台裝置的舊備份，可能覆蓋本地較新資料
                if isOtherDevice, let localSync = lastSyncDate {
                    await MainActor.run {
                        self.pendingConflict = SyncConflict(remote: remote, localLastSync: localSync)
                        self.statusMessage = "偵測到衝突，請選擇要使用哪個版本"
                    }
                    return
                }
            }
        }

        // ── 正式還原 ─────────────────────────────────────────────────────────────
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

    // MARK: - 私有 HTTP 方法

    /// PROPFIND：確認路徑存在（HTTP 200 或 207）。
    private func propfind(path: String) async throws -> Bool {
        var request = try makeRequest(path: path)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200 || http.statusCode == 207
    }

    /// MKCOL：建立目錄（忽略 405 = 已存在）。
    private func mkcol(path: String) async throws {
        var request = try makeRequest(path: path)
        request.httpMethod = "MKCOL"

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode != 201 && http.statusCode != 405 && http.statusCode != 200 {
            throw WebDAVError.connectionFailed(http.statusCode)
        }
    }

    /// PUT：上傳資料至指定路徑。
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

    /// GET：從指定路徑下載資料。
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

    // MARK: - 工具

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
