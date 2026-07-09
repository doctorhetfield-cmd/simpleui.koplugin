-- sui_patches.lua — SimpleUI
-- Monkey-patches applied to KOReader classes on plugin load.
-- All patches are reversible; teardownAll() restores every original function.

local UIManager = require("ui/uimanager")
local Device    = require("device")
local Screen    = Device.screen
local logger    = require("logger")
local _         = require("sui_i18n").translate

local Config    = require("sui_config")
local UI        = require("sui_core")
local Bottombar = require("sui_bottombar")
local SUISettings = require("sui_store")

-- Lazy: only needed on D-pad devices, inside gesture event handlers.
local _FocusManager
local function FocusManager()
    _FocusManager = _FocusManager or require("ui/widget/focusmanager")
    return _FocusManager
end

-- Lazy: only needed inside patchFileManagerClass callbacks, not at load time.
local _Titlebar
local function Titlebar()
    _Titlebar = _Titlebar or require("sui_titlebar")
    return _Titlebar
end

local M = {}

-- ---------------------------------------------------------------------------
-- Module-level state
-- ---------------------------------------------------------------------------

-- Reused for UIManager.show calls that have no extra arguments.
local _EMPTY = {}

-- True after the first FM show on boot; prevents the homescreen auto-open
-- from firing more than once. Reset in teardownAll so re-enable works cleanly.
local _hs_boot_done = false

-- Set when ReaderUI closes with "Start with Homescreen" active.
-- Makes UIManager.show defer the FM paint until the homescreen is on top,
-- eliminating the visible flash between reader and homescreen.
local _hs_pending_after_reader = false  -- kept for reset in teardown only

-- Cached value of the "start_with" setting. Updated whenever the user changes
-- the setting so UIManager.show / close avoid repeated settings reads.
-- Initialised lazily (nil until first read via isStartWithHS) so that
-- applyFirstRunDefaults() in main.lua:init() has a chance to write
-- "start_with" before we latch it for the boot session.
local _start_with_hs = nil

-- Navbar keyboard-focus state (D-pad devices only).
-- _navbar_kb_capture: the transparent InputContainer on the UIManager stack,
--   or nil when keyboard focus is inactive.
-- _navbar_kb_idx: 1-based index of the currently focused tab.
-- _navbar_kb_return_fn: optional callback invoked when the user exits focus
--   (e.g. the homescreen restores its own focus instead of the file-chooser).
local _navbar_kb_capture   = nil
local _navbar_kb_idx       = 1
local _navbar_kb_return_fn = nil

-- Set once by patchFileManagerClass so external callers (HomescreenWidget)
-- can trigger navbar keyboard focus via M.enterNavbarKbFocus().
local _enterNavbarKbFocus_fn = nil

-- Coalescence flag: true while a navpager arrow-update is already scheduled,
-- so duplicate scheduleIn(0) calls are dropped within the same event-loop tick.
local _navpager_rebuild_pending = false

local _raiseHSFromStack  -- forward declaration; defined below near closeReaderToHomescreen

-- Always points at the most recently created SimpleUIPlugin instance.
-- KOReader's FileManager:init() creates a brand-new plugin object on every
-- FM (re)instantiation (PluginLoader:createPluginInstance), but
-- patchFileManagerClass only re-installs the FileManager.setupLayout wrapper
-- once per session (see setup_already_patched below) -- so closures defined
-- inside that one-time installation would otherwise stay bound to whichever
-- plugin instance happened to exist the first time it ran. Any of those
-- closures that need "the current plugin" must resolve it via _live_plugin
-- (updated on every patchFileManagerClass call) instead of using their
-- captured `plugin` upvalue directly. This mirrors the existing
-- UIManager._simpleui_close_plugin pattern used by patchUIManagerClose.
local _live_plugin = nil

-- Ensure the goal-tap callback is initialised. Called before any HS.show()
-- or _raiseHSFromStack() that may need it. Idempotent: addToMainMenu is a
-- no-op once _goalTapCallback has been set.
local function _ensureGoalCallback(plugin_ref)
    if not plugin_ref._goalTapCallback then
        plugin_ref:addToMainMenu({})
    end
end

-- Build the standard QA-tap callback closure for the given plugin reference.
local function _makeQaTap(plugin_ref)
    return function(aid)
        plugin_ref:_navigate(aid, plugin_ref.ui, Config.loadTabConfig(), false)
    end
end

-- Cold-path HS show: activate the homescreen tab in the FM bar, then call
-- HS.show() with the standard callbacks.  Sets _navbar_prev_action on the
-- freshly-created instance.
-- Caller must guard against HS._instance already being set (warm path).
local function _showHSCold(plugin_ref, HS_ref, prev_action)
    local tabs = Config.loadTabConfig()
    Bottombar.setActiveAndRefreshFM(plugin_ref, "homescreen", tabs)
    _ensureGoalCallback(plugin_ref)
    HS_ref.show(_makeQaTap(plugin_ref), plugin_ref._goalTapCallback)
    local inst = HS_ref._instance
    if inst then inst._navbar_prev_action = prev_action end
end

