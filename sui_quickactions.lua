-- sui_quickactions.lua — Simple UI
-- Single source of truth for Quick Actions:
--   • Action Registry: built-in descriptors + external plugin registrations
--   • Storage: custom QA CRUD, default-action label/icon overrides
--   • Resolution: getEntry(id), isInPlace(id), execute(id, ctx)
--   • Menus: icon picker, rename dialog, create/edit/delete flows
--
-- CONSUMERS:
--   sui_bottombar      — QA.isInPlace(id), QA.execute(id, ctx)
--   module_quick_actions / module_action_list — QA.getEntry, QA.isBuiltin,
--                         QA.iterBuiltin, QA.getCustomQAValid
--   sui_menu           — QA.makeMenuItems, QA.makeIconsMenuItems
--
-- EXTERNAL PLUGIN API:
--   QA.register(descriptor)   — add an action to the registry
--   QA.unregister(id)         — remove an action (call on plugin unload)
--   QA.performResetAllQAIcons(plugin)
--   QA.sui_build_qa_icons(plugin, ctx_menu, ctx)
--
--   descriptor = {
--     id          = "myplugin_action",   -- unique, stable string
--     label       = _("My Action"),      -- base label (user can override)
--     icon        = "/path/to/icon.svg", -- base icon (user can override)
--     -- optional dynamic icon/label (called every render):
--     get_icon    = function(id) ... end,
--     get_label   = function(id) ... end,
--     -- execution:
--     is_in_place = true,  -- bool OR function(id)->bool
--     execute     = function(ctx) ... end,
--     -- ctx = { plugin, fm, show_unavailable }
--     -- optional metadata:
--     browsemeta_mode = nil,  -- "author"|"series"|"tags"
--   }

local UIManager = require("ui/uimanager")
local Device    = require("device")
local Screen    = Device.screen
local lfs       = require("libs/libkoreader-lfs")
local logger    = require("logger")
local _ = require("sui_i18n").translate
local N_ = require("sui_i18n").ngettext

local Config      = require("sui_config")
local SUISettings = require("sui_store")
local ButtonDialog = require("ui/widget/buttondialog")

local QA = {}
-- ---------------------------------------------------------------------------
-- Icon path guard — picker-time validation
-- ---------------------------------------------------------------------------
-- Called in every on_select callback that receives a filesystem path.
-- nil paths (user chose "Default") are always passed through unchanged.
-- Invalid paths show an InfoMessage and call on_invalid() so the caller
-- can reopen the picker or simply do nothing — the bad path is never saved.

local function _guardedSetIcon(path, on_valid, on_invalid)
    -- nil = "reset to default" — always valid, no file to check.
    if path == nil then
        on_valid(nil)
        return
    end
    if Config.isNerdIcon(path) then
        on_valid(path)
        return
    end
    local ok_ss, SUIStyle = pcall(require, "sui_style")
    local safe = ok_ss and SUIStyle and SUIStyle.safeIconPath(path, nil)
    if safe then
        on_valid(safe)
    else
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text    = _("Unsupported icon format.\nPlease use a PNG or SVG file."),
            timeout = 3,
        })
        if on_invalid then on_invalid() end
    end
end

-- ---------------------------------------------------------------------------
-- Icon directory
-- ---------------------------------------------------------------------------

local _icons_dir_cache
function QA.getIconsDir()
    if not _icons_dir_cache then
        local ok_ds, DataStorage = pcall(require, "datastorage")
        if ok_ds and DataStorage then
            _icons_dir_cache = DataStorage:getSettingsDir() .. "/simpleui/sui_icons"
        else
            local _qa_plugin_dir = debug.getinfo(1, "S").source:match("^@(.+/)[^/]+$") or "./"
            _icons_dir_cache = _qa_plugin_dir .. "icons/custom"
        end
    end
    return _icons_dir_cache
end
setmetatable(QA, {
    __index = function(t, k)
        if k == "ICONS_DIR" then
            local dir = QA.getIconsDir()
            rawset(t, "ICONS_DIR", dir)
            return dir
        end
    end,
})

-- ---------------------------------------------------------------------------
-- Action Registry
-- Built-in descriptors are defined here and mirror Config.ALL_ACTIONS.
-- External plugins may call QA.register(descriptor) to add their own.
-- ---------------------------------------------------------------------------

-- The ordered list of built-in action descriptors.
-- Each entry is self-contained: it knows how to execute itself and whether
-- it is in-place, so sui_bottombar needs no action-specific knowledge.
local _builtin_descriptors = {}
local _registry = {}        -- id → descriptor (built-ins + externals)
local _registry_order = {}  -- ordered list of all registered ids

-- Lazy references — loaded on first use to avoid circular requires at boot.
local function _BM()
    return package.loaded["sui_browsemeta"] or require("sui_browsemeta")
end
local function _Bottombar()
    return package.loaded["sui_bottombar"] or require("sui_bottombar")
end

-- showUnavailable helper used inside execute closures.
local function _unavailToast(msg)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = msg, timeout = 3 })
end

-- Helper: resolve the live FileManager instance.
local function _liveFM()
    local FM = package.loaded["apps/filemanager/filemanager"]
    return FM and FM.instance
end

-- _goHome: replicates FileChooser:goHome() used in navigate().
-- Extracted here so the "home" execute closure is self-contained.
local function _goHome(target_fm)
    local fc = target_fm and target_fm.file_chooser
    if not fc then return false end
    local home = G_reader_settings:readSetting("home_dir")
    if not home or lfs.attributes(home, "mode") ~= "directory" then
        home = Device.home_dir
    end
    if not home then return false end
    local ok_fc_mod, FC_mod = pcall(require, "sui_foldercovers")
    local in_virtual = ok_fc_mod and FC_mod.isInSeriesView and FC_mod.isInSeriesView(fc)
    if in_virtual then FC_mod.exitSeriesView(fc) end
    if fc.path == home and not in_virtual then
        target_fm._navbar_suppress_path_change = true
        pcall(function() fc:onGotoPage(1) end)
        target_fm._navbar_suppress_path_change = nil
    else
        target_fm._navbar_suppress_path_change = true
        fc:changeToPath(home)
        target_fm._navbar_suppress_path_change = nil
    end
    if target_fm.updateTitleBarPath then
        pcall(function() target_fm:updateTitleBarPath(home, true) end)
    end
    return true
end

