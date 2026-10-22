# 趨勢 as an official module (2026-10-21)

Maintainer, 2026-10-21: an official module 趨勢 with 今日熱門, 本月熱門, 今年熱門, 完結推薦, 地區推薦 and
經典名著. The maintainer has a server and the gateway. **Nothing ever fetches a Chinese web-novel platform in
real time**; Simplified Chinese web novels are only the popular ones Wikipedia has articles for.

Decided (AskUserQuestion, 2026-10-21):

1. **Where:** the HK host (`gateway.yuedureader.com`, 43.129.29.13) runs a daily job that writes static JSON;
   the app's official module reads only those files. Reachable from mainland China; the app touches no
   web-novel platform.
2. **Popular by:** Wikipedia pageviews (day / month / year), one measure for every language.
3. **地區推薦:** a 地區 option on every list (as 5 and 7 left it: 華語（繁）/ 華語（簡）/ 日本 / 英語), not a
   list of its own; it defaults to 中繼資料語言偏好推薦's language (below).
4. **經典名著:** every famous work, in copyright or not; reading goes through 尋找可用來源.
5. **Script:** the 地區 options split Chinese by script — 華語（繁）, 華語（簡）, 日本, 英語. The module format
   is not changed (no app-language template variable).
6. **完結:** the server asks Bangumi once a day for 连载结束; the app never does.
7. **No 韓國** until its pool grows.
8. **The default home stays as it is**: 趨勢 is added by hand from 新增欄目.

Follows `2026-10-17-module-ecosystem.md` (format 3.0) and the default home's module rows (6f274457).

## What was measured (2026-10-21, from this Mac)

| Region | Pool (Wikipedia categories) | Pages | Novels among them | End date on Wikidata |
|--------|-----------------------------|------:|------------------:|---------------------:|
| 華語 | zh `中华人民共和国网络小说` tree (30 subcategories) | 510 | ~42 typed as literary; 264 are TV series, 59 TV programmes, 31 films | 1 |
| 日本 | ja `小説家になろうの小説` + `カクヨムの小説` | 425 | 348 typed Q104213567 + 50 literary | 1 |
| 韓國 (not made) | ko `대한민국의 웹 소설` tree | 41 | 1 | 0 |

- Pageviews rank sensibly: zh September, from a crude title filter (59 pages): 凡人修仙传 14 257,
  盜墓筆記 7 418, 斗破苍穹 5 520, 鬼吹灯 5 178, 天官賜福 4 727, … 诡秘之主 3 199.
- Wikidata's class is unreliable for web novels (诡秘之主, 盜墓筆記 are "book series", not "web novel"), so
  the pool comes from categories, and a page is kept by its Wikidata class (novel, series, light novel, web
  novel, literary work), which removes the adaptations.
- **Completion:** Wikidata end dates cover 1 work in each pool; zh infoboxes do not say. **Bangumi does**:
  `连载开始 2018-04-01`, `连载结束 2020-05-14` for 诡秘之主. ja has `Category:継続中の作品` for ongoing works.
- **Covers:** none usable from Wikipedia (book covers are non-free); the lists are ranked lists with the
  generated cover, as なろう's. *Superseded 2026-10-22: the lists carry covers, see "Covers" below.*
- **Open Library trending** (not chosen): daily top three are Atomic Habits, Rich Dad Poor Dad, The 48 Laws
  of Power.
- **AniList's API is down**: every request answers "temporarily disabled due to severe stability issues"
  (403). This also empties the English default home's AniList rows (6f274457) until it returns.

## Calls of mine, unless vetoed

- 英語 has no 完結推薦: published books are finished; the concept is a web-novel one. The 完結推薦 list's
  地區 options are 華語（繁）, 華語（簡）, 日本.
- 經典名著 is stories only (novels, novellas, short stories and their collections): a reader's list, so
  no plays, poetry, philosophy, histories or scripture.
- ~~A 地區 param's default is its first option~~ — vetoed (maintainer, 2026-10-21): the 地區 option
  **defaults to the app's language**, through 中繼資料語言偏好推薦 (below).

## 中繼資料語言偏好推薦 (done before T1, 2026-10-21)

