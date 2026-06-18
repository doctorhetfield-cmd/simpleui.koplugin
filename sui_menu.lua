-- menu.lua — Simple UI
-- Builds the full settings submenu registered in the KOReader main menu
-- (Top Bar, Bottom Bar, Quick Actions, Pagination Bar).
-- Returns an installer: require("menu")(plugin) populates plugin.addToMainMenu.

local UIManager = require("ui/uimanager")
local Device    = require("device")
local Screen    = Device.screen
local lfs       = require("libs/libkoreader-lfs")
local logger    = require("logger")
local _ = require("sui_i18n").translate
local N_ = require("sui_i18n").ngettext
local T = require("ffi/util").template

-- Heavy UI widgets — lazy-loaded on first use so that require("menu") at boot
-- does not pull them into memory before the user ever opens the settings menu.
-- On low-memory devices these requires were the most likely point of silent
-- failure that caused the menu entry to open nothing.
local function InfoMessage()      return require("ui/widget/infomessage")      end
local function ConfirmBox()       return require("ui/widget/confirmbox")        end
local function InputDialog()      return require("ui/widget/inputdialog")       end
local function MultiInputDialog() return require("ui/widget/multiinputdialog") end
local function PathChooser()      return require("ui/widget/pathchooser")       end
local function SortWidget()       return require("ui/widget/sortwidget")        end

local Config    = require("sui_config")
local UI        = require("sui_core")
local Bottombar = require("sui_bottombar")
local SUISettings = require("sui_store")

-- ---------------------------------------------------------------------------
-- Installer function
-- ---------------------------------------------------------------------------

return function(SimpleUIPlugin)

-- Secondary icon registration: runs when sui_menu is first loaded (lazy fallback).
-- The primary registration happens eagerly in main.lua:init() with absolute-path
-- resolution and DataStorage copy.  This block is kept as a belt-and-suspenders
-- fallback for cases where sui_menu is loaded without a prior main.lua init
-- (e.g. unit tests, or future refactoring).
--
-- Fixes vs. the original three-strategy approach:
--   * plugin_root is resolved to an absolute path via lfs.currentdir() when
--     debug.getinfo returns a relative source path (happens on some devices).
--   * ICONS_PATH and ICONS_DIRS are collected in a SINGLE upvalue scan instead
--     of two sequential loops, matching the Zen UI implementation.
--   * Strategy 3 (iw.init patch) is retained for hardened builds where upvalue
--     access is unavailable.
do
    local src = debug.getinfo(1, "S").source or ""
    local plugin_root = (src:sub(1,1) == "@") and src:sub(2):match("^(.*)/[^/]+$") or nil
    -- Resolve relative paths to absolute (fix for devices where debug.getinfo
    -- returns e.g. "plugins/simpleui.koplugin/sui_menu.lua" instead of an
    -- absolute path).
    if plugin_root and plugin_root:sub(1, 1) ~= "/" then
        local ok_lfs2, lfs2 = pcall(require, "libs/libkoreader-lfs")
        local cwd = ok_lfs2 and lfs2 and lfs2.currentdir()
        if cwd then plugin_root = cwd .. "/" .. plugin_root end
    end
    if plugin_root then
        local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
        local iw_ok,  iw  = pcall(require, "ui/widget/iconwidget")
        if lfs_ok and iw_ok and iw then
            local icon_file = plugin_root .. "/icons/settings.svg"
            local icon_exists = lfs.attributes(icon_file, "mode") == "file"

            -- Prefer the unwrapped init exposed by sui_patches' wallpaper alpha patch.
            -- When that patch is active, rawget(iw,"init") returns its wrapper closure
            -- which has no ICONS_PATH/ICONS_DIRS upvalues, making the scan below fail
            -- and causing Strategy 3 to fire unnecessarily on every normal build.
            local iw_init = iw._simpleui_orig_init_for_scan or rawget(iw, "init")

            local injected_path = false
            local injected_dir  = false

            if type(iw_init) == "function" then
                -- Single scan: collect both ICONS_PATH and ICONS_DIRS together.
                local icons_path, icons_dirs
                for i = 1, 64 do
                    local uname, uval = debug.getupvalue(iw_init, i)
                    if uname == nil then break end
                    if uname == "ICONS_PATH" and type(uval) == "table" then
                        icons_path = uval
                    elseif uname == "ICONS_DIRS" and type(uval) == "table" then
                        icons_dirs = uval
                    end
                    if icons_path and icons_dirs then break end
                end
                if icons_path then
                    if icon_exists and not icons_path["simpleui_settings"] then
                        icons_path["simpleui_settings"] = icon_file
                    end
                    injected_path = true
                end
                if icons_dirs then
                    local icons_subdir = plugin_root .. "/icons"
                    local already = false
                    for _, d in ipairs(icons_dirs) do
                        if d == icons_subdir then already = true; break end
                    end
                    if not already then
                        table.insert(icons_dirs, 1, icons_subdir)
                    end
                    injected_dir = true
                end
            end

            -- Strategy 3: if upvalue injection was unavailable (hardened builds),
            -- patch IconWidget.init so icon="simpleui_settings" resolves directly.
            if not injected_path and not injected_dir and icon_exists then
                local orig_init = iw.init
                iw.init = function(self_iw, ...)
                    if self_iw.icon == "simpleui_settings" and not self_iw.file and not self_iw.image then
                        self_iw.file = icon_file
                        -- Fall through to orig_init so dimensions and the
                        -- internal ImageWidget are properly initialised.
                        -- Returning early left width/height nil and caused
                        -- "cannot render image" crashes on paintTo.
                    end
                    if type(orig_init) == "function" then orig_init(self_iw, ...) end
                end
                logger.info("simpleui: icon registered via IconWidget.init patch (fallback)")
            end
        end
    end
end

