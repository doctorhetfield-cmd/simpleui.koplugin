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
--     -- optional, only meaningful when is_in_place is true: set this when
--     -- execute() opens a widget/dialog that outlives the call itself
--     -- (e.g. a UIManager:show()'d confirm box or window). See
--     -- QA.isAsyncInPlace / sui_bottombar._executeInPlace.
--     is_async_in_place = false, -- bool, default false
--     execute     = function(ctx) ... end,
--     -- ctx = { plugin, fm, show_unavailable }
--     -- optional metadata:
--     browsemeta_mode = nil,  -- "author"|"series"|"tags"
--   }

local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan  = require("ui/widget/verticalspan")
local Device    = require("device")
local Screen    = Device.screen
local lfs       = require("libs/libkoreader-lfs")
local logger    = require("logger")
local _ = require("sui_i18n").translate
local N_ = require("sui_i18n").ngettext

local Config      = require("sui_config")
local SUISettings = require("sui_store")
local UI          = require("sui_core")

-- Landscape-aware scaling for the raw pixel/font sizes below that build
-- SUIWindow modal content directly in this file (icon picker previews, the
-- Quick Actions "Group" folder dialog, the Recent grid): every screen
-- builder here uses the ctx.SZ(n) handed to it by SUIWindow itself (single
-- source of truth, see sui_window.lua) instead of a locally-redeclared
-- wrapper. QA.buildQARowIcon is the one exception — it's a plain helper, not
-- a screen builder, so it takes its scale function as an explicit param
-- (falling back to UI.SZ if ever called without one). Not used by this
-- file's homescreen-facing helpers (those are scaled via sui_homescreen.lua's
-- own Config-patch mechanism instead).

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

-- Helper: resolve the live SimpleUIPlugin instance. Tries the given fm first
-- (set as fm._simpleui_plugin during plugin init), then the live FM, then
-- ReaderUI (where the plugin is registered as readerui.simpleui).
local function _resolveSimpleUIPlugin(fm)
    if fm and fm._simpleui_plugin then return fm._simpleui_plugin end
    local live_fm = _liveFM()
    if live_fm and live_fm._simpleui_plugin then return live_fm._simpleui_plugin end
    local RUI = package.loaded["apps/reader/readerui"]
    local rui = RUI and RUI.instance
    return rui and rui.simpleui
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
        -- Set _sui_show_folder_pending before changeToPath: the FileChooser
        -- teardown that changeToPath triggers internally is seen by
        -- patchUIManagerClose as a fullscreen-widget close, which would
        -- schedule a spurious _doShowHS. The flag tells _doShowHS to abort.
        target_fm._sui_show_folder_pending = true
        target_fm._navbar_suppress_path_change = true
        fc:changeToPath(home)
        target_fm._navbar_suppress_path_change = nil
        -- _doShowHS clears the flag; clear it here too in case it was
        -- never consumed (e.g. _doShowHS was skipped for another reason).
        target_fm._sui_show_folder_pending = nil
    end
    if target_fm.updateTitleBarPath then
        pcall(function() target_fm:updateTitleBarPath(home, true) end)
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Action implementations — self-contained, no bottombar dependency
-- ---------------------------------------------------------------------------

-- doWifiToggle: toggle Wi-Fi and immediately refresh all indicators with the
-- optimistic state before broadcastEvent clears it.
local function _doWifiToggle(plugin)
    local ok_hw, has_wifi = pcall(function() return Device:hasWifiToggle() end)
    if not (ok_hw and has_wifi) then
        UIManager:show(require("ui/widget/infomessage"):new{ text = _("WiFi not available on this device."), timeout = 2 })
        return
    end
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok_nm or not NetworkMgr then
        UIManager:show(require("ui/widget/infomessage"):new{ text = _("Network manager unavailable."), timeout = 2 })
        return
    end
    local ok_state, wifi_on = pcall(function() return NetworkMgr:isWifiOn() end)
    if not ok_state then wifi_on = false end
    if wifi_on then
        Config.wifi_optimistic = false
        pcall(function() NetworkMgr:turnOffWifi() end)
        UIManager:show(require("ui/widget/infomessage"):new{ text = _("Wi-Fi off"), timeout = 1 })
    else
        Config.wifi_optimistic = true
        local ok_on, err = pcall(function() NetworkMgr:turnOnWifi() end)
        if not ok_on then
            logger.warn("simpleui: Wi-Fi turn-on error:", tostring(err))
            Config.wifi_optimistic = nil
        end
    end
    -- Refresh all indicators with the optimistic state BEFORE broadcastEvent,
    -- which triggers onNetworkConnected/Disconnected and clears wifi_optimistic.
    if plugin then
        -- 1. Bottom bar tabs.
        plugin:_rebuildAllNavbars()
        -- 2. Topbar wifi icon — synchronous so it fires before wifi_optimistic is nil.
        local ok_tb, Topbar = pcall(require, "sui_topbar")
        if ok_tb and Topbar then
            local cfg = Config.getTopbarConfig()
            if (cfg.side["wifi"] or "hidden") ~= "hidden" then
                pcall(function() Topbar.refresh(plugin) end)
            end
        end
        -- 3. Homescreen quick-action icons — baked into ImageWidgets, need a full rebuild.
        local HS = package.loaded["sui_homescreen"]
        if HS and HS._instance then
            pcall(function() HS.refreshImmediate(false) end)
        end
    end
    -- Broadcast network events so other KOReader listeners are notified.
    -- Set wifi_broadcast_self first so onNetworkConnected/Disconnected knows
    -- the optimistic state was already applied.
    Config.wifi_broadcast_self = true
    if wifi_on then
        pcall(function() UIManager:broadcastEvent(require("ui/event"):new("NetworkDisconnected")) end)
    else
        pcall(function() UIManager:broadcastEvent(require("ui/event"):new("NetworkConnected")) end)
    end
    Config.wifi_broadcast_self = nil
end

-- refreshWifiIcon: called by onNetworkConnected/Disconnected in main.lua.
-- Clears the optimistic flag (unless we set the broadcast ourselves) and
-- rebuilds all navbars + homescreen.
local function _refreshWifiIcon(plugin)
    if not Config.wifi_broadcast_self then
        Config.wifi_optimistic = nil
    end
    plugin:_rebuildAllNavbars()
    local HS = package.loaded["sui_homescreen"]
    if HS and HS.refreshImmediate then
        pcall(function() HS.refreshImmediate(false) end)
    end
end

