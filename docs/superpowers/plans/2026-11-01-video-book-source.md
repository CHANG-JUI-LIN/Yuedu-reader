# Video book sources — legado `bookSourceType` 4 (2026-11-01)

Maintainer, 2026-11-01: 「我想加入legado的視頻功能」. Settled in the same conversation:

| Question | Decision |
|---|---|
| Last episode of a 線路 (volume) ends | **Continue into the next 線路's first episode** (MD3 / original fork), not stop (E / Sigma). Stop only after the last episode of the last 線路. |
| Player layout | **「照開源的emby player」**, then 「plezy 這個也算吧」 → Swiftfin (`jellyfin/Swiftfin`, MPL-2.0; Jellyfin is the open-source Emby fork) and plezy (`edde746/plezy`, GPL-3.0, Plex client). Design references only: no code copied. They agree on the layout (top bar, centre controls, bottom timeline, swipe up for an episode strip); where they differ V2 says which one it follows. |
| Extras in the first release | **All four:** 彈幕, next-episode link preload, multi-resolution content formats, long-press speed |
| Name | 「自己按語言翻譯」 → reuse the existing key `影片` (zh-Hant 影片, zh-Hans 视频, en Video, ja ビデオ, ko 동영상) |
| Detail page | 「視頻的詳情頁就是按照emby播放器，別共用一個詳情頁」「就是什麼海報牆之類的」 → a page of its own (`VideoDetailView`, beside `AudiobookDetailView`), media-centre style. **Videos only:** Editorial Minimalism's 「不做海報牆」 still holds for books. |

## Upstream (all four forks checked 2026-11-01)

`bookSourceType` **4 = video in every fork** (E, Sigma, MD3, huajideshutiao), so source JSON is portable.
The `Book.type` bit differs: E/Sigma/MD3 `0b100` (4), the original fork `1 shl 11` (2048).

| | E (`Luoyacheng/legado-E`) / Sigma (`Rimchars/legado`) | MD3 (`HapeLee/legado-with-MD3`) | original (`huajideshutiao/legado`) |
|---|---|---|---|
| Chapter content | one URL; text starting `<` = DASH MPD written to a temp file | one URL | JSON `{resolutions:[{name,url,width,height,bitrate,headers,mime}],defaultIndex,headers}`, or `名稱::網址` lines, or URL, or in-memory m3u8 (`#BASE:` line = Referer) |
| 線路 | `isVolume` chapters are 線路/季; episodes = chapters under the current volume | same | volume rows are "TVBox 線路分組頭", skipped when picking what to play |
| End of a 線路 | stop (「已播放完」) | next volume's first episode | linear `nextPlayable` (crosses volumes) |
| Progress | `durVolumeIndex`, `chapterInVolumeIndex`, `durChapterIndex`, `durChapterPos` (ms) | same | `durChapterIndex`, `durChapterPos` (ms) |
| 彈幕 | chapter variable `danmaku` (Bilibili XML) or big-data file; `chapter.putDanmaku(…)`; `BiliDanmukuParser` | `danmaku` on the media item, show toggle | none |
| Preload | Sigma: next episode's link, in-memory, 30 min TTL | `VideoBookPreloader` | `resourceUrl` written by a preloader |
| Speed | menu + long-press (default 3.0×, `longPressSpeed`=30) | menu 0.5–3.0 + long-press | menu |
| Other | floating window, auto-play, start full screen, RSS video, `java.openVideoPlayer(url,title,isFloat)` with per-URL position (`video_pos_<url>`, 20 days) | PiP, floating window | PiP (also on iOS), brightness/volume/zoom gestures, skip intro, lock |

Files: E `model/VideoPlay.kt`, `ui/video/VideoPlayerActivity.kt`, `help/gsyVideo/*`, `help/book/BookChapterExtensions.kt`;
Sigma same paths; MD3 `model/VideoPlay.kt`, `ui/book/video/*`, `docs/superpowers/specs/2026-10-24-video-book-source-design.md`;
original `ui/src/commonMain/.../ui/book/video/VideoPlayViewModelShared.kt`, `data/.../entities/VideoResolution.kt`.

## Real sources (evidence)

18 type-4 sources from the `Mina-kk/yuedu-MCP` corpus shards (`app/src/main/assets/corpus/shards/f_*.json`, found with
`gh search code '"bookSourceType": 4'`) and `aikankankanhhh998/shuxiangzhijiayuan/All.json`:

