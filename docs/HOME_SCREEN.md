# Home Screen

The centrepiece of SimpleUI: a home screen built from modules you choose, size and arrange. Open **Settings → Home Screen → Edit Home Screen Layout** to add, remove and reorder modules, or long-press any module on the screen to jump straight to its settings.

## Modules

### Books

- **Currently Reading** — your active book with cover, title, author, series, description, progress bar and a statistics line. Two layouts: *Default* (cover sized relative to the module width) and *Dynamic* (the cover grows or shrinks to follow the text). The statistics line can be compact (one line) or detailed (one line per item).
- **Recent Books** — a row of up to 5 recent books with cover thumbnails and progress indicators; tap one to resume reading.
- **New Books** — recently added books sorted by file date. Unread books are labelled "New" and started books show their read percentage. Opt-in.
- **To Be Read (TBR)** — books you marked as "to be read", backed by a real KOReader collection.
- **Cover Deck** — your recent or TBR books as a cover carousel. *Classic* shows the outer slice of each neighbouring cover; *Flow* shows each whole cover tilted in perspective.
- **Flat Library** — a single grid of every book in your library, regardless of folder structure.
- **Tabbed Grid** — a book grid with a tab bar in place of the section label. Each tab binds the grid to a source: reading history, new books, the To Be Read list, any collection, or the authors, series and tags of your library (group tabs list groups of books and open them in the library). Choose round, square or plain tabs, and a page indicator as numbers, a bar or none; swipe to turn the page. You can add several instances.
- **Collections** — your KOReader collections as tappable cover cards, with an **Auto** cover style that switches between a single cover and a 4-cover grid depending on collection size.
- **Featured Collection** — one collection at a time, shown as a row of covers. Add several instances to feature more than one.

### Statistics

- **Reading Goals** — progress for your annual, monthly and daily reading goals. Books you read on paper can be added by hand (a single book, or a count for a year) and are counted like any other finished book.
- **Reading Stats** — a grid of stat cards you compose yourself. See [Reading Stats & Streaks](STATS.md).
- **Reading Heatmap** — a card showing when you read: a calendar of the last weeks, a time-of-day grid (weekday × hour) or reading per hour of the day. Tap it to open the full-screen heatmap. Off by default.

### Shortcuts and extras

- **Clock & Date** — a large clock with the full date, or your own custom text.
- **Quick Actions Row** — up to 3 customisable rows of shortcut buttons (Library, History, Wi-Fi toggle, Brightness, Stats and more).
- **Action List** — the same shortcuts as a vertical, launcher-style list.
- **Quote of the Day** — a literary header picked from a shuffled quote collection. With KOReader set to Simplified Chinese (`zh_CN`), the default collection contains 100 excerpts originally written in Chinese, with authors and work titles, rather than translations of the English quotes. Other languages retain the existing English collection; it is also the fallback if the Chinese collection cannot be loaded. The module can also show your own highlights. To supply your own pool, place a `.lua` file in `<KOReader settings dir>/simpleui/sui_quotes/` (created on first run, never touched by updates) that returns a table of `{ q = "...", a = "Author", b = "Book (optional)" }` entries, then set **Source → Custom** on the module. To edit a built-in pool, change `modules/quotes.lua` (English) or `modules/quotes_zh_CN.lua` (Simplified Chinese).
- **Tiny Critter** — a pixel-art companion with a speech bubble. See [Tiny Critter](CRITTER.md). Off by default.
- **Spacer** — a blank block for breathing room between modules.

## Width and position (bento grid)

Every module takes **1/3, 1/2, 2/3 or the full width** of a row. Consecutive modules whose widths add up to a row sit side by side; a row never stacks.

- Long-press a module and choose **Width and Position** to see a live preview of its row. From there you can change its width, move it (← → within the row, ↑ ↓ between rows) or remove it.
- With **auto-fit** on, a neighbouring module adjusts so the row stays closed. Turn it off and only the chosen module changes; turning it back on restores the neighbours' previous widths.
- In a row, shorter modules stretch their box to match the tallest one and their content is centred.
- The same sheet is available from the module's own settings and from the page editor.

## Pages

A screen can have **several pages** that you swipe between. In the layout editor you can add pages, move modules between pages, and reorder modules inside a page. Incomplete rows are flagged so you can close them. The editor shows each module's width, and for full-width modules a short summary of what it displays.

Tap a page's eye icon to **hide** it: it leaves the screen but keeps its modules and their settings, so you can show it again later without rebuilding it. At least one page always stays visible.

## Custom Screens

Build extra Home-Screen-like pages of your own, each with an independent module layout, alongside your main Home Screen:

- Create, rename and delete as many custom screens as you like.
- Configure modules on each one exactly as on the main Home Screen.
- Each custom screen gets its own **Quick Action** automatically, so it can be opened from the Navigation Bar, the Quick Actions Row or the Quick Settings Bar, with its own icon.

## Look and behaviour

- **Module ordering and per-module scaling** — resize each module independently, or lock all scales together.
- **Wallpaper** — a background image for the Home Screen, with auto-rotate, stretch and Night Mode inversion options.
- **Presets** — save and load full Home Screen configurations (layout, scales, wallpaper) to switch between looks.
- **Start with Home Screen** — open the Home Screen first every time KOReader starts (**Home Screen → Behaviour**).

Back to the [README](../README.md).
