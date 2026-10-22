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
  generated cover, as なろう's.
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
**Open for T3:** how the module's param takes that default (the format's `value` is fixed text), and
what a language with no region (한국어, Français, …) defaults to — to be shown before T3.

## The server job (`scripts/trends/`, Python, like `scripts/aozora_catalog/`)

1. **Pools**, weekly: walk each region's categories (above; 英語: `YYYY English-language novels`, 2000 →
   this year), keep pages whose Wikidata class is a novel / series / light novel / web novel / literary
   work; record the item id, each language's title (zh variants by Wikipedia's conversion), author, and
   other-language titles as aliases.
2. **Pageviews**, daily: Wikimedia per-article daily views, the last 366 days on the first run, then the
   last 2 days; kept in SQLite on the host. 今日 = yesterday's views (the API's last full day), 本月 = last
   30 days, 今年 = last 365 days. The app's User-Agent; at most 5 requests a second.
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
   `enumeration` param (華語（繁）`zh-Hant`, 華語（簡）`zh-Hans`, 日本 `ja`, 英語 `en`; 完結推薦 without 英語);
   no `reading` (data only → 尋找可用來源); `cacheDuration` 6 h for today, 24 h for the rest.
2. Localizations in all five tables; `OfficialModuleFilesTests` for the bundled file.
3. No default-home change.

## Steps

- T1 server builder + tests (local runs against the real APIs; no deploy).
- T2 deploy to the HK host: Caddy `handle_path /trends/*` file server, a cron container. **Ask before.**
- T3 the module file.
- T4 live check: the five lists in each region on the simulator.

## Risks

- The 華語 pool is small (~60–100 novels) and old: Wikipedia covers famous, adapted works.
- Pageviews spike when an adaptation airs: 今日熱門 follows TV as much as reading.
- The job depends on Wikimedia; a failed day keeps the previous files. Wikidata's SPARQL service answered
  504 once in two classics queries on 2026-10-21 (the classics query is the heavy one); 華語（繁）and
  華語（簡）share one answer, and a failed classics list keeps yesterday's file. No retry is added.
- 英語's pool is large: 10 021 pages, 9 604 stories (2000 → 2026 categories, T1 run 2026-10-21), so the
  daily job asks Wikimedia ~9 600 pageview requests (one per work; at 5 a second, about 32 minutes).
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
