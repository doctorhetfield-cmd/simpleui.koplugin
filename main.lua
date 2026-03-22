-- main.lua — Folio
-- Plugin entry point. Registers the plugin and delegates to specialised modules.

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local Device          = require("device")
local logger          = require("logger")

-- i18n MUST be installed before any other plugin module is require()'d.
-- All modules capture local _ = require("gettext") at load time — if we
-- replace package.loaded["gettext"] here, every subsequent require("gettext")
-- in this plugin receives our wrapper automatically.
local I18n = require("folio_i18n")
I18n.install()

-- Design tokens (Theme, faces). Load early so any subsequent require sees a warm cache.
-- If this fails, other modules that require("folio_theme") will retry; we only log here.
do
    local ok_st, err_st = pcall(require, "folio_theme")
    if not ok_st then
        logger.err("folio: folio_theme failed to load (UI theming may break until restart):", err_st)
    end
end

local Config    = require("folio_config")
local UI        = require("folio_core")
local Bottombar = require("folio_bottombar")
local Topbar    = require("folio_topbar")
local Patches   = require("folio_patches")

local FolioPlugin = WidgetContainer:new{
    name = "folio",

    active_action             = nil,
    _rebuild_scheduled        = false,
    _topbar_timer             = nil,
    _power_dialog             = nil,

    _orig_uimanager_show      = nil,
    _orig_uimanager_close     = nil,
    _orig_booklist_new        = nil,
    _orig_menu_new            = nil,
    _orig_menu_init           = nil,
    _orig_fmcoll_show         = nil,
    _orig_rc_remove           = nil,
    _orig_rc_rename           = nil,
    _orig_fc_init             = nil,
    _orig_fm_setup            = nil,

    _makeNavbarMenu           = nil,
    _makeTopbarMenu           = nil,
    _makeQuickActionsMenu     = nil,
    _goalTapCallback          = nil,
}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function FolioPlugin:init()
    local ok, err = pcall(function()
        -- Migrate legacy `simpleui_*` / `sui_*` QoL keys before other init (one-time).
        do
            if not G_reader_settings:readSetting("folio_keys_migrated") then
                local keys = {
                    "simpleui_statusbar_set", "simpleui_screensaver_set",
                    "simpleui_one_handed_mode", "simpleui_one_handed_tap_backup",
                    "simpleui_quote_mode", "simpleui_quote_deck_order",
                    "simpleui_quote_keys_migrated", "simpleui_config_keys_migrated",
                }
                local sui_pairs = {
                    { "sui_statusbar_set", "folio_statusbar_set" },
                    { "sui_screensaver_set", "folio_screensaver_set" },
                    { "sui_one_handed_mode", "folio_one_handed_mode" },
                    { "sui_one_handed_tap_backup", "folio_one_handed_tap_backup" },
                }
                for _, old_key in ipairs(keys) do
                    local val = G_reader_settings:readSetting(old_key)
                    if val ~= nil then
                        local new_key = old_key:gsub("^simpleui_", "folio_")
                        if G_reader_settings:readSetting(new_key) == nil then
                            G_reader_settings:saveSetting(new_key, val)
                        end
                        G_reader_settings:delSetting(old_key)
                    end
                end
                for _, e in ipairs(sui_pairs) do
                    local o, n = e[1], e[2]
                    local val = G_reader_settings:readSetting(o)
                    if val ~= nil and G_reader_settings:readSetting(n) == nil then
                        G_reader_settings:saveSetting(n, val)
                        G_reader_settings:delSetting(o)
                    end
                end
                G_reader_settings:saveSetting("folio_keys_migrated", true)
                G_reader_settings:flush()
            end
        end
        -- Detect hot update: compare the version now on disk with what was
        -- running last session. If they differ, warn the user to restart so
        -- that all plugin modules are loaded fresh.
        local meta_ok, meta = pcall(require, "_meta")
        local current_version = meta_ok and meta and meta.version
        local prev_version = G_reader_settings:readSetting("folio_loaded_version")
        if current_version then
            if prev_version and prev_version ~= current_version then
                logger.info("folio: updated from", prev_version, "to", current_version,
                    "— restart recommended")
                UIManager:scheduleIn(1, function()
                    local InfoMessage = require("ui/widget/infomessage")
                    UIManager:show(InfoMessage:new{
                        text = string.format(
                            _("Folio was updated (%s → %s).\n\nA restart is recommended to apply all changes cleanly."),
                            prev_version, current_version
                        ),
                        timeout = 6,
                    })
                end)
            end
            G_reader_settings:saveSetting("folio_loaded_version", current_version)
        end

        Config.migrateLegacySettingsKeysToFolioPrefix()
        Config.applyFirstRunDefaults()
        if G_reader_settings:nilOrTrue("folio_enabled") then
            local ok_qol, Qol = pcall(require, "folio_qol")
            if ok_qol and Qol then
                if Qol.applySmartStatusBarFirstLaunch then Qol.applySmartStatusBarFirstLaunch() end
                if Qol.applyScreensaverDefaultsFirstLaunch then Qol.applyScreensaverDefaultsFirstLaunch() end
            end
        end
        Config.migrateOldCustomSlots()
        -- Only sanitize QA slots when custom QAs actually exist.
        -- getCustomQAList() is a single settings read; skipping the full
        -- sanitize pass on every boot saves several settings reads + writes
        -- for the common case where no custom QAs have been defined.
        if next(Config.getCustomQAList()) then
            Config.sanitizeQASlots()
        end
        self.ui.menu:registerToMainMenu(self)
        if G_reader_settings:nilOrTrue("folio_enabled") then
            Patches.installAll(self)
            if G_reader_settings:nilOrTrue("folio_navbar_topbar_enabled") then
                Topbar.scheduleRefresh(self, 0)
            end
            -- Pre-load desktop modules during boot idle time so the first
            -- Homescreen open has no perceptible freeze. scheduleIn(2) runs
            -- after the FileManager UI is fully painted and stable.
            UIManager:scheduleIn(2, function()
                pcall(require, "desktop_modules/moduleregistry")
            end)
        end
    end)
    if not ok then logger.err("folio: init failed:", tostring(err)) end
