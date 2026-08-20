import UIKit

/// Publishes book covers into the shared app-group container so the download Live Activity can
/// draw them.
///
/// The activity's UI runs inside the widget extension. It cannot read
/// `Application Support/Covers` — that is the app's own container — and it cannot be handed the
/// bytes through `ContentState` either, because the whole payload has only a few kilobytes of
/// budget. So one downsampled JPEG per downloading book crosses into the shared container and
/// the state carries nothing but its file name.
///
/// Reading the source cover goes through `BookCoverLoader.localImage`, the single reader of the
/// on-disk cover, so the `Covers` / `CustomCovers` routing stays in one place.
enum DownloadActivityCoverStore {

    /// Small on purpose. The activity draws this at roughly 44pt, and every byte is written on
    /// a download's progress path — the one place that must not get expensive.
    private static let maxPixelSize: CGFloat = 180

    /// Makes `bookId`'s cover readable by the widget and returns its file name.
    ///
    /// Idempotent and cheap to call repeatedly: an already-published thumbnail is left alone,
    /// so the common case (progress ticking on a book whose cover was published when the
    /// download started) costs one `fileExists` check.
    @discardableResult
    static func publish(bookId: UUID, coverImagePath: String?) -> String? {
        guard let directory = DownloadActivityAttributes.coverDirectory() else { return nil }
        let filename = "\(bookId.uuidString).jpg"
        let destination = directory.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: destination.path) { return filename }
        guard let image = BookCoverLoader.localImage(filename: coverImagePath) else { return nil }
        guard let data = downsampledJPEG(from: image) else { return nil }

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            return filename
        } catch {
            // A cover the activity cannot draw is a missing thumbnail, not a failed download.
            AppLogger.cache("⟐ download activity cover publish failed", error: error, context: [
                "bookId": bookId.uuidString,
            ])
            return nil
        }
    }

    /// Which of these books already have a usable thumbnail. A file-existence check only —
    /// safe to call on the download's progress path, unlike `publish`.
    static func publishedFilenames(for bookIds: [UUID]) -> [String: String] {
        guard let directory = DownloadActivityAttributes.coverDirectory() else { return [:] }
        var result: [String: String] = [:]
        for bookId in bookIds {
            let filename = "\(bookId.uuidString).jpg"
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(filename).path
            ) {
                result[bookId.uuidString] = filename
            }
        }
        return result
    }

    /// Drops thumbnails for books that are no longer in the activity.
    ///
    /// Without this the directory grows once per book ever downloaded. It is safe to run on
    /// every refresh: the files are rewritten on demand by `publish`.
    static func prune(keeping filenames: Set<String>) {
        guard let directory = DownloadActivityAttributes.coverDirectory(),
              let existing = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
              )
        else { return }
        for url in existing where !filenames.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func downsampledJPEG(from image: UIImage) -> Data? {
        let longestSide = max(image.size.width, image.size.height)
        guard longestSide > 0 else { return nil }
        guard longestSide > maxPixelSize else { return image.jpegData(compressionQuality: 0.8) }

        let scale = maxPixelSize / longestSide
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: 0.8)
    }
}
