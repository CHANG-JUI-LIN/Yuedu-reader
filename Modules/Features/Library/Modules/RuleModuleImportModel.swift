import Combine
import Foundation

/// 新增模組 and 檢查更新 (Phase 6e): a module file is read, checked and shown — its name,
/// author, version, lists and the sites it will send requests to — and nothing is written until
/// the reader confirms. An update that adds sites says which before it replaces anything.
@MainActor
final class RuleModuleImportModel: ObservableObject {
    struct Preview: Equatable {
        let module: RuleModule
        let data: Data
        let subscriptionURL: URL?
        /// The installed version this would replace (檢查更新); nil when adding.
        let replacing: InstalledRuleModule?

        /// Sites the update sends requests to that the installed version did not.
        var addedHosts: [String] {
            guard let replacing else { return [] }
            let known = Set(replacing.module.hosts.map { $0.lowercased() })
            return module.hosts.filter { !known.contains($0.lowercased()) }
        }
    }

    enum Phase: Equatable {
        case idle
        case loading
        case preview(Preview)
        case failed(String)
        /// 已是最新版本.
        case upToDate(String)
        case done(InstalledRuleModule)
    }

    @Published var address = ""
    @Published private(set) var phase: Phase = .idle

    private let library: RuleModuleLibrary
    private let download: (String) async throws -> (data: Data, url: URL)

    init(library: RuleModuleLibrary? = nil,
         download: @escaping (String) async throws -> (data: Data, url: URL) = { try await RuleModuleClient.download($0) }) {
        self.library = library ?? .shared
        self.download = download
    }

    var isLoading: Bool { phase == .loading }

    /// Back to an empty sheet.
    func reset() {
        address = ""
        phase = .idle
    }

    // MARK: Reading

    /// 從網址.
    func fetch() async {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        phase = .loading
        do {
            let file = try await download(address)
            show(file.data, from: file.url, replacing: nil)
        } catch {
            fail(downloading: error)
        }
    }

    /// 從檔案: the picker's URL is security-scoped.
    func read(file result: Result<URL, any Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            show(try Data(contentsOf: url), from: nil, replacing: nil)
        } catch {
            AppLogger.error("Module file unreadable", error: error, level: .error)
            phase = .failed(String(format: localized("無法讀取檔案：%@"), error.localizedDescription))
        }
    }

    /// 從剪貼簿: an address is fetched, anything else is read as the file itself.
    func read(clipboard text: String?) async {
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            phase = .failed(localized("剪貼簿為空"))
            return
        }
        let lowered = text.lowercased()
        if lowered.hasPrefix("https://") || lowered.hasPrefix("http://") {
            address = text
            await fetch()
        } else {
            show(Data(text.utf8), from: nil, replacing: nil)
        }
    }

    /// 檢查更新: the subscription address again; only a higher version is offered.
    func checkForUpdate(_ installed: InstalledRuleModule) async {
        guard let subscription = installed.subscriptionURL else { return }
        phase = .loading
        do {
            let file = try await download(subscription.absoluteString)
            show(file.data, from: subscription, replacing: installed)
        } catch {
            fail(downloading: error)
        }
    }

    private func show(_ data: Data, from subscriptionURL: URL?, replacing: InstalledRuleModule?) {
        let module: RuleModule
        do {
            module = try RuleModuleValidator.validate(data)
        } catch {
            phase = .failed(error.message)
            return
        }
        if let replacing {
            guard module.id == replacing.module.id else {
                phase = .failed(RuleModuleStoreError.differentModule(expected: replacing.module.id, offered: module.id).message)
                return
            }
            guard let offered = RuleModuleVersion(module.version), let current = RuleModuleVersion(replacing.module.version),
                  current < offered else {
                phase = .upToDate(localized("已是最新版本"))
                return
            }
        } else if OfficialRuleModules.reservedIDs.contains(module.id) {
            phase = .failed(RuleModuleStoreError.reservedID(module.id).message)
            return
        } else if library.module(id: module.id) != nil {
            phase = .failed(RuleModuleStoreError.alreadyInstalled(module.id).message)
            return
        }
        phase = .preview(Preview(module: module, data: data, subscriptionURL: subscriptionURL, replacing: replacing))
    }

    private func fail(downloading error: any Error) {
        AppLogger.network("module download failed", error: SourceFailure.loggable(error), context: ["address": address])
        phase = .failed(String(format: localized("無法下載模組：%@"), error.localizedDescription))
    }

    // MARK: Writing

    /// Adds or replaces the previewed module.
    func commit() async {
        guard case .preview(let preview) = phase else { return }
        phase = .loading
        do {
            let installed: InstalledRuleModule
            if let replacing = preview.replacing {
                installed = try await library.update(id: replacing.module.id, with: preview.data)
            } else {
                installed = try await library.install(preview.data, from: preview.subscriptionURL)
            }
            phase = .done(installed)
        } catch {
            AppLogger.error("Module not written", error: error, context: ["module": preview.module.id], level: .error)
            phase = .failed((error as? RuleModuleStoreError)?.message ?? error.localizedDescription)
        }
    }
}
