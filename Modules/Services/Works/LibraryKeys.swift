import Foundation

// The libraries (saved connections, Gutenberg, 青空文庫) wherever they are listed together:
// 範圍, 顯示在最新, 搜尋來源 and the turns 最新's books take. Book sources keep the order their
// own management gives them, after the libraries; the shelf is not a library here. 書庫順序
// (5d-3e) ordered them until the maintainer took it away (2026-10-25: not needed); they are
// listed as they come.

enum LibraryKeys {
    /// Whether a source is one of the libraries.
    static func isLibrary(_ key: SourceInstanceKey) -> Bool {
        switch key.type {
        case .opds, .calibre, .webDAV, .gutenberg, .aozora: true
        case .library, .bibliographic, .bookSource, .module: false
        }
    }

    /// The libraries there are now: saved connections as saved, then Gutenberg and 青空文庫
    /// where they are offered.
    static func available(connections: [RemoteLibraryConnection], librariesAvailable: Bool) -> [SourceInstanceKey] {
        var keys = connections.map { SourceInstanceKey(type: ProviderType($0.kind), id: $0.id) }
        if librariesAvailable {
            keys.append(SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue))
            keys.append(SourceInstanceKey(type: .aozora, id: PublicLibraryID.aozora.rawValue))
        }
        return keys
    }
}
