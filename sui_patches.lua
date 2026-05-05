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
local _hs_pending_after_reader = false
local _hs_pending_prev_action   = nil   -- real previous tab before active_action was set to "homescreen"

-- Cached value of the "start_with" setting. Updated whenever the user changes
-- the setting so UIManager.show / close avoid repeated settings reads.
local _start_with_hs = G_reader_settings:readSetting("start_with", "filemanager") == "homescreen_simpleui"

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

-- ---------------------------------------------------------------------------
-- Private helpers
-- ---------------------------------------------------------------------------

local function isStartWithHS()
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
    local orig_setupLayout = FileManager.setupLayout
    plugin._orig_fm_setup  = orig_setupLayout

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

    FileManager.setupLayout = function(fm_self)
        -- Calculate total navbar height (bottom bar + optional top bar).
        local topbar_on = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
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
            UIManager:scheduleIn(0, function()
                local HS2 = liveHS()
                if not HS2 then return end
                if not plugin._goalTapCallback then plugin:addToMainMenu({}) end
                local qa_tap   = rot_qa_tap   or function(aid) plugin:_navigate(aid, plugin.ui, Config.loadTabConfig(), false) end
                local goal_tap = rot_goal_tap or plugin._goalTapCallback
                HS2.show(qa_tap, goal_tap)
            end)
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
        local navbar_container, wrapped, bar, topbar, bar_idx, topbar_on2, topbar_idx =
            UI.wrapWithNavbar(inner_widget, plugin.active_action, tabs)
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
            if isStartWithHS() and tabInTabs("homescreen", tabs) then
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
                        if not plugin._goalTapCallback then plugin:addToMainMenu({}) end
                        local qa_tap   = rot_qa_tap   or function(aid) plugin:_navigate(aid, plugin.ui, Config.loadTabConfig(), false) end
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
                local return_to_folder = G_reader_settings:isTrue("navbar_hs_return_to_book_folder")
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
                HS_live._instance._on_qa_tap = function(aid)
                    plugin:_navigate(aid, plugin.ui, Config.loadTabConfig(), false)
                end
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
            if not G_reader_settings:nilOrTrue("navbar_enabled") then return end
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
                    G_reader_settings:saveSetting("sui_tbr_list", {})
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
                local ok_im, InfoMessage = pcall(require, "ui/widget/infomessage")
                if ok_im then
                    require("ui/uimanager"):show(InfoMessage:new{
                        text    = _("The «To Be Read» collection cannot be renamed."),
                        timeout = 2,
                    })
                end
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
        G_reader_settings:saveSetting("sui_tbr_list", list)
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
                    local ok_im, InfoMessage = pcall(require, "ui/widget/infomessage")
                    if ok_im then
                        require("ui/uimanager"):show(InfoMessage:new{
                            text    = _("To Be Read list is full (max. 5 books)."),
                            timeout = 2,
                        })
                    end
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

    if type(RC.addItemsMultiple) == "function" then
        local orig_add_multiple = RC.addItemsMultiple
        plugin._orig_rc_additemsmultiple = orig_add_multiple
        RC.addItemsMultiple = function(rc_self, files, collections_to_add, ...)
            local TBR = _getTBR()
            if TBR and collections_to_add[TBR.TBR_COLL_NAME] then
                -- Count how many slots remain in the TBR collection.
                local coll  = rc_self.coll and rc_self.coll[TBR.TBR_COLL_NAME]
                local count = 0
                if coll then for _ in pairs(coll) do count = count + 1 end end
                local max     = TBR.TBR_MAX or 5
                local allowed = max - count
                if allowed <= 0 then
                    -- No room at all — block addition and warn.
                    collections_to_add = {}
                    for k, v in pairs(collections_to_add or {}) do
                        if k ~= TBR.TBR_COLL_NAME then collections_to_add[k] = v end
                    end
                    local ok_im, InfoMessage = pcall(require, "ui/widget/infomessage")
                    if ok_im then
                        require("ui/uimanager"):show(InfoMessage:new{
                            text    = _("To Be Read list is full (max. 5 books)."),
                            timeout = 2,
                        })
                    end
                    -- Still call orig for any other collections in the map.
                    local stripped = {}
                    for k, v in pairs(collections_to_add) do
                        if k ~= TBR.TBR_COLL_NAME then stripped[k] = v end
                    end
                    if next(stripped) then
                        orig_add_multiple(rc_self, files, stripped, ...)
                    end
                    return 0
                elseif allowed < (function() local n=0; for _ in pairs(files) do n=n+1 end; return n end)() then
                    -- Partial room — let the original run but truncate TBR additions afterwards
                    -- by removing any excess entries that pushed it over the limit.
                    local result = orig_add_multiple(rc_self, files, collections_to_add, ...)
                    local coll2 = rc_self.coll and rc_self.coll[TBR.TBR_COLL_NAME]
                    if coll2 then
                        -- Build ordered list and drop those beyond TBR_MAX.
                        local items = {}
                        for _, item in pairs(coll2) do items[#items+1] = item end
                        table.sort(items, function(a,b) return (a.order or 0) < (b.order or 0) end)
                        if #items > max then
                            for i = max + 1, #items do
                                coll2[items[i].file] = nil
                            end
                            rc_self:write({ [TBR.TBR_COLL_NAME] = true })
                        end
                        local ok_im, InfoMessage = pcall(require, "ui/widget/infomessage")
                        if ok_im then
                            require("ui/uimanager"):show(InfoMessage:new{
                                text    = _("To Be Read list is full (max. 5 books)."),
                                timeout = 2,
                            })
                        end
                    end
                    pcall(function() _syncTBRSettings(TBR); plugin:_scheduleRebuild() end)
                    return result
                end
            end
            local result = orig_add_multiple(rc_self, files, collections_to_add, ...)
            local TBR2 = _getTBR()
            if TBR2 and collections_to_add[TBR2.TBR_COLL_NAME] then
                pcall(function() _syncTBRSettings(TBR2); plugin:_scheduleRebuild() end)
            end
            return result
        end
    end

    if type(RC.addRemoveItemMultiple) == "function" then
        local orig_add_remove = RC.addRemoveItemMultiple
        plugin._orig_rc_addremoveitemmultiple = orig_add_remove
        RC.addRemoveItemMultiple = function(rc_self, file, collections_to_add, ...)
            local TBR = _getTBR()
            if TBR and collections_to_add[TBR.TBR_COLL_NAME] then
                local coll  = rc_self.coll and rc_self.coll[TBR.TBR_COLL_NAME]
                local count = 0
                if coll then for _ in pairs(coll) do count = count + 1 end end
                local max = TBR.TBR_MAX or 5
                -- Check if this file is already in TBR (would be a no-op add).
                local real = file
                pcall(function() real = require("ffi/util").realpath(file) or file end)
                local already_in = coll and coll[real] ~= nil
                if not already_in and count >= max then
                    -- Strip TBR from the add map and warn.
                    local stripped = {}
                    for k, v in pairs(collections_to_add) do
                        if k ~= TBR.TBR_COLL_NAME then stripped[k] = v end
                    end
                    local ok_im, InfoMessage = pcall(require, "ui/widget/infomessage")
                    if ok_im then
                        require("ui/uimanager"):show(InfoMessage:new{
                            text    = _("To Be Read list is full (max. 5 books)."),
                            timeout = 2,
                        })
                    end
                    orig_add_remove(rc_self, file, stripped, ...)
                    pcall(function() _syncTBRSettings(TBR); plugin:_scheduleRebuild() end)
                    return
                end
            end
            orig_add_remove(rc_self, file, collections_to_add, ...)
            local TBR2 = _getTBR()
            if TBR2 and collections_to_add[TBR2.TBR_COLL_NAME] then
                pcall(function() _syncTBRSettings(TBR2); plugin:_scheduleRebuild() end)
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
-- UIManager.show patch
-- Injects the navbar into qualifying fullscreen widgets and closes the
-- homescreen whenever another fullscreen widget appears on top of it.
-- _show_depth prevents re-entrant injection when orig_show calls show again.
-- ---------------------------------------------------------------------------

function M.patchUIManagerShow(plugin)
    local orig_show = UIManager.show
    plugin._orig_uimanager_show = orig_show
    local _show_depth = 0

    -- Widgets that receive navbar injection by name (in addition to those
    -- already sized to the content area via _navbar_height_reduced).
    local INJECT_NAMES = { collections = true, history = true, coll_list = true, homescreen = true }

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
        -- Fast path: non-fullscreen widgets need no SimpleUI logic.
        if not (widget and widget.covers_fullscreen) then
            return orig_show(um_self, widget, ...)
        end

        local n_extra    = select("#", ...)
        local extra_args = n_extra > 0 and { ... } or _EMPTY
        _show_depth = _show_depth + 1

        -- Wrap in pcall so _show_depth is always decremented even on error.
        local ok, result = pcall(function()

        -- When the FM appears after the reader closes with "Start with Homescreen"
        -- active, show the FM silently then immediately open the HS on top.
        if _show_depth == 1 and _hs_pending_after_reader
                and widget == plugin.ui and isStartWithHS() then
            _hs_pending_after_reader = false
            if n_extra > 0 then
                orig_show(um_self, widget, table.unpack(extra_args))
            else
                orig_show(um_self, widget)
            end
            -- Skip HS re-open if an external caller navigated the FM to a folder.
            if widget._sui_show_folder_pending then
                widget._sui_show_folder_pending = nil
                return
            end
            local HS = liveHS() or (function()
                local ok2, m = pcall(require, "sui_homescreen"); return ok2 and m
            end)()
            if HS and not HS._instance then
                if not plugin._goalTapCallback then plugin:addToMainMenu({}) end
                -- active_action was already set to "homescreen" in UIManager.close
                -- (when _hs_pending_after_reader was flagged), so no replaceBar or setDirty
                -- needed here — the FM is covered by the HS and its paint is never visible.
                -- Use the stashed pre-change value so _navbar_prev_action records the real
                -- tab that was active before the reader was opened (e.g. "home"), not
                -- "homescreen" which active_action was changed to.
                local prev_action = _hs_pending_prev_action or plugin.active_action
                _hs_pending_prev_action = nil
                HS.show(
                    function(aid) plugin:_navigate(aid, plugin.ui, Config.loadTabConfig(), false) end,
                    plugin._goalTapCallback
                )
                -- Fix _navbar_prev_action: overwrite with the real previous tab so
                -- Back closes to the correct tab.
                local hs_inst = HS._instance
                if hs_inst then hs_inst._navbar_prev_action = prev_action end
            end
            return
        end

        -- Decide whether to inject the navbar into this widget.
        local should_inject = _show_depth == 1
            and widget
            and not widget._navbar_injected
            and not widget._navbar_skip_inject
            and widget ~= plugin.ui
            and widget.covers_fullscreen
            and widget.title_bar
            and (widget._navbar_height_reduced or (widget.name and INJECT_NAMES[widget.name]))

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

        -- Apply title-bar customisations for injected widgets.
        Titlebar().applyToInjected(widget)

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

        -- Hide the native Back button on the collections widget when the
        -- "collections" tab is absent; there is no list to go back to.
        if widget.name == "collections" and not widget._navbar_onreturn_checked then
            widget._navbar_onreturn_checked = true
            if not tabs_set["collections"] and widget.onReturn then
                widget.onReturn = nil
                if widget.page_return_arrow then
                    widget.page_return_arrow:hide()
                end
            end
        end

        local display_action = effective_action or action_before
        if not widget._navbar_inner then widget._navbar_inner = widget[1] end

        -- Build the bar without navpager arrows for non-pageable widgets to
        -- avoid the flash of arrows that would immediately be removed.
        local widget_is_pageable = (type(widget.page_num) == "number")
            or (widget.file_chooser and type(widget.file_chooser.page_num) == "number")
        local navbar_container, wrapped, bar, topbar, bar_idx, topbar_on, topbar_idx =
            UI.wrapWithNavbar(widget._navbar_inner, display_action, tabs, not widget_is_pageable)
        UI.applyNavbarState(widget, navbar_container, bar, topbar, bar_idx, topbar_on, topbar_idx, tabs)
        widget._navbar_prev_action = action_before
        widget[1]                  = wrapped
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
                if G_reader_settings:nilOrTrue("navbar_topbar_enabled") then
                    local Topbar = require("sui_topbar")
                    zone_ratio_h = (Topbar.TOTAL_TOP_H() + UI.MOD_GAP) / screen_h
                else
                    zone_ratio_h = DTAP_ZONE_MENU.h
                end
                widget:registerTouchZones({
                    {
                        id          = "simpleui_menu_tap",
                        ges         = "tap",
                        screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = zone_ratio_h },
                        handler     = function(ges)
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

        -- Schedule a navpager arrow update for the next event-loop tick.
        -- Snapshot has_prev/has_next now to avoid races with a second
        -- updatePageInfo call that may fire during the same tick.
        if G_reader_settings:isTrue("navbar_navpager_enabled") and not _navpager_rebuild_pending then
            local has_prev_snap, has_next_snap = Config.getNavpagerState()
            _navpager_rebuild_pending = true
            UIManager:scheduleIn(0, function()
                _navpager_rebuild_pending = false
                if not G_reader_settings:isTrue("navbar_navpager_enabled") then return end
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
    local orig_close = UIManager.close
    plugin._orig_uimanager_close = orig_close

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
        local stack    = UI.getWindowStack()
        local to_close = {}
        for _, entry in ipairs(stack) do
            local w = entry.widget
            if w and w ~= fm and not w.covers_fullscreen then
                to_close[#to_close + 1] = w
            end
        end
        for _, w in ipairs(to_close) do UIManager:close(w) end

        local tabs        = Config.loadTabConfig()
        local prev_action = plugin_ref.active_action
        Bottombar.setActiveAndRefreshFM(plugin_ref, "homescreen", tabs)
        if not plugin_ref._goalTapCallback then plugin_ref:addToMainMenu({}) end
        HS.show(
            function(aid) plugin_ref:_navigate(aid, plugin_ref.ui, Config.loadTabConfig(), false) end,
            plugin_ref._goalTapCallback
        )
        local hs_inst = HS._instance
        if hs_inst then hs_inst._navbar_prev_action = prev_action end
    end

    UIManager.close = function(um_self, widget, ...)
        -- Fast path: non-fullscreen widgets need no SimpleUI logic.
        if not (widget and widget.covers_fullscreen) then
            return orig_close(um_self, widget, ...)
        end

        -- Identify a closing FM by identity (FM has no .name at class level).
        local widget_is_fm = (widget == plugin.ui)

        -- Restore the active tab when an injected widget closes normally.
        -- Clear _navbar_injected immediately so a second close() is a no-op.
        if widget._navbar_injected and not widget._navbar_closing_intentionally then
            widget._navbar_injected = nil

            if widget.name == "coll_list" then
                -- coll_list sits on top of collections; find prev_action on the
                -- underlying collections widget rather than calling restoreTabInFM.
                local fm = liveFM()
                if fm and fm._navbar_container then
                    local t       = Config.loadTabConfig()
                    local restored = nil
                    for _, entry in ipairs(UI.getWindowStack()) do
                        local w = entry.widget
                        if w and w ~= widget and w._navbar_injected
                                and (w.name == "collections" or w.name == "coll_list") then
                            restored = w._navbar_prev_action
                            break
                        end
                    end
                    if not restored then
                        restored = (fm.file_chooser
                            and M._resolveTabForPath(fm.file_chooser.path, t))
                            or t[1] or "home"
                    end
                    plugin.active_action = restored
                    Bottombar.replaceBar(fm, Bottombar.buildBarWidget(restored, t), t)
                    UIManager:setDirty(fm, "ui")
                end
            else
                plugin:_restoreTabInFM(nil, widget._navbar_prev_action)
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

        -- When the FM closes, also close the homescreen so the app can exit.
        if widget_is_fm then
            local HS      = liveHS()
            local hs_inst = HS and HS._instance
            if hs_inst then
                hs_inst._navbar_closing_intentionally = true
                orig_close(um_self, hs_inst)  -- bypass our wrapper
                if HS._instance == hs_inst then HS._instance = nil end
            end
        end

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
                    -- Reader closed back to the FM (not opening another book).
                    if not widget.tearing_down then
                        local return_to_folder = G_reader_settings:isTrue("navbar_hs_return_to_book_folder")
                        if not return_to_folder then
                            _hs_pending_after_reader = true
                            -- Stash the real previous tab so the _hs_pending handler can
                            -- set it on hs_inst._navbar_prev_action correctly, even after
                            -- active_action is changed to "homescreen" below.
                            _hs_pending_prev_action = plugin.active_action
                            -- Pre-set active_action so that when UIManager.show(HS) runs
                            -- the inject-path guard sees "homescreen" and skips the redundant
                            -- setActiveAndRefreshFM + setDirty(FM) — the FM is covered by HS
                            -- and its bar will be corrected by _restoreTabInFM when HS closes.
                            local _ao2 = { bookmark_browser=true, wifi_toggle=true, frontlight=true, power=true }
                            if not _ao2[plugin.active_action] then
                                plugin.active_action = "homescreen"
                            end
                            -- Lazy refresh: the user is looking at the HS, not the FM
                            -- file list. Deferring refreshPath() until the HS closes
                            -- eliminates I/O contention with the HS widget build and
                            -- first e-ink paint, making the book→HS transition faster.
                            -- The flag is consumed in patchUIManagerClose when
                            -- widget.name == "homescreen" closes (user taps Library/Back).
                            local fm_ref = liveFM()
                            if fm_ref then
                                fm_ref._sui_lazy_refresh_path = true
                            end
                        else
                            -- Returning directly to the folder — FM is the visible
                            -- target, so refresh immediately (0 delay, same tick).
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
                        -- Skip if the reader is still open (user closed a sub-panel).
                        local RUI = package.loaded["apps/reader/readerui"]
                        if RUI and RUI.instance then return end
                        local fm2 = liveFM()
                        if fm2 then _doShowHS(fm2, plugin) end
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
        orig_menu_init(menu_self, ...)

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

        if G_reader_settings:nilOrTrue("navbar_pagination_visible") then return end
        if not TARGET_NAMES[menu_self.name]
           and not (menu_self.covers_fullscreen and menu_self.is_borderless and menu_self.title_bar_fm_style) then
            return
        end

        -- Remove all children except content_group to strip the pagination row.
        local content = menu_self[1] and menu_self[1][1]
        if content then
            for i = #content, 1, -1 do
                if content[i] ~= menu_self.content_group then
                    table.remove(content, i)
                end
            end
        end

        -- Override _recalculateDimen to suppress pagination widget updates.
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
        return G_reader_settings:isTrue("navbar_navpager_enabled")
            or G_reader_settings:isTrue("navbar_pagination_show_subtitle")
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

    local function _setPageSubtitle(tb, page, page_num)
        if not tb or not tb.subtitle_widget then return end
        _setSubtitleUnified(tb, _fm_path_base, page, page_num)
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

        -- Snapshot page state now to avoid races with a second updatePageInfo
        -- call that may fire during the same tick (switchItemTable init).
        local captured_page     = menu_self.page     or 0
        local captured_page_num = menu_self.page_num or 0

        -- Update the subtitle synchronously.
        _setPageSubtitle(menu_self.title_bar, captured_page, captured_page_num)

        -- Coalesce arrow updates: skip if one is already queued.
        if _navpager_rebuild_pending then return end
        _navpager_rebuild_pending = true

        local has_prev = captured_page > 1
        local has_next = captured_page < captured_page_num

        UIManager:scheduleIn(0, function()
            _navpager_rebuild_pending = false
            if not G_reader_settings:isTrue("navbar_navpager_enabled") then return end
            local fm = plugin.ui
            if not (fm and fm._navbar_container) then return end
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
        -- Also treat the home folder as root when "Lock Home Folder" is enabled.
        local at_root = (clean_path == "/")
        if not at_root then
            local fc_cur = fm_self.file_chooser
            if fc_cur and fc_cur._simpleui_has_go_up ~= nil then
                at_root = not fc_cur._simpleui_has_go_up
            end
        end
        if not at_root and G_reader_settings:isTrue("lock_home_folder") and at_home then
            at_root = true
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
-- Runs only when "Start with Homescreen" is active, the reader is closed,
-- the homescreen tab exists, and the homescreen is not already visible.
-- Called from SimpleUIPlugin:onResume() in main.lua.
-- ---------------------------------------------------------------------------

function M.showHSAfterResume(plugin)
    if not isStartWithHS() then return end

    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance then return end

    local tabs = Config.loadTabConfig()
    if not tabInTabs("homescreen", tabs) then return end

    local HS = liveHS()
    if HS and HS._instance then
        -- The homescreen was already open when the device suspended (e.g. the
        -- touch menu was open on top of it).  We must NOT re-show the HS, but
        -- we DO need to refresh the QA tap callback in case it captured a now-
        -- stale FileManager reference.  main.lua:onResume does this too, but
        -- the callback here is the authoritative one passed to HS.show() — keep
        -- both in sync so whichever fires first is already correct.
        HS._instance._on_qa_tap = function(aid)
            plugin:_navigate(aid, plugin.ui, Config.loadTabConfig(), false)
        end
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
            HS2._instance._on_qa_tap = function(aid)
                plugin:_navigate(aid, plugin.ui, Config.loadTabConfig(), false)
            end
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
        if not plugin._goalTapCallback then plugin:addToMainMenu({}) end
        -- Always start at page 1 after resume; restoring the last page
        -- would be disorienting after waking from standby.
        HS2._current_page = 1
        HS2.show(
            function(aid) plugin:_navigate(aid, plugin.ui, Config.loadTabConfig(), false) end,
            plugin._goalTapCallback
        )
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
        if not G_reader_settings:isTrue("simpleui_debug_button_bounds") then return end
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
function M.closeReaderToHomescreen(plugin)
    local RUI = package.loaded["apps/reader/readerui"]
    if not (RUI and RUI.instance) then return end
    local readerui = RUI.instance

    local file = readerui.document and readerui.document.file

    -- Set lazy_refresh so the FM file-list scan is deferred until the HS
    -- closes, matching the native path's I/O optimisation.
    local fm_pre = liveFM()
    if fm_pre then fm_pre._sui_lazy_refresh_path = true end

    -- Stash the current tab so the HS Back button returns to the right place.
    local prev_action = plugin.active_action

    if isStartWithHS() then
        -- "Start with Homescreen" is active: mark tearing_down so the patched
        -- UIManager.close does NOT set _hs_pending_after_reader (that path relies
        -- on UIManager:show firing, which never happens when FM.instance already
        -- exists — showFileManager just calls changeToPath instead). We open the
        -- HS ourselves via scheduleIn below, same as the !isStartWithHS() path.
        readerui.tearing_down = true
    end

    readerui:onClose()
    readerui:showFileManager(file)

    -- After the FM is on the stack, open the HS on top.
    -- This handles both cases: when "Start with Homescreen" is active and when
    -- it is not. When active, FM.instance already exists so UIManager:show is
    -- never called and the _hs_pending_after_reader hook never fires — we must
    -- open the HS directly. When not active, the UIManager patches gate on
    -- isStartWithHS() so they would never open it either.
    UIManager:scheduleIn(0, function()
        if UIManager._exit_code ~= nil then return end
        local RUI2 = package.loaded["apps/reader/readerui"]
        if RUI2 and RUI2.instance then return end
        local HS = liveHS() or (function()
            local ok, m = pcall(require, "sui_homescreen"); return ok and m
        end)()
        if not HS or HS._instance then return end
        local fm_ref = liveFM()
        -- Abort if another fullscreen widget is already on top of the FM.
        if fm_ref then
            for _, entry in ipairs(UI.getWindowStack()) do
                local w = entry.widget
                if w and w ~= fm_ref and w.covers_fullscreen then return end
            end
        end
        -- Close any orphaned non-fullscreen popups before showing the HS.
        local to_close = {}
        for _, entry in ipairs(UI.getWindowStack()) do
            local w = entry.widget
            if w and w ~= fm_ref and not w.covers_fullscreen then
                to_close[#to_close + 1] = w
            end
        end
        for _, w in ipairs(to_close) do UIManager:close(w) end

        local tabs = Config.loadTabConfig()
        Bottombar.setActiveAndRefreshFM(plugin, "homescreen", tabs)
        if not plugin._goalTapCallback then plugin:addToMainMenu({}) end
        HS.show(
            function(aid) plugin:_navigate(aid, plugin.ui, tabs, false) end,
            plugin._goalTapCallback
        )
        local hs_inst = HS._instance
        if hs_inst then hs_inst._navbar_prev_action = prev_action end
    end)
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

-- Patch ReaderMenu.exitOrRestart so the "Closing book…" InfoMessage is shown
-- immediately — before onTapCloseMenu() closes the menu — rather than only
-- after the menu has already been dismissed and repainted.
--
-- The patch fires only when the closing-notice setting is active and we are
-- actually returning to the SimpleUI homescreen (same guards as onCloseDocument).
-- A flag (_closing_notice_shown) is set on the plugin so onCloseDocument skips
-- the duplicate UIManager:show + forceRePaint that would otherwise fire later.
function M.patchReaderMenuExit(plugin)
    local ReaderMenu = package.loaded["apps/reader/modules/readermenu"]
    if not ReaderMenu then
        -- ReaderMenu is not loaded yet; it will be required when a book is
        -- opened.  Wrap require so we patch it the moment it is first loaded.
        local orig_req = _G.require
        plugin._orig_require_for_readermenu = orig_req
        _G.require = function(modname, ...)
            local result = orig_req(modname, ...)
            if modname == "apps/reader/modules/readermenu"
                    and not result._simpleui_exit_patched then
                M._wrapReaderMenuExitOrRestart(plugin, result)
            end
            return result
        end
        return
    end
    if not ReaderMenu._simpleui_exit_patched then
        M._wrapReaderMenuExitOrRestart(plugin, ReaderMenu)
    end
end

function M._wrapReaderMenuExitOrRestart(plugin, ReaderMenu)
    local orig_exit = ReaderMenu.exitOrRestart
    plugin._orig_readermenu_exit = orig_exit

    ReaderMenu.exitOrRestart = function(rm_self, callback, force)
        -- Show the "Closing book…" notice now, while the menu is still visible.
        -- The original exitOrRestart calls onTapCloseMenu() first (which closes
        -- the menu and triggers a repaint), then defers onClose() to nextTick —
        -- so the notice only appeared after the menu was already gone.
        --
        -- We skip onTapCloseMenu() entirely: it is redundant because onClose()
        -- already fires CloseReaderMenu + CloseConfigMenu internally (readerui.lua).
        -- Removing it means one fewer UIManager:close + repaint on the hot path.
        --
        -- The notice appears on top of the open menu; the menu is then torn down
        -- as part of the normal onClose() sequence.
        if G_reader_settings:nilOrTrue("simpleui_hs_closing_notice") then
            local return_to_folder = G_reader_settings:isTrue("navbar_hs_return_to_book_folder")
            local start_with_hs    = G_reader_settings:readSetting("start_with", "filemanager") == "homescreen_simpleui"
            if start_with_hs and not return_to_folder then
                local ok_im, InfoMessage = pcall(require, "ui/widget/infomessage")
                if ok_im and InfoMessage then
                    UIManager:show(InfoMessage:new{
                        text    = _("Closing book…"),
                        timeout = 0.0,
                    })
                    -- forceRePaint paints the notice onto the screen synchronously,
                    -- while the menu is still in the widget stack behind it.
                    -- Without this the InfoMessage is queued but never rendered
                    -- before onClose() tears down the entire ReaderUI.
                    UIManager:forceRePaint()
                    -- Mark as shown so onCloseDocument skips the duplicate paint.
                    plugin._closing_notice_shown = true
                end
            end
        end
        -- Skip onTapCloseMenu(); go straight to onClose() via nextTick.
        UIManager:nextTick(function()
            rm_self.ui:onClose()
            if callback then callback() end
        end)
    end

    ReaderMenu._simpleui_exit_patched = true
end

function M.installAll(plugin)
    M.patchFileManagerClass(plugin)
    M.patchStartWithMenu()
    M.patchBookList(plugin)
    M.patchCollections(plugin)
    M.patchFullscreenWidgets(plugin)
    M.patchUIManagerShow(plugin)
    M.patchUIManagerClose(plugin)
    M.patchMenuInitForPagination(plugin)
    M.patchMenuForNavpager(plugin)
    M.patchBookInfoNavigation(plugin)
    M.patchReaderMenuExit(plugin)
    -- Install button-bounds overlay when the debug setting is on at startup.
    if G_reader_settings:isTrue("simpleui_debug_button_bounds") then
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
end

function M.teardownAll(plugin)
    -- Restore UIManager patches first (highest call frequency).
    if plugin._orig_uimanager_show then
        UIManager.show              = plugin._orig_uimanager_show
        plugin._orig_uimanager_show = nil
    end
    if plugin._orig_uimanager_close then
        UIManager.close              = plugin._orig_uimanager_close
        plugin._orig_uimanager_close = nil
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
        if plugin._orig_rc_additemsmultiple then
            RC.addItemsMultiple              = plugin._orig_rc_additemsmultiple
            plugin._orig_rc_additemsmultiple = nil
        end
        if plugin._orig_rc_addremoveitemmultiple then
            RC.addRemoveItemMultiple              = plugin._orig_rc_addremoveitemmultiple
            plugin._orig_rc_addremoveitemmultiple = nil
        end
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

    local FileManagerMenu = package.loaded["apps/filemanager/filemanagermenu"]
    if FileManagerMenu and FileManagerMenu._simpleui_startwith_patched then
        FileManagerMenu.getStartWithMenuTable   = FileManagerMenu._simpleui_startwith_orig
        FileManagerMenu._simpleui_startwith_orig    = nil
        FileManagerMenu._simpleui_startwith_patched = nil
    end

    local Dispatcher = package.loaded["dispatcher"]
    if Dispatcher and Dispatcher._simpleui_execute_patched then
        Dispatcher.execute                   = Dispatcher._simpleui_execute_orig
        Dispatcher._simpleui_execute_orig    = nil
        Dispatcher._simpleui_execute_patched = nil
    end

    M.uninstallButtonBoundsDebug(plugin)

    -- Restore ReaderMenu.exitOrRestart patch.
    local ReaderMenu = package.loaded["apps/reader/modules/readermenu"]
    if ReaderMenu and ReaderMenu._simpleui_exit_patched then
        if plugin._orig_readermenu_exit then
            ReaderMenu.exitOrRestart         = plugin._orig_readermenu_exit
            plugin._orig_readermenu_exit     = nil
        end
        ReaderMenu._simpleui_exit_patched = nil
    end
    -- Restore deferred require hook if ReaderMenu was never loaded.
    if plugin._orig_require_for_readermenu then
        _G.require                             = plugin._orig_require_for_readermenu
        plugin._orig_require_for_readermenu    = nil
    end
    plugin._closing_notice_shown = nil

    -- Reset module-level state so a re-enable cycle starts clean.
    -- Transient flags are cleared unconditionally.
    -- _start_with_hs is re-read from the persisted setting instead of being
    -- forced to false: if the user does disable→enable in the same session,
    -- package.loaded keeps this module alive so the top-level initialiser
    -- never runs again, and hardcoding false would leave isStartWithHS() wrong
    -- for the rest of the session.
    _hs_boot_done             = false
    _hs_pending_after_reader  = false
    _hs_pending_prev_action   = nil
    _start_with_hs            = G_reader_settings:readSetting("start_with", "filemanager") == "homescreen_simpleui"
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