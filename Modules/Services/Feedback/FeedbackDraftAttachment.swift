@preconcurrency import AVFoundation
import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// An image or video picked for a report, already prepared for upload: images re-encoded
/// as JPEG at most 2048 px on a side (what the AI 助手 reads, and small on a mobile
/// connection), videos copied out of Photos and, when over 50 MB, exported again at a
/// lower quality. Lives in a temporary file until the report is sent.
struct FeedbackDraftAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let kind: FeedbackAttachment.Kind
    let fileURL: URL
    let contentType: String
    let fileExtension: String
    let bytes: Int
    let pixelSize: CGSize
    let thumbnail: UIImage

    static let maxImageSide: CGFloat = 2048

    // MARK: - Preparing

    /// A screenshot taken in the app (the 截圖後顯示意見回饋入口 path).
    static func image(_ image: UIImage) throws -> FeedbackDraftAttachment {
        let scaled = downscaled(image)
        guard let data = scaled.jpegData(compressionQuality: 0.8) else {
            throw FeedbackService.FeedbackError.attachmentUnreadable
        }
        let url = temporaryURL(extension: "jpg")
        try data.write(to: url)
        return FeedbackDraftAttachment(
            id: UUID(),
            kind: .image,
            fileURL: url,
            contentType: "image/jpeg",
            fileExtension: "jpg",
            bytes: data.count,
            pixelSize: CGSize(width: scaled.size.width * scaled.scale, height: scaled.size.height * scaled.scale),
            thumbnail: thumbnail(of: scaled)
        )
    }

    /// A pick from the system photo picker, which needs no photo-library permission.
    static func prepare(_ item: PhotosPickerItem) async throws -> FeedbackDraftAttachment {
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                throw FeedbackService.FeedbackError.attachmentUnreadable
            }
            return try await video(at: movie.url)
        }
        guard let data = try await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            throw FeedbackService.FeedbackError.attachmentUnreadable
        }
        return try self.image(image)
    }

    private static func video(at url: URL) async throws -> FeedbackDraftAttachment {
        var fileURL = url
        if try fileSize(url) > FeedbackFirestoreSchema.videoByteLimit {
            fileURL = try await exportSmaller(url)
            try FileManager.default.removeItem(at: url)
        }
        let size = try fileSize(fileURL)
        guard size <= FeedbackFirestoreSchema.videoByteLimit else {
            throw FeedbackService.FeedbackError.attachmentTooLarge
        }
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        let frame = try await generator.image(at: .zero).image
        var pixelSize = CGSize.zero
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
            let oriented = natural.applying(transform)
            pixelSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        }
        let ext = fileURL.pathExtension.isEmpty ? "mov" : fileURL.pathExtension.lowercased()
        return FeedbackDraftAttachment(
            id: UUID(),
            kind: .video,
            fileURL: fileURL,
            contentType: UTType(filenameExtension: ext)?.preferredMIMEType ?? "video/quicktime",
            fileExtension: ext,
            bytes: size,
            pixelSize: pixelSize,
            thumbnail: UIImage(cgImage: frame)
        )
    }

    private static func exportSmaller(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
            throw FeedbackService.FeedbackError.attachmentUnreadable
        }
        let output = temporaryURL(extension: "mp4")
        if #available(iOS 18.0, *) {
            try await session.export(to: output, as: .mp4)
        } else {
            session.outputURL = output
            session.outputFileType = .mp4
            await session.export()
            if let error = session.error { throw error }
            guard session.status == .completed else { throw FeedbackService.FeedbackError.attachmentUnreadable }
        }
        return output
    }

    // MARK: - Helpers

    private static func downscaled(_ image: UIImage) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest > maxImageSide else { return image }
        let ratio = maxImageSide / longest
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let target = CGSize(width: (pixelWidth * ratio).rounded(), height: (pixelHeight * ratio).rounded())
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private static func thumbnail(of image: UIImage) -> UIImage {
        image.preparingThumbnail(of: CGSize(width: 400, height: 400)) ?? image
    }

    private static func fileSize(_ url: URL) throws -> Int {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw FeedbackService.FeedbackError.attachmentUnreadable
        }
        return size
    }

    static func temporaryURL(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("feedback-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }

    /// Removes the temporary file once the report is sent or the attachment removed.
    func discard() {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            AppLogger.cache("Feedback attachment temp file could not be removed", error: error)
        }
    }
}

/// A video handed over by the photo picker, copied out of its sandboxed location.
private struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FeedbackDraftAttachment.temporaryURL(extension: ext)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}