end

-- ---------------------------------------------------------------------------
-- List of all plugin-owned Lua modules that must be evicted from
-- package.loaded on teardown so that a hot plugin update (replacing files
-- without restarting KOReader) always loads fresh code.
-- ---------------------------------------------------------------------------
local _PLUGIN_MODULES = {
    "folio_i18n", "folio_theme", "folio_config", "folio_core", "folio_bottombar", "folio_topbar",
    "folio_patches", "folio_menu", "folio_titlebar", "folio_quickactions",
    "folio_homescreen", "folio_foldercovers", "collectionswidget", "folio_history", "folio_power",
    "folio_readingtoolbar", "folio_qol", "folio_wifi_reminder",
    "desktop_modules/moduleregistry",
    "desktop_modules/module_books_shared",
    "desktop_modules/module_clock",
    "desktop_modules/module_collections",
    "desktop_modules/module_currently",
    "desktop_modules/module_quick_actions",
    "desktop_modules/module_quote",
    "desktop_modules/module_reading_goals",
    "desktop_modules/module_reading_stats",
    "desktop_modules/module_recent",
    "desktop_modules/quotes",
}

function FolioPlugin:onTeardown()
    if self._topbar_timer then
        UIManager:unschedule(self._topbar_timer)
        self._topbar_timer = nil
    end
    do
        local ok_rm, Rem = pcall(require, "folio_wifi_reminder")
        if ok_rm and Rem and Rem.cancelAll then pcall(Rem.cancelAll) end
    end
    Patches.teardownAll(self)
    I18n.uninstall()
    -- Give modules with internal upvalue caches a chance to nil them before
    -- their package.loaded entry is cleared — ensures the GC can collect the
    -- old tables immediately rather than waiting for the upvalue to be rebound.
    local mod_recent = package.loaded["desktop_modules/module_recent"]
    if mod_recent and type(mod_recent.reset) == "function" then
        pcall(mod_recent.reset)
    end
    local mod_rg = package.loaded["desktop_modules/module_reading_goals"]
    if mod_rg and type(mod_rg.reset) == "function" then
        pcall(mod_rg.reset)
    end
    -- Evict all plugin modules from the Lua module cache so that a hot update
    -- (files replaced on disk without restarting KOReader) picks up new code
    -- on the next plugin load, instead of reusing the old in-memory versions.
    _menu_installer = nil
    for _, mod in ipairs(_PLUGIN_MODULES) do
        package.loaded[mod] = nil
    end
end

-- ---------------------------------------------------------------------------
-- System events
-- ---------------------------------------------------------------------------

function FolioPlugin:onScreenResize()
    UI.invalidateDimCache()
    UIManager:scheduleIn(0.2, function()
        self:_rewrapAllWidgets()
        self:_refreshCurrentView()
    end)
end

function FolioPlugin:onNetworkConnected()
    Bottombar.refreshWifiIcon(self)
    do
        local ok_rm, Rem = pcall(require, "folio_wifi_reminder")
        if ok_rm and Rem and Rem.scheduleIdleReminder then
            local ok_hw, has_wifi = pcall(function() return Device:hasWifiToggle() end)
            if ok_hw and has_wifi then
                local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
                if ok_nm and NetworkMgr then
                    local ok_w, on = pcall(function() return NetworkMgr:isWifiOn() end)
                    if ok_w and on then
                        Rem.scheduleIdleReminder(self, 60)
                    end
                end
            end
        end
    end
end

function FolioPlugin:onNetworkDisconnected()
    Bottombar.refreshWifiIcon(self)
end

function FolioPlugin:onSuspend()
    if self._topbar_timer then
        UIManager:unschedule(self._topbar_timer)
        self._topbar_timer = nil
    end
end

