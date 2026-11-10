import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import org.jsoup.Jsoup;
import org.jsoup.nodes.Document;
import org.mozilla.javascript.Context;
import org.mozilla.javascript.ContextFactory;
import org.mozilla.javascript.ImporterTopLevel;
import org.mozilla.javascript.NativeArray;
import org.mozilla.javascript.RhinoException;
import org.mozilla.javascript.ScriptRuntime;
import org.mozilla.javascript.Scriptable;
import org.mozilla.javascript.ScriptableObject;
import org.mozilla.javascript.Undefined;
import org.mozilla.javascript.Wrapper;

/**
 * What Legado's Rhino does with an expression: the expected value for a bridge fix.
 *
 * Usage (through `lc.py oracle CASES.json`): java -cp rhino-1.8.1.jar:jsoup-1.16.2.jar:. Oracle CASES.json
 *
 * The context is set up as legado-E's `RhinoScriptEngine` sets up its own (2026-08 checkout):
 * Rhino 1.8.1, VERSION_ES6, interpreted mode, FEATURE_ENABLE_JAVA_MAP_ACCESS, the default
 * WrapFactory (so a Java String returned by a Java method arrives wrapped, as in Legado), and
 * jsoup 1.16.2, the version Legado pins.
 *
 * It answers one question: what do Rhino and jsoup do with this expression. It has none of
 * Legado's own bindings. `java` here is Rhino's Java package, not JsExtensions: `java.ajax`,
 * `source`, `book`, `cookie` and `cache` do not exist. Give it the smallest expression that
 * shows the behaviour, never a whole source script, and never JavaScript downloaded from a
 * site.
 *
 * A case: {"name": "...", "js": "...", "html": "...", "baseUri": "...", "result": {...}}
 *   html     optional; parsed with Jsoup.parse(html, baseUri) and bound as `doc`
 *   result   optional binding for `result`, as Legado's rules see it:
 *            {"select": "css"}       doc.select(css)        (jsoup Elements)
 *            {"selectFirst": "css"}  doc.selectFirst(css)   (jsoup Element)
 *            {"string": "text"}      a JavaScript string    (Legado binds strings unwrapped)
 *            {"javaString": "text"}  a wrapped java.lang.String, as a Java method returns one
 * Output: one JSON object per case: name, typeof, javaClass, value, error.
 */
public final class Oracle {
    private static final long CASE_LIMIT_NANOS = 5_000_000_000L;
    private static long deadline;

    private static final class LegadoContextFactory extends ContextFactory {
        @Override
        protected Context makeContext() {
            Context cx = super.makeContext();
            cx.setLanguageVersion(Context.VERSION_ES6);
            cx.setInterpretedMode(true);
            cx.setInstructionObserverThreshold(10000);
            cx.setMaximumInterpreterStackDepth(1000);
            return cx;
        }

        @Override
        protected boolean hasFeature(Context cx, int featureIndex) {
            if (featureIndex == Context.FEATURE_ENABLE_JAVA_MAP_ACCESS) {
                return true;
            }
            return super.hasFeature(cx, featureIndex);
        }

        @Override
        protected void observeInstructionCount(Context cx, int instructionCount) {
            if (System.nanoTime() > deadline) {
                throw new Error("oracle: the case ran longer than 5 s");
            }
        }
    }

    public static void main(String[] args) throws Exception {
        String text = Files.readString(Path.of(args[0]), StandardCharsets.UTF_8);
        Context cx = new LegadoContextFactory().enterContext();
        try {
            ScriptableObject reader = cx.initStandardObjects();
            reader.put("__text", reader, text);
            deadline = System.nanoTime() + CASE_LIMIT_NANOS;
            Object parsed = cx.evaluateString(reader, "JSON.parse(__text)", "cases", 1, null);
            List<?> cases = (NativeArray) parsed;
            StringBuilder out = new StringBuilder("[\n");
            for (int i = 0; i < cases.size(); i++) {
                Map<?, ?> testCase = (Map<?, ?>) cases.get(i);
                out.append(i == 0 ? "" : ",\n").append(run(cx, testCase));
            }
            System.out.println(out.append("\n]"));
        } finally {
            Context.exit();
        }
    }

