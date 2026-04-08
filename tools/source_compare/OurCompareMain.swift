import Foundation

@main
struct OurCompareMain {
    static func main() throws {
        let htmlPath = CommandLine.arguments.dropFirst().first ?? ""
        let sourcePath = CommandLine.arguments.dropFirst(2).first ?? ""
        let sourceName = CommandLine.arguments.dropFirst(3).first ?? ""

        guard !htmlPath.isEmpty, !sourcePath.isEmpty, !sourceName.isEmpty else {
            fputs("usage: our_compare <htmlPath> <sourcePath> <sourceName>\n", stderr)
            exit(2)
        }

        let html = try String(contentsOfFile: htmlPath, encoding: .utf8)
        let sourceData = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
        let sources = try JSONDecoder().decode([BookSource].self, from: sourceData)

        guard let source = sources.first(where: { $0.bookSourceName == sourceName }) else {
            fputs("source not found: \(sourceName)\n", stderr)
            exit(3)
        }

        let payload = try DefaultWebNovelParserService.shared.parseChapterPayload(
            html: html,
            baseURL: source.bookSourceUrl,
            source: source,
            runtimeVariables: nil
        )
        let nextList = try DefaultWebNovelParserService.shared.extractStringList(
            html: html,
            baseURL: source.bookSourceUrl,
            rule: source.ruleContent.nextContentUrl,
            source: source,
            runtimeVariables: nil,
            isURL: true
        )

        print("SOURCE=\(source.bookSourceName)")
        print("CONTENT_LEN=\(payload.content.count)")
        print("CONTENT_PREVIEW=\(payload.content.prefix(500))")
        print("NEXT_COUNT=\(nextList.count)")
        for item in nextList.prefix(10) {
            print("NEXT=\(item)")
        }
    }
}
