#!/usr/bin/env python3
"""Load and validate the committed IDPF EPUB 3 sample manifest."""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
DEFAULT_MANIFEST = (
    Path(__file__).resolve().parents[1]
    / "docs"
    / "build-week"
    / "epub3"
    / "sample-manifest.json"
)


class ManifestError(ValueError):
    """Raised when an EPUB sample manifest violates its schema."""


@dataclass(frozen=True)
class SmokeTarget:
    chapter_index: int | None
    spine_href: str | None
    text_probes: tuple[str, ...]
    expects_image_page: bool
    expects_fallback: bool


@dataclass(frozen=True)
class Sample:
    id: str
    title: str
    source_url: str
    catalog_url: str
    filename: str
    sha256: str
    license: str
    features: tuple[str, ...]
    smoke_targets: tuple[SmokeTarget, ...]
    manual: bool
    manual_checkpoints: tuple[str, ...]


@dataclass(frozen=True)
class Manifest:
    schema_version: int
    samples: tuple[Sample, ...]


def _error(sample_id: str, field: str, detail: str) -> ManifestError:
    return ManifestError(f"sample {sample_id!r} field {field!r}: {detail}")


def _require_object(value: Any, sample_id: str, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise _error(sample_id, field, "must be an object")
    return value


def _require_string(entry: dict[str, Any], sample_id: str, field: str) -> str:
    if field not in entry:
        raise _error(sample_id, field, "is required")
    value = entry[field]
    if not isinstance(value, str) or not value.strip():
        raise _error(sample_id, field, "must be a nonempty string")
    return value


def _require_bool(entry: dict[str, Any], sample_id: str, field: str) -> bool:
    if field not in entry:
        raise _error(sample_id, field, "is required")
    value = entry[field]
    if not isinstance(value, bool):
        raise _error(sample_id, field, "must be a boolean")
    return value


def _require_string_list(
    entry: dict[str, Any], sample_id: str, field: str, *, nonempty: bool
) -> tuple[str, ...]:
    if field not in entry:
        raise _error(sample_id, field, "is required")
    value = entry[field]
    if not isinstance(value, list):
        raise _error(sample_id, field, "must be a list")
    if nonempty and not value:
        raise _error(sample_id, field, "must not be empty")
    if any(not isinstance(item, str) or not item.strip() for item in value):
        raise _error(sample_id, field, "must contain only nonempty strings")
    return tuple(value)


def _parse_smoke_target(
    value: Any, sample_id: str, target_index: int
) -> SmokeTarget:
    field = f"smoke_targets[{target_index}]"
    entry = _require_object(value, sample_id, field)
    allowed_fields = {
        "chapter_index",
        "spine_href",
        "text_probes",
        "expects_image_page",
        "expects_fallback",
    }
    unexpected = sorted(set(entry) - allowed_fields)
    if unexpected:
        raise _error(sample_id, field, f"unexpected fields: {', '.join(unexpected)}")

    has_chapter_index = "chapter_index" in entry
    has_spine_href = "spine_href" in entry
    if has_chapter_index == has_spine_href:
        raise _error(
            sample_id,
            field,
            "must contain exactly one of chapter_index or spine_href",
        )

    chapter_index = entry.get("chapter_index")
    if has_chapter_index and (
        not isinstance(chapter_index, int)
        or isinstance(chapter_index, bool)
        or chapter_index < 0
    ):
        raise _error(sample_id, f"{field}.chapter_index", "must be a nonnegative integer")

    spine_href = entry.get("spine_href")
    if has_spine_href and (
        not isinstance(spine_href, str) or not spine_href.strip()
    ):
        raise _error(sample_id, f"{field}.spine_href", "must be a nonempty string")

    text_probes = _require_string_list(entry, sample_id, "text_probes", nonempty=False)
    expects_image_page = _require_bool(entry, sample_id, "expects_image_page")
    expects_fallback = _require_bool(entry, sample_id, "expects_fallback")
    return SmokeTarget(
        chapter_index=chapter_index,
        spine_href=spine_href,
        text_probes=text_probes,
        expects_image_page=expects_image_page,
        expects_fallback=expects_fallback,
    )


def _parse_sample(value: Any, index: int) -> Sample:
    placeholder_id = f"samples[{index}]"
    entry = _require_object(value, placeholder_id, placeholder_id)
    raw_id = entry.get("id")
    sample_id = raw_id if isinstance(raw_id, str) and raw_id else placeholder_id
    allowed_fields = {
        "id",
        "title",
        "source_url",
        "catalog_url",
        "filename",
        "sha256",
        "license",
        "features",
        "smoke_targets",
        "manual",
        "manual_checkpoints",
    }
    unexpected = sorted(set(entry) - allowed_fields)
    if unexpected:
        raise _error(sample_id, "entry", f"unexpected fields: {', '.join(unexpected)}")

    sample_id = _require_string(entry, sample_id, "id")
    title = _require_string(entry, sample_id, "title")
    source_url = _require_string(entry, sample_id, "source_url")
    catalog_url = _require_string(entry, sample_id, "catalog_url")
    filename = _require_string(entry, sample_id, "filename")
    sha256 = _require_string(entry, sample_id, "sha256")
    license_note = _require_string(entry, sample_id, "license")
    features = _require_string_list(entry, sample_id, "features", nonempty=True)
    manual = _require_bool(entry, sample_id, "manual")
    manual_checkpoints = _require_string_list(
        entry, sample_id, "manual_checkpoints", nonempty=manual
    )

    for field, url in (("source_url", source_url), ("catalog_url", catalog_url)):
        parsed = urlparse(url)
        if parsed.scheme != "https" or not parsed.netloc:
            raise _error(sample_id, field, "must be an absolute HTTPS URL")
    if not SHA256_PATTERN.fullmatch(sha256):
        raise _error(sample_id, "sha256", "must be 64 lowercase hexadecimal characters")

    if "smoke_targets" not in entry:
        raise _error(sample_id, "smoke_targets", "is required")
    smoke_targets_value = entry["smoke_targets"]
    if not isinstance(smoke_targets_value, list) or not smoke_targets_value:
        raise _error(sample_id, "smoke_targets", "must be a nonempty list")
    smoke_targets = tuple(
        _parse_smoke_target(target, sample_id, target_index)
        for target_index, target in enumerate(smoke_targets_value)
    )

    return Sample(
        id=sample_id,
        title=title,
        source_url=source_url,
        catalog_url=catalog_url,
        filename=filename,
        sha256=sha256,
        license=license_note,
        features=features,
        smoke_targets=smoke_targets,
        manual=manual,
        manual_checkpoints=manual_checkpoints,
    )


def validate_manifest(manifest: Manifest) -> None:
    """Validate constraints that span multiple samples."""

    seen_ids: set[str] = set()
    seen_filenames: set[str] = set()
    for sample in manifest.samples:
        if sample.id in seen_ids:
            raise _error(sample.id, "id", "duplicates another sample")
        seen_ids.add(sample.id)
        if sample.filename in seen_filenames:
            raise _error(sample.id, "filename", "duplicates another sample")
        seen_filenames.add(sample.filename)


def load_manifest(path: str | Path) -> Manifest:
    """Load a JSON manifest without coercing malformed values."""

    manifest_path = Path(path)
    try:
        raw = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ManifestError(f"manifest {manifest_path}: {error}") from error
    if not isinstance(raw, dict):
        raise ManifestError("manifest field 'root': must be an object")
    unexpected = sorted(set(raw) - {"schema_version", "samples"})
    if unexpected:
        raise ManifestError(f"manifest field 'root': unexpected fields: {', '.join(unexpected)}")
    if "schema_version" not in raw:
        raise ManifestError("manifest field 'root.schema_version': is required")
    schema_version = raw["schema_version"]
    if not isinstance(schema_version, int) or isinstance(schema_version, bool):
        raise ManifestError("manifest field 'root.schema_version': must be an integer")
    if schema_version != 1:
        raise ManifestError(
            f"manifest field 'root.schema_version': unsupported value {schema_version}; expected 1"
        )
    if "samples" not in raw:
        raise ManifestError("manifest field 'samples': is required")
    if not isinstance(raw["samples"], list):
        raise ManifestError("manifest field 'samples': must be a list")

    manifest = Manifest(
        schema_version=schema_version,
        samples=tuple(
            _parse_sample(sample, index) for index, sample in enumerate(raw["samples"])
        )
    )
    validate_manifest(manifest)
    return manifest


def _manifest_check(path: Path) -> int:
    manifest = load_manifest(path)
    manual_count = sum(sample.manual for sample in manifest.samples)
    if manual_count != 8:
        raise ManifestError(
            f"manifest field 'manual': expected exactly 8 manual samples, found {manual_count}"
        )
    print(
        f"manifest OK: total={len(manifest.samples)} "
        f"manual={manual_count} automated={len(manifest.samples) - manual_count}"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    check_parser = subparsers.add_parser("manifest-check", help="validate the manifest")
    check_parser.add_argument("path", nargs="?", type=Path, default=DEFAULT_MANIFEST)
    arguments = parser.parse_args(argv)

    try:
        if arguments.command == "manifest-check":
            return _manifest_check(arguments.path)
    except ManifestError as error:
        parser.exit(1, f"manifest error: {error}\n")
    raise AssertionError("unreachable")


if __name__ == "__main__":
    raise SystemExit(main())
