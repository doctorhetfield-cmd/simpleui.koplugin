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
3. Copy the folder to the `plugins/` directory on your KOReader device:
   * Kobo: `/.adds/koreader/plugins`
   * Kindle: `/koreader/plugins`
   * Android: `koreader/plugins` at the root of onboard storage.
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
| Português (Brasil) | `locale/pt_BR.po` | Partial (99.6% — 3 missing) |
| Português (Portugal) | `locale/pt_PT.po` | Partial (99.6% — 3 missing) |
| Polski (Polish) | `locale/pl.po` | Partial (98.7% — 11 missing) |
| Български (Bulgarian) | `locale/bg.po` | Partial (98.6% — 12 missing) |
| Magyar (Hungarian) | `locale/hu.po` | Partial (98.2% — 15 missing) |
| 简体中文 (Chinese Simplified) | `locale/zh_CN.po` | Partial (98.2% — 15 missing) ⚠️ |
| Русский (Russian) | `locale/ru.po` | Partial (98.1% — 16 missing) |
| Čeština (Czech) | `locale/cs.po` | Partial (97.7% — 19 missing) |
| 日本語 (Japanese) | `locale/ja.po` | Partial (97.7% — 19 missing) |
| Tiếng Việt (Vietnamese) | `locale/vi.po` | Partial (97.7% — 19 missing) ⚠️ |
| Español | `locale/es.po` | Partial (59.4% — 337 missing) |
| Türkçe (Turkish) | `locale/tr.po` | Partial (43.9% — 466 missing) |
| Deutsch (German) | `locale/de.po` | Partial (43.6% — 469 missing) |
| Français (French) | `locale/fr.po` | Partial (41.9% — 483 missing) ⚠️ |
| Română (Romanian) | `locale/ro.po` | Partial (39.7% — 501 missing) |
| Română (Moldova) | `locale/ro_MD.po` | Partial (39.7% — 501 missing) |
| Українська (Ukrainian) | `locale/uk.po` | Partial (38.9% — 508 missing) |
| Svenska (Swedish) | `locale/sv.po` | Partial (38.3% — 513 missing) |
| Italiano (Italian) | `locale/it_IT.po` | Partial (36.0% — 532 missing) ⚠️ |
| 繁體中文 (Chinese Traditional) | `locale/zh_TW.po` | Partial (35.5% — 536 missing) |

> ⚠️ These files contain syntax errors (unescaped quotes or literal line breaks inside strings) and currently fail to load in KOReader, even though most of their content is translated. Contributions to fix the offending lines are welcome.

### Adding a new language

All 831 strings in the plugin are translatable. To add a new language:

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

## 🔧 Customisation

### Custom Quote of the Day

You can supply your own quotes by placing a `.lua` file in the **custom quotes folder** on your device:

```
<KOReader settings dir>/simpleui/custom_quotes/
```

(`<KOReader settings dir>` is typically `/mnt/onboard/.adds/koreader/settings` on Kobo or `/mnt/us/koreader/settings` on Kindle.)

The file must return a table of entries in this format:

```lua
return {
    { q = "Quote text.", a = "Author Name", b = "Book Title (optional)" },
    { q = "Another quote.", a = "Another Author" },
}
```

Once the file is in place, go to **Menu → Tools → SimpleUI → Home Screen → Quote of the Day → Source → Custom** and select your file. Changes take effect the next time the Home Screen is opened.

The `custom_quotes/` folder is created automatically on first run and is never touched by plugin updates.

To add, remove or edit the **built-in** quote pool instead, open `desktop_modules/quotes.lua` inside the plugin folder and follow the same format.

### Custom Quick-Action Icons

You can use your own SVG icons for custom quick-action buttons. Place `.svg` files in the **custom icons folder**:

```
<KOReader settings dir>/simpleui/custom_icons/
```