聚合設定's 偏好閱讀語言 (several languages, ordered) and 推薦範圍 became one menu, 中繼資料語言偏好推薦:
跟隨 App 語言 (first, the default), 繁體中文, 简体中文, English, 日本語, …; one at a time; its books
first and the rest after (優先推薦, fixed). A saved 偏好閱讀語言 list gives its first language until the
reader picks; a saved 只推薦 / 不限制 becomes 優先推薦. The menu's tag (`zh-Hant`, `zh-Hans`, `ja`, `en`) is
what 趨勢's 地區 defaults to: 繁體中文 → 華語（繁）, 简体中文 → 華語（簡）, 日本語 → 日本, English → 英語.
**Settled for T3 (AskUserQuestion, 2026-10-22):** the format gained `followsLanguage` (below, T3), and a
language with no region (한국어, Français, …) gets 英語.

## The server job (`scripts/trends/`, Python, like `scripts/aozora_catalog/`)

1. **Pools**, weekly: walk each region's categories (above; 英語: `YYYY English-language novels`, 2000 →
   this year), keep pages whose Wikidata class is a novel / series / light novel / web novel / literary
   work; record the item id, each language's title (zh variants by Wikipedia's conversion), author, and
   other-language titles as aliases.
2. **Pageviews**, daily: Wikimedia per-article daily views, the last 366 days on the first run, then the
   last 2 days; kept in SQLite on the host. 今日 = yesterday's views (the API's last full day), 本月 = last
   30 days, 今年 = last 365 days. The app's User-Agent; within Wikimedia's limit (T2b: 200 a minute across
   all its APIs, 3 at once).
3. **完結**: match a pool work to its Bangumi subject by title + author; 连载结束 present = finished;
   ranked by last-365-day views.
4. **經典名著**: Wikidata stories written in the region's language, ranked by how many Wikipedias have an
   article (sitelinks); a series' volumes fold into one entry. A story is a novel / novel series by
   class (P31), a novel / novella / short story / collection by form (P7937), or a monogatari / wuxia
   novel by genre (P136); the language (P407) includes its stages and written forms. Measured
   2026-10-21: the class alone missed 紅樓夢, 四大名著, Pride and Prejudice, 1984 and ノルウェイの森 (all
   "literary work" with form novel; 紅樓夢 in written vernacular Chinese), and literary work alone brings
   in 孫子兵法, 論語, the UN Charter and 永樂大典. Plays and poetry (西廂記, 唐詩三百首) are left out — a call
   of mine, below.
5. **Output**: `https://gateway.yuedureader.com/trends/v1/<region>/<list>.json`, region `zh-Hant`,
   `zh-Hans`, `ja`, `en` (華語 written in each script with Wikipedia's own word-level variant conversion), 50 works each,
   in the module list rules' shape (title, author, intro = the article's first paragraph, url = the article,
   aliases, tags). Written atomically; a list whose run failed keeps yesterday's file and logs why.
6. **Attribution**: intros are CC BY-SA; the module's `attribution` says so and links Wikipedia.

Tests: `scripts/trends/test_build_trends.py` (as `aozora_catalog`), for the builder's pure parts (pool
filter, ranking windows, variant pick, output shape), Bangumi matching on real responses in
`scripts/trends/fixtures/`, and a failed run keeping the last files. `python3 -m unittest
scripts/trends/test_build_trends.py`; a local run needs `SSL_CERT_FILE=/etc/ssl/cert.pem` with
python.org's Python and `--limit` to stay small.

## The app

1. `Resources/Assets/official-module-trends.json`: id `trends`, title 趨勢 (5 languages), hosts
   `gateway.yuedureader.com`, lists `today`, `month`, `year`, `completed`, `classics`, each with a 地區
   `enumeration` param (華語（繁）`zh-Hant`, 華語（簡）`zh-Hans`, 日本 `ja`, 英語 `en`; 完結推薦 has 英語 too
   since T2b);
   no `reading` (data only → 尋找可用來源); `cacheDuration` 6 h for today, 24 h for the rest.
2. Localizations in all five tables; `OfficialModuleFilesTests` for the bundled file.
3. No default-home change.

## Steps

- T1 server builder + tests (local runs against the real APIs; no deploy).
- T2 deploy to the HK host (done 2026-10-22, below): a systemd timer running the host's Python, Caddy
  `handle_path /trends/*` file server.
- T3 the module file.
- T4 live check: the five lists in each region on the simulator.

## Risks

