# Demo Media Guide

README media should show the product quickly and avoid turning the repository homepage into a maintenance note.

Recommended layout:

```text
docs/demo/
  cjk-vertical-toc.gif
  rss-reading.gif
  web-normalization.gif
docs/screenshots/
  cjk-vertical.png
  english-epub.png
  toc.png
```

Use one primary GIF above the fold: CJK vertical reading plus right-opening table of contents. Keep it short: 5-10 seconds, 300-360 px wide in README, ideally under 10 MB.

Optional secondary workflow GIFs can be used below the main EPUB sections:

- `rss-reading.gif`: RSS list -> open article -> native reader view
- `web-normalization.gif`: open web page -> extraction / normalization -> clean reader view

Keep workflow GIFs short, about 4-6 seconds each. README should not show more than 2-3 GIFs total.

If a GIF is too large, put an MP4 in `docs/demo/` or a release asset and link it through a screenshot:

```md
<p align="center">
  <a href="docs/demo/cjk-vertical-toc.mp4">
    <img src="docs/screenshots/cjk-vertical.png" width="320" alt="CJK vertical reading demo">
  </a>
</p>
```

## Recording

Record the booted iPhone simulator:

```bash
xcrun simctl io booted recordVideo demo.mov
```

Stop with `Ctrl+C`.

## Convert to GIF

```bash
ffmpeg -i demo.mov -vf "fps=12,scale=640:-1:flags=lanczos" -loop 0 docs/demo/cjk-vertical-toc.gif
```

Smaller GIF:

```bash
ffmpeg -i demo.mov -vf "fps=10,scale=480:-1:flags=lanczos" -loop 0 docs/demo/cjk-vertical-toc.gif
```

## MP4 Fallback

```bash
ffmpeg -i demo.mov -vf "scale=720:-2" -c:v libx264 -crf 28 -preset slow -pix_fmt yuv420p docs/demo/cjk-vertical-toc.mp4
```