They will appear in the icon picker when creating or editing a custom quick action (**Menu → Tools → SimpleUI → Quick Actions → Edit → Icon**).

The `custom_icons/` folder is created automatically on first run and is never touched by plugin updates.

---

### Icon Packs

An icon pack lets you replace multiple SimpleUI icons at once — titlebar buttons, pagination chevrons, navigation tab icons, touch-menu tab bar icons, and quick-action icons — with a single tap.

#### Where to place packs

```
<KOReader settings dir>/simpleui/sui_icons/packs/
```

A pack can be either:
- **A subfolder** containing icon files with the correct names (see below).
- **A `.zip` file** containing those same files, either flat or inside a single root folder.

You can place packs there manually, or use **Style → Icons → Icon Packs → Install pack from ZIP…** to browse to a `.zip` directly on your device.

The `packs/` folder is created automatically on first run and is never touched by plugin updates.

#### Applying a pack

Go to **Menu → Tools → SimpleUI → Style → Icons → Icon Packs** and tap the pack you want. Icons are applied immediately to the live UI — no restart needed.

Packs are **additive and partial**: only the slots covered by the pack are changed. Slots not included in a pack keep their current value (custom or default). To revert everything afterwards, use **Style → Icons → System Icons → Reset All System Icons**.

#### File-name conventions

Every file in the pack root must be an `.svg` or `.png`. The filename (without extension) determines which icon slot it fills:

**SimpleUI titlebar buttons**

| Filename | Description |
|----------|-------------|
| `sui_menu.svg` | Menu button (right side of titlebar) |
| `sui_search.svg` | Search button |
| `sui_back.svg` | Back / return button |

**Browse-by buttons (Library titlebar)**

| Filename | Description |
|----------|-------------|
| `sui_browse_normal.svg` | Browse button — default / all books view |
| `sui_browse_author.svg` | Browse button — by author |
| `sui_browse_series.svg` | Browse button — by series |
| `sui_browse_tags.svg` | Browse button — by tags |

**Native pagination chevrons**

| Filename | Description |
|----------|-------------|
| `sui_pager_prev.svg` | Previous page |
| `sui_pager_next.svg` | Next page |
| `sui_pager_first.svg` | First page |
| `sui_pager_last.svg` | Last page |

**Navpager arrows (Bottom Bar)**

| Filename | Description |
|----------|-------------|
| `sui_navpager_prev.svg` | Navpager previous arrow |
| `sui_navpager_next.svg` | Navpager next arrow |

**Quick-action icons** (prefix `sui_action_`)

| Filename | Description |
|----------|-------------|
| `sui_action_library.svg` | Library |
| `sui_action_homescreen.svg` | Home Screen |
| `sui_action_collections.svg` | Collections |
| `sui_action_history.svg` | History |
| `sui_action_continue.svg` | Continue Reading |
| `sui_action_random_document.svg` | Random |
| `sui_action_favorites.svg` | Favourites |
| `sui_action_bookmark_browser.svg` | Bookmark Browser |
| `sui_action_wifi_toggle.svg` | Wi-Fi toggle (On) |
| `sui_action_wifi_toggle_off.svg` | Wi-Fi toggle (Off) |
| `sui_action_frontlight.svg` | Brightness |
| `sui_action_night_mode.svg` | Night Mode |
| `sui_action_stats_calendar.svg` | Reading Stats |
| `sui_action_power.svg` | Power menu |
| `sui_action_settings.svg` | SimpleUI Settings |
| `sui_action_browse_authors.svg` | Browse by Author |
| `sui_action_browse_series.svg` | Browse by Series |
| `sui_action_browse_tags.svg` | Browse by Tags |

**Quick Actions Defaults**

| Filename | Description |
|----------|-------------|
| `sui_qa_folder.svg` | Default Quick Action icon (Folder) |
| `sui_qa_plugin.svg` | Default Quick Action icon (Plugin) |
| `sui_qa_system.svg` | Default Quick Action icon (System) |

