# Library

SimpleUI extends KOReader's file browser. Most of these features rely on CoverBrowser's book-info cache, so keep the **CoverBrowser** plugin enabled and let it index your books.

## Browse by metadata

Browse your library by **Author**, **Series** or **Tags**, from a Quick Action, the title bar or the Navigation Bar. Selections compose into a trail: authors and tags stack (AND) while a series pick replaces the previous one. Series metadata is read from the book-info cache and, when present, from Calibre's `metadata.calibre`. Comic archives (CBZ) take their title, author and series from an embedded `ComicInfo.xml`.

## View and sort per tab

Each tab of the library keeps its own view and sort. **Long-press a tab** to open a sheet with *View* and *Sort*, and under them the *Group by Series* toggle (and *Flat view* on the Library tab); the same options are in *Settings › Library › Views*, one submenu per tab.

- **Library** uses KOReader's own display mode and sort, which the file browser shares.
- **Authors**, **Series** and **Tags** each choose how their list looks (any of the file browser's views except *Classic*) and how it is ordered (alphabetical, natural or number of books, optionally reversed). Authors and Tags start as a text list, Series as a list with covers.
- Listed as a list, **Authors**, **Series** and **Tags** also keep their own portrait items per page (6 by default, at most 12), set in the long-press sheet or in *Settings › Library › Views › (tab) › Items per Page*. The text of a row keeps its size: when the row is too short for it, the book count and then the author are left out.
- The long-press sheet of the **Library** tab also sets its size: *Items per page* as columns × rows (2–8, one double picker, for the orientation on screen) in a mosaic, *Items per page* (4–20, portrait) in a list, nothing in the classic view. They are the file browser's own settings, so they match *Settings › Library › Views › Library › Items per Page* and apply to every folder shown in that view.
- The books inside an author, series or tag follow the Library tab's view and sort.
- In the two detailed lists (with covers, and with metadata only) folders and books share one style, in black text. A folder shows its name over a count line ("12 books", or "3 folders · 12 books"). A book shows its title over its series (when the series display is on) and authors, with the reading progress over the file type and size on the right. With *Progress Bar in List* on (the default; *Book Covers › Progress and Details › Progress*), every book gets a bar under the authors, in the Style menu's bar or as dots (*List Progress Bar Style*), followed by a short text: "10%" ("0%" for a book never opened), "On hold" or "Finished". The text follows *Pages Read Instead of %* ("50/503", "On hold · 50/503") and *Pages Left to Read* ("10%, 453 to read"). Finished books have a full bar and unopened ones an empty bar. On rows too short for the extra line, the progress stays on the right, in the file browser's own texts. With *Finished Books* set to Fade (*Library › Browsing*), finished books are faded over the whole row in both lists; Hide removes them from every view. Rows of books still loading, deleted files and the file-name list stay as KOReader draws them.

## Collections list

The window listing the collections uses the same rows as the folders of the detailed list: the name over a line with its markers and book count ("★ · 12 books"), a chevron at the end, and the same row height. When adding a book to collections, a checkbox takes the place of the chevron. It follows *Custom Covers*: with it off the list keeps KOReader's rows. Its portrait items per page (7 by default) are set in *Settings › Library › Views › Collections › Items per Page*; an open list follows the change at once.

## Library search

A fast search across the whole library by title, author, series or filename, using the plugin's own cache instead of walking the filesystem on every query (unlike KOReader's filename-only File Search).

## Flat view

Turn on *Flat view* (in the Library tab's long-press sheet, or *Settings › Library › Views › Library*) and the Library tab lists every book under the home folder in one list or mosaic, without folders. It is meant for a library imported with many nested folders, to see everything at once. The tab's view, sort and items per page apply as in a folder. The setting stays on until you turn it off; tapping the Library tab, or leaving an Authors/Series/Tags tab, lands on the flat view. Opening the file manager (app start, closing a book) lands on the flat view too.

**Long-press a folder** and choose *Show all books here* to see the books of that folder and its subfolders flat. This does not change the setting; the back button returns to the folder.

The list comes from a cached scan of every format KOReader opens. It covers up to 8 levels of folders and 20,000 files, skips hidden entries and refreshes when a folder changes. Series grouping in this view reads the series of the whole folder at once.

## Series groups

Consecutive books of a series in a real folder are shown as one folder-like entry, so "Hainish Cycle" appears once instead of as five loose books. Opening it stays inside the same real folder, so scroll position and the back button behave as usual. In the flat view the books of a series are grouped across all folders, and a collection made from such a group includes the subfolders its books live in. *Group by Series* can be switched in the long-press sheet of the tab.

## Folder covers

Custom cover art for folders in the mosaic view:

- Uses the **first book cover** found inside a folder by default.
- A **`.cover.*` image file** placed in the folder takes priority.
- A folder whose books have no cover (or have it ignored) shows a placeholder with its name; this includes series groups and author/series/tag entries.
- **Long-press a folder** (or a series group, or an author/series/tag entry) and choose *Set folder cover…* to pick a specific book's cover.
- Optional **folder name label** with configurable position (top, centre, bottom) and style (solid or transparent background).
- Optional **item count badge** with configurable position.
- Optional **book stack** and **hide selection underline**.
- In the **list with covers** view a folder row (real or virtual) shows its name and count at the left and a fan of up to four member covers at the right, the picked or `.cover.*` cover in front. *Library › Folders › Covers in List View* switches between *Several Covers* (default) and *One Cover*; rows too short for a fan show one cover.

## Cover badges

Badges drawn on book covers: pages, series, progress, "new" and count. Each has a show toggle, a variant and a colour (dark, light, accent or secondary); a single size setting is shared by all of them. Progress can be drawn as a banner, KOReader's native indicator, or hidden. *On Hold (List View)* puts a pause badge in the middle of the cover of books on hold in the list with covers; the mosaic keeps the pause mark of the progress banner.

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
