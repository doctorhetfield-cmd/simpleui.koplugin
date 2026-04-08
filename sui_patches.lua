-- patches.lua — Simple UI
-- Monkey-patches applied to KOReader on plugin load.

local UIManager  = require("ui/uimanager")
local Screen     = require("device").screen
local logger     = require("logger")
local _          = require("gettext")

local Config    = require("sui_config")
local UI        = require("sui_core")
local Bottombar = require("sui_bottombar")
local Titlebar  = require("sui_titlebar")

local M = {}

-- Sentinel table reused for UIManager.show calls with no extra args,
-- avoiding a table allocation on every call.
local _EMPTY = {}

-- Persists across plugin re-instantiation because patches.lua stays in
-- package.loaded for the whole session. Prevents the homescreen auto-open
-- from firing more than once (only on the initial boot FM).
-- Cleared in teardownAll so a disable/re-enable cycle starts fresh.
local _hs_boot_done = false

-- Set to true when ReaderUI closes with "Start with Homescreen" active.
-- Picked up by the next setupLayout call to defer the FM paint until after
-- the homescreen is open, eliminating the flash between reader and homescreen.
local _hs_pending_after_reader = false

-- Caches the result so UIManager.show and UIManager.close (hot paths) avoid
-- repeated settings lookups on every call. Updated on init and in menu.
local _start_with_hs = G_reader_settings:readSetting("start_with", "filemanager") == "homescreen_simpleui"

-- Navbar keyboard focus mode: transparent InputContainer placed on top of the
-- UIManager stack while the user navigates bottom bar tabs via keyboard.
-- nil when inactive.  _navbar_kb_idx is the 1-based index of the focused tab.
local _navbar_kb_capture   = nil
local _navbar_kb_idx       = 1
-- Optional callback invoked when Up/Back exits navbar keyboard focus mode.
-- Set by callers such as the homescreen that need to restore their own focus
-- instead of the default file-chooser last-item focus.
local _navbar_kb_return_fn = nil
-- Forward reference set once inside patchFileManagerClass so the function can
-- be called from outside (e.g. HomescreenWidget) via M.enterNavbarKbFocus.
local _enterNavbarKbFocus_fn = nil

-- Navpager rebuild coalescence flag.
local _navpager_rebuild_pending = false

-- Returns true when "Start with Homescreen" is the active start_with value.
local function isStartWithHS()
    return _start_with_hs
end

-- Linear search over the tab list (typically 3–6 entries).
-- Used only in single-call contexts (boot, onReturn hook). Hot paths
-- in UIManager.show build a set instead to avoid repeated scans.
local function tabInTabs(id, tabs)
    for _, v in ipairs(tabs) do
        if v == id then return true end
    end
    return false
end

-- Builds a set from a tab list for O(1) membership tests.
local function tabsToSet(tabs)
    local s = {}
    for _, v in ipairs(tabs) do s[v] = true end
    return s
end

-- ---------------------------------------------------------------------------
-- FileManager.setupLayout
-- Injects the navbar, patches the title bar, and wires up onShow / onPathChanged.
-- ---------------------------------------------------------------------------

