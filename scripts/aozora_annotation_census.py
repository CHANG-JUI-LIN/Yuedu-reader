#!/usr/bin/env python3
"""Aozora Bunko annotation census.

Counts which Aozora notations appear in real works so support work can be
prioritised by measured frequency instead of impressions.

Input: a checkout of https://github.com/aozorahack/aozorabunko_text
(cards/<person>/files/<work>_<ruby|txt>_<n>/<name>.txt, Shift_JIS).
The corpus is never copied into this repo: some works are still under
copyright and are only redistributed by Aozora Bunko with permission.

Usage:
    git clone --depth 1 https://github.com/aozorahack/aozorabunko_text /path/to/corpus
    python3 scripts/aozora_annotation_census.py /path/to/corpus [--json out.json]
"""
import argparse
import json
import os
import re
import sys
from collections import Counter
from concurrent.futures import ProcessPoolExecutor

# ---------------------------------------------------------------- structure

HYPHEN_LINE = re.compile(r"^-{10,}\s*$")
TEIHON_LINE = re.compile(r"^底本[：:]")

# ---------------------------------------------------------------- inline

NOTE = re.compile(r"［＃([^］\n]*)］")
GAIJI = re.compile(r"※［＃([^］\n]*)］")
GAIJI_THEN_RUBY = re.compile(r"※［＃[^］\n]*］《[^《》\n]+》")
JIS_CODE = re.compile(r"(?<![\d\-])([12])-(\d{1,2})-(\d{1,2})(?![\d\-])")
UNICODE_CODE = re.compile(r"U\+([0-9A-Fa-f]{4,6})")
RUBY = re.compile(r"《[^《》\n]+》")
EXPLICIT_RUBY = re.compile(r"｜[^｜《\n]+《[^《》\n]+》")
ACCENT = re.compile(r"〔[^〔〕\n]*[A-Za-z][\'`^:~,/&_][^〔〕\n]*〕")
KUNOJITEN = re.compile(r"／″?＼")
UNCLOSED_NOTE = re.compile(r"［＃[^］\n]*\n")

# Ordered: the first matching rule names an annotation.
CATEGORIES = [
    ("structure", re.compile(r"^本文終わり$|^ここから本文|^本文")),
    ("kaeriten", re.compile(r"^(?:[一二三四上中下甲乙丙丁天地人]レ?|レ)$")),
    ("kunten_okurigana", re.compile(r"^（[^）]*）$")),
    ("page_break", re.compile(r"^(?:改ページ|改頁|改丁|改段|改見開き)$")),
    ("line_break", re.compile(r"^改行$")),
    ("page_center", re.compile(r"ページの左右中央")),
    ("heading", re.compile(r"見出")),
    ("indent", re.compile(r"字下げ")),
    ("chitsuki", re.compile(r"地付き|地寄せ|字上げ|右寄せ|左寄せ")),
    ("emphasis_dots", re.compile(r"傍点")),
    ("sideline", re.compile(r"傍線|鎖線|破線|波線")),
    ("bold", re.compile(r"太字")),
    ("italic", re.compile(r"斜体")),
    ("font_size", re.compile(r"大きな文字|小さな文字")),
    ("tate_chu_yoko", re.compile(r"縦中横")),
    ("warichu", re.compile(r"割り注")),
    ("kakomi", re.compile(r"囲み")),
    ("image", re.compile(r"\.(?:png|jpe?g|gif)|入る$")),
    ("caption", re.compile(r"キャプション")),
    ("left_ruby", re.compile(r"の左に「[^」]*」のルビ|左にルビ")),
    ("note_ruby", re.compile(r"の注記|注記付き|の傍記|にルビ|に「[^」]*」付き")),
    ("small_script", re.compile(r"上付き|下付き|行右小書き|行左小書き|小書き")),
    ("yokogumi", re.compile(r"横組み")),
    ("jizume", re.compile(r"字詰め")),
    ("typeface", re.compile(r"ゴシック|ゴチック|明朝|書体|フォント")),
    ("dangumi", re.compile(r"段組")),
    ("editorial", re.compile(r"底本|ママ|入力者|校訂|編集|原文|誤植|脱字|衍字|誤訳|誤記|余分|本当は|ルビの「|の誤り|か？|では「|ルビは「")),
    ("gaiji_unmarked", re.compile(r"第[34]水準|(?<![\d\-])[12]-\d{1,2}-\d{1,2}(?![\d\-])|U\+[0-9A-Fa-f]{4,6}")),
]

