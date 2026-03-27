# SimpleUI for KOReader

A clean, distraction-free UI plugin for KOReader that transforms your reading experience. SimpleUI adds a **dedicated Home Screen**, a customisable bottom navigation bar, a top status bar, and a reworked library title bar, giving you instant access to your library, history, collections, and reading stats without navigating through nested menus.

<div style="display: flex; flex-direction: row; flex-wrap: wrap; gap: 10px; max-width: 1000px; justify-content: center;">
<img src="https://github.com/user-attachments/assets/4ea92760-c2bf-488b-9f5a-1f663157c97f" width="240" height="324" alt="simpleUI1" style="object-fit: contain;" />
<img src="https://github.com/user-attachments/assets/a1a7a2c7-6c0f-484e-b6fa-c78474661480" width="240" height="324" alt="simpleUI2" style="object-fit: contain;" />
<img src="https://github.com/user-attachments/assets/1707f5c2-e367-47b8-90a9-9a9549bd9e67" width="240" height="324" alt="simpleUI3" style="object-fit: contain;" />
<img src="https://github.com/user-attachments/assets/fd443a96-e12c-4dc7-9e69-103c444458af" width="240" height="324" alt="simpleUI4" style="object-fit: contain;" />
</div>
---

## Features

### Home Screen

The centrepiece of SimpleUI. A home screen that gives you everything at a glance:

- **Clock & Date** — a large, readable clock with full date display
- **Currently Reading** — your active book with cover art, title, author, progress bar, percentage read, and estimated time left
- **Recent Books** — a row of up to 5 recent books with cover thumbnails and progress indicators; tap any to resume reading
- **Collections** — your KOReader collections displayed as tappable cover cards, right on the home screen
- **Reading Goals** — visual progress tracker for your annual and daily reading goals, including physical books read
- **Reading Stats** — compact stat cards showing today's reading time, pages, streaks, and all-time totals
- **Quick Actions** — up to 3 customisable rows of shortcut buttons (Library, History, Wi-Fi toggle, Brightness, Stats, and more)
- **New Books** — a row of up to 5 recently added books sorted by file date; unread books are labelled "New" and started books show their read percentage; opt-in via Arrange Modules
- **Quote of the Day** — optional literary header, randomly picked from a curated list of 100+ quotes; can also show your own highlights
- **Module ordering** — rearrange Home Screen modules in any order to match your workflow
- **Per-module scaling** — resize each module independently, or lock all scales together for uniform adjustments
- **Start with Home Screen** — set the Home Screen as the first screen KOReader opens every time you pick up your device

### Bottom Navigation Bar

A persistent tab bar at the bottom of the screen for one-tap navigation:

- Up to **5 fully customisable tabs**: Library, History, Collections, Favourites, Continue Reading, Home Screen, Wi-Fi Toggle, Brightness, Stats, Bookmark Browser, and custom folder or collection shortcuts
- **3 display modes**: icons only, text only, or icons + text
- **Navpager mode** — replaces the pagination bar with Prev/Next arrows at the edges of the bottom bar; arrows dim when there is no previous or next page
- **Hold anywhere on the bar** to instantly open navigation settings

### Top Status Bar

A slim status bar always visible at the top of the screen:

- Displays **clock, battery level, Wi-Fi status, frontlight brightness, disk usage, and RAM** all configurable
- Each item can be placed on the **left or right** side independently

### Custom Title Bar

A reworked title bar for the Library, History, Collections, and other full-screen views:

- **Back button** — replaces KOReader's default navigation with a cleaner chevron; hides automatically at the root folder, and also hides when the Library's *Lock Home Folder* setting is active and you are already at the home folder
- **Search button** — quick access to file search, compacts into the freed slot when the back button is hidden
- **Menu button** — opens the KOReader main menu
- **Page number in title** — shows "Page X of Y" in the subtitle when browsing multi-page views (enabled automatically by Navpager)
- **Button size** — three sizes (Compact, Default, Large) for the title bar buttons
- **Separate layouts** — Library buttons and sub-page buttons (History, Collections, etc.) can be configured independently

### Folder Covers

Custom cover art for folders in the Library mosaic view:

