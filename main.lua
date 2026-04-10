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
            -- Regista o botão TBR no diálogo de hold da Library (livro individual).
            -- addFileDialogButtons é a API oficial do KOReader para isso.
            -- O botão para seleção múltipla é injectado via patchGetPlusDialogButtons
            -- em sui_patches.lua → patchFileManagerClass.
            UIManager:scheduleIn(0, function()
                local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
                if not (ok_fm and FM and FM.instance) then return end
                local ok_tbr, TBR = pcall(require, "desktop_modules/module_tbr")
                if not (ok_tbr and TBR) then return end
                FM.instance:addFileDialogButtons("sui_tbr", function(file, is_file, _book_props)
                    if not is_file then return nil end
                    -- Only show the button for files that are books
                    -- (have a provider or have been opened before).
                    local ok_dr, DR = pcall(require, "document/documentregistry")
                    local ok_bl, BL = pcall(require, "ui/widget/booklist")
                    local is_book = (ok_dr and DR and DR:hasProvider(file))
                        or (ok_bl and BL and BL.hasBookBeenOpened(file))
                    if not is_book then return nil end
                    -- After toggling TBR, close the dialog and refresh the file list,
                    -- matching the same behaviour as "On Hold", "Reading", etc.
                    -- Note: file_dialog is a property of file_chooser, not FM.instance.
                    local close_refresh = function()
                        local fc = FM.instance and FM.instance.file_chooser
                        local dlg = fc and fc.file_dialog
                        if dlg then UIManager:close(dlg) end
                        if fc then fc:refreshPath() end
                    end
                    return { TBR.genTBRButton(file, close_refresh) }
                end)
            end)
            if G_reader_settings:nilOrTrue("navbar_topbar_enabled") then
                Topbar.scheduleRefresh(self, 0)
            end
            -- Pre-load ALL desktop modules during boot idle time so the first
            -- Homescreen open has no perceptible freeze. scheduleIn(2) runs
            -- after the FileManager UI is fully painted and stable.
            -- Registry.list() triggers _load() which pcall-requires all 9
            -- module_*.lua files — they land in package.loaded and subsequent
            -- require() calls are free table lookups, not disk I/O.
            UIManager:scheduleIn(2, function()
                local ok, reg = pcall(require, "desktop_modules/moduleregistry")
                if ok and reg then pcall(reg.list) end
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
    "sui_homescreen", "sui_foldercovers", "sui_updater",
    "desktop_modules/moduleregistry",
    "desktop_modules/module_books_shared",
    "desktop_modules/module_clock",
    "desktop_modules/module_collections",
    "desktop_modules/module_currently",
    "desktop_modules/module_quick_actions",
    "desktop_modules/module_quote",
    "desktop_modules/module_reading_goals",
    "desktop_modules/module_reading_stats",
    "desktop_modules/module_stats_provider",
    "desktop_modules/module_recent",
    "desktop_modules/module_tbr",
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
    local mod_tbr = package.loaded["desktop_modules/module_tbr"]
    if mod_tbr and type(mod_tbr.reset) == "function" then
        pcall(mod_tbr.reset)
    end
    -- Remove o botão TBR do diálogo da Library.
    local FM = package.loaded["apps/filemanager/filemanager"]
    if FM and FM.instance and FM.instance.removeFileDialogButtons then
        pcall(function() FM.instance:removeFileDialogButtons("sui_tbr") end)
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
    -- If this event was fired by doWifiToggle itself, wifi_optimistic is already
    -- set correctly and the bars are already rebuilt. Skip the reset so the
    -- optimistic icon is preserved (on Kindle isWifiOn() may lag behind).
    -- Still call _refreshCurrentView to rebuild homescreen QA icons.
    if not Config.wifi_broadcast_self then
        Config.wifi_optimistic = nil
    end
    if RUI and RUI.instance then
        self:_rebuildAllNavbars()
    else
        Bottombar.refreshWifiIcon(self)
    end
end

function SimpleUIPlugin:onNetworkDisconnected()
    if self._simpleui_suspended then return end
    local RUI = package.loaded["apps/reader/readerui"]
    -- Same rationale as onNetworkConnected above.
    if not Config.wifi_broadcast_self then
        Config.wifi_optimistic = nil
    end
    if RUI and RUI.instance then
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
    -- Outside the reader: restore the Homescreen.
    -- RS and RG have a built-in date-key guard (_stats_cache_day): they re-query
    -- automatically on a new calendar day and serve the in-memory cache otherwise.
    -- Explicit invalidation here would force full SQL queries on every wakeup
    -- even when nothing changed. Data changes from reading are handled by
    -- onCloseDocument, which invalidates those caches before the next render.
    if not reader_active then
        local HS = package.loaded["sui_homescreen"]
        if HS and HS._instance then
            HS.refresh(true)
        end
        -- Re-open the Homescreen on wakeup when \"Start with Homescreen\" is set.
        if G_reader_settings:nilOrTrue("simpleui_enabled") then
            Patches.showHSAfterResume(self)
        end
    end
end

function SimpleUIPlugin:onCloseDocument()
    if self._simpleui_suspended then return end
    local HS = package.loaded["sui_homescreen"]
    if not HS then return end

    -- Fast-path: if the HS is not visible and is already flagged for rebuild,
    -- there is nothing further to do — the next Homescreen.show() will rebuild
    -- from scratch. Avoids loading the Registry and all module pcalls.
    if not HS._instance and HS._stats_need_refresh then
        if G_reader_settings:nilOrTrue("navbar_topbar_enabled") then
            Topbar.scheduleRefresh(self, 0)
        end
        return
    end

    -- Registry is already loaded (moduleregistry was pre-loaded at boot via
    -- scheduleIn(2)); use package.loaded to avoid a pcall on the hot path.
    -- Fall back to pcall only if it hasn't been loaded yet.
    local Registry = package.loaded["desktop_modules/moduleregistry"]
    if not Registry then
        local ok, reg = pcall(require, "desktop_modules/moduleregistry")
        if not ok then return end
        Registry = reg
    end

    local PFX = "navbar_homescreen_"
    local needs_refresh    = false
    local currently_active = false

    -- Only call pcall(require) for modules that are actually enabled.
    -- Registry.get + Registry.isEnabled are cheap table lookups; the module
    -- is guaranteed already loaded when enabled (required by the HS on open).
    -- Invalidate the shared stats provider when either stats module is active.
    -- One SP.invalidate() covers both reading_goals and reading_stats — they
    -- both read ctx.stats which is populated from StatsProvider.get().
    local mod_rg = Registry.get("reading_goals")
    local mod_rs = Registry.get("reading_stats")
    local stats_active = (mod_rg and Registry.isEnabled(mod_rg, PFX))
        or (mod_rs and mod_rs.isEnabled and mod_rs.isEnabled(PFX))
    if stats_active then
        local SP = package.loaded["desktop_modules/module_stats_provider"]
        if SP then SP.invalidate(); needs_refresh = true end
    end

    -- Determine the filepath of the book that just closed.
    -- readhistory.hist[1] is still the closing book at this point (the reader
    -- has not yet handed control back to the FM, so the history order has not
    -- been updated).
    local rh         = package.loaded["readhistory"]
    local closed_fp  = rh and rh.hist and rh.hist[1] and rh.hist[1].file

    -- Currently Reading shows the current book's cover, title, author and
    -- progress (percent_finished). All of these come from _cached_books_state.
    -- When the reader closes, percent_finished has changed for the closed book.
    -- Instead of discarding the entire _cached_books_state (which forces
    -- prefetchBooks() to re-open every sidecar), we do a surgical invalidation:
    -- only the entry for the closed book is removed from prefetched_data.
    -- prefetchBooks() will then re-open exactly one sidecar (the closed book)
    -- and reuse the mtime-validated sidecar cache for all other entries.
    local mod_cr = Registry.get("currently")
    currently_active = mod_cr and Registry.isEnabled(mod_cr, PFX) or false
    if currently_active then
        -- Read the md5 of the closing book BEFORE _partial_invalidate removes
        -- its prefetched_data entry.  Needed below to surgically evict only
        -- this book from the Cover Deck stats cache.
        local closed_md5
        if closed_fp then
            local bs_pre = (HS._instance and HS._instance._cached_books_state)
                        or HS._cached_books_state
            local pe = bs_pre and bs_pre.prefetched_data
                    and bs_pre.prefetched_data[closed_fp]
            closed_md5 = pe and pe.partial_md5_checksum
        end

        local function _partial_invalidate(bs)
            if not bs then return end
            -- Drop the entry for the closed book so prefetchBooks() re-reads it.
            if bs.prefetched_data and closed_fp then
                bs.prefetched_data[closed_fp] = nil
            end
            -- current_fp will be re-resolved by the next prefetchBooks() call.
            -- Setting it to nil here ensures Currently Reading does not paint
            -- stale progress data before the refresh completes.
            bs.current_fp = nil
        end
        _partial_invalidate(HS._instance and HS._instance._cached_books_state)
        _partial_invalidate(HS._cached_books_state)
        -- When the homescreen is not visible (HS._instance == nil), the partially
        -- invalidated HS._cached_books_state (with current_fp=nil) would be passed
        -- to the next HomescreenWidget:new{} in Homescreen.show(). Because the
        -- state is non-nil, _buildCtx() skips prefetchBooks() entirely, leaving
        -- ctx.current_fp = nil and causing Currently Reading to disappear.
        -- Fix: discard the shared cached state so _buildCtx() is forced to call
        -- prefetchBooks() from scratch on the next Homescreen.show().
        if not HS._instance then
            HS._cached_books_state = nil
        end
        local MC = package.loaded["desktop_modules/module_currently"]
        if MC and MC.invalidateCache then MC.invalidateCache() end

        -- Invalidate the Cover Deck stats cache for the closed book only.
        -- The other books in the carousel have not been read, so their cached
        -- stats are still valid and should not be discarded.
        local MCD = package.loaded["desktop_modules/module_coverdeck"]
        if MCD and MCD.invalidateCacheForMd5 then
            MCD.invalidateCacheForMd5(closed_md5)
        end

        needs_refresh = true
    end

    if not needs_refresh then return end

    -- Invalidate the sidecar mtime-cache entry for the closed book so the
    -- next prefetchBooks() re-reads its updated sidecar (percent_finished, stats).
    -- All other entries remain valid — they have not changed.
    local SH = package.loaded["desktop_modules/module_books_shared"]
    if SH and SH.invalidateSidecarCache then
        SH.invalidateSidecarCache(closed_fp)  -- nil flushes all; fp invalidates only that entry
    end

    if HS._instance then
        -- If Currently Reading is active: full refresh (keep_cache=false) so
        -- prefetchBooks() re-reads the updated progress from the sidecar, but
        -- pass books_only=true so _ctx_cache and _enabled_mods_cache are kept —
        -- the set of enabled modules has not changed, only the book data has.
        -- Stats-only (not currently_active): keep_cache=true skips even _buildCtx.
        HS.refresh(not currently_active, true)
    else
        -- Homescreen not visible yet — flag it for rebuild on next open.
        HS._stats_need_refresh = true
    end

    -- Restart the topbar clock chain. While the reader was open, shouldRunTimer()
    -- returned false (RUI.instance present) so the chain stopped naturally.
    -- Without this, the topbar is frozen until the next hardware event (frontlight,
    -- charge) — wifi state changes that happened during reading would not be
    -- reflected for up to 60 s. scheduleRefresh guards against suspend internally
    -- via shouldRunTimer, so this is safe to call unconditionally here.
    if G_reader_settings:nilOrTrue("navbar_topbar_enabled") then
        Topbar.scheduleRefresh(self, 0)
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