function M.patchFileManagerClass(plugin)
    local FileManager      = require("apps/filemanager/filemanager")
    local orig_setupLayout = FileManager.setupLayout
    plugin._orig_fm_setup  = orig_setupLayout

    -- Navbar touch zones must run before FileChooser/scroll children (sui_core).
    UI.applyGesturePriorityHandleEvent(FileManager)

    -- The KOReader filemanager_swipe touch zone handler calls onSwipeFM but
    -- does not return true, so InputContainer.onGesture considers the event
    -- unconsumed and the event propagates a second time through
    -- WidgetContainer children (FileManagerMenu, etc.), causing every
    -- horizontal swipe in the library to advance two pages instead of one.
    -- Patch initGesListener to re-register the zone with a handler that
    -- returns true, consuming the event after the page turn.
    local orig_initGesListener        = FileManager.initGesListener
    plugin._orig_initGesListener      = orig_initGesListener
    FileManager._simpleui_ges_patched = false
    FileManager.initGesListener = function(fm_self)
        orig_initGesListener(fm_self)
        -- Override the zone registered above so its handler returns true,
        -- consuming the event after a page-turn swipe to prevent it from
        -- propagating a second time through WidgetContainer children.
        -- Exception: swipes going "south" (downward) must NOT be consumed
        -- here so that FileManagerMenu's zones can catch them and open the
        -- top menu.  The same applies to "north" swipes in case the user has
        -- configured the menu to open on an upward swipe.
        fm_self:registerTouchZones({
            {
                id          = "filemanager_swipe",
                ges         = "swipe",
                screen_zone = {
                    ratio_x = 0, ratio_y = 0,
                    ratio_w = 1, ratio_h = 1,
                },
                handler = function(ges)
                    -- Do not consume menu-direction swipes: let them fall
                    -- through to FileManagerMenu's touch zones (filemanager_swipe
                    -- and filemanager_ext_swipe registered on the FM child menu).
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
        local topbar_on = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
        fm_self._navbar_height = Bottombar.TOTAL_H() + (topbar_on and require("sui_topbar").TOTAL_TOP_H() or 0)

        -- Each setupLayout call produces a fresh widget tree — reset the
        -- "already shown" guard so the next onShow does the proper go-home init.
        fm_self._navbar_already_shown = nil

        -- Patch FileChooser.init once on the class so repeated FM rebuilds
        -- don't re-wrap. Reduces height to the content area.
        local FileChooser = require("ui/widget/filechooser")
        if not FileChooser._navbar_patched then
            local orig_fc_init   = FileChooser.init
            plugin._orig_fc_init = orig_fc_init
            FileChooser._navbar_patched = true
            FileChooser.init = function(fc_self)
                if fc_self.height == nil and fc_self.width == nil then
                    fc_self.height = UI.getContentHeight()
                    fc_self.y      = UI.getContentTop()
                end
                orig_fc_init(fc_self)
            end
        end

        orig_setupLayout(fm_self)

        -- Delegate all FM title-bar customisation to titlebar.lua.
        -- apply() is a no-op when the "Custom Title Bar" setting is off.
        Titlebar.apply(fm_self)

        -- Keep the original inner widget reference so re-wrapping on subsequent
        -- setupLayout calls wraps the same widget instead of the wrapper.
        local inner_widget
        if fm_self._navbar_inner then
            inner_widget = fm_self._navbar_inner
        else
            inner_widget          = fm_self[1]
            fm_self._navbar_inner = inner_widget
        end

        local tabs = Config.loadTabConfig()

        local navbar_container, wrapped, bar, topbar, bar_idx, topbar_on2, topbar_idx =
            UI.wrapWithNavbar(inner_widget, plugin.active_action, tabs)
        UI.applyNavbarState(fm_self, navbar_container, bar, topbar, bar_idx, topbar_on2, topbar_idx, tabs)
        fm_self[1] = wrapped
        fm_self._simpleui_plugin = plugin

        plugin:_updateFMHomeIcon()

        -- On boot only: if "Start with Homescreen" is active and the homescreen
        -- tab exists, defer opening the HS until onShow fires (FM must be on stack).
        if not _hs_boot_done then
            _hs_boot_done = true
            if isStartWithHS() and tabInTabs("homescreen", tabs) then
                plugin.active_action = "homescreen"
                fm_self._hs_autoopen_pending = true
            end
        end

        -- onShow fires once the FM is on the UIManager stack.
        local orig_onShow = fm_self.onShow
        fm_self.onShow = function(this)
            if orig_onShow then orig_onShow(this) end
            Bottombar.resizePaginationButtons(this.file_chooser or this, Bottombar.getPaginationIconSize())

            -- Open the homescreen if this FM was flagged at setupLayout time.
            if this._hs_autoopen_pending then
                this._hs_autoopen_pending = nil
                UIManager:scheduleIn(0, function()
                    local HS = package.loaded["sui_homescreen"]
                    if not HS then
                        local ok, m = pcall(require, "sui_homescreen")
                        HS = ok and m
                    end
                    if HS then
                        if not plugin._goalTapCallback then plugin:addToMainMenu({}) end
                        -- plugin.ui and loadTabConfig() resolved at tap time so FM
                        -- reinits or tab config changes while the HS is open are picked up.
                        HS.show(function(aid) plugin:_navigate(aid, plugin.ui, Config.loadTabConfig(), false) end, plugin._goalTapCallback)
                    end
                end)
                return
            end

            -- Guard: only do the "go home" reset on the *first* show of a fresh FM
            -- instance. When the FM reappears because a menu was closed (or a
            -- fullscreen sub-widget closed), _navbar_already_shown is already true
            -- and we must NOT reset active_action — that would discard whatever tab
            -- the user was on and break quick-actions until the next library open.
            if this._navbar_already_shown then return end
            this._navbar_already_shown = true

            -- First genuine show: reset the active tab to "home" and navigate to
            -- home_dir, unless "Return to book folder" is enabled — in that case
            -- the FM was already positioned at the book's folder by showFileManager()
            -- (native KOReader behaviour) and we should not override that.
            if this._navbar_container then
                local t = Config.loadTabConfig()
                local return_to_folder = G_reader_settings:isTrue("navbar_hs_return_to_book_folder")
                if not return_to_folder then
                    plugin.active_action = "home"
                    local home = G_reader_settings:readSetting("home_dir")
                    if home and this.file_chooser then
                        -- Suppress onPathChanged: replaceBar below covers the bar update.
                        this._navbar_suppress_path_change = true
                        this.file_chooser:changeToPath(home)
                        this._navbar_suppress_path_change = nil
                        -- updateTitleBarPath is skipped when onPathChanged is suppressed,
                        -- so call it explicitly to clear the subtitle at the home folder.
                        -- Pass force_home=true so the function treats this as "at home"
                        -- even when item_table is not yet populated (avoids stale subtitle).
                        if this.updateTitleBarPath then
                            this:updateTitleBarPath(home, true)
                        end
                    end
                end
                local active = return_to_folder and M._resolveTabForPath(
                    this.file_chooser and this.file_chooser.path, t) or "home"
                Bottombar.replaceBar(this, Bottombar.buildBarWidget(active, t), t)
                UIManager:setDirty(this, "ui")
            end
        end

        -- onCloseAllMenus fires when the main KOReader menu (TouchMenu) closes.
        -- After a menu session the FM's navbar touch-zones can become stale —
        -- particularly if a settings change caused an internal widget rebuild.
        -- Re-registering touch zones and repainting the bar with the current
        -- active_action restores quick-action taps immediately without requiring
        -- the user to navigate away and back.
        local orig_onCloseAllMenus = fm_self.onCloseAllMenus
        fm_self.onCloseAllMenus = function(this)
            if orig_onCloseAllMenus then orig_onCloseAllMenus(this) end
            if not this._navbar_container then return end
            local t = Config.loadTabConfig()
            -- Re-register touch zones so any widget rebuild during the menu
            -- session does not leave stale gesture handlers behind.
            plugin:_registerTouchZones(this)
            -- Repaint the bar with the tab that was active before the menu opened.
            Bottombar.replaceBar(this, Bottombar.buildBarWidget(plugin.active_action, t), t)
            UIManager:setDirty(this, "ui")
        end

        plugin:_registerTouchZones(fm_self)

        -- Block non-portrait rotations in the File Manager.
        -- onSetRotationMode is the event KOReader dispatches when the user or
        -- a gesture triggers a screen rotation. Returning true here consumes
        -- the event and prevents the FM from rotating to landscape or inverted
        -- portrait. The reader is unaffected — it has its own instance and its
        -- own onSetRotationMode handler is never touched here.
        -- Screen rotation constants: 0 = portrait, 1 = landscape-left,
        -- 2 = portrait-inverted, 3 = landscape-right.
        fm_self.onSetRotationMode = function(_self, mode)
            local ok, err = pcall(function()
                if mode ~= 0 then
                    -- Hardware forçou rotação — invalidar cache antes de bloquear
                    -- para evitar que onScreenResize use dimensões stale.
                    local BB = require("sui_bottombar")
                    BB.invalidateDimCache()
                    return
                end
            end)
            if not ok then
                require("logger").warn("simpleui: onSetRotationMode blocked with error:", tostring(err))
            end
            return true  -- bloqueia sempre em caso de erro; portrait regressa normalmente
        end

        -- onPathChanged: update the active tab when the user navigates directories.
        -- Skipped when _navbar_suppress_path_change is set — that flag is raised by
        -- programmatic changeToPath calls (tab tap, onShow boot) that already handle
        -- the bar rebuild themselves, making this handler redundant in those cases.
        fm_self.onPathChanged = function(this, new_path)
            if this._navbar_suppress_path_change then return end
            -- Update the title bar subtitle with the new path (mirrors what
            -- FileManager.updateTitleBarPath / onPathChanged originally did).
            if this.updateTitleBarPath then
                local home_dir2 = G_reader_settings:readSetting("home_dir") or ""
                local is_home = new_path and (new_path:gsub("/$","") == home_dir2:gsub("/$",""))
                this:updateTitleBarPath(new_path, is_home or nil)
            end
            local t          = Config.loadTabConfig()
            local new_active = M._resolveTabForPath(new_path, t) or "home"
            plugin.active_action = new_active
            if this._navbar_container then
                Bottombar.replaceBar(this, Bottombar.buildBarWidget(new_active, t), t)
                UIManager:setDirty(this, "ui")
            end
            plugin:_updateFMHomeIcon()
            -- Mark that the FM file browser was visited during this session.
            -- CoverBrowser renders scaled-down cover thumbnails into the FM list,
            -- replacing BookInfoManager’s native-size bitmaps with smaller copies.
            -- When this happens the HS cover cache is stale and must be freed so
            -- getCoverBB() re-scales from the BIM’s fresh (native-size) bitmaps.
            -- The flag is cleared in HomescreenWidget:onCloseWidget() after the
            -- cache decision is made.
            local HS = package.loaded["sui_homescreen"]
            if HS then HS._library_was_visited = true end
        end

        -- ── Navbar keyboard focus ───────────────────────────────────────────
        -- Capture device + focusmanager references once; shared by the lambdas.
        local _Device2      = require("device")
        local _FocusManager = require("ui/widget/focusmanager")

        -- _enterNavbarKbFocus: called when Down is pressed at the last file.
        -- Pushes a transparent InputContainer onto the UIManager stack that
        -- captures Left/Right (tab navigation), Press (activate), Up/Back (exit).
        -- Optional return_fn is called when Up/Back exits, instead of the
        -- default file-chooser focus-return (used by the homescreen).
        local function _enterNavbarKbFocus(return_fn)
            if not _Device2:hasDPad() then return end
            if not G_reader_settings:nilOrTrue("navbar_enabled") then return end
            if _navbar_kb_capture then return end  -- already active
            _navbar_kb_return_fn = return_fn or false

            -- Find the 1-based index of the currently active tab.
            local tabs = Config.loadTabConfig()
            _navbar_kb_idx = 1
            for i, t in ipairs(tabs) do
                if t == plugin.active_action then _navbar_kb_idx = i; break end
            end

            -- Rebuild the bar with a focus-border on the active tab.
            local FM0 = package.loaded["apps/filemanager/filemanager"]
            local fm0 = FM0 and FM0.instance
            local target0 = M._getNavbarTarget and M._getNavbarTarget(fm0) or fm0
            if target0 then
                Bottombar.replaceBar(target0,
                    Bottombar.buildBarWidgetWithKeyFocus(plugin.active_action, tabs, _navbar_kb_idx),
                    tabs)
                UIManager:setDirty(target0, "ui")
            end

            -- Build the transparent input-only overlay widget.
            local InputContainer2 = require("ui/widget/container/inputcontainer")
            local Geom2           = require("ui/geometry")
            local capture = InputContainer2:new{
                dimen             = Geom2:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() },
                covers_fullscreen = false,
            }
            function capture:paintTo() end  -- transparent

            local function _moveNavbar(delta)
                local t2 = Config.loadTabConfig()
                _navbar_kb_idx = ((_navbar_kb_idx - 1 + delta + #t2) % #t2) + 1
                local FM2 = package.loaded["apps/filemanager/filemanager"]
                local fm2 = FM2 and FM2.instance
                local target2 = M._getNavbarTarget and M._getNavbarTarget(fm2) or fm2
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
                -- Restore the normal (unfocused) bar.
                local FM2 = package.loaded["apps/filemanager/filemanager"]
                local fm2 = FM2 and FM2.instance
                local target2 = M._getNavbarTarget and M._getNavbarTarget(fm2) or fm2
                if target2 then
                    local t2 = Config.loadTabConfig()
                    Bottombar.replaceBar(target2, Bottombar.buildBarWidget(plugin.active_action, t2), t2)
                    UIManager:setDirty(target2, "ui")
                end
                -- Invoke the return callback (homescreen) or restore FC focus.
                local ret_fn = _navbar_kb_return_fn
                _navbar_kb_return_fn = nil
                if ret_fn then
                    ret_fn()
                else
                    local FC = package.loaded["ui/widget/filechooser"]
                    local fc = FC and FM0 and FM0.instance and FM0.instance.file_chooser
                    if fc and fc.layout then
                        fc:moveFocusTo(1, #fc.layout, _FocusManager.FORCED_FOCUS)
                    end
                end
            end

            capture.key_events = {}
            capture.key_events.NavbarKbLeft  = { { "Left"  } }
            capture.key_events.NavbarKbRight = { { "Right" } }
            capture.key_events.NavbarKbPress = { { "Press" } }
            capture.key_events.NavbarKbUp    = { { "Up"    } }
            if _Device2.input and _Device2.input.group and _Device2.input.group.Back then
                capture.key_events.NavbarKbBack = { { _Device2.input.group.Back } }
            end

            function capture:onNavbarKbLeft()   _moveNavbar(-1); return true end
            function capture:onNavbarKbRight()  _moveNavbar(1);  return true end
            function capture:onNavbarKbUp()     _exitNavbarKb(); return true end
            function capture:onNavbarKbBack()   _exitNavbarKb(); return true end
            function capture:onNavbarKbPress()
                _navbar_kb_capture = nil
                UIManager:close(capture)
                local t2     = Config.loadTabConfig()
                local action = t2[_navbar_kb_idx]
                if action then
                    local FM2 = package.loaded["apps/filemanager/filemanager"]
                    local fm2 = FM2 and FM2.instance
                    if fm2 then
                        local target = M._getNavbarTarget and M._getNavbarTarget(fm2) or fm2
                        plugin:_navigate(action, target, t2, false)
                    end
                end
                return true
            end

            _navbar_kb_capture = capture
            UIManager:show(capture)
        end

        -- Expose so HomescreenWidget can call M.enterNavbarKbFocus(return_fn).
        _enterNavbarKbFocus_fn = _enterNavbarKbFocus

        -- Override _wrapAroundY on the FileChooser instance so that pressing
        -- Down at the last item enters navbar keyboard focus instead of wrapping.
        if _Device2:hasDPad() and fm_self.file_chooser then
            local fc = fm_self.file_chooser
            if rawget(fc, "_wrapAroundY") == nil then  -- only patch once
                local _origWrapY = fc._wrapAroundY
                fc._wrapAroundY = function(self_fc, dy)
                    if dy > 0 and self_fc.page == (self_fc.total_pages or 1) then
                        _enterNavbarKbFocus()
                    else
                        return _origWrapY(self_fc, dy)
                    end
                end
            end
        end
    end
end

-- Returns the tab id whose configured path matches the given filesystem path,
-- or nil if no tab matches. Strips trailing slashes before comparing.
function M._resolveTabForPath(path, tabs)
    if not path then return nil end
    path = path:gsub("/$", "")
    local home_dir = G_reader_settings:readSetting("home_dir")
    if home_dir then home_dir = home_dir:gsub("/$", "") end
    for _i, tab_id in ipairs(tabs) do
        if tab_id == "home" then
            if home_dir and path == home_dir then return "home" end
        elseif tab_id:match("^custom_qa_%d+$") then
            local cfg = Config.getCustomQAConfig(tab_id)
            if cfg.path then
                local cfg_path = cfg.path:gsub("/$", "")
                if path == cfg_path then return tab_id end
            end
        end
    end
    return nil
end

-- Public entry point called by HomescreenWidget:onHSFocusDown when the user
-- presses Down on the last content row. Delegates to the closure captured
-- inside patchFileManagerClass (set once at patch time). Optional return_fn
-- is called when Up/Back exits the navbar focus mode.
function M.enterNavbarKbFocus(return_fn)
    if _enterNavbarKbFocus_fn then
        _enterNavbarKbFocus_fn(return_fn)
    end
end

-- ---------------------------------------------------------------------------
-- FileManagerMenu.getStartWithMenuTable
-- Injects "Home Screen" into KOReader's Start With submenu.
-- Patched once per session; guarded by a flag on the class itself.
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
        local sub = result.sub_item_table
        if type(sub) ~= "table" then return result end
        -- Guard against the entry already being present.
        local has_homescreen = false
        for _i, item in ipairs(sub) do
            if item.text == _("Home Screen") and item.radio then has_homescreen = true end
        end
        if not has_homescreen then
            table.insert(sub, math.max(1, #sub), {
                text         = _("Home Screen"),
                checked_func = function() return isStartWithHS() end,
                callback = function()
                    G_reader_settings:saveSetting("start_with", "homescreen_simpleui")
                    _start_with_hs = true  -- update cache immediately
                end,
                radio = true,
            })
        end
        -- Update the parent item text when "Home Screen" is the active choice.
        local orig_text_func = result.text_func
        result.text_func = function()
            if isStartWithHS() then
                return _("Start with") .. ": " .. _("Home Screen")
            end
            return orig_text_func and orig_text_func() or _("Start with")
        end
        return result
    end
end

-- ---------------------------------------------------------------------------
-- BookList.new
-- Reduces BookList height to the content area (excludes navbar + topbar).
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

-- ---------------------------------------------------------------------------
-- FMColl.onShowCollList + Menu.new + ReadCollection
-- Reduces the coll_list Menu height to the content area. patch_depth gates
-- Menu.new so only menus created during onShowCollList are affected.
-- Also syncs the SimpleUI collections pool when KOReader renames/deletes.
-- ---------------------------------------------------------------------------

function M.patchCollections(plugin)
    local ok, FMColl = pcall(require, "apps/filemanager/filemanagercollection")
    if not (ok and FMColl) then return end
    local Menu          = require("ui/widget/menu")
    local orig_menu_new = Menu.new
    plugin._orig_menu_new    = orig_menu_new
    plugin._orig_fmcoll_show = FMColl.onShowCollList
    local patch_depth = 0

    local orig_onShowCollList = FMColl.onShowCollList
    FMColl.onShowCollList = function(fmc_self, ...)
        patch_depth = patch_depth + 1
        local ok2, result = pcall(orig_onShowCollList, fmc_self, ...)
        patch_depth = patch_depth - 1
        if not ok2 then error(result) end
        return result
    end

    -- Intercept Menu.new only while onShowCollList is on the call stack.
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

    -- Removes a collection from the SimpleUI selected list and cover-override table.
    local function _removeFromPool(name)
        local CW = package.loaded["collectionswidget"]
        if not CW then return end
        local selected = CW.getSelected()
        local changed  = false
        for i = #selected, 1, -1 do
            if selected[i] == name then
                table.remove(selected, i)
                changed = true
            end
        end
        if changed then CW.saveSelected(selected) end
        local overrides = CW.getCoverOverrides()
        if overrides[name] then
            overrides[name] = nil
            CW.saveCoverOverrides(overrides)
        end
    end

    -- Renames a collection in the SimpleUI selected list and cover-override table.
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
            local result = orig_remove(rc_self, coll_name, ...)
            local ok2, err = pcall(function()
                _removeFromPool(coll_name)
                Config.purgeQACollection(coll_name)
                Config.invalidateTabsCache()
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
end

-- ---------------------------------------------------------------------------
-- SortWidget.new + PathChooser.new
-- Reduces height to the content area. SortWidget also gets title padding and
-- a _populateItems hook to force a repaint after each sort operation.
-- ---------------------------------------------------------------------------

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
            -- Temporarily wrap TitleBar.new to inject horizontal padding,
            -- then restore it immediately after SortWidget is constructed.
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
-- UIManager.show
-- Injects the navbar into qualifying fullscreen widgets and closes the
-- homescreen when any other fullscreen widget appears on top of it.
-- _show_depth prevents re-entrant injection when orig_show calls show again.
-- ---------------------------------------------------------------------------

function M.patchUIManagerShow(plugin)
    local orig_show = UIManager.show
    plugin._orig_uimanager_show = orig_show
    local _show_depth = 0

    local INJECT_NAMES = { collections = true, history = true, coll_list = true, homescreen = true }

    -- Resolves the live FileManager menu at call time, never capturing a stale
    -- reference. The FM is destroyed and recreated each time the reader closes,
    -- so a closure over the old FM's .menu would point at ReaderMenu and crash.
    -- Defined once here, shared across all injected widgets.
    local function _fmMenu()
        local live_fm = plugin.ui
        if live_fm and live_fm.menu
                and type(live_fm.menu.name) == "string"
                and live_fm.menu.name:find("filemanager") then
            return live_fm.menu
        end
        local FM2 = package.loaded["apps/filemanager/filemanager"]
        local inst = FM2 and FM2.instance
        if inst and inst.menu then return inst.menu end
        return nil
    end

    UIManager.show = function(um_self, widget, ...)
        -- Fast path: the vast majority of show() calls are non-fullscreen
        -- widgets (dialogs, menus, InfoMessage, toasts, etc.). None of the
        -- SimpleUI injection logic applies to them — skip everything.
        if not (widget and widget.covers_fullscreen) then
            -- Non-fullscreen widgets (dialogs, menus, InfoMessage, toasts, etc.)
            -- do not need any SimpleUI injection logic — return immediately.
            -- Note: the ButtonDialog callback-wrapping block that previously lived
            -- here (to make Dispatcher:execute work over the HS) has been removed.
            -- executeCustomQA now calls Dispatcher:execute directly, so no dialog
            -- callback ever needs the HS temporarily removed from the stack. The
            -- wrapping caused every ButtonDialog opened over the HS (power, bookmark
            -- source selector, etc.) to close the HS on button tap, which was wrong.
            return orig_show(um_self, widget, ...)
        end

        -- Capture varargs before the pcall closure; reuse _EMPTY when none present.
        local n_extra    = select("#", ...)
        local extra_args = n_extra > 0 and { ... } or _EMPTY
        _show_depth = _show_depth + 1

        -- Wrap the body in pcall so _show_depth is always decremented on error.
        local ok, result = pcall(function()

        -- When the FM appears after the reader closes with "Start with Homescreen"
        -- active, show it silently first then immediately open the HS on top,
        -- eliminating the flash of the FM before the homescreen appears.
        if _show_depth == 1 and _hs_pending_after_reader
                and widget and widget == plugin.ui
                and isStartWithHS() then
            _hs_pending_after_reader = false
            if n_extra > 0 then
                orig_show(um_self, widget, table.unpack(extra_args))
            else
                orig_show(um_self, widget)
            end
            local HS = package.loaded["sui_homescreen"]
            if not HS then
                local ok2, m = pcall(require, "sui_homescreen")
                HS = ok2 and m
            end
            if HS and not HS._instance then
                if not plugin._goalTapCallback then plugin:addToMainMenu({}) end
                local tabs = Config.loadTabConfig()
                -- Capture the FM's active tab *before* setting it to "homescreen".
                -- The HS widget is injected by UIManager.show below, which reads
                -- plugin.active_action as action_before and stores it as
                -- _navbar_prev_action. If we called setActiveAndRefreshFM first,
                -- action_before would already be "homescreen", so closing the HS
                -- via back-button would restore "homescreen" instead of the real
                -- previous tab (typically "home"). By setting _navbar_prev_action
                -- explicitly after show, we ensure the correct value is used.
                local prev_action = plugin.active_action
                Bottombar.setActiveAndRefreshFM(plugin, "homescreen", tabs)
                -- plugin.ui and loadTabConfig() resolved at tap time so FM
                -- reinits or tab config changes while the HS is open are picked up.
                HS.show(
                    function(aid) plugin:_navigate(aid, plugin.ui, Config.loadTabConfig(), false) end,
                    plugin._goalTapCallback
                )
                -- Correct _navbar_prev_action: UIManager.show captured "homescreen"
                -- as action_before (because setActiveAndRefreshFM ran first), but the
                -- real state to restore on back-button close is the tab that was active
                -- before the HS opened.
                local hs_inst = HS._instance
                if hs_inst then hs_inst._navbar_prev_action = prev_action end
            end
            return
        end

        -- Injection criteria: top-level show, fullscreen, not already injected,
        -- has a title bar (excludes ReaderUI), and is pre-sized or in INJECT_NAMES.
        local should_inject = _show_depth == 1
            and widget
            and not widget._navbar_injected
            and not widget._navbar_skip_inject
            and widget ~= plugin.ui
            and widget.covers_fullscreen
            and widget.title_bar      -- truthiness check, not ~= nil
            and (widget._navbar_height_reduced or (widget.name and INJECT_NAMES[widget.name]))

        if not should_inject then
            if n_extra > 0 then
                return orig_show(um_self, widget, table.unpack(extra_args))
            else
                return orig_show(um_self, widget)
            end
        end

        widget._navbar_injected = true

        -- Resize widget and its first child to the content area when not pre-sized.
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

        -- Delegate injected-widget title-bar customisation to titlebar.lua.
        -- applyToInjected() is a no-op when "Custom Title Bar" is off.
        Titlebar.applyToInjected(widget)

        local tabs          = Config.loadTabConfig()
        -- Build a set for O(1) membership tests — avoids repeated linear scans
        -- over the same tab list for each widget name check below.
        local tabs_set      = tabsToSet(tabs)
        -- Use the stashed pre-tap action if available (set by onTabTap before
        -- mutating active_action). This ensures _navbar_prev_action holds the
        -- tab that was active *before* the tap, not the tab being opened.
        -- Fall back to active_action for programmatic opens (HS boot, etc.)
        -- where _navbar_prev_action_pending is not set.
        local action_before = plugin._navbar_prev_action_pending or plugin.active_action
        plugin._navbar_prev_action_pending = nil   -- consume immediately
        local effective_action = nil

        -- Activate the tab that corresponds to the widget being shown.
        if widget.name == "collections" and Config.isFavoritesWidget(widget) and tabs_set["favorites"] then
            effective_action = Bottombar.setActiveAndRefreshFM(plugin, "favorites", tabs)
            -- NOTE: no onReturn wrapper here. The native onReturn calls
            -- UIManager:close(self), which our patchUIManagerClose already
            -- intercepts and handles (tab restore + setDirty). Adding a wrapper
            -- that also called _restoreTabInFM caused a double restore and a
            -- double close() emission on every Back button press.
        elseif widget.name == "history" and tabs_set["history"] then
            effective_action = Bottombar.setActiveAndRefreshFM(plugin, "history", tabs)
        elseif widget.name == "homescreen" and tabs_set["homescreen"] then
            effective_action = Bottombar.setActiveAndRefreshFM(plugin, "homescreen", tabs)
        elseif widget.name == "coll_list"
               or (widget.name == "collections" and not Config.isFavoritesWidget(widget)) then
            if tabs_set["collections"] then
                effective_action = Bottombar.setActiveAndRefreshFM(plugin, "collections", tabs)
            end
        end

        -- Hide the native page_return_arrow (Back button) when the widget's
        -- corresponding tab is absent from the navbar. The arrow is only
        -- meaningful as "go back to the collections list" — without the tab
        -- there is no such context to return to, so the button should not show.
        -- We nil onReturn rather than just hiding the arrow so that
        -- _recalculateDimen (called on every page turn) cannot re-show it.
        -- The widget's own _recreate_func restores onReturn on the next open,
        -- so this nil is scoped to this single injection lifetime.
        if widget.name == "collections" and not widget._navbar_onreturn_checked then
            widget._navbar_onreturn_checked = true
            -- Both favorites and non-favorites collections use onReturn to open
            -- coll_list (the collections list). The back button is only meaningful
            -- when the "collections" tab is present — that is the context Back
            -- navigates to, regardless of whether "favorites" is also a tab.
            if not tabs_set["collections"] and widget.onReturn then
                widget.onReturn = nil
                if widget.page_return_arrow then
                    widget.page_return_arrow:hide()
                end
            end
        end

        local display_action = effective_action or action_before
        if not widget._navbar_inner then widget._navbar_inner = widget[1] end

        -- For injected fullscreen widgets that are not pageable (e.g. homescreen,
        -- collections), build the bar without navpager arrows immediately rather
        -- than waiting for the scheduleIn(0) correction. This prevents the brief
        -- flash of arrows that are immediately replaced, and avoids the window
        -- where touch zones have no arrow but the visual still shows one.
        local widget_is_pageable = (type(widget.page_num) == "number")
                or (widget.file_chooser and type(widget.file_chooser.page_num) == "number")
        local navbar_container, wrapped, bar, topbar, bar_idx, topbar_on, topbar_idx =
            UI.wrapWithNavbar(widget._navbar_inner, display_action, tabs,
                not widget_is_pageable)
        UI.applyNavbarState(widget, navbar_container, bar, topbar, bar_idx, topbar_on, topbar_idx, tabs)
        widget._navbar_prev_action = action_before
        widget[1]                  = wrapped
        plugin:_registerTouchZones(widget)
        UI.applyGesturePriorityHandleEvent(widget)

        -- Register top-of-screen tap/swipe zones to open the KOReader main menu,
        -- mirroring FileManagerMenu:initGesListener for all injected pages.
        -- When the topbar is enabled, shrink the zone to exactly the topbar
        -- height (TOTAL_TOP_H) plus the first module gap (MOD_GAP), so that
        -- the touch target matches the visible topbar strip rather than the
        -- larger default KOReader zone.
        if widget.registerTouchZones then
            local DTAP_ZONE_MENU     = G_defaults:readSetting("DTAP_ZONE_MENU")
            local DTAP_ZONE_MENU_EXT = G_defaults:readSetting("DTAP_ZONE_MENU_EXT")
            if DTAP_ZONE_MENU and DTAP_ZONE_MENU_EXT then
                local screen_h    = Screen:getHeight()
                local topbar_on   = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
                local zone_ratio_h
                if topbar_on then
                    local Topbar  = require("sui_topbar")
                    local UI_core = require("sui_core")
                    zone_ratio_h  = (Topbar.TOTAL_TOP_H() + UI_core.MOD_GAP) / screen_h
                else
                    zone_ratio_h  = DTAP_ZONE_MENU.h
                end
                widget:registerTouchZones({
                    {
                        id          = "simpleui_menu_tap",
                        ges         = "tap",
                        screen_zone = {
                            ratio_x = 0, ratio_y = 0,
                            ratio_w = 1, ratio_h = zone_ratio_h,
                        },
                        handler = function(ges)
                            local m = _fmMenu(); if m then return m:onTapShowMenu(ges) end
                        end,
                    },
                    {
                        id          = "simpleui_menu_swipe",
                        ges         = "swipe",
                        screen_zone = {
                            ratio_x = 0, ratio_y = 0,
                            ratio_w = 1, ratio_h = zone_ratio_h,
                        },
                        handler = function(ges)
                            local m = _fmMenu(); if m then return m:onSwipeShowMenu(ges) end
                        end,
                    },
                })
            end
        end

        -- Resize the return button width to match the side margin.
        local rb = widget.return_button
        if rb and rb[1] then rb[1].width = UI.SIDE_M() end

        -- Override _wrapAroundY so pressing Down at the last item enters navbar keyboard focus.
        if require("device"):hasDPad() then
            if rawget(widget, "_wrapAroundY") == nil and type(widget._wrapAroundY) == "function" then
                local _origWrapY = widget._wrapAroundY
                widget._wrapAroundY = function(self_w, dy)
                    if dy > 0 and self_w.page == (self_w.total_pages or 1) then
                        M.enterNavbarKbFocus(function()
                            if self_w.layout and self_w.moveFocusTo then
                                local FocusM = require("ui/widget/focusmanager")
                                self_w:moveFocusTo(1, #self_w.layout, FocusM.FORCED_FOCUS)
                            end
                        end)
                        return true
                    else
                        return _origWrapY(self_w, dy)
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
        UIManager:setDirty(widget[1], "ui")

        -- Navpager: schedule an arrow update for the next event-loop cycle.
        -- Skipped when a coalescence-flagged update is already queued.
        if G_reader_settings:isTrue("navbar_navpager_enabled") and not _navpager_rebuild_pending then
            logger.dbg("simpleui navpager: post-show update scheduled for widget=", tostring(widget.name))
            -- Capture has_prev/has_next NOW (before yielding to the scheduler).
            -- Reading them inside the closure races with a second updatePageInfo
            -- call that may fire during the same tick and update the page position,
            -- causing the arrows to reflect the wrong state. This mirrors the fix
            -- already applied to the updatePageInfo path (line ~1258).
            local has_prev_snap, has_next_snap = Config.getNavpagerState()
            logger.dbg("simpleui navpager: post-show state snapshot =>",
                "has_prev=", tostring(has_prev_snap), "has_next=", tostring(has_next_snap))
            _navpager_rebuild_pending = true
            UIManager:scheduleIn(0, function()
                _navpager_rebuild_pending = false
                if not G_reader_settings:isTrue("navbar_navpager_enabled") then return end
                local fm2 = plugin.ui
                if not (fm2 and fm2._navbar_container) then return end
                local target2 = (widget._navbar_container and widget) or fm2
                if not Bottombar.updateNavpagerArrows(target2, has_prev_snap, has_next_snap) then
                    local tabs2 = Config.loadTabConfig()
                    local mode2 = Config.getNavbarMode()
                    local new_bar = Bottombar.buildBarWidgetWithArrows(
                        plugin.active_action, tabs2, mode2, has_prev_snap, has_next_snap)
                    logger.dbg("simpleui tz: post-show replaceBar target=", tostring(target2.name))
                    Bottombar.replaceBar(target2, new_bar, tabs2)
                end
                UIManager:setDirty(target2, "ui")
            end)
        end

        end) -- end pcall
        _show_depth = _show_depth - 1
        if not ok then
            logger.warn("simpleui: UIManager.show patch error:", tostring(result))
        end

        -- Close the homescreen if a different fullscreen widget just appeared on top.
        -- Runs regardless of injection; also covers native KOReader widgets (ReaderUI).
        -- Excludes the FM itself: the FM opening the HS in onShow must not close it here.
        if _show_depth == 0 and widget and widget.covers_fullscreen
                and widget.name ~= "homescreen"
                and widget ~= plugin.ui
                and not widget._sui_keep_homescreen then
            local stack = UI.getWindowStack()
            for _i, entry in ipairs(stack) do
                local w = entry.widget
                if w and w.name == "homescreen" then
                    -- Mark as intentional so onCloseWidget preserves _current_page.
                    -- This lets the homescreen tab tap restore the same page the
                    -- user was on when they opened a collection or folder module.
                    w._navbar_closing_intentionally = true
                    w._navbar_closing_from_module   = true  -- distinct from a tab-switch
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
-- UIManager.close
-- On close of a SimpleUI-injected widget: restores the active tab and,
-- when "Start with Homescreen" is set, re-opens the homescreen.
-- Non-fullscreen widgets are passed straight through (fast path).
-- ---------------------------------------------------------------------------

function M.patchUIManagerClose(plugin)
    local orig_close = UIManager.close
    plugin._orig_uimanager_close = orig_close

    -- Closes any orphaned non-fullscreen widgets, then shows the homescreen.
    -- Defined once at patch-install time, not re-created on every close() call.
    local function _doShowHS(fm, plugin_ref)
        local HS = package.loaded["sui_homescreen"]
        if not HS or HS._instance then return end
        -- Re-check the stack at execution time: between the scheduleIn(0) call
        -- and this function running, a new fullscreen widget (e.g. coll_list
        -- opened by onReturn after collections closed) may have appeared.
        -- If any fullscreen widget other than the FM is now on the stack,
        -- abort — we are not returning to a bare FM.
        local live_fm2 = package.loaded["apps/filemanager/filemanager"]
        live_fm2 = live_fm2 and live_fm2.instance
        for _i, entry in ipairs(UI.getWindowStack()) do
            local w = entry.widget
            if w and w ~= (live_fm2 or fm) and w.covers_fullscreen then
                return  -- another fullscreen widget is open; don't re-open HS
            end
        end
        local stack    = UI.getWindowStack()
        local to_close = {}
        for _i, entry in ipairs(stack) do
            local w = entry.widget
            if w and w ~= fm and not w.covers_fullscreen then
                to_close[#to_close + 1] = w
            end
        end
        for _, w in ipairs(to_close) do UIManager:close(w) end
        local tabs = Config.loadTabConfig()
        -- Capture the FM's active tab before setting it to "homescreen", so that
        -- closing the HS via back-button restores the correct previous tab rather
        -- than "homescreen" (see same pattern in _hs_pending_after_reader block).
        local prev_action = plugin_ref.active_action
        Bottombar.setActiveAndRefreshFM(plugin_ref, "homescreen", tabs)
        if not plugin_ref._goalTapCallback then plugin_ref:addToMainMenu({}) end
        -- plugin_ref.ui and loadTabConfig() resolved at tap time so FM
        -- reinits or tab config changes while the HS is open are picked up.
        HS.show(
            function(aid) plugin_ref:_navigate(aid, plugin_ref.ui, Config.loadTabConfig(), false) end,
            plugin_ref._goalTapCallback
        )
        -- Correct _navbar_prev_action after injection (same reason as above).
        local hs_inst = HS._instance
        if hs_inst then hs_inst._navbar_prev_action = prev_action end
    end

    UIManager.close = function(um_self, widget, ...)
        -- Fast path: non-fullscreen widgets (dialogs, menus, InfoMessage, etc.)
        -- are the vast majority of close() calls — skip all SimpleUI logic.
        if not (widget and widget.covers_fullscreen) then
            return orig_close(um_self, widget, ...)
        end

        -- Detect if this is the FileManager itself closing.
        -- FM has no name field at class level (name = "filemanager" belongs to its
        -- FileChooser child), so widget.name is nil — we identify it by identity.
        local widget_is_fm = (widget == plugin.ui)
        -- Restore the active tab when a SimpleUI-injected widget closes normally
        -- (not via intentional tab navigation).
        -- _navbar_injected is cleared immediately after processing so that a
        -- second close() on the same widget (e.g. from the native close_callback
        -- running after Menu:onCloseAllMenus already called UIManager:close)
        -- is a no-op — preventing double restoreTabInFM + double setDirty.
        if widget._navbar_injected and not widget._navbar_closing_intentionally then
            widget._navbar_injected = nil   -- consume: makes re-entry a no-op
            -- coll_list sits on top of collections; restoreTabInFM would skip it
            -- because another injected widget is still on the stack. Find the
            -- prev_action on the underlying collections widget instead.
            if widget.name == "coll_list" then
                local FM2 = package.loaded["apps/filemanager/filemanager"]
                local fm = FM2 and FM2.instance
                if fm and fm._navbar_container then
                    local t = Config.loadTabConfig()
                    local restored = nil
                    for _i, entry in ipairs(UI.getWindowStack()) do
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
                -- Pass nil for tabs: restoreTabInFM always loads fresh config.
                plugin:_restoreTabInFM(nil, widget._navbar_prev_action)
            end
        end

        -- When the FM itself is closing, the HomescreenWidget (if open) must be
        -- closed too. FM:onClose → UIManager:close(fm) → returns; no quit() is
        -- ever called explicitly. The event loop exits only when the stack empties.
        -- Without this, the HS remains on the stack and the app never terminates.
        if widget_is_fm then
            local HS = package.loaded["sui_homescreen"]
            local hs_inst = HS and HS._instance
            if hs_inst then
                -- _navbar_closing_intentionally suppresses tab-restore and
                -- re-open logic when our patched close() sees the HS widget.
                hs_inst._navbar_closing_intentionally = true
                orig_close(um_self, hs_inst)  -- bypass our wrapper, no re-entry
                if HS._instance == hs_inst then HS._instance = nil end
            end
        end

        local result = orig_close(um_self, widget, ...)

        -- Re-open the homescreen after any fullscreen widget closes when
        -- "Start with Homescreen" is configured. Applies to both injected and
        -- native widgets (ReaderProgress, CalendarView, etc.).
        -- Exclusions:
        --   • the homescreen itself (would loop)
        --   • the FileManager — FM closing means the app is exiting
        --   • widgets closed by intentional tab navigation
        --   • UIManager already in quit (Restart / explicit quit paths)
        if isStartWithHS()
                and widget.covers_fullscreen
                and widget.name ~= "homescreen"
                and not widget_is_fm
                and not widget._navbar_closing_intentionally
                and not (widget._manager and widget._manager.folder_shortcuts)
                and UIManager._exit_code == nil then
            local FM2 = package.loaded["apps/filemanager/filemanager"]
            local fm  = FM2 and FM2.instance
            local other_open = false
            for _i, entry in ipairs(UI.getWindowStack()) do
                local w = entry.widget
                if w and w ~= fm and w ~= widget then
                    if w.covers_fullscreen then
                        other_open = true; break
                    end
                end
            end
            if not other_open then
                if widget.name == "ReaderUI" then
                    -- Only re-open the HS when the reader is closing to return
                    -- to the FM (tearing_down is nil). When tearing_down=true the
                    -- reader is closing to open a *new* book — do NOT open the HS.
                    if not widget.tearing_down then
                        -- When "Return to Book Folder" is enabled, skip the HS
                        -- re-open entirely — native KOReader behaviour takes over
                        -- and the FM lands on the book's folder directly.
                        local return_to_folder = G_reader_settings:isTrue("navbar_hs_return_to_book_folder")
                        if not return_to_folder then
                            _hs_pending_after_reader = true
                        end
                        -- Refresh the FM's file list lazily so that sort order and
                        -- cover status reflect any changes made during the reading
                        -- session (e.g. marking a book as finished). scheduleIn(0)
                        -- defers the work until after the HS has opened (or the FM
                        -- has appeared), avoiding any delay on the transition.
                        UIManager:scheduleIn(0, function()
                            local FM_ref = package.loaded["apps/filemanager/filemanager"]
                            local fm_ref = FM_ref and FM_ref.instance
                            if fm_ref and fm_ref.file_chooser then
                                fm_ref.file_chooser:refreshPath()
                            end
                        end)
                    end
                else
                    UIManager:scheduleIn(0, function()
                        if UIManager._exit_code ~= nil then return end
                        -- Do NOT open the HS if ReaderUI is still open
                        -- (user closed a sub-menu like font settings, TOC, etc.
                        -- while reading — they are still in the reader).
                        local RUI = package.loaded["apps/reader/readerui"]
                        if RUI and RUI.instance then return end
                        local FM3 = package.loaded["apps/filemanager/filemanager"]
                        local fm2 = FM3 and FM3.instance
                        if fm2 then _doShowHS(fm2, plugin) end
                    end)
                end
            end
        end

        return result
    end
end

-- ---------------------------------------------------------------------------
-- Menu.init
-- Removes the pagination bar from fullscreen FM-style menus when
-- "navbar_pagination_visible" is off.
-- ---------------------------------------------------------------------------

function M.patchMenuInitForPagination(plugin)
    local Menu = require("ui/widget/menu")
    local TARGET_NAMES = {
        filemanager = true, history = true, collections = true, coll_list = true,
    }
    local orig_menu_init = Menu.init
    plugin._orig_menu_init = orig_menu_init

    Menu.init = function(menu_self, ...)
        orig_menu_init(menu_self, ...)

        -- Fix: Menu:onSwipe does not return true, so horizontal swipe events
        -- propagate down to the FM's filemanager_swipe touch zone and advance
        -- two pages instead of one.  Install an instance-level onSwipe that
        -- calls the original and then returns true to consume the event.
        -- Applied to all named target menus (history, collections, coll_list)
        -- and any fullscreen borderless menu that gets navbar-injected.
        local is_target = TARGET_NAMES[menu_self.name]
            or (menu_self.covers_fullscreen
                and menu_self.is_borderless
                and menu_self.title_bar_fm_style)
        if is_target then
            local orig_onSwipe = menu_self.onSwipe  -- may be nil (inherits from Menu)
            menu_self.onSwipe = function(self_m, arg, ges_ev)
                if orig_onSwipe then
                    orig_onSwipe(self_m, arg, ges_ev)
                else
                    Menu.onSwipe(self_m, arg, ges_ev)
                end
                return true  -- consume: prevent propagation to FM's filemanager_swipe
            end
        end

        if G_reader_settings:nilOrTrue("navbar_pagination_visible") then return end
        if not TARGET_NAMES[menu_self.name]
           and not (menu_self.covers_fullscreen
                    and menu_self.is_borderless
                    and menu_self.title_bar_fm_style) then
            return
        end
        -- Remove all children except content_group to eliminate the pagination row.
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
-- Menu.updatePageInfo hook for Navpager
-- When the navpager is active, rebuilds the bottom bar after every page
-- change so the Prev/Next arrows reflect the new enabled/disabled state.
-- This patch is lightweight: it only fires when navbar_navpager_enabled is
-- true AND the menu's page or page_num has actually changed.
-- ---------------------------------------------------------------------------

function M.patchMenuForNavpager(plugin)
    local Menu = require("ui/widget/menu")
    -- Guard: don't double-patch if installAll is called again.
    if Menu._simpleui_navpager_patched then return end
    Menu._simpleui_navpager_patched = true

    logger.dbg("simpleui navpager: patchMenuForNavpager installed")

    -- _getNavbarTarget: returns the topmost fullscreen widget with a navbar,
    -- falling back to fm. Fixes bar updates going to FM even when an injected
    -- widget (Favorites, Collections…) is visible on top.
    local function _getNavbarTarget(fm)
        local UI    = require("sui_core")
        local stack = UI.getWindowStack()
        for i = #stack, 1, -1 do
            local w = stack[i] and stack[i].widget
            if w and w.covers_fullscreen and w._navbar_container then
                return w
            end
        end
        return fm
    end
    M._getNavbarTarget = _getNavbarTarget

    -- _subtitleEnabled: true when the title-bar page subtitle should be shown.
    -- Fires for navpager (original) OR the standalone pagination subtitle setting.
    local function _subtitleEnabled()
        return G_reader_settings:isTrue("navbar_navpager_enabled")
            or G_reader_settings:isTrue("navbar_pagination_show_subtitle")
    end
    M._subtitleEnabled = _subtitleEnabled

    local orig_updatePageInfo = Menu.updatePageInfo
    plugin._orig_menu_update_page_info = orig_updatePageInfo

    -- ---------------------------------------------------------------------------
    -- Shared helper: set "Page X of Y" in a widget's title_bar subtitle.
    -- Called from both the updatePageInfo hook (History/Collections/any Menu)
    -- and from the FM updateTitleBarPath hook below.
    -- Only runs when the navpager is enabled; no-ops otherwise.
    -- ---------------------------------------------------------------------------
    -- Single source of truth for the FM title-bar subtitle.
    -- _fm_path_base: the raw path string last written by updateTitleBarPath
    -- (empty string at home).  Always set before calling _setPageSubtitle.
    local _fm_path_base = ""

    -- _setSubtitleUnified: the ONE place that calls tb:setSubTitle in the FM.
    -- Combines path (if any) with page indicator (if enabled and multi-page).
    local function _setSubtitleUnified(tb, path_base, page, page_num)
        if not tb or not tb.subtitle_widget then return end
        local parts = {}
        if path_base and path_base ~= "" then
            parts[#parts + 1] = path_base
        end
        if _subtitleEnabled() and page_num and page_num > 1 then
            local T = require("ffi/util").template
            parts[#parts + 1] = T(_("Page %1 of %2"), page, page_num)
        end
        tb:setSubTitle(table.concat(parts, "  ·  "), true)
    end

    local function _setPageSubtitle(tb, page, page_num)
        if not tb or not tb.subtitle_widget then return end
        _setSubtitleUnified(tb, _fm_path_base, page, page_num)
    end
    -- Expose so the FM hook (defined below) can reuse it.
    M._setPageSubtitle = _setPageSubtitle

    -- Setter so other modules (e.g. sui_foldercovers) can update the path
    -- base when entering a virtual folder that never calls updateTitleBarPath.
    function M.setFMPathBase(text, fm_self)
        _fm_path_base = text or ""
        -- Immediately repaint the unified subtitle if we have a FM reference.
        if fm_self then
            local tb3 = fm_self.title_bar
            local fc2 = fm_self.file_chooser
            if tb3 and tb3.subtitle_widget then
                local pg     = fc2 and (fc2.page     or 0) or 0
                local pg_num = fc2 and (fc2.page_num or 0) or 0
                _setSubtitleUnified(tb3, _fm_path_base, pg, pg_num)
            end
        end
    end

    Menu.updatePageInfo = function(menu_self, select_number)
        orig_updatePageInfo(menu_self, select_number)

        -- Fix: when the plugin has resized a fullscreen menu widget to
        -- getContentHeight(), the widget's dimen no longer covers the native
        -- pagination bar (page_info group), which sits just below the content
        -- area. CoverMenu:updateItems (used by CoverBrowser in History /
        -- Collections mosaic mode) calls setDirty with the widget's dimen,
        -- so the bar never gets repainted after a page turn — chevrons stay
        -- frozen in their initial enabled/disabled state.
        -- Forcing a setDirty on the page_info widget itself fixes this.
        if menu_self.page_info and menu_self._navbar_injected then
            local UIManager_fix = require("ui/uimanager")
            UIManager_fix:setDirty(menu_self.show_parent or menu_self, "ui",
                menu_self.page_info.dimen)
        end

        if not _subtitleEnabled() then return end

        local captured_page     = menu_self.page     or 0
        local captured_page_num = menu_self.page_num or 0

        logger.dbg("simpleui navpager: updatePageInfo fired name=",
            tostring(menu_self.name),
            "page=", tostring(captured_page),
            "page_num=", tostring(captured_page_num))

        -- Update the subtitle immediately (synchronous).
        _setPageSubtitle(menu_self.title_bar, captured_page, captured_page_num)

        -- Coalesce: skip if an update is already queued for this tick.
        -- But always update captured state so the latest page is used.
        if _navpager_rebuild_pending then return end
        _navpager_rebuild_pending = true

        -- Derive has_prev/has_next from the captured state now, not inside the
        -- closure. getNavpagerState() re-reads the widget after a tick and can
        -- race with a second updatePageInfo call during switchItemTable init,
        -- causing the arrows to reflect the wrong page position.
        local has_prev = captured_page > 1
        local has_next = captured_page < captured_page_num

        local UIManager = require("ui/uimanager")
        UIManager:scheduleIn(0, function()
            _navpager_rebuild_pending = false
            if not G_reader_settings:isTrue("navbar_navpager_enabled") then return end
            local Bottombar = require("sui_bottombar")
            local fm        = plugin.ui
            if not (fm and fm._navbar_container) then return end

            logger.dbg("simpleui navpager: scheduleIn updating arrows",
                "has_prev=", tostring(has_prev), "has_next=", tostring(has_next))

            local target = M._getNavbarTarget(fm)
            if not Bottombar.updateNavpagerArrows(target, has_prev, has_next) then
                local Config  = require("sui_config")
                local tabs    = Config.loadTabConfig()
                local mode    = Config.getNavbarMode()
                local new_bar = Bottombar.buildBarWidgetWithArrows(
                    plugin.active_action, tabs, mode, has_prev, has_next)
                logger.dbg("simpleui tz: updatePageInfo replaceBar target=", tostring(target.name))
                Bottombar.replaceBar(target, new_bar, tabs)
            end
            UIManager:setDirty(target, "ui")
        end)
    end

    -- ---------------------------------------------------------------------------
    -- FM hook: append "— Page X of Y" to the path subtitle in the library view.
    -- The FM uses updateTitleBarPath (aliased as onPathChanged) rather than
    -- updatePageInfo, so we patch it separately on the FileManager class.
    -- ---------------------------------------------------------------------------
    local FileManager = package.loaded["apps/filemanager/filemanager"]
        or require("apps/filemanager/filemanager")

    local orig_updateTitleBarPath = FileManager.updateTitleBarPath
    plugin._orig_fm_updateTitleBarPath = orig_updateTitleBarPath

    FileManager.updateTitleBarPath = function(fm_self, path, force_home)
        local ffiUtil = require("ffi/util")
        local function _norm(p)
            if not p then return "" end
            p = p:gsub("/$", "")
            local ok, rp = pcall(ffiUtil.realpath, p)
            if ok and rp then p = rp:gsub("/$", "") end
            return p
        end
        local fc_path    = fm_self.file_chooser and fm_self.file_chooser.path or nil
        local home_dir   = _norm(G_reader_settings:readSetting("home_dir"))
        local clean_path = _norm(path or fc_path)
        local at_home    = force_home or (home_dir ~= "" and clean_path == home_dir)

        -- Determine whether the back button should be hidden at this path.
        -- Mirrors the logic in genItemTable (sui_titlebar.lua) so that
        -- programmatic navigations (Library button, boot onShow) that call
        -- updateTitleBarPath directly also hide the button correctly.
        --
        -- Desired behaviour:
        --   - Hide at filesystem root.
        --   - Hide at the library home folder only when "Lock Home Folder" is enabled.
        local at_root = (clean_path == "/")
        if not at_root then
            local fc_cur = fm_self.file_chooser
            if fc_cur and fc_cur._simpleui_has_go_up ~= nil then
                at_root = not fc_cur._simpleui_has_go_up
            end
        end
        -- lock_home_folder: treat the home path as root.
        if not at_root and G_reader_settings:isTrue("lock_home_folder") and at_home then
            at_root = true
        end

        -- Force the back button off-screen when at root (or locked-at-home).
        -- genItemTable handles the show case (is_sub=true) with the correct
        -- icon and callback; we only force-hide here for navigations that
        -- genItemTable may miss (Library button tap, suppress-flagged boot).
        local tb = fm_self.title_bar
        if tb and tb.left_button and fm_self._titlebar_patched then
            if at_root then
                local Screen = require("device").screen
                tb.left_button.overlap_offset = { Screen:getWidth() + 100, 0 }
                tb.left_button.callback       = function() end
                tb.left_button.hold_callback  = function() end
                local sb = fm_self._titlebar_search_btn
                local x  = fm_self._simpleui_search_x_compact
                if sb and x and sb.overlap_offset then
                    sb.overlap_offset = { x, 0 }
                end
            else
                local sb = fm_self._titlebar_search_btn
                local x  = fm_self._simpleui_search_x
                if sb and x and sb.overlap_offset then
                    sb.overlap_offset = { x, 0 }
                end
            end
            local UIManager = require("ui/uimanager")
            UIManager:setDirty(tb.show_parent or fm_self, "ui", tb.dimen)
        end

        -- Determine the path text for the subtitle.
        -- At home we want an empty base; in a subfolder we call the original
        -- (which writes the path into the subtitle) then immediately read it
        -- back so _setSubtitleUnified can combine path + page in one write.
        if at_home then
            _fm_path_base = ""
        else
            -- Let the original write the path first so we can read it back.
            orig_updateTitleBarPath(fm_self, path)
            local tb2 = fm_self.title_bar
            _fm_path_base = (tb2 and tb2.subtitle_widget and tb2.subtitle_widget.text) or ""
        end

        -- Now write the unified subtitle (path + page if enabled).
        local fc2 = fm_self.file_chooser
        local tb3 = fm_self.title_bar
        if tb3 and tb3.subtitle_widget then
            local pg     = fc2 and (fc2.page     or 0) or 0
            local pg_num = fc2 and (fc2.page_num or 0) or 0
            _setSubtitleUnified(tb3, _fm_path_base, pg, pg_num)
        end
    end
end

-- ---------------------------------------------------------------------------
-- installAll / teardownAll
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Resume hook
-- Opens the Homescreen after the device wakes from suspend, but only when:
--   • "Start with Homescreen" is active (isStartWithHS())
--   • the Homescreen tab exists in the tab config
--   • no reader session is active (RUI.instance is nil)
--   • the Homescreen is not already on screen (HS._instance is nil)
--   • UIManager is not in quit/exit state
--
-- Called from SimpleUIPlugin:onResume() in main.lua.
-- ---------------------------------------------------------------------------

-- Reuses the already-installed _doShowHS closure from patchUIManagerClose
-- by looking up the live FM instance the same way that function does.
-- scheduleIn(0) defers until the event loop has finished processing the
-- Resume event chain (screensaver dismiss, topbar refresh, etc.) so that
-- UIManager:show(HS) lands on a fully-settled stack.
-- ---------------------------------------------------------------------------
function M.showHSAfterResume(plugin)
    -- Guard 1: setting must be "Start with Homescreen".
    if not isStartWithHS() then return end

    -- Guard 2: reader must not be active.
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance then return end

    -- Guard 3: homescreen tab must be in the tab config.
    local tabs = Config.loadTabConfig()
    if not tabInTabs("homescreen", tabs) then return end

    -- Guard 4: HS must not already be open.
    local HS = package.loaded["sui_homescreen"]
    if HS and HS._instance then return end

    -- Guard 5: UIManager must not be shutting down.
    if UIManager._exit_code ~= nil then return end

    UIManager:scheduleIn(0, function()
        -- Re-check guards at execution time — state may have changed while
        -- the 0-second schedule was queued (e.g. user opened a book).
        if UIManager._exit_code ~= nil then return end
        local RUI2 = package.loaded["apps/reader/readerui"]
        if RUI2 and RUI2.instance then return end
        local HS2 = package.loaded["sui_homescreen"]
        if HS2 and HS2._instance then return end

        local FM = package.loaded["apps/filemanager/filemanager"]
        local fm = FM and FM.instance
        if not fm then return end

        -- Lazily load Homescreen if not yet in package.loaded.
        if not HS2 then
            local ok, m = pcall(require, "sui_homescreen")
            HS2 = ok and m
        end
        if not HS2 then return end

        local t = Config.loadTabConfig()
        local prev_action = plugin.active_action
        Bottombar.setActiveAndRefreshFM(plugin, "homescreen", t)
        if not plugin._goalTapCallback then plugin:addToMainMenu({}) end
        -- Always start at page 1 after a resume — restoring the last page
        -- would be disorienting after the device wakes from standby.
        HS2._current_page = 1
        HS2.show(
            function(aid) plugin:_navigate(aid, plugin.ui, Config.loadTabConfig(), false) end,
            plugin._goalTapCallback
        )
        -- Preserve the previous tab so back-button from HS returns correctly.
        local hs_inst = HS2._instance
        if hs_inst then hs_inst._navbar_prev_action = prev_action end
    end)
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
    -- Folder covers: only install when the feature is enabled.
    -- Installing unconditionally wraps MosaicMenuItem.update even when FC is
    -- disabled, hiding the BookInfoManager upvalue from subsequent
    -- userpatch.getUpValue() calls made by third-party user-patches (such as
    -- 2-browser-folder-cover.lua).  When FC is disabled we leave
    -- MosaicMenuItem.update untouched so those patches work correctly.
    -- FC.install() is also called from sui_menu.lua when the toggle is turned on.
    local ok_fc, FC = pcall(require, "sui_foldercovers")
    if ok_fc and FC and FC.isEnabled() then
        pcall(FC.install)
    end
end

function M.teardownAll(plugin)
    -- Restore UIManager patches first (highest call frequency).
    if plugin._orig_uimanager_show then
        UIManager.show  = plugin._orig_uimanager_show
        plugin._orig_uimanager_show = nil
    end
    if plugin._orig_uimanager_close then
        UIManager.close = plugin._orig_uimanager_close
        plugin._orig_uimanager_close = nil
    end
    -- Restore class patches via package.loaded (modules already loaded; no pcall needed).
    local BookList = package.loaded["ui/widget/booklist"]
    if BookList and plugin._orig_booklist_new then
        BookList.new = plugin._orig_booklist_new; plugin._orig_booklist_new = nil
    end
    local Menu = package.loaded["ui/widget/menu"]
    if Menu then
        if plugin._orig_menu_new  then Menu.new  = plugin._orig_menu_new;  plugin._orig_menu_new  = nil end
        if plugin._orig_menu_init then Menu.init = plugin._orig_menu_init; plugin._orig_menu_init = nil end
        if plugin._orig_menu_update_page_info then
            Menu.updatePageInfo              = plugin._orig_menu_update_page_info
            plugin._orig_menu_update_page_info = nil
        end
        Menu._simpleui_navpager_patched = nil
    end
    local FileManager2 = package.loaded["apps/filemanager/filemanager"]
    if FileManager2 and plugin._orig_fm_updateTitleBarPath then
        FileManager2.updateTitleBarPath = plugin._orig_fm_updateTitleBarPath
        plugin._orig_fm_updateTitleBarPath = nil
    end
    local FMColl = package.loaded["apps/filemanager/filemanagercollection"]
    if FMColl and plugin._orig_fmcoll_show then
        FMColl.onShowCollList = plugin._orig_fmcoll_show; plugin._orig_fmcoll_show = nil
    end
    local RC = package.loaded["readcollection"]
    if RC then
        if plugin._orig_rc_remove then RC.removeCollection = plugin._orig_rc_remove; plugin._orig_rc_remove = nil end
        if plugin._orig_rc_rename then RC.renameCollection = plugin._orig_rc_rename; plugin._orig_rc_rename = nil end
    end
    local SortWidget = package.loaded["ui/widget/sortwidget"]
    if SortWidget and plugin._orig_sortwidget_new then
        SortWidget.new = plugin._orig_sortwidget_new; plugin._orig_sortwidget_new = nil
    end
    local PathChooser = package.loaded["ui/widget/pathchooser"]
    if PathChooser and plugin._orig_pathchooser_new then
        PathChooser.new = plugin._orig_pathchooser_new; plugin._orig_pathchooser_new = nil
    end
    local FileChooser = package.loaded["ui/widget/filechooser"]
    if FileChooser and plugin._orig_fc_init then
        FileChooser.init            = plugin._orig_fc_init
        FileChooser._navbar_patched = nil
        plugin._orig_fc_init        = nil
    end
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    if FileManager and FileManager._simpleui_gesture_priority_applied then
        UI.unapplyGesturePriorityHandleEvent(FileManager)
    end
    if FileManager and plugin._orig_initGesListener then
        FileManager.initGesListener        = plugin._orig_initGesListener
        plugin._orig_initGesListener       = nil
        FileManager._simpleui_ges_patched  = nil
    end

    if FileManager and plugin._orig_fm_setup then
        FileManager.setupLayout = plugin._orig_fm_setup; plugin._orig_fm_setup = nil
    end
    local FileManagerMenu = package.loaded["apps/filemanager/filemanagermenu"]
    if FileManagerMenu and FileManagerMenu._simpleui_startwith_patched then
        FileManagerMenu.getStartWithMenuTable       = FileManagerMenu._simpleui_startwith_orig
        FileManagerMenu._simpleui_startwith_orig    = nil
        FileManagerMenu._simpleui_startwith_patched = nil
    end
    local Dispatcher2 = package.loaded["dispatcher"]
    if Dispatcher2 and Dispatcher2._simpleui_execute_patched then
        Dispatcher2.execute                    = Dispatcher2._simpleui_execute_orig
        Dispatcher2._simpleui_execute_orig     = nil
        Dispatcher2._simpleui_execute_patched  = nil
    end
    -- Reset all module-level state so a re-enable cycle starts clean.
    _hs_boot_done              = false
    _hs_pending_after_reader   = false
    _start_with_hs             = nil
    _navpager_rebuild_pending  = false
    -- Close any active navbar keyboard focus capture widget.
    if _navbar_kb_capture then
        UIManager:close(_navbar_kb_capture)
        _navbar_kb_capture    = nil
    end
    _navbar_kb_idx       = 1
    _navbar_kb_return_fn = nil
    _enterNavbarKbFocus_fn = nil
    Config.reset()
    local Registry = package.loaded["desktop_modules/moduleregistry"]
    if Registry then Registry.invalidate() end
    local FC = package.loaded["sui_foldercovers"]
    if FC then
        pcall(FC.uninstall)
    end
end

-- ---------------------------------------------------------------------------
-- Patch Dispatcher:execute so that when the homescreen is active, events are
-- delivered via broadcastEvent instead of sendEvent.
--
-- WHY: UIManager:sendEvent delivers to the top widget only. When a QuickMenu
-- button is tapped, it calls UIManager:close(quickmenu) first — making
-- HomescreenWidget the top widget — and then Dispatcher:execute fires events
-- like ShowColl / ShowCollList. HomescreenWidget has no handlers for these,
-- so they are silently dropped. FileManager's collection/history modules only
-- receive events via broadcastEvent in this context.
-- ---------------------------------------------------------------------------
do
    local ok, Dispatcher = pcall(require, "dispatcher")
    if ok and Dispatcher and not Dispatcher._simpleui_execute_patched then
        local orig_execute = Dispatcher.execute
        Dispatcher._simpleui_execute_orig = orig_execute
        Dispatcher.execute = function(self, settings, exec_props)
            local HS = package.loaded["sui_homescreen"]
            if not (HS and HS._instance) then
                return orig_execute(self, settings, exec_props)
            end
            -- Homescreen is active: sink HS to the bottom of the window stack so
            -- that FM and its plugins sit on top and receive sendEvent normally.
            -- This mirrors what _executeInPlace does for bottombar QA actions, and
            -- fixes overlays (e.g. Reading Statistics: Show Progress) that were
            -- invisible when triggered via a QuickMenu because the old
            -- sendEvent→broadcastEvent redirect caused delivery ordering issues.
            local UIManager_ref = require("ui/uimanager")
            local stack   = UIManager_ref._window_stack
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
            -- Restore HS to its original position regardless of success/failure.
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
                logger.warn("simpleui: Dispatcher:execute (hs sink):", err)
            end
        end
        Dispatcher._simpleui_execute_patched = true
        logger.dbg("simpleui: Dispatcher:execute patched for homescreen stack-sink")
    end
end

return M