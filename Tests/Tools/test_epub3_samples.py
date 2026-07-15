import copy
import json
import tempfile
import unittest
from pathlib import Path

from scripts.epub3_samples import DEFAULT_MANIFEST, ManifestError, load_manifest


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


if __name__ == "__main__":
    unittest.main()
