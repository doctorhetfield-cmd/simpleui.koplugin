# Icon Packs

An icon pack lets you replace multiple SimpleUI icons at once — titlebar buttons, pagination chevrons, navigation tab icons, touch-menu tab bar icons, and quick-action icons — with a single tap.

## Where to place packs

```
<KOReader settings dir>/simpleui/sui_icons/packs/
```

A pack can be either:
- **A subfolder** containing icon files with the correct names (see below).
- **A `.zip` file** containing those same files, either flat or inside a single root folder.

You can place packs there manually, or use **Style → Icons → Icon Packs → Install pack from ZIP…** to browse to a `.zip` directly on your device.

The `packs/` folder is created automatically on first run and is never touched by plugin updates.

## Applying a pack

Open Simple UI's Settings and go to **Style → Icons → Icon Packs**, then tap the pack you want. Icons are applied immediately to the live UI — no restart needed.

Packs are **additive and partial**: only the slots covered by the pack are changed. Slots not included in a pack keep their current value (custom or default). To revert everything afterwards, use **Style → Icons → System Icons → Reset All System Icons**.

## File-name conventions

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
| `sui_qa_group.svg` | Default Quick Action icon (Group) |

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

## Optional manifest (`pack.lua`)

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

## Typical pack structure

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

## Notes for pack authors

- Use `.svg` for best results; KOReader renders SVGs at any resolution. `.png` files work but may look blurry on high-DPI screens.
- Icon paths are stored as absolute paths in settings. If you move or rename the pack folder after applying it, the icons will break until you re-apply the pack. Zip-installed packs are extracted to `packs/` and are therefore stable.
- To share a pack, zip the folder (`NightOwl/`) and distribute the `.zip`.

## Custom Icons Folder

The lightweight, single-icon alternative to a full pack. Place `.svg` files in:

```
<KOReader settings dir>/simpleui/custom_icons/
```

to make them available in the icon picker when creating or editing a custom Quick Action (**Quick Actions → Edit → Icon**). Like `packs/`, this folder is created automatically on first run and left untouched by updates. Use an Icon Pack when you want to restyle many icons at once with a shared identity; use this folder when you just want one specific icon for one specific action.

Back to the [README](../README.md).
