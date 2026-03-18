# SimpleUI for KOReader

A clean, distraction-free UI plugin for KOReader that transforms your reading experience. SimpleUI adds a **dedicated Home Screen**, a customisable bottom navigation bar, and a top status bar, giving you instant access to your library, history, collections, and reading stats without navigating through nested menus.

---

## Features

### Home Screen

The centrepiece of SimpleUI. A home screen that gives you everything at a glance:

- **Clock & Date** — a large, readable clock with full date display, always visible on your home screen
- **Currently Reading** — shows your active book with cover art, title, author, reading progress bar, percentage read, and estimated time left
- **Recent Books** — a row of up to 5 recent books with cover thumbnails and progress indicators; tap any to resume reading
- **Collections** — your KOReader collections displayed as tappable cards, right on the home screen
- **Reading Goals** — visual progress tracker for your annual and daily reading goals
- **Reading Stats** — compact stat cards showing your reading activity at a glance
- **Quick Actions** — up to 3 customisable rows of shortcut buttons (Library, History, Wi-Fi toggle, Brightness, Stats, and more)
- **Quote of the Day** — optional literary quote header, randomly picked from a curated list of 100+ quotes
- **Custom Header** — choose between clock, clock + date, a custom text label, or the Quote of the Day as your Home Screen header
- **Module ordering** — rearrange Home Screen modules in any order to match your workflow
- **Start with Home Screen** — set the Home Screen as the first screen KOReader opens, so it greets you every time you pick up your device

### Bottom Navigation Bar

A persistent tab bar at the bottom of the screen for one-tap navigation:

- Up to **5 fully customisable tabs**: Library, History, Collections, Favorites, Continue Reading, Home Screen, Wi-Fi Toggle, Brightness, Stats, and custom folder/collection shortcuts
- **3 display modes**: icons only, text only, or icons + text
- **Hold anywhere on the bar** to instantly open the navigation settings

### Top Status Bar

A slim status bar always visible at the top of the screen:

- Displays **clock, battery level, Wi-Fi status, frontlight brightness, disk usage, and RAM** — all configurable
- Each item can be placed on the **left or right** side independently

### Quick Actions

Shortcut buttons configurable both on the Home Screen and in the bottom bar:

- Assign any tab to a **custom folder**, **collection**, or **KOReader plugin action**
- Quick **Wi-Fi toggle** and **frontlight control** directly from the bar
- **Power menu** (Restart, Quit) accessible as a tab

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
| Português (Portugal) | `locale/pt_PT.po` | Complete |
| Português (Brasil) | `locale/pt_BR.po` | Complete |
| 简体中文 (Chinese) | `locale/zh_CN.po` | Complete |

### Adding a new language

All 190 visible strings in the plugin are translatable. To add a new language:

1. Copy `locale/simpleui.pot` to `locale/<lang>.po`, using the standard locale code for your language (examples: `de`, `fr`, `es`, `it`, `zh_CN`, `ja`)
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

To add, remove or edit the Quote of the Day pool, open `quotes.lua` inside the plugin folder. Each entry follows this format:

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