SimpleUIPlugin.addToMainMenu = function(self, menu_items)
    local plugin = self

    -- Local aliases for Config functions.
    local loadTabConfig       = Config.loadTabConfig
    local saveTabConfig       = Config.saveTabConfig
    local getCustomQAList     = Config.getCustomQAList
    local saveCustomQAList    = Config.saveCustomQAList
    local getCustomQAConfig   = Config.getCustomQAConfig
    local saveCustomQAConfig  = Config.saveCustomQAConfig
    local deleteCustomQA      = Config.deleteCustomQA
    local nextCustomQAId      = Config.nextCustomQAId
    local getTopbarConfig     = Config.getTopbarConfig
    local saveTopbarConfig    = Config.saveTopbarConfig
    local _ensureHomePresent  = Config._ensureHomePresent
    local _sanitizeLabel      = Config.sanitizeLabel
    local _homeLabel          = Config.homeLabel
    local _getNonFavoritesCollections = Config.getNonFavoritesCollections
    local ALL_ACTIONS         = Config.ALL_ACTIONS
    local ACTION_BY_ID        = Config.ACTION_BY_ID
    local TOPBAR_ITEMS        = Config.TOPBAR_ITEMS
    local TOPBAR_ITEM_LABEL   = Config.TOPBAR_ITEM_LABEL
    local MAX_CUSTOM_QA       = Config.MAX_CUSTOM_QA
    local CUSTOM_ICON         = Config.CUSTOM_ICON
    local CUSTOM_PLUGIN_ICON  = Config.CUSTOM_PLUGIN_ICON
    local CUSTOM_DISPATCHER_ICON = Config.CUSTOM_DISPATCHER_ICON
    local TOTAL_H             = Bottombar.TOTAL_H
    local MAX_LABEL_LEN       = Config.MAX_LABEL_LEN

    -- Hardware capability — evaluated once per menu session, not per item render.
    -- All pool builders (tabs, position, QA) share this single check so that
    -- "Brightness" appears consistently in every pool on devices that have a
    -- frontlight, and is absent on those that don't.
    local _has_fl = nil
    local function hasFrontlight()
        if _has_fl == nil then
            local ok, v = pcall(function() return Device:hasFrontlight() end)
            _has_fl = ok and v == true
        end
        return _has_fl
    end

    -- Returns true when the given action id should be shown in menus on this device.
    -- Currently only "frontlight" is hardware-gated; all other ids are always shown.
    local function actionAvailable(id)
        if id == "frontlight" then return hasFrontlight() end
        if id == "browse_authors" or id == "browse_series" or id == "browse_tags" then
            local ok_bm, BM = pcall(require, "sui_browsemeta")
            return ok_bm and BM and BM.isEnabled()
        end
        return true
    end

    -- -----------------------------------------------------------------------
    -- Mode radio-item helper
    -- -----------------------------------------------------------------------

    local function modeItem(label, mode_value)
        return {
            text           = label,
            radio          = true,
            keep_menu_open = true,
            checked_func   = function() return Config.getNavbarMode() == mode_value end,
            callback       = function()
                Config.saveNavbarMode(mode_value)
                plugin:_scheduleRebuild()
            end,
        }
    end

    local function makeTypeMenu()
        return {
            modeItem(_("Icons") .. " + " .. _("Text"), "both"),
            modeItem(_("Icons only"),                   "icons"),
            modeItem(_("Text only"),                    "text"),
        }
    end

    -- -----------------------------------------------------------------------
    -- Tab and position menu builders
    -- -----------------------------------------------------------------------

    local function makePositionMenu(pos)
        local items        = {}
        local cached_tabs
        local cached_labels = {}

        local function getTabs()
            if not cached_tabs then cached_tabs = loadTabConfig() end
            return cached_tabs
        end

        local function getResolvedLabel(id)
            if not cached_labels[id] then
                if id:match("^custom_qa_%d+$") then
                    cached_labels[id] = getCustomQAConfig(id).label
                elseif id == "home" then
                    cached_labels[id] = _homeLabel()
                else
                    cached_labels[id] = (ACTION_BY_ID[id] and ACTION_BY_ID[id].label) or id
                end
            end
            return cached_labels[id]
        end

        local pool = {}
        for _i, action in ipairs(ALL_ACTIONS) do
            if actionAvailable(action.id) then pool[#pool + 1] = action.id end
        end
        for _i, qa_id in ipairs(getCustomQAList()) do pool[#pool + 1] = qa_id end

        for _i, id in ipairs(pool) do
            local _id = id
            items[#items + 1] = {
                text_func    = function()
                    local lbl  = getResolvedLabel(_id)
                    local tabs = getTabs()
                    for i, tid in ipairs(tabs) do
                        if tid == _id and i ~= pos then
                            return lbl .. "  (#" .. i .. ")"
                        end
                    end
                    return lbl
                end,
                checked_func = function() return getTabs()[pos] == _id end,
                keep_menu_open = true,
                callback     = function()
                    local tabs    = loadTabConfig()
                    cached_tabs   = nil
                    cached_labels = {}
                    local old_id  = tabs[pos]
                    if old_id == _id then return end
                    tabs[pos] = _id
                    for i, tid in ipairs(tabs) do
                        if i ~= pos and tid == _id then tabs[i] = old_id; break end
                    end
                    _ensureHomePresent(tabs)
                    saveTabConfig(tabs)
                    plugin:_scheduleRebuild()
                end,
            }
        end
        -- Pre-compute sort keys once so text_func is not called O(N log N) times
        -- during the sort comparison (#13).
        for _i, item in ipairs(items) do
            local t = item.text_func()
            item._sort_key = (t:match("^(.-)%s+%(#") or t):lower()
        end
        table.sort(items, function(a, b) return a._sort_key < b._sort_key end)
        for _i, item in ipairs(items) do item._sort_key = nil end
        return items
    end

    local function getActionLabel(id)
        if not id then return "?" end
        if id:match("^custom_qa_%d+$") then return getCustomQAConfig(id).label end
        if id == "home" then return _homeLabel() end
        return (ACTION_BY_ID[id] and ACTION_BY_ID[id].label) or id
    end

    local function makeTabsMenu(ctx_menu)
        local items = {}

        items[#items + 1] = {
            text           = _("Arrange Tabs"),
            keep_menu_open = true,
            separator      = true,
            callback       = function()
                local tabs       = loadTabConfig()
                local sort_items = {}
                for _i, tid in ipairs(tabs) do
                    sort_items[#sort_items + 1] = { text = getActionLabel(tid), orig_item = tid }
                end
                local function on_save()
                    local new_tabs = {}
                    for _i, item in ipairs(sort_items) do new_tabs[#new_tabs + 1] = item.orig_item end
                    _ensureHomePresent(new_tabs)
                    saveTabConfig(new_tabs)
                    plugin:_scheduleRebuild()
                    if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end
                end
                UIManager:show(SortWidget():new{
                    title             = _("Arrange Tabs"),
                    item_table        = sort_items,
                    covers_fullscreen = true,
                    callback          = on_save,
                })
            end,
        }

        local toggle_items = {}
        local action_pool  = {}
        for _i, action in ipairs(ALL_ACTIONS) do
            if actionAvailable(action.id) then action_pool[#action_pool + 1] = action.id end
        end
        for _i, qa_id in ipairs(getCustomQAList()) do action_pool[#action_pool + 1] = qa_id end

        for _i, aid in ipairs(action_pool) do
            local _aid = aid
            local _base_label = getActionLabel(_aid)
            toggle_items[#toggle_items + 1] = {
                _base        = _base_label,
                text_func    = function()
                    local limit = Config.effectiveMaxTabs()
                    for _i, tid in ipairs(loadTabConfig()) do
                        if tid == _aid then return _base_label end
                    end
                    local rem = limit - #loadTabConfig()
                    if rem <= 2 then return _base_label .. string.format(N_("  (%d left)", "  (%d left)", rem), rem) end
                    return _base_label
                end,
                checked_func = function()
                    for _i, tid in ipairs(loadTabConfig()) do
                        if tid == _aid then return true end
                    end
                    return false
                end,
                radio          = false,
                keep_menu_open = true,
                callback = function()
                    local tabs       = loadTabConfig()
                    local limit      = Config.effectiveMaxTabs()
                    local min_tabs   = Config.isNavpagerEnabled() and 1 or 2
                    local active_pos = nil
                    for i, tid in ipairs(tabs) do
                        if tid == _aid then active_pos = i; break end
                    end
                    if active_pos then
                        if #tabs <= min_tabs then
                            UIManager:show(InfoMessage():new{
                                text = Config.isNavpagerEnabled()
                                    and _("Minimum 1 tab required in navpager mode.")
                                    or  _("Minimum 2 tabs required. Select another tab first."),
                                timeout = 2,
                            })
                            return
                        end
                        table.remove(tabs, active_pos)
                    else
                        if #tabs >= limit then
                            UIManager:show(InfoMessage():new{
                                text = string.format(N_("The maximum of %d tab has been reached. Remove one first.",
                                       "The maximum of %d tabs has been reached. Remove one first.", limit), limit), timeout = 2,
                            })
                            return
                        end
                        tabs[#tabs + 1] = _aid
                    end
                    _ensureHomePresent(tabs)
                    saveTabConfig(tabs)
                    plugin:_scheduleRebuild()
                end,
            }
        end
        table.sort(toggle_items, function(a, b) return a._base:lower() < b._base:lower() end)
        for _i, item in ipairs(toggle_items) do items[#items + 1] = item end
        return items
    end

    -- -----------------------------------------------------------------------
    -- Pagination bar menu builder
    -- -----------------------------------------------------------------------

    local function makePaginationBarMenu()
        -- ── helpers ──────────────────────────────────────────────────────────
        -- "Geral" state is encoded in two existing keys:
        --   Predefinido : pagination_visible=true,  navpager=false
        --   Navpager    : navpager=true             (pagination_visible ignored)
        --   Oculto      : pagination_visible=false, navpager=false
        local function getGeral()
            if SUISettings:isTrue("simpleui_bar_navpager_enabled") then
                return "navpager"
            elseif SUISettings:nilOrTrue("simpleui_bar_pagination_visible") then
                return "predefinido"
            else
                return "oculto"
            end
        end

        local function setGeral(mode)
            if mode == "navpager" then
                SUISettings:saveSetting("simpleui_bar_navpager_enabled", true)
                SUISettings:saveSetting("simpleui_bar_pagination_visible", false)
                -- Navpager requires dot pager on homescreen (koreader style not allowed).
                if not SUISettings:nilOrTrue("simpleui_bar_dotpager_always") then
                    SUISettings:saveSetting("simpleui_bar_dotpager_always", true)
                end
                -- Trim tabs to navpager limit if needed.
                local tabs = Config.loadTabConfig()
                if #tabs > Config.MAX_TABS_NAVPAGER then
                    while #tabs > Config.MAX_TABS_NAVPAGER do
                        table.remove(tabs, #tabs)
                    end
                    Config.saveTabConfig(tabs)
                end
            elseif mode == "predefinido" then
                SUISettings:saveSetting("simpleui_bar_navpager_enabled", false)
                SUISettings:saveSetting("simpleui_bar_pagination_visible", true)
            else -- "oculto"
                SUISettings:saveSetting("simpleui_bar_navpager_enabled", false)
                SUISettings:saveSetting("simpleui_bar_pagination_visible", false)
            end
        end

        local function restartPrompt(text)
            UIManager:show(ConfirmBox():new{
                text        = text,
                ok_text     = _("Restart"), cancel_text = _("Later"),
                ok_callback = function()
                    SUISettings:flush()
                    UIManager:restartKOReader()
                end,
            })
        end

        -- ── menu ─────────────────────────────────────────────────────────────
        return {
                -- ── Subfolder: General ────────────────────────────────────────────
            {
                text           = _("Mode"),
                sub_item_table = {
                    {
                        text         = _("Default"),
                        radio        = true,
                        checked_func = function() return getGeral() == "predefinido" end,
                        callback     = function()
                            if getGeral() == "predefinido" then return end
                            setGeral("predefinido")
                            restartPrompt(_("Pagination bar set to Default.\n\nRestart now?"))
                        end,
                    },
                    {
                        text         = _("Navpager"),
                        radio        = true,
                        checked_func = function() return getGeral() == "navpager" end,
                        help_text    = _("Replaces the pagination bar with Prev/Next arrows at the edges of the bottom bar.\nThe arrows dim when there is no previous or next page.\nWith navpager active, as few as 1 tab and at most 4 tabs can be configured."),
                        callback     = function()
                            if getGeral() == "navpager" then return end
                            setGeral("navpager")
                            restartPrompt(_("Navpager enabled.\n\nRestart now?"))
                        end,
                    },
                    {
                        text         = _("Hidden"),
                        radio        = true,
                        checked_func = function() return getGeral() == "oculto" end,
                        callback     = function()
                            if getGeral() == "oculto" then return end
                            setGeral("oculto")
                            restartPrompt(_("Pagination bar hidden.\n\nRestart now?"))
                        end,
                    },
                },
            },
                -- ── Subfolder: Home Screen ────────────────────────────────────────
            {
                text           = _("Home Screen Style"),
                sub_item_table = {
                    {
                        text         = _("Dot Pager"),
                        radio        = true,
                        checked_func = function()
                            -- Dot Pager is always forced when Navpager is active.
                            return not SUISettings:isTrue("simpleui_hs_pagination_hidden")
                                and (SUISettings:nilOrTrue("simpleui_bar_dotpager_always")
                                    or getGeral() == "navpager")
                        end,
                        help_text    = _("Shows a row of dots at the bottom of the homescreen.\nThe active page dot is filled; the others are dimmed.\nAlways active when Navpager is selected."),
                        callback     = function()
                            SUISettings:saveSetting("simpleui_hs_pagination_hidden", false)
                            if not SUISettings:nilOrTrue("simpleui_bar_dotpager_always") then
                                SUISettings:saveSetting("simpleui_bar_dotpager_always", true)
                            end
                            plugin:_scheduleRebuild()
                            local ok_hs, HS = pcall(require, "sui_homescreen")
                            if ok_hs and HS then HS.refresh(true) end
                        end,
                        keep_menu_open = true,
                    },
                    {
                        text         = _("KOReader"),
                        radio        = true,
                        -- Not selectable when Navpager is active.
                        enabled_func = function() return getGeral() ~= "navpager" end,
                        checked_func = function()
                            return not SUISettings:isTrue("simpleui_hs_pagination_hidden")
                                and not SUISettings:nilOrTrue("simpleui_bar_dotpager_always")
                                and getGeral() ~= "navpager"
                        end,
                        help_text    = _("Uses the standard KOReader pagination bar on the homescreen.\nNot available when Navpager is active."),
                        callback     = function()
                            SUISettings:saveSetting("simpleui_hs_pagination_hidden", false)
                            if SUISettings:nilOrTrue("simpleui_bar_dotpager_always") then
                                SUISettings:saveSetting("simpleui_bar_dotpager_always", false)
                            end
                            plugin:_scheduleRebuild()
                            local ok_hs, HS = pcall(require, "sui_homescreen")
                            if ok_hs and HS then HS.refresh(true) end
                        end,
                        keep_menu_open = true,
                    },
                    {
                        text         = _("Hidden"),
                        radio        = true,
                        -- Not selectable when Navpager is active (navpager needs dot pager).
                        enabled_func = function() return getGeral() ~= "navpager" end,
                        checked_func = function()
                            return SUISettings:isTrue("simpleui_hs_pagination_hidden")
                                and getGeral() ~= "navpager"
                        end,
                        help_text    = _("Hides the pagination bar on the homescreen.\nNot available when Navpager is active."),
                        callback     = function()
                            if SUISettings:isTrue("simpleui_hs_pagination_hidden") then return end
                            SUISettings:saveSetting("simpleui_hs_pagination_hidden", true)
                            local ok_hs, HS = pcall(require, "sui_homescreen")
                            if ok_hs and HS then HS.refresh(true) end
                        end,
                        keep_menu_open = true,
                    },
                },
            },
                -- ── Subfolder: Size (only when general is not hidden) ─────────────
            {
                text           = _("Bar Size"),
                enabled_func   = function() return getGeral() ~= "oculto" end,
                sub_item_table = {
                    {
                        text           = _("Extra Small"),
                        radio          = true,
                        enabled_func   = function() return getGeral() ~= "oculto" end,
                        checked_func   = function()
                            return (SUISettings:readSetting("simpleui_bar_pagination_size") or "s") == "xs"
                        end,
                        callback       = function()
                            SUISettings:saveSetting("simpleui_bar_pagination_size", "xs")
                            restartPrompt(_("Pagination bar size will change after restart.\n\nRestart now?"))
                        end,
                    },
                    {
                        text           = _("Small"),
                        radio          = true,
                        enabled_func   = function() return getGeral() ~= "oculto" end,
                        checked_func   = function()
                            return (SUISettings:readSetting("simpleui_bar_pagination_size") or "s") == "s"
                        end,
                        callback       = function()
                            SUISettings:saveSetting("simpleui_bar_pagination_size", "s")
                            restartPrompt(_("Pagination bar size will change after restart.\n\nRestart now?"))
                        end,
                    },
                    {
                        text           = _("Default"),
                        radio          = true,
                        enabled_func   = function() return getGeral() ~= "oculto" end,
                        checked_func   = function()
                            return (SUISettings:readSetting("simpleui_bar_pagination_size") or "s") == "m"
                        end,
                        callback       = function()
                            SUISettings:saveSetting("simpleui_bar_pagination_size", "m")
                            restartPrompt(_("Pagination bar size will change after restart.\n\nRestart now?"))
                        end,
                    },
                },
            },
                -- ── Number of pages in the title bar ──────────────────────────────
            {
                text         = _("Show Page Count in Title Bar"),
                separator    = true,
                checked_func = function()
                    return SUISettings:isTrue("simpleui_bar_pagination_show_subtitle")
                end,
                help_text    = _("Shows \"Page X of Y\" in the title bar subtitle when browsing the library, history or collections.\nNavpager enables this automatically.\nNot available when Navpager is active."),
                callback     = function()
                    local on = SUISettings:isTrue("simpleui_bar_pagination_show_subtitle")
                    SUISettings:saveSetting("simpleui_bar_pagination_show_subtitle", not on)
                    plugin:_scheduleRebuild()
                end,
                keep_menu_open = true,
            },
        }
    end

    -- -----------------------------------------------------------------------
    -- Topbar menu builders
    -- -----------------------------------------------------------------------

    local function makeTopbarItemsMenu()
        local items = {}

        -- Custom Text item — toggle visibility via tap, edit text via long-press.
        do
            local k = "custom_text"
            -- "Edit Custom Text" -- plain action item, opens InputDialog directly on tap.
            items[#items + 1] = {
                text_func = function()
                    local t = Config.getTopbarCustomText()
                    if t ~= "" then
                        return _("Edit Custom Text") .. '  "' .. t .. '"'
                    end
                    return _("Edit Custom Text")
                end,
                keep_menu_open = true,
                callback = function()
                    local dlg
                    dlg = InputDialog():new{
                        title       = _("Custom Text"),
                        input       = Config.getTopbarCustomText(),
                        description = string.format(N_("Text shown in the top bar.\nMaximum %d character.",
                                      "Text shown in the top bar.\nMaximum %d characters.", Config.TOPBAR_CUSTOM_TEXT_MAX),
                                      Config.TOPBAR_CUSTOM_TEXT_MAX),
                        input_type  = "text",
                        buttons     = {{
                            {
                                text     = _("Cancel"),
                                id       = "close",
                                callback = function() UIManager:close(dlg) end,
                            },
                            {
                                text             = _("Set"),
                                is_enter_default = true,
                                callback         = function()
                                    local text = dlg:getInputText()
                                    Config.setTopbarCustomText(text)
                                    UIManager:close(dlg)
                                    -- Auto-enable when text is set and item is hidden.
                                    if text ~= "" then
                                        local cfg = getTopbarConfig()
                                        if not cfg.order_center then cfg.order_center = {} end
                                        if (cfg.side[k] or "hidden") == "hidden" then
                                            cfg.side[k] = "right"
                                        local new_left, new_center = {}, {}
                                        for _, v in ipairs(cfg.order_left) do if v ~= k then new_left[#new_left + 1] = v end end
                                        cfg.order_left = new_left
                                        for _, v in ipairs(cfg.order_center) do if v ~= k then new_center[#new_center + 1] = v end end
                                        cfg.order_center = new_center
                                            local found = false
                                            for _i, v in ipairs(cfg.order_right) do if v == k then found = true; break end end
                                            if not found then cfg.order_right[#cfg.order_right + 1] = k end
                                            saveTopbarConfig(cfg)
                                        end
                                    end
                                    plugin:_scheduleRebuild()
                                end,
                            },
                        }},
                    }
                    UIManager:show(dlg)
                    dlg:onShowKeyboard()
                end,
                separator = true,
                sui_hidden = ctx_menu and ctx_menu.is_sui and true or nil,
            }
        end

        if #items > 0 then items[#items].separator = true end

        items[#items + 1] = {
            text           = _("Arrange Items"),
            keep_menu_open = true,
            separator      = true,
            callback       = function()
                local cfg        = getTopbarConfig()
                if not cfg.order_center then cfg.order_center = {} end
                local SEP_LEFT   = "__sep_left__"
                local SEP_CENTER = "__sep_center__"
                local SEP_RIGHT  = "__sep_right__"
                local sort_items = {}
                sort_items[#sort_items + 1] = { text = _("Left"):upper(), orig_item = SEP_LEFT, is_divider = true }
                for _i, key in ipairs(cfg.order_left) do
                    if cfg.side[key] ~= "hidden" then
                        sort_items[#sort_items + 1] = { text = TOPBAR_ITEM_LABEL(key), orig_item = key }
                    end
                end
                sort_items[#sort_items + 1] = { text = _("Center"):upper(), orig_item = SEP_CENTER, is_divider = true }
                for _i, key in ipairs(cfg.order_center) do
                    if cfg.side[key] == "center" then
                        sort_items[#sort_items + 1] = { text = TOPBAR_ITEM_LABEL(key), orig_item = key }
                    end
                end
                sort_items[#sort_items + 1] = { text = _("Right"):upper(), orig_item = SEP_RIGHT, is_divider = true }
                for _i, key in ipairs(cfg.order_right) do
                    if cfg.side[key] ~= "hidden" then
                        sort_items[#sort_items + 1] = { text = TOPBAR_ITEM_LABEL(key), orig_item = key }
                    end
                end
                local function on_save()
                    local sep_left_pos, sep_center_pos, sep_right_pos
                    for j, item in ipairs(sort_items) do
                        if item.orig_item == SEP_LEFT   then sep_left_pos   = j end
                        if item.orig_item == SEP_CENTER then sep_center_pos = j end
                        if item.orig_item == SEP_RIGHT  then sep_right_pos  = j end
                    end
                    if not sep_left_pos or not sep_center_pos or not sep_right_pos
                            or sep_left_pos > sep_center_pos or sep_center_pos > sep_right_pos
                            or (sort_items[1] and sort_items[1].orig_item ~= SEP_LEFT) then
                        local InfoMessage = ctx_menu and ctx_menu.InfoMessage or require("ui/widget/infomessage")
                        local uim = ctx_menu and ctx_menu.UIManager or UIManager
                        uim:show(InfoMessage:new{
                            text    = _("Invalid arrangement.\nKeep the Left, Center and Right separators in order."),
                            timeout = 3,
                        })
                        return
                    end
                    local new_left, new_center, new_right = {}, {}, {}
                    local current_side = nil
                    for _i, item in ipairs(sort_items) do
                        if     item.orig_item == SEP_LEFT   then current_side = "left"
                        elseif item.orig_item == SEP_CENTER then current_side = "center"
                        elseif item.orig_item == SEP_RIGHT  then current_side = "right"
                        elseif current_side == "left"   then new_left[#new_left + 1]     = item.orig_item; cfg.side[item.orig_item] = "left"
                        elseif current_side == "center" then new_center[#new_center + 1] = item.orig_item; cfg.side[item.orig_item] = "center"
                        elseif current_side == "right"  then new_right[#new_right + 1]   = item.orig_item; cfg.side[item.orig_item] = "right"
                        end
                    end
                    -- Keep hidden items at the tail of each list so they can be restored later.
                    for _i, key in ipairs(cfg.order_left)   do if cfg.side[key] == "hidden" then new_left[#new_left + 1]     = key end end
                    for _i, key in ipairs(cfg.order_center) do if cfg.side[key] == "hidden" then new_center[#new_center + 1] = key end end
                    for _i, key in ipairs(cfg.order_right)  do if cfg.side[key] == "hidden" then new_right[#new_right + 1]   = key end end
                    cfg.order_left   = new_left
                    cfg.order_center = new_center
                    cfg.order_right  = new_right
                    saveTopbarConfig(cfg)
                    plugin:_scheduleRebuild()
                    if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end
                end

                if ctx_menu and ctx_menu.show_arrange then
                    ctx_menu.show_arrange({
                        title             = _("Arrange Items"),
                        items             = sort_items,
                        on_change         = on_save,
                        on_close          = on_save
                    })
                else
                    UIManager:show(SortWidget():new{
                        title             = _("Arrange Items"),
                        item_table        = sort_items,
                        covers_fullscreen = true,
                        callback          = on_save,
                    })
                end
            end,
        }

        local sorted_keys = {}
        for _i, k in ipairs(TOPBAR_ITEMS) do sorted_keys[#sorted_keys + 1] = k end
        table.sort(sorted_keys, function(a, b) return TOPBAR_ITEM_LABEL(a):lower() < TOPBAR_ITEM_LABEL(b):lower() end)

        for _i, key in ipairs(sorted_keys) do
            local k = key
            items[#items + 1] = {
                text_func    = function()
                    local side = Config.getTopbarConfigCached().side[k] or "hidden"
                    local label = TOPBAR_ITEM_LABEL(k)
                    if side == "left"   then return label .. "  \xe2\x97\x82"
                    elseif side == "center" then return label .. "  \xe2\x97\x86"
                    elseif side == "right"  then return label .. "  \xe2\x96\xb8"
                    else return label end
                end,
                -- Uses the cached config so opening the menu doesn't rebuild
                -- the config table once per item (#16).
                checked_func = function()
                    return (Config.getTopbarConfigCached().side[k] or "hidden") ~= "hidden"
                end,
                keep_menu_open = true,
                callback = function()
                    -- Reads fresh config for the mutation, then invalidates cache.
                    local cfg = getTopbarConfig()
                    if not cfg.order_center then cfg.order_center = {} end
                    if (cfg.side[k] or "hidden") == "hidden" then
                        -- Restore to the last known slot, checking all three lists.
                        local last_side = "right"
                        for _i, v in ipairs(cfg.order_left)   do if v == k then last_side = "left";   break end end
                        for _i, v in ipairs(cfg.order_center) do if v == k then last_side = "center"; break end end
                        cfg.side[k] = last_side
                        if last_side == "left" then
                            local found = false
                            for _i, v in ipairs(cfg.order_left) do if v == k then found = true; break end end
                            if not found then cfg.order_left[#cfg.order_left + 1] = k end
                        elseif last_side == "center" then
                            local found = false
                            for _i, v in ipairs(cfg.order_center) do if v == k then found = true; break end end
                            if not found then cfg.order_center[#cfg.order_center + 1] = k end
                        else
                            local found = false
                            for _i, v in ipairs(cfg.order_right) do if v == k then found = true; break end end
                            if not found then cfg.order_right[#cfg.order_right + 1] = k end
                        end
                    else
                        cfg.side[k] = "hidden"
                    end
                    saveTopbarConfig(cfg)   -- also calls Config.invalidateTopbarConfigCache()
                    plugin:_scheduleRebuild()
                    if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end
                end,
            }
        end
        return items
    end


    local function makeTopbarMenu(ctx_menu)
        return {
            {
                text_func    = function()
                    return _("Enable Status Bar")
                end,
                checked_func = function() return SUISettings:nilOrTrue("simpleui_topbar_enabled") end,
                keep_menu_open = true,
                callback     = function()
                    local on = SUISettings:nilOrTrue("simpleui_topbar_enabled")
                    SUISettings:saveSetting("simpleui_topbar_enabled", not on)
                    UIManager:show(ConfirmBox():new{
                        text = string.format(_("Status Bar will be %s after restart.\n\nRestart now?"), on and _("disabled") or _("enabled")),
                        ok_text = _("Restart"), cancel_text = _("Later"),
                        ok_callback = function()
                            SUISettings:flush()
                            UIManager:restartKOReader()
                        end,
                    })
                end,
                separator = true,
            },
            {
                text = _("Items"),
                sub_item_table_func = function() return makeTopbarItemsMenu(ctx_menu) end,
                sui_build = ctx_menu and ctx_menu.is_sui and function(ctx, _item)
                    local SUIWindow = require("sui_window")
                    return SUIWindow.ListRow{
                        title        = _("Items"),
                        subtitle     = function()
                            local cfg = Config.getTopbarConfig()
                            local names = {}
                            for _, key in ipairs(cfg.order_left) do
                                if (cfg.side[key] or "hidden") ~= "hidden" then names[#names + 1] = Config.TOPBAR_ITEM_LABEL(key) end
                            end
                            for _, key in ipairs(cfg.order_center) do
                                if (cfg.side[key] or "hidden") == "center" then names[#names + 1] = Config.TOPBAR_ITEM_LABEL(key) end
                            end
                            for _, key in ipairs(cfg.order_right) do
                                if (cfg.side[key] or "hidden") == "right" then names[#names + 1] = Config.TOPBAR_ITEM_LABEL(key) end
                            end
                            return #names > 0 and table.concat(names, "  ·  ") or _("No items selected.")
                        end,
                        inner_w      = ctx.inner_w,
                        show_chevron = true,
                        on_tap       = function()
                            local cfg        = Config.getTopbarConfig()
                            local SEP_LEFT   = "__sep_left__"
                            local SEP_CENTER = "__sep_center__"
                            local SEP_RIGHT  = "__sep_right__"
                            local sort_items = {}
                            
                            local function add_item(k)
                                local subtitle = nil
                                local on_more = nil
                                if k == "custom_text" then
                                    local t = Config.getTopbarCustomText()
                                    if t ~= "" then subtitle = t else subtitle = _("Empty") end
                                    on_more = function(anchor_dimen)
                                        local SUIWindow2 = require("sui_window")
                                        SUIWindow2.ActionMenu{
                                            anchor = anchor_dimen,
                                            items = {
                                                {
                                                    text = _("Edit Custom Text"),
                                                    icon = "edit",
                                                    on_tap = function()
                                                        local InputDialog = require("ui/widget/inputdialog")
                                                        local dlg
                                                        dlg = InputDialog:new{
                                                            title       = _("Custom Text"),
                                                            input       = Config.getTopbarCustomText(),
                                                            description = string.format(ctx_menu.N_("Text shown in the top bar.\nMaximum %d character.",
                                                                          "Text shown in the top bar.\nMaximum %d characters.", Config.TOPBAR_CUSTOM_TEXT_MAX),
                                                                          Config.TOPBAR_CUSTOM_TEXT_MAX),
                                                            input_type  = "text",
                                                            buttons     = {{
                                                                { text = _("Cancel"), id = "close", callback = function() ctx_menu.UIManager:close(dlg) end },
                                                                { text = _("Set"), is_enter_default = true, callback = function()
                                                                    local text = dlg:getInputText()
                                                                    Config.setTopbarCustomText(text)
                                                                    ctx_menu.UIManager:close(dlg)
                                                                    plugin:_scheduleRebuild()
                                                                    ctx.repaint()
                                                                end },
                                                            }},
                                                        }
                                                        ctx_menu.UIManager:show(dlg)
                                                        dlg:onShowKeyboard()
                                                    end,
                                                }
                                            }
                                        }
                                    end
                                end
                                sort_items[#sort_items + 1] = {
                                    text = Config.TOPBAR_ITEM_LABEL(k),
                                    orig_item = k,
                                    subtitle = subtitle,
                                    on_more = on_more,
                                }
                            end
                            
                            sort_items[#sort_items + 1] = { text = _("Left"):upper(), orig_item = SEP_LEFT, is_divider = true }
                            for _, key in ipairs(cfg.order_left) do
                                if (cfg.side[key] or "hidden") ~= "hidden" then add_item(key) end
                            end
                            sort_items[#sort_items + 1] = { text = _("Center"):upper(), orig_item = SEP_CENTER, is_divider = true }
                            for _, key in ipairs(cfg.order_center) do
                                if (cfg.side[key] or "hidden") == "center" then add_item(key) end
                            end
                            sort_items[#sort_items + 1] = { text = _("Right"):upper(), orig_item = SEP_RIGHT, is_divider = true }
                            for _, key in ipairs(cfg.order_right) do
                                if (cfg.side[key] or "hidden") == "right" then add_item(key) end
                            end
                            
                            ctx.push("arrange", {
                                title = _("Items"),
                                items = sort_items,
                                empty_text = _("No items selected."),
                                on_delete = function(item)
                                    cfg.side[item.orig_item] = "hidden"
                                end,
                                on_change = function(items_to_save)
                                    local new_left, new_center, new_right = {}, {}, {}
                                    local current_side = nil
                                    for _, item in ipairs(items_to_save) do
                                        if     item.orig_item == SEP_LEFT   then current_side = "left"
                                        elseif item.orig_item == SEP_CENTER then current_side = "center"
                                        elseif item.orig_item == SEP_RIGHT  then current_side = "right"
                                        elseif current_side == "left"   then new_left[#new_left + 1]     = item.orig_item; cfg.side[item.orig_item] = "left"
                                        elseif current_side == "center" then new_center[#new_center + 1] = item.orig_item; cfg.side[item.orig_item] = "center"
                                        elseif current_side == "right"  then new_right[#new_right + 1]   = item.orig_item; cfg.side[item.orig_item] = "right"
                                        end
                                    end
                                    for _, key in ipairs(cfg.order_left)   do if (cfg.side[key] or "hidden") == "hidden" then new_left[#new_left + 1]     = key end end
                                    for _, key in ipairs(cfg.order_center) do if (cfg.side[key] or "hidden") == "hidden" then new_center[#new_center + 1] = key end end
                                    for _, key in ipairs(cfg.order_right)  do if (cfg.side[key] or "hidden") == "hidden" then new_right[#new_right + 1]   = key end end
                                    cfg.order_left   = new_left
                                    cfg.order_center = new_center
                                    cfg.order_right  = new_right
                                    Config.saveTopbarConfig(cfg)
                                    plugin:_scheduleRebuild()
                                end,
                                footer_text = _("Add Item"),
                                footer_enabled = function()
                                    local cfg2 = Config.getTopbarConfigCached()
                                    for _, k in ipairs(Config.TOPBAR_ITEMS) do
                                        if (cfg2.side[k] or "hidden") == "hidden" then return true end
                                    end
                                    return false
                                end,
                                footer_action = function(ctx2)
                                    local cfg2 = Config.getTopbarConfig()
                                    local picker_items = {}
                                    for _, k in ipairs(Config.TOPBAR_ITEMS) do
                                        if (cfg2.side[k] or "hidden") == "hidden" then
                                            local _k = k
                                            local _label = Config.TOPBAR_ITEM_LABEL(k)
                                            picker_items[#picker_items + 1] = {
                                                text = _label,
                                                on_tap = function(picker_ctx)
                                                    cfg2.side[_k] = "right"
                                                    local new_left, new_center = {}, {}
                                                    for _, v in ipairs(cfg2.order_left) do if v ~= _k then new_left[#new_left + 1] = v end end
                                                    cfg2.order_left = new_left
                                                    for _, v in ipairs(cfg2.order_center) do if v ~= _k then new_center[#new_center + 1] = v end end
                                                    cfg2.order_center = new_center
                                                    local found = false
                                                    for _, v in ipairs(cfg2.order_right) do if v == _k then found = true; break end end
                                                    if not found then cfg2.order_right[#cfg2.order_right + 1] = _k end
                                                    Config.saveTopbarConfig(cfg2)
                                                    add_item(_k)
                                                    plugin:_scheduleRebuild()
                                                    picker_ctx.pop()
                                                    ctx2.repaint()
                                                end
                                            }
                                        end
                                    end
                                    ctx2.push("item_picker", {
                                        title = _("Add Item"),
                                        items = picker_items,
                                    })
                                end
                            })
                        end
                    }
                end or nil,
            },
            {
                text_func = function()
                    return _("Size")
                end,
                value_func = function() return Config.getTopbarSizePct() .. "%" end,
                keep_menu_open = true,
                callback = function()
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text    = _("Status Bar Size"),
                        info_text     = _("Height of the top status bar.\n100% is the default size."),
                        value         = Config.getTopbarSizePct(),
                        value_min     = Config.TOPBAR_SIZE_MIN,
                        value_max     = Config.TOPBAR_SIZE_MAX,
                        value_step    = Config.TOPBAR_SIZE_STEP,
                        unit          = "%",
                        ok_text       = _("Apply"),
                        cancel_text   = _("Cancel"),
                        default_value = Config.TOPBAR_SIZE_DEF,
                        callback      = function(spin)
                            Config.setTopbarSizePct(spin.value)
                            UI.invalidateDimCache()
                            plugin:_rewrapAllWidgets()
                            local ok_hs, HS = pcall(require, "sui_homescreen")
                            if ok_hs and HS then HS.refresh(true) end
                            UIManager:show(ConfirmBox():new{
                                text       = _("A restart is required to apply the new bar size across all layouts.\n\nRestart now?"),
                                ok_text    = _("Restart"),
                                cancel_text = _("Later"),
                                ok_callback = function()
                                    SUISettings:flush()
                                    UIManager:restartKOReader()
                                end,
                            })
                        end,
                    })
                end,
            },
            {
                text           = _("Swipe Indicator"),
                keep_menu_open = true,
                checked_func   = function() return SUISettings:nilOrTrue("simpleui_topbar_swipe_indicator") end,
                callback = function()
                    SUISettings:saveSetting("simpleui_topbar_swipe_indicator",
                        not SUISettings:nilOrTrue("simpleui_topbar_swipe_indicator"))
                    plugin:_scheduleRebuild()
                end,
            },
            {
                text           = _("Hide Wi-Fi Icon When Off"),
                keep_menu_open = true,
                checked_func   = function() return Config.getWifiHideWhenOff() end,
                callback = function()
                    Config.setWifiHideWhenOff(not Config.getWifiHideWhenOff())
                    plugin:_scheduleRebuild()
                end,
            },
            {
                text         = _("Settings on Long Tap"),
                help_text    = _("When enabled, long-pressing the top bar opens its settings menu.\nDisable this to prevent the settings menu from appearing on long tap."),
                checked_func = function()
                    return SUISettings:nilOrTrue("simpleui_topbar_settings_on_hold")
                end,
                keep_menu_open = true,
                callback = function()
                    local on = SUISettings:nilOrTrue("simpleui_topbar_settings_on_hold")
                    SUISettings:saveSetting("simpleui_topbar_settings_on_hold", not on)
                end,
            },
        }
    end

    -- -----------------------------------------------------------------------
    -- Bottom bar menu builder
    -- -----------------------------------------------------------------------

    local function makeNavbarMenu(ctx_menu)
        return {
            {
                text_func    = function()
                    return _("Enable Navigation Bar")
                end,
                checked_func = function() return SUISettings:nilOrTrue("simpleui_bar_enabled") end,
                keep_menu_open = true,
                callback     = function()
                    local on = SUISettings:nilOrTrue("simpleui_bar_enabled")
                    SUISettings:saveSetting("simpleui_bar_enabled", not on)
                    UIManager:show(ConfirmBox():new{
                        text = string.format(_("Navigation Bar will be %s after restart.\n\nRestart now?"), on and _("disabled") or _("enabled")),
                        ok_text = _("Restart"), cancel_text = _("Later"),
                        ok_callback = function()
                            SUISettings:flush()
                            UIManager:restartKOReader()
                        end,
                    })
                end,
                separator = true,
            },
            {
                text_func = function()
                    local n     = #loadTabConfig()
                    local limit = Config.effectiveMaxTabs()
                    local remaining = limit - n
                    if remaining <= 0 then
                        return string.format(_("Tabs  (%d/%d — at limit)"), n, limit)
                    end
                    return string.format(_("Tabs  (%d/%d — %d left)"), n, limit, remaining)
                end,
                sub_item_table_func = function() return makeTabsMenu(ctx_menu) end,
                sui_build = ctx_menu and ctx_menu.is_sui and function(ctx, _item)
                    local SUIWindow = require("sui_window")
                    return SUIWindow.ListRow{
                        title        = _("Tabs"),
                        subtitle     = function()
                            local tabs = loadTabConfig()
                            if #tabs == 0 then return _("No items selected.") end
                            local names = {}
                            for _, tid in ipairs(tabs) do
                                names[#names + 1] = getActionLabel(tid)
                            end
                            return table.concat(names, "  ·  ")
                        end,
                        inner_w      = ctx.inner_w,
                        item_count   = function() return #loadTabConfig() end,
                        max_items    = function() return Config.effectiveMaxTabs() end,
                        show_chevron = true,
                        on_tap       = function()
                            local tabs = loadTabConfig()
                            local sort_items = {}
                            local min_tabs = Config.isNavpagerEnabled() and 1 or 2
                            
                            local function refresh_delete_handlers()
                                for i, item in ipairs(sort_items) do
                                    local _tid = item.orig_item
                                    if #sort_items > min_tabs then
                                        item.on_delete = function()
                                            local new_tabs = {}
                                            for _, t in ipairs(loadTabConfig()) do
                                                if t ~= _tid then table.insert(new_tabs, t) end
                                            end
                                            _ensureHomePresent(new_tabs)
                                            saveTabConfig(new_tabs)
                                            for j, v in ipairs(sort_items) do
                                                if v.orig_item == _tid then table.remove(sort_items, j); break end
                                            end
                                            refresh_delete_handlers()
                                            plugin:_scheduleRebuild()
                                            if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end
                                            ctx.repaint()
                                        end
                                    else
                                        item.on_delete = nil
                                    end
                                end
                            end
                            
                            for _, tid in ipairs(tabs) do
                                sort_items[#sort_items + 1] = {
                                    text = getActionLabel(tid),
                                    orig_item = tid,
                                }
                            end
                            refresh_delete_handlers()
                            ctx.push("arrange", {
                                title = _("Tabs"),
                                items = sort_items,
                                empty_text = _("No items selected."),
                                item_count = function() return #loadTabConfig() end,
                                max_items  = function() return Config.effectiveMaxTabs() end,
                                on_change = function(items_to_save)
                                    local new_tabs = {}
                                    for _, item in ipairs(items_to_save) do new_tabs[#new_tabs + 1] = item.orig_item end
                                    _ensureHomePresent(new_tabs)
                                    saveTabConfig(new_tabs)
                                    plugin:_scheduleRebuild()
                                    if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end
                                end,
                                footer_text = _("Add Item"),
                                footer_action = function(ctx2)
                                    local tabs = loadTabConfig()
                                    local action_pool = {}
                                    for _i, action in ipairs(ALL_ACTIONS) do
                                        if actionAvailable(action.id) then action_pool[#action_pool + 1] = action.id end
                                    end
                                    for _i, qa_id in ipairs(getCustomQAList()) do action_pool[#action_pool + 1] = qa_id end
                                    
                                    local picker_items = {}
                                    for _, aid in ipairs(action_pool) do
                                        local is_sel = false
                                        for _, tid in ipairs(tabs) do if tid == aid then is_sel = true break end end
                                        if not is_sel then
                                            local _aid = aid
                                            local _label = getActionLabel(_aid)
                                            picker_items[#picker_items + 1] = {
                                                text = _label,
                                                on_tap = function(picker_ctx)
                                                    local cur = loadTabConfig()
                                                    local limit = Config.effectiveMaxTabs()
                                                    if #cur >= limit then
                                                        local InfoMessage = ctx_menu and ctx_menu.InfoMessage or require("ui/widget/infomessage")
                                                        local uim = ctx_menu and ctx_menu.UIManager or require("ui/uimanager")
                                                        local N_ = ctx_menu and ctx_menu.N_ or require("sui_i18n").ngettext
                                                        uim:show(InfoMessage:new{
                                                            text = string.format(N_("The maximum of %d tab has been reached. Remove one first.",
                                                                   "The maximum of %d tabs has been reached. Remove one first.", limit), limit), timeout = 2,
                                                        })
                                                        return
                                                    end
                                                    cur[#cur + 1] = _aid
                                                    _ensureHomePresent(cur)
                                                    saveTabConfig(cur)
                                                    table.insert(sort_items, { text = _label, orig_item = _aid })
                                                    refresh_delete_handlers()
                                                    plugin:_scheduleRebuild()
                                                    if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end
                                                    picker_ctx.pop()
                                                    ctx2.repaint()
                                                end
                                            }
                                        end
                                    end
                                    table.sort(picker_items, function(a, b) return a.text:lower() < b.text:lower() end)
                                    ctx2.push("item_picker", {
                                        title = _("Add Item"),
                                        items = picker_items,
                                    })
                                end
                            })
                        end
                    }
                end or nil,
            },
            {
                text = _("Tab Style"),
                sub_item_table_func = makeTypeMenu,
            },
            {
                text = _("Bar Style"),
                sub_item_table = {
                    {
                        text           = _("Default"),
                        radio          = true,
                        checked_func   = function() return require("sui_bottombar").getBarStyle() == "default" end,
                        keep_menu_open = true,
                        callback       = function()
                            SUISettings:saveSetting("simpleui_bar_style", "default")
                            UI.invalidateDimCache()
                            plugin:_scheduleRebuild()
                            if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end
                        end,
                    },
                    {
                        text           = _("Framed"),
                        radio          = true,
                        checked_func   = function() return require("sui_bottombar").getBarStyle() == "framed" end,
                        keep_menu_open = true,
                        callback       = function()
                            SUISettings:saveSetting("simpleui_bar_style", "framed")
                            UI.invalidateDimCache()
                            plugin:_scheduleRebuild()
                            if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end
                        end,
                    },
                    {
                        text           = _("Bare"),
                        radio          = true,
                        checked_func   = function() return require("sui_bottombar").getBarStyle() == "bare" end,
                        keep_menu_open = true,
                        callback       = function()
                            SUISettings:saveSetting("simpleui_bar_style", "bare")
                            UI.invalidateDimCache()
                            plugin:_scheduleRebuild()
                            if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end
                        end,
                    },
                },
            },
            {
                text_func = function()
                    return _("Bar Size")
                end,
                value_func = function() return Config.getBarSizePct() .. "%" end,
                keep_menu_open = true,
                callback = function()
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text    = _("Navigation Bar Size"),
                        info_text     = _("Height of the bottom navigation bar.\n100% is the default size."),
                        value         = Config.getBarSizePct(),
                        value_min     = Config.BAR_SIZE_MIN,
                        value_max     = Config.BAR_SIZE_MAX,
                        value_step    = Config.BAR_SIZE_STEP,
                        unit          = "%",
                        ok_text       = _("Apply"),
                        cancel_text   = _("Cancel"),
                        default_value = Config.BAR_SIZE_DEF,
                        callback      = function(spin)
                            Config.setBarSizePct(spin.value)
                            UI.invalidateDimCache()
                            plugin:_rewrapAllWidgets()
                            local ok_hs, HS = pcall(require, "sui_homescreen")
                            if ok_hs and HS then HS.refresh(true) end
                            UIManager:show(ConfirmBox():new{
                                text       = _("A restart is required to apply the new bar size across all layouts.\n\nRestart now?"),
                                ok_text    = _("Restart"),
                                cancel_text = _("Later"),
                                ok_callback = function()
                                    SUISettings:flush()
                                    UIManager:restartKOReader()
                                end,
                            })
                        end,
                    })
                end,
            },
            Config.makeScaleItem({
                text_func     = function() return _("Icon Size") end,
                title         = _("Icon Size"),
                info          = _("Size of the tab icons.\n100% is the default size."),
                get           = function() return Config.getIconScalePct() end,
                set           = function(pct) Config.setIconScalePct(pct) end,
                refresh       = function() UI.invalidateDimCache(); plugin:_rebuildAllNavbars() end,
                value_min     = Config.ICON_SCALE_MIN, value_max = Config.ICON_SCALE_MAX,
                value_step    = Config.ICON_SCALE_STEP, default_value = Config.ICON_SCALE_DEF,
            }),
            Config.makeScaleItem({
                text_func     = function() return _("Label Size") end,
                title         = _("Label Size"),
                info          = _("Size of the tab label text.\n100% is the default size."),
                get           = function() return Config.getNavbarLabelScalePct() end,
                set           = function(pct) Config.setNavbarLabelScalePct(pct) end,
                refresh       = function() UI.invalidateDimCache(); plugin:_rebuildAllNavbars() end,
                value_min     = Config.NAVBAR_LABEL_SCALE_MIN, value_max = Config.NAVBAR_LABEL_SCALE_MAX,
                value_step    = Config.NAVBAR_LABEL_SCALE_STEP, default_value = Config.NAVBAR_LABEL_SCALE_DEF,
            }),
            Config.makeScaleItem({
                text_func     = function() return _("Bottom Margin") end,
                title         = _("Bottom Margin"),
                info          = _("Space below the bottom navigation bar.\n100% is the default spacing."),
                get           = function() return Config.getBottomMarginPct() end,
                set           = function(pct) Config.setBottomMarginPct(pct) end,
                refresh       = function()
                    UI.invalidateDimCache(); plugin:_rewrapAllWidgets()
                    local ok_hs, HS = pcall(require, "sui_homescreen")
                    if ok_hs and HS then HS.refresh(true) end
                end,
                value_min     = Config.BOT_MARGIN_MIN, value_max = Config.BOT_MARGIN_MAX,
                value_step    = Config.BOT_MARGIN_STEP, default_value = Config.BOT_MARGIN_DEF,
            }),
            {
                text         = _("Settings on Long Tap"),
                help_text    = _("When enabled, long-pressing the bottom bar opens its settings menu.\nDisable this to prevent the settings menu from appearing on long tap."),
                checked_func = function()
                    return SUISettings:nilOrTrue("simpleui_bar_settings_on_hold")
                end,
                keep_menu_open = true,
                callback = function()
                    local on = SUISettings:nilOrTrue("simpleui_bar_settings_on_hold")
                    SUISettings:saveSetting("simpleui_bar_settings_on_hold", not on)
                end,
            },
        }
    end

    plugin._makeNavbarMenu = makeNavbarMenu
    plugin._makeTopbarMenu = makeTopbarMenu

    -- -----------------------------------------------------------------------
    -- Title Bar menu builder
    -- -----------------------------------------------------------------------

    -- Builds a visibility toggle list for one context ("fm" or "inj").
    local function makeTitleBarItemsForCtx(ctx)
        local Titlebar = require("sui_titlebar")
        local items = {}
        for _i, item in ipairs(Titlebar.ITEMS) do
            if item.ctx == ctx then
                local item_id    = item.id
                local item_label = item.label
                items[#items + 1] = {
                    text_func = function()
                        local state = Titlebar.isItemVisible(item_id) and _("On") or _("Off")
                        return item_label() .. " — " .. state
                    end,
                    checked_func   = function() return Titlebar.isItemVisible(item_id) end,
                    enabled_func   = function() return Titlebar.isEnabled() end,
                    keep_menu_open = true,
                    callback       = function()
                        Titlebar.setItemVisible(item_id, not Titlebar.isItemVisible(item_id))
                        _reapplyAllTitlebars()
                    end,
                }
            end
        end
        return items
    end

    -- Builds an arrange-items menu for one context.
    -- cfg_getter / cfg_saver — functions that load/save the side config.
    -- ctx — "fm" or "inj", used to filter M.ITEMS.
    local function makeTitleBarArrangeMenu(ctx_menu, ctx, cfg_getter, cfg_saver)
        local Titlebar   = require("sui_titlebar")
        local SEP_LEFT   = "__sep_left__"
        local SEP_RIGHT  = "__sep_right__"

        -- Build label lookup for this context.
        local labels = {}
        for _i, item in ipairs(Titlebar.ITEMS) do
            if item.ctx == ctx and not item.no_side then
                labels[item.id] = item.label
            end
        end

        local cfg        = cfg_getter()
        local sort_items = {}

        sort_items[#sort_items + 1] = {
            text = _("Left"):upper(), orig_item = SEP_LEFT, is_divider = true,
        }
        for _i, id in ipairs(cfg.order_left) do
            if labels[id] then
                sort_items[#sort_items + 1] = { text = labels[id](), orig_item = id }
            end
        end
        sort_items[#sort_items + 1] = {
            text = _("Right"):upper(), orig_item = SEP_RIGHT, is_divider = true,
        }
        for _i, id in ipairs(cfg.order_right) do
            if labels[id] then
                sort_items[#sort_items + 1] = { text = labels[id](), orig_item = id }
            end
        end

        local function on_save()
                -- Validate: separators must be in correct relative order.
                local sep_l, sep_r
                for j, item in ipairs(sort_items) do
                    if item.orig_item == SEP_LEFT  then sep_l = j end
                    if item.orig_item == SEP_RIGHT then sep_r = j end
                end
                if not sep_l or not sep_r or sep_l > sep_r
                        or (sort_items[1] and sort_items[1].orig_item ~= SEP_LEFT) then
                    local InfoMessage = ctx_menu and ctx_menu.InfoMessage or require("ui/widget/infomessage")
                    local uim = ctx_menu and ctx_menu.UIManager or UIManager
                    uim:show(InfoMessage:new{
                        text    = _("Invalid arrangement.\nKeep items between the Left and Right separators."),
                        timeout = 3,
                    })
                    return
                end
                local new_left, new_right = {}, {}
                local current_side = nil
                for _i, item in ipairs(sort_items) do
                    if     item.orig_item == SEP_LEFT  then current_side = "left"
                    elseif item.orig_item == SEP_RIGHT then current_side = "right"
                    elseif current_side == "left"  then
                        new_left[#new_left + 1]    = item.orig_item
                        cfg.side[item.orig_item]   = "left"
                    elseif current_side == "right" then
                        new_right[#new_right + 1]  = item.orig_item
                        cfg.side[item.orig_item]   = "right"
                    end
                end
                -- Preserve hidden items at the end of each order list.
                for _i, id in ipairs(cfg.order_left)  do
                    if not Titlebar.isItemVisible(id) then new_left[#new_left + 1]   = id end
                end
                for _i, id in ipairs(cfg.order_right) do
                    if not Titlebar.isItemVisible(id) then new_right[#new_right + 1] = id end
                end
                cfg.order_left  = new_left
                cfg.order_right = new_right
                cfg_saver(cfg)
                _reapplyAllTitlebars()
                if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end
        end

        if ctx_menu and ctx_menu.show_arrange then
            ctx_menu.show_arrange({
                title             = _("Arrange Buttons"),
                items             = sort_items,
                on_change         = on_save,
                on_close          = on_save
            })
        else
            UIManager:show(SortWidget():new{
                title             = _("Arrange Buttons"),
                item_table        = sort_items,
                covers_fullscreen = true,
                callback          = on_save,
            })
        end
    end

    -- Forward-declare _reapplyAllTitlebars so it is locally available inside
    -- the arrange closures without triggering strict.lua global-access errors.
    local _reapplyAllTitlebars
    _reapplyAllTitlebars = function()
        local Titlebar = require("sui_titlebar")
        local FM = package.loaded["apps/filemanager/filemanager"]
        local fm = FM and FM.instance
        local stack = require("sui_core").getWindowStack()
        Titlebar.reapplyAll(fm, stack)
        if fm then UIManager:setDirty(fm[1], "ui") end
    end

    local function makeTitleBarSUIBuild(ctx_menu, title_str, tb_ctx, cfg_getter, cfg_saver)
        return ctx_menu and ctx_menu.is_sui and function(ctx, _item)
            local SUIWindow = require("sui_window")
            local Titlebar  = require("sui_titlebar")

            return SUIWindow.ListRow{
                title        = title_str,
                subtitle     = function()
                    local cfg = cfg_getter()
                    local labels = {}
                    for _i, t_item in ipairs(Titlebar.ITEMS) do
                        if t_item.ctx == tb_ctx and not t_item.no_side then
                            labels[t_item.id] = t_item.label
                        end
                    end
                    local names = {}
                    for _, key in ipairs(cfg.order_left) do
                        if Titlebar.isItemVisible(key) and labels[key] then names[#names + 1] = labels[key]() end
                    end
                    for _, key in ipairs(cfg.order_right) do
                        if Titlebar.isItemVisible(key) and labels[key] then names[#names + 1] = labels[key]() end
                    end
                    return #names > 0 and table.concat(names, "  ·  ") or _("No items selected.")
                end,
                inner_w      = ctx.inner_w,
                show_chevron = true,
                on_tap       = function()
                     ctx.push("nested_menu", {
                        title = title_str,
                        footer_text = _("Add Button"),
                        footer_enabled = function()
                            for _i, item in ipairs(Titlebar.ITEMS) do
                                if item.ctx == tb_ctx and not item.no_side then
                                    if not Titlebar.isItemVisible(item.id) then return true end
                                end
                            end
                            return false
                        end,
                        footer_action = function(ctx2)
                            local picker_items = {}
                            for _i, item in ipairs(Titlebar.ITEMS) do
                                if item.ctx == tb_ctx and not item.no_side then
                                    if not Titlebar.isItemVisible(item.id) then
                                        local _id = item.id
                                        local _label = item.label()
                                        picker_items[#picker_items + 1] = {
                                            text = _label,
                                            on_tap = function(picker_ctx)
                                                Titlebar.setItemVisible(_id, true)
                                                local cfg = cfg_getter()
                                                cfg.side[_id] = "right"
                                                local new_left = {}
                                                for _, v in ipairs(cfg.order_left) do if v ~= _id then new_left[#new_left + 1] = v end end
                                                cfg.order_left = new_left
                                                local found = false
                                                for _, v in ipairs(cfg.order_right) do if v == _id then found = true; break end end
                                                if not found then cfg.order_right[#cfg.order_right + 1] = _id end
                                                cfg_saver(cfg)
                                                _reapplyAllTitlebars()
                                                picker_ctx.pop()
                                                ctx2.repaint()
                                            end
                                        }
                                    end
                                end
                            end
                            ctx2.push("item_picker", {
                                title = _("Add Button"),
                                items = picker_items,
                            })
                        end,
                    items_func = function()
                        local result_items = {}

                        for _i, item in ipairs(Titlebar.ITEMS) do
                            if item.ctx == tb_ctx and item.no_side then
                                local item_id = item.id
                                local item_label = item.label
                                result_items[#result_items + 1] = {
                                    text_func = function()
                                        local state = Titlebar.isItemVisible(item_id) and _("On") or _("Off")
                                        return item_label() .. " — " .. state
                                    end,
                                    checked_func   = function() return Titlebar.isItemVisible(item_id) end,
                                    enabled_func   = function() return Titlebar.isEnabled() end,
                                    keep_menu_open = true,
                                    callback       = function()
                                        Titlebar.setItemVisible(item_id, not Titlebar.isItemVisible(item_id))
                                        _reapplyAllTitlebars()
                                    end,
                                }
                            end
                        end

                        if #result_items > 0 then
                            result_items[#result_items].separator = true
                        end

                        result_items[#result_items + 1] = {
                            text = "Arrange List Wrapper",
                            sui_build = function(ctx3, item3)
                                local SEP_LEFT  = "__sep_left__"
                                local SEP_RIGHT = "__sep_right__"
                                
                                local labels = {}
                                for _i, t_item in ipairs(Titlebar.ITEMS) do
                                    if t_item.ctx == tb_ctx and not t_item.no_side then
                                        labels[t_item.id] = t_item.label
                                    end
                                end

                                local cfg = cfg_getter()
                                local sort_items = {}
                                sort_items[#sort_items + 1] = { text = _("Left"):upper(), orig_item = SEP_LEFT, is_divider = true }
                                for _i, key in ipairs(cfg.order_left) do
                                    if Titlebar.isItemVisible(key) and labels[key] then
                                        sort_items[#sort_items + 1] = { text = labels[key](), orig_item = key }
                                    end
                                end
                                sort_items[#sort_items + 1] = { text = _("Right"):upper(), orig_item = SEP_RIGHT, is_divider = true }
                                for _i, key in ipairs(cfg.order_right) do
                                    if Titlebar.isItemVisible(key) and labels[key] then
                                        sort_items[#sort_items + 1] = { text = labels[key](), orig_item = key }
                                    end
                                end

                                return SUIWindow.ArrangeList{
                                    inner_w    = ctx3.inner_w,
                                    items      = sort_items,
                                    empty_text = _("No items selected."),
                                    on_repaint = function() ctx3.repaint() end,
                                    on_delete  = function(idx, sitem)
                                        Titlebar.setItemVisible(sitem.orig_item, false)
                                        _reapplyAllTitlebars()
                                    end,
                                    on_change  = function(items_to_save)
                                        local cfg2 = cfg_getter()
                                        local new_left, new_right = {}, {}
                                        local current_side = nil
                                        for _i, sitem in ipairs(items_to_save) do
                                            if     sitem.orig_item == SEP_LEFT   then current_side = "left"
                                            elseif sitem.orig_item == SEP_RIGHT  then current_side = "right"
                                            elseif current_side == "left"   then new_left[#new_left + 1]   = sitem.orig_item; cfg2.side[sitem.orig_item] = "left"
                                            elseif current_side == "right"  then new_right[#new_right + 1] = sitem.orig_item; cfg2.side[sitem.orig_item] = "right"
                                            end
                                        end
                                        for _i, key in ipairs(cfg2.order_left)   do if not Titlebar.isItemVisible(key) then new_left[#new_left + 1]   = key end end
                                        for _i, key in ipairs(cfg2.order_right)  do if not Titlebar.isItemVisible(key) then new_right[#new_right + 1] = key end end
                                        cfg2.order_left   = new_left
                                        cfg2.order_right  = new_right
                                        cfg_saver(cfg2)
                                        _reapplyAllTitlebars()
                                    end
                                }
                            end
                        }
                        return result_items
                    end
                    })
                end
            }
        end or nil
    end

    local function makeTitleBarFMMenu(ctx_menu)
        local Titlebar = require("sui_titlebar")
        local items = makeTitleBarItemsForCtx("fm")
        if #items > 0 then items[#items].separator = true end
        items[#items + 1] = {
            text           = _("Arrange Buttons"),
            enabled_func   = function() return Titlebar.isEnabled() end,
            keep_menu_open = true,
            callback       = function()
                makeTitleBarArrangeMenu(ctx_menu, "fm", Titlebar.getFMConfig, Titlebar.saveFMConfig)
            end,
        }
        return items
    end

    local function makeTitleBarSubMenu(ctx_menu)
        local Titlebar = require("sui_titlebar")
        local items = makeTitleBarItemsForCtx("sub")
        if #items > 0 then items[#items].separator = true end
        items[#items + 1] = {
            text           = _("Arrange Buttons"),
            enabled_func   = function() return Titlebar.isEnabled() end,
            keep_menu_open = true,
            callback       = function()
                makeTitleBarArrangeMenu(ctx_menu, "sub", Titlebar.getSubConfig, Titlebar.saveSubConfig)
            end,
        }
        return items
    end

    local function makeTitleBarMenu(ctx_menu)
        local function sizeItem(label, key)
            return {
                text         = label,
                radio        = true,
                keep_menu_open = true,
                checked_func = function() return require("sui_titlebar").getSizeKey() == key end,
                callback     = function()
                    require("sui_titlebar").setSizeKey(key)
                    _reapplyAllTitlebars()
                end,
            }
        end
        return {
            {
                text_func    = function()
                    return _("Enable Title Bar")
                end,
                checked_func = function() return require("sui_titlebar").isEnabled() end,
                separator    = true,
                callback     = function()
                    local Titlebar = require("sui_titlebar")
                    local on = Titlebar.isEnabled()
                    Titlebar.setEnabled(not on)
                    SUISettings:flush()
                    UIManager:show(ConfirmBox():new{
                        text = string.format(
                            _("Title Bar will be %s after restart.\n\nRestart now?"),
                            on and _("disabled") or _("enabled")
                        ),
                        ok_text     = _("Restart"),
                        cancel_text = _("Later"),
                        ok_callback = function()
                            UIManager:restartKOReader()
                        end,
                    })
                end,
            },
            {
                text         = _("Library Buttons"),
                enabled_func = function() return require("sui_titlebar").isEnabled() end,
                sub_item_table_func = function() return makeTitleBarFMMenu(ctx_menu) end,
                sui_build = makeTitleBarSUIBuild(ctx_menu, _("Library Buttons"), "fm", require("sui_titlebar").getFMConfig, require("sui_titlebar").saveFMConfig),
            },
            {
                text         = _("Sub-page Buttons"),
                enabled_func = function() return require("sui_titlebar").isEnabled() end,
                sub_item_table_func = function() return makeTitleBarSubMenu(ctx_menu) end,
                sui_build = makeTitleBarSUIBuild(ctx_menu, _("Sub-page Buttons"), "sub", require("sui_titlebar").getSubConfig, require("sui_titlebar").saveSubConfig),
            },
            {
                text      = _("Appearance"):upper(),
                is_divider= true,
                sui_build = function(ctx)
                    return require("sui_window").SectionLabel{ text = _("Appearance"):upper(), inner_w = ctx.inner_w }
                end,
                dim       = true,
                enabled_func = function() return false end,
                keep_menu_open = true,
                callback  = function() end,
            },
            {
                text      = _("Button Size"),
                enabled_func = function() return require("sui_titlebar").isEnabled() end,
                sub_item_table = {
                    sizeItem(_("Compact"), "compact"),
                    sizeItem(_("Default"), "default"),
                    sizeItem(_("Large"),   "large"),
                },
            },
        }
    end

    plugin._makeTitleBarMenu = makeTitleBarMenu

    -- -----------------------------------------------------------------------
    -- Quick Actions
    -- -----------------------------------------------------------------------

    -- Quick Actions — delegated to sui_quickactions.lua
    local QA = require("sui_quickactions")
    local function makeQuickActionsMenu(ctx_menu)
        return QA.makeMenuItems(plugin, ctx_menu)
    end
    plugin._makeQuickActionsMenu = makeQuickActionsMenu

    local function refreshHomescreen()
        -- Rebuild the widget tree immediately (synchronous) with keep_cache=false
        -- so that book modules (Currently Reading, Recent Books) re-prefetch their
        -- data. Using keep_cache=true would reuse _cached_books_state which was
        -- built before those modules were enabled (with current_fp=nil, recent_fps={})
        -- causing the newly-enabled modules to render empty until the next full open.
        -- Collections and other modules have no per-instance cache so this is a
        -- no-op cost for them.
        --
        -- We also schedule a setDirty via UIManager:nextTick to guarantee a repaint
        -- AFTER the menu widget is removed from the stack. Any setDirty fired while
        -- the menu is open is painted behind it; when the menu closes the UIManager
        -- only repaints the menu frame region, not the full HS. nextTick runs after
        -- the current event's onCloseWidget teardown, so the HS is the top widget
        -- by the time the dirty is processed.
        local HS = package.loaded["sui_homescreen"]
        if not (HS and HS._instance) then return end
        local hs = HS._instance
        hs:_refreshImmediate(false)
        UIManager:nextTick(function()
            if HS._instance == hs and hs._navbar_container then
                UIManager:setDirty(hs, "ui")
            end
        end)
    end

    -- _goalTapCallback: shown when the user taps the Reading Goals widget on
    -- the Homescreen. Lets them set the annual goal.
    self._goalTapCallback = function()
        local ok_rg, RG = pcall(require, "readinggoals")
        if ok_rg and RG then RG.showAnnualGoalDialog(function() refreshHomescreen() end) end
    end

    -- -----------------------------------------------------------------------
    -- Shared parametric helpers
    -- All menu-building functions below accept a `ctx` table:
    --   ctx.pfx       — settings key prefix, e.g. "simpleui_hs_"
    --   ctx.pfx_qa    — QA settings prefix, e.g. "simpleui_hs_qa_"
    --   ctx.refresh   — zero-arg function to refresh the page after a change
    -- -----------------------------------------------------------------------

    local MAX_QA_ITEMS = 6  -- max actions per QA slot (used by makeQAMenu)

    local HOMESCREEN_CTX = {
        pfx     = "simpleui_hs_",
        pfx_qa  = "simpleui_hs_qa_",
        refresh = refreshHomescreen,
    }

    local Registry = require("desktop_modules/moduleregistry")

    -- Returns number of active modules for a given ctx.
    local function countModules(ctx)
        return Registry.countEnabled(ctx.pfx)
    end

    -- getQAPool — builds the list of available actions for Quick Actions menus.
    -- Must be declared before makeQAMenu/makeModulesMenu which use it.
    local function getQAPool()
        local available = {}
        for _i, a in ipairs(ALL_ACTIONS) do
            if actionAvailable(a.id) then
                available[#available+1] = { id = a.id, label = a.id == "home" and Config.homeLabel() or a.label }
            end
        end
        for _i, qa_id in ipairs(getCustomQAList()) do
            local _qid = qa_id
            available[#available+1] = { id = _qid, label = getCustomQAConfig(_qid).label }
        end
        return available
    end

    -- Builds the QA slot sub-menu for a given ctx and slot number.
    local function makeQAMenu(ctx, slot_n)
        local items_key  = ctx.pfx_qa .. slot_n .. "_items"
        local labels_key = ctx.pfx_qa .. slot_n .. "_labels"
        local slot_label = _("Quick Actions Row")
        local function getItems() return SUISettings:readSetting(items_key) or {} end
        local function isSelected(id)
            for _i, v in ipairs(getItems()) do if v == id then return true end end
            return false
        end
        local function toggleItem(id)
            local items = getItems(); local new_items = {}; local found = false
            for _i, v in ipairs(items) do if v == id then found = true else new_items[#new_items+1] = v end end
            if not found then
                if #items >= MAX_QA_ITEMS then
                    UIManager:show(InfoMessage():new{ text = string.format(N_("The maximum of %d action per module has been reached. Remove one first.",
                              "The maximum of %d actions per module has been reached. Remove one first.", MAX_QA_ITEMS), MAX_QA_ITEMS), timeout = 2 })
                    return
                end
                new_items[#new_items+1] = id
            end
            SUISettings:saveSetting(items_key, new_items); ctx.refresh()
        end
        local items_sub = {}
        local sorted_pool = {}
        for _i, a in ipairs(getQAPool()) do sorted_pool[#sorted_pool+1] = a end
        table.sort(sorted_pool, function(a, b) return a.label:lower() < b.label:lower() end)
        items_sub[#items_sub+1] = {
            text           = _("Arrange Items"),
            keep_menu_open = true,
            separator      = true,
            enabled_func   = function() return #getItems() >= 2 end,
            callback       = function()
              local qa_ids = getItems()
              if #qa_ids < 2 then UIManager:show(InfoMessage():new{ text = _("Add at least 2 actions to arrange."), timeout = 2 }); return end
              local pool_labels = {}; for _i, a in ipairs(getQAPool()) do pool_labels[a.id] = a.label end
              local sort_items = {}
              for _i, id in ipairs(qa_ids) do sort_items[#sort_items+1] = { text = pool_labels[id] or id, orig_item = id } end
              UIManager:show(SortWidget():new{ title = string.format(_("Arrange %s"), slot_label), covers_fullscreen = true, item_table = sort_items,
                  callback = function()
                      local new_order = {}; for _i, item in ipairs(sort_items) do new_order[#new_order+1] = item.orig_item end
                      SUISettings:saveSetting(items_key, new_order); ctx.refresh()
                  end })
          end,
        }
        for _i, a in ipairs(sorted_pool) do
            local aid = a.id; local _lbl = a.label
            items_sub[#items_sub+1] = {
                text_func = function()
                    if isSelected(aid) then return _lbl end
                    local rem = MAX_QA_ITEMS - #getItems()
                    if rem <= 2 then return _lbl .. string.format(N_("  (%d left)", "  (%d left)", rem), rem) end
                    return _lbl
                end,
                checked_func   = function() return isSelected(aid) end,
                keep_menu_open = true,
                callback       = function() toggleItem(aid) end,
            }
        end
        return {
            {
                text           = _("Hide Label"),
                checked_func   = function() return not SUISettings:nilOrTrue(labels_key) end,
                keep_menu_open = true,
                separator      = true,
                callback       = function()
                    SUISettings:saveSetting(labels_key, not SUISettings:nilOrTrue(labels_key))
                    ctx.refresh()
                end,
            },
            {
                text                = _("Items"),
                sub_item_table_func = function() return items_sub end,
                sui_build = ctx and ctx.is_sui and function(ctx2, _item)
                    local SUIWindow = require("sui_window")
                    return SUIWindow.ListRow{
                        title        = _("Items"),
                        subtitle     = function()
                            local qa_ids = getItems()
                            if #qa_ids == 0 then return _("No items selected.") end
                            local pool_labels = {}
                            for _, a in ipairs(getQAPool()) do pool_labels[a.id] = a.label end
                            local names = {}
                            for _, id in ipairs(qa_ids) do
                                names[#names + 1] = pool_labels[id] or id
                            end
                            return table.concat(names, "  ·  ")
                        end,
                        inner_w      = ctx2.inner_w,
                        item_count   = function() return #getItems() end,
                        max_items    = MAX_QA_ITEMS,
                        show_chevron = true,
                        on_tap       = function()
                            local qa_ids = getItems()
                            local pool_labels = {}
                            for _, a in ipairs(getQAPool()) do pool_labels[a.id] = a.label end
                            local sort_items = {}
                            for _, id in ipairs(qa_ids) do
                                sort_items[#sort_items + 1] = { text = pool_labels[id] or id, orig_item = id }
                            end
                            
                            ctx2.push("arrange", {
                                title = _("Items"),
                                items = sort_items,
                                empty_text = _("No items selected."),
                                item_count = function() return #getItems() end,
                                max_items  = MAX_QA_ITEMS,
                                on_delete = function(item) end,
                                on_change = function(items_to_save)
                                    local new_order = {}
                                    for _, it in ipairs(items_to_save) do new_order[#new_order + 1] = it.orig_item end
                                    SUISettings:saveSetting(items_key, new_order)
                                    ctx.refresh()
                                end,
                                footer_text = _("Add Item"),
                                footer_action = function(ctx3)
                                    local picker_items = {}
                                    local sorted_pool2 = {}
                                    for _, a in ipairs(getQAPool()) do sorted_pool2[#sorted_pool2 + 1] = a end
                                    table.sort(sorted_pool2, function(a, b) return a.label:lower() < b.label:lower() end)

                                    for _, a in ipairs(sorted_pool2) do
                                        if not isSelected(a.id) then
                                            local _id = a.id
                                            local _label = a.label
                                            picker_items[#picker_items + 1] = {
                                                text   = _label,
                                                on_tap = function(picker_ctx)
                                                    local cur = getItems()
                                                    if #cur >= MAX_QA_ITEMS then
                                                        local InfoMessage = ctx.InfoMessage or require("ui/widget/infomessage")
                                                        local uim = ctx.UIManager or require("ui/uimanager")
                                                        local N_ = ctx.N_ or require("sui_i18n").ngettext
                                                        uim:show(InfoMessage:new{
                                                            text = string.format(N_("The maximum of %d action per module has been reached. Remove one first.",
                                                                   "The maximum of %d actions per module has been reached. Remove one first.", MAX_QA_ITEMS), MAX_QA_ITEMS), timeout = 2,
                                                        })
                                                        return
                                                    end
                                                    cur[#cur + 1] = _id
                                                    SUISettings:saveSetting(items_key, cur)
                                                    table.insert(sort_items, { text = _label, orig_item = _id })
                                                    ctx.refresh()
                                                    picker_ctx.pop()
                                                    ctx3.repaint()
                                                end,
                                            }
                                        end
                                    end
                                    ctx3.push("item_picker", {
                                        title = _("Add Item"),
                                        items = picker_items,
                                    })
                                end
                            })
                        end
                    }
                end or nil,
            },
        }
    end

    -- Builds the full "Modules" sub-menu for a given ctx.
    -- Fully registry-driven: no module ids hardcoded here.
    local function makeModulesMenu(ctx)
        -- ctx_menu passed to each module's getMenuItems()
        -- InfoMessage and SortWidget are resolved lazily on first access via
        -- __index so that require("ui/widget/...") is deferred until the user
        -- actually opens a module settings menu, not when makeModulesMenu runs.
        local ctx_menu_data = {
            pfx           = ctx.pfx,
            pfx_qa        = ctx.pfx_qa,
            refresh       = ctx.refresh,
            UIManager     = UIManager,
            _             = _,
            N_            = N_,
            MAX_LABEL_LEN = MAX_LABEL_LEN,
            makeQAMenu    = makeQAMenu,
            _cover_picker = nil,
        }
        local ctx_menu = setmetatable(ctx_menu_data, {
            __index = function(t, k)
                if k == "InfoMessage" then
                    local v = InfoMessage(); rawset(t, k, v); return v
                elseif k == "SortWidget" then
                    local v = SortWidget(); rawset(t, k, v); return v
                end
            end,
        })

        local function loadOrder()
            local saved   = SUISettings:readSetting(ctx.pfx .. "module_order")
            local default = Registry.defaultOrder()
            if type(saved) ~= "table" or #saved == 0 then return default end
            local seen = {}; local result = {}
            for _loop_, v in ipairs(saved) do seen[v] = true; result[#result+1] = v end
            for _loop_, v in ipairs(default) do if not seen[v] then result[#result+1] = v end end
            return result
        end

        -- Toggle item for one module descriptor.
        -- Persistence is fully delegated to mod.setEnabled(pfx, on).
        local function makeToggleItem(mod)
            local _mod = mod
            return {
                text_func = function()
                    return _(_mod.name) -- FIX: Force translation evaluation at display time
                end,
                checked_func   = function() return Registry.isEnabled(_mod, ctx.pfx) end,
                keep_menu_open = true,
                callback = function()
                    local on = Registry.isEnabled(_mod, ctx.pfx)
                    if type(_mod.setEnabled) == "function" then
                        _mod.setEnabled(ctx.pfx, not on)
                    elseif _mod.enabled_key then
                        SUISettings:saveSetting(ctx.pfx .. _mod.enabled_key, not on)
                    end
                    ctx.refresh()
                end,
            }
        end

        -- Module Settings sub-menu: one entry per module that has getMenuItems.
        -- Count labels are provided by mod.getCountLabel(pfx) — no per-id special cases.
        local function makeModuleSettingsMenu()
            local items    = {}
            local qa_items = {}
            for _loop_, mod in ipairs(Registry.list()) do
                if type(mod.getMenuItems) == "function" then
                    local _mod = mod
                    local text_fn = function()
                        local count_lbl = type(_mod.getCountLabel) == "function"
                            and _mod.getCountLabel(ctx.pfx)
                        return count_lbl
                            and (_(_mod.name) .. "  " .. count_lbl) -- FIX: Force translation
                            or   _(_mod.name)                      -- FIX: Force translation
                    end
                    if _mod.id:match("_row_") then
                        qa_items[#qa_items + 1] = {
                            text_func           = text_fn,
                            sub_item_table_func = function() return _mod.getMenuItems(ctx_menu) end,
                        }
                    else
                        items[#items + 1] = {
                            text_func           = text_fn,
                            sub_item_table_func = function() return _mod.getMenuItems(ctx_menu) end,
                        }
                    end
                end
            end
            if #qa_items > 0 then
                items[#items + 1] = {
                    text                = _("Quick Actions"),
                    sub_item_table_func = function() return qa_items end,
                }
            end
            return items
        end

        return {
            {
                text_func = function()
                    local n = countModules(ctx)
                    return string.format(_("Modules  (%d)"), n)
                end,
                sub_item_table_func = function()
                    local result = {
                        {
                            text = _("Edit Layout"),
                            callback = function()
                                local SettingsWindow = require("sui_settings_window")
                                SettingsWindow:show()
                            end,
                        },
                        {
                            text = _("Module Settings"),
                            sub_item_table_func = makeModuleSettingsMenu,
                        },
                    }
                    return result
                end,
            },
        }
    end

    -- Helper: applies a full layout refresh after transparency / wallpaper-visibility changes.
    -- Mirrors the equivalent helper in the stable 1.5.0 Homescreen menu.
    local function _applyFullLayoutRefresh()
        plugin:_rewrapAllWidgets()
        local Patches = package.loaded["sui_patches"]
        if Patches and Patches.injectWallpaperIntoFullscreenWidget then
            local core_ok, core = pcall(require, "sui_core")
            local stack = core_ok and core.getWindowStack and core.getWindowStack()
            if stack then
                for _, entry in ipairs(stack) do
                    if entry.widget and entry.widget._navbar_injected then
                        pcall(Patches.injectWallpaperIntoFullscreenWidget, entry.widget)
                    end
                end
            end
        end
        local HS = package.loaded["sui_homescreen"]
        if HS and HS.rebuildLayout then
            HS.rebuildLayout()
        end
        local FM = package.loaded["apps/filemanager/filemanager"]
        if FM and FM.instance then
            FM.instance._navbar_inner = nil
            pcall(function() FM.instance:setupLayout() end)
            UIManager:setDirty(FM.instance, "ui")
        end
    end

    local function makeWallpaperMenuItems()
        return {
            {
                text           = _("Enable Wallpaper"),
                checked_func = function() return SUISettings:isTrue("simpleui_style_wallpaper_enabled") end,
                callback     = function()
                    local HS = require("sui_homescreen")
                    HS.styleSetWallpaperEnabled(not SUISettings:isTrue("simpleui_style_wallpaper_enabled"))
                    _applyFullLayoutRefresh()
                end,
                separator    = true,
                keep_menu_open = true,
            },
            {
                text = _("Select Wallpaper"),
                enabled_func = function() return SUISettings:isTrue("simpleui_style_wallpaper_enabled") end,
                sub_item_table_func = function()
                    local HS = require("sui_homescreen")
                    local items = {}
                    local wps = HS.styleScanWallpapers()
                    for _, wp in ipairs(wps) do
                        local _wp = wp
                        items[#items + 1] = {
                            text_func    = function() return _wp.label end,
                            radio        = true,
                            checked_func = function() return HS.styleGetWallpaper() == _wp.path end,
                            keep_menu_open = true,
                            callback = function()
                                HS.styleSetWallpaper(_wp.path)
                                _applyFullLayoutRefresh()
                            end,
                        }
                    end
                    if #items == 0 then
                        items[#items+1] = { text = _("No wallpapers found."), enabled = false }
                    end
                    items[#items+1] = { text = _("Place images in:"), enabled = false, separator = true }
                    items[#items+1] = { text = HS.styleGetWallpapersDir(), enabled = false }
                    return items
                end,
            },
            -- Transparent status bar (active only when wallpaper is enabled and selected)
            {
                text         = _("Transparent status bar"),
                checked_func = function()
                    local HS = require("sui_homescreen")
                    return HS.styleStatusbarTransparent()
                end,
                enabled_func = function()
                    return SUISettings:isTrue("simpleui_style_wallpaper_enabled")
                        and require("sui_homescreen").styleGetWallpaper() ~= nil
                end,
                callback = function()
                    local HS = require("sui_homescreen")
                    HS.styleSetStatusbarTransparent(not HS.styleStatusbarTransparent())
                    _applyFullLayoutRefresh()
                end,
                keep_menu_open = true,
            },
            -- Transparent navigation bar (active only when wallpaper is enabled and selected)
            {
                text         = _("Transparent navigation bar"),
                checked_func = function()
                    if Bottombar.getBarStyle() == "bare" then return true end
                    local HS = require("sui_homescreen")
                    return HS.styleNavbarTransparent()
                end,
                enabled_func = function()
                    return SUISettings:isTrue("simpleui_style_wallpaper_enabled")
                        and require("sui_homescreen").styleGetWallpaper() ~= nil
                        and Bottombar.getBarStyle() ~= "bare"
                end,
                callback = function()
                    local HS = require("sui_homescreen")
                    HS.styleSetNavbarTransparent(not HS.styleNavbarTransparent())
                    _applyFullLayoutRefresh()
                end,
                keep_menu_open = true,
            },
            -- Show wallpaper on all FM / overlay screens
            {
                text         = _("Show wallpaper on all screens"),
                checked_func = function()
                    local HS = require("sui_homescreen")
                    return HS.styleGetWallpaperShowInFM()
                end,
                enabled_func = function()
                    return SUISettings:isTrue("simpleui_style_wallpaper_enabled")
                        and require("sui_homescreen").styleGetWallpaper() ~= nil
                end,
                callback = function()
                    local HS = require("sui_homescreen")
                    HS.styleSetWallpaperShowInFM(not HS.styleGetWallpaperShowInFM())
                    _applyFullLayoutRefresh()
                end,
                keep_menu_open = true,
                separator      = true,
            },
            {
                text = _("Stretch to fill screen"),
                enabled_func = function() return SUISettings:isTrue("simpleui_style_wallpaper_enabled") end,
                checked_func = function() return require("sui_homescreen").styleGetWallpaperStretch() end,
                keep_menu_open = true,
                callback = function()
                    local HS = require("sui_homescreen")
                    HS.styleSetWallpaperStretch(not HS.styleGetWallpaperStretch())
                    _applyFullLayoutRefresh()
                end,
            },
            {
                text = _("Auto-rotate"),
                enabled_func = function() return SUISettings:isTrue("simpleui_style_wallpaper_enabled") end,
                checked_func = function() return require("sui_homescreen").styleGetWallpaperAutoRotate() end,
                keep_menu_open = true,
                callback = function()
                    local HS = require("sui_homescreen")
                    HS.styleSetWallpaperAutoRotate(not HS.styleGetWallpaperAutoRotate())
                    _applyFullLayoutRefresh()
                end,
            },
            {
                text = _("Invert in Night Mode"),
                enabled_func = function() return SUISettings:isTrue("simpleui_style_wallpaper_enabled") end,
                checked_func = function() return require("sui_homescreen").styleGetWallpaperInvertNight() end,
                keep_menu_open = true,
                callback = function()
                    local HS = require("sui_homescreen")
                    HS.styleSetWallpaperInvertNight(not HS.styleGetWallpaperInvertNight())
                    _applyFullLayoutRefresh()
                end,
            },
            {
                text_func = function()
                    return _("Lighten")
                end,
                value_func = function()
                    local HS = require("sui_homescreen")
                    local op = HS.styleGetWallpaperOpacity()
                    return op .. "%"
                end,
                enabled_func = function() return SUISettings:isTrue("simpleui_style_wallpaper_enabled") end,
                keep_menu_open = true,
                callback = function()
                    local HS = require("sui_homescreen")
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text = _("Lighten Wallpaper"),
                        info_text  = _("Fades the wallpaper towards white to improve text readability.\n0% is the default (no lightening)."),
                        value      = HS.styleGetWallpaperOpacity(),
                        value_min  = 0,
                        value_max  = 99,
                        value_step = 5,
                        unit       = "%",
                        ok_text    = _("Apply"),
                        cancel_text = _("Cancel"),
                        default_value = 0,
                        callback = function(spin)
                            HS.styleSetWallpaperOpacity(spin.value)
                            _applyFullLayoutRefresh()
                        end,
                    })
                end,
            },
        }
    end
    plugin.makeWallpaperMenuItems = makeWallpaperMenuItems

    local function makeBehaviourMenuItems(ctx)
        ctx = ctx or HOMESCREEN_CTX
        return {
            {
                text           = _("Start with Home Screen"),
                checked_func   = function()
                    return G_reader_settings:readSetting("start_with") == "homescreen_simpleui"
                end,
                keep_menu_open = true,
                callback       = function()
                    local is_hs = G_reader_settings:readSetting("start_with") == "homescreen_simpleui"
                    G_reader_settings:saveSetting("start_with", is_hs and "filemanager" or "homescreen_simpleui")
                end,
            },
            {
                text_func = function() return _("Scale") end,
                separator = true,
                sub_item_table = {
                    {
                        text_func    = function() return _("Lock Scale") end,
                        checked_func = function() return Config.isScaleLinked() end,
                        keep_menu_open = true,
                        separator = true,
                        callback = function()
                            Config.setScaleLinked(not Config.isScaleLinked())
                            _applyFullLayoutRefresh()
                        end,
                    },
                    {
                        text_func = function()
                            return _("Modules")
                        end,
                        value_func = function() return Config.getModuleScalePct() .. "%" end,
                        keep_menu_open = true,
                        callback = function()
                            local SpinWidget = require("ui/widget/spinwidget")
                            UIManager:show(SpinWidget:new{
                                title_text    = _("Module Scale"),
                                info_text     = Config.isScaleLinked()
                                    and _("Scales all modules and labels together.\n100% is the default size.")
                                    or  _("Global scale for all modules.\nIndividual overrides in Module Settings take precedence.\n100% is the default size."),
                                value         = Config.getModuleScalePct(),
                                value_min     = Config.SCALE_MIN,
                                value_max     = Config.SCALE_MAX,
                                value_step    = Config.SCALE_STEP,
                                unit          = "%",
                                ok_text       = _("Apply"),
                                cancel_text   = _("Cancel"),
                                default_value = Config.SCALE_DEF,
                                callback = function(spin)
                                    Config.setModuleScale(spin.value)
                                    local HS = package.loaded["sui_homescreen"]
                                    if HS and HS.invalidateLabelCache then HS.invalidateLabelCache() end
                                    _applyFullLayoutRefresh()
                                    if ctx and ctx.refresh then ctx.refresh() end
                                end,
                            })
                        end,
                    },
                    {
                        text_func      = function() return _("Labels") end,
                        keep_menu_open = true,
                        callback = function()
                            if Config.isScaleLinked() then
                                local UIManager_  = require("ui/uimanager")
                                local InfoMessage = require("ui/widget/infomessage")
                                UIManager_:show(InfoMessage:new{
                                    text    = _("Disable \"Lock Scale\" first to set a custom label scale."),
                                    timeout = 3,
                                })
                                return
                            end
                            local SpinWidget = require("ui/widget/spinwidget")
                            local UIManager_ = require("ui/uimanager")
                            UIManager_:show(SpinWidget:new{
                                title_text    = _("Label Scale"),
                                info_text     = _("Scales the section label text above each module.\n100% is the default size."),
                                value         = Config.getLabelScalePct(),
                                value_min     = Config.SCALE_MIN,
                                value_max     = Config.SCALE_MAX,
                                value_step    = Config.SCALE_STEP,
                                unit          = "%",
                                ok_text       = _("Apply"),
                                cancel_text   = _("Cancel"),
                                default_value = Config.SCALE_DEF,
                                callback = function(spin)
                                    Config.setLabelScale(spin.value)
                                    local HS = package.loaded["sui_homescreen"]
                                    if HS and HS.invalidateLabelCache then HS.invalidateLabelCache() end
                                    _applyFullLayoutRefresh()
                                    if ctx and ctx.refresh then ctx.refresh() end
                                end,
                            })
                        end,
                    },
                    {
                        text      = _("Reset to Default Scale"),
                        separator = true,
                        callback  = function()
                            local ConfirmBox = require("ui/widget/confirmbox")
                            UIManager:show(ConfirmBox:new{
                                text    = _("Reset all scales to default (100%)? This cannot be undone."),
                                ok_text = _("Reset"),
                                ok_callback = function()
                                    Config.resetAllScales(ctx.pfx, ctx.pfx_qa)
                                    local HS = package.loaded["sui_homescreen"]
                                    if HS and HS.invalidateLabelCache then HS.invalidateLabelCache() end
                                    _applyFullLayoutRefresh()
                                    if ctx and ctx.refresh then ctx.refresh() end
                                end,
                            })
                        end,
                    },
                },
            },
            {
                text           = _("Return to Book Folder"),
                help_text      = _("When closing a book from the Home Screen, go back to the folder where the book is located instead of the Library home folder."),
                checked_func   = function()
                    return SUISettings:isTrue("simpleui_hs_return_to_book_folder")
                end,
                keep_menu_open = true,
                callback       = function()
                    local on = SUISettings:isTrue("simpleui_hs_return_to_book_folder")
                    SUISettings:saveSetting("simpleui_hs_return_to_book_folder", not on)
                end,
            },
            {
                text = _("Closing Book Notice"),
                help_text = _("Show a brief \"Closing book…\" notice when closing a book, preventing accidental double-taps while e-ink refreshes."),
                sub_item_table = {
                    {
                        text = _("Always"),
                        radio = true,
                        keep_menu_open = true,
                        checked_func = function()
                            local mode = SUISettings:readSetting("simpleui_hs_closing_notice_mode")
                            if not mode then return SUISettings:nilOrTrue("simpleui_hs_closing_notice") end
                            return mode == "always"
                        end,
                        callback = function()
                            SUISettings:saveSetting("simpleui_hs_closing_notice_mode", "always")
                        end,
                    },
                    {
                        text = _("Gesture Only"),
                        radio = true,
                        keep_menu_open = true,
                        checked_func = function()
                            return SUISettings:readSetting("simpleui_hs_closing_notice_mode") == "gesture_only"
                        end,
                        callback = function()
                            SUISettings:saveSetting("simpleui_hs_closing_notice_mode", "gesture_only")
                        end,
                    },
                    {
                        text = _("Never"),
                        radio = true,
                        keep_menu_open = true,
                        checked_func = function()
                            local mode = SUISettings:readSetting("simpleui_hs_closing_notice_mode")
                            if not mode then return not SUISettings:nilOrTrue("simpleui_hs_closing_notice") end
                            return mode == "never"
                        end,
                        callback = function()
                            SUISettings:saveSetting("simpleui_hs_closing_notice_mode", "never")
                        end,
                    },
                },
            },
            {
                text           = _("Overflow Warning"),
                help_text      = _("Warn when modules on a page exceed the available screen height."),
                checked_func   = function()
                    return SUISettings:nilOrTrue("simpleui_hs_overflow_warn")
                end,
                keep_menu_open = true,
                callback       = function()
                    local on = SUISettings:nilOrTrue("simpleui_hs_overflow_warn")
                    SUISettings:saveSetting("simpleui_hs_overflow_warn", not on)
                end,
            },
            {
                text           = _("Settings on Long Tap"),
                help_text      = _("When enabled, long-pressing a module on the home screen opens its settings menu.\nDisable this to prevent settings from appearing on long tap."),
                checked_func   = function()
                    return SUISettings:nilOrTrue("simpleui_hs_settings_on_hold")
                end,
                keep_menu_open = true,
                callback       = function()
                    local on = SUISettings:nilOrTrue("simpleui_hs_settings_on_hold")
                    SUISettings:saveSetting("simpleui_hs_settings_on_hold", not on)
                    refreshHomescreen()
                end,
            },
            {
                text           = _("Preserve Deleted Books in Statistics"),
                help_text      = _("When a finished book is deleted from the device, keep it counted in the Books Read statistics on the Home Screen.\n\nBooks changed back to Reading or Abandoned are automatically removed from this list."),
                checked_func   = function()
                    return SUISettings:nilOrTrue("simpleui_preserve_deleted_books_in_stats")
                end,
                keep_menu_open = true,
                callback       = function()
                    local on = SUISettings:nilOrTrue("simpleui_preserve_deleted_books_in_stats")
                    SUISettings:saveSetting("simpleui_preserve_deleted_books_in_stats", not on)
                    local SP = package.loaded["desktop_modules/module_stats_provider"]
                    if SP and SP.invalidate then pcall(SP.invalidate) end
                    refreshHomescreen()
                end,
            },
        }
    end
    plugin.makeBehaviourMenuItems = makeBehaviourMenuItems

    local function makeHomescreenMenu(ctx_menu)
        return {
            {
                text = _("Modules"),
                sub_item_table_func = function() return makeModulesMenu(HOMESCREEN_CTX) end,
            },
            {
                text = _("Wallpaper"),
                sub_item_table_func = makeWallpaperMenuItems,
            },
            {
                text = _("Presets"),
                sub_item_table_func = function()
                    local P = require("sui_presets")
                    return P.makeMenuItems{
                        on_apply       = function()
                            local HS = package.loaded["sui_homescreen"]
                            if HS and HS.rebuildLayout then HS.rebuildLayout() end
                            refreshHomescreen()
                            _applyFullLayoutRefresh()
                        end,
                        on_save        = refreshHomescreen,
                        lock_overlay   = ctx_menu and ctx_menu.lock_overlay,
                        unlock_overlay = ctx_menu and ctx_menu.unlock_overlay,
                    }
                end,
            },
            {
                text = _("Behaviour"),
                sub_item_table_func = function() return makeBehaviourMenuItems(HOMESCREEN_CTX) end,
            },
        }
    end

    local function makeBarsMenuItems(ctx_menu)
        return {
            { text = _("Status Bar"),     sub_item_table_func = function() return makeTopbarMenu(ctx_menu) end },
            { text = _("Navigation Bar"),  sub_item_table_func = function() return makeNavbarMenu(ctx_menu) end },
            { text = _("Title Bar"),      sub_item_table_func = function() return makeTitleBarMenu(ctx_menu) end },
            { text = _("Pagination Bar"), sub_item_table_func = function() return makePaginationBarMenu(ctx_menu) end },
            {
                text = _("Quick Settings Bar"),
                sub_item_table_func = function()
                    local ok, QSBar = pcall(require, "sui_quicksettings_bar")
                    return ok and QSBar.makeMenuItems(ctx_menu) or {}
                end
            },
        }
    end

    plugin.makeBarsMenuItems = makeBarsMenuItems

    local function makeLibraryMenuItems(ctx_menu)
        local ok_fc, FC = pcall(require, "sui_foldercovers")
        if not ok_fc or not FC then return {} end
        -- Refresh the mosaic view immediately after any setting change.
        local function _refreshFC()
            local FM = package.loaded["apps/filemanager/filemanager"]
            local fm = FM and FM.instance
            if fm and fm.file_chooser then
                fm._navbar_suppress_path_change = true
                fm.file_chooser:refreshPath()
                fm._navbar_suppress_path_change = nil
            end
        end
        return {
            -- ── Enable Library Custom Covers ────────────────────────────
            {
                text           = _("Enable Library Custom Covers"),
                checked_func   = function() return FC.isEnabled() end,
                keep_menu_open = true,
                callback       = function()
                    local enabling = not FC.isEnabled()
                    FC.setEnabled(enabling)
                    if enabling then
                        pcall(FC.install)
                    else
                        pcall(FC.uninstall)
                    end
                    _refreshFC()
                end,
            },
            -- ── Enable Browse by Author / Series / Tags ───────────────────────
            {
                text         = _("Enable Browse by Author / Series / Tags"),
                checked_func = function()
                    local ok_bm, BM = pcall(require, "sui_browsemeta")
                    return ok_bm and BM and BM.isEnabled()
                end,
                callback     = function()
                    local ok_bm, BM = pcall(require, "sui_browsemeta")
                    if not (ok_bm and BM) then return end
                    local enabling = not BM.isEnabled()
                    BM.setEnabled(enabling)
                    local FM2 = package.loaded["apps/filemanager/filemanager"]
                    local fm2 = FM2 and FM2.instance
                    if fm2 then
                        local ok_tb, TB = pcall(require, "sui_titlebar")
                        if ok_tb and TB then pcall(TB.restore, fm2) end
                    end
                    if enabling then
                        pcall(BM.install)
                    else
                        local fc2 = fm2 and fm2.file_chooser
                        if fc2 and fc2.path then
                            if fc2.path:find("/\u{E257}", 1, true) then
                                BM.exitToNormal(fc2, fm2)
                            end
                        end
                        BM.setSavedMode("normal")
                        pcall(BM.uninstall)
                    end
                    if fm2 then
                        local ok_tb, TB = pcall(require, "sui_titlebar")
                        if ok_tb and TB then pcall(TB.apply, fm2) end
                    end
                end,
            },
            -- ── Group by Book Series ──────────────────────────────────────────
            {
                text           = _("Group by Book Series"),
                checked_func   = function() return FC.getSeriesGrouping() end,
                keep_menu_open = true,
                separator      = true,
                enabled_func   = function() return FC.isEnabled() end,
                callback       = function()
                    FC.setSeriesGrouping(not FC.getSeriesGrouping())
                    FC.invalidateCache()
                    _refreshFC()
                end,
            },
            -- ── Cover Settings ───────────────────────────────────
            {
                text         = _("Cover Settings"),
                enabled_func = function() return FC.isEnabled() end,
                sub_item_table = {
                    -- ── Folder Cover Type ──────────────────────────────────────
                    {
                        text         = _("Folder Cover Type"),
                        sub_item_table = {
                            {
                                text           = _("Single Cover"),
                                radio          = true,
                                checked_func   = function() return FC.getFolderStyle() == "single" end,
                                keep_menu_open = true,
                                callback       = function()
                                    FC.setFolderStyle("single")
                                    FC.invalidateCache()
                                    _refreshFC()
                                end,
                            },
                            {
                                text           = _("4-Cover Grid (Mosaic View Only)"),
                                radio          = true,
                                checked_func   = function() return FC.getFolderStyle() == "quad" end,
                                keep_menu_open = true,
                                callback       = function()
                                    FC.setFolderStyle("quad")
                                    FC.invalidateCache()
                                    _refreshFC()
                                end,
                            },
                            {
                                text           = _("Auto (Single ↔ 4-Cover Grid)"),
                                radio          = true,
                                checked_func   = function() return FC.getFolderStyle() == "auto" end,
                                keep_menu_open = true,
                                callback       = function()
                                    FC.setFolderStyle("auto")
                                    FC.invalidateCache()
                                    _refreshFC()
                                end,
                            },
                        },
                    },
                    -- ── Overlays ───────────────────────────────────────────────
                    {
                        text         = _("Overlays"),
                        sub_item_table = {
                            -- ── Badges ────────────────────────────────────────
                            {
                                text         = _("Badges"),
                                sub_item_table = {
                                    -- ── Size ──────────────────────────────────────────────
                                    {
                                        text_func      = function() return _("Size") end,
                                        value_func     = function() return FC.getBadgeScalePct() .. "%" end,
                                        keep_menu_open = true,
                                        separator      = true,
                                        callback = function()
                                            local SpinWidget = require("ui/widget/spinwidget")
                                            local UIM = ctx_menu and ctx_menu.UIManager or UIManager
                                            UIM:show(SpinWidget:new{
                                                title_text    = _("Badge Size"),
                                                info_text     = _("Scale for the library badges (progress, pages, etc.).\n100% is the default size."),
                                                value         = FC.getBadgeScalePct(),
                                                value_min     = FC.FC_BADGE_SCALE_MIN,
                                                value_max     = FC.FC_BADGE_SCALE_MAX,
                                                value_step    = FC.FC_BADGE_SCALE_STEP,
                                                unit          = "%",
                                                ok_text       = _("Apply"),
                                                cancel_text   = _("Cancel"),
                                                default_value = FC.FC_BADGE_SCALE_DEF,
                                                callback      = function(spin)
                                                    FC.setBadgeScale(spin.value)
                                                    FC.invalidateCache()
                                                    _refreshFC()
                                                end,
                                            })
                                        end,
                                    },
                                    -- ── Number of Books in Folder ─────────────────────────
                                    {
                                        text_func  = function() return _("Number of Books in Folder") end,
                                        value_func = function()
                                            if FC.getBadgeHidden() then return _("Hidden") end
                                            return FC.getBadgePosition() == "top" and _("Top") or _("Bottom")
                                        end,
                                        sub_item_table = {
                                            {
                                                text_func  = function() return _("Position") end,
                                                value_func = function()
                                                    if FC.getBadgeHidden() then return _("Hidden") end
                                                    return FC.getBadgePosition() == "top" and _("Top") or _("Bottom")
                                                end,
                                                sub_item_table = {
                                                    {
                                                        text           = _("Top"),
                                                        radio          = true,
                                                        checked_func   = function() return not FC.getBadgeHidden() and FC.getBadgePosition() == "top" end,
                                                        keep_menu_open = true,
                                                        callback       = function()
                                                            FC.setBadgeHidden(false)
                                                            FC.setBadgePosition("top")
                                                            FC.invalidateCache(); _refreshFC()
                                                        end,
                                                    },
                                                    {
                                                        text           = _("Bottom"),
                                                        radio          = true,
                                                        checked_func   = function() return not FC.getBadgeHidden() and FC.getBadgePosition() == "bottom" end,
                                                        keep_menu_open = true,
                                                        callback       = function()
                                                            FC.setBadgeHidden(false)
                                                            FC.setBadgePosition("bottom")
                                                            FC.invalidateCache(); _refreshFC()
                                                        end,
                                                    },
                                                    {
                                                        text           = _("Hidden"),
                                                        radio          = true,
                                                        checked_func   = function() return FC.getBadgeHidden() end,
                                                        keep_menu_open = true,
                                                        callback       = function()
                                                            FC.setBadgeHidden(true)
                                                            FC.invalidateCache(); _refreshFC()
                                                        end,
                                                    },
                                                },
                                            },
                                            {
                                                text_func    = function() return _("Color") end,
                                                value_func   = function()
                                                    return FC.getBadgeColorFolder() == "dark" and _("Dark") or _("Light")
                                                end,
                                                enabled_func = function() return not FC.getBadgeHidden() end,
                                                sub_item_table = {
                                                    {
                                                        text           = _("Dark"),
                                                        radio          = true,
                                                        checked_func   = function() return FC.getBadgeColorFolder() == "dark" end,
                                                        keep_menu_open = true,
                                                        callback       = function() FC.setBadgeColorFolder("dark"); FC.invalidateCache(); _refreshFC() end,
                                                    },
                                                    {
                                                        text           = _("Light"),
                                                        radio          = true,
                                                        checked_func   = function() return FC.getBadgeColorFolder() == "light" end,
                                                        keep_menu_open = true,
                                                        callback       = function() FC.setBadgeColorFolder("light"); FC.invalidateCache(); _refreshFC() end,
                                                    },
                                                },
                                            },
                                        },
                                    },
                                    -- ── Number of Pages ───────────────────────────────────
                                    {
                                        text_func  = function() return _("Number of Pages") end,
                                        value_func = function()
                                            return FC.getOverlayPages() and _("Visible") or _("Hidden")
                                        end,
                                        sub_item_table = {
                                            {
                                                text_func  = function() return _("Visibility") end,
                                                value_func = function()
                                                    return FC.getOverlayPages() and _("Visible") or _("Hidden")
                                                end,
                                                sub_item_table = {
                                                    {
                                                        text           = _("Visible"),
                                                        radio          = true,
                                                        checked_func   = function() return FC.getOverlayPages() end,
                                                        keep_menu_open = true,
                                                        callback       = function() FC.setOverlayPages(true); FC.invalidateCache(); _refreshFC() end,
                                                    },
                                                    {
                                                        text           = _("Hidden"),
                                                        radio          = true,
                                                        checked_func   = function() return not FC.getOverlayPages() end,
                                                        keep_menu_open = true,
                                                        callback       = function() FC.setOverlayPages(false); FC.invalidateCache(); _refreshFC() end,
                                                    },
                                                },
                                            },
                                            {
                                                text_func    = function() return _("Color") end,
                                                value_func   = function()
                                                    return FC.getBadgeColorPages() == "dark" and _("Dark") or _("Light")
                                                end,
                                                enabled_func = function() return FC.getOverlayPages() end,
                                                sub_item_table = {
                                                    {
                                                        text           = _("Dark"),
                                                        radio          = true,
                                                        checked_func   = function() return FC.getBadgeColorPages() == "dark" end,
                                                        keep_menu_open = true,
                                                        callback       = function() FC.setBadgeColorPages("dark"); FC.invalidateCache(); _refreshFC() end,
                                                    },
                                                    {
                                                        text           = _("Light"),
                                                        radio          = true,
                                                        checked_func   = function() return FC.getBadgeColorPages() == "light" end,
                                                        keep_menu_open = true,
                                                        callback       = function() FC.setBadgeColorPages("light"); FC.invalidateCache(); _refreshFC() end,
                                                    },
                                                },
                                            },
                                        },
                                    },
                                    -- ── Series Index ──────────────────────────────────────
                                    {
                                        text_func  = function() return _("Series Index") end,
                                        value_func = function()
                                            return FC.getOverlaySeries() and _("Visible") or _("Hidden")
                                        end,
                                        sub_item_table = {
                                            {
                                                text_func  = function() return _("Visibility") end,
                                                value_func = function()
                                                    return FC.getOverlaySeries() and _("Visible") or _("Hidden")
                                                end,
                                                sub_item_table = {
                                                    {
                                                        text           = _("Visible"),
                                                        radio          = true,
                                                        checked_func   = function() return FC.getOverlaySeries() end,
                                                        keep_menu_open = true,
                                                        callback       = function() FC.setOverlaySeries(true); FC.invalidateCache(); _refreshFC() end,
                                                    },
                                                    {
                                                        text           = _("Hidden"),
                                                        radio          = true,
                                                        checked_func   = function() return not FC.getOverlaySeries() end,
                                                        keep_menu_open = true,
                                                        callback       = function() FC.setOverlaySeries(false); FC.invalidateCache(); _refreshFC() end,
                                                    },
                                                },
                                            },
                                            {
                                                text_func    = function() return _("Color") end,
                                                value_func   = function()
                                                    return FC.getBadgeColorSeries() == "dark" and _("Dark") or _("Light")
                                                end,
                                                enabled_func = function() return FC.getOverlaySeries() end,
                                                sub_item_table = {
                                                    {
                                                        text           = _("Dark"),
                                                        radio          = true,
                                                        checked_func   = function() return FC.getBadgeColorSeries() == "dark" end,
                                                        keep_menu_open = true,
                                                        callback       = function() FC.setBadgeColorSeries("dark"); FC.invalidateCache(); _refreshFC() end,
                                                    },
                                                    {
                                                        text           = _("Light"),
                                                        radio          = true,
                                                        checked_func   = function() return FC.getBadgeColorSeries() == "light" end,
                                                        keep_menu_open = true,
                                                        callback       = function() FC.setBadgeColorSeries("light"); FC.invalidateCache(); _refreshFC() end,
                                                    },
                                                },
                                            },
                                        },
                                    },
                                    -- ── Progress ──────────────────────────────────────────
                                    {
                                        text_func  = function() return _("Progress") end,
                                        value_func = function()
                                            local m = FC.getProgressMode()
                                            if m == "banner" then return _("Banner")
                                            elseif m == "native" then return _("Native")
                                            else return _("None") end
                                        end,
                                        sub_item_table = {
                                            {
                                                text_func  = function() return _("Type") end,
                                                value_func = function()
                                                    local m = FC.getProgressMode()
                                                    if m == "banner" then return _("Banner")
                                                    elseif m == "native" then return _("Native")
                                                    else return _("None") end
                                                end,
                                                sub_item_table = {
                                                    {
                                                        text           = _("Banner"),
                                                        radio          = true,
                                                        checked_func   = function() return FC.getProgressMode() == "banner" end,
                                                        keep_menu_open = true,
                                                        callback       = function() FC.setProgressMode("banner"); FC.invalidateCache(); _refreshFC() end,
                                                    },
                                                    {
                                                        text           = _("Native"),
                                                        radio          = true,
                                                        checked_func   = function() return FC.getProgressMode() == "native" end,
                                                        keep_menu_open = true,
                                                        callback       = function() FC.setProgressMode("native"); FC.invalidateCache(); _refreshFC() end,
                                                    },
                                                    {
                                                        text           = _("None"),
                                                        radio          = true,
                                                        checked_func   = function() return FC.getProgressMode() == "none" end,
                                                        keep_menu_open = true,
                                                        callback       = function() FC.setProgressMode("none"); FC.invalidateCache(); _refreshFC() end,
                                                    },
                                                },
                                            },
                                            {
                                                text_func    = function() return _("Color") end,
                                                value_func   = function()
                                                    return FC.getBadgeColorProgress() == "dark" and _("Dark") or _("Light")
                                                end,
                                                enabled_func = function() return FC.getProgressMode() ~= "none" end,
                                                sub_item_table = {
                                                    {
                                                        text           = _("Dark"),
                                                        radio          = true,
                                                        checked_func   = function() return FC.getBadgeColorProgress() == "dark" end,
                                                        keep_menu_open = true,
                                                        callback       = function() FC.setBadgeColorProgress("dark"); FC.invalidateCache(); _refreshFC() end,
                                                    },
                                                    {
                                                        text           = _("Light"),
                                                        radio          = true,
                                                        checked_func   = function() return FC.getBadgeColorProgress() == "light" end,
                                                        keep_menu_open = true,
                                                        callback       = function() FC.setBadgeColorProgress("light"); FC.invalidateCache(); _refreshFC() end,
                                                    },
                                                },
                                            },
                                        },
                                    },
                                    -- ── New Book ──────────────────────────────────────────
                                    {
                                        text_func  = function() return _("New Book") end,
                                        value_func = function()
                                            local m = FC.getNewMode()
                                            if m == "badge" then return _("Badge")
                                            elseif m == "ribbon" then return _("Ribbon")
                                            else return _("None") end
                                        end,
                                        sub_item_table = {
                                            {
                                                text_func  = function() return _("Type") end,
                                                value_func = function()
                                                    local m = FC.getNewMode()
                                                    if m == "badge" then return _("Badge")
                                                    elseif m == "ribbon" then return _("Ribbon")
                                                    else return _("None") end
                                                end,
                                                sub_item_table = {
                                                    {
                                                        text           = _("Badge"),
                                                        radio          = true,
                                                        checked_func   = function() return FC.getNewMode() == "badge" end,
                                                        keep_menu_open = true,
                                                        callback       = function() FC.setNewMode("badge"); FC.invalidateCache(); _refreshFC() end,
                                                    },
                                                    {
                                                        text           = _("Ribbon"),
                                                        radio          = true,
                                                        checked_func   = function() return FC.getNewMode() == "ribbon" end,
                                                        keep_menu_open = true,
                                                        callback       = function() FC.setNewMode("ribbon"); FC.invalidateCache(); _refreshFC() end,
                                                    },
                                                    {
                                                        text           = _("None"),
                                                        radio          = true,
                                                        checked_func   = function() return FC.getNewMode() == "none" end,
                                                        keep_menu_open = true,
                                                        callback       = function() FC.setNewMode("none"); FC.invalidateCache(); _refreshFC() end,
                                                    },
                                                },
                                            },
                                            {
                                                text_func    = function() return _("Color") end,
                                                value_func   = function()
                                                    return FC.getBadgeColorNew() == "dark" and _("Dark") or _("Light")
                                                end,
                                                enabled_func = function() return FC.getNewMode() ~= "none" end,
                                                sub_item_table = {
                                                    {
                                                        text           = _("Dark"),
                                                        radio          = true,
                                                        checked_func   = function() return FC.getBadgeColorNew() == "dark" end,
                                                        keep_menu_open = true,
                                                        callback       = function() FC.setBadgeColorNew("dark"); FC.invalidateCache(); _refreshFC() end,
                                                    },
                                                    {
                                                        text           = _("Light"),
                                                        radio          = true,
                                                        checked_func   = function() return FC.getBadgeColorNew() == "light" end,
                                                        keep_menu_open = true,
                                                        callback       = function() FC.setBadgeColorNew("light"); FC.invalidateCache(); _refreshFC() end,
                                                    },
                                                },
                                            },
                                        },
                                    },
                                },
                            },
                            -- ── Finished Books ────────────────────────────────────────────────
                            {
                                text_func  = function() return _("Finished Books") end,
                                value_func = function()
                                    if not FC.getFadeFinished() then return _("Off") end
                                    return FC.getFadeAmountPct() .. "%"
                                end,
                                sub_item_table = {
                                    {
                                        text           = _("Fade Finished Books"),
                                        checked_func   = function() return FC.getFadeFinished() end,
                                        keep_menu_open = true,
                                        callback       = function()
                                            FC.setFadeFinished(not FC.getFadeFinished())
                                            _refreshFC()
                                        end,
                                    },
                                    {
                                        text_func    = function() return _("Intensity") end,
                                        value_func   = function() return FC.getFadeAmountPct() .. "%" end,
                                        enabled_func = function() return FC.getFadeFinished() end,
                                        keep_menu_open = true,
                                        callback = function()
                                            local SpinWidget = require("ui/widget/spinwidget")
                                            UIManager:show(SpinWidget:new{
                                                title_text    = _("Fade Intensity"),
                                                info_text     = _("Fades finished book covers towards white.\n50% is the default."),
                                                value         = FC.getFadeAmountPct(),
                                                value_min     = FC.FADE_AMOUNT_MIN,
                                                value_max     = FC.FADE_AMOUNT_MAX,
                                                value_step    = FC.FADE_AMOUNT_STEP,
                                                unit          = "%",
                                                ok_text       = _("Apply"),
                                                cancel_text   = _("Cancel"),
                                                default_value = FC.FADE_AMOUNT_DEF,
                                                callback = function(spin)
                                                    FC.setFadeAmountPct(spin.value)
                                                    _refreshFC()
                                                end,
                                            })
                                        end,
                                    },
                                },
                            },
                            -- ── Folder Name ───────────────────────────────────────────────────
                            {
                                text         = _("Folder Name"),
                                enabled_func = function() return not FC.getShowTitleStrip() end,
                                sub_item_table = {
                                    {
                                        text_func  = function() return _("Visibility") end,
                                        value_func = function()
                                            if FC.getLabelMode() == "hidden" then return _("Hidden") end
                                            return FC.getLabelStyle() == "alpha" and _("Transparent") or _("Solid")
                                        end,
                                        sub_item_table = {
                                            {
                                                text           = _("Solid"),
                                                radio          = true,
                                                checked_func   = function()
                                                    return FC.getLabelMode() ~= "hidden" and FC.getLabelStyle() == "solid"
                                                end,
                                                keep_menu_open = true,
                                                callback       = function()
                                                    FC.setLabelMode("overlay")
                                                    FC.setLabelStyle("solid")
                                                    _refreshFC()
                                                end,
                                            },
                                            {
                                                text           = _("Transparent"),
                                                radio          = true,
                                                checked_func   = function()
                                                    return FC.getLabelMode() ~= "hidden" and FC.getLabelStyle() == "alpha"
                                                end,
                                                keep_menu_open = true,
                                                callback       = function()
                                                    FC.setLabelMode("overlay")
                                                    FC.setLabelStyle("alpha")
                                                    _refreshFC()
                                                end,
                                            },
                                            {
                                                text           = _("Hidden"),
                                                radio          = true,
                                                checked_func   = function() return FC.getLabelMode() == "hidden" end,
                                                keep_menu_open = true,
                                                callback       = function()
                                                    FC.setLabelMode("hidden")
                                                    _refreshFC()
                                                end,
                                            },
                                        },
                                    },
                                    {
                                        text_func  = function() return _("Position") end,
                                        value_func = function()
                                            local p = FC.getLabelPosition()
                                            if p == "top" then return _("Top")
                                            elseif p == "center" then return _("Center")
                                            else return _("Bottom") end
                                        end,
                                        enabled_func = function() return FC.getLabelMode() ~= "hidden" end,
                                        sub_item_table = {
                                            {
                                                text           = _("Top"),
                                                radio          = true,
                                                checked_func   = function() return FC.getLabelPosition() == "top" end,
                                                keep_menu_open = true,
                                                callback       = function() FC.setLabelPosition("top"); _refreshFC() end,
                                            },
                                            {
                                                text           = _("Center"),
                                                radio          = true,
                                                checked_func   = function() return FC.getLabelPosition() == "center" end,
                                                keep_menu_open = true,
                                                callback       = function() FC.setLabelPosition("center"); _refreshFC() end,
                                            },
                                            {
                                                text           = _("Bottom"),
                                                radio          = true,
                                                checked_func   = function() return FC.getLabelPosition() == "bottom" end,
                                                keep_menu_open = true,
                                                callback       = function() FC.setLabelPosition("bottom"); _refreshFC() end,
                                            },
                                        },
                                    },
                                    (function()
                                        local Config = require("sui_config")
                                        return Config.makeScaleItem({
                                            text_func    = function() return _("Text Size") end,
                                            enabled_func = function() return FC.getLabelMode() ~= "hidden" end,
                                            title        = _("Folder Name Text Size"),
                                            info         = _("Scale for the folder name overlay text.\n100% is the default size."),
                                            get          = function() return FC.getLabelScalePct() end,
                                            set          = function(v) FC.setLabelScale(v) end,
                                            refresh      = function() FC.invalidateCache(); _refreshFC() end,
                                        })
                                    end)(),
                                },
                            },
                            -- ── Title and Author Below Covers ─────────────────────────────────
                            {
                                text         = _("Title and Author Below Covers"),
                                sub_item_table = {
                                    {
                                        text           = _("Off"),
                                        radio          = true,
                                        checked_func   = function()
                                            return not FC.getShowTitleStrip() and not FC.getShowAuthorStrip()
                                        end,
                                        keep_menu_open = true,
                                        callback       = function()
                                            if FC.getShowTitleStrip() or FC.getShowAuthorStrip() then
                                                FC.setShowTitleStrip(false)
                                                FC.setShowAuthorStrip(false)
                                                local CB = ctx_menu and ctx_menu.ConfirmBox or ConfirmBox()
                                                local UIM = ctx_menu and ctx_menu.UIManager or UIManager
                                                UIM:show(CB:new{
                                                    text        = _("Title strip disabled.\n\nRestart now?"),
                                                    ok_text     = _("Restart"), cancel_text = _("Later"),
                                                    ok_callback = function()
                                                        SUISettings:flush()
                                                        UIM:restartKOReader()
                                                    end,
                                                })
                                            end
                                        end,
                                    },
                                    {
                                        text           = _("Title only"),
                                        radio          = true,
                                        checked_func   = function()
                                            return FC.getShowTitleStrip() and not FC.getShowAuthorStrip()
                                        end,
                                        keep_menu_open = true,
                                        callback       = function()
                                            FC.setShowTitleStrip(true)
                                            FC.setShowAuthorStrip(false)
                                            local CB = ctx_menu and ctx_menu.ConfirmBox or ConfirmBox()
                                            local UIM = ctx_menu and ctx_menu.UIManager or UIManager
                                            UIM:show(CB:new{
                                                text        = _("Title strip enabled.\n\nRestart now?"),
                                                ok_text     = _("Restart"), cancel_text = _("Later"),
                                                ok_callback = function()
                                                    SUISettings:flush()
                                                    UIM:restartKOReader()
                                                end,
                                            })
                                        end,
                                    },
                                    {
                                        text           = _("Title and Author"),
                                        radio          = true,
                                        checked_func   = function()
                                            return FC.getShowTitleStrip() and FC.getShowAuthorStrip()
                                        end,
                                        keep_menu_open = true,
                                        callback       = function()
                                            FC.setShowTitleStrip(true)
                                            FC.setShowAuthorStrip(true)
                                            local CB = ctx_menu and ctx_menu.ConfirmBox or ConfirmBox()
                                            local UIM = ctx_menu and ctx_menu.UIManager or UIManager
                                            UIM:show(CB:new{
                                                text        = _("Title and author strip enabled.\n\nRestart now?"),
                                                ok_text     = _("Restart"), cancel_text = _("Later"),
                                                ok_callback = function()
                                                    SUISettings:flush()
                                                    UIM:restartKOReader()
                                                end,
                                            })
                                        end,
                                    },
                                },
                            },
                        },
                    },
                    -- ── Uniformize Covers (2:3) ────────────────────────────────
                    {
                        text           = _("Uniformize Covers (2:3)"),
                        checked_func   = function() return FC.getCoverMode() == "2_3" end,
                        keep_menu_open = true,
                        callback       = function()
                            FC.setCoverMode(FC.getCoverMode() == "2_3" and "default" or "2_3")
                            _refreshFC()
                        end,
                    },
                    {
                        text           = _("Hide Selection Underline"),
                        checked_func   = function() return FC.getHideUnderline() end,
                        keep_menu_open = true,
                        callback       = function() FC.setHideUnderline(not FC.getHideUnderline()); _refreshFC() end,
                    },
                    {
                        text           = _("Hide Folder Book Spine"),
                        checked_func   = function() return FC.getHideSpine() end,
                        keep_menu_open = true,
                        callback       = function()
                            FC.setHideSpine(not FC.getHideSpine())
                            FC.invalidateCache()
                            _refreshFC()
                        end,
                    },
                    {
                        text           = _("Placeholder Cover for Bookless Folders"),
                        checked_func   = function() return FC.getSubfolderCover() end,
                        keep_menu_open = true,
                        callback       = function()
                            FC.setSubfolderCover(not FC.getSubfolderCover())
                            if not FC.getSubfolderCover() then
                                FC.setRecursiveCover(false)
                            end
                            FC.invalidateCache()
                            _refreshFC()
                        end,
                    },
                    {
                        text           = _("Scan Subfolders for Covers"),
                        checked_func   = function() return FC.getRecursiveCover() end,
                        enabled_func   = function() return FC.getSubfolderCover() end,
                        keep_menu_open = true,
                        callback       = function()
                            FC.setRecursiveCover(not FC.getRecursiveCover())
                            FC.invalidateCache()
                            _refreshFC()
                        end,
                    },
                },
            },
            -- ── Library View ─────────────────────────────────────────────────
            -- Expõe apenas os 3 items de items-por-página do CoverBrowser:
            --   • Items per page in portrait mosaic mode
            --   • Items per page in landscape mosaic mode
            --   • Items per page in portrait list mode
            -- Os restantes items (Progress, Display hints, Series, cache, etc.)
            -- são omitidos intencionalmente.
            {
                text      = _("Display"),
                separator = true,
                sub_item_table_func = function()
                    -- CoverBrowser é registado como fm.coverbrowser via
                    -- FileManager:registerModule(plugin_module.name, ...).
                    -- Chamamos addToMainMenu com uma tabela temporária para
                    -- obter os items sem depender de setUpdateItemTable ter
                    -- sido invocado (que só acontece ao abrir o menu nativo).
                    local FM = package.loaded["apps/filemanager/filemanager"]
                    local fm = FM and FM.instance
                    local cb = fm and fm.coverbrowser
                    if not cb or type(cb.addToMainMenu) ~= "function" then
                        return {}
                    end

                    -- Pré-populamos filebrowser_settings com um stub para que
                    -- CoverBrowser não saia cedo no check
                    -- `if menu_items.filebrowser_settings == nil then return end`
                    -- e injete o item "Mosaic and detailed list settings".
                    local tmp = {
                        filebrowser_settings = {
                            sub_item_table = {
                                {}, -- placeholder pos 1 (Show hidden files)
                                {}, -- placeholder pos 2 (Show unsupported files)
                                {}, -- placeholder pos 3 (Classic mode settings)
                            },
                        },
                    }
                    local ok = pcall(cb.addToMainMenu, cb, tmp)
                    if not ok then return {} end

                    local items = {}

                    -- 1. "Display mode" — radio mosaic/list/classic (intacto)
                    if tmp.filemanager_display_mode then
                        table.insert(items, tmp.filemanager_display_mode)
                    end

                    -- 2. "Mosaic and detailed list settings" filtrado:
                    --    apenas os 3 primeiros items (spinners de grid/lista).
                    --    O CoverBrowser insere na pos 4+ do stub.
                    local mosaic_item
                    for i, child in ipairs(tmp.filebrowser_settings.sub_item_table) do
                        if i > 3 and (child.text or child.text_func) then
                            mosaic_item = child
                            break
                        end
                    end

                    if mosaic_item and type(mosaic_item.sub_item_table) == "table" then
                        -- Os 3 primeiros entries são sempre:
                        --   [1] Items per page in portrait mosaic mode  (DoubleSpinWidget)
                        --   [2] Items per page in landscape mosaic mode (DoubleSpinWidget, separator=true)
                        --   [3] Items per page in portrait list mode    (SpinWidget)
                        -- Clonamos [2] sem o separator para não partir o visual.
                        local filtered = {}
                        for i = 1, 3 do
                            local entry = mosaic_item.sub_item_table[i]
                            if not entry then break end
                            if i == 2 then
                                local clean = {}
                                for k, v in pairs(entry) do clean[k] = v end
                                clean.separator = nil
                                table.insert(filtered, clean)
                            else
                                table.insert(filtered, entry)
                            end
                        end
                        table.insert(items, {
                            text           = mosaic_item.text,
                            separator      = mosaic_item.separator,
                            sub_item_table = filtered,
                        })
                    end

                    return items
                end,
            },
        }
    end
    plugin.makeLibraryMenuItems = makeLibraryMenuItems

    plugin.makeStyleMenuItems = function(ctx_menu)
        return {
            -- ── Icons (sub-folder) ─────────────────────────────────────
            {
                text = _("Icons"),
                sub_item_table = {
                    -- ── System Icons ──────────────────────────────────────────
                    {
                        text_func = function()
                            local ok_ss, SUIStyle = pcall(require, "sui_style")
                            if not ok_ss or not SUIStyle then return _("System Icons") end
                            local has_custom = false
                            for _, s in ipairs(SUIStyle.SLOTS) do
                                if s.group ~= "sui_qa_defaults" and SUIStyle.getIcon(s.id) ~= nil then
                                    has_custom = true
                                    break
                                end
                            end
                            return _("System Icons") .. (has_custom and "  \u{270E}" or "")
                        end,
                        sub_item_table_func = function()
                            local ok_ss, SUIStyle = pcall(require, "sui_style")
                            if not ok_ss or not SUIStyle then return {} end
                            return SUIStyle.makeMenuItems(plugin)
                        end,
                        sui_build = ctx_menu and ctx_menu.is_sui and function(ctx, _item)
                            local SUIWindow = require("sui_window")
                            return SUIWindow.ListRow{
                                title        = type(_item.text_func) == "function" and _item.text_func() or _item.text,
                                inner_w      = ctx.inner_w,
                                show_chevron = true,
                                on_tap       = function()
                                    local SUIStyle = require("sui_style")
                                    if SUIStyle.sui_build_system_icons then SUIStyle.sui_build_system_icons(plugin, ctx_menu, ctx) end
                                end
                            }
                        end or nil,
                    },
                    -- ── Quick Actions Icons ────────────────────────────────────
                    {
                        text_func = function()
                            local has_custom = false
                            local ok_qa, QA2 = pcall(require, "sui_quickactions")
                            if ok_qa and QA2 then
                                for _, a in ipairs(Config.ALL_ACTIONS) do
                                    if QA2.getDefaultActionIcon(a.id) ~= nil then
                                        has_custom = true
                                        break
                                    end
                                end
                            if not has_custom and QA2.getDefaultActionIcon("wifi_toggle_off") ~= nil then
                                has_custom = true
                            end
                            end
                            if not has_custom then
                                for _i, qa_id in ipairs(Config.getCustomQAList()) do
                                    local c = Config.getCustomQAConfig(qa_id)
                                    if c.icon ~= nil
                                        and c.icon ~= Config.CUSTOM_ICON
                                        and c.icon ~= Config.CUSTOM_PLUGIN_ICON
                                        and c.icon ~= Config.CUSTOM_DISPATCHER_ICON
                                    then
                                        has_custom = true
                                        break
                                    end
                                end
                            end
                            if not has_custom then
                                local ok_ss, SUIStyle = pcall(require, "sui_style")
                                if ok_ss and SUIStyle then
                                    for _, s in ipairs(SUIStyle.SLOTS) do
                                        if s.group == "sui_qa_defaults" and SUIStyle.getIcon(s.id) ~= nil then
                                            has_custom = true
                                            break
                                        end
                                    end
                                end
                            end
                            return _("Quick Actions Icons") .. (has_custom and "  \u{270E}" or "")
                        end,
                        sub_item_table_func = function()
                            local ok_qa, QA2 = pcall(require, "sui_quickactions")
                            if not ok_qa or not QA2 then return {} end
                            return QA2.makeIconsMenuItems(plugin)
                        end,
                        sui_build = ctx_menu and ctx_menu.is_sui and function(ctx, _item)
                            local SUIWindow = require("sui_window")
                            return SUIWindow.ListRow{
                                title        = type(_item.text_func) == "function" and _item.text_func() or _item.text,
                                inner_w      = ctx.inner_w,
                                show_chevron = true,
                                on_tap       = function()
                                    local QA2 = require("sui_quickactions")
                                    if QA2.sui_build_qa_icons then QA2.sui_build_qa_icons(plugin, ctx_menu, ctx) end
                                end
                            }
                        end or nil,
                    },
                    -- ── Icon Packs ────────────────────────────────────────────
                    {
                        text = _("Icon Packs"),
                        sub_item_table_func = function()
                            local ok_ip, IP = pcall(require, "sui_style")
                            if not ok_ip or not IP then
                                return {{ text = _("Module unavailable"), enabled = false }}
                            end

                            -- ── Helper: reapply all icon changes ─────────────────
                            local function _reapplyAllPacks()
                                -- Titlebar (system icons)
                                local ok_tb, TB = pcall(require, "sui_titlebar")
                                if ok_tb and TB then
                                    local FM = package.loaded["apps/filemanager/filemanager"]
                                    local fm = FM and FM.instance
                                    if fm then
                                        pcall(TB.reapplyAll, fm, UIManager._window_stack)
                                    end
                                    if TB.refreshBrowseIcons and fm then
                                        TB.refreshBrowseIcons(fm)
                                    end
                                end
                                -- Pagination chevrons and collections back button
                                local ok_ss2, SS2 = pcall(require, "sui_style")
                                if ok_ss2 and SS2 then
                                    local FM2 = package.loaded["apps/filemanager/filemanager"]
                                    local fm2 = FM2 and FM2.instance
                                    if fm2 and fm2.file_chooser then
                                        pcall(SS2.applyPaginationIcons, fm2.file_chooser)
                                    end
                                    local ok_ui2, UIManager2 = pcall(require, "ui/uimanager")
                                    if ok_ui2 then
                                        for _, entry in ipairs(UIManager2._window_stack or {}) do
                                            local w = entry.widget
                                            if w and w.page_info_left_chev then
                                                pcall(SS2.applyPaginationIcons, w)
                                            end
                                            if w and (w.name == "collections" or w.name == "coll_list") then
                                                pcall(SS2.applyCollBackIcon, w)
                                            end
                                        end
                                    end
                                end

                                -- Invalidate Quick Actions & Folder Covers caches
                                local ok_qa, QA_pack = pcall(require, "sui_quickactions")
                                if ok_qa and QA_pack and QA_pack.invalidateCustomQACache then QA_pack.invalidateCustomQACache() end
                                local ok_fc, FC = pcall(require, "sui_foldercovers")
                                if ok_fc and FC and FC.invalidateCache then FC.invalidateCache() end
                                local FM = package.loaded["apps/filemanager/filemanager"]
                                local fm_inst = FM and FM.instance
                                if fm_inst and fm_inst.file_chooser then
                                    fm_inst._navbar_suppress_path_change = true
                                    fm_inst.file_chooser:refreshPath()
                                    fm_inst._navbar_suppress_path_change = nil
                                end

                                -- QA navbars
                                plugin:_rebuildAllNavbars()
                                -- Homescreen
                                local HS = package.loaded["sui_homescreen"]
                                if HS and HS._instance then
                                    local hs = HS._instance
                                    UIManager:nextTick(function()
                                        if HS._instance == hs then
                                            HS._instance:_refreshImmediate(false)
                                        end
                                    end)
                                end
                            end

                            local items = {}

                            -- ── Install zip ───────────────────────────────────────
                            items[#items + 1] = {
                                text = _("Install pack from ZIP"),
                                sub_item_table_func = function()
                                    local sub = {}
                                    local dir = IP.getPacksDir()
                                    local lfs = require("libs/libkoreader-lfs")
                                    local T   = require("ffi/util").template
                                    local zips = {}
                                    if dir and lfs.attributes(dir, "mode") == "directory" then
                                        for fname in lfs.dir(dir) do
                                            if fname ~= "." and fname ~= ".." and fname:lower():match("%.zip$") then
                                                zips[#zips + 1] = { name = fname, path = dir .. "/" .. fname }
                                            end
                                        end
                                        table.sort(zips, function(a, b) return a.name:lower() < b.name:lower() end)
                                    end

                                    if #zips == 0 then
                                        sub[#sub + 1] = {
                                            text    = T(_("No .zip files found.\nPlace .zip files in:\n%1"), dir or ""),
                                            enabled = false,
                                        }
                                    else
                                        for _i, z in ipairs(zips) do
                                            local _z = z
                                            sub[#sub + 1] = {
                                                text     = _z.name,
                                                callback = function()
                                                    local pack_name, err = IP.installZip(_z.path)
                                                    if pack_name then
                                                        UIManager:show(InfoMessage():new{
                                                            text    = string.format(
                                                                _("Pack \"%s\" installed.\nYou can now apply it from the list."),
                                                                pack_name),
                                                            timeout = 4,
                                                        })
                                                    else
                                                        UIManager:show(InfoMessage():new{
                                                            text    = _("Error installing pack:") .. "\n" .. tostring(err),
                                                            timeout = 5,
                                                        })
                                                    end
                                                end,
                                            }
                                        end
                                    end
                                    return sub
                                end,
                                separator = true,
                            }

                            -- ── Pack list ─────────────────────────────────────────
                            local packs = IP.listPacks()
                            if #packs == 0 then
                                items[#items + 1] = {
                                    text    = _("No packs found.") .. "\n"
                                              .. _("Place a folder or .zip in:") .. "\n"
                                              .. (IP.getPacksDir() or ""),
                                    enabled = false,
                                }
                            else
                                for _i, pack in ipairs(packs) do
                                    local _pack = pack
                                    items[#items + 1] = {
                                        text     = _pack.name,
                                        callback = function()
                                            local result, err = IP.applyPack(_pack.path)
                                            if result then
                                                _reapplyAllPacks()
                                                UIManager:show(InfoMessage():new{
                                                    text    = string.format(
                                                        _("Pack \"%s\" applied.\n%d icons replaced."),
                                                        _pack.name, result.applied),
                                                    timeout = 3,
                                                })
                                            else
                                                UIManager:show(InfoMessage():new{
                                                    text    = _("Error applying pack:") .. "\n" .. tostring(err),
                                                    timeout = 5,
                                                })
                                            end
                                        end,
                                    }
                                end
                            end

                            return items
                        end,
                        separator = true,
                    },
                    -- ── Icon Presets ──────────────────────────────────────────
                    -- Consolidated here (previously nested under Style > Icons >
                    -- Icon Presets, 4 levels deep).
                    {
                        text = _("Icon Presets"),
                        sub_item_table_func = function()
                            local ok_ip, P   = pcall(require, "sui_presets")
                            local ok_qa, QA2 = pcall(require, "sui_quickactions")
                            local ok_ss, SS2 = pcall(require, "sui_style")
                            local IP  = ok_ip and P and P.icons or nil
                            local QA2 = ok_qa and QA2 or nil

                            -- Helper: reapply all icon changes after a preset is applied.
                            local function _reapplyAll()
                                -- Titlebar (system icons).
                                local ok_tb, TB = pcall(require, "sui_titlebar")
                                if ok_tb and TB then
                                    local FM = package.loaded["apps/filemanager/filemanager"]
                                    local fm = FM and FM.instance
                                    if fm then
                                        pcall(TB.reapplyAll, fm, UIManager._window_stack)
                                    end
                                    if TB.refreshBrowseIcons and fm then
                                        TB.refreshBrowseIcons(fm)
                                    end
                                end
                                -- Pagination chevrons and collections back button.
                                local ok_ss2, SS2 = pcall(require, "sui_style")
                                if ok_ss2 and SS2 then
                                    local FM2 = package.loaded["apps/filemanager/filemanager"]
                                    local fm2 = FM2 and FM2.instance
                                    if fm2 and fm2.file_chooser then
                                        pcall(SS2.applyPaginationIcons, fm2.file_chooser)
                                    end
                                    local ok_ui2, UIManager2 = pcall(require, "ui/uimanager")
                                    if ok_ui2 then
                                        for _, entry in ipairs(UIManager2._window_stack or {}) do
                                            local w = entry.widget
                                            if w and w.page_info_left_chev then
                                                pcall(SS2.applyPaginationIcons, w)
                                            end
                                            if w and (w.name == "collections" or w.name == "coll_list") then
                                                pcall(SS2.applyCollBackIcon, w)
                                            end
                                        end
                                    end
                                end

                                -- Invalidate Quick Actions & Folder Covers caches
                                if QA2 and QA2.invalidateCustomQACache then QA2.invalidateCustomQACache() end
                                local ok_fc, FC = pcall(require, "sui_foldercovers")
                                if ok_fc and FC and FC.invalidateCache then FC.invalidateCache() end
                                local FM = package.loaded["apps/filemanager/filemanager"]
                                local fm_inst = FM and FM.instance
                                if fm_inst and fm_inst.file_chooser then
                                    fm_inst._navbar_suppress_path_change = true
                                    fm_inst.file_chooser:refreshPath()
                                    fm_inst._navbar_suppress_path_change = nil
                                end

                                -- QA navbars.
                                plugin:_rebuildAllNavbars()
                                -- Homescreen: rebuild layout after the menu
                                -- closes (nextTick) so setDirty is
                                -- processed with the HS on top of the stack.
                                local HS = package.loaded["sui_homescreen"]
                                if HS and HS._instance then
                                    local hs = HS._instance
                                    UIManager:nextTick(function()
                                        if HS._instance == hs then
                                            HS._instance:_refreshImmediate(false)
                                        end
                                    end)
                                end
                            end

                            local items = {}
                            local names = IP and IP.listNames() or {}

                            -- ── Select Preset ──────────────────────────────────────
                            local select_items = {}
                            for _k, name in ipairs(names) do
                                local _name = name
                                select_items[#select_items + 1] = {
                                    text_func = function() return _name end,
                                    radio = true,
                                    checked_func = function()
                                        return SUISettings:get("simpleui_icon_active_preset") == _name
                                    end,
                                    callback = function()
                                        if not IP then return end
                                        if IP.apply(_name, QA2) then
                                            SUISettings:set("simpleui_icon_active_preset", _name)
                                            _reapplyAll()
                                        else
                                            UIManager:show(InfoMessage():new{
                                                text    = string.format(_("Preset \"%s\" not found."), _name),
                                                timeout = 2,
                                            })
                                        end
                                    end,
                                }
                            end

                            items[#items + 1] = {
                                text           = _("Select Preset"),
                                enabled        = #names > 0,
                                dim            = #names == 0,
                                sub_item_table = select_items,
                                separator      = true,
                            }

                            -- ── Save as new preset ─────────────────────────────────
                            items[#items + 1] = {
                                text     = _("Save as new preset"),
                                callback = function()
                                    if not IP then return end
                                    local dialog
                                    dialog = InputDialog():new{
                                        title      = _("Save icon preset"),
                                        input      = "",
                                        input_hint = _("Preset name"),
                                        buttons    = {{
                                            {
                                                text     = _("Cancel"),
                                                id       = "close",
                                                callback = function() UIManager:close(dialog) end,
                                            },
                                            {
                                                text             = _("Save"),
                                                is_enter_default = true,
                                                callback         = function()
                                                    local name = dialog:getInputText()
                                                    name = name and name:match("^%s*(.-)%s*$") or ""
                                                    if name == "" then
                                                        UIManager:show(InfoMessage():new{
                                                            text    = _("Please enter a name for the preset."),
                                                            timeout = 2,
                                                        })
                                                        return
                                                    end
                                                    local function _doSave()
                                                        IP.save(name)
                                                        SUISettings:set("simpleui_icon_active_preset", name)
                                                        UIManager:close(dialog)
                                                        UIManager:show(InfoMessage():new{
                                                            text    = string.format(_("Preset \"%s\" saved."), name),
                                                            timeout = 2,
                                                        })
                                                        UIManager:nextTick(function()
                                                            if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end
                                                        end)
                                                    end
                                                    if IP.exists(name) then
                                                        UIManager:show(ConfirmBox():new{
                                                            text        = string.format(
                                                                _("A preset named \"%s\" already exists.\nOverwrite it?"), name),
                                                            ok_text     = _("Overwrite"),
                                                            cancel_text = _("Cancel"),
                                                            ok_callback = _doSave,
                                                        })
                                                    else
                                                        _doSave()
                                                    end
                                                end,
                                            },
                                        }},
                                    }
                                    UIManager:show(dialog)
                                end,
                            }

                            -- ── Manage presets ──────────────────────────────────────────
                            if #names > 0 then
                                items[#items + 1] = {
                                    text = _("Manage presets"),
                                    sub_item_table_func = function()
                                        local sub = {}
                                        for _k, name in ipairs(IP and IP.listNames() or {}) do
                                            local _name = name
                                            sub[#sub + 1] = {
                                                text = _name,
                                                sub_item_table = {
                                                    { text = _("Update with current settings"), callback = function()
                                                        UIManager:show(ConfirmBox():new{
                                                            text = string.format(_("Overwrite preset \"%s\" with the current icon settings?"), _name),
                                                            ok_text     = _("Overwrite"),
                                                            cancel_text = _("Cancel"),
                                                            ok_callback = function()
                                                                if IP then
                                                                    IP.save(_name)
                                                                    SUISettings:set("simpleui_icon_active_preset", _name)
                                                                    UIManager:show(InfoMessage():new{ text = string.format(_("Preset \"%s\" updated."), _name), timeout = 2 })
                                                                    UIManager:nextTick(function() if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end end)
                                                                end
                                                            end,
                                                        })
                                                    end },
                                                    { text = _("Rename"), callback = function()
                                                        local dialog2
                                                        dialog2 = InputDialog():new{
                                                            title   = string.format(_("Rename \"%s\""), _name),
                                                            input   = _name,
                                                            buttons = {{
                                                                { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog2) end },
                                                                { text = _("Rename"), is_enter_default = true, callback = function()
                                                                    local new_name = dialog2:getInputText()
                                                                    new_name = new_name and new_name:match("^%s*(.-)%s*$") or ""
                                                                    if new_name == "" or new_name == _name then UIManager:close(dialog2); return end
                                                                    if IP and IP.exists(new_name) then
                                                                        UIManager:show(InfoMessage():new{ text = string.format(_("A preset named \"%s\" already exists."), new_name), timeout = 2 })
                                                                        return
                                                                    end
                                                                    if IP then
                                                                        IP.rename(_name, new_name)
                                                                        local active = SUISettings:get("simpleui_icon_active_preset")
                                                                        if active == _name then SUISettings:set("simpleui_icon_active_preset", new_name) end
                                                                    end
                                                                    UIManager:close(dialog2)
                                                                    UIManager:nextTick(function() if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end end)
                                                                end },
                                                            }}
                                                        }
                                                        UIManager:show(dialog2)
                                                        dialog2:onShowKeyboard()
                                                    end },
                                                    { text = _("Delete"), callback = function()
                                                        UIManager:show(ConfirmBox():new{
                                                            text        = string.format(_("Delete preset \"%s\"?"), _name),
                                                            ok_text     = _("Delete"),
                                                            cancel_text = _("Cancel"),
                                                            ok_callback = function()
                                                                if IP then
                                                                    IP.delete(_name)
                                                                    local active = SUISettings:get("simpleui_icon_active_preset")
                                                                    if active == _name then SUISettings:del("simpleui_icon_active_preset") end
                                                                end
                                                                UIManager:nextTick(function() if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end end)
                                                            end,
                                                        })
                                                    end },
                                                }
                                            }
                                        end
                                        return sub
                                    end,
                                    sui_build = ctx_menu and ctx_menu.is_sui and function(ctx, _item)
                                        local SUIWindow = require("sui_window")
                                        return SUIWindow.ListRow{
                                            title        = _("Manage presets"),
                                            inner_w      = ctx.inner_w,
                                            show_chevron = true,
                                            on_tap       = function()
                                                ctx.push("nested_menu", {
                                                    title = _("Manage presets"),
                                                    items_func = function()
                                                        return {
                                                            {
                                                                text = "Items List",
                                                                sui_build = function(ctx2)
                                                                    local SUIWindow2 = require("sui_window")
                                                                    local rows = {}
                                                                    for _k, name in ipairs(IP and IP.listNames() or {}) do
                                                                        local _name = name
                                                                        rows[#rows + 1] = SUIWindow2.ListRow{
                                                                            title     = _name,
                                                                            inner_w   = ctx2.inner_w,
                                                                            on_delete = function()
                                                                                UIManager:show(ConfirmBox():new{
                                                                                    text        = string.format(_("Delete preset \"%s\"?"), _name),
                                                                                    ok_text     = _("Delete"),
                                                                                    cancel_text = _("Cancel"),
                                                                                    ok_callback = function()
                                                                                        if IP then
                                                                                            IP.delete(_name)
                                                                                            local active = SUISettings:get("simpleui_icon_active_preset")
                                                                                            if active == _name then SUISettings:del("simpleui_icon_active_preset") end
                                                                                        end
                                                                                        ctx2.repaint()
                                                                                        UIManager:nextTick(function() if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end end)
                                                                                    end,
                                                                                })
                                                                            end,
                                                                            on_edit = function()
                                                                                local dialog2
                                                                                dialog2 = InputDialog():new{
                                                                                    title   = string.format(_("Rename \"%s\""), _name),
                                                                                    input   = _name,
                                                                                    buttons = {{
                                                                                        { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog2) end },
                                                                                        { text = _("Rename"), is_enter_default = true, callback = function()
                                                                                            local new_name = dialog2:getInputText()
                                                                                            new_name = new_name and new_name:match("^%s*(.-)%s*$") or ""
                                                                                            if new_name == "" or new_name == _name then UIManager:close(dialog2); return end
                                                                                            if IP and IP.exists(new_name) then
                                                                                                UIManager:show(InfoMessage():new{ text = string.format(_("A preset named \"%s\" already exists."), new_name), timeout = 2 })
                                                                                                return
                                                                                            end
                                                                                            if IP then
                                                                                                IP.rename(_name, new_name)
                                                                                                local active = SUISettings:get("simpleui_icon_active_preset")
                                                                                                if active == _name then SUISettings:set("simpleui_icon_active_preset", new_name) end
                                                                                            end
                                                                                            UIManager:close(dialog2)
                                                                                            ctx2.repaint()
                                                                                            UIManager:nextTick(function() if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end end)
                                                                                        end },
                                                                                    }}
                                                                                }
                                                                                UIManager:show(dialog2)
                                                                                dialog2:onShowKeyboard()
                                                                            end,
                                                                            on_update = function()
                                                                                UIManager:show(ConfirmBox():new{
                                                                                    text = string.format(_("Overwrite preset \"%s\" with the current icon settings?"), _name),
                                                                                    ok_text     = _("Overwrite"),
                                                                                    cancel_text = _("Cancel"),
                                                                                    ok_callback = function()
                                                                                        if IP then
                                                                                            IP.save(_name)
                                                                                            SUISettings:set("simpleui_icon_active_preset", _name)
                                                                                            UIManager:show(InfoMessage():new{ text = string.format(_("Preset \"%s\" updated."), _name), timeout = 2 })
                                                                                            ctx2.repaint()
                                                                                            UIManager:nextTick(function() if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end end)
                                                                                        end
                                                                                    end,
                                                                                })
                                                                            end,
                                                                        }
                                                                    end
                                                                    if #rows == 0 then
                                                                        rows[#rows + 1] = SUIWindow2.ListRow{ title = _("No presets found."), inner_w = ctx2.inner_w }
                                                                    end
                                                                    return rows
                                                                end
                                                            }
                                                        }
                                                    end
                                                })
                                            end
                                        }
                                    end or nil,
                                }
                            end

                            -- ── Import ─────────────────────────────────────────────
                            items[#items + 1] = {
                                text = _("Import preset"),
                                sub_item_table_func = function()
                                    local sub = {}
                                    if not IP then return sub end
                                    local files = IP.listImportFiles()

                                    if #files == 0 then
                                        sub[#sub + 1] = {
                                            text    = T(_("No preset files found.\nPlace .lua files in:\n%1"), IP.getImportDir() or ""),
                                            enabled = false,
                                        }
                                    else
                                        for _i, f in ipairs(files) do
                                            local _f = f
                                            sub[#sub + 1] = {
                                                text     = _f.name,
                                                callback = function()
                                                    local imported_name, err = IP.import(_f.path)
                                                    if imported_name then
                                                        UIManager:show(InfoMessage():new{
                                                            text = string.format(_("Preset \"%s\" imported."), imported_name),
                                                            timeout = 3,
                                                        })
                                                        UIManager:nextTick(function()
                                                            if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end
                                                        end)
                                                    else
                                                        UIManager:show(InfoMessage():new{
                                                            text = _("Error importing preset: ") .. tostring(err),
                                                            timeout = 4,
                                                        })
                                                    end
                                                end,
                                            }
                                        end
                                    end
                                    return sub
                                end,
                                separator = true,
                            }

                            -- ── Export ─────────────────────────────────────────────
                            if #names > 0 then
                                items[#items + 1] = {
                                    text = _("Export preset"),
                                    sub_item_table_func = function()
                                        local sub = {}
                                        for _k, name in ipairs(IP and IP.listNames() or {}) do
                                            local _name = name
                                            sub[#sub + 1] = {
                                                text     = _name,
                                                callback = function()
                                                    if not IP then return end
                                                    local filepath, err = IP.export(_name)
                                                    if filepath then
                                                        UIManager:show(InfoMessage():new{
                                                            text = string.format(_("Preset exported to:\n%s"), filepath),
                                                            timeout = 4,
                                                        })
                                                    else
                                                        UIManager:show(InfoMessage():new{
                                                            text = _("Error exporting preset: ") .. tostring(err),
                                                            timeout = 4,
                                                        })
                                                    end
                                                end,
                                            }
                                        end
                                        return sub
                                    end,
                                }
                            end

                            return items
                        end,
                        separator = true,
                    },
                }, -- end Icons sub_item_table
            },   -- end Icons submenu
            -- ── UI Font ───────────────────────────────────────────────────
            {
                text = _("UI Font"),
                text_func = function()
                    local ok_ss, SUIStyle = pcall(require, "sui_style")
                    if not ok_ss or not SUIStyle then return _("UI Font") end
                    local enabled = SUISettings:isTrue("simpleui_ui_font_enabled")
                    local name    = SUISettings:get("simpleui_ui_font_name") or "Noto Sans"
                    if not enabled then
                        return _("UI Font  (default)")
                    end
                    return string.format(_("UI Font  [%s]"), name)
                end,
                sub_item_table_func = function()
                    local ok_ss, SUIStyle = pcall(require, "sui_style")
                    if not ok_ss or not SUIStyle then return {} end
                    local ok_fi, items = pcall(SUIStyle.makeFontMenuItems)
                    if not ok_fi or type(items) ~= "table" then return {} end
                    return items
                end,
            },
            {
                text = _("Progress Bar Type"),
                sub_item_table = {
                    {
                        text           = _("Flat"),
                        radio          = true,
                        checked_func   = function() return (SUISettings:get("simpleui_style_progress_bar_type") or "flat") == "flat" end,
                        keep_menu_open = true,
                        callback       = function()
                            SUISettings:set("simpleui_style_progress_bar_type", "flat")
                            refreshHomescreen()
                            if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end
                        end,
                    },
                    {
                        text           = _("Framed"),
                        radio          = true,
                        checked_func   = function() return (SUISettings:get("simpleui_style_progress_bar_type") or "flat") == "framed" end,
                        keep_menu_open = true,
                        callback       = function()
                            SUISettings:set("simpleui_style_progress_bar_type", "framed")
                            refreshHomescreen()
                            if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end
                        end,
                    },
                },
            },
            -- ── Theme Colors [DISABLED — not ready for release] ───────
            --[[
            -- ── Theme Colors ──────────────────────────────────────────────
            {
                text_func = function()
                    -- Show the edit pencil if any theme color role is set.
                    local has = SUISettings:get("simpleui_style_theme_bg")
                             or SUISettings:get("simpleui_style_theme_fg")
                             or SUISettings:get("simpleui_style_theme_bottombar_bg")
                             or SUISettings:get("simpleui_style_theme_bottombar_fg")
                             or SUISettings:get("simpleui_style_theme_statusbar_bg")
                             or SUISettings:get("simpleui_style_theme_statusbar_fg")
                             or SUISettings:get("simpleui_style_theme_text_secondary")
                             or SUISettings:get("simpleui_style_theme_separator")
                             or SUISettings:get("simpleui_style_theme_accent")
                    return _("Theme Colors") .. (has and "  \u{270E}" or "")
                end,
                sub_item_table_func = function()
                    local ok_ss, SUIStyle = pcall(require, "sui_style")
                    if not ok_ss or not SUIStyle then return {} end
                    local ok_fi, items = pcall(SUIStyle.makeThemeMenuItems)
                    if not ok_fi or type(items) ~= "table" then return {} end
                    return items
                end,
            },
            -- END DISABLED: Theme Colors ]]
        }
    end

    local function makeAboutMenuItems(ctx_menu)
        local _plugin_dir = (debug.getinfo(1, "S").source or ""):match("^@?(.+)/[^/]+$")
        local ok, Meta = pcall(dofile, _plugin_dir .. "/_meta.lua")
        if not ok or type(Meta) ~= "table" or Meta.name ~= "simpleui" then
            local rok, rmeta = pcall(require, "_meta")
            Meta = (rok and type(rmeta) == "table" and rmeta.name == "simpleui" and rmeta) or {}
        end
        return {
            {
                text           = string.format(_("Version: %s"), Meta.version or "?"),
                keep_menu_open = true,
                callback       = function() end,
            },
            {
                text           = string.format(_("Author: %s"), Meta.author or "?"),
                keep_menu_open = true,
                callback       = function() end,
            },
            {
                text           = _("Automatic Update Check"),
                checked_func   = function()
                    return SUISettings:isTrue("simpleui_updater_auto_check")
                end,
                keep_menu_open = true,
                callback       = function()
                    SUISettings:set("simpleui_updater_auto_check",
                        not SUISettings:isTrue("simpleui_updater_auto_check"))
                end,
            },
            {
                text      = _("Check for Updates"),
                callback  = function()
                    local ok_upd, Updater = pcall(require, "sui_updater")
                    if not ok_upd then
                        local UIM = ctx_menu and ctx_menu.UIManager or UIManager
                        local InfoMsg = ctx_menu and ctx_menu.InfoMessage or InfoMessage()
                        UIM:show(InfoMsg:new{
                            text    = _("Updater module not found."),
                            timeout = 4,
                        })
                        return
                    end
                    Updater.checkForUpdates()
                end,
            },
            {
                text      = _("Factory Reset"),
                separator = true,
                callback  = function()
                    local ConfirmBoxWidget = ctx_menu and ctx_menu.ConfirmBox or ConfirmBox()
                    local UIM = ctx_menu and ctx_menu.UIManager or UIManager
                    UIM:show(ConfirmBoxWidget:new{
                        text        = _("This will delete all Simple UI settings and restart KOReader.\nAre you sure?"),
                        ok_text     = _("Delete Settings"),
                        cancel_text = _("Cancel"),
                        ok_callback = function()
                            local keys_to_delete = {}
                            for k, _ in SUISettings:iterateKeys() do
                                keys_to_delete[#keys_to_delete + 1] = k
                            end
                            for _, k in ipairs(keys_to_delete) do
                                SUISettings:del(k)
                            end
                            SUISettings:flush()
                            
                            if G_reader_settings:readSetting("start_with") == "homescreen_simpleui" then
                                G_reader_settings:saveSetting("start_with", "filemanager")
                            end
                            UIM:restartKOReader()
                        end,
                    })
                end,
            },
        }
    end
    plugin.makeAboutMenuItems = makeAboutMenuItems

    -- -----------------------------------------------------------------------
    -- Main menu entry
    -- -----------------------------------------------------------------------

    -- sorting_hint = "tools" places this entry in the Tools section of the
    -- KOReader main menu (where Statistics, Terminal, etc. live).
    -- Using a dedicated key "simpleui" avoids colliding with the section table.
    --
    -- OPT-H: All sub-menus are now built lazily via sub_item_table_func.
    -- Previously makeNavbarMenu(), makePaginationBarMenu() and makeTopbarMenu()
    -- were called eagerly at registration time, creating hundreds of closures
    -- (checked_func, callback, enabled_func, etc.) even if the user never opens
    -- the menu. With sub_item_table_func the closures are only allocated when
    -- the user actually taps the menu entry.
    --
    -- Menu structure (reorganised):
    --   Simple UI
    --   ├── [On/Off toggle]
    --   ├── Bars          ← all peripheral UI bars
    --   │   ├── Status Bar
    --   │   ├── Navigation Bar
    --   │   ├── Title Bar
    --   │   └── Pagination Bar
    --   ├── Home Screen   ← everything about the homescreen
    --   │   └── (modules, quick actions, wallpaper, behaviour, presets)
    --   ├── Library       ← book-browser settings
    --   ├── Appearance    ← icons and font
    --   │   ├── System Icons
    --   │   ├── Quick Actions Icons
    --   │   ├── Icon Packs
    --   │   ├── Icon Presets
    --   │   └── UI Font
    --   ├── Quick Actions ← global custom quick actions
    --   └── About
    menu_items.simpleui = {
        sorting_hint = "tools",
        text = _("Simple UI"),
        sub_item_table = {
            -- ── Enable / Disable toggle ───────────────────────────────────────
            {
                text_func    = function()
                    return _("Simple UI") .. " — " .. (SUISettings:nilOrTrue("simpleui_enabled") and _("On") or _("Off"))
                end,
                checked_func = function() return SUISettings:nilOrTrue("simpleui_enabled") end,
                callback     = function()
                    local on = SUISettings:nilOrTrue("simpleui_enabled")
                    SUISettings:saveSetting("simpleui_enabled", not on)
                    -- When disabling SimpleUI, reset "Start with Homescreen" if active,
                    -- because "homescreen_simpleui" is not a value the base KOReader
                    -- understands — leaving it set would cause a blank screen on next boot.
                    if on and G_reader_settings:readSetting("start_with") == "homescreen_simpleui" then
                        G_reader_settings:saveSetting("start_with", "filemanager")
                    end
                    -- Flush immediately so a hard reboot / crash cannot leave the
                    -- setting unsaved, which would cause a white-screen boot loop
                    -- the next time KOReader starts with the plugin installed.
                    SUISettings:flush()
                    UIManager:show(ConfirmBox():new{
                        text        = string.format(_("Simple UI will be %s after restart.\n\nRestart now?"), on and _("disabled") or _("enabled")),
                        ok_text     = _("Restart"), cancel_text = _("Later"),
                        ok_callback = function()
                            UIManager:restartKOReader()
                        end,
                    })
                end,
                separator = true,
            },
            -- ── Bars ─────────────────────────────────────────────────────────
            -- Groups all peripheral UI bars (top, bottom, pagination, title).
            {
                text = _("Bars"),
                sub_item_table_func = function() return makeBarsMenuItems() end,
            },
            -- ── Home Screen ──────────────────────────────────────────────────
            -- All settings that apply to the homescreen context live here.
            { text = _("Home Screen"), sub_item_table_func = makeHomescreenMenu },
            -- ── Library ──────────────────────────────────────────────────────
            -- Book-browser settings: folder covers, series grouping, browse by meta.
            {
                text = _("Library"),
                sub_item_table_func = function() return plugin.makeLibraryMenuItems() end,
            },
            -- ── Appearance ───────────────────────────────────────────────────
            -- Consolidates all visual customisation: icons (system, quick actions,
            -- packs, presets) and the UI font. Previously split across Style > Icons
            -- (4 levels deep) and Style > UI Font.
            {
                text = _("Style"),
                sub_item_table_func = function() return plugin.makeStyleMenuItems(nil) end,
            },
            -- ── Quick Actions ────────────────────────────────────────────────
            -- Global custom quick actions (not homescreen-specific).
            {
                text_func = function()
                    local n   = #getCustomQAList()
                    local rem = MAX_CUSTOM_QA - n
                    if n == 0 then return _("Quick Actions") end
                    if rem <= 0 then
                        return string.format(_("Quick Actions  (%d/%d — at limit)"), n, MAX_CUSTOM_QA)
                    end
                    return string.format(_("Quick Actions  (%d/%d — %d left)"), n, MAX_CUSTOM_QA, rem)
                end,
                sub_item_table_func = makeQuickActionsMenu,
            },
            -- -----------------------------------------------------------------
            -- About submenu
            -- -----------------------------------------------------------------
            {
                text                = _("About"),
                separator           = true,
                sub_item_table_func = function() return plugin.makeAboutMenuItems(nil) end,
            },
        },
    }
    -- Update banner: injected as the first item of the main menu
    -- when a newer version is available. Uses in-memory cache (zero I/O).
    do
        local ok_u, Updater = pcall(require, "sui_updater")
        local banner = (ok_u and Updater) and Updater.build_update_banner_item() or nil
        if banner then
            table.insert(menu_items.simpleui.sub_item_table, 1, banner)
        end
    end
end -- addToMainMenu

end -- installer function