-- showFrontlightDialog: open the KOReader brightness widget.
-- ---------------------------------------------------------------------------
-- Indicator tracking for dialog/window-style in-place actions.
--
-- Actions like power/settings/frontlight are `is_in_place = true`: tapping
-- them opens a dialog without "navigating" anywhere, so they should light up
-- the bottom bar indicator only for as long as that dialog is on screen, then
-- restore whatever tab was active before it opened. bookmark_browser and
-- power already did this by hand (see the historical setTempTabActive call
-- sites below); these two helpers make it a reusable primitive instead of
-- something every new dialog action has to re-implement.
--
-- Two variants, matching the two shapes dialogs come in:
--   trackIndicatorWhileOpen  — for widgets with no on_close hook of their own
--                               (e.g. KOReader's core FrontlightWidget):
--                               monkey-patches onCloseWidget, chaining any
--                               existing handler.
--   trackIndicatorViaCallback — for windows that already accept an on_close
--                               callback (SettingsWindow, SUIWindow-based
--                               windows): passes a `restore` function through
--                               instead of touching the widget at all.
-- Both no-op safely (dialog still opens) when `plugin` is nil or the
-- bottombar module/API isn't available.
-- ---------------------------------------------------------------------------

function QA.trackIndicatorWhileOpen(plugin, action_id, widget)
    if not (plugin and widget) then return widget end
    local BB = _Bottombar()
    if not (BB and BB.setTempTabActive) then return widget end

    local prev_action = plugin.active_action
    local restored = false
    local function restore()
        if restored then return end
        restored = true
        BB.setTempTabActive(plugin, action_id, false, prev_action)
    end

    BB.setTempTabActive(plugin, action_id, true, prev_action)

    local orig_close = widget.onCloseWidget
    widget.onCloseWidget = function(self_w)
        restore()
        self_w.onCloseWidget = orig_close
        if orig_close then return orig_close(self_w) end
    end

    return widget
end

function QA.trackIndicatorViaCallback(plugin, action_id, opener)
    local BB = _Bottombar()
    if not (plugin and BB and BB.setTempTabActive) then
        return opener(function() end)
    end

    local prev_action = plugin.active_action
    local restored = false
    local function restore()
        if restored then return end
        restored = true
        BB.setTempTabActive(plugin, action_id, false, prev_action)
    end

    BB.setTempTabActive(plugin, action_id, true, prev_action)
    return opener(restore)
end

local function _showFrontlightDialog(plugin)
    local ok_f, has_fl = pcall(function() return Device:hasFrontlight() end)
    if not ok_f or not has_fl then
        UIManager:show(require("ui/widget/infomessage"):new{
            text = _("Frontlight not available on this device."), timeout = 2,
        })
        return
    end
    local widget = require("ui/widget/frontlightwidget"):new{}
    QA.trackIndicatorWhileOpen(plugin, "frontlight", widget)
    UIManager:show(widget)
end

-- showBookmarkBrowserSourceDialog: source-picker for the bookmark browser.
-- Uses _Bottombar().setTempTabActive to manage the bar indicator.
local function _showBookmarkBrowserSourceDialog(bb_ui)
    local ok_bb, BookmarkBrowser = pcall(require, "ui/widget/bookmarkbrowser")
    if not ok_bb then
        _unavailToast(_("Bookmark browser not available."))
        return
    end
    local FM         = package.loaded["apps/filemanager/filemanager"]
    local plugin     = FM and FM.instance and FM.instance._simpleui_plugin
    local prev_action = plugin and plugin.active_action
    local BB         = _Bottombar()
    if plugin then BB.setTempTabActive(plugin, "bookmark_browser", true, prev_action) end

    local HS         = package.loaded["sui_homescreen"]
    local hs_was_open = HS and HS._instance ~= nil
    local home_dir   = G_reader_settings:readSetting("home_dir")
    local source_dialog
    local function open_with_source(fetch_fn, subfolders)
        UIManager:close(source_dialog)
        local info_msg = require("ui/widget/infomessage"):new{
            text    = _("Fetching bookmarks\xe2\x80\xa6"),
            timeout = 0.1,
            _navbar_closing_intentionally = true,
        }
        UIManager:show(info_msg)
        UIManager:nextTick(function()
            local books = {}
            if type(fetch_fn) == "function" then
                fetch_fn(books)
            else
                local util             = require("util")
                local DocumentRegistry = require("document/documentregistry")
                util.findFiles(fetch_fn, function(file)
                    books[file] = DocumentRegistry:hasProvider(file) or nil
                end, subfolders)
            end
            BookmarkBrowser:show(books, bb_ui)
            if hs_was_open then
                local UI_mod = require("sui_core")
                local stack  = UI_mod.getWindowStack()
                for i = #stack, 1, -1 do
                    local w = stack[i] and stack[i].widget
                    if w and w.covers_fullscreen and w.name ~= "homescreen" then
                        local orig_cw = w.onCloseWidget
                        w.onCloseWidget = function(self_w)
                            local hs_inst2 = HS and HS._instance
                            if hs_inst2 then
                                hs_inst2._navbar_closing_intentionally = true
                                UIManager:close(hs_inst2)
                            end
                            if plugin then
                                BB.setTempTabActive(plugin, "bookmark_browser", false, prev_action)
                            end
                            self_w._navbar_closing_intentionally = true
                            self_w.onCloseWidget = orig_cw
                            if orig_cw then return orig_cw(self_w) end
                        end
                        break
                    end
                end
            end
        end)
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    source_dialog = ButtonDialog:new{
        title        = _("Bookmark browser"),
        title_align  = "center",
        width_factor = 0.8,
        buttons = {
            {{ text = _("History"), callback = function()
                open_with_source(function(books)
                    for _, v in ipairs(require("readhistory").hist) do
                        books[v.file] = v.select_enabled or nil
                    end
                end)
            end }},
            {{ text = _("Collections"), callback = function()
                open_with_source(function(books)
                    local rc = require("readcollection")
                    if rc.coll then
                        for _, coll in pairs(rc.coll) do
                            for file in pairs(coll) do books[file] = true end
                        end
                    end
                end)
            end }},
            {{ text = _("Home folder"), enabled = home_dir ~= nil,
               callback = function() open_with_source(home_dir, false) end }},
            {{ text = _("Home folder + subfolders"), enabled = home_dir ~= nil,
               callback = function() open_with_source(home_dir, true) end }},
            {{ text = _("Cancel"), callback = function()
                if plugin then BB.setTempTabActive(plugin, "bookmark_browser", false, prev_action) end
                UIManager:close(source_dialog)
                if hs_was_open then
                    local hs_inst = HS and HS._instance
                    if hs_inst then UIManager:setDirty(hs_inst, "full") end
                end
            end }},
        },
    }
    UIManager:show(source_dialog)
end

-- showPowerDialog: power menu (restart / reboot / sleep / quit).
-- Uses _Bottombar().setTempTabActive to update the bar indicator while the
-- dialog is open — that is a legitimate navbar operation, not action logic.
local function _showPowerDialog(plugin)
    if plugin._power_dialog then return end  -- guard: ignore double-tap
    local ButtonDialog  = require("ui/widget/buttondialog")
    local dialog_w      = math.floor(Screen:getWidth() * 0.42)
    local prev_action   = plugin.active_action
    local BB            = _Bottombar()

    BB.setTempTabActive(plugin, "power", true, prev_action)

    local _quitting = false
    local function _clear()
        plugin._power_dialog = nil
        if _quitting then return end
        BB.setTempTabActive(plugin, "power", false, prev_action)
    end

    local buttons = {}
    if Device:canRestart() then
        buttons[#buttons + 1] = {{ text = _("Restart"), callback = function()
            _quitting = true
            local d = plugin._power_dialog; plugin._power_dialog = nil
            UIManager:close(d); UIManager:flushSettings(); UIManager:restartKOReader()
        end }}
    end
    if Device:canReboot() then
        buttons[#buttons + 1] = {{ text = _("Reboot"), callback = function()
            local d = plugin._power_dialog; plugin._power_dialog = nil
            UIManager:close(d); UIManager:askForReboot()
        end }}
    end
    if Device:canSuspend() then
        buttons[#buttons + 1] = {{ text = _("Sleep"), callback = function()
            _quitting = true
            local d = plugin._power_dialog; plugin._power_dialog = nil
            UIManager:close(d); UIManager:flushSettings(); UIManager:suspend()
        end }}
    end
    buttons[#buttons + 1] = {{ text = _("Quit"), callback = function()
        _quitting = true
        local d = plugin._power_dialog; plugin._power_dialog = nil
        UIManager:close(d); UIManager:flushSettings(); UIManager:quit(0)
    end }}

    plugin._power_dialog = ButtonDialog:new{
        width              = dialog_w,
        tap_close_callback = _clear,
        onCloseWidget      = _clear,
        buttons            = buttons,
    }
    UIManager:show(plugin._power_dialog)
