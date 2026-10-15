# 同題材作品: the reader picks the category — plan

> **For agentic workers:** one branch (`detail/related-category-picker`), tests written first, a "What landed" entry at the end. This file is gitignored; commit it with `git add -f`. Merge to main with `--no-ff`; never push.

**Goal:** 作品詳情's 同題材作品 reads the source's category that the book's first genre names (`SourceGenreLinks`), and nothing in the app changes it. The reader can now pick another category from the section's header.

## Maintainer's decisions (2026-10-15, by option)

1. **A menu beside the title.** It lists the book's genres that name one of the source's categories. A submenu, 其他分類, lists the source's other categories. The data stays the source's own categories, and none is guessed.
2. **Remembered per source.** A genre picked from the book's own genres becomes the source's preference. Every book of that source whose genres include it reads it first, and the latest pick wins among several. A category picked from 其他分類 is not one of the book's genres, so it holds for that book only.

## Settled here (each changeable on the maintainer's word)

- **One store:** `RelatedCategoryChoiceStore`, UserDefaults `yd_related_category_choice`, JSON. Not synced, because it is a device preference like the reading genre profile.
  - At most 20 preferences per source.
  - At most 300 book picks; the oldest are dropped.
  - Titles compare as `SourceGenreMatching.normalized` does.
- **Picking another genre for the book clears that book's 其他分類 pick.**
- **Switching keeps the shown books until the new ones arrive.** The section does not vanish, so the page does not jump under the reader. A failed switch shows the retry row under the new category.
- **The menu shows only when there is a choice:** at least two categories in all.
- **One path:** the choice feeds the same `SectionPageLoader` page 1 read. 查看全部 opens the chosen category.

## Tests (first)

- `SourceGenreMatchingTests`: a preferred genre wins; the latest preference wins; a book's pick wins and is ignored once the source no longer lists it; without either, the first genre is used, as before.
- `RelatedCategoryChoiceStoreTests`:
  - a genre pick moves to the front of its source's list only;
  - a 其他分類 pick holds for its book only;
  - a genre pick clears the book's pick;
  - picks persist across instances;
  - caps.
- `SourceGenreLinksTests`:
  - choices list the matched genres in genre order, then the other categories;
  - choosing loads the new category and keeps the section shown;
  - another book of the source follows a genre pick but not a 其他分類 pick.

## What landed

### Branch `detail/related-category-picker` (2026-10-15)

- `RelatedCategoryChoiceStore` (Services/Online) holds two kinds of pick:
  - per-source genre preferences, latest first;
  - per-book 其他分類 picks.
- `SourceGenreMatching.relatedCategory(for:among:preferred:bookPick:)` decides the category. A book pick applies while the source still lists it; then the best-ranked preference among the book's genres; then the first genre, as before.
- `SourceGenreLinks`:
  - publishes `choices` (`RelatedCategoryChoices`: matched genres, other categories, current);
  - gains `choose(_:key:source:tags:book:)`;
  - a switch or a retry keeps the section shown (no `.hidden`/`.loading` in between);
  - a picked category with no other book keeps its header and says 「這個分類沒有其他作品」.
- `BookDetailSectionHeader` takes an accessory beside the title. `BookDetailRelatedSection` puts a native `Menu` there:
  - an inline `Picker` of the matched genres, plus a 其他分類 submenu `Picker`;
  - VoiceOver label 「同題材分類」, value the current category;
  - shown only when there are two or more categories.
  - Wired into both `OnlineBookView` and `AudiobookDetailView`.
- Three new strings in all five lproj.
- Tests:
  - unit: 22/22 (`SourceGenreMatchingTests`, `SourceGenreLinksTests`, `RelatedCategoryChoiceStoreTests`);
  - UI, iOS 27 iPhone 18 Pro Max: `testRelatedWorksCategoryMenu` (new) and `testGenreLinkAndRelatedWorksOpenTheSourcesCategory` both pass;
  - screenshots checked: the menu beside the title, the checkmark and the submenu, and the empty category.
