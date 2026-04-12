import re

file_path = "yuedu app/Models/PublicationSession.swift"
with open(file_path, "r") as f:
    text = f.read()

old_block = """        let title = publication.metadata.title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let authors = publication.metadata.authors
            .map(\.name)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "、")

        let (obfuscationIdentifier, encryptionAlgorithmsByHref) = await epubEncryptionMetadata(from: sourceURL)

        let session = PublicationSession(
            id: UUID().uuidString.lowercased(),
            sourceURL: sourceURL,
            publication: publication,
            bookTitle: title?.isEmpty == false
                ? title!
                : sourceURL.deletingPathExtension().lastPathComponent,
            author: authors,
            chapters: chapters,"""

new_block = """        let finalTitle: String
        let finalAuthor: String
        if let cachedTitle = cachedTitle, let cachedAuthor = cachedAuthor {
            finalTitle = cachedTitle
            finalAuthor = cachedAuthor
        } else {
            let titleText = publication.metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let authorText = publication.metadata.authors
                .map(\.name)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "、")
            finalTitle = titleText?.isEmpty == false ? titleText! : sourceURL.deletingPathExtension().lastPathComponent
            finalAuthor = authorText
        }

        let (obfuscationIdentifier, encryptionAlgorithmsByHref) = await epubEncryptionMetadata(from: sourceURL)

        let session = PublicationSession(
            id: UUID().uuidString.lowercased(),
            sourceURL: sourceURL,
            publication: publication,
            bookTitle: finalTitle,
            author: finalAuthor,
            chapters: chapters,"""

text = text.replace(old_block, new_block)
with open(file_path, "w") as f:
    f.write(text)
print("done replacing cachedTitle usage")
