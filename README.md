# SimpleUI for KOReader

A clean, distraction-free UI plugin for KOReader. SimpleUI adds a **dedicated Home Screen**, a customisable Navigation Bar, a top status bar and a reworked library title bar, giving you instant access to your library, history, collections and reading stats without navigating through nested menus.

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Features](#features)
  - [Home Screen](#home-screen)
  - [Tiny Critter](#tiny-critter)
  - [Reading Stats & Streaks](#reading-stats--streaks)
  - [Library](#library)
  - [Navigation Bar](#navigation-bar)
  - [Top Status Bar](#top-status-bar)
  - [Quick Settings Bar](#quick-settings-bar)
  - [Custom Title Bar](#custom-title-bar)
  - [Quick Actions](#quick-actions)
  - [Style](#style)
  - [Settings](#settings)
  - [Backup & Restore](#backup--restore)
  - [Factory Reset](#factory-reset)
- [Translations](#translations)
- [Icon Packs](#icon-packs)
- [Contributing](#contributing)
- [License](#license)

<div style="display: flex; flex-direction: row; flex-wrap: wrap; gap: 10px; max-width: 1000px; justify-content: center;">
<img src="https://github.com/user-attachments/assets/4ea92760-c2bf-488b-9f5a-1f663157c97f" width="240" height="324" alt="simpleUI1" style="object-fit: contain;" />
<img src="https://github.com/user-attachments/assets/a1a7a2c7-6c0f-484e-b6fa-c78474661480" width="240" height="324" alt="simpleUI2" style="object-fit: contain;" />
<img src="https://github.com/user-attachments/assets/1707f5c2-e367-47b8-90a9-9a9549bd9e67" width="240" height="324" alt="simpleUI3" style="object-fit: contain;" />
<img src="https://github.com/user-attachments/assets/fd443a96-e12c-4dc7-9e69-103c444458af" width="240" height="324" alt="simpleUI4" style="object-fit: contain;" />
</div>

---

## Requirements

- **KOReader v2026.03 or newer.**
- The **CoverBrowser** plugin enabled (it ships with KOReader). Covers, mosaic views and library browsing depend on its book-info cache.
- Simple UI checks for plugins that conflict with it at startup and disables them automatically (it shows a message when it does). Restart KOReader when asked.

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


> **Updating:** Simple UI checks for new releases at most once a day (and on demand from **About → Check for Updates**). When one is available a banner appears at the top of the About menu; you can read the release notes and install it from there. Your settings and your own files (wallpapers, icons, quotes, critters) are never touched by an update.

---

## Features

### Home Screen

Build the screen you want from modules — Currently Reading, Recent and New Books, To Be Read, Cover Deck, Collections, Reading Goals, Reading Stats, Reading Heatmap, Tabbed Grid, Quick Actions, Quote of the Day, a Tiny Critter and more. Each module is a box you size and place freely on a grid of 6 columns, so modules sit side by side; you can split a screen into **several pages**, save **presets**, set a **wallpaper** and create extra **Custom Screens**.

See [docs/HOME_SCREEN.md](docs/HOME_SCREEN.md) for every module and the layout tools.

### Tiny Critter

A pixel-art companion that comments on your reading, remembers its mood, reacts to events (a finished book, a long session, low battery), offers daily challenges and suggests what to read next. Seven critters are bundled, and you can add your own critters, decorations and phrases. See [docs/CRITTER.md](docs/CRITTER.md).

### Reading Stats & Streaks

A grid of stat cards you compose yourself (Cards, Detailed Cards with charts, or List), plus the Reading Insights, Streak Manager (with freezes), Reading Heatmap and Finished Books windows. See [docs/STATS.md](docs/STATS.md).

### Library

Browse by author, series or tags, search the whole library by metadata, group series into one entry, and customise folder covers and cover badges. See [docs/LIBRARY.md](docs/LIBRARY.md).

### Navigation Bar

A persistent tab bar at the bottom of the screen for one-tap navigation:

- Up to **6 fully customisable tabs**: Library, History, Collections, Favourites, Continue Reading, Home Screen, Wi-Fi Toggle, Brightness, Stats, Bookmark Browser, Browse by Author/Series/Tags, and custom folder, collection or Custom Screen shortcuts
- **3 display modes**: icons only, text only, or icons + text
- **2 layouts**: Full-width and Floating, each with white or gray tone, optional frame and adjustable opacity
- **Adjustable bar size, icon size, and label size**
- **Navpager mode** — replaces the pagination bar with Prev/Next arrows at the edges of the Navigation Bar; arrows dim when there is no previous or next page
- **Hold anywhere on the bar** to instantly open navigation settings

### Top Status Bar

A slim status bar always visible at the top of the screen:

- Displays **clock, Wi-Fi status, Bluetooth, frontlight brightness, battery level, disk usage and RAM**, plus custom text — all configurable. Items the device cannot show (for example Bluetooth on a device without it) are not offered
- Each item can be placed on the **left, centre or right** of the bar independently; items in the centre replace the swipe indicator
- Adjustable bar size, with an optional swipe indicator

### Quick Settings Bar

An extra panel tab injected into KOReader's native touch menu, giving one-tap access to your favourite Quick Actions plus frontlight and warmth sliders without leaving your current screen:

- Configure which Quick Actions appear, and reorder them
- Optional **frontlight** and **warmth** sliders in the **Minimal** or **Classic** style, aligned with the button row, also available in the reader's Book layout
- **3 button types**: Round, Rounded Square, Bare, with adjustable label size and background

### Custom Title Bar

A reworked title bar for the Library, History, Collections, and other full-screen views:

- **Back button** — a cleaner chevron; hides automatically at the root folder, and also when the Library's *Lock Home Folder* setting is active and you are already at the home folder
- **Search button** — quick access to file search, compacts into the freed slot when the back button is hidden
- **Menu button** — opens the KOReader main menu
- **Page number in title** — shows "Page X of Y" in the subtitle when browsing multi-page views (enabled automatically by Navpager)
- **Button size** — Compact, Default or Large
- **Separate layouts** — Library buttons and sub-page buttons (History, Collections, etc.) can be configured independently

### Quick Actions

Shortcut buttons configurable on the Home Screen, the Navigation Bar, the Title Bar, and the Quick Settings Bar:

- Assign any action to a **custom folder**, **collection**, or **KOReader plugin**
- Quick **Wi-Fi toggle**, **frontlight control** and **Night Mode**
- **Night Mode** shows the mode a tap switches to: **Night Mode** (moon) by day, **Day Mode** (sun) at night; each state's icon can be replaced separately (see [Icon Packs](docs/ICON_PACKS.md))
- **Power menu** (Restart, Quit) accessible as a tab
- **Bookmark Browser** — browse your highlights and bookmarks across all books
- Every **Custom Screen** gets its own Quick Action automatically
- Icons can be a built-in image, a Nerd Font symbol, or your own custom icon file

### Style

- **Accent colour** (colour screens only) — **Style → Accent Color** sets the colour of active controls: slider fills, progress bars and rings, the heatmap, the active tab and selected segments. Black and white until you choose one; unchanged on monochrome screens. The picker works with the D-pad. Surfaces can also use a **secondary colour**, derived from the accent unless you pick one.
- **Fonts** — choose the font family of text elements. Inter and Geist Pixel are bundled.
- **Module labels** — classic or all-caps headings above modules.
- **Cover elements** — badges, folder name and book stack (see [docs/LIBRARY.md](docs/LIBRARY.md)).
- **Icons** — replace system and action icons one by one, or install an [icon pack](docs/ICON_PACKS.md). Icon presets save and restore your icon choices.
- **Night mode** and **portrait / landscape** are supported throughout; the UI also works with buttons only (no touch screen).

### Settings

All features are accessible from the **SUI Settings Window** — a full-screen, touch-friendly panel with sections for Home Screen, Bars, Library, Style, Quick Actions and About. Open it by tapping the **Settings** button (gear icon), which sits in the Navigation Bar and Quick Settings Bar by default and can also be bound to a Quick Action or gesture. Long-pressing most bars or modules jumps straight to their own settings.

### Backup & Restore

Export your entire SimpleUI configuration to a single portable `.sui` file and restore it on any device:

- **One-tap export** from *About → Backup & Restore*, or bind the **Backup** Quick Action to a bar or gesture
- Choose what to include: appearance/style, home screen layout, bars, library settings, quick actions, goals & streaks, wallpaper, custom quotes, custom critters, and custom icons (files included)
- Restore selectively — untick any category during import; preset libraries **merge** into yours (identical presets de-duplicate, conflicting ones are renamed `name (1)` instead of overwritten)
- Files live in `settings/simpleui/backups/` — copy them somewhere safe (e.g. over USB) before re-flashing firmware

### Factory Reset

Found under **About → Factory Reset**. This wipes every Simple UI setting — layout, bars, quick actions, presets, everything the plugin has saved — back to defaults, then restarts KOReader.

- **Asset files are untouched.** Wallpapers, custom icons, custom quote files and backups live as plain files under `settings/simpleui/`, so a Factory Reset never deletes them; only the configuration that pointed to them is cleared.
- **The Welcome Screen runs again**, exactly like a fresh install.
- **Export a Backup first** if you might want your current setup back — Factory Reset does not create one.

---

## Translations

SimpleUI has full translation support. The UI language follows your KOReader language setting — no configuration needed. English is built in; every other language is a `locale/<code>.po` file. Browse the [`locale/`](locale) folder for the languages available, and open a `.po` file in a PO editor such as [Poedit](https://poedit.net/) to see how complete it is. Coverage changes often as contributions come in, so it is not tracked here.

> ⚠️ A `.po` file with a syntax error (an unescaped quote or a literal line break inside a string) cannot be loaded by KOReader, so that language falls back to English. Run `msgfmt --statistics -o /dev/null locale/<code>.po` to check a file.

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

## Icon Packs

An icon pack replaces many SimpleUI icons at once — titlebar buttons, pagination chevrons, navigation tab icons, tab bar icons and quick-action icons. Install one from **Style → Icons → Icon Packs → Install pack from ZIP…**, or drop it into `<KOReader settings dir>/simpleui/sui_icons/packs/`. For a single icon, put an `.svg` in `<KOReader settings dir>/simpleui/custom_icons/` and pick it when editing a Quick Action.

File names, the optional `pack.lua` manifest and authoring notes are in [docs/ICON_PACKS.md](docs/ICON_PACKS.md).

---

## Contributing

Contributions are welcome — bug fixes, new features, translations, and documentation improvements. See [CONTRIBUTING.md](CONTRIBUTING.md) for how to get started.

To report a bug, open an **Issue** and include your KOReader version and device model.

---

## License

Copyright (c) 2026 doctorhetfield-cmd

Licensed under the GNU General Public License, version 3 or (at your option) any later version (GPL-3.0-or-later) — see [LICENSE](LICENSE) for details.