end

-- Expose so main.lua proxy methods and sui_bottombar.refreshWifiIcon callers
-- can be redirected here without requiring sui_bottombar.
QA.doWifiToggle                    = _doWifiToggle
QA.refreshWifiIcon                 = _refreshWifiIcon
QA.showFrontlightDialog            = _showFrontlightDialog
QA.showPowerDialog                 = _showPowerDialog
QA.showBookmarkBrowserSourceDialog = _showBookmarkBrowserSourceDialog

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
                -- Always prefer the live FM instance: ctx.fm may be stale
                -- after the reader closes and the FM is recreated. The fallback
                -- in navigate() resolves the live FM when _navbar_container is
                -- absent, but a partially-destroyed old instance can still pass
                -- that check while having no file_chooser.
                local FM2   = package.loaded["apps/filemanager/filemanager"]
                local fm    = (FM2 and FM2.instance) or ctx.fm or _liveFM()
                if not _goHome(fm) then
                    -- file_chooser not yet created (transitional state after
                    -- returning from the reader) — schedule for the next cycle
                    -- and re-resolve the live instance at that point.
                    UIManager:scheduleIn(0, function()
                        local FM3 = package.loaded["apps/filemanager/filemanager"]
                        local live_fm = (FM3 and FM3.instance) or fm
                        if not _goHome(live_fm) and live_fm and live_fm.file_chooser then
                            UIManager:setDirty(live_fm, "partial")
                        end
                    end)
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
            id    = "recent",
            label = _("Recent"),
            icon  = Config.ICON.recent,
            is_in_place = true,
            execute = function(ctx)
                QA.showRecentWindow(ctx.fm)
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
            id    = "random_document",
            label = _("Random"),
            icon  = Config.ICON.random,
            -- is_in_place: like bookmark_browser/power, this opens a floating
            -- dialog (MultiConfirmBox) on top of whatever screen is active —
            -- it doesn't need the FM to be the visible screen. Keeping this
            -- as `false` forced navigate() to close the homescreen and reveal
            -- the FM underneath before showing the dialog, which is why the
            -- action looked like it "went to Library" no matter where it was
            -- triggered from.
            is_in_place = true,
            -- The MultiConfirmBox outlives this execute() call, same as
            -- bookmark_browser/power — see QA.isAsyncInPlace.
            is_async_in_place = true,
            execute = function(ctx)
                local su = ctx.show_unavailable or _unavailToast
                -- ctx.fm is "whatever widget owns the bottom bar that was
                -- tapped" (see sui_bottombar.registerTouchZones), NOT
                -- necessarily the FileManager — it can be the homescreen,
                -- Collections, History, etc. when random_document is tapped
                -- from their injected bars. Only trust it if it actually
                -- behaves like a FileManager (has openRandomFile); otherwise
                -- fall back to the live FM instance (which stays alive
                -- underneath the homescreen even while hidden — see the
                -- window-stack sink notes in sui_bottombar._executeInPlace).
                local function isFM(w) return w and w.openRandomFile end
                local fm = isFM(ctx.fm) and ctx.fm or _liveFM()
                if not isFM(fm) then fm = nil end
                -- FileManager:openRandomFile only touches `self` to recurse
                -- on the "Another" button (self:openRandomFile(...)) — it
                -- never reads anything off self. So it's safe to call on the
                -- FileManager *class* itself when there's no valid instance
                -- at all, e.g. triggered from inside the reader or the
                -- in-reader quicksettings bar: KOReader tears the FM widget
                -- down (FileManager.instance = nil) the moment a book is
                -- opened.
                local FMClass = fm
                    or package.loaded["apps/filemanager/filemanager"]
                    or require("apps/filemanager/filemanager")
                if not (FMClass and FMClass.openRandomFile) then
                    su(_("File Manager not available."))
                    return
                end
                local dir = (fm and fm.file_chooser and fm.file_chooser.path)
                    or G_reader_settings:readSetting("home_dir")
                    or (Device and Device.home_dir)
                    or "."
                FMClass:openRandomFile(dir, false)
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
            -- is_async_in_place: opens a widget that outlives this execute()
            -- call (async dialog), so _executeInPlace must skip the HS
            -- stack-sink/restore dance for it — see QA.isAsyncInPlace.
            is_async_in_place = true,
            execute = function(ctx)
                local fm = ctx.fm or _liveFM()
                local _bb_ui = fm
                local ok_rui, ReaderUI = pcall(require, "apps/reader/readerui")
                if ok_rui and ReaderUI and ReaderUI.instance then
                    _bb_ui = ReaderUI.instance
                end
                if _bb_ui and not _bb_ui.bookinfo then
                    local ok_bi, BookInfo = pcall(require, "apps/filemanager/filemanagerbookinfo")
                    if ok_bi and BookInfo then
                        _bb_ui.bookinfo = BookInfo
                    end
                end
                _showBookmarkBrowserSourceDialog(_bb_ui)
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
                _doWifiToggle(ctx.plugin or _simpleui_plugin())
            end,
        },
        {
            id    = "frontlight",
            label = _("Brightness"),
            icon  = Config.ICON.frontlight,
            is_in_place = true,
            execute = function(ctx)
                _showFrontlightDialog(ctx.plugin or _simpleui_plugin())
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
                local plugin = ctx.plugin or _simpleui_plugin()
                local ok, SW = pcall(require, "sui_stats_windows")
                if ok and SW and SW.showReadingInsightsWindow then
                    QA.trackIndicatorViaCallback(plugin, "stats_calendar", function(restore)
                        SW.showReadingInsightsWindow(restore)
                    end)
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
            is_async_in_place = true,
            execute = function(ctx)
                _showPowerDialog(ctx.plugin or _simpleui_plugin())
            end,
        },
        {
            id    = "sui_settings",
            label = _("Settings"),
            icon  = Config.ICON.ko_settings,
            is_in_place = true,
            execute = function(ctx)
                local plugin = ctx.plugin or _simpleui_plugin()
                QA.trackIndicatorViaCallback(plugin, "sui_settings", function(restore)
                    require("sui_settings_window"):show(restore)
                end)
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
-- QA.isAsyncInPlace(id) — single authority for "is this in-place action a
-- floating widget/dialog that outlives its execute() call". Mirrors
-- QA.isInPlace's shape: built-ins declare `is_async_in_place = true` on their
-- descriptor (bookmark_browser, power, random_document), custom QA folders
-- delegate to QA.isAsyncInPlaceCustomQA. sui_bottombar._executeInPlace uses
-- this to decide whether to skip the HS stack-sink/restore dance — that dance
-- must not run for actions whose UI is still open when navigate() returns.
-- ---------------------------------------------------------------------------
function QA.isAsyncInPlace(id)
    if not id then return false end
    if id:match("^custom_qa_%d+$") then
        return QA.isAsyncInPlaceCustomQA(id)
    end
    local desc = _registry[id]
    if not desc then return false end
    return desc.is_async_in_place == true
end

-- ---------------------------------------------------------------------------
-- QA.getBrowseMode(id) — single authority for "is this a browsemeta action,
-- and under which mode (author/series/tags)". Reads the same `browsemeta_mode`
-- field already carried by the browse_authors/browse_series/browse_tags
-- descriptors (see the builtins table above), instead of requiring every
-- caller to hardcode the three ids. Returns nil for anything else, so
-- `if QA.getBrowseMode(id) then ... end` works as a plain boolean check too.
-- ---------------------------------------------------------------------------

function QA.getBrowseMode(id)
    if not id then return nil end
    local desc = _registry[id]
    return desc and desc.browsemeta_mode or nil
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
        icon              = cfg.icon,
        qa_folder         = cfg.qa_folder,
    }