- Automatically uses the **first book cover** found inside a folder
- Supports a **`.cover.*` image file** placed manually in the folder for full control
- **Long-press any folder** and tap *Set folder cover…* to pick a specific book's cover as the folder's cover, only visible when Folder Covers is enabled
- Optional **folder name label** with configurable position (top, centre, bottom) and style (solid or transparent background)
- Optional **item count badge** with configurable position
- **Hide selection underline** for a cleaner look

### Quick Actions

Shortcut buttons configurable both on the Home Screen and in the bottom bar:

- Assign any action to a **custom folder**, **collection**, or **KOReader plugin**
- Quick **Wi-Fi toggle** and **frontlight control**
- **Power menu** (Restart, Quit) accessible as a tab
- **Bookmark Browser** — browse your highlights and bookmarks across all books

### Settings

All features are accessible via **Menu → Tools → SimpleUI**

---

## Installation

1. Download this repository as a ZIP — click **Code → Download ZIP**
2. Extract the folder and confirm it is named `simpleui.koplugin`
3. Copy the folder to the `plugins/` directory on your KOReader device
4. Restart KOReader
5. Go to **Menu → Tools → SimpleUI** to enable and configure the plugin

> **Tip:** After enabling the plugin, tap the **Home Screen** tab in the bottom bar to open your new home screen.

> **Tip:** To make the Home Screen your default start screen, go to **Menu → Tools → SimpleUI → Home Screen → Start with Home Screen**. From then on, KOReader opens directly to your home screen every time you turn on your device.

---

## 🌍 Translations

SimpleUI has full translation support. The UI language is detected automatically from your KOReader language setting — no configuration needed.

### Included languages

| Language | File | Status |
|---|---|---|
| English | *(built-in)* | Complete |
| Português (Portugal) | `locale/pt_PT.po` | Complete (100%) |
| Português (Brasil) | `locale/pt_BR.po` | Complete (100%) |
| Français (French) | `locale/fr.po` | Partial (93.5% — 22 missing) |
| Español | `locale/es.po` | Partial (84.4% — 53 missing) |
| Русский (Russian) | `locale/ru.po` | Partial (84.4% — 53 missing) |
| 简体中文 (Chinese Simplified) | `locale/zh_CN.po` | Partial (84.4% — 53 missing) |
| Türkçe (Turkish) | `locale/tr.po` | Partial (81.7% — 62 missing) |
| 繁體中文 (Chinese Traditional) | `locale/zh_TW.po` | Partial (81.7% — 62 missing) |
| Română (Romanian) | `locale/ro.po` | Partial (81.7% — 62 missing) |
| Deutsch (German) | `locale/de.po` | Partial (58.4% — 141 missing) |

### Adding a new language

All 339 strings in the plugin are translatable. To add a new language:

1. Copy `locale/simpleui.pot` to `locale/<lang>.po`, using the standard locale code for your language (examples: `de`, `fr`, `it`, `ja`)
2. Open the file in any text editor or a dedicated PO editor such as [Poedit](https://poedit.net/)
3. For each entry, fill in the `msgstr` field with your translation:

```po
msgid "Currently Reading"
msgstr "Aktuell gelesen"
```

4. Save the file inside the `locale/` folder — no code changes needed
5. Restart KOReader; the plugin picks up the new language automatically

The plugin first tries an exact match for the locale code (e.g. `pt_PT.po`), then falls back to the language prefix (e.g. `pt.po`), then falls back to English.

### Notes for translators

- Placeholders like `%d`, `%s`, and `%%` must be kept in your translation exactly as they appear in the `msgid` — you can reorder them if your language requires it, but not remove them
- `\n` is a line break — keep it in the same position
- Never modify the `msgid` line — only edit `msgstr`
- If a `msgstr` is left empty (`""`), the English original is shown as a fallback
- Submitting your translation as a Pull Request is very welcome — see [CONTRIBUTING.md](CONTRIBUTING.md)

---

## 🔧 Customising Quotes

To add, remove or edit the Quote of the Day pool, open `desktop_modules/quotes.lua` inside the plugin folder. Each entry follows this format:

```lua
{ q = "Quote text.", a = "Author Name", b = "Book Title (optional)" }
```

Changes take effect the next time the Home Screen is opened.

---

## Contributing

Contributions are welcome — bug fixes, new features, translations, and documentation improvements. See [CONTRIBUTING.md](CONTRIBUTING.md) for how to get started.

To report a bug, open an **Issue** and include your KOReader version and device model.

---

## 📄 License

MIT — see [LICENSE](LICENSE) for details.
