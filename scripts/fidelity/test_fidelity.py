#!/usr/bin/env python3
"""Self-tests for the render-fidelity scorer.

A scorer that only ever says "similar" is worthless, so most of these are
negative controls: a known defect is injected into a synthetic rendering and the
score has to fall, by a plausible amount, and name the right cause.

Run: python3 scripts/fidelity/test_fidelity.py
"""

import json
import math
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True     # no __pycache__ beside the oracle
import fidelity  # noqa: E402

BODY = "這是一段用來檢查換行位置的正文內容，句子夠長才會換好幾行，標點也算在裡面。"


def render(paragraphs, *, width=366, margin=8, line_height=1.5, vertical=False, images=(), boxes=(),
           prefix="", page=(255, 255, 255)):
    """A tiny block layout: fixed-advance characters, one fragment per line.

    Returns a capture dict plus its pixel grid, in the shape both capture sides write."""
    text = prefix
    fragments, blocks, image_items, painted = [], [{"i": 0, "p": -1, "tag": "body", "own": [], "ctx": []}], [], []
    cursor = margin
    pending = {at: image for at, image in images}
    for number, paragraph in enumerate(paragraphs):
        if number in pending:
            image = pending[number]
            image_items.append({"x": margin + image.get("dx", 0), "y": cursor, "w": image["w"], "h": image["h"],
                                "src": image["src"], "at": len(text), "b": 0})
            cursor += image["h"] + 8
        size = paragraph.get("size", 17)
        indent = paragraph.get("indent", 2) * size
        pitch = size * paragraph.get("line_height", line_height)
        content = size * 1.4
        characters = paragraph["text"]
        block = len(blocks)
        blocks.append({"i": block, "p": 0, "tag": paragraph.get("tag", "p"), "own": paragraph.get("own", []),
                       "ctx": paragraph.get("ctx", [])})
        if text:
            text += "\n"
        top = cursor
        position, first = 0, True
        while position < len(characters):
            inset = paragraph.get("inset", 0)
            available = width - 2 * margin - 2 * inset - (indent if first else 0)
            count = max(1, int(available // size) - paragraph.get("shorter", 0))
            piece = characters[position:position + count]
            start = len(text) + position
            x = margin + inset + paragraph.get("shift", 0) + (indent if first else 0)
            if paragraph.get("align") == "center":
                x = (width - len(piece) * size) / 2
            fragments.append({"s": start, "e": start + len(piece), "x": x, "y": cursor + (pitch - content) / 2,
                              "w": len(piece) * size, "h": content, "fs": size, "fw": paragraph.get("weight", 400),
                              "it": paragraph.get("italic", False), "c": paragraph.get("color", "000000"), "b": block})
            cursor += pitch
            position += count
            first = False
        text += characters
        if paragraph.get("background"):
            painted.append({"x": margin, "y": top, "w": width - 2 * margin, "h": cursor - top,
                            "bg": "%02x%02x%02x" % paragraph["background"], "bw": [0, 0, 0, 0], "page": False})
        cursor += paragraph.get("gap", size)
    for box in boxes:
        painted.append(dict(box))
    height = cursor + margin
    dump = {"schema": 1, "writingMode": "horizontal-tb", "direction": "ltr", "viewportWidth": width,
            "viewportHeight": 776, "contentWidth": width, "contentHeight": height, "text": text,
            "fragments": fragments, "images": image_items, "boxes": painted, "blocks": blocks, "ruby": []}

    size = 4
    cols, rows = math.ceil(width / size), math.ceil(height / size)
    grid = bytearray(bytes(page) * 2 * cols * rows)

    def fill(x, y, w, h, mean, dominant=None):
        for row in range(max(0, int(y // size)), min(rows, int((y + h) // size) + 1)):
            for col in range(max(0, int(x // size)), min(cols, int((x + w) // size) + 1)):
                at = (row * cols + col) * 6
                grid[at:at + 3] = bytes(mean)
                grid[at + 3:at + 6] = bytes(dominant or mean)

    for box in painted:
        if box.get("bg"):
            fill(box["x"], box["y"], box["w"], box["h"], fidelity.hex_color(box["bg"]))
    for image in image_items:
        fill(image["x"], image["y"], image["w"], image["h"], (90, 120, 160))
    for fragment in fragments:          # ink darkens the mean; the paper stays the dominant colour
        for row in range(int(fragment["y"] // size), min(rows, int((fragment["y"] + fragment["h"]) // size) + 1)):
            for col in range(int(fragment["x"] // size), min(cols, int((fragment["x"] + fragment["w"]) // size) + 1)):
                at = (row * cols + col) * 6
                grid[at:at + 3] = bytes(max(0, value - 60) for value in grid[at + 3:at + 6])

    if vertical:
        # The same layout turned: lines run down, and advance leftwards from the right edge.
        def turn(item):
            turned = dict(item)
            turned.update(x=height - (item["y"] + item["h"]), y=item["x"], w=item["h"], h=item["w"])
            return turned
        dump.update(writingMode="vertical-rl", contentWidth=height, contentHeight=width,
                    fragments=[turn(f) for f in fragments], images=[turn(i) for i in image_items],
                    boxes=[turn(b) for b in painted])
        turned_cols, turned_rows = math.ceil(height / size), math.ceil(width / size)
        turned = bytearray(bytes(page) * 2 * turned_cols * turned_rows)
        for row in range(rows):
            for col in range(cols):
                target_col = int((height - (row + 0.5) * size) // size)
                if 0 <= target_col < turned_cols and col < turned_rows:
                    at, to = (row * cols + col) * 6, (col * turned_cols + target_col) * 6
                    turned[to:to + 6] = grid[at:at + 6]
        grid, cols, rows = turned, turned_cols, turned_rows
    dump["cells"] = {"size": size, "cols": cols, "rows": rows, "file": "cells.bin"}
    return dump, bytes(grid)


def score(reference, engine):
    with tempfile.TemporaryDirectory() as scratch:
        sides = []
        for name, (dump, grid) in (("reference", reference), ("engine", engine)):
            directory = Path(scratch) / name
            directory.mkdir()
            (directory / "cells.bin").write_bytes(grid)
            (directory / "dump.json").write_text(json.dumps(dump), encoding="utf-8")
            sides.append(fidelity.load_side(directory))
        return fidelity.score_chapter(*sides)


def chapter(**changes):
    paragraphs = [{"text": "第一章", "size": 24, "indent": 0, "align": "center", "weight": 700, "tag": "h2"}]
    paragraphs += [{"text": BODY * 3} for _ in range(4)]
    for paragraph in paragraphs[1:]:
        paragraph.update(changes)
    return paragraphs


class TextStream(unittest.TestCase):
    def test_spacing_never_anchors(self):
        characters, offsets = fidelity.normalize("甲 乙\n　丙­丁")
        self.assertEqual([chr(c) for c in characters], ["甲", "乙", "丙", "丁"])
        self.assertEqual(offsets, [0, 2, 5, 7])

    def test_a_surrogate_pair_is_one_character(self):
        characters, offsets = fidelity.normalize("a😀b")
        self.assertEqual(len(characters), 3)
        self.assertEqual(offsets, [0, 1, 3])

    def test_alignment_survives_insertions_on_either_side(self):
        base = [ord(c) for c in BODY * 4]
        extra = [ord(c) for c in "編者按：本章有刪節。"]
        with_prefix = extra + base
        self.assertEqual(fidelity.align(base, with_prefix)[:5], [len(extra) + k for k in range(5)])
        middle = base[:40] + extra + base[40:]
        matched = fidelity.align(middle, base)
        self.assertEqual(sum(1 for m in matched if m >= 0), len(base))
        self.assertTrue(all(m == -1 for m in matched[40:40 + len(extra)]))

    def test_alignment_is_monotone(self):
        a = [ord(c) for c in BODY * 2 + "尾聲" + BODY]
        b = [ord(c) for c in BODY + "插話" + BODY * 2]
        matched = [m for m in fidelity.align(a, b) if m >= 0]
        self.assertEqual(matched, sorted(matched))
        self.assertGreater(len(matched), len(BODY) * 2)


class Scoring(unittest.TestCase):
    def test_a_rendering_matches_itself(self):
        capture = render(chapter())
        result = score(capture, capture)
        self.assertAlmostEqual(result["total"], 100.0, places=6)
        self.assertEqual({k: v for k, v in result["lost"].items() if v > 1e-9}, {})

    def test_vertical_rendering_matches_itself(self):
        capture = render(chapter(), vertical=True)
        result = score(capture, capture)
        self.assertAlmostEqual(result["total"], 100.0, places=6)

    def test_lines_one_character_short_cost_a_little(self):
        result = score(render(chapter()), render(chapter(shorter=1)))
        self.assertLess(result["total"], 97)
        self.assertGreater(result["total"], 80)
        self.assertGreater(result["lost"]["line-break"], 2)

    def test_a_missing_indent_is_named(self):
        result = score(render(chapter()), render(chapter(indent=0)))
        self.assertLess(result["total"], 97)
        self.assertGreater(result["lost"]["indent"], 3)
        self.assertGreater(result["lost"]["indent"], result["lost"].get("line-pitch", 0))
        self.assertLess(result["lost"].get("inline-start", 0), 0.2)

    def test_a_shifted_column_is_not_a_wrong_indent(self):
        result = score(render(chapter()), render(chapter(shift=20)))
        self.assertGreater(result["lost"]["inline-start"], 2)
        self.assertLess(result["lost"].get("indent", 0), 0.2)
        self.assertLess(result["lost"].get("inline-size", 0), 0.2)
        self.assertGreater(result["total"], 90)

    def test_a_narrower_column_is_named(self):
        result = score(render(chapter()), render(chapter(inset=24)))
        self.assertGreater(result["lost"]["inline-size"], 2)
        self.assertGreater(result["lost"]["inline-start"], 2)
        self.assertLess(result["lost"].get("indent", 0), 0.2)

    def test_a_heading_that_lost_its_centring_is_named(self):
        engine = chapter()
        engine[0].pop("align")
        result = score(render(chapter()), render(engine))
        self.assertGreater(result["lost"]["alignment"], 0.5)
        self.assertGreater(result["lost"]["inline-start"], 0.5)

    def test_a_tighter_line_height_is_named(self):
        result = score(render(chapter()), render(chapter(line_height=1.2)))
        self.assertLess(result["total"], 92)
        self.assertGreater(result["lost"]["line-pitch"], 5)
        self.assertLess(result["lost"].get("indent", 0), 1)

    def test_a_wrong_font_size_is_named(self):
        result = score(render(chapter()), render(chapter(size=14)))
        self.assertLess(result["total"], 88)
        self.assertGreater(result["lost"]["font-size"], 8)

    def test_a_wrong_colour_and_weight_are_named(self):
        result = score(render(chapter()), render(chapter(color="cc0000", weight=700)))
        self.assertGreater(result["lost"]["color"], 1.5)
        self.assertGreater(result["lost"]["bold"], 1.5)
        self.assertGreater(result["total"], 85)

    def test_a_dropped_paragraph_costs_its_share(self):
        full = chapter()
        result = score(render(full), render(full[:-1]))
        self.assertGreater(result["lost"]["missing-text"], 15)
        self.assertLess(result["total"], 85)

    def test_text_the_reference_lacks_is_penalised_but_the_rest_still_aligns(self):
        result = score(render(chapter()), render(chapter(), prefix="本章說 1234 條評論"))
        self.assertGreater(result["matched"], result["referenceCharacters"] * 0.99)
        self.assertLess(result["lost"].get("line-break", 0), 0.5)

    def test_a_missing_background_is_a_paint_loss(self):
        result = score(render(chapter(background=(130, 60, 170), color="ffffff")), render(chapter(color="ffffff")))
        self.assertLess(result["visual"], 40)
        self.assertGreater(result["visualWeight"], 0.45)
        self.assertLess(result["total"], 75)
        self.assertGreater(result["paintLost"]["background"], 50)
        self.assertGreater(result["layout"], 99)

    def test_a_different_page_colour_is_a_paint_loss(self):
        result = score(render(chapter(), page=(245, 232, 200)), render(chapter()))
        self.assertLess(result["visual"], 80)
        self.assertGreater(result["visualWeight"], 0.45)

    def test_plain_text_is_judged_on_layout_alone(self):
        result = score(render(chapter()), render(chapter(indent=0)))
        self.assertLess(result["visualWeight"], 0.05)
        self.assertAlmostEqual(result["total"], result["layout"], delta=1.0)

    def test_images_missing_or_missized_are_named(self):
        picture = {"w": 300, "h": 200, "src": "../Images/map.jpg"}
        reference = render(chapter(), images=[(2, picture)])
        self.assertGreater(score(reference, render(chapter()))["lost"]["image-missing"], 5)
        small = score(reference, render(chapter(), images=[(2, dict(picture, w=150, h=100, src="x/MAP.JPG"))]))
        self.assertGreater(small["lost"]["image-size"], 2)
        self.assertNotIn("image-missing", {k for k, v in small["lost"].items() if v > 0})

    def test_a_picture_weighs_what_the_text_in_its_place_would(self):
        wide = {"w": 350, "h": 200, "src": "../Images/map.jpg"}
        small = {"w": 17, "h": 17, "src": "../Images/mark.gif"}
        lost_wide = score(render(chapter(), images=[(2, wide)]), render(chapter()))["lost"]["image-missing"]
        lost_small = score(render(chapter(), images=[(2, small)]), render(chapter()))["lost"]["image-missing"]
        self.assertGreater(lost_wide, 15)
        self.assertLess(lost_small, 0.2)

    def test_a_picture_that_does_not_name_its_file_pairs_by_order(self):
        picture = {"w": 300, "h": 200, "src": "../Images/cover.jpg"}
        reference = render(chapter(), images=[(2, picture)])
        result = score(reference, render(chapter(), images=[(2, dict(picture, src=""))]))
        self.assertNotIn("image-missing", {k for k, v in result["lost"].items() if v > 0})
        self.assertGreater(result["total"], 99)

    def test_a_page_with_nothing_to_read_has_no_direction_to_get_wrong(self):
        cover = {"schema": 1, "writingMode": "horizontal-tb", "viewportWidth": 390, "viewportHeight": 776,
                 "contentWidth": 390, "contentHeight": 776, "text": "", "fragments": [], "boxes": [], "blocks": [],
                 "images": [{"x": 0, "y": 0, "w": 390, "h": 520, "src": "cover.jpg", "at": 0}]}
        shown = dict(cover, writingMode="vertical-rl", text="\ufffc")
        with tempfile.TemporaryDirectory() as folder:
            for name, dump in (("reference", cover), ("engine", shown)):
                directory = Path(folder) / name
                directory.mkdir()
                (directory / "dump.json").write_text(json.dumps(dump), encoding="utf-8")
            reference, engine = fidelity.load_pair(Path(folder) / "reference", Path(folder) / "engine")
            result = fidelity.score_chapter(reference, engine)
        self.assertFalse(engine.vertical)
        self.assertNotIn("writing-mode", result["lost"])
        self.assertGreater(result["layout"], 99)

    def test_a_vertical_chapter_laid_out_horizontally_scores_low(self):
        result = score(render(chapter(), vertical=True), render(chapter()))
        self.assertLess(result["total"], 80)

    def test_loss_is_attributed_to_the_css_context(self):
        reference = chapter()
        reference[2]["ctx"] = ["table"]
        engine = chapter()
        engine[2]["indent"] = 0
        result = score(render(reference), render(engine))
        self.assertGreater(result["context"]["indent|table"], 0.5)
        self.assertNotIn("indent|plain", {k for k, v in result["context"].items() if v > 0.01})


class BookVerdict(unittest.TestCase):
    """What a chapter that could not be measured does to its book."""

    @staticmethod
    def report(totals, skipped):
        chapters = [{"book": "b", "spine": spine, "set": "dev", "total": total, "layout": total, "visual": 100.0,
                     "visualWeight": 0.0, "context": {}, "paintLost": {}, "route": "browser",
                     "routeDetail": "browser"} for spine, total in enumerate(totals)]
        return fidelity.build_report({"run": "t", "refKey": "k"}, chapters,
                                     [dict(row, book="b", spine=90 + number) for number, row in enumerate(skipped)])

    def test_a_chapter_the_reference_could_not_render_does_not_fail_the_book(self):
        report = self.report([90, 92, 88], [{"side": "reference", "reason": "readiness did not answer"}])
        self.assertTrue(report["books"][0]["passes"])
        self.assertEqual(report["books"][0]["unmeasured"], 1)
        self.assertTrue(report["goalMet"])

    def test_a_chapter_the_reader_could_not_render_fails_the_book(self):
        report = self.report([90, 92, 88], [{"side": "engine", "reason": "layout threw"}])
        self.assertFalse(report["books"][0]["passes"])
        self.assertFalse(report["goalMet"])

    def test_a_book_mostly_unmeasured_has_not_passed(self):
        report = self.report([95], [{"side": "reference", "reason": "x"}, {"side": "reference", "reason": "y"}])
        self.assertFalse(report["books"][0]["passes"])

    def test_a_book_with_no_measured_chapter_fails_the_goal(self):
        report = fidelity.build_report({"run": "t", "refKey": "k"}, [],
                                       [{"book": "b", "spine": 1, "side": "reference", "reason": "x"}])
        self.assertEqual(report["unmeasuredBooks"], ["b"])
        self.assertFalse(report["goalMet"])

    def test_a_capture_that_stopped_part_way_cannot_meet_the_goal(self):
        chapters = [{"book": "b", "spine": 1, "set": "dev", "total": 95.0, "layout": 95.0, "visual": 100.0,
                     "visualWeight": 0.0, "context": {}, "paintLost": {}, "route": "browser", "routeDetail": "browser"}]
        whole = fidelity.build_report({"run": "t", "refKey": "k", "complete": True}, chapters, [])
        partial = fidelity.build_report({"run": "t", "refKey": "k", "complete": False}, chapters, [])
        self.assertTrue(whole["goalMet"])
        self.assertFalse(partial["goalMet"])
        self.assertIn("stopped before the end", fidelity.render_markdown(partial))

    def test_late_reference_resources_are_reported(self):
        chapters = [{"book": "b", "spine": 1, "set": "dev", "total": 90.0, "layout": 90.0, "visual": 100.0,
                     "visualWeight": 0.0, "context": {}, "paintLost": {}, "route": "browser",
                     "routeDetail": "browser", "referenceLate": "fonts"}]
        report = fidelity.build_report({"run": "t", "refKey": "k"}, chapters, [])
        self.assertEqual(report["caveats"][0]["chapters"], 1)
        self.assertIn("fonts", report["caveats"][0]["caveat"])
        self.assertIn("Reference caveats", fidelity.render_markdown(report))


class RunComparison(unittest.TestCase):
    """The verdict on a slice: progress somewhere, no book worse, no chapter pushed back to legacy."""

    @staticmethod
    def report(rows, skipped=(), run="r", complete=True):
        """rows: (book, spine, set, total, routeDetail)."""
        chapters = [{"book": book, "spine": spine, "set": name, "total": float(total), "layout": float(total),
                     "visual": 100.0, "visualWeight": 0.0, "context": {}, "paintLost": {},
                     "route": "legacy" if detail.startswith("legacy") else "browser", "routeDetail": detail}
                    for book, spine, name, total, detail in rows]
        return fidelity.build_report({"run": run, "refKey": "k", "complete": complete}, chapters, list(skipped))

    BASE = [("a", 0, "dev", 70, "browser"), ("a", 1, "holdout", 70, "browser"),
            ("b", 0, "dev", 90, "browser"), ("b", 1, "holdout", 90, "browser"),
            ("c", 0, "dev", 60, "legacy: capability float,table"), ("c", 1, "dev", 85, "browser")]

    def changed(self, **totals):
        """BASE with some chapters replaced: a0=75 sets book a, spine 0; a tuple also sets the route."""
        rows = []
        for book, spine, name, total, detail in self.BASE:
            value = totals.get(f"{book}{spine}", total)
            if isinstance(value, tuple):
                value, detail = value
            rows.append((book, spine, name, value, detail))
        return rows

    def verdict(self, rows, **options):
        skipped = options.pop("skipped", ())
        return fidelity.compare_reports(self.report(self.BASE, run="base"),
                                        self.report(rows, skipped=skipped, run="new"), **options)

    def test_nothing_changed_is_not_progress(self):
        result = self.verdict(self.BASE)
        self.assertEqual(result["verdict"], "NO PROGRESS")
        self.assertEqual(result["failures"], [])

    def test_a_book_that_rises_is_progress(self):
        result = self.verdict(self.changed(a0=71))          # book a: 70.0 → 70.5
        self.assertEqual(result["verdict"], "PASS")
        self.assertIn("a: 70.0 → 70.5", result["progress"])

    def test_a_rise_below_the_step_is_not_progress(self):
        self.assertEqual(self.verdict(self.changed(a0=70.4))["verdict"], "NO PROGRESS")   # +0.2 on the book

    def test_a_dev_regression_fails_even_with_progress_elsewhere(self):
        result = self.verdict(self.changed(a0=80, b0=89.4))
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any(text.startswith("b: dev") for text in result["failures"]))

    def test_holdout_has_the_wider_tolerance(self):
        self.assertEqual(self.verdict(self.changed(a0=80, b1=89.2))["verdict"], "PASS")    # holdout −0.8
        self.assertEqual(self.verdict(self.changed(a0=80, b1=88.8))["verdict"], "FAIL")    # holdout −1.2

    def test_pushing_a_chapter_back_to_legacy_fails_whatever_the_score(self):
        result = self.verdict(self.changed(a0=(95, "legacy: capability float")))
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("browser engine fell 5 → 4" in text for text in result["failures"]))

    def test_drift_in_chapters_legacy_drew_both_times_is_neither_progress_nor_failure(self):
        down = self.verdict(self.changed(c0=(50, "legacy: capability float,table")))
        self.assertEqual(down["verdict"], "NO PROGRESS")
        self.assertEqual(down["legacyBoth"]["chapters"], 1)
        up = self.verdict(self.changed(c0=(70, "legacy: capability float,table")))
        self.assertEqual(up["verdict"], "NO PROGRESS")

    def test_a_fallback_reason_removed_without_loss_is_progress(self):
        result = self.verdict(self.changed(c0=(60, "legacy: capability table")))
        self.assertEqual(result["verdict"], "PASS")
        self.assertTrue(any("'float' gone from 1 chapters" in text for text in result["progress"]))

    def test_a_fallback_reason_removed_at_a_cost_is_not_progress(self):
        # The chapter leaves the legacy renderer and loses on the way.
        result = self.verdict(self.changed(c0=(59.8, "browser")))
        self.assertFalse(any("gone" in text for text in result["progress"]))
        self.assertEqual(result["verdict"], "NO PROGRESS")

    def test_a_partial_run_is_marked_and_fails_a_full_comparison(self):
        rows = [row for row in self.changed(a0=80) if row[0] == "a"]
        partial = self.verdict(rows)
        self.assertTrue(partial["partial"])
        self.assertEqual(partial["verdict"], "PASS")
        self.assertIn("partial", fidelity.render_comparison(partial))
        self.assertEqual(self.verdict(rows, full=True)["verdict"], "FAIL")

    def test_a_chapter_the_reader_no_longer_renders_fails(self):
        rows = [row for row in self.changed(a0=80) if (row[0], row[1]) != ("b", 0)]
        result = self.verdict(rows, skipped=[{"book": "b", "spine": 0, "side": "engine", "reason": "layout threw"}])
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("b spine 0" in text for text in result["failures"]))

    def test_runs_scored_differently_are_not_compared(self):
        base, new = self.report(self.BASE), self.report(self.changed(a0=80))
        new["scorer"] = base["scorer"] + 1
        self.assertEqual(fidelity.compare_reports(base, new)["verdict"], "FAIL")

    def test_an_incomplete_capture_fails(self):
        result = fidelity.compare_reports(self.report(self.BASE), self.report(self.changed(a0=80), complete=False))
        self.assertEqual(result["verdict"], "FAIL")


class Provenance(unittest.TestCase):
    LOG = """Resolved source packages:
  SwiftSoup: https://github.com/scinfu/SwiftSoup @ 2.7.6
  YueduCoreText: {location} @ {version}
  Zip: https://github.com/marmelroy/Zip @ 2.1.2
"""

    def test_a_published_package_is_named_with_its_version(self):
        log = self.LOG.format(location="https://github.com/CHANG-JUI-LIN/YueduCoreText", version="0.6.1")
        self.assertEqual(fidelity.resolved_package(log), ("https://github.com/CHANG-JUI-LIN/YueduCoreText", "0.6.1"))

    def test_a_folder_a_workspace_put_in_its_place_is_local(self):
        # What xcodebuild 27 prints for it: the path and no version.
        log = "Resolved source packages:\n  YueduCoreText: /Users/someone/Desktop/Loop Copies/YueduCoreText\n" \
              "  Zip: https://github.com/marmelroy/Zip @ 2.1.2\n"
        self.assertEqual(fidelity.resolved_package(log), ("/Users/someone/Desktop/Loop Copies/YueduCoreText", "local"))

    def test_a_log_without_the_package_says_so(self):
        self.assertEqual(fidelity.resolved_package("Resolved source packages:\n  Zip: https://x @ 1.0\n"), (None, None))


class PresentationForms(unittest.TestCase):
    """A renderer's choice of glyph form for the same character is not a text difference."""

    def test_vertical_punctuation_forms_are_the_plain_characters(self):
        plain, _ = fidelity.normalize("他說：「好，走罷。」她問：「真的？」……")
        vertical, _ = fidelity.normalize("他說︓﹁好︐走罷︒﹂她問︓﹁真的︖﹂︙︙")
        self.assertEqual(plain, vertical)

    def test_full_width_and_half_width_twins_match(self):
        self.assertEqual(fidelity.normalize("ＡＢＣ１２３！")[0], fidelity.normalize("ABC123!")[0])

    def test_different_characters_stay_different(self):
        self.assertNotEqual(fidelity.normalize("好，走罷")[0], fidelity.normalize("好。走罷")[0])

    def test_a_vertical_rendering_with_presentation_forms_aligns_completely(self):
        body = [{"text": "他說：「這句話夠長，才會換行；標點也算在裡面。」她答：「知道了，走罷。」"} for _ in range(4)]
        swapped = [{"text": paragraph["text"].translate(str.maketrans("：「，；。」", "︓﹁︐︔︒﹂"))} for paragraph in body]
        result = score(render(body, vertical=True), render(swapped, vertical=True))
        self.assertEqual(result["matched"], result["referenceCharacters"])
        self.assertGreater(result["total"], 99)


class BreakAgreement(unittest.TestCase):
    def test_exact_near_and_far(self):
        self.assertEqual(fidelity.break_score([20, 40, 60], [20, 40, 60]), 1.0)
        self.assertAlmostEqual(fidelity.break_score([20, 40, 60], [21, 41, 61]), 0.6)
        self.assertEqual(fidelity.break_score([20, 40, 60], [30, 50, 70]), 0.0)
        self.assertEqual(fidelity.break_score([], [10]), 0.0)
        self.assertEqual(fidelity.break_score([], []), 1.0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
