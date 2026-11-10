import Foundation

extension URLSession {
    /// For downloads whose bytes the app writes to a store of its own as they arrive: an
    /// offline chapter's pages and illustrations (`OfflineChapterStore`) and network covers
    /// (`CoverImagePipeline`'s NetworkCovers directory).
    ///
    /// `URLSession.shared` writes every cacheable response into `URLCache.shared`'s Cache.db
    /// as well, so each of those bytes went to disk twice. MetricKit counted 1 GB of writes in
    /// a day from `__CFURLCache::CreateAndStoreCacheNode` on 3.0.0 (143), a build whose source
    /// requests already ran without a URL cache (`WebFetcher.defaultSessionConfiguration`,
    /// `LegadoJSBridge.requestSession`) — Crashlytics a3bab04b.
    ///
    /// Cookies are the shared store's, as on `URLSession.shared`: an image CDN that sets a
    /// cookie on the chapter page still gets it back.
    static let savedDownloads: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        // Source sites' pages and pictures: capped at TLS 1.2 (`ServerTrustPolicy.capAtTLS12`).
        return URLSession.sourceSites(configuration)
    }()
}