# Groups used for cumulative coverage. "css" = expressible with properties the
# legacy EPUB style model already has (textIndent/textAlign/margin/fontSize/
# fontWeight/isItalic/pageBreakBefore/underline).
GROUPS = {
    "css": ["heading", "indent", "chitsuki", "page_break", "line_break", "font_size", "bold", "italic"],
    "emphasis": ["emphasis_dots", "sideline"],
    "long_tail": ["tate_chu_yoko", "warichu", "kaeriten", "kunten_okurigana", "kakomi",
                   "image", "caption", "left_ruby", "note_ruby", "small_script",
                   "yokogumi", "jizume", "page_center", "typeface", "dangumi",
                   "gaiji_unmarked", "other"],
}
INVISIBLE = {"editorial", "structure"}  # proofreading notes and markers; dropping them loses nothing

# ---------------------------------------------------------------- TOC rules
# Mirrors TXTChapterParser.chapterPatterns / specialTitlePattern (line based,
# lines longer than 100 UTF-16 units are ignored, first bucket with >= 2 hits wins).

NUM = "[零一二三四五六七八九十百千萬万\\d]+"
CHAPTER_PATTERNS = [re.compile(p) for p in [
    rf"^\s*第{NUM}章", rf"^\s*第{NUM}[節节]", rf"^\s*第{NUM}卷", rf"^\s*第{NUM}回",
    rf"^\s*第{NUM}篇", rf"^\s*第{NUM}部", rf"^\s*卷{NUM}",
    r"^\s*Chapter\s*\d+", r"^\s*CHAPTER\s*\d+", r"^\s*Part\s*\d+", r"^\s*PART\s*\d+",
]]
SPECIAL_TITLE = re.compile(
    r"^\s*(序章|序言|序幕|前言|引子|引言|楔子|尾聲|尾声|終章|终章|後記|后记|番外|後序|后序|結語|结语"
    r"|Prologue|Epilogue|Preface|Introduction)", re.IGNORECASE)
SECTION_BLOCK_BYTES = 12 * 1024


def utf16_length(text):
    return len(text.encode("utf-16-le")) // 2


def app_toc_titles(lines):
    buckets = [0] * len(CHAPTER_PATTERNS)
    special = 0
    for line in lines:
        if utf16_length(line) > 100:
            continue
        for index, pattern in enumerate(CHAPTER_PATTERNS):
            if pattern.match(line):
                buckets[index] += 1
        if SPECIAL_TITLE.match(line):
            special += 1
    winner = next((count for count in buckets if count >= 2), None)
    if winner is None:
        winner = next((count for count in buckets if count > 0), 0)
    return winner + special


# ---------------------------------------------------------------- decoding

def decode(data):
    for encoding in ("cp932", "utf-8"):
        try:
            return data.decode(encoding), encoding
        except UnicodeDecodeError:
            pass
    return data.decode("cp932", errors="replace"), "cp932-lossy"


def split_sections(lines):
    """aozora2html's states: head -> (chuuki) -> body -> tail."""
    header_end = next((i for i, line in enumerate(lines) if not line.strip()), len(lines))
    body_start = header_end
    has_notation_block = False
    first = next((i for i in range(header_end, min(len(lines), header_end + 5))
                  if lines[i].strip()), None)
    if first is not None and HYPHEN_LINE.match(lines[first]):
        closing = next((i for i in range(first + 1, len(lines)) if HYPHEN_LINE.match(lines[i])), None)
        if closing is not None:
            has_notation_block = True
            body_start = closing + 1
    tail_start = next((i for i in range(body_start, len(lines)) if TEIHON_LINE.match(lines[i])), len(lines))
    return lines[:header_end], body_start, tail_start, has_notation_block


def resolve_jis(plane, row, cell):
    if plane == 1:
        raw = bytes([0xA0 + row, 0xA0 + cell])
    else:
        raw = bytes([0x8F, 0xA0 + row, 0xA0 + cell])
    try:
        text = raw.decode("euc_jis_2004")
    except UnicodeDecodeError:
        return None
    return text or None


def classify(note):
    for name, pattern in CATEGORIES:
        if pattern.search(note):
            return name
    return "other"


def shape(note):
    """Normalise an annotation so unknown kinds can be grouped."""
    note = re.sub(r"「[^」]*」", "「…」", note)
    return re.sub(r"[0-9０-９]+", "N", note)


# ---------------------------------------------------------------- per work

