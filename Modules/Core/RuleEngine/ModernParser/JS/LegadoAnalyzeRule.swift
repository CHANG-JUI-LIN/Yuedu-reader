import Foundation
import JavaScriptCore

/// `io.legado.app.model.analyzeRule.AnalyzeRule()` in a script: a rule reader of the script's
/// own. Kotlin's no-argument constructor makes it with no source and no book, and it reads only
/// the content it is given (`setContent`) or handed per call (`getString(rule, mContent)`):
/// legado-E `AnalyzeRule.kt`, whose class Legado's `RhinoClassShutter` leaves visible.
/// 八叉书库 (YCK1330) reads a page it fetched itself with
/// `AnalyzeRule().setContent(page).getElement(rule)`.
///
/// It is the script's, on the script's queue: the engine it holds is created and read there.
@objc protocol LegadoAnalyzeRuleExport: JSExport {
    /// Legado's `setContent(content, baseUrl = null)`: throws on a null content.
    func setContent(_ content: JSValue, _ baseUrl: JSValue) -> LegadoAnalyzeRule?
    func setBaseUrl(_ baseUrl: JSValue) -> LegadoAnalyzeRule
    func getString(_ ruleStr: JSValue, _ mContent: JSValue, _ isUrl: JSValue) -> String
    func getStringList(_ ruleStr: JSValue, _ mContent: JSValue, _ isUrl: JSValue) -> [String]?
    /// `getElement(rule)`; the polyfill wraps the value as jsoup objects (`__yueduJsoupWrap`).
    func getElement(_ ruleStr: String) -> Any?
    func getElements(_ ruleStr: String) -> Any
}

@objc final class LegadoAnalyzeRule: NSObject, LegadoAnalyzeRuleExport {
    private let engine: ModernRuleEngine
    /// The context's page copies, which the elements this reader hands out live in.
    private let trees: LegadoScriptTrees

    init(engine: ModernRuleEngine, trees: LegadoScriptTrees) {
        self.engine = engine
        self.trees = trees
        super.init()
    }

    func setContent(_ content: JSValue, _ baseUrl: JSValue) -> LegadoAnalyzeRule? {
        guard let input = LegadoJSBridge.ruleInput(from: content) else {
            // Kotlin's `AssertionError`, which the script sees as an exception.
            if let context = JSContext.current() {
                context.exception = JSValue(newErrorFromMessage: "内容不可空（Content cannot be null）", in: context)
            }
            return nil
        }
        // `setBaseUrl(null)` keeps the base it had.
        engine.setContent(input, baseUrl: baseUrl.isString ? baseUrl.toString() : engine.baseUrl)
        return self
    }

    func setBaseUrl(_ baseUrl: JSValue) -> LegadoAnalyzeRule {
        engine.setBaseUrl(baseUrl.isString ? baseUrl.toString() : nil)
        return self
    }

    func getString(_ ruleStr: JSValue, _ mContent: JSValue, _ isUrl: JSValue) -> String {
        engine.getString(
            ruleStr: Self.rule(ruleStr), mContent: LegadoJSBridge.ruleInput(from: mContent),
            isUrl: isUrl.isBoolean && isUrl.toBool()
        )
    }

    func getStringList(_ ruleStr: JSValue, _ mContent: JSValue, _ isUrl: JSValue) -> [String]? {
        engine.getStringList(
            ruleStr: Self.rule(ruleStr), mContent: LegadoJSBridge.ruleInput(from: mContent),
            isUrl: isUrl.isBoolean && isUrl.toBool()
        )
    }

    func getElement(_ ruleStr: String) -> Any? {
        engine.scriptElement(ruleStr: ruleStr).map { LegadoJsoupElement.bridged($0, trees: trees) }
    }

    func getElements(_ ruleStr: String) -> Any {
        LegadoJsoupElement.bridged(engine.scriptElements(ruleStr: ruleStr), trees: trees)
    }

    /// A rule argument as Legado's `String?` reads it: `null` is no rule.
    private static func rule(_ value: JSValue) -> String? {
        value.isUndefined || value.isNull ? nil : value.toString()
    }
}
