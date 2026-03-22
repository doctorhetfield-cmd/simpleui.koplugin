# Folio

A KOReader plugin that replaces the default file-manager and reader chrome with a calmer, purpose-built surface: a **Home** dashboard, **top and bottom bars** you configure, a **custom title bar** in the library stack, **folder covers**, and **reader-side conveniences** (gestures, optional defaults, Wi‑Fi nudge). Built for e‑ink: large tap targets, readable typography, and a single shared theme (`folio_theme` / `DESIGN.md`).

Requires [KOReader](https://github.com/koreader/koreader). Clone or download this plugin from your usual Git host.

---

## Why use it

KOReader exposes almost everything through menus and dialogs. Folio doesn’t remove that power — it **front-loads** what you use every day: open the book you’re on, jump to collections, see goals and stats, and move in the reader without hunting. Configuration lives under **Menu → Tools → Folio**.

---

## The shell

**Home** — Composable modules (clock, quote, current book, recents, collections, goals, stats, quick actions). Reorder them, scale each module or lock scales, and optionally **start KOReader on Home** instead of the raw library.

**Bottom bar** — Up to **six** slots ( **four** when Navpager is on). Actions span library routes, Home, collections, history, continue, favourites, bookmarks, connectivity, brightness, statistics, power, and **user-defined** folders, collections, or plugins. Icons-only, text-only, or both. **Long-press** the bar for settings.

**Top bar** — Clock, Wi‑Fi, brightness, battery, disk, and RAM — each item can sit on the **left or right** with its own order.

**Title bar** — Back, search, and menu with size presets; behaviour respects root paths and locked home folder. Where Folio adds pagination context, the subtitle can show **page position**. Library vs inner views can use **different** button layouts where exposed.

---

## Library and history

**Folder covers** — Mosaic folders can show art from the first book inside, a **`.cover.*`** file in the folder, or a cover you **pick via long-press**. Optional label and count badge; optional hiding of the selection underline.

**Reading history** — Folio ships a **dedicated history screen** (timeline-style overview and milestones) integrated via the plugin’s patches, instead of relying on the stock list alone.

---

## Reader

**One-handed mode** — Remaps forward/back tap zones for left- or right-hand use; turning the mode off **restores** your previous KOReader page-turn zone settings.

**Swipe-up toolbar** — From the bottom edge of the page, a strip for brightness, font size, and light/night-style toggles (as wired in `folio_readingtoolbar.lua`).

**First-run defaults** — Optional one-time application of a **cleaner reader footer** profile and **screensaver** defaults (cover + message) when you haven’t already set your own — gated by Folio settings flags.

**Wi‑Fi reminder** — Optional banner if wireless stays on; dismiss or auto-hide per implementation.

---

## Installation

1. Download this repo (**Code → Download ZIP**).
2. Unzip so the directory name is **`folio.koplugin`**.
3. Copy it into your KOReader **`plugins/`** folder.
4. Restart KOReader.
5. **Menu → Tools → Folio** — enable the plugin and tune modules and bars.

---

## Translations

GNU gettext (`.po`). Language follows KOReader when a matching file exists under `locale/`.

Shipped: **en** (default), **pt_PT**, **pt_BR**, **es**, **zh_CN**, **ru**.

To add a language: copy `locale/folio.pot` to `locale/<code>.po`, translate `msgstr` entries (keep `%s` / `%d` / `\n`), restart. Roughly **300** message ids; the total moves as strings are added.

---

## Quote pool

Curated lines live in `desktop_modules/quotes.lua`:

```lua
{ q = "…", a = "Author", b = "Optional book title" }
```

The Home **Quote** module can also pull **random highlights** from your books or **mix** both sources — configured in Folio’s Home settings.

---

## Contributing

Issues and pull requests are welcome. Guidelines: [CONTRIBUTING.md](CONTRIBUTING.md).

---

## License

MIT — see [LICENSE](LICENSE).
