# EPUB 3 official-sample harness

This harness reproducibly selects and downloads the official EPUB 3 samples
described by `sample-manifest.json`.

Validate the committed manifest:

```bash
python3 scripts/epub3_samples.py manifest-check
```

Fetch every sample whose binary is not already valid in the local cache:

```bash
python3 scripts/epub3_samples.py fetch
```

Force a verified replacement of one exact sample:

```bash
python3 scripts/epub3_samples.py fetch --sample linear-algebra --force
```

Downloaded EPUB binaries live under `.build-week/epub3-samples/books/`.
Generated checksum evidence and reports belong under
`.build-week/epub3-samples/checksums/` and
`.build-week/epub3-samples/reports/` in later harness stages. The repository's
top-level `.gitignore` excludes the entire `.build-week/` tree. Do not commit
official EPUB binaries or generated artifacts.

License and attribution details are sample-specific; use the committed
manifest as the source of truth.

Passing this harness does not claim complete EPUB 3 support. Scanner and
baseline/report commands are planned for later stages and are not available in
this downloader stage.
