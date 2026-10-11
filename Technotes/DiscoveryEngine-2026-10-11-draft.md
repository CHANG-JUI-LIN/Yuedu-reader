# Discovery engine (Phase 7) — draft, 2026-10-11

Status: **idea recorded, not designed.** First step settled 2026-10-11 (below). The maintainer chose (2026-10-11) to make this a phase of its own (Phase 7; Phase 6 is already modules), and to keep building Phase 5 as planned. Nothing here is decided beyond that; each "Open" item needs its own answer before work starts.

## First step: recommendations from the reader's own sources (maintainer, 2026-10-11)

Phase 7 starts on device, from the sources the reader has already added, not from a server. The self-built index below moves to a later step; it is not dropped.

- **Input:** the discover pages of the reader's book sources, but only the categories and charts a source offers. Public libraries and remote libraries are inputs too.
- **On device:** requests, reading history, ranking and the cache all stay on the phone. Yuedu runs no server and collects nothing centrally. Running on the device does not by itself license the content: each source's rules still apply.
- **Ranking:**

  | Signal | What it does |
  |---|---|
  | Source mix | No single source fills the home |
  | Genre match | The genres the reader reads come first |
  | Exploration | Each refresh brings in some books not seen before |
  | Cross-source dedupe | A work shows once and keeps every source (5c-4's work index) |
  | Recent reading | Books like the ones in 繼續閱讀 |
  | Local cache | Opening the home does not request dozens of sources |

- **On the home:** a section kind of its own, 為你推薦, drawn with decision 14's five layouts. It sits beside the public sections, so a home without sources is still not empty. The two modes, public and from the reader's sources, are sections on one home, not separate tabs.
- **Extension point:** a licensed metadata API or regional chart later becomes one more `DiscoveryProvider`, with no rewrite.
- **Depends on:** 5d-6's 「書源的排行／最近更新」 (the source categories and charts) and 5d-2/5d-3 (sections and layouts).

## The idea (later step: server-side)

The home should not wait for thousands of book sources to each offer good rankings. Yuedu recommends **works** itself, then finds where the reader can read them.

```
Discovery = book knowledge graph + regional recommendation + source availability
```

| Layer | Answers | Depends on the reader's sources? |
|---|---|---|
| Book knowledge graph | Which works, authors, series, languages, genres and editions exist | No |
| Discovery & recommendation | What to show this reader: region and language first for a new reader, then interests and reading history | No |
| Availability resolver | Where this reader can read a recommended work: shelf, Calibre, WebDAV, OPDS, book sources | Yes |

A recommended work without any source is still shown, marked 「未找到可用來源」. Scoring and availability are computed apart.

## How it fits what exists

- **The home (Phase 5)** is the renderer either way. Recommendations arrive as more section kinds, such as 為你推薦 and 在地熱門, drawn with the five layouts (Phase 5 plan, decision 14).
- **Availability resolver** is the design's 「尋找可用來源」, which needs unified search (Phase 4, design §15).
- **Book knowledge graph** is wider than Phase 3's external metadata, which only fills gaps for books the reader already has, on device. This one needs a server-side index of works the reader does not have.
- **Book sources, Calibre, WebDAV and OPDS** stop being responsible for recommending. They supply text and, where they have them, extra signals.

## Server sketch (proposed interfaces, none exist)

- Global book index: multilingual works, editions, authors, genres.
- Regional trend aggregator: public rankings and catalogs per market.
- Recommendation: recall → rank → dedupe → diversity.
- API: `/discover?region=…`, `/recommendations`.

The reader's private libraries, history and credentials stay on device. The server sees only public book data, plus usage signals the reader agreed to share.

## A first ranking without AI

An explainable score for a new reader: language and region match, regional popularity, interest match, data quality, freshness. The weights are placeholders until measured. Region is only the cold-start signal; reading language, chosen interests and behaviour outweigh it over time (someone in Taiwan may read mostly English fantasy).

## Candidate data (each to be verified before use)

- **Open Library:** works, authors, editions and subjects; monthly dumps suit an index better than bulk API calls. *Open: the dumps' license, and whether trending is per region.*
- **Google Books:** bibliographic data, covers and availability across languages. *Open: terms for storing and redistributing results from a server.*
- **Project Gutenberg / 青空文庫:** works that can actually be read, with their sources. Already in the app.
- **Regional rankings** (Taiwan, Japan, US): licensed providers or public lists. *Open: which, and on what terms.*
- **Hardcover:** discovery, reading records and recommendations, with a public GraphQL API. *Open: whether its data may feed a public service.*
- **Yuedu's own anonymous, opt-in signals,** once there are enough readers.

Three kinds of data come from different places and must not be confused: bibliographic, popularity and availability. A catalog that can search a book does not know what readers in one market are reading this week.

## Open questions

1. The data sources and their licenses, item by item.
2. Where the server runs, and what it costs at scale.
3. Privacy: what, if anything, leaves the device, and the consent flow.
4. Matching a recommended work to a source's book, which is Phase 4's work matching.
5. How recommendations are evaluated before they ship.
6. Region gates: 公有書庫 and other content rules that already differ in China.
