/**
 * 書源解析引擎 - JavaScript 實作（對齊 Legado）
 * 可在瀏覽器與 iOS WKWebView 共用，不依賴 Swift/CSS 端邏輯。
 * 使用 DOMParser + querySelector / XPath / 正則 / 簡易 JSONPath。
 */
(function (global) {
  'use strict';
  function trim(s) { return (s || '').trim(); }
  function isJson(str) {
    const t = trim(str);
    return t.startsWith('{') || t.startsWith('[');
  }

  function resolveURL(raw, base) {
    const s = trim(raw);
    if (!s) return '';
    const optionMatch = s.match(/,\s*(\{[\s\S]*\}|%7B[\s\S]*%7D)\s*$/i);
    const optionSuffix = optionMatch ? s.slice(optionMatch.index) : '';
    const urlPart = optionMatch ? trim(s.slice(0, optionMatch.index)) : s;
    if (!urlPart) return s;
    if (/^https?:\/\//i.test(urlPart)) return urlPart + optionSuffix;
    try {
      if (urlPart.startsWith('//')) return (new URL(base).protocol || 'https:') + urlPart + optionSuffix;
      if (urlPart.startsWith('/')) {
        const u = new URL(base);
        return u.origin + urlPart + optionSuffix;
      }
      return new URL(urlPart, base).href + optionSuffix;
    } catch (_) { return s; }
  }

  function parseHTML(html) {
    if (typeof html !== 'string') return null;
    const parser = new DOMParser();
    return parser.parseFromString(html, 'text/html');
  }

  function splitRuleAndRegex(rule) {
    const parts = trim(rule).split('##');
    const main = trim(parts[0] || '');
    const regexParts = parts.slice(1).map(p => trim(p)).filter(Boolean);
    return { main, regexParts };
  }

  function splitSelectorAndAttr(s) {
    const lastAt = s.lastIndexOf('@');
    if (lastAt === -1) return { selector: trim(s), attr: 'text' };
    return {
      selector: trim(s.slice(0, lastAt)),
      attr: trim(s.slice(lastAt + 1)).toLowerCase() || 'text'
    };
  }

  /** 預處理 Legado 選擇器，轉為可安全傳給 querySelector 的形式，或回傳需手動處理的資訊 */
  function preprocessLegadoSelector(sel) {
    let s = trim(sel);
    if (!s) return { type: 'skip' };
    if (/^\{\{.*\}\}$/.test(s)) return { type: 'template', raw: s };
    const jsMatch = s.match(/^<js>[\s\S]*?<\/js>\s*(.*)$/i);
    if (jsMatch) s = trim(jsMatch[1] || '');
    if (!s) return { type: 'skip' };
    const eqMatch = s.match(/^(.+?):eq\((-?\d+)\)$/);
    if (eqMatch) return { type: 'eq', base: trim(eqMatch[1]), index: parseInt(eqMatch[2], 10) };
    const exclMatch = s.match(/^(.+?)!(-?\d+)(?::(-?\d+))?$/);
    if (exclMatch) return { type: 'exclude', base: trim(exclMatch[1]), excludeIndices: [parseInt(exclMatch[2], 10)] };
    const arrExclMatch = s.match(/^(.+?)\[!([^\]]*)\]$/);
    if (arrExclMatch) {
      const indices = arrExclMatch[2].split(/[,:]/).map(x => parseInt(trim(x), 10)).filter(n => !isNaN(n));
      return { type: 'exclude', base: trim(arrExclMatch[1]), excludeIndices: indices };
    }
    return { type: 'css', selector: s };
  }

  function safeQuerySelectorAll(root, selector) {
    if (!root || !selector) return [];
    const pre = preprocessLegadoSelector(selector);
    if (pre.type === 'skip' || pre.type === 'template') return [];
    if (pre.type === 'eq') {
      try {
        const list = Array.from(root.querySelectorAll ? root.querySelectorAll(pre.base) : []);
        const i = pre.index < 0 ? list.length + pre.index : pre.index;
        return i >= 0 && i < list.length ? [list[i]] : [];
      } catch (_) { return []; }
    }
    if (pre.type === 'exclude') {
      try {
        const list = Array.from(root.querySelectorAll ? root.querySelectorAll(pre.base) : []);
        const excl = new Set((pre.excludeIndices || []).map(n => n < 0 ? list.length + n : n));
        return list.filter((_, i) => !excl.has(i));
      } catch (_) { return []; }
    }
    try {
      return Array.from(root.querySelectorAll(pre.selector));
    } catch (_) {
      return [];
    }
  }

  function safeQuerySelector(root, selector) {
    const list = safeQuerySelectorAll(root, selector);
    return list.length ? list[0] : null;
  }

  function applyRegex(text, parts) {
    if (!parts || parts.length === 0) return text;
    const pattern = parts[0];
    if (!pattern) return text;
    try {
      const regex = new RegExp(pattern, 'g');
      if (parts.length >= 2) {
        return text.replace(regex, parts[1]);
      }
      const m = text.match(new RegExp(pattern));
      if (m) return (m[1] !== undefined ? m[1] : m[0]) || '';
      return '';
    } catch (_) { return text; }
  }

  function cleanText(text) {
    return (text || '').replace(/\r/g, '').split('\n')
      .map(l => l.trim()).filter(Boolean).join('\n');
  }

  function asBool(value) {
    if (typeof value === 'boolean') return value;
    if (typeof value === 'number') return value !== 0;
    const s = trim(String(value || '')).toLowerCase();
    if (!s) return false;
    return ['true', '1', 'yes', 'y', 'vip', 'pay', 'volume'].includes(s);
  }

  function ensureRuntimeContext(seed) {
    if (seed && typeof seed === 'object' && !Array.isArray(seed)) {
      if (seed.vars && typeof seed.vars === 'object') {
        return { vars: Object.assign(Object.create(null), seed.vars) };
      }
      return { vars: Object.assign(Object.create(null), seed) };
    }
    return { vars: Object.create(null) };
  }

  function cloneRuntimeVariables(runtimeContext) {
    return Object.assign({}, runtimeContext && runtimeContext.vars || {});
  }

  function getRuntimeValue(runtimeContext, key) {
    if (!runtimeContext || !runtimeContext.vars) return '';
    const normalizedKey = trim(String(key || ''));
    if (!normalizedKey) return '';
    const value = runtimeContext.vars[normalizedKey];
    return value == null ? '' : String(value);
  }

  function setRuntimeValue(runtimeContext, key, value) {
    if (!runtimeContext || !runtimeContext.vars) return '';
    const normalizedKey = trim(String(key || ''));
    if (!normalizedKey) return '';
    const normalizedValue = value == null ? '' : String(value);
    runtimeContext.vars[normalizedKey] = normalizedValue;
    return normalizedValue;
  }

  function substituteRuntimeGets(text, runtimeContext) {
    if (typeof text !== 'string' || !text) return text;
    return text.replace(/@get:\{([^{}]+)\}/g, function (_, key) {
      return getRuntimeValue(runtimeContext, key);
    });
  }

  function splitTopLevel(text, delimiter) {
    const out = [];
    let current = '';
    let quote = '';
    let depthBrace = 0;
    let depthBracket = 0;
    let depthParen = 0;
    const src = String(text || '');
    for (let i = 0; i < src.length; i++) {
      const ch = src[i];
      const prev = i > 0 ? src[i - 1] : '';
      if (quote) {
        current += ch;
        if (ch === quote && prev !== '\\') quote = '';
        continue;
      }
      if (ch === '"' || ch === "'") {
        quote = ch;
        current += ch;
        continue;
      }
      if (ch === '{') depthBrace++;
      else if (ch === '}') depthBrace = Math.max(0, depthBrace - 1);
      else if (ch === '[') depthBracket++;
      else if (ch === ']') depthBracket = Math.max(0, depthBracket - 1);
      else if (ch === '(') depthParen++;
      else if (ch === ')') depthParen = Math.max(0, depthParen - 1);
      if (ch === delimiter && depthBrace === 0 && depthBracket === 0 && depthParen === 0) {
        out.push(current);
        current = '';
        continue;
      }
      current += ch;
    }
    out.push(current);
    return out;
  }

  function unquoteString(text) {
    const value = trim(String(text || ''));
    if (value.length >= 2) {
      const first = value[0];
      const last = value[value.length - 1];
      if ((first === '"' || first === "'") && first === last) {
        return value.slice(1, -1).replace(/\\(["'])/g, '$1');
      }
    }
    return value;
  }

  function splitTrailingPutDirective(rule) {
    const src = trim(String(rule || ''));
    if (!src) return { main: '', putSpec: '' };
    let quote = '';
    let depth = 0;
    let putIndex = -1;
    for (let i = 0; i < src.length; i++) {
      const ch = src[i];
      const prev = i > 0 ? src[i - 1] : '';
      if (quote) {
        if (ch === quote && prev !== '\\') quote = '';
        continue;
      }
      if (ch === '"' || ch === "'") {
        quote = ch;
        continue;
      }
      if (ch === '{') depth++;
      else if (ch === '}') depth = Math.max(0, depth - 1);
      if (depth === 0 && src.slice(i).startsWith('@put:{')) putIndex = i;
    }
    if (putIndex === -1) return { main: src, putSpec: '' };
    return {
      main: trim(src.slice(0, putIndex)),
      putSpec: trim(src.slice(putIndex + 5))
    };
  }

  function evalUserScript(script, scope) {
    const code = trim(script);
    if (!code) return scope && scope.result;
    const ctx = Object.assign({ result: '' }, scope || {});
    try {
      const keys = Object.keys(ctx);
      const values = keys.map(k => ctx[k]);
      const fn = new Function(...keys, `
        "use strict";
        var __out = result;
        ${code}
        return typeof result === "undefined" ? __out : result;
      `);
      return fn(...values);
    } catch (_) {
      return ctx.result;
    }
  }

  function splitRulePipeline(rule) {
    let raw = String(rule || '');
    const scripts = [];
    raw = raw.replace(/<js>([\s\S]*?)<\/js>/ig, function (_, code) {
      scripts.push(trim(code));
      return '';
    });
    const baseLines = [];
    raw.split(/\r?\n/).forEach(function (line) {
      const text = trim(line);
      if (!text) return;
      if (/^@js:/i.test(text)) {
        scripts.push(trim(text.slice(4)));
        return;
      }
      const inlineJs = text.match(/^(.*)@js:([\s\S]*)$/i);
      if (inlineJs) {
        const head = trim(inlineJs[1]);
        const tail = trim(inlineJs[2]);
        if (head) baseLines.push(head);
        if (tail) scripts.push(tail);
        return;
      }
      baseLines.push(text);
    });
    return { main: trim(baseLines.join('\n')), scripts: scripts.filter(Boolean) };
  }

  function extractObjectPathValue(obj, rawPath, runtimeContext, baseURL) {
    const path = trim(rawPath || '');
    if (!path) return '';
    if (/^@get:\{/.test(path)) return getRuntimeValue(runtimeContext, path.slice(6, -1));
    if (/^@json:/i.test(path) || /^\$\./.test(path) || /^\$\[/.test(path)) {
      return extractValueByJson(obj, path.replace(/^@json:/i, ''), '');
    }
    const val = jsonPathGet(obj, path);
    if (val == null) return '';
    return typeof val === 'string' ? val : JSON.stringify(val);
  }

  function evaluateTemplateExpression(expr, scope) {
    const raw = substituteRuntimeGets(trim(expr || ''), scope && scope.runtimeContext);
    if (!raw) return '';
    if ((raw.startsWith('"') && raw.endsWith('"')) || (raw.startsWith("'") && raw.endsWith("'"))) {
      return unquoteString(raw);
    }
    const looksLikeScript =
      raw.includes('java.') ||
      raw.includes('=') ||
      raw.includes('?') ||
      raw.includes('(') ||
      raw.includes(';');
    if (!looksLikeScript) {
      return extractObjectPathValue(scope && scope.currentObject, raw, scope && scope.runtimeContext, scope && scope.baseUrl);
    }
    const localScope = Object.assign({}, scope || {}, { result: '' });
    if (!localScope.runtimeContext) localScope.runtimeContext = ensureRuntimeContext();
    if (!localScope.java) localScope.java = createJavaShim(localScope);
    const out = evalUserScript('result = (function(){ return (' + raw + '); })();', localScope);
    return out == null ? '' : String(out);
  }

  function renderObjectTemplates(text, obj, runtimeContext, baseURL) {
    if (!obj || typeof text !== 'string') return text;
    return text.replace(/\{\{([^{}]+)\}\}|\{(\$[^{}]+)\}/g, function (_, a, b) {
      const expr = trim(a || b || '');
      if (!expr) return '';
      if (expr.includes('||')) {
        const alts = expr.split('||').map(s => trim(s)).filter(Boolean);
        for (const alt of alts) {
          const v = trim(evaluateTemplateExpression(alt, {
            currentObject: obj,
            runtimeContext: runtimeContext,
            baseUrl: baseURL,
            sourceContent: obj
          }));
          if (v) return v;
        }
        return '';
      }
      return evaluateTemplateExpression(expr, {
        currentObject: obj,
        runtimeContext: runtimeContext,
        baseUrl: baseURL,
        sourceContent: obj
      });
    });
  }

  function createJavaShim(scope) {
    return {
      getString: function (rule) {
        if (scope && scope.currentObject && typeof scope.currentObject === 'object') {
          return extractValueFromObject(scope.currentObject, scope.baseUrl || '', String(rule || ''), scope.runtimeContext, scope.sourceContent);
        }
        return routeExtractValue(scope && scope.sourceContent || '', scope && scope.baseUrl || '', String(rule || ''), scope && scope.contextNode, scope && scope.currentObject, scope && scope.runtimeContext);
      },
      put: function (key, val) { return setRuntimeValue(scope && scope.runtimeContext, key, val); },
      get: function (key) { return getRuntimeValue(scope && scope.runtimeContext, key); },
      base64Decode: function (s) {
        try {
          if (typeof atob === 'function') return atob(String(s || ''));
        } catch (_) {}
        return '';
      },
      timeFormat: function (value) {
        const n = Number(value);
        if (!isFinite(n)) return String(value || '');
        const ms = n > 1e12 ? n : n * 1000;
        return new Date(ms).toISOString().replace('T', ' ').slice(0, 19);
      }
    };
  }

  function applyJsPostProcessors(value, scripts, scope) {
    let result = value == null ? '' : value;
    for (const script of scripts || []) {
      const localScope = Object.assign({}, scope || {}, { result });
      if (!localScope.runtimeContext) localScope.runtimeContext = ensureRuntimeContext();
      if (!localScope.java) localScope.java = createJavaShim(localScope);
      result = evalUserScript(script, localScope);
      if (result == null) result = '';
      if (typeof result === 'string') result = substituteRuntimeGets(result, localScope.runtimeContext);
    }
    return typeof result === 'string' ? trim(result) : result;
  }

  function evaluateRuleLike(expr, scope) {
    const rendered = substituteRuntimeGets(trim(expr || ''), scope && scope.runtimeContext);
    if (!rendered) return '';
    if ((rendered.startsWith('"') && rendered.endsWith('"')) || (rendered.startsWith("'") && rendered.endsWith("'"))) {
      return unquoteString(rendered);
    }
    if (/^@get:\{/.test(rendered)) return getRuntimeValue(scope && scope.runtimeContext, rendered.slice(6, -1));
    if (scope && scope.currentObject && typeof scope.currentObject === 'object' && !scope.contextNode) {
      return extractValueFromObject(scope.currentObject, scope.baseUrl || '', rendered, scope.runtimeContext, scope.sourceContent);
    }
    return routeExtractValue(scope && scope.sourceContent || '', scope && scope.baseUrl || '', rendered, scope && scope.contextNode, scope && scope.currentObject, scope && scope.runtimeContext);
  }

  function applyPutDirective(spec, scope) {
    const raw = trim(spec || '').replace(/^\{/, '').replace(/\}$/, '');
    if (!raw) return '';
    const pairs = splitTopLevel(raw, ',').map(s => trim(s)).filter(Boolean);
    for (const pair of pairs) {
      const idx = pair.indexOf(':');
      if (idx === -1) continue;
      const key = unquoteString(pair.slice(0, idx));
      const expr = pair.slice(idx + 1);
      const value = evaluateRuleLike(expr, scope || {});
      setRuntimeValue(scope && scope.runtimeContext, key, value);
    }
    return '';
  }

  function preprocessContentByBookInfoRule(html, baseURL, bookUrl, ruleBookInfo, runtimeContext) {
    const initScript = trim(ruleBookInfo && ruleBookInfo.init || '');
    if (!initScript) return html;
    const initial = html == null ? '' : String(html);
    const out = evalUserScript(initScript, {
      result: initial,
      baseUrl: baseURL,
      bookUrl: bookUrl,
      ruleBookInfo: ruleBookInfo || {},
      runtimeContext: runtimeContext,
      java: null
    });
    if (typeof out === 'string') return out;
    if (out == null) return initial;
    try { return JSON.stringify(out); } catch (_) { return String(out); }
  }

  function applyTocFormat(chapter, formatJs, baseURL, runtimeContext) {
    const script = trim(formatJs || '');
    if (!script) return chapter;
    const seed = {
      index: chapter.index,
      title: chapter.title || '',
      url: chapter.url || '',
      isVolume: !!chapter.isVolume,
      isVip: !!chapter.isVip,
      isPay: !!chapter.isPay
    };
    const out = evalUserScript(script, {
      result: Object.assign({}, seed),
      title: seed.title,
      url: seed.url,
      index: seed.index,
      isVolume: seed.isVolume,
      isVip: seed.isVip,
      isPay: seed.isPay,
      baseUrl: baseURL,
      runtimeContext: runtimeContext,
      java: null
    });
    if (out && typeof out === 'object' && !Array.isArray(out)) {
      return {
        index: typeof out.index === 'number' ? out.index : seed.index,
        title: trim(out.title != null ? String(out.title) : seed.title),
        url: trim(out.url != null ? String(out.url) : seed.url),
        isVolume: asBool(out.isVolume),
        isVip: asBool(out.isVip),
        isPay: asBool(out.isPay)
      };
    }
    if (typeof out === 'string' && out) {
      return Object.assign({}, seed, { title: trim(out) });
    }
    return seed;
  }

  function finalizeChapter(chapter, ruleToc, baseURL, runtimeContext) {
    let normalized = {
      index: chapter.index,
      title: trim(chapter.title || '') || ('第' + (chapter.index + 1) + '章'),
      url: resolveURL(chapter.url || '', baseURL),
      isVolume: asBool(chapter.isVolume),
      isVip: asBool(chapter.isVip),
      isPay: asBool(chapter.isPay),
      runtimeVariables: cloneRuntimeVariables(runtimeContext)
    };
    normalized = applyTocFormat(normalized, ruleToc && ruleToc.formatJs || '', baseURL, runtimeContext);
    normalized.title = trim(normalized.title || '') || ('第' + (normalized.index + 1) + '章');
    normalized.url = resolveURL(normalized.url || '', baseURL);
    normalized.isVolume = asBool(normalized.isVolume);
    normalized.isVip = asBool(normalized.isVip);
    normalized.isPay = asBool(normalized.isPay);
    normalized.runtimeVariables = cloneRuntimeVariables(runtimeContext);
    return normalized;
  }

  function testRegex(pattern, text) {
    const p = trim(pattern || '');
    if (!p) return true;
    try {
      return new RegExp(p).test(text || '');
    } catch (_) {
      return true;
    }
  }

  function getAttr(el, attr) {
    if (!el || !el.getAttribute) return '';
    const a = (attr || '').toLowerCase();
    if (a === 'text' || a === 'innertext' || a === '') return cleanText(el.textContent || '');
    if (a === 'href') return el.getAttribute('href') || '';
    if (a === 'src') return el.getAttribute('src') || '';
    if (a === 'outerhtml') return el.outerHTML || '';
    if (a.startsWith('attr(') && a.endsWith(')')) return el.getAttribute(a.slice(5, -1)) || '';
    return el.getAttribute(attr) || '';
  }

  function isJsoupContentSpec(seg) {
    const s = trim(seg).toLowerCase();
    return ['text', 'href', 'src', 'html', 'all', 'owntext', 'textnodes'].includes(s);
  }

  function isJsoupDefaultRule(rule) {
    const segments = trim(rule).split('@').map(s => trim(s)).filter(Boolean);
    for (const seg of segments) {
      if (!seg) continue;
      if (!seg.includes('.') && /^[a-z0-9]+$/i.test(seg)) return true;
      const parts = seg.split('.');
      if (parts.length >= 2) {
        const type = parts[0].toLowerCase();
        if (['class', 'id', 'tag', 'text', 'children'].includes(type)) return true;
        if (/^[a-z][a-z0-9]*$/i.test(type) && /^-?\d+$/.test(parts[parts.length - 1])) return true;
      }
    }
    return false;
  }

  const KNOWN_TAGS = /^(a|div|span|td|tr|li|ul|ol|dl|dt|dd|p|h[1-6]|table|tbody|thead|form|input|img|strong|em|section|article|header|footer|nav|main)$/i;
  function parseJsoupSegment(seg) {
    const s = trim(seg).replace(/^\./, '');
    if (!s) return null;
    const parts = s.split('.');
    if (parts.length === 1) {
      if (/^[a-z0-9]+$/i.test(s)) return { css: s.toLowerCase(), index: null };
      return null;
    }
    let type = parts[0].toLowerCase();
    let name = parts[1];
    let index = null;
    if (parts.length >= 3 && /^-?\d+$/.test(parts[2])) index = parseInt(parts[2], 10);
    else if (parts.length === 2 && /^-?\d+$/.test(parts[1])) {
      index = parseInt(parts[1], 10);
      name = type;
      type = KNOWN_TAGS.test(type) ? 'tag' : (type.startsWith('#') ? 'id' : 'class');
      if (type === 'class') name = name.replace(/^\./, '');
    }
    let css = '';
    if (type === 'class') css = '.' + name;
    else if (type === 'id') css = '#' + name.replace(/^#/, '');
    else if (type === 'tag') css = name.toLowerCase();
    else return null;
    return { css, index };
  }

  function getElementsBySegment(parents, segment) {
    const parsed = parseJsoupSegment(segment);
    if (!parsed) return [];
    const out = [];
    for (const p of parents) {
      let list = [];
      try {
        if (parsed.css.startsWith('.') && p.getElementsByClassName) {
          list = Array.from(p.getElementsByClassName(parsed.css.slice(1)));
        } else if (parsed.css.startsWith('#') && p.getElementById) {
          const one = p.getElementById(parsed.css.slice(1));
          if (one) list = [one];
        } else if (p.querySelectorAll) {
          list = Array.from(p.querySelectorAll(parsed.css));
        }
      } catch (_) { list = []; }
      if (parsed.index != null) {
        const i = parsed.index < 0 ? list.length + parsed.index : parsed.index;
        if (i >= 0 && i < list.length) out.push(list[i]);
      } else {
        out.push(...list);
      }
    }
    return out;
  }

  function getResultLast(elements, lastRule) {
    const textS = [];
    const r = trim(lastRule).toLowerCase();
    for (const el of elements) {
      let v = '';
      if (r === 'text') v = cleanText(el.textContent || '');
      else if (r === 'textnodes' || r === 'owntext') {
        v = Array.from(el.childNodes).filter(n => n.nodeType === 3).map(n => n.textContent || '').join('').trim();
      } else if (r === 'html' || r === 'all') v = el.outerHTML || '';
      else v = el.getAttribute(lastRule) || '';
      if (v) textS.push(v);
    }
    return textS;
  }

  function extractListByJsoupDefault(html, baseURL, rule) {
    const { main, regexParts } = splitRuleAndRegex(rule);
    const segments = main.split('@').map(s => trim(s)).filter(Boolean);
    if (segments.length === 0) return [];
    const doc = parseHTML(html);
    if (!doc) return [];
    let current = [doc.documentElement || doc.body || doc];
    let lastContent = null;
    for (const seg of segments) {
      if (isJsoupContentSpec(seg)) { lastContent = seg; break; }
      current = getElementsBySegment(current, seg);
      if (current.length === 0) return [];
    }
    return current;
  }

  function extractValueByJsoupDefaultFromElements(elements, baseURL, rule) {
    const { main, regexParts } = splitRuleAndRegex(rule);
    const segments = main.split('@').map(s => trim(s)).filter(Boolean);
    let contentSpec = 'text';
    for (const seg of segments) {
      if (isJsoupContentSpec(seg)) { contentSpec = trim(seg).toLowerCase(); break; }
    }
    if (elements.length === 0) return '';
    const el = elements[0];
    let value = '';
    if (contentSpec === 'href') { value = el.getAttribute('href') || ''; if (value) value = resolveURL(value, baseURL); }
    else if (contentSpec === 'src') { value = el.getAttribute('src') || ''; if (value) value = resolveURL(value, baseURL); }
    else if (contentSpec === 'html' || contentSpec === 'all') value = el.outerHTML || '';
    else if (contentSpec === 'owntext' || contentSpec === 'textnodes') value = Array.from(el.childNodes).filter(n => n.nodeType === 3).map(n => n.textContent || '').join('').trim();
    else value = cleanText(el.textContent || '');
    value = applyRegex(value, regexParts);
    return trim(value);
  }

  function extractListByCss(doc, baseURL, rule) {
    const { main } = splitRuleAndRegex(rule);
    const steps = main.split('@@').map(s => trim(s)).filter(Boolean);
    if (steps.length === 0) return [];
    const root = doc.documentElement || doc.body || doc;
    const firstStep = steps[0];
    const { selector } = splitSelectorAndAttr(firstStep);
    if (!selector) return [];
    let nodes = safeQuerySelectorAll(root, selector);
    for (let i = 1; i < steps.length; i++) {
      const { selector: subSel } = splitSelectorAndAttr(steps[i]);
      if (!subSel) continue;
      nodes = nodes.flatMap(n => safeQuerySelectorAll(n, subSel));
    }
    return nodes;
  }

  function extractValueByCss(elOrDoc, rule, baseURL) {
    const { main, regexParts } = splitRuleAndRegex(rule);
    const { selector, attr } = splitSelectorAndAttr(main);
    let target = elOrDoc;
    if (selector) {
      const pre = preprocessLegadoSelector(selector);
      if (pre.type === 'template') {
        try {
          const inner = pre.raw.slice(2, -2).trim();
          if (/^["']/.test(inner)) {
            const val = trim(inner.replace(/^["']|["']$/g, ''));
            return trim(applyRegex(val, regexParts));
          }
        } catch (_) {}
        return '';
      }
      const found = safeQuerySelector(elOrDoc, selector);
      if (!found && regexParts.length > 0) {
        let raw = elOrDoc.outerHTML || elOrDoc.documentElement?.outerHTML || '';
        return trim(applyRegex(raw, regexParts));
      }
      if (!found) return '';
      target = found;
    }
    let value = getAttr(target, attr);
    if ((attr === 'href' || attr === 'src') && value) value = resolveURL(value, baseURL);
    value = applyRegex(value, regexParts);
    return trim(value);
  }

  function extractByXPath(doc, xpath, single) {
    try {
      const context = doc.documentElement || doc.body || doc;
      const result = doc.evaluate(xpath, context, null, single ? 9 : 7, null); // 9=FIRST_ORDERED_NODE, 7=ORDERED_NODE_SNAPSHOT
      if (single) return result.singleNodeValue ? [result.singleNodeValue] : [];
      const arr = [];
      for (let i = 0; i < result.snapshotLength; i++) arr.push(result.snapshotItem(i));
      return arr;
    } catch (_) { return []; }
  }

  function splitJsonPath(path) {
    const src = trim(path || '').replace(/^\$\.?/, '');
    if (!src) return [];
    const tokens = [];
    let buf = '';
    let depth = 0;
    for (let i = 0; i < src.length; i++) {
      const ch = src[i];
      if (ch === '[') depth++;
      if (ch === ']') depth--;
      if (ch === '.' && depth === 0) {
        if (buf) tokens.push(buf);
        buf = '';
      } else {
        buf += ch;
      }
    }
    if (buf) tokens.push(buf);
    return tokens;
  }

  function collectChildValues(node) {
    if (node == null) return [];
    if (Array.isArray(node)) return node.slice();
    if (typeof node === 'object') return Object.keys(node).map(k => node[k]);
    return [];
  }

  function applyJsonToken(nodes, token) {
    const out = [];
    const t = trim(token || '');
    if (!t) return nodes;
    const filterMatch = t.match(/^(.*)\[\?\(@\.(.+?)\)\]$/);
    const indexMatch = t.match(/^(.*)\[(\-?\d+)\]$/);
    for (const node of nodes) {
      if (node == null) continue;
      if (t === '*') {
        out.push(...collectChildValues(node));
        continue;
      }
      if (filterMatch) {
        const head = trim(filterMatch[1]);
        const prop = trim(filterMatch[2]);
        const baseNodes = head ? applyJsonToken([node], head) : collectChildValues(node);
        for (const item of baseNodes) {
          if (item && typeof item === 'object' && item[prop] != null) out.push(item);
        }
        continue;
      }
      if (indexMatch) {
        const head = trim(indexMatch[1]);
        const idx = parseInt(indexMatch[2], 10);
        const baseNodes = head ? applyJsonToken([node], head) : [node];
        for (const item of baseNodes) {
          if (!Array.isArray(item)) continue;
          const actual = idx < 0 ? item.length + idx : idx;
          if (actual >= 0 && actual < item.length) out.push(item[actual]);
        }
        continue;
      }
      if (Array.isArray(node)) {
        for (const item of node) {
          if (item && typeof item === 'object' && t in item) out.push(item[t]);
        }
      } else if (typeof node === 'object' && t in node) {
        out.push(node[t]);
      }
    }
    return out;
  }

  function jsonPathQuery(obj, path) {
    if (!path) return [obj];
    const tokens = splitJsonPath(path);
    let nodes = [obj];
    for (const token of tokens) {
      nodes = applyJsonToken(nodes, token);
      if (!nodes.length) break;
    }
    return nodes;
  }

  function jsonPathGet(obj, path) {
    const list = jsonPathQuery(obj, path);
    if (!list.length) return undefined;
    return list.length === 1 ? list[0] : list;
  }

  function extractListByJson(root, rule) {
    const pipeline = splitRulePipeline(rule);
    const { main } = splitRuleAndRegex(pipeline.main);
    const path = trim(main);
    const values = jsonPathQuery(root, path);
    return values.filter(v => v != null);
  }

  function extractValueByJson(root, rule, baseURL, runtimeContext) {
    const pipeline = splitRulePipeline(rule);
    const rendered = renderObjectTemplates(pipeline.main, root, runtimeContext, baseURL);
    const { main, regexParts } = splitRuleAndRegex(rendered);
    const path = trim(main);
    let val = jsonPathGet(root, path);
    if (val == null) return '';
    if (Array.isArray(val)) val = val[0];
    if (val == null) return '';
    if (typeof val !== 'string') val = JSON.stringify(val);
    let result = trim(applyRegex(val, regexParts));
    result = applyJsPostProcessors(result, pipeline.scripts, { baseUrl: baseURL, currentObject: root, sourceContent: root, runtimeContext: runtimeContext });
    return typeof result === 'string' ? trim(result) : trim(String(result || ''));
  }

  function extractValueFromObject(root, baseURL, rule, runtimeContext, sourceContent) {
    let trimmed = substituteRuntimeGets(trim(rule), runtimeContext);
    if (!trimmed) {
      if (root == null) return '';
      return typeof root === 'string' ? trim(root) : '';
    }

    if (/^@get:\{[^{}]+\}$/.test(trimmed)) return getRuntimeValue(runtimeContext, trimmed.slice(6, -1));
    if (/^@put:\{[\s\S]*\}$/.test(trimmed)) {
      applyPutDirective(trimmed.slice(5), {
        currentObject: root,
        baseUrl: baseURL,
        sourceContent: sourceContent || root,
        runtimeContext: runtimeContext
      });
      return '';
    }

    if (trimmed.startsWith('@@')) trimmed = trim(trimmed.slice(2));
    if (trimmed.includes('&&')) {
      const parts = trimmed.split('&&').map(s => trim(s)).filter(Boolean);
      if (parts.length > 1) {
        return parts.map(function (part) {
          return extractValueFromObject(root, baseURL, part, runtimeContext, sourceContent);
        }).filter(Boolean).join('\n');
      }
    }
    if (trimmed.includes('||')) {
      const alts = trimmed.split('||').map(s => trim(s)).filter(Boolean);
      for (const alt of alts) {
        const value = extractValueFromObject(root, baseURL, alt, runtimeContext, sourceContent);
        if (trim(value)) return trim(value);
      }
      return '';
    }

    const pipeline = splitRulePipeline(trimmed);
    const rendered = renderObjectTemplates(pipeline.main, root, runtimeContext, baseURL);
    const contextDirective = splitTrailingPutDirective(rendered);
    const { main, regexParts } = splitRuleAndRegex(contextDirective.main);
    let path = trim(main);
    if (!path) {
      let seed = '';
      if (typeof root === 'string') seed = root;
      if (contextDirective.putSpec) {
        applyPutDirective(contextDirective.putSpec, {
          currentObject: root,
          baseUrl: baseURL,
          sourceContent: sourceContent || root,
          runtimeContext: runtimeContext
        });
      }
      const finalSeed = applyJsPostProcessors(trim(seed), pipeline.scripts, { baseUrl: baseURL, currentObject: root, sourceContent: root, runtimeContext: runtimeContext });
      return typeof finalSeed === 'string' ? trim(finalSeed) : trim(String(finalSeed || ''));
    }

    if (/^@json:/i.test(path)) path = trim(path.slice(6));
    let value = jsonPathGet(root, path);
    if (value == null && /^[a-zA-Z0-9_$]+$/.test(path) && root && typeof root === 'object' && path in root) {
      value = root[path];
    }
    if (Array.isArray(value)) value = value[0];
    if (value == null) value = '';
    if (typeof value !== 'string') {
      try { value = JSON.stringify(value); } catch (_) { value = String(value); }
    }
    let result = trim(applyRegex(value, regexParts));
    if (contextDirective.putSpec) {
      applyPutDirective(contextDirective.putSpec, {
        result: result,
        currentObject: root,
        baseUrl: baseURL,
        sourceContent: sourceContent || root,
        runtimeContext: runtimeContext
      });
    }
    result = applyJsPostProcessors(result, pipeline.scripts, { baseUrl: baseURL, currentObject: root, sourceContent: root, runtimeContext: runtimeContext });
    return typeof result === 'string' ? trim(result) : trim(String(result || ''));
  }

  function extractRegexAllInOne(html, pattern) {
    const p = trim(pattern);
    if (!p) return [];
    try {
      const regex = new RegExp(p, 'g');
      const out = [];
      let m;
      while ((m = regex.exec(html)) !== null) {
        out.push(m.slice(0));
      }
      return out;
    } catch (_) { return []; }
  }

  function substituteGroupRefs(template, groups) {
    let s = template;
    for (let i = 1; i < groups.length; i++) s = s.replace(new RegExp('\\$' + i, 'g'), groups[i] || '');
    return s;
  }

  function routeExtractList(content, baseURL, rule, runtimeContext) {
    let trimmed = substituteRuntimeGets(trim(rule), runtimeContext);
    if (!trimmed) return [];

    if (trimmed.startsWith('@@')) trimmed = trim(trimmed.slice(2));
    let shouldReverse = false;
    if (trimmed.startsWith('-')) { shouldReverse = true; trimmed = trim(trimmed.slice(1)); }

    if (trimmed.includes('||')) {
      for (const alt of trimmed.split('||')) {
        const nodes = routeExtractList(content, baseURL, trim(alt), runtimeContext);
        if (nodes.length) return shouldReverse ? nodes.reverse() : nodes;
      }
      return [];
    }
    if (trimmed.includes('%%')) {
      const parts = trimmed.split('%%').map(s => trim(s)).filter(Boolean);
      if (parts.length > 1) {
        const lists = parts.map(p => routeExtractList(content, baseURL, p, runtimeContext));
        if (lists.some(l => !l.length)) return [];
        const interleaved = [];
        for (let i = 0; ; i++) {
          let any = false;
          for (const list of lists) {
            if (i < list.length) { interleaved.push(list[i]); any = true; }
          }
          if (!any) break;
        }
        return shouldReverse ? interleaved.reverse() : interleaved;
      }
    }
    if (trimmed.includes('&&')) {
      const parts = trimmed.split('&&').map(s => trim(s)).filter(Boolean);
      if (parts.length > 1) {
        const merged = [];
        for (const p of parts) merged.push(...routeExtractList(content, baseURL, p, runtimeContext));
        return shouldReverse ? merged.reverse() : merged;
      }
    }

    if (isJson(content)) return [];

    const doc = parseHTML(content);
    if (!doc) return [];

    let nodes = [];
    if (/^@xpath:/i.test(trimmed) || (trimmed.startsWith('//') && !trimmed.startsWith('//@'))) {
      const xpath = /^@xpath:/i.test(trimmed) ? trim(trimmed.slice(7)) : trimmed;
      nodes = extractByXPath(doc, xpath, false);
    } else if (/^@css:/i.test(trimmed)) {
      nodes = extractListByCss(doc, baseURL, trim(trimmed.slice(5)));
    } else if (isJsoupDefaultRule(trimmed)) {
      nodes = extractListByJsoupDefault(content, baseURL, trimmed);
    } else {
      nodes = extractListByCss(doc, baseURL, trimmed);
    }
    return shouldReverse ? nodes.reverse() : nodes;
  }

  function routeExtractValue(content, baseURL, rule, contextNode, currentObject, runtimeContext) {
    let trimmed = substituteRuntimeGets(trim(rule), runtimeContext);
    if (!trimmed) return contextNode ? cleanText(contextNode.textContent || '') : '';

    if (/^@get:\{[^{}]+\}$/.test(trimmed)) return getRuntimeValue(runtimeContext, trimmed.slice(6, -1));
    if (/^@put:\{[\s\S]*\}$/.test(trimmed)) {
      applyPutDirective(trimmed.slice(5), {
        currentObject: currentObject,
        contextNode: contextNode,
        baseUrl: baseURL,
        sourceContent: content,
        runtimeContext: runtimeContext
      });
      return '';
    }

    if (trimmed.startsWith('@@')) trimmed = trim(trimmed.slice(2));
    if (trimmed.includes('&&')) {
      const parts = trimmed.split('&&').map(s => trim(s)).filter(Boolean);
      if (parts.length > 1) {
        return parts.map(p => routeExtractValue(content, baseURL, p, contextNode, currentObject, runtimeContext)).filter(Boolean).join('\n');
      }
    }
    if (trimmed.includes('||')) {
      for (const alt of trimmed.split('||')) {
        const s = routeExtractValue(content, baseURL, trim(alt), contextNode, currentObject, runtimeContext);
        if (s) return s;
      }
      return '';
    }

    if (currentObject && typeof currentObject === 'object' && !contextNode) {
      return extractValueFromObject(currentObject, baseURL, trimmed, runtimeContext, content);
    }

    const doc = contextNode ? null : parseHTML(content);
    const root = contextNode || (doc && (doc.documentElement || doc.body || doc));
    const pipeline = splitRulePipeline(trimmed);
    const coreRule = trim(pipeline.main);

    if (isJson(content) && !contextNode) {
      try {
        const data = JSON.parse(content);
        return extractValueFromObject(data, baseURL, trimmed, runtimeContext, content);
      } catch (_) { return ''; }
    }
    if (/^@json:/i.test(coreRule) || /^\$\./.test(coreRule) || /^\$\[/.test(coreRule)) {
      try {
        const data = typeof content === 'string' ? JSON.parse(content) : content;
        return extractValueFromObject(data, baseURL, trimmed, runtimeContext, content);
      } catch (_) { return ''; }
    }
    const contextDirective = splitTrailingPutDirective(coreRule);
    const extractionRule = contextDirective.main;
    let result = '';
    if (/^@xpath:/i.test(extractionRule) || (extractionRule.startsWith('//') && !extractionRule.startsWith('//@'))) {
      const xpath = /^@xpath:/i.test(extractionRule) ? trim(extractionRule.slice(7)) : extractionRule;
      const nodes = extractByXPath(root.ownerDocument || root, xpath, true);
      if (nodes.length) result = cleanText(nodes[0].textContent || '') || (nodes[0].getAttribute ? (nodes[0].getAttribute('href') || nodes[0].getAttribute('src') || '') : '');
    } else if (/^@css:/i.test(extractionRule)) {
      result = extractValueByCss(root, trim(extractionRule.slice(5)), baseURL);
    } else if (isJsoupDefaultRule(extractionRule)) {
      const elements = contextNode
        ? (function () {
            const { main } = splitRuleAndRegex(extractionRule);
            const segments = main.split('@').map(s => trim(s)).filter(Boolean);
            let current = [contextNode];
            for (const seg of segments) {
              if (isJsoupContentSpec(seg)) break;
              current = getElementsBySegment(current, seg);
              if (!current.length) return [];
            }
            return current;
          })()
        : extractListByJsoupDefault(content, baseURL, extractionRule);
      result = extractValueByJsoupDefaultFromElements(elements, baseURL, extractionRule);
    } else {
      result = extractValueByCss(root, extractionRule, baseURL);
    }
    if (contextDirective.putSpec) {
      applyPutDirective(contextDirective.putSpec, {
        result: result,
        currentObject: currentObject,
        contextNode: contextNode,
        baseUrl: baseURL,
        sourceContent: content,
        runtimeContext: runtimeContext
      });
    }
    result = applyJsPostProcessors(result, pipeline.scripts, {
      baseUrl: baseURL,
      currentObject: currentObject || null,
      contextNode: contextNode || null,
      sourceContent: content,
      runtimeContext: runtimeContext
    });
    return typeof result === 'string' ? trim(result) : trim(String(result || ''));
  }

  function cleanBookName(name) {
    const s = trim(name || '');
    if (!s) return s;
    const m = s.match(/^\s*\d+[\.\、．]\s*/);
    return m ? trim(s.slice(m[0].length)) : s;
  }

  function parseSearchResults(html, baseURL, ruleSearch, runtimeVariablesSeed) {
    if (isJson(html)) return parseSearchResultsJSON(html, baseURL, ruleSearch, runtimeVariablesSeed);
    const bookList = trim(ruleSearch.bookList || '');
    if (!bookList) return [];
    const nodes = routeExtractList(html, baseURL, bookList, ensureRuntimeContext(runtimeVariablesSeed));
    const books = [];
    for (const node of nodes) {
      const runtimeContext = ensureRuntimeContext(runtimeVariablesSeed);
      const bookUrl = routeExtractValue(html, baseURL, ruleSearch.bookUrl || '', node, null, runtimeContext);
      if (!bookUrl) continue;
      const name = cleanBookName(routeExtractValue(html, baseURL, ruleSearch.name || '', node, null, runtimeContext));
      const author = routeExtractValue(html, baseURL, ruleSearch.author || '', node, null, runtimeContext);
      const intro = routeExtractValue(html, baseURL, ruleSearch.intro || '', node, null, runtimeContext);
      const coverUrl = routeExtractValue(html, baseURL, ruleSearch.coverUrl || '', node, null, runtimeContext);
      const wordCount = routeExtractValue(html, baseURL, ruleSearch.wordCount || '', node, null, runtimeContext);
      const lastChapter = routeExtractValue(html, baseURL, ruleSearch.lastChapter || '', node, null, runtimeContext);
      const kind = routeExtractValue(html, baseURL, ruleSearch.kind || '', node, null, runtimeContext);
      books.push({
        name, author, intro, coverUrl, bookUrl, tocUrl: bookUrl, wordCount, lastChapter, kind,
        runtimeVariables: cloneRuntimeVariables(runtimeContext)
      });
    }
    return books;
  }

  function parseSearchResultsJSON(jsonStr, baseURL, ruleSearch, runtimeVariablesSeed) {
    try {
      const data = JSON.parse(jsonStr);
      const bookListRule = trim(ruleSearch.bookList || '');
      if (!bookListRule) return [];
      const arr = extractListByJson(data, bookListRule);
      const books = [];
      for (const item of arr) {
        const runtimeContext = ensureRuntimeContext(runtimeVariablesSeed);
        const bookUrlRaw = extractValueFromObject(item, baseURL, ruleSearch.bookUrl || '', runtimeContext, item) || (typeof item === 'object' && (item.url || item.link || item.bookUrl));
        if (!bookUrlRaw && (typeof item !== 'object' || !item.link)) continue;
        const finalUrl = typeof bookUrlRaw === 'string' ? resolveURL(bookUrlRaw, baseURL) : '';
        if (!finalUrl) continue;
        const name = cleanBookName(extractValueFromObject(item, baseURL, ruleSearch.name || '', runtimeContext, item) || (item && item.name) || '');
        const author = extractValueFromObject(item, baseURL, ruleSearch.author || '', runtimeContext, item) || (item && item.author) || '';
        books.push({
          name,
          author,
          intro: extractValueFromObject(item, baseURL, ruleSearch.intro || '', runtimeContext, item) || (item && item.intro) || '',
          coverUrl: resolveURL(extractValueFromObject(item, baseURL, ruleSearch.coverUrl || '', runtimeContext, item) || (item && item.coverUrl) || '', baseURL),
          bookUrl: finalUrl,
          tocUrl: finalUrl,
          wordCount: extractValueFromObject(item, baseURL, ruleSearch.wordCount || '', runtimeContext, item) || '',
          lastChapter: extractValueFromObject(item, baseURL, ruleSearch.lastChapter || '', runtimeContext, item) || '',
          kind: extractValueFromObject(item, baseURL, ruleSearch.kind || '', runtimeContext, item) || '',
          runtimeVariables: cloneRuntimeVariables(runtimeContext)
        });
      }
      return books;
    } catch (_) { return []; }
  }

  function parseBookInfo(html, bookUrl, baseURL, ruleBookInfo, runtimeVariablesSeed) {
    const runtimeContext = ensureRuntimeContext(runtimeVariablesSeed);
    const prepared = preprocessContentByBookInfoRule(html, baseURL, bookUrl, ruleBookInfo, runtimeContext);
    if (isJson(prepared)) return parseBookInfoJSON(prepared, bookUrl, baseURL, ruleBookInfo, runtimeContext);
    const tocUrlRule = trim(ruleBookInfo.tocUrl || '');
    const extractedTocUrl = tocUrlRule ? routeExtractValue(prepared, baseURL, tocUrlRule, null, null, runtimeContext) : bookUrl;
    return {
      name: cleanBookName(routeExtractValue(prepared, baseURL, ruleBookInfo.name || '', null, null, runtimeContext)),
      author: routeExtractValue(prepared, baseURL, ruleBookInfo.author || '', null, null, runtimeContext),
      intro: routeExtractValue(prepared, baseURL, ruleBookInfo.intro || '', null, null, runtimeContext),
      coverUrl: routeExtractValue(prepared, baseURL, ruleBookInfo.coverUrl || '', null, null, runtimeContext),
      bookUrl,
      tocUrl: extractedTocUrl || bookUrl,
      wordCount: routeExtractValue(prepared, baseURL, ruleBookInfo.wordCount || '', null, null, runtimeContext),
      lastChapter: routeExtractValue(prepared, baseURL, ruleBookInfo.lastChapter || '', null, null, runtimeContext),
      kind: routeExtractValue(prepared, baseURL, ruleBookInfo.kind || '', null, null, runtimeContext),
      runtimeVariables: cloneRuntimeVariables(runtimeContext)
    };
  }

  function parseBookInfoJSON(jsonStr, bookUrl, baseURL, ruleBookInfo, runtimeContext) {
    try {
      const root = JSON.parse(jsonStr);
      const tocUrlRule = trim(ruleBookInfo.tocUrl || '');
      const extractedTocUrl = tocUrlRule ? extractValueFromObject(root, baseURL, tocUrlRule, runtimeContext, root) : bookUrl;
      return {
        name: cleanBookName(extractValueFromObject(root, baseURL, ruleBookInfo.name || '', runtimeContext, root)),
        author: extractValueFromObject(root, baseURL, ruleBookInfo.author || '', runtimeContext, root),
        intro: extractValueFromObject(root, baseURL, ruleBookInfo.intro || '', runtimeContext, root),
        coverUrl: extractValueFromObject(root, baseURL, ruleBookInfo.coverUrl || '', runtimeContext, root),
        bookUrl,
        tocUrl: extractedTocUrl || bookUrl,
        wordCount: extractValueFromObject(root, baseURL, ruleBookInfo.wordCount || '', runtimeContext, root),
        lastChapter: extractValueFromObject(root, baseURL, ruleBookInfo.lastChapter || '', runtimeContext, root),
        kind: extractValueFromObject(root, baseURL, ruleBookInfo.kind || '', runtimeContext, root),
        runtimeVariables: cloneRuntimeVariables(runtimeContext)
      };
    } catch (_) {
      return { name: '', author: '', intro: '', coverUrl: '', bookUrl, tocUrl: bookUrl, wordCount: '', lastChapter: '', kind: '', runtimeVariables: cloneRuntimeVariables(runtimeContext) };
    }
  }

  function parseTOC(html, baseURL, ruleToc, runtimeVariablesSeed) {
    if (isJson(html)) return parseTOCJSON(html, baseURL, ruleToc, runtimeVariablesSeed);
    const listRule = trim(ruleToc.chapterList || '');
    if (!listRule) return [];
    if (listRule.startsWith(':')) {
      const pattern = trim(listRule.slice(1));
      if (!pattern) return [];
      const matches = extractRegexAllInOne(html, pattern);
      return matches.map((groups, i) => {
        const runtimeContext = ensureRuntimeContext(runtimeVariablesSeed);
        const chapterUrl = substituteGroupRefs(ruleToc.chapterUrl || '$1', groups);
        const title = substituteGroupRefs(ruleToc.chapterName || '$2', groups);
        const isVolume = substituteGroupRefs(ruleToc.isVolume || '', groups);
        const isVip = substituteGroupRefs(ruleToc.isVip || '', groups);
        const isPay = substituteGroupRefs(ruleToc.isPay || '', groups);
        return finalizeChapter({
          index: i,
          title: title || ('第' + (i + 1) + '章'),
          url: chapterUrl,
          isVolume,
          isVip,
          isPay
        }, ruleToc, baseURL, runtimeContext);
      }).filter(c => c.url || c.isVolume);
    }
    const nodes = routeExtractList(html, baseURL, listRule, ensureRuntimeContext(runtimeVariablesSeed));
    const mapped = nodes.map((node, i) => {
      const runtimeContext = ensureRuntimeContext(runtimeVariablesSeed);
      const chapterUrl = routeExtractValue(html, baseURL, ruleToc.chapterUrl || '', node, null, runtimeContext);
      const title = routeExtractValue(html, baseURL, ruleToc.chapterName || '', node, null, runtimeContext);
      const isVolume = routeExtractValue(html, baseURL, ruleToc.isVolume || '', node, null, runtimeContext);
      const isVip = routeExtractValue(html, baseURL, ruleToc.isVip || '', node, null, runtimeContext);
      const isPay = routeExtractValue(html, baseURL, ruleToc.isPay || '', node, null, runtimeContext);
      return finalizeChapter({
        index: i,
        title: title || ('第' + (i + 1) + '章'),
        url: chapterUrl,
        isVolume,
        isVip,
        isPay
      }, ruleToc, baseURL, runtimeContext);
    });
    const filtered = mapped.filter(c => c.url || c.isVolume);
    return filtered;
  }

  function parseTOCJSON(jsonStr, baseURL, ruleToc, runtimeVariablesSeed) {
    try {
      const data = JSON.parse(jsonStr);
      const listRule = trim(ruleToc.chapterList || '');
      if (!listRule) return [];
      const arr = extractListByJson(data, listRule);
      return arr.map((item, i) => {
        const runtimeContext = ensureRuntimeContext(runtimeVariablesSeed);
        const chapterUrl = extractValueFromObject(item, baseURL, ruleToc.chapterUrl || '', runtimeContext, item) || (item && (item.url || item.link)) || '';
        const title = extractValueFromObject(item, baseURL, ruleToc.chapterName || '', runtimeContext, item) || (item && item.title) || ('第' + (i + 1) + '章');
        const isVolume = extractValueFromObject(item, baseURL, ruleToc.isVolume || '', runtimeContext, item) || (item && item.isVolume);
        const isVip = extractValueFromObject(item, baseURL, ruleToc.isVip || '', runtimeContext, item) || (item && item.isVip);
        const isPay = extractValueFromObject(item, baseURL, ruleToc.isPay || '', runtimeContext, item) || (item && item.isPay);
        return finalizeChapter({
          index: i,
          title,
          url: chapterUrl,
          isVolume,
          isVip,
          isPay
        }, ruleToc, baseURL, runtimeContext);
      }).filter(c => c.url || c.isVolume);
    } catch (_) { return []; }
  }

  function parseChapterContent(html, baseURL, ruleContent, runtimeVariablesSeed) {
    const payload = parseChapterPayload(html, baseURL, ruleContent, runtimeVariablesSeed);
    return payload.content || '';
  }

  function parseChapterPayload(html, baseURL, ruleContent, runtimeVariablesSeed) {
    const runtimeContext = ensureRuntimeContext(runtimeVariablesSeed);
    let title = '';
    let content = '';
    if (isJson(html)) {
      try {
        const data = JSON.parse(html);
        content = trim(extractValueFromObject(data, baseURL, ruleContent.content || '', runtimeContext, data));
        title = trim(extractValueFromObject(data, baseURL, ruleContent.title || '', runtimeContext, data));
      } catch (_) {
        return { content: '', title: '', sourceMatched: true, isPay: false, runtimeVariables: cloneRuntimeVariables(runtimeContext) };
      }
    } else {
      content = trim(routeExtractValue(html, baseURL, ruleContent.content || '', null, null, runtimeContext));
      title = trim(routeExtractValue(html, baseURL, ruleContent.title || '', null, null, runtimeContext));
    }
    const sourceMatched = testRegex(ruleContent.sourceRegex || '', html || '') || testRegex(ruleContent.sourceRegex || '', content || '');
    let isPay = false;
    const payAction = trim(ruleContent.payAction || '');
    if (payAction) {
      const payResult = evalUserScript(payAction, {
        result: false,
        html: html || '',
        content,
        title,
        baseUrl: baseURL,
        runtimeContext: runtimeContext,
        java: null
      });
      isPay = asBool(payResult);
    }
    return { content, title, sourceMatched, isPay, runtimeVariables: cloneRuntimeVariables(runtimeContext) };
  }

  var engine = {
    parseSearchResults,
    parseBookInfo,
    parseTOC,
    parseChapterContent,
    parseChapterPayload,
    routeExtractList,
    routeExtractValue,
    resolveURL,
    isJson
  };
  global.BookSourceEngine = engine;
  if (typeof window !== 'undefined') window.BookSourceEngine = engine;
})(typeof self !== 'undefined' ? self : typeof global !== 'undefined' ? global : this);
