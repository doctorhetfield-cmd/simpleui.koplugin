-- main.lua — Simple UI
-- Plugin entry point. Registers the plugin and delegates to specialised modules.

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local logger          = require("logger")
local Dispatcher      = require("dispatcher")

-- Each simpleui module captures its own local translation proxy from sui_i18n.
-- The native package.loaded["gettext"] is never wrapped or replaced, which
-- prevents state-mutation conflicts with other plugins.
local I18n = require("infra/sui_i18n")
local _    = I18n.translate

local Config       = require("infra/sui_config")
local UI           = require("infra/sui_core")
local Bottombar    = require("screens/sui_bottombar")
local Topbar       = require("screens/sui_topbar")
local QSBar        = require("screens/sui_quicksettings_bar")
local Patches      = require("infra/sui_patches")
local WindowHooks  = require("infra/sui_window_hooks")
local Memory       = require("infra/sui_memory")
local Text         = require("infra/sui_text")
local SUISettings  = require("infra/sui_store")

-- Installer of the settings menu builders, loaded on first use by
-- _ensureMenus and dropped on teardown so a hot update loads the new one.
local _menu_installer

-- ---------------------------------------------------------------------------
-- ReaderStatistics class-table accessor
-- ---------------------------------------------------------------------------
-- KOReader loads plugins via dofile(), not require(), so the statistics plugin
-- is never registered in package.loaded under a predictable key. The path also
-- differs between platforms (Kobo: relative "plugins/…", Linux deb/Android:
-- absolute path under /usr/lib/koreader or the data dir). We try every known
-- strategy in order and cache the result so subsequent calls are free.
local _rs_module_cache  -- nil = not yet resolved, false = not available

local function _requireStatistics()
    if _rs_module_cache ~= nil then return _rs_module_cache or nil end

    -- 1. Check package.loaded for any key containing "statistics.koplugin".
    --    On Kobo the key is "plugins/statistics.koplugin/main"; on other
    --    platforms it may differ, so we scan all loaded modules.
    for key, m in pairs(package.loaded) do
        if type(key) == "string" and key:find("statistics.koplugin", 1, true) then
            _rs_module_cache = m
            return m
        end
    end

    -- 2. Scan package.path for a statistics.koplugin directory and dofile it,
    --    exactly as PluginLoader does. This works on all platforms because
    --    PluginLoader:loadPlugins() already added every plugin root to
    --    package.path before SimpleUI:init() runs.
    for path_entry in package.path:gmatch("[^;]+") do
        -- path_entry looks like "/some/dir/statistics.koplugin/?.lua"
        local plugin_root = path_entry:match("^(.*statistics%.koplugin)/")
        if plugin_root then
            local mainfile = plugin_root .. "/main.lua"
            local ok, m = pcall(dofile, mainfile)
            if ok and m then
                _rs_module_cache = m
                return m
            end
        end
    end

    -- Not available (statistics plugin disabled or not installed).
    _rs_module_cache = false
    return nil
end

local SimpleUIPlugin = WidgetContainer:new{
    name = "simpleui",

    active_action             = nil,
    _rebuild_scheduled        = false,
    _topbar_timer             = nil,
    _power_dialog             = nil,

    _orig_fc_init             = nil,

    _makeNavbarMenu           = nil,
    _makeTopbarMenu           = nil,
    _makeQuickActionsMenu     = nil,
}

