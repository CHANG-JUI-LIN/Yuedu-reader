import Foundation

public enum ChapterLoadState: Equatable {
    case idle
    case loading
    case ready
    case failed(reason: String)
}
