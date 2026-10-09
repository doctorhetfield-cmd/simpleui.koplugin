# SimpleUI for KOReader

A clean, distraction-free UI plugin for KOReader that transforms your reading experience. SimpleUI adds a **dedicated Home Screen**, a customisable Navigation Bar, a top status bar, and a reworked library title bar, giving you instant access to your library, history, collections, and reading stats without navigating through nested menus.

## Table of Contents

- [Installation](#installation)
- [Features](#features)
  - [Home Screen](#home-screen)
  - [Custom Screens](#custom-screens)
  - [Navigation Bar](#navigation-bar)
  - [Top Status Bar](#top-status-bar)
  - [Quick Settings Bar](#quick-settings-bar)
  - [Custom Title Bar](#custom-title-bar)
  - [Folder Covers](#folder-covers)
  - [Reading Stats & Streaks](#reading-stats--streaks)
  - [Quick Actions](#quick-actions)
  - [Settings](#settings)
  - [Backup & Restore](#backup--restore)
  - [Factory Reset](#factory-reset)
- [Translations](#translations)
  - [Included languages](#included-languages)
  - [Adding a new language](#adding-a-new-language)
  - [Notes for translators](#notes-for-translators)
- [Icon Packs](#icon-packs)
  - [Where to place packs](#where-to-place-packs)
  - [Applying a pack](#applying-a-pack)
  - [File-name conventions](#file-name-conventions)
  - [Optional manifest (`pack.lua`)](#optional-manifest-packlua)
  - [Typical pack structure](#typical-pack-structure)
  - [Notes for pack authors](#notes-for-pack-authors)
  - [Custom Icons Folder](#custom-icons-folder)
- [Contributing](#contributing)
- [License](#license)

<div style="display: flex; flex-direction: row; flex-wrap: wrap; gap: 10px; max-width: 1000px; justify-content: center;">
<img src="https://github.com/user-attachments/assets/4ea92760-c2bf-488b-9f5a-1f663157c97f" width="240" height="324" alt="simpleUI1" style="object-fit: contain;" />
<img src="https://github.com/user-attachments/assets/a1a7a2c7-6c0f-484e-b6fa-c78474661480" width="240" height="324" alt="simpleUI2" style="object-fit: contain;" />
<img src="https://github.com/user-attachments/assets/1707f5c2-e367-47b8-90a9-9a9549bd9e67" width="240" height="324" alt="simpleUI3" style="object-fit: contain;" />
<img src="https://github.com/user-attachments/assets/fd443a96-e12c-4dc7-9e69-103c444458af" width="240" height="324" alt="simpleUI4" style="object-fit: contain;" />
</div>

---

## Installation

> **Install from the latest release, not from _Code → Download ZIP_.** The repository download extracts to a folder such as `simpleui.koplugin-main`, which KOReader does not recognise as this plugin. The release ZIP already contains a correctly named `simpleui.koplugin` folder.

1. Open the [latest release](https://github.com/doctorhetfield-cmd/simpleui.koplugin/releases/latest) page
2. Scroll down to **Assets** and click **`simpleui.koplugin.zip`** to download it (ignore *Source code (zip)* and *Source code (tar.gz)*)
3. Extract the ZIP on your computer. You should get a folder named exactly `simpleui.koplugin` with `main.lua` and `_meta.lua` directly inside. Some extraction tools add a wrapper folder with the same name (`simpleui.koplugin/simpleui.koplugin`); if that happens, copy the inner folder, the one that holds `main.lua`
4. Connect your device to your computer and copy the `simpleui.koplugin` folder to the `plugins/` directory of your KOReader installation:
   * Kobo: `/.adds/koreader/plugins`
   * Kindle: `/koreader/plugins`
   * Android: `koreader/plugins` at the root of onboard storage.
5. Restart KOReader — Simple UI enables itself automatically and, on this first launch only, walks you through a short **Welcome Screen** (pick a starter layout, a few quick tips) before landing on your new Home Screen
6. From there, tap the **Settings** button (gear icon) on the Navigation Bar any time to open the SUI Settings Window and configure the plugin further

> **Tip:** If the plugin does not appear after restarting, check that the folder is named exactly `simpleui.koplugin`, sits directly inside `plugins/`, and is not nested (`plugins/simpleui.koplugin/simpleui.koplugin`).

> **Tip:** If you skip or close the Welcome Screen, tap the **Home Screen** tab in the Navigation Bar to open your new home screen.

> **Tip:** "Start with Home Screen" is already on after the Welcome Screen finishes, so KOReader opens directly to your Home Screen every time you turn on your device. You can toggle it any time from the Settings button under **Home Screen → Behaviour → Start with Home Screen**.

---

## Features

### Home Screen

The centrepiece of SimpleUI. A home screen that gives you everything at a glance:

- **Clock & Date** — a large, readable clock with full date display, or your own custom text
- **Currently Reading** — your active book with cover art, title, author, progress bar, percentage read, and estimated time left
- **Recent Books** — a row of up to 5 recent books with cover thumbnails and progress indicators; tap any to resume reading
- **New Books** — a row of up to 5 recently added books sorted by file date; unread books are labelled "New" and started books show their read percentage; opt-in via Arrange Modules
- **To Be Read (TBR)** — a row of books you've marked as "to be read", backed by a real KOReader collection
- **Cover Deck** — your recent or TBR books as a horizontal cover-flow carousel
- **Flat Library** — a single grid of every book in your library, regardless of folder structure
- **Collections** — your KOReader collections displayed as tappable cover cards, with an **Auto** cover style that switches between a single cover and a 4-cover grid depending on collection size
- **Featured Collection** — like Collections, but focused on one collection at a time, shown as a row of covers; add multiple instances to feature more than one
- **Reading Goals** — visual progress tracker for your annual and daily reading goals, including physical books read
- **Reading Stats** — compact stat cards showing today's reading time, pages, streaks, and all-time totals, with full statistics windows and streak tracking behind them (see **Reading Stats & Streaks** below)
- **Quick Actions Row** — up to 3 customisable rows of shortcut buttons (Library, History, Wi-Fi toggle, Brightness, Stats, and more)
- **Action List** — the same shortcuts as Quick Actions, shown as a vertical app-launcher-style list instead of a row
- **Spacer** — a blank block to add breathing room between modules
- **Quote of the Day** — optional literary header, randomly picked from a curated list of 100+ quotes; can also show your own highlights. Supply your own pool by placing a `.lua` file in `<KOReader settings dir>/simpleui/sui_quotes/` (created automatically on first run, never touched by updates) returning a table of `{ q = "...", a = "Author", b = "Book (optional)" }` entries, then set **Source → Custom** on the module. Edit the built-in pool instead via `modules/quotes.lua` in the plugin folder.
- **Module ordering & per-module scaling** — rearrange Home Screen modules in any order, resize each independently, or lock all scales together for uniform adjustments
- **Wallpaper** — a background image for the Home Screen, with auto-rotate, stretch, and Night Mode inversion options
- **Presets** — save and load full Home Screen configurations (layout, scales, wallpaper) to switch between different looks
- **Start with Home Screen** — set the Home Screen as the first screen KOReader opens every time you pick up your device

### Custom Screens

Build extra Home-Screen-like pages of your own, each with an independent module layout, alongside your main Home Screen:

- **Create, rename, and delete** as many custom screens as you like
- Configure modules on each one exactly as on the main Home Screen (any module above can be used)
- Each Custom Screen gets its own **Quick Action** automatically, so it can be opened from the Navigation Bar, Quick Actions Row, or Quick Settings Bar, with its own icon

### Navigation Bar

A persistent tab bar at the bottom of the screen for one-tap navigation:

- Up to **5 fully customisable tabs**: Library, History, Collections, Favourites, Continue Reading, Home Screen, Wi-Fi Toggle, Brightness, Stats, Bookmark Browser, and custom folder, collection, or Custom Screen shortcuts
- **3 display modes**: icons only, text only, or icons + text
- **3 bar styles**: Default, Framed, Bare
- **Adjustable bar size, icon size, and label size**
- **Navpager mode** — replaces the pagination bar with Prev/Next arrows at the edges of the Navigation Bar; arrows dim when there is no previous or next page
- **Hold anywhere on the bar** to instantly open navigation settings

### Top Status Bar

A slim status bar always visible at the top of the screen:

- Displays **clock, battery level, Wi-Fi status, frontlight brightness, disk usage, and RAM**, plus custom text — all configurable
- Each item can be placed on the **left or right** side independently
- Adjustable bar size, with an optional swipe indicator

### Quick Settings Bar

An extra panel tab injected into KOReader's native touch menu, giving one-tap access to your favourite Quick Actions plus frontlight and warmth sliders without leaving your current screen:

- Configure which Quick Actions appear, and reorder them
- Optional **frontlight** and **warmth** sliders
- **3 button types**: Round, Rounded Square, Bare, with adjustable label size and background

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

### Reading Stats & Streaks

Beyond the compact Reading Stats module, SimpleUI adds dedicated statistics windows:

- **Reading Insights** — a year-by-year overview with a monthly chart and current/best day and week streaks
- **Streak Manager** — a calendar view of your reading activity, with a **freeze** mechanic: bank freezes automatically as you read, then spend one to cover a single missed day right after an active one, so a one-off gap doesn't reset your streak
- **Finished Books** — a list of every book you finished this year, with the date range you spent reading each one

### Quick Actions

Shortcut buttons configurable on the Home Screen, the Navigation Bar, the Title Bar, and the Quick Settings Bar:

- Assign any action to a **custom folder**, **collection**, or **KOReader plugin**
- Quick **Wi-Fi toggle** and **frontlight control**
- **Power menu** (Restart, Quit) accessible as a tab
- **Bookmark Browser** — browse your highlights and bookmarks across all books
- Every **Custom Screen** gets its own Quick Action automatically
- Icons can be a built-in image, a Nerd Font symbol, or your own custom icon file

### Settings

All features are accessible from the **SUI Settings Window** — a full-screen, touch-friendly panel with sections for Home Screen, Bars, Library, Style, Quick Actions, and About. Open it by tapping the **Settings** button (gear icon), which sits in the Navigation Bar and Quick Settings Bar by default and can also be bound to a Quick Action or gesture of your own. Long-pressing most bars or modules jumps straight to their own settings without going through the section list at all.

### Backup & Restore

Export your entire SimpleUI configuration to a single portable `.sui` file and restore it on any device:

- **One-tap export** from *About → Backup & Restore*, or bind the **Backup** Quick Action to a bar or gesture
- Choose what to include: appearance/style, home screen layout, bars, library settings, quick actions, goals & streaks, wallpaper, custom quotes, and custom icons (files included)
- Restore selectively — untick any category during import; preset libraries **merge** into yours (identical presets de-duplicate, conflicting ones are renamed `name (1)` instead of overwritten)
- Files live in `settings/simpleui/backups/` — copy them somewhere safe (e.g. over USB) before re-flashing firmware

### Factory Reset

Found under **About → Factory Reset**. This wipes every Simple UI setting — layout, bars, quick actions, presets library, everything the plugin has ever saved — back to defaults, then restarts KOReader.

- **Asset files are untouched.** Wallpapers, custom icons, custom quote files, and exported presets/backups live as plain files under `settings/simpleui/`, not as settings entries, so a Factory Reset never deletes them; only the configuration that pointed to them is cleared.
- **The Welcome Screen runs again.** Because the reset also clears the "onboarding seen" flag, the next restart boots straight back into the first-run Welcome Screen, exactly like a fresh install.
- **Export a Backup first** if you might want your current setup back afterwards — Factory Reset itself does not create one.

---

## Translations

SimpleUI has full translation support. The UI language is detected automatically from your KOReader language setting — no configuration needed.

### Included languages

English is built in. Beyond that, translation files exist for:

Bulgarian (`bg`), Czech (`cs`), German (`de`), Spanish (`es`), French (`fr`), Hungarian (`hu`), Italian (`it_IT`), Japanese (`ja`), Lithuanian (`lt_LT`), Polish (`pl`), Portuguese – Brazil (`pt_BR`), Portuguese – Portugal (`pt_PT`), Romanian (`ro`, `ro_MD`), Russian (`ru`), Swedish (`sv`), Turkish (`tr`), Ukrainian (`uk`), Vietnamese (`vi`), Chinese Simplified (`zh_CN`), Chinese Traditional (`zh_TW`) — each as `locale/<code>.po`.

Coverage varies by language and changes frequently as contributions come in, so we don't track exact percentages here — open a `.po` file or a PO editor such as [Poedit](https://poedit.net/) to see how complete a given language currently is.

> ⚠️ A `.po` file can contain syntax errors (an unescaped quote or a literal line break inside a string) that stop it from loading in KOReader, even though most of its content is translated. If a language you expect to see falls back to English, this is the most likely cause. Run `msgfmt --statistics -o /dev/null locale/<code>.po` to check a file for errors — contributions to fix the offending lines are welcome.

### Adding a new language

Every user-facing string in the plugin is translatable. To add a new language:

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

---

## Icon Packs

An icon pack lets you replace multiple SimpleUI icons at once — titlebar buttons, pagination chevrons, navigation tab icons, touch-menu tab bar icons, and quick-action icons — with a single tap.

### Where to place packs

```
<KOReader settings dir>/simpleui/sui_icons/packs/
```

A pack can be either:
- **A subfolder** containing icon files with the correct names (see below).
- **A `.zip` file** containing those same files, either flat or inside a single root folder.

You can place packs there manually, or use **Style → Icons → Icon Packs → Install pack from ZIP…** to browse to a `.zip` directly on your device.

The `packs/` folder is created automatically on first run and is never touched by plugin updates.

### Applying a pack

Open Simple UI's Settings and go to **Style → Icons → Icon Packs**, then tap the pack you want. Icons are applied immediately to the live UI — no restart needed.

Packs are **additive and partial**: only the slots covered by the pack are changed. Slots not included in a pack keep their current value (custom or default). To revert everything afterwards, use **Style → Icons → System Icons → Reset All System Icons**.

### File-name conventions

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

**Navpager arrows (Navigation Bar)**

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
| `sui_action_recent.svg` | Recent |
| `sui_action_continue.svg` | Continue Reading |
| `sui_action_random_document.svg` | Random |
| `sui_action_favorites.svg` | Favourites |
| `sui_action_bookmark_browser.svg` | Bookmark Browser |
| `sui_action_search_library.svg` | Search |
| `sui_action_wifi_toggle.svg` | Wi-Fi toggle |
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

### Optional manifest (`pack.lua`)

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

### Typical pack structure

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

### Notes for pack authors

- Use `.svg` for best results; KOReader renders SVGs at any resolution. `.png` files work but may look blurry on high-DPI screens.
- Icon paths are stored as absolute paths in settings. If you move or rename the pack folder after applying it, the icons will break until you re-apply the pack. Zip-installed packs are extracted to `packs/` and are therefore stable.
- To share a pack, zip the folder (`NightOwl/`) and distribute the `.zip`.

### Custom Icons Folder

The lightweight, single-icon alternative to a full pack. Place `.svg` files in:

```
<KOReader settings dir>/simpleui/custom_icons/
```

to make them available in the icon picker when creating or editing a custom Quick Action (**Quick Actions → Edit → Icon**). Like `packs/`, this folder is created automatically on first run and left untouched by updates. Use an Icon Pack when you want to restyle many icons at once with a shared identity; use this folder when you just want one specific icon for one specific action.

---

## Contributing

Contributions are welcome — bug fixes, new features, translations, and documentation improvements. See [CONTRIBUTING.md](CONTRIBUTING.md) for how to get started.

To report a bug, open an **Issue** and include your KOReader version and device model.

---

## License

MIT — see [LICENSE](LICENSE) for details.
