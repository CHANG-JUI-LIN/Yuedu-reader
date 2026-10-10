import AVFoundation
import Foundation

/// An `AVURLAsset` that sends the given HTTP headers with every request it makes.
///
/// Source media is gated the way source pages are: 起点's 彩蛋 MP4s answer 403 without
/// `Referer: https://m.qidian.com/`, and audiobook CDNs check the source's User-Agent. legado
/// hands the header map to its player for the same reason (`AnalyzeUrl.headerMap`).
///
/// `AVURLAssetHTTPHeaderFieldsKey` is not a published AVFoundation constant, but it is the
/// only way to attach headers to a plain asset short of proxying every byte through a resource
/// loader, and it has been honoured by every iOS release this app supports. It lives here and
/// nowhere else so that, if a release ever stops honouring it, there is one place to change.
enum HeaderedMediaAsset {
    static func make(url: URL, headers: [String: String]) -> AVURLAsset {
        let options: [String: Any] = headers.isEmpty
            ? [:] : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        return AVURLAsset(url: url, options: options)
    }
}
