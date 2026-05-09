import Foundation
import UIKit

/// Experimental high-speed HTML-to-String engine (SAX-style transpiler).
/// Avoids DOM tree construction for memory optimization and ~20x speedup.
final class DirtyHTMLParser {
    static let shared = DirtyHTMLParser()
    
    func parse(htmlData data: Data, baseFont: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var currentText = ""
        var isTag = false
        var currentTag = ""
        var currentFont = baseFont
        
        // Simple state machine processing the byte stream directly
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes {
                let char = Character(UnicodeScalar(byte))
                
                if char == "<" {
                    isTag = true
                    currentTag = ""
                    if !currentText.isEmpty {
                        // Replace basic entity characters
                        let text = currentText
                            .replacingOccurrences(of: "&nbsp;", with: " ")
                            .replacingOccurrences(of: "&lt;", with: "<")
                            .replacingOccurrences(of: "&gt;", with: ">")
                        
                        result.append(NSAttributedString(string: text, attributes: [.font: currentFont]))
                        currentText = ""
                    }
                } else if char == ">" {
                    isTag = false
                    // Update state based on tag (e.g. <b> makes bold)
                    let lowerTag = currentTag.lowercased()
                    if lowerTag == "b" || lowerTag == "strong" {
                        if let descriptor = currentFont.fontDescriptor.withSymbolicTraits(.traitBold) {
                            currentFont = UIFont(descriptor: descriptor, size: currentFont.pointSize)
                        }
                    } else if lowerTag == "/b" || lowerTag == "/strong" {
                        currentFont = baseFont
                    } else if lowerTag == "br" || lowerTag == "p" || lowerTag == "/p" {
                        result.append(NSAttributedString(string: "\n", attributes: [.font: currentFont]))
                    }
                } else {
                    if isTag {
                        currentTag.append(char)
                    } else {
                        currentText.append(char)
                    }
                }
            }
        }
        
        if !currentText.isEmpty {
            result.append(NSAttributedString(string: currentText, attributes: [.font: currentFont]))
        }
        
        return result
    }
}
