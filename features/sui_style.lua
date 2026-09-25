-- sui_style.lua — SimpleUI's shared style module.
--
-- Two independent responsibilities live in this file:
--
-- 1. Design tokens (COLOR, FS_*, FACE_*, ICON, BORDER_SZ, BADGE_*) — the
--    single source of truth every SimpleUI module draws its look from.
--    Change a value here, not at the call site.
--
-- 2. System icon overrides — lets the user replace individual KOReader/
--    SimpleUI icons (titlebar buttons, touch-menu tabs, pagination chevrons,
--    navpager arrows, the collections back button, folder-cover placeholder)
--    with their own SVG/PNG/Nerd-Font glyph. Overrides are stored in
--    SUISettings under "simpleui_sysicon_<slot_id>"; nil means "use default".
--
-- Icon override mechanics
-- ───────────────────────
-- Tab-bar icons: FileManagerMenu.onShowMenu and ReaderMenu.onShowMenu are
-- patched so every (re)open replaces tab icons with the user's choices
-- before TouchMenu is built. Matching uses `tab.id` (stamped by KOReader's
-- MenuSorter onto every tab entry) — NOT `tab.key`, which native tabs never
-- have. Patches are installed by installTabIconPatch()/
-- installReaderTabIconPatch() and removed on teardown.
--
-- Titlebar / search / back icons: sui_titlebar.lua calls
-- SUIStyle.getIcon(slot_id) when assigning image.file to each button, and
-- calls SUIStyle.applyIconToBtn() after building it so the override can be
-- swapped in without duplicating button-construction logic.
--
-- Public API
-- ──────────
--   Design tokens: SUIStyle.COLOR / .FS_* / .FACE_* / .ICON / .icon(name)
--
--   SUIStyle.SLOTS                        — ordered list of slot descriptors
--   SUIStyle.getIcon(id) / .setIcon(id, path) — read/write one override
--   SUIStyle.resetAll() / .performResetAllSystemIcons(plugin) — clear overrides
--   SUIStyle.applyTabIcons(fm_or_ui_or_table)  — push overrides into a live
--                                                 FM/Reader tab_item_table
--   SUIStyle.install/removeTabIconPatch()        — persistent FM-menu patch
--   SUIStyle.install/removeReaderTabIconPatch()  — persistent Reader-menu patch
--   SUIStyle.refreshLiveTabBars()          — reapply + repaint any open
--                                             FM/Reader tab bar right now
--   SUIStyle.makeMenuItems(plugin)         — sub_item_table for the settings menu
--   SUIStyle.sui_build_system_icons(...)   — native RowPage renderer for the same menu
--   SUIStyle.applyIconToBtn(id, btn)       — overwrite a live button's icon
--   SUIStyle.restoreDefaultIcon(btn, ...)  — revert a live button to its default
--   SUIStyle.applyPaginationIcons(widget)  — apply pg_icons overrides to a
--                                             Menu/FileChooser's chevron buttons
--   SUIStyle.applyCollBackIcon(widget)     — apply coll_back override to a
--                                             collections widget's back button
--
--   Fonts: SUIStyle.applyUIFont() / .makeFontMenuItems()
--   Icon packs: SUIStyle.getPacksDir() / .listPacks() / .installZip(path) /
--               .applyPack(path)

local SUISettings     = require("infra/sui_store")
local logger          = require("logger")
local _               = require("infra/sui_i18n").translate
local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local FrameContainer   = require("ui/widget/container/framecontainer")
local HorizontalGroup  = require("ui/widget/horizontalgroup")
local HorizontalSpan   = require("ui/widget/horizontalspan")
local Screen          = Device.screen

-- ---------------------------------------------------------------------------
-- Slot catalogue
-- ---------------------------------------------------------------------------
-- Each slot describes one configurable icon position.
--   id          key suffix for SUISettings ("simpleui_sysicon_<id>")
--   label       display name shown in the picker menu
--   group       "sui_titlebar" | "bm_icons"
--   default_ko  KOReader built-in name (used only as documentation / preview)
-- ---------------------------------------------------------------------------

local M = {}

M.SLOTS = {
    -- ── SimpleUI titlebar buttons ────────────────────────────────────────
    {
        id        = "sui_menu",
        label     = function() return _("Menu Button") end,
        group     = "sui_titlebar",
        default_ko = "appbar.menu",
    },
    {
        id        = "sui_search",
        label     = function() return _("Search Button") end,
        group     = "sui_titlebar",
        default_ko = "appbar.search",
    },
    {
        id        = "sui_back",
        label     = function() return _("Back Button") end,
        group     = "sui_titlebar",
        default_ko = "chevron.left",   -- matches the ICON_UP used at runtime
    },
    -- ── Browse Meta titlebar icons ───────────────────────────────────────
    -- These override the four icons used by the Browse button in the FM
    -- titlebar (normal/author/series/tags mode).
    {
        id        = "sui_browse_normal",
        label     = function() return _("Browse Button (default)") end,
        group     = "sui_browse_icons",
        default_ko = "icons/default.svg",
    },
    {
        id        = "sui_browse_author",
        label     = function() return _("Browse Button (author)") end,
        group     = "sui_browse_icons",
        default_ko = "icons/author.svg",
    },
    {
        id        = "sui_browse_series",
        label     = function() return _("Browse Button (series)") end,
        group     = "sui_browse_icons",
        default_ko = "icons/series.svg",
    },
    {
        id        = "sui_browse_tags",
        label     = function() return _("Browse Button (tags)") end,
        group     = "sui_browse_icons",
        default_ko = "icons/tags.svg",
    },
    -- ── Native pagination bar chevrons ───────────────────────────────────
    -- Override the four chevron Buttons in KOReader's native pagination row
    -- (page_info_{left,right,first,last}_chev).  Applied after every
    -- Menu:init / FileChooser:init via M.applyPaginationIcons().
    {
        id        = "sui_pager_prev",
        label     = function() return _("Pagination: Previous Page") end,
        group     = "sui_pager_icons",
        default_ko = "chevron.left",
    },
    {
        id        = "sui_pager_next",
        label     = function() return _("Pagination: Next Page") end,
        group     = "sui_pager_icons",
        default_ko = "chevron.right",
    },
    {
        id        = "sui_pager_first",
        label     = function() return _("Pagination: First Page") end,
        group     = "sui_pager_icons",
        default_ko = "chevron.first",
    },
    {
        id        = "sui_pager_last",
        label     = function() return _("Pagination: Last Page") end,
        group     = "sui_pager_icons",
        default_ko = "chevron.last",
    },
    -- ── Navpager arrows (bottom bar) ─────────────────────────────────────
    {
        id        = "sui_navpager_prev",
        label     = function() return _("Navpager: Previous") end,
        group     = "sui_navpager_icons",
        default_ko = "chevron.left",
    },
    {
        id        = "sui_navpager_next",
        label     = function() return _("Navpager: Next") end,
        group     = "sui_navpager_icons",
        default_ko = "chevron.right",
    },
    -- ── Collections back button ──────────────────────────────────────────
    -- Overrides the page_return_arrow ("appbar.back") in Collections /
    -- coll_list widgets.  Applied after Menu:init via M.applyCollBackIcon().
    {
        id        = "sui_coll_back",
        label     = function() return _("Collections: Back Button") end,
        group     = "sui_coll_icons",
        default_ko = "appbar.back",
    },
    -- ── Quick Actions Defaults ───────────────────────────────────────────
    {
        id        = "sui_qa_folder",
        label     = function() return _("Default: Folder") end,
        group     = "sui_qa_defaults",
        default_ko = "icons/custom.svg",
    },
    {
        id        = "sui_qa_plugin",
        label     = function() return _("Default: Plugin") end,
        group     = "sui_qa_defaults",
        default_ko = "icons/plugin.svg",
    },
    {
        id        = "sui_qa_system",
        label     = function() return _("Default: System") end,
        group     = "sui_qa_defaults",
        default_ko = "appbar.settings",
    },
    {
        id        = "sui_qa_group",
        label     = function() return _("Default: Group") end,
        group     = "sui_qa_defaults",
        default_ko = "icons/group.svg",
    },
    -- ── Folder Covers ────────────────────────────────────────────────────
    {
        id        = "sui_fc_empty",
        label     = function() return _("Folder Covers: Empty Folder") end,
        group     = "sui_fc_icons",
        default_ko = "icons/custom.svg",
    },
    -- ── Touch menu tab bar ───────────────────────────────────────────────
    -- Overrides the icons shown on the native KOReader touch-menu tabs
    -- (FileManager + Reader), plus the SimpleUI-injected Quick Settings tab.
    -- `tab_id` matches the `.id` field KOReader's MenuSorter stamps onto
    -- each tab entry (menu_items key), NOT `tab.key` (that field doesn't
    -- exist on native tabs). Applied live by M.applyTabIcons().
    {
        id         = "sui_tab_main",
        label      = function() return _("Tab: Menu") end,
        group      = "sui_tabbar_icons",
        tab_id     = "main",
        default_ko = "appbar.menu",
    },
    {
        id         = "sui_tab_setting",
        label      = function() return _("Tab: Settings") end,
        group      = "sui_tabbar_icons",
        tab_id     = "setting",
        default_ko = "appbar.settings",
    },
    {
        id         = "sui_tab_tools",
        label      = function() return _("Tab: Tools") end,
        group      = "sui_tabbar_icons",
        tab_id     = "tools",
        default_ko = "appbar.tools",
    },
    {
        id         = "sui_tab_search",
        label      = function() return _("Tab: Search") end,
        group      = "sui_tabbar_icons",
        tab_id     = "search",
        default_ko = "appbar.search",
    },
    {
        id         = "sui_tab_fm_settings",
        label      = function() return _("Tab: File Browser Settings") end,
        group      = "sui_tabbar_icons",
        tab_id     = "filemanager_settings",
        default_ko = "appbar.filebrowser",
    },
    {
        id         = "sui_tab_navigation",
        label      = function() return _("Tab: Reader Navigation") end,
        group      = "sui_tabbar_icons",
        tab_id     = "navigation",
        default_ko = "appbar.navigation",
    },
    {
        id         = "sui_tab_typeset",
        label      = function() return _("Tab: Reader Typeset") end,
        group      = "sui_tabbar_icons",
        tab_id     = "typeset",
        default_ko = "appbar.typeset",
    },
    {
        id         = "sui_tab_filebrowser",
        label      = function() return _("Tab: Back to File Browser") end,
        group      = "sui_tabbar_icons",
        tab_id     = "filebrowser",
        default_ko = "appbar.filebrowser",
    },
    {
        id         = "sui_tab_qs_panel",
        label      = function() return _("Tab: SimpleUI Quick Settings") end,
        group      = "sui_tabbar_icons",
        tab_id     = "_sui_qs_panel",
        default_ko = "simpleui_settings",
    },
}

