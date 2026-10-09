# Contributing to SimpleUI

Thank you for your interest in contributing! There are several ways to help — fixing bugs, improving the code, adding a translation, or improving the documentation. All contributions are welcome.

---

## Ways to contribute

| Type | What it involves |
|---|---|
| 🐛 Bug report | Open an Issue describing what went wrong |
| 💡 Feature request | Open an Issue with your idea |
| 🌍 Translation | Add or improve a `.po` file in `locale/` |
| 🔧 Code | Fork, branch, change, and open a Pull Request |
| 📝 Documentation | Improve the README or add inline comments |

---

## Reporting a bug

Open an **Issue** and include:

- A clear description of what happened and what you expected
- Your **KOReader version** (visible in Menu → Help → About)
- Your **device model** (e.g. Kobo Libra 2, Kindle Paperwhite 5)
- The steps to reproduce the problem, if you can

If the bug causes a crash, the KOReader log (`crash.log` or `reader.log` in the KOReader folder) is very helpful.

---

## Suggesting a feature

Open an **Issue** describing the feature and why it would be useful. Screenshots or mockups are welcome if they help explain the idea.

---

## Contributing a translation

Translations live in the `locale/` folder as standard `.po` files. No programming knowledge is needed.

### Adding a new language

1. Copy `locale/simpleui.pot` to `locale/<lang>.po`, using the standard locale code for your language — for example `de.po`, `fr.po`, `es.po`, `it.po`, `zh_CN.po`, `ja.po`
2. Open the file in any text editor or a dedicated PO editor such as [Poedit](https://poedit.net/)
3. Fill in the header fields at the top of the file:

```po
"Language-Team: German\n"
"Language: de\n"
"Plural-Forms: nplurals=2; plural=(n != 1);\n"
```

4. For each entry, fill in the `msgstr` field with your translation:

```po
msgid "Currently Reading"
msgstr "Aktuell gelesen"

msgid "%d%% Read"
msgstr "%d%% gelesen"
```

5. Submit your file as a Pull Request (see below)

### Improving an existing translation

Open the existing `.po` file for your language, correct or complete the `msgstr` values, and submit a Pull Request.

### Translation guidelines

- **Never modify the `msgid`** — only edit `msgstr`
- **Keep placeholders intact**: `%d`, `%s`, `%%`, and `\n` must appear in `msgstr` exactly as they do in `msgid`. You may reorder them if your language requires it, but do not remove them
- **Leave `msgstr` empty** (`""`) for any string you are unsure about — the English original will be shown as a fallback
- If your language has different plural forms (e.g. Russian, Polish), set `Plural-Forms` in the header accordingly

---

## Contributing code

### Setup

SimpleUI is a standard KOReader plugin written in Lua. No build system or compilation step is required. The plugin runs directly from the source files.

To test changes:

1. Copy the plugin folder to the `plugins/` directory on your device or the KOReader emulator
2. Restart KOReader to reload the plugin

The [KOReader emulator](https://github.com/koreader/koreader/blob/master/doc/Building.md) is the fastest way to iterate without a physical device.

### Making a change

1. **Fork** this repository (click the Fork button at the top right of the GitHub page)
2. Create a new branch for your change:

```
git checkout -b fix/my-bug-description
```

3. Make your changes
4. If you added any new visible text (strings shown in the UI), wrap them with `_()`:

```lua
-- correct
UIManager:show(InfoMessage:new{ text = _("Something went wrong.") })

-- incorrect — not translatable
UIManager:show(InfoMessage:new{ text = "Something went wrong." })
```

5. If your change introduces new strings, add them to the translation template:
   - Run the extraction command below, or manually add entries to `locale/simpleui.pot`
   - Add the English text as `msgid` and leave `msgstr` as `""`
   - Update any existing `.po` files you are able to translate

6. Commit with a clear message that describes what changed and why:

```
git commit -m "Fix progress bar not updating after resume"
```

7. Push your branch and open a **Pull Request** against `main`

### Extracting translatable strings

If you have Python 3 available, you can regenerate `simpleui.pot` from the source files by running the extraction script from the plugin root:

```bash
python3 extract_strings.py
```

This script extracts both regular strings (`_()` and `_lc()`) and plural strings (`N_()` and `N_lc()`) with proper POT file formatting including file locations.

### Updating translation files

After regenerating `simpleui.pot`, update existing `.po` files to include new strings:

```bash
# Using gettext tools (if available)
msgmerge --update locale/<lang>.po locale/simpleui.pot
```

### Code style

- Follow the style of the surrounding code — indentation, spacing, and naming conventions are consistent throughout the plugin
- Keep functions focused; avoid adding logic to build/render functions that belongs in helpers
- Prefer `local` variables; avoid polluting the module-level scope
- If a string is shown to the user, it must be wrapped in `_()`
- Add a short comment when the reason for a decision is not obvious from the code
- All settings keys written to `G_reader_settings` must use either the `simpleui_` or `navbar_` prefix — never bare unprefixed keys
- Settings rows keep a static label; the current choice is shown only as the right-side value (`value_func`, plus `mandatory_func` for the native menu) — never concatenated into the label (`"Sort: Title"`). Use `Config.makeRadioSubmenuItem` for N-way choices; the convention is described in `engines/sui_window.lua`

### Patching KOReader classes

KOReader creates a plugin instance for each host UI (file manager and reader)
and recreates them whenever a book is opened or closed. Each instance runs
`Patches.installAll` and later `Patches.teardownAll`, in an order the plugin
does not control. Patches must be safe against repeated installs and
out-of-order teardowns, otherwise wrappers stack up and their effect grows
with every book opened (for example, layout insets applied once per wrapper).

Use the shared hook helpers in `infra/sui_patches.lua`:

| Helper | Purpose |
|---|---|
| `_acquireHooks(target, key, owner)` | Registers the plugin as a user. Returns a state to fill when hooks must be installed, `nil` when they already exist. |
| `_addHook(state, target, key, wrapped)` | Replaces `target[key]` and records the original. Returns the original. |
| `_trackHooks(state, entries)` | Records functions already assigned in place, as `{ target, key, orig }`. |
| `_releaseHooks(target, key, owner)` | Unregisters the plugin and restores the originals once no user is left. |

Rules:

1. Never assign to a class function without `_acquireHooks`. A plain
   `Class.fn = function ... end` runs once per instance.
2. Store hook state on the patched class, not on the plugin instance or in a
   module local; instances and modules are recreated, classes are not.
3. Release in `teardownAll` in the reverse order of installation. A wrapper is
   restored only while it is still the outermost one.
4. Inside wrappers, resolve the plugin through `_live_plugin`; the instance
   captured at install time may be stale.
5. Wrappers that change a temporary field must restore it, including on error
   (`pcall`, then restore, then re-raise).
6. Do not clear a shared guard flag from an instance that did not set it.

Checklist before merging a patch:

- Open and close a book several times: layout, margins and widgets must stay
  identical between cycles.
- Disable and re-enable the plugin: no wrapper may remain after disabling.
- Rotate the screen with the file manager and with the homescreen on top.

### User data directories

SimpleUI stores user-customisable files **outside the plugin folder** so they survive plugin updates. Do not place user files inside the plugin directory.

| Purpose | Path on device |
|---|---|
| Custom quick-action icons | `<KOReader settings dir>/simpleui/custom_icons/` |
| Custom quote files | `<KOReader settings dir>/simpleui/custom_quotes/` |

`<KOReader settings dir>` is the KOReader settings directory returned by `DataStorage:getSettingsDir()` — typically `/mnt/onboard/.adds/koreader/settings` on Kobo or `/mnt/us/koreader/settings` on Kindle.

On first run (and after each update) the plugin automatically creates these directories and migrates any files that were previously stored inside the plugin folder.

If you are adding a new feature that requires user-supplied files, always resolve the path via `DataStorage:getSettingsDir() .. "/simpleui/<your_subfolder>"` and create the directory in the `simpleui_userdata_migrated_v*` block in `main.lua`.

### Building a release ZIP

Run `make build` from inside the plugin folder. This produces `simpleui.koplugin.zip` in the parent directory.

The Makefile automatically excludes development-only files (README, LICENSE, Makefile itself, `.git`, etc.) and the contents of the user data directories (`icons/custom/` and `desktop_modules/custom_quotes/`) so that user files on a device are never overwritten by an update.

### File structure

```
simpleui.koplugin/
├── main.lua                  — plugin entry point, lifecycle, and user-data migration
├── sui_config.lua            — constants, action catalogue, settings helpers
├── sui_core.lua              — shared layout infrastructure
├── sui_bottombar.lua         — bottom navigation bar
├── sui_topbar.lua            — top status bar
├── sui_homescreen.lua        — Home Screen widget
├── sui_patches.lua           — KOReader monkey-patches
├── sui_menu.lua              — settings menu (lazy-loaded)
├── sui_i18n.lua              — translation loader
├── sui_quickactions.lua      — custom quick-action CRUD and icon picker
├── sui_titlebar.lua          — custom title bar
├── features/library/
│   ├── sui_foldercovers.lua    — folder cover settings + MosaicMenuItem/ListMenuItem paint patch
│   ├── sui_library_browse.lua  — virtual author/series/tags browser
│   ├── sui_series_grouping.lua — inline series grouping inside real folders
│   ├── sui_cover_widgets.lua   — pure cover/badge rendering (no settings, no patches)
│   ├── sui_filter_state.lua    — composable filter trail (author/series/tags)
│   ├── sui_virtual_path.lua    — virtual browse-path encode/decode
│   ├── sui_metadata_source.lua — SQL + Calibre metadata query layer (cached)
│   ├── sui_cover_overrides.lua — user-picked cover storage (shared)
│   ├── sui_group_actions.lua   — shared cover-picker / create-collection dialogs
│   └── sui_cover_finder.lua    — on-disk folder cover discovery
├── sui_updater.lua           — OTA update checker and installer
├── desktop_modules/
│   ├── moduleregistry.lua    — module registry and ordering
│   ├── module_currently.lua  — Currently Reading module
│   ├── module_recent.lua     — Recent Books module
│   ├── module_new_books.lua  — New Books module
│   ├── module_collections.lua — Collections module
│   ├── module_tbr.lua        — To Be Read module
│   ├── module_reading_goals.lua — Reading Goals module
│   ├── module_reading_stats.lua — Reading Stats module
│   ├── module_quick_actions.lua — Quick Actions module
│   ├── module_quote.lua      — Quote of the Day module
│   ├── module_clock.lua      — Clock module
│   ├── module_coverdeck.lua  — Cover Deck module
│   ├── module_books_shared.lua  — shared helpers for book modules
│   ├── module_stats_provider.lua — reading stats data provider
│   ├── module_action_list.lua — action list helpers
│   ├── quotes.lua            — built-in quote database
│   └── custom_quotes/        — placeholder only; user files live in DataStorage
├── icons/
│   ├── *.svg                 — built-in icons
│   └── custom/               — placeholder only; user files live in DataStorage
└── locale/
    ├── simpleui.pot          — translation template
    ├── pt_PT.po              — Portuguese (Portugal)
    ├── pt_BR.po              — Portuguese (Brazil)
    └── …                     — other language files
```

---

## Pull Request checklist

Before submitting, please check:

- [ ] The change works on a real device or the KOReader emulator
- [ ] Any new UI strings are wrapped in `_()`
- [ ] New strings are added to `locale/simpleui.pot`
- [ ] New `G_reader_settings` keys use the `simpleui_` or `navbar_` prefix
- [ ] Any new user files are stored in `DataStorage/simpleui/` (not inside the plugin folder)
- [ ] The commit message clearly describes the change
- [ ] No debug logging or commented-out code is left in

---

Thank you for helping make SimpleUI better!
