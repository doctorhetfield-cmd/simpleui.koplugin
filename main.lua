-- main.lua — Simple UI
-- Plugin entry point. Registers the plugin and delegates to specialised modules.

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local logger          = require("logger")
local Dispatcher      = require("dispatcher")

-- Each simpleui module captures its own local translation proxy from sui_i18n.
-- The native package.loaded["gettext"] is never wrapped or replaced, which
-- prevents state-mutation conflicts with other plugins (e.g. zlibrary).
local I18n = require("sui_i18n")
local _    = I18n.translate

local Config    = require("sui_config")
local UI        = require("sui_core")
local Bottombar = require("sui_bottombar")
local Topbar    = require("sui_topbar")
local Patches   = require("sui_patches")

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
                    local _t = require("sui_i18n").translate
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
        -- Always run sanitizeQASlots: it cleans both custom QA slot references
        -- and any stale built-in IDs from navbar_tabs.  The function is cheap —
        -- it reads a handful of settings and only writes back when it finds
        -- something invalid, so the common no-op case costs only a few reads.
        Config.sanitizeQASlots()
        self.ui.menu:registerToMainMenu(self)

        -- Register gesture-assignable actions via Dispatcher.
        -- After this, KOReader's gesture/keyboard settings will list these
        -- actions so the user can bind any gesture to them.
        Dispatcher:init()
        Dispatcher:registerAction("simpleui_go_homescreen", {
            category = "none",
            event    = "SimpleUIGoHomescreen",
            title    = _("Simple UI: Go to Homescreen"),
            general  = true,
        })
        Dispatcher:registerAction("simpleui_go_library", {
            category = "none",
            event    = "SimpleUIGoLibrary",
            title    = _("Simple UI: Go to Library"),
            general  = true,
        })
        Dispatcher:registerAction("simpleui_toggle_home_library", {
            category = "none",
            event    = "SimpleUIToggleHomeLibrary",
            title    = _("Simple UI: Toggle Homescreen / Library"),
            general  = true,
        })

        -- -------------------------------------------------------------------
        -- Icon registration: register the settings tab icon into KOReader's
        -- icon system at plugin init time (eager, not lazy).
        --
        -- This mirrors the approach used by Zen UI (common/inject_icons.lua):
        --   1. Resolve plugin_root to an ABSOLUTE path.  On some KOReader
        --      builds/devices debug.getinfo returns a relative source path
        --      (e.g. "plugins/simpleui.koplugin/main.lua"); without the
        --      lfs.currentdir() fix, every subsequent lfs.attributes() call
        --      fails silently and all three icon-injection strategies in
        --      sui_menu.lua are skipped, leaving the tab icon blank.
        --   2. Copy the SVG to DataStorage/icons/ (persistent, survives
        --      between sessions).  KOReader's ICONS_DIRS always includes
        --      that directory, so the icon resolves even if the runtime
        --      upvalue injection below fails (e.g. hardened builds).
        --   3. Inject the resolved path into IconWidget's ICONS_PATH and
        --      ICONS_DIRS upvalue caches so the icon is immediately available
        --      in the current session without needing a restart.
        --      Unlike sui_menu.lua's three-strategy approach, both caches are
        --      populated in a single upvalue scan (matching Zen UI's method).
        -- -------------------------------------------------------------------
        do
            -- Step 1: resolve plugin_root to an absolute path.
            local src = debug.getinfo(1, "S").source or ""
            local plugin_root = (src:sub(1, 1) == "@") and src:sub(2):match("^(.*)/[^/]+$") or nil
            if plugin_root and plugin_root:sub(1, 1) ~= "/" then
                local ok_lfs2, lfs2 = pcall(require, "libs/libkoreader-lfs")
                local cwd = ok_lfs2 and lfs2 and lfs2.currentdir()
                if cwd then plugin_root = cwd .. "/" .. plugin_root end
            end

            if plugin_root then
                local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
                if ok_lfs and lfs then
                    local icon_src = plugin_root .. "/icons/settings.svg"
                    if lfs.attributes(icon_src, "mode") == "file" then

                        -- Step 2: copy to DataStorage/icons/simpleui_settings.svg
                        -- so ICONS_DIRS disk lookup works even without upvalue injection.
                        pcall(function()
                            local DataStorage = require("datastorage")
                            local ffiutil     = require("ffi/util")
                            local user_dir    = DataStorage:getDataDir() .. "/icons"
                            if lfs.attributes(user_dir, "mode") ~= "directory" then
                                lfs.mkdir(user_dir)
                            end
                            local dst = user_dir .. "/simpleui_settings.svg"
                            if lfs.attributes(dst, "mode") ~= "file" then
                                ffiutil.copyFile(icon_src, dst)
                            end
                        end)

                        -- Step 3: inject into IconWidget's runtime upvalue caches.
                        -- Scan once, collect both ICONS_PATH and ICONS_DIRS together.
                        pcall(function()
                            local iw      = require("ui/widget/iconwidget")
                            local iw_init = rawget(iw, "init")
                            if type(iw_init) ~= "function" then return end
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
                            if icons_path and not icons_path["simpleui_settings"] then
                                icons_path["simpleui_settings"] = icon_src
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
                            end
                        end)

                    end
                end
            end
        end
        -- -------------------------------------------------------------------

        -- -------------------------------------------------------------------
        -- Tab injection: add a dedicated "Simple UI" tab to the KOReader menu
        -- bar (both FileManager and Reader), positioned right after the
        -- QuickSettings tab.  We patch setUpdateItemTable on the menu class
        -- once — the flag __sui_tab_patched prevents double-patching on
        -- subsequent plugin reloads within the same KOReader session.
        -- This mirrors the approach used by Zen UI.
        --
        -- sui_menu is loaded lazily: the pre-bootstrap buildTabItems below
        -- triggers require("sui_menu") on the first menu open, which registers
        -- the icon and installs the real buildTabItems before the tab is built.
        -- This removes sui_menu (and its lfs + IconWidget introspection) from
        -- the critical startup path.
        -- -------------------------------------------------------------------
        do
            -- Pre-bootstrap buildTabItems: installed now so setUpdateItemTable
            -- always finds a callable.  On first call it loads sui_menu (which
            -- replaces this function with the real cached version) and
            -- delegates immediately to the real implementation.
            if not rawget(SimpleUIPlugin, "buildTabItems") then
                SimpleUIPlugin.buildTabItems = function(plugin_self)
                    -- Trigger the full sui_menu load + installer.
                    -- addToMainMenu is the bootstrap stub; calling it with a
                    -- dummy table runs the installer, which replaces both
                    -- addToMainMenu and buildTabItems on SimpleUIPlugin.
                    plugin_self:addToMainMenu({})
                    -- Delegate to the real buildTabItems now installed.
                    local real = rawget(SimpleUIPlugin, "buildTabItems")
                    if type(real) == "function" then
                        return real(plugin_self)
                    end
                    return {}
                end
            end

            local plugin_self = self

            local function find_quicksettings_pos(tab_table)
                for i, tab in ipairs(tab_table) do
                    for _, field in ipairs({ "id", "name", "icon" }) do
                        local v = tab[field]
                        if type(v) == "string" then
                            local norm = v:lower():gsub("[%s_%-]+", "")
                            if norm == "quicksettings" then return i end
                        end
                    end
                end
                return nil
            end

            local function inject_sui_tab(menu_class)
                if not menu_class or menu_class.__sui_tab_patched then return end
                menu_class.__sui_tab_patched = true
                local orig_sut = menu_class.setUpdateItemTable
                menu_class.setUpdateItemTable = function(m_self)
                    orig_sut(m_self)
                    -- Respect the user's choice: default on (nilOrTrue), skip if explicitly false.
                    if not G_reader_settings:nilOrTrue("simpleui_settings_tab_enabled") then return end
                    if type(m_self.tab_item_table) ~= "table" then return end
                    local build_fn = rawget(SimpleUIPlugin, "buildTabItems")
                    if type(build_fn) ~= "function" then return end
                    local ok, tab_items = pcall(build_fn, plugin_self)
                    if not ok or type(tab_items) ~= "table" then return end
                    -- Mirror exactly how Zen UI does it: set icon as a field on
                    -- the items array itself (not a wrapper table), then insert
                    -- that array directly into tab_item_table.
                    tab_items.icon = "simpleui_settings"
                    local qs_pos     = find_quicksettings_pos(m_self.tab_item_table)
                    local insert_pos = qs_pos and (qs_pos + 1) or 1
                    table.insert(m_self.tab_item_table, insert_pos, tab_items)
                end
            end

            -- Inject the SUI tab only into FileManager (and HomeScreen), not into
            -- the Reader menu. The SimpleUI settings tab should not appear while
            -- a document is open.
            local ok_fm, FileManagerMenu = pcall(require, "apps/filemanager/filemanagermenu")
            if ok_fm and FileManagerMenu then inject_sui_tab(FileManagerMenu) end
        end
        -- -------------------------------------------------------------------
        if G_reader_settings:nilOrTrue("simpleui_enabled") then
            Patches.installAll(self)
            -- Register the TBR button in the Library hold dialog (single book).
            -- addFileDialogButtons is the official KOReader API for this.
            -- The multi-selection button is injected via patchGetPlusDialogButtons
            -- in sui_patches.lua → patchFileManagerClass.
            UIManager:scheduleIn(0, function()
                local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
                if not (ok_fm and FM and FM.instance) then return end
                local ok_tbr, TBR = pcall(require, "desktop_modules/module_tbr")
                if not (ok_tbr and TBR) then return end

                -- Shared button factory: generates the TBR button for a given file.
                -- Used by both FM's showFileDialog (library browser) and
                -- FileSearcher's onMenuHold (search results), so both surfaces
                -- show the same "Add to To Be Read" option on long-press.
                local function _makeTBRRow(file, is_file, _book_props, close_refresh_fn)
                    if not is_file then return nil end
                    local ok_dr, DR = pcall(require, "document/documentregistry")
                    local ok_bl, BL = pcall(require, "ui/widget/booklist")
                    local is_book = (ok_dr and DR and DR:hasProvider(file))
                        or (ok_bl and BL and BL.hasBookBeenOpened(file))
                    if not is_book then return nil end
                    return { TBR.genTBRButton(file, close_refresh_fn) }
                end

                -- 1. Library browser (FileManager.showFileDialog).
                -- After toggling TBR, close the dialog and refresh the file list,
                -- matching the same behaviour as "On Hold", "Reading", etc.
                -- Note: file_dialog is a property of file_chooser, not FM.instance.
                FM.instance:addFileDialogButtons("sui_tbr", function(file, is_file, book_props)
                    local close_refresh = function()
                        local fc = FM.instance and FM.instance.file_chooser
                        local dlg = fc and fc.file_dialog
                        if dlg then UIManager:close(dlg) end
                        if fc then fc:refreshPath() end
                    end
                    return _makeTBRRow(file, is_file, book_props, close_refresh)
                end)

                -- 2. Search results (FileSearcher.onMenuHold).
                --
                -- The problem: file_dialog_added_buttons row_funcs are called as
                --   row_func(file, is_file, book_props)
                -- with no reference to the dialog being built.  In the library
                -- this is fine because close_refresh captures file_chooser by
                -- closure.  In FileSearcher, self.file_dialog (the ButtonDialog)
                -- is owned by booklist_menu — the `self` inside onMenuHold — and
                -- that object is not reachable from a plain row_func closure.
                --
                -- Solution: monkey-patch FileSearcher.onMenuHold to wrap each
                -- added row_func with a closure that captures `self` (booklist_menu)
                -- and therefore can close `self.file_dialog` correctly, exactly
                -- mirroring what close_dialog_callback does natively.
                local ok_fs, FS = pcall(require, "apps/filemanager/filemanagerfilesearcher")
                if ok_fs and FS and not FS._sui_onMenuHold_patched then
                    FS._sui_onMenuHold_patched = true
                    local orig_onMenuHold = FS.onMenuHold
                    FS.onMenuHold = function(menu_self, item)
                        -- Wrap every added row_func so it receives a close_cb
                        -- that closes menu_self.file_dialog — same as the native
                        -- close_dialog_callback defined inside orig_onMenuHold.
                        local manager = menu_self._manager
                        local orig_added = manager and manager.file_dialog_added_buttons
                        local wrapped
                        if orig_added then
                            wrapped = { index = orig_added.index }
                            for i, row_func in ipairs(orig_added) do
                                wrapped[i] = function(file, is_file, book_props)
                                    -- close_cb matches native close_dialog_callback:
                                    -- UIManager:close(self.file_dialog) where self
                                    -- is menu_self (the booklist_menu widget).
                                    local close_cb = function()
                                        UIManager:close(menu_self.file_dialog)
                                    end
                                    -- row_func signature: (file, is_file, book_props, close_cb)
                                    -- _makeTBRRow uses the 4th arg as its close_refresh_fn.
                                    return row_func(file, is_file, book_props, close_cb)
                                end
                            end
                            manager.file_dialog_added_buttons = wrapped
                        end
                        local result = orig_onMenuHold(menu_self, item)
                        -- Restore the original table so the next call gets
                        -- unmodified row_funcs (not double-wrapped).
                        if orig_added and manager then
                            manager.file_dialog_added_buttons = orig_added
                        end
                        return result
                    end

                    -- Register the TBR row_func on the FileSearcher class.
                    -- Note: row_func here accepts an optional 4th arg (close_cb)
                    -- injected by the patched onMenuHold above.
                    FS.file_dialog_added_buttons = FS.file_dialog_added_buttons or { index = {} }
                    if FS.file_dialog_added_buttons.index["sui_tbr"] == nil then
                        local row_func = function(file, is_file, book_props, close_cb)
                            return _makeTBRRow(file, is_file, book_props, close_cb)
                        end
                        table.insert(FS.file_dialog_added_buttons, row_func)
                        FS.file_dialog_added_buttons.index["sui_tbr"] =
                            #FS.file_dialog_added_buttons
                    end
                end
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
            -- Silent automatic update check — 24 h throttle.
            -- scheduleIn(3) ensures it runs after the first paint is stable
            -- and does not compete with the module preload above.
            UIManager:scheduleIn(3, function()
                local ok, Updater = pcall(require, "sui_updater")
                if ok and Updater then Updater.scheduleAutoCheck() end
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
    "sui_homescreen", "sui_foldercovers", "sui_browsemeta", "sui_updater",
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

-- ---------------------------------------------------------------------------
-- Dispatcher gesture handlers
-- ---------------------------------------------------------------------------

-- Called when the user triggers the "Go to Homescreen" gesture.
-- When inside the Reader: closes the reader and opens the Homescreen using
-- the exact same path as the native "Start with Homescreen" setting
-- (sui_patches._hs_pending_after_reader), regardless of whether that
-- setting is actually enabled.
-- When outside the Reader: equivalent to tapping the Homescreen tab.
function SimpleUIPlugin:onSimpleUIGoHomescreen()
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance then
        Patches.closeReaderToHomescreen(self)
        return true
    end
    local tabs = Config.loadTabConfig()
    self:_navigate("homescreen", self.ui, tabs, false)
    return true
end

-- Called when the user triggers the "Go to Library" gesture.
-- When inside the Reader: closes the reader and returns to the Library
-- (home_dir) without showing the Homescreen, as if "return to book folder"
-- were disabled — the FM file browser becomes the top widget.
-- When outside the Reader: equivalent to tapping the Library tab.
function SimpleUIPlugin:onSimpleUIGoLibrary()
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance then
        Patches.closeReaderToLibrary(self)
        return true
    end
    local tabs = Config.loadTabConfig()
    self:_navigate("home", self.ui, tabs, false)
    return true
end

-- Called when the user triggers the "Toggle Homescreen / Library" gesture.
-- If the Homescreen is currently open: navigates to the library (home_dir).
-- If inside the Reader: closes the reader and opens the Homescreen (same
-- path as GoHomescreen above).
-- Otherwise (library or any other view): opens the Homescreen.
function SimpleUIPlugin:onSimpleUIToggleHomeLibrary()
    local HS = package.loaded["sui_homescreen"]
    local hs_open = HS and HS._instance ~= nil
    local tabs = Config.loadTabConfig()
    if hs_open then
        self:_navigate("home", self.ui, tabs, false)
        return true
    end
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance then
        Patches.closeReaderToHomescreen(self)
        return true
    end
    self:_navigate("homescreen", self.ui, tabs, false)
    return true
end

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
    -- Remove the TBR button from the Library browser dialog and search results.
    local FM = package.loaded["apps/filemanager/filemanager"]
    if FM and FM.instance and FM.instance.removeFileDialogButtons then
        pcall(function() FM.instance:removeFileDialogButtons("sui_tbr") end)
    end
    -- Remove the TBR button from the FileSearcher table and restore the original onMenuHold.
    local FS = package.loaded["apps/filemanager/filemanagerfilesearcher"]
    if FS then
        -- Restore the original onMenuHold if it was replaced.
        if FS._sui_onMenuHold_patched and FS._sui_orig_onMenuHold then
            FS.onMenuHold = FS._sui_orig_onMenuHold
            FS._sui_orig_onMenuHold = nil
            FS._sui_onMenuHold_patched = nil
        elseif FS._sui_onMenuHold_patched then
            -- Patch was installed but orig was not saved separately
            -- (captured in the closure); just clear the flag and TBR entry.
            FS._sui_onMenuHold_patched = nil
        end
        if FS.file_dialog_added_buttons then
            local idx = FS.file_dialog_added_buttons.index
                and FS.file_dialog_added_buttons.index["sui_tbr"]
            if idx then
                pcall(function()
                    table.remove(FS.file_dialog_added_buttons, idx)
                    FS.file_dialog_added_buttons.index["sui_tbr"] = nil
                    for id, i in pairs(FS.file_dialog_added_buttons.index) do
                        if i > idx then
                            FS.file_dialog_added_buttons.index[id] = i - 1
                        end
                    end
                    if #FS.file_dialog_added_buttons == 0 then
                        FS.file_dialog_added_buttons = nil
                    end
                end)
            end
        end
    end
    local mod_rg = package.loaded["desktop_modules/module_reading_goals"]
    if mod_rg and type(mod_rg.reset) == "function" then
        pcall(mod_rg.reset)
    end
    local mod_bm = package.loaded["sui_browsemeta"]
    if mod_bm and type(mod_bm.reset) == "function" then
        pcall(mod_bm.reset)
    end
    -- Evict all plugin modules from the Lua module cache so that a hot update
    -- (files replaced on disk without restarting KOReader) picks up new code
    -- on the next plugin load, instead of reusing the old in-memory versions.
    _menu_installer = nil
    -- Nil buildTabItems so its upvalue cache (_tab_items_cache) is released,
    -- and the patch can rebuild fresh on next plugin load.
    SimpleUIPlugin.buildTabItems = nil
    -- Clear the tab-injection flag so the patch can be re-applied if the
    -- plugin is reloaded within the same KOReader session.
    local fm_menu = package.loaded["apps/filemanager/filemanagermenu"]
    if fm_menu then fm_menu.__sui_tab_patched = nil end
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
        local RUI = package.loaded["apps/reader/readerui"]
        if RUI and RUI.instance then return end

        -- If the homescreen is open, close and reopen it so HomescreenWidget:new
        -- runs with the new screen dimensions. rewrapAllWidgets cannot resize it
        -- correctly because its layout is built entirely in init(), not via
        -- wrapWithNavbar — the same reason FM uses reinit() (= rotate()) instead
        -- of a simple rewrap.
        local HS = package.loaded["sui_homescreen"]
        if HS and HS._instance then
            local hs_inst = HS._instance
            hs_inst._navbar_closing_intentionally = true
            pcall(function() UIManager:close(hs_inst) end)
            hs_inst._navbar_closing_intentionally = nil
            if not self._goalTapCallback then self:addToMainMenu({}) end
            local tabs = Config.loadTabConfig()
            Bottombar.setActiveAndRefreshFM(self, "homescreen", tabs)
            HS.show(
                function(aid) self:_navigate(aid, self.ui, Config.loadTabConfig(), false) end,
                self._goalTapCallback
            )
            return
        end

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
            -- Refresh the QA tap callback on the live homescreen instance.
            -- If the device suspended while the homescreen (or the touch menu
            -- floating on top of it) was open, HS._instance survives but its
            -- _on_qa_tap closure may reference a stale FileManager object.
            -- Reassigning it here ensures QA buttons work on the very first
            -- tap after wakeup, without requiring the user to navigate away
            -- and reopen the homescreen.
            local plugin_ref = self
            HS._instance._on_qa_tap = function(aid)
                plugin_ref:_navigate(aid, plugin_ref.ui, Config.loadTabConfig(), false)
            end
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

    -- Show a brief "closing book" notice when returning to the homescreen.
    -- Mirrors the "Opening file" InfoMessage used by ReaderUI, but smaller
    -- (no filename) and disappears on the next repaint — it does not block
    -- the homescreen load in any way.
    -- NOTE: patchReaderMenuExit (sui_patches) shows this notice earlier, while
    -- the reader menu is still open, so the user sees it immediately on tap.
    -- When that path fires it sets _closing_notice_shown; we skip the duplicate
    -- show+forceRePaint here to avoid a redundant e-ink refresh on the hot path.
    if G_reader_settings:nilOrTrue("simpleui_hs_closing_notice") then
        local return_to_folder = G_reader_settings:isTrue("navbar_hs_return_to_book_folder")
        local start_with_hs    = G_reader_settings:readSetting("start_with", "filemanager") == "homescreen_simpleui"
        -- Only show when we are actually going back to the SimpleUI homescreen.
        if start_with_hs and not return_to_folder then
            if self._closing_notice_shown then
                -- Already shown before the menu closed; just clear the flag.
                self._closing_notice_shown = nil
            else
                -- Fallback: menu patch did not fire (e.g. gesture/direct close).
                UIManager:show(InfoMessage:new{
                    text    = _("Closing book…"),
                    timeout = 0.0,
                })
                UIManager:forceRePaint()
            end
        end
    end

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
    -- Read the md5 of the closing book once — used by both Currently Reading
    -- and Cover Deck for surgical stats-cache invalidation.
    local closed_md5
    if closed_fp then
        local bs_pre = (HS._instance and HS._instance._cached_books_state)
                    or HS._cached_books_state
        local pe = bs_pre and bs_pre.prefetched_data
                and bs_pre.prefetched_data[closed_fp]
        closed_md5 = pe and pe.partial_md5_checksum
    end

    -- Currently Reading: invalidate book data so the next render shows fresh
    -- progress. Uses surgical invalidation to avoid re-opening every sidecar.
    local mod_cr = Registry.get("currently")
    currently_active = mod_cr and Registry.isEnabled(mod_cr, PFX) or false
    -- Also check coverdeck here so we know whether its full discard will
    -- supersede the surgical currently-reading invalidation below.
    local mod_cd = Registry.get("coverdeck")
    local coverdeck_active = mod_cd and Registry.isEnabled(mod_cd, PFX) or false
    if currently_active then
        -- Surgical invalidation: drop only the closed book's entry so
        -- prefetchBooks() re-reads exactly one sidecar, cache-hitting the rest.
        -- Skipped when coverdeck is also active — its block below will discard
        -- _cached_books_state entirely, making the partial work redundant.
        if not coverdeck_active then
            local function _partial_invalidate(bs)
                if not bs then return end
                -- Drop the entry for the closed book so prefetchBooks() re-reads it.
                if bs.prefetched_data and closed_fp then
                    bs.prefetched_data[closed_fp] = nil
                end
                -- current_fp will be re-resolved by the next prefetchBooks() call.
                -- Setting it to nil ensures Currently Reading does not paint
                -- stale progress data before the refresh completes.
                bs.current_fp = nil
            end
            if HS._instance then
                _partial_invalidate(HS._instance._cached_books_state)
                _partial_invalidate(HS._cached_books_state)
            end
        end
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
        needs_refresh = true
    end

    -- Cover Deck: invalidate book list and stats cache so the carousel
    -- reflects the updated reading history immediately on return to the HS.
    -- This is independent of Currently Reading — coverdeck may be active alone.
    if coverdeck_active then
        -- Surgically evict only the closed book's stats from the cache.
        -- All other carousel entries are unaffected.
        local MCD = package.loaded["desktop_modules/module_coverdeck"]
        if MCD then
            if closed_md5 and MCD.invalidateCacheForMd5 then
                -- Fast path: only evict the one book that changed.
                MCD.invalidateCacheForMd5(closed_md5)
            elseif MCD.invalidateCache then
                -- Fallback: md5 was not in prefetched_data (book outside the
                -- top-5 window, or _cached_books_state was already nil).
                -- Full flush is safe — fetchBookStats re-populates on demand.
                MCD.invalidateCache()
            end
        end
        -- Invalidate _cached_books_state so prefetchBooks() re-reads the
        -- updated history order (closed book moves to position 1 = new centre).
        -- Also reset the session index so the carousel returns to fps[1].
        if HS._instance then
            HS._instance._cached_books_state = nil
            if HS._instance._ctx_cache then
                HS._instance._ctx_cache.coverdeck_cur_idx = nil
            end
        else
            HS._cached_books_state = nil
        end
        needs_refresh = true
    end

    if not needs_refresh then return end

    local book_mod_active = currently_active or coverdeck_active

    -- Invalidate the sidecar mtime-cache entry for the closed book only when
    -- a book module is active — prefetchBooks() will re-read it on next render.
    -- Stats-only path never calls prefetchBooks, so no sidecar work is needed.
    -- Guard: only invalidate surgically when closed_fp is known; a nil fp would
    -- flush the entire cache, discarding valid entries for all other books.
    if book_mod_active and closed_fp then
        local SH = package.loaded["desktop_modules/module_books_shared"]
        if SH and SH.invalidateSidecarCache then
            SH.invalidateSidecarCache(closed_fp)
        end
    end

    if HS._instance then
        -- Determine what changed and use the narrowest refresh that covers it:
        --   books_only  → book module(s) active; prefetchBooks() must re-run.
        --   stats_only  → only stats modules active; SP.get() must re-run but
        --                  no sidecar I/O is needed (_cached_books_state kept).
        -- keep_cache is always false — we never want to reuse a stale _ctx_cache.
        HS.refresh(false, book_mod_active, not book_mod_active)
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

-- ---------------------------------------------------------------------------
-- onBookMetadataChanged — fired by KOReader when the user edits a book's
-- title, author, or other doc_props via "Book information" → "Set custom".
--
-- SimpleUI reads title/author from the sidecar's doc_props via prefetchBooks()
-- and caches the result in both the sidecar mtime-cache (_sidecar_cache in
-- module_books_shared) and the homescreen's _cached_books_state table.
--
-- Without this handler, editing metadata has no visible effect on the
-- Currently Reading (and Recent) modules: _cached_books_state is never
-- cleared, so prefetchBooks() is never re-called, and the old stale values
-- are shown even though the sidecar on disk is already correct.
--
-- Fix: when BookMetadataChanged fires, flush the sidecar cache entirely (we
-- don't know which file was edited from the event alone; prop_updated carries
-- a filepath key in some call-sites but not all, so a full flush is safest
-- and cheap — it only costs one extra DS.open on the next render), discard
-- _cached_books_state to force a full prefetchBooks() pass, and schedule a
-- homescreen refresh so the corrected metadata appears immediately.
-- ---------------------------------------------------------------------------
function SimpleUIPlugin:onBookMetadataChanged(_prop_updated)
    if self._simpleui_suspended then return end

    local HS = package.loaded["sui_homescreen"]
    if not HS then return end

    -- Flush the entire sidecar mtime-cache.  The next prefetchBooks() will
    -- re-open each sidecar and repopulate the cache from fresh disk state.
    local SH = package.loaded["desktop_modules/module_books_shared"]
    if SH and SH.invalidateSidecarCache then
        SH.invalidateSidecarCache()  -- nil → flush all
    end

    -- Discard the cached prefetch state on both the class and any live
    -- instance so _buildCtx() is forced to call prefetchBooks() from scratch.
    if HS._instance then
        HS._instance._cached_books_state = nil
    end
    HS._cached_books_state = nil

    -- Trigger a homescreen refresh (keep_cache=false, books_only=true).
    if HS._instance then
        HS.refresh(false, true)
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
    local _ = require("sui_i18n").translate
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