- The 華語 pool is small (~60–100 novels) and old: Wikipedia covers famous, adapted works.
- Pageviews spike when an adaptation airs: 今日熱門 follows TV as much as reading.
- The job depends on Wikimedia; a failed day keeps the previous files. Wikidata's SPARQL service answered
  504 once in two classics queries on 2026-10-21 (the classics query is the heavy one); 華語（繁）and
  華語（簡）share one answer, and a failed classics list keeps yesterday's file. (Since T2b a timeout, 429 or
  503 is asked again once; a 504 is not.)
- 英語's pool is large: 10 021 pages, 9 604 stories (2000 → 2026 categories, T1 run 2026-10-21), so the
  daily job asks Wikimedia ~9 600 pageview requests (one per work). The "5 a second" this plan first
  assumed was over Wikimedia's limit (T2b); with the pool from 1890 it is ~23 200 requests a day.
  華語 is 510 pages / 42 stories, 日本 425 / 381.

## T1 result (2026-10-21, this Mac, live APIs, `--limit 30` stories a pool)

- 華語 今日熱門: 凡人修仙傳, 天官賜福, 鬥破蒼穹, 明朝那些事兒, 大主宰, 斗羅大陸, 無限恐怖, 後宮甄嬛傳 …;
  完結推薦 10 of 30 (凡人修仙傳, 鬥破蒼穹, 全職高手, 將夜 …).
- 完結, split (the store's `finished` table): 華語 10 finished, 13 on Bangumi with no end date, 7 not
  on Bangumi as a novel (後宮如懿傳, 步步驚心, 新宋 …); 日本 3 finished, 21 with no end date, 6 not
  on Bangumi as a novel (JKハル is a manga there; only its spin-off is a novel). "No end date" is
  unknown, not ongoing: Bangumi's light-novel series subjects carry only 发售日 (この素晴らしい世界に
  祝福を！ ended in 2020 and has no 连载结束). 完結推薦 lists only works Bangumi says ended. **Open:**
  whether the server may ask なろう's own API once a day for its end flag (日本 only; not a Chinese
  platform, not from the app) — to be asked before T2.
- Bangumi names a pen name longer or shorter than Wikidata (唐七公子 / 唐七, 平鳥コウ (XPJbox)): one
  name containing the other is the same author, the titles having matched exactly.
- 經典名著: 華語 紅樓夢, 西遊記, 三國演義, 水滸傳, 金瓶梅, 三體, 封神演義, 聊齋志異, 狂人日記 …; 英語 Harry
  Potter (its volumes folded), The Lord of the Rings, Nineteen Eighty-Four, Pride and Prejudice …; 日本
  ノルウェイの森, 海辺のカフカ, 竹取物語, 羅生門, 人間失格 ….
- Wikidata's `zh` labels mix scripts (墨香铜臭 on 華語（繁）): author names and label-only titles go
  through zh.wikipedia's own converter (`action=parse`, `variant`), the one its titles and extracts use.

## T2 (2026-10-22): deployed to the HK host

Decided (AskUserQuestion, 2026-10-22): the job runs from a **systemd timer on the host's own Python**
(3.12, the builder is stdlib only), not a container; and 日本's 完結 **also asks 小説家になろう's API**.