- **Every one outputs a single URL.** None uses the resolutions JSON, `名稱::網址`, or MPD text.
- 6 call `java.startBrowser(url)` themselves when `book.durChapterIndex == chapter.index` and return a text blob
  (「【刷新正文】播放 ✅直链: …」) — written for a legado without a player. E behaves the same (the browser opens). We
  keep that: the source's side effect runs, and the player reports "not a playable link".
- 3 return a parse-page URL (`jx.…/?url=`): an HTML player page, not a stream. Same outcome as above.
- 線路 via `isVolume`: 稀饭影视 (`V`), 西瓜卡通 (`$.volume`), 榴莲影视 (JS-built tabs).
- Live test candidates: 河马剧场 `freevideo.zqqds.cn` (MP4 JSON), 奈飞工厂 / 猫看 (m3u8, likely Referer), 稀饭影视 (線路).

光遇聚合 「短剧」 is **out**: it emits video only when `java.getAppVariant` (an E-only probe) exists; without it the
content is a text blob plus `startBrowser`. Adding `getAppVariant` would flip many sources into E branches.

## Platform limit

AVFoundation plays MP4/MOV and HLS. **DASH (`.mpd`), FLV, MKV, AVI do not play** — the E/Sigma MPD branch cannot be
ported. Such content gets a clear message, not a retry. (Swiftfin solves this with an MPV backend; adding MPV/VLC is
a separate decision, not in this plan.)

## V1 — the type and its data flow

- `BookSource.bookSourceType` 4: edit-view picker (`影片`), info sheet, the `0/1/2/3` comments.
- `OnlineBookContentKind.video`, `BookPipelineKind.video`; `kind(fromSourceType:)` 4 → `.video`;
  `kind(fromTypeNumber:)` stays as it is: the `Book.type` bits (4 in E/Sigma/MD3, 2048 in the original) reach us
  only from a source that probed `java.getAppVariant`, which we do not have, and the same function reads URL query
  values (`?type=4`, `?category=4`) where 4 is usually a novel category.
  No text-label heuristics (「短剧」 etc.): no real source needs one, and 「短剧」 would route 光遇's text blob into the player.
  `declaredContentKind(for:)` 4 → `.video`.
- Every switch over both enums (the compiler lists exhaustive ones); grep `default:` inside those switches —
  they absorb the new case silently (BookStore, ReadingChapterPlace, ImportedBookCover, ChapterRenumbering,
  WorkTableOfContents, Models).
