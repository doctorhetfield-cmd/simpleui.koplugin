-- main.lua — Simple UI
-- Plugin entry point. Registers the plugin and delegates to specialised modules.

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local logger          = require("logger")

-- i18n MUST be installed before any other plugin module is require()'d.
-- All modules capture local _ = require("gettext") at load time — if we
-- replace package.loaded["gettext"] here, every subsequent require("gettext")
-- in this plugin receives our wrapper automatically.
local I18n = require("sui_i18n")
I18n.install()

local Config    = require("sui_config")
local UI        = require("sui_core")
local Bottombar = require("sui_bottombar")
local Topbar    = require("sui_topbar")
local Patches   = require("sui_patches")
local _ = require("gettext")

local SimpleUIPlugin = WidgetContainer:new{
    name = "simpleui",

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

function SimpleUIPlugin:init()
    local ok, err = pcall(function()
        -- Detect hot update: compare the version now on disk with what was
        -- running last session. If they differ, warn the user to restart so
        -- that all plugin modules are loaded fresh.
        local meta_ok, meta = pcall(require, "_meta")
        local current_version = meta_ok and meta and meta.version
        local prev_version = G_reader_settings:readSetting("simpleui_loaded_version")
        if current_version then
            if prev_version and prev_version ~= current_version then
                logger.info("simpleui: updated from", prev_version, "to", current_version,
                    "— restart recommended")
                UIManager:scheduleIn(1, function()
                    local InfoMessage = require("ui/widget/infomessage")
                    local _t = require("gettext")
                    UIManager:show(InfoMessage:new{
                        text = string.format(
                            _t("Simple UI was updated (%s → %s).\n\nA restart is recommended to apply all changes cleanly."),
                            prev_version, current_version
                        ),
                        timeout = 6,
                    })
                end)
            end
            G_reader_settings:saveSetting("simpleui_loaded_version", current_version)
        end

        Config.applyFirstRunDefaults()
        Config.migrateOldCustomSlots()
        -- Only sanitize QA slots when custom QAs actually exist.
        -- getCustomQAList() is a single settings read; skipping the full
        -- sanitize pass on every boot saves several settings reads + writes
        -- for the common case where no custom QAs have been defined.
        if next(Config.getCustomQAList()) then
            Config.sanitizeQASlots()
        end
        self.ui.menu:registerToMainMenu(self)
        if G_reader_settings:nilOrTrue("simpleui_enabled") then
            Patches.installAll(self)
            if G_reader_settings:nilOrTrue("navbar_topbar_enabled") then
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
    if not ok then logger.err("simpleui: init failed:", tostring(err)) end
end

-- ---------------------------------------------------------------------------
-- List of all plugin-owned Lua modules that must be evicted from
-- package.loaded on teardown so that a hot plugin update (replacing files
-- without restarting KOReader) always loads fresh code.
-- ---------------------------------------------------------------------------
local _PLUGIN_MODULES = {
    "sui_i18n", "sui_config", "sui_core", "sui_bottombar", "sui_topbar",
    "sui_patches", "sui_menu", "sui_titlebar", "sui_quickactions",
    "sui_homescreen", "sui_foldercovers",
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

function SimpleUIPlugin:onTeardown()
    if self._topbar_timer then
        UIManager:unschedule(self._topbar_timer)
        self._topbar_timer = nil
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

function SimpleUIPlugin:onScreenResize()
    if self._simpleui_suspended then return end
    UI.invalidateDimCache()
    UIManager:scheduleIn(0.2, function()
        if self._simpleui_suspended then return end
        self:_rewrapAllWidgets()
        self:_refreshCurrentView()
    end)
end

function SimpleUIPlugin:onNetworkConnected()
    if self._simpleui_suspended then return end
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance then
        Config.wifi_optimistic = nil
        self:_rebuildAllNavbars()
    else
        Bottombar.refreshWifiIcon(self)
    end
end

function SimpleUIPlugin:onNetworkDisconnected()
    if self._simpleui_suspended then return end
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance then
        Config.wifi_optimistic = nil
        self:_rebuildAllNavbars()
    else
        Bottombar.refreshWifiIcon(self)
    end
end

function SimpleUIPlugin:onSuspend()
    self._simpleui_suspended = true
    -- Snapshot whether the reader was open at the moment of suspend.
    -- We cannot rely on RUI.instance being intact by the time onResume fires
    -- (e.g. autosuspend can race with a reader teardown on some Kobo builds),
    -- so we capture the truth here, while the world is still settled.
    local RUI = package.loaded["apps/reader/readerui"]
    self._simpleui_reader_was_active = (RUI and RUI.instance) and true or false
    if self._topbar_timer then
        UIManager:unschedule(self._topbar_timer)
        self._topbar_timer = nil
    end
end

function SimpleUIPlugin:onResume()
    self._simpleui_suspended = false
    if G_reader_settings:nilOrTrue("navbar_topbar_enabled") then
        -- Small delay to let the wakeup transition finish before refreshing
        -- the topbar. Avoids a race with HomescreenWidget:onResume() and
        -- prevents the timer firing while the device is still mid-wakeup.
        Topbar.scheduleRefresh(self, 0.5)
    end
    -- Use the snapshot captured in onSuspend rather than checking RUI.instance
    -- live. On some Kobo builds the autosuspend timer fires close to a reader
    -- teardown, leaving RUI.instance nil even though the user was reading —
    -- causing the homescreen to open on wakeup instead of returning to the reader.
    local reader_active = self._simpleui_reader_was_active
    self._simpleui_reader_was_active = nil  -- consume; next suspend will repopulate
    -- Outside the reader: invalidate stat caches and restore the Homescreen.
    if not reader_active then
        local ok_rg, RG = pcall(require, "desktop_modules/module_reading_goals")
        if ok_rg and RG and RG.invalidateCache then RG.invalidateCache() end
        local ok_rs, RS = pcall(require, "desktop_modules/module_reading_stats")
        if ok_rs and RS and RS.invalidateCache then RS.invalidateCache() end
        -- If the Homescreen is already visible, force a rebuild so the freshly
        -- invalidated stats are reflected immediately (e.g. after marking a book
        -- as read inside the reader and returning here).
        -- Use keep_cache=true: book metadata has not changed during suspend, so
        -- we preserve _cached_books_state and skip the expensive prefetchBooks()
        -- IO (5-6 DocSettings.open calls).
        -- If it's not visible, showHSAfterResume will open it and onShow will
        -- run _buildContent from scratch anyway.
        local HS = package.loaded["sui_homescreen"]
        if HS and HS._instance then
            HS.refresh(true)
        end
        -- Re-open the Homescreen on wakeup when "Start with Homescreen" is set.
        if G_reader_settings:nilOrTrue("simpleui_enabled") then
            Patches.showHSAfterResume(self)
        end
    end
end

function SimpleUIPlugin:onCloseDocument()
    if self._simpleui_suspended then return end
    local HS = package.loaded["sui_homescreen"]
    if not HS then return end
    -- Only invalidate caches for modules that are actually enabled and visible.
    local ok_reg, Registry = pcall(require, "desktop_modules/moduleregistry")
    if not ok_reg then return end
    local PFX = "navbar_homescreen_"
    local needs_refresh = false
    local mod_rg = Registry.get("reading_goals")
    if mod_rg and Registry.isEnabled(mod_rg, PFX) then
        local ok, RG = pcall(require, "desktop_modules/module_reading_goals")
        if ok and RG and RG.invalidateCache then RG.invalidateCache(); needs_refresh = true end
    end
    local mod_rs = Registry.get("reading_stats")
    if mod_rs and Registry.isEnabled(mod_rs, PFX) then
        local ok, RS = pcall(require, "desktop_modules/module_reading_stats")
        if ok and RS and RS.invalidateCache then RS.invalidateCache(); needs_refresh = true end
    end
    -- Currently Reading shows the current book's cover, title, author and
    -- progress (percent_finished). All of these come from _cached_books_state,
    -- which keep_cache=true preserves. When the reader closes, percent_finished
    -- has changed — clear _cached_books_state so the next prefetchBooks() re-reads
    -- the updated sidecar data.
    local mod_cr = Registry.get("currently")
    local currently_active = mod_cr and Registry.isEnabled(mod_cr, PFX)
    if currently_active then
        if HS._instance then HS._instance._cached_books_state = nil end
        HS._cached_books_state = nil
        needs_refresh = true
    end
    if not needs_refresh then return end
    if HS._instance then
        -- If Currently Reading is active we must do a full refresh so
        -- prefetchBooks() re-reads the updated progress from the sidecar.
        -- Otherwise keep_cache=true is enough (stats-only update).
        HS.refresh(not currently_active)
    else
        -- Homescreen not visible yet — flag it for rebuild on next open.
        HS._stats_need_refresh = true
    end
end

function SimpleUIPlugin:onFrontlightStateChanged()
    if self._simpleui_suspended then return end
    if not G_reader_settings:nilOrTrue("navbar_topbar_enabled") then return end
    Topbar.scheduleRefresh(self, 0)
end

function SimpleUIPlugin:onCharging()
    if self._simpleui_suspended then return end
    if not G_reader_settings:nilOrTrue("navbar_topbar_enabled") then return end
    Topbar.scheduleRefresh(self, 0)
end

function SimpleUIPlugin:onNotCharging()
    if self._simpleui_suspended then return end
    if not G_reader_settings:nilOrTrue("navbar_topbar_enabled") then return end
    Topbar.scheduleRefresh(self, 0)
end

-- ---------------------------------------------------------------------------
-- Topbar delegation
-- ---------------------------------------------------------------------------

function SimpleUIPlugin:_registerTouchZones(fm_self)
    Bottombar.registerTouchZones(self, fm_self)
    Topbar.registerTouchZones(self, fm_self)
end

function SimpleUIPlugin:_scheduleTopbarRefresh(delay)
    Topbar.scheduleRefresh(self, delay)
end

function SimpleUIPlugin:_refreshTopbar()
    Topbar.refresh(self)
end

-- ---------------------------------------------------------------------------
-- Bottombar delegation
-- ---------------------------------------------------------------------------

function SimpleUIPlugin:_onTabTap(action_id, fm_self)
    Bottombar.onTabTap(self, action_id, fm_self)
end

function SimpleUIPlugin:_navigate(action_id, fm_self, tabs, force)
    Bottombar.navigate(self, action_id, fm_self, tabs, force)
end

function SimpleUIPlugin:_refreshCurrentView()
    local tabs      = Config.loadTabConfig()
    local action_id = self.active_action or tabs[1] or "home"
    self:_navigate(action_id, self.ui, tabs)
end

function SimpleUIPlugin:_rebuildAllNavbars()
    Bottombar.rebuildAllNavbars(self)
end

function SimpleUIPlugin:_rewrapAllWidgets()
    Bottombar.rewrapAllWidgets(self)
end

function SimpleUIPlugin:_restoreTabInFM(tabs, prev_action)
    Bottombar.restoreTabInFM(self, tabs, prev_action)
end

function SimpleUIPlugin:_setPowerTabActive(active, prev_action)
    Bottombar.setPowerTabActive(self, active, prev_action)
end

function SimpleUIPlugin:_showPowerDialog(fm_self)
    Bottombar.showPowerDialog(self, fm_self)
end

function SimpleUIPlugin:_doWifiToggle()
    Bottombar.doWifiToggle(self)
end

function SimpleUIPlugin:_doRotateScreen()
    Bottombar.doRotateScreen()
end

function SimpleUIPlugin:_showFrontlightDialog()
    Bottombar.showFrontlightDialog()
end

function SimpleUIPlugin:_scheduleRebuild()
    if self._rebuild_scheduled then return end
    self._rebuild_scheduled = true
    UIManager:scheduleIn(0.1, function()
        self._rebuild_scheduled = false
        self:_rebuildAllNavbars()
    end)
end

function SimpleUIPlugin:_updateFMHomeIcon() end

-- ---------------------------------------------------------------------------
-- Main menu entry (sui_menu is lazy-loaded on first access)
-- ---------------------------------------------------------------------------

local _menu_installer = nil

function SimpleUIPlugin:addToMainMenu(menu_items)
    local _ = require("gettext")
    if not _menu_installer then
        local ok, result = pcall(require, "sui_menu")
        if not ok then
            logger.err("simpleui: sui_menu failed to load: " .. tostring(result))
            menu_items.simpleui = { sorting_hint = "tools", text = _("Simple UI"), sub_item_table = {} }
            return
        end
        _menu_installer = result
        -- Capture the bootstrap stub before installing so we can detect replacement.
        local bootstrap_fn = rawget(SimpleUIPlugin, "addToMainMenu")
        _menu_installer(SimpleUIPlugin)
        -- The installer replaces addToMainMenu on the class; call the real one now.
        local real_fn = rawget(SimpleUIPlugin, "addToMainMenu")
        if type(real_fn) == "function" and real_fn ~= bootstrap_fn then
            real_fn(self, menu_items)
        else
            logger.err("simpleui: sui_menu installer did not replace addToMainMenu")
            menu_items.simpleui = { sorting_hint = "tools", text = _("Simple UI"), sub_item_table = {} }
        end
        return
    end
end

return SimpleUIPlugin