# Library

SimpleUI extends KOReader's file browser. Most of these features rely on CoverBrowser's book-info cache, so keep the **CoverBrowser** plugin enabled and let it index your books.

## Browse by metadata

Browse your library by **Author**, **Series** or **Tags**, from a Quick Action, the title bar or the Navigation Bar. Selections compose into a trail: authors and tags stack (AND) while a series pick replaces the previous one. Series metadata is read from the book-info cache and, when present, from Calibre's `metadata.calibre`. Comic archives (CBZ) take their title, author and series from an embedded `ComicInfo.xml`.

## Library search

A fast search across the whole library by title, author, series or filename, using the plugin's own cache instead of walking the filesystem on every query (unlike KOReader's filename-only File Search).

## Search bar

An optional search field pinned at the top of the library (*Library › Search Bar*, off by default). Typing filters the books and folders on screen as you go, by title, author, series or filename, using the same cache as the library search; a folder stays when it holds a matching book. It works in folders, series groups and the Authors, Series and Tags views. Clearing the field, or opening another folder, brings back the whole list with its sort and filters.

## Series groups

Consecutive books of a series in a real folder are shown as one folder-like entry, so "Hainish Cycle" appears once instead of as five loose books. Opening it stays inside the same real folder, so scroll position and the back button behave as usual.

## Folder covers

Custom cover art for folders in the mosaic view:

- Uses the **first book cover** found inside a folder by default.
- A **`.cover.*` image file** placed in the folder takes priority.
- **Long-press a folder** (or a series group, or an author/series/tag entry) and choose *Set folder cover…* to pick a specific book's cover.
- Optional **folder name label** with configurable position (top, centre, bottom) and style (solid or transparent background).
- Optional **item count badge** with configurable position.
- Optional **book stack** and **hide selection underline**.

## Cover badges

Badges drawn on book covers: pages, series, progress, "new" and count. Each has a show toggle, a variant and a colour (dark, light, accent or secondary); a single size setting is shared by all of them. Progress can be drawn as a banner, KOReader's native indicator, or hidden.

## Long-press sheets

Books and folders open an action sheet with the usual file actions (status, reset, collections, book information, plugin-registered buttons), the same on the Home Screen, in search results and in the file browser.

## Create collections from groups

From a folder, series group or author/series/tag entry you can create a collection holding its books.

Back to the [README](../README.md).
