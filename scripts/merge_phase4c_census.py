#!/usr/bin/env python3
"""Merge a successful Phase 4C census shard into the checked-in artifact.

The full simulator run scanned every book except Kusamakura before reporting its
Unicode ZIP-entry read failures.  Kusamakura is scanned separately so a
CoreSimulator restart cannot discard the other 7,335 completed chapter scans.
This merger is intentionally specific to that deterministic recovery path.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


KUSAMAKURA_ID = "official-epub3/kusamakura-japanese-vertical-writing.epub"


def merge_counted_records(
    left: list[dict[str, Any]],
    right: list[dict[str, Any]],
    identity_fields: tuple[str, ...],
) -> list[dict[str, Any]]:
    merged: dict[tuple[Any, ...], dict[str, Any]] = {}
    for record in [*left, *right]:
        key = tuple(record[field] for field in identity_fields)
        destination = merged.setdefault(
            key, {field: record[field] for field in identity_fields}
        )
        for count in ("epubCount", "chapterCount", "elementHits"):
            if count in record:
                destination[count] = destination.get(count, 0) + record[count]
    return list(merged.values())


def merge_features(
    base_features: list[dict[str, Any]],
    shard_features: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    by_feature = {feature["feature"]: feature for feature in base_features}

    for shard_feature in shard_features:
        name = shard_feature["feature"]
        if name not in by_feature:
            by_feature[name] = shard_feature
            continue

        base_feature = by_feature[name]
        for count in ("epubCount", "chapterCount", "elementHits"):
            base_feature[count] += shard_feature[count]

        base_feature["layers"] = merge_counted_records(
            base_feature["layers"], shard_feature["layers"], ("layer",)
        )
        base_feature["patterns"] = merge_counted_records(
            base_feature["patterns"],
            shard_feature["patterns"],
            ("layer", "property", "value", "selector", "element"),
        )

    for feature in by_feature.values():
        feature["layers"].sort(
            key=lambda layer: (
                -layer["chapterCount"],
                -layer["epubCount"],
                -layer["elementHits"],
                layer["layer"],
            )
        )
        feature["patterns"].sort(
            key=lambda pattern: (
                -pattern["chapterCount"],
                -pattern["epubCount"],
                -pattern["elementHits"],
                pattern["layer"],
                pattern["property"],
                pattern["value"],
                pattern["selector"],
                pattern["element"],
            )
        )
        feature["patterns"] = feature["patterns"][:30]

    return sorted(
        by_feature.values(),
        key=lambda feature: (
            -feature["epubCount"],
            -feature["chapterCount"],
            feature["feature"],
        ),
    )


def rebuild_origins(books: list[dict[str, Any]]) -> list[dict[str, Any]]:
    origins: dict[str, dict[str, Any]] = {}
    for book in books:
        origin = origins.setdefault(
            book["origin"],
            {
                "origin": book["origin"],
                "epubCount": 0,
                "chapterCount": 0,
                "scannedChapterCount": 0,
            },
        )
        origin["epubCount"] += 1
        origin["chapterCount"] += book["chapterCount"]
        origin["scannedChapterCount"] += book["scannedChapterCount"]
    return sorted(origins.values(), key=lambda origin: origin["origin"])


def negate_counted_records(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for record in records:
        negative = dict(record)
        for count in ("epubCount", "chapterCount", "elementHits"):
            if count in negative:
                negative[count] = -negative[count]
        result.append(negative)
    return result


def negate_features(features: list[dict[str, Any]]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for feature in features:
        negative = dict(feature)
        for count in ("epubCount", "chapterCount", "elementHits"):
            negative[count] = -negative[count]
        negative["layers"] = negate_counted_records(feature["layers"])
        negative["patterns"] = negate_counted_records(feature["patterns"])
        result.append(negative)
    return result


def remove_previous_shard(
    base: dict[str, Any], previous_shard: dict[str, Any]
) -> dict[str, Any]:
    existing = next(book for book in base["books"] if book["id"] == KUSAMAKURA_ID)
    if existing["scannedChapterCount"] != 15:
        raise ValueError("cannot replace a Kusamakura shard that is not already merged")

    unscanned_book = dict(existing)
    unscanned_book["scannedChapterCount"] = 0
    unscanned_book["scannerFallbackChapterCount"] = 0
    books = [
        unscanned_book if book["id"] == KUSAMAKURA_ID else book
        for book in base["books"]
    ]

    result = dict(base)
    result["books"] = books
    result["origins"] = rebuild_origins(books)
    result["scannedChapterCount"] = sum(
        book["scannedChapterCount"] for book in books
    )
    result["features"] = merge_features(
        base["features"], negate_features(previous_shard["features"])
    )
    result["scannerFallbacks"] = merge_counted_records(
        base["scannerFallbacks"],
        negate_counted_records(previous_shard["scannerFallbacks"]),
        ("reason",),
    )
    result["scannerFallbacks"] = [
        fallback
        for fallback in result["scannerFallbacks"]
        if fallback["epubCount"] > 0 or fallback["chapterCount"] > 0
    ]
    fallback_prefix = f"{KUSAMAKURA_ID}#"
    result["ingestionFallbacks"] = [
        fallback
        for fallback in base.get("ingestionFallbacks", [])
        if not fallback.startswith(fallback_prefix)
    ]
    return result


def merge(base: dict[str, Any], shard: dict[str, Any]) -> dict[str, Any]:
    shard_books = shard["books"]
    if len(shard_books) != 1 or shard_books[0]["id"] != KUSAMAKURA_ID:
        raise ValueError("the shard must contain only the Kusamakura census")
    if shard["corpusChapterCount"] != 15 or shard["scannedChapterCount"] != 15:
        raise ValueError("the Kusamakura shard must contain 15 successful chapters")
    if shard["failures"]:
        raise ValueError("the Kusamakura shard contains scan failures")

    existing = next(book for book in base["books"] if book["id"] == KUSAMAKURA_ID)
    if existing["scannedChapterCount"] == 15:
        return base
    if existing["scannedChapterCount"] != 0:
        raise ValueError("the base has a partially scanned Kusamakura entry")

    books = [book for book in base["books"] if book["id"] != KUSAMAKURA_ID]
    books.extend(shard_books)
    books.sort(key=lambda book: book["id"])

    failure_prefix = f"{KUSAMAKURA_ID}#"
    failures = [
        failure for failure in base["failures"] if not failure.startswith(failure_prefix)
    ]
    failures.extend(shard["failures"])

    result = dict(base)
    result["books"] = books
    result["origins"] = rebuild_origins(books)
    result["corpusEPUBCount"] = len(books)
    result["corpusChapterCount"] = sum(book["chapterCount"] for book in books)
    result["scannedChapterCount"] = sum(
        book["scannedChapterCount"] for book in books
    )
    result["failures"] = sorted(failures)
    result["ingestionFallbacks"] = sorted(
        [*base.get("ingestionFallbacks", []), *shard.get("ingestionFallbacks", [])]
    )
    result["features"] = merge_features(base["features"], shard["features"])
    result["scannerFallbacks"] = merge_counted_records(
        base["scannerFallbacks"], shard["scannerFallbacks"], ("reason",)
    )
    result["scannerFallbacks"].sort(
        key=lambda fallback: (
            -fallback["epubCount"],
            -fallback["chapterCount"],
            fallback["reason"],
        )
    )

    if (
        result["corpusEPUBCount"] != 23
        or result["corpusChapterCount"] != 7_350
        or result["scannedChapterCount"] != 7_350
        or result["failures"]
        or len(result["ingestionFallbacks"]) != 15
    ):
        raise ValueError("merged census failed corpus completeness checks")
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True, type=Path)
    parser.add_argument("--shard", required=True, type=Path)
    parser.add_argument("--previous-shard", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    with args.base.open(encoding="utf-8") as handle:
        base = json.load(handle)
    with args.shard.open(encoding="utf-8") as handle:
        shard = json.load(handle)
    if args.previous_shard:
        with args.previous_shard.open(encoding="utf-8") as handle:
            previous_shard = json.load(handle)
        base = remove_previous_shard(base, previous_shard)

    result = merge(base, shard)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as handle:
        json.dump(result, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")


if __name__ == "__main__":
    main()
