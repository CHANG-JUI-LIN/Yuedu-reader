import re

file_path = "yuedu app/Models/Models.swift"
with open(file_path, "r") as f:
    text = f.read()

old_block = """            // 2. 提取封面圖片（在背景線程完成）
            let coverStart = ProcessInfo.processInfo.systemUptime
            if let coverImage = await EPUBBookService.shared.extractCoverImage(from: destURL) {
                let coverName = "\(uuid)_cover.jpg"
                let coverURL = documentsURL(for: coverName)
                // 將封面轉為 JPEG 儲存（壓縮節省空間）
                if let jpegData = coverImage.jpegData(compressionQuality: 0.85) {
                    do {
                        try jpegData.write(to: coverURL)
                    } catch {
                        Logger(subsystem: "com.yuedu.app", category: "BookStore").error("Failed to write cover image at \(coverURL): \(error)")
                    }
                    coverFilename = coverName
                }
            }
            importTrace(
                "stage=coverExtract done elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - coverStart) * 1000)) hasCover=\(coverFilename != nil)"
            )
            try Task.checkCancellation()

            let metadataStart = ProcessInfo.processInfo.systemUptime
            let session = try? await PublicationSession.open(sourceURL: destURL)
            importTrace(
                "stage=metadataOpen done elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - metadataStart) * 1000)) chapters=\(session?.chapters.count ?? 0)"
            )
            try Task.checkCancellation()"""

new_block = """            // 2. 提取封面與元數據（合併處理以避免重複解析 EPUB ZIP 與 XML）
            let metadataStart = ProcessInfo.processInfo.systemUptime
            let session = try? await PublicationSession.open(sourceURL: destURL)
            importTrace(
                "stage=metadataOpen done elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - metadataStart) * 1000)) chapters=\(session?.chapters.count ?? 0)"
            )
            try Task.checkCancellation()

            let coverStart = ProcessInfo.processInfo.systemUptime
            if let coverResult = await session?.publication.cover(),
               case .success(let coverImage) = coverResult {
                let coverName = "\(uuid)_cover.jpg"
                let coverURL = documentsURL(for: coverName)
                // 將封面轉為 JPEG 儲存（壓縮節省空間）
                if let jpegData = coverImage.jpegData(compressionQuality: 0.85) {
                    do {
                        try jpegData.write(to: coverURL)
                    } catch {
                        Logger(subsystem: "com.yuedu.app", category: "BookStore").error("Failed to write cover image at \(coverURL): \(error)")
                    }
                    coverFilename = coverName
                }
            }
            importTrace(
                "stage=coverExtract done elapsedMs=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - coverStart) * 1000)) hasCover=\(coverFilename != nil)"
            )
            try Task.checkCancellation()"""

if old_block in text:
    text = text.replace(old_block, new_block)
    with open(file_path, "w") as f:
        f.write(text)
    print("Fixed Models.swift double EPUB parsing")
else:
    print("Could not find the block to replace in Models.swift!")