    private static String run(Context cx, Map<?, ?> testCase) {
        String name = string(testCase.get("name"), "?");
        StringBuilder row = new StringBuilder("{\"name\": ").append(quote(name));
        try {
            // Legado's top level is an ImporterTopLevel (`RhinoTopLevel`): importPackage,
            // importClass and JavaImporter exist.
            ScriptableObject scope = new ImporterTopLevel(cx);
            Document doc = null;
            if (testCase.get("html") instanceof CharSequence html) {
                doc = Jsoup.parse(html.toString(), string(testCase.get("baseUri"), ""));
                ScriptableObject.putProperty(scope, "doc", Context.javaToJS(doc, scope));
            }
            if (testCase.get("result") instanceof Map<?, ?> result) {
                ScriptableObject.putProperty(scope, "result", bindResult(cx, scope, doc, result));
            }
            deadline = System.nanoTime() + CASE_LIMIT_NANOS;
            Object value = cx.evaluateString(scope, string(testCase.get("js"), ""), name, 1, null);
            row.append(", \"typeof\": ").append(quote(ScriptRuntime.typeof(value)));
            Object plain = value instanceof Wrapper wrapper ? wrapper.unwrap() : value;
            if (plain != null && !(plain instanceof Scriptable) && plain != Undefined.instance) {
                row.append(", \"javaClass\": ").append(quote(plain.getClass().getName()));
            }
            row.append(", \"value\": ").append(quote(display(cx, scope, value)));
        } catch (RhinoException error) {
            row.append(", \"error\": ").append(quote(error.getClass().getSimpleName() + ": " + error.details()));
        } catch (RuntimeException | Error error) {
            row.append(", \"error\": ").append(quote(error.getClass().getName() + ": " + error.getMessage()));
        }
        return row.append("}").toString();
    }

    private static Object bindResult(Context cx, Scriptable scope, Document doc, Map<?, ?> spec) {
        if (spec.get("string") instanceof CharSequence value) {
            return value.toString();
        }
        if (spec.get("javaString") instanceof CharSequence value) {
            return cx.getWrapFactory().wrap(cx, scope, value.toString(), null);
        }
        if (doc == null) {
            throw new IllegalArgumentException("result.select and result.selectFirst need html");
        }
        if (spec.get("select") instanceof CharSequence css) {
            return Context.javaToJS(doc.select(css.toString()), scope);
        }
        if (spec.get("selectFirst") instanceof CharSequence css) {
            return Context.javaToJS(doc.selectFirst(css.toString()), scope);
        }
        throw new IllegalArgumentException("result needs one of string, javaString, select, selectFirst");
    }

    /** JSON for JavaScript values, toString() for Java objects (jsoup Elements print outerHtml). */
    private static String display(Context cx, Scriptable scope, Object value) {
        if (value == null) {
            return "null";
        }
        if (value == Undefined.instance) {
            return "undefined";
        }
        if (value instanceof Wrapper wrapper) {
            return String.valueOf(wrapper.unwrap());
        }
        if (value instanceof Scriptable) {
            try {
                ScriptableObject.putProperty(scope, "__value", value);
                return Context.toString(cx.evaluateString(scope, "JSON.stringify(__value)", "display", 1, null));
            } catch (RhinoException error) {
                return Context.toString(value);
            }
        }
        return Context.toString(value);
    }

    private static String string(Object value, String fallback) {
        return value instanceof CharSequence text ? text.toString() : fallback;
    }

    private static String quote(String text) {
        StringBuilder out = new StringBuilder("\"");
        for (char c : text.toCharArray()) {
            switch (c) {
                case '"' -> out.append("\\\"");
                case '\\' -> out.append("\\\\");
                case '\n' -> out.append("\\n");
                case '\r' -> out.append("\\r");
                case '\t' -> out.append("\\t");
                default -> {
                    if (c < 0x20) {
                        out.append(String.format("\\u%04x", (int) c));
                    } else {
                        out.append(c);
                    }
                }
            }
        }
        return out.append('"').toString();
    }
}
