#!/usr/bin/env python3
"""Render-fidelity oracle: corpus extraction, capture plans and scoring.

Compares the reader's own rendering of an EPUB chapter with a WKWebView
reference. The captures come from `RenderFidelityOracleTests`; this file only
reads them. Contract: docs/browser-layout/fidelity-loop/ORACLE.md.

Frozen by scripts/fidelity/oracle.lock. Standard library only.
"""

import argparse
import datetime
import functools
import hashlib
import html
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import unicodedata
import zipfile
from bisect import bisect_left
from collections import Counter, defaultdict
from pathlib import Path
from urllib.parse import unquote

HERE = Path(__file__).resolve().parent
DEFAULT_OUT = Path.home() / "Library" / "Caches" / "YueduFidelity"

# Scoring constants. Changing any of them changes what a score means: bump
# SCORER_VERSION and re-record the baseline (ORACLE.md, "Changing the oracle").
SCORER_VERSION = 1
PASS_SCORE = 80.0
ALERT_SCORE = 60.0
ITEM_WEIGHTS = {"lines": 0.30, "horizontal": 0.25, "vertical": 0.25, "typography": 0.20}
TYPOGRAPHY_WEIGHTS = {"font-size": 0.60, "bold": 0.15, "italic": 0.10, "color": 0.15}
IMAGE_WEIGHTS = {"image-size": 0.50, "image-position": 0.25, "block-gap": 0.25}
BREAK_CREDIT = {0: 1.0, 1: 0.6, 2: 0.3}       # line start off by N characters
PAINT_NOISE = 8                                # channel difference treated as rendering noise
PAINT_LIMIT = 64                               # channel difference treated as a different colour
INK_MATCH = 48                                 # a cell this close to its text colour is ink, not paper
INLINE_REACH = 0.12                            # a position this share of the line extent off scores 0
SIZE_REACH = 0.20                              # a column this share of the line extent off scores 0
PAINT_FULL_AREA = 0.03                         # share of painted cells that earns the full visual half
EXTRA_TEXT_CAP = 0.30                          # most that text absent from the reference can cost
TEXT_PER_POINT = 0.66                          # weight of a column-wide image per point along the block axis,
                                               # in line-weight units; narrower images weigh proportionally less
WRITING_MODE_FACTOR = 0.30                     # what survives when text runs in the wrong direction
MIN_COVERAGE = 0.5                             # share of a book's sample that must be measured for it to pass

# The language every capture runs in. Font fallback and punctuation follow it on
# both sides, so a capture made under another language is a different measurement.
CAPTURE_LANGUAGE = "zh-Hant"
CAPTURE_REGION = "TW"

# What one slice has to show, and what it may not cost, when two runs are compared.
PROGRESS_STEP = 0.3                            # a book has to rise this much for the slice to count as progress
DEV_TOLERANCE = 0.5                            # how far a book's dev chapters may fall
HOLDOUT_TOLERANCE = 1.0                        # how far a book's holdout chapters may fall
CHAPTER_STEADY = 0.05                          # a chapter within this much of its old score has not moved


# --------------------------------------------------------------------------- corpus

def load_corpus():
    with open(HERE / "corpus.json", encoding="utf-8") as handle:
        return json.load(handle)


def discover_books(corpus):
    """Every *.epub in the corpus folder. A file whose name contains an entry's
    `match` text gets that entry's id and pinned chapters; any other file gets an
    id derived from its name, so a book dropped into the folder is measured too."""
    root = Path(corpus["root"])
    entries = corpus.get("books", [])
    books, used = [], {}
    for path in sorted(root.glob("*.epub")):
        name = unicodedata.normalize("NFC", path.name)
        matches = [entry for entry in entries if unicodedata.normalize("NFC", entry["match"]) in name]
        if len(matches) > 1:
            raise SystemExit(f"{path.name}: matched by several corpus entries: "
                             + ", ".join(entry["id"] for entry in matches))
        if matches:
            book_id, pinned = matches[0]["id"], matches[0].get("pinned", [])
        else:
            book_id, pinned = "book-" + hashlib.sha1(name.encode("utf-8")).hexdigest()[:8], []
        if book_id in used:
            raise SystemExit(f"{path.name} and {used[book_id]} both resolve to the id {book_id}")
        used[book_id] = path.name
        books.append({"id": book_id, "file": path.name, "path": str(path), "pinned": pinned})
    return books


def entry_name(info):
    """A zip entry name as UTF-8. Archives without the UTF-8 flag are read as
    cp437 by zipfile; EPUB producers write UTF-8 regardless."""
    name = info.filename
    if not info.flag_bits & 0x800:
        try:
            name = name.encode("cp437").decode("utf-8")
        except (UnicodeEncodeError, UnicodeDecodeError):
            pass
    return name


def extract_book(book, out):
    """Unpacks one EPUB so WebKit can load its chapters with their own
    relative resources. Returns the extraction root."""
    source = Path(book["path"])
    root = out / "corpus" / book["id"]
    stat = source.stat()
    stamp = f"{source.name}|{stat.st_size}|{int(stat.st_mtime)}"
    marker = root / ".yuedu-fidelity-source"
    if marker.exists() and marker.read_text(encoding="utf-8") == stamp:
        return root
    if root.exists():
        shutil.rmtree(root)
    root.mkdir(parents=True)
    resolved = root.resolve()
    with zipfile.ZipFile(source) as archive:
        for info in archive.infolist():
            name = entry_name(info)
            if name.endswith("/"):
                continue
            target = (root / name).resolve()
            if resolved not in target.parents:
                raise SystemExit(f"{source.name}: entry escapes the extraction root: {name}")
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(info) as reader, open(target, "wb") as writer:
                shutil.copyfileobj(reader, writer)
    marker.write_text(stamp, encoding="utf-8")
    return root


def command_plan(args):
    corpus = load_corpus()
    out = Path(args.out)
    books = discover_books(corpus)
    if not books:
        raise SystemExit(f"no *.epub under {corpus['root']}")
    only = {}
    for item in args.only or []:
        book_id, _, spines = item.partition(":")
        only[book_id] = [int(value) for value in spines.split(",") if value]
    wanted = set(args.books.split(",")) if args.books else None
    if only and wanted is None:
        wanted = set(only)
    unknown = (wanted or set()) - {book["id"] for book in books}
    if unknown:
        raise SystemExit(f"unknown book id: {', '.join(sorted(unknown))}")
    plan_books = []
    for book in books:
        if wanted is not None and book["id"] not in wanted:
            continue
        root = extract_book(book, out)
        entry = {"id": book["id"], "epub": book["path"], "root": str(root),
                 "dev": corpus["sample"]["dev"], "holdout": corpus["sample"]["holdout"], "pinned": book["pinned"]}
        if book["id"] in only:
            entry["only"] = only[book["id"]]
        plan_books.append(entry)
    run_directory = out / "runs" / args.run
    run_directory.mkdir(parents=True, exist_ok=True)
    plan = {"schema": 1, "out": str(out), "run": args.run, "language": CAPTURE_LANGUAGE, "region": CAPTURE_REGION,
            "sides": args.sides.split(","), "sets": args.sets.split(","), "saveTiles": args.tiles, "books": plan_books}
    path = run_directory / "plan.json"
    path.write_text(json.dumps(plan, ensure_ascii=False, indent=1), encoding="utf-8")
    print(path)


# --------------------------------------------------------------------------- text