-- Quick lookup by id.
local _SLOT_BY_ID = {}
for _, s in ipairs(M.SLOTS) do _SLOT_BY_ID[s.id] = s end

-- ---------------------------------------------------------------------------
-- Settings helpers
-- ---------------------------------------------------------------------------

local function _key(id) return "simpleui_sysicon_" .. id end

--- Returns the stored icon path for `id`, or nil if using the default.
function M.getIcon(id)
    local v = SUISettings:get(_key(id))
    return (type(v) == "string" and v ~= "") and v or nil
end

--- Saves `path` as the icon for `id`.  Pass nil to reset to default.
function M.setIcon(id, path)
    if type(path) == "string" and path ~= "" then
        SUISettings:set(_key(id), path)
    else
        SUISettings:del(_key(id))
    end
end

-- ---------------------------------------------------------------------------
-- Icon path guard
-- ---------------------------------------------------------------------------
-- SUPPORTED_ICON_EXTS: formats that imagewidget.lua can actually load.
-- SVG requires librsvg (available on most KOReader builds).
-- PNG is always safe (liblodepng is always present).
-- JPG/JPEG are supported but not recommended for icons (no transparency).
-- Exported (not local) so callers that need to *offer* the same set of
-- formats — e.g. engines/sui_asset_browser.lua's file filter in the
-- "Browse…" button of QA.showIconPicker — stay in sync with what this
-- validator actually accepts, instead of duplicating the literal set.
M.SUPPORTED_ICON_EXTS = { png = true, svg = true, jpg = true, jpeg = true }

--- Validates `path` as a loadable icon file.
--- Returns `path` when valid, `fallback` otherwise.
--- Also clears the stored setting for `slot_id` (when given) so a bad path
--- is not retried on the next startup.
---
--- @param path      string|any   candidate icon path
--- @param fallback  string|nil   path to return when `path` is invalid (nil = no icon)
--- @param slot_id   string|nil   SUISettings key suffix; when given, a bad path
---                               is deleted from settings so it is not retried.
--- @return string|nil
function M.safeIconPath(path, fallback, slot_id)
    -- Type check — nil/non-string means "no override", not an error.
    if type(path) ~= "string" or path == "" then
        return fallback
    end

    local Config = require("infra/sui_config")
    if Config.isNerdIcon(path) then
        return path
    end

    -- Extension check — fast, no I/O.
    local ext = path:match("%.([^.]+)$")
    if not ext or not M.SUPPORTED_ICON_EXTS[ext:lower()] then
        logger.warn("simpleui/style: unsupported icon format '" .. tostring(ext)
                    .. "' in path: " .. path)
        if slot_id then M.setIcon(slot_id, nil) end
        return fallback
    end

    -- Existence check — requires lfs; skip gracefully when unavailable.
    -- Note: _reqLFS() is defined later in this file (Lua forward-reference
    -- limitation), so we inline the pcall here instead of calling it.
    local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if lfs_ok and lfs then
        if lfs.attributes(path, "mode") ~= "file" then
            logger.warn("simpleui/style: icon file not found: " .. path)
            if slot_id then M.setIcon(slot_id, nil) end
            return fallback
        end
    else
        -- lfs unavailable: trust the extension check, warn once.
        logger.warn("simpleui/style: lfs unavailable, skipping existence check for: " .. path)
    end

    return path
end

--- Clears every system icon override.
function M.resetAll()
    for _, s in ipairs(M.SLOTS) do
        if s.group ~= "sui_qa_defaults" then
            SUISettings:del(_key(s.id))
        end
    end
end

--- Clears every system icon override and triggers all runtime updates.
function M.performResetAllSystemIcons(plugin)
    M.resetAll()
    
    local fm = package.loaded["apps/filemanager/filemanager"] and package.loaded["apps/filemanager/filemanager"].instance
    local ok_tb, TB = pcall(require, "screens/sui_titlebar")
    if ok_tb and TB then
        local UIManager = require("ui/uimanager")
        pcall(TB.reapplyAll, fm, UIManager._window_stack)
        if TB.refreshBrowseIcons and fm then TB.refreshBrowseIcons(fm) end
    end
    
    local UIManager = require("ui/uimanager")
    if fm and fm.file_chooser then pcall(M.applyPaginationIcons, fm.file_chooser) end
    if UIManager then
        for _, entry in ipairs(UIManager._window_stack or {}) do
            local w = entry.widget
            if w and w.page_info_left_chev then pcall(M.applyPaginationIcons, w) end
            if w and (w.name == "collections" or w.name == "coll_list") then pcall(M.applyCollBackIcon, w) end
        end
    end
    
    local ok_qa, QA2 = pcall(require, "features/sui_quickactions")
    if ok_qa and QA2 and QA2.invalidateCustomQACache then QA2.invalidateCustomQACache() end
    local ok_fc, FC = pcall(require, "features/library/sui_foldercovers")
    if ok_fc and FC and FC.invalidateCache then FC.invalidateCache() end
    pcall(M.refreshLiveTabBars)
    
    if fm and fm.file_chooser then
        fm._navbar_suppress_path_change = true
        fm.file_chooser:refreshPath()
        fm._navbar_suppress_path_change = nil
    end
    if plugin then plugin:_rebuildAllNavbars() end
    local ScreenEngine = package.loaded["engines/sui_screen_engine"]
    if ScreenEngine then ScreenEngine.refreshAllLiveImmediate(false) end
end

-- ---------------------------------------------------------------------------
-- Apply helpers — called by sui_titlebar.lua
-- ---------------------------------------------------------------------------

-- Points a button's render-tree slot at a new widget and keeps every place
-- that can reference the old one in sync:
--   • horizontal_group[2] — what IconButton actually paints.
--   • label_container[1]  — what a plain Button{icon=…} actually paints
--                            (pagination chevrons use this, not IconButton).
--   • dimen                — recomputed from the button's own w/h (not the
--                            new widget's natural size), since widgetInvert
--                            (flash_ui highlight) and IconButton:update() /
--                            initGesListener() both read it.
-- Setting btn[w_key] alone is not enough: the render tree still points at
-- the old widget until these slots are patched too.
local function _syncButtonRenderSlot(btn, w_key, new_w)
    btn[w_key] = new_w

    local hg = btn.horizontal_group
    if hg and hg[2] and type(hg[2]) == "table"
            and hg[2].paintTo and hg[2] ~= new_w then
        hg[2] = new_w
    end

    local lc = btn.label_container
    if lc and lc[1] and type(lc[1]) == "table"
            and lc[1].paintTo and lc[1] ~= new_w then
        lc[1] = new_w
    end

    local w_width  = btn.width  or new_w.width  or 0
    local w_height = btn.height or new_w.height or 0
    -- TextWidget only computes its size lazily inside paintTo — force it now.
    pcall(new_w.getSize, new_w)
    local Geom = require("ui/geometry")
    new_w.dimen = Geom:new{ x = 0, y = 0, w = w_width, h = w_height }

    if btn.dimen then
        btn.dimen.w = w_width  + (btn.padding_left  or 0) + (btn.padding_right  or 0)
        btn.dimen.h = w_height + (btn.padding_top   or 0) + (btn.padding_bottom or 0)
    end
end

--- Replaces image.file on a live button widget with the stored override for
--- `id`.  Does nothing when no override is set or the button has no image.
--- Returns true when an override was applied.
function M.applyIconToBtn(id, btn)
    local raw = M.getIcon(id)
    if not raw then return false end
    if not btn then return false end
    local path = M.safeIconPath(raw, nil, id)
    if not path then return false end
    
    local Config = require("infra/sui_config")
    local is_nerd = Config.isNerdIcon(path)

    local function applyToWidget(w_key)
        local w = btn[w_key]
        if not w then return end

        if is_nerd then
            local nerd_char = Config.nerdIconChar(path)
            local Font = require("ui/font")
            local TextWidget = require("ui/widget/textwidget")

            pcall(w.free, w)

            local w_width  = btn.width  or w.width
            local w_height = btn.height or w.height
            local font_size = math.floor(math.min(w_width, w_height) * 0.65)

            local new_w = TextWidget:new{
                text    = nerd_char,
                face    = Font:getFace(M.FACE_ICONS, font_size),
                fgcolor = btn.icon_color or require("ffi/blitbuffer").COLOR_BLACK,
                padding = 0,
            }
            new_w.width  = w_width
            new_w.height = w_height
            new_w.is_sui_wrapper = true

            local orig_paintTo = new_w.paintTo
            new_w.paintTo = function(self_w, bb, x, y)
                local sz = self_w:getSize()
                local ox = x + math.floor((w_width - sz.w) / 2)
                local oy = y + math.floor((w_height - sz.h) / 2)
                orig_paintTo(self_w, bb, ox, oy)
            end

            _syncButtonRenderSlot(btn, w_key, new_w)

            local bb_mod = package.loaded["screens/sui_bottombar"]
            if bb_mod and bb_mod.patchDimmedIcon then
                bb_mod.patchDimmedIcon(btn)
            end
        else
            if w.is_sui_wrapper then
                pcall(w.free, w)
                local IconWidget = require("ui/widget/iconwidget")
                local new_w = IconWidget:new{
                    file   = path,
                    width  = btn.width,
                    height = btn.height,
                }
                _syncButtonRenderSlot(btn, w_key, new_w)

                local bb_mod = package.loaded["screens/sui_bottombar"]
                if bb_mod and bb_mod.patchDimmedIcon then
                    bb_mod.patchDimmedIcon(btn)
                end
            else
                -- Mutate the existing widget in-place: object identity at
                -- horizontal_group[2] is preserved, no slot sync needed.
                w.icon = nil
                w.file = path
                pcall(w.free, w)
                pcall(w.init, w)
            end
        end
    end

    if btn.image then
        applyToWidget("image")
        return true
    elseif btn.label_widget then
        applyToWidget("label_widget")
        return true
    end

    return false