end

function QA.saveCustomQAConfig(qa_id, label, path, collection, icon, plugin_key, plugin_method, dispatcher_action, is_folder)
    SUISettings:set(getQASettingsKey(qa_id), {
        label             = label,
        path              = path,
        collection        = collection,
        plugin_key        = plugin_key,
        plugin_method     = plugin_method,
        dispatcher_action = dispatcher_action,
        icon              = icon,
        qa_folder         = is_folder or nil,
    })
end

-- ---------------------------------------------------------------------------
-- QA Groups — a custom QA that, instead of navigating, opens a small modal
-- listing a set of member QA ids. Members are stored under a sibling key so
-- the fixed saveCustomQAConfig signature above stays untouched apart from
-- the trailing is_folder flag.
-- ---------------------------------------------------------------------------

local function getQAFolderItemsKey(qa_id)
    return "simpleui_qa_" .. qa_id .. "_folder_items"
end

function QA.getQAFolderItems(qa_id)
    return SUISettings:get(getQAFolderItemsKey(qa_id)) or {}
end

function QA.saveQAFolderItems(qa_id, items)
    SUISettings:set(getQAFolderItemsKey(qa_id), items)
end

function QA.deleteCustomQA(qa_id)
    SUISettings:del(getQASettingsKey(qa_id))
    SUISettings:del(getQAFolderItemsKey(qa_id))
    _qa_key_cache[qa_id] = nil
    -- If qa_id was a member of any group, drop it from that group's list too.
    do
        local list = QA.getCustomQAList()
        for _i, other_id in ipairs(list) do
            if other_id ~= qa_id then
                local other_cfg = SUISettings:get(getQASettingsKey(other_id))
                if type(other_cfg) == "table" and other_cfg.qa_folder then
                    local items = QA.getQAFolderItems(other_id)
                    local changed = false
                    local new_items = {}
                    for _j, member_id in ipairs(items) do
                        if member_id == qa_id then changed = true
                        else new_items[#new_items + 1] = member_id end
                    end
                    if changed then QA.saveQAFolderItems(other_id, new_items) end
                end
            end
        end
    end
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
                cfg.icon, cfg.plugin_key, cfg.plugin_method, cfg.dispatcher_action, cfg.qa_folder)
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
                cfg.icon, cfg.plugin_key, cfg.plugin_method, cfg.dispatcher_action, cfg.qa_folder)
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

    -- Prune stale/invalid members from each group's own item list, and drop
    -- membership of ids that are themselves groups (nesting is not supported).
    for _i, id in ipairs(list) do
        local cfg = SUISettings:get(getQASettingsKey(id))
        if type(cfg) == "table" and cfg.qa_folder then
            local items = QA.getQAFolderItems(id)
            local clean = {}
            local group_changed = false
            for _j, member_id in ipairs(items) do
                local member_valid = Config.ACTION_BY_ID[member_id]
                        or (member_id:match("^custom_qa_%d+$") and valid_custom[member_id])
                local member_cfg = member_valid and member_id:match("^custom_qa_%d+$")
                        and SUISettings:get(getQASettingsKey(member_id))
                local is_group_member = type(member_cfg) == "table" and member_cfg.qa_folder
                if member_valid and not is_group_member then
                    clean[#clean + 1] = member_id
                else
                    group_changed = true
                    changed = true
                end
            end
            if group_changed then QA.saveQAFolderItems(id, clean) end
        end
    end

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
            if c.qa_folder then
                local n = #QA.getQAFolderItems(_id)
                desc = "▤ " .. string.format(ctx_menu.N_("%d item", "%d items", n), n)
            elseif c.dispatcher_action and c.dispatcher_action ~= "" then
                desc = "⊕ " .. c.dispatcher_action
            elseif c.plugin_key and c.plugin_key ~= "" then
                desc = "⬡ " .. c.plugin_key .. ":" .. (c.plugin_method or "?")
            elseif c.collection and c.collection ~= "" then
                desc = "⊞ " .. c.collection
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
    
    local btn_size = ctx.SZ(Screen:scaleBySize(36))
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
            radius     = ctx.SZ(Screen:scaleBySize(8)),
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
                            and c.icon ~= Config.CUSTOM_GROUP_ICON
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
                    if c.qa_folder then
                        effective_icon = Config.CUSTOM_GROUP_ICON
                    elseif c.dispatcher_action and c.dispatcher_action ~= "" then
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
                                Config.saveCustomQAConfig(_id, c.label, c.path, c.collection, new_icon, c.plugin_key, c.plugin_method, c.dispatcher_action, c.qa_folder)
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
                                    if c.qa_folder then type_default = Config.CUSTOM_GROUP_ICON
                                    elseif c.dispatcher_action and c.dispatcher_action ~= "" then type_default = Config.CUSTOM_DISPATCHER_ICON
                                    elseif c.plugin_key and c.plugin_key ~= "" then type_default = Config.CUSTOM_PLUGIN_ICON
                                    else type_default = Config.CUSTOM_ICON end
                                    Config.saveCustomQAConfig(_id, c.label, c.path, c.collection, safe_icon or type_default, c.plugin_key, c.plugin_method, c.dispatcher_action, c.qa_folder)
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
        if cfg.qa_folder then
            default_icon = (ok_ss and SUIStyle and SUIStyle.getIcon("sui_qa_group")) or Config.CUSTOM_GROUP_ICON or Config.CUSTOM_ICON
        elseif cfg.dispatcher_action and cfg.dispatcher_action ~= "" then
            default_icon = (ok_ss and SUIStyle and SUIStyle.getIcon("sui_qa_system")) or Config.CUSTOM_DISPATCHER_ICON
        elseif cfg.plugin_key and cfg.plugin_key ~= "" then
            default_icon = (ok_ss and SUIStyle and SUIStyle.getIcon("sui_qa_plugin")) or Config.CUSTOM_PLUGIN_ICON
        else
            default_icon = (ok_ss and SUIStyle and SUIStyle.getIcon("sui_qa_folder")) or Config.CUSTOM_ICON
        end

        local icon = cfg.icon or default_icon
        if cfg.icon == Config.CUSTOM_ICON or cfg.icon == Config.CUSTOM_PLUGIN_ICON
                or cfg.icon == Config.CUSTOM_DISPATCHER_ICON or cfg.icon == Config.CUSTOM_GROUP_ICON then
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
    local pending_group_items = qa_id and cfg.qa_folder and QA.getQAFolderItems(qa_id) or {}

    if cfg.qa_folder then
        current_action_type = "group"
        current_action_title = _("Group")
    elseif cfg.dispatcher_action and cfg.dispatcher_action ~= "" then
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

    local function commitQA(final_label, path, coll, default_icon, fm_key, fm_method, dispatcher_action, is_folder)
        local final_id = qa_id or Config.nextCustomQAId()
        if not qa_id then
            local list = Config.getCustomQAList()
            list[#list + 1] = final_id
            Config.saveCustomQAList(list)
        end
        Config.saveCustomQAConfig(final_id, final_label, path, coll,
            chosen_icon or default_icon, fm_key, fm_method, dispatcher_action, is_folder)
        if is_folder then
            QA.saveQAFolderItems(final_id, pending_group_items)
        end
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
            _buildSaveDialog(false)
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
        elseif current_action_type == "group" then
            action_label = action_label .. string.format(N_("Group (%d item)", "Group (%d items)", #pending_group_items), #pending_group_items)
            icon_default = Config.CUSTOM_GROUP_ICON
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
                        
                        local p_path, p_coll, p_pk, p_pm, p_da
                        if current_action_type == "path" then p_path = current_action_val1
                        elseif current_action_type == "collection" then p_coll = current_action_val1
                        elseif current_action_type == "plugin" then p_pk = current_action_val1; p_pm = current_action_val2
                        elseif current_action_type == "dispatcher" then p_da = current_action_val1
                        end

                        commitQA(final_label, p_path, p_coll, chosen_icon or icon_default, p_pk, p_pm, p_da,
                            current_action_type == "group" or nil)
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
        local actions = _scanDispatcherActions()
        if #actions == 0 then
            UIManager:show(InfoMessage:new{ text = _("No system actions found."), timeout = 3 })
            cancelActionPicker()
            return
        end
        local buttons = {}
        table.sort(actions, function(a, b) return a.title:lower() < b.title:lower() end)
        for _i, a in ipairs(actions) do
            local _a = a
            buttons[#buttons + 1] = {{ text = _a.title, callback = function()
                UIManager:close(plugin._qa_dispatcher_picker)
                current_action_type = "dispatcher"
                current_action_val1 = _a.id
                current_action_title = _a.title
                _buildSaveDialog(true)
            end }}
        end
        buttons[#buttons + 1] = {{ text = _("Cancel"),
            callback = function() UIManager:close(plugin._qa_dispatcher_picker); cancelActionPicker() end }}
        plugin._qa_dispatcher_picker = ButtonDialog:new{ title = _("System Actions"), title_align = "center", buttons = buttons }
        UIManager:show(plugin._qa_dispatcher_picker)
    end

    -- Availability filter mirroring sui_menu.lua's actionAvailable(), duplicated
    -- here (deliberately, not shared) since sui_menu's version is a private
    -- local inside its own plugin-installer closure.
    local function _groupMemberAvailable(id)
        if id == "frontlight" then
            local ok, v = pcall(function() return Device:hasFrontlight() end)
            return ok and v == true
        end
        if QA.getBrowseMode(id) then
            local ok_bm, BM = pcall(require, "sui_browsemeta")
            return ok_bm and BM and BM.isEnabled()
        end
        return true
    end

    -- Group member picker: a checkbox-style ButtonDialog, rebuilt in place on
    -- every toggle (same rebuild pattern as _buildSaveDialog). Tap order sets
    -- the group's display order; nesting (a group inside a group) is blocked
    -- by excluding other qa_folder entries from the pool.
    local function openGroupMemberPicker()
        local pool = {}
        for _i, a in ipairs(Config.ALL_ACTIONS) do
            if _groupMemberAvailable(a.id) then
                pool[#pool + 1] = { id = a.id, label = a.id == "home" and Config.homeLabel() or a.label }
            end
        end
        for _i, other_id in ipairs(Config.getCustomQAList()) do
            if other_id ~= qa_id then
                local other_cfg = Config.getCustomQAConfig(other_id)
                if not other_cfg.qa_folder then
                    pool[#pool + 1] = { id = other_id, label = other_cfg.label }
                end
            end
        end
        table.sort(pool, function(a, b) return a.label:lower() < b.label:lower() end)

        local selected = {}
        local order = {}
        for _i, id in ipairs(pending_group_items) do
            selected[id] = true
            order[#order + 1] = id
        end

        local dialog
        local function rebuild()
            local buttons = {}
            for _i, a in ipairs(pool) do
                local _id = a.id
                local mark = selected[_id] and "☑ " or "☐ "
                buttons[#buttons + 1] = {{ text = mark .. a.label, callback = function()
                    UIManager:close(dialog)
                    if selected[_id] then
                        selected[_id] = nil
                        for j, id in ipairs(order) do
                            if id == _id then table.remove(order, j); break end
                        end
                    else
                        selected[_id] = true
                        order[#order + 1] = _id
                    end
                    rebuild()
                end }}
            end
            buttons[#buttons + 1] = {{ text = _("Done"), callback = function()
                UIManager:close(dialog)
                pending_group_items = order
                current_action_type = "group"
                current_action_val1 = nil
                current_action_val2 = nil
                current_action_title = _("Group")
                _buildSaveDialog(true)
            end }}
            buttons[#buttons + 1] = {{ text = _("Cancel"), callback = function()
                UIManager:close(dialog)
                cancelActionPicker()
            end }}
            dialog = ButtonDialog:new{ title = _("Group: select actions"), title_align = "center", buttons = buttons }
            UIManager:show(dialog)
        end
        rebuild()
    end

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
            {{ text = _("Group of Quick Actions"),
               callback = function() UIManager:close(choice_dialog); openGroupMemberPicker() end }},
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
                                and c.icon ~= Config.CUSTOM_GROUP_ICON
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
                            if c.qa_folder then
                                type_default = Config.CUSTOM_GROUP_ICON
                            elseif c.dispatcher_action and c.dispatcher_action ~= "" then
                                type_default = Config.CUSTOM_DISPATCHER_ICON
                            elseif c.plugin_key and c.plugin_key ~= "" then
                                type_default = Config.CUSTOM_PLUGIN_ICON
                            else
                                type_default = Config.CUSTOM_ICON
                            end
                            Config.saveCustomQAConfig(_id, c.label, c.path, c.collection,
                                safe_icon or type_default,
                                c.plugin_key, c.plugin_method, c.dispatcher_action, c.qa_folder)
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
                if c.qa_folder then
                    local n = #Config.getQAFolderItems(_id)
                    desc = "▤ " .. string.format(N_("%d item", "%d items", n), n)
                elseif c.dispatcher_action and c.dispatcher_action ~= "" then
                    desc = "⊕ " .. c.dispatcher_action
                elseif c.plugin_key and c.plugin_key ~= "" then
                    desc = "⬡ " .. c.plugin_key .. ":" .. (c.plugin_method or "?")
                elseif c.collection and c.collection ~= "" then
                    desc = "⊞ " .. c.collection
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
                        if c.qa_folder then
                            local n = #Config.getQAFolderItems(_id)
                            desc = "▤ " .. string.format(N_("%d item", "%d items", n), n)
                        elseif c.plugin_key and c.plugin_key ~= "" then
                            desc = "⬡ " .. c.plugin_key .. ":" .. (c.plugin_method or "?")
                        elseif c.collection and c.collection ~= "" then
                            desc = "⊞ " .. c.collection
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

    if cfg.qa_folder then
        QA.showQAFolderDialog(action_id, cfg.label, fm, show_unavailable_fn)

    elseif cfg.dispatcher_action and cfg.dispatcher_action ~= "" then
        local ok_disp, Dispatcher = pcall(require, "dispatcher")
        if ok_disp and Dispatcher then
            local ok, err = pcall(function()
                Dispatcher:execute({ [cfg.dispatcher_action] = true })
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

    else
        _unavail(_("No folder, collection or plugin configured.\nGo to Simple UI → Settings → Quick Actions to set one."))
    end
end

-- ---------------------------------------------------------------------------
-- buildQARowIcon — small icon preview widget for a Quick Action row.
-- Mirrors the preview used in Style → Icons → System icons (image / nerd-font
-- glyph / fallback initial, framed square) but sized for inline row use.
-- ---------------------------------------------------------------------------

function QA.buildQARowIcon(icon_value, fallback_label, scale_fn)
    local Blitbuffer     = require("ffi/blitbuffer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local ImageWidget    = require("ui/widget/imagewidget")
    local TextWidget     = require("ui/widget/textwidget")
    local Font           = require("ui/font")
    local Geom           = require("ui/geometry")
    local ok_ss, SUIStyle = pcall(require, "sui_style")

    -- scale_fn is the caller's ctx.SZ; fall back to UI.SZ (identical value
    -- during a synchronous SUIWindow build) if ever called without a ctx.
    local SZ = scale_fn or UI.SZ
    local btn_size  = SZ(Screen:scaleBySize(28))
    local icon_size = math.floor(btn_size * 0.7)
    local border_sz = ok_ss and SUIStyle.BORDER_SZ or 1
    local is_nerd   = Config.isNerdIcon(icon_value)

    local icon_widget
    if is_nerd and icon_value then
        local nerd_char = Config.nerdIconChar(icon_value)
        if nerd_char and ok_ss and SUIStyle then
            icon_widget = TextWidget:new{
                text    = nerd_char,
                face    = Font:getFace(SUIStyle.FACE_ICONS, math.floor(icon_size * 0.8)),
                fgcolor = Blitbuffer.COLOR_BLACK,
                padding = 0,
            }
        end
    elseif icon_value then
        local safe_path = ok_ss and SUIStyle and SUIStyle.safeIconPath(icon_value, nil)
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
        radius     = SZ(Screen:scaleBySize(6)),
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

-- ---------------------------------------------------------------------------
-- showQAFolderDialog — runtime modal listing a group's member Quick Actions.
-- Tapping a member closes the modal and executes it via QA.execute, the same
-- single authority used everywhere else (dock, quicksettings bar, etc).
-- ---------------------------------------------------------------------------

function QA.showQAFolderDialog(qa_id, title, fm, show_unavailable_fn)
    local SUIWindow = require("sui_window")
    -- Same plugin-resolution helper runMember() below already relies on —
    -- needed here too so the group's own tab can light up while the window
    -- is open (see trackIndicatorViaCallback below).
    local plugin = _resolveSimpleUIPlugin(fm)

    -- Shared by both grid tiles and the list fallback: executes a member,
    -- routing non-in-place members (folder/collection/library-style QAs)
    -- through plugin:_navigate() so an open Homescreen is closed first and
    -- the navigation is actually visible.
    local function runMember(_mid, ctx)
        ctx.close()
        if QA.isInPlace(_mid) then
            QA.execute(_mid, { fm = fm, show_unavailable = show_unavailable_fn })
        else
            local plugin = _resolveSimpleUIPlugin(fm)
            if plugin and plugin._navigate then
                plugin:_navigate(_mid, plugin.ui or fm, Config.loadTabConfig(), false)
            else
                QA.execute(_mid, { fm = fm, show_unavailable = show_unavailable_fn })
            end
        end
    end

    local function buildRoot(ctx)
        local items = QA.getQAFolderItems(qa_id)

        if #items == 0 then
            return SUIWindow.RowPage{
                items      = {},
                inner_w    = ctx.inner_w,
                empty_text = _("This group is empty.\nAdd actions to it from Settings → Quick Actions."),
                on_repaint = function() ctx.repaint() end,
            }
        end

        -- Preferred rendering: a grid of icon tiles, visually identical to
        -- the Quick Actions Row widget (Style → Icons → System icons uses
        -- the same tile look). Falls back to the plain icon+label list if
        -- the Quick Actions Row module hasn't been loaded for some reason.
        local mqa = package.loaded["desktop_modules/module_quick_actions"]
        if mqa and mqa.buildQAWidget and mqa.getQADims and mqa.FRAME_SZ then
            local valid_items = {}
            local cqa_valid = QA.getCustomQAValid()
            for _, mid in ipairs(items) do
                if mid:match("^custom_qa_%d+$") then
                    if cqa_valid[mid] then valid_items[#valid_items + 1] = mid end
                elseif QA.isBuiltin(mid) then
                    valid_items[#valid_items + 1] = mid
                end
            end

            if #valid_items > 0 then
                local inner_w = ctx.inner_w
                local target_frame_sz = ctx.SZ(Screen:scaleBySize(70))
                local cols = math.max(3, math.min(6, math.floor(inner_w / (target_frame_sz * 1.18))))
                local frame_sz = math.floor((inner_w * 0.86) / cols)
                local scale = math.max(0.45, math.min(1.4, frame_sz / mqa.FRAME_SZ))
                local d = mqa.getQADims(scale)

                -- Horizontal gap between tiles within a row, and vertical gap
                -- above every row (including the first, for breathing room
                -- under the title bar) plus a trailing one below the last row.
                local gap_w = ctx.SZ(Screen:scaleBySize(20))
                local gap_h = ctx.SZ(Screen:scaleBySize(20))
                -- buildQAWidget always reserves its own PAD*2 horizontal
                -- margin inside the width it's given; add it back here so a
                -- "tight" row_w below actually yields gap_w between tiles.
                -- (UI.PAD is a fixed device-pixel constant, not itself
                -- landscape-scaled, so it's wrapped in SZ() here to match
                -- gap_w/gap_h/target_frame_sz above.)
                local ok_core, UI_local = pcall(require, "sui_core")
                local pad2 = (ok_core and UI_local and UI_local.PAD and ctx.SZ(UI_local.PAD * 2)) or ctx.SZ(Screen:scaleBySize(28))

                local function on_tap_fn(_mid) runMember(_mid, ctx) end

                local rows = {}
                local i = 1
                while i <= #valid_items do
                    local chunk = {}
                    for j = i, math.min(i + cols - 1, #valid_items) do
                        chunk[#chunk + 1] = valid_items[j]
                    end
                    local n = #chunk
                    -- Size the row to exactly what this chunk needs (not the
                    -- full inner_w) so buildQAWidget's own gap/centering math
                    -- packs the tiles from the left instead of justifying
                    -- them across the whole row width.
                    local row_w = math.min(inner_w,
                        n * d.frame_sz + math.max(0, n - 1) * gap_w + pad2)
                    local tile_row = mqa.buildQAWidget(
                        row_w, chunk, true, on_tap_fn, d, "rounded_square", "solid", nil)
                    rows[#rows + 1] = VerticalGroup:new{ align = "left",
                        VerticalSpan:new{ width = gap_h },
                        tile_row,
                    }
                    i = i + cols
                end
                rows[#rows + 1] = VerticalSpan:new{ width = gap_h }
                return rows
            end
        end

        -- Fallback: icon + label list (previous behaviour).
        local rows = {}
        for _i, member_id in ipairs(items) do
            local _mid  = member_id
            local entry = QA.getEntry(_mid)
            rows[#rows + 1] = {
                text        = entry.label,
                left_widget = QA.buildQARowIcon(entry.icon, entry.label, ctx.SZ),
                on_tap      = function() runMember(_mid, ctx) end,
            }
        end
        return SUIWindow.RowPage{
            items      = rows,
            inner_w    = ctx.inner_w,
            empty_text = _("This group is empty.\nAdd actions to it from Settings → Quick Actions."),
            on_repaint = function() ctx.repaint() end,
        }
    end

    -- QA group ids (custom_qa_N with qa_folder=true) are `is_in_place` via
    -- QA.isInPlaceCustomQA — same character as power/settings/stats: opening
    -- the group's window doesn't "navigate" anywhere, so the tab should only
    -- light up while it's on screen. trackIndicatorViaCallback (the same
    -- primitive used for sui_settings/stats_calendar) hands back a `restore`
    -- closure that plugs straight into SUIWindow's own on_close hook — no
    -- per-window bookkeeping needed here, and it degrades gracefully
    -- (window still opens, just untracked) if plugin can't be resolved.
    QA.trackIndicatorViaCallback(plugin, qa_id, function(restore)
        local win = SUIWindow:new{
            name        = "sui_win_qa_folder",
            title       = function() return title or _("Quick Actions") end,
            screens     = { __root__ = buildRoot },
            position    = "bottom",
            auto_height = true,
            on_close    = restore,
        }
        win:show()
    end)
end

-- ---------------------------------------------------------------------------
-- showRecentWindow — covers-only grid of the most recently read books,
-- tap to open. Data comes from module_books_shared.prefetchBooks(),
-- independent of the homescreen ctx, so it works from anywhere the "recent"
-- quickaction or the "Simple UI: Recent" gesture can fire (dock,
-- quicksettings bar, FileManager, ReaderUI). Finished books are always
-- excluded (no toggle) — mirrors module_recent's own default before its
-- "Show finished books" setting is turned on. Uses auto_height, same as
-- showQAFolderDialog above, so the window shrinks to fit its content
-- instead of reserving a fixed screen fraction.
-- ---------------------------------------------------------------------------

local RECENT_NUM_COLS  = 4
local RECENT_MAX_BOOKS = RECENT_NUM_COLS  -- single row, no wrapping

-- Mirrors sui_homescreen.lua's _normalizeKoboPath() so covers sourced the
-- same way (via module_books_shared/ReadHistory) open identically on Kobo.
local function _recentNormalizeKoboPath(filepath)
    if not filepath then return filepath end
    local ok, PluginLoader = pcall(require, "pluginloader")
    if not ok or not PluginLoader then return filepath end
    local kobo = PluginLoader:getPluginInstance("kobo_plugin")
    if not kobo or not kobo.virtual_library then return filepath end
    local vl = kobo.virtual_library
    if not next(vl.virtual_to_real) then
        local ok2, err = pcall(function() vl:buildPathMappings() end)
        if not ok2 then
            logger.warn("sui_quickactions: kobo buildPathMappings failed (recent):", err)
            return filepath
        end
    end
    if vl:isVirtualPath(filepath) then return filepath end
    local virtual = vl:getVirtualPath(filepath)
    return virtual or filepath
end

local function _recentOpenBook(filepath)
    local BD = require("ui/bidi")
    local doOpen = function()
        local ReaderUI = package.loaded["apps/reader/readerui"]
            or require("apps/reader/readerui")
        ReaderUI:showReader(_recentNormalizeKoboPath(filepath))
    end
    if G_reader_settings:isTrue("file_ask_to_open") then
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text        = _("Open this file?") .. "\n\n" .. BD.filename(filepath:match("([^/]+)$")),
            ok_text     = _("Open"),
            cancel_text = _("Cancel"),
            ok_callback = doOpen,
        })
    else
        doOpen()
    end
end

local function _recentMakeCoverCell(SH, fp, bd, cw, ch)
    local Geom            = require("ui/geometry")
    local GestureRange    = require("ui/gesturerange")
    local InputContainer  = require("ui/widget/container/inputcontainer")

    local cover = SH.getBookCover(fp, cw, ch, nil, 0.10)
        or SH.coverPlaceholder(bd.title, bd.authors, cw, ch)

    local ic = InputContainer:new{
        dimen = Geom:new{ w = cw, h = ch },
        cover,
    }
    ic.ges_events = {
        Tap = { GestureRange:new{
            ges   = "tap",
            range = function() return ic.dimen end,
        }},
    }
    function ic:onTap()
        _recentOpenBook(fp)
        return true
    end
    return ic
end

local function _recentBuildRootScreen(ctx)
    local SUIWindow       = require("sui_window")
    local SH              = require("desktop_modules/module_books_shared")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")

    local inner_w = ctx.inner_w
    local state   = SH.prefetchBooks(false, true, RECENT_MAX_BOOKS)
    local all_fps = state.recent_fps or {}

    if #all_fps == 0 then
        return { SUIWindow.ListRow{ inner_w = inner_w, title = _("No recent books.") } }
    end

    -- Finished books are always excluded — no toggle, matches the default
    -- (off) state of module_recent's own "Show finished books" setting.
    local fps = {}
    for _, fp in ipairs(all_fps) do
        local pd  = state.prefetched_data[fp]
        local pct = pd and pd.percent or 0
        local is_done = (pct >= 1.0) or
                        (type(pd) == "table" and type(pd.summary) == "table"
                         and pd.summary.status == "complete")
        if not is_done then
            fps[#fps + 1] = fp
        end
    end

    if #fps == 0 then
        return { SUIWindow.ListRow{ inner_w = inner_w, title = _("All recent books are finished.") } }
    end

    local rows = {}
    local gap  = ctx.SZ(Screen:scaleBySize(10))
    local cw   = math.floor((inner_w - (RECENT_NUM_COLS - 1) * gap) / RECENT_NUM_COLS)
    local ch   = math.floor(cw * 3 / 2)

    local i = 1
    while i <= #fps do
        local hg = HorizontalGroup:new{ align = "top" }
        for c = 1, RECENT_NUM_COLS do
            local fp = fps[i]
            if fp then
                local pd = state.prefetched_data[fp]
                local bd = SH.getBookData(fp, pd)
                hg[#hg + 1] = _recentMakeCoverCell(SH, fp, bd, cw, ch)
                i = i + 1
                if c < RECENT_NUM_COLS and fps[i] then
                    hg[#hg + 1] = HorizontalSpan:new{ width = gap }
                end
            end
        end
        rows[#rows + 1] = hg
        if i <= #fps then
            rows[#rows + 1] = VerticalSpan:new{ width = gap }
        end
    end

    return rows
end

-- fm is optional — omitted when called from the "Simple UI: Recent" gesture
-- (main.lua:onSimpleUIRecentWindow), in which case _resolveSimpleUIPlugin
-- falls back to the live FM, same degrade-gracefully behaviour as
-- showQAFolderDialog above.
function QA.showRecentWindow(fm)
    local SUIWindow = require("sui_window")
    local plugin = _resolveSimpleUIPlugin(fm)

    QA.trackIndicatorViaCallback(plugin, "recent", function(restore)
        local win = SUIWindow:new{
            name        = "sui_win_recent",
            title       = _("Recent"),
            screens     = { __root__ = _recentBuildRootScreen },
            position    = "bottom",
            auto_height = true,
            on_close    = restore,
        }
        win:show()
    end)
end

-- ---------------------------------------------------------------------------
-- isInPlaceCustomQA — kept for backwards compatibility
-- ---------------------------------------------------------------------------

function QA.isInPlaceCustomQA(action_id)
    local cfg = SUISettings:get("simpleui_qa_" .. action_id) or {}
    if cfg.qa_folder then return true end
    if cfg.dispatcher_action and cfg.dispatcher_action ~= "" then return true end
    if cfg.plugin_key and cfg.plugin_method and cfg.plugin_key ~= "" then return true end
    return false
end

-- ---------------------------------------------------------------------------
-- isAsyncInPlaceCustomQA — in-place custom QAs whose UI outlives the calling
-- function (i.e. opens a floating widget instead of executing synchronously).
-- Delegated to by QA.isAsyncInPlace for the custom_qa_%d+ case (mirrors
-- QA.isInPlaceCustomQA's role for QA.isInPlace above). These must NOT be
-- wrapped by the HS stack-sink/restore dance in sui_bottombar._executeInPlace,
-- because the sink is undone before the async widget's own show/close cycle
-- completes.
-- ---------------------------------------------------------------------------

function QA.isAsyncInPlaceCustomQA(action_id)
    local cfg = SUISettings:get("simpleui_qa_" .. action_id) or {}
    return cfg.qa_folder == true
end

-- ---------------------------------------------------------------------------
-- Bootstrap: register all built-in actions at module load time.
-- ---------------------------------------------------------------------------
_registerBuiltins()

return QA
