import Foundation
import Combine

// MARK: - 書源管理（ObservableObject）

class BookSourceStore: ObservableObject {
    static let shared = BookSourceStore()

    @Published var sources: [BookSource] = []

    private let fileName = "book_sources.json"

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    private init() {
        load()
    }

    // MARK: CRUD

    func add(_ source: BookSource) {
        sources.insert(source, at: 0)
        save()
    }

    func update(_ source: BookSource) {
        if let idx = sources.firstIndex(where: { $0.id == source.id }) {
            sources[idx] = source
            save()
        }
    }

    func delete(id: UUID) {
        sources.removeAll { $0.id == id }
        save()
    }

    func toggle(id: UUID) {
        if let idx = sources.firstIndex(where: { $0.id == id }) {
            sources[idx].enabled.toggle()
            save()
        }
    }

    var enabledSources: [BookSource] {
        sources.filter { $0.enabled }
    }

    // MARK: 匯入（Legado 相容）

    @discardableResult
    func importFromJSON(_ json: String) throws -> Int {
        guard let data = json.data(using: .utf8) else {
            throw ImportError.invalidData
        }
        let decoder = JSONDecoder()
        var imported: [BookSource] = []

        // 嘗試陣列格式 [...]
        if let arr = try? decoder.decode([BookSource].self, from: data) {
            imported = arr
        }
        // 嘗試單個物件 {...}
        else if let single = try? decoder.decode(BookSource.self, from: data) {
            imported = [single]
        }
        // 嘗試 Legado App 備份格式（bookSources 欄位）
        else if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let raw = dict["bookSources"] {
            let subData = try JSONSerialization.data(withJSONObject: raw)
            imported = (try? decoder.decode([BookSource].self, from: subData)) ?? []
        }
        else {
            // 產生有用的診斷訊息
            let detail: String
            do {
                _ = try decoder.decode([BookSource].self, from: data)
                detail = ""
            } catch let DecodingError.typeMismatch(type, ctx) {
                detail = "類型不匹配: 期望 \(type), 路徑: \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
            } catch let DecodingError.keyNotFound(key, ctx) {
                detail = "缺少 key: \(key.stringValue), 路徑: \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
            } catch let DecodingError.dataCorrupted(ctx) {
                detail = "數據損壞: \(ctx.debugDescription)"
            } catch {
                detail = error.localizedDescription
            }
            throw ImportError.parseErrorDetail(detail)
        }

        guard !imported.isEmpty else {
            throw ImportError.parseError
        }

        // 去重：已存在相同 bookSourceUrl 的則更新，否則新增
        for src in imported {
            if let idx = sources.firstIndex(where: { $0.bookSourceUrl == src.bookSourceUrl }) {
                var updated = src
                updated.id = sources[idx].id   // 保留原 id
                sources[idx] = updated
            } else {
                sources.append(src)
            }
        }
        save()
        return imported.count
    }

    // MARK: 匯出

    func exportToJSON() -> String {
        guard let data = try? JSONEncoder().encode(sources),
              let str = String(data: data, encoding: .utf8)
        else { return "[]" }
        return str
    }

    func exportToJSON(ids: [UUID]) -> String {
        let selected = sources.filter { ids.contains($0.id) }
        guard let data = try? JSONEncoder().encode(selected),
              let str = String(data: data, encoding: .utf8)
        else { return "[]" }
        return str
    }

    // MARK: 持久化

    private func save() {
        if let data = try? JSONEncoder().encode(sources) {
            try? data.write(to: fileURL)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([BookSource].self, from: data)
        else { return }
        sources = decoded
    }

    // MARK: 錯誤

    enum ImportError: LocalizedError {
        case invalidData
        case parseError
        case parseErrorDetail(String)

        var errorDescription: String? {
            switch self {
            case .invalidData: return "無效的數據格式"
            case .parseError: return "無法解析書源 JSON，請確認格式正確"
            case .parseErrorDetail(let detail):
                return "無法解析書源 JSON: \(detail)"
            }
        }
    }
}