def analyse(path):
    with open(path, "rb") as handle:
        data = handle.read()
    text, encoding = decode(data)
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    lines = text.split("\n")
    _, body_start, tail_start, has_notation_block = split_sections(lines)
    body = "\n".join(lines[body_start:tail_start])

    categories = Counter()
    unknown = Counter()
    headings = 0  # block headings come as a start/end pair; count the start only
    gaiji_positions = {m.start() for m in GAIJI.finditer(body)}
    for match in NOTE.finditer(body):
        if match.start() - 1 in gaiji_positions:
            continue
        note = match.group(1)
        name = classify(note)
        categories[name] += 1
        if name == "heading" and "終わり" not in note:
            headings += 1
        if name == "other":
            unknown[shape(note)] += 1

    gaiji = Counter()
    for match in GAIJI.finditer(body):
        note = match.group(1)
        jis = JIS_CODE.search(note)
        uni = UNICODE_CODE.search(note)
        gaiji["total"] += 1
        if jis:
            resolved = resolve_jis(int(jis.group(1)), int(jis.group(2)), int(jis.group(3)))
            if resolved is None:
                gaiji["jis_unmapped"] += 1
            else:
                gaiji["jis_mapped"] += 1
                if any(ord(ch) > 0xFFFF for ch in resolved):
                    gaiji["non_bmp"] += 1
                if len(resolved) > 1:
                    gaiji["sequence"] += 1
        elif uni:
            gaiji["unicode"] += 1
            if int(uni.group(1), 16) > 0xFFFF:
                gaiji["non_bmp"] += 1
        else:
            gaiji["description_only"] += 1

    toc_titles = app_toc_titles(lines)
    return {
        "path": path,
        "bytes": len(data),
        "encoding": encoding,
        "has_notation_block": has_notation_block,
        "has_tail": tail_start < len(lines),
        "ruby": len(RUBY.findall(body)),
        "explicit_ruby": len(EXPLICIT_RUBY.findall(body)),
        "gaiji": dict(gaiji),
        "gaiji_then_ruby": len(GAIJI_THEN_RUBY.findall(body)),
        "accent": len(ACCENT.findall(body)),
        "kunojiten": len(KUNOJITEN.findall(body)),
        "unclosed_note": len(UNCLOSED_NOTE.findall(body)),
        "categories": dict(categories),
        "unknown": dict(unknown),
        "headings": headings,
        "app_toc_titles": toc_titles,
    }


# ---------------------------------------------------------------- corpus

WORK_DIR = re.compile(r"^(\d+)_(ruby|txt)(?:_(\d+))?$")


def pick_works(root):
    """One file per work: prefer the ruby edition, then the largest file."""
    chosen = {}
    for directory, _, files in os.walk(os.path.join(root, "cards")):
        for name in files:
            if not name.lower().endswith(".txt"):
                continue
            path = os.path.join(directory, name)
            match = WORK_DIR.match(os.path.basename(directory))
            key = match.group(1) if match else path
            rank = (1 if match and match.group(2) == "ruby" else 0, os.path.getsize(path))
            if key not in chosen or rank > chosen[key][0]:
                chosen[key] = (rank, path)
    return sorted(path for _, path in chosen.values())


def pct(part, whole):
    return round(100.0 * part / whole, 1) if whole else 0.0