**Folder Covers**

| Filename | Description |
|----------|-------------|
| `sui_fc_empty.svg` | Placeholder cover for empty folders |

**Touch menu tab bar** (native KOReader tabs + the SimpleUI-injected Quick Settings tab)

| Filename | Description |
|----------|-------------|
| `sui_tab_main.svg` | Tab: Menu |
| `sui_tab_setting.svg` | Tab: Settings |
| `sui_tab_tools.svg` | Tab: Tools |
| `sui_tab_search.svg` | Tab: Search |
| `sui_tab_fm_settings.svg` | Tab: File Browser Settings (File Manager only) |
| `sui_tab_navigation.svg` | Tab: Reader Navigation (Reader only) |
| `sui_tab_typeset.svg` | Tab: Reader Typeset (Reader only) |
| `sui_tab_filebrowser.svg` | Tab: Back to File Browser (Reader only) |
| `sui_tab_qs_panel.svg` | Tab: SimpleUI Quick Settings (injected tab) |

> **Tab bar icons only support `.svg`/`.png` image files — Nerd Font symbols are not available for this group.** These icons are rendered by KOReader's own native tab-bar widget, which only ever resolves an icon by looking up an image file by name; it has no code path for drawing a font glyph. Every other icon group in SimpleUI (titlebar, pagination, navpager, quick actions, etc.) is rendered by SimpleUI's own widgets and supports Nerd Font symbols normally — this limitation is specific to the tab bar. The "Nerd Font symbol…" option is hidden accordingly when picking a tab bar icon from **Style → Icons → System Icons → Tab Bar**.

Files with names that do not match any of the above are silently ignored.

#### Optional manifest (`pack.lua`)

A pack can include a `pack.lua` file in its root to provide metadata and override the default filename conventions:

```lua
return {
    name        = "Night Owl",          -- display name in the menu (default: folder name)
    author      = "your-name",
    version     = "1.0",
    description = "Dark, rounded icons",

    -- Optional: map a slot ID to an alternative filename inside the pack.
    -- Useful if you want filenames that differ from the convention above.
    map = {
        sui_menu    = "hamburger.svg",
        sui_pager_prev = "arrow-left.svg",
    },
}
```

If `pack.lua` is absent, the pack name shown in the menu is the folder name (or the zip stem).

#### Typical pack structure

```
NightOwl/                       ← pack name (or NightOwl.zip)
  pack.lua                      ← optional manifest
  sui_menu.svg
  sui_search.svg
  sui_back.svg
  sui_browse_normal.svg
  sui_browse_author.svg
  sui_browse_series.svg
  sui_browse_tags.svg
  sui_pager_prev.svg
  sui_pager_next.svg
  sui_pager_first.svg
  sui_pager_last.svg
  sui_navpager_prev.svg
  sui_navpager_next.svg
  sui_action_library.svg
  sui_action_collections.svg
  sui_action_history.svg
  sui_action_continue.svg
  sui_action_frontlight.svg
  sui_action_night_mode.svg
  sui_action_power.svg
  sui_action_settings.svg
```

All files are optional — a valid pack can contain as few as one icon.

#### Notes for pack authors

- Use `.svg` for best results; KOReader renders SVGs at any resolution. `.png` files work but may look blurry on high-DPI screens.
- Icon paths are stored as absolute paths in settings. If you move or rename the pack folder after applying it, the icons will break until you re-apply the pack. Zip-installed packs are extracted to `packs/` and are therefore stable.
- To share a pack, zip the folder (`NightOwl/`) and distribute the `.zip`.

---

## Contributing

Contributions are welcome — bug fixes, new features, translations, and documentation improvements. See [CONTRIBUTING.md](CONTRIBUTING.md) for how to get started.

To report a bug, open an **Issue** and include your KOReader version and device model.

---

## 📄 License

MIT — see [LICENSE](LICENSE) for details.
