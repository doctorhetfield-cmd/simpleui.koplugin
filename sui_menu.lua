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

            local iw_init = rawget(iw, "init")

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
                iw.init = function(self_iw)
                    if self_iw.icon == "simpleui_settings" and not self_iw.file and not self_iw.image then
                        self_iw.file = icon_file
                        return
                    end
                    if type(orig_init) == "function" then orig_init(self_iw) end
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

    local function makeTabsMenu()
        local items = {}

        items[#items + 1] = {
            text           = _("Arrange tabs"),
            keep_menu_open = true,
            separator      = true,
            callback       = function()
                local tabs       = loadTabConfig()
                local sort_items = {}
                for _i, tid in ipairs(tabs) do
                    sort_items[#sort_items + 1] = { text = getActionLabel(tid), orig_item = tid }
                end
                local sort_widget = SortWidget():new{
                    title             = _("Arrange tabs"),
                    item_table        = sort_items,
                    covers_fullscreen = true,
                    callback          = function()
                        local new_tabs = {}
                        for _i, item in ipairs(sort_items) do new_tabs[#new_tabs + 1] = item.orig_item end
                        _ensureHomePresent(new_tabs)
                        saveTabConfig(new_tabs)
                        plugin:_scheduleRebuild()
                    end,
                }
                UIManager:show(sort_widget)
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
                text           = _("General"),
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
                text           = _("Home Screen"),
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
                text           = _("Size"),
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
                text         = _("Number of Pages in Title Bar Always"),
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
        items[#items + 1] = {
            text           = _("Swipe Indicator"),
            keep_menu_open = true,
            checked_func   = function() return SUISettings:nilOrTrue("simpleui_topbar_swipe_indicator") end,
            callback = function()
                SUISettings:saveSetting("simpleui_topbar_swipe_indicator",
                    not SUISettings:nilOrTrue("simpleui_topbar_swipe_indicator"))
                plugin:_scheduleRebuild()
            end,
        }
        items[#items + 1] = {
            text           = _("Hide Wi-Fi icon when off"),
            keep_menu_open = true,
            checked_func   = function() return Config.getWifiHideWhenOff() end,
            callback = function()
                Config.setWifiHideWhenOff(not Config.getWifiHideWhenOff())
                plugin:_scheduleRebuild()
            end,
            separator = true,
        }

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
                sort_items[#sort_items + 1] = { text = "── " .. _("Left") .. " ──", orig_item = SEP_LEFT, dim = true }
                for _i, key in ipairs(cfg.order_left) do
                    if cfg.side[key] ~= "hidden" then
                        sort_items[#sort_items + 1] = { text = TOPBAR_ITEM_LABEL(key), orig_item = key }
                    end
                end
                sort_items[#sort_items + 1] = { text = "── " .. _("Center") .. " ──", orig_item = SEP_CENTER, dim = true }
                for _i, key in ipairs(cfg.order_center) do
                    if cfg.side[key] == "center" then
                        sort_items[#sort_items + 1] = { text = TOPBAR_ITEM_LABEL(key), orig_item = key }
                    end
                end
                sort_items[#sort_items + 1] = { text = "── " .. _("Right") .. " ──", orig_item = SEP_RIGHT, dim = true }
                for _i, key in ipairs(cfg.order_right) do
                    if cfg.side[key] ~= "hidden" then
                        sort_items[#sort_items + 1] = { text = TOPBAR_ITEM_LABEL(key), orig_item = key }
                    end
                end
                UIManager:show(SortWidget():new{
                    title             = _("Arrange Items"),
                    item_table        = sort_items,
                    covers_fullscreen = true,
                    callback          = function()
                        local sep_left_pos, sep_center_pos, sep_right_pos
                        for j, item in ipairs(sort_items) do
                            if item.orig_item == SEP_LEFT   then sep_left_pos   = j end
                            if item.orig_item == SEP_CENTER then sep_center_pos = j end
                            if item.orig_item == SEP_RIGHT  then sep_right_pos  = j end
                        end
                        if not sep_left_pos or not sep_center_pos or not sep_right_pos
                                or sep_left_pos > sep_center_pos or sep_center_pos > sep_right_pos
                                or (sort_items[1] and sort_items[1].orig_item ~= SEP_LEFT) then
                            UIManager:show(InfoMessage():new{
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
                    end,
                })
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
                end,
            }
        end
        return items
    end


    local function makeTopbarMenu()
        return {
            {
                text_func    = function()
                    return _("Top Bar") .. " — " .. (SUISettings:nilOrTrue("simpleui_topbar_enabled") and _("On") or _("Off"))
                end,
                checked_func = function() return SUISettings:nilOrTrue("simpleui_topbar_enabled") end,
                keep_menu_open = true,
                callback     = function()
                    local on = SUISettings:nilOrTrue("simpleui_topbar_enabled")
                    SUISettings:saveSetting("simpleui_topbar_enabled", not on)
                    UIManager:show(ConfirmBox():new{
                        text = string.format(_("Top Bar will be %s after restart.\n\nRestart now?"), on and _("disabled") or _("enabled")),
                        ok_text = _("Restart"), cancel_text = _("Later"),
                        ok_callback = function()
                            SUISettings:flush()
                            UIManager:restartKOReader()
                        end,
                    })
                end,
            },
            {
                text_func = function()
                    return _("Size")
                end,
                keep_menu_open = true,
                callback = function()
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text    = _("Top Bar Size"),
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
            { text = _("Items"), sub_item_table_func = makeTopbarItemsMenu },
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

    local function makeNavbarMenu()
        return {
            {
                text_func    = function()
                    return _("Bottom Bar") .. " — " .. (SUISettings:nilOrTrue("simpleui_bar_enabled") and _("On") or _("Off"))
                end,
                checked_func = function() return SUISettings:nilOrTrue("simpleui_bar_enabled") end,
                keep_menu_open = true,
                callback     = function()
                    local on = SUISettings:nilOrTrue("simpleui_bar_enabled")
                    SUISettings:saveSetting("simpleui_bar_enabled", not on)
                    UIManager:show(ConfirmBox():new{
                        text = string.format(_("Bottom Bar will be %s after restart.\n\nRestart now?"), on and _("disabled") or _("enabled")),
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
                    return _("Size")
                end,
                keep_menu_open = true,
                callback = function()
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text    = _("Bottom Bar Size"),
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
                text_func     = function()
                    local pct = Config.getBottomMarginPct()
                    return pct == Config.BOT_MARGIN_DEF
                        and _("Bottom Margin")
                        or  string.format(_("Bottom Margin — %d%%"), pct)
                end,
                title         = _("Bottom Margin"),
                info          = _("Space below the bottom navigation bar.\n100% is the default spacing."),
                get           = function() return Config.getBottomMarginPct() end,
                set           = function(pct) Config.setBottomMarginPct(pct) end,
                refresh       = function()
                    UI.invalidateDimCache()
                    plugin:_rewrapAllWidgets()
                    local ok_hs, HS = pcall(require, "sui_homescreen")
                    if ok_hs and HS then HS.refresh(true) end
                end,
                value_min     = Config.BOT_MARGIN_MIN,
                value_max     = Config.BOT_MARGIN_MAX,
                value_step    = Config.BOT_MARGIN_STEP,
                default_value = Config.BOT_MARGIN_DEF,
            }),
            Config.makeScaleItem({
                text_func     = function()
                    local pct = Config.getIconScalePct()
                    return pct == Config.ICON_SCALE_DEF
                        and _("Icon Size")
                        or  string.format(_("Icon Size — %d%%"), pct)
                end,
                title         = _("Icon Size"),
                info          = _("Size of the tab icons.\n100% is the default size."),
                get           = function() return Config.getIconScalePct() end,
                set           = function(pct) Config.setIconScalePct(pct) end,
                refresh       = function()
                    UI.invalidateDimCache()
                    plugin:_rebuildAllNavbars()
                end,
                value_min     = Config.ICON_SCALE_MIN,
                value_max     = Config.ICON_SCALE_MAX,
                value_step    = Config.ICON_SCALE_STEP,
                default_value = Config.ICON_SCALE_DEF,
            }),
            Config.makeScaleItem({
                text_func     = function()
                    local pct = Config.getNavbarLabelScalePct()
                    return pct == Config.NAVBAR_LABEL_SCALE_DEF
                        and _("Label Size")
                        or  string.format(_("Label Size — %d%%"), pct)
                end,
                title         = _("Label Size"),
                info          = _("Size of the tab label text.\n100% is the default size."),
                get           = function() return Config.getNavbarLabelScalePct() end,
                set           = function(pct) Config.setNavbarLabelScalePct(pct) end,
                refresh       = function()
                    UI.invalidateDimCache()
                    plugin:_rebuildAllNavbars()
                end,
                value_min     = Config.NAVBAR_LABEL_SCALE_MIN,
                value_max     = Config.NAVBAR_LABEL_SCALE_MAX,
                value_step    = Config.NAVBAR_LABEL_SCALE_STEP,
                default_value = Config.NAVBAR_LABEL_SCALE_DEF,
            }),
            {
                text_func    = function()
                    return _("Top separator") .. " — " .. (SUISettings:isTrue("simpleui_bar_hide_separator") and _("Hidden") or _("Visible"))
                end,
                checked_func = function() return not SUISettings:isTrue("simpleui_bar_hide_separator") end,
                keep_menu_open = true,
                callback     = function()
                    local hidden = SUISettings:isTrue("simpleui_bar_hide_separator")
                    SUISettings:saveSetting("simpleui_bar_hide_separator", not hidden)
                    plugin:_rebuildAllNavbars()
                    local ok_hs, HS = pcall(require, "sui_homescreen")
                    if ok_hs and HS then HS.refresh(true) end
                end,
            },
            {
                text = _("Type"),
                sub_item_table_func = makeTypeMenu,
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
                sub_item_table_func = makeTabsMenu,
            },
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

    -- Resolves the live FM + window stack and re-applies (or restores) all
    -- titlebar state. Called by every toggle in this submenu.
    local function _reapplyAllTitlebars()
        local Titlebar = require("sui_titlebar")
        local FM = package.loaded["apps/filemanager/filemanager"]
        local fm = FM and FM.instance
        local stack = require("sui_core").getWindowStack()
        Titlebar.reapplyAll(fm, stack)
        if fm then UIManager:setDirty(fm[1], "ui") end
    end

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
    local function makeTitleBarArrangeMenu(ctx, cfg_getter, cfg_saver)
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
            text = "── " .. _("Left") .. " ──", orig_item = SEP_LEFT, dim = true,
        }
        for _i, id in ipairs(cfg.order_left) do
            if labels[id] then
                sort_items[#sort_items + 1] = { text = labels[id](), orig_item = id }
            end
        end
        sort_items[#sort_items + 1] = {
            text = "── " .. _("Right") .. " ──", orig_item = SEP_RIGHT, dim = true,
        }
        for _i, id in ipairs(cfg.order_right) do
            if labels[id] then
                sort_items[#sort_items + 1] = { text = labels[id](), orig_item = id }
            end
        end

        UIManager:show(SortWidget():new{
            title             = _("Arrange Buttons"),
            item_table        = sort_items,
            covers_fullscreen = true,
            callback          = function()
                -- Validate: separators must be in correct relative order.
                local sep_l, sep_r
                for j, item in ipairs(sort_items) do
                    if item.orig_item == SEP_LEFT  then sep_l = j end
                    if item.orig_item == SEP_RIGHT then sep_r = j end
                end
                if not sep_l or not sep_r or sep_l > sep_r
                        or (sort_items[1] and sort_items[1].orig_item ~= SEP_LEFT) then
                    UIManager:show(InfoMessage():new{
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
                    if cfg.side[id] == "hidden" then new_left[#new_left + 1]   = id end
                end
                for _i, id in ipairs(cfg.order_right) do
                    if cfg.side[id] == "hidden" then new_right[#new_right + 1] = id end
                end
                cfg.order_left  = new_left
                cfg.order_right = new_right
                cfg_saver(cfg)
                _reapplyAllTitlebars()
            end,
        })
    end

    local function makeTitleBarFMMenu()
        local Titlebar = require("sui_titlebar")
        local items = makeTitleBarItemsForCtx("fm")
        if #items > 0 then items[#items].separator = true end
        items[#items + 1] = {
            text           = _("Arrange Buttons"),
            enabled_func   = function() return Titlebar.isEnabled() end,
            keep_menu_open = true,
            callback       = function()
                makeTitleBarArrangeMenu("fm", Titlebar.getFMConfig, Titlebar.saveFMConfig)
            end,
        }
        return items
    end

    local function makeTitleBarSubMenu()
        local Titlebar = require("sui_titlebar")
        local items = makeTitleBarItemsForCtx("sub")
        if #items > 0 then items[#items].separator = true end
        items[#items + 1] = {
            text           = _("Arrange Buttons"),
            enabled_func   = function() return Titlebar.isEnabled() end,
            keep_menu_open = true,
            callback       = function()
                makeTitleBarArrangeMenu("sub", Titlebar.getSubConfig, Titlebar.saveSubConfig)
            end,
        }
        return items
    end

    local function makeTitleBarMenu()
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
                    local on = require("sui_titlebar").isEnabled()
                    return _("Custom Title Bar") .. " — " .. (on and _("On") or _("Off"))
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
                            _("Custom Title Bar will be %s after restart.\n\nRestart now?"),
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
                text      = _("Button Size"),
                enabled_func = function() return require("sui_titlebar").isEnabled() end,
                separator = true,
                sub_item_table = {
                    sizeItem(_("Compact"), "compact"),
                    sizeItem(_("Default"), "default"),
                    sizeItem(_("Large"),   "large"),
                },
            },
            {
                text         = _("Library Buttons"),
                enabled_func = function() return require("sui_titlebar").isEnabled() end,
                sub_item_table_func = makeTitleBarFMMenu,
            },
            {
                text         = _("Sub-pages Buttons"),
                enabled_func = function() return require("sui_titlebar").isEnabled() end,
                sub_item_table_func = makeTitleBarSubMenu,
            },
        }
    end

    plugin._makeTitleBarMenu = makeTitleBarMenu

    -- -----------------------------------------------------------------------
    -- Quick Actions
    -- -----------------------------------------------------------------------

    -- Quick Actions — delegated to sui_quickactions.lua
    local QA = require("sui_quickactions")
    local function makeQuickActionsMenu()
        return QA.makeMenuItems(plugin)
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
    -- the Homescreen. Lets them set annual/physical goals.
    self._goalTapCallback = function()
        local goal     = SUISettings:readSetting("simpleui_reading_goal") or 0
        local physical = SUISettings:readSetting("simpleui_reading_goal_physical") or 0
        local ButtonDialog = require("ui/widget/buttondialog")
        local dlg
        dlg = ButtonDialog:new{ title = _("Annual Reading Goal"), buttons = {
            {{ text = goal > 0 and string.format(N_("Digital: %d book in %s", "Digital: %d books in %s", goal), goal, os.date("%Y")) or string.format(_("Digital Goal  (%s)"), os.date("%Y")),
               callback = function()
                   UIManager:close(dlg)
                   local ok_rg, RG = pcall(require, "readinggoals")
                   if ok_rg and RG then RG.showAnnualGoalDialog(function() refreshHomescreen() end) end
               end }},
            {{ text = string.format(N_("Physical: %d book in %s", "Physical: %d books in %s", physical), physical, os.date("%Y")),
               callback = function()
                   UIManager:close(dlg)
                   local ok_rg, RG = pcall(require, "readinggoals")
                   if ok_rg and RG then RG.showAnnualPhysicalDialog(function() refreshHomescreen() end) end
               end }},
        }}
        UIManager:show(dlg)
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
        local slot_label = string.format(_("Quick Actions %d"), slot_n)
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
                text           = _("Hide Text"),
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
                    if _mod.id:match("^quick_actions_%d+$") then
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

        -- Toggle items sorted alphabetically
        local toggles = {}
        for _loop_, mod in ipairs(Registry.list()) do
            toggles[#toggles+1] = makeToggleItem(mod)
        end
        table.sort(toggles, function(a, b)
            local ta = type(a.text_func) == "function" and a.text_func() or (a.text or "")
            local tb = type(b.text_func) == "function" and b.text_func() or (b.text or "")
            return ta:lower() < tb:lower()
        end)

        return {
            {
                text_func = function()
                    local n = countModules(ctx)
                    return string.format(_("Modules  (%d)"), n)
                end,
                sub_item_table_func = function()
                    local result = {
                        {
                            text = _("Number of Pages"), keep_menu_open = true,
                            callback = function()
                                local T          = _
                                local SpinWidget = require("ui/widget/spinwidget")
                                local HS         = require("sui_homescreen")
                                local PAGE_BREAK = HS.PAGE_BREAK_ID
                                local order = SUISettings:readSetting(ctx.pfx .. "module_order") or {}
                                local saved_breaks = 0
                                for _i, key in ipairs(order) do
                                    if key == PAGE_BREAK then saved_breaks = saved_breaks + 1 end
                                end
                                local current_pages = SUISettings:readSetting(ctx.pfx .. "homescreen_num_pages")
                                    or math.max(1, saved_breaks + 1)
                                UIManager:show(SpinWidget:new{
                                    title_text    = _("Number of Pages"),
                                    info_text     = _("Choose how many pages the homescreen has.\nEmpty pages stay empty. Modules keep their position."),
                                    value         = current_pages,
                                    value_min     = 1,
                                    value_max     = 10,
                                    value_step    = 1,
                                    ok_text       = _("OK"),
                                    cancel_text   = _("Cancel"),
                                    default_value = 1,
                                    callback = function(spin)
                                        local new_pages = spin.value
                                        SUISettings:saveSetting(ctx.pfx .. "homescreen_num_pages", new_pages)

                                        -- Re-read the current order (captured above may be stale if
                                        -- another operation ran before the SpinWidget closed).
                                        local cur_order = SUISettings:readSetting(ctx.pfx .. "module_order") or {}

                                        -- Split cur_order into pages so we know which modules live
                                        -- on pages that are being removed.
                                        local pages_by_id = {}
                                        local cur_pg = {}
                                        for _i2, k in ipairs(cur_order) do
                                            if k == PAGE_BREAK then
                                                pages_by_id[#pages_by_id + 1] = cur_pg
                                                cur_pg = {}
                                            else
                                                cur_pg[#cur_pg + 1] = k
                                            end
                                        end
                                        pages_by_id[#pages_by_id + 1] = cur_pg

                                        -- Disable modules that live on pages beyond new_pages.
                                        local Registry = require("desktop_modules/moduleregistry")
                                        for pg_idx = new_pages + 1, #pages_by_id do
                                            for _i2, mod_id in ipairs(pages_by_id[pg_idx]) do
                                                local mod = Registry.get(mod_id)
                                                if mod then
                                                    if type(mod.setEnabled) == "function" then
                                                        mod.setEnabled(ctx.pfx, false)
                                                    elseif mod.enabled_key then
                                                        SUISettings:saveSetting(ctx.pfx .. mod.enabled_key, false)
                                                    end
                                                end
                                            end
                                        end

                                        -- Rebuild module_order with exactly (new_pages - 1) PAGE_BREAKs,
                                        -- keeping only the modules from pages 1..new_pages, then
                                        -- appending disabled/tail modules (no breaks after them).
                                        local new_order = {}
                                        local tail = {}
                                        for pg_idx, pg_ids in ipairs(pages_by_id) do
                                            if pg_idx <= new_pages then
                                                -- Insert separator before page 2, 3, … (not before page 1).
                                                if pg_idx > 1 then
                                                    new_order[#new_order + 1] = PAGE_BREAK
                                                end
                                                for _i2, k in ipairs(pg_ids) do
                                                    new_order[#new_order + 1] = k
                                                end
                                            else
                                                -- Modules on removed pages go to the tail (disabled above).
                                                for _i2, k in ipairs(pg_ids) do
                                                    tail[#tail + 1] = k
                                                end
                                            end
                                        end
                                        for _i2, k in ipairs(tail) do
                                            new_order[#new_order + 1] = k
                                        end
                                        SUISettings:saveSetting(ctx.pfx .. "module_order", new_order)

                                        -- Reset to page 1 if the current page no longer exists.
                                        local HS2 = package.loaded["sui_homescreen"]
                                        if HS2 and HS2._instance then
                                            if (HS2._instance._current_page or 1) > new_pages then
                                                HS2._instance._current_page = 1
                                            end
                                        end

                                        ctx.refresh()
                                    end,
                                })
                            end,
                        },
                        {
                            text = _("Arrange Modules"), keep_menu_open = true,
                            callback = function()
                                local HS         = require("sui_homescreen")
                                local PAGE_BREAK = HS.PAGE_BREAK_ID
                                local T          = _

                                local order       = loadOrder()
                                local enabled_ids = {}
                                for _i, key in ipairs(order) do
                                    if key ~= PAGE_BREAK then
                                        local mod = Registry.get(key)
                                        if mod and Registry.isEnabled(mod, ctx.pfx) then
                                            enabled_ids[#enabled_ids + 1] = key
                                        end
                                    end
                                end

                                if #enabled_ids < 2 then
                                    UIManager:show(InfoMessage():new{
                                        text = _("Enable at least 2 modules to arrange."), timeout = 2 })
                                    return
                                end

                                local saved_breaks = 0
                                for _i, key in ipairs(order) do
                                    if key == PAGE_BREAK then saved_breaks = saved_breaks + 1 end
                                end
                                local n_pages = SUISettings:readSetting(ctx.pfx .. "homescreen_num_pages")
                                    or math.max(1, saved_breaks + 1)
                                n_pages = math.max(1, math.min(10, n_pages))

                                -- Build sort_items preserving existing per-page layout.
                                -- Modules stay where they are; extra breaks appended if more pages chosen.
                                local function buildSortItems(n_pgs)
                                    local items = {}
                                    local current_breaks = 0
                                    for _i, key in ipairs(order) do
                                        if key == PAGE_BREAK then
                                            if current_breaks < n_pgs - 1 then
                                                current_breaks = current_breaks + 1
                                                items[#items + 1] = {
                                                    text      = "── " .. string.format(_("Page %d"), current_breaks + 1) .. " ──",
                                                    orig_item = PAGE_BREAK,
                                                    _is_break = true,
                                                    dim       = true,
                                                }
                                            end
                                        else
                                            local mod = Registry.get(key)
                                            if mod and Registry.isEnabled(mod, ctx.pfx) then
                                                items[#items + 1] = {
                                                    text      = T(mod.name),
                                                    orig_item = key,
                                                }
                                            end
                                        end
                                    end
                                    -- Append extra page separators if n_pgs > existing pages.
                                    while current_breaks < n_pgs - 1 do
                                        current_breaks = current_breaks + 1
                                        items[#items + 1] = {
                                            text      = "── " .. string.format(_("Page %d"), current_breaks + 1) .. " ──",
                                            orig_item = PAGE_BREAK,
                                            _is_break = true,
                                            dim       = true,
                                        }
                                    end
                                    return items
                                end

                                local function validate(items)
                                    if items[1] and items[1]._is_break then
                                        return false, _("Cannot place modules after Page 1 separator.\nPage 1 must always have at least 1 module.")
                                    end
                                    local has_mod = false
                                    for _i, it in ipairs(items) do
                                        if not it._is_break then has_mod = true; break end
                                    end
                                    if not has_mod then
                                        return false, _("Enable at least 2 modules to arrange.")
                                    end
                                    return true
                                end

                                local function saveOrder(sort_items)
                                    local ok, err = validate(sort_items)
                                    if not ok then
                                        UIManager:show(InfoMessage():new{ text = err, timeout = 3 })
                                        return false
                                    end
                                    -- Preserve empty pages: emit PAGE_BREAK for every separator in the list.
                                    local new_order  = {}
                                    local active_set = {}
                                    for _i, item in ipairs(sort_items) do
                                        if item._is_break then
                                            new_order[#new_order + 1] = PAGE_BREAK
                                        else
                                            new_order[#new_order + 1] = item.orig_item
                                            active_set[item.orig_item] = true
                                        end
                                    end
                                    -- Disabled modules go to the tail.
                                    for _i, k in ipairs(order) do
                                        if k ~= PAGE_BREAK and not active_set[k] then
                                            new_order[#new_order + 1] = k
                                        end
                                    end
                                    SUISettings:saveSetting(ctx.pfx .. "module_order", new_order)
                                    local HS2 = package.loaded["sui_homescreen"]
                                    if HS2 and HS2._instance then HS2._instance._current_page = 1 end
                                    ctx.refresh()
                                    return true
                                end

                                local sort_items = buildSortItems(n_pages)
                                UIManager:show(SortWidget():new{
                                    title             = _("Arrange Modules"),
                                    item_table        = sort_items,
                                    covers_fullscreen = true,
                                    callback          = function() saveOrder(sort_items) end,
                                })
                            end,
                        },
                        {
                            text = _("Module Settings"),
                            sub_item_table_func = makeModuleSettingsMenu,
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
                                        ctx.refresh()
                                    end,
                                },
                                {
                                    text_func = function()
                                        return _("Modules")
                                    end,
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
                                                ctx.refresh()
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
                                                ctx.refresh()
                                            end,
                                        })
                                    end,
                                },
                            },
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
                                        ctx.refresh()
                                    end,
                                })
                            end,
                        },
                    }
                    for _loop_, t in ipairs(toggles) do result[#result+1] = t end
                    return result
                end,
            },
        }
    end

    -- -----------------------------------------------------------------------
    -- makeHomescreenMenu
    -- -----------------------------------------------------------------------

    local function makeHomescreenMenu()
        local ctx = HOMESCREEN_CTX
        local modules_items = makeModulesMenu(ctx)

        -- Helper to cleanly apply layout-affecting changes (transparency, wallpaper, preset).
        local function _applyFullLayoutRefresh()
            plugin:_rewrapAllWidgets()
            local Patches = package.loaded["sui_patches"]
            if Patches and Patches.injectWallpaperIntoFullscreenWidget then
                local stack = require("sui_core").getWindowStack()
                for _, entry in ipairs(stack) do
                    if entry.widget and entry.widget._navbar_injected then
                        pcall(Patches.injectWallpaperIntoFullscreenWidget, entry.widget)
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

        -- ── Wallpapers sub-menu (delegates to Homescreen style API) ─────
        local function _HS()
            local ok, hs = pcall(require, "sui_homescreen")
            return ok and hs or nil
        end

        local function makeWallpapersMenu()
            local function makeWallpaperSubItems()
                local hs    = _HS()
                local items = {}
                -- Master on/off switch — when disabled all other options are greyed out
                items[#items + 1] = {
                    text         = _("Enable wallpaper"),
                    checked_func = function()
                        local h = _HS(); return h and h.styleGetWallpaperEnabled()
                    end,
                    callback = function()
                        local h = _HS()
                        if h then
                            local was_on = h.styleGetWallpaperEnabled()
                            h.styleSetWallpaperEnabled(not was_on)
                            _applyFullLayoutRefresh()
                        end
                    end,
                    keep_menu_open = true,
                    separator      = true,
                }
                -- Transparent status bar (enabled only when a wallpaper is active)
                items[#items + 1] = {
                    text         = _("Transparent status bar"),
                    checked_func = function()
                        local h = _HS(); return h and h.styleStatusbarTransparent()
                    end,
                    enabled_func = function()
                        local h = _HS(); return h and h.styleGetWallpaperEnabled() and h.styleGetWallpaper() ~= nil
                    end,
                    callback = function()
                        local h = _HS()
                        if h then h.styleSetStatusbarTransparent(not h.styleStatusbarTransparent()) end

                        _applyFullLayoutRefresh()
                    end,
                    keep_menu_open = true,
                }
                -- Transparent navigation bar (enabled only when a wallpaper is active)
                items[#items + 1] = {
                    text         = _("Transparent navigation bar"),
                    checked_func = function()
                        local h = _HS(); return h and h.styleNavbarTransparent()
                    end,
                    enabled_func = function()
                        local h = _HS(); return h and h.styleGetWallpaperEnabled() and h.styleGetWallpaper() ~= nil
                    end,
                    callback = function()
                        local h = _HS()
                        if h then h.styleSetNavbarTransparent(not h.styleNavbarTransparent()) end

                        _applyFullLayoutRefresh()
                    end,
                    keep_menu_open = true,
                }
                -- Stretch to fill screen
                items[#items + 1] = {
                    text         = _("Stretch to fill screen"),
                    checked_func = function()
                        local h = _HS(); return h and h.styleGetWallpaperStretch()
                    end,
                    enabled_func = function()
                        local h = _HS(); return h and h.styleGetWallpaperEnabled() and h.styleGetWallpaper() ~= nil
                    end,
                    callback = function()
                        local h = _HS()
                        if h then h.styleSetWallpaperStretch(not h.styleGetWallpaperStretch()) end
                    end,
                    keep_menu_open = true,
                }
                -- Auto-rotate image to match screen orientation
                items[#items + 1] = {
                    text         = _("Rotate image"),
                    checked_func = function()
                        local h = _HS(); return h and h.styleGetWallpaperAutoRotate()
                    end,
                    enabled_func = function()
                        local h = _HS(); return h and h.styleGetWallpaperEnabled() and h.styleGetWallpaper() ~= nil
                    end,
                    callback = function()
                        local h = _HS()
                        if h then h.styleSetWallpaperAutoRotate(not h.styleGetWallpaperAutoRotate()) end
                    end,
                    keep_menu_open = true,
                }
                -- Invert image in night mode
                items[#items + 1] = {
                    text         = _("Invert image colours in night mode"),
                    checked_func = function()
                        local h = _HS(); return h and h.styleGetWallpaperInvertNight()
                    end,
                    enabled_func = function()
                        local h = _HS(); return h and h.styleGetWallpaperEnabled() and h.styleGetWallpaper() ~= nil
                    end,
                    callback = function()
                        local h = _HS()
                        if h then h.styleSetWallpaperInvertNight(not h.styleGetWallpaperInvertNight()) end
                    end,
                    keep_menu_open = true,
                }
                -- Opacity / fade-toward-white level
                items[#items + 1] = {
                    text_func    = function()
                        local h   = _HS()
                        local val = h and h.styleGetWallpaperOpacity() or 0
                        return T(_("Image opacity: %1%"), 100 - val)
                    end,
                    enabled_func = function()
                        local h = _HS(); return h and h.styleGetWallpaperEnabled() and h.styleGetWallpaper() ~= nil
                    end,
                    callback = function(touchmenu_instance)
                        local SpinWidget = require("ui/widget/spinwidget")
                        local h          = _HS()
                        if not h then return end
                        local spin = SpinWidget:new{
                            title_text    = _("Image opacity"),
                            info_text     = _("Lower the opacity to improve readability."),
                            value         = 100 - (h.styleGetWallpaperOpacity() or 0),
                            default_value = 100,
                            value_min     = 1,
                            value_max     = 100,
                            value_step    = 1,
                            value_hold_step = 10,
                            unit          = "%",
                            callback      = function(widget)
                                h.styleSetWallpaperOpacity(100 - widget.value)
                                if touchmenu_instance then
                                    touchmenu_instance:updateItems()
                                end
                            end,
                        }
                        UIManager:show(spin)
                    end,
                    keep_menu_open = true,
                    separator = true,
                }
                -- Show wallpaper on all screens (FM, overlays, Collections, History)
                items[#items + 1] = {
                    text         = _("Show wallpaper on all screens"),
                    checked_func = function()
                        local h = _HS(); return h and h.styleGetWallpaperShowInFM()
                    end,
                    enabled_func = function()
                        local h = _HS(); return h and h.styleGetWallpaperEnabled() and h.styleGetWallpaper() ~= nil
                    end,
                    callback = function()
                        local h = _HS()
                        if h then h.styleSetWallpaperShowInFM(not h.styleGetWallpaperShowInFM()) end
                        _applyFullLayoutRefresh()
                    end,
                    keep_menu_open = true,
                    separator      = true,
                }
                -- Image list (None + scanned files)
                items[#items + 1] = {
                    text         = _("None"),
                    radio        = true,
                    checked_func = function()
                        local h = _HS(); return h and h.styleGetWallpaper() == nil
                    end,
                    enabled_func = function()
                        local h = _HS(); return h and h.styleGetWallpaperEnabled()
                    end,
                    callback = function()
                        local h = _HS()
                        if h then
                            local was_set = h.styleGetWallpaper() ~= nil
                            h.styleSetWallpaper(nil)
                            if was_set then
                                _applyFullLayoutRefresh()
                            end
                        end
                    end,
                }
                if hs then
                    local list = hs.styleScanWallpapers()
                    if #list == 0 then
                        items[#items + 1] = {
                            text         = T(_("No images found.\nDrop files into:\n%1"),
                                            hs.styleGetWallpapersDir()),
                            enabled_func = function() return false end,
                            callback     = function() end,
                        }
                    else
                        for _, item in ipairs(list) do
                            local p, l = item.path, item.label
                            items[#items + 1] = {
                                text         = l,
                                radio        = true,
                                checked_func = function()
                                    local h = _HS(); return h and h.styleGetWallpaper() == p
                                end,
                                enabled_func = function()
                                    local h = _HS(); return h and h.styleGetWallpaperEnabled()
                                end,
                                callback = function()
                                    local h = _HS()
                                    if h then h.styleSetWallpaper(p) end
                                    _applyFullLayoutRefresh()
                                end,
                            }
                        end
                    end
                end
                return items
            end

            return {
                text = _("Wallpaper"),
                sub_item_table_func = makeWallpaperSubItems,
            }
        end

        -- ── Behaviour sub-menu (items previously flat in HS menu) ────────
        local function makeBehaviourMenu()
            return {
                text = _("Behaviour"),
                sub_item_table = {
            {
                text         = _("Start with Home Screen"),
                checked_func = function()
                    return G_reader_settings:readSetting("start_with", "filemanager") == "homescreen_simpleui"
                end,
                callback = function()
                    local on = G_reader_settings:readSetting("start_with", "filemanager") == "homescreen_simpleui"
                    G_reader_settings:saveSetting("start_with", on and "filemanager" or "homescreen_simpleui")
                end,
            },
            {
                text         = _("Return to Book Folder"),
                help_text    = _("When enabled, opening the file browser after finishing or closing a book navigates to the folder the book is in, matching native KOReader behaviour.\nWhen disabled (default), SimpleUI always returns to the library root.\nThis option works independently of \"Start with Home Screen\"."),
                checked_func = function()
                    return SUISettings:isTrue("simpleui_hs_return_to_book_folder")
                end,
                keep_menu_open = true,
                callback = function()
                    local on = SUISettings:isTrue("simpleui_hs_return_to_book_folder")
                    SUISettings:saveSetting("simpleui_hs_return_to_book_folder", not on)
                end,
            },
            {
                text      = _("Closing Notice"),
                help_text = _("Controls when the brief \"Closing book…\" notice is shown when leaving a book.\n\n• Always: shown whenever a book is closed, whether via the menu or a gesture.\n• Gesture Only: shown only when closing via a gesture (e.g. swipe); not shown when using the reader menu.\n• Never: the notice is never shown."),
                sub_item_table = {
                    {
                        text         = _("Always"),
                        radio        = true,
                        checked_func = function()
                            local mode = SUISettings:readSetting("simpleui_hs_closing_notice_mode")
                            if mode then return mode == "always" end
                            -- Migrate from old boolean: nil/true → "always"
                            return SUISettings:nilOrTrue("simpleui_hs_closing_notice")
                        end,
                        keep_menu_open = true,
                        callback = function()
                            SUISettings:saveSetting("simpleui_hs_closing_notice_mode", "always")
                        end,
                    },
                    {
                        text         = _("Gesture Only"),
                        radio        = true,
                        checked_func = function()
                            return SUISettings:readSetting("simpleui_hs_closing_notice_mode") == "gesture_only"
                        end,
                        keep_menu_open = true,
                        callback = function()
                            SUISettings:saveSetting("simpleui_hs_closing_notice_mode", "gesture_only")
                        end,
                    },
                    {
                        text         = _("Never"),
                        radio        = true,
                        checked_func = function()
                            local mode = SUISettings:readSetting("simpleui_hs_closing_notice_mode")
                            if mode then return mode == "never" end
                            -- Migrate from old boolean: explicit false → "never"
                            return SUISettings:get("simpleui_hs_closing_notice") == false
                        end,
                        keep_menu_open = true,
                        callback = function()
                            SUISettings:saveSetting("simpleui_hs_closing_notice_mode", "never")
                        end,
                    },
                },
            },
            {
                text         = _("Settings on Long Tap"),
                help_text    = _("When enabled, long-pressing a section opens its settings menu.\nDisable this to prevent the settings menu from appearing on long tap."),
                checked_func = function()
                    return SUISettings:nilOrTrue("simpleui_hs_settings_on_hold")
                end,
                keep_menu_open = true,
                callback = function()
                    local on = SUISettings:nilOrTrue("simpleui_hs_settings_on_hold")
                    SUISettings:saveSetting("simpleui_hs_settings_on_hold", not on)
                end,
            },
            {
                text         = _("Warn When Modules Overflow"),
                help_text    = _("When enabled, a notice is shown if the modules on a page are taller than the visible area.\nDisable this to silence the warning."),
                checked_func = function()
                    return SUISettings:nilOrTrue("simpleui_hs_overflow_warn")
                end,
                keep_menu_open = true,
                callback = function()
                    local on = SUISettings:nilOrTrue("simpleui_hs_overflow_warn")
                    SUISettings:saveSetting("simpleui_hs_overflow_warn", not on)
                    -- Reset the per-session dedup key so the warning fires
                    -- immediately if overflow is still present and was re-enabled.
                    local ok_hs, HS = pcall(require, "sui_homescreen")
                    if ok_hs and HS and HS._instance then
                        HS._instance._overflow_warn_key = nil
                    end
                end,
                separator = true,
            },
                },  -- end Behaviour.sub_item_table
            }       -- end Behaviour item
        end         -- end makeBehaviourMenu

        -- ── Presets sub-menu ────────────────────────────────────────────
        -- Lazy-require so that sui_presets.lua is only loaded when the user
        -- actually opens the Homescreen menu (never at boot).
        local function _Presets()
            local ok, p = pcall(require, "sui_presets")
            return ok and p or nil
        end

        local function makePresetsMenu()
            local items = {}

            -- ── Apply ──────────────────────────────────────────────────
            -- One radio-style entry per saved preset.  Appears first so it is
            -- the primary action when the user opens the sub-menu.
            local P     = _Presets()
            local names = P and P.listNames() or {}

            if #names > 0 then
                for _i, name in ipairs(names) do
                    local _name = name
                    items[#items + 1] = {
                        text_func = function()
                            -- Show a checkmark next to the preset whose name
                            -- matches the value stored in "simpleui_hs_active_preset".
                            local active = SUISettings:get("simpleui_hs_active_preset")
                            if active == _name then
                                return "✓  " .. _name
                            end
                            return "    " .. _name
                        end,
                        callback = function()
                            local p = _Presets()
                            if not p then return end
                            if p.apply(_name) then
                                SUISettings:set("simpleui_hs_active_preset", _name)
                                UIManager:nextTick(function()
                                    _applyFullLayoutRefresh()
                                end)
                            else
                                UIManager:show(InfoMessage():new{
                                    text    = string.format(_("Preset \"%s\" not found."), _name),
                                    timeout = 2,
                                })
                            end
                        end,
                    }
                end
                -- Visual separator between apply list and management actions.
                items[#items].separator = true
            end

            -- ── Save current as new preset ─────────────────────────────
            items[#items + 1] = {
                text     = _("Save as new preset…"),
                callback = function()
                    local p = _Presets()
                    if not p then return end
                    local dialog
                    dialog = InputDialog():new{
                        title    = _("Save preset"),
                        input    = "",
                        input_hint = _("Preset name"),
                        buttons  = {{
                            {
                                text     = _("Cancel"),
                                id       = "close",
                                callback = function()
                                    UIManager:close(dialog)
                                end,
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
                                    local overwrite = p.exists(name)
                                    local function _doSave()
                                        p.save(name)
                                        SUISettings:set("simpleui_hs_active_preset", name)
                                        UIManager:close(dialog)
                                        UIManager:show(InfoMessage():new{
                                            text    = string.format(_("Preset \"%s\" saved."), name),
                                            timeout = 2,
                                        })
                                    end
                                    if overwrite then
                                        UIManager:show(ConfirmBox():new{
                                            text        = string.format(
                                                _("A preset named \"%s\" already exists.\nOverwrite it?"),
                                                name
                                            ),
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

            -- ── Overwrite existing preset with current state ───────────
            if #names > 0 then
                items[#items + 1] = {
                    text = _("Update existing preset…"),
                    sub_item_table_func = function()
                        local p2   = _Presets()
                        local sub  = {}
                        for _i, name in ipairs(p2 and p2.listNames() or {}) do
                            local _name = name
                            sub[#sub + 1] = {
                                text     = _name,
                                callback = function()
                                    local p3 = _Presets()
                                    if not p3 then return end
                                    UIManager:show(ConfirmBox():new{
                                        text        = string.format(
                                            _("Overwrite preset \"%s\" with the current homescreen settings?"),
                                            _name
                                        ),
                                        ok_text     = _("Overwrite"),
                                        cancel_text = _("Cancel"),
                                        ok_callback = function()
                                            p3.save(_name)
                                            SUISettings:set("simpleui_hs_active_preset", _name)
                                            UIManager:show(InfoMessage():new{
                                                text    = string.format(_("Preset \"%s\" updated."), _name),
                                                timeout = 2,
                                            })
                                        end,
                                    })
                                end,
                            }
                        end
                        return sub
                    end,
                }
            end

            -- ── Rename ────────────────────────────────────────────────
            if #names > 0 then
                items[#items + 1] = {
                    text = _("Rename preset…"),
                    sub_item_table_func = function()
                        local p2  = _Presets()
                        local sub = {}
                        for _i, name in ipairs(p2 and p2.listNames() or {}) do
                            local _name = name
                            sub[#sub + 1] = {
                                text     = _name,
                                callback = function()
                                    local dialog2
                                    dialog2 = InputDialog():new{
                                        title    = string.format(_("Rename \"%s\""), _name),
                                        input    = _name,
                                        buttons  = {{
                                            {
                                                text     = _("Cancel"),
                                                id       = "close",
                                                callback = function()
                                                    UIManager:close(dialog2)
                                                end,
                                            },
                                            {
                                                text             = _("Rename"),
                                                is_enter_default = true,
                                                callback         = function()
                                                    local new_name = dialog2:getInputText()
                                                    new_name = new_name and new_name:match("^%s*(.-)%s*$") or ""
                                                    if new_name == "" or new_name == _name then
                                                        UIManager:close(dialog2)
                                                        return
                                                    end
                                                    local p3 = _Presets()
                                                    if not p3 then return end
                                                    if p3.exists(new_name) then
                                                        UIManager:show(InfoMessage():new{
                                                            text    = string.format(
                                                                _("A preset named \"%s\" already exists."),
                                                                new_name
                                                            ),
                                                            timeout = 2,
                                                        })
                                                        return
                                                    end
                                                    p3.rename(_name, new_name)
                                                    local active = SUISettings:get("simpleui_hs_active_preset")
                                                    if active == _name then
                                                        SUISettings:set("simpleui_hs_active_preset", new_name)
                                                    end
                                                    UIManager:close(dialog2)
                                                end,
                                            },
                                        }},
                                    }
                                    UIManager:show(dialog2)
                                end,
                            }
                        end
                        return sub
                    end,
                }
            end

            -- ── Delete ────────────────────────────────────────────────
            if #names > 0 then
                items[#items + 1] = {
                    text = _("Delete preset…"),
                    sub_item_table_func = function()
                        local p2  = _Presets()
                        local sub = {}
                        for _i, name in ipairs(p2 and p2.listNames() or {}) do
                            local _name = name
                            sub[#sub + 1] = {
                                text     = _name,
                                callback = function()
                                    UIManager:show(ConfirmBox():new{
                                        text        = string.format(
                                            _("Delete preset \"%s\"?"),
                                            _name
                                        ),
                                        ok_text     = _("Delete"),
                                        cancel_text = _("Cancel"),
                                        ok_callback = function()
                                            local p3 = _Presets()
                                            if not p3 then return end
                                            p3.delete(_name)
                                            local active = SUISettings:get("simpleui_hs_active_preset")
                                            if active == _name then
                                                SUISettings:del("simpleui_hs_active_preset")
                                            end
                                        end,
                                    })
                                end,
                            }
                        end
                        return sub
                    end,
                }
            end

            -- ── Import ────────────────────────────────────────────────
            items[#items + 1] = {
                text = _("Import preset…"),
                sub_item_table_func = function()
                    local p = _Presets()
                    local sub = {}
                    if not p then return sub end
                    local files = p.listImportFiles()

                    sub[#sub + 1] = {
                        text     = _("Open import folder"),
                        callback = function()
                            local dir = p.getImportDir()
                            if not dir then return end
                            local FM = package.loaded["apps/filemanager/filemanager"]
                            if FM and FM.instance and FM.instance.file_chooser then
                                local HS = package.loaded["sui_homescreen"]
                                if HS and HS._instance then
                                    HS._instance._navbar_closing_intentionally = true
                                    require("ui/uimanager"):close(HS._instance)
                                end
                                FM.instance.file_chooser:changeToPath(dir)
                            end
                        end,
                        separator = #files > 0,
                    }

                    if #files == 0 then
                        sub[#sub + 1] = {
                            text    = T(_("No preset files found.\nPlace .lua files in:\n%1"), p.getImportDir() or ""),
                            enabled = false,
                        }
                    else
                        for _i, f in ipairs(files) do
                            local _f = f
                            sub[#sub + 1] = {
                                text     = _f.name,
                                callback = function()
                                    local imported_name, err = p.import(_f.path)
                                    if imported_name then
                                        UIManager:show(InfoMessage():new{
                                            text = string.format(_("Preset \"%s\" imported."), imported_name),
                                            timeout = 3,
                                        })
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

            -- ── Export ────────────────────────────────────────────────
            if #names > 0 then
                items[#items + 1] = {
                    text = _("Export preset…"),
                    sub_item_table_func = function()
                        local p2  = _Presets()
                        local sub = {}
                        for _i, name in ipairs(p2 and p2.listNames() or {}) do
                            local _name = name
                            sub[#sub + 1] = {
                                text     = _name,
                                callback = function()
                                    local p3 = _Presets()
                                    if not p3 then return end
                                    local filepath, err = p3.export(_name)
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
        end

        -- ── Final menu structure ─────────────────────────────────────────
        return {
            -- Homepage Presets ► (topo, separador abaixo para separar das opções de comportamento)
            {
                text_func = function()
                    local P     = _Presets()
                    local names = P and P.listNames() or {}
                    local active = SUISettings:get("simpleui_hs_active_preset")
                    if active and active ~= "" then
                        return string.format(_("Homepage Presets  [%s]"), active)
                    end
                    if #names == 0 then
                        return _("Homepage Presets")
                    end
                    return string.format(_("Homepage Presets  (%d)"), #names)
                end,
                sub_item_table_func = makePresetsMenu,
                separator = true,
            },
            -- Behaviour ►
            makeBehaviourMenu(),
            -- Wallpapers ►
            makeWallpapersMenu(),
            -- Modules (N) ►
            table.unpack(modules_items),
        }
    end



    -- Local helper: updates the active tab in the FileManager bar.
    function setActiveAndRefreshFM(plugin_ref, action_id, tabs)
        plugin_ref.active_action = action_id
        local fm = plugin_ref.ui
        if fm and fm._navbar_container then
            Bottombar.replaceBar(fm, Bottombar.buildBarWidget(action_id, fm._navbar_tabs or tabs), tabs)
            UIManager:setDirty(fm[1], "ui")
        end
        return action_id
    end

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
    menu_items.simpleui = {
        sorting_hint = "tools",
        text = _("Simple UI"),
        sub_item_table = {
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
            {
                text = _("Top"),
                sub_item_table = {
                    { text = _("Status Bar"), sub_item_table_func = makeTopbarMenu   },
                    { text = _("Title Bar"),  sub_item_table_func = makeTitleBarMenu },
                    {
                        text       = _("Settings Tab"),
                        help_text  = _("Show or hide the dedicated Simple UI tab in the menu bar.\nWhen hidden, Simple UI settings remain accessible via the main menu.\nTakes effect after a restart."),
                        checked_func = function()
                            return SUISettings:nilOrTrue("simpleui_settings_tab_enabled")
                        end,
                        keep_menu_open = true,
                        callback = function()
                            local on = SUISettings:nilOrTrue("simpleui_settings_tab_enabled")
                            SUISettings:saveSetting("simpleui_settings_tab_enabled", not on)
                            UIManager:show(ConfirmBox():new{
                                text = string.format(
                                    _("The Simple UI settings tab will be %s after restart.\n\nRestart now?"),
                                    on and _("hidden") or _("shown")
                                ),
                                ok_text = _("Restart"), cancel_text = _("Later"),
                                ok_callback = function()
                                    SUISettings:flush()
                                    UIManager:restartKOReader()
                                end,
                            })
                        end,
                    },
                },
            },
            { text = _("Home Screen"), sub_item_table_func = makeHomescreenMenu },
            {
                text = _("Bottom"),
                sub_item_table = {
                    { text = _("Navigation Bar"), sub_item_table_func = makeNavbarMenu          },
                    { text = _("Pagination Bar"), sub_item_table_func = makePaginationBarMenu   },
                },
            },
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
            -- ── Style ─────────────────────────────────────────────────────────
            {
                text = _("Style"),
                sub_item_table = {
                    {
                        text = _("Icons"),
                        sub_item_table = {
                            -- ── Icon Presets ──────────────────────────────────────────
                            {
                                text_func = function()
                                    local ok_ip, P = pcall(require, "sui_presets")
                                    if not ok_ip or not P then return _("Icon Presets") end
                                    local names = P.icons.listNames()
                                    local active = SUISettings:get("simpleui_icon_active_preset")
                                    if active and active ~= "" then
                                        return string.format(_("Icon Presets  [%s]"), active)
                                    end
                                    if #names == 0 then return _("Icon Presets") end
                                    return string.format(_("Icon Presets  (%d)"), #names)
                                end,
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

                                    -- ── Apply: one entry per saved preset ──────────────────
                                    if #names > 0 then
                                        for _k, name in ipairs(names) do
                                            local _name = name
                                            items[#items + 1] = {
                                                text_func = function()
                                                    local active = SUISettings:get("simpleui_icon_active_preset")
                                                    return (active == _name and "\u{2713}  " or "    ") .. _name
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
                                        items[#items].separator = true
                                    end

                                    -- ── Save as new preset ─────────────────────────────────
                                    items[#items + 1] = {
                                        text     = _("Save as new preset…"),
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

                                    -- ── Update existing preset ─────────────────────────────
                                    if #names > 0 then
                                        items[#items + 1] = {
                                            text = _("Update existing preset…"),
                                            sub_item_table_func = function()
                                                local sub = {}
                                                for _k, name in ipairs(IP and IP.listNames() or {}) do
                                                    local _name = name
                                                    sub[#sub + 1] = {
                                                        text     = _name,
                                                        callback = function()
                                                            UIManager:show(ConfirmBox():new{
                                                                text        = string.format(
                                                                    _("Overwrite preset \"%s\" with the current icon settings?"), _name),
                                                                ok_text     = _("Overwrite"),
                                                                cancel_text = _("Cancel"),
                                                                ok_callback = function()
                                                                    if IP then
                                                                        IP.save(_name)
                                                                        SUISettings:set("simpleui_icon_active_preset", _name)
                                                                        UIManager:show(InfoMessage():new{
                                                                            text    = string.format(_("Preset \"%s\" updated."), _name),
                                                                            timeout = 2,
                                                                        })
                                                                    end
                                                                end,
                                                            })
                                                        end,
                                                    }
                                                end
                                                return sub
                                            end,
                                        }
                                    end

                                    -- ── Rename ─────────────────────────────────────────────
                                    if #names > 0 then
                                        items[#items + 1] = {
                                            text = _("Rename preset…"),
                                            sub_item_table_func = function()
                                                local sub = {}
                                                for _k, name in ipairs(IP and IP.listNames() or {}) do
                                                    local _name = name
                                                    sub[#sub + 1] = {
                                                        text     = _name,
                                                        callback = function()
                                                            local dialog2
                                                            dialog2 = InputDialog():new{
                                                                title   = string.format(_("Rename \"%s\""), _name),
                                                                input   = _name,
                                                                buttons = {{
                                                                    {
                                                                        text     = _("Cancel"),
                                                                        id       = "close",
                                                                        callback = function() UIManager:close(dialog2) end,
                                                                    },
                                                                    {
                                                                        text             = _("Rename"),
                                                                        is_enter_default = true,
                                                                        callback         = function()
                                                                            local new_name = dialog2:getInputText()
                                                                            new_name = new_name and new_name:match("^%s*(.-)%s*$") or ""
                                                                            if new_name == "" or new_name == _name then
                                                                                UIManager:close(dialog2)
                                                                                return
                                                                            end
                                                                            if IP and IP.exists(new_name) then
                                                                                UIManager:show(InfoMessage():new{
                                                                                    text    = string.format(
                                                                                        _("A preset named \"%s\" already exists."), new_name),
                                                                                    timeout = 2,
                                                                                })
                                                                                return
                                                                            end
                                                                            if IP then
                                                                                IP.rename(_name, new_name)
                                                                                local active = SUISettings:get("simpleui_icon_active_preset")
                                                                                if active == _name then
                                                                                    SUISettings:set("simpleui_icon_active_preset", new_name)
                                                                                end
                                                                            end
                                                                            UIManager:close(dialog2)
                                                                        end,
                                                                    },
                                                                }},
                                                            }
                                                            UIManager:show(dialog2)
                                                        end,
                                                    }
                                                end
                                                return sub
                                            end,
                                        }
                                    end

                                    -- ── Delete ─────────────────────────────────────────────
                                    if #names > 0 then
                                        items[#items + 1] = {
                                            text = _("Delete preset…"),
                                            sub_item_table_func = function()
                                                local sub = {}
                                                for _k, name in ipairs(IP and IP.listNames() or {}) do
                                                    local _name = name
                                                    sub[#sub + 1] = {
                                                        text     = _name,
                                                        callback = function()
                                                            UIManager:show(ConfirmBox():new{
                                                                text        = string.format(_("Delete preset \"%s\"?"), _name),
                                                                ok_text     = _("Delete"),
                                                                cancel_text = _("Cancel"),
                                                                ok_callback = function()
                                                                    if IP then
                                                                        IP.delete(_name)
                                                                        local active = SUISettings:get("simpleui_icon_active_preset")
                                                                        if active == _name then
                                                                            SUISettings:del("simpleui_icon_active_preset")
                                                                        end
                                                                    end
                                                                end,
                                                            })
                                                        end,
                                                    }
                                                end
                                                return sub
                                            end,
                                        }
                                    end

                                    -- ── Import ─────────────────────────────────────────────
                                    items[#items + 1] = {
                                        text = _("Import preset…"),
                                        sub_item_table_func = function()
                                            local sub = {}
                                            if not IP then return sub end
                                            local files = IP.listImportFiles()

                                            sub[#sub + 1] = {
                                                text     = _("Open import folder"),
                                                callback = function()
                                                    local dir = IP.getImportDir()
                                                    if not dir then return end
                                                    local FM = package.loaded["apps/filemanager/filemanager"]
                                                    if FM and FM.instance and FM.instance.file_chooser then
                                                    local HS = package.loaded["sui_homescreen"]
                                                    if HS and HS._instance then
                                                        HS._instance._navbar_closing_intentionally = true
                                                        require("ui/uimanager"):close(HS._instance)
                                                    end
                                                        FM.instance.file_chooser:changeToPath(dir)
                                                    end
                                                end,
                                                separator = #files > 0,
                                            }

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
                                            text = _("Export preset…"),
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

                            -- ── Icon Packs ────────────────────────────────────────────
                            {
                                text_func = function()
                                    local ok_ip, IP = pcall(require, "sui_style")
                                    if not ok_ip or not IP then return _("Icon Packs") end
                                    local n = #IP.listPacks()
                                    if n == 0 then return _("Icon Packs") end
                                    return string.format(_("Icon Packs  (%d)"), n)
                                end,
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
                                text = _("Install pack from ZIP…"),
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
                            },
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
                            },
                        },
                    },
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
                },
            },
            {
                text = _("Library"),
                sub_item_table_func = function()
                    local ok_fc, FC = pcall(require, "sui_foldercovers")
                    if not ok_fc or not FC then return {} end
                    -- Refresh the mosaic view immediately after any setting change.
                    local function _refreshFC()
                        local FM = package.loaded["apps/filemanager/filemanager"]
                        local fm = FM and FM.instance
                        if fm and fm.file_chooser then
                            -- refreshPath rebuilds the item list from scratch and
                            -- passes it through switchItemTable, which is where the
                            -- series-grouping hook (_sgProcessItemTable) runs.
                            -- updateItems alone skips that hook, so grouping would
                            -- only appear after a manual refresh.
                        fm._navbar_suppress_path_change = true
                        fm.file_chooser:refreshPath()
                        fm._navbar_suppress_path_change = nil
                        end
                    end
                    return {
                        {
                            text         = _("Browse by Author / Series / Tags"),
                            checked_func = function()
                                local ok_bm, BM = pcall(require, "sui_browsemeta")
                                return ok_bm and BM and BM.isEnabled()
                            end,
                            separator    = true,
                            callback     = function()
                                local ok_bm, BM = pcall(require, "sui_browsemeta")
                                if not (ok_bm and BM) then return end
                                local enabling = not BM.isEnabled()
                                BM.setEnabled(enabling)
                                -- Teardown titlebar FIRST so the fc.genItemTable hook
                                -- (which holds BM upvalues) is removed before
                                -- BM.uninstall() nils _orig_genItemTable.
                                local FM2 = package.loaded["apps/filemanager/filemanager"]
                                local fm2 = FM2 and FM2.instance
                                if fm2 then
                                    local ok_tb, TB = pcall(require, "sui_titlebar")
                                    if ok_tb and TB then pcall(TB.restore, fm2) end
                                end
                                if enabling then
                                    pcall(BM.install)
                                else
                                    -- Exit virtual tree before uninstalling.
                                    local fc2 = fm2 and fm2.file_chooser
                                    if fc2 and fc2.path then
                                        if fc2.path:find("/\u{E257}", 1, true) then
                                            BM.exitToNormal(fc2, fm2)
                                        end
                                    end
                                    -- Safety net: ensure "normal" is persisted even
                                    -- when the FC was already on a real path (so
                                    -- exitToNormal was skipped) or if exitToNormal
                                    -- errored before reaching setSavedMode. Must run
                                    -- before uninstall so the patches are still intact
                                    -- when changeToPath fires from exitToNormal above.
                                    BM.setSavedMode("normal")
                                    pcall(BM.uninstall)
                                end
                                -- Rebuild titlebar (with or without browse button).
                                if fm2 then
                                    local ok_tb, TB = pcall(require, "sui_titlebar")
                                    if ok_tb and TB then pcall(TB.apply, fm2) end
                                end
                            end,
                        },
                        {
                            text         = _("Folder Covers"),
                            checked_func = function() return FC.isEnabled() end,
                            separator    = true,
                            sub_item_table = {
                                {
                                    text           = _("Enable Folder Covers"),
                                    checked_func   = function() return FC.isEnabled() end,
                                    keep_menu_open = true,
                                    separator      = true,
                                    callback       = function()
                                        local enabling = not FC.isEnabled()
                                        FC.setEnabled(enabling)
                                        -- Install or uninstall the MosaicMenuItem patch
                                        -- at toggle time so that third-party user-patches
                                        -- (e.g. 2-browser-folder-cover.lua) that rely on
                                        -- userpatch.getUpValue(MosaicMenuItem.update, …)
                                        -- find the original function when FC is off.
                                        if enabling then
                                            pcall(FC.install)
                                        else
                                            pcall(FC.uninstall)
                                        end
                                        _refreshFC()
                                    end,
                                },
                                {
                                    text           = _("Single Cover"),
                                    radio          = true,
                                    checked_func   = function() return FC.getFolderStyle() == "single" end,
                                    enabled_func   = function() return FC.isEnabled() end,
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
                                    enabled_func   = function() return FC.isEnabled() end,
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
                                    enabled_func   = function() return FC.isEnabled() end,
                                    keep_menu_open = true,
                                    callback       = function()
                                        FC.setFolderStyle("auto")
                                        FC.invalidateCache()
                                        _refreshFC()
                                    end,
                                },
                            },
                        },
                        {
                            text           = _("Group Books by Series"),
                            checked_func   = function() return FC.getSeriesGrouping() end,
                            keep_menu_open = true,
                            enabled_func   = function() return FC.isEnabled() end,
                            callback       = function()
                                FC.setSeriesGrouping(not FC.getSeriesGrouping())
                                FC.invalidateCache()
                                _refreshFC()
                            end,
                        },
                        {
                            text         = _("Overlays"),
                            enabled_func = function() return FC.isEnabled() end,
                            sub_item_table = {
                                -- ── Badges ───────────────────────────────────────────────────────
                                {
                                    text         = _("Badges"),
                                    sub_item_table = {
                                        {
                                            text_func = function()
                                                return _("Size")
                                            end,
                                            keep_menu_open = true,
                                            separator = true,
                                            callback = function()
                                                local SpinWidget = require("ui/widget/spinwidget")
                                                UIManager:show(SpinWidget:new{
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
                                        -- ── Number of Books in Folder ─────────────────────────────
                                        {
                                            text         = _("Number of Books in Folder"),
                                            sub_item_table = {
                                                {
                                                    text           = _("Hidden"),
                                                    checked_func   = function() return FC.getBadgeHidden() end,
                                                    keep_menu_open = true,
                                                    separator      = true,
                                                    callback       = function()
                                                        FC.setBadgeHidden(not FC.getBadgeHidden())
                                                        FC.invalidateCache()
                                                        _refreshFC()
                                                    end,
                                                },
                                                {
                                                    text           = _("Top"),
                                                    radio          = true,
                                                    checked_func   = function() return not FC.getBadgeHidden() and FC.getBadgePosition() == "top" end,
                                                    enabled_func   = function() return not FC.getBadgeHidden() end,
                                                    keep_menu_open = true,
                                                    callback       = function() FC.setBadgePosition("top"); _refreshFC() end,
                                                },
                                                {
                                                    text           = _("Bottom"),
                                                    radio          = true,
                                                    checked_func   = function() return not FC.getBadgeHidden() and FC.getBadgePosition() == "bottom" end,
                                                    enabled_func   = function() return not FC.getBadgeHidden() end,
                                                    keep_menu_open = true,
                                                    separator      = true,
                                                    callback       = function() FC.setBadgePosition("bottom"); _refreshFC() end,
                                                },
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
                                        -- ── Number of Pages ───────────────────────────────────────
                                        {
                                            text         = _("Number of Pages"),
                                            sub_item_table = {
                                                {
                                                    text           = _("Hidden"),
                                                    checked_func   = function() return not FC.getOverlayPages() end,
                                                    keep_menu_open = true,
                                                    separator      = true,
                                                    callback       = function() FC.setOverlayPages(not FC.getOverlayPages()); FC.invalidateCache(); _refreshFC() end,
                                                },
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
                                        -- ── Series Index ──────────────────────────────────────────
                                        {
                                            text         = _("Series Index"),
                                            sub_item_table = {
                                                {
                                                    text           = _("Hidden"),
                                                    checked_func   = function() return not FC.getOverlaySeries() end,
                                                    keep_menu_open = true,
                                                    separator      = true,
                                                    callback       = function() FC.setOverlaySeries(not FC.getOverlaySeries()); FC.invalidateCache(); _refreshFC() end,
                                                },
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
                                        -- ── Progress ────────────────────────────────────────
                                        {
                                            text         = _("Progress"),
                                            sub_item_table = {
                                                {
                                                    text           = _("Banner"),
                                                    radio          = true,
                                                    checked_func   = function() return FC.getProgressMode() == "banner" end,
                                                    keep_menu_open = true,
                                                    callback       = function()
                                                        FC.setProgressMode("banner")
                                                        FC.invalidateCache()
                                                        _refreshFC()
                                                    end,
                                                },
                                                {
                                                    text           = _("Native"),
                                                    radio          = true,
                                                    checked_func   = function() return FC.getProgressMode() == "native" end,
                                                    keep_menu_open = true,
                                                    callback       = function()
                                                        FC.setProgressMode("native")
                                                        FC.invalidateCache()
                                                        _refreshFC()
                                                    end,
                                                },
                                                {
                                                    text           = _("None"),
                                                    radio          = true,
                                                    checked_func   = function() return FC.getProgressMode() == "none" end,
                                                    keep_menu_open = true,
                                                    separator      = true,
                                                    callback       = function()
                                                        FC.setProgressMode("none")
                                                        FC.invalidateCache()
                                                        _refreshFC()
                                                    end,
                                                },
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
                                        -- ── New Book ───────────────────────────────────────────
                                        {
                                            text         = _("New Book"),
                                            sub_item_table = {
                                                {
                                                    text           = _("Hidden"),
                                                    checked_func   = function() return not FC.getOverlayNew() end,
                                                    keep_menu_open = true,
                                                    separator      = true,
                                                    callback       = function()
                                                        FC.setOverlayNew(not FC.getOverlayNew())
                                                        FC.invalidateCache()
                                                        _refreshFC()
                                                    end,
                                                },
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
                                -- ── Folder Name ───────────────────────────────────────────────────
                                {
                                    text         = _("Folder Name"),
                                    enabled_func = function() return not FC.getShowTitleStrip() end,
                                    sub_item_table = {
                                        {
                                            text           = _("Hidden"),
                                            checked_func   = function() return FC.getLabelMode() == "hidden" end,
                                            keep_menu_open = true,
                                            separator      = true,
                                            callback       = function()
                                                FC.setLabelMode(FC.getLabelMode() == "hidden" and "overlay" or "hidden")
                                                _refreshFC()
                                            end,
                                        },
                                        {
                                            text           = _("Transparent"),
                                            checked_func   = function() return FC.getLabelStyle() == "alpha" end,
                                            enabled_func   = function() return FC.getLabelMode() ~= "hidden" end,
                                            keep_menu_open = true,
                                            separator      = true,
                                            callback       = function()
                                                FC.setLabelStyle(FC.getLabelStyle() == "alpha" and "solid" or "alpha")
                                                _refreshFC()
                                            end,
                                        },
                                        {
                                            text           = _("Top"),
                                            radio          = true,
                                            checked_func   = function() return FC.getLabelPosition() == "top" end,
                                            enabled_func   = function() return FC.getLabelMode() ~= "hidden" end,
                                            keep_menu_open = true,
                                            callback       = function() FC.setLabelPosition("top"); _refreshFC() end,
                                        },
                                        {
                                            text           = _("Center"),
                                            radio          = true,
                                            checked_func   = function() return FC.getLabelPosition() == "center" end,
                                            enabled_func   = function() return FC.getLabelMode() ~= "hidden" end,
                                            keep_menu_open = true,
                                            callback       = function() FC.setLabelPosition("center"); _refreshFC() end,
                                        },
                                        {
                                            text           = _("Bottom"),
                                            radio          = true,
                                            checked_func   = function() return FC.getLabelPosition() == "bottom" end,
                                            enabled_func   = function() return FC.getLabelMode() ~= "hidden" end,
                                            keep_menu_open = true,
                                            callback       = function() FC.setLabelPosition("bottom"); _refreshFC() end,
                                        },
                                        (function()
                                            local Config = require("sui_config")
                                            return Config.makeScaleItem({
                                                text_func    = function() return _("Text size") end,
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
                                -- ── Title and Author Below Covers ───────────────────────────────────
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
                                                    UIManager:show(ConfirmBox():new{
                                                        text        = _("Title strip disabled.\n\nRestart now?"),
                                                        ok_text     = _("Restart"), cancel_text = _("Later"),
                                                        ok_callback = function()
                                                            SUISettings:flush()
                                                            UIManager:restartKOReader()
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
                                                UIManager:show(ConfirmBox():new{
                                                    text        = _("Title strip enabled.\n\nRestart now?"),
                                                    ok_text     = _("Restart"), cancel_text = _("Later"),
                                                    ok_callback = function()
                                                        SUISettings:flush()
                                                        UIManager:restartKOReader()
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
                                                UIManager:show(ConfirmBox():new{
                                                    text        = _("Title and author strip enabled.\n\nRestart now?"),
                                                    ok_text     = _("Restart"), cancel_text = _("Later"),
                                                    ok_callback = function()
                                                        SUISettings:flush()
                                                        UIManager:restartKOReader()
                                                    end,
                                                })
                                            end,
                                        },
                                    },
                                },
                            },
                        },
                        {
                            text           = _("Uniformize Covers (2:3)"),
                            checked_func   = function() return FC.getCoverMode() == "2_3" end,
                            enabled_func   = function() return FC.isEnabled() end,
                            keep_menu_open = true,
                            callback       = function()
                                FC.setCoverMode(FC.getCoverMode() == "2_3" and "default" or "2_3")
                                _refreshFC()
                            end,
                        },
                        {
                            text           = _("Hide selection underline"),
                            checked_func   = function() return FC.getHideUnderline() end,
                            enabled_func   = function() return FC.isEnabled() end,
                            keep_menu_open = true,
                            callback       = function() FC.setHideUnderline(not FC.getHideUnderline()); _refreshFC() end,
                        },
                        {
                            text           = _("Hide book spine"),
                            checked_func   = function() return FC.getHideSpine() end,
                            enabled_func   = function() return FC.isEnabled() end,
                            keep_menu_open = true,
                            callback       = function()
                                FC.setHideSpine(not FC.getHideSpine())
                                FC.invalidateCache()
                                _refreshFC()
                            end,
                        },
                        {
                            text           = _("Placeholder cover for bookless folders"),
                            checked_func   = function() return FC.getSubfolderCover() end,
                            enabled_func   = function() return FC.isEnabled() end,
                            keep_menu_open = true,
                            callback       = function()
                                FC.setSubfolderCover(not FC.getSubfolderCover())
                                -- Disable recursive search when the parent option is turned off.
                                if not FC.getSubfolderCover() then
                                    FC.setRecursiveCover(false)
                                end
                                FC.invalidateCache()
                                _refreshFC()
                            end,
                        },
                        {
                            text           = _("Scan subfolders for cover"),
                            checked_func   = function() return FC.getRecursiveCover() end,
                            enabled_func   = function() return FC.isEnabled() and FC.getSubfolderCover() end,
                            keep_menu_open = true,
                            callback       = function()
                                FC.setRecursiveCover(not FC.getRecursiveCover())
                                FC.invalidateCache()
                                _refreshFC()
                            end,
                        },
                    }
                end,
            },
            -- -----------------------------------------------------------------
            -- "Custom Tabs" groups the settings for each custom-tab plugin
            -- that slots into SimpleUI's navbar.  Right now only BookFusion
            -- lives here; future custom tabs can be added alongside it.
            -- Each tab's builder is pcall-wrapped so a syntax error in one
            -- can't knock out the whole Simple UI settings menu.
            -- -----------------------------------------------------------------
            {
                text = _("Custom Tabs"),
                sub_item_table_func = function()
                    local items = {}
                    local ok_bfs, BFS = pcall(require, "sui_bookfusion_settings")
                    if ok_bfs and BFS and BFS.build then
                        items[#items+1] = BFS.build()
                    end
                    return items
                end,
            },
            -- -----------------------------------------------------------------
            -- Developer submenu
            -- To re-enable: change _SHOW_DEVELOPER_MENU to true (line below).
            -- -----------------------------------------------------------------
            -- About submenu
            -- -----------------------------------------------------------------
            {
                text                = _("About"),
                separator           = true,
                sub_item_table_func = function()
                    local _plugin_dir = (debug.getinfo(1, "S").source or ""):match("^@(.+)/[^/]+$")
                    local ok, Meta = pcall(dofile, _plugin_dir .. "/_meta.lua")
                    if not ok or type(Meta) ~= "table" then
                        local rok, rmeta = pcall(require, "_meta")
                        Meta = (rok and rmeta) or {}
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
                            text      = _("Check for Updates"),
                            callback  = function()
                                local ok, Updater = pcall(require, "sui_updater")
                                if not ok then
                                    UIManager:show(InfoMessage():new{
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
                                local ConfirmBox = require("ui/widget/confirmbox")
                                UIManager:show(ConfirmBox:new{
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
                                        UIManager:restartKOReader()
                                    end,
                                })
                            end,
                        },
                    }
                end,
            },
        },
    }
    -- Update banner: injected as the first item of the main menu
    -- when a newer version is available. Uses in-memory cache (zero I/O).
    -- Kept separate from the table literal so sub_item_table remains a
    -- plain table — buildTabItems reads it directly and requires that.
    do
        local ok_u, Updater = pcall(require, "sui_updater")
        local banner = (ok_u and Updater) and Updater.build_update_banner_item() or nil
        if banner then
            table.insert(menu_items.simpleui.sub_item_table, 1, banner)
        end
    end
end -- addToMainMenu

-- Build the item list for the dedicated SimpleUI settings tab.
-- Called by the tab-injection patch in main.lua every time the menu opens.
-- We call the real addToMainMenu once and cache the sub_item_table; subsequent
-- calls reuse the cache so we don't reconstruct hundreds of closures on every
-- menu open (which would be expensive on low-memory e-readers).
-- The cache is cleared by onTeardown via SimpleUIPlugin.buildTabItems = nil.
local _tab_items_cache = nil
SimpleUIPlugin.buildTabItems = function(self)
    if _tab_items_cache then return _tab_items_cache end
    local fake_items = {}
    -- addToMainMenu at this point is the REAL function installed by the
    -- installer (not the bootstrap stub), so this is safe to call directly.
    SimpleUIPlugin.addToMainMenu(self, fake_items)
    local entry = fake_items.simpleui
    _tab_items_cache = entry and entry.sub_item_table or {}
    return _tab_items_cache
end

end -- installer function