-- Register a descriptor into the registry.
-- Safe to call from within this module (built-ins) or from external plugins.
local function _registerDescriptor(desc)
    if not desc or not desc.id then
        logger.warn("simpleui: QA.register: descriptor missing 'id'")
        return
    end
    local id = desc.id
    if not _registry[id] then
        _registry_order[#_registry_order + 1] = id
    end
    _registry[id] = desc
end

-- Register all built-in actions.
-- Called once at module load time (bottom of this file).
local function _registerBuiltins()
    local function _simpleui_plugin()
        -- Resolve the live plugin instance via the FM first.
        local fm = _liveFM()
        if fm and fm._simpleui_plugin then return fm._simpleui_plugin end
        -- Inside the reader the FM may not be the active instance.
        -- The plugin is registered on ReaderUI as readerui.simpleui.
        local RUI = package.loaded["apps/reader/readerui"]
        local rui = RUI and RUI.instance
        return rui and rui.simpleui
    end

    local builtins = {
        -- ── Navigation actions ──────────────────────────────────────────────
        {
            id    = "home",
            label = _("Library"),
            icon  = Config.ICON.library,
            is_in_place = false,
            execute = function(ctx)
                local fm = ctx.fm or _liveFM()
                if not _goHome(fm) then
                    if fm and fm.file_chooser then
                        UIManager:setDirty(fm, "partial")
                    end
                end
            end,
        },
        {
            id    = "homescreen",
            label = _("Home"),
            icon  = Config.ICON.ko_home,
            is_in_place = false,
            execute = function(ctx)
                local plugin = ctx.plugin or _simpleui_plugin()
                local ok_hs, HS = pcall(require, "sui_homescreen")
                if ok_hs and HS and type(HS.show) == "function" then
                    local saved_page = HS._current_page or 1
                    if ctx.already_active then
                        HS._current_page = 1
                    elseif saved_page <= 1 then
                        HS._current_page = 1
                    end
                    local on_qa_tap = function(aid)
                        if plugin then
                            plugin:_navigate(aid, plugin.ui, Config.loadTabConfig(), false)
                        end
                    end
                    local on_goal_tap = plugin and plugin._goalTapCallback or nil
                      if plugin then
                        local ok_bb, BB = pcall(require, "sui_bottombar")
                        if ok_bb and BB and BB.setActiveAndRefreshFM then
                            local tabs = Config.loadTabConfig()
                            BB.setActiveAndRefreshFM(plugin, "homescreen", tabs)
                        else
                            plugin.active_action = "homescreen"
                        end
                    end
                    HS.show(on_qa_tap, on_goal_tap)
                else
                    local su = ctx.show_unavailable or _unavailToast
                    su(_("Homescreen not available."))
                end
            end,
        },
        {
            id    = "collections",
            label = _("Collections"),
            icon  = Config.ICON.collections,
            is_in_place = false,
            execute = function(ctx)
                local fm = ctx.fm or _liveFM()
                local su = ctx.show_unavailable or _unavailToast
                if fm and fm.collections then fm.collections:onShowCollList()
                else su(_("Collections not available.")) end
            end,
        },
        {
            id    = "history",
            label = _("History"),
            icon  = Config.ICON.history,
            is_in_place = false,
            execute = function(ctx)
                local fm = ctx.fm or _liveFM()
                local su = ctx.show_unavailable or _unavailToast
                local ok = pcall(function() fm.history:onShowHist() end)
                if not ok then su(_("History not available.")) end
            end,
        },
        {
            id    = "continue",
            label = _("Continue"),
            icon  = Config.ICON.continue_,
            is_in_place = false,
            execute = function(ctx)
                local su = ctx.show_unavailable or _unavailToast
                local RH = package.loaded["readhistory"] or require("readhistory")
                local fp = RH and RH.hist and RH.hist[1] and RH.hist[1].file
                if fp then
                    local ReaderUI = package.loaded["apps/reader/readerui"]
                        or require("apps/reader/readerui")
                    ReaderUI:showReader(fp)
                else
                    su(_("No book in history."))
                end
            end,
        },
        {
            id    = "favorites",
            label = _("Favorites"),
            icon  = Config.ICON.ko_star,
            is_in_place = false,
            execute = function(ctx)
                local fm = ctx.fm or _liveFM()
                local su = ctx.show_unavailable or _unavailToast
                if fm and fm.collections then fm.collections:onShowColl()
                else su(_("Favorites not available.")) end
            end,
        },
        -- ── Overlay / dialog actions ────────────────────────────────────────
        {
            id    = "bookmark_browser",
            label = _("Bookmarks"),
            icon  = Config.ICON.ko_bookmark,
            is_in_place = true,
            -- needs_stack_sink = false (opens async widgets, skip the HS sink)
            execute = function(ctx)
                local fm = ctx.fm or _liveFM()
                local _bb_ui = fm
                local ok_rui, ReaderUI = pcall(require, "apps/reader/readerui")
                if ok_rui and ReaderUI and ReaderUI.instance then
                    _bb_ui = ReaderUI.instance
                end
                -- BookmarkBrowser:getBookList() calls self.ui.bookinfo.extendProps()
                -- and self.ui.bookinfo.prop_text[]. When _bb_ui is the FileManager
                -- (no open book), it has no bookinfo field, causing a crash.
                -- Inject the BookInfo module directly so both static accessors work.
                if _bb_ui and not _bb_ui.bookinfo then
                    local ok_bi, BookInfo = pcall(require, "apps/filemanager/filemanagerbookinfo")
                    if ok_bi and BookInfo then
                        _bb_ui.bookinfo = BookInfo
                    end
                end
                _Bottombar().showBookmarkBrowserSourceDialog(_bb_ui)
            end,
        },
        {
            id    = "wifi_toggle",
            label = _("Wi-Fi"),
            icon  = Config.ICON.ko_wifi_on,
            get_icon = function(_id)
                return Config.wifiIcon()
            end,
            get_label = function(_id)
                local a = Config.ACTION_BY_ID["wifi_toggle"]
                return QA.getDefaultActionLabel("wifi_toggle") or (a and a.label)
            end,
            is_in_place = true,
            execute = function(ctx)
                _Bottombar().doWifiToggle(ctx.plugin or _simpleui_plugin())
            end,
        },
        {
            id    = "frontlight",
            label = _("Brightness"),
            icon  = Config.ICON.frontlight,
            is_in_place = true,
            execute = function(_ctx)
                _Bottombar().showFrontlightDialog()
            end,
        },
        {
            id    = "night_mode",
            label = _("Night Mode"),
            icon  = Config.ICON.night,
            is_in_place = true,
            execute = function(_ctx)
                UIManager:broadcastEvent(require("ui/event"):new("ToggleNightMode"))
            end,
        },
        {
            id    = "stats_calendar",
            label = _("Stats"),
            icon  = Config.ICON.stats,
            is_in_place = true,
            execute = function(ctx)
                local su = ctx.show_unavailable or _unavailToast
                local ok, SW = pcall(require, "sui_stats_windows")
                if ok and SW and SW.showReadingInsightsWindow then
                    SW.showReadingInsightsWindow()
                else
                    local ok2, err = pcall(function()
                        UIManager:broadcastEvent(require("ui/event"):new("ShowCalendarView"))
                    end)
                    if not ok2 then su(_("Statistics plugin not available.")) end
                end
            end,
        },
        {
            id    = "power",
            label = _("Power"),
            icon  = Config.ICON.power,
            is_in_place = true,
            execute = function(ctx)
                _Bottombar().showPowerDialog(ctx.plugin or _simpleui_plugin())
            end,
        },
        {
            id    = "sui_settings",
            label = _("Settings"),
            icon  = Config.ICON.ko_settings,
            is_in_place = true,
            execute = function(ctx)
                local SettingsWindow = require("sui_settings_window")
                SettingsWindow:show()
            end,
        },
        -- ── Browse meta actions ─────────────────────────────────────────────
        {
            id    = "browse_authors",
            label = _("Authors"),
            icon  = Config.ICON.author,
            browsemeta_mode = "author",
            is_in_place = false,
            execute = function(ctx)
                local su = ctx.show_unavailable or _unavailToast
                local ok_bm, BM = pcall(_BM)
                if not (ok_bm and BM) then su(_("Browse by Authors/Series/Tags not available.")); return end
                if not BM.isEnabled() then su(_("Enable 'Browse by Author / Series / Tags' in the library menu first.")); return end
                local fm = ctx.fm or _liveFM()
                local fc = fm and fm.file_chooser
                if not fc then return end
                if ctx.already_active then BM.navigateToRoot(fc, fm, "author")
                else BM.navigateTo(fm, "author") end
            end,
        },
        {
            id    = "browse_series",
            label = _("Series"),
            icon  = Config.ICON.series,
            browsemeta_mode = "series",
            is_in_place = false,
            execute = function(ctx)
                local su = ctx.show_unavailable or _unavailToast
                local ok_bm, BM = pcall(_BM)
                if not (ok_bm and BM) then su(_("Browse by Authors/Series/Tags not available.")); return end
                if not BM.isEnabled() then su(_("Enable 'Browse by Author / Series / Tags' in the library menu first.")); return end
                local fm = ctx.fm or _liveFM()
                local fc = fm and fm.file_chooser
                if not fc then return end
                if ctx.already_active then BM.navigateToRoot(fc, fm, "series")
                else BM.navigateTo(fm, "series") end
            end,
        },
        {
            id    = "browse_tags",
            label = _("Tags"),
            icon  = Config.ICON.tags,
            browsemeta_mode = "tags",
            is_in_place = false,
            execute = function(ctx)
                local su = ctx.show_unavailable or _unavailToast
                local ok_bm, BM = pcall(_BM)
                if not (ok_bm and BM) then su(_("Browse by Authors/Series/Tags not available.")); return end
                if not BM.isEnabled() then su(_("Enable 'Browse by Author / Series / Tags' in the library menu first.")); return end
                local fm = ctx.fm or _liveFM()
                local fc = fm and fm.file_chooser
                if not fc then return end
                if ctx.already_active then BM.navigateToRoot(fc, fm, "tags")
                else BM.navigateTo(fm, "tags") end
            end,
        },
    }

    for _, desc in ipairs(builtins) do
        _builtin_descriptors[#_builtin_descriptors + 1] = desc
        _registerDescriptor(desc)
    end
end

-- ---------------------------------------------------------------------------
-- Public registry API
-- ---------------------------------------------------------------------------

-- Register an external action descriptor.
-- Safe to call multiple times with the same id (replaces previous entry).
function QA.register(descriptor)
    if not descriptor or not descriptor.id then
        logger.warn("simpleui: QA.register: descriptor missing 'id'")
        return
    end
    if not descriptor.execute then
        logger.warn("simpleui: QA.register: descriptor missing 'execute' for id=" .. tostring(descriptor.id))
        return
    end
    _registerDescriptor(descriptor)
    logger.dbg("simpleui: QA.register: registered external action", descriptor.id)
end

-- Remove a registered external action.
-- Built-in actions cannot be unregistered.
function QA.unregister(id)
    if not _registry[id] then return end
    -- Prevent removal of built-ins.
    for _, desc in ipairs(_builtin_descriptors) do
        if desc.id == id then
            logger.warn("simpleui: QA.unregister: cannot unregister built-in action", id)
            return
        end
    end
    _registry[id] = nil
    local new_order = {}
    for _, oid in ipairs(_registry_order) do
        if oid ~= id then new_order[#new_order + 1] = oid end
    end
    _registry_order = new_order
    logger.dbg("simpleui: QA.unregister: removed", id)
end

-- Returns true when `id` is a registered built-in action.
function QA.isBuiltin(id)
    if not id then return false end
    for _, desc in ipairs(_builtin_descriptors) do
        if desc.id == id then return true end
    end
    return false
end

-- Returns an ordered iterator over built-in descriptors.
-- Usage: for desc in QA.iterBuiltin() do ... end
function QA.iterBuiltin()
    local i = 0
    return function()
        i = i + 1
        return _builtin_descriptors[i]
    end
end

-- Returns an ordered list of all registered action ids (built-ins + externals).
-- Custom QAs (custom_qa_N) are NOT included — use QA.getCustomQAList() for those.
function QA.allIds()
    return _registry_order
end

-- ---------------------------------------------------------------------------
-- QA.isInPlace(id) — single authority replacing _isInPlaceAction in bottombar
-- ---------------------------------------------------------------------------

function QA.isInPlace(id)
    if not id then return false end
    -- Custom QA: delegate to config.
    if id:match("^custom_qa_%d+$") then
        return QA.isInPlaceCustomQA(id)
    end
    -- Registered built-in or external.
    local desc = _registry[id]
    if not desc then return false end
    local iip = desc.is_in_place
    if type(iip) == "function" then return iip(id) end
    return iip == true
end

-- ---------------------------------------------------------------------------
-- QA.execute(id, ctx) — single authority replacing all if/elseif in bottombar
-- ctx = { plugin, fm, show_unavailable, already_active }
-- ---------------------------------------------------------------------------

function QA.execute(id, ctx)
    ctx = ctx or {}
    local su = ctx.show_unavailable or _unavailToast

    -- Custom QA: delegate to existing executor.
    if id and id:match("^custom_qa_%d+$") then
        QA.executeCustomQA(id, ctx.fm, su)
        return
    end

    local desc = _registry[id]
    if not desc then
        logger.warn("simpleui: QA.execute: unknown action id=" .. tostring(id))
        su(string.format(_("Action not available: %s"), tostring(id)))
        return
    end

    local ok, err = pcall(desc.execute, ctx)
    if not ok then
        logger.warn("simpleui: QA.execute: error in", id, tostring(err))
        su(string.format(_("Action error: %s"), tostring(err)))
    end
end

-- ---------------------------------------------------------------------------
-- Custom Quick Actions persistence (unchanged from original)
-- ---------------------------------------------------------------------------

local _qa_key_cache = {}
local function getQASettingsKey(qa_id)
    local k = _qa_key_cache[qa_id]
    if not k then
        k = "simpleui_qa_" .. qa_id
        _qa_key_cache[qa_id] = k
    end
    return k
end

function QA.getCustomQAList()
    return SUISettings:get("simpleui_qa_list") or {}
end

function QA.saveCustomQAList(list)
    SUISettings:set("simpleui_qa_list", list)
end

function QA.getCustomQAConfig(qa_id)
    local cfg = SUISettings:get(getQASettingsKey(qa_id)) or {}
    return {
        label             = cfg.label or qa_id,
        path              = cfg.path,
        collection        = cfg.collection,
        plugin_key        = cfg.plugin_key,
        plugin_method     = cfg.plugin_method,
        dispatcher_action = cfg.dispatcher_action,
        dispatcher_value  = cfg.dispatcher_value,
        menu_path         = cfg.menu_path,
        icon              = cfg.icon,
    }
end

function QA.saveCustomQAConfig(qa_id, label, path, collection, icon, plugin_key, plugin_method, dispatcher_action, dispatcher_value, menu_path)
    SUISettings:set(getQASettingsKey(qa_id), {
        label             = label,
        path              = path,
        collection        = collection,
        plugin_key        = plugin_key,
        plugin_method     = plugin_method,
        dispatcher_action = dispatcher_action,
        dispatcher_value  = dispatcher_value,
        menu_path         = menu_path,
        icon              = icon,
    })
end

function QA.deleteCustomQA(qa_id)
    SUISettings:del(getQASettingsKey(qa_id))
    _qa_key_cache[qa_id] = nil
    local list = QA.getCustomQAList()
    local new_list = {}
    for _i, id in ipairs(list) do
        if id ~= qa_id then new_list[#new_list + 1] = id end
    end
    QA.saveCustomQAList(new_list)
    local mqa = package.loaded["desktop_modules/module_quick_actions"]
    if mqa and mqa.invalidateCustomQACache then mqa.invalidateCustomQACache() end
    local tabs = SUISettings:get("simpleui_bar_tabs")
    if type(tabs) == "table" then
        local new_tabs = {}
        for _i, id in ipairs(tabs) do
            if id ~= qa_id then new_tabs[#new_tabs + 1] = id end
        end
        SUISettings:set("simpleui_bar_tabs", new_tabs)
    end
    for _i, pfx in ipairs({ "simpleui_hs_qa_" }) do
        for slot = 1, 3 do
            local key = pfx .. slot .. "_items"
            local dqa = SUISettings:get(key)
            if type(dqa) == "table" then
                local new_dqa = {}
                for _i, id in ipairs(dqa) do
                    if id ~= qa_id then new_dqa[#new_dqa + 1] = id end
                end
                SUISettings:set(key, new_dqa)
            end
        end
    end
end

function QA.purgeQACollection(coll_name)
    local list    = QA.getCustomQAList()
    local changed = false
    for _i, qa_id in ipairs(list) do
        local cfg = QA.getCustomQAConfig(qa_id)
        if cfg.collection == coll_name then
            QA.saveCustomQAConfig(qa_id, cfg.label, cfg.path, nil,
                cfg.icon, cfg.plugin_key, cfg.plugin_method, cfg.dispatcher_action)
            changed = true
        end
    end
    return changed
end

function QA.renameQACollection(old_name, new_name)
    local list    = QA.getCustomQAList()
    local changed = false
    for _i, qa_id in ipairs(list) do
        local cfg = QA.getCustomQAConfig(qa_id)
        if cfg.collection == old_name then
            QA.saveCustomQAConfig(qa_id, cfg.label, cfg.path, new_name,
                cfg.icon, cfg.plugin_key, cfg.plugin_method, cfg.dispatcher_action)
            changed = true
        end
    end
    return changed
end

function QA.sanitizeQASlots()
    local Config = require("sui_config")

    local list = QA.getCustomQAList()
    local clean_list = {}
    local list_changed = false
    for _i, id in ipairs(list) do
        if id:match("^custom_qa_%d+$") then
            local cfg = SUISettings:get(getQASettingsKey(id))
            if type(cfg) == "table" and next(cfg) then
                clean_list[#clean_list + 1] = id
            else
                list_changed = true
            end
        else
            list_changed = true
        end
    end
    if list_changed then
        QA.saveCustomQAList(clean_list)
        list = clean_list
    end

    local valid_custom = {}
    for _i, id in ipairs(list) do valid_custom[id] = true end
    local changed = list_changed

    for _, pfx in ipairs({ "simpleui_hs_qa_" }) do
        for slot = 1, 3 do
            local key  = pfx .. slot .. "_items"
            local items = SUISettings:get(key)
            if type(items) == "table" then
                local clean = {}
                local slot_changed = false
                for _i, id in ipairs(items) do
                    if not id:match("^custom_qa_%d+$") or valid_custom[id] then
                        clean[#clean+1] = id
                    else
                        slot_changed = true
                        changed = true
                    end
                end
                if slot_changed then SUISettings:set(key, clean) end
            end
        end
    end

    local tabs = SUISettings:get("simpleui_bar_tabs")
    if type(tabs) == "table" then
        local clean_tabs = {}
        local tabs_changed = false
        for _i, id in ipairs(tabs) do
            if Config.ACTION_BY_ID[id]
                    or (id:match("^custom_qa_%d+$") and valid_custom[id]) then
                clean_tabs[#clean_tabs + 1] = id
            else
                tabs_changed = true
                changed = true
            end
        end
        if tabs_changed then
            SUISettings:set("simpleui_bar_tabs", clean_tabs)
            Config.invalidateTabsCache()
        end
    end

    if changed then
        local mqa = package.loaded["desktop_modules/module_quick_actions"]
        if mqa and mqa.invalidateCustomQACache then mqa.invalidateCustomQACache() end
    end
    return changed
end

function QA.nextCustomQAId()
    local list  = QA.getCustomQAList()
    local max_n = 0
    for _i, id in ipairs(list) do
        local n = tonumber(id:match("^custom_qa_(%d+)$"))
        if n and n > max_n then max_n = n end
    end
    local n = max_n + 1
    while SUISettings:get("simpleui_qa_custom_qa_" .. n) do n = n + 1 end
    return "custom_qa_" .. n
end

function QA.clearQAKeyCache()
    for k in pairs(_qa_key_cache) do _qa_key_cache[k] = nil end
end

-- ---------------------------------------------------------------------------
-- Default-action label / icon overrides
-- ---------------------------------------------------------------------------

local function _defaultLabelKey(id) return "simpleui_action_" .. id .. "_label" end
local function _defaultIconKey(id)  return "simpleui_action_" .. id .. "_icon"  end

function QA.getDefaultActionLabel(id)
    return SUISettings:get(_defaultLabelKey(id))
end

function QA.getDefaultActionIcon(id)
    return SUISettings:get(_defaultIconKey(id))
end

function QA.setDefaultActionLabel(id, label)
    if label and label ~= "" then
        SUISettings:set(_defaultLabelKey(id), label)
    else
        SUISettings:del(_defaultLabelKey(id))
    end
end

function QA.setDefaultActionIcon(id, icon)
    if icon then
        SUISettings:set(_defaultIconKey(id), icon)
    else
        SUISettings:del(_defaultIconKey(id))
    end
end

function QA.performResetAllQAIcons(plugin)
    for _k, a in ipairs(Config.ALL_ACTIONS) do
        SUISettings:del("simpleui_action_" .. a.id .. "_icon")
    end
    SUISettings:del("simpleui_action_wifi_toggle_off_icon")
    for _i, qa_id in ipairs(QA.getCustomQAList()) do
        local cfg = SUISettings:get("simpleui_qa_" .. qa_id)
        if type(cfg) == "table" then
            cfg.icon = nil
            SUISettings:set("simpleui_qa_" .. qa_id, cfg)
        end
    end
    local ok_ss, SUIStyle = pcall(require, "sui_style")
    if ok_ss and SUIStyle then
        for _, s in ipairs(SUIStyle.SLOTS) do
            if s.group == "sui_qa_defaults" then
                SUIStyle.setIcon(s.id, nil)
            end
        end
    end
    QA.invalidateCustomQACache()
    if plugin then plugin:_rebuildAllNavbars() end
    local ok, HS = pcall(require, "sui_homescreen")
    if ok and HS and HS._instance then HS._instance:_refreshImmediate(false) end
end

function QA.sui_show_qa_list(plugin, ctx_menu, ctx)
    local function get_rows()
        local rows = {}
        local qa_list = Config.getCustomQAList()
        local sorted_qa = {}
        for _i, qa_id in ipairs(qa_list) do
            local cfg = Config.getCustomQAConfig(qa_id)
            sorted_qa[#sorted_qa + 1] = { id = qa_id, label = cfg.label or qa_id }
        end
        table.sort(sorted_qa, function(a, b) return a.label:lower() < b.label:lower() end)

        for _i, entry in ipairs(sorted_qa) do
            local _id = entry.id
            local c = Config.getCustomQAConfig(_id)
            local desc
            if c.dispatcher_action and c.dispatcher_action ~= "" then
                desc = "⊕ " .. c.dispatcher_action
            elseif c.plugin_key and c.plugin_key ~= "" then
                desc = "⬡ " .. c.plugin_key .. ":" .. (c.plugin_method or "?")
            elseif c.collection and c.collection ~= "" then
                desc = "⊞ " .. c.collection
            elseif c.menu_path and type(c.menu_path) == "table" then
                desc = "⊚ " .. (c.menu_path.display_label or "Menu Action")
            else
                desc = c.path or ctx_menu._("not configured")
                if #desc > 34 then desc = "…" .. desc:sub(-31) end
            end

            rows[#rows + 1] = {
                text = c.label,
                subtitle = desc,
                on_edit = function()
                    QA.showQuickActionDialog(plugin, _id, function()
                        local ok, HS = pcall(require, "sui_homescreen")
                        if ok and HS and HS._instance then HS._instance:_refreshImmediate(false) end
                        if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end
                        ctx.repaint()
                    end)
                end,
                on_delete = function()
                    local ConfirmBox = require("ui/widget/confirmbox")
                    ctx_menu.UIManager:show(ConfirmBox:new{
                        text        = string.format(ctx_menu._("Delete quick action \"%s\"?"), c.label),
                        ok_text     = ctx_menu._("Delete"),
                        cancel_text = ctx_menu._("Cancel"),
                        ok_callback = function()
                            Config.deleteCustomQA(_id)
                            Config.invalidateTabsCache()
                            QA.invalidateCustomQACache()
                            plugin:_rebuildAllNavbars()
                            local ok, HS = pcall(require, "sui_homescreen")
                            if ok and HS and HS._instance then HS._instance:_refreshImmediate(false) end
                            if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end
                            ctx.repaint()
                        end,
                    })
                end,
                on_tap = function()
                    QA.showQuickActionDialog(plugin, _id, function()
                        local ok, HS = pcall(require, "sui_homescreen")
                        if ok and HS and HS._instance then HS._instance:_refreshImmediate(false) end
                        if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end
                        ctx.repaint()
                    end)
                end,
            }
        end
        return rows
    end

    local MAX_CUSTOM_QA = Config.MAX_CUSTOM_QA

    ctx_menu.show_row_page({
        title = ctx_menu._("Quick Actions"),
        items_func = get_rows,
        empty_text = ctx_menu._("No actions configured"),
        footer_text = ctx_menu._("Create Quick Action"),
        footer_enabled = function() return #Config.getCustomQAList() < MAX_CUSTOM_QA end,
        footer_action = function(ctx2)
            if #Config.getCustomQAList() >= MAX_CUSTOM_QA then
                local InfoMessage = require("ui/widget/infomessage")
                ctx_menu.UIManager:show(InfoMessage:new{
                    text    = string.format(ctx_menu.N_("The maximum of %d quick action has been reached. Delete one first.",
                              "The maximum of %d quick actions has been reached. Delete one first.", MAX_CUSTOM_QA), MAX_CUSTOM_QA),
                    timeout = 2,
                })
                return
            end
            QA.showQuickActionDialog(plugin, nil, function()
                local ok, HS = pcall(require, "sui_homescreen")
                if ok and HS and HS._instance then HS._instance:_refreshImmediate(false) end
                if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end
                if ctx2.jump_to_last_page then ctx2.jump_to_last_page() end
                ctx2.repaint()
            end)
        end
    })
end

function QA.sui_build_qa_icons(plugin, ctx_menu, ctx)
    local Device = require("device")
    local Screen = Device.screen
    local Blitbuffer = require("ffi/blitbuffer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local ImageWidget = require("ui/widget/imagewidget")
    local TextWidget = require("ui/widget/textwidget")
    local Font = require("ui/font")
    local Geom = require("ui/geometry")
    
    local btn_size = Screen:scaleBySize(36)
    local icon_size = math.floor(btn_size * 0.7)
    local ok_ss, SUIStyle = pcall(require, "sui_style")
    local border_sz = ok_ss and SUIStyle.BORDER_SZ or 1
    
    local function makeIconPreview(icon_path, is_nerd, fallback_label)
        local icon_widget
        if is_nerd and icon_path then
            local nerd_char = Config.nerdIconChar(icon_path)
            if nerd_char and ok_ss and SUIStyle then
                icon_widget = TextWidget:new{
                    text    = nerd_char,
                    face    = Font:getFace(SUIStyle.FACE_ICONS, math.floor(icon_size * 0.8)),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    padding = 0,
                }
            end
        elseif icon_path then
            local safe_path = ok_ss and SUIStyle and SUIStyle.safeIconPath(icon_path, nil)
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
        
        if not icon_widget then
            icon_widget = TextWidget:new{
                text    = fallback_label and fallback_label:sub(1, 1):upper() or "?",
                face    = Font:getFace("cfont", math.floor(icon_size * 0.7)),
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
        end
        
        return FrameContainer:new{
            dimen      = Geom:new{ w = btn_size, h = btn_size },
            radius     = Screen:scaleBySize(8),
            bordersize = border_sz,
            background = Blitbuffer.COLOR_WHITE,
            color      = Blitbuffer.gray(0.75),
            padding    = 0,
            [1]        = CenterContainer:new{
                dimen = Geom:new{ w = btn_size - border_sz * 2, h = btn_size - border_sz * 2 },
                [1]   = icon_widget,
            }
        }
    end

    local pool = {}
    for _k, a in ipairs(Config.ALL_ACTIONS) do
        local lbl = QA.getEntry(a.id).label
        if a.id == "wifi_toggle" then
            pool[#pool + 1] = { id = a.id, is_default = true, title = lbl .. "  (" .. _("On") .. ")" }
            pool[#pool + 1] = { id = "wifi_toggle_off", is_default = true, title = lbl .. "  (" .. _("Off") .. ")" }
        else
            pool[#pool + 1] = { id = a.id, is_default = true, title = lbl }
        end
    end
    for _i, qa_id in ipairs(Config.getCustomQAList()) do
        local c = Config.getCustomQAConfig(qa_id)
        pool[#pool + 1] = { id = qa_id, is_default = false, title = c.label or qa_id }
    end
    table.sort(pool, function(a, b) return a.title:lower() < b.title:lower() end)

    local function get_rows()
        local rows = {}
        local defaults = {}
        local customs = {}
        for _, entry in ipairs(pool) do
            if entry.is_default then table.insert(defaults, entry)
            else table.insert(customs, entry) end
        end
        
        local function add_entry(entry)
            local _id         = entry.id
            local _is_default = entry.is_default
            local _title      = entry.title
            
            local current_icon
            if _is_default then
                current_icon = QA.getDefaultActionIcon(_id)
            else
                current_icon = Config.getCustomQAConfig(_id).icon
            end
            
            local has_custom = _is_default
                and QA.getDefaultActionIcon(_id) ~= nil
                or (not _is_default and (function()
                        local c = Config.getCustomQAConfig(_id)
                        return c.icon ~= nil
                            and c.icon ~= Config.CUSTOM_ICON
                            and c.icon ~= Config.CUSTOM_PLUGIN_ICON
                            and c.icon ~= Config.CUSTOM_DISPATCHER_ICON
                    end)())
                    
            local is_nerd = Config.isNerdIcon(current_icon)
            local effective_icon = current_icon
            if not effective_icon then
                if _is_default then
                    if _id == "wifi_toggle_off" then
                        effective_icon = Config.ICON.ko_wifi_off
                    else
                        local a_entry = Config.ACTION_BY_ID[_id]
                        effective_icon = a_entry and a_entry.icon
                    end
                else
                    local c = Config.getCustomQAConfig(_id)
                    if c.dispatcher_action and c.dispatcher_action ~= "" then
                        effective_icon = Config.CUSTOM_DISPATCHER_ICON
                    elseif c.plugin_key and c.plugin_key ~= "" then
                        effective_icon = Config.CUSTOM_PLUGIN_ICON
                    else
                        effective_icon = Config.CUSTOM_ICON
                    end
                end
            end
            
            rows[#rows + 1] = {
                text = _title .. (has_custom and "  \u{270E}" or ""),
                show_chevron = true,
                right_widget = makeIconPreview(effective_icon, is_nerd, _title),
                on_hold = function() end,
                on_tap = function()
                    local default_label = _title .. " (" .. _("default") .. ")"
                    QA.showIconPicker(current_icon, function(new_icon)
                        local function _guardedSetIcon(path, on_valid)
                            if path == nil then on_valid(nil); return end
                            local ok_ss, SUIStyle = pcall(require, "sui_style")
                            local safe = ok_ss and SUIStyle and SUIStyle.safeIconPath(path, nil)
                            if safe then on_valid(safe)
                            else
                                ctx_menu.UIManager:show(ctx_menu.InfoMessage:new{ text = _("Unsupported icon format.\nPlease use a PNG or SVG file."), timeout = 3 })
                            end
                        end
                        
                        if Config.isNerdIcon(new_icon) then
                            if _is_default then
                                QA.setDefaultActionIcon(_id, new_icon)
                            else
                                local c = Config.getCustomQAConfig(_id)
                                Config.saveCustomQAConfig(_id, c.label, c.path, c.collection, new_icon, c.plugin_key, c.plugin_method, c.dispatcher_action)
                            end
                            QA.invalidateCustomQACache()
                            plugin:_rebuildAllNavbars()
                            local ok, HS = pcall(require, "sui_homescreen")
                            if ok and HS and HS._instance then HS._instance:_refreshImmediate(false) end
                            ctx.repaint()
                        else
                            _guardedSetIcon(new_icon, function(safe_icon)
                                if _is_default then
                                    QA.setDefaultActionIcon(_id, safe_icon)
                                else
                                    local c = Config.getCustomQAConfig(_id)
                                    local type_default
                                    if c.dispatcher_action and c.dispatcher_action ~= "" then type_default = Config.CUSTOM_DISPATCHER_ICON
                                    elseif c.plugin_key and c.plugin_key ~= "" then type_default = Config.CUSTOM_PLUGIN_ICON
                                    else type_default = Config.CUSTOM_ICON end
                                    Config.saveCustomQAConfig(_id, c.label, c.path, c.collection, safe_icon or type_default, c.plugin_key, c.plugin_method, c.dispatcher_action)
                                end
                                QA.invalidateCustomQACache()
                                plugin:_rebuildAllNavbars()
                                local ok, HS = pcall(require, "sui_homescreen")
                                if ok and HS and HS._instance then HS._instance:_refreshImmediate(false) end
                                ctx.repaint()
                            end)
                        end
                    end, default_label, plugin, "_qa_icon_picker_style", true)
                end,
            }
        end

        if #defaults > 0 then
            rows[#rows + 1] = {
                text = _("System Actions"):upper(),
                is_divider = true,
                sui_build = function(ctx)
                    return require("sui_window").SectionLabel{ text = _("System Actions"):upper(), inner_w = ctx.inner_w }
                end
            }
            for _, entry in ipairs(defaults) do add_entry(entry) end
        end
        if #customs > 0 then
            rows[#rows + 1] = {
                text = _("Custom Actions"):upper(),
                is_divider = true,
                sui_build = function(ctx)
                    return require("sui_window").SectionLabel{ text = _("Custom Actions"):upper(), inner_w = ctx.inner_w }
                end
            }
            for _, entry in ipairs(customs) do add_entry(entry) end
        end
        return rows
    end

    ctx_menu.show_row_page({
        title = _("Quick Actions Icons"),
        items_func = get_rows,
        footer_text = _("Reset All"),
        footer_icon = "update",
        footer_action = function(ctx2)
            local ConfirmBox = require("ui/widget/confirmbox")
            ctx_menu.UIManager:show(ConfirmBox:new{
                text = _("Reset all Quick Actions icons to default?"),
                ok_text = _("Reset"),
                cancel_text = _("Cancel"),
                ok_callback = function()
                    QA.performResetAllQAIcons(plugin)
                    ctx2.repaint()
                end,
            })
        end
    })
end

-- ---------------------------------------------------------------------------
-- getEntry(id) — canonical resolver used by ALL rendering code
-- ---------------------------------------------------------------------------

local _wifi_entry = { icon = "", label = "" }

function QA.getEntry(id)
    -- Custom QA
    if id and id:match("^custom_qa_%d+$") then
        local cfg = SUISettings:get("simpleui_qa_" .. id) or {}
        local default_icon
        local ok_ss, SUIStyle = pcall(require, "sui_style")
        if cfg.dispatcher_action and cfg.dispatcher_action ~= "" then
            default_icon = (ok_ss and SUIStyle and SUIStyle.getIcon("sui_qa_system")) or Config.CUSTOM_DISPATCHER_ICON
        elseif cfg.plugin_key and cfg.plugin_key ~= "" then
            default_icon = (ok_ss and SUIStyle and SUIStyle.getIcon("sui_qa_plugin")) or Config.CUSTOM_PLUGIN_ICON
        else
            default_icon = (ok_ss and SUIStyle and SUIStyle.getIcon("sui_qa_folder")) or Config.CUSTOM_ICON
        end

        local icon = cfg.icon or default_icon
        if cfg.icon == Config.CUSTOM_ICON or cfg.icon == Config.CUSTOM_PLUGIN_ICON or cfg.icon == Config.CUSTOM_DISPATCHER_ICON then
            icon = default_icon
        end

        return {
            icon  = icon,
            label = cfg.label or id,
        }
    end

    -- Registered action: check for dynamic get_icon / get_label first.
    local desc = _registry[id]
    if not desc then
        -- Try Config.ACTION_BY_ID for backwards compatibility with external
        -- code that still calls getEntry() for actions not yet registered.
        local a = Config.ACTION_BY_ID[id]
        if not a then
            logger.warn("simpleui: QA.getEntry: unknown id " .. tostring(id))
            return { icon = Config.ICON.library, label = tostring(id) }
        end
        desc = a
    end

    -- Dynamic icon/label (e.g. wifi_toggle).
    local has_dynamic = desc.get_icon or desc.get_label
    local icon_ov  = QA.getDefaultActionIcon(id)
    local label_ov = QA.getDefaultActionLabel(id)

    if id == "wifi_toggle" then
        _wifi_entry.icon  = (desc.get_icon and desc.get_icon(id)) or desc.icon
        _wifi_entry.label = label_ov or (desc.get_label and desc.get_label(id)) or desc.label
        return _wifi_entry
    end

    if not icon_ov and not label_ov and not has_dynamic then
        return desc  -- fast path: no overrides, no dynamic fields
    end
    return {
        icon  = icon_ov or (desc.get_icon and desc.get_icon(id)) or desc.icon,
        label = label_ov or (desc.get_label and desc.get_label(id)) or desc.label,
    }
end

-- ---------------------------------------------------------------------------
-- Custom QA validity cache
-- ---------------------------------------------------------------------------

local _cqa_valid_cache = nil

function QA.getCustomQAValid()
    if not _cqa_valid_cache then
        local list = Config.getCustomQAList()
        local s = {}
        for _, id in ipairs(list) do s[id] = true end
        _cqa_valid_cache = s
    end
    return _cqa_valid_cache
end

function QA.invalidateCustomQACache()
    _cqa_valid_cache = nil
end

-- ---------------------------------------------------------------------------
-- Icon picker
-- ---------------------------------------------------------------------------

local function _loadCustomIconList()
    local icons = {}
    local attr  = lfs.attributes(QA.ICONS_DIR)
    if not attr or attr.mode ~= "directory" then return icons end
    for fname in lfs.dir(QA.ICONS_DIR) do
        if fname:match("%.[Ss][Vv][Gg]$") or fname:match("%.[Pp][Nn][Gg]$") then
            local path  = QA.ICONS_DIR .. "/" .. fname
            local label = (fname:match("^(.+)%.[^%.]+$") or fname):gsub("_", " ")
            icons[#icons + 1] = { path = path, label = label }
        end
    end
    table.sort(icons, function(a, b) return a.label:lower() < b.label:lower() end)
    return icons
end

local function _showNerdIconPreview(sentinel, on_confirm, on_back)
    local ConfirmBox = require("ui/widget/confirmbox")
    local nerd_char  = Config.nerdIconChar(sentinel)
    local hex        = sentinel:match("nerd:(.+)")
    UIManager:show(ConfirmBox:new{
        text        = ("U+%s  %s"):format(hex, nerd_char) .. "\n\n" ..
                      _("Use this Nerd Font icon?"),
        ok_text     = _("Confirm"),
        cancel_text = _("Cancel"),
        ok_callback = function() on_confirm(sentinel) end,
        cancel_callback = function() if on_back then on_back() end end,
    })
end

local function _showNerdIconInput(current_icon, on_select, on_cancel)
    local InputDialog = require("ui/widget/inputdialog")
    local InfoMessage = require("ui/widget/infomessage")
    local current_hex = ""
    if current_icon then
        current_hex = current_icon:match("^nerd:([0-9A-Fa-f]+)$") or ""
    end
    local dlg
    local function _openInputDlg()
        dlg = InputDialog:new{
            title       = _("Nerd Font Icon"),
            input       = current_hex:upper(),
            input_hint  = _("hex code, e.g. E001"),
            description = _("Enter the Unicode codepoint (hex) of a Nerd Fonts symbol.\nYou can look up codes with wakamaifondue.com using the file:\n  /koreader/fonts/nerdfonts/symbols.ttf\nLeave blank and press OK to remove a Nerd Font icon."),
            buttons = {{
                {
                    text     = _("Cancel"),
                    callback = function()
                        UIManager:close(dlg)
                        if on_cancel then on_cancel() end
                    end,
                },
                {
                    text             = _("OK"),
                    is_enter_default = true,
                    callback         = function()
                        local raw = dlg:getInputText()
                        if raw:match("^%s*$") then
                            UIManager:close(dlg)
                            on_select(nil)
                            return
                        end
                        local hex = raw:match("^%s*([0-9A-Fa-f]+)%s*$")
                        if hex and #hex >= 1 and #hex <= 6 then
                            local sentinel = "nerd:" .. hex:upper()
                            if Config.nerdIconChar(sentinel) then
                                UIManager:close(dlg)
                                _showNerdIconPreview(sentinel,
                                    on_select,
                                    function() UIManager:nextTick(_openInputDlg) end)
                            else
                                UIManager:show(InfoMessage:new{
                                    text    = _("Codepoint out of valid Unicode range (0–10FFFF)."),
                                    timeout = 3,
                                })
                            end
                        else
                            UIManager:show(InfoMessage:new{
                                text    = _("Invalid input. Please enter 1–6 hexadecimal digits (0–9, A–F)."),
                                timeout = 3,
                            })
                        end
                    end,
                },
            }},
        }
        UIManager:show(dlg)
    end
    _openInputDlg()
end

function QA.showIconPicker(current_icon, on_select, default_label, _picker_handle, picker_key, allow_nerd, on_cancel)
    _picker_handle = _picker_handle or QA
    picker_key     = picker_key     or "_icon_picker"
    local ButtonDialog = require("ui/widget/buttondialog")
    local icons   = _loadCustomIconList()
    local buttons = {}
    local is_nerd    = Config.isNerdIcon(current_icon)
    local is_svg     = current_icon and not is_nerd
    local default_marker = (not current_icon) and "  ✓" or ""
    buttons[#buttons + 1] = {{
        text     = (default_label or _("Default")) .. default_marker,
        callback = function()
            UIManager:close(_picker_handle[picker_key])
            on_select(nil)
        end,
    }}
    if allow_nerd then
        local nerd_char   = Config.nerdIconChar(current_icon)
        local nerd_marker = is_nerd and ("  " .. nerd_char .. "  ✓") or ""
        buttons[#buttons + 1] = {{
            text     = _("Nerd Font symbol…") .. nerd_marker,
            callback = function()
                UIManager:close(_picker_handle[picker_key])
                _showNerdIconInput(current_icon, function(new_icon)
                    on_select(new_icon)
                end, function()
                    QA.showIconPicker(current_icon, on_select, default_label, _picker_handle, picker_key, allow_nerd, on_cancel)
                end)
            end,
        }}
    end

    -- ==========================================================================
    -- Browse files button — opens sui_icon_browser to pick icons from filesystem
    -- ==========================================================================
    buttons[#buttons + 1] = {{
        text = _("Browse files…"),
        callback = function()
            UIManager:close(_picker_handle[picker_key])
            local IconBrowser = require("sui_icon_browser")
            local DataStorage = require("datastorage")
            UIManager:show(IconBrowser:new{
                path = DataStorage:getDataDir() .. "/icons/",
                onConfirm = function(file_path)
                    on_select(file_path)
                end,
            })
        end,
    }}

    if #icons == 0 then
        buttons[#buttons + 1] = {{
            text    = _("No icons found in:") .. "\n" .. QA.ICONS_DIR,
            enabled = false,
        }}
    else
        for _i, icon in ipairs(icons) do
            local p = icon
            buttons[#buttons + 1] = {{
                text     = p.label .. ((is_svg and current_icon == p.path) and "  ✓" or ""),
                callback = function()
                    UIManager:close(_picker_handle[picker_key])
                    on_select(p.path)
                end,
            }}
        end
    end
    buttons[#buttons + 1] = {{
        text     = _("Cancel"),
        callback = function()
            UIManager:close(_picker_handle[picker_key])
            if on_cancel then on_cancel() end
        end,
    }}
    _picker_handle[picker_key] = ButtonDialog:new{ buttons = buttons }
    UIManager:show(_picker_handle[picker_key])
end

-- ---------------------------------------------------------------------------
-- Plugin scanner helpers (used by showQuickActionDialog)
-- ---------------------------------------------------------------------------

local function _scanFMPlugins()
    local fm = package.loaded["apps/filemanager/filemanager"]
    fm = fm and fm.instance
    if not fm then return {} end
    local known = {
        { key = "history",          method = "onShowHist",                      title = _("History")           },
        { key = "bookinfo",         method = "onShowBookInfo",                  title = _("Book Info")         },
        { key = "collections",      method = "onShowColl",                      title = _("Favorites")         },
        { key = "collections",      method = "onShowCollList",                  title = _("Collections")       },
        { key = "filesearcher",     method = "onShowFileSearch",                title = _("File Search")       },
        { key = "folder_shortcuts", method = "onShowFolderShortcutsDialog",     title = _("Folder Shortcuts")  },
        { key = "dictionary",       method = "onShowDictionaryLookup",          title = _("Dictionary Lookup") },
        { key = "wikipedia",        method = "onShowWikipediaLookup",           title = _("Wikipedia Lookup")  },
    }
    local results = {}
    for _, entry in ipairs(known) do
        local mod = fm[entry.key]
        if mod and type(mod[entry.method]) == "function" then
            results[#results + 1] = { fm_key = entry.key, fm_method = entry.method, title = entry.title }
        end
    end
    local native_keys = {
        screenshot=true, menu=true, history=true, bookinfo=true, collections=true,
        filesearcher=true, folder_shortcuts=true, languagesupport=true,
        dictionary=true, wikipedia=true, devicestatus=true, devicelistener=true,
        networklistener=true,
    }
    local our_name  = "simpleui"
    local seen_keys = {}
    local fm_val_to_key = {}
    for k, v in pairs(fm) do
        if type(k) == "string" and type(v) == "table" then fm_val_to_key[v] = k end
    end
    for i = 1, #fm do
        local val = fm[i]
        if type(val) ~= "table" or type(val.name) ~= "string" then goto cont end
        local fm_key = fm_val_to_key[val]
        if not fm_key or native_keys[fm_key] or seen_keys[fm_key] or fm_key == our_name then goto cont end
        if type(val.addToMainMenu) ~= "function" then goto cont end
        seen_keys[fm_key] = true
        local method = nil
        for _, pfx in ipairs({"onShow","show","open","launch","onOpen"}) do
            if type(val[pfx]) == "function" then method = pfx; break end
        end
        if not method then
            local cap = "on" .. fm_key:sub(1,1):upper() .. fm_key:sub(2)
            if type(val[cap]) == "function" then method = cap end
        end
        if not method then
            local probe = {}
            local ok = pcall(function() val:addToMainMenu(probe) end)
            if ok then
                local entry = probe[fm_key] or probe[val.name]
                if entry and type(entry.callback) == "function" then
                    local cb = entry.callback
                    val._sui_launch = function(_self) cb() end
                    method = "_sui_launch"
                end
            end
        end
        if method then
            local raw     = (val.name or fm_key):gsub("^filemanager", "")
            local display = raw:sub(1,1):upper() .. raw:sub(2)
            local probe2 = {}
            local ok2 = pcall(function() val:addToMainMenu(probe2) end)
            if ok2 then
                local entry2 = probe2[fm_key] or probe2[val.name]
                if entry2 and type(entry2.text) == "string" and entry2.text ~= "" then
                    display = entry2.text
                end
            end
            results[#results + 1] = { fm_key = fm_key, fm_method = method, title = display }
        end
        ::cont::
    end
    table.sort(results, function(a, b) return a.title < b.title end)
    return results
end

local function _scanDispatcherActions()
    local ok_d, Dispatcher = pcall(require, "dispatcher")
    if not ok_d or not Dispatcher then return {} end
    pcall(function() Dispatcher:init() end)
    local settingsList, dispatcher_menu_order
    pcall(function()
        local fn_idx = 1
        while true do
            local name, val = debug.getupvalue(Dispatcher.registerAction, fn_idx)
            if not name then break end
            if name == "settingsList"          then settingsList          = val end
            if name == "dispatcher_menu_order" then dispatcher_menu_order = val end
            fn_idx = fn_idx + 1
        end
    end)
    if type(settingsList) ~= "table" then return {} end
    local order = (type(dispatcher_menu_order) == "table" and dispatcher_menu_order)
        or (function()
            local t = {}
            for k in pairs(settingsList) do t[#t+1] = k end
            table.sort(t)
            return t
        end)()
    local results = {}
    for _i, action_id in ipairs(order) do
        local def = settingsList[action_id]
        if type(def) == "table" and def.title and def.category == "none"
                and (def.condition == nil or def.condition == true) then
            results[#results + 1] = { id = action_id, title = tostring(def.title) }
        end
    end
    table.sort(results, function(a, b) return a.title < b.title end)
    return results
end

-- ---------------------------------------------------------------------------
-- Create / Edit dialog
-- ---------------------------------------------------------------------------

function QA.showQuickActionDialog(plugin, qa_id, on_done)
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local InfoMessage      = require("ui/widget/infomessage")
    local ButtonDialog     = require("ui/widget/buttondialog")

    local getNonFavColl    = Config.getNonFavoritesCollections
    local collections      = getNonFavColl and getNonFavColl() or {}
    table.sort(collections, function(a, b) return a:lower() < b:lower() end)

    local cfg         = qa_id and Config.getCustomQAConfig(qa_id) or {}
    local start_path  = cfg.path or G_reader_settings:readSetting("home_dir") or "/"
    local chosen_icon = cfg.icon
    local dlg_title   = qa_id and _("Edit Quick Action") or _("New Quick Action")
    local TOTAL_H     = require("sui_bottombar").TOTAL_H

    local current_action_type = nil
    local current_action_val1 = nil
    local current_action_val2 = nil
    local current_action_title = nil
    
    if cfg.dispatcher_action and cfg.dispatcher_action ~= "" then
        current_action_type = "dispatcher"
        current_action_val1 = cfg.dispatcher_action
        current_action_title = cfg.dispatcher_action
    elseif cfg.plugin_key and cfg.plugin_key ~= "" then
        current_action_type = "plugin"
        current_action_val1 = cfg.plugin_key
        current_action_val2 = cfg.plugin_method
        current_action_title = cfg.plugin_key
    elseif cfg.collection and cfg.collection ~= "" then
        current_action_type = "collection"
        current_action_val1 = cfg.collection
        current_action_title = cfg.collection
    elseif cfg.path and cfg.path ~= "" then
        current_action_type = "path"
        current_action_val1 = cfg.path
        current_action_title = cfg.path:match("([^/]+)$") or cfg.path
    elseif cfg.menu_path and type(cfg.menu_path) == "table" then
        current_action_type = "menu"
        current_action_val1 = cfg.menu_path
        current_action_title = cfg.menu_path.display_label or "Menu Action"
    end

    local function iconButtonLabel(default_lbl)
        if not chosen_icon then return default_lbl or _("Icon: Default") end
        local nerd_char = Config.nerdIconChar(chosen_icon)
        if nerd_char then
            local hex = chosen_icon:match("nerd:(.+)")
            return _("Icon") .. ": " .. nerd_char .. " (" .. hex .. ")"
        end
        local fname = chosen_icon:match("([^/]+)$") or chosen_icon
        local stem  = (fname:match("^(.+)%.[^%.]+$") or fname):gsub("_", " ")
        return _("Icon") .. ": " .. stem
    end

    local function commitQA(final_label, path, coll, default_icon, fm_key, fm_method, dispatcher_action, dispatcher_value, menu_path)
        local final_id = qa_id or Config.nextCustomQAId()
        if not qa_id then
            local list = Config.getCustomQAList()
            list[#list + 1] = final_id
            Config.saveCustomQAList(list)
        end
        Config.saveCustomQAConfig(final_id, final_label, path, coll,
            chosen_icon or default_icon, fm_key, fm_method, dispatcher_action, dispatcher_value, menu_path)
        QA.invalidateCustomQACache()
        plugin:_rebuildAllNavbars()
        if on_done then on_done() end
    end

    local active_dialog = nil
    local openActionPicker

    local function cancelActionPicker()
        if not current_action_type and not qa_id then
            if on_done then on_done() end
        else
          if active_dialog then
             UIManager:close(active_dialog)
             active_dialog = nil
           end
           if _buildSaveDialog then
               _buildSaveDialog(false)
           elseif on_done then
               on_done()
           end
        end
    end

    local function _buildSaveDialog(update_name_with_title)
        if active_dialog then UIManager:close(active_dialog); active_dialog = nil end

        local default_lbl = _("Default")
        if current_action_type == "path" or current_action_type == "collection" then default_lbl = _("Default (Folder)")
        elseif current_action_type == "plugin" then default_lbl = _("Default (Plugin)")
        elseif current_action_type == "dispatcher" then default_lbl = _("Default (System)")
        end

        local function openIconPicker()
            if active_dialog then
                local inputs = active_dialog:getFields()
                if inputs and inputs[1] then cfg.label = inputs[1] end
                UIManager:close(active_dialog)
                active_dialog = nil
            end
            
            QA.showIconPicker(chosen_icon, function(new_icon)
                chosen_icon = new_icon
                _buildSaveDialog(false)
            end, default_lbl, plugin, "_qa_icon_picker", true, function()
                -- Quando cancela o picker de ícone, volta às propriedades
                _buildSaveDialog(false)
            end)
        end

        local action_label = _("Action") .. ": "
        local icon_default = Config.CUSTOM_ICON
        if current_action_type == "path" or current_action_type == "collection" then
            action_label = action_label .. (current_action_title or "")
            icon_default = Config.CUSTOM_ICON
        elseif current_action_type == "plugin" then
            action_label = action_label .. (current_action_title or "")
            icon_default = Config.CUSTOM_PLUGIN_ICON
        elseif current_action_type == "dispatcher" then
            action_label = action_label .. (current_action_title or "")
            icon_default = Config.CUSTOM_DISPATCHER_ICON
        elseif current_action_type == "menu" then
            action_label = action_label .. (current_action_title or "")
            icon_default = Config.CUSTOM_ICON
        else
            action_label = action_label .. _("None")
        end
        
        if update_name_with_title and current_action_title then
            cfg.label = current_action_title
        end

        local fields = { { description = _("Name"), text = cfg.label or current_action_title or "", hint = _("Action name…") } }

        active_dialog = MultiInputDialog:new{
            title  = dlg_title,
            fields = fields,
            buttons = {
                { { text = action_label, callback = function()
                    if active_dialog then
                        local inputs = active_dialog:getFields()
                        if inputs and inputs[1] then cfg.label = inputs[1] end
                    end
                    openActionPicker() 
                end } },
                { { text = iconButtonLabel(default_lbl),
                    callback = function() openIconPicker() end } },
                { { text = _("Cancel"),
                    callback = function() UIManager:close(active_dialog); active_dialog = nil end },
                  { text = _("Save"), is_enter_default = true,
                    callback = function()
                        if not current_action_type then
                            UIManager:show(InfoMessage:new{ text = _("Please select an action."), timeout = 3 })
                            return
                        end
                        local inputs = active_dialog:getFields()
                        local final_label = Config.sanitizeLabel(inputs[1]) or current_action_title or _("Action")
                        
                        UIManager:close(active_dialog); active_dialog = nil
                        
                        local p_path, p_coll, p_pk, p_pm, p_da, p_dv, p_mp
                        if current_action_type == "path" then p_path = current_action_val1
                        elseif current_action_type == "collection" then p_coll = current_action_val1
                        elseif current_action_type == "plugin" then p_pk = current_action_val1; p_pm = current_action_val2
                        elseif current_action_type == "dispatcher" then p_da = current_action_val1; p_dv = current_action_val2
                        elseif current_action_type == "menu" then p_mp = current_action_val1
                        end
                        
                        commitQA(final_label, p_path, p_coll, chosen_icon or icon_default, p_pk, p_pm, p_da, p_dv, p_mp)
                    end } },
            },
        }
        UIManager:show(active_dialog)
        pcall(function() active_dialog:onShowKeyboard() end)
    end

    local sanitize = Config.sanitizeLabel

    local function openFolderPicker()
        local ok_pc, PathChooser = pcall(require, "ui/widget/pathchooser")
        if not ok_pc or not PathChooser then
            UIManager:show(InfoMessage:new{ text = _("Path chooser not available."), timeout = 3 })
            if active_dialog then UIManager:show(active_dialog) else cancelActionPicker() end
            return
        end
        local pc = PathChooser:new{
            select_directory = true,
            select_file      = false,
            show_files       = false,
            path             = start_path,
            onConfirm        = function(chosen_path)
                chosen_path = chosen_path:gsub("/$", "")
                current_action_type = "path"
                current_action_val1 = chosen_path
                current_action_title = chosen_path:match("([^/]+)$") or chosen_path
                UIManager:scheduleIn(0.3, function()
                    _buildSaveDialog(true)
                end)
            end,
            onCancel = function()
                UIManager:scheduleIn(0.3, function() cancelActionPicker() end)
            end,
        }
        UIManager:show(pc)
    end

    local function openCollectionPicker()
        local buttons = {}
        for _i, coll_name in ipairs(collections) do
            local name = coll_name
            buttons[#buttons + 1] = {{ text = name, callback = function()
                UIManager:close(plugin._qa_coll_picker)
                current_action_type = "collection"
                current_action_val1 = name
                current_action_title = name
                _buildSaveDialog(true)
            end }}
        end
        buttons[#buttons + 1] = {{ text = _("Cancel"),
            callback = function() UIManager:close(plugin._qa_coll_picker); cancelActionPicker() end }}
        plugin._qa_coll_picker = ButtonDialog:new{ title = _("Collection"), title_align = "center", buttons = buttons }
        UIManager:show(plugin._qa_coll_picker)
    end

    local function openPluginPicker()
        local plugin_actions = _scanFMPlugins()
        if #plugin_actions == 0 then
            UIManager:show(InfoMessage:new{ text = _("No plugins found."), timeout = 3 })
            cancelActionPicker()
            return
        end
        local buttons = {}
        table.sort(plugin_actions, function(a, b) return a.title:lower() < b.title:lower() end)
        for _i, a in ipairs(plugin_actions) do
            local _a = a
            buttons[#buttons + 1] = {{ text = _a.title, callback = function()
                UIManager:close(plugin._qa_plugin_picker)
                current_action_type = "plugin"
                current_action_val1 = _a.fm_key
                current_action_val2 = _a.fm_method
                current_action_title = _a.title
                _buildSaveDialog(true)
            end }}
        end
        buttons[#buttons + 1] = {{ text = _("Cancel"),
            callback = function() UIManager:close(plugin._qa_plugin_picker); cancelActionPicker() end }}
        plugin._qa_plugin_picker = ButtonDialog:new{ title = _("Plugin"), title_align = "center", buttons = buttons }
        UIManager:show(plugin._qa_plugin_picker)
    end

    local function openDispatcherPicker()
        local Dispatcher = require("dispatcher")
        Dispatcher:init()
        
        -- Get settingsList upvalue
        local settingsList, dispatcher_menu_order
        local fn_idx = 1
        while true do
            local name, val = debug.getupvalue(Dispatcher.registerAction, fn_idx)
            if not name then break end
            if name == "settingsList" then settingsList = val end
            if name == "dispatcher_menu_order" then dispatcher_menu_order = val end
            fn_idx = fn_idx + 1
        end
        
        if type(settingsList) ~= "table" then
            UIManager:show(InfoMessage:new{ text = _("No system actions found."), timeout = 3 })
            cancelActionPicker()
            return
        end
        local order = (type(dispatcher_menu_order) == "table" and dispatcher_menu_order)
            or (function()
                local keys = {}
                for key in pairs(settingsList) do keys[#keys + 1] = key end
                table.sort(keys)
                return keys
            end)()
        
        -- Define categories for grouping
        local sections = {
            { key = "general",     title = _("General") },
            { key = "device",      title = _("Device") },
            { key = "screen",      title = _("Screen and lights") },
            { key = "filemanager", title = _("File browser") },
            { key = "reader",      title = _("Reader") },
            { key = "rolling",     title = _("Reflowable documents (epub, fb2, txt…)") },
            { key = "paging",      title = _("Fixed layout documents (pdf, djvu, pics…)") },
        }
        
        -- Collect actions by category
        local sections_map = {}
        for _, sec in ipairs(sections) do
            sections_map[sec.key] = { title = sec.title, items = {} }
        end
        
        for _, action_id in ipairs(order) do
            local def = settingsList[action_id]
            if type(def) == "table" and def.title and def.category
                    and (def.condition == nil or def.condition == true) then
                -- Determine section
                local section_key = "general"
                for _, sec in ipairs(sections) do
                    if def[sec.key] == true then
                        section_key = sec.key
                        break
                    end
                end
                table.insert(sections_map[section_key].items, {
                    id = action_id,
                    title = tostring(def.title),
                    category = def.category,
                    def = def,
                })
            end
        end
        
        -- Handle action selection based on category
        local function handleAction(action)
            local category = action.category
            local action_id = action.id
            local action_title = action.title
            local def = action.def
            
            if category == "none" or category == "arg" then
                -- Direct action with no arguments or simple argument
                current_action_type = "dispatcher"
                current_action_val1 = action_id
                current_action_val2 = true
                current_action_title = action_title
                _buildSaveDialog(true)
             elseif category == "absolutenumber" or category == "incrementalnumber" then
                -- Numeric action: show SpinWidget to select value
                local SpinWidget = require("ui/widget/spinwidget")
                local spin = SpinWidget:new{
                    title_text = action_title,
                    value = def.default or def.min or 0,
                    value_min = def.min or 0,
                    value_max = def.max or 100,
                    value_step = def.step or 1,
                    unit = def.unit,
                    callback = function(spin)
                        local value = spin.value
                        current_action_type = "dispatcher"
                        current_action_val1 = action_id
                        current_action_val2 = value
                        current_action_title = action_title .. ": " .. tostring(value)
                        _buildSaveDialog(true)
                    end,
                }
                UIManager:show(spin)
            elseif category == "string" or category == "configurable" then
                -- Parameterized action: show submenu with available options
                local sub_items = {}
                local args = def.args
                local toggle = def.toggle
                if def.args_func then
                    local ok, a, t = pcall(def.args_func)
                    if ok then
                        args = a
                        toggle = t
                    end
                end
                
                if args and #args > 0 then
                    for i, value in ipairs(args) do
                        local display = toggle and toggle[i] or tostring(value)
                        table.insert(sub_items, {{
                            text = display,
                            callback = function()
                                current_action_type = "dispatcher"
                                current_action_val1 = action_id
                                current_action_val2 = value
                                current_action_title = display
                                _buildSaveDialog(true)
                            end,
                        }})
                    end
                end
                
                if #sub_items > 0 then
                    local sub_dialog = ButtonDialog:new{
                        title = action_title,
                        title_align = "center",
                        buttons = sub_items,
                        width = math.floor(Screen:getWidth() * 0.7),
                    }
                    UIManager:show(sub_dialog)
                else
                    UIManager:show(InfoMessage:new{
                        text = _("No options available for this action."),
                        timeout = 2,
                    })
                end
            end
        end
        -- Build category buttons
        local buttons = {}
        for _, sec in ipairs(sections) do
            local items = sections_map[sec.key].items
            if #items > 0 then
                table.sort(items, function(a, b) return a.title:lower() < b.title:lower() end)
                local sub_buttons = {}
                for _, action in ipairs(items) do
                    sub_buttons[#sub_buttons + 1] = {{
                        text = action.title,
                        callback = function()
                            handleAction(action)
                        end,
                    }}
                end
                buttons[#buttons + 1] = {{
                    text = sec.title,
                    callback = function()
                        local sub_dialog = ButtonDialog:new{
                            title = sec.title,
                            title_align = "center",
                            buttons = sub_buttons,
                            width = math.floor(Screen:getWidth() * 0.7),
                        }
                        UIManager:show(sub_dialog)
                    end,
                }}
            end
        end
        
        if #buttons == 0 then
            UIManager:show(InfoMessage:new{ text = _("No system actions found."), timeout = 3 })
            cancelActionPicker()
            return
        end
        
        local picker = ButtonDialog:new{
            title = _("System Actions"),
            title_align = "center",
            buttons = buttons,
            width = math.floor(Screen:getWidth() * 0.7),
        }
        UIManager:show(picker)
    end
    -- ==========================================================================
    -- openMenuPicker — record a menu navigation path
    -- ==========================================================================
    local function openMenuPicker()
        local FM = package.loaded["apps/filemanager/filemanager"]
        local fm = FM and FM.instance
        local RUI = package.loaded["apps/reader/readerui"]
        
        local target_menu = nil
        local view = "reader"
        
        -- Try to get ReaderUI menu first
        if RUI and RUI.instance and RUI.instance.menu then
            if not RUI.instance.menu.menu_container or not RUI.instance.menu.menu_container[1] then
                RUI.instance.menu:onShowMenu()
            end
            target_menu = RUI.instance.menu.menu_container and RUI.instance.menu.menu_container[1]
            view = "reader"
        elseif fm and fm.menu then
            -- Fall back to FileManager menu
            if not fm.menu.menu_container or not fm.menu.menu_container[1] then
                fm.menu:onShowMenu()
            end
            target_menu = fm.menu.menu_container and fm.menu.menu_container[1]
            view = "fb"
        else
            UIManager:show(InfoMessage:new{
                text = _("Open a book or go to file browser first."),
                timeout = 3,
            })
            cancelActionPicker()
            return
        end
        
        if not target_menu then
            UIManager:show(InfoMessage:new{
                text = _("Could not open menu."),
                timeout = 3,
            })
            cancelActionPicker()
            return
        end
        
        local ok, MenuPicker = pcall(require, "sui_menu_picker")
        if not ok then
            UIManager:show(InfoMessage:new{
                text = _("Failed to load menu picker module."),
                timeout = 3,
            })
            cancelActionPicker()
            return
        end
        
        MenuPicker.startPicking(
            target_menu,
            function(path_record)
                -- Create a clean copy with only serializable data
                local function cleanString(s)
                    if not s then return "" end
                    return s:gsub("[\n\r]", ""):match("^%s*(.-)%s*$") or ""
                end
                local clean_record = {
                    tab_index = path_record.tab_index,
                    display_label = cleanString(path_record.display_label),
                    index_path = path_record.index_path,
                    view = view,
                    is_leaf = path_record.is_leaf,
                }
                
                current_action_type = "menu"
                current_action_val1 = clean_record
                current_action_title = clean_record.display_label
                _buildSaveDialog(true)
            end,
            function()
                cancelActionPicker()
            end,
            view
        )
    end

    -- ==========================================================================
    -- openActionPicker — main action type selection dialog
    -- ==========================================================================
    openActionPicker = function()
        if active_dialog then UIManager:close(active_dialog); active_dialog = nil end
        local choice_dialog
        choice_dialog = ButtonDialog:new{ title = _("Action Type"), title_align = "center", buttons = {
            {{ text = _("Folder"),
               callback = function() UIManager:close(choice_dialog); openFolderPicker() end }},
            {{ text = _("Collection"), enabled = #collections > 0,
               callback = function() UIManager:close(choice_dialog); openCollectionPicker() end }},
            {{ text = _("Plugin"),
               callback = function() UIManager:close(choice_dialog); openPluginPicker() end }},
            {{ text = _("System Actions"),
               callback = function() UIManager:close(choice_dialog); openDispatcherPicker() end }},
            {{ text = _("Menu Action"),
               callback = function()
                   UIManager:close(choice_dialog)
                   local SUIWindow = require("sui_window")
                   for _, inst in ipairs(SUIWindow._open_instances or {}) do
                       inst:close()
                   end
                   openMenuPicker()
               end }},
            {{ text = _("Cancel"),
               callback = function() UIManager:close(choice_dialog); cancelActionPicker() end }},
        }}
        UIManager:show(choice_dialog)
    end

    if not qa_id then
        openActionPicker()
    else
        _buildSaveDialog(false)
    end
end

-- ---------------------------------------------------------------------------
-- makeIconsMenuItems(plugin) — sub_item_table for Style → Icons
-- ---------------------------------------------------------------------------

function QA.makeIconsMenuItems(plugin)
    local items = {}

    items[#items + 1] = {
        text           = _("Reset All Quick Action Icons"),
        keep_menu_open = true,
        callback       = function()
            for _k, a in ipairs(Config.ALL_ACTIONS) do
                SUISettings:del("simpleui_action_" .. a.id .. "_icon")
            end
            SUISettings:del("simpleui_action_wifi_toggle_off_icon")
            for _i, qa_id in ipairs(QA.getCustomQAList()) do
                local cfg = SUISettings:get("simpleui_qa_" .. qa_id)
                if type(cfg) == "table" then
                    cfg.icon = nil
                    SUISettings:set("simpleui_qa_" .. qa_id, cfg)
                end
            end
            local ok_ss, SUIStyle = pcall(require, "sui_style")
            if ok_ss and SUIStyle then
                for _, s in ipairs(SUIStyle.SLOTS) do
                    if s.group == "sui_qa_defaults" then
                        SUIStyle.setIcon(s.id, nil)
                    end
                end
            end
            QA.invalidateCustomQACache()
            plugin:_rebuildAllNavbars()
            local ok, HS = pcall(require, "sui_homescreen")
            if ok and HS and HS._instance then HS._instance:_refreshImmediate(false) end
        end,
        separator = true,
    }

    local ok_ss, SUIStyle = pcall(require, "sui_style")
    if ok_ss and SUIStyle then
        for _, slot in ipairs(SUIStyle.SLOTS) do
            if slot.group == "sui_qa_defaults" then
                items[#items + 1] = {
                    text_func = function()
                        local path = SUIStyle.getIcon(slot.id)
                        local label = type(slot.label) == "function" and slot.label() or slot.label
                        if path then
                            return label .. "  \u{270E}"
                        end
                        return label
                    end,
                    keep_menu_open = true,
                    callback = function()
                        QA.showIconPicker(
                            SUIStyle.getIcon(slot.id),
                            function(new_path)
                                _guardedSetIcon(new_path, function(safe_path)
                                    SUIStyle.setIcon(slot.id, safe_path)
                                    QA.invalidateCustomQACache()
                                    plugin:_rebuildAllNavbars()
                                    local ok, HS = pcall(require, "sui_homescreen")
                                    if ok and HS and HS._instance then HS._instance:_refreshImmediate(false) end
                                end)
                            end,
                            type(slot.label) == "function" and slot.label() or slot.label,
                            plugin,
                            "_sysicon_picker_" .. slot.id
                        )
                    end,
                }
            end
        end
        if #items > 1 then
            items[#items].separator = true
        end
    end

    local pool = {}
    for _k, a in ipairs(Config.ALL_ACTIONS) do
        local lbl = QA.getEntry(a.id).label
        if a.id == "wifi_toggle" then
            pool[#pool + 1] = { id = a.id, is_default = true, title = lbl .. "  (" .. _("On") .. ")" }
            pool[#pool + 1] = { id = "wifi_toggle_off", is_default = true, title = lbl .. "  (" .. _("Off") .. ")" }
        else
            pool[#pool + 1] = { id = a.id, is_default = true, title = lbl }
        end
    end
    for _i, qa_id in ipairs(Config.getCustomQAList()) do
        local c = Config.getCustomQAConfig(qa_id)
        pool[#pool + 1] = { id = qa_id, is_default = false, title = c.label or qa_id }
    end
    table.sort(pool, function(a, b)
        return a.title:lower() < b.title:lower()
    end)

    for _k, entry in ipairs(pool) do
        local _id         = entry.id
        local _is_default = entry.is_default
        local _title      = entry.title
        items[#items + 1] = {
            text_func = function()
                local has_custom = _is_default
                    and QA.getDefaultActionIcon(_id) ~= nil
                    or (not _is_default and (function()
                            local c = Config.getCustomQAConfig(_id)
                            return c.icon ~= nil
                                and c.icon ~= Config.CUSTOM_ICON
                                and c.icon ~= Config.CUSTOM_PLUGIN_ICON
                                and c.icon ~= Config.CUSTOM_DISPATCHER_ICON
                        end)())
                return _title .. (has_custom and "  \u{270E}" or "")
            end,
            keep_menu_open = true,
            callback = function()
                local current_icon
                if _is_default then
                    current_icon = QA.getDefaultActionIcon(_id)
                else
                    current_icon = Config.getCustomQAConfig(_id).icon
                end
                local default_label = _title .. " (" .. _("default") .. ")"
                QA.showIconPicker(current_icon, function(new_icon)
                    _guardedSetIcon(new_icon, function(safe_icon)
                        if _is_default then
                            QA.setDefaultActionIcon(_id, safe_icon)
                        else
                            local c = Config.getCustomQAConfig(_id)
                            local type_default
                            if c.dispatcher_action and c.dispatcher_action ~= "" then
                                type_default = Config.CUSTOM_DISPATCHER_ICON
                            elseif c.plugin_key and c.plugin_key ~= "" then
                                type_default = Config.CUSTOM_PLUGIN_ICON
                            else
                                type_default = Config.CUSTOM_ICON
                            end
                            Config.saveCustomQAConfig(_id, c.label, c.path, c.collection,
                                safe_icon or type_default,
                                c.plugin_key, c.plugin_method, c.dispatcher_action)
                        end
                        QA.invalidateCustomQACache()
                        plugin:_rebuildAllNavbars()
                        local ok, HS = pcall(require, "sui_homescreen")
                        if ok and HS and HS._instance then HS._instance:_refreshImmediate(false) end
                    end)
                end, default_label, plugin, "_qa_icon_picker_style")
            end,
        }
    end
    return items
end

-- ---------------------------------------------------------------------------
-- makeMenuItems(plugin) — Quick Actions menu items
-- ---------------------------------------------------------------------------

function QA.makeMenuItems(plugin, ctx_menu)
    local InfoMessage = require("ui/widget/infomessage")
    local ConfirmBox  = require("ui/widget/confirmbox")
    local InputDialog = require("ui/widget/inputdialog")

    local MAX_CUSTOM_QA = Config.MAX_CUSTOM_QA

    local items = {}

    if not (ctx_menu and ctx_menu.is_sui) then
        items[#items + 1] = {
            text         = _("Create Quick Action"),
            enabled_func = function() return #Config.getCustomQAList() < MAX_CUSTOM_QA end,
            callback     = function(_menu_self, suppress_refresh)
                if #Config.getCustomQAList() >= MAX_CUSTOM_QA then
                    UIManager:show(InfoMessage:new{
                        text    = string.format(N_("The maximum of %d quick action has been reached. Delete one first.",
                                  "The maximum of %d quick actions has been reached. Delete one first.", MAX_CUSTOM_QA), MAX_CUSTOM_QA),
                        timeout = 2,
                    })
                    return
                end
                if suppress_refresh then suppress_refresh() end
                QA.showQuickActionDialog(plugin, nil, function()
                    local ok, HS = pcall(require, "sui_homescreen")
                    if ok and HS and HS._instance then HS._instance:_refreshImmediate(false) end
                    if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end
                end)
            end,
            separator    = true,
        }
    end

    local qa_list = Config.getCustomQAList()
    if #qa_list == 0 then return items end
    items[#items].separator = true

    local sorted_qa = {}
    for _i, qa_id in ipairs(qa_list) do
        local cfg = Config.getCustomQAConfig(qa_id)
        sorted_qa[#sorted_qa + 1] = { id = qa_id, label = cfg.label or qa_id }
    end
    table.sort(sorted_qa, function(a, b) return a.label:lower() < b.label:lower() end)

    for _i, entry in ipairs(sorted_qa) do
        local _id = entry.id
        items[#items + 1] = {
            text_func = function()
                local c = Config.getCustomQAConfig(_id)
                local desc
                if c.dispatcher_action and c.dispatcher_action ~= "" then
                    desc = "⊕ " .. c.dispatcher_action
                elseif c.plugin_key and c.plugin_key ~= "" then
                    desc = "⬡ " .. c.plugin_key .. ":" .. (c.plugin_method or "?")
                elseif c.collection and c.collection ~= "" then
                    desc = "⊞ " .. c.collection
                elseif c.menu_path and type(c.menu_path) == "table" then
                    desc = "⊚ " .. (c.menu_path.display_label or "Menu Action")
                else
                    desc = c.path or _("not configured")
                    if #desc > 34 then desc = "…" .. desc:sub(-31) end
                end
                return c.label .. "  |  " .. desc
            end,
            sub_item_table_func = function()
                local sub = {}
                sub[#sub + 1] = {
                    text_func = function()
                        local c = Config.getCustomQAConfig(_id)
                        local desc
                        if c.plugin_key and c.plugin_key ~= "" then
                            desc = "⬡ " .. c.plugin_key .. ":" .. (c.plugin_method or "?")
                        elseif c.collection and c.collection ~= "" then
                            desc = "⊞ " .. c.collection
                        elseif c.menu_path and type(c.menu_path) == "table" then
                            desc = "⊚ " .. (c.menu_path.display_label or "Menu Action")
                        else
                            desc = c.path or _("not configured")
                            if #desc > 38 then desc = "…" .. desc:sub(-35) end
                        end
                        return c.label .. "  |  " .. desc
                    end,
                    enabled = false,
                }
                sub[#sub + 1] = {
                    text     = _("Edit"),
                    callback = function(_menu_self, suppress_refresh)
                        if suppress_refresh then suppress_refresh() end
                        QA.showQuickActionDialog(plugin, _id, function()
                            local ok, HS = pcall(require, "sui_homescreen")
                            if ok and HS and HS._instance then HS._instance:_refreshImmediate(false) end
                            if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end
                        end)
                    end,
                }
                sub[#sub + 1] = {
                    text     = _("Delete"),
                    callback = function()
                        local c = Config.getCustomQAConfig(_id)
                        UIManager:show(ConfirmBox:new{
                            text        = string.format(_("Delete quick action \"%s\"?"), c.label),
                            ok_text     = _("Delete"),
                            cancel_text = _("Cancel"),
                            ok_callback = function()
                                Config.deleteCustomQA(_id)
                                Config.invalidateTabsCache()
                                QA.invalidateCustomQACache()
                                plugin:_rebuildAllNavbars()
                                if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end
                            end,
                        })
                    end,
                }
                return sub
            end,
        }
    end

    return items
end

-- ---------------------------------------------------------------------------
-- executeCustomQA — single source of truth for custom QA execution
-- ---------------------------------------------------------------------------

function QA.executeCustomQA(action_id, fm, show_unavailable_fn)
    local function _unavail(msg)
        if show_unavailable_fn then
            show_unavailable_fn(msg)
        else
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{ text = msg, timeout = 3 })
        end
    end

    local cfg = SUISettings:get("simpleui_qa_" .. action_id) or {}

    if cfg.dispatcher_action and cfg.dispatcher_action ~= "" then
        local ok_disp, Dispatcher = pcall(require, "dispatcher")
        if ok_disp and Dispatcher then
            local action_value = cfg.dispatcher_value or true
            local ok, err = pcall(function()
                Dispatcher:execute({ [cfg.dispatcher_action] = action_value })
            end)
            if not ok then
                logger.warn("simpleui: dispatcher_action failed:", cfg.dispatcher_action, tostring(err))
                _unavail(string.format(_("System action error: %s"), tostring(err)))
            end
        else
            _unavail(_("Dispatcher not available."))
        end

    elseif cfg.plugin_key and cfg.plugin_method and cfg.plugin_key ~= "" then
        local live_fm = package.loaded["apps/filemanager/filemanager"]
        live_fm = live_fm and live_fm.instance
        local effective_fm = (live_fm and live_fm[cfg.plugin_key]) and live_fm or fm
        local plugin_inst = effective_fm and effective_fm[cfg.plugin_key]

        local method = cfg.plugin_method
        if plugin_inst and not plugin_inst[method] and method == "_sui_launch" then
            local probe = {}
            local ok = pcall(function() plugin_inst:addToMainMenu(probe) end)
            if ok then
                local entry = probe[cfg.plugin_key] or probe[plugin_inst.name]
                if entry and type(entry.callback) == "function" then
                    local cb = entry.callback
                    plugin_inst._sui_launch = function(_self) cb() end
                end
            end
        end

        if plugin_inst and type(plugin_inst[method]) == "function" then
            local ok, err = pcall(function() plugin_inst[method](plugin_inst) end)
            if not ok then _unavail(string.format(_("Plugin error: %s"), tostring(err))) end
        else
            _unavail(string.format(_("Plugin not available: %s"), cfg.plugin_key))
        end

    elseif cfg.collection and cfg.collection ~= "" then
        if fm and fm.collections then
            local ok, err = pcall(function() fm.collections:onShowColl(cfg.collection) end)
            if not ok then _unavail(string.format(_("Collection not available: %s"), cfg.collection)) end
        end

    elseif cfg.path and cfg.path ~= "" then
        if fm and fm.file_chooser then fm.file_chooser:changeToPath(cfg.path) end

    -- Menu action (recorded menu navigation path)
    elseif cfg.menu_path and type(cfg.menu_path) == "table" then
        local MenuPicker = require("sui_menu_picker")
        local target_menu = nil
        
        local recorded_view = cfg.menu_path.view or "reader"
        local RUI = package.loaded["apps/reader/readerui"]
        local FM_mod = package.loaded["apps/filemanager/filemanager"]
        local fm_inst = FM_mod and FM_mod.instance
        local rui_inst = RUI and RUI.instance
        
        -- Check if current view matches the recorded view
        local current_view = nil
        if rui_inst and rui_inst.menu then
            current_view = "reader"
        elseif fm_inst and fm_inst.menu then
            current_view = "fb"
        end
        
        if recorded_view ~= current_view then
            local msg = (recorded_view == "reader") 
                and _("This shortcut only works in the reader. Please open a book first.")
                or _("This shortcut only works in the file browser.")
            _unavail(msg)
            return
        end
        
        -- Get the target menu widget
        if recorded_view == "reader" then
            if rui_inst and rui_inst.menu then
                if not rui_inst.menu.show_parent then
                    rui_inst.menu:onShowMenu()
                end
                local mc = rui_inst.menu.menu_container
                if mc and mc[1] then
                    target_menu = mc[1]
                else
                    target_menu = rui_inst.menu
                end
            end
        else  -- "fb"
            if fm_inst and fm_inst.menu then
                fm_inst.menu:onShowMenu(cfg.menu_path.tab_index or 1)
                local mc = fm_inst.menu.menu_container
                if mc and mc[1] then
                    target_menu = mc[1]
                else
                    target_menu = fm_inst.menu
                end
            end
        end
        
        if not target_menu then
            _unavail(_("Menu not available."))
            return
        end
        
        local ok, err = pcall(MenuPicker.replay, target_menu, cfg.menu_path)
        if not ok then
            logger.warn("simpleui: menu replay failed for", action_id, tostring(err))
            _unavail(_("Failed to replay menu action. Menu structure may have changed."))
        end

    else
        _unavail(_("No folder, collection or plugin configured.\nGo to Simple UI → Settings → Quick Actions to set one."))
    end
end

-- ---------------------------------------------------------------------------
-- isInPlaceCustomQA — kept for backwards compatibility
-- ---------------------------------------------------------------------------

function QA.isInPlaceCustomQA(action_id)
    local cfg = SUISettings:get("simpleui_qa_" .. action_id) or {}
    if cfg.dispatcher_action and cfg.dispatcher_action ~= "" then return true end
    if cfg.plugin_key and cfg.plugin_method and cfg.plugin_key ~= "" then return true end
    return false
end

-- ---------------------------------------------------------------------------
-- Bootstrap: register all built-in actions at module load time.
-- ---------------------------------------------------------------------------
_registerBuiltins()

return QA