end

-- ---------------------------------------------------------------------------
-- Native Button icon replacement helper
-- ---------------------------------------------------------------------------
-- KOReader has two icon-button widget types with different internal structures:
--
--   • IconButton  → self.image is an IconWidget created in IconButton:init().
--                   We can swap the icon by setting .icon=nil / .file=path on
--                   that ImageWidget and calling :free() + :init().
--
--   • Button{icon=…} → self.label_widget is an IconWidget created inside
--                   Button:init() when self.text is nil.  There is NO self.image
--                   on a plain Button.  The label_widget must be patched the
--                   same way (nil the .icon, set .file) so IconWidget:init()
--                   skips the symbol-lookup branch and loads the file directly.
--                   Setting btn.icon to a file path and re-calling btn:init()
--                   does NOT work: Button:init() creates a fresh IconWidget with
--                   icon=<path> and IconWidget:init() treats that value as a
--                   symbolic name, fails the directory scan, and falls back to
--                   ICON_NOT_FOUND (the warning triangle).
--
-- Strategy:
--   1. If btn.image exists  → it's an IconButton  → patch btn.image directly.
--   2. If btn.label_widget exists → it's a Button → patch btn.label_widget.
--   Both cases: set .icon = nil, .file = path, then :free() + :init().
-- ---------------------------------------------------------------------------

-- Restores a native button's image widget to a default icon/file, intelligently
-- tearing down any SUI wrapper (like Nerd Fonts) that might be in its place.
function M.restoreDefaultIcon(btn, default_icon, default_file)
    if not btn then return end

    local function applyToWidget(w_key)
        local w = btn[w_key]
        if not w then return end
        if w.is_sui_wrapper then
            pcall(w.free, w)
            local IconWidget = require("ui/widget/iconwidget")
            local new_w = IconWidget:new{
                icon   = default_icon,
                file   = default_file,
                width  = btn.width,
                height = btn.height,
            }
            _syncButtonRenderSlot(btn, w_key, new_w)
        else
            -- Mutate in-place: object identity at horizontal_group[2] is
            -- preserved so no slot sync is needed.
            w.icon = default_icon
            if default_icon and default_icon ~= "" then
                w.file = nil
            else
                w.file = default_file
            end
            pcall(w.free, w)
            pcall(w.init, w)
        end
    end

    if btn.image then applyToWidget("image")
    elseif btn.label_widget then applyToWidget("label_widget")
    end
end

-- ---------------------------------------------------------------------------
-- Pagination chevron icon application  (pg_icons group)
-- ---------------------------------------------------------------------------

-- Slot-id → button field name on the widget.
local _PG_CHEV_FIELDS = {
    sui_pager_prev  = "page_info_left_chev",
    sui_pager_next  = "page_info_right_chev",
    sui_pager_first = "page_info_first_chev",
    sui_pager_last  = "page_info_last_chev",
}

--- Applies stored pg_icons overrides to the pagination buttons of `widget`.
--- `widget` may be a FileChooser or any Menu instance (Collections, History…).
--- Returns true when at least one override was applied.
function M.applyPaginationIcons(widget)
    if not widget then return false end
    local applied = false
    for id, field in pairs(_PG_CHEV_FIELDS) do
        local btn = widget[field]
        if btn then
            applied = M.applyIconToBtn(id, btn) or applied
        end
    end
    return applied
end

-- ---------------------------------------------------------------------------
-- Collections back-button icon application  (coll_icons group)
-- ---------------------------------------------------------------------------

--- Applies the stored coll_back override to the page_return_arrow of `widget`.
--- `widget` should be a collections or coll_list Menu instance.
--- Returns true when an override was applied.
function M.applyCollBackIcon(widget)
    if not widget then return false end
    local btn = widget.page_return_arrow
    if not btn then return false end
    return M.applyIconToBtn("sui_coll_back", btn)
end

-- ---------------------------------------------------------------------------
-- FM tab icon application
-- ---------------------------------------------------------------------------

-- Build a tab_id → slot_id map for fast lookup.
-- NOTE: KOReader's MenuSorter stamps `.id = order_id` onto every top-level
-- tab entry (see ui/menusorter.lua:sort()); native tabs never have a
-- `.key` field. The SimpleUI-injected Quick Settings tab is given an
-- explicit `.id = "_sui_qs_panel"` in sui_quicksettings_bar.lua so it can
-- be matched the same way.
local _TAB_ID_TO_SLOT = {}
for _, s in ipairs(M.SLOTS) do
    if s.tab_id then _TAB_ID_TO_SLOT[s.tab_id] = s.id end
end

-- ---------------------------------------------------------------------------
-- Tab-icon name registration
-- ---------------------------------------------------------------------------
-- Unlike every other icon slot in this file — which SimpleUI renders itself
-- via ImageWidget/IconWidget with `.file = path`, so any absolute/relative
-- path works — tab-bar icons are rendered by KOReader's OWN native widgets:
-- TouchMenu → TouchMenuBar → IconButton → IconWidget. IconButton
-- unconditionally does `IconWidget:new{ icon = self.icon }`, and
-- IconWidget:init() ALWAYS treats a non-file, non-image `.icon` as a bare
-- NAME to search for under ICONS_DIRS + {".svg",".png"} (see
-- ui/widget/iconwidget.lua) — it never accepts a literal file path.
-- Assigning a full custom path straight into `tab.icon` therefore always
-- resolves to icon-not-found.
--
-- The same trick sui_quicksettings_bar.lua already uses to make
-- "simpleui_settings" resolve applies here too: REGISTER the custom icon under
-- a stable bare name:
--   1. Copy the file to DataStorage/icons/<name>.<ext> (disk-based lookup;
--      ICONS_DIRS always searches the user icons dir first, so this alone
--      is enough, and survives restarts).
--   2. Also poke IconWidget's runtime ICONS_PATH cache so the change is
--      visible immediately, without waiting for a fresh process.
-- Only .svg/.png are supported here because those are the only two
-- extensions IconWidget's by-name search ever tries.
local _TAB_ICON_NAME_CACHE = {} -- slot_id -> { src = last-registered source path, name = registered name }

