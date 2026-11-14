import Foundation

/// 閱讀設定's behaviour rows as one value (`ReaderBehaviorSettings`), for 匯出閱讀設定 and
/// its import — the only place they travel together. Each row keeps its own storage;
/// this only reads them out and writes them back.
extension GlobalSettings {
    /// Every row filled in, from the live settings. The touch layouts are the ones the
    /// reader would draw for each reading direction, default included, so an import
    /// reproduces the exporter's grid rather than keeping whatever the receiver had.
    var currentReaderBehaviorSettings: ReaderBehaviorSettings {
        var value = ReaderBehaviorSettings()
        value.textConversion = textConversion.rawValue
        value.usesBookSpacing = readerUsesBookSpacing
        value.spreadMode = readerSpreadMode.rawValue
        value.tapBothSidesNextPage = readerTapBothSidesNextPage
        value.swipeUpToExit = readerSwipeUpToExit
        value.pullDownToBookmark = readerPullDownToBookmark
        value.touchZonesLeftToRight = TouchZoneConfig.load(isRTL: false)
        value.touchZonesRightToLeft = TouchZoneConfig.load(isRTL: true)
        value.followsSystemBrightness = followSystemBrightness
        value.brightness = readerBrightness
        value.keepsScreenAwake = readerKeepsScreenAwake
        return value
    }

    /// Writes every non-nil row, assigning only what differs so an unchanged row does not
    /// stamp a sync clock (閱讀時螢幕常亮 has one). Expects a `sanitized()` value.
    func applyReaderBehaviorSettings(_ behavior: ReaderBehaviorSettings) {
        func assign<Value: Equatable>(_ path: ReferenceWritableKeyPath<GlobalSettings, Value>, _ value: Value?) {
            guard let value, self[keyPath: path] != value else { return }
            self[keyPath: path] = value
        }
        assign(\.textConversion, behavior.textConversion.flatMap(TextConversion.init(rawValue:)))
        assign(\.readerUsesBookSpacing, behavior.usesBookSpacing)
        assign(\.readerSpreadMode, behavior.spreadMode.flatMap(ReaderSpreadMode.init(rawValue:)))
        // The grid before 全局翻頁: saving a grid in the editor turns 全局翻頁 off, and the
        // file's own value for it is what should stand.
        if let zones = behavior.touchZonesLeftToRight, zones != TouchZoneConfig.load(isRTL: false) {
            zones.save(isRTL: false)
        }
        if let zones = behavior.touchZonesRightToLeft, zones != TouchZoneConfig.load(isRTL: true) {
            zones.save(isRTL: true)
        }
        assign(\.readerTapBothSidesNextPage, behavior.tapBothSidesNextPage)
        assign(\.readerSwipeUpToExit, behavior.swipeUpToExit)
        assign(\.readerPullDownToBookmark, behavior.pullDownToBookmark)
        assign(\.followSystemBrightness, behavior.followsSystemBrightness)
        assign(\.readerBrightness, behavior.brightness)
        assign(\.readerKeepsScreenAwake, behavior.keepsScreenAwake)
    }
}