-- Close all non-fullscreen widgets on the stack except the FM.
-- Used before restoring the homescreen so orphaned toasts/toasters are gone.
local function _closeOrphanedPopups(fm_ref, hs_inst)
    local stack    = UI.getWindowStack()
    local to_close = {}
    for _, entry in ipairs(stack) do
        local w = entry.widget
        if w and w ~= fm_ref and not w.covers_fullscreen
                and not (hs_inst and w == hs_inst) then
            to_close[#to_close + 1] = w
        end
    end
    for _, w in ipairs(to_close) do UIManager:close(w) end
end

-- Show an InfoMessage using UIManager directly (avoids capturing the local
-- UIManager upvalue inside patchCollections closures where it may be stale).
local function _showInfoMsg(text, timeout)
    local ok, IM = pcall(require, "ui/widget/infomessage")
    if ok and IM then
        UIManager:show(IM:new{ text = text, timeout = timeout or 2 })
    end
end

-- ---------------------------------------------------------------------------
-- Private helpers
-- ---------------------------------------------------------------------------

local function isStartWithHS()
    if _start_with_hs == nil then
        _start_with_hs = G_reader_settings:readSetting("start_with", "filemanager") == "homescreen_simpleui"
    end
    return _start_with_hs
end

-- Linear search used in low-frequency paths (boot, resume).
-- Hot paths build a set with tabsToSet() instead.
local function tabInTabs(id, tabs)
    for _, v in ipairs(tabs) do
        if v == id then return true end
    end
    return false
end

-- Converts a tab list to a hash-set for O(1) membership tests.
local function tabsToSet(tabs)
    local s = {}
    for _, v in ipairs(tabs) do s[v] = true end
    return s
end

-- Returns the live FM instance from package.loaded, or nil.
local function liveFM()
    local mod = package.loaded["apps/filemanager/filemanager"]
    return mod and mod.instance
end

-- Returns the live homescreen module from package.loaded, or nil.
local function liveHS()
    return package.loaded["sui_homescreen"]
end

-- ---------------------------------------------------------------------------
-- FileManager class patches
-- Patches setupLayout, initGesListener, FileChooser.init, and FileChooser.changeToPath.
-- Also wires up the per-instance event handlers: onShow, onCloseAllMenus,
-- onPathChanged, onSetRotationMode, and the D-pad navbar keyboard focus system.
-- ---------------------------------------------------------------------------

function M.patchFileManagerClass(plugin)
    local FileManager      = require("apps/filemanager/filemanager")

    -- Refresh the shared "live plugin" pointer on every call -- including
    -- when setup_already_patched is true below.  This is what lets the
    -- one-time-installed setupLayout/onShow/onPathChanged closures (which
    -- captured a `plugin` upvalue from the very first installation) find
    -- their way back to the current instance instead of silently operating
    -- on a stale one after the FM is recreated (e.g. after returning from
    -- the reader, after a rotation reinit, or around a suspend/resume cycle
    -- that tears down and rebuilds the FileManager).
    _live_plugin = plugin

    -- Guard: only wrap FileManager.setupLayout once per session.
    --
    -- patchFileManagerClass is called by installAll on every FM lifecycle event
    -- (including when a new FM instance is created after returning from the reader).
    -- Without this guard, each call adds another wrapper_A on top of the existing
    -- chain.  The outermost wrapper_A calls wrapWithNavbar AFTER patchWallpaperFM's
    -- wrapper_B has already cleared backgrounds, producing a fresh outer
    -- FrameContainer with COLOR_WHITE that nobody clears → wallpaper disappears.
    --
    -- The guard flag lives on the FileManager class table so it survives FM instance
    -- recreation.  teardownAll clears it so a full disable→enable cycle reinstalls
    -- the wrapper cleanly.
    local setup_already_patched = FileManager._simpleui_setup_patched
    -- orig_setupLayout is declared here (outer scope) so the setupLayout closure
    -- below can capture it even though both are inside the guard block.
    local orig_setupLayout
    if not setup_already_patched then
        FileManager._simpleui_setup_patched = true
        orig_setupLayout      = FileManager.setupLayout
        plugin._orig_fm_setup = orig_setupLayout
    end

    -- Navbar touch zones must be processed before FileChooser scroll children.
    UI.applyGesturePriorityHandleEvent(FileManager)

    -- Fix: the native filemanager_swipe handler does not return true, so the
    -- event propagates a second time through WidgetContainer children and every
    -- horizontal swipe advances two pages instead of one. Re-register the zone
    -- with a handler that returns true to consume the event after the page turn.
    -- North/south swipes are intentionally not consumed so FileManagerMenu's
    -- zones can catch them and open the top menu.
    local orig_initGesListener        = FileManager.initGesListener
    plugin._orig_initGesListener      = orig_initGesListener
    FileManager._simpleui_ges_patched = false
    FileManager.initGesListener = function(fm_self)
        orig_initGesListener(fm_self)
        fm_self:registerTouchZones({
            {
                id          = "filemanager_swipe",
                ges         = "swipe",
                screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
                handler = function(ges)
                    if ges.direction == "south" or ges.direction == "north" then
                        return false
                    end
                    fm_self:onSwipeFM(ges)
                    return true
                end,
            },
        })
    end

    if not setup_already_patched then
    FileManager.setupLayout = function(fm_self)
        -- Resolve the live plugin instance rather than relying on the
        -- `plugin` upvalue captured when this closure was installed (which
        -- only happens once per session -- see setup_already_patched above).
        -- Without this, a FM recreated later in the session (e.g. returning
        -- from the reader, a rotation reinit, or after a suspend/resume
        -- cycle) would read/write active_action on a stale, disconnected
        -- plugin instance -- the visible symptom being the navbar indicator
        -- not following actual navigation (e.g. staying lit on "Homescreen"
        -- after tapping into the Library).
        local plugin = _live_plugin or plugin
        -- Calculate total navbar height (bottom bar + optional top bar).
        local topbar_on = SUISettings:nilOrTrue("simpleui_topbar_enabled")
        fm_self._navbar_height = Bottombar.TOTAL_H()
            + (topbar_on and require("sui_topbar").TOTAL_TOP_H() or 0)

        -- Reset the "first show" guard so onShow reinitialises on the next open.
        fm_self._navbar_already_shown = nil

        -- If HomescreenWidget:onSetRotationMode signalled a rotation reopen,
        -- open the HS directly via scheduleIn(0) now that setupLayout has
        -- rebuilt the FM at the new screen dimensions.
        -- We cannot rely on onShow here because the FM is already on the
        -- UIManager stack during reinit -- onShow only fires on first push.
        local HS = liveHS()
        if HS and HS._rotation_pending then
            HS._rotation_pending = false
            local rot_qa_tap   = HS._rotation_on_qa_tap
            local rot_goal_tap = HS._rotation_on_goal_tap
            HS._rotation_on_qa_tap   = nil
            HS._rotation_on_goal_tap = nil
            -- Show the new HS synchronously here, before setupLayout returns,
            -- so it is on the UIManager stack before the event loop drains and
            -- paints anything.  This prevents the FM flash that occurred when
            -- scheduleIn(0) was used: the FM dirty flag was consumed by the
            -- repaint before the scheduled callback had a chance to push the HS.
            -- Clear the FM invisible flag first so the FM is repaintable again
            -- if the user later closes the HS normally.
            local FM2 = package.loaded["apps/filemanager/filemanager"]
            local fm2 = FM2 and FM2.instance
            if fm2 then fm2.invisible = nil end
            _ensureGoalCallback(plugin)
            local qa_tap   = rot_qa_tap   or _makeQaTap(plugin)
            local goal_tap = rot_goal_tap or plugin._goalTapCallback
            local HS2 = liveHS()
            if HS2 then HS2.show(qa_tap, goal_tap) end
        end

        -- Patch FileChooser once on the class (not per instance) to shrink it
        -- to the content area and to flag external path changes.
        local FileChooser = require("ui/widget/filechooser")
        if not FileChooser._navbar_patched then
            local orig_fc_init         = FileChooser.init
            local orig_fc_changeToPath = FileChooser.changeToPath
            plugin._orig_fc_init       = orig_fc_init
            FileChooser._navbar_patched = true

            -- Shrink the file chooser to leave room for the navbar.
            FileChooser.init = function(fc_self)
                if fc_self.height == nil and fc_self.width == nil then
                    fc_self.height = UI.getContentHeight()
                    fc_self.y      = UI.getContentTop()
                end
                orig_fc_init(fc_self)
            end

            -- When an external caller (e.g. native "Show Folder") changes the
            -- path, set a flag so _doShowHS skips re-opening the homescreen.
            -- SimpleUI's own path changes raise _navbar_suppress_path_change
            -- before calling, so they never trigger this flag.
            FileChooser.changeToPath = function(fc_self, path, focused_path)
                local fm_ref = liveFM()
                if fm_ref and fc_self.ui == fm_ref
                        and not fm_ref._navbar_suppress_path_change then
                    -- Do not set the flag while a book is being opened;
                    -- changeToPath can be triggered mid-open and would cause
                    -- ReaderUI to get the "No reader engine" error.
                    local RUI = package.loaded["apps/reader/readerui"]
                    if not (RUI and RUI.instance) then
                        fm_ref._sui_show_folder_pending = true
                    end
                end
                return orig_fc_changeToPath(fc_self, path, focused_path)
            end
        end

        -- Patch FileManager.reinit so that external callers (e.g. NewsDownloader
        -- "Go to news folder") work correctly when the homescreen is on top.
        --
        -- Without this, reinit() silently rebuilds the FM underneath the
        -- homescreen and the user never sees the target folder.
        --
        -- When the homescreen IS open we skip reinit entirely and instead:
        --   1. Close the homescreen intentionally (suppresses _doShowHS reopen).
        --   2. Navigate the already-visible FM to the requested path directly,
        --      bypassing the onShow "go home" reset that showFiles would trigger.
        --   3. Rebuild the navbar bar with the Library tab active.
        --   4. Set _sui_show_folder_pending so that the calling TouchMenu closing
        --      afterwards does not trigger another _doShowHS.
        -- When the homescreen is NOT open the call is a transparent pass-through.
        if not FileManager._simpleui_reinit_patched then
            FileManager._simpleui_reinit_patched = true
            local orig_reinit = FileManager.reinit
            FileManager.reinit = function(fm_self, path, focused_file)
                -- Rotation calls reinit with path=nil; pass those through
                -- unconditionally — they must go through orig_reinit so that
                -- setupLayout rebuilds the FM at the new screen dimensions.
                if not path then
                    return orig_reinit(fm_self, path, focused_file)
                end

                local HS      = liveHS()
                local hs_inst = HS and HS._instance

                -- Resolve the target path the same way reinit would.
                local ffiUtil = require("ffi/util")
                local resolved = ffiUtil.realpath(path) or path

                -- Detect whether a foreign fullscreen widget (History,
                -- Collections, etc.) is on top of the FM. These widgets sit
                -- above the FM in the UIManager stack and cover it entirely;
                -- orig_reinit would call setupLayout and rebuild the FM
                -- underneath them, producing a visible glitch. Instead we
                -- close every such widget first, then navigate manually.
                --
                -- Strategy: collect every widget above the FM that is neither
                -- the FM itself nor the SimpleUI homescreen (already handled
                -- via hs_inst), then close them all before proceeding.
                local overlays = {}
                if not hs_inst then
                    local stack = UI.getWindowStack()
                    -- Stack is bottom-to-top; find the FM position first.
                    local fm_pos = 0
                    for i, entry in ipairs(stack) do
                        if entry.widget == fm_self then fm_pos = i; break end
                    end
                    -- Everything above the FM that is not the HS is an overlay.
                    for i = fm_pos + 1, #stack do
                        local w = stack[i].widget
                        if w then overlays[#overlays + 1] = w end
                    end
                end

                -- Pass-through when nothing special is on top: orig_reinit is
                -- correct and complete for the plain FM case.
                if not hs_inst and #overlays == 0 then
                    return orig_reinit(fm_self, path, focused_file)
                end

                -- From here: either the HS is open, or foreign widgets sit
                -- above the FM. Close them all before navigating.

                -- 1a. Close the homescreen intentionally (only when open).
                if hs_inst then
                    hs_inst._navbar_closing_intentionally = true
                    pcall(function() UIManager:close(hs_inst) end)
                    hs_inst._navbar_closing_intentionally = nil
                end

                -- 1b. Close any overlay widgets (History, Collections, …)
                --     top-to-bottom so each close is clean.
                for i = #overlays, 1, -1 do
                    pcall(function() UIManager:close(overlays[i]) end)
                end

                -- 2. Navigate the FM to the requested path.
                --    Suppress onPathChanged — we rebuild the bar explicitly below.
                if fm_self.file_chooser and resolved then
                    fm_self._navbar_suppress_path_change = true
                    pcall(function() fm_self.file_chooser:changeToPath(resolved) end)
                    fm_self._navbar_suppress_path_change = nil
                end

                -- 3. Update the title bar to show the new path.
                if fm_self.updateTitleBarPath then
                    pcall(function() fm_self:updateTitleBarPath(resolved, false) end)
                end

                -- 4. Rebuild the navbar with the Library ("home") tab active.
                local sui = fm_self._simpleui_plugin
                if sui then sui.active_action = "home" end
                local tabs = Config.loadTabConfig()
                if fm_self._navbar_container then
                    Bottombar.replaceBar(fm_self, Bottombar.buildBarWidget("home", tabs), tabs)
                    UIManager:setDirty(fm_self, "ui")
                end

                -- 5. Suppress _doShowHS for the TouchMenu that closes after
                --    the calling menu callback returns (relevant for hs_inst
                --    case; harmless when only an overlay is present).
                fm_self._sui_show_folder_pending = true
            end
        end

        orig_setupLayout(fm_self)

        -- Re-apply title-bar customisations to the fresh TitleBar instance that
        -- orig_setupLayout just created.  We must use reapply (restore + apply)
        -- rather than apply alone: apply guards itself with _titlebar_patched so
        -- it is a no-op on subsequent calls (e.g. after a rotation reinit) unless
        -- the flag is cleared first.  The restore step is safe on a brand-new
        -- title_bar because apply() overwrites all geometry afterwards anyway.
        Titlebar().reapply(fm_self)

        -- Use _navbar_inner to prevent wrapping the wrapper on repeated
        -- setupLayout calls (e.g. after closing a book). Exception: when the
        -- screen dimensions change (rotation), drop the cached widget so the
        -- fresh FileChooser built by orig_setupLayout with the new dimensions
        -- is used instead.
        local cur_w = Screen:getWidth()
        local cur_h = Screen:getHeight()
        if fm_self._navbar_inner
                and (fm_self._navbar_layout_w ~= cur_w
                     or fm_self._navbar_layout_h ~= cur_h) then
            fm_self._navbar_inner = nil
        end
        local inner_widget = fm_self._navbar_inner or fm_self[1]
        fm_self._navbar_inner    = inner_widget
        fm_self._navbar_layout_w = cur_w
        fm_self._navbar_layout_h = cur_h

        local tabs = Config.loadTabConfig()
        -- Recalculate the correct indicator from the FC path before wrapping.
        -- When setupLayout runs after the reader closes, plugin.active_action
        -- may already be "homescreen" (set by patchUIManagerClose to prepare
        -- the HS re-open). The wrapWithNavbar call below would then build the
        -- bar with "homescreen" active, which persists until something forces a
        -- replaceBar — causing the intermittent "homescreen tab lit while in
        -- library" symptom. Using the resolved path here keeps the bar correct
        -- from the start, independently of what the HS lifecycle does afterwards.
        local _wrap_active = plugin.active_action
        local _fc_now = fm_self.file_chooser
        if _fc_now and _fc_now.path then
            _wrap_active = M._resolveTabForPath(_fc_now.path, tabs) or "home"
        end
        local navbar_container, wrapped, bar, topbar, bar_idx, topbar_on2, topbar_idx =
            UI.wrapWithNavbar(inner_widget, _wrap_active, tabs)
        UI.applyNavbarState(fm_self, navbar_container, bar, topbar, bar_idx, topbar_on2, topbar_idx, tabs)
        fm_self[1] = wrapped
        fm_self._simpleui_plugin = plugin

        -- Resize pagination buttons (chevrons) on every setupLayout call so that
        -- they use the correct Simple UI size after rotation rebuilds the FM.
        -- onShow only fires on the first push to the UIManager stack, so without
        -- this the buttons keep their default KOReader size after a rotation.
        Bottombar.resizePaginationButtons(fm_self.file_chooser or fm_self, Bottombar.getPaginationIconSize())

        plugin:_updateFMHomeIcon()

        -- On the very first boot, schedule the homescreen auto-open for onShow.
        if not _hs_boot_done then
            _hs_boot_done = true
            -- Note: we intentionally do NOT require the "homescreen" tab to be
            -- present in the navbar. "Start with Home Screen" is a launch
            -- behaviour, independent of whether the user has kept the tab.
            if isStartWithHS() then
                plugin.active_action      = "homescreen"
                fm_self._hs_autoopen_pending = true
            end
        end

        -- onShow: fires once the FM is on the UIManager stack.
        local orig_onShow = fm_self.onShow
        fm_self.onShow = function(this)
            if orig_onShow then orig_onShow(this) end
            Bottombar.resizePaginationButtons(this.file_chooser or this, Bottombar.getPaginationIconSize())

            -- Open the homescreen if it was flagged at setupLayout time (boot or rotation).
            if this._hs_autoopen_pending then
                this._hs_autoopen_pending = nil
                local rot_qa_tap   = this._hs_rotation_on_qa_tap
                local rot_goal_tap = this._hs_rotation_on_goal_tap
                this._hs_rotation_on_qa_tap   = nil
                this._hs_rotation_on_goal_tap = nil
                UIManager:scheduleIn(0, function()
                    local HS = liveHS() or (function()
                        local ok, m = pcall(require, "sui_homescreen"); return ok and m
                    end)()
                    if HS then
                        _ensureGoalCallback(plugin)
                        local qa_tap   = rot_qa_tap   or _makeQaTap(plugin)
                        local goal_tap = rot_goal_tap or plugin._goalTapCallback
                        HS.show(qa_tap, goal_tap)
                    end
                end)
                return
            end

            -- Only run the "go home" reset on the first genuine show of this FM
            -- instance. Skip it when the FM reappears after a sub-widget closes.
            if this._navbar_already_shown then return end
            this._navbar_already_shown = true

            if this._navbar_container then
                local t = Config.loadTabConfig()
                -- _sui_return_to_book_folder_pending is set by closeReaderToHomescreen
                -- when "Return to Book Folder" is on. Consume it now so it fires
                -- exactly once per close, then honour it exactly like return_to_folder=true.
                local pending_folder = this._sui_return_to_book_folder_pending
                this._sui_return_to_book_folder_pending = nil
                local return_to_folder = pending_folder
                    or SUISettings:isTrue("simpleui_hs_return_to_book_folder")
                if not return_to_folder then
                    plugin.active_action = "home"
                    local home = G_reader_settings:readSetting("home_dir")
                    if home and this.file_chooser then
                        -- Suppress onPathChanged: replaceBar below handles the bar.
                        this._navbar_suppress_path_change = true
                        this.file_chooser:changeToPath(home)
                        this._navbar_suppress_path_change = nil
                        -- Explicitly clear the subtitle since onPathChanged was skipped.
                        if this.updateTitleBarPath then
                            this:updateTitleBarPath(home, true)
                        end
                    end
                end
                local active = return_to_folder
                    and M._resolveTabForPath(this.file_chooser and this.file_chooser.path, t)
                    or "home"
                Bottombar.replaceBar(this, Bottombar.buildBarWidget(active, t), t)
                UIManager:setDirty(this, "ui")
            end
        end

        -- onCloseAllMenus: fires when the KOReader main menu (TouchMenu) closes.
        -- Re-registers touch zones and repaints the bar so stale handlers are fixed.
        -- Also refreshes the homescreen QA tap callback: if the device suspended
        -- while the touch menu was open over the homescreen, the HS survives but
        -- its _on_qa_tap may be stale.  Refreshing it here covers the case where
        -- the user simply closes the touch menu without sleeping (e.g. back-key),
        -- and also acts as a safety net complementing the onResume fix.
        local orig_onCloseAllMenus = fm_self.onCloseAllMenus
        fm_self.onCloseAllMenus = function(this)
            if orig_onCloseAllMenus then orig_onCloseAllMenus(this) end
            -- Refresh the live homescreen's QA tap callback first so it is
            -- current before any repaint that follows.
            local HS_live = liveHS()
            if HS_live and HS_live._instance then
                HS_live._instance._on_qa_tap = _makeQaTap(plugin)
            end
            if not this._navbar_container then return end
            -- Skip the bar rebuild when navigate() set _navbar_tab_nav_in_progress:
            -- navigate() will call replaceBar immediately after this returns, so
            -- rebuilding here produces a redundant buildBarWidget + setDirty that
            -- slows down every injected-widget → FM tab transition.
            if this._navbar_tab_nav_in_progress then return end
            local t = Config.loadTabConfig()
            plugin:_registerTouchZones(this)
            Bottombar.replaceBar(this, Bottombar.buildBarWidget(plugin.active_action, t), t)
            UIManager:setDirty(this, "ui")
        end

        plugin:_registerTouchZones(fm_self)

        -- onPathChanged: update the active tab when the user navigates directories.
        -- Skipped when _navbar_suppress_path_change is set (programmatic navigation).
        fm_self.onPathChanged = function(this, new_path)
            if this._navbar_suppress_path_change then return end

            -- Normalise home_dir once and pass it down to avoid a second read.
            local home_dir_norm = (G_reader_settings:readSetting("home_dir") or ""):gsub("/$", "")
            if this.updateTitleBarPath then
                local is_home = new_path and (new_path:gsub("/$", "") == home_dir_norm)
                this:updateTitleBarPath(new_path, is_home or nil)
            end

            local t          = Config.loadTabConfig()
            local new_active = M._resolveTabForPath(new_path, t, home_dir_norm) or "home"
            plugin.active_action = new_active
            if this._navbar_container then
                Bottombar.replaceBar(this, Bottombar.buildBarWidget(new_active, t), t)
                UIManager:setDirty(this, "ui")
            end
            plugin:_updateFMHomeIcon()

            -- Mark the library as visited so the homescreen can invalidate its
            -- cover cache if CoverBrowser has replaced native-size bitmaps.
            local HS = liveHS()
            if HS then HS._library_was_visited = true end
        end

        -- Navbar keyboard focus (D-pad devices only).
        -- Pushes a transparent InputContainer that captures directional keys
        -- while the user navigates tabs, then pops itself on Press or Back.
        local function _enterNavbarKbFocus(return_fn)
            if not Device:hasDPad() then return end
            if not SUISettings:nilOrTrue("simpleui_bar_enabled") then return end
            if _navbar_kb_capture then return end  -- already active

            _navbar_kb_return_fn = return_fn or false

            -- Find the index of the currently active tab.
            local tabs = Config.loadTabConfig()
            _navbar_kb_idx = 1
            for i, t in ipairs(tabs) do
                if t == plugin.active_action then _navbar_kb_idx = i; break end
            end

            -- Draw the bar with a focus-border on the active tab.
            local target0 = M._getNavbarTarget and M._getNavbarTarget(liveFM()) or liveFM()
            if target0 then
                Bottombar.replaceBar(target0,
                    Bottombar.buildBarWidgetWithKeyFocus(plugin.active_action, tabs, _navbar_kb_idx),
                    tabs)
                UIManager:setDirty(target0, "ui")
            end

            -- Build the transparent key-capture overlay.
            local InputContainer = require("ui/widget/container/inputcontainer")
            local Geom           = require("ui/geometry")
            local capture = InputContainer:new{
                dimen             = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() },
                covers_fullscreen = false,
            }
            function capture:paintTo() end  -- fully transparent

            local function _moveNavbar(delta)
                local t2      = Config.loadTabConfig()
                _navbar_kb_idx = ((_navbar_kb_idx - 1 + delta + #t2) % #t2) + 1
                local target2 = M._getNavbarTarget and M._getNavbarTarget(liveFM()) or liveFM()
                if target2 then
                    Bottombar.replaceBar(target2,
                        Bottombar.buildBarWidgetWithKeyFocus(plugin.active_action, t2, _navbar_kb_idx),
                        t2)
                    UIManager:setDirty(target2, "ui")
                end
            end

            local function _exitNavbarKb()
                _navbar_kb_capture = nil
                UIManager:close(capture)
                -- Restore the unfocused bar.
                local fm2     = liveFM()
                local target2 = M._getNavbarTarget and M._getNavbarTarget(fm2) or fm2
                if target2 then
                    local t2 = Config.loadTabConfig()
                    Bottombar.replaceBar(target2, Bottombar.buildBarWidget(plugin.active_action, t2), t2)
                    UIManager:setDirty(target2, "ui")
                end
                -- Call the return callback, or restore focus to the file chooser.
                local ret_fn = _navbar_kb_return_fn
                _navbar_kb_return_fn = nil
                if ret_fn then
                    ret_fn()
                else
                    local FC = package.loaded["ui/widget/filechooser"]
                    local fm2i = liveFM()
                    local fc   = FC and fm2i and fm2i.file_chooser
                    if fc and fc.layout then
                        fc:moveFocusTo(1, #fc.layout, FocusManager().FORCED_FOCUS)
                    end
                end
            end

            capture.key_events = {
                NavbarKbLeft  = { { "Left"  } },
                NavbarKbRight = { { "Right" } },
                NavbarKbPress = { { "Press" } },
                NavbarKbUp    = { { "Up"    } },
            }
            if Device.input and Device.input.group and Device.input.group.Back then
                capture.key_events.NavbarKbBack = { { Device.input.group.Back } }
            end

            function capture:onNavbarKbLeft()  _moveNavbar(-1); return true end
            function capture:onNavbarKbRight() _moveNavbar(1);  return true end
            function capture:onNavbarKbUp()    _exitNavbarKb(); return true end
            function capture:onNavbarKbBack()  _exitNavbarKb(); return true end
            function capture:onNavbarKbPress()
                _navbar_kb_capture = nil
                UIManager:close(capture)
                local t2     = Config.loadTabConfig()
                local action = t2[_navbar_kb_idx]
                local fm2    = liveFM()
                if action and fm2 then
                    local target = M._getNavbarTarget and M._getNavbarTarget(fm2) or fm2
                    plugin:_navigate(action, target, t2, false)
                end
                return true
            end

            _navbar_kb_capture = capture
            UIManager:show(capture)
        end

        -- Expose for HomescreenWidget:onHSFocusDown.
        _enterNavbarKbFocus_fn = _enterNavbarKbFocus

        -- On D-pad devices, pressing Down at the last file enters navbar focus
        -- instead of wrapping back to the top of the list.
        if Device:hasDPad() and fm_self.file_chooser then
            local fc = fm_self.file_chooser
            if rawget(fc, "_wrapAroundY") == nil then
                local origWrapY = fc._wrapAroundY
                fc._wrapAroundY = function(self_fc, dy)
                    if dy > 0 and self_fc.page == (self_fc.total_pages or 1) then
                        _enterNavbarKbFocus()
                    else
                        return origWrapY(self_fc, dy)
                    end
                end
            end
        end
    end
    end -- if not setup_already_patched
end

-- ---------------------------------------------------------------------------
-- Tab-to-path resolver
-- Returns the tab id whose configured path matches the given filesystem path,
-- or nil if no tab matches.
-- Pass home_dir_norm when the caller has already read and normalised home_dir
-- to avoid a redundant settings read.
-- ---------------------------------------------------------------------------

function M._resolveTabForPath(path, tabs, home_dir_norm)
    if not path then return nil end
    path = path:gsub("/$", "")
    if home_dir_norm == nil then
        local hd = G_reader_settings:readSetting("home_dir")
        home_dir_norm = hd and hd:gsub("/$", "") or false
    end
    for _, tab_id in ipairs(tabs) do
        if tab_id == "home" then
            if home_dir_norm and path == home_dir_norm then return "home" end
        elseif tab_id:match("^custom_qa_%d+$") then
            local cfg = Config.getCustomQAConfig(tab_id)
            if cfg.path and path == cfg.path:gsub("/$", "") then
                return tab_id
            end
        end
    end
    return nil
end

-- Public entry point for HomescreenWidget:onHSFocusDown.
function M.enterNavbarKbFocus(return_fn)
    if _enterNavbarKbFocus_fn then
        _enterNavbarKbFocus_fn(return_fn)
    end
end

-- ---------------------------------------------------------------------------
-- "Start with Home Screen" menu entry
-- Injects the HomeScreen radio item into KOReader's Start With submenu.
-- Patched once per session; a flag on the class prevents double-patching.
-- ---------------------------------------------------------------------------

function M.patchStartWithMenu()
    local FileManagerMenu = package.loaded["apps/filemanager/filemanagermenu"]
    if not FileManagerMenu then
        local ok, m = pcall(require, "apps/filemanager/filemanagermenu")
        FileManagerMenu = ok and m or nil
    end
    if not FileManagerMenu then return end
    if FileManagerMenu._simpleui_startwith_patched then return end
    local orig_fn = FileManagerMenu.getStartWithMenuTable
    if not orig_fn then return end

    FileManagerMenu._simpleui_startwith_patched = true
    FileManagerMenu._simpleui_startwith_orig    = orig_fn

    FileManagerMenu.getStartWithMenuTable = function(fmm_self)
        local result = orig_fn(fmm_self)
        local sub    = result.sub_item_table
        if type(sub) ~= "table" then return result end

        -- Wrap every native item's callback to clear _start_with_hs when a
        -- native option is selected. Without this, selecting e.g. "file browser"
        -- writes the setting directly but leaves _start_with_hs=true, causing
        -- the HS to keep opening on boot even after the user switched away.
        for _, item in ipairs(sub) do
            if item.radio and type(item.callback) == "function" then
                local orig_cb    = item.callback
                local orig_check = item.checked_func
                item.callback = function()
                    _start_with_hs = false
                    orig_cb()
                end
                -- Also read the setting directly so checked_func stays in sync
                -- even when _start_with_hs cache and the persisted setting drift.
                if orig_check then
                    item.checked_func = function()
                        if _start_with_hs then return false end
                        return orig_check()
                    end
                end
            end
        end

        -- Resolve gettext once so the loop and the menu entry share the same string.
        local hs_text = _("Home Screen")

        -- Add the entry only if it is not already present.
        local found = false
        for _, item in ipairs(sub) do
            if item.text == hs_text and item.radio then found = true; break end
        end
        if not found then
            table.insert(sub, math.max(1, #sub), {
                text         = hs_text,
                -- Read the setting directly as ground truth; fall back to the
                -- cache only when the setting hasn't been written yet.
                checked_func = function()
                    return G_reader_settings:readSetting("start_with") == "homescreen_simpleui"
                end,
                callback = function()
                    G_reader_settings:saveSetting("start_with", "homescreen_simpleui")
                    _start_with_hs = true
                end,
                radio = true,
            })
        end

        -- Update the parent item label when Home Screen is the active choice.
        local orig_text_func = result.text_func
        result.text_func = function()
            if G_reader_settings:readSetting("start_with") == "homescreen_simpleui" then
                return _("Start with") .. ": " .. _("Home Screen")
            end
            return orig_text_func and orig_text_func() or _("Start with")
        end
        return result
    end
end

-- ---------------------------------------------------------------------------
-- Widget height patches
-- Shrink fullscreen widgets so they fit within the content area (below the
-- navbar). Each patch stores the original constructor so teardownAll can
-- restore it.
-- ---------------------------------------------------------------------------

function M.patchBookList(plugin)
    local BookList    = require("ui/widget/booklist")
    local orig_bl_new = BookList.new
    plugin._orig_booklist_new = orig_bl_new
    BookList.new = function(class, attrs, ...)
        attrs = attrs or {}
        if not attrs.height and not attrs._navbar_height_reduced then
            attrs.height                 = UI.getContentHeight()
            attrs.y                      = UI.getContentTop()
            attrs._navbar_height_reduced = true
        end
        return orig_bl_new(class, attrs, ...)
    end
end

-- Patches the collections list menu (coll_list) height, and keeps the
-- SimpleUI collections pool in sync when KOReader renames or deletes a collection.
function M.patchCollections(plugin)
    local ok, FMColl = pcall(require, "apps/filemanager/filemanagercollection")
    if not (ok and FMColl) then return end

    local Menu          = require("ui/widget/menu")
    local orig_menu_new = Menu.new
    plugin._orig_menu_new    = orig_menu_new
    plugin._orig_fmcoll_show = FMColl.onShowCollList

    -- patch_depth gates Menu.new so only menus created during onShowCollList
    -- have their height reduced.
    local patch_depth = 0

    local orig_onShowCollList = FMColl.onShowCollList
    FMColl.onShowCollList = function(fmc_self, ...)
        patch_depth = patch_depth + 1
        local ok2, result = pcall(orig_onShowCollList, fmc_self, ...)
        patch_depth = patch_depth - 1
        if not ok2 then error(result) end
        return result
    end

    Menu.new = function(class, attrs, ...)
        attrs = attrs or {}
        if patch_depth > 0
                and attrs.covers_fullscreen and attrs.is_borderless
                and attrs.is_popout == false
                and not attrs.height and not attrs._navbar_height_reduced then
            attrs.height                 = UI.getContentHeight()
            attrs.y                      = UI.getContentTop()
            attrs._navbar_height_reduced = true
            attrs.name                   = attrs.name or "coll_list"
        end
        return orig_menu_new(class, attrs, ...)
    end

    local ok_rc, RC = pcall(require, "readcollection")
    if not (ok_rc and RC) then return end

    -- Remove a collection from the SimpleUI selected list and cover-override table.
    local function _removeFromPool(name)
        local CW = package.loaded["collectionswidget"]
        if not CW then return end
        local selected = CW.getSelected()
        local changed  = false
        for i = #selected, 1, -1 do
            if selected[i] == name then
                table.remove(selected, i)
                changed = true
                break  -- names are unique
            end
        end
        if changed then CW.saveSelected(selected) end
        local overrides = CW.getCoverOverrides()
        if overrides[name] then
            overrides[name] = nil
            CW.saveCoverOverrides(overrides)
        end
    end

    -- Rename a collection in the SimpleUI selected list and cover-override table.
    local function _renameInPool(old_name, new_name)
        local CW = package.loaded["collectionswidget"]
        if not CW then return end
        local selected = CW.getSelected()
        local changed  = false
        for i, name in ipairs(selected) do
            if name == old_name then
                selected[i] = new_name
                changed = true
            end
        end
        if changed then CW.saveSelected(selected) end
        local overrides = CW.getCoverOverrides()
        if overrides[old_name] then
            overrides[new_name] = overrides[old_name]
            overrides[old_name] = nil
            CW.saveCoverOverrides(overrides)
        end
    end

    if type(RC.removeCollection) == "function" then
        local orig_remove = RC.removeCollection
        plugin._orig_rc_remove = orig_remove
        RC.removeCollection = function(rc_self, coll_name, ...)
            local TBR = package.loaded["desktop_modules/module_tbr"]
            -- The TBR collection cannot be permanently deleted.
            -- Let RC delete it (so the KOReader UI gets its confirmation flow),
            -- then immediately recreate it empty and sync settings.
            local result = orig_remove(rc_self, coll_name, ...)
            local ok2, err = pcall(function()
                if TBR and coll_name == TBR.TBR_COLL_NAME then
                    rc_self:addCollection(TBR.TBR_COLL_NAME)
                    rc_self:write({ [TBR.TBR_COLL_NAME] = true })
                    SUISettings:saveSetting("simpleui_tbr_list", {})
                else
                    _removeFromPool(coll_name)
                    Config.purgeQACollection(coll_name)
                    Config.invalidateTabsCache()
                end
                plugin:_scheduleRebuild()
            end)
            if not ok2 then logger.warn("simpleui: removeCollection hook:", tostring(err)) end
            return result
        end
    end

    if type(RC.renameCollection) == "function" then
        local orig_rename = RC.renameCollection
        plugin._orig_rc_rename = orig_rename
        RC.renameCollection = function(rc_self, old_name, new_name, ...)
            -- Prevent renaming the TBR collection — its name is the plugin's key.
            local TBR = package.loaded["desktop_modules/module_tbr"]
            if TBR and old_name == TBR.TBR_COLL_NAME then
                _showInfoMsg(_("The «To Be Read» collection cannot be renamed."))
                return  -- abort
            end
            local result = orig_rename(rc_self, old_name, new_name, ...)
            local ok2, err = pcall(function()
                _renameInPool(old_name, new_name)
                Config.renameQACollection(old_name, new_name)
                plugin:_scheduleRebuild()
            end)
            if not ok2 then logger.warn("simpleui: renameCollection hook:", tostring(err)) end
            return result
        end
    end

    -- ---------------------------------------------------------------------------
    -- TBR hooks on RC.addItem / RC.removeItem:
    -- Fire only when the user adds/removes books via the *native KOReader*
    -- collections UI.  The plugin's addTBR/removeTBR functions bypass these
    -- hooked methods entirely to avoid re-entrancy.
    -- Responsibilities: enforce the 5-book cap on add; sync G_reader_settings.
    -- ---------------------------------------------------------------------------

    -- Helper: re-read the TBR list from RC and persist into G_reader_settings.
    local function _syncTBRSettings(TBR)
        local list = TBR.getTBRList()
        SUISettings:saveSetting("simpleui_tbr_list", list)
    end

    local function _getTBR()
        return package.loaded["desktop_modules/module_tbr"]
    end

    if type(RC.addItem) == "function" then
        local orig_add = RC.addItem
        plugin._orig_rc_additem = orig_add
        RC.addItem = function(rc_self, file, coll_name, attr, ...)
            local TBR = _getTBR()
            if TBR and coll_name == TBR.TBR_COLL_NAME then
                local coll  = rc_self.coll and rc_self.coll[coll_name]
                local count = 0
                if coll then for _ in pairs(coll) do count = count + 1 end end
                if count >= (TBR.TBR_MAX or 5) then
                    _showInfoMsg(_("To Be Read list is full (max. 5 books)."))
                    return  -- abort — do NOT call orig_add
                end
            end
            orig_add(rc_self, file, coll_name, attr, ...)
            if TBR and coll_name == TBR.TBR_COLL_NAME then
                local ok2, err = pcall(function()
                    _syncTBRSettings(TBR)
                    plugin:_scheduleRebuild()
                end)
                if not ok2 then logger.warn("simpleui: RC.addItem TBR hook:", tostring(err)) end
            end
        end
    end

    if type(RC.removeItem) == "function" then
        local orig_remove_item = RC.removeItem
        plugin._orig_rc_removeitem = orig_remove_item
        RC.removeItem = function(rc_self, file, coll_name, no_write, ...)
            orig_remove_item(rc_self, file, coll_name, no_write, ...)
            local TBR = _getTBR()
            -- coll_name == nil means "remove from all collections".
            if TBR and (coll_name == TBR.TBR_COLL_NAME or coll_name == nil) then
                local ok2, err = pcall(function()
                    _syncTBRSettings(TBR)
                    plugin:_scheduleRebuild()
                end)
                if not ok2 then logger.warn("simpleui: RC.removeItem TBR hook:", tostring(err)) end
            end
        end
    end

    -- Patch FMColl.updateCollListItemTable to:
    --   1. Hide the TBR collection when it is empty (no books).
    --   2. Show the localised display name instead of the raw RC key.
    if type(FMColl.updateCollListItemTable) == "function" then
        local orig_update = FMColl.updateCollListItemTable
        plugin._orig_fmcoll_update_coll_list = orig_update
        FMColl.updateCollListItemTable = function(fmc_self, do_init, item_number)
            orig_update(fmc_self, do_init, item_number)
            local TBR = package.loaded["desktop_modules/module_tbr"]
            if not TBR then return end
            local coll_list = fmc_self.coll_list
            if not (coll_list and coll_list.item_table) then return end
            local tbr_name  = TBR.TBR_COLL_NAME
            local tbr_empty = TBR.getTBRCount() == 0
            local changed   = false
            local filtered  = {}
            for _, item in ipairs(coll_list.item_table) do
                if item.name == tbr_name then
                    if tbr_empty then
                        -- Omit the TBR entry entirely when empty.
                        changed = true
                    else
                        -- Replace the raw key with the localised display name.
                        local disp = TBR.getDisplayName()
                        if item.text ~= disp then
                            item.text = disp
                            changed   = true
                        end
                        filtered[#filtered + 1] = item
                    end
                else
                    filtered[#filtered + 1] = item
                end
            end
            if changed then
                local new_title
                pcall(function()
                    new_title = T(_("Collections (%1)"), #filtered)
                end)
                if not new_title then
                    new_title = "Collections (" .. #filtered .. ")"
                end
                coll_list:switchItemTable(new_title, filtered, -1)
            end
        end
    end

    -- Patch FMColl.getCollectionTitle so the TBR collection shows its
    -- localised name whenever KOReader renders it (e.g. inside a book list).
    if type(FMColl.getCollectionTitle) == "function" then
        local orig_title = FMColl.getCollectionTitle
        plugin._orig_fmcoll_get_coll_title = orig_title
        FMColl.getCollectionTitle = function(fmc_self, collection_name)
            local TBR = package.loaded["desktop_modules/module_tbr"]
            if TBR and collection_name == TBR.TBR_COLL_NAME then
                return TBR.getDisplayName()
            end
            return orig_title(fmc_self, collection_name)
        end
    end
end

-- Patches SortWidget and PathChooser to fit inside the content area.
-- SortWidget also gets a title padding fix and a repaint hook after each sort.
function M.patchFullscreenWidgets(plugin)
    local ok_sw, SortWidget  = pcall(require, "ui/widget/sortwidget")
    local ok_pc, PathChooser = pcall(require, "ui/widget/pathchooser")

    if ok_sw and SortWidget then
        local ok_tb, TitleBar = pcall(require, "ui/widget/titlebar")
        local orig_sw_new     = SortWidget.new
        plugin._orig_sortwidget_new = orig_sw_new

        SortWidget.new = function(class, attrs, ...)
            attrs = attrs or {}
            if attrs.covers_fullscreen and not attrs._navbar_height_reduced then
                attrs.height                 = UI.getContentHeight()
                attrs.y                      = UI.getContentTop()
                attrs._navbar_height_reduced = true
            end
            -- Temporarily wrap TitleBar.new to inject horizontal padding, then
            -- restore it immediately after SortWidget is built.
            local orig_tb_new
            if ok_tb and TitleBar and attrs.covers_fullscreen then
                orig_tb_new = TitleBar.new
                TitleBar.new = function(tb_class, tb_attrs, ...)
                    tb_attrs = tb_attrs or {}
                    tb_attrs.title_h_padding = Screen:scaleBySize(24)
                    return orig_tb_new(tb_class, tb_attrs, ...)
                end
            end
            local ok_sw2, sw_or_err = pcall(orig_sw_new, class, attrs, ...)
            if orig_tb_new then TitleBar.new = orig_tb_new end
            if not ok_sw2 then error(sw_or_err, 2) end
            local sw = sw_or_err
            if not attrs.covers_fullscreen then return sw end

            -- Zero the footer height to remove the pagination bar space.
            local vfooter = sw[1] and sw[1][1] and sw[1][1][2] and sw[1][1][2][1]
            if vfooter and vfooter[3] and vfooter[3].dimen then
                vfooter[3].dimen.h = 0
            end

            -- Force a full repaint after each sort list update.
            local orig_populate = sw._populateItems
            if type(orig_populate) == "function" then
                sw._populateItems = function(self_sw, ...)
                    local result = orig_populate(self_sw, ...)
                    UIManager:setDirty(nil, "ui")
                    return result
                end
            end
            return sw
        end
    end

    if ok_pc and PathChooser then
        local orig_pc_new = PathChooser.new
        plugin._orig_pathchooser_new = orig_pc_new
        PathChooser.new = function(class, attrs, ...)
            attrs = attrs or {}
            if attrs.covers_fullscreen and not attrs._navbar_height_reduced then
                attrs.height                 = UI.getContentHeight()
                attrs.y                      = UI.getContentTop()
                attrs._navbar_height_reduced = true
            end
            return orig_pc_new(class, attrs, ...)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Cover Transition
-- Shows the book cover full-screen for a brief moment right as the reader
-- opens or closes, masking the layout/repaint flash that would otherwise be
-- visible. Deliberately stateless and patch-free: it is only ever called
-- from the two hooks that already exist for this purpose — the ReaderUI
-- branch inside the single UIManager.show wrapper below (open side) and
-- SimpleUIPlugin:onCloseDocument in main.lua (close side). No new
-- monkey-patch is installed for this feature, so it cannot conflict with
-- (or duplicate) any other UIManager.show / ReaderUI wrapper a user-supplied
-- patch may already be maintaining.
-- ---------------------------------------------------------------------------

local CoverTransition = {}
M.CoverTransition = CoverTransition

local _ct_widget     = nil
local _ct_close_task = nil

-- Blitbuffer ownership: normally cover_bb comes straight from the
-- BookInfoManager cache or from an already-open document — neither of those
-- is ours to free. The one exception is the best-quality direct-extraction
-- fallback below, which opens its own temporary document and therefore
-- returns a bb nothing else is tracking. _ct_owned_bb is only ever set in
-- that case, and only that bb ever gets :free()'d.
local _ct_owned_bb = nil

-- Lazy-loaded, same pattern as module_books_shared.getBookInfoManager(): no
-- package.path manipulation needed, CoverBrowser (if present) has already
-- registered "bookinfomanager" in package.loaded by the time SimpleUI reads it.
local _ct_BookInfoManager -- nil = not yet resolved, false = unavailable
local function _ctBookInfoManager()
    if _ct_BookInfoManager == nil then
        local ok, bim = pcall(require, "bookinfomanager")
        _ct_BookInfoManager = ok and bim or false
    end
    return _ct_BookInfoManager or nil
end

function CoverTransition.isOpenEnabled()
    return SUISettings:isTrue("simpleui_reader_cover_open")
end

function CoverTransition.isCloseEnabled()
    return SUISettings:isTrue("simpleui_reader_cover_close")
end

-- Off by default (stretch-to-fill, the original behaviour). When on, the
-- cover keeps its native aspect ratio — scaled to fit inside the screen
-- rather than stretched to it — with the rest of the screen filled in
-- black. Only changes how the widget is built in show() below; does not
-- touch which cover source is used.
function CoverTransition.isFitEnabled()
    return SUISettings:isTrue("simpleui_reader_cover_fit")
end

-- Off by default. Only affects the single moment where no live document is
-- available yet — the "Opening file '...'." notice substitution, before
-- ReaderUI has actually loaded anything. In every other case (close side,
-- and the second open-side call once ReaderUI is up) the cover already
-- comes straight off the live document at full quality, so this toggle
-- changes nothing there.
function CoverTransition.isBestQualityEnabled()
    return SUISettings:isTrue("simpleui_reader_cover_bestquality")
end

-- Only source: the CoverBrowser cache DB, if the plugin is installed and has
-- already indexed the file. Deliberately does NOT fall back to opening the
-- document directly (unlike a full re-implementation would) — that path
-- means a second, temporary document render just to grab a thumbnail, which
-- is the kind of extra SQLite/CRE work this feature exists to hide, not add.
-- Cache misses simply skip the cover for that one transition, unless
-- best-quality mode asks for the direct-extraction fallback below.
local function _ctFindCoverBB(filepath)
    if not filepath or filepath == "" then return nil end
    local BIM = _ctBookInfoManager()
    if not BIM then return nil end

    local ok, info = pcall(function() return BIM:getBookInfo(filepath, true) end)
    if not ok or not info then return nil end
    if not info.has_cover or info.ignore_cover or not info.cover_bb then return nil end
    return info.cover_bb
end

-- Best-quality fallback: opens the file itself just long enough to pull its
-- native embedded cover, then closes it again. This is genuine extra I/O on
-- the opening hot path (document open + provider load), so it is used only
-- as a last resort — when the caller has no live document AND either the
-- cache missed or best-quality mode is on — never as the first choice.
-- Returns bb, true (the `true` marks it as owned: caller must free it).
local function _ctExtractCoverDirect(filepath)
    if not filepath or filepath == "" then return nil end
    local ok_dr, DocumentRegistry = pcall(require, "document/documentregistry")
    if not ok_dr or not DocumentRegistry or not DocumentRegistry:hasProvider(filepath) then
        return nil
    end

    local ok_rui, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok_rui or not ReaderUI then return nil end

    local document
    local ok, cover_bb = pcall(function()
        local provider = ReaderUI:extendProvider(filepath, DocumentRegistry:getProvider(filepath))
        document = DocumentRegistry:openDocument(filepath, provider)
        if not document then return nil end
        if document.loadDocument and not document:loadDocument(false) then return nil end
        return document:getCoverPageImage()
    end)

    if document then
        pcall(function() document:close() end)
    end

    if ok and cover_bb then return cover_bb, true end
    if not ok then
        logger.warn("simpleui/sui_patches: CoverTransition direct extraction failed", cover_bb)
    end
    return nil
end

-- Public: exposed so other SimpleUI modules can reuse the exact same cover
-- source instead of re-implementing BookInfoManager lookup.
--
-- live_document, when given, is an already-open document object for
-- `filepath` (e.g. widget.document in the ReaderUI-open branch below, or
-- ui.document from onCloseDocument while a book is open).
-- In that case the cover is read straight off the open document — the same
-- zero-extra-I/O path KOReader's own BookInfo:getCoverImage() uses — instead
-- of going through BookInfoManager. Custom covers (DocSettings custom cover
-- file) are still honoured, since that is the one case where a *different*,
-- normally tiny, file legitimately needs to be opened.
--
-- Second return value: true when the returned bb was obtained via the
-- direct-extraction fallback and is therefore owned by the caller (must be
-- :free()'d). Always nil/false for the live-document and cache paths, since
-- those bbs are managed elsewhere (the open document, or BookInfoManager's
-- own cache) and must never be freed here.
function CoverTransition.findCoverBB(filepath, live_document)
    if live_document then
        local ok, bb = pcall(function()
            local DocSettings = require("docsettings")
            local custom_cover = DocSettings:findCustomCoverFile(filepath)
            if custom_cover then
                local DocumentRegistry = require("document/documentregistry")
                local cover_doc = DocumentRegistry:openDocument(custom_cover)
                if cover_doc then
                    local cbb = cover_doc:getCoverPageImage()
                    cover_doc:close()
                    if cbb then return cbb end
                end
            end
            return live_document:getCoverPageImage()
        end)
        if ok and bb then return bb end
    end

    local cache_bb = _ctFindCoverBB(filepath)
    if cache_bb and not CoverTransition.isBestQualityEnabled() then
        return cache_bb
    end

    -- Cache missed, or best-quality mode wants the sharper source anyway —
    -- either way this only runs when there is no live document, i.e. the
    -- single "Opening file '...'." notice-substitution moment.
    local direct_bb, owned = _ctExtractCoverDirect(filepath)
    if direct_bb then return direct_bb, owned end

    return cache_bb
end

function CoverTransition.isShowing()
    return _ct_widget ~= nil
end

-- Set by patchReaderShowCoroutine right before calling through to the
-- original ReaderUI.showReaderCoroutine, and consumed by the very next
-- UIManager.show call inside the wrapper below (which — in that narrow
-- window — is always KOReader's own "Opening file '...'." InfoMessage).
-- A plain string (the file being opened), not a boolean, so the wrapper
-- doesn't need to re-derive the path from the InfoMessage's translated text.
CoverTransition._pending_open_file = nil

-- Cancels a pending scheduled close (used when a new transition starts
-- before the previous one's auto-close has fired).
local function _ctCancelPendingClose()
    if _ct_close_task then
        UIManager:unschedule(_ct_close_task)
        _ct_close_task = nil
    end
end

-- Frees the direct-extraction bb, if there is one. Safe to call unconditionally.
local function _ctFreeOwnedBB()
    if not _ct_owned_bb then return end
    pcall(function() _ct_owned_bb:free() end)
    _ct_owned_bb = nil
end

function CoverTransition.close()
    _ctCancelPendingClose()
    if _ct_widget then
        pcall(function() UIManager:close(_ct_widget) end)
        _ct_widget = nil
    end
    _ctFreeOwnedBB()
end

-- Builds the actual cover widget. Stretch (default) fills the screen exactly,
-- distorting the cover's aspect ratio if it doesn't match the screen's.
-- Fit mode (opt-in) preserves the cover's proportions instead, centering it
-- over a black backdrop that covers the rest of the screen — matches how
-- most cover-only reading apps present a book cover.
-- Falls back to stretch if the bb doesn't expose dimensions, or on any error
-- building the fit containers, so a layout hiccup never means no cover at all.
local function _ctMakeCoverWidget(cover_bb, ImageWidget)
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()

    local function stretch()
        return ImageWidget:new{
            image             = cover_bb,
            width             = screen_w,
            height            = screen_h,
            alpha             = true,
            image_disposable  = false,
        }
    end

    if not CoverTransition.isFitEnabled() then
        return stretch()
    end

    if not (cover_bb.getWidth and cover_bb.getHeight) then
        return stretch()
    end
    local ok_size, cover_w, cover_h = pcall(function()
        return cover_bb:getWidth(), cover_bb:getHeight()
    end)
    if not (ok_size and cover_w and cover_h and cover_w > 0 and cover_h > 0) then
        return stretch()
    end

    local ok_fit, fit_widget = pcall(function()
        local Blitbuffer      = require("ffi/blitbuffer")
        local FrameContainer  = require("ui/widget/container/framecontainer")
        local CenterContainer = require("ui/widget/container/centercontainer")

        local scale_factor = math.min(screen_w / cover_w, screen_h / cover_h)
        local image = ImageWidget:new{
            image             = cover_bb,
            scale_factor      = scale_factor,
            alpha             = true,
            image_disposable  = false,
        }
        return FrameContainer:new{
            dimen      = { w = screen_w, h = screen_h },
            padding    = 0,
            bordersize = 0,
            background = Blitbuffer.COLOR_BLACK,
            CenterContainer:new{
                dimen = { w = screen_w, h = screen_h },
                image,
            },
        }
    end)
    if ok_fit and fit_widget then return fit_widget end

    logger.warn("simpleui/sui_patches: CoverTransition fit layout failed, falling back to stretch", fit_widget)
    return stretch()
end

-- show(filepath, orig_show) — orig_show must be the pristine UIManager.show
-- (i.e. the value captured before any wrapper ran), so the cover itself is
-- never re-processed by the navbar-injection logic below.
-- Returns true if a cover was actually displayed.
function CoverTransition.show(filepath, orig_show, live_document)
    local cover_bb, owned = CoverTransition.findCoverBB(filepath, live_document)
    if not cover_bb then return false end

    CoverTransition.close()
    if owned then _ct_owned_bb = cover_bb end

    local ok_iw, ImageWidget = pcall(require, "ui/widget/imagewidget")
    if not ok_iw then
        _ctFreeOwnedBB()
        return false
    end

    local ok_w, widget_or_err = pcall(_ctMakeCoverWidget, cover_bb, ImageWidget)
    if not ok_w then
        logger.warn("simpleui/sui_patches: CoverTransition failed to build widget", widget_or_err)
        _ctFreeOwnedBB()
        return false
    end

    local widget = widget_or_err
    local ok_show = pcall(orig_show, UIManager, widget, "full")
    if not ok_show then
        _ctFreeOwnedBB()
        return false
    end

    UIManager:forceRePaint()
    _ct_widget = widget
    return true
end

-- Auto-closes the cover shortly after showing it, so it never lingers over
-- the freshly-painted reader/FM if the caller forgets to close it explicitly.
function CoverTransition.scheduleAutoClose(delay)
    _ctCancelPendingClose()
    _ct_close_task = function()
        _ct_close_task = nil
        CoverTransition.close()
    end
    UIManager:scheduleIn(delay or 0.15, _ct_close_task)
end

-- ---------------------------------------------------------------------------
-- UIManager.show patch
-- Injects the navbar into qualifying fullscreen widgets and closes the
-- homescreen whenever another fullscreen widget appears on top of it.
-- _show_depth prevents re-entrant injection when orig_show calls show again.
-- ---------------------------------------------------------------------------

function M.patchUIManagerShow(plugin)
    -- Guard: only install one wrapper per session. The wrapper lives on the
    -- UIManager global; subsequent installAll calls (triggered by FM recreation
    -- after returning from the reader) must not stack a second wrapper on top.
    --
    -- On re-entry we update the shared plugin slot so the single live wrapper
    -- always resolves plugin references through the current FM instance.
    if UIManager._simpleui_show_patched then
        UIManager._simpleui_show_plugin = plugin
        -- Give the new plugin instance a back-reference to the original so
        -- teardownAll can restore UIManager.show correctly.
        plugin._orig_uimanager_show = UIManager._simpleui_show_orig
        return
    end
    UIManager._simpleui_show_patched = true
    UIManager._simpleui_show_plugin  = plugin

    local orig_show = UIManager.show
    UIManager._simpleui_show_orig = orig_show
    plugin._orig_uimanager_show   = orig_show
    local _show_depth = 0

    -- Widgets that receive navbar injection by name (in addition to those
    -- already sized to the content area via _navbar_height_reduced).
    local INJECT_NAMES = { collections = true, history = true, coll_list = true, homescreen = true }

    -- Widgets that receive wallpaper injection. Intentionally narrower than
    -- INJECT_NAMES: SortWidget, PathChooser and other utility overlays that
    -- happen to set covers_fullscreen must NOT get the wallpaper treatment.
    M._WALLPAPER_NAMES = { collections = true, history = true, coll_list = true }

    -- Resolve the live FM menu at call time so we never capture a stale reference.
    -- The FM is destroyed and recreated every time the reader opens/closes.
    local function _fmMenu()
        local fm = plugin.ui
        if fm and fm.menu
                and type(fm.menu.name) == "string"
                and fm.menu.name:find("filemanager") then
            return fm.menu
        end
        local inst = liveFM()
        return inst and inst.menu or nil
    end

    UIManager.show = function(um_self, widget, ...)
        -- Resolve the live plugin instance rather than the `plugin` upvalue
        -- captured when this wrapper was installed (only once per session --
        -- see the guard above). UIManager._simpleui_show_plugin IS kept fresh
        -- on every patchUIManagerShow call (FM recreation after returning
        -- from the reader, rotation, suspend/resume, etc.), but until now
        -- nothing inside this closure actually read it back -- every
        -- reference below silently kept using the stale instance from the
        -- very first install. That mismatch is what let the navbar's active
        -- indicator drift out of sync with the widget actually on screen.
        local plugin = UIManager._simpleui_show_plugin or plugin

        -- Cover Transition (open side, notice substitution): the very next
        -- UIManager.show call after ReaderUI.showReaderCoroutine flagged a
        -- file is, in that narrow window, always KOReader's own "Opening
        -- file '...'." InfoMessage (timeout=0.0, no covers_fullscreen — see
        -- patchReaderShowCoroutine). Swap the cover in for it so nothing
        -- text-based ever flashes while the book loads. Falls through to
        -- showing the InfoMessage normally when no cover is available, so
        -- books with no cached cover still get their loading feedback.
        local pending_open_file = CoverTransition._pending_open_file
        if pending_open_file then
            CoverTransition._pending_open_file = nil
            if widget and widget.timeout == 0.0 and not widget.covers_fullscreen then
                local ok_ct, shown = pcall(CoverTransition.show, pending_open_file, orig_show)
                if ok_ct and shown then
                    return
                end
            end
        end

        -- Fast path: non-fullscreen widgets need no SimpleUI logic.
        if not (widget and widget.covers_fullscreen) then
            return orig_show(um_self, widget, ...)
        end

        -- Wire the native "File browser" menu tab to use our flash-free
        -- close path every time a ReaderUI is shown (guard inside the fn).
        if widget.name == "ReaderUI" then
            pcall(M.wireReaderMenuFMTab,    plugin, widget)
            pcall(M.patchReloadDocument,    plugin, widget)

            -- Cover Transition (open side): show the cover a beat before the
            -- reader's own chrome paints, then auto-close shortly after —
            -- entirely optional and off by default. Uses orig_show (the
            -- pristine UIManager.show) so the cover widget itself never goes
            -- through the navbar-injection path below.
            if CoverTransition.isOpenEnabled() then
                if CoverTransition.isShowing() then
                    -- Already showing (put up earlier by the notice
                    -- substitution above) — just push the auto-close out
                    -- instead of closing and re-showing the same cover.
                    CoverTransition.scheduleAutoClose(0.15)
                else
                    local fp = widget.document and widget.document.file
                    local ok_ct, shown = pcall(CoverTransition.show, fp, orig_show, widget.document)
                    if ok_ct and shown then
                        CoverTransition.scheduleAutoClose(0.15)
                    end
                end
            end
        end

        local n_extra    = select("#", ...)
        local extra_args = n_extra > 0 and { ... } or _EMPTY
        _show_depth = _show_depth + 1

        -- Wrap in pcall so _show_depth is always decremented even on error.
        local ok, result = pcall(function()


        -- Decide whether to inject the navbar into this widget.
        -- Check the Bar Injection API registry first (O(n) over a tiny list).
        local _bi_desc = UI.BarInjection.matchWidget(widget)

        local should_inject = _show_depth == 1
            and widget
            and not widget._navbar_injected
            and not widget._navbar_skip_inject
            and widget ~= plugin.ui
            and widget.covers_fullscreen
            -- title_bar is NOT required for BI-registered widgets: Titlebar.applyToInjected
            -- already guards itself when title_bar is absent.
            and (widget.title_bar or _bi_desc ~= nil)
            and (widget._navbar_height_reduced
                 or (widget.name and INJECT_NAMES[widget.name])
                 or _bi_desc ~= nil)

        if not should_inject then
            if n_extra > 0 then
                return orig_show(um_self, widget, table.unpack(extra_args))
            else
                return orig_show(um_self, widget)
            end
        end

        widget._navbar_injected = true

        -- Resize the widget to the content area if it is not already sized.
        if not widget._navbar_height_reduced then
            local content_h   = UI.getContentHeight()
            local content_top = UI.getContentTop()
            if widget.dimen then
                widget.dimen.h = content_h
                widget.dimen.y = content_top
            end
            if widget[1] and widget[1].dimen then
                widget[1].dimen.h = content_h
                widget[1].dimen.y = content_top
            end
            widget._navbar_height_reduced = true
        end

        -- Apply title-bar customisations for sub-pages widgets.
        Titlebar().applyToSub(widget)

        local tabs      = Config.loadTabConfig()
        local tabs_set  = tabsToSet(tabs)

        -- Use the pre-tap action stash when available so _navbar_prev_action
        -- records the tab that was active before the tap, not the one opened.
        local action_before = plugin._navbar_prev_action_pending or plugin.active_action
        plugin._navbar_prev_action_pending = nil
        local effective_action = nil

        -- Activate the tab that matches this widget.
        if widget.name == "collections" and Config.isFavoritesWidget(widget) and tabs_set["favorites"] then
            effective_action = Bottombar.setActiveAndRefreshFM(plugin, "favorites", tabs)
        elseif widget.name == "history" and tabs_set["history"] then
            effective_action = Bottombar.setActiveAndRefreshFM(plugin, "history", tabs)
        elseif widget.name == "homescreen" and tabs_set["homescreen"] then
            -- Skip the FM bar rebuild + setDirty when active_action is already
            -- "homescreen" (e.g. set in UIManager.close before the reader closed).
            -- setupLayout already built the correct bar; rebuilding it here and
            -- calling setDirty(FM) is redundant since the FM is covered by the HS.
            if plugin.active_action ~= "homescreen" then
                effective_action = Bottombar.setActiveAndRefreshFM(plugin, "homescreen", tabs)
            else
                effective_action = "homescreen"
            end
        elseif widget.name == "coll_list"
               or (widget.name == "collections" and not Config.isFavoritesWidget(widget)) then
            if tabs_set["collections"] then
                effective_action = Bottombar.setActiveAndRefreshFM(plugin, "collections", tabs)
            end
        end

        local display_action = effective_action or action_before
        if not widget._navbar_inner then widget._navbar_inner = widget[1] end

        -- Build the bar without navpager arrows for non-pageable widgets to
        -- avoid the flash of arrows that would immediately be removed.
        -- BI descriptor may override the auto-detection via is_pageable.
        local widget_is_pageable
        if _bi_desc ~= nil and _bi_desc.is_pageable ~= nil then
            if type(_bi_desc.is_pageable) == "function" then
                local ok_ip, ip = pcall(_bi_desc.is_pageable, widget)
                widget_is_pageable = ok_ip and ip == true
            else
                widget_is_pageable = _bi_desc.is_pageable == true
            end
        else
            widget_is_pageable = (type(widget.page_num) == "number")
                or (widget.file_chooser and type(widget.file_chooser.page_num) == "number")
        end
        local navbar_container, wrapped, bar, topbar, bar_idx, topbar_on, topbar_idx =
            UI.wrapWithNavbar(widget._navbar_inner, display_action, tabs, not widget_is_pageable)
        UI.applyNavbarState(widget, navbar_container, bar, topbar, bar_idx, topbar_on, topbar_idx, tabs)
        widget._navbar_prev_action = action_before
        widget[1]                  = wrapped

        -- ── Bar Injection API post-injection ────────────────────────────────
        -- When this widget was matched via BI.matchWidget(), handle the extra
        -- descriptor-driven behaviour:
        --   1. Activate the tab the descriptor requested (if any).
        --   2. Store the descriptor on the widget for O(1) lookup at close time
        --      (and to survive a BI.unregister() between show and close).
        --   3. Fire on_inject callback.
        if _bi_desc then
            widget._sui_bi_desc = _bi_desc

            -- Determine and activate the action for this widget.
            local bi_action
            if type(_bi_desc.get_active_action) == "function" then
                local ok_ga, ga_result = pcall(_bi_desc.get_active_action, widget)
                bi_action = ok_ga and ga_result or nil
            else
                bi_action = _bi_desc.active_action_id
            end
            if bi_action then
                Bottombar.setActiveAndRefreshFM(plugin, bi_action, tabs)
            end

            -- on_inject callback.
            if type(_bi_desc.on_inject) == "function" then
                pcall(_bi_desc.on_inject, widget, { plugin = plugin, tabs = tabs })
            end
        end
        -- ────────────────────────────────────────────────────────────────────
        plugin:_registerTouchZones(widget)
        UI.applyGesturePriorityHandleEvent(widget)

        -- Register top-of-screen zones to open the KOReader main menu,
        -- matching what FileManagerMenu:initGesListener does for the FM.
        if widget.registerTouchZones then
            local DTAP_ZONE_MENU     = G_defaults:readSetting("DTAP_ZONE_MENU")
            local DTAP_ZONE_MENU_EXT = G_defaults:readSetting("DTAP_ZONE_MENU_EXT")
            if DTAP_ZONE_MENU and DTAP_ZONE_MENU_EXT then
                local screen_h    = Screen:getHeight()
                local zone_ratio_h
                if SUISettings:nilOrTrue("simpleui_topbar_enabled") then
                    local Topbar = require("sui_topbar")
                    zone_ratio_h = Topbar.TOTAL_TOP_H() / screen_h
                else
                    zone_ratio_h = DTAP_ZONE_MENU.h
                end

                -- Returns true when the tap position falls inside an injected
                -- titlebar button (hamburger, close, etc.) on this widget.
                -- These buttons live in the same top zone as the menu tap zone, so
                -- we must let their taps fall through rather than opening the menu.
                -- We prefer button.dimen (populated after the first paint) and fall
                -- back to the overlap_offset + width values we set explicitly.
                local function _tapOnSubBtn(ges)
                    local pos = ges.pos
                    if not pos then return false end
                    local tb = widget.title_bar
                    -- Collect all injected button refs stored on the widget.
                    local btns = {}
                    if tb and tb.left_button  then btns[#btns+1] = tb.left_button end
                    if tb and tb.right_button then btns[#btns+1] = tb.right_button end
                    local logger = require("logger")
                    logger.dbg("simpleui _tapOnSubBtn: pos=", pos.x, pos.y, "n_btns=", #btns)
                    for i, btn in ipairs(btns) do
                        local hit = false
                        local bw = btn.width or (btn.dimen and btn.dimen.w) or 0
                        local bx_oo = btn.overlap_offset and btn.overlap_offset[1]
                        local bx_dm = btn.dimen and btn.dimen.x
                        logger.dbg("  btn[", i, "] width=", bw,
                            "overlap_offset=", tostring(bx_oo),
                            "dimen.x=", tostring(bx_dm),
                            "dimen.w=", tostring(btn.dimen and btn.dimen.w))
                        if bw <= 0 then goto continue end
                        -- Prefer overlap_offset (set by the plugin, always current)
                        -- over dimen (only populated after paintTo; stale on first tap).
                        if btn.overlap_offset then
                            local bx = btn.overlap_offset[1]
                            hit = pos.x >= bx and pos.x <= bx + bw
                        elseif btn.dimen and btn.dimen.x then
                            hit = pos.x >= btn.dimen.x
                              and pos.x <= btn.dimen.x + bw
                              and pos.y >= (btn.dimen.y or 0)
                              and pos.y <= (btn.dimen.y or 0) + (btn.dimen.h or bw)
                        end
                        logger.dbg("  btn[", i, "] hit=", tostring(hit))
                        if hit then return true end
                        ::continue::
                    end
                    return false
                end

                widget:registerTouchZones({
                    {
                        id          = "simpleui_menu_tap",
                        ges         = "tap",
                        screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = zone_ratio_h },
                        handler     = function(ges)
                            local logger = require("logger")
                            logger.dbg("simpleui_menu_tap FIRED pos=", ges.pos and ges.pos.x, ges.pos and ges.pos.y)
                            if _tapOnSubBtn(ges) then
                                logger.dbg("simpleui_menu_tap: sub btn hit, passing through")
                                return false
                            end
                            local m = _fmMenu(); if m then return m:onTapShowMenu(ges) end
                        end,
                    },
                    {
                        id          = "simpleui_menu_swipe",
                        ges         = "swipe",
                        screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = zone_ratio_h },
                        handler     = function(ges)
                            local m = _fmMenu(); if m then return m:onSwipeShowMenu(ges) end
                        end,
                    },
                })
            end
        end

        -- Resize the return button to match the side margin.
        local rb = widget.return_button
        if rb and rb[1] then rb[1].width = UI.SIDE_M() end

        -- On D-pad devices, pressing Down at the last item enters navbar focus.
        if Device:hasDPad() then
            if rawget(widget, "_wrapAroundY") == nil and type(widget._wrapAroundY) == "function" then
                local origWrapY = widget._wrapAroundY
                widget._wrapAroundY = function(self_w, dy)
                    if dy > 0 and self_w.page == (self_w.total_pages or 1) then
                        M.enterNavbarKbFocus(function()
                            if self_w.layout and self_w.moveFocusTo then
                                self_w:moveFocusTo(1, #self_w.layout, FocusManager().FORCED_FOCUS)
                            end
                        end)
                        return true
                    else
                        return origWrapY(self_w, dy)
                    end
                end
            end
        end

        Bottombar.resizePaginationButtons(widget, Bottombar.getPaginationIconSize())

        if n_extra > 0 then
            orig_show(um_self, widget, table.unpack(extra_args))
        else
            orig_show(um_self, widget)
        end

        -- Clear the subtitle on the injected widget's own title_bar.
        -- Menu:init calls updatePageInfo before UIManager.show, so
        -- _setPageSubtitle may have already written the stale FM path
        -- (_fm_path_base) into the widget's subtitle_widget. Wipe it
        -- here, after orig_show, and also reset the shared upvalue so
        -- future updatePageInfo calls on this widget stay clean.
        do
            local inj_tb = widget.title_bar
            if inj_tb and inj_tb.subtitle_widget then
                local pg     = widget.page     or 0
                local pg_num = widget.page_num or 0
                -- Rebuild subtitle without path: page indicator only (or empty).
                local page_text = ""
                if M._subtitleEnabled and M._subtitleEnabled()
                        and pg_num and pg_num > 1 then
                    local ffiUtil2 = require("ffi/util")
                    page_text = ffiUtil2.template(_("Page %1 of %2"), pg, pg_num)
                end
                inj_tb:setSubTitle(page_text, true)
            end
            -- Also reset the shared upvalue so subsequent updatePageInfo
            -- calls on this widget do not re-inject the FM path.
            M.setFMPathBase("", plugin.ui)
        end

        -- For the homescreen, onShow will call setDirty(self) covering the full
        -- screen immediately after orig_show returns — skip the redundant partial dirty.
        if widget.name ~= "homescreen" then
            UIManager:setDirty(widget[1], "ui")
        end

        -- Paint the wallpaper behind this fullscreen overlay (Collections,
        -- History, etc.) using the same mechanism as patchWallpaperFM.
        pcall(M.injectWallpaperIntoFullscreenWidget, widget)

        -- Schedule a navpager arrow update for the next event-loop tick.
        -- Snapshot has_prev/has_next now to avoid races with a second
        -- updatePageInfo call that may fire during the same tick.
        if SUISettings:isTrue("simpleui_bar_navpager_enabled") and not _navpager_rebuild_pending then
            local has_prev_snap, has_next_snap = Config.getNavpagerState()
            _navpager_rebuild_pending = true
            UIManager:scheduleIn(0, function()
                _navpager_rebuild_pending = false
                if not SUISettings:isTrue("simpleui_bar_navpager_enabled") then return end
                local fm2 = plugin.ui
                if not (fm2 and fm2._navbar_container) then return end
                local target2 = (widget._navbar_container and widget) or fm2
                if not Bottombar.updateNavpagerArrows(target2, has_prev_snap, has_next_snap) then
                    local tabs2   = Config.loadTabConfig()
                    local mode2   = Config.getNavbarMode()
                    local new_bar = Bottombar.buildBarWidgetWithArrows(
                        plugin.active_action, tabs2, mode2, has_prev_snap, has_next_snap)
                    Bottombar.replaceBar(target2, new_bar, tabs2)
                end
                UIManager:setDirty(target2, "ui")
            end)
        end

        end) -- end pcall
        _show_depth = _show_depth - 1
        if not ok then
            logger.warn("simpleui: UIManager.show error:", tostring(result))
        end

        -- Close the homescreen when a different fullscreen widget appears on top.
        -- Exclude widgets that claim covers_fullscreen but are mere popups with no
        -- title_bar and no name (e.g. VocabBuilder's MenuDialog).
        if _show_depth == 0 and widget and widget.covers_fullscreen
                and (widget.title_bar or widget.name)
                and widget.name ~= "homescreen"
                and widget ~= plugin.ui
                and not widget._sui_keep_homescreen then
            local stack = UI.getWindowStack()
            for _, entry in ipairs(stack) do
                local w = entry.widget
                if w and w.name == "homescreen" then
                    w._navbar_closing_intentionally = true
                    w._navbar_closing_from_module   = true
                    UIManager:close(w)
                    w._navbar_closing_intentionally = nil
                    w._navbar_closing_from_module   = nil
                    break
                end
            end
        end
        return result
    end
end

-- ---------------------------------------------------------------------------
-- UIManager.close patch
-- Restores the active tab when an injected widget closes, re-opens the
-- homescreen when "Start with Homescreen" is set, and ensures the homescreen
-- is closed when the FM itself exits (so the app terminates cleanly).
-- Non-fullscreen widgets are passed straight through as a fast path.
-- ---------------------------------------------------------------------------

function M.patchUIManagerClose(plugin)
    -- Guard: only install one wrapper per session. The wrapper lives on the
    -- UIManager global; subsequent installAll calls (triggered by FM recreation
    -- after returning from the reader) must not stack a second wrapper on top.
    --
    -- Without this guard, each FM lifecycle creates a new wrapper that captures
    -- a stale plugin/FM reference, producing a chain of N wrappers after N cycles.
    -- The old wrappers fire on every UIManager:close() and incorrectly enter the
    -- homescreen-restore block because their plugin.ui no longer matches the
    -- widget being closed (FM mismatch → widget_is_fm=false).
    --
    -- On re-entry we update the shared plugin slot so the single live wrapper
    -- always uses the current FM instance for all comparisons.
    if UIManager._simpleui_close_patched then
        UIManager._simpleui_close_plugin = plugin
        -- Give the new plugin instance a back-reference to the original so
        -- teardownAll can restore UIManager.close correctly.
        plugin._orig_uimanager_close = UIManager._simpleui_close_orig
        return
    end
    UIManager._simpleui_close_patched = true
    UIManager._simpleui_close_plugin  = plugin

    local orig_close = UIManager.close
    UIManager._simpleui_close_orig = orig_close
    plugin._orig_uimanager_close   = orig_close

    -- Show the homescreen after any fullscreen widget closes, if conditions allow.
    -- Defined once at patch-install time so it is not recreated on every close().
    local function _doShowHS(fm, plugin_ref)
        local HS = liveHS()
        if not HS or HS._instance then return end

        -- Abort if another fullscreen widget appeared between the scheduleIn(0)
        -- call and this execution (e.g. coll_list opened by onReturn).
        local fm_mod   = package.loaded["apps/filemanager/filemanager"]
        local live_fm2 = fm_mod and fm_mod.instance
        for _, entry in ipairs(UI.getWindowStack()) do
            local w = entry.widget
            if w and w ~= (live_fm2 or fm) and w.covers_fullscreen then return end
        end

        -- Skip if an external caller navigated the FM to a folder.
        local current_fm = live_fm2 or fm
        if current_fm and current_fm._sui_show_folder_pending then
            current_fm._sui_show_folder_pending = nil
            return
        end

        -- Close any orphaned non-fullscreen widgets before showing the HS.
        _closeOrphanedPopups(fm, nil)

        local prev_action = plugin_ref.active_action
        _showHSCold(plugin_ref, HS, prev_action)
    end

    UIManager.close = function(um_self, widget, ...)
        -- Fast path: non-fullscreen widgets need no SimpleUI logic.
        if not (widget and widget.covers_fullscreen) then
            return orig_close(um_self, widget, ...)
        end

        -- Resolve the active plugin reference at call time, not from the
        -- upvalue captured at install time.  The shared slot is updated on
        -- every installAll cycle so this always points to the current plugin
        -- instance (and therefore the current FM via .ui).
        local active_plugin = UIManager._simpleui_close_plugin

        -- Identify a closing FM by identity (FM has no .name at class level).
        local widget_is_fm = (widget == active_plugin.ui)

        -- Restore the active tab when an injected widget closes normally.
        -- Clear _navbar_injected immediately so a second close() is a no-op.
        if widget._navbar_injected and not widget._navbar_closing_intentionally then
            widget._navbar_injected = nil

            if widget.name == "coll_list" then
                -- coll_list sits on top of collections; find what to restore.
                -- If there is still a collections/coll_list widget underneath,
                -- the user is going back to the collections list — so keep the
                -- "collections" tab active (if it is in the tab bar).
                -- Only fall back to _navbar_prev_action when there is no
                -- matching underlying widget (edge-case: collections tab absent).
                local fm = liveFM()
                if fm and fm._navbar_container then
                    local t       = Config.loadTabConfig()
                    local restored = nil
                    local underlying_coll = nil
                    for _, entry in ipairs(UI.getWindowStack()) do
                        local w = entry.widget
                        if w and w ~= widget and w._navbar_injected
                                and (w.name == "collections" or w.name == "coll_list") then
                            underlying_coll = w
                            break
                        end
                    end
                    if underlying_coll then
                        -- Going back to the collections list: activate the
                        -- "collections" tab, or if absent use the underlying
                        -- widget's prev_action.
                        local tabs_set = {}
                        for _, tid in ipairs(t) do tabs_set[tid] = true end
                        if tabs_set["collections"] then
                            restored = "collections"
                        else
                            restored = underlying_coll._navbar_prev_action
                        end
                    end
                    if not restored then
                        restored = (fm.file_chooser
                            and M._resolveTabForPath(fm.file_chooser.path, t))
                            or t[1] or "home"
                    end
                    active_plugin.active_action = restored
                    Bottombar.replaceBar(fm, Bottombar.buildBarWidget(restored, t), t)
                    UIManager:setDirty(fm, "ui")
                end
            else
                active_plugin:_restoreTabInFM(nil, widget._navbar_prev_action)
            end

            -- Restore _fm_path_base from the FM's current folder so the
            -- breadcrumb reappears in the subtitle after the overlay closes.
            local fm_r = liveFM()
            if fm_r then
                local fc_r = fm_r.file_chooser
                if fc_r and fc_r.path then
                    pcall(function() fm_r:updateTitleBarPath(fc_r.path, false) end)
                end
            end
        end

        -- ── Bar Injection API on_close callback ─────────────────────────────
        -- Use the descriptor reference stored at inject time (widget._sui_bi_desc)
        -- so this fires correctly even when BI.unregister() was called meanwhile.
        local _bi_close_desc = widget._sui_bi_desc
        if _bi_close_desc and type(_bi_close_desc.on_close) == "function" then
            pcall(_bi_close_desc.on_close, widget, { plugin = active_plugin })
        end
        -- ────────────────────────────────────────────────────────────────────

        -- The homescreen is closed on FM exit via SimpleUIPlugin:onCloseWidget,
        -- which uses self.ui.tearing_down as the discriminator (set only when
        -- the reader is opening, not on exit). Nothing to do here.

        local result = orig_close(um_self, widget, ...)

        -- Lazy FM refresh: consume the flag set when the reader closed with
        -- return_to_folder=false. The HS was on top — now that it is closing,
        -- the FM is about to become visible. Schedule refreshPath() for the
        -- next event-loop tick so it runs after the HS teardown is complete.
        -- Guard: only when the HS is closing normally (not intentionally, which
        -- is the tab-switch path that does not expose the FM file list).
        if widget.name == "homescreen"
                and not widget._navbar_closing_intentionally then
            local fm_lazy = liveFM()
            if fm_lazy and fm_lazy._sui_lazy_refresh_path then
                fm_lazy._sui_lazy_refresh_path = nil
                UIManager:scheduleIn(0, function()
                    local fm_ref = liveFM()
                    if fm_ref and fm_ref.file_chooser then
                        fm_ref.file_chooser:refreshPath()
                    end
                end)
            end
        end

        -- Re-open the homescreen after a fullscreen widget closes, subject to guards.
        -- Exclude widgets that claim covers_fullscreen but are mere popups with no
        -- title_bar and no name (e.g. VocabBuilder's MenuDialog).
        --
        -- Primary reader→HS paths are handled upstream (flash-free):
        --   • Bottombar tab tap   → navigate() → closeReaderToHomescreen
        --   • Gesture             → onSimpleUIGoHomescreen → closeReaderToHomescreen
        --   • Native FM menu tab  → wireReaderMenuFMTab callback
        -- closeReaderToHomescreen sets tearing_down=true, so the ReaderUI branch
        -- below is skipped for those paths. This block is a last-resort fallback
        -- for any path not covered above (e.g. a third-party plugin closing the reader).
        if isStartWithHS()
                and widget.covers_fullscreen
                and (widget.title_bar or widget.name)
                and widget.name ~= "homescreen"
                and not widget_is_fm
                and not widget._navbar_closing_intentionally
                and not widget._navbar_hs_scheduled
                and not (widget._manager and widget._manager.folder_shortcuts)
                and UIManager._exit_code == nil then
            widget._navbar_hs_scheduled = true
            local fm = liveFM()
            local other_open = false
            for _, entry in ipairs(UI.getWindowStack()) do
                local w = entry.widget
                if w and w ~= fm and w ~= widget and w.covers_fullscreen then
                    other_open = true; break
                end
            end
            if not other_open then
                if widget.name == "ReaderUI" then
                    -- Fallback: reader closed without going through closeReaderToHomescreen.
                    -- tearing_down guards against double-firing with that function.
                    if not widget.tearing_down then
                        local return_to_folder = SUISettings:isTrue("simpleui_hs_return_to_book_folder")
                        if not return_to_folder then
                            local prev_action = active_plugin.active_action
                            local _ao2 = { bookmark_browser=true, wifi_toggle=true, frontlight=true, power=true }
                            if active_plugin.active_action == nil or not _ao2[active_plugin.active_action] then
                                active_plugin.active_action = "homescreen"
                            end
                            local fm_ref = liveFM()
                            if fm_ref then fm_ref._sui_lazy_refresh_path = true end
                            UIManager:nextTick(function()
                                if UIManager._exit_code ~= nil then return end
                                -- If the FM is already gone, the app is exiting
                                -- (exit from reader: FM closes before this tick runs).
                                if not liveFM() then return end
                                local RUI2 = package.loaded["apps/reader/readerui"]
                                if RUI2 and RUI2.instance then return end
                                if _raiseHSFromStack(active_plugin, prev_action) then return end
                                local HS2 = liveHS()
                                if not (HS2 and not HS2._instance) then return end
                                _showHSCold(active_plugin, HS2, prev_action)
                            end)
                        else
                            UIManager:scheduleIn(0, function()
                                local fm_ref = liveFM()
                                if fm_ref and fm_ref.file_chooser then
                                    fm_ref.file_chooser:refreshPath()
                                end
                            end)
                        end
                    end
                else
                    UIManager:scheduleIn(0, function()
                        if UIManager._exit_code ~= nil then return end
                        local fm2 = liveFM()
                        if not fm2 then return end  -- FM gone = app is exiting
                        local RUI = package.loaded["apps/reader/readerui"]
                        if RUI and RUI.instance then return end
                        _doShowHS(fm2, active_plugin)
                    end)
                end
            end
        end

        return result
    end
end

-- ---------------------------------------------------------------------------
-- Menu.init patch — pagination bar visibility
-- Removes the pagination bar from fullscreen FM-style menus when
-- "navbar_pagination_visible" is off, and fixes horizontal swipe propagation.
-- ---------------------------------------------------------------------------

function M.patchMenuInitForPagination(plugin)
    local Menu = require("ui/widget/menu")
    local TARGET_NAMES = {
        filemanager = true, history = true, collections = true, coll_list = true,
    }
    local orig_menu_init  = Menu.init
    plugin._orig_menu_init = orig_menu_init

    Menu.init = function(menu_self, ...)
        -- Centralised keyboard-shortcut indicator suppression.
        -- These are the lettered badges (W, E, R, …) drawn over book covers
        -- on devices with a physical keyboard.  They overlap cover art and are
        -- redundant on touch-first devices.
        --
        -- To re-enable the indicators, change the constant below to `true`:
        --   local SUI_SHOW_SHORTCUT_INDICATORS = true
        local SUI_SHOW_SHORTCUT_INDICATORS = false
        if not SUI_SHOW_SHORTCUT_INDICATORS then
            menu_self.is_enable_shortcut = false
        end

        orig_menu_init(menu_self, ...)

        -- Apply icon overrides for collections/history/FM menus.
        pcall(function()
            local ok_ss, SS = pcall(require, "sui_style")
            if not (ok_ss and SS) then return end
            -- Pagination chevrons: present in all fullscreen menus after init().
            if SS.applyPaginationIcons then
                SS.applyPaginationIcons(menu_self)
            end
            -- Collections back button: only present in collections/coll_list.
            if SS.applyCollBackIcon
                    and (menu_self.name == "collections" or menu_self.name == "coll_list") then
                SS.applyCollBackIcon(menu_self)
            end
        end)

        -- Fix: Menu:onSwipe does not return true, so horizontal swipes propagate
        -- to FM's filemanager_swipe zone and advance two pages. Wrap onSwipe to
        -- consume the event after it is handled.
        local is_target = TARGET_NAMES[menu_self.name]
            or (menu_self.covers_fullscreen and menu_self.is_borderless and menu_self.title_bar_fm_style)
        if is_target then
            local orig_onSwipe = menu_self.onSwipe
            menu_self.onSwipe = function(self_m, arg, ges_ev)
                if orig_onSwipe then
                    orig_onSwipe(self_m, arg, ges_ev)
                else
                    Menu.onSwipe(self_m, arg, ges_ev)
                end
                return true
            end
        end

        if SUISettings:nilOrTrue("simpleui_bar_pagination_visible") then return end
        -- The structural fallback below (covers_fullscreen + is_borderless +
        -- title_bar_fm_style) is also matched by native KOReader Menus that are
        -- NOT FM-style overlays — e.g. ReaderSearch's "all results" Menu
        -- (readersearch.lua sets all three flags too) — which only ever shows
        -- while the FileManager is closed (book open, Reader active). Without
        -- the liveFM() check, opening that menu while "Hide pagination bar" is
        -- on would silently strip its page indicator and back button.
        -- liveFM() ~= nil restricts the fallback to menus actually created
        -- while FM is the active screen (e.g. Collections' property/folder
        -- sub-lists, which have no explicit name), matching the same intent
        -- as TARGET_NAMES without re-exposing the Reader-side leak.
        local is_fm_style_overlay = menu_self.covers_fullscreen
                                 and menu_self.is_borderless
                                 and menu_self.title_bar_fm_style
                                 and liveFM() ~= nil
        if not TARGET_NAMES[menu_self.name] and not is_fm_style_overlay then
            return
        end

        -- Collections widgets historically kept their layout untouched because the
        -- native page_return_arrow lived inside return_button and was needed for
        -- back-navigation. Since sui_titlebar.applyToSub now suppresses both
        -- return_button and page_return_arrow (and owns back-navigation via
        -- sub_back_btn), that concern no longer applies.
        --
        -- The user has explicitly asked to hide the pagination bar (general setting),
        -- so honour that for collections / coll_list just like History and FM.

        -- Remove all children except content_group to strip the pagination row
        -- (page_info, return_button, etc.).
        local content = menu_self[1] and menu_self[1][1]
        if content then
            for i = #content, 1, -1 do
                if content[i] ~= menu_self.content_group then
                    table.remove(content, i)
                end
            end
        end

        -- Override _recalculateDimen to suppress pagination widget updates.
        -- page_return_arrow and page_info are no longer layout children here,
        -- so nil them out during the call to prevent KOReader sizing them.
        menu_self._recalculateDimen = function(self_inner, no_recalculate_dimen)
            local saved_arrow = self_inner.page_return_arrow
            local saved_text  = self_inner.page_info_text
            local saved_info  = self_inner.page_info
            self_inner.page_return_arrow = nil
            self_inner.page_info_text    = nil
            self_inner.page_info         = nil
            local instance_fn = self_inner._recalculateDimen
            self_inner._recalculateDimen = nil
            local ok, err = pcall(function()
                self_inner:_recalculateDimen(no_recalculate_dimen)
            end)
            self_inner._recalculateDimen = instance_fn
            self_inner.page_return_arrow = saved_arrow
            self_inner.page_info_text    = saved_text
            self_inner.page_info         = saved_info
            if not ok then error(err, 2) end
        end
        menu_self:_recalculateDimen()
    end
end

-- ---------------------------------------------------------------------------
-- Menu.updatePageInfo + FileManager.updateTitleBarPath patches — navpager
-- Rebuilds the navpager arrows and the title-bar subtitle after every page
-- turn or directory change. Updates are coalesced per event-loop tick.
-- ---------------------------------------------------------------------------

function M.patchMenuForNavpager(plugin)
    -- Keep the shared live-plugin pointer fresh regardless of call order
    -- relative to patchFileManagerClass (installAll already calls this after
    -- patchFileManagerClass, but this guards against future reordering).
    _live_plugin = plugin

    local Menu = require("ui/widget/menu")
    if Menu._simpleui_navpager_patched then return end
    Menu._simpleui_navpager_patched = true

    -- Resolved once as upvalues; used in the hot paths below.
    local ffiUtil   = require("ffi/util")
    local _template = ffiUtil.template

    -- Returns the topmost fullscreen widget that has a navbar, falling back
    -- to the FM. Prevents bar updates going to the FM when an injected widget
    -- (Collections, Favorites…) is currently visible on top.
    local function _getNavbarTarget(fm)
        local stack = UI.getWindowStack()
        for i = #stack, 1, -1 do
            local w = stack[i] and stack[i].widget
            if w and w.covers_fullscreen and w._navbar_container then return w end
        end
        return fm
    end
    M._getNavbarTarget = _getNavbarTarget

    -- True when any subtitle (page indicator or pagination subtitle) should show.
    local function _subtitleEnabled()
        return SUISettings:isTrue("simpleui_bar_navpager_enabled")
            or SUISettings:isTrue("simpleui_bar_pagination_show_subtitle")
    end
    M._subtitleEnabled = _subtitleEnabled

    -- _fm_path_base: the path string last set by updateTitleBarPath (empty at home).
    local _fm_path_base = ""

    -- Writes the unified subtitle (path + "Page X of Y") in a single call.
    local function _setSubtitleUnified(tb, path_base, page, page_num)
        if not tb or not tb.subtitle_widget then return end
        local parts = {}
        if path_base and path_base ~= "" then
            parts[#parts + 1] = path_base
        end
        if _subtitleEnabled() and page_num and page_num > 1 then
            parts[#parts + 1] = _template(_("Page %1 of %2"), page, page_num)
        end
        tb:setSubTitle(table.concat(parts, "  ·  "), true)
    end

    -- menu_self is optional; when provided and the widget is an injected overlay
    -- (history, collections, …) the FM path prefix is suppressed so it does not
    -- bleed into a foreign title bar.
    local function _setPageSubtitle(tb, page, page_num, menu_self)
        if not tb or not tb.subtitle_widget then return end
        local path_base = (menu_self and menu_self._navbar_injected) and "" or _fm_path_base
        _setSubtitleUnified(tb, path_base, page, page_num)
    end
    M._setPageSubtitle = _setPageSubtitle

    -- Called by external modules (e.g. sui_foldercovers) when entering a virtual
    -- folder that does not go through updateTitleBarPath.
    function M.setFMPathBase(text, fm_self)
        _fm_path_base = text or ""
        if fm_self then
            local tb = fm_self.title_bar
            local fc = fm_self.file_chooser
            if tb and tb.subtitle_widget then
                local pg     = fc and (fc.page     or 0) or 0
                local pg_num = fc and (fc.page_num or 0) or 0
                _setSubtitleUnified(tb, _fm_path_base, pg, pg_num)
            end
        end
    end

    -- Hook Menu.updatePageInfo to keep the subtitle and navpager arrows in sync.
    local orig_updatePageInfo          = Menu.updatePageInfo
    plugin._orig_menu_update_page_info = orig_updatePageInfo

    Menu.updatePageInfo = function(menu_self, select_number)
        orig_updatePageInfo(menu_self, select_number)

        -- Fix: when the plugin has shrunk a fullscreen menu to getContentHeight(),
        -- its dimen no longer covers the native page_info bar. Force a targeted
        -- setDirty so CoverBrowser's chevrons repaint after each page turn.
        if menu_self.page_info and menu_self._navbar_injected then
            UIManager:setDirty(menu_self.show_parent or menu_self, "ui",
                menu_self.page_info.dimen)
        end

        if not _subtitleEnabled() then return end

        -- Read page state synchronously, exactly as the native bar does:
        -- orig_updatePageInfo has already run _recalculateDimen, so page and
        -- page_num are authoritative at this point.
        local captured_page     = menu_self.page     or 0
        local captured_page_num = menu_self.page_num or 0

        -- Update the subtitle synchronously.
        -- Pass menu_self so injected overlays (history, collections) do not
        -- inherit the FM's current path in their subtitle.
        _setPageSubtitle(menu_self.title_bar, captured_page, captured_page_num, menu_self)

        -- Navpager arrow update: coalesce multiple calls within the same tick,
        -- but read page/page_num from menu_self at execution time (not from the
        -- snapshot above). This mirrors the native bar's logic — it always reads
        -- self.page and self.page_num at the moment it runs — and avoids stale
        -- snapshots when switchItemTable fires updatePageInfo before UIManager:show
        -- (e.g. Collections, History), or when a second call in the same tick
        -- would overwrite a pending snapshot with wrong values.
        --
        -- The reference to menu_self is safe: the closure only executes one tick
        -- later while the widget is alive (it was just shown or just updated).
        if _navpager_rebuild_pending then return end
        _navpager_rebuild_pending = true

        UIManager:scheduleIn(0, function()
            _navpager_rebuild_pending = false
            if not SUISettings:isTrue("simpleui_bar_navpager_enabled") then return end
            -- Resolve the live plugin instance: Menu._simpleui_navpager_patched
            -- guards this whole patch to a single installation per session, so
            -- the `plugin` upvalue captured above can go stale once the FM is
            -- recreated (reader return, rotation, suspend/resume). Falling back
            -- to plugin.ui/.active_action on a stale instance here would build
            -- the navpager-arrow bar against the wrong active tab.
            local plugin = _live_plugin or plugin
            local fm = plugin.ui
            if not (fm and fm._navbar_container) then return end
            -- Re-read page state from the live widget at execution time.
            -- This is the same source of truth the native bar uses and guarantees
            -- correctness regardless of when updatePageInfo was called relative
            -- to UIManager:show (Collections/History call switchItemTable before
            -- show, so the snapshot taken above may precede the final page_num).
            local live_page     = menu_self.page     or 0
            local live_page_num = menu_self.page_num or 0
            local has_prev = live_page > 1
            local has_next = live_page < live_page_num
            local target = _getNavbarTarget(fm)
            if not Bottombar.updateNavpagerArrows(target, has_prev, has_next) then
                local tabs    = Config.loadTabConfig()
                local mode    = Config.getNavbarMode()
                local new_bar = Bottombar.buildBarWidgetWithArrows(
                    plugin.active_action, tabs, mode, has_prev, has_next)
                Bottombar.replaceBar(target, new_bar, tabs)
            end
            UIManager:setDirty(target, "ui")
        end)
    end

    -- Hook FileManager.updateTitleBarPath to update the subtitle and the
    -- back-button visibility on every directory navigation.
    -- The FM calls this instead of updatePageInfo, so it needs its own patch.
    local FileManager = package.loaded["apps/filemanager/filemanager"]
        or require("apps/filemanager/filemanager")

    -- Normalise a filesystem path: strip trailing slash and resolve symlinks.
    local function _norm(p)
        if not p then return "" end
        p = p:gsub("/$", "")
        local ok, rp = pcall(ffiUtil.realpath, p)
        if ok and rp then p = rp:gsub("/$", "") end
        return p
    end

    local orig_updateTitleBarPath          = FileManager.updateTitleBarPath
    plugin._orig_fm_updateTitleBarPath     = orig_updateTitleBarPath

    FileManager.updateTitleBarPath = function(fm_self, path, force_home)
        local fc_path    = fm_self.file_chooser and fm_self.file_chooser.path or nil
        local home_dir   = _norm(G_reader_settings:readSetting("home_dir"))
        local clean_path = _norm(path or fc_path)
        local at_home    = force_home or (home_dir ~= "" and clean_path == home_dir)

        -- Determine whether we are at the filesystem root (back button hidden).
        -- Delegate to sui_titlebar's isAtRoot which owns the single authoritative
        -- criterion (virtual paths, series-view, lock_home_folder all handled there).
        local fc_cur  = fm_self.file_chooser
        local ok_ti, TI = pcall(require, "sui_titlebar")
        local at_root
        if ok_ti and TI and TI.isAtRoot then
            at_root = TI.isAtRoot(fc_cur)
        else
            -- Fallback: path-only check when sui_titlebar is unavailable.
            at_root = (clean_path == "/")
            if not at_root and G_reader_settings:isTrue("lock_home_folder") and at_home then
                at_root = true
            end
        end

        -- Show or hide the back button and adjust the search button position.
        local tb = fm_self.title_bar
        if tb and tb.left_button and fm_self._titlebar_patched then
            if at_root then
                tb.left_button.overlap_offset = { Screen:getWidth() + 100, 0 }
                tb.left_button.callback       = function() end
                tb.left_button.hold_callback  = function() end
                local sb = fm_self._titlebar_search_btn
                local x  = fm_self._simpleui_search_x_compact
                if sb and x and sb.overlap_offset then sb.overlap_offset = { x, 0 } end
            else
                local sb = fm_self._titlebar_search_btn
                local x  = fm_self._simpleui_search_x
                if sb and x and sb.overlap_offset then sb.overlap_offset = { x, 0 } end
            end
            UIManager:setDirty(tb.show_parent or fm_self, "ui", tb.dimen)
        end

        -- Build the subtitle: empty at home, path text in subfolders.
        -- Call the original first when in a subfolder so it writes the path text,
        -- then read it back so _setSubtitleUnified can combine path + page in one write.
        if at_home then
            _fm_path_base = ""
        else
            orig_updateTitleBarPath(fm_self, path)
            local tb2     = fm_self.title_bar
            _fm_path_base = (tb2 and tb2.subtitle_widget and tb2.subtitle_widget.text) or ""
        end

        local fc = fm_self.file_chooser
        local tb3 = fm_self.title_bar
        if tb3 and tb3.subtitle_widget then
            local pg     = fc and (fc.page     or 0) or 0
            local pg_num = fc and (fc.page_num or 0) or 0
            _setSubtitleUnified(tb3, _fm_path_base, pg, pg_num)
        end
    end
end

-- ---------------------------------------------------------------------------
-- showHSAfterResume
-- Opens the homescreen after the device wakes from suspend.
--
-- Normal mode (force=false/nil): runs only when "Start with Homescreen" is
-- active, the reader is closed, and the homescreen is not already visible.
-- The homescreen tab does NOT need to be present in the navbar for this to
-- fire.
--
-- Forced mode (force=true): used by "Return to Home Screen on Wakeup". Bypasses
-- the isStartWithHS() gate entirely, and — unlike normal mode — also handles
-- the reader being open: it closes the reader via closeReaderToHomescreen()
-- first (which raises/shows the HS itself), then returns. This lets the
-- feature work even when the user was mid-book at the moment of suspend.
--
-- Called from SimpleUIPlugin:onResume() in main.lua.
-- ---------------------------------------------------------------------------

function M.showHSAfterResume(plugin, force)
    if not (force or isStartWithHS()) then return end

    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance then
        if not force then return end
        -- Forced path: the reader is open on wakeup but the user wants the
        -- Homescreen regardless. closeReaderToHomescreen() already performs
        -- onClose(false) + showFileManager() + raising/showing the HS (or
        -- landing in the book's folder if "Return to Book Folder" is on),
        -- so there is nothing left to do here once it has been scheduled.
        M.closeReaderToHomescreen(plugin, false)
        return
    end

    local tabs = Config.loadTabConfig()
    -- Note: we intentionally do NOT require the "homescreen" tab to be in
    -- the navbar. "Start with Home Screen" is a launch behaviour that should
    -- work regardless of whether the user keeps the tab visible.

    local HS = liveHS()
    if HS and HS._instance then
        -- The homescreen was already open when the device suspended (e.g. the
        -- touch menu was open on top of it).  We must NOT re-show the HS, but
        -- we DO need to refresh the QA tap callback in case it captured a now-
        -- stale FileManager reference.  main.lua:onResume does this too, but
        -- the callback here is the authoritative one passed to HS.show() — keep
        -- both in sync so whichever fires first is already correct.
        HS._instance._on_qa_tap = _makeQaTap(plugin)
        return
    end

    if UIManager._exit_code ~= nil then return end

    -- Defer until the event loop has settled after the resume chain.
    UIManager:scheduleIn(0, function()
        if UIManager._exit_code ~= nil then return end
        local RUI2 = package.loaded["apps/reader/readerui"]
        if RUI2 and RUI2.instance then return end
        local HS2 = liveHS()
        if HS2 and HS2._instance then
            -- Same staleness guard for the deferred path: the HS appeared
            -- between the outer check and the scheduleIn(0) callback.
            HS2._instance._on_qa_tap = _makeQaTap(plugin)
            return
        end

        local fm = liveFM()
        if not fm then return end

        if not HS2 then
            local ok, m = pcall(require, "sui_homescreen")
            HS2 = ok and m
        end
        if not HS2 then return end

        local t           = Config.loadTabConfig()
        local prev_action = plugin.active_action
        Bottombar.setActiveAndRefreshFM(plugin, "homescreen", t)
        _ensureGoalCallback(plugin)
        -- Always start at page 1 after resume; restoring the last page
        -- would be disorienting after waking from standby.
        HS2._current_page = 1
        HS2.show(_makeQaTap(plugin), plugin._goalTapCallback)
        local hs_inst = HS2._instance
        if hs_inst then hs_inst._navbar_prev_action = prev_action end
    end)
end

-- ---------------------------------------------------------------------------
-- Book Information dialog — restore FM path on close
-- ---------------------------------------------------------------------------
-- When "Book information" is opened from the File Manager, the KeyValuePage
-- (KVP) widget is fullscreen.  When it closes, patchUIManagerClose sees no
-- other fullscreen widget on the stack (the FM itself is explicitly excluded
-- from the "other_open" check) and therefore calls _doShowHS, which pushes
-- the HomeScreen on top of the FM.  This does not happen when the same dialog
-- is opened from History, because History is still on the stack as a second
-- fullscreen widget, so other_open = true and _doShowHS is skipped.
--
-- Fix: wrap filemanagerutil.genBookInformationButton so that, when the caller
-- is the FM (not the reader), we (a) record the current file_chooser path
-- before the dialog opens and (b) inject a wrapper around the KVP's
-- close_callback that sets _sui_show_folder_pending = true (suppresses
-- _doShowHS) and calls changeToPath to restore the folder if the FM drifted.
-- ---------------------------------------------------------------------------

function M.patchBookInfoNavigation(plugin)
    local ok_util, fmutil = pcall(require, "apps/filemanager/filemanagerutil")
    if not ok_util or not fmutil then return end
    if fmutil._simpleui_bookinfo_nav_patched then return end
    fmutil._simpleui_bookinfo_nav_patched = true

    local orig_gen = fmutil.genBookInformationButton
    plugin._orig_fmutil_gen_bookinfo = orig_gen

    fmutil.genBookInformationButton = function(doc_settings_or_file, book_props, caller_callback, button_disabled)
        local btn = orig_gen(doc_settings_or_file, book_props, caller_callback, button_disabled)
        local orig_cb = btn.callback
        btn.callback = function()
            -- Capture the FM path *before* orig_cb fires (orig_cb calls
            -- caller_callback which closes the file-dialog, then shows the KVP).
            local FileManager = require("apps/filemanager/filemanager")
            local fm = FileManager.instance
            local saved_path = fm and fm.file_chooser and fm.file_chooser.path

            orig_cb()

            -- Only intervene when called from the FM (not from the reader).
            if not saved_path then return end
            if not (fm and fm.bookinfo and fm.bookinfo.kvp_widget) then return end

            local kvp = fm.bookinfo.kvp_widget
            local orig_close_cb = kvp.close_callback
            kvp.close_callback = function()
                -- Run the original close_callback first (metadata broadcast etc.).
                if orig_close_cb then orig_close_cb() end

                -- Suppress _doShowHS: by the time scheduleIn(0) fires this flag
                -- will be checked and the HS open will be skipped.
                local fm2 = require("apps/filemanager/filemanager").instance
                if fm2 then
                    fm2._sui_show_folder_pending = true
                    -- Restore the folder the user was browsing, in case the FM
                    -- drifted (e.g. a metadata write triggered a path change).
                    if fm2.file_chooser and fm2.file_chooser.path ~= saved_path then
                        fm2.file_chooser:changeToPath(saved_path)
                    end
                end
            end
        end
        return btn
    end
end

-- ---------------------------------------------------------------------------
-- Fix: wrap filemanagerutil.genStatusButtonsRow (and genMultipleStatusButtonsRow)
-- so that marking a book as finished/reading/abandoned from the library
-- immediately invalidates the StatsProvider cache and the sidecar cache entry.
--
-- Without this patch, SP.invalidate() is only called from onCloseDocument
-- (when a book is actually opened and then closed). Setting the status from
-- the library writes the sidecar directly via filemanagerutil.saveSummary but
-- no event is broadcast, so books_year/books_total stay stale until the next
-- reading session.
--
-- Strategy: wrap both genStatusButtonsRow and genMultipleStatusButtonsRow so
-- that each status-button callback, after doing its own work and calling the
-- original caller_callback, also:
--   1. Invalidates the sidecar cache entry for the affected file (so the next
--      prefetchBooks() re-reads the updated summary instead of using the
--      stale cached value).
--   2. Calls SP.invalidate() to discard the books_year/books_total counts so
--      the next homescreen render re-runs the sidecar scan.
--   3. Sets HS._stats_need_refresh = true so the homescreen rebuilds when it
--      next becomes visible (mirrors what onCloseDocument does).
-- ---------------------------------------------------------------------------

local function _onStatusChanged(file)
    -- 0. If the book is no longer "complete", remove it from the deleted-books
    --    store (in case it was previously deleted then re-added by the user and
    --    its status is now being changed back to reading/abandoned).
    --    We read the sidecar — saveSummary has already flushed the new status
    --    to disk before caller_callback() is invoked, so this is always current.
    pcall(function()
        local DB = SUISettings.DeletedBooks
        if not (DB and DB.isEnabled()) then return end
        local ok_DS, DocSettings = pcall(require, "docsettings")
        if not ok_DS or not DocSettings then return end
        local ds = DocSettings:open(file)
        local summary = ds:readSetting("summary")
        local new_status = type(summary) == "table" and summary.status or nil
        if new_status ~= "complete" then
            local md5 = ds:readSetting("partial_md5_checksum")
            pcall(function() ds:close() end)
            if md5 then DB.removeByMd5(md5) end
        else
            pcall(function() ds:close() end)
        end
    end)

    -- 1. Invalidate the sidecar cache for this file so the stale summary is
    --    not reused when the homescreen re-renders.
    local SH = package.loaded["desktop_modules/module_books_shared"]
    if SH and SH.invalidateSidecarCache then
        pcall(SH.invalidateSidecarCache, file)
    end

    -- 2. Invalidate the StatsProvider cache so books_year/books_total are
    --    re-counted from sidecars on the next render.
    local SP = package.loaded["desktop_modules/module_stats_provider"]
    if SP and SP.invalidate then
        pcall(SP.invalidate)
    end

    -- 3. Invalidate the homescreen context cache and flag for stats refresh.
    --    _stats_need_refresh alone is not enough: onShow() reads it but then
    --    calls _updatePage(keep_cache=true), which reuses _ctx_cache — so the
    --    stale ctx.stats survives. We must also clear _ctx_cache so that the
    --    next _updatePage() call re-runs _buildCtx() and fetches fresh stats
    --    from the now-invalidated StatsProvider.
    local ok_hs, HS = pcall(require, "sui_homescreen")
    if ok_hs and HS then
        -- Flag for the class-level check in onShow.
        HS._stats_need_refresh = true
        -- Also clear the cache on the live instance (if the HS is currently
        -- open behind the FM/library dialog).
        local inst = HS._instance
        if inst then
            inst._ctx_cache          = nil
            inst._stats_need_refresh = true
        end
    end
end

function M.patchStatusButtons(plugin)
    local ok_util, fmutil = pcall(require, "apps/filemanager/filemanagerutil")
    if not ok_util or not fmutil then return end
    if fmutil._simpleui_status_buttons_patched then return end
    fmutil._simpleui_status_buttons_patched = true

    -- ── genStatusButtonsRow ────────────────────────────────────────────────
    -- The single-file variant changes status directly (no ConfirmBox), but
    -- using caller_callback injection is simpler and equally correct: the
    -- status is written before caller_callback() is called inside orig_gen_row.
    local orig_gen_row = fmutil.genStatusButtonsRow
    plugin._orig_fmutil_gen_status_row = orig_gen_row

    fmutil.genStatusButtonsRow = function(doc_settings_or_file, caller_callback)
        -- Resolve the filepath once, before the buttons are built.
        local file
        if type(doc_settings_or_file) == "table" then
            file = doc_settings_or_file:readSetting("doc_path")
        else
            file = doc_settings_or_file
        end

        local wrapped_callback = function()
            if caller_callback then caller_callback() end
            if file then _onStatusChanged(file) end
        end
        return orig_gen_row(doc_settings_or_file, wrapped_callback)
    end

    -- ── genMultipleStatusButtonsRow ────────────────────────────────────────
    -- genMultipleStatusButtonsRow shows a ConfirmBox before actually changing
    -- the status. We cannot wrap btn.callback (it fires before confirmation).
    -- Instead, we inject _onStatusChanged into the caller_callback so it runs
    -- after the status has been written to disk (inside ok_callback → caller_callback).
    local orig_gen_multi = fmutil.genMultipleStatusButtonsRow
    plugin._orig_fmutil_gen_status_multi = orig_gen_multi

    fmutil.genMultipleStatusButtonsRow = function(files, caller_callback, button_disabled)
        local wrapped_callback = function()
            if caller_callback then caller_callback() end
            if type(files) == "table" then
                for f in pairs(files) do
                    _onStatusChanged(f)
                end
            end
        end
        return orig_gen_multi(files, wrapped_callback, button_disabled)
    end
end

function M.unpatchStatusButtons(plugin)
    local fmutil = package.loaded["apps/filemanager/filemanagerutil"]
    if not fmutil or not fmutil._simpleui_status_buttons_patched then return end

    if plugin._orig_fmutil_gen_status_row then
        fmutil.genStatusButtonsRow        = plugin._orig_fmutil_gen_status_row
        plugin._orig_fmutil_gen_status_row = nil
    end
    if plugin._orig_fmutil_gen_status_multi then
        fmutil.genMultipleStatusButtonsRow        = plugin._orig_fmutil_gen_status_multi
        plugin._orig_fmutil_gen_status_multi      = nil
    end
    fmutil._simpleui_status_buttons_patched = nil
end

-- ---------------------------------------------------------------------------
-- Fix: wrap filemanagerutil.genResetSettingsButton (and
-- genMultipleResetSettingsButton) so that resetting a document's settings
-- from an FM dialog ("Reset" button — file long-press, Collections, History,
-- file searcher) also invalidates the StatsProvider cache and the sidecar
-- cache entry, exactly like the status-change buttons above.
--
-- Resetting a document purges its whole sidecar file, including
-- summary.status. A book previously marked "complete" silently drops out of
-- books_year/books_total, but nothing tells the homescreen to re-count, so
-- the stale (too high) figure lingers until the next unrelated SP.invalidate()
-- trigger (opening/closing a book, a status-button press elsewhere, etc.).
--
-- Reuses _onStatusChanged(file): after the purge, the sidecar is gone, so
-- DocSettings:open(file) opens a fresh empty sidecar and reads back no
-- summary — new_status is nil, which is treated as "not complete", so the
-- helper clears the sidecar cache entry, invalidates SP, flags the
-- homescreen for a refresh, and (best-effort) drops any stale DeletedBooks
-- entry for the file. Note this is *not* about the separate
-- "simpleui_preserve_deleted_books_in_stats" DeletedBooks feature, which
-- only fires on actual file deletion (see patchDeleteFile above) — this
-- patch is purely about keeping the homescreen's books_year/books_total
-- counters in sync when a "complete" book's sidecar is reset without being
-- deleted.
-- ---------------------------------------------------------------------------
function M.patchResetSettingsButton(plugin)
    local ok_util, fmutil = pcall(require, "apps/filemanager/filemanagerutil")
    if not ok_util or not fmutil then return end
    if fmutil._simpleui_reset_button_patched then return end
    fmutil._simpleui_reset_button_patched = true

    -- ── genResetSettingsButton ──────────────────────────────────────────────
    -- Resolve the filepath the same way genResetSettingsButton itself does,
    -- before the button is built, so it's available to the wrapped callback
    -- regardless of whether doc_settings_or_file is a DocSettings table or a
    -- plain path string.
    local orig_gen_reset = fmutil.genResetSettingsButton
    plugin._orig_fmutil_gen_reset = orig_gen_reset

    fmutil.genResetSettingsButton = function(doc_settings_or_file, caller_callback, button_disabled)
        local file
        if type(doc_settings_or_file) == "table" then
            file = doc_settings_or_file:readSetting("doc_path")
        else
            local ok_ffi, ffiUtil = pcall(require, "ffi/util")
            file = (ok_ffi and ffiUtil.realpath(doc_settings_or_file)) or doc_settings_or_file
        end

        local wrapped_callback = function()
            if caller_callback then caller_callback() end
            if file then _onStatusChanged(file) end
        end
        return orig_gen_reset(doc_settings_or_file, wrapped_callback, button_disabled)
    end

    -- ── genMultipleResetSettingsButton ──────────────────────────────────────
    local orig_gen_reset_multi = fmutil.genMultipleResetSettingsButton
    plugin._orig_fmutil_gen_reset_multi = orig_gen_reset_multi

    fmutil.genMultipleResetSettingsButton = function(files, caller_callback, button_disabled)
        local wrapped_callback = function()
            if caller_callback then caller_callback() end
            if type(files) == "table" then
                for f in pairs(files) do
                    _onStatusChanged(f)
                end
            end
        end
        return orig_gen_reset_multi(files, wrapped_callback, button_disabled)
    end
end

function M.unpatchResetSettingsButton(plugin)
    local fmutil = package.loaded["apps/filemanager/filemanagerutil"]
    if not fmutil or not fmutil._simpleui_reset_button_patched then return end

    if plugin._orig_fmutil_gen_reset then
        fmutil.genResetSettingsButton    = plugin._orig_fmutil_gen_reset
        plugin._orig_fmutil_gen_reset    = nil
    end
    if plugin._orig_fmutil_gen_reset_multi then
        fmutil.genMultipleResetSettingsButton    = plugin._orig_fmutil_gen_reset_multi
        plugin._orig_fmutil_gen_reset_multi      = nil
    end
    fmutil._simpleui_reset_button_patched = nil
end

-- ---------------------------------------------------------------------------
-- Global Text Size (Style ▸ Global Text Size)
-- Patches ui/font.lua's Font:getFace() so Config.getFontScalePct() scales
-- EVERY KOReader UI text size drawn through it — native menus, dialogs,
-- titlebars, file browser AND SimpleUI's own FS_* widgets — from one choke
-- point, since Font:getFace() is what the UI Font picker's Font.fontmap
-- swap already flows through for every one of those surfaces. It does NOT
-- touch the actual e-book reading font size: that's rendered by crengine
-- via its own font-size setting, entirely separate from ui/font.lua.
--
-- No-op (never wraps getFace) when the setting is at its 100% default, so
-- users who never touch it pay zero extra cost on this very hot path.
-- Like the UI Font picker itself, a change only takes full effect after a
-- restart — the scale is captured once, at install time.
-- ---------------------------------------------------------------------------

function M.patchFontGetFace(plugin)
    local Font = require("ui/font")
    if Font._simpleui_getface_patched then return end

    local scale = Config.getFontScalePct() / 100
    if scale == 1 then return end  -- default: leave getFace fully untouched

    Font._simpleui_getface_patched = true
    local orig_getFace   = Font.getFace
    plugin._orig_font_getface = orig_getFace

    Font.getFace = function(self, font, size, faceindex)
        if not size then size = self.sizemap[font] end
        if size then size = math.max(1, math.floor(size * scale)) end
        return orig_getFace(self, font, size, faceindex)
    end
end

function M.unpatchFontGetFace(plugin)
    local Font = package.loaded["ui/font"]
    if not Font or not Font._simpleui_getface_patched then return end

    if plugin._orig_font_getface then
        Font.getFace              = plugin._orig_font_getface
        plugin._orig_font_getface = nil
    end
    Font._simpleui_getface_patched = nil
end

-- ---------------------------------------------------------------------------
-- installAll / teardownAll
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Debug: button bounds overlay
-- When "simpleui_debug_button_bounds" is enabled, wraps Button:paintTo so
-- every button draws a 2px border over itself, making it easy to verify
-- the actual tap target real estate on device.
-- ---------------------------------------------------------------------------

function M.installButtonBoundsDebug(plugin)
    local Button = package.loaded["ui/widget/button"]
    if not Button then
        -- Button not loaded yet; defer until first use via a lazy wrapper on
        -- the Button module loader — we hook require instead.
        local orig_require = _G.require
        plugin._orig_require_for_bounds = orig_require
        _G.require = function(modname, ...)
            local result = orig_require(modname, ...)
            if modname == "ui/widget/button" and not result._simpleui_bounds_patched then
                M._wrapButtonPaintTo(plugin, result)
            end
            return result
        end
        return
    end
    if not Button._simpleui_bounds_patched then
        M._wrapButtonPaintTo(plugin, Button)
    end
end

function M._wrapButtonPaintTo(plugin, Button)
    local Blitbuffer = require("ffi/blitbuffer")
    local orig_paintTo = Button.paintTo
    plugin._orig_button_paintTo = orig_paintTo
    Button._simpleui_bounds_patched = true

    Button.paintTo = function(btn_self, bb, x, y)
        orig_paintTo(btn_self, bb, x, y)
        if not SUISettings:isTrue("simpleui_debug_button_bounds") then return end
        local dimen = btn_self:getSize()
        if not dimen then return end
        bb:paintBorder(x, y, dimen.w, dimen.h, 2, Blitbuffer.COLOR_RED)
    end
end

function M.uninstallButtonBoundsDebug(plugin)
    -- Restore the require hook if we set one.
    if plugin._orig_require_for_bounds then
        _G.require = plugin._orig_require_for_bounds
        plugin._orig_require_for_bounds = nil
    end
    -- Restore Button:paintTo if Button was already loaded when we patched it.
    local Button = package.loaded["ui/widget/button"]
    if Button and plugin._orig_button_paintTo then
        Button.paintTo = plugin._orig_button_paintTo
        plugin._orig_button_paintTo     = nil
        Button._simpleui_bounds_patched = nil
    end
end

-- ---------------------------------------------------------------------------
-- Reader-close helpers for gesture actions
-- ---------------------------------------------------------------------------

-- Close the reader and open the Homescreen afterwards, exactly as if
-- "Start with Homescreen" were active, regardless of the actual setting.
-- Safe to call when the reader is NOT open (no-op in that case).
-- ---------------------------------------------------------------------------
-- _raiseHSFromStack  — warm-path promotion of the suspended HS widget.
--
-- When the reader opened, the HS was left alive at the bottom of the
-- UIManager stack instead of being destroyed.  This function:
--   1. Finds the HS entry and moves it to the top of the stack (O(n)).
--   2. Re-injects a fresh navbar (new FM instance, correct tabs/bar).
--   3. Calls _refresh(false) to update only the fields invalidated by
--      onCloseDocument (progress, stats, book order) — no full rebuild.
--   4. Fires setDirty so the e-ink compositor repaints.
--
-- Returns true  → warm-path taken, caller must NOT call HS.show().
-- Returns false → HS was not on the stack; caller falls back to HS.show().
-- ---------------------------------------------------------------------------
_raiseHSFromStack = function(plugin, prev_action)
    local HS      = liveHS()
    local hs_inst = HS and HS._instance
    if not hs_inst then return false end

    -- Move to top of the window stack.
    local stack = UIManager._window_stack
    if not stack then return false end
    local found = false
    for i = 1, #stack do
        if stack[i].widget == hs_inst then
            if i ~= #stack then
                local entry = table.remove(stack, i)
                table.insert(stack, entry)
            end
            found = true
            break
        end
    end
    if not found then
        -- Widget was evicted from the stack unexpectedly — fall back.
        HS._instance = nil
        return false
    end

    -- Re-inject a fresh navbar for the new FM instance.
    --
    -- We must NOT call wrapWithNavbar here.  _navbar_inner points to the
    -- FrameContainer placeholder that HomescreenWidget:init() installs as
    -- self[1] before onShow() replaces the real content.  Using it as the
    -- inner argument would produce a new OverlapGroup whose [1] is that
    -- blank placeholder, painting the screen white.
    --
    -- The correct approach is to rebuild only the bottom-bar widget and
    -- slot it into the *existing* _navbar_container (which already holds
    -- the live HS content at [1]).  replaceBar does exactly that.
    local tabs = Config.loadTabConfig()
    Bottombar.setActiveAndRefreshFM(plugin, "homescreen", tabs)
    _ensureGoalCallback(plugin)
    local new_bar = Bottombar.buildBarWidget("homescreen", tabs)
    Bottombar.replaceBar(hs_inst, new_bar, tabs)
    hs_inst._navbar_injected    = true
    hs_inst._navbar_prev_action = prev_action

    -- Refresh stale data (stats, progress, book order).
    hs_inst._on_qa_tap   = _makeQaTap(plugin)
    hs_inst._on_goal_tap = plugin._goalTapCallback
    pcall(function() hs_inst:_refresh(false) end)

    -- Scope the dirty region to the widget's own dimen instead of the full
    -- screen. On colour panels, a full-screen "ui" dirty can be promoted to
    -- a full flash by the EPDC driver; the dimen-scoped form stays as a "ui"
    -- waveform and merges cleanly with the single repaint queued by the caller.
    UIManager:setDirty(hs_inst, function()
        return "ui", hs_inst.dimen
    end)
    return true
end

-- ---------------------------------------------------------------------------
-- _prepareReaderClose
--
-- Sets all pre-close flags before the actual onClose call.
-- Returns: file, return_to_folder, prev_action
-- ---------------------------------------------------------------------------
local function _prepareReaderClose(plugin, readerui, via_gesture)
    local file = readerui.document and readerui.document.file
    local return_to_folder = SUISettings:isTrue("simpleui_hs_return_to_book_folder")
    local fm_pre = liveFM()

    -- lazy_refresh defers FM file-list scan until HS closes (I/O optimisation).
    -- Skip when returning to book folder: FM path != home_dir, so a lazy
    -- refresh-path would navigate away from the book's folder.
    if fm_pre and not return_to_folder then
        fm_pre._sui_lazy_refresh_path = true
    end
    -- Signal FM onShow hook: do NOT override the path back to home_dir.
    if fm_pre and return_to_folder then
        fm_pre._sui_return_to_book_folder_pending = true
    end

    local prev_action = plugin.active_action
    plugin._closing_via_gesture = via_gesture
    -- Mark tearing_down so patchUIManagerClose's ReaderUI block does not try
    -- to re-open the HS a second time while our close is in progress.
    readerui.tearing_down = true

    return file, return_to_folder, prev_action
end

-- ---------------------------------------------------------------------------
-- _closeReaderToHomescreenSync
--
-- Synchronous inner body: onClose(false) + showFileManager + optional HS.
-- Shared between closeReaderToHomescreen (gesture path, inside nextTick) and
-- wireReaderMenuFMTab (TouchMenu path, called directly from the callback).
--
-- WHY THIS EXISTS:
--   TouchMenuItem:onTapSelect calls UIManager:forceRePaint() after the item
--   callback returns. If the reader close is deferred via nextTick, that flush
--   happens with the TouchMenu gone but the book still on screen — a visible
--   intermediate e-ink refresh. Native KOReader avoids this by running
--   onClose() + showFileManager() synchronously inside the callback, before
--   forceRePaint() fires. We mirror that with onClose(false) to suppress the
--   internal "full" flash that the original onClose() would have queued.
-- ---------------------------------------------------------------------------
local function _closeReaderToHomescreenSync(plugin, readerui, file,
                                             return_to_folder, prev_action)
    if UIManager._exit_code ~= nil then return end

    readerui:onClose(false)
    -- showFileManager(file) navigates the FM to the book's parent folder
    -- (last_dir derived from file path) — mirrors native behaviour.
    readerui:showFileManager(file)

    -- When "Return to Book Folder" is on: close the reader and land in the FM
    -- at the book's folder with no HS — identical to native KOReader.
    if return_to_folder then
        plugin.active_action = "home"
        return
    end

    -- Default path: raise or show the Homescreen on top of the FM.
    local HS = liveHS() or (function()
        local ok, m = pcall(require, "sui_homescreen"); return ok and m
    end)()
    if not HS then return end

    local fm_ref = liveFM()
    _closeOrphanedPopups(fm_ref, HS._instance)
    if _raiseHSFromStack(plugin, prev_action) then return end

    if HS._instance then return end
    _showHSCold(plugin, HS, prev_action)
end

-- via_gesture: true (default) for gesture-triggered closes, false for menu-triggered.
-- Controls plugin._closing_via_gesture so onCloseDocument shows the closing notice
-- only when the mode warrants it (e.g. "gesture_only" must not fire for menu closes).
--
-- Uses nextTick so the gesture event handler returns before onClose runs.
-- Safe for gestures because no forceRePaint() follows the gesture callback.
-- For the TouchMenu path, wireReaderMenuFMTab calls _closeReaderToHomescreenSync
-- directly (synchronous) to match native KOReader's single-repaint behaviour.
function M.closeReaderToHomescreen(plugin, via_gesture)
    if via_gesture == nil then via_gesture = true end
    local RUI = package.loaded["apps/reader/readerui"]
    if not (RUI and RUI.instance) then return end
    local readerui = RUI.instance

    local file, return_to_folder, prev_action =
        _prepareReaderClose(plugin, readerui, via_gesture)

    -- -----------------------------------------------------------------------
    -- Flash elimination (#35 equivalent).
    --
    -- Previous sequence (caused FM flash):
    --   readerui:onClose()        → queues UIManager:close(self.dialog, "full")
    --   readerui:showFileManager()→ FM lands on stack
    --   [event loop drains → FM painted with "full" flash]
    --   scheduleIn(0) fires       → HS raised, "ui" repaint follows
    --
    -- New sequence (flash-free, gesture path):
    --   nextTick fires (same event-loop batch as the gesture):
    --     onClose(false)          → suppresses internal "full" refresh;
    --                               onCloseDocument fires + flushes "Closing…" notice
    --     showFileManager         → FM ready synchronously
    --     _raiseHSFromStack/show  → HS on top in the same tick
    --   [event loop drains → single "ui" repaint of HS or FM]
    -- -----------------------------------------------------------------------
    UIManager:nextTick(function()
        -- Guard: another book opened between gesture and nextTick (edge case).
        local RUI2 = package.loaded["apps/reader/readerui"]
        if RUI2 and RUI2.instance and RUI2.instance ~= readerui then return end
        _closeReaderToHomescreenSync(plugin, readerui, file,
                                     return_to_folder, prev_action)
    end)
end

-- ---------------------------------------------------------------------------
-- wireReaderMenuFMTab
--
-- Replaces the native "File browser" tab callback in ReadingMenu with one
-- that mirrors native KOReader's synchronous close sequence:
--   onTapCloseMenu → onClose(false) → showFileManager [→ HS if needed]
--
-- The original plugin version deferred to nextTick here, which caused a
-- visible intermediate flash: TouchMenuItem:onTapSelect calls forceRePaint()
-- after the callback, flushing the e-ink with the menu closed but the reader
-- still visible before the nextTick had a chance to run.
--
-- onClose(false) suppresses the "full" refresh that onClose() would queue,
-- preventing the FM from flashing before the HS appears — same technique as
-- the gesture path, but without the nextTick wrapper.
-- ---------------------------------------------------------------------------
-- Suppress the "Closing book…" notice during document reloads triggered by
-- formatting changes (font size, margins, line spacing, etc.).
--
-- KOReader's ReaderUI:reloadDocument() calls self:onClose(false) internally,
-- which fires onCloseDocument — the same event we use to show the notice.
-- There is no way to distinguish a reload-triggered close from a real close
-- inside onCloseDocument itself, so we set _suppress_closing_notice on the
-- plugin just before the original reloadDocument runs.  The flag is consumed
-- (and cleared) unconditionally at the top of onCloseDocument.
--
-- Applied once per ReaderUI instance (guard: _simpleui_reload_patched).
function M.patchReloadDocument(plugin, readerui)
    if not readerui then return end
    if readerui._simpleui_reload_patched then return end
    local orig = readerui.reloadDocument
    if type(orig) ~= "function" then return end
    readerui.reloadDocument = function(self, ...)
        plugin._suppress_closing_notice = true
        plugin._suppress_opening_cover  = true
        return orig(self, ...)
    end
    readerui._simpleui_reload_patched = true
end

-- ---------------------------------------------------------------------------
-- ReaderUI.showReaderCoroutine — class-level patch, installed once.
--
-- KOReader shows a plain "Opening file '...'." InfoMessage synchronously at
-- the very top of showReaderCoroutine, before the (potentially slow) actual
-- document load happens on the next tick. When Cover Transition's open side
-- is enabled, that notice is what stays on screen for the whole load — our
-- existing ReaderUI-shown hook further down fires too late to hide it, it
-- only masks the final instant the reader itself appears.
--
-- Rather than reimplementing showReaderCoroutine's coroutine/crash-handling
-- body (out of scope for this feature, and a maintenance burden across
-- KOReader versions), this only flags the file about to be opened; the
-- existing single UIManager.show wrapper below recognises the very next
-- InfoMessage call as that notice and substitutes the cover for it. Nothing
-- here duplicates or second-guesses KOReader's own opening logic.
-- ---------------------------------------------------------------------------
function M.patchReaderShowCoroutine(plugin)
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or not ReaderUI then return end
    if ReaderUI._simpleui_show_coroutine_patched then return end
    ReaderUI._simpleui_show_coroutine_patched = true

    local orig = ReaderUI.showReaderCoroutine
    ReaderUI.showReaderCoroutine = function(self, file, provider, seamless)
        -- This patch is only ever installed once, so the `plugin` upvalue
        -- would go stale across FM recreations — resolve the live instance
        -- the same way the UIManager.show wrapper does.
        local live_plugin = UIManager._simpleui_show_plugin or plugin
        local is_reload = live_plugin._suppress_opening_cover
        live_plugin._suppress_opening_cover = nil

        if not seamless and not is_reload and CoverTransition.isOpenEnabled() then
            CoverTransition._pending_open_file = file
        end
        return orig(self, file, provider, seamless)
    end
end


function M.wireReaderMenuFMTab(plugin, readerui)
    if not (readerui and readerui.menu) then return end
    local menu_ref = readerui.menu
    if menu_ref._simpleui_fm_tab_wrapped then return end
    local items = menu_ref.menu_items
    if not (items and items.filemanager) then return end

    items.filemanager.callback = function()
        -- Mirrors native KOReader's synchronous sequence exactly:
        --   onTapCloseMenu → onClose(false) → showFileManager [→ HS]
        --
        -- We must NOT defer to nextTick here. TouchMenuItem:onTapSelect calls
        -- UIManager:forceRePaint() after this callback returns. If the reader
        -- close is deferred, that flush happens with the TouchMenu gone but the
        -- book still on screen — an unwanted intermediate e-ink refresh.
        -- Running synchronously means forceRePaint sees the HS/FM already in
        -- place (same as native), producing a single clean transition.
        --
        -- The pre-notice block (our_msg) that previously bridged the
        -- "TouchMenu-close gap" is no longer needed: onCloseDocument fires
        -- synchronously inside onClose(false) and handles its own notice
        -- flushing. The suppress flag (_suppress_closing_notice) was only
        -- needed to prevent a duplicate; it is no longer set here.

        -- Close the TouchMenu (synchronous, queues a repaint but does not
        -- flush — the flush will happen after this entire callback returns).
        if menu_ref.onTapCloseMenu then menu_ref:onTapCloseMenu() end

        -- Run the reader close synchronously (no nextTick).
        -- via_gesture=false: menu-triggered, "gesture_only" notice mode skipped.
        local file, return_to_folder, prev_action =
            _prepareReaderClose(plugin, readerui, false)
        _closeReaderToHomescreenSync(plugin, readerui, file,
                                     return_to_folder, prev_action)
    end
    menu_ref._simpleui_fm_tab_wrapped = true
end

-- Close the reader and return to the Library (FM at home_dir) with no
-- Homescreen appearing on top — equivalent to the user closing the reader
-- when "return to book folder" / "Start with Homescreen" are both off.
-- Safe to call when the reader is NOT open (no-op in that case).
function M.closeReaderToLibrary(plugin)
    local RUI = package.loaded["apps/reader/readerui"]
    if not (RUI and RUI.instance) then return end
    local readerui = RUI.instance

    -- _navbar_closing_intentionally on the widget makes the patched
    -- UIManager.close skip the entire HS re-open block (see the guard at the
    -- top of that block). This is the same flag used by tab-navigation to
    -- suppress the HS when closing overlays intentionally.
    readerui._navbar_closing_intentionally = true

    local file = readerui.document and readerui.document.file
    plugin._closing_via_gesture = true
    readerui:onClose()
    -- onClose() calls UIManager:close(self.dialog) which runs synchronously,
    -- so the flag has already been consumed. No need to clear it.
    readerui:showFileManager(file)

    -- After the FM appears, navigate to home_dir and rebuild the navbar.
    UIManager:scheduleIn(0, function()
        local fm_ref = liveFM()
        if not fm_ref then return end
        local home = G_reader_settings:readSetting("home_dir")
        local lfs  = require("libs/libkoreader-lfs")
        if not home or lfs.attributes(home, "mode") ~= "directory" then
            home = require("device").home_dir
        end
        if home and fm_ref.file_chooser then
            fm_ref._navbar_suppress_path_change = true
            fm_ref.file_chooser:changeToPath(home)
            fm_ref._navbar_suppress_path_change = nil
            if fm_ref.updateTitleBarPath then
                pcall(function() fm_ref:updateTitleBarPath(home, true) end)
            end
        elseif fm_ref.file_chooser then
            fm_ref.file_chooser:refreshPath()
        end
        local tabs = Config.loadTabConfig()
        plugin.active_action = "home"
        Bottombar.replaceBar(fm_ref, Bottombar.buildBarWidget("home", tabs), tabs)
        UIManager:setDirty(fm_ref, "ui")
    end)
end

-- ---------------------------------------------------------------------------
-- Wallpaper in File Manager and fullscreen overlays
-- Paints the SimpleUI homescreen wallpaper behind the FM, Collections,
-- History, and other fullscreen surfaces when the "Show in FM" setting is on.
--
-- Widget tree after wrapWithNavbar (FM case):
--   fm_self[1]              = simpleui FrameContainer  (background=COLOR_WHITE)
--   fm_self[1][1]           = OverlapGroup (navbar_container, no background)
--   fm_self[1][1][1]        = KOReader fm_ui FrameContainer (background=COLOR_WHITE)
--   fm_self[1][1][1][1]     = FileChooser (Menu subclass)
--   fm_self[1][1][1][1][1]  = Menu's inner FrameContainer (background=COLOR_WHITE)
--   fm_self._navbar_inner   = same as fm_self[1][1][1] (saved before wrapping)
--
-- Widget tree after wrapWithNavbar (fullscreen overlay -- Collections, History):
--   widget[1]               = simpleui FrameContainer  (background=COLOR_WHITE)
--   widget[1][1]            = OverlapGroup (navbar_container)
--   widget[1][1][1]         = original Menu widget
--   widget[1][1][1][1]      = Menu's inner FrameContainer (background=COLOR_WHITE)
--   widget._navbar_inner    = same as widget[1][1][1]
--
-- Fix: wrap paintTo on the outermost simpleui FrameContainer to paint wallpaper
-- first; clear background=nil on every FrameContainer in the chain so none of
-- them overwrite it with a white fill.  The _navbar_inner reference gives us
-- direct access to the KOReader-level widgets without walking the full tree.
-- ---------------------------------------------------------------------------

-- Paint the wallpaper onto bb, anchored at y=0 (top of screen), with opacity.
local function _paintWallpaper(bg_widget, bb, x, y)
    if not bg_widget then return end
    local ok_hs, HS = pcall(require, "sui_homescreen")
    local opacity = ok_hs and HS and HS.styleGetWallpaperOpacityValue() or 0
    bg_widget:paintTo(bb, x, 0)
    if opacity and opacity > 0 then
        bb:lightenRect(x, 0, Screen:getWidth(), Screen:getHeight(), opacity / 100)
    end
end

-- Returns the wallpaper bg widget when FM wallpaper is active, else nil.
-- Combines _wallpaperEnabledFM + _getWallpaperBg into one pcall(require).
-- All wallpaper paintTo hooks call this; the single pcall per frame replaces
-- the previous two separate pcall(require) calls per invocation.
local function _wallpaperBg()
    local ok, HS = pcall(require, "sui_homescreen")
    if not (ok and HS and HS.styleGetWallpaperShowInFM
            and HS.styleGetWallpaperShowInFM()) then return nil end
    if not HS.styleGetBgWidget then return nil end
    return HS.styleGetBgWidget()
end

-- Kept for callers that only need the boolean (e.g. setupLayout background clear).
local function _wallpaperEnabledFM()
    local ok, HS = pcall(require, "sui_homescreen")
    return ok and HS and HS.styleGetWallpaperShowInFM and HS.styleGetWallpaperShowInFM()
end

-- Compatibility shim — internal callers replaced with _wallpaperBg().
local function _getWallpaperBg()
    return _wallpaperBg()
end

-- Recursively nil all COLOR_WHITE backgrounds in a widget tree.
-- Stops at depth 12 to avoid runaway traversal.
local function _clearWhiteBackgrounds(w, depth)
    if not w or type(w) ~= "table" or depth > 12 then return end
    local Blitbuffer = require("ffi/blitbuffer")
    -- Use pcall to guard against __eq crashing on cdata nil values.
    -- w.background can be a cdata (e.g. BlitBuffer color) that triggers
    -- blitbuffer.lua's __eq metamethod, which crashes if either operand
    -- is an uninitialised/null cdata rather than a proper Lua nil.
    local ok, is_white = pcall(function() return w.background == Blitbuffer.COLOR_WHITE end)
    if ok and is_white then
        w.background = nil
    end
    for i = 1, #w do
        _clearWhiteBackgrounds(w[i], depth + 1)
    end
end

-- Inject the wallpaper paint hook into a fullscreen overlay widget
-- (Collections, History, etc.) after wrapWithNavbar has run.
--
-- For overlays the widget object itself is stable — KOReader reuses the same
-- Lua table across opens.  The hook is placed on widget[1] (the outer
-- FrameContainer produced by wrapWithNavbar) guarded by _sui_wallpaper_patched
-- so we only wrap paintTo once.  Backgrounds in the chain are cleared so
-- they do not paint white over the wallpaper.
--
-- NOTE: This function is NOT used for the FM — see patchWallpaperFM below,
-- which wraps paintTo on the FileManager instance itself (the stable object
-- that sits in UIManager._window_stack and is never recreated).
local function _injectWallpaperIntoWidget(widget)
    if not widget then return end
    local outer = widget[1]   -- simpleui outer FrameContainer
    if not outer or outer._sui_wallpaper_patched then return end
    outer._sui_wallpaper_patched = true

    -- Clear opaque backgrounds in the widget chain.
    outer.background = nil
    local ni = widget._navbar_inner
    if ni then
        ni.background = nil
        local ni1 = ni[1]
        if ni1 then
            ni1.background = nil
            if ni1[1] then ni1[1].background = nil end
        end
    end

    -- Deep-clear nested backgrounds (Button frames, item wrappers, etc.)
    if ni then
        _clearWhiteBackgrounds(ni, 0)
    else
        _clearWhiteBackgrounds(outer, 0)
    end

    -- Wrap paintTo on the outer FrameContainer.
    local _orig_pt = outer.paintTo
    function outer:paintTo(bb, x, y)
        local live_bg = _wallpaperBg()
        if live_bg then _paintWallpaper(live_bg, bb, x, y) end
        _orig_pt(self, bb, x, y)
    end
end

function M.patchWallpaperFM(plugin)
    local FileManager = require("apps/filemanager/filemanager")

    -- Guard: only install once per session.
    if FileManager._simpleui_wallpaper_fm_patched then return end
    FileManager._simpleui_wallpaper_fm_patched = true

    -- -----------------------------------------------------------------------
    -- Core approach: wrap paintTo on the FileManager CLASS, not on transient
    -- inner widgets.
    --
    -- Why inner widgets don't work:
    --   Every setupLayout call (e.g. after closing a book) calls wrapWithNavbar,
    --   which creates brand-new FrameContainer and OverlapGroup objects.  Any
    --   paintTo hook installed on those objects is silently discarded the moment
    --   setupLayout runs again — the FM's self[1] now points to the new objects
    --   and the old ones (with the hook) are garbage-collected.
    --
    -- Why wrapping the class works:
    --   UIManager._repaint() calls widget:paintTo() on the object that was
    --   passed to UIManager:show() — the FileManager *instance*.  That instance
    --   is never replaced (only its self[1] child changes).  By wrapping the
    --   CLASS-level paintTo we intercept every repaint before any child widget
    --   is painted, regardless of how many times setupLayout rebuilds self[1].
    --
    -- Flow per repaint:
    --   1. Our hook fires first → _paintWallpaper() draws wallpaper onto Screen.bb
    --   2. original WidgetContainer:paintTo → self[1]:paintTo (the outer FC)
    --        → outer FC paints nothing (background=nil, bordersize=0, padding=0)
    --        → OverlapGroup:paintTo → KOReader fm_ui FC (background=nil) → etc.
    --
    --   setupLayout also clears backgrounds in the chain (same as before) so
    --   no white rectangle is drawn on top of the wallpaper.
    -- -----------------------------------------------------------------------
    local orig_fm_paintTo = FileManager.paintTo  -- nil: inherits WidgetContainer:paintTo
    local base_wc_paintTo                        -- resolved lazily on first call

    plugin._simpleui_orig_fm_paintTo = orig_fm_paintTo  -- may be nil; stored for teardown

    FileManager.paintTo = function(fm_self, bb, x, y)
        -- Only intercept the FileManager instance (not subclasses / other callers).
        local _live_bg_fm = _wallpaperBg()
        if _live_bg_fm then _paintWallpaper(_live_bg_fm, bb, x, y) end
        -- Call the original paintTo (WidgetContainer:paintTo).
        if orig_fm_paintTo then
            orig_fm_paintTo(fm_self, bb, x, y)
        else
            if not base_wc_paintTo then
                local WC = require("ui/widget/container/widgetcontainer")
                base_wc_paintTo = WC.paintTo
            end
            base_wc_paintTo(fm_self, bb, x, y)
        end
    end

    -- Chain after patchFileManagerClass.setupLayout so the widget tree is
    -- already wrapped by wrapWithNavbar when our code runs.
    -- The sole job of this setupLayout wrapper is now to clear the white
    -- backgrounds in the newly-built widget chain so nothing paints a white
    -- rectangle on top of the wallpaper that was already drawn by paintTo.
    local base_setupLayout = FileManager.setupLayout
    plugin._orig_fm_wallpaper_setup = base_setupLayout

    FileManager.setupLayout = function(fm_self)
        base_setupLayout(fm_self)

        if not _wallpaperEnabledFM() then return end

        -- Clear all opaque backgrounds in the freshly-built widget chain.
        -- wrapWithNavbar sets outer.background = COLOR_WHITE when the navbar
        -- is not transparent; KOReader's setupLayout sets fm_ui.background =
        -- COLOR_WHITE.  Nil them all so paintTo (above) can show through.
        local outer = fm_self[1]
        if outer then
            outer.background = nil
            local ni = fm_self._navbar_inner
            if ni then
                ni.background = nil
                local ni1 = ni[1]
                if ni1 then
                    ni1.background = nil
                    if ni1[1] then ni1[1].background = nil end
                end
                _clearWhiteBackgrounds(ni, 0)
            else
                _clearWhiteBackgrounds(outer, 0)
            end
        end
    end

    -- -----------------------------------------------------------------------
    -- Button frame background patch
    -- button.lua always sets frame.background = COLOR_WHITE when the Button
    -- has no explicit self.background colour (the else branch, line ~226).
    -- This makes chevrons, coll_back, and other icon Buttons paint a white
    -- rectangle behind them even with bordersize=0.
    -- Fix: wrap Button:paintTo to temporarily nil frame.background while
    -- wallpaper-in-FM is active, then restore it after the paint call.
    -- We guard against double-patching by saving our own orig ref.
    -- -----------------------------------------------------------------------
    local ok_btn, Button = pcall(require, "ui/widget/button")
    if ok_btn and Button and not plugin._orig_wp_button_paintTo then
        local orig_btn_pt = Button.paintTo
        plugin._orig_wp_button_paintTo = orig_btn_pt

        Button.paintTo = function(btn_self, bb, x, y)
            -- Only intercept when: wallpaper active, no explicit button colour,
            -- and the frame FrameContainer exists and has a background.
            if _wallpaperEnabledFM() and not btn_self.background
                    and btn_self[1] and btn_self[1].background then
                local saved = btn_self[1].background
                btn_self[1].background = nil
                orig_btn_pt(btn_self, bb, x, y)
                btn_self[1].background = saved
            else
                orig_btn_pt(btn_self, bb, x, y)
            end
        end
    end

    -- -----------------------------------------------------------------------
    -- IconWidget alpha patch
    -- Button:paintTo above already nils frame.background to avoid painting the
    -- white rectangle of the FrameContainer. But the IconWidget inside the Button
    -- (chevrons, coll_back) and inside the native KOReader TitleBar IconButton
    -- (home, hamburger, plus) was rendered with alpha=false by default:
    -- the lazy _render() composites the icon onto a white BB and caches this
    -- "flat" version — the white pixels get baked in.
    -- Even with frame.background=nil, IconWidget:paintTo calls blitFrom()
    -- (without alpha-blending) and paints those white pixels directly over
    -- the wallpaper.
    --
    -- Fix: wrap IconWidget:init to set self.alpha = true when the FM wallpaper
    -- is active. Since _render() is lazy (called on the first paintTo via
    -- getSize()), the flag is read BEFORE the cache lookup, forcing the
    -- "...|alpha" hash and compositing with the alpha channel intact, without
    -- touching the background already painted by the wallpaper.
    --
    -- original_in_nightmode=false: native ImageWidget/KOReader field.
    -- When alpha=true and the screen is in night mode, ImageWidget:paintTo
    -- inverts the image again (to cancel out the global screen inversion).
    -- For icons over wallpapers this is undesirable — we disable it here.
    -- Guard: only acts if iw_self.alpha is still false, avoiding overwriting
    -- explicit configurations set by the widgets themselves.
    -- -----------------------------------------------------------------------
    local ok_iw, IconWidget = pcall(require, "ui/widget/iconwidget")
    if ok_iw and IconWidget and not plugin._orig_wp_iconwidget_init then
        local orig_iw_init = IconWidget.init
        plugin._orig_wp_iconwidget_init = orig_iw_init
        -- Expose the unwrapped init so that the icon-registration upvalue scan in
        -- sui_menu.lua and sui_quicksettings_bar.lua can find ICONS_PATH / ICONS_DIRS
        -- even after this patch replaces IconWidget.init.  Without this, rawget(iw,"init")
        -- returns our wrapper, whose upvalues don't include ICONS_PATH/ICONS_DIRS, causing
        -- Strategy 3 / Layer 3 to fire on every normal build and double-wrap init again.
        IconWidget._simpleui_orig_init_for_scan = orig_iw_init

        IconWidget.init = function(iw_self, ...)
            orig_iw_init(iw_self, ...)
            -- Only intervenes when the FM wallpaper is active and the icon does
            -- not yet have an explicit alpha defined by the instantiating widget.
            if _wallpaperEnabledFM() and not iw_self.alpha then
                iw_self.alpha = true
                iw_self.original_in_nightmode = false
            end
        end
    end

    -- -----------------------------------------------------------------------
    -- Menu.init background patch
    -- Menu:init (menu.lua ~913) always creates self[1] = FrameContainer with
    -- background = COLOR_WHITE. _injectWallpaperIntoWidget nils it once, but
    -- every setupLayout call re-creates the full widget tree via Menu:init.
    -- Wrap Menu.init so fullscreen FM-style menus always get nil backgrounds
    -- when wallpaper is active.  We chain on top of whatever Menu.init is
    -- current (may already be wrapped by patchMenuInitForPagination).
    -- -----------------------------------------------------------------------
    local ok_menu, Menu = pcall(require, "ui/widget/menu")
    if ok_menu and Menu and not plugin._orig_wp_menu_init then
        local orig_menu_init = Menu.init
        plugin._orig_wp_menu_init = orig_menu_init

        Menu.init = function(menu_self, ...)
            orig_menu_init(menu_self, ...)
            if not _wallpaperEnabledFM() then return end
            -- Covers two cases:
            --   1. Fullscreen borderless overlays (Collections, History, etc.)
            --   2. FM FileChooser (name == "filemanager") — does not have
            --      covers_fullscreen or is_borderless but occupies the whole screen.
            --      Without this, Menu:init resets background=COLOR_WHITE on every
            --      file list rebuild and the original condition never catches it.
            local is_fm_file_chooser   = (menu_self.name == "filemanager")
            -- Gate by the same name allowlist used for the actual wallpaper-image
            -- injection (M._WALLPAPER_NAMES, set in patchUIManagerShow). Without
            -- this, ANY covers_fullscreen+is_borderless Menu gets its background
            -- nil'd — including ReaderSearch's "all results" Menu (readersearch.lua
            -- sets covers_fullscreen=true, is_borderless=true too), which has
            -- nothing painting a backdrop behind it, leaving the book page behind
            -- it visible through the now-transparent search results list.
            local is_fullscreen_overlay = menu_self.covers_fullscreen
                                       and menu_self.is_borderless
                                       and menu_self.name
                                       and M._WALLPAPER_NAMES
                                       and M._WALLPAPER_NAMES[menu_self.name]
            if (is_fm_file_chooser or is_fullscreen_overlay) and menu_self[1] then
                -- Clear the outer FrameContainer KOReader always builds white.
                menu_self[1].background = nil
                -- Also clear the inner OverlapGroup's first FrameContainer child.
                local inner = menu_self[1][1]
                if inner and inner[1] then
                    inner[1].background = nil
                end
            end
        end
    end

    -- -----------------------------------------------------------------------
    -- UnderlineContainer colour patch
    -- UnderlineContainer (used by MosaicMenuItem and ListMenuItem as the
    -- per-item root widget) defaults to color = COLOR_WHITE so its focus
    -- indicator line is invisible by default.  Against a white Menu background
    -- that's fine, but against a wallpaper the white line is very visible
    -- under every book item even when the item is not focused.
    -- Fix: wrap UnderlineContainer:paintTo so that when wallpaper is active
    -- and color == COLOR_WHITE (the "hidden / unfocused" state), we skip the
    -- bb:paintRect call that draws the white line.
    -- -----------------------------------------------------------------------
    local ok_uc, UnderlineContainer = pcall(require, "ui/widget/container/underlinecontainer")
    if ok_uc and UnderlineContainer and not plugin._orig_wp_uc_paintTo then
        local Blitbuffer = require("ffi/blitbuffer")
        local orig_uc_pt = UnderlineContainer.paintTo
        plugin._orig_wp_uc_paintTo = orig_uc_pt

        UnderlineContainer.paintTo = function(uc_self, bb, x, y)
            if _wallpaperEnabledFM() and uc_self.color == Blitbuffer.COLOR_WHITE then
                -- Paint only the child, skip the white underline.
                local container_size = uc_self:getSize()
                if not uc_self.dimen then
                    local Geom = require("ui/geometry")
                    uc_self.dimen = Geom:new{ x = x, y = y, w = container_size.w, h = container_size.h }
                else
                    uc_self.dimen.x = x
                    uc_self.dimen.y = y
                end
                local content_size = uc_self[1]:getSize()
                uc_self[1]:paintTo(bb, x, y)
            else
                orig_uc_pt(uc_self, bb, x, y)
            end
        end
    end

    -- -----------------------------------------------------------------------
    -- TextBoxWidget transparent-composite patch
    -- TextBoxWidget fills its internal blitbuffer (_bb) with
    -- self.bgcolor = COLOR_WHITE before each paintTo, even with
    -- bordersize=0 and without FrameContainer. This causes an opaque white
    -- background on book titles in "Detailed" and "Detailed with Cover" views,
    -- on the pagination bar text, and in any TextBoxWidget inside
    -- the FM when the wallpaper is active.
    --
    -- Reuses the same technique as UI.makeAlphaTextBox (sui_core.lua):
    --   1. renders the TBW into an 8-bit tmp_bb with bgcolor=white (normal)
    --   2. inverts the tmp_bb (text=white/mask, background=black/transparent)
    --   3. colorblitFromRGB32 composites with the original fgcolor over the
    --      destination bb (which already has the wallpaper painted underneath)
    --
    -- Only intervenes when: active wallpaper AND bgcolor == COLOR_WHITE (i.e.
    -- the default white background — custom bgcolors are respected).
    -- -----------------------------------------------------------------------
    local ok_tbw, TextBoxWidget = pcall(require, "ui/widget/textboxwidget")
    if ok_tbw and TextBoxWidget and not plugin._orig_wp_tbw_paintTo then
        local Blitbuffer = require("ffi/blitbuffer")
        local orig_tbw_pt = TextBoxWidget.paintTo
        plugin._orig_wp_tbw_paintTo = orig_tbw_pt

        TextBoxWidget.paintTo = function(tbw_self, bb, x, y)
            if not (_wallpaperEnabledFM()
                    and tbw_self.bgcolor == Blitbuffer.COLOR_WHITE) then
                return orig_tbw_pt(tbw_self, bb, x, y)
            end

            local dimen = tbw_self:getSize()
            local w, h  = dimen.w, dimen.h
            if w <= 0 or h <= 0 then
                return orig_tbw_pt(tbw_self, bb, x, y)
            end

            if not tbw_self._sui_tmp_bb or tbw_self._sui_tmp_bb:getWidth() ~= w or tbw_self._sui_tmp_bb:getHeight() ~= h then
                if tbw_self._sui_tmp_bb then tbw_self._sui_tmp_bb:free() end
                tbw_self._sui_tmp_bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
            end

            local fgcolor = tbw_self.fgcolor or Blitbuffer.COLOR_BLACK
            UI.paintWithAlphaMask(tbw_self, bb, x, y, w, h, fgcolor, orig_tbw_pt, tbw_self._sui_tmp_bb)
        end

        local orig_tbw_free = TextBoxWidget.free
        plugin._orig_wp_tbw_free = orig_tbw_free
        TextBoxWidget.free = function(tbw_self, full)
            if tbw_self._sui_tmp_bb and full ~= false then
                tbw_self._sui_tmp_bb:free(); tbw_self._sui_tmp_bb = nil
            end
            if orig_tbw_free then orig_tbw_free(tbw_self, full) end
        end
    end

    -- -----------------------------------------------------------------------
    -- ProgressWidget bgcolor patch
    -- ProgressWidget (reading progress bar in mosaic and list views)
    -- is created with bgcolor = COLOR_WHITE and paints a background rectangle
    -- directly in paintTo, without going through FrameContainer.
    -- Fix: temporarily replace bgcolor with nil during paint to omit the
    -- white fill; the border and the fill bar (fillcolor/bordercolor)
    -- are drawn over the existing wallpaper.
    -- -----------------------------------------------------------------------
    local ok_pw, ProgressWidget = pcall(require, "ui/widget/progresswidget")
    if ok_pw and ProgressWidget and not plugin._orig_wp_pw_paintTo then
        local Blitbuffer = require("ffi/blitbuffer")
        local orig_pw_pt = ProgressWidget.paintTo
        plugin._orig_wp_pw_paintTo = orig_pw_pt

        ProgressWidget.paintTo = function(pw_self, bb, x, y)
            if _wallpaperEnabledFM()
                    and pw_self.bgcolor == Blitbuffer.COLOR_WHITE then
                local saved = pw_self.bgcolor
                pw_self.bgcolor = nil
                orig_pw_pt(pw_self, bb, x, y)
                pw_self.bgcolor = saved
            else
                orig_pw_pt(pw_self, bb, x, y)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- ffi/util.purgeDir safety patch
-- Root cause: purgeDir iterates a directory with lfs.dir(), then calls
-- lfs.attributes(fullpath) on each entry. If an entry disappears between
-- the lfs.dir() listing and the lfs.attributes() call (race condition with
-- macOS .DS_Store / temp files, or files removed mid-iteration), attributes
-- is nil and `attributes.mode` crashes with "attempt to index a nil value".
--
-- Strategy: require("ffi/util") returns the same cached table that
-- filemanager.lua holds as its local `ffiUtil` upvalue.  Replacing
-- ffiUtil.purgeDir on that table means every caller — including the
-- recursive call inside purgeDir itself — picks up the safe version,
-- because the recursive call is `util.purgeDir(fullpath)` via the table,
-- not a local upvalue.
--
-- The patch is applied once (guarded by _simpleui_purgeDir_patched) and
-- reversed cleanly in teardownAll.
-- ---------------------------------------------------------------------------
function M.patchPurgeDir(plugin)
    local ok, ffiUtil = pcall(require, "ffi/util")
    if not ok or not ffiUtil or not ffiUtil.purgeDir then return end
    if ffiUtil._simpleui_purgeDir_patched then return end
    ffiUtil._simpleui_purgeDir_patched = true

    local lfs          = require("libs/libkoreader-lfs")
    local orig_purgeDir = ffiUtil.purgeDir
    if plugin then plugin._orig_ffi_purgeDir = orig_purgeDir end

    ffiUtil.purgeDir = function(dir)
        local ok2, err
        ok2, err = lfs.attributes(dir)
        if not ok2 or err ~= nil then
            return nil, err
        end
        for f in lfs.dir(dir) do
            if f ~= "." and f ~= ".." then
                local fullpath = ffiUtil.joinPath(dir, f)
                local attributes = lfs.attributes(fullpath)
                if not attributes then
                    -- Entry disappeared between lfs.dir() and lfs.attributes()
                    -- (race condition with .DS_Store, temp files, etc.); skip.
                elseif attributes.mode == "directory" then
                    ok2, err = ffiUtil.purgeDir(fullpath)
                    if not ok2 or err ~= nil then return ok2, err end
                else
                    ok2, err = os.remove(fullpath)
                    if not ok2 or err ~= nil then return ok2, err end
                end
            end
        end
        return os.remove(dir)
    end
end

-- (kept for teardown symmetry — no longer does folder-level guarding)
function M.patchDeleteFile(FileManager, plugin)
    if FileManager._simpleui_deleteFile_patched then return end
    FileManager._simpleui_deleteFile_patched = true

    local orig_deleteFile = FileManager.deleteFile
    if plugin then plugin._orig_fm_deleteFile = orig_deleteFile end

    FileManager.deleteFile = function(fm_self, file, is_file)
        if not is_file then
            if not file then
                logger.warn("simpleui: deleteFile called with nil folder path, aborting")
                return false
            end
            local lfs2 = require("libs/libkoreader-lfs")
            if not lfs2.attributes(file, "mode") then
                logger.warn("simpleui: deleteFile: folder gone before purgeDir:", tostring(file))
                -- Return true so post_delete_callback fires and FM refreshes.
                return true
            end
        end

        -- Preserve finished books in statistics before the sidecar is purged.
        -- DocSettings.updateLocation (called inside orig_deleteFile) deletes the
        -- .sdr, which is the only place summary.status lives.  We snapshot the
        -- relevant fields here, before the delete, so countMarkedReadBoth can
        -- continue counting this book even after the file and sidecar are gone.
        if is_file then
            pcall(function()
                local DB = SUISettings.DeletedBooks
                if not DB or not DB.isEnabled() then return end
                local ok_DS, DocSettings = pcall(require, "docsettings")
                if not ok_DS or not DocSettings then return end
                local ds = DocSettings:open(file)
                local summary = ds:readSetting("summary")
                if type(summary) ~= "table" or summary.status ~= "complete" then
                    pcall(function() ds:close() end)
                    return
                end
                local md5 = ds:readSetting("partial_md5_checksum")
                if not md5 then
                    pcall(function() ds:close() end)
                    return
                end
                local doc_props = ds:readSetting("doc_props")
                local title   = doc_props and doc_props.title   or ""
                local authors = doc_props and doc_props.authors or ""
                -- Derive year from summary.modified (same source as countMarkedReadBoth).
                local year = 0
                local mod = summary.modified
                if type(mod) == "number" then
                    year = tonumber(os.date("%Y", mod)) or 0
                elseif type(mod) == "string" and #mod >= 4 then
                    year = tonumber(mod:sub(1, 4)) or 0
                elseif type(mod) == "table" and mod.year then
                    year = mod.year
                end
                pcall(function() ds:close() end)
                DB.add(md5, title, authors, year)
                logger.dbg("simpleui: preserved deleted finished book in stats:", title, "(md5:", md5, "year:", year, ")")
            end)
        end

        return orig_deleteFile(fm_self, file, is_file)
    end
end

-- patchHistoryMenuHold
-- Wraps FileManagerHistory.onMenuHold so that CoverBrowser's injected
-- "Refresh cached book information" (and sibling) buttons do not crash when
-- booklist_menu has been nilled by its close_callback before the button fires.
--
-- Root cause: CoverBrowser.addFileDialogButtons captures the FileManagerHistory
-- *class* as `widget` and calls widget.getMenuInstance() inside each button
-- callback.  getMenuInstance() resolves ui.history.booklist_menu at call time,
-- which is nil if the close_callback already ran (SimpleUI's altered widget
-- lifecycle can trigger this earlier than stock KOReader does).
--
-- Fix: override getMenuInstance() to return the booklist_menu instance that was
-- live at the moment of the hold.  We install a thin wrapper around onMenuHold
-- that captures `self` (= booklist_menu, valid at hold time) and temporarily
-- replaces getMenuInstance with a closure over that reference for the duration
-- of the dialog's lifetime.  The original is restored when the dialog closes.
-- A session guard prevents double-patching across FM lifecycle cycles.
function M.patchHistoryMenuHold()
    local ok, FMH = pcall(require, "apps/filemanager/filemanagerhistory")
    if not (ok and FMH) then return end
    if FMH._sui_onMenuHold_patched then return end
    FMH._sui_onMenuHold_patched = true

    local orig_getMenuInstance = FMH.getMenuInstance
    local orig_onMenuHold      = FMH.onMenuHold

    FMH.onMenuHold = function(bm_self, item)
        -- bm_self is the booklist_menu instance (valid here, may be nil later).
        -- Temporarily override the class-level getMenuInstance so CoverBrowser's
        -- button callbacks resolve to this specific instance instead of going
        -- through ui.history.booklist_menu (which may be nil by then).
        local overridden = false
        if bm_self and orig_getMenuInstance then
            overridden = true
            FMH.getMenuInstance = function()
                return bm_self
            end
        end

        local result = orig_onMenuHold(bm_self, item)

        -- Restore after the dialog is shown.  We do this via a close hook on
        -- the file_dialog so getMenuInstance remains valid for as long as the
        -- dialog is on screen, and is restored the moment it closes.
        if overridden then
            local dlg = bm_self and bm_self.file_dialog
            if dlg then
                local orig_on_close = dlg.onCloseWidget
                dlg.onCloseWidget = function(dlg_self, ...)
                    FMH.getMenuInstance = orig_getMenuInstance
                    if orig_on_close then
                        return orig_on_close(dlg_self, ...)
                    end
                end
            else
                -- No dialog was created (e.g. hold on a non-file item); restore now.
                FMH.getMenuInstance = orig_getMenuInstance
            end
        end

        return result
    end
end

-- Called from patchUIManagerShow after a fullscreen overlay (Collections,
-- History, etc.) has been wrapped with wrapWithNavbar and shown.
function M.injectWallpaperIntoFullscreenWidget(widget)
    if not widget then return end
    -- Only inject wallpaper into the known FM-style overlay widgets.
    -- Utility overlays that happen to set covers_fullscreen (SortWidget,
    -- PathChooser, etc.) must be left untouched.
    if not (M._WALLPAPER_NAMES and M._WALLPAPER_NAMES[widget.name]) then return end
    if not (_wallpaperEnabledFM() and _getWallpaperBg()) then return end
    _injectWallpaperIntoWidget(widget)
end


function M.installAll(plugin)
    M.patchPurgeDir(plugin)
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok_fm and FileManager then M.patchDeleteFile(FileManager, plugin) end
    M.patchFileManagerClass(plugin)
    M.patchStartWithMenu()
    M.patchBookList(plugin)
    M.patchHistoryMenuHold()
    M.patchCollections(plugin)
    M.patchFullscreenWidgets(plugin)
    M.patchUIManagerShow(plugin)
    M.patchReaderShowCoroutine(plugin)
    M.patchUIManagerClose(plugin)
    M.patchMenuInitForPagination(plugin)
    M.patchMenuForNavpager(plugin)
    M.patchBookInfoNavigation(plugin)
    M.patchStatusButtons(plugin)
    M.patchResetSettingsButton(plugin)
    M.patchFontGetFace(plugin)
    -- Install the FM + Reader tab icon patches so system icon overrides
    -- survive menu rebuilds.
    local ok_ss, SUIStyle = pcall(require, "sui_style")
    if ok_ss and SUIStyle then
        pcall(SUIStyle.installTabIconPatch, plugin)
        pcall(SUIStyle.installReaderTabIconPatch, plugin)
    end
    -- Install button-bounds overlay when the debug setting is on at startup.
    if SUISettings:isTrue("simpleui_debug_button_bounds") then
        M.installButtonBoundsDebug(plugin)
    end
    -- Folder covers are installed only when the feature is enabled to avoid
    -- wrapping MosaicMenuItem.update unconditionally, which would hide the
    -- BookInfoManager upvalue from third-party user-patches.
    -- FC.install() is also called from sui_menu.lua when the toggle is turned on.
    local ok_fc, FC = pcall(require, "sui_foldercovers")
    if ok_fc and FC and FC.isEnabled() then
        pcall(FC.install)
    end
    -- Virtual author/series browser — installed only when the feature is enabled
    -- in settings (default: on). When disabled, FileChooser is left unpatched so
    -- third-party user-patches (e.g. 2-author-series.lua) can run unobstructed.
    local ok_bm, BM = pcall(require, "sui_browsemeta")
    if ok_bm and BM and BM.isEnabled() then pcall(BM.install) end
    -- Wallpaper in FM and fullscreen overlay surfaces.
    M.patchWallpaperFM(plugin)

    -- ------------------------------------------------------------------
    -- Reader-only patches.
    --
    -- installAll runs once per SimpleUIPlugin instantiation, and KOReader
    -- instantiates one plugin per host UI — both the FileManager AND the
    -- ReaderUI call SimpleUIPlugin:init() (hence installAll) separately.
    -- wireReaderMenuFMTab / patchReloadDocument only make sense when
    -- plugin.ui is a ReaderUI, so guard on plugin.ui.document, a field
    -- only ReaderUI instances have (FileManager has no .document).
    --
    -- BUG FIX: these two were previously defined but never called from
    -- anywhere, meaning the reader's "File browser" menu tab kept its
    -- native callback instead of ours. That callback closes the reader
    -- via readerui:onClose() directly, without going through
    -- _prepareReaderClose (which sets readerui.tearing_down = true).
    -- Without that flag, SimpleUIPlugin:onCloseWidget's real-exit guard
    -- misfires on the CloseWidget broadcast and tears down the suspended
    -- Homescreen, leaving the bare FileManager exposed once showFileManager
    -- runs — i.e. exactly the "opens the library instead of the homescreen"
    -- symptom.
    -- ------------------------------------------------------------------
    if plugin.ui and plugin.ui.document then
        M.wireReaderMenuFMTab(plugin, plugin.ui)
        M.patchReloadDocument(plugin, plugin.ui)
    end
end

function M.teardownAll(plugin)
    -- Cover Transition holds no monkey-patch of its own (it is only ever
    -- invoked from hooks owned by other patches in this file), but it can
    -- have a widget on screen or a pending auto-close timer at teardown time.
    pcall(CoverTransition.close)

    -- Restore ffi/util.purgeDir patch.
    local ffiUtil = package.loaded["ffi/util"]
    if ffiUtil and ffiUtil._simpleui_purgeDir_patched and plugin._orig_ffi_purgeDir then
        ffiUtil.purgeDir                  = plugin._orig_ffi_purgeDir
        ffiUtil._simpleui_purgeDir_patched = nil
        plugin._orig_ffi_purgeDir         = nil
    end

    -- Restore FileManager.deleteFile patch.
    local FM = package.loaded["apps/filemanager/filemanager"]
    if FM and FM._simpleui_deleteFile_patched and plugin._orig_fm_deleteFile then
        FM.deleteFile                    = plugin._orig_fm_deleteFile
        FM._simpleui_deleteFile_patched  = nil
        plugin._orig_fm_deleteFile       = nil
    end

    -- Restore UIManager patches first (highest call frequency).
    -- Also clear the session-guard flags so a re-enable cycle reinstalls
    -- the wrappers cleanly without hitting the early-return branches.
    if plugin._orig_uimanager_show then
        UIManager.show                   = plugin._orig_uimanager_show
        plugin._orig_uimanager_show      = nil
        UIManager._simpleui_show_patched = nil
        UIManager._simpleui_show_plugin  = nil
        UIManager._simpleui_show_orig    = nil
    end
    if plugin._orig_uimanager_close then
        UIManager.close                   = plugin._orig_uimanager_close
        plugin._orig_uimanager_close      = nil
        UIManager._simpleui_close_patched = nil
        UIManager._simpleui_close_plugin  = nil
        UIManager._simpleui_close_orig    = nil
    end

    -- Restore widget class patches via package.loaded.
    local BookList = package.loaded["ui/widget/booklist"]
    if BookList and plugin._orig_booklist_new then
        BookList.new              = plugin._orig_booklist_new
        plugin._orig_booklist_new = nil
    end

    local Menu = package.loaded["ui/widget/menu"]
    if Menu then
        if plugin._orig_menu_new then
            Menu.new              = plugin._orig_menu_new
            plugin._orig_menu_new = nil
        end
        if plugin._orig_menu_init then
            Menu.init              = plugin._orig_menu_init
            plugin._orig_menu_init = nil
        end
        if plugin._orig_menu_update_page_info then
            Menu.updatePageInfo                = plugin._orig_menu_update_page_info
            plugin._orig_menu_update_page_info = nil
        end
        Menu._simpleui_navpager_patched = nil
    end

    local FileManager = package.loaded["apps/filemanager/filemanager"]
    if FileManager then
        if plugin._orig_fm_updateTitleBarPath then
            FileManager.updateTitleBarPath         = plugin._orig_fm_updateTitleBarPath
            plugin._orig_fm_updateTitleBarPath     = nil
        end
        if FileManager._simpleui_gesture_priority_applied then
            UI.unapplyGesturePriorityHandleEvent(FileManager)
        end
        if plugin._orig_initGesListener then
            FileManager.initGesListener       = plugin._orig_initGesListener
            plugin._orig_initGesListener      = nil
            FileManager._simpleui_ges_patched = nil
        end
        if plugin._orig_fm_setup then
            FileManager.setupLayout = plugin._orig_fm_setup
            plugin._orig_fm_setup   = nil
        end
        -- Clear the setupLayout guard so patchFileManagerClass reinstalls the
        -- wrapper cleanly on the next installAll (e.g. after disable→enable).
        FileManager._simpleui_setup_patched = nil
    end

    local FMColl = package.loaded["apps/filemanager/filemanagercollection"]
    if FMColl then
        if plugin._orig_fmcoll_show then
            FMColl.onShowCollList    = plugin._orig_fmcoll_show
            plugin._orig_fmcoll_show = nil
        end
        if plugin._orig_fmcoll_update_coll_list then
            FMColl.updateCollListItemTable       = plugin._orig_fmcoll_update_coll_list
            plugin._orig_fmcoll_update_coll_list = nil
        end
        if plugin._orig_fmcoll_get_coll_title then
            FMColl.getCollectionTitle           = plugin._orig_fmcoll_get_coll_title
            plugin._orig_fmcoll_get_coll_title  = nil
        end
    end

    local RC = package.loaded["readcollection"]
    if RC then
        if plugin._orig_rc_remove then
            RC.removeCollection    = plugin._orig_rc_remove
            plugin._orig_rc_remove = nil
        end
        if plugin._orig_rc_rename then
            RC.renameCollection    = plugin._orig_rc_rename
            plugin._orig_rc_rename = nil
        end
        if plugin._orig_rc_additem then
            RC.addItem              = plugin._orig_rc_additem
            plugin._orig_rc_additem = nil
        end
        if plugin._orig_rc_removeitem then
            RC.removeItem              = plugin._orig_rc_removeitem
            plugin._orig_rc_removeitem = nil
        end
    end

    local SortWidget = package.loaded["ui/widget/sortwidget"]
    if SortWidget and plugin._orig_sortwidget_new then
        SortWidget.new              = plugin._orig_sortwidget_new
        plugin._orig_sortwidget_new = nil
    end

    local PathChooser = package.loaded["ui/widget/pathchooser"]
    if PathChooser and plugin._orig_pathchooser_new then
        PathChooser.new              = plugin._orig_pathchooser_new
        plugin._orig_pathchooser_new = nil
    end

    local FileChooser = package.loaded["ui/widget/filechooser"]
    if FileChooser and plugin._orig_fc_init then
        FileChooser.init            = plugin._orig_fc_init
        FileChooser._navbar_patched = nil
        plugin._orig_fc_init        = nil
    end

    local fmutil = package.loaded["apps/filemanager/filemanagerutil"]
    if fmutil and fmutil._simpleui_bookinfo_nav_patched then
        if plugin._orig_fmutil_gen_bookinfo then
            fmutil.genBookInformationButton       = plugin._orig_fmutil_gen_bookinfo
            plugin._orig_fmutil_gen_bookinfo      = nil
        end
        fmutil._simpleui_bookinfo_nav_patched = nil
    end
    M.unpatchStatusButtons(plugin)
    M.unpatchResetSettingsButton(plugin)
    M.unpatchFontGetFace(plugin)

    local FMH = package.loaded["apps/filemanager/filemanagerhistory"]
    if FMH and FMH._sui_onMenuHold_patched then
        FMH._sui_onMenuHold_patched = nil
        -- The patched onMenuHold and its getMenuInstance override restore
        -- themselves on dialog close; clearing the guard suffices for re-enable.
    end

    local FileManagerMenu = package.loaded["apps/filemanager/filemanagermenu"]
    if FileManagerMenu and FileManagerMenu._simpleui_startwith_patched then
        FileManagerMenu.getStartWithMenuTable   = FileManagerMenu._simpleui_startwith_orig
        FileManagerMenu._simpleui_startwith_orig    = nil
        FileManagerMenu._simpleui_startwith_patched = nil
    end
    -- Remove the FM tab icon patch installed by SUIStyle.
    if plugin._sysicon_fmmenu_patched then
        local ok_ss, SUIStyle = pcall(require, "sui_style")
        if ok_ss and SUIStyle then pcall(SUIStyle.removeTabIconPatch) end
        plugin._sysicon_fmmenu_patched = nil
    end
    -- Remove the Reader tab icon patch installed by SUIStyle.
    if plugin._sysicon_rdmenu_patched then
        local ok_ss, SUIStyle = pcall(require, "sui_style")
        if ok_ss and SUIStyle then pcall(SUIStyle.removeReaderTabIconPatch) end
        plugin._sysicon_rdmenu_patched = nil
    end

    local Dispatcher = package.loaded["dispatcher"]
    if Dispatcher and Dispatcher._simpleui_execute_patched then
        Dispatcher.execute                   = Dispatcher._simpleui_execute_orig
        Dispatcher._simpleui_execute_orig    = nil
        Dispatcher._simpleui_execute_patched = nil
    end

    M.uninstallButtonBoundsDebug(plugin)

    -- Clear transient close-path flag.
    plugin._closing_via_gesture = nil

    -- Reset module-level state so a re-enable cycle starts clean.
    -- Transient flags are cleared unconditionally.
    -- _start_with_hs is reset to nil (not false) so isStartWithHS() performs a
    -- fresh lazy read on the next installAll cycle, picking up any setting
    -- change made while the plugin was disabled.
    _hs_boot_done             = false
    _hs_pending_after_reader  = false
    _start_with_hs            = nil
    _navpager_rebuild_pending = false

    -- Clear lazy-refresh flag on the FM instance, if any.
    local fm_td = liveFM()
    if fm_td then fm_td._sui_lazy_refresh_path = nil end

    if _navbar_kb_capture then
        UIManager:close(_navbar_kb_capture)
        _navbar_kb_capture = nil
    end
    _navbar_kb_idx       = 1
    _navbar_kb_return_fn = nil
    _enterNavbarKbFocus_fn = nil

    Config.reset()

    local Registry = package.loaded["desktop_modules/moduleregistry"]
    if Registry then Registry.invalidate() end

    local FC = package.loaded["sui_foldercovers"]
    if FC then pcall(FC.uninstall) end

    local BM = package.loaded["sui_browsemeta"]
    if BM then
        pcall(BM.uninstall)
        pcall(BM.reset)
    end

    -- Restore wallpaper FM patch.
    -- Do NOT restore _orig_fm_wallpaper_setup: patchFileManagerClass's teardown
    -- above has already restored FileManager.setupLayout to the KOReader native
    -- version (plugin._orig_fm_setup).  The wallpaper wrapper saved
    -- base_setupLayout = the patchFileManagerClass version at install time; putting
    -- that stale pointer back now would leave an extra, unreachable wrapper in the
    -- chain on the next FM instance.
    -- Instead, just discard the saved pointer and clear the guard flag so that the
    -- next installAll (triggered when the new FM instance calls plugin:init()) can
    -- reinstall the wallpaper wrapper on top of the freshly reinstalled
    -- patchFileManagerClass wrapper.
    local FM_wp = package.loaded["apps/filemanager/filemanager"]
    if FM_wp then
        -- Restore FileManager.paintTo (our wallpaper hook lives here).
        -- _simpleui_orig_fm_paintTo is nil when FM had no own paintTo
        -- (inherited WidgetContainer:paintTo) — setting to nil restores that.
        FM_wp.paintTo                        = plugin._simpleui_orig_fm_paintTo
        plugin._simpleui_orig_fm_paintTo     = nil
        plugin._orig_fm_wallpaper_setup      = nil
        FM_wp._simpleui_wallpaper_fm_patched = nil   -- allow reinstall on next init
    end

    -- Restore wallpaper Button:paintTo patch.
    local Button_wp = package.loaded["ui/widget/button"]
    if Button_wp and plugin._orig_wp_button_paintTo then
        Button_wp.paintTo              = plugin._orig_wp_button_paintTo
        plugin._orig_wp_button_paintTo = nil
    end

    -- Restore wallpaper IconWidget:init patch.
    local IW_wp = package.loaded["ui/widget/iconwidget"]
    if IW_wp and plugin._orig_wp_iconwidget_init then
        IW_wp.init                      = plugin._orig_wp_iconwidget_init
        plugin._orig_wp_iconwidget_init = nil
    end

    -- Restore wallpaper Menu.init patch.
    local Menu_wp = package.loaded["ui/widget/menu"]
    if Menu_wp and plugin._orig_wp_menu_init then
        Menu_wp.init              = plugin._orig_wp_menu_init
        plugin._orig_wp_menu_init = nil
    end

    -- Restore wallpaper UnderlineContainer:paintTo patch.
    local UC_wp = package.loaded["ui/widget/container/underlinecontainer"]
    if UC_wp and plugin._orig_wp_uc_paintTo then
        UC_wp.paintTo              = plugin._orig_wp_uc_paintTo
        plugin._orig_wp_uc_paintTo = nil
    end

    -- Restore wallpaper TextBoxWidget:paintTo patch.
    local TBW_wp = package.loaded["ui/widget/textboxwidget"]
    if TBW_wp and plugin._orig_wp_tbw_paintTo then
        TBW_wp.paintTo              = plugin._orig_wp_tbw_paintTo
        plugin._orig_wp_tbw_paintTo = nil
    end
    if TBW_wp and plugin._orig_wp_tbw_free then
        TBW_wp.free                 = plugin._orig_wp_tbw_free
        plugin._orig_wp_tbw_free    = nil
    end

    -- Restore wallpaper ProgressWidget:paintTo patch.
    local PW_wp = package.loaded["ui/widget/progresswidget"]
    if PW_wp and plugin._orig_wp_pw_paintTo then
        PW_wp.paintTo              = plugin._orig_wp_pw_paintTo
        plugin._orig_wp_pw_paintTo = nil
    end
end

-- ---------------------------------------------------------------------------
-- Dispatcher:execute patch
-- When the homescreen is active, UIManager:sendEvent delivers only to the top
-- widget. Since the HS sits on top, events like ShowColl / ShowCollList are
-- never received by the FM. Fix: temporarily sink the HS to the bottom of the
-- window stack so the FM's plugins receive sendEvent normally, then restore.
-- ---------------------------------------------------------------------------

do
    local ok, Dispatcher = pcall(require, "dispatcher")
    if ok and Dispatcher and not Dispatcher._simpleui_execute_patched then
        local orig_execute = Dispatcher.execute
        Dispatcher._simpleui_execute_orig = orig_execute

        Dispatcher.execute = function(self, settings, exec_props)
            local HS = liveHS()
            if not (HS and HS._instance) then
                return orig_execute(self, settings, exec_props)
            end

            -- Sink the HS to the bottom of the stack.
            local stack   = UIManager._window_stack
            local hs_inst = HS._instance
            local hs_idx  = nil
            for i, entry in ipairs(stack) do
                if entry.widget == hs_inst then hs_idx = i; break end
            end
            if hs_idx and hs_idx > 1 then
                local entry = table.remove(stack, hs_idx)
                table.insert(stack, 1, entry)
            end

            local ok2, err = pcall(orig_execute, self, settings, exec_props)

            -- Restore the HS to its original position regardless of outcome.
            if hs_idx and hs_idx > 1 then
                for i, entry in ipairs(stack) do
                    if entry.widget == hs_inst then
                        local e = table.remove(stack, i)
                        table.insert(stack, hs_idx, e)
                        break
                    end
                end
            end

            if not ok2 then
                logger.warn("simpleui: Dispatcher:execute error:", err)
            end
        end

        Dispatcher._simpleui_execute_patched = true
    end
end

return M