import Foundation
import UIKit

/// Adds speech/media semantics to the existing resolved tree. DOM parsing and
/// source-text construction still have exactly one owner each.
enum BrowserLayoutSemanticContent {
    struct MediaTree {
        let root: ComputedStyleNode
        let attachments: [Int: EPUBMediaAttachment]
        let images: [String: UIImage]
    }

    static func prepareMedia(in root: ComputedStyleNode, renderWidth: CGFloat) -> MediaTree {
        var attachments: [Int: EPUBMediaAttachment] = [:]
        var images: [String: UIImage] = [:]
        func transform(_ node: ComputedStyleNode) -> ComputedStyleNode {
            guard !node.style.isHidden, node.style.display != .none else { return node }
            if node.tag == "video", let element = node.semanticElement {
                let sources = node.children.compactMap { child -> HTMLDOMElementSnapshot? in
                    guard case .element(let source) = child, source.tag == "source" else { return nil }
                    return source.semanticElement
                }
                let direct = element.attribute("src")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let source = direct.isEmpty
                    ? sources.first { !($0.attribute("src") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    : element
                if let source, let href = source.attribute("src"), !href.isEmpty {
                    let media = EPUBMediaAttachment(
                        kind: .video, sourceHref: href,
                        mediaType: source.attribute("type"), title: element.attribute("title"),
                        posterHref: element.attribute("poster")
                    )
                    attachments[node.nodeID] = media
                    // Synthetic image identity only: the real href stays in the
                    // media registry and is resolved by the publication adapter.
                    let key = "browser-video-placeholder:\(node.nodeID)"
                    let width = element.attribute("width").flatMap(Double.init)
                    let height = element.attribute("height").flatMap(Double.init)
                    let intrinsic: CGSize? = width.flatMap { w in
                        height.map { h in CGSize(width: w, height: h) }
                    }
                    images[key] = EPUBMediaPlaceholderRenderer.videoImage(maxWidth: renderWidth, intrinsicSize: intrinsic)
                    var attributes = element.attributes
                    attributes["src"] = key
                    return ComputedStyleNode(
                        tag: "img",
                        semanticElement: HTMLDOMElementSnapshot(
                            semanticPath: element.semanticPath, tagName: "img", namespace: element.namespace,
                            attributes: attributes, svgRenderability: nil
                        ),
                        style: node.style, children: [], nodeID: node.nodeID,
                        linkTarget: node.linkTarget, anchorID: node.anchorID
                    )
                }
            }
            var changed = false
            let children = node.children.map { child -> StyleTreeChild in
                guard case .element(let element) = child else { return child }
                let transformed = transform(element)
                changed = changed || transformed !== element
                return .element(transformed)
            }
            guard changed else { return node }
            return ComputedStyleNode(
                tag: node.tag, semanticElement: node.semanticElement, style: node.style,
                children: children, nodeID: node.nodeID,
                linkTarget: node.linkTarget, anchorID: node.anchorID
            )
        }
        let transformed = transform(root)
        return MediaTree(root: transformed, attachments: attachments, images: images)
    }

    static func pronunciationHints(root: ComputedStyleNode, box: BlockBox, sourceText: String) -> [TTSPronunciationHint] {
        var ipaByNode: [Int: String] = [:]
        func visit(_ node: ComputedStyleNode, inheritedIPA: String?) {
            let alphabet = node.semanticElement?.attribute("ssml:alphabet")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let authored = node.semanticElement?.attribute("ssml:ph")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let ipa = (alphabet == nil || alphabet == "ipa") && authored?.isEmpty == false ? authored : inheritedIPA
            ipaByNode[node.nodeID] = ipa
            for child in node.children {
                if case .element(let element) = child { visit(element, inheritedIPA: ipa) }
            }
        }
        visit(root, inheritedIPA: nil)
        let attributed = ipaByNode.isEmpty ? nil : NSMutableAttributedString(string: sourceText)
        var rubyHints: [TTSPronunciationHint] = []
        func record(_ range: NSRange, nodeID: Int) {
            guard let attributed, range.length > 0, NSMaxRange(range) <= attributed.length,
                  let ipa = ipaByNode[nodeID] else { return }
            attributed.addAttribute(HTMLAttributedStringBuilder.ipaPronunciationAttribute, value: ipa, range: range)
        }
        func walk(_ box: BlockBox) {
            for run in box.inlineRuns {
                if let ruby = run.ruby {
                    for piece in ruby.base { record(piece.sourceRange, nodeID: piece.nodeID) }
                    let reading = ruby.annotation.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !reading.isEmpty {
                        rubyHints.append(TTSPronunciationHint(range: ruby.sourceRange, reading: reading))
                    }
                } else { record(run.sourceRange, nodeID: run.nodeID) }
            }
            for child in box.children { walk(child) }
        }
        walk(box)
        let ipaHints = attributed.map {
            TTSPronunciationAnnotator.hints(in: $0, lexicons: [], bookLanguage: nil)
        } ?? []
        return (ipaHints + rubyHints.filter { ruby in
            !ipaHints.contains { NSIntersectionRange($0.range, ruby.range).length > 0 }
        }).sorted { $0.range.location < $1.range.location }
    }
}