--- Registers `path` under a stable per-slot icon name so KOReader's native
--- tab-bar widgets (which only resolve `.icon` by name) can find it.
--- Returns the registered name, or nil if `path` can't be registered
--- (unsupported extension, nerd-font glyph ref, or I/O failure) — callers
--- should fall back to the slot's native default in that case.
function M.registerTabIconName(slot_id, path)
    if type(path) ~= "string" or path == "" then return nil end

    local ok_cfg, Config = pcall(require, "infra/sui_config")
    if ok_cfg and Config.isNerdIcon and Config.isNerdIcon(path) then
        -- Nerd-font glyph references aren't files; nothing to register.
        return nil
    end

    local ext = path:match("%.([^.]+)$")
    ext = ext and ext:lower()
    if ext ~= "svg" and ext ~= "png" then
        -- IconWidget's by-name search only ever tries .svg/.png — jpg/jpeg
        -- (allowed for every other icon slot) can never be found this way.
        logger.warn("simpleui/style: tab icons must be .svg or .png (got: "
                    .. tostring(ext) .. ") — falling back to default for " .. slot_id)
        return nil
    end

    local name = "simpleui_" .. slot_id
    local cached = _TAB_ICON_NAME_CACHE[slot_id]
    if cached and cached.src == path and cached.name == name then
        return name -- already registered for this exact source
    end

    local ok_ds, DataStorage = pcall(require, "datastorage")
    local ok_lfs, lfs        = pcall(require, "libs/libkoreader-lfs")
    local ok_fu, ffiutil     = pcall(require, "ffi/util")
    if not (ok_ds and ok_lfs and ok_fu) then return nil end

    local user_dir = DataStorage:getDataDir() .. "/icons"
    if lfs.attributes(user_dir, "mode") ~= "directory" then
        pcall(lfs.mkdir, user_dir)
    end
    local dst = user_dir .. "/" .. name .. "." .. ext

    -- Always (re)copy — the user may have picked a different source file
    -- for the same slot since the last time this ran.
    local copy_ok = pcall(ffiutil.copyFile, path, dst)
    if not copy_ok or lfs.attributes(dst, "mode") ~= "file" then
        logger.warn("simpleui/style: failed to register tab icon for " .. slot_id)
        return nil
    end

    -- Keep IconWidget's runtime name-cache in sync so the change applies
    -- immediately, without a restart (same approach as
    -- sui_quicksettings_bar.lua's icon-registration Layer 2).
    pcall(function()
        local iw = require("ui/widget/iconwidget")
        local iw_init = iw._simpleui_orig_init_for_scan or rawget(iw, "init")
        if type(iw_init) ~= "function" then return end
        for i = 1, 64 do
            local uname, uval = debug.getupvalue(iw_init, i)
            if uname == nil then break end
            if uname == "ICONS_PATH" and type(uval) == "table" then
                uval[name] = dst
                break
            end
        end
    end)

    _TAB_ICON_NAME_CACHE[slot_id] = { src = path, name = name }
    return name
end

--- Iterates the live tab_item_table of a FileManager or ReaderMenu instance
--- and resyncs every recognized tab's icon: the user's registered override
--- when one exists, or the slot's native default otherwise. Also accepts a
--- raw tab_item_table. Always resyncing (rather than only touching tabs
--- with an override) also fixes resets: a tab that previously had a custom
--- icon correctly reverts to its native icon once the override is cleared.
function M.applyTabIcons(fm_or_table)
    local tab_table
    if type(fm_or_table) == "table" then
        -- Could be a FM instance, a ReaderUI instance, or a raw table.
        if fm_or_table.file_manager_menu
           and fm_or_table.file_manager_menu.tab_item_table then
            tab_table = fm_or_table.file_manager_menu.tab_item_table
        elseif fm_or_table.menu
           and fm_or_table.menu.tab_item_table then
            -- ReaderUI instance (ReaderMenu is registered as ui.menu).
            tab_table = fm_or_table.menu.tab_item_table
        elseif fm_or_table.tab_item_table then
            -- FileManagerMenu or ReaderMenu instance passed directly.
            tab_table = fm_or_table.tab_item_table
        elseif fm_or_table[1] and fm_or_table[1].icon ~= nil then
            -- raw tab_item_table passed directly
            tab_table = fm_or_table
        end
    end
    if not tab_table then return end

    for _, tab in ipairs(tab_table) do
        local slot_id = tab.id and _TAB_ID_TO_SLOT[tab.id]
        if slot_id then
            local slot = _SLOT_BY_ID[slot_id]
            local raw  = M.getIcon(slot_id)
            if raw then
                local name = M.registerTabIconName(slot_id, raw)
                tab.icon = name or (slot and slot.default_ko) or tab.icon
            elseif slot and slot.default_ko then
                tab.icon = slot.default_ko
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Persistent tab-bar icon patches (FileManagerMenu + ReaderMenu)
-- ---------------------------------------------------------------------------
-- Both patches hook `onShowMenu` rather than `setUpdateItemTable`.
--
-- Why onShowMenu: FileManagerMenu/ReaderMenu:onShowMenu only calls
-- setUpdateItemTable() when `self.tab_item_table == nil` (build-once, cache
-- forever per instance). Patching onShowMenu instead of setUpdateItemTable
-- guarantees our override runs on *every* menu opening, and — critically —
-- runs it by forcing the table to be built (via a dynamic `menu_self:
-- setUpdateItemTable()` call, which resolves to whatever version is
-- currently installed, including sui_quicksettings_bar's own tab-injection
-- wrap) *before* delegating to the untouched native onShowMenu that
-- actually constructs the TouchMenu widget. This sidesteps any ordering
-- dependency between this patch and sui_quicksettings_bar's own patches:
-- by the time TouchMenu:new{} runs, every tab (native + injected) already
-- has its final icon.
--
-- The SimpleUI-injected Quick Settings tab (_sui_qs_panel) is additionally
-- kept in sync directly by QSBar.refreshPanelTabIcon() (see
-- sui_quicksettings_bar.lua), since that tab is a single shared table
-- object reused by reference in both FM and Reader — mutating its `.icon`
-- field once is sufficient and avoids relying on injection-vs-override
-- ordering altogether. applyTabIcons() below still matches it too, as a
-- harmless no-op confirmation once it's present in a given tab_item_table.

-- Descriptors for the two patch targets: module path, the plugin-instance
-- flag name (read/cleared by sui_patches.lua on teardown), and a log label.
local _TAB_PATCH_TARGETS = {
    fm = {
        module_path  = "apps/filemanager/filemanagermenu",
        plugin_flag  = "_sysicon_fmmenu_patched",
        log_label    = "FM",
    },
    reader = {
        module_path  = "apps/reader/modules/readermenu",
        plugin_flag  = "_sysicon_rdmenu_patched",
        log_label    = "Reader",
    },
}

-- installed[target] tracks whether _installTabPatch has already run for
-- that target, so repeated calls (e.g. on plugin re-init) are no-ops.
local _tab_patch_installed = { fm = false, reader = false }

local function _installTabPatch(target, plugin)
    if _tab_patch_installed[target] then return end
    local t = _TAB_PATCH_TARGETS[target]
    local Menu = package.loaded[t.module_path]
    if not Menu then
        local ok, m = pcall(require, t.module_path)
        Menu = ok and m or nil
    end
    if not Menu then return end
    if Menu._simpleui_sysicon_patched then return end

    local orig = Menu.onShowMenu
    Menu._simpleui_sysicon_orig    = orig
    Menu._simpleui_sysicon_patched = true
    if plugin then plugin[t.plugin_flag] = true end

    Menu.onShowMenu = function(menu_self, ...)
        if menu_self.tab_item_table == nil then
            menu_self:setUpdateItemTable()
        end
        if menu_self.tab_item_table then
            M.applyTabIcons(menu_self.tab_item_table)
        end
        return orig(menu_self, ...)
    end

    _tab_patch_installed[target] = true
    logger.dbg("simpleui/style: " .. t.log_label .. " tab icon patch installed")
end

local function _removeTabPatch(target)
    if not _tab_patch_installed[target] then return end
    local t = _TAB_PATCH_TARGETS[target]
    local Menu = package.loaded[t.module_path]
    if Menu and Menu._simpleui_sysicon_patched then
        Menu.onShowMenu                = Menu._simpleui_sysicon_orig
        Menu._simpleui_sysicon_orig    = nil
        Menu._simpleui_sysicon_patched = nil
    end
    _tab_patch_installed[target] = false
    logger.dbg("simpleui/style: " .. t.log_label .. " tab icon patch removed")
end

function M.installTabIconPatch(plugin)       _installTabPatch("fm", plugin) end
function M.removeTabIconPatch()              _removeTabPatch("fm") end
function M.installReaderTabIconPatch(plugin) _installTabPatch("reader", plugin) end
function M.removeReaderTabIconPatch()        _removeTabPatch("reader") end

-- ---------------------------------------------------------------------------
-- Live tab-bar icon refresh
-- ---------------------------------------------------------------------------
-- Pushes current overrides into any live FM/Reader tab bar and asks it to
-- redraw. Covers the (rare) case where the icon picker is used while a
-- touch menu with tabs is already on the window stack.

function M.refreshLiveTabBars()
    -- Keep the shared Quick Settings panel tab's icon in sync regardless
    -- of whether the quicksettings-bar feature itself is currently enabled.
    local ok_qs, QSBar = pcall(require, "screens/sui_quicksettings_bar")
    if ok_qs and QSBar and QSBar.refreshPanelTabIcon then
        pcall(QSBar.refreshPanelTabIcon)
    end

    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if not ok_ui then return end

    local fm = package.loaded["apps/filemanager/filemanager"]
    fm = fm and fm.instance
    if fm and fm.file_manager_menu and fm.file_manager_menu.tab_item_table then
        M.applyTabIcons(fm.file_manager_menu.tab_item_table)
    end

    for _, entry in ipairs(UIManager._window_stack or {}) do
        local w = entry.widget
        if w and w.tab_item_table then
            M.applyTabIcons(w.tab_item_table)
            UIManager:setDirty(w, "ui")
        end
    end
end

-- ---------------------------------------------------------------------------
-- Menu builder
-- ---------------------------------------------------------------------------

--- Returns the sub_item_table for Style ▸ Icons ▸ System Icons.
function M.makeMenuItems(plugin)
    local QA = require("features/sui_quickactions")

    -- Helper: get the current FM instance (may be nil).
    local function _fm()
        local FM = package.loaded["apps/filemanager/filemanager"]
        return FM and FM.instance
    end

    -- Helper: reapply titlebar icons to the live FM and all injected widgets.
    local function _reapplyTitlebar()
        local ok_tb, TB = pcall(require, "screens/sui_titlebar")
        if not ok_tb or not TB then return end
        local fm = _fm()
        local ok_ui, UIManager = pcall(require, "ui/uimanager")
        pcall(TB.reapplyAll, fm, ok_ui and UIManager._window_stack or nil)
    end

    -- Helper: reapply pagination icons on all live fullscreen menus and FM.
    local function _reapplyPaginationIcons()
        local ok_ui, UIManager = pcall(require, "ui/uimanager")
        if not ok_ui then return end

        -- Collect every widget that has pagination buttons and apply icons now.
        -- We must apply before nextTick so the widgets hold the new icon data
        -- when the deferred setDirty fires.
        local dirty_widgets = {}

        local fm = _fm()
        if fm and fm.file_chooser then
            if M.applyPaginationIcons(fm.file_chooser) then
                dirty_widgets[#dirty_widgets + 1] = fm.file_chooser
            end
        end

        -- Apply to any fullscreen menu currently on the stack (History, etc.).
        for _, entry in ipairs(UIManager._window_stack or {}) do
            local w = entry.widget
            if w and w.page_info_left_chev then
                if M.applyPaginationIcons(w) then
                    dirty_widgets[#dirty_widgets + 1] = w
                end
            end
        end

        if #dirty_widgets == 0 then return end

        -- Defer setDirty to the next tick so it runs *after* UIManager:close()
        -- has already finished its own _refresh() for the icon-picker dialog.
        -- Without this, the picker's close-repaint races with ours and the
        -- pagination bar may not reflect the new icon on screen.
        -- This is the same pattern used by sui_titlebar for deferred repaints.
        UIManager:nextTick(function()
            for _, w in ipairs(dirty_widgets) do
                UIManager:setDirty(w, "ui")
            end
        end)
    end

    -- Helper: reapply collections back icon on live collections widgets.
    local function _reapplyCollBackIcon()
        local ok_ui, UIManager = pcall(require, "ui/uimanager")
        if not ok_ui then return end
        for _, entry in ipairs(UIManager._window_stack or {}) do
            local w = entry.widget
            if w and (w.name == "collections" or w.name == "coll_list") then
                M.applyCollBackIcon(w)
            end
        end
    end

    -- Helper: after a change, reapply everything that is affected.
    local function _refresh(group)
        if group == "sui_titlebar" then
            _reapplyTitlebar()
        elseif group == "pg_icons" or group == "sui_pager_icons" then
            _reapplyPaginationIcons()
        elseif group == "coll_icons" then
            _reapplyCollBackIcon()
        elseif group == "sui_navpager_icons" then
            if plugin then plugin:_rebuildAllNavbars() end
        elseif group == "sui_qa_defaults" then
            local ok_qa, QA = pcall(require, "features/sui_quickactions")
            if ok_qa and QA.invalidateCustomQACache then QA.invalidateCustomQACache() end
            if plugin then plugin:_rebuildAllNavbars() end
            local ok_se, ScreenEngine = pcall(require, "engines/sui_screen_engine")
            if ok_se and ScreenEngine then ScreenEngine.refreshAllLiveImmediate(false) end
        elseif group == "sui_fc_icons" then
            local ok_fc, FC = pcall(require, "features/library/sui_foldercovers")
            if ok_fc and FC and FC.invalidateCache then FC.invalidateCache() end
            local fm = _fm()
            if fm and fm.file_chooser then
                fm._navbar_suppress_path_change = true
                fm.file_chooser:refreshPath()
                fm._navbar_suppress_path_change = nil
            end
        elseif group == "sui_tabbar_icons" then
            M.refreshLiveTabBars()
        end
    end

    -- ── One row per slot ─────────────────────────────────────────────────
    local function _makeRow(slot)
        return {
            text_func = function()
                local path = M.getIcon(slot.id)
                local label = type(slot.label) == "function" and slot.label() or slot.label
                if path then
                    return label .. "  \u{270E}"
                end
                return label
            end,
            keep_menu_open = true,
            callback = function()
                QA.showIconPicker(
                    M.getIcon(slot.id),
                    function(new_path)
                        -- Guard: validate format/existence before persisting.
                        -- nil = "reset to default", always valid.
                        if new_path == nil then
                            M.setIcon(slot.id, nil)
                            _refresh(slot.group)
                            return
                        end
                        local safe = M.safeIconPath(new_path, nil)
                        if safe then
                            M.setIcon(slot.id, safe)
                            _refresh(slot.group)
                        else
                            require("infra/sui_core").Notify.toast(_("Unsupported icon format.\nPlease use a PNG or SVG file."))
                        end
                    end,
                    type(slot.label) == "function" and slot.label() or slot.label,
                    plugin,
                    "_sysicon_picker_" .. slot.id,
                    true
                )
            end,
        }
    end

    -- ── Group the slots ───────────────────────────────────────────────────
    local items = {}

    -- Reset all item at the top.
    items[#items + 1] = {
        text           = _("Reset All System Icons"),
        keep_menu_open = true,
        callback       = function()
            M.performResetAllSystemIcons(plugin)
        end,
        separator      = true,
    }

    -- Appends one row per slot in `group_id`, in M.SLOTS order.
    local function _addGroupRows(group_id)
        for _, slot in ipairs(M.SLOTS) do
            if slot.group == group_id then
                items[#items + 1] = _makeRow(slot)
            end
        end
    end

    _addGroupRows("sui_titlebar")

    -- Browse icons additionally need the live browse button refreshed after
    -- a change, so wrap the row's callback instead of using _addGroupRows.
    for _, slot in ipairs(M.SLOTS) do
        if slot.group == "sui_browse_icons" then
            local row = _makeRow(slot)
            local orig_cb = row.callback
            row.callback = function()
                orig_cb()
                local ok_tb, TB = pcall(require, "screens/sui_titlebar")
                if ok_tb and TB and TB.refreshBrowseIcons then
                    TB.refreshBrowseIcons(_fm())
                end
            end
            items[#items + 1] = row
        end
    end

    _addGroupRows("sui_pager_icons")
    _addGroupRows("sui_navpager_icons")
    _addGroupRows("sui_fc_icons")
    _addGroupRows("sui_tabbar_icons")

    return items
end

function M.sui_build_system_icons(plugin, ctx_menu, ctx)
    local Device = require("device")
    local Screen = Device.screen
    local FrameContainer = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local ImageWidget = require("ui/widget/imagewidget")
    local TextWidget = require("ui/widget/textwidget")
    local IconWidget = require("ui/widget/iconwidget")
    local Font = require("ui/font")
    local Geom = require("ui/geometry")
    
    local btn_size = Screen:scaleBySize(36)
    local icon_size = math.floor(btn_size * 0.7)
    local border_sz = Screen:scaleBySize(1)
    
    local function makeIconPreview(icon_path, ko_native, fallback_label)
        local icon_widget
        local Config = require("infra/sui_config")
        local is_nerd = icon_path and Config.isNerdIcon(icon_path)
        
        if is_nerd then
            local nerd_char = Config.nerdIconChar(icon_path)
            if nerd_char then
                icon_widget = TextWidget:new{
                    text    = nerd_char,
                    face    = Font:getFace(M.FACE_ICONS, math.floor(icon_size * 0.8)),
                    fgcolor = M.COLOR.text_primary,
                    padding = 0,
                }
            end
        elseif icon_path then
            local safe_path = M.safeIconPath(icon_path, nil)
            if safe_path then
                local iw = ImageWidget:new{
                    file    = safe_path,
                    width   = icon_size,
                    height  = icon_size,
                    is_icon = true,
                    alpha   = true,
                }
                if pcall(function() iw:_render() end) then
                    icon_widget = iw
                else
                    iw:free()
                end
            end
        end
        
        if not icon_widget and ko_native then
            icon_widget = IconWidget:new{
                icon    = ko_native,
                width   = icon_size,
                height  = icon_size,
            }
        end

        if not icon_widget then
            icon_widget = TextWidget:new{
                text    = fallback_label and fallback_label:sub(1, 1):upper() or "?",
                face    = Font:getFace("cfont", math.floor(icon_size * 0.7)),
                fgcolor = M.COLOR.text_primary,
            }
        end
        
        return FrameContainer:new{
            dimen      = Geom:new{ w = btn_size, h = btn_size },
            radius     = Screen:scaleBySize(8),
            bordersize = border_sz,
            background = M.COLOR.surface,
            color      = M.COLOR.gray,
            padding    = 0,
            [1]        = CenterContainer:new{
                dimen = Geom:new{ w = btn_size - border_sz * 2, h = btn_size - border_sz * 2 },
                [1]   = icon_widget,
            }
        }
    end

    local function get_rows()
        local rows = {}
        local function addGroup(group_id, group_name)
            local added_title = false
            for _idx, slot in ipairs(M.SLOTS) do
                if slot.group == group_id then
                    if not added_title then
                        rows[#rows + 1] = {
                            text = group_name:upper(),
                            is_divider = true,
                            sui_build = function(ctx)
                                return require("engines/sui_window").SectionLabel{ text = group_name:upper(), inner_w = ctx.inner_w }
                            end
                        }
                        added_title = true
                    end
                    
                    local path = M.getIcon(slot.id)
                    local label = type(slot.label) == "function" and slot.label() or slot.label
                    
                    local effective_path = path
                    local ko_native = nil
                    if not effective_path then
                        if slot.default_ko and slot.default_ko:match("%.svg$") then
                            local _plugin_dir = require("infra/sui_paths").getPluginDirNoSlash()
                            local lfs = require("libs/libkoreader-lfs")
                            if lfs.attributes(_plugin_dir .. "/" .. slot.default_ko, "mode") == "file" then
                                effective_path = _plugin_dir .. "/" .. slot.default_ko
                            else
                                ko_native = slot.default_ko
                            end
                        elseif slot.default_ko then
                            ko_native = slot.default_ko
                        end
                    end
                    
                    rows[#rows + 1] = {
                        text = label .. (path and "  \u{270E}" or ""),
                        show_chevron = true,
                        right_widget = makeIconPreview(effective_path, ko_native, label),
                        on_hold = function() end,
                        on_tap = function()
                            local QA = require("features/sui_quickactions")
                            QA.showIconPicker(path, function(new_path)
                                local function _guardedSetIcon(ipath, on_valid)
                                    if ipath == nil then on_valid(nil); return end
                                    local safe = M.safeIconPath(ipath, nil)
                                    if not safe then
                                        require("infra/sui_core").Notify.toast(_("Unsupported icon format.\nPlease use a PNG or SVG file."))
                                        return
                                    end
                                    if slot.group == "sui_tabbar_icons" then
                                        local ext = safe:match("%.([^.]+)$")
                                        ext = ext and ext:lower()
                                        if ext ~= "svg" and ext ~= "png" then
                                            require("infra/sui_core").Notify.toast(_("Tab bar icons must be PNG or SVG."))
                                            return
                                        end
                                    end
                                    on_valid(safe)
                                end
                                _guardedSetIcon(new_path, function(safe_path)
                                    M.setIcon(slot.id, safe_path)
                                    QA.invalidateCustomQACache()
                                    plugin:_rebuildAllNavbars()
                                    if slot.group == "sui_tabbar_icons" then
                                        pcall(M.refreshLiveTabBars)
                                    end
                                    local ScreenEngine = package.loaded["engines/sui_screen_engine"]
                                    if ScreenEngine then ScreenEngine.refreshAllLiveImmediate(false) end
                                    -- Reapply titlebar icons and dirty the root widget so the
                                    -- titlebar repaints in the same paint cycle as the bottombar.
                                    -- Using setDirty on plugin.ui (the FM root) mirrors what
                                    -- _rebuildAllNavbars does — no tick scheduling needed because
                                    -- the SUIWindow is a child of this widget and is composited
                                    -- together with it by the UIManager.
                                    local ok_tb, TB = pcall(require, "screens/sui_titlebar")
                                    if ok_tb and TB then
                                        local ok_ui, UIManager = pcall(require, "ui/uimanager")
                                        pcall(TB.reapplyAll, plugin.ui,
                                              ok_ui and UIManager._window_stack or nil)
                                        if ok_ui and UIManager and plugin.ui then
                                            UIManager:setDirty(plugin.ui, "ui")
                                        end
                                    end
                                    ctx.repaint()
                                end)
                            end, label, plugin, "_sysicon_picker_" .. slot.id, slot.group ~= "sui_tabbar_icons")
                        end
                    }
                end
            end
        end

        addGroup("sui_titlebar", _("Title Bar"))
        addGroup("sui_browse_icons", _("Browse Icons"))
        addGroup("sui_pager_icons", _("Pagination Bar"))
        addGroup("sui_navpager_icons", _("Navpager"))
        addGroup("sui_fc_icons", _("Folder Covers"))
        addGroup("sui_tabbar_icons", _("Tab Bar"))
        return rows
    end
    
    ctx_menu.show_row_page({
        title = _("System Icons"),
        items_func = get_rows,
        footer_text = _("Reset All"),
        footer_icon = "update",
        footer_action = function(ctx2)
            local ConfirmBox = require("ui/widget/confirmbox")
            ctx_menu.UIManager:show(ConfirmBox:new{
                text = _("Reset all system icons to default?"),
                ok_text = _("Reset"),
                cancel_text = _("Cancel"),
                ok_callback = function()
                    M.performResetAllSystemIcons(plugin)
                    ctx2.repaint()
                end,
            })
        end,
    })
end

-- ---------------------------------------------------------------------------
-- SUI Typographic Scale
-- ---------------------------------------------------------------------------
-- Five semantic font-size levels used across all SimpleUI modules.
-- Change values only here — every module derives its sizes from these.
--
--  FS_TITLE    (22)  — primary title, placeholder, cover heading, dir label
--  FS_SUBTITLE (20)  — subtitle, author name, large numeric value
--  FS_BODY     (18)  — standard row text, quote body, section label
--  FS_DETAIL   (15)  — metadata, percentages, collection labels, stats label
--  FS_CAPTION  (12)  — minimum readable label, pagination xs, goal sub-label
--
--  Badge overlays (module_collections, sui_foldercovers) are calculated
--  proportionally to their container size and intentionally bypass this scale.
--
--  Modules that have their own user-controlled scale factor (topbar, bottombar)
--  multiply that factor on top, e.g.:
--      math.floor(SUIStyle.FS_TITLE * _getTopbarScale())
--
--  The Style ▸ Global Text Size setting (Config.getFontScalePct()) is NOT
--  applied here. It patches ui/font.lua's Font:getFace() directly (see
--  sui_patches.lua patchFontGetFace), so it scales every KOReader UI text
--  size — native menus/dialogs AND SimpleUI's own FS_* widgets alike —
--  from a single choke point. Baking it into FS_* here too would double
--  the scale for every SimpleUI-drawn string.
--
--  _FS_SCALE is reserved for a possible future *SimpleUI-only* density
--  knob, layered independently on top of the global Font:getFace scale.

local _FS_SCALE = 1.0

local function _fs(base)
    return math.max(8, math.floor(base * _FS_SCALE))
end

M.FS_TITLE    = _fs(22)
M.FS_SUBTITLE = _fs(20)
M.FS_BODY     = _fs(18)
M.FS_DETAIL   = _fs(15)
M.FS_CAPTION  = _fs(12)

-- ---------------------------------------------------------------------------
-- SUI Color Palette
-- ---------------------------------------------------------------------------
-- Semantic color tokens used across all SimpleUI modules. Change values only
-- here — every module derives its colors from this table.
-- Usage: fgcolor = SUIStyle.COLOR.text_dim
--
--  text_primary         — primary text, active icons/borders (black).
--  text_secondary       — secondary text (e.g. onboarding subtitles).
--  text_dim             — inactive/dim text or icons (e.g. opts.dim
--                         variants, chart axis labels).
--  surface              — solid light background / "eraser" fill.
--  surface_flat         — flat dark background (flat-style cards, bars).
--  gray                 — medium-weight gray: card and frame borders, the
--                         bottom bar separator, the book cover spine/edge
--                         line, accent borders on active controls (progress
--                         bar fg, focused buttons/icons), and muted chart bars.
--  gray_strong          — darker gray: menu and list separator lines, light
--                         circular fills, the placeholder background behind
--                         book covers, and muted icon fills.
--  gray_soft            — lighter gray, used where gray_strong would be too
--                         heavy (e.g. onboarding, cover widgets) — also the
--                         border color for library/book-grid badges.
--  track                — progress bar / badge track background.
--  disabled             — disabled control/icon state.
--  debug                — debug-only visual overlays.
M.COLOR = {
    text_primary         = Blitbuffer.COLOR_BLACK,
    text_secondary       = Blitbuffer.COLOR_DARK_GRAY,
    text_dim             = Blitbuffer.gray(0.45),
    surface              = Blitbuffer.COLOR_WHITE,
    surface_flat         = Blitbuffer.gray(0.08),
    gray                 = Blitbuffer.gray(0.72),
    gray_strong          = Blitbuffer.gray(0.85),
    gray_soft            = Blitbuffer.gray(0.33),
    track                = Blitbuffer.gray(0.15),
    disabled             = Blitbuffer.gray(0.25),
    debug                = Blitbuffer.COLOR_RED,
}

-- Global border thickness for all frames and elements
M.BORDER_SZ   = math.max(1, Screen:scaleBySize(1))

-- ---------------------------------------------------------------------------
-- computeBox(show_frame, solid_bg, scale, pad) — style and sizing for the
-- optional Frame/Background box offered by every homescreen card that has
-- one.
--
-- `outer_margin` keeps the box's own visible edge — border and/or solid
-- background — aligned with sectionLabel's own left/right text inset
-- (engines/sui_screen_engine.lua), instead of flush against the module's
-- true outer edges. `inner_pad` is the breathing room between that edge
-- and the content, reserved only while the box is actually shown; with no
-- frame and no background there's nothing to leave room between, so
-- content sits directly at outer_margin, matching the label above it.
--
-- inset_h always reserves outer_margin on both sides — the label's own
-- inset is unconditional too, so this keeps content aligned with it
-- whether or not the box is currently shown. inset_v has no outer_margin
-- term: there's no label edge to align against vertically.
-- ---------------------------------------------------------------------------
function M.computeBox(show_frame, solid_bg, scale, pad, backdrop_strength)
    -- backdrop_strength 0–100: 0 transparent, 1–99 scrim, 100 solid.
    -- solid_bg remains supported: true ≡ strength 100.
    local strength = require("features/sui_wallpaper").clampBackdropStrength(backdrop_strength)
    if strength == nil then
        strength = solid_bg and 100 or 0
    end
    local opaque    = strength >= 100
    local has_scrim = strength > 0 and strength < 100
    local has_box   = show_frame or opaque or has_scrim
    local border_sz = show_frame and M.BORDER_SZ or 0
    local inner_pad = has_box and pad or 0
    return {
        has_box           = has_box,
        border_sz         = border_sz,
        radius            = has_box and math.floor(Screen:scaleBySize(12) * (scale or 1)) or 0,
        border_color      = M.COLOR.gray,
        bg_color          = opaque and M.COLOR.surface or nil,
        backdrop_strength = strength,
        -- Outer margin is applied by module chrome (single source of truth
        -- for label alignment). computeBox only contributes inner pad/border.
        outer_margin      = 0,
        inner_pad         = inner_pad,
        inset_h = inner_pad * 2 + border_sz * 2,
        inset_v = inner_pad * 2 + border_sz * 2,
    }
end

-- ---------------------------------------------------------------------------
-- wrapBox(content, box) — wraps `content` (already sized to fit within
-- box.inset_h/inset_v less than the module's own w) in the optional Frame/
-- Background box computed by computeBox(). The box's own edge sits inset
-- by box.outer_margin on the left and right, so it lines up with
-- sectionLabel's text above it instead of extending past it to the
-- column's true edges. The returned widget's total width is exactly the
-- w originally passed to computeBox.
-- ---------------------------------------------------------------------------
function M.wrapBox(content, box)
    local inner = FrameContainer:new{
        bordersize     = box.border_sz,
        radius         = box.radius,
        color          = box.border_color,
        background     = box.bg_color,
        padding        = box.inner_pad,
        padding_top    = box.has_box and box.inner_pad or 0,
        padding_bottom = box.has_box and box.inner_pad or 0,
        content,
    }
    -- Scrim / solid module backdrop is painted by the homescreen module
    -- wrapper (screen engine) so every module type shares one path.
    if box.outer_margin <= 0 then return inner end
    return HorizontalGroup:new{
        align = "top",
        HorizontalSpan:new{ width = box.outer_margin },
        inner,
        HorizontalSpan:new{ width = box.outer_margin },
    }
end

-- Thinner border and specific color for library badges and book covers
M.BADGE_BORDER_SZ  = require("ui/size").border.thin
M.BADGE_BORDER_CLR = M.COLOR.gray_soft

-- Global size trim applied on top of every corner-badge scale (progress
-- pentagon, pages, series index, new book) — both the Library grid's own
-- badges (features/library/sui_foldercovers.lua's M.getBadgeScale) and the
-- book-grid modules' badges (engines/sui_book_grid.lua's
-- GridRenderer.getBadgeScale). Baked in here, instead of into either
-- badge-scale setting's default value, so the user-facing "100%" in both
-- the Library "Badge Size" and the Home Screen "Badge Size" spinners keeps
-- meaning "this control's own baseline" — the baseline itself is just 10%
-- smaller everywhere than it used to be. Not applied to module_collections.lua's
-- own count badge, which isn't part of this shared four-badge family.
M.BADGE_SIZE_ADJUST = 0.9

-- ---------------------------------------------------------------------------
-- SUI Font Face Aliases
-- ---------------------------------------------------------------------------
-- Semantic font-face tokens used across all SimpleUI modules.
-- These are KOReader fontmap alias names passed to Font:getFace().
-- They select the font *file*; the size always comes from FS_* above.
-- Change values only here — every module derives its font faces from these.
--
--  FACE_REGULAR  — NotoSans-Regular: prose, labels, metadata, all general UI text.
--
--  FACE_BOLD     — NotoSans-Bold: emphasis, titles that need weight.
--                  Use sparingly; most titles use FACE_REGULAR + bold=true.
--
--  FACE_MONO     — DroidSansMono: counters, numeric badges, file counts,
--                  any value where fixed-width spacing matters.
--  FACE_ICONS    — nerdfonts/symbols.ttf: glyph / icon codepoints (U+E000…).
--
-- NOTE: When the UI Font picker (_applyFont) rewrites Font.fontmap, it updates
-- the KO slot names directly (e.g. "cfont", "tfont"). Because FACE_REGULAR and
-- FACE_BOLD point to those same slots, all SUI widgets automatically inherit
-- the user's chosen font with no extra work.

M.FACE_REGULAR = "cfont"
M.FACE_BOLD    = "tfont"
M.FACE_MONO    = "infont"
M.FACE_ICONS   = "symbols"

-- ---------------------------------------------------------------------------
-- SUI Icon Glyphs (Nerd Fonts / Material Symbols codepoints)
-- ---------------------------------------------------------------------------
-- Centralizes all glyphs used in the UI to eliminate Unicode scattered
-- around. Usage: text = SUIStyle.icon("chevron")  →  "\u{E8CC}"
-- Never use the codepoints directly in code — always use SUIStyle.icon().
--
-- Categories:
--   Navigation — chevron, back, more
--   Actions    — check, uncheck, delete, edit, add, drag
--   State      — goal, stats

M.ICON = {
    -- Navigation
    chevron  = "\u{F105}",   -- nf-fa-angle_right
    back     = "\u{E5C4}",   -- arrow_back
    more     = "\u{E8D7}",   -- more_horiz / three dots (the card's "…" button)

    -- Actions
    check    = "\u{E832}",   -- check_box (checked)
    uncheck  = "\u{E82F}",   -- check_box_outline_blank
    delete   = "\u{F014}",   -- trash / delete (NerdFonts)
    edit     = "\u{F040}",   -- pencil / edit (NerdFonts)
    add      = "\u{E145}",   -- add / plus
    drag     = "\u{E25D}",   -- drag_handle
    arrow_up   = "\u{E75C}", -- arrow up (NerdFonts)
    arrow_down = "\u{E744}", -- arrow down (NerdFonts)
    move_page  = "\u{F0EC}", -- exchange / move
    update     = "\u{E769}", -- update / sync
    hide       = "\u{E908}", -- eye-off / hide (NerdFonts)
    show       = "\u{E907}", -- eye / show (NerdFonts)

    -- State / Content
    goal     = "\u{E153}",   -- flag (reading goals)
    stats    = "\u{E24B}",   -- bar_chart
    clock    = "\u{E385}",
    page     = "\u{F40E}",
    book     = "\u{F401}",
    calendar = "\u{F490}",
    trophy   = "\u{EC3B}",
    highlights = "\u{EE6B}",
    notes    = "\u{EAEC}",
    arrow_right = "\u{F178}",
}

--- Returns the icon glyph named `name`, or "" if it doesn't exist.
--- Usage: TextWidget:new{ text = SUIStyle.icon("chevron"), face = ... }
---
--- @param name string  key into M.ICON
--- @return string
function M.icon(name)
    return M.ICON[name] or ""
end

-- ---------------------------------------------------------------------------
-- UI Font face picker
-- ---------------------------------------------------------------------------
-- Allows the user to replace KOReader's built-in UI font with any font
-- installed on the system.
--
-- Settings keys (all via SUISettings):
--   simpleui_ui_font_name     string   — selected font family name
--   simpleui_ui_font_enabled  bool     — true = custom font active
--
-- The font path is resolved at apply-time via cre.getFontFaceFilenameAndFaceIndex
-- so the setting stores the human-readable family name, not a raw file path.
--
-- Public API:
--   M.applyUIFont()          — restore saved font (called from main.lua init)
--   M.makeFontMenuItems()    — returns sub_item_table for Style ▸ UI Font
-- ---------------------------------------------------------------------------

-- Settings keys
local _FONT_KEY_NAME    = "simpleui_ui_font_name"
local _FONT_KEY_ENABLED = "simpleui_ui_font_enabled"
local _FONT_DEFAULT     = "Noto Sans"

-- Module-level lazy caches — populated once by _initFonts().
local _font_list     = nil   -- ordered list of font family names (strings)
local _fonts         = nil   -- map: family name → { regular=path, bold=path }
local _replaced      = nil   -- map: Font.fontmap slot → "regular"|"bold"

-- ── Lazy module accessors ────────────────────────────────────────────────

-- Requires `modname`, returning nil instead of raising when it's unavailable.
local function _req(modname)
    local ok, m = pcall(require, modname)
    return ok and m or nil
end
local function _reqFont()     return _req("ui/font") end
local function _reqFontList() return _req("fontlist") end
local function _reqUIManager() return _req("ui/uimanager") end
local function _reqLFS()      return _req("libs/libkoreader-lfs") end

-- Loads the cre C module. Primary path goes through CreDocument:engineInit(),
-- which works in both the reader and the file manager; falls back to
-- requiring libkoreader-cre directly for builds where it's pre-loaded.
local function _reqCRE()
    local ok, m = pcall(function()
        return require("document/credocument"):engineInit()
    end)
    return (ok and m) or _req("libs/libkoreader-cre")
end

-- ── Path helpers ─────────────────────────────────────────────────────────

-- Heuristic: try "Font-Regular.ext" → "Font-Bold.ext",
-- then "Font.ext" → "Font-Bold.ext".
local function _boldPath(path_regular)
    if not path_regular then return nil end
    local p, n = path_regular:gsub("%-Regular%.", "-Bold.", 1)
    if n > 0 then return p end
    p, n = path_regular:gsub("(%.)([^.]+)$", "-Bold.%2", 1)
    return n > 0 and p or nil
end

-- ── Font list initialisation ──────────────────────────────────────────────

-- Builds _font_list, _fonts, _replaced.
local function _initFonts()
    local Font     = _reqFont()
    local FontList = _reqFontList()
    local cre      = _reqCRE()
    local lfs      = _reqLFS()
    if not (Font and FontList and cre) then
        _font_list = {}; _fonts = {}; _replaced = {}
        logger.warn("simpleui/style: font modules unavailable, font picker disabled")
        return
    end

    _font_list = {}
    _fonts     = {}
    _replaced  = {}

    -- Build the set of paths that will be accepted as valid font sources.
    local path_set = {}
    for _, p in ipairs(FontList.fontlist) do 
        -- Verify the file still exists on disk, as FontList caches paths across restarts.
        if not lfs or lfs.attributes(p, "mode") == "file" then
            path_set[p] = true 
        end
    end

    -- Walk CRE's font face list and keep only those whose file is in path_set.
    for _, name in ipairs(cre.getFontFaces()) do
        local path_regular = cre.getFontFaceFilenameAndFaceIndex(name)
        if path_regular and path_set[path_regular] then
            local path_bold  = _boldPath(path_regular)
            local bold_ok    = path_set[path_bold]
            table.insert(_font_list, name)
            if bold_ok then
                _fonts[name] = { regular = path_regular, bold = path_bold }
            else
                _fonts[name] = { regular = path_regular, bold = path_regular }
            end
        end
    end

    -- Record which Font.fontmap slots map to the two built-in Noto variants
    -- so we know exactly which entries to overwrite on apply.
    local type_font = {
        ["NotoSans-Regular.ttf"] = "regular",
        ["NotoSans-Bold.ttf"]    = "bold",
    }
    for slot, font_file in pairs(Font.fontmap) do
        local typ = type_font[font_file]
        if typ then _replaced[slot] = typ end
    end

    logger.dbg("simpleui/style: font list built,", #_font_list, "faces")
end

-- Ensures the cache is valid for the current setting value.
-- Wrapped in pcall internally so any unexpected error leaves the caches in a
-- safe (empty) state instead of propagating to the caller.
local function _ensureFonts()
    if _font_list ~= nil then return end
    local ok, err = pcall(_initFonts)
    if not ok then
        logger.warn("simpleui/style: _initFonts error:", err)
        _font_list    = _font_list    or {}
        _fonts        = _fonts        or {}
        _replaced     = _replaced     or {}
    end
end

-- ── Apply ────────────────────────────────────────────────────────────────

-- Refreshes the class-level font face defaults on KOReader's TitleBar widget.
--
-- TitleBar (ui/widget/titlebar.lua) evaluates Font:getFace("smalltfont") etc.
-- at require()-time as default field values in the OverlapGroup:extend{} table.
-- After _applyFont() updates Font.fontmap, those frozen face objects still point
-- to the old NotoSans paths, so every new TitleBar instance inherits the wrong
-- font regardless of the fontmap change.
--
-- Fix: after updating fontmap, call Font:getFace() again for each frozen slot
-- to get a face object bound to the new path, and overwrite the class default.
-- Safe to call even if titlebar.lua was never required (pcall + check).
local function _refreshTitleBarFaces()
    local ok_tb, TitleBar = pcall(require, "ui/widget/titlebar")
    if not ok_tb or not TitleBar then return end
    local Font = _reqFont()
    if not Font then return end
    -- These are the four slots frozen as class-level defaults in TitleBar.
    -- Re-fetching them forces Font to resolve the new fontmap path and cache
    -- a face under the new hash, then we replace the class default.
    local slots = {
        { field = "title_face_fullscreen",     face = "smalltfont"     },
        { field = "title_face_not_fullscreen", face = "x_smalltfont"   },
        { field = "subtitle_face",             face = "xx_smallinfofont"},
        { field = "info_text_face",            face = "x_smallinfofont" },
    }
    for _, s in ipairs(slots) do
        local ok_f, face = pcall(Font.getFace, Font, s.face)
        if ok_f and face then
            TitleBar[s.field] = face
        end
    end
end

-- Writes the chosen font paths into Font.fontmap.
local function _applyFont(name)
    local Font = _reqFont()
    if not Font then return end
    _ensureFonts()
    if not SUISettings:isTrue(_FONT_KEY_ENABLED) then return end
    if not (_fonts and _fonts[name]) then return end
    for slot, typ in pairs(_replaced) do
        Font.fontmap[slot] = _fonts[name][typ]
    end
    logger.dbg("simpleui/style: UI font applied →", name)
    -- Refresh TitleBar class defaults so new instances use the updated font.
    _refreshTitleBarFaces()
end

--- Restore the saved font preference.  Called from main.lua at plugin init.
function M.applyUIFont()
    _ensureFonts()
    if SUISettings:isTrue(_FONT_KEY_ENABLED) then
        local name = SUISettings:get(_FONT_KEY_NAME) or _FONT_DEFAULT
        if _fonts and _fonts[name] then
            _applyFont(name)
        else
            logger.warn("simpleui/style: active UI font not found on disk, disabling custom font:", name)
            SUISettings:set(_FONT_KEY_ENABLED, false)
        end
    end
end

-- ── Menu builder ─────────────────────────────────────────────────────────

--- Returns the sub_item_table for Style ▸ UI Font.
--- Never throws: any internal error is caught and surfaced as a disabled
--- "unavailable" entry so the menu always opens.
function M.makeFontMenuItems()
    local ok_ef, err_ef = pcall(_ensureFonts)
    if not ok_ef then
        logger.warn("simpleui/style: makeFontMenuItems – _ensureFonts error:", err_ef)
        _font_list = _font_list or {}
        _fonts     = _fonts     or {}
        _replaced  = _replaced  or {}
    end
    local Font      = _reqFont()
    local UIManager = _reqUIManager()

    local function _isEnabled()
        return SUISettings:isTrue(_FONT_KEY_ENABLED)
    end
    local function _currentName()
        return SUISettings:get(_FONT_KEY_NAME) or _FONT_DEFAULT
    end

    local items = {}

    -- ── Toggle: enable custom font ────────────────────────────────────────
    items[#items + 1] = {
        text         = _("Enable custom UI font"),
        checked_func = _isEnabled,
        callback     = function()
            local new_val = not _isEnabled()
            SUISettings:set(_FONT_KEY_ENABLED, new_val)
            if new_val then _applyFont(_currentName()) end
            if UIManager then
                UIManager:askForRestart(_("Restart to fully apply the UI font change."))
            end
        end,
    }

    -- ── One entry per available font face ────────────────────────────────
    if #_font_list == 0 then
        items[#items + 1] = {
            text    = _("No fonts found."),
            enabled_func = function() return false end,
            callback     = function() end,
        }
    else
        for _k, name in ipairs(_font_list) do
            local _name = name   -- upvalue capture
            items[#items + 1] = {
                text_func = function()
                    local label = _name
                    if _fonts[_name] and _fonts[_name].regular == _fonts[_name].bold then
                        label = label .. "  (no bold)"
                    end
                    if _isEnabled() and _name == _currentName() then
                        label = "\u{2713}  " .. label
                    end
                    return label
                end,
                -- Hide this entry in SUIWindow until the custom-font toggle is on.
                sui_hidden = function() return not _isEnabled() end,
                -- Render the menu entry in that font face when supported.
                font_func = Font and function(size)
                    local fd = _fonts[_name]
                    if not fd then return nil end
                    return Font:getFace(fd.regular, size)
                end or nil,
                -- Grey-out the currently selected entry.
                enabled_func = function()
                    return not (_isEnabled() and _name == _currentName())
                end,
                keep_menu_open = true,
                callback = function()
                    SUISettings:set(_FONT_KEY_NAME, _name)
                    SUISettings:set(_FONT_KEY_ENABLED, true)
                    _applyFont(_name)
                    if UIManager then
                        UIManager:askForRestart(_("Restart to fully apply the UI font change."))
                    end
                end,
            }
        end
    end

    return items
end

-- ---------------------------------------------------------------------------
-- Icon Packs
-- ---------------------------------------------------------------------------

local function _isIconFile(fname)
    return fname:match("%.[Ss][Vv][Gg]$") ~= nil
        or fname:match("%.[Pp][Nn][Gg]$") ~= nil
end

local _ACTION_SET = {
    library=true, homescreen=true, collections=true, history=true, continue=true,
    favorites=true, bookmark_browser=true, wifi_toggle=true, frontlight=true,
    night_mode=true,
    stats_calendar=true, power=true, browse_authors=true, browse_series=true, browse_tags=true,
    settings=true,
}

-- Maps icon-pack filename identifiers to internal action ids when they differ.
-- "sui_action_library.svg" is the public icon name for the "home" (Library) action.
local _ICON_ID_ALIAS = { library = "home", settings = "sui_settings" }

local function _filenameToKey(fname)
    local stem = fname:match("^(.+)%.[^%.]+$") or fname
    for _, s in ipairs(M.SLOTS) do
        if s.id == stem then return "simpleui_sysicon_" .. stem, "sysicon" end
    end
    local action_id = stem:match("^sui_action_(.+)$")
    if action_id and _ACTION_SET[action_id] then
        local internal_id = _ICON_ID_ALIAS[action_id] or action_id
        return "simpleui_action_" .. internal_id .. "_icon", "action"
    end
    return nil, nil
end

function M.getPacksDir()
    local ok, DS = pcall(require, "datastorage")
    if not ok or not DS then return nil end
    local lfs = require("libs/libkoreader-lfs")
    local dir = DS:getSettingsDir() .. "/simpleui/sui_icons/packs"
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(dir)
    end
    return dir
end

local function _loadManifest(pack_dir)
    local lfs = require("libs/libkoreader-lfs")
    local path = pack_dir .. "/pack.lua"
    if lfs.attributes(path, "mode") ~= "file" then return {} end
    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" then return data end
    logger.warn("sui_style: invalid pack.lua in", pack_dir)
    return {}
end

function M.listPacks()
    local dir = M.getPacksDir()
    if not dir then return {} end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(dir, "mode") ~= "directory" then return {} end

    local packs = {}
    for fname in lfs.dir(dir) do
        if fname ~= "." and fname ~= ".." then
            local full = dir .. "/" .. fname
            local attr = lfs.attributes(full)
            if attr then
                if attr.mode == "directory" then
                    local has_icon = false
                    for f2 in lfs.dir(full) do
                        if _isIconFile(f2) then has_icon = true; break end
                    end
                    if has_icon then
                        local manifest = _loadManifest(full)
                        packs[#packs + 1] = {
                            name   = (type(manifest.name) == "string" and manifest.name ~= "") and manifest.name or fname,
                            path   = full,
                            is_zip = false,
                        }
                    end
                end
            end
        end
    end
    table.sort(packs, function(a, b) return a.name:lower() < b.name:lower() end)
    return packs
end

local function _applyFromDir(pack_dir)
    local lfs = require("libs/libkoreader-lfs")
    local manifest  = _loadManifest(pack_dir)
    local file_map  = (type(manifest.map) == "table") and manifest.map or {}
    local result    = { applied = 0, skipped = 0, errors = 0 }
    local done_keys = {}

    for slot_id, rel_fname in pairs(file_map) do
        local settings_key = _filenameToKey(slot_id)
        if settings_key then
            local full_path    = pack_dir .. "/" .. rel_fname
            if lfs.attributes(full_path, "mode") == "file" then
                SUISettings:set(settings_key, full_path)
                done_keys[settings_key] = true
                result.applied = result.applied + 1
            else
                result.errors = result.errors + 1
            end
        else
            result.errors = result.errors + 1
        end
    end

    pcall(function()
        for fname in lfs.dir(pack_dir) do
            if fname ~= "." and fname ~= ".." and _isIconFile(fname) then
                local settings_key = _filenameToKey(fname)
                if settings_key then
                    if not done_keys[settings_key] then
                        local full_path = pack_dir .. "/" .. fname
                        if lfs.attributes(full_path, "mode") == "file" then
                            SUISettings:set(settings_key, full_path)
                            done_keys[settings_key] = true
                            result.applied = result.applied + 1
                        else
                            result.errors = result.errors + 1
                        end
                    end
                else
                    result.skipped = result.skipped + 1
                end
            end
        end
    end)
    return result
end

function M.installZip(zip_path)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(zip_path, "mode") ~= "file" then return nil, _("File not found: ") .. tostring(zip_path) end
    local ok_arc, Archiver = pcall(require, "ffi/archiver")
    if not ok_arc or not Archiver then return nil, _("ffi/archiver not available in this KOReader version") end
    local packs_dir = M.getPacksDir()
    if not packs_dir then return nil, _("Could not determine packs folder") end
    local arc = Archiver.Reader:new()
    if not arc:open(zip_path) then return nil, _("Could not open zip (invalid format or corrupted)") end
    local root_prefix = nil
    for entry in arc:iterate() do
        if entry.mode == "file" then
            local first_seg = entry.path:match("^([^/]+)/")
            if first_seg then
                if root_prefix == nil then root_prefix = first_seg
                elseif root_prefix ~= first_seg then root_prefix = false; break end
            else
                root_prefix = false; break
            end
        end
    end
    local zip_stem  = zip_path:match("([^/\\]+)%.[Zz][Ii][Pp]$") or "pack"
    local pack_name = (root_prefix and root_prefix ~= "") and root_prefix or zip_stem
    local dest_dir  = packs_dir .. "/" .. pack_name
    if lfs.attributes(dest_dir, "mode") ~= "directory" then lfs.mkdir(dest_dir) end
    local n_extracted = 0
    for entry in arc:iterate() do
        if entry.mode == "file" then
            local rel = entry.path
            if root_prefix and root_prefix ~= "" then
                local stripped = rel:match("^" .. root_prefix .. "/(.+)$")
                if stripped then rel = stripped else goto continue_entry end
            end
            if not rel:match("/") and rel ~= "" then
                if _isIconFile(rel) or rel == "pack.lua" then
                    arc:extractToPath(entry.path, dest_dir .. "/" .. rel)
                    n_extracted = n_extracted + 1
                end
            end
        end
        ::continue_entry::
    end
    return pack_name, dest_dir
end

function M.applyPack(pack_path)
    local lfs = require("libs/libkoreader-lfs")
    if not pack_path then return nil, _("pack_path not provided") end
    local attr = lfs.attributes(pack_path)
    if not attr then return nil, _("Path does not exist: ") .. tostring(pack_path) end
    local pack_dir
    if attr.mode == "directory" then
        pack_dir = pack_path
    elseif attr.mode == "file" and pack_path:lower():match("%.zip$") then
        local _name, dest_or_err = M.installZip(pack_path)
        if not _name then return nil, _("Error extracting zip: ") .. tostring(dest_or_err) end
        pack_dir = dest_or_err
    else
        return nil, _("Unsupported format (use a folder or a .zip file)")
    end
    if lfs.attributes(pack_dir, "mode") ~= "directory" then return nil, _("Pack folder not accessible: ") .. tostring(pack_dir) end
    return _applyFromDir(pack_dir)
end

return M