-- Tap on the Reading Goals widget of a screen: sets the annual goal.
function SimpleUIPlugin._goalTapCallback()
    require("infra/sui_goals").showDialog("annual", function()
        local HS = package.loaded["screens/sui_homescreen"]
        if HS then HS.refreshNow() end
    end)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function SimpleUIPlugin:init()
    -- Conflicting plugins/patches: disable or block before UI setup.
    do
        local ok_cc, compat = pcall(require, "infra/sui_compat_check")
        if ok_cc and type(compat) == "function" then
            local stop = false
            local ok_run, result = pcall(compat)
            if ok_run then
                stop = result and true or false
            else
                logger.err("simpleui: compatibility check failed:", tostring(result))
            end
            if stop then
                return
            end
        end
    end

    -- Re-register the "open custom screen" Quick Action for every persisted
    -- Custom Screen. QA.register() only writes to an in-memory table inside
    -- features/sui_quickactions.lua, so it does not survive a KOReader
    -- restart on its own — this has to run again on every plugin init.
    --
    -- MUST run before the big init pcall below: that pcall builds the
    -- bottom bar, which calls Config.loadTabConfig(). loadTabConfig()
    -- validates every persisted tab id via QA.isRegistered() and memoizes
    -- the filtered result for the rest of the session — so if a Custom
    -- Screen's QA isn't registered yet at that first call, its tab is
    -- logged as "unknown" and dropped from the cache for good until the
    -- next restart. Registering here first, and invalidating the tabs
    -- cache afterwards as a safety net, guarantees loadTabConfig() always
    -- sees it. Isolated in its own pcall so a bug here can never take down
    -- the rest of plugin init.
    local ok_cs, err_cs = pcall(function()
        require("infra/sui_custom_screens").registerAllQuickActions()
        require("infra/sui_config").invalidateTabsCache()
    end)
    if not ok_cs then
        logger.err("simpleui: custom screens QA registration failed:", tostring(err_cs))
    end

    local ok, err = pcall(function()
        -- Ensure the simpleui settings directory tree exists before any
        -- SUISettings call.  SUISettings is lazy — its LuaSettings store is
        -- opened on first use — but LuaSettings:open() cannot create the
        -- parent directory.  If the directory is missing (fresh install, or
        -- the dir was wiped) the open will succeed but flush() will silently
        -- fail, discarding all writes for the session.
        --
        -- We create all five user-data directories here unconditionally so
        -- that (a) SUISettings can write safely and (b) a fresh install never
        -- needs to wait until the migration block to have a usable directory
        -- structure.  All five lfs.attributes calls are cheap (single stat
        -- syscall each) and lfs.mkdir is only called when the directory is
        -- actually absent, so the common steady-state cost is negligible.
        do
            local ok_ds,  DataStorage = pcall(require, "datastorage")
            local ok_lfs, lfs_early  = pcall(require, "libs/libkoreader-lfs")
            if ok_ds and ok_lfs then
                local base = DataStorage:getSettingsDir() .. "/simpleui"
                for _, sub in ipairs({
                    "", "/sui_icons", "/sui_icons/packs", "/sui_quotes",
                    "/sui_wallpapers", "/sui_presets", "/sui_presets/sui_presets_export", "/sui_presets/sui_presets_import",
                    "/backups"
                }) do
                    local path = base .. sub
                    if lfs_early.attributes(path, "mode") ~= "directory" then
                        lfs_early.mkdir(path)
                    end
                end
            end
        end

        -- Detect hot update: compare the version now on disk with what was
        -- running last session. If they differ, warn the user to restart so
        -- that all plugin modules are loaded fresh.
        local current_version
        local src = debug.getinfo(1, "S").source or ""
        local p_root = src:match("^@?(.+)/[^/]+$")
        if p_root then
            local ok, meta = pcall(dofile, p_root .. "/_meta.lua")
            if ok and type(meta) == "table" and meta.name == "simpleui" then
                current_version = meta.version
            end
        end
        if not current_version then
            local meta_ok, meta = pcall(require, "_meta")
            if meta_ok and type(meta) == "table" and meta.name == "simpleui" then
                current_version = meta.version
            end
        end
        -- Read version from SUISettings; fall back to G_reader_settings for the
        -- first boot after the Phase-4 migration (before v2 migration has run).
        local prev_version = SUISettings:get("simpleui_loaded_version")
            or G_reader_settings:readSetting("simpleui_loaded_version")
        if current_version then
            if prev_version and prev_version ~= current_version then
                logger.info("simpleui: updated from", prev_version, "to", current_version,
                    "— restart recommended")
                UIManager:scheduleIn(1, function()
                    UI.Notify.toast(string.format(
                            _("Simple UI was updated (%s → %s).\n\nA restart is recommended to apply all changes cleanly."),
                            prev_version, current_version
                        ), 6)
                end)
            end
            if prev_version ~= current_version then
                SUISettings:set("simpleui_loaded_version", current_version)
            end
        end

        -- One-time migrations: the module is loaded only while a flag is missing.
        if not G_reader_settings:isTrue("simpleui_userdata_migrated_v1")
                or not SUISettings:isTrue("simpleui_settings_migrated_v14") then
            require("infra/sui_migrations").run()
        end

        Config.applyFirstRunDefaults()
        Config.migrateOldCustomSlots()
        -- Always run sanitizeQASlots: it cleans both custom QA slot references
        -- and any stale built-in IDs from navbar_tabs.  The function is cheap —
        -- it reads a handful of settings and only writes back when it finds
        -- something invalid, so the common no-op case costs only a few reads.
        Config.sanitizeQASlots()
        -- Apply the saved UI font preference early, before any widget is built.
        -- SUIStyle is lazy (module-level init runs only when the font menu opens)
        -- so this pcall is cheap on the common path where no custom font is set.
        do
            local ok_ss, SUIStyle = pcall(require, "features/sui_style")
            if ok_ss and SUIStyle and SUIStyle.applyUIFont then
                pcall(SUIStyle.applyUIFont)
            end
        end
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
    Dispatcher:registerAction("simpleui_settings_window", {
        category = "none",
        event    = "SimpleUISettingsWindow",
        title    = _("Simple UI: Settings"),
        general  = true,
    })
    Dispatcher:registerAction("simpleui_recent_window", {
        category = "none",
        event    = "SimpleUIRecentWindow",
        title    = _("Simple UI: Recent"),
        general  = true,
    })
    Dispatcher:registerAction("simpleui_navbar_window", {
        category = "none",
        event    = "SimpleUINavbarWindow",
        title    = _("Simple UI: Navigation Bar"),
        general  = true,
    })


        -- -------------------------------------------------------------------
        -- First-run bootstrap: both the launch screen and the book-close
        -- destination default to the Homescreen.
        --
        -- The launch screen is written here, before Patches.installAll, so the
        -- setupLayout patch sees it and sets _hs_autoopen_pending = true. The
        -- normal onShow → ScreenEngine.show() → Onboarding.show() chain then
        -- handles everything.
        -- -------------------------------------------------------------------
        local _sui_first_run = not SUISettings:get("simpleui_onboarding_done")
        if _sui_first_run then
            Config.setStartWithHomescreen(true)
            Config.setBookCloseTarget(Config.BOOK_CLOSE_TARGET.HOMESCREEN)
            Config.applyFirstRunLibraryDefaults()
        end
        logger.info("simpleui[diag]: init first_run=", _sui_first_run,
            "onboarding_done=", SUISettings:get("simpleui_onboarding_done"),
            "start_with=", G_reader_settings:readSetting("start_with"),
            "has_document=", self.ui and self.ui.document ~= nil)

        if SUISettings:nilOrTrue("simpleui_enabled") then
            Patches.installAll(self)

            pcall(function() QSBar.install() end)
            -- Register the TBR button in the Library hold dialog (single book).
            -- addFileDialogButtons is the official KOReader API for this.
            -- The multi-selection button is injected via patchGetPlusDialogButtons
            -- in sui_patches.lua → patchFileManagerClass.
            UIManager:scheduleIn(0, function()
                local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
                if not (ok_fm and FM and FM.instance) then return end
                local ok_tbr, TBR = pcall(require, "modules/module_tbr")
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
                FM.instance:addFileDialogButtons("sui_tbr", function(file, is_file, book_props, close_cb)
                    local close_refresh = close_cb or function()
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

            -- Register the "More by <Author>" button in the Library hold dialog.
            -- Shown only when:
            --   • the item is a book file
            --   • Browse by Author/Series/Tags (BM) is enabled
            --   • the book has author metadata
            --   • there are ≥ 2 books by that author in the current folder tree
            -- Tapping the button closes the dialog and navigates the FM directly
            -- to the virtual author leaf, skipping the top-level Authors list.
            UIManager:scheduleIn(0, function()
                local ok_fm2, FM2 = pcall(require, "apps/filemanager/filemanager")
                if not (ok_fm2 and FM2 and FM2.instance) then return end
                local ok_bm, BM = pcall(require, "features/library/sui_library_browse")
                if not (ok_bm and BM) then return end

                -- Shared factory: returns a button row or nil.
                -- close_cb is injected by the caller (FM dialog or FS patch).
                local function _makeAuthorRow(file, is_file, book_props, close_cb)
                    if not is_file then return nil end
                    if not BM.isEnabled() then return nil end

                    -- Multi-author: navigates to the first author only.
                    local author = Text.firstLine(book_props and book_props.authors)
                    if not author then return nil end

                    local fc2 = FM2.instance and FM2.instance.file_chooser
                    local count = BM.getAuthorBookCount(fc2, author)
                    if count < 2 then return nil end

                    return {{
                        text     = string.format(_("More by %s (%d)"), author, count),
                        sui_icon = "author",
                        callback = function()
                            if close_cb then close_cb() end
                            local fm2 = FM2.instance
                            if fm2 then BM.navigateToLeaf(fm2, "author", author, { origin_file = file }) end
                        end,
                    }}
                end

                -- 1. Library browser (FileManager.showFileDialog).
                FM2.instance:addFileDialogButtons("sui_browse_author", function(file, is_file, book_props, close_cb)
                    local close_nav = close_cb or function()
                        local fc2 = FM2.instance and FM2.instance.file_chooser
                        local dlg = fc2 and fc2.file_dialog
                        if dlg then UIManager:close(dlg) end
                    end
                    return _makeAuthorRow(file, is_file, book_props, close_nav)
                end)

                -- 2. Search results (FileSearcher.onMenuHold).
                -- The existing TBR monkey-patch on FS.onMenuHold already wraps
                -- every row_func with a close_cb as the 4th argument, so our
                -- factory receives it without any further patching needed.
                local ok_fs2, FS2 = pcall(require, "apps/filemanager/filemanagerfilesearcher")
                if ok_fs2 and FS2 then
                    FS2.file_dialog_added_buttons = FS2.file_dialog_added_buttons or { index = {} }
                    if FS2.file_dialog_added_buttons.index["sui_browse_author"] == nil then
                        local row_func = function(file, is_file, book_props, close_cb)
                            return _makeAuthorRow(file, is_file, book_props, close_cb)
                        end
                        table.insert(FS2.file_dialog_added_buttons, row_func)
                        FS2.file_dialog_added_buttons.index["sui_browse_author"] =
                            #FS2.file_dialog_added_buttons
                    end
                end
            end)

            -- Register the "Book statistics" button in the Library hold dialog.
            -- Shown only for book files; opens a standalone per-book stats window.
            UIManager:scheduleIn(0, function()
                local ok_fm3, FM3 = pcall(require, "apps/filemanager/filemanager")
                if not (ok_fm3 and FM3 and FM3.instance) then return end

                local function _makeBookStatsRow(file, is_file, _book_props, close_cb)
                    if not is_file then return nil end
                    local ok_dr, DR = pcall(require, "document/documentregistry")
                    local ok_bl, BL = pcall(require, "ui/widget/booklist")
                    local is_book = (ok_dr and DR and DR:hasProvider(file))
                        or (ok_bl and BL and BL.hasBookBeenOpened(file))
                    if not is_book then return nil end
                    return {{
                        text     = _("Book statistics"),
                        sui_icon = "chart",
                        callback = function()
                            if close_cb then close_cb() end
                            require("screens/sui_stats_launcher").open("book", { filepath = file })
                        end,
                    }}
                end

                -- 1. Library browser (FileManager.showFileDialog).
                FM3.instance:addFileDialogButtons("sui_book_stats", function(file, is_file, book_props, close_cb)
                    local close_it = close_cb or function()
                        local fc3 = FM3.instance and FM3.instance.file_chooser
                        local dlg = fc3 and fc3.file_dialog
                        if dlg then UIManager:close(dlg) end
                    end
                    return _makeBookStatsRow(file, is_file, book_props, close_it)
                end)

                -- 2. Search results (FileSearcher.onMenuHold).
                -- The existing TBR monkey-patch on FS.onMenuHold already wraps
                -- every row_func with a close_cb as the 4th argument, so our
                -- factory receives it without any further patching needed.
                local ok_fs3, FS3 = pcall(require, "apps/filemanager/filemanagerfilesearcher")
                if ok_fs3 and FS3 then
                    FS3.file_dialog_added_buttons = FS3.file_dialog_added_buttons or { index = {} }
                    if FS3.file_dialog_added_buttons.index["sui_book_stats"] == nil then
                        table.insert(FS3.file_dialog_added_buttons, function(file, is_file, book_props, close_cb)
                            return _makeBookStatsRow(file, is_file, book_props, close_cb)
                        end)
                        FS3.file_dialog_added_buttons.index["sui_book_stats"] =
                            #FS3.file_dialog_added_buttons
                    end
                end
            end)

            if SUISettings:nilOrTrue("simpleui_topbar_enabled") then
                Topbar.scheduleRefresh(self, 0)
            end
            -- Pre-load the modules enabled on any screen during boot idle
            -- time so the first screen open has no perceptible freeze.
            -- scheduleIn(2) runs after the FileManager UI is fully painted
            -- and stable. Modules that are off stay unloaded.
            UIManager:scheduleIn(2, function()
                local ok, reg = pcall(require, "modules/moduleregistry")
                if not (ok and reg) then return end
                pcall(function()
                    local SE = require("engines/sui_screen_engine")
                    local pfxs = {}
                    for _i, id in ipairs(SE.knownScreenIds()) do pfxs[#pfxs + 1] = SE.getPfx(id) end
                    reg.preloadEnabled(pfxs)
                end)
            end)
            -- Silent automatic update check — 24 h throttle.
            -- scheduleIn(3) ensures it runs after the first paint is stable
            -- and does not compete with the module preload above.
            UIManager:scheduleIn(3, function()
                local ok, Updater = pcall(require, "infra/sui_updater")
                if ok and Updater then Updater.scheduleAutoCheck() end
            end)
            -- Release statistics.sqlite3 before every cloud sync (Reader
            -- menu, auto-sync, and paths with no screen on the stack).
            -- See ScreenEngine.prepareForStatsSync.
            do
                local RS = _requireStatistics()
                if RS and RS.onSyncBookStats and not RS._sui_sync_patched then
                    local orig_onSyncBookStats = RS.onSyncBookStats
                    RS._sui_orig_onSyncBookStats = orig_onSyncBookStats
                    RS._sui_sync_patched         = true
                    RS.onSyncBookStats = function(self_rs, ...)
                        local SE = package.loaded["engines/sui_screen_engine"]
                        if SE and SE.prepareForStatsSync then
                            SE.prepareForStatsSync()
                        end
                        return orig_onSyncBookStats(self_rs, ...)
                    end
                end
            end
        end
    end)
    if not ok then logger.err("simpleui: init failed:", tostring(err)) end
end

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
-- (home_dir) without showing the Homescreen — the FM file browser becomes
-- the top widget.
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
    local HS = package.loaded["screens/sui_homescreen"]
    if HS and HS._instance then
        self:_navigate("home", self.ui, Config.loadTabConfig(), false)
        return true
    end
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance then
        Patches.closeReaderToHomescreen(self)
        return true
    end
    self:_navigate("homescreen", self.ui, Config.loadTabConfig(), false)
    return true
end

function SimpleUIPlugin:onSimpleUISettingsWindow()
    local SettingsWindow = require("screens/sui_settings_window")
    SettingsWindow:show()
    return true
end

function SimpleUIPlugin:onSimpleUIRecentWindow()
    local ok, QA = pcall(require, "features/sui_quickactions")
    if ok and QA and QA.showRecentWindow then QA.showRecentWindow() end
    return true
end

-- Called when the user triggers the "Simple UI: Navigation Bar" gesture:
-- opens a floating window reproducing the configured tab row, usable from
-- anywhere (Reader, FileManager, an injected screen with no bar of its own, …).
--
-- When the current screen already has the bar injected on it (FileManager,
-- Homescreen, Collections, History, a Custom Screen, …), showing the
-- floating reproduction on top of it would be entirely redundant, so a
-- warning is shown instead and the window is never opened.
-- Bottombar.isBarInjectedOnCurrentScreen is the single source of truth for
-- that check (Bottombar.showFloatingBarWindow repeats it defensively too).
function SimpleUIPlugin:onSimpleUINavbarWindow()
    if Bottombar.isBarInjectedOnCurrentScreen() then
        UI.Notify.toast(_("The navigation bar is already available on this screen."), 2)
        return true
    end
    Bottombar.showFloatingBarWindow()
    return true
end

-- onCloseWidget fires on the plugin when the FM (self.ui) closes — both on a
-- real exit and when the FM is tearing down because the Reader is about to
-- open (self.ui.tearing_down, set by filemanager.lua:onShowingReader /
-- onSetupShowReader).
--
-- We close every currently live screen, EXCEPT one that is currently
-- soft-parked (see ScreenWidget:onShowingReader / ScreenEngine.
-- isSoftParkEnabled in engines/sui_screen_engine.lua) — closing it here
-- would immediately undo what onShowingReader just decided to keep alive
-- for a warm reader-return. By construction there is never more than one
-- parked screen at a time (onShowingReader only parks when it is the sole
-- live screen), so every other entry in this loop is guaranteed to still
-- be a real, non-parked, hidden-alive screen that needs closing exactly as
-- before — most commonly a Custom Screen the user navigated away from
-- without explicitly closing it (see ScreenEngine.liveScreenIds()'s doc
-- comment in engines/sui_screen_engine.lua). Closing each one here frees
-- its whole widget tree (module wrappers, wallpaper cache, quote widgets,
-- clock refresh timer, sqlite handle) as soon as the reader opens, rather
-- than retaining it in RAM for the whole session — and it keeps the
-- original guarantee this loop exists for: no more than one hidden-but-
-- alive screen ever receiving broadcast events (onResume,
-- onSetRotationMode, ...) meant for the reader. A parked screen's own
-- event handlers are separately guarded (see ScreenWidget:onResume /
-- onSyncBookStats) to skip their refresh work while hidden, so leaving it
-- alive here does not reopen that class of bug.
--
-- _navbar_closing_intentionally makes ScreenWidget:onCloseWidget take its
-- "preserve lightweight state" branch (that screen's own _cached_books_state
-- / _current_page / _cfg_cache — no bitmaps or widgets) for whichever id it
-- is closing, so a later ScreenEngine.show()/CustomScreens open rebuild is
-- warm-seeded rather than fully cold. The cover bitmap cache
-- (sui_config.lua's _bim_cover_cache) is untouched by this close, since it
-- lives independently of any screen widget instance.
--
-- ScreenWidget:onCloseWidget() (engines/sui_screen_engine.lua) already
-- clears the flat _instance field for whichever id it belongs to as part of
-- its own teardown, so there is no separate bookkeeping needed here beyond
-- calling UIManager:close() on each live, non-parked instance.
--
-- _raiseHSFromStack (the old, pre-2.5 warm-path stack-promotion helper in
-- sui_patches.lua) was removed for the reason above: this loop used to
-- close every live screen unconditionally, so every screen's _instance was
-- always nil by the time a raise could fire. _raiseParkedScreen (infra/
-- sui_patches.lua) is its successor, now that this loop leaves a parked
-- screen's _instance alone for it to find.

-- Mark exit early so HS reopen paths bail before _exit_code is set (that
-- only happens once the window stack is empty). Force-close soft-parked
-- screens so they cannot keep the stack non-empty and block quit.
function SimpleUIPlugin:onExit()
    UIManager._simpleui_exiting = true
    local ScreenEngine = package.loaded["engines/sui_screen_engine"]
    if ScreenEngine then
        for _, id in ipairs(ScreenEngine.liveScreenIds()) do
            local inst = ScreenEngine.getInstance(id)
            if inst then
                inst._parked = nil
                inst._navbar_closing_intentionally = true
                pcall(function() UIManager:close(inst) end)
            end
        end
    end
    return false
end

function SimpleUIPlugin:onRestart()
    UIManager._simpleui_exiting = true
    return false
end

function SimpleUIPlugin:onCloseWidget()
    -- The host UI is closing: stop this instance's clock, which would
    -- otherwise keep rescheduling itself and keep the instance alive.
    if self._topbar_timer then
        UIManager:unschedule(self._topbar_timer)
        self._topbar_timer = nil
    end
    local ScreenEngine = package.loaded["engines/sui_screen_engine"]
    if not ScreenEngine then return end
    local exiting = UIManager._simpleui_exiting or UIManager._exit_code ~= nil
    for _, id in ipairs(ScreenEngine.liveScreenIds()) do
        local inst = ScreenEngine.getInstance(id)
        if inst and (exiting or not inst._parked) then
            inst._parked = nil
            inst._navbar_closing_intentionally = true
            UIManager:close(inst)
        end
    end
end

-- Removes the file-dialog button `id` from the file manager and from the
-- file searcher's shared button table, keeping that table's index consistent.
local function _removeFileDialogButton(id, FM, FS)
    if FM and FM.instance and FM.instance.removeFileDialogButtons then
        pcall(function() FM.instance:removeFileDialogButtons(id) end)
    end
    local buttons = FS and FS.file_dialog_added_buttons
    local idx = buttons and buttons.index and buttons.index[id]
    if not idx then return end
    pcall(function()
        table.remove(buttons, idx)
        buttons.index[id] = nil
        for other, i in pairs(buttons.index) do
            if i > idx then buttons.index[other] = i - 1 end
        end
        if #buttons == 0 then FS.file_dialog_added_buttons = nil end
    end)
end

function SimpleUIPlugin:onTeardown()
    -- Flush the plugin settings store so any in-memory writes are persisted
    -- before the plugin is unloaded or KOReader exits.
    SUISettings:flush()
    if self._topbar_timer then
        UIManager:unschedule(self._topbar_timer)
        self._topbar_timer = nil
    end
    Patches.teardownAll(self)
    -- Hand the UI font slots back to the system font before the module cache
    -- is cleared.
    local style = package.loaded["features/sui_style"]
    if style and style.restoreUIFont then pcall(style.restoreUIFont) end
    pcall(function() QSBar.uninstall() end)
    I18n.uninstall()
    -- Give modules with internal caches and scheduled work a chance to
    -- release them before their package.loaded entry is cleared, so the GC
    -- can collect the old tables right away.
    Memory.reset()
    local FM = package.loaded["apps/filemanager/filemanager"]
    local FS = package.loaded["apps/filemanager/filemanagerfilesearcher"]
    -- Restore the FileSearcher's original onMenuHold if it was replaced. When
    -- the original was captured in the patch's closure, only the flag is cleared.
    if FS and FS._sui_onMenuHold_patched then
        if FS._sui_orig_onMenuHold then
            FS.onMenuHold = FS._sui_orig_onMenuHold
            FS._sui_orig_onMenuHold = nil
        end
        FS._sui_onMenuHold_patched = nil
    end
    for _, button_id in ipairs({ "sui_tbr", "sui_browse_author", "sui_book_stats" }) do
        _removeFileDialogButton(button_id, FM, FS)
    end
    -- Evict all plugin modules from the Lua module cache so that a hot update
    -- (files replaced on disk without restarting KOReader) picks up new code
    -- on the next plugin load, instead of reusing the old in-memory versions.
    _menu_installer = nil
    -- Restore ReaderStatistics:onSyncBookStats and clear any in-flight
    -- stats-sync guard so a hot reload cannot leave openStatsDB blocked.
    local RS = _requireStatistics()
    if RS and RS._sui_sync_patched then
        if RS._sui_orig_onSyncBookStats then
            RS.onSyncBookStats = RS._sui_orig_onSyncBookStats
            RS._sui_orig_onSyncBookStats = nil
        end
        RS._sui_sync_patched = nil
    end
    local ok_cfg, Cfg = pcall(require, "infra/sui_config")
    if ok_cfg and Cfg and Cfg.endStatsSyncGuard then
        Cfg.endStatsSyncGuard()
    end
    require("infra/sui_paths").unloadModules()
    -- Reclaim the unloaded plugin's heap and native buffers before the reader
    -- starts allocating.
    collectgarbage("collect")
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

        -- If the homescreen is open, close and reopen it so ScreenWidget:new
        -- runs with the new screen dimensions. rewrapAllWidgets cannot resize it
        -- correctly because its layout is built entirely in init(), not via
        -- wrapWithNavbar — the same reason FM uses reinit() (= rotate()) instead
        -- of a simple rewrap.
        local HS = package.loaded["screens/sui_homescreen"]
        if HS and HS._instance then
            local hs_inst = HS._instance
            hs_inst._navbar_closing_intentionally = true
            pcall(function() UIManager:close(hs_inst) end)
            hs_inst._navbar_closing_intentionally = nil
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
        local QA = package.loaded["features/sui_quickactions"] or require("features/sui_quickactions")
        QA.refreshWifiIcon(self)
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
        local QA = package.loaded["features/sui_quickactions"] or require("features/sui_quickactions")
        QA.refreshWifiIcon(self)
    end
end

function SimpleUIPlugin:onSuspend()
    self._simpleui_suspended = true
    self._suspended_at = os.time()
    -- Windows opened over a screen do not outlive the suspend.
    pcall(function() require("engines/sui_window").closeAll() end)
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
    -- Flush any settings written via SUISettings:setNoFlush() (currently:
    -- module_books_shared.lua's stale-books cache, refreshed in-memory on
    -- every prefetchBooks() success but never fsync'd on that hot path —
    -- see the WRITE COST / FLUSH COST notes there). Device suspend is
    -- infrequent and off the reader-return critical path, so this is a
    -- safe, low-cost point to make those writes durable across a full
    -- KOReader process restart.
    pcall(function() SUISettings:flush() end)
end

function SimpleUIPlugin:onResume()
    self._simpleui_suspended = false
    -- Time asleep is not reading time.
    local session = self._critter_session
    if session and self._suspended_at then
        session.paused = (session.paused or 0) + math.max(0, os.time() - self._suspended_at)
    end
    self._suspended_at = nil
    if SUISettings:nilOrTrue("simpleui_topbar_enabled") then
        -- Small delay to let the wakeup transition finish before refreshing
        -- the topbar. Avoids a race with ScreenWidget:onResume() and
        -- prevents the timer firing while the device is still mid-wakeup.
        Topbar.scheduleRefresh(self, 0.5)
    end
    -- Use the snapshot captured in onSuspend rather than checking RUI.instance
    -- live. On some Kobo builds the autosuspend timer fires close to a reader
    -- teardown, leaving RUI.instance nil even though the user was reading —
    -- causing the homescreen to open on wakeup instead of returning to the reader.
    local reader_active = self._simpleui_reader_was_active
    self._simpleui_reader_was_active = nil  -- consume; next suspend will repopulate

    -- "Return to Home Screen on Wakeup": unlike "Start with Homescreen" (which
    -- only ever fires when the reader was already closed), this setting must
    -- also override a reader that WAS open at suspend time. Handle it first,
    -- via the live RUI check (not the snapshot) so we don't try to close a
    -- reader that already tore itself down during the races described above.
    if SUISettings:nilOrTrue("simpleui_enabled")
            and SUISettings:isTrue("simpleui_hs_return_on_wakeup") then
        local RUI_live = package.loaded["apps/reader/readerui"]
        if RUI_live and RUI_live.instance then
            Patches.showHSAfterResume(self, true)
            return
        end
    end

    -- Outside the reader: restore the Homescreen.
    -- RS and RG have a built-in date-key guard (_stats_cache_day): they re-query
    -- automatically on a new calendar day and serve the in-memory cache otherwise.
    -- Explicit invalidation here would force full SQL queries on every wakeup
    -- even when nothing changed. Data changes from reading are handled by
    -- onCloseDocument, which invalidates those caches before the next render.
    if not reader_active then
        local HS = package.loaded["screens/sui_homescreen"]
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
            -- Use keep_cache=false so that stats modules always re-fetch from
            -- the DB on wakeup.  ScreenWidget:onResume already issued a
            -- stats-only _refresh, but this call (which fires slightly later in
            -- the same resume chain) must not override it with a keep_cache=true
            -- that reuses a potentially stale _ctx_cache.
            HS.refresh(false)
        end
        -- Any live Custom Screen needs the same follow-up full refresh HS
        -- gets above. ScreenWidget:onResume (engines/sui_screen_engine.lua)
        -- already ran for every live screen with stats_only=true, which
        -- keeps single-value stats current but leaves anything backed by a
        -- paginated grid module (TBR, Library grid, ...) stale — HS has
        -- this call to cover that gap, and a Custom Screen has no other
        -- caller asking for it, live-but-hidden underneath it or not.
        local ScreenEngine = package.loaded["engines/sui_screen_engine"]
        if ScreenEngine then
            for _, id in ipairs(ScreenEngine.liveScreenIds()) do
                if id ~= "hs" then
                    ScreenEngine.refreshScreen(id, false)
                end
            end
        end
        -- Re-open the Homescreen on wakeup when \"Start with Homescreen\" is set.
        if SUISettings:nilOrTrue("simpleui_enabled") then
            Patches.showHSAfterResume(self)
        end
    end
end

-- Reading session of a book that is being reloaded, handed to the reader that replaces it.
local _carried_session

function SimpleUIPlugin:onReaderReady()
    -- Start of the reading session, which the critter reacts to when the book closes;
    -- a reload of the same book continues the session it interrupted.
    local doc_settings = self.ui and self.ui.doc_settings
    local book_summary = doc_settings and doc_settings:readSetting("summary")
    local file = self.ui and self.ui.document and self.ui.document.file
    local carried = _carried_session
    _carried_session = nil
    if carried and file and carried.file == file then
        self._critter_session = carried
    else
        self._critter_session = {
            at = os.time(), file = file, paused = 0,
            status = book_summary and book_summary.status or nil,
        }
    end

    -- Warm the sidecar cache for the opened book from the reader's own
    -- in-memory settings, so that onCloseDocument has access to its
    -- pre-session summary state even if the file browser didn't scan it
    -- recently (e.g. direct boot to book). No sidecar re-read is needed.
    local RUI = package.loaded["apps/reader/readerui"]
    local ui  = RUI and RUI.instance
    local fp  = ui and ui.document and ui.document.file
    local ds  = ui and ui.doc_settings
    local SH  = package.loaded["modules/module_books_shared"]
    if not (fp and ds and SH and SH._cachePut) then return end

    local doc_props = ds:readSetting("doc_props")
    SH._cachePut(fp, ds.source_candidate, {
        percent              = ds:readSetting("percent_finished") or 0,
        title                = doc_props and doc_props.title,
        authors              = doc_props and doc_props.authors,
        doc_pages            = ds:readSetting("doc_pages"),
        partial_md5_checksum = ds:readSetting("partial_md5_checksum"),
        summary              = ds:readSetting("summary"),
    })
end

-- Makes the critter react to what the reading session that ends now left behind:
-- a book finished and the session itself, and notes the session for the day's
-- challenge. Does nothing without a session.
function SimpleUIPlugin:_recordCritterReactions()
    local session = self._critter_session
    self._critter_session = nil
    local doc_settings = self.ui and self.ui.doc_settings
    if not (session and doc_settings) then return end
    local summary = doc_settings:readSetting("summary")
    local props = doc_settings:readSetting("doc_props")
    local ok, err = pcall(function()
        local Reactions = require("modules/critter/reactions")
        for _i, reaction in ipairs(Reactions.closeReactions(
                session, summary and summary.status, props and props.title, os.time())) do
            Reactions.record(reaction.kind, reaction.data)
        end
        -- A session started in time may meet a deadline challenge.
        local Challenge = require("modules/critter/challenge")
        local state = Challenge.read()
        local updated = Challenge.sessionStarted(state, session.at)
        if updated ~= state then Challenge.write(updated) end
    end)
    if not ok then logger.warn("simpleui: critter reactions failed: " .. tostring(err)) end
end

function SimpleUIPlugin:onCloseDocument()
    -- Consume _closing_via_gesture unconditionally before any early return,
    -- so the flag never leaks to a subsequent close if this handler bails out
    -- (e.g. while the plugin is suspended).
    local via_gesture = self._closing_via_gesture
    self._closing_via_gesture = nil

    -- Consume the reload-suppress flag once, up front (rather than deep
    -- inside the notice block below), so it is also visible to the
    -- per-screen visual-refresh guard near the end of this function. Set by
    -- patchReloadDocument just before ReaderUI:reloadDocument() runs —
    -- covers font size, margins, line spacing, and any other CRE setting
    -- change that triggers a background reflow + seamless reload. Those
    -- calls close and reopen ReaderUI in the same synchronous call chain;
    -- CloseDocument fires exactly the same as on a real close, so we need
    -- this flag to tell the two apart.
    local is_reload = self._suppress_closing_notice
    self._suppress_closing_notice = nil

    if is_reload then
        _carried_session = self._critter_session
    end
    if self._simpleui_suspended then return end
    if not is_reload then self:_recordCritterReactions() end
    local ScreenEngine = package.loaded["engines/sui_screen_engine"]
    if not ScreenEngine then return end

    local Perf = require("infra/sui_perf")
    if not is_reload then Perf.begin("onCloseDocument") end

    -- Filepath of the book that just closed. readhistory.hist[1] is still the
    -- closing book at this point (the reader has not yet handed control back
    -- to the FM, so the history order has not been updated). Computed here,
    -- ahead of the notice block below, so both the cover-transition call and
    -- the later stats-invalidation block (which also needs it) share one
    -- lookup instead of repeating it.
    local rh        = package.loaded["readhistory"]
    local closed_fp = rh and rh.hist and rh.hist[1] and rh.hist[1].file

    -- Cover Transition (close side): show the book cover instead of the
    -- plain "Closing book…" notice below, for a less jarring exit from the
    -- reader. Off by default; only takes effect for closes that would have
    -- shown the notice anyway (an internal reload never reaches this point
    -- with is_reload false, so it is never affected). If no cover is found
    -- (e.g. CoverBrowser not installed, or the book was never indexed) this
    -- silently falls through to the ordinary text notice further down.
    local cover_shown = false
    if not is_reload then
        if Patches and Patches.CoverTransition and Patches.CoverTransition.isCloseEnabled() then
            local orig_show = WindowHooks.origShow()
            local live_doc  = self.ui and self.ui.document
            local ok_ct, shown = pcall(Patches.CoverTransition.show, closed_fp, orig_show, live_doc)
            cover_shown = ok_ct and shown
            if cover_shown then
                Patches.CoverTransition.scheduleAutoClose(0.5)
            end
        end
    end

    -- Show a brief "closing book" notice whenever a book is closed. This is
    -- a single global toggle, not a per-screen one — it fires regardless of
    -- which screen the user lands on afterwards, so it stays keyed under the
    -- legacy simpleui_hs_ prefix it was given before Custom Screens existed
    -- (renaming the stored setting key would need its own migration for a
    -- pure naming detail, so it is left as-is here).
    -- onCloseDocument is the single, authoritative place for this: it fires on
    -- every close path (menu, gesture, or any direct call to ReaderUI:onClose).
    --
    -- How the three modes work:
    --   "always"       — show on every book close, regardless of how it was
    --                    triggered or where the user ends up afterwards.
    --   "gesture_only" — show only when the close was triggered by a SimpleUI
    --                    gesture (GoHomescreen, GoLibrary, ToggleHomeLibrary).
    --                    Those paths set plugin._closing_via_gesture = true
    --                    immediately before readerui:onClose(). We read and
    --                    clear that flag above. Menu-triggered closes never set
    --                    the flag — no KOReader internals patched.
    --   "never"        — never show.
    --
    -- The notice is shown while readerui.dialog is still on the widget stack
    -- (i.e. the book page is still the background). forceRePaint pushes it to
    -- the e-ink screen immediately; without it _repaint() only runs on the next
    -- event-loop tick, after closeDocument() and UIManager:close(dialog) have
    -- already run, so the notice would appear over whatever's underneath far
    -- too late.
    -- timeout=0.0 schedules the InfoMessage to close itself on the next tick.
    --
    -- Migration: if simpleui_hs_closing_notice_mode is absent, fall back to the
    -- old boolean simpleui_hs_closing_notice. Explicit false → "never"; anything
    -- else (true or unset) → "always". Default when neither key exists is "always".
    do
        local notice_mode = SUISettings:readSetting("simpleui_hs_closing_notice_mode")
        if not notice_mode then
            notice_mode = SUISettings:readSetting("simpleui_hs_closing_notice") == false
                and "never" or "always"
        end

        local suppress = is_reload or cover_shown

        if (notice_mode == "always" and not suppress)
                or (notice_mode == "gesture_only" and via_gesture) then
            -- UIManager:show() respects honor_silent_mode on InfoMessage, which
            -- means the notice is silently dropped when the Dispatcher has put
            -- the UIManager into silent mode to batch multiple gesture actions.
            -- Bypass silent mode for the sticky show + repaint, then restore.
            local was_silent = UIManager:isInSilentMode()
            if was_silent then UIManager:setSilentMode(false) end
            -- Hold the widget so closeClosingNotice (sui_patches) can dismiss it
            -- when the Homescreen becomes visible. timeout=0.0 is a safety net
            -- for paths that never raise the HS.
            self._closing_notice = UI.Notify.sticky(_("Closing book…"), { timeout = 0.0 })
            if was_silent then UIManager:setSilentMode(true) end
        end
    end

    -- Every screen id worth considering for this close event: the built-in
    -- Homescreen (always) plus any Custom Screen with tracked state this
    -- session — live right now, or closed-but-warm (see
    -- ScreenEngine.knownScreenIds()). A stats/currently-reading/coverdeck
    -- module can be enabled on any of them, each with its own pfx, so unlike
    -- the single-screen era this cannot be decided from one flat check.
    local screen_ids = ScreenEngine.knownScreenIds()

    -- Registry is already loaded (moduleregistry was pre-loaded at boot via
    -- scheduleIn(2)); use package.loaded to avoid a pcall on the hot path.
    -- Fall back to pcall only if it hasn't been loaded yet.
    local Registry = package.loaded["modules/moduleregistry"]
    if not Registry then
        local ok, reg = pcall(require, "modules/moduleregistry")
        if not ok then return end
        Registry = reg
    end

    -- Only call pcall(require) for modules that are actually enabled.
    -- Registry.get + Registry.isEnabled are cheap table lookups; the module
    -- is guaranteed already loaded when enabled (required by its screen on open).

    -- closed_fp (filepath of the book that just closed) was already resolved
    -- near the top of this function, ahead of the Cover Transition / notice
    -- block, which also needs it.

    -- Per-screen module-active flags, keyed by screen id. Each known screen
    -- can have a different set of modules enabled (different pfx) — computed
    -- once per screen here, then reused by every block below instead of each
    -- block re-deciding activity against a single hardcoded pfx.
    local mod_rg   = Registry.get("reading_goals")
    local mod_cr   = Registry.get("currently")
    local mod_cd   = Registry.get("coverdeck")

    local stats_active_for     = {}
    local currently_active_for = {}
    local coverdeck_active_for = {}
    local any_stats_active     = false
    local any_currently_active = false
    local any_coverdeck_active = false

    for _, id in ipairs(screen_ids) do
        local pfx = ScreenEngine.getPfx(id)

        local s_active = (mod_rg and Registry.isEnabled(mod_rg, pfx))
            or Registry.wantsData(pfx, "stats")
        stats_active_for[id] = s_active
        any_stats_active = any_stats_active or s_active

        local c_active  = mod_cr and Registry.isEnabled(mod_cr, pfx) or false
        local cd_active = mod_cd and Registry.isEnabled(mod_cd, pfx) or false
        currently_active_for[id] = c_active
        coverdeck_active_for[id] = cd_active
        any_currently_active = any_currently_active or c_active
        any_coverdeck_active = any_coverdeck_active or cd_active
    end

    -- Tracks, per screen id, whether that screen has pending work below —
    -- the per-id equivalent of the old single `needs_refresh` flag.
    local needs_refresh_for = {}
    local any_needs_refresh = false

    -- Invalidate the shared stats provider when any known screen has a stats
    -- module active. One invalidation covers both reading_goals and
    -- reading_stats — they both read ctx.stats which is populated from
    -- StatsProvider.get(). StatsProvider is a single provider shared by every
    -- screen (not per-screen state), so this whole block still runs at most
    -- once per close, regardless of how many screens use it.
    --
    -- A reading session always changes the DB-derived time series. The
    -- finished-book counts come from the provider's ledger, which is synced
    -- from the closed book's live settings — they stay valid until
    -- UIManager:close() → onCloseWidget, which runs after this handler — and
    -- are recounted only when that sync changed the ledger.
    if any_stats_active then
        local SP = package.loaded["modules/module_stats_provider"]
        -- Fall back to pcall require: the module may not be in package.loaded yet
        -- if no screen was opened this session (e.g. the user went straight
        -- from boot to the reader without visiting any SimpleUI screen).
        if not SP then
            local ok_sp, m = pcall(require, "modules/module_stats_provider")
            if ok_sp then SP = m end
        end
        if SP then
            if closed_fp then
                SP.syncClosedBook(closed_fp)
                SP.invalidateTimeSeries()
            else
                SP.invalidate()
            end
            for _, id in ipairs(screen_ids) do
                if stats_active_for[id] then
                    needs_refresh_for[id] = true
                    any_needs_refresh = true
                end
            end
        end
    end

    -- Currently Reading shows the current book's cover, title, author and
    -- progress (percent_finished). All of these come from a screen's own
    -- _cached_books_state. When the reader closes, percent_finished has
    -- changed for the closed book. Instead of discarding the entire
    -- _cached_books_state (which forces prefetchBooks() to re-open every
    -- sidecar), we do a surgical invalidation: only the entry for the closed
    -- book is removed from prefetched_data. prefetchBooks() will then re-open
    -- exactly one sidecar (the closed book) and reuse the mtime-validated
    -- sidecar cache for all other entries.
    -- Read the md5 of the closing book once — used by both Currently Reading
    -- and Cover Deck for surgical stats-cache invalidation. Tries every known
    -- screen's cache in turn (whichever one actually has the closed book's
    -- entry); a miss on all of them just falls back to the full-flush path
    -- further down, so trying more than one screen here is a pure bonus, not
    -- a correctness requirement.
    local closed_md5
    if closed_fp then
        for _, id in ipairs(screen_ids) do
            local bs_pre = ScreenEngine.getCachedBooksState(id)
            local pe = bs_pre and bs_pre.prefetched_data
                    and bs_pre.prefetched_data[closed_fp]
            if pe and pe.partial_md5_checksum then
                closed_md5 = pe.partial_md5_checksum
                break
            end
        end
    end

    -- Currently Reading: invalidate book data so the next render shows fresh
    -- progress. Always a full discard of the cached book-list state (never a
    -- surgical per-entry patch): current_fp itself may have changed — the
    -- just-closed book might not even be the one that becomes "current" next
    -- (e.g. a different book was already ahead in ReadHistory) — and only a
    -- fresh prefetchBooks() pass can re-resolve that. Mirrors the Cover Deck
    -- block below exactly, so both book-list modules stay correct regardless
    -- of which one (if any) is active alongside the other on a given screen.
    if any_currently_active then
        for _, id in ipairs(screen_ids) do
            if currently_active_for[id] then
                local inst = ScreenEngine.getInstance(id)
                if inst then
                    inst._cached_books_state = nil
                else
                    -- Not currently visible — the flat, id-level state would
                    -- otherwise be reused verbatim (current_fp included) on
                    -- the next ScreenWidget:new{}. Discard it so that open is
                    -- forced to call prefetchBooks() from scratch.
                    ScreenEngine.setCachedBooksState(id, nil)
                end
                needs_refresh_for[id] = true
                any_needs_refresh = true
            end
        end
        -- Surgical invalidation, mirroring the Cover Deck block below: evict
        -- only the closed book's cached stats when its md5 is known, falling
        -- back to a full flush otherwise.
        local MC = package.loaded["modules/module_currently"]
        if MC then
            if closed_md5 and MC.invalidateCacheForMd5 then
                MC.invalidateCacheForMd5(closed_md5)
            elseif MC.invalidateCache then
                MC.invalidateCache()
            end
        end
    end

    -- Cover Deck: invalidate book list and stats cache so the carousel
    -- reflects the updated reading history immediately on return to whichever
    -- screen shows it. This is independent of Currently Reading — coverdeck
    -- may be active alone.
    if any_coverdeck_active then
        -- Surgically evict only the closed book's stats from the cache.
        -- All other carousel entries are unaffected. module_coverdeck.lua's
        -- cache is shared across every screen (keyed by md5, not by screen
        -- id), so this runs once regardless of how many screens show it.
        local MCD = package.loaded["modules/module_coverdeck"]
        if MCD then
            if closed_md5 and MCD.invalidateCacheForMd5 then
                -- Fast path: only evict the one book that changed.
                MCD.invalidateCacheForMd5(closed_md5)
            elseif MCD.invalidateCache then
                -- Fallback: md5 was not found in any known screen's
                -- prefetched_data (book outside the top-5 window, or every
                -- _cached_books_state was already nil). Full flush is safe —
                -- fetchBookStats re-populates on demand.
                MCD.invalidateCache()
            end
        end
        -- Invalidate _cached_books_state so prefetchBooks() re-reads the
        -- updated history order (closed book moves to position 1 = new centre)
        -- on the next deferred _refresh() tick. Also reset the session index
        -- so the carousel returns to fps[1] once fresh data lands.
        --
        -- Deliberately mirrors SP.invalidate() in module_stats_provider.lua:
        -- that function clears only _cache_day (the "needs recompute" flag)
        -- and explicitly does NOT touch _cache, so SP.getStale() keeps
        -- returning the previous day's numbers for one frame after a
        -- reading session ends — accepted as fine, since SP.get() overwrites
        -- everything ~50ms later anyway. Earlier versions of this code tried
        -- to eagerly fix a live screen's _ctx_cache.current_fp/recent_fps
        -- right here via SH.peekRecentBooks(), to avoid the carousel/title
        -- showing the previous book for that one frame — but that traded a
        -- few stat syscalls per close for a guarantee that wasn't actually
        -- needed: exactly like the stats case, _ctx_cache.current_fp/
        -- recent_fps being one step stale for ~50ms is harmless, since the
        -- deferred _refresh() tick (see _refresh()'s scheduleIn(0.05, ...) in
        -- engines/sui_screen_engine.lua) unconditionally re-resolves both
        -- from a real SH.prefetchBooks() call and repaints. So: touch
        -- nothing here, exactly like SP.invalidate() touches nothing in
        -- _cache.
        for _, id in ipairs(screen_ids) do
            if coverdeck_active_for[id] then
                local inst = ScreenEngine.getInstance(id)
                if inst then
                    inst._cached_books_state = nil
                    if inst._ctx_cache then
                        inst._ctx_cache.coverdeck_cur_idx = nil
                    end
                else
                    -- Not live: discard the flat cached state so the next
                    -- open is forced to call prefetchBooks() from scratch.
                    -- Without this, the stale _cached_books_state (non-nil)
                    -- causes _buildCtx() to skip prefetchBooks(), leaving the
                    -- carousel with the old history order until the user
                    -- manually refreshes.
                    ScreenEngine.setCachedBooksState(id, nil)
                end
                needs_refresh_for[id] = true
                any_needs_refresh = true
            end
        end
    end

    Perf.mark("onCloseDocument invalidation done")
    if not any_needs_refresh then return end

    -- Invalidate the sidecar mtime-cache entry for the closed book once, if
    -- any screen has a book module (Currently Reading / Cover Deck) active —
    -- prefetchBooks() will re-read it on next render. Stats-only screens
    -- never call prefetchBooks, so no sidecar work is needed for them.
    -- Guard: only invalidate surgically when closed_fp is known; a nil fp would
    -- flush the entire cache, discarding valid entries for all other books.
    local any_book_mod_active = any_currently_active or any_coverdeck_active
    if any_book_mod_active and closed_fp then
        local SH = package.loaded["modules/module_books_shared"]
        if SH and SH.invalidateSidecarCache then
            SH.invalidateSidecarCache(closed_fp)
        end
    end

    -- Refresh (or flag for refresh) every screen with pending work, using the
    -- narrowest refresh that covers what changed on that particular screen.
    for _, id in ipairs(screen_ids) do
        if needs_refresh_for[id] then
            local book_mod_active = currently_active_for[id] or coverdeck_active_for[id]
            local inst = ScreenEngine.getInstance(id)
            if inst then
                if is_reload then
                    -- Defensive branch, not expected to trigger in normal
                    -- operation. It used to guard against a real hazard: the
                    -- old ReaderUI being torn down and a new one shown in its
                    -- place in the same synchronous call chain
                    -- (ReaderUI:reloadDocument, triggered by a font size,
                    -- margin, line spacing, or other CRE setting change),
                    -- with a ScreenWidget instance still parked, hidden,
                    -- under the reader from before the soft-park architecture
                    -- was retired. Refreshing it there would have
                    -- UIManager:setDirty()'d it while it was briefly the
                    -- topmost widget (old reader gone, new reader not shown
                    -- yet), producing a visible flash to this screen and
                    -- back.
                    --
                    -- Since ScreenWidget:onShowingReader() now closes the
                    -- screen the moment a book is opened (see
                    -- engines/sui_screen_engine.lua), ScreenEngine.getInstance(id)
                    -- is nil throughout the entire time a book is open —
                    -- including across a reload — so `inst` above should
                    -- never be truthy here anymore. Kept as a safety net
                    -- rather than removed, in case a future change
                    -- reintroduces a scenario where a screen instance
                    -- survives underneath the reader.
                    --
                    -- Nothing on this screen has actually changed: the book's
                    -- status/percent_finished are unaffected by a reformat,
                    -- and the reading session survives the reload via
                    -- PreserveCurrentSession (see readerui.lua:reloadDocument).
                    -- So just flag the widget for a refresh the next time it
                    -- genuinely becomes visible, instead of repainting it now.
                    ScreenEngine.setNeedsRefresh(id)
                else
                    -- Determine what changed and use the narrowest refresh that
                    -- covers it:
                    --   books_only  → book module(s) active; prefetchBooks() must re-run.
                    --   stats_only  → only stats modules active; SP.get() must re-run but
                    --                  no sidecar I/O is needed (_cached_books_state kept).
                    -- keep_cache is always false — we never want to reuse a stale _ctx_cache.
                    ScreenEngine.refreshScreen(id, false, book_mod_active, not book_mod_active)
                end
            else
                -- Not currently visible — flag it for rebuild on next open.
                ScreenEngine.setNeedsRefresh(id)
            end
        end
    end

end

-- ---------------------------------------------------------------------------
-- onBookMetadataChanged — fired by KOReader when the user edits a book's
-- title, author, or other doc_props via "Book information" → "Set custom".
--
-- SimpleUI reads title/author from the sidecar's doc_props via prefetchBooks()
-- and caches the result in both the sidecar mtime-cache (_sidecar_cache in
-- module_books_shared) and each live screen's own _cached_books_state table.
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
-- _cached_books_state to force a full prefetchBooks() pass, and refresh every
-- live screen (built-in Homescreen and any open Custom Screen) so the
-- corrected metadata appears immediately wherever it's shown.
-- ---------------------------------------------------------------------------
function SimpleUIPlugin:onBookMetadataChanged(_prop_updated)
    if self._simpleui_suspended then return end

    local ScreenEngine = package.loaded["engines/sui_screen_engine"]
    if not ScreenEngine then return end

    -- Flush the entire sidecar mtime-cache.  The next prefetchBooks() will
    -- re-open each sidecar and repopulate the cache from fresh disk state.
    local SH = package.loaded["modules/module_books_shared"]
    if SH and SH.invalidateSidecarCache then
        SH.invalidateSidecarCache()  -- nil → flush all
    end

    -- Discard the cached prefetch state and refresh (keep_cache=false,
    -- books_only=true) on every screen that is currently live, so
    -- _buildCtx() is forced to call prefetchBooks() from scratch on each.
    for _, id in ipairs(ScreenEngine.liveScreenIds()) do
        local screen = ScreenEngine.getInstance(id)
        if screen then
            screen._cached_books_state = nil
            screen:_refresh(false, true)
        end
    end
end

function SimpleUIPlugin:onFrontlightStateChanged()
    if self._simpleui_suspended then return end
    if not SUISettings:nilOrTrue("simpleui_topbar_enabled") then return end
    Topbar.scheduleRefresh(self, 0)
end

function SimpleUIPlugin:onBluetoothStateChanged(args)
    if self._simpleui_suspended then return end
    if not SUISettings:nilOrTrue("simpleui_topbar_enabled") then return end
    local state
    if type(args) == "table" and type(args.state) == "boolean" then state = args.state end
    require("screens/sui_bluetooth").setState(state)
    Topbar.scheduleRefresh(self, 0)
end

function SimpleUIPlugin:onCharging()
    if self._simpleui_suspended then return end
    if not SUISettings:nilOrTrue("simpleui_topbar_enabled") then return end
    Topbar.scheduleRefresh(self, 0)
end

function SimpleUIPlugin:onNotCharging()
    if self._simpleui_suspended then return end
    if not SUISettings:nilOrTrue("simpleui_topbar_enabled") then return end
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

function SimpleUIPlugin:_doWifiToggle()
    local QA = package.loaded["features/sui_quickactions"] or require("features/sui_quickactions")
    QA.doWifiToggle(self)
end

function SimpleUIPlugin:_doRotateScreen()
    Bottombar.doRotateScreen()
end

function SimpleUIPlugin:_showFrontlightDialog()
    local QA = package.loaded["features/sui_quickactions"] or require("features/sui_quickactions")
    QA.showFrontlightDialog(self)
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
-- Main menu entry and settings menus
-- ---------------------------------------------------------------------------

-- Tools > Simple UI opens the SUI Settings Window. "tools" sorts the entry in
-- the Tools section of the KOReader main menu; the dedicated key "simpleui"
-- avoids colliding with the section table.
function SimpleUIPlugin:addToMainMenu(menu_items)
    local _ = require("infra/sui_i18n").translate
    menu_items.simpleui = {
        sorting_hint = "tools",
        text         = _("Simple UI"),
        callback     = function()
            require("screens/sui_settings_window"):show()
        end,
    }
end

-- Sets the settings menu builders of screens/sui_menu (plugin.make*,
-- _makeNavbarMenu, ...) on this instance, loading the installer on first use.
function SimpleUIPlugin:_ensureMenus()
    if self._makeNavbarMenu then return end
    if not _menu_installer then
        local ok, result = pcall(require, "screens/sui_menu")
        if not ok then
            logger.err("simpleui: sui_menu failed to load: " .. tostring(result))
            return
        end
        _menu_installer = result
        _menu_installer(SimpleUIPlugin)
    end
    self:_buildMenus()
end

return SimpleUIPlugin