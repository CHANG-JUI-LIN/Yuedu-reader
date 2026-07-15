import copy
import hashlib
import io
import json
import socket
import tempfile
import threading
import unittest
import urllib.request
import zipfile
from collections import Counter
from contextlib import redirect_stderr, redirect_stdout
from dataclasses import FrozenInstanceError, replace
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import get_type_hints
from unittest import mock

import scripts.epub3_samples as epub3_samples
from scripts.epub3_samples import (
    DEFAULT_MANIFEST,
    ManifestError,
    Sample,
    SmokeTarget,
    load_manifest,
)


def _epub_bytes(label):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as archive:
        archive.writestr("mimetype", "application/epub+zip")
        archive.writestr("EPUB/content.xhtml", label)
    return output.getvalue()


CONTAINER_XML = """\
<?xml version="1.0"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
  <rootfiles>
    <rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""

VALID_OPF = """\
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:test</dc:identifier>
    <dc:title>Scanner fixture</dc:title>
    <dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="chapter"/></spine>
</package>
"""

NAV_XHTML = """\
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops">
  <body><nav epub:type="toc"><ol><li><a href="chapter.xhtml#start">Chapter</a></li></ol></nav></body>
</html>
"""

CHAPTER_XHTML = """\
<html xmlns="http://www.w3.org/1999/xhtml"><body><p id="start">Text</p></body></html>
"""


def _structural_entries(*, opf=VALID_OPF, container=CONTAINER_XML):
    entries = [
        ("mimetype", b"application/epub+zip", zipfile.ZIP_STORED),
        ("META-INF/container.xml", container.encode(), zipfile.ZIP_DEFLATED),
        ("OPS/package.opf", opf.encode(), zipfile.ZIP_DEFLATED),
        ("OPS/nav.xhtml", NAV_XHTML.encode(), zipfile.ZIP_DEFLATED),
        ("OPS/chapter.xhtml", CHAPTER_XHTML.encode(), zipfile.ZIP_DEFLATED),
    ]
    return entries


def _write_epub(path, entries):
    with zipfile.ZipFile(path, "w") as archive:
        for name, payload, compression in entries:
            archive.writestr(name, payload, compress_type=compression)


def _replace_entry(entries, name, payload, compression=zipfile.ZIP_DEFLATED):
    return [entry for entry in entries if entry[0] != name] + [
        (name, payload, compression)
    ]


class LocalHTTPServer:
    def __init__(self, routes):
        self.routes = routes
        self.requests = Counter()
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                owner.requests[self.path] += 1
                route = owner.routes[self.path]
                body = route["body"]
                self.send_response(route.get("status", 200))
                if route.get("malformed_chunked"):
                    self.send_header("Transfer-Encoding", "chunked")
                    self.end_headers()
                    declared_size = len(body) + 100
                    self.wfile.write(f"{declared_size:x}\r\n".encode("ascii"))
                    self.wfile.write(body)
                    self.wfile.flush()
                    self.close_connection = True
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()
                    return
                self.send_header(
                    "Content-Length", str(route.get("content_length", len(body)))
                )
                self.end_headers()
                self.wfile.write(body)
                self.wfile.flush()
                if route.get("interrupt"):
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()

            def log_message(self, format, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def url(self, path):
        host, port = self.server.server_address
        return f"http://{host}:{port}{path}"


def _sample(server, path, payload, *, sample_id="sample-book", filename=None):
    return Sample(
        id=sample_id,
        title="Sample Book",
        source_url=server.url(path),
        catalog_url="https://example.com/catalog",
        filename=filename or f"{sample_id}.epub",
        sha256=hashlib.sha256(payload).hexdigest(),
        license="Test fixture",
        features=("reflowable",),
        smoke_targets=(
            SmokeTarget(
                chapter_index=0,
                spine_href=None,
                text_probes=("Sample text",),
                expects_image_page=False,
                expects_fallback=False,
            ),
        ),
        manual=False,
        manual_checkpoints=(),
    )


class EPUB3SamplesManifestTests(unittest.TestCase):
    def setUp(self):
        self.manifest = {
            "schema_version": 1,
            "samples": [
                {
                    "id": "sample-book",
                    "title": "Sample Book",
                    "source_url": "https://example.com/sample-book.epub",
                    "catalog_url": "https://example.com/catalog",
                    "filename": "sample-book.epub",
                    "sha256": "a" * 64,
                    "license": "Public-domain sample; metadata supplied by the publisher.",
                    "features": ["reflowable", "xhtml"],
                    "smoke_targets": [
                        {
                            "chapter_index": 0,
                            "text_probes": ["Sample text"],
                            "expects_image_page": False,
                            "expects_fallback": False,
                        }
                    ],
                    "manual": False,
                    "manual_checkpoints": [],
                }
            ]
        }

    def _load(self, manifest):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps(manifest), encoding="utf-8")
            return load_manifest(path)

    def test_loads_complete_entry(self):
        manifest = self._load(self.manifest)

        self.assertEqual(len(manifest.samples), 1)
        self.assertEqual(manifest.schema_version, 1)
        self.assertEqual(manifest.samples[0].id, "sample-book")
        self.assertEqual(manifest.samples[0].smoke_targets[0].chapter_index, 0)

    def test_rejects_missing_schema_version(self):
        manifest = copy.deepcopy(self.manifest)
        del manifest["schema_version"]

        with self.assertRaisesRegex(ManifestError, "root.*schema_version.*required"):
            self._load(manifest)

    def test_rejects_unsupported_schema_version(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["schema_version"] = 2

        with self.assertRaisesRegex(ManifestError, "root.*schema_version.*unsupported"):
            self._load(manifest)

    def test_rejects_boolean_schema_version(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["schema_version"] = True

        with self.assertRaisesRegex(ManifestError, "root.*schema_version.*integer"):
            self._load(manifest)

    def test_rejects_duplicate_ids(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["samples"].append(copy.deepcopy(manifest["samples"][0]))
        manifest["samples"][1]["filename"] = "other.epub"

        with self.assertRaisesRegex(ManifestError, "sample-book.*id"):
            self._load(manifest)

    def test_rejects_duplicate_filenames(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["samples"].append(copy.deepcopy(manifest["samples"][0]))
        manifest["samples"][1]["id"] = "other-book"

        with self.assertRaisesRegex(ManifestError, "other-book.*filename"):
            self._load(manifest)

    def test_rejects_non_https_source_url(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["samples"][0]["source_url"] = "http://example.com/sample-book.epub"

        with self.assertRaisesRegex(ManifestError, "sample-book.*source_url"):
            self._load(manifest)

    def test_rejects_invalid_sha256(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["samples"][0]["sha256"] = "ABC123"

        with self.assertRaisesRegex(ManifestError, "sample-book.*sha256"):
            self._load(manifest)

    def test_rejects_unsafe_filenames(self):
        for filename in (
            "/tmp/outside.epub",
            "../outside.epub",
            "nested/book.epub",
            "nested\\book.epub",
            ".",
            "..",
        ):
            with self.subTest(filename=filename):
                manifest = copy.deepcopy(self.manifest)
                manifest["samples"][0]["filename"] = filename

                with self.assertRaisesRegex(
                    ManifestError, "sample-book.*filename"
                ):
                    self._load(manifest)

    def test_rejects_missing_license_notes(self):
        manifest = copy.deepcopy(self.manifest)
        del manifest["samples"][0]["license"]

        with self.assertRaisesRegex(ManifestError, "sample-book.*license"):
            self._load(manifest)

    def test_rejects_empty_feature_list(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["samples"][0]["features"] = []

        with self.assertRaisesRegex(ManifestError, "sample-book.*features"):
            self._load(manifest)

    def test_rejects_manual_entry_without_checkpoints(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["samples"][0]["manual"] = True

        with self.assertRaisesRegex(ManifestError, "sample-book.*manual_checkpoints"):
            self._load(manifest)

    def test_rejects_smoke_target_with_both_selectors(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["samples"][0]["smoke_targets"][0]["spine_href"] = "chapter.xhtml"

        with self.assertRaisesRegex(ManifestError, r"sample-book.*smoke_targets\[0\]"):
            self._load(manifest)

    def test_rejects_smoke_target_without_selector(self):
        manifest = copy.deepcopy(self.manifest)
        del manifest["samples"][0]["smoke_targets"][0]["chapter_index"]

        with self.assertRaisesRegex(ManifestError, r"sample-book.*smoke_targets\[0\]"):
            self._load(manifest)

    def test_rejects_negative_chapter_index(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["samples"][0]["smoke_targets"][0]["chapter_index"] = -1

        with self.assertRaisesRegex(ManifestError, "sample-book.*chapter_index"):
            self._load(manifest)

    def test_rejects_boolean_chapter_index(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["samples"][0]["smoke_targets"][0]["chapter_index"] = True

        with self.assertRaisesRegex(ManifestError, "sample-book.*chapter_index"):
            self._load(manifest)

    def test_rejects_whitespace_only_top_level_string(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["samples"][0]["title"] = "   "

        with self.assertRaisesRegex(ManifestError, "sample-book.*title"):
            self._load(manifest)

    def test_rejects_whitespace_only_feature(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["samples"][0]["features"] = ["  "]

        with self.assertRaisesRegex(ManifestError, "sample-book.*features"):
            self._load(manifest)

    def test_rejects_whitespace_only_text_probe(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["samples"][0]["smoke_targets"][0]["text_probes"] = ["\t"]

        with self.assertRaisesRegex(ManifestError, "sample-book.*text_probes"):
            self._load(manifest)

    def test_rejects_whitespace_only_manual_checkpoint(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["samples"][0]["manual"] = True
        manifest["samples"][0]["manual_checkpoints"] = ["\n"]

        with self.assertRaisesRegex(ManifestError, "sample-book.*manual_checkpoints"):
            self._load(manifest)

    def test_committed_manifest_contract(self):
        manifest = load_manifest(DEFAULT_MANIFEST)
        manual_samples = {sample.id: sample.title for sample in manifest.samples if sample.manual}

        self.assertEqual(manifest.schema_version, 1)
        self.assertEqual(len(manifest.samples), 42)
        self.assertEqual(
            manual_samples,
            {
                "accessible-epub3": "Accessible EPUB 3",
                "childrens-literature": "Children's Literature",
                "israelsailing": "Israel Sailing",
                "kusamakura": "Kusamakura",
                "linear-algebra": "Linear Algebra",
                "moby-dick": "Moby Dick",
                "page-blanche": "Page Blanche",
                "wasteland-otf": "The Waste Land with OTF fonts",
            },
        )

        samples = {sample.id: sample for sample in manifest.samples}
        self.assertEqual(
            samples["cc-shared-culture"].license,
            "CC BY-NC-SA 3.0 Unported (official catalog sample-specific license).",
        )

        linear_target = samples["linear-algebra"].smoke_targets[0]
        self.assertEqual(linear_target.spine_href, "xhtml/fcla-xml-2.30li17.xhtml")
        self.assertNotEqual(linear_target.spine_href, "xhtml/titlepage.xhtml")
        self.assertTrue(linear_target.text_probes)
        self.assertTrue(all(probe.strip() for probe in linear_target.text_probes))

        moby_checkpoints = " ".join(samples["moby-dick"].manual_checkpoints)
        self.assertIn("English justified body rhythm", moby_checkpoints)
        self.assertIn("long-word hyphenation", moby_checkpoints)

        wasteland_checkpoints = " ".join(samples["wasteland-otf"].manual_checkpoints)
        for expected_coverage in (
            "single-spine English layout",
            "body rhythm",
            "missing-glyph or tofu boxes",
            "embedded font unavailable",
            "readable sans-serif/static fallback",
            "semantic sections",
            "remain distinguishable",
            "embedded-font behavior",
            "baseline-supported",
        ):
            with self.subTest(wasteland_coverage=expected_coverage):
                self.assertIn(expected_coverage, wasteland_checkpoints)


class EPUB3SampleDownloadTests(unittest.TestCase):
    def assert_no_part_files(self, books_dir):
        self.assertEqual(list(books_dir.glob("*.part")), [])

    def test_successful_download_is_verified_and_atomically_moved(self):
        payload = _epub_bytes("successful download")
        with LocalHTTPServer({"/book.epub": {"body": payload}}) as server:
            sample = _sample(server, "/book.epub", payload)
            with tempfile.TemporaryDirectory() as directory:
                books_dir = Path(directory) / "books"
                timeouts = []

                def recording_opener(url, *, timeout):
                    timeouts.append(timeout)
                    return urllib.request.urlopen(url, timeout=timeout)

                result = epub3_samples.fetch_sample(
                    sample, books_dir, opener=recording_opener
                )

                destination = books_dir / sample.filename
                self.assertTrue(result.ok)
                self.assertEqual(result.status, "downloaded")
                self.assertEqual(result.path, destination.resolve(strict=True))
                self.assertEqual(destination.read_bytes(), payload)
                self.assertEqual(epub3_samples.sha256_file(destination), sample.sha256)
                self.assert_no_part_files(books_dir)
                self.assertEqual(timeouts, [60])

    def test_books_directory_symlink_switch_keeps_download_in_resolved_directory(self):
        payload = _epub_bytes("fixed resolved directory")
        with LocalHTTPServer({"/book.epub": {"body": payload}}) as server:
            sample = _sample(server, "/book.epub", payload)
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                directory_a = root / "A"
                directory_b = root / "B"
                directory_a.mkdir()
                directory_b.mkdir()
                books_link = root / "books"
                books_link.symlink_to(directory_a, target_is_directory=True)

                def switching_opener(url, *, timeout):
                    response = urllib.request.urlopen(url, timeout=timeout)
                    books_link.unlink()
                    books_link.symlink_to(directory_b, target_is_directory=True)
                    return response

                result = epub3_samples.fetch_sample(
                    sample, books_link, opener=switching_opener
                )

                destination_a = directory_a / sample.filename
                destination_b = directory_b / sample.filename
                part_files_a = list(directory_a.glob("*.part"))
                part_files_b = list(directory_b.glob("*.part"))
                self.assertTrue(
                    result.ok,
                    f"{result.message}; A parts={part_files_a}; B parts={part_files_b}",
                )
                self.assertEqual(result.status, "downloaded")
                self.assertEqual(
                    result.path, directory_a.resolve(strict=True) / sample.filename
                )
                self.assertEqual(destination_a.read_bytes(), payload)
                self.assertFalse(destination_b.exists())
                self.assertTrue(epub3_samples.has_zip_signature(destination_a))
                self.assertEqual(
                    epub3_samples.sha256_file(destination_a), sample.sha256
                )
                self.assertEqual(part_files_a, [])
                self.assertEqual(part_files_b, [])
                self.assertEqual(server.requests["/book.epub"], 1)

    def test_unsafe_direct_sample_cannot_escape_books_directory(self):
        sentinel_payload = _epub_bytes("outside sentinel")
        with LocalHTTPServer({"/book.epub": {"body": sentinel_payload}}) as server:
            sample = _sample(
                server,
                "/book.epub",
                sentinel_payload,
                filename="../outside.epub",
            )
            with tempfile.TemporaryDirectory(dir="/tmp") as directory:
                root = Path(directory)
                books_dir = root / "books"
                books_dir.mkdir()
                sentinel = root / "outside.epub"
                sentinel.write_bytes(sentinel_payload)
                original_inode = sentinel.stat().st_ino

                result = epub3_samples.fetch_sample(sample, books_dir)

                self.assertFalse(result.ok)
                self.assertEqual(result.status, "failed")
                self.assertIn("sample-book", result.message)
                self.assertIn("filename", result.message)
                self.assertEqual(sentinel.read_bytes(), sentinel_payload)
                self.assertEqual(sentinel.stat().st_ino, original_inode)
                self.assert_no_part_files(books_dir)
                self.assertEqual(server.requests["/book.epub"], 0)

    def test_symlink_destination_cannot_escape_books_directory(self):
        sentinel_payload = _epub_bytes("symlink sentinel")
        with LocalHTTPServer({"/book.epub": {"body": sentinel_payload}}) as server:
            sample = _sample(server, "/book.epub", sentinel_payload)
            with tempfile.TemporaryDirectory(dir="/tmp") as directory:
                root = Path(directory)
                books_dir = root / "books"
                books_dir.mkdir()
                sentinel = root / "outside.epub"
                sentinel.write_bytes(sentinel_payload)
                original_inode = sentinel.stat().st_ino
                destination = books_dir / sample.filename
                destination.symlink_to(sentinel)

                result = epub3_samples.fetch_sample(sample, books_dir)

                self.assertFalse(result.ok)
                self.assertEqual(result.status, "failed")
                self.assertIn("sample-book", result.message)
                self.assertIn("filename", result.message)
                self.assertTrue(destination.is_symlink())
                self.assertEqual(sentinel.read_bytes(), sentinel_payload)
                self.assertEqual(sentinel.stat().st_ino, original_inode)
                self.assert_no_part_files(books_dir)
                self.assertEqual(server.requests["/book.epub"], 0)

    def test_valid_cache_is_reused_without_request(self):
        payload = _epub_bytes("cached download")
        with LocalHTTPServer({"/book.epub": {"body": payload}}) as server:
            sample = _sample(server, "/book.epub", payload)
            with tempfile.TemporaryDirectory() as directory:
                books_dir = Path(directory) / "books"
                books_dir.mkdir()
                destination = books_dir / sample.filename
                destination.write_bytes(payload)

                result = epub3_samples.fetch_sample(sample, books_dir)

                self.assertTrue(result.ok)
                self.assertEqual(result.status, "cached")
                self.assertEqual(server.requests["/book.epub"], 0)
                self.assertEqual(destination.read_bytes(), payload)

    def test_checksum_mismatch_preserves_existing_book_and_cleans_part(self):
        expected_payload = _epub_bytes("expected")
        wrong_payload = _epub_bytes("wrong")
        existing_payload = _epub_bytes("existing")
        with LocalHTTPServer({"/book.epub": {"body": wrong_payload}}) as server:
            sample = _sample(server, "/book.epub", expected_payload)
            with tempfile.TemporaryDirectory() as directory:
                books_dir = Path(directory) / "books"
                books_dir.mkdir()
                destination = books_dir / sample.filename
                destination.write_bytes(existing_payload)

                result = epub3_samples.fetch_sample(sample, books_dir)

                self.assertFalse(result.ok)
                self.assertEqual(result.status, "failed")
                self.assertIn("checksum", result.message.lower())
                self.assertEqual(destination.read_bytes(), existing_payload)
                self.assert_no_part_files(books_dir)

    def test_non_zip_response_is_rejected_even_when_checksum_matches(self):
        payload = b"not a zip file"
        with LocalHTTPServer({"/book.epub": {"body": payload}}) as server:
            sample = _sample(server, "/book.epub", payload)
            with tempfile.TemporaryDirectory() as directory:
                books_dir = Path(directory) / "books"

                result = epub3_samples.fetch_sample(sample, books_dir)

                self.assertFalse(result.ok)
                self.assertEqual(result.status, "failed")
                self.assertIn("ZIP", result.message)
                self.assertFalse((books_dir / sample.filename).exists())
                self.assert_no_part_files(books_dir)

    def test_interrupted_download_cleans_part(self):
        payload = _epub_bytes("interrupted")[:20]
        route = {
            "body": payload,
            "malformed_chunked": True,
        }
        with LocalHTTPServer({"/book.epub": route}) as server:
            sample = _sample(server, "/book.epub", _epub_bytes("complete"))
            with tempfile.TemporaryDirectory() as directory:
                books_dir = Path(directory) / "books"
                books_dir.mkdir()
                destination = books_dir / sample.filename
                existing_payload = _epub_bytes("existing")
                destination.write_bytes(existing_payload)

                result = epub3_samples.fetch_sample(sample, books_dir)

                self.assertFalse(result.ok)
                self.assertEqual(result.status, "failed")
                self.assertIn("IncompleteRead", result.message)
                self.assertNotIn("checksum", result.message.lower())
                self.assertEqual(destination.read_bytes(), existing_payload)
                self.assert_no_part_files(books_dir)
                self.assertEqual(server.requests["/book.epub"], 1)

    def test_fetch_all_continues_after_failure_and_aggregates_failure(self):
        invalid_payload = b"not a zip"
        valid_payload = _epub_bytes("valid second sample")
        routes = {
            "/invalid.epub": {"body": invalid_payload},
            "/valid.epub": {"body": valid_payload},
        }
        with LocalHTTPServer(routes) as server:
            samples = (
                _sample(
                    server,
                    "/invalid.epub",
                    invalid_payload,
                    sample_id="invalid",
                ),
                _sample(
                    server,
                    "/valid.epub",
                    valid_payload,
                    sample_id="valid",
                ),
            )
            with tempfile.TemporaryDirectory() as directory:
                results = epub3_samples.fetch_all(samples, Path(directory) / "books")

                self.assertEqual(
                    [result.status for result in results], ["failed", "downloaded"]
                )
                self.assertFalse(all(result.ok for result in results))
                self.assertEqual(server.requests["/invalid.epub"], 1)
                self.assertEqual(server.requests["/valid.epub"], 1)

    def test_force_redownloads_and_replaces_valid_cache(self):
        payload = _epub_bytes("force download")
        with LocalHTTPServer({"/book.epub": {"body": payload}}) as server:
            sample = _sample(server, "/book.epub", payload)
            with tempfile.TemporaryDirectory() as directory:
                books_dir = Path(directory) / "books"
                books_dir.mkdir()
                destination = books_dir / sample.filename
                destination.write_bytes(payload)
                original_inode = destination.stat().st_ino

                result = epub3_samples.fetch_sample(sample, books_dir, force=True)

                self.assertTrue(result.ok)
                self.assertEqual(result.status, "downloaded")
                self.assertEqual(server.requests["/book.epub"], 1)
                self.assertNotEqual(destination.stat().st_ino, original_inode)
                self.assertEqual(destination.read_bytes(), payload)
                self.assert_no_part_files(books_dir)

    def test_replace_failure_preserves_existing_book_and_cleans_part(self):
        payload = _epub_bytes("valid replacement")
        existing_payload = _epub_bytes("existing book")
        with LocalHTTPServer({"/book.epub": {"body": payload}}) as server:
            sample = _sample(server, "/book.epub", payload)
            with tempfile.TemporaryDirectory() as directory:
                books_dir = Path(directory) / "books"
                books_dir.mkdir()
                destination = books_dir / sample.filename
                destination.write_bytes(existing_payload)

                with mock.patch.object(
                    epub3_samples.os,
                    "replace",
                    side_effect=OSError("injected replace failure"),
                ) as replace:
                    result = epub3_samples.fetch_sample(sample, books_dir)

                self.assertFalse(result.ok)
                self.assertEqual(result.status, "failed")
                self.assertIn("injected replace failure", result.message)
                replace.assert_called_once()
                self.assertEqual(destination.read_bytes(), existing_payload)
                self.assert_no_part_files(books_dir)
                self.assertEqual(server.requests["/book.epub"], 1)


class EPUB3PackageScannerTests(unittest.TestCase):
    def _scan(self, entries=None, *, sample_id="fixture"):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.epub"
            _write_epub(
                path,
                entries if entries is not None else _structural_entries(),
            )
            return epub3_samples.scan_epub(path, sample_id=sample_id)

    def test_empty_zip_is_not_replaced_by_default_fixture(self):
        result = self._scan([])

        self.assertFalse(result.ok)
        self.assertTrue(any("mimetype missing" in error for error in result.errors))

    def test_valid_package_reports_structural_facts(self):
        result = self._scan()

        self.assertTrue(result.ok, result.errors)
        self.assertEqual(result.status, "passed")
        self.assertEqual(result.sample_id, "fixture")
        self.assertEqual(result.rootfile, "OPS/package.opf")
        self.assertEqual(result.version, "3.0")
        self.assertEqual(result.manifest_count, 2)
        self.assertEqual(result.spine_count, 1)
        self.assertEqual(result.nav, "OPS/nav.xhtml")
        self.assertEqual(result.detected_features, ())
        self.assertEqual(result.errors, ())

    def test_mimetype_must_be_first_stored_and_exact(self):
        valid = _structural_entries()
        cases = {
            "first": [valid[1], valid[0], *valid[2:]],
            "stored": [
                ("mimetype", b"application/epub+zip", zipfile.ZIP_DEFLATED),
                *valid[1:],
            ],
            "content": [
                ("mimetype", b"application/epub+zip\n", zipfile.ZIP_STORED),
                *valid[1:],
            ],
            "missing": valid[1:],
        }

        for expected, entries in cases.items():
            with self.subTest(expected=expected):
                result = self._scan(entries)
                self.assertFalse(result.ok)
                self.assertTrue(
                    any("mimetype" in error and expected in error for error in result.errors),
                    result.errors,
                )

    def test_container_rootfile_and_opf_failures_are_sample_scoped(self):
        invalid_container = "<container>"
        missing_rootfile = (
            '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
            "<rootfiles/></container>"
        )
        rootfile_without_path = (
            '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
            "<rootfiles><rootfile/></rootfiles></container>"
        )
        cases = {
            "container.xml missing": [
                entry for entry in _structural_entries() if entry[0] != "META-INF/container.xml"
            ],
            "container.xml XML": _structural_entries(container=invalid_container),
            "rootfile missing": _structural_entries(container=missing_rootfile),
            "rootfile full-path": _structural_entries(container=rootfile_without_path),
            "rootfile resource": _structural_entries(
                container=CONTAINER_XML.replace("OPS/package.opf", "OPS/missing.opf")
            ),
            "OPF XML": _structural_entries(opf="<package>"),
        }

        for expected, entries in cases.items():
            with self.subTest(expected=expected):
                result = self._scan(entries, sample_id="broken-book")
                self.assertFalse(result.ok)
                self.assertTrue(any(expected in error for error in result.errors), result.errors)
                self.assertTrue(all("broken-book" in error for error in result.errors))

    def test_container_requires_direct_container_rootfiles_hierarchy(self):
        rootfile = (
            '<rootfile full-path="OPS/package.opf" '
            'media-type="application/oebps-package+xml"/>'
        )
        cases = {
            "container root element": f"<wrong><rootfiles>{rootfile}</rootfiles></wrong>",
            "direct rootfiles": (
                '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
                f"<wrapper><rootfiles>{rootfile}</rootfiles></wrapper></container>"
            ),
            "direct rootfile": (
                '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
                f"<rootfiles><wrapper>{rootfile}</wrapper></rootfiles></container>"
            ),
        }

        for expected, container in cases.items():
            with self.subTest(expected=expected):
                result = self._scan(_structural_entries(container=container))
                self.assertFalse(result.ok)
                self.assertTrue(any(expected in error for error in result.errors), result.errors)

    def test_container_and_package_require_exact_vocabulary_namespaces(self):
        cases = {
            "OCF namespace": _structural_entries(
                container=CONTAINER_XML.replace(
                    "urn:oasis:names:tc:opendocument:xmlns:container",
                    "urn:wrong:container",
                )
            ),
            "OPF package namespace": _structural_entries(
                opf=VALID_OPF.replace(
                    "http://www.idpf.org/2007/opf", "urn:wrong:opf"
                )
            ),
            "OPF direct child namespace": _structural_entries(
                opf=VALID_OPF.replace(
                    "<manifest>", '<foreign:manifest xmlns:foreign="urn:wrong:opf">'
                ).replace("</manifest>", "</foreign:manifest>")
            ),
        }

        for expected, entries in cases.items():
            with self.subTest(expected=expected):
                result = self._scan(entries)
                self.assertFalse(result.ok)
                self.assertTrue(any(expected in error for error in result.errors), result.errors)

    def test_container_foreign_rootfiles_and_rootfile_are_never_valid(self):
        foreign_rootfiles = CONTAINER_XML.replace(
            "<rootfiles>", '<f:rootfiles xmlns:f="urn:foreign">'
        ).replace("</rootfiles>", "</f:rootfiles>")
        foreign_rootfile = CONTAINER_XML.replace(
            "<rootfile ", '<f:rootfile xmlns:f="urn:foreign" '
        )
        for container in (foreign_rootfiles, foreign_rootfile):
            with self.subTest(container=container):
                result = self._scan(_structural_entries(container=container))

                self.assertFalse(result.ok)
                self.assertTrue(
                    any("namespace" in error for error in result.errors),
                    result.errors,
                )

    def test_rootfile_requires_nonblank_path_and_supported_media_type(self):
        cases = {
            "rootfile full-path": (
                '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
                '<rootfiles><rootfile full-path="   " '
                'media-type="application/oebps-package+xml"/></rootfiles></container>'
            ),
            "rootfile media-type": (
                '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
                '<rootfiles><rootfile full-path="OPS/package.opf"/>'
                "</rootfiles></container>"
            ),
            "unsupported rootfile media-type": (
                '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
                '<rootfiles><rootfile full-path="OPS/package.opf" '
                'media-type="application/xml"/></rootfiles></container>'
            ),
        }

        for expected, container in cases.items():
            with self.subTest(expected=expected):
                result = self._scan(_structural_entries(container=container))
                self.assertFalse(result.ok)
                self.assertTrue(any(expected in error for error in result.errors), result.errors)

    def test_selects_first_supported_rootfile_from_direct_candidates(self):
        container = """\
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="legacy.opf" media-type="application/x-legacy-package"/>
    <rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""

        result = self._scan(_structural_entries(container=container))

        self.assertTrue(result.ok, result.errors)
        self.assertEqual(result.rootfile, "OPS/package.opf")

    def test_corrupt_and_missing_epubs_return_failed_results(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            missing = epub3_samples.scan_epub(root / "missing.epub", sample_id="missing")
            corrupt_path = root / "corrupt.epub"
            corrupt_path.write_bytes(b"not a zip")
            corrupt = epub3_samples.scan_epub(corrupt_path, sample_id="corrupt")

        self.assertFalse(missing.ok)
        self.assertIn("missing", " ".join(missing.errors))
        self.assertFalse(corrupt.ok)
        self.assertIn("corrupt", " ".join(corrupt.errors))

    def test_manifest_spine_and_nav_references_must_exist(self):
        missing_manifest_resource = [
            entry for entry in _structural_entries() if entry[0] != "OPS/chapter.xhtml"
        ]
        missing_spine_id = _structural_entries(
            opf=VALID_OPF.replace('idref="chapter"', 'idref="unknown"')
        )
        missing_spine_resource = _structural_entries(
            opf=VALID_OPF.replace('href="chapter.xhtml"', 'href="missing.xhtml"', 1)
        )
        missing_nav_resource = [
            entry for entry in _structural_entries() if entry[0] != "OPS/nav.xhtml"
        ]
        cases = {
            "manifest resource": missing_manifest_resource,
            "spine idref": missing_spine_id,
            "spine resource": missing_spine_resource,
            "nav resource": missing_nav_resource,
        }

        for expected, entries in cases.items():
            with self.subTest(expected=expected):
                result = self._scan(entries)
                self.assertFalse(result.ok)
                self.assertTrue(any(expected in error for error in result.errors), result.errors)

    def test_duplicate_manifest_ids_fail(self):
        duplicate = VALID_OPF.replace(
            '<item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>',
            '<item id="nav" href="chapter.xhtml" media-type="application/xhtml+xml"/>',
        )

        result = self._scan(_structural_entries(opf=duplicate))

        self.assertFalse(result.ok)
        self.assertTrue(any("duplicate manifest ID" in error for error in result.errors))

    def test_package_requires_nonblank_unique_identifier_and_matching_identifier(self):
        cases = {
            "unique-identifier missing": VALID_OPF.replace(' unique-identifier="uid"', ""),
            "unique-identifier blank": VALID_OPF.replace('unique-identifier="uid"', 'unique-identifier="   "'),
            "unique-identifier target": VALID_OPF.replace('unique-identifier="uid"', 'unique-identifier="missing"'),
            "unique-identifier target blank": VALID_OPF.replace(
                '<dc:identifier id="uid">urn:test</dc:identifier>',
                '<dc:identifier id="uid">   </dc:identifier>\n'
                '    <dc:identifier>urn:fallback</dc:identifier>',
            ),
        }

        for expected, opf in cases.items():
            with self.subTest(expected=expected):
                result = self._scan(_structural_entries(opf=opf))
                self.assertFalse(result.ok)
                self.assertTrue(any(expected in error for error in result.errors), result.errors)

    def test_package_version_must_be_exactly_epub_3_0(self):
        for version in ("banana", "3.1", "2.0"):
            with self.subTest(version=version):
                opf = VALID_OPF.replace('version="3.0"', f'version="{version}"')
                result = self._scan(_structural_entries(opf=opf))
                self.assertFalse(result.ok)
                self.assertTrue(
                    any("unsupported package version" in error for error in result.errors),
                    result.errors,
                )

    def test_spine_requires_at_least_one_direct_itemref(self):
        opf = VALID_OPF.replace(
            '<spine><itemref idref="chapter"/></spine>', "<spine/>"
        )

        result = self._scan(_structural_entries(opf=opf))

        self.assertFalse(result.ok)
        self.assertTrue(
            any("spine must contain at least one direct itemref" in error for error in result.errors),
            result.errors,
        )

    def test_package_requires_direct_metadata_manifest_and_spine(self):
        metadata_start = '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
        cases = {
            "direct metadata": VALID_OPF.replace(
                metadata_start, f"<wrapper>{metadata_start}"
            ).replace("</metadata>", "</metadata></wrapper>", 1),
            "direct manifest": VALID_OPF.replace(
                "<manifest>", "<wrapper><manifest>", 1
            ).replace("</manifest>", "</manifest></wrapper>", 1),
            "direct spine": VALID_OPF.replace(
                "<spine>", "<wrapper><spine>", 1
            ).replace("</spine>", "</spine></wrapper>", 1),
        }

        for expected, opf in cases.items():
            with self.subTest(expected=expected):
                result = self._scan(_structural_entries(opf=opf))
                self.assertFalse(result.ok)
                self.assertTrue(any(expected in error for error in result.errors), result.errors)

    def test_metadata_requires_identifier_title_and_language(self):
        cases = {
            "dc:identifier": VALID_OPF.replace(
                '    <dc:identifier id="uid">urn:test</dc:identifier>\n', ""
            ),
            "dc:title": VALID_OPF.replace(
                "    <dc:title>Scanner fixture</dc:title>\n", ""
            ),
            "dc:language": VALID_OPF.replace("    <dc:language>en</dc:language>\n", ""),
        }

        for expected, opf in cases.items():
            with self.subTest(expected=expected):
                result = self._scan(_structural_entries(opf=opf))
                self.assertFalse(result.ok)
                self.assertTrue(any(expected in error for error in result.errors), result.errors)

    def test_manifest_items_require_nonblank_id_href_and_media_type(self):
        cases = {
            "manifest item ID": VALID_OPF.replace('id="chapter"', 'id="   "', 1),
            "manifest item href": VALID_OPF.replace('href="chapter.xhtml"', 'href="   "', 1),
            "manifest item media-type": VALID_OPF.replace(
                'media-type="application/xhtml+xml"/>\n  </manifest>',
                'media-type="   "/>\n  </manifest>',
            ),
        }

        for expected, opf in cases.items():
            with self.subTest(expected=expected):
                result = self._scan(_structural_entries(opf=opf))
                self.assertFalse(result.ok)
                self.assertTrue(any(expected in error for error in result.errors), result.errors)

    def test_nav_item_requires_xhtml_media_type(self):
        opf = VALID_OPF.replace(
            'id="nav" href="nav.xhtml" media-type="application/xhtml+xml"',
            'id="nav" href="nav.xhtml" media-type="application/xml"',
        )

        result = self._scan(_structural_entries(opf=opf))

        self.assertFalse(result.ok)
        self.assertTrue(any("nav media-type" in error for error in result.errors), result.errors)

    def test_manifest_requires_exactly_one_nav_item(self):
        opf = VALID_OPF.replace(
            "</manifest>",
            '<item id="nav-two" href="nav-two.xhtml" media-type="application/xhtml+xml" '
            'properties="nav"/>\n  </manifest>',
        )
        entries = [
            *_structural_entries(opf=opf),
            ("OPS/nav-two.xhtml", NAV_XHTML.encode(), zipfile.ZIP_DEFLATED),
        ]

        result = self._scan(entries)

        self.assertFalse(result.ok)
        self.assertTrue(
            any("exactly one nav manifest item" in error for error in result.errors),
            result.errors,
        )

    def test_nav_target_requires_html_root_and_epub_toc_nav(self):
        cases = {
            "nav XHTML html root": b"<svg xmlns='http://www.w3.org/2000/svg'/>",
            "nav epub:type toc": b"<html xmlns='http://www.w3.org/1999/xhtml'><body/></html>",
            "nav epub:type namespace": NAV_XHTML.replace(
                'epub:type="toc"', 'type="toc"'
            ).encode(),
        }

        for expected, nav_payload in cases.items():
            with self.subTest(expected=expected):
                entries = _replace_entry(
                    _structural_entries(), "OPS/nav.xhtml", nav_payload
                )
                result = self._scan(entries)
                self.assertFalse(result.ok)
                self.assertTrue(any(expected in error for error in result.errors), result.errors)

    def test_nav_toc_element_must_be_in_xhtml_namespace(self):
        nav = NAV_XHTML.replace(
            '<nav epub:type="toc">',
            '<foreign:nav xmlns:foreign="urn:wrong:xhtml" epub:type="toc">',
        ).replace("</nav>", "</foreign:nav>")

        result = self._scan(
            _replace_entry(_structural_entries(), "OPS/nav.xhtml", nav.encode())
        )

        self.assertFalse(result.ok)
        self.assertTrue(any("XHTML toc nav" in error for error in result.errors), result.errors)

    def test_nav_target_requires_exactly_one_toc_nav(self):
        duplicate_toc = NAV_XHTML.replace(
            "</body>",
            '<nav epub:type="toc"><ol><li><a href="chapter.xhtml">Again</a></li></ol></nav></body>',
        )

        result = self._scan(
            _replace_entry(
                _structural_entries(), "OPS/nav.xhtml", duplicate_toc.encode()
            )
        )

        self.assertFalse(result.ok)
        self.assertTrue(
            any("exactly one nav epub:type toc" in error for error in result.errors),
            result.errors,
        )

    def test_nav_toc_epub_type_accepts_additional_tokens(self):
        nav = NAV_XHTML.replace('epub:type="toc"', 'epub:type="landmarks toc"')

        result = self._scan(
            _replace_entry(_structural_entries(), "OPS/nav.xhtml", nav.encode())
        )

        self.assertTrue(result.ok, result.errors)

    def test_media_overlay_reference_requires_existing_smil_item(self):
        dangling = VALID_OPF.replace(
            'id="chapter" href="chapter.xhtml"',
            'id="chapter" href="chapter.xhtml" media-overlay="missing"',
        )
        wrong_type = VALID_OPF.replace(
            'id="chapter" href="chapter.xhtml"',
            'id="chapter" href="chapter.xhtml" media-overlay="overlay"',
        ).replace(
            "</manifest>",
            '<item id="overlay" href="overlay.xhtml" media-type="application/xhtml+xml"/>\n  </manifest>',
        )
        cases = {
            "media-overlay IDREF blank": _structural_entries(
                opf=VALID_OPF.replace(
                    'id="chapter" href="chapter.xhtml"',
                    'id="chapter" href="chapter.xhtml" media-overlay="   "',
                )
            ),
            "media-overlay IDREF": _structural_entries(opf=dangling),
            "media-overlay SMIL": [
                *_structural_entries(opf=wrong_type),
                ("OPS/overlay.xhtml", CHAPTER_XHTML.encode(), zipfile.ZIP_DEFLATED),
            ],
        }

        for expected, entries in cases.items():
            with self.subTest(expected=expected):
                result = self._scan(entries)
                self.assertFalse(result.ok)
                self.assertTrue(any(expected in error for error in result.errors), result.errors)

    def test_media_overlay_requires_content_source_and_valid_local_smil_document(self):
        valid_opf = VALID_OPF.replace(
            'id="chapter" href="chapter.xhtml"',
            'id="chapter" href="chapter.xhtml" media-overlay="overlay"',
        ).replace(
            "</manifest>",
            '<item id="overlay" href="overlay.smil" media-type="application/smil+xml"/>\n  </manifest>',
        )
        valid_smil = b"<smil xmlns='http://www.w3.org/ns/SMIL' version='3.0'><body/></smil>"
        cases = {
            "media-overlay source Content Document": (
                valid_opf.replace(
                    'id="chapter" href="chapter.xhtml" media-overlay="overlay" media-type="application/xhtml+xml"',
                    'id="chapter" href="chapter.xhtml" media-overlay="overlay" media-type="text/plain"',
                ),
                valid_smil,
            ),
            "media-overlay target local": (
                valid_opf.replace('href="overlay.smil"', 'href="https://example.com/overlay.smil"'),
                None,
            ),
            "SMIL namespace": (
                valid_opf,
                b"<smil xmlns='urn:wrong:smil' version='3.0'><body/></smil>",
            ),
            "SMIL root": (
                valid_opf,
                b"<seq xmlns='http://www.w3.org/ns/SMIL' version='3.0'><body/></seq>",
            ),
            "SMIL version": (
                valid_opf,
                b"<smil xmlns='http://www.w3.org/ns/SMIL' version='2.0'><body/></smil>",
            ),
            "SMIL direct body": (
                valid_opf,
                b"<smil xmlns='http://www.w3.org/ns/SMIL' version='3.0'><head/></smil>",
            ),
        }
        for expected, (opf, smil) in cases.items():
            with self.subTest(expected=expected):
                entries = _structural_entries(opf=opf)
                if smil is not None:
                    entries.append(
                        ("OPS/overlay.smil", smil, zipfile.ZIP_DEFLATED)
                    )
                result = self._scan(entries)
                self.assertFalse(result.ok)
                self.assertNotIn("media-overlay", result.detected_features)
                self.assertTrue(any(expected in error for error in result.errors), result.errors)

    def test_zip_entry_names_reject_unsafe_or_ambiguous_paths(self):
        cases = {
            "absolute": "/absolute.xhtml",
            "parent traversal": "OPS/../escape.xhtml",
            "backslash": "OPS\\ambiguous.xhtml",
            "ambiguous": "OPS//ambiguous.xhtml",
        }
        for expected, unsafe_name in cases.items():
            with self.subTest(expected=expected):
                entries = [
                    *_structural_entries(),
                    (unsafe_name, b"unsafe", zipfile.ZIP_STORED),
                ]
                result = self._scan(entries)
                self.assertFalse(result.ok)
                self.assertTrue(any(expected in error for error in result.errors), result.errors)

    def test_archive_budget_constants_have_required_headroom(self):
        expected = {
            "MAX_ARCHIVE_ENTRIES": 10_000,
            "MAX_TOTAL_UNCOMPRESSED": 512 * 1024 * 1024,
            "MAX_ENTRY_UNCOMPRESSED": 128 * 1024 * 1024,
            "MAX_COMPRESSION_RATIO": 200,
            "MAX_PARSED_RESOURCE_BYTES": 32 * 1024 * 1024,
        }
        for name, value in expected.items():
            with self.subTest(name=name):
                self.assertEqual(getattr(epub3_samples, name, None), value)

    def test_archive_entry_count_total_single_and_ratio_limits(self):
        ratio_entries = [
            *_structural_entries(),
            ("OPS/compressed.bin", b"A" * 10_000, zipfile.ZIP_DEFLATED),
        ]
        cases = (
            ("entry count", _structural_entries(), "MAX_ARCHIVE_ENTRIES", 4),
            ("total uncompressed", _structural_entries(), "MAX_TOTAL_UNCOMPRESSED", 100),
            ("entry uncompressed", _structural_entries(), "MAX_ENTRY_UNCOMPRESSED", 10),
            ("compression ratio", ratio_entries, "MAX_COMPRESSION_RATIO", 2),
        )
        for expected, entries, constant, limit in cases:
            with self.subTest(expected=expected):
                with mock.patch.object(
                    epub3_samples, constant, limit, create=True
                ):
                    result = self._scan(entries, sample_id="budget-book")
                self.assertFalse(result.ok)
                self.assertTrue(any(expected in error for error in result.errors), result.errors)
                self.assertTrue(all("budget-book" in error for error in result.errors))

    def test_parsed_resource_streaming_cap_fails_scan(self):
        with mock.patch.object(
            epub3_samples, "MAX_PARSED_RESOURCE_BYTES", 40, create=True
        ):
            result = self._scan(sample_id="capped-book")

        self.assertFalse(result.ok)
        self.assertTrue(any("parsed resource byte limit" in error for error in result.errors), result.errors)

    def test_normalized_zip_entry_name_collisions_fail(self):
        entries = [
            *_structural_entries(),
            ("OPS/a/../chapter.xhtml", b"collision", zipfile.ZIP_STORED),
        ]

        result = self._scan(entries)

        self.assertFalse(result.ok)
        self.assertTrue(
            any("normalized-name collision" in error for error in result.errors),
            result.errors,
        )

    def test_internal_hrefs_are_url_decoded_and_external_uris_are_not_zip_resources(self):
        opf = VALID_OPF.replace(
            'href="chapter.xhtml" media-type="application/xhtml+xml"',
            'href="chapter%2Exhtml?edition=test#start" media-type="application/xhtml+xml"',
        ).replace(
            "</manifest>",
            '<item id="remote" href="https://example.com/remote.xhtml" '
            'media-type="application/xhtml+xml"/>\n  </manifest>',
        )

        result = self._scan(_structural_entries(opf=opf))

        self.assertTrue(result.ok, result.errors)

    def test_internal_href_cannot_escape_opf_directory(self):
        opf = VALID_OPF.replace('href="chapter.xhtml"', 'href="../../escape.xhtml"', 1)

        result = self._scan(_structural_entries(opf=opf))

        self.assertFalse(result.ok)
        self.assertTrue(any("manifest href" in error and "escape" in error for error in result.errors))

    def test_detects_features_from_package_and_resource_content(self):
        feature_opf = """\
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:features</dc:identifier>
    <dc:title>Feature fixture</dc:title>
    <dc:language>en</dc:language>
    <meta property="rendition:layout">pre-paginated</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml" media-overlay="audio"/>
    <item id="audio" href="overlay.smil" media-type="application/smil+xml"/>
    <item id="figure" href="figure.svg" media-type="image/svg+xml"/>
    <item id="handler" href="handler.xhtml" media-type="application/xhtml+xml" properties="scripted"/>
  </manifest>
  <spine page-progression-direction="rtl"><itemref idref="chapter"/></spine>
  <bindings><mediaType media-type="application/x-demo" handler="handler"/></bindings>
</package>
"""
        feature_chapter = """\
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:m="http://www.w3.org/1998/Math/MathML"
      dir="rtl"><body style="writing-mode: vertical-rl">
  <ruby>漢<rt>かん</rt></ruby><m:math><m:mi>x</m:mi></m:math>
  <svg xmlns="http://www.w3.org/2000/svg"><circle r="2"/></svg>
</body></html>
"""
        entries = _structural_entries(opf=feature_opf)
        entries = [entry for entry in entries if entry[0] != "OPS/chapter.xhtml"]
        entries.extend(
            (
                ("OPS/chapter.xhtml", feature_chapter.encode(), zipfile.ZIP_DEFLATED),
                (
                    "OPS/overlay.smil",
                    b"<smil xmlns='http://www.w3.org/ns/SMIL' version='3.0'><body/></smil>",
                    zipfile.ZIP_DEFLATED,
                ),
                ("OPS/figure.svg", b"<svg xmlns='http://www.w3.org/2000/svg'/>", zipfile.ZIP_DEFLATED),
                ("OPS/handler.xhtml", CHAPTER_XHTML.encode(), zipfile.ZIP_DEFLATED),
            )
        )

        result = self._scan(entries)

        self.assertTrue(result.ok, result.errors)
        self.assertEqual(
            set(result.detected_features),
            {
                "bindings",
                "fixed-layout",
                "mathml",
                "media-overlay",
                "page-progression",
                "rtl",
                "ruby",
                "svg",
                "vertical-writing",
            },
        )

    def test_foreign_vocabulary_elements_do_not_trigger_features(self):
        chapter = b"""\
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:f="urn:foreign">
  <body><f:math/><f:ruby/><f:svg/><f:box dir="rtl" style="writing-mode:vertical-rl"/></body>
</html>
"""
        result = self._scan(
            _replace_entry(_structural_entries(), "OPS/chapter.xhtml", chapter)
        )

        self.assertTrue(result.ok, result.errors)
        for feature in ("mathml", "ruby", "svg", "rtl", "vertical-writing"):
            self.assertNotIn(feature, result.detected_features)

    def test_only_unqualified_xhtml_dir_and_style_attributes_trigger_features(self):
        foreign_attributes = b"""\
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:f="urn:foreign">
  <body f:dir="rtl" f:style="writing-mode:vertical-rl"/>
</html>
"""
        unqualified_attributes = b"""\
<html xmlns="http://www.w3.org/1999/xhtml">
  <body dir="rtl" style="writing-mode:vertical-rl"/>
</html>
"""

        foreign_result = self._scan(
            _replace_entry(
                _structural_entries(), "OPS/chapter.xhtml", foreign_attributes
            )
        )
        unqualified_result = self._scan(
            _replace_entry(
                _structural_entries(), "OPS/chapter.xhtml", unqualified_attributes
            )
        )

        self.assertTrue(foreign_result.ok, foreign_result.errors)
        self.assertNotIn("rtl", foreign_result.detected_features)
        self.assertNotIn("vertical-writing", foreign_result.detected_features)
        self.assertTrue(unqualified_result.ok, unqualified_result.errors)
        self.assertIn("rtl", unqualified_result.detected_features)
        self.assertIn("vertical-writing", unqualified_result.detected_features)

    def test_valid_binding_is_detected(self):
        opf = VALID_OPF.replace(
            "</manifest>",
            '<item id="handler" href="handler.xhtml" media-type="application/xhtml+xml" '
            'properties="scripted"/>\n'
            '<item id="widget" href="widget.xml" media-type="application/x-demo"/>\n  </manifest>',
        ).replace(
            "</package>",
            '<bindings><mediaType media-type="application/x-demo" handler="handler"/></bindings>\n'
            "</package>",
        )
        entries = [
            *_structural_entries(opf=opf),
            ("OPS/handler.xhtml", CHAPTER_XHTML.encode(), zipfile.ZIP_DEFLATED),
            ("OPS/widget.xml", b"<widget/>", zipfile.ZIP_DEFLATED),
        ]

        result = self._scan(entries)

        self.assertTrue(result.ok, result.errors)
        self.assertIn("bindings", result.detected_features)
        self.assertEqual(result.warnings, ())

    def test_bindings_require_valid_media_type_and_scripted_xhtml_handler(self):
        valid_opf = VALID_OPF.replace(
            "</manifest>",
            '<item id="handler" href="handler.xhtml" media-type="application/xhtml+xml" '
            'properties="scripted"/>\n  </manifest>',
        ).replace(
            "</package>",
            '<bindings><mediaType media-type="application/x-demo" handler="handler"/></bindings>\n'
            "</package>",
        )
        cases = {
            "bindings must contain": valid_opf.replace(
                '<bindings><mediaType media-type="application/x-demo" handler="handler"/></bindings>',
                "<bindings/>",
            ),
            "binding media-type missing": valid_opf.replace(
                ' media-type="application/x-demo"', ""
            ),
            "binding media-type blank": valid_opf.replace(
                'media-type="application/x-demo"', 'media-type="   "'
            ),
            "binding handler missing": valid_opf.replace(' handler="handler"', ""),
            "binding handler blank": valid_opf.replace(
                'handler="handler"', 'handler="   "'
            ),
            "binding handler ID": valid_opf.replace(
                'handler="handler"', 'handler="missing"'
            ),
            "binding handler XHTML": valid_opf.replace(
                'id="handler" href="handler.xhtml" media-type="application/xhtml+xml"',
                'id="handler" href="handler.xhtml" media-type="application/xml"',
            ),
            "binding handler scripted": valid_opf.replace(
                ' properties="scripted"/>\n  </manifest>', "/>\n  </manifest>"
            ),
        }

        for expected, opf in cases.items():
            with self.subTest(expected=expected):
                entries = [
                    *_structural_entries(opf=opf),
                    (
                        "OPS/handler.xhtml",
                        CHAPTER_XHTML.encode(),
                        zipfile.ZIP_DEFLATED,
                    ),
                ]
                result = self._scan(entries)
                self.assertFalse(result.ok)
                self.assertTrue(any(expected in error for error in result.errors), result.errors)

    def test_binding_handler_requires_local_xhtml_document_with_direct_body(self):
        valid_opf = VALID_OPF.replace(
            "</manifest>",
            '<item id="handler" href="handler.xhtml" media-type="application/xhtml+xml" '
            'properties="scripted"/>\n  </manifest>',
        ).replace(
            "</package>",
            '<bindings><mediaType media-type="application/x-demo" handler="handler"/></bindings>\n'
            "</package>",
        )
        cases = {
            "binding handler local": (
                valid_opf.replace(
                    'href="handler.xhtml"', 'href="https://example.com/handler.xhtml"'
                ),
                None,
            ),
            "binding handler XHTML root": (valid_opf, b"<garbage/>"),
            "binding handler direct body": (
                valid_opf,
                b'<html xmlns="http://www.w3.org/1999/xhtml"><head/></html>',
            ),
        }
        for expected, (opf, handler_payload) in cases.items():
            with self.subTest(expected=expected):
                entries = _structural_entries(opf=opf)
                if handler_payload is not None:
                    entries.append(
                        (
                            "OPS/handler.xhtml",
                            handler_payload,
                            zipfile.ZIP_DEFLATED,
                        )
                    )
                result = self._scan(entries)
                self.assertFalse(result.ok)
                self.assertNotIn("bindings", result.detected_features)
                self.assertTrue(any(expected in error for error in result.errors), result.errors)

    def test_css_comments_do_not_trigger_writing_features(self):
        opf = VALID_OPF.replace(
            "</manifest>",
            '<item id="css" href="styles.css" media-type="text/css"/>\n  </manifest>',
        )
        entries = [
            *_structural_entries(opf=opf),
            (
                "OPS/styles.css",
                b"/* writing-mode: vertical-rl; direction: rtl; */",
                zipfile.ZIP_DEFLATED,
            ),
        ]

        result = self._scan(entries)

        self.assertTrue(result.ok, result.errors)
        self.assertNotIn("vertical-writing", result.detected_features)
        self.assertNotIn("rtl", result.detected_features)

    def test_css_property_names_and_quoted_values_do_not_trigger_features(self):
        opf = VALID_OPF.replace(
            "</manifest>",
            '<item id="css" href="styles.css" media-type="text/css"/>\n  </manifest>',
        )
        false_positive_styles = (
            "body { --reading-direction: rtl; --preferred-writing-mode: vertical-rl; }",
            'body::before { content: "direction:rtl; writing-mode:vertical-rl"; }',
            "body::before { content: 'direction:rtl; writing-mode:vertical-rl'; }",
        )
        for stylesheet in false_positive_styles:
            with self.subTest(stylesheet=stylesheet):
                entries = [
                    *_structural_entries(opf=opf),
                    (
                        "OPS/styles.css",
                        stylesheet.encode(),
                        zipfile.ZIP_DEFLATED,
                    ),
                ]
                result = self._scan(entries)
                self.assertTrue(result.ok, result.errors)
                self.assertNotIn("vertical-writing", result.detected_features)
                self.assertNotIn("rtl", result.detected_features)

    def test_css_function_arguments_do_not_trigger_writing_features(self):
        opf = VALID_OPF.replace(
            "</manifest>",
            '<item id="css" href="styles.css" media-type="text/css"/>\n  </manifest>',
        )
        stylesheets = (
            "body { background:url(data:text/plain,direction:rtl;writing-mode:vertical-rl); }",
            'body { background:url("data:text/plain,direction:rtl;writing-mode:vertical-rl"); }',
            "body { value:outer(inner(direction:rtl;writing-mode:vertical-rl)); }",
        )
        for stylesheet in stylesheets:
            with self.subTest(stylesheet=stylesheet):
                entries = [
                    *_structural_entries(opf=opf),
                    ("OPS/styles.css", stylesheet.encode(), zipfile.ZIP_DEFLATED),
                ]
                result = self._scan(entries)
                self.assertTrue(result.ok, result.errors)
                self.assertNotIn("vertical-writing", result.detected_features)
                self.assertNotIn("rtl", result.detected_features)

    def test_css_lexer_preserves_real_declarations_after_string_comment_marker(self):
        opf = VALID_OPF.replace(
            "</manifest>",
            '<item id="css" href="styles.css" media-type="text/css"/>\n  </manifest>',
        )
        entries = [
            *_structural_entries(opf=opf),
            (
                "OPS/styles.css",
                b'body { content:"/*"; direction:rtl; writing-mode:vertical-rl; }',
                zipfile.ZIP_DEFLATED,
            ),
        ]

        result = self._scan(entries)

        self.assertTrue(result.ok, result.errors)
        self.assertIn("rtl", result.detected_features)
        self.assertIn("vertical-writing", result.detected_features)

    def test_css_lexer_keeps_escaped_function_closers_and_strings_masked(self):
        opf = VALID_OPF.replace(
            "</manifest>",
            '<item id="css" href="styles.css" media-type="text/css"/>\n  </manifest>',
        )
        stylesheets = (
            r"body { background:url(foo\);direction:rtl); }",
            r"body { background:url(foo\);writing-mode:vertical-rl); }",
            r'body { content:"escaped \" direction:rtl; writing-mode:vertical-rl"; }',
            r"body { content:'escaped \' direction:rtl; writing-mode:vertical-rl'; }",
            "body { /* direction:rtl; */ value:outer(inner(writing-mode:vertical-rl)); }",
        )
        for stylesheet in stylesheets:
            with self.subTest(stylesheet=stylesheet):
                entries = [
                    *_structural_entries(opf=opf),
                    ("OPS/styles.css", stylesheet.encode(), zipfile.ZIP_DEFLATED),
                ]

                result = self._scan(entries)

                self.assertTrue(result.ok, result.errors)
                self.assertNotIn("rtl", result.detected_features)
                self.assertNotIn("vertical-writing", result.detected_features)

    def test_css_exact_writing_property_names_are_detected(self):
        opf = VALID_OPF.replace(
            "</manifest>",
            '<item id="css" href="styles.css" media-type="text/css"/>\n  </manifest>',
        )
        entries = [
            *_structural_entries(opf=opf),
            (
                "OPS/styles.css",
                b"body { direction:rtl; writing-mode:vertical-rl; }",
                zipfile.ZIP_DEFLATED,
            ),
        ]

        result = self._scan(entries)

        self.assertTrue(result.ok, result.errors)
        self.assertIn("vertical-writing", result.detected_features)
        self.assertIn("rtl", result.detected_features)

    def test_xhtml_prose_does_not_trigger_writing_features(self):
        chapter = b"""\
<html xmlns="http://www.w3.org/1999/xhtml"><body>
  <p>The examples writing-mode: vertical-rl and direction: rtl are prose.</p>
</body></html>
"""
        entries = _replace_entry(
            _structural_entries(), "OPS/chapter.xhtml", chapter
        )

        result = self._scan(entries)

        self.assertTrue(result.ok, result.errors)
        self.assertNotIn("vertical-writing", result.detected_features)
        self.assertNotIn("rtl", result.detected_features)

    def test_detects_writing_features_only_in_css_contexts(self):
        opf_with_css = VALID_OPF.replace(
            "</manifest>",
            '<item id="css" href="styles.css" media-type="text/css"/>\n  </manifest>',
        )
        cases = {
            "style attribute": (
                _structural_entries(),
                b'<html xmlns="http://www.w3.org/1999/xhtml"><body '
                b'style="writing-mode: vertical-rl; direction: rtl"/></html>',
                None,
            ),
            "style element": (
                _structural_entries(),
                b'<html xmlns="http://www.w3.org/1999/xhtml"><head><style>'
                b'body { writing-mode: vertical-rl; direction: rtl; }'
                b'</style></head><body/></html>',
                None,
            ),
            "manifest CSS": (
                _structural_entries(opf=opf_with_css),
                CHAPTER_XHTML.encode(),
                b'body { writing-mode: vertical-rl; direction: rtl; }',
            ),
        }

        for context, (base_entries, chapter, stylesheet) in cases.items():
            with self.subTest(context=context):
                entries = _replace_entry(
                    base_entries, "OPS/chapter.xhtml", chapter
                )
                if stylesheet is not None:
                    entries.append(
                        ("OPS/styles.css", stylesheet, zipfile.ZIP_DEFLATED)
                    )
                result = self._scan(entries)
                self.assertTrue(result.ok, result.errors)
                self.assertIn("vertical-writing", result.detected_features)
                self.assertIn("rtl", result.detected_features)

    def test_invalid_page_progression_direction_fails_without_detection(self):
        opf = VALID_OPF.replace(
            "<spine>", '<spine page-progression-direction="garbage">'
        )

        result = self._scan(_structural_entries(opf=opf))

        self.assertFalse(result.ok)
        self.assertTrue(
            any("page-progression-direction" in error for error in result.errors),
            result.errors,
        )
        self.assertNotIn("page-progression", result.detected_features)

    def test_valid_page_progression_directions_are_detected(self):
        for direction in ("ltr", "rtl"):
            with self.subTest(direction=direction):
                opf = VALID_OPF.replace(
                    "<spine>",
                    f'<spine page-progression-direction="{direction}">',
                )
                result = self._scan(_structural_entries(opf=opf))
                self.assertTrue(result.ok, result.errors)
                self.assertIn("page-progression", result.detected_features)
                self.assertEqual("rtl" in result.detected_features, direction == "rtl")

    def test_itemref_fixed_layout_property_is_detected(self):
        opf = VALID_OPF.replace(
            '<itemref idref="chapter"/>',
            '<itemref idref="chapter" properties="rendition:layout-pre-paginated"/>',
        )

        result = self._scan(_structural_entries(opf=opf))

        self.assertTrue(result.ok, result.errors)
        self.assertIn("fixed-layout", result.detected_features)

    def test_invalid_package_direction_and_rendition_layout_fail(self):
        invalid_direction = VALID_OPF.replace(
            'unique-identifier="uid">',
            'unique-identifier="uid" dir="garbage">',
        )
        invalid_layout = VALID_OPF.replace(
            "  </metadata>",
            '    <meta property="rendition:layout">garbage</meta>\n  </metadata>',
        )
        cases = {
            "package dir": invalid_direction,
            "rendition:layout": invalid_layout,
        }

        for expected, opf in cases.items():
            with self.subTest(expected=expected):
                result = self._scan(_structural_entries(opf=opf))
                self.assertFalse(result.ok)
                self.assertTrue(any(expected in error for error in result.errors), result.errors)

    def test_manifest_feature_claims_without_content_are_not_detected(self):
        claimed_opf = VALID_OPF.replace(
            'id="chapter" href="chapter.xhtml"',
            'id="chapter" href="chapter.xhtml" properties="mathml svg scripted"',
        )

        result = self._scan(_structural_entries(opf=claimed_opf))

        self.assertTrue(result.ok, result.errors)
        self.assertNotIn("mathml", result.detected_features)
        self.assertNotIn("svg", result.detected_features)
        self.assertNotIn("scripted", result.detected_features)

    def test_known_uninspected_media_types_do_not_warn(self):
        resources = (
            ("lexicon.pls", "application/pls+xml"),
            ("captions.vtt", "text/vtt"),
            ("captions.xml", "application/ttml+xml"),
            ("page.xpgt", "application/adobe-page-template+xml"),
            ("font.woff", "application/font-woff"),
        )
        declarations = "\n".join(
            f'<item id="known-{index}" href="{href}" media-type="{media_type}"/>'
            for index, (href, media_type) in enumerate(resources)
        )
        opf = VALID_OPF.replace("</manifest>", f"{declarations}\n  </manifest>")
        entries = _structural_entries(opf=opf)
        entries.extend(
            (f"OPS/{href}", b"fixture", zipfile.ZIP_STORED)
            for href, _ in resources
        )

        result = self._scan(entries)

        self.assertTrue(result.ok, result.errors)
        self.assertEqual(result.warnings, ())


class EPUB3PackageAggregateTests(unittest.TestCase):
    def test_scan_all_continues_after_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            books_dir = Path(directory)
            first = Sample(
                id="broken",
                title="Broken",
                source_url="https://example.com/broken.epub",
                catalog_url="https://example.com",
                filename="broken.epub",
                sha256="a" * 64,
                license="fixture",
                features=("fixture",),
                smoke_targets=(),
                manual=False,
                manual_checkpoints=(),
            )
            second = replace(first, id="valid", title="Valid", filename="valid.epub")
            (books_dir / first.filename).write_bytes(b"corrupt")
            _write_epub(books_dir / second.filename, _structural_entries())

            results = epub3_samples.scan_all((first, second), books_dir)

        self.assertEqual([result.sample_id for result in results], ["broken", "valid"])
        self.assertEqual([result.status for result in results], ["failed", "passed"])

    def test_stable_report_sorts_samples_and_serializes_each_once(self):
        results = (
            epub3_samples.ScanResult(
                sample_id="z-book",
                path=Path("z.epub"),
                status="passed",
                rootfile="OPS/package.opf",
                version="3.0",
                manifest_count=2,
                spine_count=1,
                nav="OPS/nav.xhtml",
                detected_features=("ruby", "mathml"),
                warnings=(),
                errors=(),
            ),
            epub3_samples.ScanResult(
                sample_id="a-book",
                path=Path("a.epub"),
                status="failed",
                rootfile=None,
                version=None,
                manifest_count=0,
                spine_count=0,
                nav=None,
                detected_features=(),
                warnings=(),
                errors=("a-book: corrupt ZIP",),
            ),
        )
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "scan-results.json"
            epub3_samples.write_scan_report(results, report)
            first_bytes = report.read_bytes()
            epub3_samples.write_scan_report(reversed(results), report)
            second_bytes = report.read_bytes()
            payload = json.loads(second_bytes)

        self.assertEqual(first_bytes, second_bytes)
        self.assertEqual([entry["sample_id"] for entry in payload["results"]], ["a-book", "z-book"])
        self.assertEqual(len(payload["results"]), 2)
        self.assertEqual(payload["results"][1]["detected_features"], ["mathml", "ruby"])

    def test_report_rejects_duplicate_sample_ids_in_any_order(self):
        passed = epub3_samples.ScanResult(
            sample_id="duplicate",
            path=Path("passed.epub"),
            status="passed",
            rootfile="OPS/package.opf",
            version="3.0",
            manifest_count=1,
            spine_count=1,
            nav="OPS/nav.xhtml",
            detected_features=(),
            warnings=(),
            errors=(),
        )
        failed = replace(
            passed,
            path=Path("failed.epub"),
            status="failed",
            errors=("duplicate: failure",),
        )
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "scan-results.json"
            for ordered in ((passed, failed), (failed, passed)):
                with self.subTest(first=ordered[0].status):
                    with self.assertRaisesRegex(ValueError, "duplicate sample ID"):
                        epub3_samples.write_scan_report(ordered, report)

    def test_atomic_report_replace_failure_preserves_old_report_and_cleans_temp(self):
        result = epub3_samples.ScanResult(
            sample_id="sample",
            path=Path("sample.epub"),
            status="passed",
            rootfile="OPS/package.opf",
            version="3.0",
            manifest_count=1,
            spine_count=1,
            nav="OPS/nav.xhtml",
            detected_features=(),
            warnings=(),
            errors=(),
        )
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "scan-results.json"
            report.write_bytes(b"old report")
            with mock.patch.object(
                epub3_samples.os,
                "replace",
                side_effect=OSError("injected report replace failure"),
            ):
                with self.assertRaisesRegex(OSError, "injected report replace failure"):
                    epub3_samples.write_scan_report((result,), report)
            self.assertEqual(report.read_bytes(), b"old report")
            self.assertEqual(list(report.parent.glob("*.tmp")), [])


class ScanResultTests(unittest.TestCase):
    def test_ok_is_derived_from_status_and_result_is_frozen(self):
        result = epub3_samples.ScanResult(
            sample_id="sample",
            path=Path("sample.epub"),
            status="passed",
            rootfile="OPS/package.opf",
            version="3.0",
            manifest_count=1,
            spine_count=1,
            nav=None,
            detected_features=(),
            warnings=(),
            errors=(),
        )

        self.assertTrue(result.ok)
        with self.assertRaises((AttributeError, FrozenInstanceError)):
            result.status = "failed"


class FetchResultTests(unittest.TestCase):
    def test_ok_is_derived_from_status_and_read_only(self):
        path = Path("sample.epub")
        for status, expected_ok in (
            ("downloaded", True),
            ("cached", True),
            ("failed", False),
        ):
            with self.subTest(status=status):
                result = epub3_samples.FetchResult(
                    sample_id="sample-book",
                    status=status,
                    message="result",
                    path=path,
                )

                self.assertEqual(result.ok, expected_ok)
                with self.assertRaises((AttributeError, FrozenInstanceError)):
                    result.ok = not expected_ok

    def test_path_is_nonoptional(self):
        self.assertIs(get_type_hints(epub3_samples.FetchResult)["path"], Path)


class EPUB3SamplesCLITests(unittest.TestCase):
    def _run_main(self, arguments):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            exit_code = epub3_samples.main(arguments)
        return exit_code, stdout.getvalue(), stderr.getvalue()

    def test_duplicate_sample_with_force_is_fetched_once(self):
        captured = []

        def capture_fetch(samples, books_dir, *, force):
            captured.append((tuple(sample.id for sample in samples), force))
            return (
                epub3_samples.FetchResult(
                    sample_id="linear-algebra",
                    status="downloaded",
                    message="downloaded and verified",
                    path=Path(books_dir) / "linear-algebra.epub",
                ),
            )

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            epub3_samples, "fetch_all", side_effect=capture_fetch
        ):
            exit_code, stdout, stderr = self._run_main(
                [
                    "fetch",
                    "--sample",
                    "linear-algebra",
                    "--sample",
                    "linear-algebra",
                    "--force",
                    "--books-dir",
                    directory,
                ]
            )

        self.assertEqual(exit_code, 0)
        self.assertEqual(captured, [(("linear-algebra",), True)])
        self.assertIn("downloaded: linear-algebra:", stdout)
        self.assertEqual(stderr, "")

    def test_repeatable_samples_preserve_first_order(self):
        captured_ids = []

        def capture_fetch(samples, books_dir, *, force):
            captured_ids.extend(sample.id for sample in samples)
            return tuple(
                epub3_samples.FetchResult(
                    sample_id=sample.id,
                    status="cached",
                    message="verified cache",
                    path=Path(books_dir) / sample.filename,
                )
                for sample in samples
            )

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            epub3_samples, "fetch_all", side_effect=capture_fetch
        ):
            exit_code, stdout, stderr = self._run_main(
                [
                    "fetch",
                    "--sample",
                    "moby-dick",
                    "--sample",
                    "linear-algebra",
                    "--sample",
                    "moby-dick",
                    "--books-dir",
                    directory,
                ]
            )

        self.assertEqual(exit_code, 0)
        self.assertEqual(captured_ids, ["moby-dick", "linear-algebra"])
        self.assertIn("cached: moby-dick:", stdout)
        self.assertIn("cached: linear-algebra:", stdout)
        self.assertEqual(stderr, "")

    def test_unknown_sample_reports_failure_only_on_stderr(self):
        exit_code, stdout, stderr = self._run_main(
            ["fetch", "--sample", "unknown-sample"]
        )

        self.assertEqual(exit_code, 1)
        self.assertEqual(stdout, "")
        self.assertIn("unknown sample ID(s): unknown-sample", stderr)

    def test_failed_fetch_reports_failure_only_on_stderr(self):
        failed_result = epub3_samples.FetchResult(
            sample_id="linear-algebra",
            status="failed",
            message="injected download failure",
            path=Path("linear-algebra.epub"),
        )
        with mock.patch.object(
            epub3_samples, "fetch_all", return_value=(failed_result,)
        ):
            exit_code, stdout, stderr = self._run_main(
                ["fetch", "--sample", "linear-algebra"]
            )

        self.assertEqual(exit_code, 1)
        self.assertEqual(stdout, "")
        self.assertIn("failed: linear-algebra: injected download failure", stderr)

    def test_scan_deduplicates_selection_writes_report_and_routes_summaries(self):
        template = Sample(
            id="broken",
            title="Broken",
            source_url="https://example.com/broken.epub",
            catalog_url="https://example.com",
            filename="broken.epub",
            sha256="a" * 64,
            license="fixture",
            features=("fixture",),
            smoke_targets=(),
            manual=False,
            manual_checkpoints=(),
        )
        valid_sample = replace(template, id="valid", title="Valid", filename="valid.epub")
        manifest = epub3_samples.Manifest(schema_version=1, samples=(template, valid_sample))
        captured = []

        def capture_scan(samples, books_dir):
            captured.append(tuple(sample.id for sample in samples))
            return (
                epub3_samples.ScanResult(
                    sample_id="broken",
                    path=Path(books_dir) / "broken.epub",
                    status="failed",
                    rootfile=None,
                    version=None,
                    manifest_count=0,
                    spine_count=0,
                    nav=None,
                    detected_features=(),
                    warnings=(),
                    errors=("broken: corrupt ZIP",),
                ),
                epub3_samples.ScanResult(
                    sample_id="valid",
                    path=Path(books_dir) / "valid.epub",
                    status="passed",
                    rootfile="OPS/package.opf",
                    version="3.0",
                    manifest_count=2,
                    spine_count=1,
                    nav="OPS/nav.xhtml",
                    detected_features=(),
                    warnings=(),
                    errors=(),
                ),
            )

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            epub3_samples, "load_manifest", return_value=manifest
        ), mock.patch.object(epub3_samples, "scan_all", side_effect=capture_scan):
            report = Path(directory) / "results" / "scan-results.json"
            exit_code, stdout, stderr = self._run_main(
                [
                    "scan",
                    "--sample",
                    "broken",
                    "--sample",
                    "valid",
                    "--sample",
                    "broken",
                    "--books-dir",
                    directory,
                    "--results",
                    str(report),
                ]
            )
            payload = json.loads(report.read_text(encoding="utf-8"))

        self.assertEqual(exit_code, 1)
        self.assertEqual(captured, [("broken", "valid")])
        self.assertEqual([entry["sample_id"] for entry in payload["results"]], ["broken", "valid"])
        self.assertIn("passed: valid:", stdout)
        self.assertNotIn("broken", stdout)
        self.assertIn("failed: broken: corrupt ZIP", stderr)

    def test_scan_unknown_sample_fails_without_scanning(self):
        with mock.patch.object(epub3_samples, "scan_all") as scan_all:
            exit_code, stdout, stderr = self._run_main(
                ["scan", "--sample", "unknown-sample"]
            )

        self.assertEqual(exit_code, 1)
        self.assertEqual(stdout, "")
        self.assertIn("unknown sample ID(s): unknown-sample", stderr)
        scan_all.assert_not_called()

    def test_scan_report_oserror_is_one_line_stderr_failure(self):
        result = epub3_samples.ScanResult(
            sample_id="linear-algebra",
            path=Path("linear-algebra.epub"),
            status="passed",
            rootfile="EPUB/package.opf",
            version="3.0",
            manifest_count=1,
            spine_count=1,
            nav="EPUB/nav.xhtml",
            detected_features=(),
            warnings=(),
            errors=(),
        )
        with mock.patch.object(
            epub3_samples, "scan_all", return_value=(result,)
        ), mock.patch.object(
            epub3_samples,
            "write_scan_report",
            side_effect=OSError("report filesystem failure"),
        ):
            try:
                exit_code, stdout, stderr = self._run_main(
                    ["scan", "--sample", "linear-algebra"]
                )
            except OSError as error:
                self.fail(f"CLI leaked OSError traceback path: {error}")

        self.assertEqual(exit_code, 1)
        self.assertEqual(stdout, "")
        self.assertEqual(stderr.count("\n"), 1)
        self.assertIn("scan error: report filesystem failure", stderr)


if __name__ == "__main__":
    unittest.main()