def utf16_units(text):
    data = text.encode("utf-16-le", "surrogatepass")
    return struct.unpack("<%dH" % (len(data) // 2), data)


def is_unanchored(unit):
    """Characters that never anchor a comparison: spacing, controls, joiners,
    soft hyphens and the object-replacement character."""
    return (unit <= 0x20 or 0x7F <= unit <= 0xA0 or unit == 0xAD or unit == 0x1680
            or 0x2000 <= unit <= 0x200F or 0x2028 <= unit <= 0x202F or 0x205F <= unit <= 0x2064
            or unit == 0x3000 or unit == 0xFEFF or unit == 0xFFFC or 0xDC00 <= unit <= 0xDFFF)


@functools.lru_cache(maxsize=None)
def fold(code):
    """One code point for a character however a renderer chose to present it.

    Vertical text is commonly set with presentation forms (︐ for ，, ﹁ for 「) and
    a renderer may swap full-width and half-width twins; to a reader these are the
    same character in the same place. The first code point of the compatibility
    form stands for all of them, and both sides are folded alike."""
    if 0xD800 <= code <= 0xDFFF:
        return code
    text = unicodedata.normalize("NFKC", chr(code))
    return ord(text[0]) if text else code


def normalize(text):
    """The anchoring characters of a text stream and their UTF-16 offsets."""
    units = utf16_units(text)
    characters, offsets = [], []
    index, count = 0, len(units)
    while index < count:
        unit = units[index]
        if 0xD800 <= unit <= 0xDBFF and index + 1 < count and 0xDC00 <= units[index + 1] <= 0xDFFF:
            characters.append(fold(0x10000 + ((unit - 0xD800) << 10) + (units[index + 1] - 0xDC00)))
            offsets.append(index)
            index += 2
            continue
        if not is_unanchored(unit):
            characters.append(fold(unit))
            offsets.append(index)
        index += 1
    return characters, offsets


def align(a, b, gram=6, look=3000):
    """For each character of `a`, the index of the same character in `b`, or -1.
    Monotone. Runs of equal characters pair directly; after a difference the
    two streams resume at the nearest shared `gram`-character sequence."""
    matches = [-1] * len(a)
    if a == b:
        return list(range(len(a)))
    index = None
    i = j = 0
    n, m = len(a), len(b)
    while i < n and j < m:
        if a[i] == b[j]:
            matches[i] = j
            i += 1
            j += 1
            continue
        if index is None:
            index = defaultdict(list)
            for position in range(m - gram + 1):
                index[tuple(b[position:position + gram])].append(position)
        best = None
        for skip_a in range(min(look, n - i - gram + 1)):
            if best is not None and skip_a >= best[0]:
                break
            positions = index.get(tuple(a[i + skip_a:i + skip_a + gram]))
            if not positions:
                continue
            at = bisect_left(positions, j)
            if at == len(positions):
                continue
            cost = skip_a + positions[at] - j
            if best is None or cost < best[0]:
                best = (cost, skip_a, positions[at] - j)
        if best is None:
            # Nothing shared within reach on this side; move on and try again.
            i += max(1, min(look, n - i - gram + 1))
            continue
        i += best[1]
        j += best[2]
    return matches


# --------------------------------------------------------------------------- geometry

def soft(difference, tolerance, zero):
    """1 within `tolerance`, 0 at `zero` and beyond, linear in between."""
    difference = abs(difference)
    if difference <= tolerance:
        return 1.0
    if difference >= zero or zero <= tolerance:
        return 0.0
    return 1.0 - (difference - tolerance) / (zero - tolerance)


def median(values):
    ordered = sorted(values)
    middle = len(ordered) // 2
    return ordered[middle] if len(ordered) % 2 else (ordered[middle - 1] + ordered[middle]) / 2


class Side:
    """One capture in logical coordinates: `i` along a line, `b` across lines.
    Vertical-rl text runs down and its lines advance leftwards, so the block
    axis is measured from the document's right edge."""

    def __init__(self, dump, directory=None, vertical=None):
        self.dump = dump
        self.vertical = dump.get("writingMode", "horizontal-tb").startswith("vertical") if vertical is None else vertical
        self.width = float(dump.get("contentWidth", 0))
        self.height = float(dump.get("contentHeight", 0))
        self.inline_extent = float(dump.get("viewportHeight" if self.vertical else "viewportWidth", 0)) or 366.0
        self.characters, self.offsets = normalize(dump.get("text", ""))
        self.fragment_of = [-1] * len(self.characters)
        self.fragments, self.first_character = [], []
        for fragment in sorted(dump.get("fragments", []), key=lambda f: (f["s"], f["e"])):
            low = bisect_left(self.offsets, fragment["s"])
            high = bisect_left(self.offsets, fragment["e"])
            if low == high:
                continue            # spacing, line ends, placeholders: nothing to anchor on
            for character in range(low, high):
                self.fragment_of[character] = len(self.fragments)
            self.fragments.append(fragment)
            self.first_character.append(low)
        self.boxes = [self.box(f) for f in self.fragments]
        self.line_of, self.lines = self.build_lines()
        self.images = [dict(image, box=self.box(image)) for image in dump.get("images", [])
                       if not image.get("page") and image.get("w", 0) > 0 and image.get("h", 0) > 0]
        self.grid = None
        cells = dump.get("cells")
        if directory is not None and cells:
            path = Path(directory) / cells["file"]
            if path.exists():
                self.grid = Grid(path.read_bytes(), cells["cols"], cells["rows"], cells["size"], self)

    def box(self, item):
        """(inline start, inline end, block start, block end)."""
        if self.vertical:
            return (item["y"], item["y"] + item["h"], self.width - (item["x"] + item["w"]), self.width - item["x"])
        return (item["x"], item["x"] + item["w"], item["y"], item["y"] + item["h"])

    def build_lines(self):
        """Groups fragments, in document order, into visual lines. A fragment
        stays on the current line when it overlaps the previous fragment across
        lines, their centres are closer than half the taller one (tightly leaded
        lines overlap too), and it sits next to the line along it."""
        line_of = [-1] * len(self.fragments)
        lines = []
        previous = None
        for number, fragment in enumerate(self.fragments):
            i0, i1, b0, b1 = self.boxes[number]
            same = False
            if previous is not None and lines:
                overlap = min(b1, previous[3]) - max(b0, previous[2])
                smaller = min(b1 - b0, previous[3] - previous[2])
                larger = max(b1 - b0, previous[3] - previous[2])
                apart = abs((b0 + b1) - (previous[2] + previous[3])) / 2
                line = lines[-1]
                gap = max(i0 - line["i1"], line["i0"] - i1, 0.0)
                same = smaller > 0 and overlap >= 0.4 * smaller and apart <= 0.5 * larger \
                    and gap <= max(40.0, 2.5 * fragment.get("fs", 0))
            if same:
                line = lines[-1]
                line["fragments"].append(number)
                line["i0"] = min(line["i0"], i0)
                line["i1"] = max(line["i1"], i1)
            else:
                lines.append({"fragments": [number], "i0": i0, "i1": i1})
            line_of[number] = len(lines) - 1
            previous = (i0, i1, b0, b1)
        return line_of, lines

    def line_shape(self, fragment_numbers):
        """Extent and centre of the part of a line drawn by these fragments;
        the longest fragment decides the centre and the font size."""
        lead = max(fragment_numbers, key=lambda n: self.boxes[n][1] - self.boxes[n][0])
        boxes = [self.boxes[n] for n in fragment_numbers]
        return {"i0": min(b[0] for b in boxes), "i1": max(b[1] for b in boxes),
                "b0": min(b[2] for b in boxes), "b1": max(b[3] for b in boxes),
                "center": (self.boxes[lead][2] + self.boxes[lead][3]) / 2,
                "size": self.fragments[lead].get("fs", 0)}


class Grid:
    """The 4pt pixel grid of one capture, addressed in logical coordinates."""

    def __init__(self, data, cols, rows, size, side):
        self.data, self.cols, self.rows, self.size, self.side = data, cols, rows, size, side
        self.blocks = cols if side.vertical else rows       # cells across lines
        self.inlines = rows if side.vertical else cols      # cells along a line
        # 0 where no text is drawn, otherwise 1 + the index of its colour.
        self.text = bytearray(self.blocks * self.inlines)
        self.inks = []
        known = {}
        ruby = side.dump.get("ruby", [])
        for item, (i0, i1, b0, b1) in zip(side.fragments + ruby, side.boxes + [side.box(r) for r in ruby]):
            ink = hex_color(item.get("c"))
            if ink not in known and len(self.inks) < 254:
                known[ink] = len(self.inks)
                self.inks.append(ink)
            mark = 1 + known.get(ink, 0)
            for block in range(max(0, int(b0 // size)), min(self.blocks, int(b1 // size) + 1)):
                row = block * self.inlines
                for inline in range(max(0, int(i0 // size)), min(self.inlines, int(i1 // size) + 1)):
                    self.text[row + inline] = mark
        sample = Counter()
        for cell in range(0, cols * rows, 7):
            sample[bytes(data[cell * 6 + 3:cell * 6 + 6])] += 1
        self.background = tuple(sample.most_common(1)[0][0]) if sample else (255, 255, 255)

    def is_ink(self, mark, color):
        """Whether a text cell shows its glyphs rather than the paper under them:
        large or bold text covers most of a cell."""
        ink = self.inks[mark - 1]
        return channel_distance(color, ink) <= INK_MATCH and channel_distance(ink, self.background) > INK_MATCH

    def offset(self, block, inline):
        """Byte offset of a logical cell, or -1 outside the capture."""
        if not (0 <= block < self.blocks and 0 <= inline < self.inlines):
            return -1
        if self.side.vertical:
            column = int((self.side.width - (block + 0.5) * self.size) // self.size)
            if not 0 <= column < self.cols:
                return -1
            return (inline * self.cols + column) * 6
        return (block * self.cols + inline) * 6


# --------------------------------------------------------------------------- scoring

def channel_distance(a, b):
    return max(abs(a[0] - b[0]), abs(a[1] - b[1]), abs(a[2] - b[2]))


def hex_color(value):
    try:
        return (int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16))
    except (ValueError, TypeError, IndexError):
        return (0, 0, 0)


def basename(source):
    return unquote(str(source or "").split("#")[0].split("?")[0]).rsplit("/", 1)[-1].lower()


def break_score(reference, engine):
    """Agreement of line starts inside one paragraph (its first start excluded)."""
    if not reference and not engine:
        return 1.0
    if not reference or not engine:
        return 0.0

    def credit(starts, others):
        total = 0.0
        for start in starts:
            at = bisect_left(others, start)
            nearest = min((abs(others[k] - start) for k in (at - 1, at) if 0 <= k < len(others)), default=None)
            total += BREAK_CREDIT.get(nearest, 0.0)
        return total / len(starts)

    recall, precision = credit(reference, engine), credit(engine, reference)
    return 0.0 if recall + precision == 0 else 2 * recall * precision / (recall + precision)


def flags_of(block):
    flags = list(block.get("ctx", []))
    for flag in block.get("own", []):
        if flag not in flags:
            flags.append(flag)
    return flags or ["plain"]


def score_chapter(reference, engine):
    """Scores one chapter. Returns a plain dict: total, layout, visual, the
    points lost per reason and per CSS context, and the per-item records."""
    lost = Counter()            # reason → layout points (of 100) lost
    context = Counter()         # (reason, flag) → layout points lost
    matches = align(reference.characters, engine.characters)
    blocks = {block["i"]: block for block in reference.dump.get("blocks", [])}
    viewport = float(reference.dump.get("viewportHeight", 776)) or 776.0

    # Reference paragraphs: consecutive fragments of one block container.
    paragraphs = []
    for number, fragment in enumerate(reference.fragments):
        if paragraphs and paragraphs[-1]["block"] == fragment.get("b", -1):
            paragraphs[-1]["fragments"].append(number)
        else:
            paragraphs.append({"kind": "text", "block": fragment.get("b", -1), "fragments": [number],
                               "at": fragment["s"]})
    items = paragraphs + [{"kind": "image", "at": image.get("at", 0), "image": image} for image in reference.images]
    items.sort(key=lambda item: (item["at"], 0 if item["kind"] == "image" else 1))

    # Images pair by file name, in order. The legacy route knows an image's
    # place in the text only to the nearest chunk; where it sits decides the rest.
    engine_images = sorted(engine.images, key=lambda image: (image.get("at", 0), image["box"][2], image["box"][0]))
    taken, cursor = set(), 0
    for item in items:
        if item["kind"] != "image":
            continue
        name = basename(item["image"].get("src"))

        def shows(k):
            # A picture that does not say which file it came from can be any file; order decides.
            other = basename(engine_images[k].get("src"))
            return not name or not other or other == name

        found = next((k for k in range(cursor, len(engine_images)) if k not in taken and shows(k)), None)
        if found is None:
            found = next((k for k in range(len(engine_images))
                          if k not in taken and name and basename(engine_images[k].get("src")) == name), None)
        if found is not None:
            taken.add(found)
            cursor = found + 1
            item["engine"] = engine_images[found]

    records, anchors = [], []
    weight_sum = score_sum = 0.0
    previous_reference = previous_engine = None      # block-axis exit of the previous item

    def lose(reason, points, flags):
        if points <= 0:
            return
        lost[reason] += points
        for flag in flags:
            context[(reason, flag)] += points / len(flags)

    for item in items:
        if item["kind"] == "image":
            box = item["image"]["box"]
            flags = flags_of(blocks.get(item["image"].get("b", -1), {}))
            # The text that would fill the same area: the full line extent for
            # a picture as wide as the column, a sliver for one the size of a character.
            weight = (TEXT_PER_POINT * min(box[3] - box[2], viewport)
                      * min(1.0, max(box[1] - box[0], 0.0) / reference.inline_extent))
            entry_reference, exit_reference = box[2], box[3]
            other = item.get("engine")
            parts = {}
            if other is None:
                score, entry_engine, exit_engine = 0.0, None, None
                losses = {"image-missing": 1.0}
            else:
                ebox = other["box"]
                width, height = box[1] - box[0], box[3] - box[2]
                parts["image-size"] = 0.5 * soft((ebox[1] - ebox[0]) - width, max(2.0, 0.02 * width), 0.5 * width) \
                    + 0.5 * soft((ebox[3] - ebox[2]) - height, max(2.0, 0.02 * height), 0.5 * height)
                parts["image-position"] = 0.5 * soft(ebox[0] - box[0], 2.0, 32.0) + 0.5 * soft(ebox[1] - box[1], 2.0, 32.0)
                entry_engine, exit_engine = ebox[2], ebox[3]
                if previous_engine is not None or previous_reference is None:
                    gap_reference = entry_reference - (previous_reference or 0.0)
                    gap_engine = entry_engine - (previous_engine or 0.0)
                    parts["block-gap"] = soft(gap_engine - gap_reference, 2.0, max(12.0, 0.5 * abs(gap_reference)))
                used = sum(IMAGE_WEIGHTS[name] for name in parts)
                score = sum(IMAGE_WEIGHTS[name] * value for name, value in parts.items()) / used
                losses = {name: IMAGE_WEIGHTS[name] * (1 - value) / used for name, value in parts.items()}
                anchors.append((box[2], ebox[2]))
                anchors.append((box[3], ebox[3]))
            records.append({"kind": "image", "weight": weight, "score": score, "flags": flags, "losses": losses,
                            "src": basename(item["image"].get("src"))})
            previous_reference, previous_engine = exit_reference, exit_engine
            weight_sum += weight
            score_sum += weight * score
            continue

        block = blocks.get(item["block"], {})
        flags = flags_of(block)
        # A block's direction is the document's unless the capture flagged it as different.
        rtl = (reference.dump.get("direction", "ltr") == "rtl") != ("mixed-direction" in block.get("own", []))
        # Reference lines of this paragraph, in order, each with its first character.
        reference_lines, reference_starts = [], []
        for number in item["fragments"]:
            line = reference.line_of[number]
            if reference_lines and reference_lines[-1][0] == line:
                reference_lines[-1][1].append(number)
            else:
                reference_lines.append((line, [number]))
                reference_starts.append(reference.first_character[number])
        reference_shapes = [reference.line_shape(numbers) for _, numbers in reference_lines]
        weight = sum(max(shape["size"], 1.0) for shape in reference_shapes)
        # The same characters on the engine side.
        total = matched = 0
        engine_lines, engine_starts, pairs = [], [], Counter()
        for number in item["fragments"]:
            fragment = reference.fragments[number]
            low = reference.first_character[number]
            high = bisect_left(reference.offsets, fragment["e"])
            for character in range(low, high):
                total += 1
                partner = matches[character]
                if partner < 0:
                    continue
                other = engine.fragment_of[partner]
                if other < 0:
                    continue
                matched += 1
                pairs[(number, other)] += 1
                line = engine.line_of[other]
                if engine_lines and engine_lines[-1][0] == line:
                    if other not in engine_lines[-1][2]:
                        engine_lines[-1][1].append(other)
                        engine_lines[-1][2].add(other)
                else:
                    engine_lines.append((line, [other], {other}))
                    engine_starts.append(character)
        ratio = matched / total if total else 0.0
        entry_reference, exit_reference = reference_shapes[0]["center"], reference_shapes[-1]["center"]
        if not engine_lines:
            records.append({"kind": "text", "weight": weight, "score": 0.0, "flags": flags,
                            "losses": {"missing-text": 1.0}, "block": item["block"], "lines": len(reference_lines)})
            previous_reference, previous_engine = exit_reference, None
            weight_sum += weight
            continue
        engine_shapes = [engine.line_shape(numbers) for _, numbers, _ in engine_lines]
        lines_a, lines_b = len(reference_shapes), len(engine_shapes)
        count = 1 - abs(lines_a - lines_b) / max(lines_a, lines_b)
        breaks = break_score(reference_starts[1:], engine_starts[1:])
        parts = {"line-count": (0.5, count), "line-break": (0.5, breaks)}
        lines_score = 0.5 * count + 0.5 * breaks

        def start_edge(shape):
            return shape["i1"] if rtl else shape["i0"]

        def end_edge(shape):
            return shape["i0"] if rtl else shape["i1"]

        def center(shape):
            return (shape["i0"] + shape["i1"]) / 2

        # Where the text column sits, how wide it is, and the first line's indent
        # inside it are judged separately: a shifted block is not also a wrong indent.
        direction = -1.0 if rtl else 1.0
        extent = reference.inline_extent
        horizontal = {}
        if lines_a >= 2 and lines_b >= 2:
            start_a = median([start_edge(s) for s in reference_shapes[1:]])
            start_b = median([start_edge(s) for s in engine_shapes[1:]])
            end_a = median([end_edge(s) for s in reference_shapes[:-1]])
            end_b = median([end_edge(s) for s in engine_shapes[:-1]])
            horizontal["inline-start"] = soft(start_b - start_a, 1.5, INLINE_REACH * extent)
            horizontal["inline-size"] = soft(abs(end_b - start_b) - abs(end_a - start_a), 2.0, SIZE_REACH * extent)
            horizontal["indent"] = soft(direction * ((start_edge(engine_shapes[0]) - start_b)
                                                     - (start_edge(reference_shapes[0]) - start_a)),
                                        1.5, max(16.0, reference_shapes[0]["size"]))
        else:
            horizontal["inline-start"] = soft(start_edge(engine_shapes[0]) - start_edge(reference_shapes[0]),
                                              1.5, INLINE_REACH * extent)
            if lines_a == 1 and lines_b == 1:
                horizontal["alignment"] = soft(center(engine_shapes[0]) - center(reference_shapes[0]),
                                               1.5, INLINE_REACH * extent)
        horizontal_score = sum(horizontal.values()) / len(horizontal)

        entry_engine, exit_engine = engine_shapes[0]["center"], engine_shapes[-1]["center"]
        vertical = {}
        if lines_a >= 2 and lines_b >= 2:
            pitch_reference = (exit_reference - entry_reference) / (lines_a - 1)
            pitch_engine = (exit_engine - entry_engine) / (lines_b - 1)
            vertical["line-pitch"] = soft(pitch_engine - pitch_reference, 0.6, max(2.0, 0.3 * abs(pitch_reference)))
        if previous_engine is not None or previous_reference is None:
            gap_reference = entry_reference - (previous_reference or 0.0)
            gap_engine = entry_engine - (previous_engine or 0.0)
            vertical["block-gap"] = soft(gap_engine - gap_reference, 2.0,
                                         max(12.0, reference_shapes[0]["size"], 0.5 * abs(gap_reference)))
        vertical_score = sum(vertical.values()) / len(vertical) if vertical else 1.0

        typography = dict.fromkeys(TYPOGRAPHY_WEIGHTS, 0.0)
        for (number, other), characters in pairs.items():
            a, b = reference.fragments[number], engine.fragments[other]
            share = characters / matched
            size = a.get("fs", 0)
            if abs(size - b.get("fs", 0)) <= max(0.6, 0.04 * size):
                typography["font-size"] += share
            if (a.get("fw", 400) >= 600) == (b.get("fw", 400) >= 600):
                typography["bold"] += share
            if bool(a.get("it")) == bool(b.get("it")):
                typography["italic"] += share
            if channel_distance(hex_color(a.get("c")), hex_color(b.get("c"))) <= 32:
                typography["color"] += share
        typography_score = sum(TYPOGRAPHY_WEIGHTS[name] * value for name, value in typography.items())

        body = (ITEM_WEIGHTS["lines"] * lines_score + ITEM_WEIGHTS["horizontal"] * horizontal_score
                + ITEM_WEIGHTS["vertical"] * vertical_score + ITEM_WEIGHTS["typography"] * typography_score)
        score = ratio * body
        losses = {"missing-text": 1 - ratio}
        for name, (share, value) in parts.items():
            losses[name] = ratio * ITEM_WEIGHTS["lines"] * share * (1 - value)
        for name, value in horizontal.items():
            losses[name] = ratio * ITEM_WEIGHTS["horizontal"] * (1 - value) / len(horizontal)
        for name, value in vertical.items():
            losses[name] = ratio * ITEM_WEIGHTS["vertical"] * (1 - value) / len(vertical)
        for name, value in typography.items():
            losses[name] = ratio * ITEM_WEIGHTS["typography"] * TYPOGRAPHY_WEIGHTS[name] * (1 - value)
        records.append({"kind": "text", "weight": weight, "score": score, "flags": flags, "losses": losses,
                        "block": item["block"], "lines": lines_a, "engineLines": lines_b})
        anchors.append((min(s["b0"] for s in reference_shapes), min(s["b0"] for s in engine_shapes)))
        anchors.append((max(s["b1"] for s in reference_shapes), max(s["b1"] for s in engine_shapes)))
        previous_reference, previous_engine = exit_reference, exit_engine
        weight_sum += weight
        score_sum += weight * score

    # Text the engine draws that the reference does not contain.
    drawn = sum(1 for number in engine.fragment_of if number >= 0)
    paired = set(partner for partner in matches if partner >= 0)
    extra = sum(1 for character, number in enumerate(engine.fragment_of) if number >= 0 and character not in paired)
    extra_factor = 1.0 - min(EXTRA_TEXT_CAP, extra / drawn) if drawn else 1.0

    if weight_sum > 0:
        layout = score_sum / weight_sum * extra_factor
        for record in records:
            for reason, share in record["losses"].items():
                lose(reason, 100.0 * record["weight"] * share / weight_sum, record["flags"])
        lose("extra-text", 100.0 * (score_sum / weight_sum) * (1 - extra_factor), ["plain"])
    else:
        # Nothing to read in the reference: the engine should draw nothing either.
        layout = 1.0 if not drawn and not engine.images else 0.5
        lose("extra-text", 100.0 * (1 - layout), ["plain"])

    visual, area, paint_lost = score_paint(reference, engine, anchors)
    if reference.vertical != engine.vertical:
        # Everything above compares along and across lines, so text set in the
        # wrong direction would otherwise look identical. It is the most visible
        # difference there is: the chapter keeps a fraction of what it earned.
        lose("writing-mode", 100.0 * layout * (1 - WRITING_MODE_FACTOR), ["plain"])
        paint_lost = dict(paint_lost, **{"writing-mode": 100.0 * visual * (1 - WRITING_MODE_FACTOR)})
        layout *= WRITING_MODE_FACTOR
        visual *= WRITING_MODE_FACTOR
    visual_weight = 0.5 * min(1.0, area / PAINT_FULL_AREA)
    total = 100.0 * (0.5 * layout + visual_weight * visual) / (0.5 + visual_weight)
    return {
        "total": total, "layout": 100.0 * layout, "visual": 100.0 * visual, "visualWeight": visual_weight,
        "paintArea": area, "matched": sum(1 for partner in matches if partner >= 0),
        "referenceCharacters": len(reference.characters), "engineCharacters": len(engine.characters),
        "lost": dict(lost), "context": {f"{reason}|{flag}": points for (reason, flag), points in context.items()},
        "paintLost": paint_lost, "items": len(records),
        "worstItems": sorted(({"kind": r["kind"], "score": round(r["score"], 3), "weight": round(r["weight"], 1),
                               "flags": r["flags"], "block": r.get("block"), "src": r.get("src"),
                               "lines": r.get("lines"), "engineLines": r.get("engineLines"),
                               "losses": {k: round(v, 3) for k, v in r["losses"].items() if v > 0.005}}
                              for r in records if r["score"] < 0.9),
                             key=lambda r: (r["score"] - 1) * r["weight"])[:12],
    }


def score_paint(reference, engine, anchors):
    """Compares what is painted, cell by cell, after sliding the engine's
    rendering so that the same paragraphs and images sit on the same rows.

    Text is scored from geometry, so under text only the paper colour counts.
    Returns (similarity, share of cells carrying paint, points lost per class)."""
    a, b = reference.grid, engine.grid
    if a is None or b is None:
        return 1.0, 0.0, {}
    # A strictly increasing subset of the anchors: a chapter whose items are not
    # stacked (floats, table cells) keeps the ones that are.
    chain = []
    for pair in sorted(anchors):
        if not chain or (pair[0] > chain[-1][0] + 0.5 and pair[1] >= chain[-1][1]):
            chain.append(pair)
    positions = [pair[0] for pair in chain]

    def project(block):
        if not chain:
            return block
        at = bisect_left(positions, block)
        if at == 0:
            return block + chain[0][1] - chain[0][0]
        if at == len(chain):
            return block + chain[-1][1] - chain[-1][0]
        (a0, b0), (a1, b1) = chain[at - 1], chain[at]
        return b0 + (block - a0) * (b1 - b0) / (a1 - a0)

    # What the reference paints, by class, to say where a difference came from.
    classes = bytearray(a.blocks * a.inlines)

    def mark(box, value):
        for block in range(max(0, int(box[2] // a.size)), min(a.blocks, int(box[3] // a.size) + 1)):
            row = block * a.inlines
            for inline in range(max(0, int(box[0] // a.size)), min(a.inlines, int(box[1] // a.size) + 1)):
                classes[row + inline] = value

    for painted in reference.dump.get("boxes", []):
        if painted.get("page"):
            continue
        box = reference.box(painted)
        if painted.get("bg") or painted.get("image"):
            mark(box, 2)
        elif any(painted.get("bw", [])):
            mark(box, 3)
    for image in reference.images:
        mark(image["box"], 1)
    names = {0: "other", 1: "image", 2: "background", 3: "border"}

    extent = max([box[3] for box in reference.boxes] + [image["box"][3] for image in reference.images]
                 + [reference.box(painted)[3] for painted in reference.dump.get("boxes", []) if not painted.get("page")]
                 + [a.size])
    rows = min(a.blocks, int(extent // a.size) + 1)
    page_differs = channel_distance(a.background, b.background) > PAINT_NOISE
    data_a, data_b, size = a.data, b.data, a.size
    considered = similar = 0.0
    lost = Counter()
    for block in range(rows):
        other_block = int(project((block + 0.5) * size) // b.size)
        row_a, row_b = block * a.inlines, other_block * b.inlines
        in_b = 0 <= other_block < b.blocks
        for inline in range(a.inlines):
            at = a.offset(block, inline)
            if at < 0:
                continue
            to = b.offset(other_block, inline) if in_b else -1
            text_a = a.text[row_a + inline]
            text_b = b.text[row_b + inline] if to >= 0 and inline < b.inlines else 0
            shift = 3 if text_a or text_b else 0
            color_a = (data_a[at + shift], data_a[at + shift + 1], data_a[at + shift + 2])
            color_b = (data_b[to + shift], data_b[to + shift + 1], data_b[to + shift + 2]) if to >= 0 else b.background
            if (text_a and a.is_ink(text_a, color_a)) or (text_b and b.is_ink(text_b, color_b)):
                continue
            difference = channel_distance(color_a, color_b)
            if not page_differs and difference <= PAINT_NOISE \
                    and channel_distance(color_a, a.background) <= PAINT_NOISE \
                    and channel_distance(color_b, b.background) <= PAINT_NOISE:
                continue
            considered += 1
            likeness = 1.0 - min(1.0, max(0.0, (difference - PAINT_NOISE) / (PAINT_LIMIT - PAINT_NOISE)))
            similar += likeness
            if likeness < 1.0:
                lost[names[classes[row_a + inline]]] += 1.0 - likeness
    if not considered:
        return 1.0, 0.0, {}
    visual = similar / considered
    return visual, considered / (rows * a.inlines), {name: 100.0 * value / considered for name, value in lost.items()}


# --------------------------------------------------------------------------- run report

def load_side(directory, vertical=None):
    with open(Path(directory) / "dump.json", encoding="utf-8") as handle:
        return Side(json.load(handle), directory, vertical)


def load_pair(reference_directory, engine_directory):
    """Both captures of one chapter, ready to compare.

    A reader sets a whole book in the book's writing mode; a page of that book
    with nothing to read on it (a cover) has no direction to get wrong, and the
    reference reports it in the default one. Its pictures are then compared
    where they are on the page, in the reference's frame."""
    reference, engine = load_side(reference_directory), load_side(engine_directory)
    if engine.vertical != reference.vertical and not reference.characters:
        engine = load_side(engine_directory, vertical=reference.vertical)
    return reference, engine


def command_score(args):
    out = Path(args.out)
    run_directory = out / "runs" / args.run
    with open(run_directory / "capture-index.json", encoding="utf-8") as handle:
        index = json.load(handle)
    reference_root = out / "ref" / index["refKey"]
    chapters, skipped = [], []
    for entry in index["chapters"]:
        if "spine" not in entry:
            skipped.append({"book": entry.get("book"), "reason": entry.get("error", "unknown")})
            continue
        key = {"book": entry["book"], "spine": entry["spine"], "set": entry.get("set"), "href": entry.get("href")}
        reference_directory = reference_root / entry["book"] / str(entry["spine"])
        engine_directory = run_directory / entry["book"] / str(entry["spine"])
        problem = entry.get("error") or entry.get("webkitError") or entry.get("engineError")
        if not problem and not (reference_directory / "dump.json").exists():
            problem = "reference capture missing"
        if not problem and not (engine_directory / "dump.json").exists():
            problem = "engine capture missing"
        if problem:
            skipped.append(dict(key, reason=problem, side="engine" if entry.get("engineError") else "reference"))
            continue
        reference, engine = load_pair(reference_directory, engine_directory)
        if reference.dump.get("parseError"):
            skipped.append(dict(key, reason="reference reported an XML parse error", side="reference"))
            continue
        result = score_chapter(reference, engine)
        result.update(key, route=engine.dump.get("route"), routeDetail=engine.dump.get("routeDetail"),
                      writingMode=reference.dump.get("writingMode"), engineWritingMode=engine.dump.get("writingMode"),
                      frameTimeouts=reference.dump.get("frameTimeouts", 0),
                      referenceLate=reference.dump.get("late") or "")
        chapters.append(result)
        if args.verbose:
            print(f"{entry['book']:22} {entry['spine']:5d} {result['total']:6.1f}  layout {result['layout']:5.1f}"
                  f"  visual {result['visual']:5.1f} ×{result['visualWeight']:.2f}  {result['routeDetail']}")

    report = build_report(index, chapters, skipped)
    # Which code was measured; written by measure.sh next to the capture.
    provenance = run_directory / "provenance.json"
    if provenance.exists():
        with open(provenance, encoding="utf-8") as handle:
            report["provenance"] = json.load(handle)
    (run_directory / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=1), encoding="utf-8")
    text = render_markdown(report)
    (run_directory / "report.md").write_text(text, encoding="utf-8")
    (run_directory / "index.html").write_text(render_html(report, run_directory, reference_root), encoding="utf-8")
    if args.markdown:
        Path(args.markdown).write_text(text, encoding="utf-8")
    print(text)
    print(f"report: {run_directory / 'report.md'}")
    print(f"side by side: {run_directory / 'index.html'}")
    if args.require_goal and not report["goalMet"]:
        sys.exit(3)


def fallback_reasons(chapter):
    """Why a chapter was handed to the legacy renderer: `legacy: capability a,b` names two reasons."""
    detail = chapter.get("routeDetail") or ""
    if chapter.get("route") != "legacy" or ":" not in detail:
        return set()
    rest = detail.partition(":")[2].strip()
    kind, _, names = rest.partition(" ")
    if kind != "capability":
        return {rest}
    return {name.strip() for name in names.split(",") if name.strip()}


def build_report(index, chapters, skipped):
    books = {}
    for chapter in chapters:
        books.setdefault(chapter["book"], []).append(chapter)
    book_rows = []
    gaps = Counter()            # (reason, flag) → points lost, averaged per book
    reasons = Counter()
    paint = Counter()
    routes = Counter()
    for book_id in sorted(books):
        rows = books[book_id]
        count = len(rows)

        def mean(values):
            values = list(values)
            return sum(values) / len(values) if values else None

        score = mean(row["total"] for row in rows)
        missing = [entry for entry in skipped if entry.get("book") == book_id]
        failed = sum(1 for entry in missing if entry.get("side") == "engine")
        measured = count / (count + len(missing)) >= MIN_COVERAGE
        book_rows.append({
            "book": book_id, "score": score, "chapters": count, "unmeasured": len(missing), "engineFailed": failed,
            "dev": mean(row["total"] for row in rows if row["set"] == "dev"),
            "holdout": mean(row["total"] for row in rows if row["set"] == "holdout"),
            "layout": mean(row["layout"] for row in rows), "visual": mean(row["visual"] for row in rows),
            "lowest": min(rows, key=lambda row: row["total"])["total"],
            "alerts": sorted(row["spine"] for row in rows if row["total"] < ALERT_SCORE),
            "browser": sum(1 for row in rows if row["route"] == "browser"),
            "legacy": sum(1 for row in rows if row["route"] == "legacy"),
            "passes": score is not None and score >= PASS_SCORE and not failed and measured,
        })
        for row in rows:
            routes[row["routeDetail"] or "unknown"] += 1
            share = (0.5 / (0.5 + row["visualWeight"])) / count      # layout points → chapter points → book points
            for name, points in row["context"].items():
                reason, _, flag = name.partition("|")
                gaps[(reason, flag)] += points * share
                reasons[reason] += points * share
            visual_share = (row["visualWeight"] / (0.5 + row["visualWeight"])) / count
            for name, points in row["paintLost"].items():
                paint[name] += points * visual_share
                reasons["paint:" + name] += points * visual_share
    book_count = max(1, len(book_rows))
    unmeasured_books = sorted({entry.get("book") for entry in skipped if entry.get("book") not in books})
    # Why chapters fell back to the legacy renderer, and how those chapters score.
    fallbacks = {}
    for chapter in chapters:
        for reason in fallback_reasons(chapter):
            entry = fallbacks.setdefault(reason, {"chapters": 0, "books": set(), "total": 0.0})
            entry["chapters"] += 1
            entry["books"].add(chapter["book"])
            entry["total"] += chapter["total"]

    caveats = Counter()
    for chapter in chapters:
        for name in filter(None, (chapter.get("referenceLate") or "").split(",")):
            caveats[(chapter["book"], f"{name} still loading when the reference was measured")] += 1
        if chapter.get("frameTimeouts"):
            caveats[(chapter["book"], "reference tiles captured without a frame signal")] += 1

    def mean_of(route):
        values = [chapter["total"] for chapter in chapters if chapter["route"] == route]
        return sum(values) / len(values) if values else None
    return {
        "schema": 1, "scorer": SCORER_VERSION, "run": index["run"], "refKey": index["refKey"],
        "profile": index.get("profile"), "generated": datetime.datetime.now().isoformat(timespec="seconds"),
        "passScore": PASS_SCORE, "alertScore": ALERT_SCORE,
        # A capture that stopped part-way measured only some of the sample.
        "complete": index.get("complete", True),
        "goalMet": (bool(book_rows) and all(row["passes"] for row in book_rows) and not unmeasured_books
                    and index.get("complete", True)),
        "books": book_rows, "unmeasuredBooks": unmeasured_books,
        "reasons": [{"reason": reason, "points": points / book_count} for reason, points in reasons.most_common()],
        "gaps": [{"reason": reason, "context": flag, "points": points / book_count}
                 for (reason, flag), points in gaps.most_common(40)],
        "routes": [{"route": route, "chapters": count} for route, count in routes.most_common()],
        "routeScores": {"browser": mean_of("browser"), "legacy": mean_of("legacy"),
                        "browserChapters": sum(1 for chapter in chapters if chapter["route"] == "browser"),
                        "legacyChapters": sum(1 for chapter in chapters if chapter["route"] == "legacy")},
        "fallbacks": sorted(({"reason": reason, "chapters": entry["chapters"], "books": sorted(entry["books"]),
                              "score": entry["total"] / entry["chapters"]} for reason, entry in fallbacks.items()),
                            key=lambda row: -row["chapters"]),
        "skipped": skipped,
        "caveats": [{"book": book, "caveat": caveat, "chapters": count}
                    for (book, caveat), count in sorted(caveats.items())],
        "chapters": sorted(chapters, key=lambda row: (row["book"], row["spine"])),
    }


def render_markdown(report):
    def number(value):
        return "—" if value is None else f"{value:.1f}"

    lines = [
        f"# Render fidelity — {report['run']}",
        "",
        f"Generated {report['generated']} · scorer v{report['scorer']} · reference `{report['refKey']}`",
        "",
    ]
    measured = report.get("provenance")
    if measured:
        lines += [f"Measured: reader `{measured.get('reader', 'unknown')}` · engine package "
                  f"`{measured.get('package', 'unknown')}`", ""]
    lines += [
        f"**Goal (every book ≥ {report['passScore']:.0f}): {'MET' if report['goalMet'] else 'not met'}** — "
        f"{sum(1 for row in report['books'] if row['passes'])} of {len(report['books'])} books pass.",
        "",
    ]
    if not report["complete"]:
        lines += ["**The capture stopped before the end of its plan: the books below are only the part that was "
                  "measured, and the goal cannot be met by this run.**", ""]
    lines += [
        "| Book | Score | Dev | Holdout | Layout | Visual | Lowest chapter | Chapters | Browser / Legacy | Below "
        f"{report['alertScore']:.0f} (spine) | Unmeasured |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|",
    ]
    for row in sorted(report["books"], key=lambda row: row["score"] if row["score"] is not None else -1):
        mark = "" if row["passes"] else " ✗"
        lines.append(
            f"| {row['book']}{mark} | **{number(row['score'])}** | {number(row['dev'])} | {number(row['holdout'])} | "
            f"{number(row['layout'])} | {number(row['visual'])} | {number(row['lowest'])} | {row['chapters']} | "
            f"{row['browser']} / {row['legacy']} | {', '.join(map(str, row['alerts'])) or '—'} | {row['unmeasured']} |")
    for book in report["unmeasuredBooks"]:
        lines.append(f"| {book} ✗ | — | — | — | — | — | — | 0 | — | — | all |")
    lines += ["", "## Where the points go", "",
              "Points are book-score points: what one book loses on average to each cause.", "",
              "| Cause | Points |", "|---|---:|"]
    lines += [f"| {row['reason']} | {row['points']:.2f} |" for row in report["reasons"][:16] if row["points"] >= 0.05]
    lines += ["", "## Largest gaps by CSS context", "",
              "| Cause | Context of the reference block | Points |", "|---|---|---:|"]
    lines += [f"| {row['reason']} | {row['context']} | {row['points']:.2f} |" for row in report["gaps"][:24]
              if row["points"] >= 0.05]
    scores = report["routeScores"]
    lines += ["", "## Engine route of the measured chapters", "",
              f"Browser engine: {scores['browserChapters']} chapters, mean {number(scores['browser'])}. "
              f"Legacy fallback: {scores['legacyChapters']} chapters, mean {number(scores['legacy'])}.", "",
              "A chapter falls back whole when the capability scanner finds any of these; one chapter can name several.",
              "", "| Fallback reason | Chapters | Books | Mean score of those chapters |", "|---|---:|---|---:|"]
    lines += [f"| {row['reason']} | {row['chapters']} | {', '.join(row['books'])} | {row['score']:.1f} |"
              for row in report["fallbacks"]]
    lines += ["", "| Route as reported | Chapters |", "|---|---:|"]
    lines += [f"| {row['route']} | {row['chapters']} |" for row in report["routes"]]
    if report["caveats"]:
        lines += ["", "## Reference caveats", "", "| Book | Chapters | Caveat |", "|---|---:|---|"]
        lines += [f"| {row['book']} | {row['chapters']} | {row['caveat']} |" for row in report["caveats"]]
    if report["skipped"]:
        lines += ["", "## Not measured", "",
                  "A chapter the reader failed to render fails its book. A chapter the reference could not render "
                  f"is left out, unless that leaves less than {MIN_COVERAGE:.0%} of the book's sample measured.", "",
                  "| Book | Spine | Side | Reason |", "|---|---:|---|---|"]
        lines += [f"| {row.get('book')} | {row.get('spine', '—')} | {row.get('side', '—')} | "
                  f"{str(row.get('reason'))[:160]} |" for row in report["skipped"]]
    lines.append("")
    return "\n".join(lines)


def render_html(report, run_directory, reference_root):
    """Both renderings of each chapter next to each other, worst first."""
    parts = ["<!doctype html><meta charset='utf-8'><title>Render fidelity — %s</title>" % html.escape(report["run"]),
             "<style>body{font:14px -apple-system;margin:24px;background:#f4f4f5;color:#18181b}"
             "h2{margin-top:40px}figure{display:inline-block;margin:0 12px 12px 0;vertical-align:top}"
             "figcaption{font-size:12px;color:#52525b;margin-bottom:4px}img{width:244px;border:1px solid #d4d4d8;"
             "display:block;background:#fff}code{font-size:12px}.low{color:#b91c1c}</style>",
             "<h1>%s</h1><p>Left: WKWebView reference. Right: the reader. Worst chapters first.</p>"
             % html.escape(report["run"])]
    for chapter in sorted(report["chapters"], key=lambda row: row["total"]):
        reference_directory = Path(reference_root) / chapter["book"] / str(chapter["spine"])
        engine_directory = Path(run_directory) / chapter["book"] / str(chapter["spine"])
        reasons = sorted(chapter["lost"].items(), key=lambda pair: -pair[1])[:5]
        parts.append("<h2 class='%s'>%s · spine %s — %.1f</h2><p>layout %.1f · visual %.1f ×%.2f · %s<br><code>%s</code></p>"
                     % ("low" if chapter["total"] < report["passScore"] else "", html.escape(chapter["book"]),
                        chapter["spine"], chapter["total"], chapter["layout"], chapter["visual"],
                        chapter["visualWeight"], html.escape(str(chapter["routeDetail"])),
                        html.escape(", ".join(f"{name} −{points:.1f}" for name, points in reasons))))
        tiles = sorted(path.name for path in reference_directory.glob("tile-*.jpg"))
        for name in tiles:
            for label, directory in (("WebKit", reference_directory), ("Reader", engine_directory)):
                path = directory / name
                if path.exists():
                    parts.append("<figure><figcaption>%s %s</figcaption><img loading='lazy' src='%s'></figure>"
                                 % (label, name, html.escape(path.as_uri())))
    return "\n".join(parts)


# --------------------------------------------------------------------------- oracle lock

# What decides a score. Whoever changes one of these re-records the lock, and the
# baseline too when scores can move (ORACLE.md, "改量法").
FROZEN = [
    "scripts/fidelity/fidelity.py",
    "scripts/fidelity/measure.sh",
    "scripts/fidelity/corpus.json",
    "scripts/fidelity/test_fidelity.py",
    "Tests/iOS/yuedu appTests/RenderFidelityOracleTests.swift",
    "docs/browser-layout/fidelity-loop/ORACLE.md",
    "docs/browser-layout/fidelity-loop/GOAL.md",
]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else "missing"


def command_lock(args):
    root = HERE.parent.parent
    lock_path = HERE / "oracle.lock"
    if args.write:
        lock = {"schema": 1, "files": {name: digest(root / name) for name in FROZEN}}
        lock_path.write_text(json.dumps(lock, indent=1) + "\n", encoding="utf-8")
        print(f"wrote {lock_path}")
        return
    if not lock_path.exists():
        raise SystemExit("scripts/fidelity/oracle.lock is missing; run `fidelity.py lock --write` after reviewing the oracle")
    with open(lock_path, encoding="utf-8") as handle:
        expected = json.load(handle)["files"]
    trees = [("oracle", root)]
    if args.tree and Path(args.tree).resolve() != root:
        trees.append(("tree under test", Path(args.tree).resolve()))
    problems = [f"{label}: {name}" for label, tree in trees for name in FROZEN
                if digest(tree / name) != expected.get(name)]
    if problems:
        print("frozen oracle files differ from oracle.lock:")
        for problem in problems:
            print(f"  {problem}")
        sys.exit(2)
    print(f"oracle lock ok ({len(FROZEN)} files, {len(trees)} tree{'s' if len(trees) > 1 else ''})")


# --------------------------------------------------------------------------- cli

# --------------------------------------------------------------------------- what was measured

def resolved_package(log_text, name="YueduCoreText"):
    """The line xcodebuild prints for one package under "Resolved source packages":
    `<name>: <url> @ <version>` for a published package, and `<name>: <path>` with
    no version for a folder that a workspace put in its place. Returns
    (location, version), with version "local" for the folder."""
    match = re.search(rf"^\s*{re.escape(name)}: (\S.*?)(?: @ (\S+))?\s*$", log_text, re.MULTILINE)
    if not match:
        return None, None
    location, version = match.group(1).strip(), match.group(2)
    if version is None:
        return (location, "local") if location.startswith("/") else (location, None)
    return location, version


def describe_checkout(directory):
    def git(*arguments):
        result = subprocess.run(["git", "-C", str(directory), *arguments], capture_output=True, text=True)
        return result.stdout.strip() if result.returncode == 0 else ""

    head = git("rev-parse", "--short", "HEAD")
    if not head:
        return "unknown"
    changed = " + uncommitted changes" if git("status", "--porcelain", "--untracked-files=no") else ""
    return f"{git('branch', '--show-current') or 'detached'} {head}{changed}"


def command_provenance(args):
    """Records which code a capture was built from. With a workspace, the engine
    has to be the folder the workspace lists: a build that fell back to the
    published package measured something other than the change under test."""
    with open(args.log, encoding="utf-8", errors="replace") as handle:
        location, version = resolved_package(handle.read())
    if args.workspace and version != "local":
        print(f"!! a workspace was given ({args.workspace}), but the build used "
              f"{location or 'an unknown package'} @ {version or 'unknown'}.\n"
              "   The engine checkout beside the workspace is not what was measured.", file=sys.stderr)
        sys.exit(1)
    def short(path):
        return str(path).replace(str(Path.home()), "~", 1)

    package = f"{short(location)} @ {version}" if location else "unknown"
    if version == "local":
        package += f" ({describe_checkout(location)})"
    # The state read before the build: other sessions commit to the same checkout meanwhile.
    reader = args.built or describe_checkout(args.tree)
    record = {"reader": f"{short(Path(args.tree).resolve())} ({reader})", "package": package}
    target = Path(args.out) / "runs" / args.run / "provenance.json"
    target.write_text(json.dumps(record, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"measured: reader {record['reader']} · engine package {record['package']}")


# --------------------------------------------------------------------------- comparing two runs

def compare_reports(base, new, full=False):
    """What a change did, judged only on chapters both runs measured.

    A chapter's set (dev or holdout) is the base run's: a chapter re-measured
    alone is still the chapter it was in the full sample.

    A chapter the legacy renderer drew both times drifts a little from run to
    run (up to ±3 on one chapter, measured 2026-10-01; new-engine chapters
    repeat exactly). Book scores here leave those chapters out, so their drift
    is neither progress nor regression; a change to the legacy renderer itself
    has to be read from the two runs' own reports."""
    old = {(chapter["book"], chapter["spine"]): chapter for chapter in base["chapters"]}
    now = {(chapter["book"], chapter["spine"]): chapter for chapter in new["chapters"]}
    shared = sorted(old.keys() & now.keys())

    def untouched(key):
        return old[key].get("route") == "legacy" and now[key].get("route") == "legacy"
    failures, progress, rows = [], [], []
    if base.get("scorer") != new.get("scorer") or base.get("refKey") != new.get("refKey"):
        failures.append("the two runs were scored by different oracles or against different references: "
                        f"scorer {base.get('scorer')} / {new.get('scorer')}, "
                        f"reference {base.get('refKey')} / {new.get('refKey')}")
    if not new.get("complete", True):
        failures.append("the new run's capture stopped before the end of its plan")
    if full and len(shared) < len(old):
        failures.append(f"a full comparison was asked for, but only {len(shared)} of the base run's "
                        f"{len(old)} chapters were measured again")
    for entry in new.get("skipped", []):
        key = (entry.get("book"), entry.get("spine"))
        if key in old:
            failures.append(f"{key[0]} spine {key[1]}: measured before, now not measured "
                            f"({entry.get('side', 'unknown')} side: {str(entry.get('reason'))[:120]})")

    def mean(values):
        values = list(values)
        return sum(values) / len(values) if values else None

    for book in sorted({book for book, _ in shared}):
        keys = [key for key in shared if key[0] == book]
        judged = [key for key in keys if not untouched(key)]
        row = {"book": book, "chapters": len(keys), "judged": len(judged)}
        for name, tolerance in (("dev", DEV_TOLERANCE), ("holdout", HOLDOUT_TOLERANCE)):
            subset = [key for key in judged if (old[key].get("set") == "holdout") == (name == "holdout")]
            before, after = mean(old[key]["total"] for key in subset), mean(now[key]["total"] for key in subset)
            row[name] = {"before": before, "after": after, "chapters": len(subset)}
            if subset and after - before < -tolerance:
                failures.append(f"{book}: {name} chapters fell {before:.1f} → {after:.1f} "
                                f"(more than {tolerance} allowed)")
        before, after = mean(old[key]["total"] for key in judged), mean(now[key]["total"] for key in judged)
        row["all"] = {"before": before, "after": after}
        if judged and after - before >= PROGRESS_STEP:
            progress.append(f"{book}: {before:.1f} → {after:.1f}")
        gone = (set().union(*(fallback_reasons(old[key]) for key in keys))
                - set().union(*(fallback_reasons(now[key]) for key in keys)))
        for reason in sorted(gone):
            affected = [key for key in keys if reason in fallback_reasons(old[key])]
            # Only a chapter that left the legacy renderer says anything about the change.
            if all(now[key]["total"] >= old[key]["total"] - CHAPTER_STEADY for key in affected if not untouched(key)):
                progress.append(f"{book}: fallback reason '{reason}' gone from {len(affected)} chapters, none lower")
        row["browser"] = {"before": sum(1 for key in keys if old[key].get("route") == "browser"),
                          "after": sum(1 for key in keys if now[key].get("route") == "browser")}
        rows.append(row)
    browser_before = sum(row["browser"]["before"] for row in rows)
    browser_after = sum(row["browser"]["after"] for row in rows)
    if browser_after < browser_before:
        failures.append(f"chapters laid out by the browser engine fell {browser_before} → {browser_after}")
    moved = sorted(({"book": key[0], "spine": key[1], "set": old[key].get("set"), "before": old[key]["total"],
                     "after": now[key]["total"], "routeBefore": old[key].get("routeDetail"),
                     "routeAfter": now[key].get("routeDetail")} for key in shared if not untouched(key)),
                   key=lambda row: -abs(row["after"] - row["before"]))
    drift = [abs(now[key]["total"] - old[key]["total"]) for key in shared if untouched(key)]
    if not shared:
        failures.append("the two runs share no measured chapter")
    verdict = "FAIL" if failures else ("PASS" if progress else "NO PROGRESS")
    return {"verdict": verdict, "base": base.get("run"), "run": new.get("run"), "shared": len(shared),
            "baseChapters": len(old), "partial": len(shared) < len(old), "books": rows, "progress": progress,
            "failures": failures, "browser": {"before": browser_before, "after": browser_after},
            "moved": [row for row in moved if abs(row["after"] - row["before"]) >= CHAPTER_STEADY][:20],
            "legacyBoth": {"chapters": len(drift), "largestMove": max(drift) if drift else 0.0}}


def render_comparison(result):
    def number(value):
        return "—" if value is None else f"{value:.1f}"

    def delta(pair):
        if pair["before"] is None or pair["after"] is None:
            return "—"
        return f"{pair['after'] - pair['before']:+.1f}"

    scope = (f"{result['shared']} of the base run's {result['baseChapters']} chapters"
             + (" — partial: not a verdict on the whole corpus" if result["partial"] else ""))
    lines = [f"# Fidelity comparison — {result['run']} against {result['base']}", "",
             f"COMPARE: {result['verdict']} ({scope})", "",
             f"Left out: {result['legacyBoth']['chapters']} chapters the legacy renderer drew in both runs "
             f"(largest move {result['legacyBoth']['largestMove']:.1f}); no slice reaches them.", "",
             "| Book | Dev before | Dev after | Δ | Holdout before | Holdout after | Δ | All Δ | Browser chapters |",
             "|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for row in result["books"]:
        lines.append(f"| {row['book']} | {number(row['dev']['before'])} | {number(row['dev']['after'])} | "
                     f"{delta(row['dev'])} | {number(row['holdout']['before'])} | {number(row['holdout']['after'])} | "
                     f"{delta(row['holdout'])} | {delta(row['all'])} | "
                     f"{row['browser']['before']} → {row['browser']['after']} |")
    lines += ["", "## Progress", ""] + ([f"- {text}" for text in result["progress"]] or ["- none"])
    lines += ["", "## Failures", ""] + ([f"- {text}" for text in result["failures"]] or ["- none"])
    if result["moved"]:
        lines += ["", "## Chapters that moved most", "",
                  "| Book | Spine | Set | Before | After | Δ | Route before → after |", "|---|---:|---|---:|---:|---:|---|"]
        for row in result["moved"]:
            route = (row["routeBefore"] if row["routeBefore"] == row["routeAfter"]
                     else f"{row['routeBefore']} → {row['routeAfter']}")
            lines.append(f"| {row['book']} | {row['spine']} | {row['set']} | {row['before']:.1f} | {row['after']:.1f} | "
                         f"{row['after'] - row['before']:+.1f} | {route} |")
    lines.append("")
    return "\n".join(lines)


def command_compare(args):
    out = Path(args.out)
    reports = []
    for run in (args.base, args.run):
        with open(out / "runs" / run / "report.json", encoding="utf-8") as handle:
            reports.append(json.load(handle))
    result = compare_reports(reports[0], reports[1], full=args.full)
    text = render_comparison(result)
    (out / "runs" / args.run / f"compare-{args.base}.md").write_text(text, encoding="utf-8")
    if args.markdown:
        Path(args.markdown).write_text(text, encoding="utf-8")
    print(text)
    sys.exit(0 if result["verdict"] == "PASS" else 4)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    plan = commands.add_parser("plan", help="extract the corpus and write a capture plan")
    plan.add_argument("--run", default=datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
    plan.add_argument("--out", default=os.environ.get("YUEDU_FIDELITY_OUT", str(DEFAULT_OUT)))
    plan.add_argument("--sets", default="dev", help="dev, holdout or dev,holdout")
    plan.add_argument("--sides", default="webkit,engine")
    plan.add_argument("--books", help="comma-separated book ids (default: the whole corpus)")
    plan.add_argument("--only", action="append", help="book-id:spine,spine — explicit chapters of one book")
    plan.add_argument("--tiles", type=int, default=4, help="side-by-side images kept per chapter and side")
    plan.set_defaults(handler=command_plan)
    score = commands.add_parser("score", help="score a captured run")
    score.add_argument("--run", required=True)
    score.add_argument("--out", default=os.environ.get("YUEDU_FIDELITY_OUT", str(DEFAULT_OUT)))
    score.add_argument("--markdown", help="also write the summary to this path")
    score.add_argument("--require-goal", action="store_true", help="exit 3 unless every book passes")
    score.add_argument("--verbose", action="store_true")
    score.set_defaults(handler=command_score)
    compare = commands.add_parser("compare", help="judge one scored run against an earlier one")
    compare.add_argument("--run", required=True, help="the run holding the change")
    compare.add_argument("--base", required=True, help="the last accepted run")
    compare.add_argument("--out", default=os.environ.get("YUEDU_FIDELITY_OUT", str(DEFAULT_OUT)))
    compare.add_argument("--full", action="store_true",
                         help="fail unless every chapter of the base run was measured again")
    compare.add_argument("--markdown", help="also write the comparison to this path")
    compare.set_defaults(handler=command_compare)
    provenance = commands.add_parser("provenance", help="record which checkout and engine package a capture built")
    provenance.add_argument("--run", required=True)
    provenance.add_argument("--out", default=os.environ.get("YUEDU_FIDELITY_OUT", str(DEFAULT_OUT)))
    provenance.add_argument("--tree", required=True, help="the reader checkout that was built")
    provenance.add_argument("--log", required=True, help="the xcodebuild log of the capture")
    provenance.add_argument("--workspace", default="", help="the workspace the build used, if any")
    provenance.add_argument("--built", default="", help="the checkout's state when the build started (describe)")
    provenance.set_defaults(handler=command_provenance)
    describe = commands.add_parser("describe", help="branch, commit and whether a checkout has uncommitted changes")
    describe.add_argument("tree")
    describe.set_defaults(handler=lambda args: print(describe_checkout(args.tree)))
    lock = commands.add_parser("lock", help="check or re-record the hashes of the frozen oracle files")
    lock.add_argument("--write", action="store_true")
    lock.add_argument("--check", action="store_true")
    lock.add_argument("--tree", help="also check this checkout's copies")
    lock.set_defaults(handler=command_lock)
    args = parser.parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
