import Foundation
import UIKit

/// Decides what bytes an imported image is stored as, and under which extension.
///
/// One rule for every image store (頁面背景 / 啟動圖 / 閱讀背景) because the two
/// import sources disagree about what they hand over: a Files pick names its
/// format in the path extension, while a photo-library pick is raw bytes that
/// are very often HEIC — a container none of the stores list as supported and
/// whose extension would then not match the file it was written into. Keeping
/// PNG and JPEG byte-for-byte avoids a needless re-encode of the common cases.
enum ImportedImageNormalizer {
    struct Output {
        let data: Data
        let fileExtension: String
    }

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
    private static let jpegSignature: [UInt8] = [0xFF, 0xD8, 0xFF]

    static func isPNG(_ data: Data) -> Bool { data.starts(with: pngSignature) }
    static func isJPEG(_ data: Data) -> Bool { data.starts(with: jpegSignature) }

    /// - Parameters:
    ///   - image: the already-decoded image, used only to re-encode when needed.
    ///   - fallbackExtension: the source file's extension for a Files pick;
    ///     stores pass a placeholder for photo-library data.
    ///   - allowedExtensions: the store's supported set, so a format it does
    ///     accept (WebP) survives untouched.
    /// - Returns: nil only when the data can't be re-encoded at all.
    static func normalize(
        image: UIImage,
        data: Data,
        fallbackExtension: String,
        allowedExtensions: Set<String>
    ) -> Output? {
        if isPNG(data) {
            return Output(data: data, fileExtension: "png")
        }
        if isJPEG(data) {
            return Output(data: data, fileExtension: "jpg")
        }
        let lowered = fallbackExtension.lowercased()
        if allowedExtensions.contains(lowered), !lowered.isEmpty {
            return Output(data: data, fileExtension: lowered)
        }
        // HEIC and friends: re-encode so the extension describes the bytes.
        guard let jpeg = image.jpegData(compressionQuality: 0.9) else { return nil }
        return Output(data: jpeg, fileExtension: "jpg")
    }

    /// Re-encodes a resized image, keeping PNG only when the source was PNG
    /// (transparency) — otherwise JPEG, which is far smaller for photographs.
    static func encode(resized image: UIImage, preservingPNG sourceWasPNG: Bool) -> Output? {
        if sourceWasPNG, let png = image.pngData() {
            return Output(data: png, fileExtension: "png")
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.9) else { return nil }
        return Output(data: jpeg, fileExtension: "jpg")
    }
}
