#!/usr/bin/env python3
"""Load and validate the committed IDPF EPUB 3 sample manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import posixpath
import re
import ssl
import sys
import tempfile
import urllib.request
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable
from urllib.parse import unquote, urlparse, urlsplit
from xml.etree import ElementTree


SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
DEFAULT_MANIFEST = (
    Path(__file__).resolve().parents[1]
    / "docs"
    / "build-week"
    / "epub3"
    / "sample-manifest.json"
)
DEFAULT_BOOKS_DIR = (
    Path(__file__).resolve().parents[1]
    / ".build-week"
    / "epub3-samples"
    / "books"
)
DEFAULT_SCAN_RESULTS = (
    Path(__file__).resolve().parents[1]
    / ".build-week"
    / "epub3-samples"
    / "results"
    / "scan-results.json"
)
DEFAULT_MATRIX = (
    Path(__file__).resolve().parents[1]
    / "docs"
    / "build-week"
    / "epub3"
    / "compatibility-matrix.md"
)
DEFAULT_EVIDENCE_ROOT = (
    Path(__file__).resolve().parents[1]
    / "docs"
    / "build-week"
    / "epub3"
    / "evidence"
)
ZIP_SIGNATURES = (b"PK\x03\x04", b"PK\x05\x06", b"PK\x07\x08")
EPUB_MIMETYPE = b"application/epub+zip"
OPF_MEDIA_TYPE = "application/oebps-package+xml"
OCF_NAMESPACE = "urn:oasis:names:tc:opendocument:xmlns:container"
OPF_NAMESPACE = "http://www.idpf.org/2007/opf"
DC_NAMESPACE = "http://purl.org/dc/elements/1.1/"
EPUB_NAMESPACE = "http://www.idpf.org/2007/ops"
XHTML_NAMESPACE = "http://www.w3.org/1999/xhtml"
MATHML_NAMESPACE = "http://www.w3.org/1998/Math/MathML"
SVG_NAMESPACE = "http://www.w3.org/2000/svg"
SMIL_NAMESPACE = "http://www.w3.org/ns/SMIL"
MAX_ARCHIVE_ENTRIES = 10_000
MAX_TOTAL_UNCOMPRESSED = 512 * 1024 * 1024
MAX_ENTRY_UNCOMPRESSED = 128 * 1024 * 1024
MAX_COMPRESSION_RATIO = 200
MAX_PARSED_RESOURCE_BYTES = 32 * 1024 * 1024
EVIDENCE_ID_PATTERN = re.compile(r"BW-EPUB3-[0-9]{3}\Z")
EVIDENCE_REFERENCE_PATTERN = re.compile(r"\bBW-EPUB3-[A-Za-z0-9-]+\b")
COMMIT_REFERENCE_PATTERN = re.compile(r"\b[0-9a-f]{7,40}\b")
ALLOWED_MATRIX_OUTCOMES = frozenset(
    {
        "baseline-supported",
        "build-week-fixed",
        "readable-fallback",
        "unsupported-safe",
        "failing",
        "not-run",
    }
)
MATRIX_HEADERS = (
    "Sample",
    "SHA-256",
    "Features",
    "B static",
    "B open",
    "B render",
    "B paged",
    "B scroll",
    "B manual",
    "C static",
    "C open",
    "C render",
    "C paged",
    "C scroll",
    "C manual",
    "Final outcome",
    "Issue",
    "Evidence",
    "Test",
    "Commit",
)
REQUIRED_EVIDENCE_FIELDS = {
    "sample/checkpoint": "Sample/checkpoint",
    "sample checksum": "Sample checksum",
    "baseline commit": "Baseline commit",
    "after commit": "After commit",
    "fixture": "Fixture",
    "test command": "Test command",
    "device/ios/settings": "Device/iOS/settings",
    "expected behavior": "Expected behavior",
    "observed behavior": "Observed behavior",
    "official content visible": "Official content visible",
}
MATRIX_PLACEHOLDERS = frozenset({"", "-", "n/a", "none", "not-run", "pending"})


def _urlopen_with_system_ca(url: str, *, timeout: int):
    verify_paths = ssl.get_default_verify_paths()
    context = None
    system_ca_file = Path("/etc/ssl/cert.pem")
    if (
        verify_paths.cafile is None
        and verify_paths.capath is None
        and system_ca_file.is_file()
    ):
        context = ssl.create_default_context(cafile=system_ca_file)
    return urllib.request.urlopen(url, timeout=timeout, context=context)


class ManifestError(ValueError):
    """Raised when an EPUB sample manifest violates its schema."""


class MatrixError(ValueError):
    """Raised when the committed compatibility matrix is incomplete or invalid."""


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


@dataclass(frozen=True)
class FetchResult:
    sample_id: str
    status: str
    message: str
    path: Path

    @property
    def ok(self) -> bool:
        return self.status in {"downloaded", "cached"}


@dataclass(frozen=True)
class ScanResult:
    sample_id: str
    path: Path
    status: str
    rootfile: str | None
    version: str | None
    manifest_count: int
    spine_count: int
    nav: str | None
    detected_features: tuple[str, ...]
    warnings: tuple[str, ...]
    errors: tuple[str, ...]

    @property
    def ok(self) -> bool:
        return self.status == "passed"


@dataclass(frozen=True)
class MatrixCheckResult:
    sample_count: int
    evidence_count: int


def _error(sample_id: str, field: str, detail: str) -> ManifestError:
    return ManifestError(f"sample {sample_id!r} field {field!r}: {detail}")


def _require_safe_filename(sample_id: str, filename: str) -> str:
    if (
        not isinstance(filename, str)
        or not filename.strip()
        or filename in {".", ".."}
        or Path(filename).is_absolute()
        or "/" in filename
        or "\\" in filename
        or Path(filename).name != filename
    ):
        raise _error(sample_id, "filename", "must be a single safe basename")
    return filename


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
    filename = _require_safe_filename(
        sample_id, _require_string(entry, sample_id, "filename")
    )
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


def sha256_file(path: str | Path) -> str:
    """Return the lowercase SHA-256 digest for a file."""

    digest = hashlib.sha256()
    with Path(path).open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def has_zip_signature(path: str | Path) -> bool:
    """Return whether a file starts with a recognized ZIP signature."""

    with Path(path).open("rb") as file:
        return file.read(4) in ZIP_SIGNATURES


def fetch_sample(
    sample: Sample,
    books_dir: str | Path,
    *,
    force: bool = False,
    opener: Callable[..., Any] = _urlopen_with_system_ca,
) -> FetchResult:
    """Download and verify one EPUB without exposing partial content."""

    books_path = Path(books_dir)
    destination = (
        books_path / sample.filename
        if isinstance(sample.filename, str)
        else books_path
    )
    part_path: Path | None = None

    try:
        filename = _require_safe_filename(sample.id, sample.filename)
        books_path.mkdir(parents=True, exist_ok=True)
        resolved_books_path = books_path.resolve(strict=True)
        if not resolved_books_path.is_dir():
            raise NotADirectoryError(f"books path is not a directory: {books_path}")
        destination = resolved_books_path / filename
        resolved_destination = destination.resolve(strict=False)
        if resolved_destination.parent != resolved_books_path:
            raise _error(
                sample.id,
                "filename",
                "must resolve directly inside the books directory",
            )
    except (OSError, RuntimeError, ValueError) as error:
        return FetchResult(
            sample_id=sample.id,
            status="failed",
            message=str(error),
            path=destination,
        )

    if not force and destination.is_file():
        try:
            if (
                has_zip_signature(destination)
                and sha256_file(destination) == sample.sha256
            ):
                return FetchResult(
                    sample_id=sample.id,
                    status="cached",
                    message="verified cache",
                    path=destination,
                )
        except OSError:
            pass

    try:
        descriptor, part_name = tempfile.mkstemp(
            prefix=f".{filename}.", suffix=".part", dir=resolved_books_path
        )
        part_path = Path(part_name)
        with os.fdopen(descriptor, "wb") as output:
            with opener(sample.source_url, timeout=60) as response:
                while chunk := response.read(1024 * 1024):
                    output.write(chunk)

        if not has_zip_signature(part_path):
            raise ValueError("download does not have a ZIP signature")
        actual_sha256 = sha256_file(part_path)
        if actual_sha256 != sample.sha256:
            raise ValueError(
                f"checksum mismatch: expected {sample.sha256}, got {actual_sha256}"
            )
        os.replace(part_path, destination)
        return FetchResult(
            sample_id=sample.id,
            status="downloaded",
            message="downloaded and verified",
            path=destination,
        )
    except Exception as error:
        return FetchResult(
            sample_id=sample.id,
            status="failed",
            message=str(error),
            path=destination,
        )
    finally:
        if part_path is not None:
            try:
                part_path.unlink(missing_ok=True)
            except OSError:
                pass


def fetch_all(
    samples: Iterable[Sample],
    books_dir: str | Path,
    *,
    force: bool = False,
    opener: Callable[..., Any] = _urlopen_with_system_ca,
) -> tuple[FetchResult, ...]:
    """Fetch every sample, retaining an individual result for every attempt."""

    return tuple(
        fetch_sample(sample, books_dir, force=force, opener=opener)
        for sample in samples
    )


@dataclass(frozen=True)
class _PackageItem:
    id: str
    href: str
    media_type: str
    properties: tuple[str, ...]
    resource_path: str | None
    external: bool
    media_overlay: str | None


def _local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _namespace(tag: str) -> str | None:
    if tag.startswith("{") and "}" in tag:
        return tag[1:].split("}", 1)[0]
    return None


def _qname(namespace: str, local_name: str) -> str:
    return f"{{{namespace}}}{local_name}"


def _direct_children(
    element: ElementTree.Element, local_name: str
) -> list[ElementTree.Element]:
    return [child for child in element if _local_name(child.tag) == local_name]


def _direct_qualified_children(
    element: ElementTree.Element, namespace: str, local_name: str
) -> list[ElementTree.Element]:
    qualified = _qname(namespace, local_name)
    return [child for child in element if child.tag == qualified]


def _css_declaration_context(text: str) -> str:
    output: list[str] = []
    quote: str | None = None
    comment = False
    function_depth = 0
    index = 0
    while index < len(text):
        character = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""
        if comment:
            output.append(" ")
            if character == "*" and following == "/":
                output.append(" ")
                comment = False
                index += 2
            else:
                index += 1
            continue
        if quote is not None:
            output.append(" ")
            if character == "\\" and following:
                output.append(" ")
                index += 2
            elif character == quote:
                quote = None
                index += 1
            else:
                index += 1
            continue
        if character == "/" and following == "*":
            output.extend((" ", " "))
            comment = True
            index += 2
        elif character in {'"', "'"}:
            quote = character
            output.append(" ")
            index += 1
        elif character == "\\":
            output.append(" ")
            if following:
                output.append(" ")
                index += 2
            else:
                index += 1
        elif character == "(":
            function_depth += 1
            output.append(" ")
            index += 1
        elif function_depth:
            if character == ")":
                function_depth -= 1
            output.append(" ")
            index += 1
        else:
            output.append(character)
            index += 1
    return "".join(output)


def _detect_css_features(text: str, features: set[str]) -> None:
    css = _css_declaration_context(text).lower()
    if re.search(
        r"(?:^|[;{])\s*(?:-epub-|-webkit-)?writing-mode\s*:\s*"
        r"(?:vertical(?:-rl|-lr)?|sideways(?:-rl|-lr)?)\b",
        css,
    ):
        features.add("vertical-writing")
    if re.search(r"(?:^|[;{])\s*direction\s*:\s*rtl\b", css):
        features.add("rtl")


def _scan_message(sample_id: str, detail: str, entry: str | None = None) -> str:
    location = f" entry {entry!r}" if entry is not None else ""
    return f"sample {sample_id!r}{location}: {detail}"


def _failed_scan(
    sample_id: str,
    path: Path,
    errors: Iterable[str],
    *,
    rootfile: str | None = None,
    version: str | None = None,
    manifest_count: int = 0,
    spine_count: int = 0,
    nav: str | None = None,
    detected_features: Iterable[str] = (),
    warnings: Iterable[str] = (),
) -> ScanResult:
    return ScanResult(
        sample_id=sample_id,
        path=path,
        status="failed",
        rootfile=rootfile,
        version=version,
        manifest_count=manifest_count,
        spine_count=spine_count,
        nav=nav,
        detected_features=tuple(sorted(set(detected_features))),
        warnings=tuple(warnings),
        errors=tuple(errors),
    )


def _validate_zip_entries(
    infos: list[zipfile.ZipInfo], sample_id: str
) -> tuple[dict[str, zipfile.ZipInfo], list[str]]:
    entries: dict[str, zipfile.ZipInfo] = {}
    normalized_sources: dict[str, str] = {}
    errors: list[str] = []
    for info in infos:
        name = info.filename
        parts = name.split("/")
        normalized = posixpath.normpath(name)
        if name.startswith("/") or re.match(r"^[A-Za-z]:", name):
            errors.append(_scan_message(sample_id, "absolute ZIP entry path", name))
        if "\\" in name:
            errors.append(_scan_message(sample_id, "backslash in ZIP entry path", name))
        if ".." in parts:
            errors.append(_scan_message(sample_id, "parent traversal in ZIP entry path", name))
        if (
            not name
            or "" in parts[:-1]
            or "." in parts
            or "\x00" in name
            or normalized in {"", ".", ".."}
        ):
            errors.append(_scan_message(sample_id, "ambiguous ZIP entry path", name))

        collision_source = normalized_sources.get(normalized)
        if collision_source is not None:
            errors.append(
                _scan_message(
                    sample_id,
                    f"normalized-name collision with {collision_source!r}",
                    name,
                )
            )
        else:
            normalized_sources[normalized] = name
        entries[name] = info
    return entries, errors


def _resolve_archive_reference(
    base_directory: str, reference: str
) -> tuple[str | None, bool, str | None]:
    try:
        parsed = urlsplit(reference)
    except ValueError as error:
        return None, False, f"invalid URI: {error}"
    if parsed.scheme or parsed.netloc:
        return None, True, None
    try:
        decoded = unquote(parsed.path, encoding="utf-8", errors="strict")
    except UnicodeError as error:
        return None, False, f"invalid percent encoding: {error}"
    if not decoded:
        return None, False, "empty resource path"
    if decoded.startswith("/") or re.match(r"^[A-Za-z]:", decoded):
        return None, False, "absolute resource path"
    if "\\" in decoded or "\x00" in decoded:
        return None, False, "ambiguous resource path"
    normalized = posixpath.normpath(posixpath.join(base_directory, decoded))
    if normalized == ".." or normalized.startswith("../") or normalized.startswith("/"):
        return None, False, "resource path escapes archive root"
    return normalized, False, None


def _archive_budget_errors(
    infos: list[zipfile.ZipInfo], sample_id: str
) -> list[str]:
    errors: list[str] = []
    if len(infos) > MAX_ARCHIVE_ENTRIES:
        errors.append(_scan_message(sample_id, "archive entry count limit exceeded"))
    total = sum(info.file_size for info in infos)
    if total > MAX_TOTAL_UNCOMPRESSED:
        errors.append(_scan_message(sample_id, "archive total uncompressed limit exceeded"))
    for info in infos:
        if info.file_size > MAX_ENTRY_UNCOMPRESSED:
            errors.append(
                _scan_message(sample_id, "archive entry uncompressed limit exceeded", info.filename)
            )
        if info.file_size > 0:
            ratio = float("inf") if info.compress_size == 0 else info.file_size / info.compress_size
            if ratio > MAX_COMPRESSION_RATIO:
                errors.append(
                    _scan_message(sample_id, "archive compression ratio limit exceeded", info.filename)
                )
    return errors


def _read_capped_resource(
    archive: zipfile.ZipFile, entry: str, sample_id: str, label: str
) -> tuple[bytes | None, str | None]:
    chunks: list[bytes] = []
    total = 0
    try:
        with archive.open(entry, "r") as source:
            while chunk := source.read(64 * 1024):
                total += len(chunk)
                if total > MAX_PARSED_RESOURCE_BYTES:
                    return None, _scan_message(
                        sample_id, f"{label} parsed resource byte limit exceeded", entry
                    )
                chunks.append(chunk)
    except (KeyError, OSError, RuntimeError, zipfile.BadZipFile) as error:
        return None, _scan_message(sample_id, f"{label} resource unreadable: {error}", entry)
    return b"".join(chunks), None


def _parse_xml(
    archive: zipfile.ZipFile,
    entry: str,
    sample_id: str,
    label: str,
) -> tuple[ElementTree.Element | None, bytes | None, str | None]:
    payload, read_error = _read_capped_resource(archive, entry, sample_id, label)
    if read_error is not None:
        return None, None, read_error
    assert payload is not None
    try:
        return ElementTree.fromstring(payload), payload, None
    except ElementTree.ParseError as error:
        return None, payload, _scan_message(sample_id, f"{label} XML is not well-formed: {error}", entry)


def _scan_resource_features(
    archive: zipfile.ZipFile,
    sample_id: str,
    items: Iterable[_PackageItem],
    features: set[str],
    warnings: list[str],
    errors: list[str],
    binding_media_types: set[str],
) -> None:
    scanned_paths: set[str] = set()
    known_unscanned_types = {
        "application/javascript",
        "application/oebps-page-map+xml",
        "application/pls+xml",
        "application/ttml+xml",
        "application/adobe-page-template+xml",
        "application/font-woff",
        "application/vnd.ms-opentype",
        "application/x-dtbncx+xml",
        "application/xml",
        "application/octet-stream",
        "font/otf",
        "font/ttf",
        "font/woff",
        "font/woff2",
        "text/javascript",
        "text/vtt",
    }
    for item in items:
        path = item.resource_path
        if item.external or path is None or path in scanned_paths:
            continue
        scanned_paths.add(path)
        media_type = item.media_type.lower()
        if media_type == "text/css":
            payload, read_error = _read_capped_resource(
                archive, path, sample_id, "CSS"
            )
            if read_error is not None:
                errors.append(read_error)
                continue
            assert payload is not None
            text = payload.decode("utf-8", errors="replace").lower()
            _detect_css_features(text, features)
            continue

        xml_types = {
            "application/xhtml+xml",
            "application/smil+xml",
            "image/svg+xml",
            "application/mathml+xml",
        }
        if media_type not in xml_types:
            if not (
                media_type in known_unscanned_types
                or media_type in binding_media_types
                or media_type.startswith(("audio/", "image/", "video/"))
            ):
                warnings.append(
                    _scan_message(
                        sample_id,
                        f"unsupported media type not content-scanned: {item.media_type or '<missing>'}",
                        path,
                    )
                )
            continue

        root, _, xml_error = _parse_xml(
            archive, path, sample_id, "manifest resource"
        )
        if xml_error is not None:
            errors.append(xml_error)
            continue
        assert root is not None
        tags = {element.tag for element in root.iter()}
        if _qname(MATHML_NAMESPACE, "math") in tags:
            features.add("mathml")
        if _qname(XHTML_NAMESPACE, "ruby") in tags:
            features.add("ruby")
        if _qname(SVG_NAMESPACE, "svg") in tags:
            features.add("svg")
        if media_type == "image/svg+xml" and root.tag == _qname(SVG_NAMESPACE, "svg"):
            features.add("svg")
        for element in root.iter():
            if _namespace(element.tag) != XHTML_NAMESPACE:
                continue
            raw_direction = element.attrib.get("dir")
            if raw_direction is not None:
                direction = raw_direction.strip().lower()
                if direction not in {"ltr", "rtl", "auto"}:
                    errors.append(
                        _scan_message(
                            sample_id,
                            f"resource dir has invalid value {raw_direction!r}",
                            path,
                        )
                    )
                elif direction == "rtl":
                    features.add("rtl")
            style = element.attrib.get("style")
            if style is not None:
                _detect_css_features(style, features)
            if element.tag == _qname(XHTML_NAMESPACE, "style"):
                _detect_css_features("".join(element.itertext()), features)


def _validate_media_overlays(
    archive: zipfile.ZipFile,
    sample_id: str,
    items: list[_PackageItem],
    items_by_id: dict[str, _PackageItem],
    entries: dict[str, zipfile.ZipInfo],
    features: set[str],
    errors: list[str],
) -> None:
    for source in items:
        if source.media_overlay is None:
            continue
        valid = True
        if source.media_type not in {"application/xhtml+xml", "image/svg+xml"}:
            errors.append(
                _scan_message(sample_id, "media-overlay source Content Document required", source.href)
            )
            valid = False
        target = items_by_id.get(source.media_overlay)
        if target is None:
            continue
        if target.media_type != "application/smil+xml":
            continue
        if target.external or target.resource_path is None:
            errors.append(
                _scan_message(sample_id, "media-overlay target local SMIL required", target.href)
            )
            valid = False
        elif target.resource_path in entries:
            root, _, parse_error = _parse_xml(
                archive, target.resource_path, sample_id, "SMIL"
            )
            if parse_error is not None:
                errors.append(parse_error)
                valid = False
            elif root is not None:
                if root.tag != _qname(SMIL_NAMESPACE, "smil"):
                    detail = "SMIL root invalid"
                    if _local_name(root.tag) == "smil":
                        detail = "SMIL namespace invalid"
                    errors.append(_scan_message(sample_id, detail, target.resource_path))
                    valid = False
                if root.get("version") != "3.0":
                    errors.append(_scan_message(sample_id, "SMIL version must be 3.0", target.resource_path))
                    valid = False
                if not _direct_qualified_children(root, SMIL_NAMESPACE, "body"):
                    errors.append(_scan_message(sample_id, "SMIL direct body missing", target.resource_path))
                    valid = False
        else:
            valid = False
        if valid:
            features.add("media-overlay")


def _validate_container_vocabulary(
    root: ElementTree.Element, sample_id: str, entry: str, errors: list[str]
) -> bool:
    if _local_name(root.tag) != "container":
        errors.append(_scan_message(sample_id, "container root element must be container", entry))
        return False
    if root.tag != _qname(OCF_NAMESPACE, "container"):
        errors.append(_scan_message(sample_id, "OCF namespace invalid", entry))
        return False
    return True


def _validate_opf_skeleton(
    root: ElementTree.Element, sample_id: str, entry: str, errors: list[str]
) -> str | None:
    if _local_name(root.tag) != "package":
        errors.append(_scan_message(sample_id, "OPF root element is not package", entry))
        return None
    if root.tag != _qname(OPF_NAMESPACE, "package"):
        errors.append(_scan_message(sample_id, "OPF package namespace invalid", entry))
        return None
    version = root.get("version")
    if version is None or not version.strip():
        errors.append(_scan_message(sample_id, "OPF package version missing", entry))
    elif version.strip() != "3.0":
        errors.append(
            _scan_message(
                sample_id,
                f"unsupported package version {version!r}; expected '3.0'",
                entry,
            )
        )
    return version


def _validate_nav_document(
    archive: zipfile.ZipFile,
    sample_id: str,
    nav: str,
    errors: list[str],
) -> None:
    nav_root, _, nav_error = _parse_xml(archive, nav, sample_id, "nav XHTML")
    if nav_error is not None:
        errors.append(nav_error)
        return
    assert nav_root is not None
    if nav_root.tag != _qname(XHTML_NAMESPACE, "html"):
        errors.append(
            _scan_message(sample_id, "nav XHTML html root missing or in wrong namespace", nav)
        )
    toc_navs = [
        element
        for element in nav_root.iter()
        if element.tag == _qname(XHTML_NAMESPACE, "nav")
        and "toc" in element.get(f"{{{EPUB_NAMESPACE}}}type", "").split()
    ]
    if len(toc_navs) == 1:
        return
    foreign_toc = any(
        _local_name(element.tag) == "nav"
        and element.tag != _qname(XHTML_NAMESPACE, "nav")
        and "toc" in element.get(f"{{{EPUB_NAMESPACE}}}type", "").split()
        for element in nav_root.iter()
    )
    unqualified_toc = any(
        element.tag == _qname(XHTML_NAMESPACE, "nav")
        and "toc" in element.get("type", "").split()
        for element in nav_root.iter()
    )
    if foreign_toc:
        detail = "XHTML toc nav namespace invalid"
    elif not toc_navs and unqualified_toc:
        detail = "nav epub:type namespace invalid"
    else:
        detail = f"exactly one nav epub:type toc required; found {len(toc_navs)}"
    errors.append(_scan_message(sample_id, detail, nav))


def _validate_binding_handler(
    archive: zipfile.ZipFile,
    sample_id: str,
    package_entry: str,
    handler_id: str,
    handler: _PackageItem,
    entries: dict[str, zipfile.ZipInfo],
    errors: list[str],
) -> bool:
    valid = True
    if handler.external or handler.resource_path is None:
        errors.append(
            _scan_message(sample_id, f"binding handler local resource required for {handler_id!r}", package_entry)
        )
        valid = False
    if handler.media_type != "application/xhtml+xml":
        errors.append(
            _scan_message(sample_id, f"binding handler XHTML media-type required for {handler_id!r}", package_entry)
        )
        valid = False
    if "scripted" not in handler.properties:
        errors.append(
            _scan_message(sample_id, f"binding handler scripted property required for {handler_id!r}", package_entry)
        )
        valid = False
    if handler.external or handler.resource_path is None or handler.resource_path not in entries:
        return False
    root, _, parse_error = _parse_xml(
        archive, handler.resource_path, sample_id, "binding handler XHTML"
    )
    if parse_error is not None:
        errors.append(parse_error)
        return False
    assert root is not None
    if root.tag != _qname(XHTML_NAMESPACE, "html"):
        errors.append(_scan_message(sample_id, "binding handler XHTML root invalid", handler.resource_path))
        valid = False
    if not _direct_qualified_children(root, XHTML_NAMESPACE, "body"):
        errors.append(_scan_message(sample_id, "binding handler direct body missing", handler.resource_path))
        valid = False
    return valid


def scan_epub(path: str | Path, *, sample_id: str | None = None) -> ScanResult:
    """Read and structurally validate one EPUB package without extracting it."""

    epub_path = Path(path)
    resolved_sample_id = sample_id or epub_path.stem or epub_path.name
    rootfile: str | None = None
    version: str | None = None
    manifest_count = 0
    spine_count = 0
    nav: str | None = None
    features: set[str] = set()
    warnings: list[str] = []
    errors: list[str] = []

    try:
        archive = zipfile.ZipFile(epub_path, "r")
    except FileNotFoundError as error:
        return _failed_scan(
            resolved_sample_id,
            epub_path,
            (_scan_message(resolved_sample_id, f"missing EPUB: {error}"),),
        )
    except (OSError, zipfile.BadZipFile) as error:
        return _failed_scan(
            resolved_sample_id,
            epub_path,
            (_scan_message(resolved_sample_id, f"corrupt ZIP: {error}"),),
        )

    with archive:
        infos = archive.infolist()
        budget_errors = _archive_budget_errors(infos, resolved_sample_id)
        if budget_errors:
            return _failed_scan(resolved_sample_id, epub_path, budget_errors)
        entries, name_errors = _validate_zip_entries(infos, resolved_sample_id)
        errors.extend(name_errors)
        if errors:
            return _failed_scan(resolved_sample_id, epub_path, errors)

        mimetype_info = entries.get("mimetype")
        if mimetype_info is None:
            errors.append(_scan_message(resolved_sample_id, "mimetype missing"))
        else:
            if not infos or infos[0].filename != "mimetype":
                errors.append(
                    _scan_message(resolved_sample_id, "mimetype must be first ZIP entry", "mimetype")
                )
            if mimetype_info.compress_type != zipfile.ZIP_STORED:
                errors.append(
                    _scan_message(resolved_sample_id, "mimetype must be stored uncompressed", "mimetype")
                )
            try:
                mimetype_content = archive.read(mimetype_info)
            except (OSError, RuntimeError, zipfile.BadZipFile) as error:
                errors.append(
                    _scan_message(resolved_sample_id, f"mimetype content unreadable: {error}", "mimetype")
                )
            else:
                if mimetype_content != EPUB_MIMETYPE:
                    errors.append(
                        _scan_message(resolved_sample_id, "mimetype content must be application/epub+zip", "mimetype")
                    )

        container_entry = "META-INF/container.xml"
        if container_entry not in entries:
            errors.append(_scan_message(resolved_sample_id, "container.xml missing", container_entry))
            return _failed_scan(resolved_sample_id, epub_path, errors)
        container_root, _, container_error = _parse_xml(
            archive, container_entry, resolved_sample_id, "container.xml"
        )
        if container_error is not None:
            errors.append(container_error)
            return _failed_scan(resolved_sample_id, epub_path, errors)
        assert container_root is not None
        if not _validate_container_vocabulary(
            container_root, resolved_sample_id, container_entry, errors
        ):
            return _failed_scan(resolved_sample_id, epub_path, errors)
        rootfiles_elements = _direct_qualified_children(
            container_root, OCF_NAMESPACE, "rootfiles"
        )
        if not rootfiles_elements:
            if _direct_children(container_root, "rootfiles"):
                errors.append(
                    _scan_message(
                        resolved_sample_id,
                        "OCF direct child namespace invalid for rootfiles",
                        container_entry,
                    )
                )
        if len(rootfiles_elements) != 1:
            errors.append(
                _scan_message(
                    resolved_sample_id,
                    "container must have exactly one direct rootfiles element",
                    container_entry,
                )
            )
            return _failed_scan(resolved_sample_id, epub_path, errors)
        rootfiles = _direct_qualified_children(
            rootfiles_elements[0], OCF_NAMESPACE, "rootfile"
        )
        if not rootfiles:
            if _direct_children(rootfiles_elements[0], "rootfile"):
                errors.append(
                    _scan_message(
                        resolved_sample_id,
                        "OCF direct child namespace invalid for rootfile",
                        container_entry,
                    )
                )
        if not rootfiles:
            errors.append(
                _scan_message(resolved_sample_id, "direct rootfile missing", container_entry)
            )
            return _failed_scan(resolved_sample_id, epub_path, errors)
        supported_rootfiles: list[str] = []
        unsupported_media_types: list[str] = []
        for candidate in rootfiles:
            raw_path = candidate.get("full-path")
            media_type = candidate.get("media-type")
            if raw_path is None or not raw_path.strip():
                errors.append(
                    _scan_message(
                        resolved_sample_id,
                        "rootfile full-path must be nonblank",
                        container_entry,
                    )
                )
            if media_type is None or not media_type.strip():
                errors.append(
                    _scan_message(
                        resolved_sample_id,
                        "rootfile media-type must be nonblank",
                        container_entry,
                    )
                )
            elif media_type.strip() == OPF_MEDIA_TYPE and raw_path and raw_path.strip():
                supported_rootfiles.append(raw_path.strip())
            else:
                unsupported_media_types.append((media_type or "").strip())
        if not supported_rootfiles:
            errors.append(
                _scan_message(
                    resolved_sample_id,
                    "unsupported rootfile media-type; expected application/oebps-package+xml",
                    container_entry,
                )
            )
        if errors:
            return _failed_scan(resolved_sample_id, epub_path, errors)
        if unsupported_media_types:
            warnings.append(
                _scan_message(
                    resolved_sample_id,
                    f"ignored unsupported rootfile media-type(s): {', '.join(unsupported_media_types)}",
                    container_entry,
                )
            )
        raw_rootfile = supported_rootfiles[0]
        rootfile, rootfile_external, rootfile_error = _resolve_archive_reference("", raw_rootfile)
        if rootfile_error is not None or rootfile_external or rootfile is None:
            errors.append(
                _scan_message(
                    resolved_sample_id,
                    f"rootfile full-path invalid: {rootfile_error or 'external URI'}",
                    container_entry,
                )
            )
            return _failed_scan(resolved_sample_id, epub_path, errors)
        if rootfile not in entries:
            errors.append(_scan_message(resolved_sample_id, "rootfile resource missing", rootfile))
            return _failed_scan(resolved_sample_id, epub_path, errors, rootfile=rootfile)

        package_root, _, package_error = _parse_xml(
            archive, rootfile, resolved_sample_id, "OPF"
        )
        if package_error is not None:
            errors.append(package_error)
            return _failed_scan(resolved_sample_id, epub_path, errors, rootfile=rootfile)
        assert package_root is not None
        version = _validate_opf_skeleton(
            package_root, resolved_sample_id, rootfile, errors
        )
        if package_root.tag != _qname(OPF_NAMESPACE, "package"):
            return _failed_scan(resolved_sample_id, epub_path, errors, rootfile=rootfile)

        package_direction = package_root.get("dir")
        if package_direction is not None:
            direction = package_direction.strip().lower()
            if direction not in {"ltr", "rtl", "auto"}:
                errors.append(
                    _scan_message(
                        resolved_sample_id,
                        f"package dir has invalid value {package_direction!r}",
                        rootfile,
                    )
                )
            elif direction == "rtl":
                features.add("rtl")

        def opf_children(name: str) -> list[ElementTree.Element]:
            qualified = _direct_qualified_children(package_root, OPF_NAMESPACE, name)
            if qualified:
                return qualified
            local = _direct_children(package_root, name)
            if local:
                errors.append(
                    _scan_message(
                        resolved_sample_id,
                        f"OPF direct child namespace invalid for {name}",
                        rootfile,
                    )
                )
            return []

        metadata_elements = opf_children("metadata")
        manifest_elements = opf_children("manifest")
        spine_elements = opf_children("spine")
        if len(metadata_elements) != 1:
            errors.append(_scan_message(resolved_sample_id, "direct metadata missing or repeated", rootfile))
        if len(manifest_elements) != 1:
            errors.append(_scan_message(resolved_sample_id, "direct manifest missing or repeated", rootfile))
        if len(spine_elements) != 1:
            errors.append(_scan_message(resolved_sample_id, "direct spine missing or repeated", rootfile))
        if not metadata_elements or not manifest_elements or not spine_elements:
            return _failed_scan(
                resolved_sample_id, epub_path, errors, rootfile=rootfile, version=version
            )

        metadata_element = metadata_elements[0]
        metadata_by_name: dict[str, list[ElementTree.Element]] = {}
        for child in metadata_element:
            if _namespace(child.tag) == DC_NAMESPACE:
                metadata_by_name.setdefault(_local_name(child.tag), []).append(child)
        for required_name in ("identifier", "title", "language"):
            values = metadata_by_name.get(required_name, [])
            if not any((element.text or "").strip() for element in values):
                errors.append(
                    _scan_message(
                        resolved_sample_id, f"dc:{required_name} missing or blank", rootfile
                    )
                )

        raw_unique_identifier = package_root.get("unique-identifier")
        if raw_unique_identifier is None:
            errors.append(_scan_message(resolved_sample_id, "unique-identifier missing", rootfile))
            unique_identifier = ""
        else:
            unique_identifier = raw_unique_identifier.strip()
            if not unique_identifier:
                errors.append(_scan_message(resolved_sample_id, "unique-identifier blank", rootfile))
        if unique_identifier:
            matching_identifiers = [
                element
                for element in metadata_by_name.get("identifier", [])
                if element.get("id") == unique_identifier
            ]
            if not matching_identifiers:
                errors.append(
                    _scan_message(
                        resolved_sample_id,
                        f"unique-identifier target {unique_identifier!r} not found",
                        rootfile,
                    )
                )
            elif not any(
                (element.text or "").strip() for element in matching_identifiers
            ):
                errors.append(
                    _scan_message(
                        resolved_sample_id,
                        f"unique-identifier target blank for {unique_identifier!r}",
                        rootfile,
                    )
                )

        manifest_element = manifest_elements[0]
        package_directory = posixpath.dirname(rootfile)
        items: list[_PackageItem] = []
        items_by_id: dict[str, _PackageItem] = {}
        manifest_item_elements = _direct_qualified_children(
            manifest_element, OPF_NAMESPACE, "item"
        )
        manifest_count = len(manifest_item_elements)
        for element in manifest_item_elements:
            item_id = element.get("id", "").strip()
            href = element.get("href", "").strip()
            media_type = element.get("media-type", "").strip()
            properties = tuple(sorted(set(element.get("properties", "").split())))
            raw_media_overlay = element.get("media-overlay")
            media_overlay = (
                raw_media_overlay.strip() if raw_media_overlay is not None else None
            )
            if not item_id:
                errors.append(
                    _scan_message(
                        resolved_sample_id, "manifest item ID must be nonblank", rootfile
                    )
                )
                continue
            if item_id in items_by_id:
                errors.append(
                    _scan_message(resolved_sample_id, f"duplicate manifest ID {item_id!r}", rootfile)
                )
                continue
            if not href:
                errors.append(
                    _scan_message(
                        resolved_sample_id, "manifest item href must be nonblank", rootfile
                    )
                )
            if not media_type:
                errors.append(
                    _scan_message(
                        resolved_sample_id,
                        "manifest item media-type must be nonblank",
                        rootfile,
                    )
                )
            if raw_media_overlay is not None and not media_overlay:
                errors.append(
                    _scan_message(
                        resolved_sample_id,
                        "media-overlay IDREF blank",
                        rootfile,
                    )
                )
            if href:
                resource_path, external, href_error = _resolve_archive_reference(
                    package_directory, href
                )
            else:
                resource_path, external, href_error = None, False, None
            if href_error is not None:
                errors.append(
                    _scan_message(
                        resolved_sample_id,
                        f"manifest href {href!r} invalid: {href_error}",
                        rootfile,
                    )
                )
            item = _PackageItem(
                id=item_id,
                href=href,
                media_type=media_type,
                properties=properties,
                resource_path=resource_path,
                external=external,
                media_overlay=media_overlay,
            )
            items.append(item)
            items_by_id[item_id] = item

        for item in items:
            if (
                not item.external
                and item.resource_path is not None
                and item.resource_path not in entries
            ):
                errors.append(
                    _scan_message(
                        resolved_sample_id,
                        f"manifest resource missing for ID {item.id!r}",
                        item.resource_path,
                    )
                )
            if item.media_overlay is not None:
                overlay = items_by_id.get(item.media_overlay)
                if overlay is None:
                    errors.append(
                        _scan_message(
                            resolved_sample_id,
                            f"media-overlay IDREF {item.media_overlay!r} does not exist",
                            rootfile,
                        )
                    )
                elif overlay.media_type != "application/smil+xml":
                    errors.append(
                        _scan_message(
                            resolved_sample_id,
                            f"media-overlay SMIL target {item.media_overlay!r} has media-type {overlay.media_type!r}",
                            rootfile,
                        )
                    )

        _validate_media_overlays(
            archive,
            resolved_sample_id,
            items,
            items_by_id,
            entries,
            features,
            errors,
        )

        nav_items = [item for item in items if "nav" in item.properties]
        if len(nav_items) != 1:
            errors.append(
                _scan_message(
                    resolved_sample_id,
                    f"exactly one nav manifest item required; found {len(nav_items)}",
                    rootfile,
                )
            )
        else:
            nav_item = nav_items[0]
            nav = nav_item.resource_path
            if nav_item.media_type != "application/xhtml+xml":
                errors.append(
                    _scan_message(
                        resolved_sample_id,
                        f"nav media-type must be application/xhtml+xml, got {nav_item.media_type!r}",
                        rootfile,
                    )
                )
            if nav_item.external or nav is None or nav not in entries:
                errors.append(
                    _scan_message(resolved_sample_id, "nav resource missing", nav or nav_item.href)
                )
            else:
                _validate_nav_document(archive, resolved_sample_id, nav, errors)

        spine = spine_elements[0]
        progression = spine.get("page-progression-direction")
        if progression is not None:
            normalized_progression = progression.strip().lower()
            if normalized_progression not in {"default", "ltr", "rtl"}:
                errors.append(
                    _scan_message(
                        resolved_sample_id,
                        f"page-progression-direction has invalid value {progression!r}",
                        rootfile,
                    )
                )
            elif normalized_progression in {"ltr", "rtl"}:
                features.add("page-progression")
                if normalized_progression == "rtl":
                    features.add("rtl")
        itemrefs = _direct_qualified_children(spine, OPF_NAMESPACE, "itemref")
        spine_count = len(itemrefs)
        if not itemrefs:
            errors.append(
                _scan_message(
                    resolved_sample_id,
                    "spine must contain at least one direct itemref",
                    rootfile,
                )
            )
        for itemref in itemrefs:
            idref = itemref.get("idref", "").strip()
            if "rendition:layout-pre-paginated" in itemref.get("properties", "").split():
                features.add("fixed-layout")
            item = items_by_id.get(idref)
            if item is None:
                errors.append(
                    _scan_message(resolved_sample_id, f"spine idref {idref!r} does not exist", rootfile)
                )
            elif (
                item.external
                or item.resource_path is None
                or item.resource_path not in entries
            ):
                errors.append(
                    _scan_message(
                        resolved_sample_id,
                        f"spine resource missing for idref {idref!r}",
                        item.resource_path or item.href,
                    )
                )

        for meta in _direct_qualified_children(metadata_element, OPF_NAMESPACE, "meta"):
            if meta.get("property") == "rendition:layout":
                layout = (meta.text or "").strip().lower()
                if layout not in {"reflowable", "pre-paginated"}:
                    errors.append(
                        _scan_message(
                            resolved_sample_id,
                            f"rendition:layout has invalid value {layout!r}",
                            rootfile,
                        )
                    )
                elif layout == "pre-paginated":
                    features.add("fixed-layout")
        binding_media_types: set[str] = set()
        for bindings in _direct_qualified_children(package_root, OPF_NAMESPACE, "bindings"):
            media_types = _direct_qualified_children(bindings, OPF_NAMESPACE, "mediaType")
            bindings_valid = True
            if not media_types:
                errors.append(
                    _scan_message(
                        resolved_sample_id,
                        "bindings must contain at least one direct mediaType",
                        rootfile,
                    )
                )
                bindings_valid = False
            for media_type_binding in media_types:
                raw_media_type = media_type_binding.get("media-type")
                raw_handler = media_type_binding.get("handler")
                binding_media_type = (
                    raw_media_type.strip() if raw_media_type is not None else ""
                )
                handler_id = raw_handler.strip() if raw_handler is not None else ""
                if raw_media_type is None:
                    errors.append(
                        _scan_message(
                            resolved_sample_id, "binding media-type missing", rootfile
                        )
                    )
                    bindings_valid = False
                elif not binding_media_type:
                    errors.append(
                        _scan_message(
                            resolved_sample_id, "binding media-type blank", rootfile
                        )
                    )
                    bindings_valid = False
                else:
                    binding_media_types.add(binding_media_type.lower())
                if raw_handler is None:
                    errors.append(
                        _scan_message(
                            resolved_sample_id, "binding handler missing", rootfile
                        )
                    )
                    bindings_valid = False
                elif not handler_id:
                    errors.append(
                        _scan_message(
                            resolved_sample_id, "binding handler blank", rootfile
                        )
                    )
                    bindings_valid = False
                if handler_id:
                    handler = items_by_id.get(handler_id)
                    if handler is None:
                        errors.append(
                            _scan_message(
                                resolved_sample_id,
                                f"binding handler ID {handler_id!r} does not exist",
                                rootfile,
                            )
                        )
                        bindings_valid = False
                    elif not _validate_binding_handler(
                        archive,
                        resolved_sample_id,
                        rootfile,
                        handler_id,
                        handler,
                        entries,
                        errors,
                    ):
                        bindings_valid = False
            if bindings_valid:
                features.add("bindings")

        _scan_resource_features(
            archive,
            resolved_sample_id,
            items,
            features,
            warnings,
            errors,
            binding_media_types,
        )

    status = "passed" if not errors else "failed"
    return ScanResult(
        sample_id=resolved_sample_id,
        path=epub_path,
        status=status,
        rootfile=rootfile,
        version=version,
        manifest_count=manifest_count,
        spine_count=spine_count,
        nav=nav,
        detected_features=tuple(sorted(features)),
        warnings=tuple(warnings),
        errors=tuple(errors),
    )


def scan_all(
    samples: Iterable[Sample], books_dir: str | Path
) -> tuple[ScanResult, ...]:
    """Scan each unique requested sample and retain every individual result."""

    books_path = Path(books_dir)
    seen_ids: set[str] = set()
    results: list[ScanResult] = []
    for sample in samples:
        if sample.id in seen_ids:
            continue
        seen_ids.add(sample.id)
        results.append(
            scan_epub(books_path / sample.filename, sample_id=sample.id)
        )
    return tuple(results)


def write_scan_report(
    results: Iterable[ScanResult], path: str | Path
) -> Path:
    """Atomically write a deterministic JSON report for scan results."""

    report_path = Path(path)
    unique_results: dict[str, ScanResult] = {}
    for result in results:
        if result.sample_id in unique_results:
            raise ValueError(f"duplicate sample ID in scan report: {result.sample_id}")
        unique_results[result.sample_id] = result
    payload = {
        "schema_version": 1,
        "results": [
            {
                "detected_features": sorted(result.detected_features),
                "errors": list(result.errors),
                "manifest_count": result.manifest_count,
                "nav": result.nav,
                "path": str(result.path),
                "rootfile": result.rootfile,
                "sample_id": result.sample_id,
                "spine_count": result.spine_count,
                "status": result.status,
                "version": result.version,
                "warnings": list(result.warnings),
            }
            for result in sorted(unique_results.values(), key=lambda item: item.sample_id)
        ],
    }
    serialized = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")
    report_path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{report_path.name}.", suffix=".tmp", dir=report_path.parent
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(serialized)
        os.replace(temporary_path, report_path)
    finally:
        temporary_path.unlink(missing_ok=True)
    return report_path


def _matrix_cells(line: str) -> tuple[str, ...]:
    stripped = line.strip()
    if not stripped.startswith("|") or not stripped.endswith("|"):
        return ()
    return tuple(cell.strip() for cell in stripped[1:-1].split("|"))


def _plain_matrix_cell(cell: str) -> str:
    value = cell.strip()
    if len(value) >= 2 and value.startswith("`") and value.endswith("`"):
        value = value[1:-1].strip()
    return value


def _read_matrix_rows(path: Path) -> tuple[dict[str, str], ...]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise MatrixError(f"cannot read matrix {path}: {error}") from error

    header_index = None
    for index, line in enumerate(lines):
        if _matrix_cells(line) == MATRIX_HEADERS:
            header_index = index
            break
    if header_index is None:
        raise MatrixError("matrix header is missing or does not match the required schema")
    if header_index + 1 >= len(lines):
        raise MatrixError("matrix delimiter row is missing")
    delimiter = _matrix_cells(lines[header_index + 1])
    if len(delimiter) != len(MATRIX_HEADERS) or any(
        re.fullmatch(r":?-{3,}:?", cell) is None for cell in delimiter
    ):
        raise MatrixError("matrix delimiter row is invalid")

    rows: list[dict[str, str]] = []
    for line_number, line in enumerate(lines[header_index + 2 :], start=header_index + 3):
        if not line.strip():
            if rows:
                break
            continue
        cells = _matrix_cells(line)
        if not cells:
            if rows:
                break
            raise MatrixError(f"matrix row {line_number} is not a Markdown table row")
        if len(cells) != len(MATRIX_HEADERS):
            raise MatrixError(
                f"matrix row {line_number} has {len(cells)} columns; "
                f"expected {len(MATRIX_HEADERS)}"
            )
        rows.append(dict(zip(MATRIX_HEADERS, cells)))
    if not rows:
        raise MatrixError("matrix contains no sample rows")
    return tuple(rows)


def _is_matrix_placeholder(cell: str) -> bool:
    return _plain_matrix_cell(cell).lower() in MATRIX_PLACEHOLDERS


def _evidence_references(cell: str) -> tuple[str, ...]:
    references = tuple(dict.fromkeys(EVIDENCE_REFERENCE_PATTERN.findall(cell)))
    for evidence_id in references:
        if EVIDENCE_ID_PATTERN.fullmatch(evidence_id) is None:
            raise MatrixError(f"invalid evidence ID {evidence_id!r}")
    return references


def _read_evidence_fields(readme_path: Path) -> dict[str, str]:
    try:
        text = readme_path.read_text(encoding="utf-8")
    except OSError as error:
        raise MatrixError(f"cannot read evidence README {readme_path}: {error}") from error
    fields: dict[str, str] = {}
    for line in text.splitlines():
        match = re.match(r"\s*-\s+([^:]+):\s*(.*?)\s*\Z", line)
        if match is None:
            continue
        fields[match.group(1).strip().lower()] = match.group(2).strip()
    return fields


def _validate_evidence_directory(evidence_id: str, evidence_root: Path) -> None:
    directory = evidence_root / evidence_id
    if not directory.is_dir():
        raise MatrixError(f"evidence directory missing for {evidence_id}: {directory}")
    for filename in ("README.md", "before.png", "after.png"):
        path = directory / filename
        if not path.is_file():
            raise MatrixError(f"evidence {evidence_id} is missing {filename}")

    fields = _read_evidence_fields(directory / "README.md")
    for key, label in REQUIRED_EVIDENCE_FIELDS.items():
        if not fields.get(key):
            raise MatrixError(f"evidence {evidence_id} README is missing {label}")
    checksum = fields["sample checksum"]
    if SHA256_PATTERN.fullmatch(checksum) is None:
        raise MatrixError(f"evidence {evidence_id} has invalid Sample checksum")
    official_content_visible = fields["official content visible"].lower()
    if official_content_visible not in {"yes", "no"}:
        raise MatrixError(
            f"evidence {evidence_id} Official content visible must be yes or no"
        )
    if official_content_visible == "yes" and not fields.get("license attribution"):
        raise MatrixError(f"evidence {evidence_id} README is missing License attribution")


def check_compatibility_matrix(
    manifest_path: str | Path = DEFAULT_MANIFEST,
    matrix_path: str | Path = DEFAULT_MATRIX,
    evidence_root: str | Path = DEFAULT_EVIDENCE_ROOT,
) -> MatrixCheckResult:
    """Validate manifest coverage, final outcomes, and linked evidence packages."""

    manifest = load_manifest(manifest_path)
    rows = _read_matrix_rows(Path(matrix_path))
    manifest_by_id = {sample.id: sample for sample in manifest.samples}
    rows_by_id: dict[str, dict[str, str]] = {}
    for row in rows:
        sample_id = _plain_matrix_cell(row["Sample"])
        if sample_id in rows_by_id:
            raise MatrixError(f"duplicate matrix sample ID: {sample_id}")
        rows_by_id[sample_id] = row

    unknown_ids = sorted(set(rows_by_id) - set(manifest_by_id))
    if unknown_ids:
        raise MatrixError(f"unknown matrix sample ID(s): {', '.join(unknown_ids)}")
    missing_ids = sorted(set(manifest_by_id) - set(rows_by_id))
    if missing_ids:
        raise MatrixError(f"missing manifest sample ID(s): {', '.join(missing_ids)}")

    referenced_evidence: set[str] = set()
    for sample_id, row in rows_by_id.items():
        recorded_sha256 = _plain_matrix_cell(row["SHA-256"])
        if recorded_sha256 != manifest_by_id[sample_id].sha256:
            raise MatrixError(f"matrix sample {sample_id} SHA-256 does not match manifest")
        outcome = _plain_matrix_cell(row["Final outcome"])
        if outcome not in ALLOWED_MATRIX_OUTCOMES:
            raise MatrixError(
                f"matrix sample {sample_id} has invalid final outcome {outcome!r}"
            )

        issue_references = _evidence_references(row["Issue"])
        evidence_references = _evidence_references(row["Evidence"])
        referenced_evidence.update(evidence_references)
        if outcome == "build-week-fixed":
            if not issue_references:
                raise MatrixError(
                    f"build-week-fixed sample {sample_id} requires an Issue link"
                )
            if _is_matrix_placeholder(row["Test"]):
                raise MatrixError(
                    f"build-week-fixed sample {sample_id} requires a Test link"
                )
            if COMMIT_REFERENCE_PATTERN.search(row["Commit"]) is None:
                raise MatrixError(
                    f"build-week-fixed sample {sample_id} requires a Commit link"
                )
            if not evidence_references:
                raise MatrixError(
                    f"build-week-fixed sample {sample_id} requires an Evidence link"
                )
            if set(issue_references) != set(evidence_references):
                raise MatrixError(
                    f"build-week-fixed sample {sample_id} must use the same evidence ID "
                    "in Issue and Evidence"
                )

    evidence_path = Path(evidence_root)
    for evidence_id in sorted(referenced_evidence):
        _validate_evidence_directory(evidence_id, evidence_path)
    return MatrixCheckResult(
        sample_count=len(rows_by_id), evidence_count=len(referenced_evidence)
    )


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


def _matrix_check(manifest_path: Path, matrix_path: Path, evidence_root: Path) -> int:
    result = check_compatibility_matrix(manifest_path, matrix_path, evidence_root)
    print(
        f"matrix OK: samples={result.sample_count} evidence={result.evidence_count}"
    )
    return 0


def _fetch_samples(sample_ids: list[str] | None, books_dir: Path, force: bool) -> int:
    manifest = load_manifest(DEFAULT_MANIFEST)
    samples_by_id = {sample.id: sample for sample in manifest.samples}
    if sample_ids:
        unique_sample_ids = tuple(dict.fromkeys(sample_ids))
        unknown_ids = sorted(set(unique_sample_ids) - samples_by_id.keys())
        if unknown_ids:
            print(
                f"fetch error: unknown sample ID(s): {', '.join(unknown_ids)}",
                file=sys.stderr,
            )
            return 1
        selected_samples = tuple(
            samples_by_id[sample_id] for sample_id in unique_sample_ids
        )
    else:
        selected_samples = manifest.samples

    results = fetch_all(selected_samples, books_dir, force=force)
    for result in results:
        detail = str(result.path) if result.ok else result.message
        output = sys.stdout if result.ok else sys.stderr
        print(f"{result.status}: {result.sample_id}: {detail}", file=output)
    return int(any(not result.ok for result in results))


def _scan_samples(
    sample_ids: list[str] | None,
    books_dir: Path,
    results_path: Path,
) -> int:
    manifest = load_manifest(DEFAULT_MANIFEST)
    samples_by_id = {sample.id: sample for sample in manifest.samples}
    if sample_ids:
        unique_sample_ids = tuple(dict.fromkeys(sample_ids))
        unknown_ids = sorted(set(unique_sample_ids) - samples_by_id.keys())
        if unknown_ids:
            print(
                f"scan error: unknown sample ID(s): {', '.join(unknown_ids)}",
                file=sys.stderr,
            )
            return 1
        selected_samples = tuple(
            samples_by_id[sample_id] for sample_id in unique_sample_ids
        )
    else:
        selected_samples = manifest.samples

    results = scan_all(selected_samples, books_dir)
    try:
        write_scan_report(results, results_path)
    except OSError as error:
        print(f"scan error: {error}", file=sys.stderr)
        return 1
    for result in results:
        if result.ok:
            detail = (
                f"{result.path} rootfile={result.rootfile} "
                f"manifest={result.manifest_count} spine={result.spine_count}"
            )
            print(f"passed: {result.sample_id}: {detail}")
        else:
            summary_errors = []
            for error in result.errors:
                detail = error
                for prefix in (f"sample {result.sample_id!r}", result.sample_id):
                    if detail.startswith(prefix):
                        detail = detail[len(prefix) :].lstrip(": ")
                        break
                summary_errors.append(detail)
            print(
                f"failed: {result.sample_id}: {'; '.join(summary_errors)}",
                file=sys.stderr,
            )
    return int(any(not result.ok for result in results))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    check_parser = subparsers.add_parser("manifest-check", help="validate the manifest")
    check_parser.add_argument("path", nargs="?", type=Path, default=DEFAULT_MANIFEST)
    matrix_parser = subparsers.add_parser(
        "matrix-check", help="validate compatibility matrix and evidence links"
    )
    matrix_parser.add_argument(
        "--manifest", type=Path, default=DEFAULT_MANIFEST, help=argparse.SUPPRESS
    )
    matrix_parser.add_argument(
        "--matrix", type=Path, default=DEFAULT_MATRIX, help=argparse.SUPPRESS
    )
    matrix_parser.add_argument(
        "--evidence-root",
        type=Path,
        default=DEFAULT_EVIDENCE_ROOT,
        help=argparse.SUPPRESS,
    )
    fetch_parser = subparsers.add_parser("fetch", help="download verified EPUB samples")
    fetch_parser.add_argument(
        "--sample",
        action="append",
        dest="sample_ids",
        metavar="ID",
        help="fetch only this sample ID (repeatable)",
    )
    fetch_parser.add_argument(
        "--force", action="store_true", help="replace valid cached files"
    )
    fetch_parser.add_argument(
        "--books-dir", type=Path, default=DEFAULT_BOOKS_DIR, help=argparse.SUPPRESS
    )
    scan_parser = subparsers.add_parser("scan", help="scan EPUB package structure")
    scan_parser.add_argument(
        "--sample",
        action="append",
        dest="sample_ids",
        metavar="ID",
        help="scan only this sample ID (repeatable)",
    )
    scan_parser.add_argument(
        "--books-dir", type=Path, default=DEFAULT_BOOKS_DIR, help=argparse.SUPPRESS
    )
    scan_parser.add_argument(
        "--results", type=Path, default=DEFAULT_SCAN_RESULTS, help=argparse.SUPPRESS
    )
    arguments = parser.parse_args(argv)

    try:
        if arguments.command == "manifest-check":
            return _manifest_check(arguments.path)
        if arguments.command == "matrix-check":
            return _matrix_check(
                arguments.manifest, arguments.matrix, arguments.evidence_root
            )
        if arguments.command == "fetch":
            return _fetch_samples(
                arguments.sample_ids, arguments.books_dir, arguments.force
            )
        if arguments.command == "scan":
            return _scan_samples(
                arguments.sample_ids, arguments.books_dir, arguments.results
            )
    except ManifestError as error:
        parser.exit(1, f"manifest error: {error}\n")
    except MatrixError as error:
        parser.exit(1, f"matrix error: {error}\n")
    raise AssertionError("unreachable")


if __name__ == "__main__":
    raise SystemExit(main())
