# Hide Menu Items

Hide tabs, submenus and items of KOReader's File Manager and Reader menus. Nothing is deleted and no KOReader file is touched: the entries are only left out when the menu opens.

## Where

**Style → Hide Menu Items**, with one list for the **File Manager** menu and one for the **Reader** menu. Both can be edited from anywhere; the menu of a context you have not opened yet is listed after you open it once.

- A checked entry is visible. Tap it to hide it.
- A submenu has a **Show this menu** row on top. Hiding a submenu hides everything inside it; its items are greyed out and cannot be changed until the submenu is shown again, and they keep their own state.
- **Show All Items** makes everything visible again in both menus.

Changes show up the next time the menu opens; no restart is needed.

## Protected entries

The Quick Settings tab and the menus that contain it cannot be hidden, and the menu always keeps at least one tab. The Simple UI entry can be hidden: keep another way to open its settings, such as a quick action.

## How it works

Entries are matched by the id KOReader gives each menu entry. Hidden ids are stored in `simpleui_menu_hidden_fm` and `simpleui_menu_hidden_reader`. Every time the menu is built or opened, a step in the shared menu hooks removes them from the tab table.

The full menu (ids and names) is saved to `settings/simpleui/menu_tree_fm.lua` and `menu_tree_reader.lua`, rewritten only when it changes. Entries generated on the fly inside a submenu have no id and cannot be hidden.

## Reset by hand

Use **Show All Items**, or delete the two settings above from `settings/simpleui/sui_settings.lua`.
