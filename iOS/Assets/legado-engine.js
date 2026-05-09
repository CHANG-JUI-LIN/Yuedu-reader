/**
 * Legado-compatible rule engine for WKWebView
 * Supports: CSS selectors, Legado shorthand, XPath, @attr extractors, ##regex##, JS rules
 * Operators: && (merge) || (fallback) %% (interleave)
 * Exposed as window.LE
 */
(function (W) {
  'use strict';

  // ── URL 解析 ──────────────────────────────────────────────────────────────
  function resolveUrl(href, base) {
    if (!href || href.startsWith('javascript:')) return '';
    try { return new URL(href.trim(), base || document.baseURI).href; } catch (e) { return href.trim(); }
  }

  // ── 操作符分割（跳過括號內容）──────────────────────────────────────────
  function splitOp(rule, op) {
    var parts = [], depth = 0, cur = '', i = 0, L = rule.length, oL = op.length;
    while (i < L) {
      var c = rule[i];
      if ('([{'.indexOf(c) >= 0) depth++;
      else if (')]}'.indexOf(c) >= 0) depth--;
      else if (depth === 0 && rule.substr(i, oL) === op) {
        parts.push(cur); cur = ''; i += oL; continue;
      }
      cur += c; i++;
    }
    parts.push(cur);
    return parts;
  }

  // ── 解析規則：分離選擇器、@attr、##regex## ────────────────────────────
  function parseRule(rule) {
    rule = rule.trim();

    // 提取 ##regex##replacement## 後綴
    var hashIdx = -1, depth = 0;
    for (var i = 0; i < rule.length - 1; i++) {
      if ('([{'.indexOf(rule[i]) >= 0) depth++;
      else if (')]}'.indexOf(rule[i]) >= 0) depth--;
      else if (depth === 0 && rule[i] === '#' && rule[i+1] === '#') { hashIdx = i; break; }
    }
    var post = hashIdx >= 0 ? rule.slice(hashIdx) : '';
    var core = hashIdx >= 0 ? rule.slice(0, hashIdx) : rule;

    // 提取 @attrType（從右往左找最後一個 @text/@href/@src/@html/@owntext/@attr.xxx）
    var attrMatch = core.match(/^([\s\S]*?)@(text|html|href|src|owntext|attr\.[^\s#@]+)$/i);
    if (attrMatch) {
      return { sel: attrMatch[1].trim(), attr: attrMatch[2].toLowerCase(), post: post };
    }
    return { sel: core.trim(), attr: 'text', post: post };
  }

  // ── 提取屬性值 ───────────────────────────────────────────────────────────
  function getAttr(el, attr, baseUrl) {
    if (!el) return '';
    attr = attr.toLowerCase();
    if (attr === 'text') return (el.textContent || '').trim();
    if (attr === 'html')  return el.innerHTML || '';
    if (attr === 'owntext') {
      var t = '';
      el.childNodes.forEach(function (n) { if (n.nodeType === 3) t += n.textContent; });
      return t.trim();
    }
    if (attr === 'href') {
      var href = el.getAttribute('href') || el.href || '';
      return baseUrl ? resolveUrl(href, baseUrl) : href;
    }
    if (attr === 'src') {
      var src = el.getAttribute('src') || el.src || '';
      return baseUrl ? resolveUrl(src, baseUrl) : src;
    }
    if (attr.startsWith('attr.')) return (el.getAttribute(attr.slice(5)) || '').trim();
    return (el.getAttribute(attr) || '').trim();
  }

  // ── 應用正則後處理 ────────────────────────────────────────────────────────
  function applyPost(text, post) {
    if (!post || !post.includes('##')) return text;
    var parts = post.split('##');
    var i = 1;
    while (i + 1 < parts.length) {
      try { text = text.replace(new RegExp(parts[i], 'g'), parts[i + 1] || ''); } catch (e) {}
      i += 2;
    }
    return text;
  }

  // ── 查詢 DOM 元素 ────────────────────────────────────────────────────────
  function queryElements(sel, ctx) {
    sel = (sel || '').trim();
    if (!sel || sel === '.') return ctx ? [ctx] : [document];
    ctx = ctx || document;

    // XPath
    if (sel[0] === '/' || sel.startsWith('./') || sel.startsWith('//')) {
      var res = [], it;
      try {
        it = document.evaluate(sel, ctx, null, XPathResult.ORDERED_NODE_ITERATOR_TYPE, null);
        var n; while ((n = it.iterateNext())) res.push(n);
      } catch (e) {}
      return res;
    }

    // Legado 簡寫：class.name[.index]、tag.name[.index]、id.name
    var lg = sel.match(/^(-?)(class|tag|id)\.([^.\s]+)(?:\.(-?\d+))?$/i);
    if (lg) {
      var rev = lg[1] === '-', type = lg[2].toLowerCase(), name = lg[3];
      var idx = lg[4] !== undefined ? parseInt(lg[4]) : null;
      var els = [];
      if (type === 'class') els = Array.from(ctx.getElementsByClassName(name));
      else if (type === 'tag') els = Array.from(ctx.getElementsByTagName(name));
      else if (type === 'id') { var e = document.getElementById(name); els = e ? [e] : []; }
      if (rev) els = els.reverse();
      if (idx !== null) {
        var realIdx = idx < 0 ? els.length + idx : idx;
        return realIdx >= 0 && realIdx < els.length ? [els[realIdx]] : [];
      }
      return els;
    }

    // 標準 CSS 選擇器
    try { return Array.from(ctx.querySelectorAll(sel)); } catch (e) { return []; }
  }

  // ── 核心：從規則取字串列表（支援所有操作符）─────────────────────────────
  function getList(rule, ctx, baseUrl) {
    rule = (rule || '').trim();
    if (!rule) return [];

    // JS 規則 <js>...</js>
    if (rule.startsWith('<js>')) {
      var end = rule.lastIndexOf('</js>');
      var code = end > 0 ? rule.slice(4, end) : rule.slice(4);
      try {
        var fn = new Function('result', 'baseUrl', 'java', code);
        var r = fn.call(null, '', baseUrl || document.baseURI, {});
        return r !== undefined && r !== null ? [String(r)] : [];
      } catch (e) { return []; }
    }

    // {{js_expr}}
    if (rule.startsWith('{{') && rule.endsWith('}}')) {
      try {
        var fn2 = new Function('return (' + rule.slice(2, -2) + ')');
        return [String(fn2())];
      } catch (e) { return []; }
    }

    // || fallback
    var orParts = splitOp(rule, '||');
    if (orParts.length > 1) {
      for (var i = 0; i < orParts.length; i++) {
        var r2 = getList(orParts[i].trim(), ctx, baseUrl);
        if (r2.length > 0) return r2;
      }
      return [];
    }

    // %% interleave
    var ppParts = splitOp(rule, '%%');
    if (ppParts.length > 1) {
      var lists = ppParts.map(function (p) { return getList(p.trim(), ctx, baseUrl); });
      var res = [], maxLen = Math.max.apply(null, lists.map(function (l) { return l.length; }));
      for (var i = 0; i < maxLen; i++) {
        lists.forEach(function (l) { if (i < l.length) res.push(l[i]); });
      }
      return res;
    }

    // && merge
    var andParts = splitOp(rule, '&&');
    if (andParts.length > 1) {
      var res2 = [];
      andParts.forEach(function (p) { res2 = res2.concat(getList(p.trim(), ctx, baseUrl)); });
      return res2;
    }

    // 單規則
    var pr = parseRule(rule);
    var attr = pr.attr;
    var needsUrl = attr === 'href' || attr === 'src';
    var els = queryElements(pr.sel, ctx);
    return els
      .map(function (el) { return applyPost(getAttr(el, attr, needsUrl ? baseUrl : null), pr.post); })
      .filter(function (s) { return s.trim() !== ''; });
  }

  // ── 取單一字串 ────────────────────────────────────────────────────────────
  function getString(rule, ctx, baseUrl) {
    return getList(rule, ctx, baseUrl).join('\n');
  }

  // ── 取元素列表（用於 bookList / chapterList）──────────────────────────────
  function getElements(rule, ctx) {
    rule = (rule || '').trim();
    if (!rule) return [];

    // || fallback
    var orParts = splitOp(rule, '||');
    if (orParts.length > 1) {
      for (var i = 0; i < orParts.length; i++) {
        var r = getElements(orParts[i].trim(), ctx);
        if (r.length > 0) return r;
      }
      return [];
    }

    // && merge
    var andParts = splitOp(rule, '&&');
    if (andParts.length > 1) {
      var res = [];
      andParts.forEach(function (p) { res = res.concat(getElements(p.trim(), ctx)); });
      return res;
    }

    // 取選擇器部分（排除 @attr 和 ##regex）
    var pr = parseRule(rule);
    return queryElements(pr.sel, ctx || document);
  }

  // ── 全域 API ──────────────────────────────────────────────────────────────
  W.LE = {
    /** 對當前文件（或指定元素）套用規則，返回字串 */
    getString: function (rule, el, baseUrl) {
      return getString(rule, el || null, baseUrl || document.baseURI);
    },
    /** 對當前文件（或指定元素）套用規則，返回字串陣列 */
    getList: function (rule, el, baseUrl) {
      return getList(rule, el || null, baseUrl || document.baseURI);
    },
    /** 用規則選取元素列表（用於書單/目錄） */
    getElements: function (rule) {
      return getElements(rule, document);
    },
    /** 解析相對 URL */
    resolveUrl: function (href, base) {
      return resolveUrl(href, base || document.baseURI);
    }
  };

})(window);