- Chapter content is a URL, so for `.video`: no HTML formatting / `normalizeLegadoContent`; exempt from replace
  rules (the 水印去除 preset deletes `http…` tokens — the audiobook bug; today the user's rules already run only at
  display time, so a URL never meets them). The link is cached and refetched exactly as an audiobook chapter's is
  (`OnlineChapterAudioProvider`: `ChapterFetchManager.fetchChapter`, then `discardResolvedAudio` + one silent refetch
  when it fails to play — legado's `resourceUrl`). One path: no second cache for video links.
- Labels: 影片 tag in search rows/groups, shelf badge + VoiceOver (as 有聲書), source picker, home cards.
- Progress: reuse the audiobook chapter-index + seconds fields (`audioChapterIndex`, `audioTimeSeconds`) — no third
  position scheme. Any new field is Optional with no default (`ReadingBook` sync-hash rule).
- **Sync skew (checked):** an old build decodes an unknown `contentPipelineKind` by inference (online → `.html`) — no
  crash. Its sync merge compares hashes of what it decoded, so it uploads nothing until that book changes on the old
  device; once it does (opened, progress saved), the record goes back up as `.html`. So `BookStore.snapshotForSync`
  — where every merged record enters, from iCloud and WebDAV alike — takes `.video` back for an online `.html`
  record whose source is type 4 (beside the existing `module` repair, same deletion rule). Every open path then
  reads a correct record; none needs its own check. The works index (`ContentKind`) is local derived data: an old
  build that cannot decode it rebuilds it. Audio/manga auto-detection skips `.video` records.

## V2 — the player (Swiftfin layout)

- Full screen, rotates; `AVPlayerLayer` with our own overlay (not `AVPlayerViewController`: the overlay must host
  彈幕, long-press speed and the episode drawer). Assets only through `HeaderedMediaAsset`.
- **Toolbar:** close (`xmark`; `chevron.down` while the drawer is open), title = book name, subtitle = 線路 · episode;
  action buttons: speed menu, PiP, AirPlay (`AVRoutePickerView`), aspect fill, previous/next episode, 彈幕 (V5),
  resolution (V3).
- **Centre (plezy):** previous episode / play-pause / next episode — episodes are what a video source changes
  most (short dramas). Swiftfin's ±jump moves to the horizontal swipe gesture, as Swiftfin also does.
  **Bottom:** scrubbable progress + times.
- **Drawer (Swiftfin "supplements" = plezy's swipe-up content strip):** swipe up on the bottom area, or the
  選集 button; the centre controls and timeline fade while it is up, the top bar stays. Tabs: 選集 (線路 tabs +
  episodes) and 資訊 (intro).
- **Gestures:** tap toggles the overlay; horizontal pan scrubs; horizontal swipe jumps ±10 s; vertical pan on the
  left edge = brightness, right edge = volume (plezy's edge tracker); pinch = aspect fill;
  **long-press = temporary speed** (default 3.0×, settable); gesture lock.
- Episode end → next episode, crossing into the next 線路; the last episode of the last 線路 stops.
- Progress saved on pause, background, close, episode change, and periodically; reopening resumes.
- PiP (automatic on background) + `.playback`/`.moviePlayback` session + Now Playing / remote commands.
- **Detail page `VideoDetailView` (Swiftfin `ItemView`, compact enhanced header + series episode group):**
  `OnlineBookDetailDestination` routes `.video` to it, as it routes `.audio` to `AudiobookDetailView` — one router.
  Full-bleed backdrop (the cover, scaled and blurred: sources carry no 16:9 art) fading into the page colour;
  portrait poster, title, meta line (kind tags, latest episode, source); primary 「開始播放／繼續播放」 + the
  resume episode; add to shelf; 簡介 (expandable). Then 選集: the 線路 picker (Swiftfin's season selector) over
  the episodes as cards (number + title; no thumbnails — sources have none). Then a poster wall: 同題材 works
  from the source's own category (the existing genre links), and the source's other versions.
  Works the same from 搜尋, 探索, 書架 and 作品詳情.
- `java.openVideoPlayer` goes through this player (single-URL mode, per-URL position like E) — then
  `SourceBrowserPresenter.presentVideo`'s separate `AVPlayerViewController` setup is deleted. One player path.
- `yuedu-ios-design` skill; `.inline` titles; iOS 17 menu → sheet sequencing; every control VoiceOver-labelled,
  slider label + value; localization keys in all five `.lproj`.

## V3 — content formats (the original fork's three-step parse)

JSON `VideoSource` → `名稱::網址` lines → URL / in-memory m3u8 (`#BASE:` Referer prefix, served through an
`AVAssetResourceLoader` like `AudioStreamResourceLoader`). Text starting `<` (MPD) → the platform-limit message.
Switching resolution keeps the position and does not refetch the chapter.
**Verify live:** a Referer-protected HLS stream needs the headers on segment and key requests, not just the playlist.

## V4 — preload and refetch

Next episode's link resolved while the current one plays (in memory, short TTL — Sigma 30 min), reusing
`AudiobookResourcePreloader`'s mechanism if it generalises rather than adding a second preloader. First play error →
refetch the chapter once (original `retryOnPlayError`; the audiobook path does the same).

## V5 — 彈幕

Data: chapter variable `danmaku` (Bilibili XML string) or the big-data file; JS `chapter.putDanmaku(xml)` (E) —
check Sigma/MD3 names first. Parse `<d p="time,mode,size,color,…">text</d>` (mode 1 scroll, 4 bottom, 5 top).
Overlay driven by player time (follows pause, seek, speed); show toggle, speed/opacity settings.

## V6 — acceptance

Live: 河马剧场 (MP4), 奈飞工厂 / 猫看 (HLS + Referer), 稀饭影视 (線路 crossing). Unit tests per phase; UI test for
open → play → next → drawer; VoiceOver tree check; iOS 17 and 27.

## Out of scope

RSS video, 光遇 「短剧」, MPV/VLC for DASH/FLV/MKV, floating window (PiP covers it), subtitles.
