import AVFoundation
import Foundation
import UniformTypeIdentifiers
import os.log

/// AVPlayer refuses to open 番茄畅听-style audiobook URLs. Their path carries no
/// file extension (e.g. `https://…fqnovelvod.com/…/video/tos/cn/…/?…&mime_type=audio_mpeg`)
/// and the VOD CDN answers with a `Content-Type` AVFoundation does not treat as
/// playable audio, so it fails the item with `AVErrorFileFormatNotRecognized`
/// ("無法打開") before a single byte is decoded — even though the bytes are a valid
/// MP3 stream. Android's ExoPlayer sniffs the container and plays it fine; iOS does
/// not, so we have to tell AVFoundation the type out-of-band.
///
/// This `AVAssetResourceLoaderDelegate` routes the asset through a custom scheme,
/// declares the real MIME type up front via the content-information request, and
/// proxies the actual byte-range reads to the origin over `URLSession` (forwarding
/// the source headers). Only extension-less / non-audio-extension URLs are routed
/// here; ordinary `.mp3`/`.m4a` links keep the plain `AVURLAsset` fast path.
final class AudioStreamResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private static let schemePrefix = "fqaudio-"
    private static var associatedKey: UInt8 = 0

    private let originURL: URL
    private let headers: [String: String]
    private let contentUTI: String
    private let queue = DispatchQueue(label: "com.yuedu.audio.resourceloader")
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]

    private init(originURL: URL, headers: [String: String], contentUTI: String) {
        self.originURL = originURL
        self.headers = headers
        self.contentUTI = contentUTI
    }

    /// True when AVPlayer cannot infer the format on its own (no usable audio file
    /// extension), so the URL must be routed through the resource loader.
    static func requiresLoader(for url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let knownAudioExtensions: Set<String> = [
            "aac", "aiff", "aif", "flac", "m4a", "m4b", "mp3", "oga", "ogg", "opus", "wav",
        ]
        return !knownAudioExtensions.contains(ext)
    }

    /// Build an `AVURLAsset` whose loads are intercepted by a retained loader that
    /// forces the correct MIME type. Returns `nil` if the URL cannot be rewritten,
    /// so the caller can fall back to a plain asset.
    static func makeAsset(url: URL, headers: [String: String]) -> AVURLAsset? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let originScheme = components.scheme
        else { return nil }

        components.scheme = schemePrefix + originScheme
        guard let customURL = components.url else { return nil }

        let loader = AudioStreamResourceLoader(
            originURL: url,
            headers: headers,
            contentUTI: inferredContentUTI(for: url)
        )
        let asset = AVURLAsset(url: customURL, options: nil)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        // `setDelegate` holds the delegate weakly; pin the loader's lifetime to the
        // asset so it survives as long as playback needs it.
        objc_setAssociatedObject(asset, &associatedKey, loader, .OBJC_ASSOCIATION_RETAIN)
        return asset
    }

    /// Map the `mime_type=` query (or a fallback) onto a UTI AVFoundation accepts.
    private static func inferredContentUTI(for url: URL) -> String {
        let query = url.query?.lowercased() ?? ""
        let mime: String
        if query.contains("mime_type=audio_mpeg") || query.contains("mime=audio/mpeg") {
            mime = "audio/mpeg"
        } else if query.contains("aac") {
            mime = "audio/aac"
        } else if query.contains("mp4") || query.contains("m4a") {
            mime = "audio/mp4"
        } else {
            mime = "audio/mpeg"
        }
        return UTType(mimeType: mime)?.identifier ?? UTType.mp3.identifier
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        var request = URLRequest(url: originURL)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let dataRequest = loadingRequest.dataRequest {
            let start = dataRequest.requestedOffset
            if dataRequest.requestsAllDataToEndOfResource {
                request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range")
            } else {
                let end = start + Int64(dataRequest.requestedLength) - 1
                request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            }
        } else {
            // Content-info-only probe: fetch a single byte, not the whole file.
            request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        }

        let key = ObjectIdentifier(loadingRequest)
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async { self.tasks[key] = nil }

            if let error {
                loadingRequest.finishLoading(with: error)
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                audiobookLog("resourceLoader origin bad status=\(status)")
                loadingRequest.finishLoading(with: URLError(.badServerResponse))
                return
            }

            if let info = loadingRequest.contentInformationRequest {
                info.contentType = self.contentUTI
                info.isByteRangeAccessSupported = true
                info.contentLength = self.totalLength(from: http) ?? Int64(data?.count ?? 0)
            }
            if let data, let dataRequest = loadingRequest.dataRequest {
                dataRequest.respond(with: data)
            }
            loadingRequest.finishLoading()
        }

        queue.async { self.tasks[key] = task }
        task.resume()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let key = ObjectIdentifier(loadingRequest)
        queue.async {
            self.tasks[key]?.cancel()
            self.tasks[key] = nil
        }
    }

    /// Parse the total resource size from a `Content-Range: bytes a-b/total` header.
    /// Falls back to `nil` when the origin answered `200` without range support.
    private func totalLength(from response: HTTPURLResponse) -> Int64? {
        guard let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
              let slash = contentRange.lastIndex(of: "/")
        else { return nil }
        let totalString = contentRange[contentRange.index(after: slash)...]
        return Int64(totalString.trimmingCharacters(in: .whitespaces))
    }
}