def summarise(results, file_count):
    works = len(results)
    summary = {"files_scanned": file_count, "works": works}

    encodings = Counter(r["encoding"] for r in results)
    summary["encodings"] = dict(encodings)
    sizes = sorted(r["bytes"] for r in results)
    summary["file_kb"] = {label: round(sizes[min(len(sizes) - 1, int(len(sizes) * q))] / 1024, 1)
                          for label, q in (("p50", 0.5), ("p90", 0.9), ("p99", 0.99), ("max", 1.0))}
    summary["structure"] = {
        "notation_block": pct(sum(r["has_notation_block"] for r in results), works),
        "teihon_tail": pct(sum(r["has_tail"] for r in results), works),
        "unclosed_note_works": sum(1 for r in results if r["unclosed_note"]),
    }

    def works_with(predicate):
        count = sum(1 for r in results if predicate(r))
        return {"works": count, "pct": pct(count, works)}

    summary["inline"] = {
        "ruby": works_with(lambda r: r["ruby"] > 0),
        "explicit_ruby": works_with(lambda r: r["explicit_ruby"] > 0),
        "gaiji": works_with(lambda r: r["gaiji"].get("total", 0) > 0),
        "gaiji_then_ruby": works_with(lambda r: r["gaiji_then_ruby"] > 0),
        "accent": works_with(lambda r: r["accent"] > 0),
        "kunojiten": works_with(lambda r: r["kunojiten"] > 0),
    }

    names = [name for name, _ in CATEGORIES] + ["other"]
    summary["annotations"] = {}
    for name in names:
        containing = sum(1 for r in results if r["categories"].get(name))
        occurrences = sum(r["categories"].get(name, 0) for r in results)
        summary["annotations"][name] = {"works": containing, "pct": pct(containing, works),
                                        "occurrences": occurrences}

    gaiji = Counter()
    for r in results:
        gaiji.update(r["gaiji"])
    total = gaiji.get("total", 0)
    summary["gaiji"] = {key: {"count": value, "pct_of_gaiji": pct(value, total)}
                        for key, value in sorted(gaiji.items())}
    summary["gaiji"]["works_all_resolvable"] = works_with(
        lambda r: r["gaiji"].get("total", 0) > 0
        and r["gaiji"].get("description_only", 0) == 0
        and r["gaiji"].get("jis_unmapped", 0) == 0)
    summary["gaiji"]["works_with_description_only"] = works_with(
        lambda r: r["gaiji"].get("description_only", 0) > 0)
    summary["gaiji"]["works_with_non_bmp"] = works_with(lambda r: r["gaiji"].get("non_bmp", 0) > 0)

    # Text correctness: every character the reader shows is the intended one.
    def text_wrong_now(r):
        return r["gaiji"].get("total", 0) or r["accent"] or r["kunojiten"]

    def text_wrong_after_tables(r):
        return r["gaiji"].get("description_only", 0) or r["gaiji"].get("jis_unmapped", 0)

    summary["text_correct"] = {
        "now": works_with(lambda r: not text_wrong_now(r)),
        "after_gaiji_tables_accent_kunojiten": works_with(lambda r: not text_wrong_after_tables(r)),
    }

    # Formatting: cumulative share of works that lose no visible formatting.
    def lost(r, supported):
        return any(count for name, count in r["categories"].items()
                   if name not in INVISIBLE and name not in supported)

    supported = set()
    steps = [("now", [])]
    steps.append(("+css (heading/indent/chitsuki/page & line break/size/bold/italic)", GROUPS["css"]))
    steps.append(("+emphasis (傍点/傍線)", GROUPS["emphasis"]))
    long_tail = sorted(GROUPS["long_tail"],
                       key=lambda n: -summary["annotations"].get(n, {}).get("works", 0))
    for name in long_tail:
        steps.append((f"+{name}", [name]))
    coverage = []
    for label, names_added in steps:
        supported.update(names_added)
        frozen = set(supported)
        coverage.append({"step": label, **works_with(lambda r: not lost(r, frozen))})
    summary["formatting_coverage"] = coverage

    # Table of contents under today's TXT rules.
    def toc_mode(r):
        if r["app_toc_titles"] > 0:
            return "regex"
        return "sections" if r["bytes"] > SECTION_BLOCK_BYTES else "single"

    modes = Counter(toc_mode(r) for r in results)
    summary["toc"] = {
        "today": {mode: {"works": count, "pct": pct(count, works)} for mode, count in modes.items()},
        "sections_but_has_headings": works_with(lambda r: toc_mode(r) == "sections" and r["headings"] >= 2),
        "has_two_or_more_headings": works_with(lambda r: r["headings"] >= 2),
    }

    unknown = Counter()
    unknown_works = Counter()
    for r in results:
        unknown.update(r["unknown"])
        unknown_works.update(r["unknown"].keys())
    summary["unknown_top"] = [{"shape": s, "occurrences": c, "works": unknown_works[s]}
                              for s, c in unknown.most_common(40)]
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("corpus")
    parser.add_argument("--json")
    parser.add_argument("--limit", type=int, default=0)
    args = parser.parse_args()

    paths = pick_works(args.corpus)
    file_count = sum(1 for _, _, files in os.walk(os.path.join(args.corpus, "cards"))
                     for name in files if name.lower().endswith(".txt"))
    if args.limit:
        paths = paths[: args.limit]
    with ProcessPoolExecutor() as pool:
        results = list(pool.map(analyse, paths, chunksize=64))
    summary = summarise(results, file_count)
    output = json.dumps(summary, ensure_ascii=False, indent=2)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            handle.write(output + "\n")
    print(output)


if __name__ == "__main__":
    sys.exit(main())
