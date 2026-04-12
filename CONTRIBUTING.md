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

### File structure

```
simpleui.koplugin/
├── main.lua                  — plugin entry point and lifecycle
├── config.lua                — constants, action catalogue, settings helpers
├── ui.lua                    — shared layout infrastructure
├── bottombar.lua             — bottom navigation bar
├── topbar.lua                — top status bar
├── homescreen.lua            — Home Screen widget
├── patches.lua               — KOReader monkey-patches
├── menu.lua                  — settings menu (lazy-loaded)
├── i18n.lua                  — translation loader
├── quotes.lua                — Quote of the Day database
├── desktop_modules/
│   ├── moduleregistry.lua    — module registry and ordering
│   ├── module_header.lua     — Header module (clock, date, quote)
│   ├── module_currently.lua  — Currently Reading module
│   ├── module_recent.lua     — Recent Books module
│   ├── module_collections.lua — Collections module
│   ├── module_reading_goals.lua — Reading Goals module
│   ├── module_reading_stats.lua — Reading Stats module
│   ├── module_quick_actions.lua — Quick Actions module
│   └── module_books_shared.lua  — shared helpers for book modules
└── locale/
    ├── simpleui.pot          — translation template (190 strings)
    ├── pt_PT.po              — Portuguese (Portugal)
    └── pt_BR.po              — Portuguese (Brazil)
```

---

## Pull Request checklist

Before submitting, please check:

- [ ] The change works on a real device or the KOReader emulator
- [ ] Any new UI strings are wrapped in `_()`
- [ ] New strings are added to `locale/simpleui.pot`
- [ ] The commit message clearly describes the change
- [ ] No debug logging or commented-out code is left in

---

Thank you for helping make SimpleUI better!