- Files: `scripts/trends/deploy/` — `yuedu-trends.service` (oneshot, user `yuedu-trends`,
  `MemoryMax=300M`, hardened), `yuedu-trends.timer` (04:30 UTC daily, `Persistent`), `Caddyfile` (the
  host's `/etc/caddy/Caddyfile`, now `handle_path /trends/*` + `handle { reverse_proxy … }`), and
  `deploy.sh` (installs the script to `/opt/yuedu-trends/` and the units; the store is kept).
- Host paths: store `/var/lib/yuedu-trends/trends.sqlite`, files `/var/lib/yuedu-trends/public/v1/`,
  served as `https://gateway.yuedureader.com/trends/v1/<region>/<list>.json`, `Cache-Control:
  public, max-age=3600`. Caddy's previous file: `/etc/caddy/Caddyfile.before-trends-20261022`.
- What is live: `sha256sum /opt/yuedu-trends/build_trends.py` against `scripts/trends/build_trends.py`.
- Measured before deploying (英語 at full size, 9 604 works × 366 days, this Mac): `popular()` held the
  year of daily views in Python — 39 766 ms, 531 MB peak, store 532 MB; summing the windows in SQLite
  (and a `WITHOUT ROWID` table, days past a year deleted) — 946 ms, 37 MB, store 313 MB. Wikidata's
  whole claims took ~38 KB a work (~370 MB for 英語's pool); holding only the claims asked for (P31;
  P50/P170; P179) keeps it flat, and 英語's authors are asked for the listed works only.
- なろう: the work's code comes from the ja article's link to `ncode.syosetu.com` (19 of 30 articles;
  Wikidata's P11335 had 5); of several links, the one whose なろう title holds the article's; `end` 0 =
  finished. Either Bangumi or なろう saying it ended is enough. Sample of 30: 17 known to なろう, 3
  finished; 完結推薦 3 → 4. Most ja works notable enough for an article are still running.
- A failed upstream request fails that pool's lists for the day; they keep yesterday's files. No retry
  (until T2b, below).
- First run on the host (2026-10-22 11:57–14:33 CST, 156 min, success, memory peak 248 MB — the
  cgroup counts the 200 MB store's page cache): 華語 4 min (42 stories), 日本 22 min (381; なろう: 292
  articles link a work, 274 known, 100 finished), 英語 2 h 10 min (9 604; 0.81 s a pageview request
  from the host). A daily run asks as many requests, so `TimeoutStartSec` went 3 h → 6 h.
- Live check from the Mac: all 19 files 200, `application/json`, gzip, `Cache-Control: public,
  max-age=3600`; `en/completed.json` 404 (no such list); `/healthz` 200. 英語 今日熱門 by views: Klara
  and the Sun, Verity, Fourth Wing, Slow Horses …; 日本 完結推薦 50 (転生したらスライムだった件, 無職転生,
  本好きの下剋上 …); 華語 今日熱門: 凡人修仙傳, 盜墓筆記, 鬥破蒼穹, 鬼吹燈, 詭秘之主 ….

## T2b (2026-10-22): the builder after T2 — not deployed yet

Decided (AskUserQuestion, 2026-10-22, each the recommended option):

- **英語 完結: 單本＋完結系列**, from English Wikipedia's infobox (`infobox_finished`): a book in no series
  is finished; a book of a series is when the series' own infobox gives an end (its article, or a
  character's article that links the series, followed at most twice); no infobox, an unlinked series or
  no dates → unknown, left out.
- **A series is one entry, from 2 books in the pool** (every region): its books' and its own article's
  views summed under its **earliest-published book** (P577). The entry carries `series` (the series
  article's title without its qualifier, else its label), shown under the author. A folded entry is
  finished when the series' infobox says so (英語), or when every book is (Bangumi / なろう).
  Deviation from what was asked: "a series with no first book in the pool shows the series' article
  title" is not needed — with the pool from 1890, every listed series had its first book.
- **英語's pool from 1890** (was 2000): 1890–1999 adds 14 621 pages, ~24 600 in all.
- **Authors from the infobox** where Wikidata names no person: P170 / P50, else P2093 (author name
  string), else the book infobox's `author`/`authors`/`著者`/`作者` — read for listed works only.
- Wikidata's `mul` labels (names the same in every language since 2024) are read as every language's.
- Pageviews are asked 3 at a time. Wikimedia's limit (mediawiki.org, Wikimedia APIs/Rate limits, read
  2026-10-22) is 200 requests a minute for a bot whose User-Agent names it, **one budget across every
  Wikimedia site and API**, at most 3 at once; 5 a second with 8 at once got 429 after four minutes.
  Every Wikimedia host (Action API, Wikidata, pageviews) now shares one pace, 0.35 s (171 a minute);
  the query service keeps its own. A failed request stops the rest.
- **One retry** (AskUserQuestion, 2026-10-22, 「重試一次」): a request unanswered for 120 s, or answered
  429 / 503, is asked again once after Retry-After (else 5 s; a wait over 300 s is not waited for). A
  local run of ~13 000 pageview requests had one go unanswered and lost the day's 英語 lists; a day asks
  ~24 000. Logged as `retrying in …`; delete when a month of runs never logs one.
- Deployed 2026-10-22 18:06 CST, with the retry 18:08; the host's previous script, unit and store are kept as
  `*.before-series-20261022` (`/opt/yuedu-trends/`, `/var/lib/yuedu-trends/`). `MemoryMax` 300M → 450M:
  reading the 1890 pool peaked at 236 MB on the Mac.
  The 2 h 10 min sequential first run was latency-bound (0.81 s a request).
- The store migrates itself: `pool` gains `series` and `published`, and the pools are read again.

## T3 (2026-10-22): the module file

- Format 3.0 gained `followsLanguage` on an enumeration (its default is the option in the reader's
  中繼資料語言偏好推薦: the option's `language`, else its `value`, by language then by base language;
  `value` when none), the option's `language`, and `localizations.<lang>.entries.<id>.params.<name>`
  (`title`, `description`, `options`). The section form shows 跟隨中繼資料語言偏好推薦 first; picking it
  clears the saved value. Docs: `docs/modules/README.md` §3.1, §7, §8.
- `Resources/Assets/official-module-trends.json`, five lists, each with the 地區 param; `trends` is in
  `OfficialRuleModules.ids` after `narou`.
- A module item's `series` reaches `WorkSummary.series`; every home card shows it under the author (a
  poster card in its small line, `Mistborn・已加入書架`, so it does not grow), and VoiceOver reads it.

## Covers (2026-10-22, maintainer: 「不能抓封面嗎？」)

- Each listed work carries `cover`: its **Bangumi** subject's own cover (`images.common`, lain.bgm.tv)
  where the work was matched there and Bangumi has one, else its **Wikipedia article's page image**
  (`prop=pageimages`, `pilicense=any`, 400 px asked, 500 px given), without Wikipedia's `utm_` query.
  Not `api.bgm.tv/v0/subjects/{id}/image`: a subject without a cover redirects to a placeholder.
- A page image is kept only when it **stands** (taller than wide) and is not an SVG. Measured on the
  host, 2026-10-22, over every listed work: 英語 117 of 120 page images stand (the 3 wide ones are
  open first editions); 華語 35 of 46 (the wide ones a café, a TV still, open old books).
- **No page image from ja.wikipedia** (`Pool.article_covers`): it keeps no non-free file, so no cover;
  its listed works' 46 page images are title logos, anime stills and photos (はたらく魔王さま! is a
  Shibuya street, 吾輩は猫である a cat). 日本 covers are Bangumi's only (92 of 151 matched).
