# Library

SimpleUI extends KOReader's file browser. Most of these features rely on CoverBrowser's book-info cache, so keep the **CoverBrowser** plugin enabled and let it index your books.

## Browse by metadata

Browse your library by **Author**, **Series** or **Tags**, from a Quick Action, the title bar or the Navigation Bar. Selections compose into a trail: authors and tags stack (AND) while a series pick replaces the previous one. Series metadata is read from the book-info cache and, when present, from Calibre's `metadata.calibre`. Comic archives (CBZ) take their title, author and series from an embedded `ComicInfo.xml`.

## Library search

A fast search across the whole library by title, author, series or filename, using the plugin's own cache instead of walking the filesystem on every query (unlike KOReader's filename-only File Search).

## Series groups

Consecutive books of a series in a real folder are shown as one folder-like entry, so "Hainish Cycle" appears once instead of as five loose books. Opening it stays inside the same real folder, so scroll position and the back button behave as usual.

## Folder covers

Custom cover art for folders in the mosaic view:

- Uses the **first book cover** found inside a folder by default.
- A **`.cover.*` image file** placed in the folder takes priority.
- A folder whose books have no cover (or have it ignored) shows a placeholder with its name; this includes series groups and author/series/tag entries.
- **Long-press a folder** (or a series group, or an author/series/tag entry) and choose *Set folder cover…* to pick a specific book's cover.
- Optional **folder name label** with configurable position (top, centre, bottom) and style (solid or transparent background).
- Optional **item count badge** with configurable position.
- Optional **book stack** and **hide selection underline**.

## Cover badges

Badges drawn on book covers: pages, series, progress, "new" and count. Each has a show toggle, a variant and a colour (dark, light, accent or secondary); a single size setting is shared by all of them. Progress can be drawn as a banner, KOReader's native indicator, or hidden.

## Long-press sheets

Books and folders open an action sheet with the usual file actions (status, reset, collections, book information, plugin-registered buttons), the same on the Home Screen, in search results and in the file browser.

## Book cover

*Book cover* in a book's long-press sheet opens a window with the current cover, where it comes from (the book file or a custom image) and its size. Tap the cover to see it full screen. From there you can:

- **Search online** for covers on Open Library and Google Books, and optionally Apple Books (off by default; its artwork is subject to Apple's terms). The search uses the book's ISBN when it has one, then its title and author, which you can edit; *Search* runs it again. Type an ISBN instead (with or without hyphens) to find the covers of that edition only. While it runs, a notice shows its progress; a tap cancels it, keeping the covers found so far. The covers found open in a sheet over the window, largest first, eight per page with their source and size; select one and tap *Use this cover*. Closing the sheet keeps the results: *Show N covers* opens it again.
- **Choose from device**: pick an image file.
- **Undo last change** (and undo the undo), or **Restore original cover**.

Covers are stored with KOReader's own custom cover (`cover.*` in the book's sidecar folder), so they show everywhere, outside SimpleUI too, including a folder cover that uses the book. Online search needs Wi-Fi; KOReader asks to turn it on when needed. When no cover service can be reached (no internet, or the connection dropped), a notice says so instead of reporting that no covers were found.

## Create collections from groups

From a folder, series group or author/series/tag entry you can create a collection holding its books.

Back to the [README](../README.md).