function FolioPlugin:onResume()
    if G_reader_settings:nilOrTrue("folio_navbar_topbar_enabled") then
        Topbar.scheduleRefresh(self, 0)
    end
    local RUI = package.loaded["apps/reader/readerui"]
    local reader_active = RUI and RUI.instance
    -- Outside the reader: invalidate stat caches and restore the Homescreen.
    if not reader_active then
        local ok_rg, RG = pcall(require, "desktop_modules/module_reading_goals")
        if ok_rg and RG and RG.invalidateCache then RG.invalidateCache() end
        local ok_rs, RS = pcall(require, "desktop_modules/module_reading_stats")
        if ok_rs and RS and RS.invalidateCache then RS.invalidateCache() end
        -- Note: module_quote highlight pool is NOT invalidated on resume.
        -- Highlights only change when the user reads a book; invalidating here
        -- would cause the displayed quote to change on every wakeup/focus change.
        -- If the Homescreen is already visible, force a rebuild so the freshly
        -- invalidated stats are reflected immediately (e.g. after marking a book
        -- as read inside the reader and returning here).
        -- If it's not visible, showHSAfterResume will open it and onShow will
        -- run _buildContent from scratch anyway.
        local HS = package.loaded["folio_homescreen"]
        if HS and HS._instance then
            HS.refresh(false)
        end
        -- Re-open the Homescreen on wakeup when "Start with Homescreen" is set.
        if G_reader_settings:nilOrTrue("folio_enabled") then
            Patches.showHSAfterResume(self)
        end
    end
end

function FolioPlugin:onFrontlightStateChanged()
    if not G_reader_settings:nilOrTrue("folio_navbar_topbar_enabled") then return end
    Topbar.scheduleRefresh(self, 0)
end

-- ---------------------------------------------------------------------------
-- Topbar delegation
-- ---------------------------------------------------------------------------

function FolioPlugin:_registerTouchZones(fm_self)
    Bottombar.registerTouchZones(self, fm_self)
    Topbar.registerTouchZones(self, fm_self)
end

function FolioPlugin:_scheduleTopbarRefresh(delay)
    Topbar.scheduleRefresh(self, delay)
end

function FolioPlugin:_refreshTopbar()
    Topbar.refresh(self)
end

-- ---------------------------------------------------------------------------
-- Bottombar delegation
-- ---------------------------------------------------------------------------

function FolioPlugin:_onTabTap(action_id, fm_self)
    Bottombar.onTabTap(self, action_id, fm_self)
end

function FolioPlugin:_navigate(action_id, fm_self, tabs, force)
    Bottombar.navigate(self, action_id, fm_self, tabs, force)
end

function FolioPlugin:_refreshCurrentView()
    local tabs      = Config.loadTabConfig()
    local action_id = self.active_action or tabs[1] or "home"
    self:_navigate(action_id, self.ui, tabs)
end

function FolioPlugin:_rebuildAllNavbars()
    Bottombar.rebuildAllNavbars(self)
end

function FolioPlugin:_rewrapAllWidgets()
    Bottombar.rewrapAllWidgets(self)
end

function FolioPlugin:_restoreTabInFM(tabs, prev_action)
    Bottombar.restoreTabInFM(self, tabs, prev_action)
end

function FolioPlugin:_setPowerTabActive(active, prev_action)
    Bottombar.setPowerTabActive(self, active, prev_action)
end

function FolioPlugin:_showPowerDialog(fm_self)
    Bottombar.showPowerDialog(self, fm_self)
end

function FolioPlugin:_doWifiToggle()
    Bottombar.doWifiToggle(self)
end

function FolioPlugin:_doRotateScreen()
    Bottombar.doRotateScreen()
end

function FolioPlugin:_showFrontlightDialog()
    Bottombar.showFrontlightDialog()
end

function FolioPlugin:_scheduleRebuild()
    if self._rebuild_scheduled then return end
    self._rebuild_scheduled = true
    UIManager:scheduleIn(0.1, function()
        self._rebuild_scheduled = false
        self:_rebuildAllNavbars()
    end)
end

function FolioPlugin:_updateFMHomeIcon() end

-- ---------------------------------------------------------------------------
-- Main menu entry (folio_menu is lazy-loaded on first access)
-- ---------------------------------------------------------------------------

local _menu_installer = nil

function FolioPlugin:addToMainMenu(menu_items)
    if not _menu_installer then
        local ok, result = pcall(require, "folio_menu")
        if not ok then
            logger.err("folio: folio_menu failed to load: " .. tostring(result))
            menu_items.folio = { sorting_hint = "tools", text = _("Folio"), sub_item_table = {} }
            return
        end
        _menu_installer = result
        -- Capture the bootstrap stub before installing so we can detect replacement.
        local bootstrap_fn = rawget(FolioPlugin, "addToMainMenu")
        _menu_installer(FolioPlugin)
        -- The installer replaces addToMainMenu on the class; call the real one now.
        local real_fn = rawget(FolioPlugin, "addToMainMenu")
        if type(real_fn) == "function" and real_fn ~= bootstrap_fn then
            real_fn(self, menu_items)
        else
            logger.err("folio: folio_menu installer did not replace addToMainMenu")
            menu_items.folio = { sorting_hint = "tools", text = _("Folio"), sub_item_table = {} }
        end
        return
    end
end

return FolioPlugin