- Page images come from `upload.wikimedia.org` and `thumb.wikimedia.org` (both seen on the host), so the
  module's `hosts` lists both, and `lain.bgm.tv`. Fetched from the host with the cover loader's Safari
  User-Agent: 200 from all three with curl; Python's urllib with that UA got 403 from
  `thumb.wikimedia.org` (a browser UA on a non-browser connection), so the app is checked in T4.
- Most 英語 covers are non-free files (fair use on en.wikipedia), not CC BY-SA, and so are 13 of 華語
  經典名著's (zh.wikipedia's own uploads; 11 more are Commons files). Maintainer, 2026-10-22: keep them
  all; the attribution line says so — "Wikipedia, Wikidata (CC BY-SA 4.0), Bangumi. Covers © their
  respective owners." (in English, as the line is shown in every language).
- **經典名著 are asked of Bangumi too** (pools Bangumi finishes: 華語, 日本), for its cover first, by
  the article's zh-cn title, the article, else the label. 日本's classics had no cover at all (no page
  images from ja.wikipedia); Bangumi has 39 of its 50, with covers, and 9 more of 華語's (measured on the
  host, 2026-10-22). Asked once a day while not known finished, like the trending works.
- The store's `finished` table gains `cover`. A store from before it forgets its Bangumi matches once and
  asks again, for their covers (~1 request a second, a few minutes).
- **Result on the host** (run of 2026-10-22 20:08, 12 min 42 s; the full run before it, 18:35–20:08, peaked at 157.5 MB; neither logged a retry), covers
  of works listed: 華語 today/month/year 34 of 41–42 (29 Bangumi, 5 zh.wikipedia), completed 12/12,
  classics 30/50 (12 Bangumi, 10 Commons, 8 zh.wikipedia); 日本 today 41, month 42, year 44, completed
  47, classics 39 of 50 (all Bangumi; classics were 0 before they were asked of Bangumi); 英語 today
  50, month 49, year 49, completed 49, classics 45 of 50 (en.wikipedia's own files 13–35 a list, the
  rest Commons). Fetched through URLSession with the cover loader's User-Agent from this Mac: 200 from
  upload.wikimedia.org and thumb.wikimedia.org (one 400 from a Commons original, not seen again in three
  more tries).

## Region follows 中繼資料語言偏好推薦 live (2026-10-22, maintainer bug)

Changing the language did not change the home's rows. Three places held the old answer:
`ExploreHome`'s `syncKey` did not include the language, a module row's `inputsKey` was only the module's
version, and 為你推薦's `inputsKey` did not include the language that orders it. All three now do; a
row with a picked 地區 keeps its key.
