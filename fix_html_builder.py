import re

file_path = "yuedu app/Models/CoreText/HTMLAttributedStringBuilder.swift"
with open(file_path, "r") as f:
    code = f.read()

# 1. normalizeWhitespace
code = re.sub(
    r'private func normalizeWhitespace\(_ text: String\) -> String \{[\s\S]*?return collapsed\.replacingOccurrences\(of: "\\u\{00A0\}", with: " "\)\n\s*\}',
    r'''private func normalizeWhitespace(_ text: String) -> String {
    let collapsed = text.replacingOccurrences(of: "[ \\n\\r\\t\\u{000C}]+", with: " ", options: .regularExpression)
    return collapsed.replacingOccurrences(of: "\\u{00A0}", with: " ")
}''',
    code
)

# 2. appendSegment
code = code.replace(
    '''        func appendSegment(isLast: Bool) {
            guard segment.length > 0 else { return }
            
            let segmentStyle''',
    '''        func appendSegment(isLast: Bool) {
            guard segment.length > 0 else { return }

            let trimCharSet = CharacterSet(charactersIn: " \\n\\r\\t\\u{000C}")
            while segment.length > 0, let first = segment.string.unicodeScalars.first, trimCharSet.contains(first) {
                segment.deleteCharacters(in: NSRange(location: 0, length: 1))
            }
            while segment.length > 0, let last = segment.string.unicodeScalars.last, trimCharSet.contains(last) {
                segment.deleteCharacters(in: NSRange(location: segment.length - 1, length: 1))
            }

            guard segment.length > 0 else { return }
            
            let segmentStyle'''
)

with open(file_path, "w") as f:
    f.write(code)

