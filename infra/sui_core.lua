-- ui.lua — Simple UI
-- Shared layout infrastructure: side margin, content dimensions,
-- OverlapGroup composition (wrapWithNavbar), topbar replacement
-- and access to the UIManager window stack.

-- Widget classes — required lazily on first use (wrapWithNavbar and friends).
-- Blitbuffer, Device, Screen and logger are kept eager because they are used
-- at module level to compute the shared layout constants below.
local _FrameContainer, _OverlapGroup, _LineWidget, _Geom
local function FrameContainer() _FrameContainer = _FrameContainer or require("ui/widget/container/framecontainer"); return _FrameContainer end
local function OverlapGroup()   _OverlapGroup   = _OverlapGroup   or require("ui/widget/overlapgroup");             return _OverlapGroup   end
local function LineWidget()     _LineWidget     = _LineWidget     or require("ui/widget/linewidget");               return _LineWidget     end
local function Geom()           _Geom           = _Geom           or require("ui/geometry");                        return _Geom           end
local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Screen         = Device.screen
local logger         = require("logger")
local SUISettings = require("infra/sui_store")
local SUIStyle    = require("features/sui_style")

-- Lazy references to sibling modules — resolved on first use to avoid
-- circular-require issues at load time, but stored as upvalues so that
-- the hot paths (getContentHeight, getContentTop, wrapWithNavbar,
-- applyNavbarState) never pay a require() lookup after the first call.
local _Bottombar, _Topbar
local function _BB() _Bottombar = _Bottombar or require("screens/sui_bottombar"); return _Bottombar end
local function _TB() _Topbar    = _Topbar    or require("screens/sui_topbar");    return _Topbar    end

local M   = {}
local _dim = {}

-- ---------------------------------------------------------------------------
-- Live plugin resolution + the standard Quick Action / Goal tap callbacks.
--
-- This is the ONE authoritative implementation of "find the current
-- SimpleUIPlugin instance and build its standard on_qa_tap/on_goal_tap
-- callbacks" — used by both the built-in Homescreen (via
-- infra/sui_patches.lua's _showHSCold/_makeQaTap, which now delegate here)
-- and any Custom Screen (via engines/sui_screen_engine.lua's
-- ScreenEngine.showCustomScreen). Before this, showCustomScreen passed
-- `nil, nil` for these callbacks — Quick Actions/Action List modules placed
-- on a Custom Screen tapped silently (ctx.on_qa_tap's `if self_ref._on_qa_tap
-- then` guard was never true), while the exact same module on the
-- Homescreen worked, because only the Homescreen's _showHSCold ever
-- supplied real callbacks. Living in sui_core.lua (a base module with no
-- reverse dependency on either sui_patches.lua or sui_screen_engine.lua)
-- lets both require it without a circular-require risk.
--
-- Deliberately resolves the plugin instance and Config LAZILY, inside the
-- returned closures, rather than capturing `plugin_ref` once at creation
-- time: a Custom Screen instance can outlive the FileManager/ReaderUI
-- object that was live when it was opened (e.g. the reader closes and a
-- fresh FileManager+plugin instance is created while the Custom Screen is
-- still on screen), and unlike HS._instance, Custom Screen instances have
-- no equivalent "refresh _on_qa_tap after FM recreation" call sites
-- scattered through sui_patches.lua. Resolving fresh on every tap sidesteps
-- that staleness class entirely instead of requiring parity plumbing at
-- every lifecycle event HS currently hooks.
-- ---------------------------------------------------------------------------

--- Resolve the currently-live SimpleUIPlugin instance, from either the
--- active FileManager (fm._simpleui_plugin, set in sui_patches.lua's
--- patchFileManagerClass) or the active ReaderUI (readerui.simpleui, set at
--- plugin registration) — whichever is currently on screen.
function M.getLivePlugin()
    local FM = package.loaded["apps/filemanager/filemanager"]
    local fm = FM and FM.instance
    if fm and fm._simpleui_plugin then return fm._simpleui_plugin end
    local RUI = package.loaded["apps/reader/readerui"]
    local rui = RUI and RUI.instance
    return rui and rui.simpleui
end

--- Resolve whichever screen — the built-in Homescreen or a Custom Screen —
--- is currently open/topmost, generically. Returns id, instance (both nil
--- if none is open).
---
--- Single authority for "is some screen open right now": both
--- screens/sui_bottombar.lua's M.navigate() (deciding whether to close the
--- open screen before an FM-opening Quick Action) and
--- features/sui_quickactions.lua's _showBookmarkBrowserSourceDialog() (deciding
--- whether to keep the open screen alive/restored around an async dialog)
--- need exactly this lookup. Before this helper existed both call sites
--- duplicated the same ScreenEngine.liveScreenIds()[1] + getInstance() pair
--- independently — centralised here so the "which screen is open" logic
--- only has one place to get right (and one place to extend, e.g. if this
--- ever needs to consider more than the first live id).
---
--- At most one screen is normally live/topmost at a time, so the first id
--- from ScreenEngine.liveScreenIds() is the one currently on top.
function M.getOpenScreen()
    local ok, ScreenEngine = pcall(require, "engines/sui_screen_engine")
    if not ok or not ScreenEngine then return nil, nil end
    local id = ScreenEngine.liveScreenIds()[1]
    if not id then return nil, nil end
    return id, ScreenEngine.getInstance(id)
end

--- Standard Quick-Action-tap callback: resolves the live plugin at call
--- time and routes through its normal navigation entry point. Safe to hand
--- to any screen (Homescreen or Custom Screen) as its on_qa_tap.
function M.makeQaTap()
    return function(aid)
        local plugin = M.getLivePlugin()
        if not plugin then return end
        local Config = require("infra/sui_config")
        plugin:_navigate(aid, plugin.ui, Config.loadTabConfig(), false)
    end
end

--- Ensures plugin._goalTapCallback exists (addToMainMenu populates it
--- lazily; idempotent), then returns a callback that resolves the live
--- plugin at call time and forwards to it. Safe to hand to any screen as
--- its on_goal_tap.
function M.makeGoalTap()
    return function(...)
        local plugin = M.getLivePlugin()
        if not plugin then return end
        if not plugin._goalTapCallback then
            plugin:addToMainMenu({})
        end
        if plugin._goalTapCallback then
            plugin._goalTapCallback(...)
        end
    end
end

-- UNCONFIRMED HYPOTHESIS (bug #2 — duplicate navbar after rapid-fire rotations):
-- Counter incremented on every genuine SetRotationMode event (mode ~=
-- current_mode) received by ScreenWidget:onSetRotationMode. Serves as a
-- shared source of truth between sui_homescreen.lua and sui_patches.lua
-- (both require this module, so they share the same M table) so that the
-- setupLayout guard in sui_patches.lua knows a rotation happened
-- since the navbar was last wrapped, even when the W x H comparison
-- isn't enough (rapid-fire rotations / repeated dimensions).
-- Reversible: removing this block and the calls to bumpRotationGeneration /
-- getRotationGeneration doesn't affect anything else in the module.
local _rotation_generation = 0

-- ---------------------------------------------------------------------------
-- Shared layout constants — single source of truth for all desktop modules.
--
-- Every module_*.lua and sui_homescreen.lua reads these instead of declaring
-- their own identical local copies. Values are computed once at load time
-- via scaleBySize and stored as plain numbers — zero overhead at render time.
--
-- LABEL_PAD_TOP    : space above a section label text              (= PAD2)
-- LABEL_PAD_BOT    : space below a section label text, above content
-- LABEL_TEXT_H     : estimated height of the section label TextWidget
-- LABEL_H          : total vertical space consumed by a section label
--                    (LABEL_PAD_TOP + LABEL_PAD_BOT + LABEL_TEXT_H)
-- MOD_GAP          : vertical gap inserted by _buildContent after each module
-- PAD              : standard horizontal/vertical padding inside modules
-- PAD2             : smaller padding (half of PAD)
-- SIDE_PAD()       : left/right inset of the homescreen content area
--                    (derived from SIDE_M, defined below)
-- ---------------------------------------------------------------------------

M.PAD           = Screen:scaleBySize(14)
M.PAD2          = Screen:scaleBySize(8)
M.MOD_GAP       = Screen:scaleBySize(23)   -- includes former LABEL_PAD_TOP (8px)
M.LABEL_PAD_TOP = 0                         -- absorbed into MOD_GAP
M.LABEL_PAD_BOT = M.PAD2                    -- padding_bottom of sectionLabel (was 4px, now 8px)
local _ok_ss, _SUIStyle_core = pcall(require, "features/sui_style")
local _body_fs = (_ok_ss and _SUIStyle_core and _SUIStyle_core.FS_BODY) or 18
M.LABEL_TEXT_H  = Screen:scaleBySize(_body_fs)  -- TextWidget height for FS_BODY (18pt)
M.LABEL_H       = M.LABEL_PAD_TOP + M.LABEL_PAD_BOT + M.LABEL_TEXT_H

-- Shared secondary text colour used across all desktop modules.
-- Kept as a pass-through of the shared style catalog (features/sui_style.lua
-- loads before this module and doesn't depend on it, so no circular-require
-- concern) rather than pointing every consumer at SUIStyle.COLOR directly,
-- since ~10 modules already import this as UI.CLR_TEXT_SUB.
M.CLR_TEXT_SUB  = SUIStyle.COLOR.text_primary

-- ---------------------------------------------------------------------------
-- Landscape reduction factor — single source of truth.
--
-- The home screen renders as a two-column spread in landscape (like an open
-- book), so portrait-sized content must shrink to fit one spread column.
-- Any other SimpleUI surface that wants the same "shrink to fit" behaviour
-- in landscape (e.g. SUIWindow) reuses this exact factor rather than
-- deriving its own, so the reduction always matches the home screen's.
--
-- getSpreadColWidth()/getPortraitInnerW() are also called directly by
-- ScreenWidget:_updatePage() with its own inner_w, so both this file and
-- _updatePage derive the column width from the same formula.
-- ---------------------------------------------------------------------------

--- Returns true when the screen is wider than it is tall.
function M.isLandscape()
    return Screen:getWidth() > Screen:getHeight()
end

--- Returns the screen's width/height as they would be in portrait mode,
--- regardless of the device's current rotation. In portrait this is simply
--- Screen:getWidth()/getHeight(); in landscape the two are swapped back to
--- their notional portrait values.
---
--- Anything that wants to derive a size from "the portrait screen" and then
--- apply getLandscapeFactor() on top (SUIWindow's default/explicit width and
--- height being the main case) must start from these values instead of the
--- raw, currently-rotated Screen:getWidth()/getHeight() — otherwise the
--- short/long axes get swapped and the landscape shrink is applied on top of
--- an already-rotated dimension, compounding the reduction on one axis.
function M.getPortraitDims()
    local w, h = Screen:getWidth(), Screen:getHeight()
    if w > h then
        return h, w
    end
    return w, h
end

--- Usable width the screen would have in portrait mode, regardless of
--- current rotation.
function M.getPortraitInnerW()
    local portrait_w = M.getPortraitDims()
    return M.getInnerW(portrait_w)
end

--- Width of one column in the two-column landscape spread. `inner_w`
--- defaults to a live read; pass it explicitly when the caller already
--- has its own authoritative value.
function M.getSpreadColWidth(inner_w)
    inner_w = inner_w or M.getInnerW()
    return math.floor((inner_w - M.PAD) / 2)
end

--- Returns the landscape reduction factor (1 in portrait — no reduction).
function M.getLandscapeFactor()
    if not M.isLandscape() then return 1 end
    local portrait_inner_w = M.getPortraitInnerW()
    if portrait_inner_w <= 0 then return 1 end
    return M.getSpreadColWidth() / portrait_inner_w
end

--- Shared landscape-aware size multiplier for SUIWindow content built outside
--- sui_window.lua itself (e.g. sui_stats_windows.lua). Mirrors the SZ() helper
--- in sui_window.lua, but reads the factor live from getLandscapeFactor()
--- instead of a value frozen at window-construction time — simpler for
--- consumers that don't track a per-window scale, and equivalent in practice
--- since orientation doesn't change mid-build. sui_window.lua keeps its own
--- frozen _sui_scale/SZ; this is for every other SUIWindow-content file.
function M.SZ(n)
    return math.floor(n * M.getLandscapeFactor())
end

-- ---------------------------------------------------------------------------
-- Shared menu-item resolver
-- Converts KOReader-style menu item tables (with checked_func / enabled_func /
-- sub_item_table_func) into flat, statically-resolved tables suitable for use
-- in our custom Menu widgets (P2 — eliminates duplication in bottombar/topbar).
-- ---------------------------------------------------------------------------

function M.resolveMenuItems(items)
    local out = {}
    for _, item in ipairs(items) do
        local r = {}
        for k, v in pairs(item) do r[k] = v end
        if type(item.sub_item_table_func) == "function" then
            -- Lazy resolution: keep the original func and resolve only when
            -- the user actually navigates into this sub-menu. This avoids
            -- building the entire menu tree upfront — critical on e-readers
            -- where onMenuSelect is the only code path that reaches sub-menus.
            -- The resolved table is stored back so repeated opens are free.
            local orig_fn = item.sub_item_table_func
            r.sub_item_table_func = nil
            r._sui_lazy_fn = orig_fn
            r.sub_item_table = nil   -- will be populated on first navigation
        elseif type(item.sub_item_table) == "table" then
            -- Statically-provided sub-tables are resolved eagerly (they are
            -- already in memory, so there is nothing to defer).
            r.sub_item_table = M.resolveMenuItems(item.sub_item_table)
        end
        if type(item.checked_func) == "function" then
            local cf = item.checked_func
            r.mandatory_func = function() return cf() and "\u{2713}" or "" end
            r.checked_func   = nil
        end
        if type(item.enabled_func) == "function" then
            r.dim        = not item.enabled_func()
            r.enabled_func = nil
        end
        out[#out + 1] = r
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Screen edge margin
-- ---------------------------------------------------------------------------

local function _cached(key, fn)
    if not _dim[key] then _dim[key] = fn() end
    return _dim[key]
end

-- Horizontal margin of every full-width surface: top bar, title bar, bottom
-- bar, library pages, home screen and custom screens. It is a layout constant
-- of its own and does not depend on which bars are enabled.
function M.SIDE_M()
    return _cached("side_m", function() return Screen:scaleBySize(24) - 3 end)
end

-- Left/right inset of the homescreen content area. Modules add PAD of their
-- own on top, so the content edge lands on SIDE_M.
function M.SIDE_PAD()
    return _cached("side_pad", function() return M.SIDE_M() - M.PAD end)
end

-- Width between the side margins of a screen `screen_w` wide (default: live).
function M.getUsableW(screen_w)
    return (screen_w or Screen:getWidth()) - M.SIDE_M() * 2
end

-- Width of the homescreen content area of a screen `screen_w` wide
-- (default: live).
function M.getInnerW(screen_w)
    return (screen_w or Screen:getWidth()) - M.SIDE_PAD() * 2
end

-- ---------------------------------------------------------------------------
-- Invalidates all dimension caches across bottombar and topbar
-- ---------------------------------------------------------------------------

function M.invalidateDimCache()
    _dim = {}
    local bb = package.loaded["screens/sui_bottombar"]
    if bb and bb.invalidateDimCache then bb.invalidateDimCache() end
    local tb = package.loaded["screens/sui_topbar"]
    if tb and tb.invalidateDimCache then tb.invalidateDimCache() end
    -- Clear VerticalSpan pools so stale px values (computed before resize)
    -- are not reused after scaleBySize produces different numbers. Every
    -- live screen (built-in Homescreen or a Custom Screen) has its own
    -- instance-level pool, so clear whichever screen(s) are actually open
    -- rather than assuming the Homescreen.
    local hs = package.loaded["screens/sui_homescreen"]
    if hs then
        for _, id in ipairs(hs.liveScreenIds()) do
            local inst = hs.getInstance(id)
            if inst and inst._vspan_pool then
                inst._vspan_pool = {}
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- UNCONFIRMED HYPOTHESIS (bug #2) — shared rotation generation.
-- See the comment next to the _rotation_generation declaration above.
-- ---------------------------------------------------------------------------

function M.bumpRotationGeneration()
    _rotation_generation = _rotation_generation + 1
    return _rotation_generation
end

function M.getRotationGeneration()
    return _rotation_generation
end

-- ---------------------------------------------------------------------------
-- Pending rotation reopen
--
-- A screen (the built-in Homescreen or a Custom Screen) closes itself on a
-- cross-family rotation and registers itself here instead of reopening
-- immediately, so that FileManager gets a chance to run its own rotation
-- handling first (see ScreenWidget:onSetRotationMode in
-- engines/sui_screen_engine.lua). FileManager's patched setupLayout
-- (infra/sui_patches.lua) drains this list once it has rebuilt itself at the
-- new screen dimensions, and reopens each screen in turn.
-- ---------------------------------------------------------------------------
local _pending_rotation_reopen = {}

function M.setPendingRotationReopen(id, instance_cfg, on_qa_tap, on_goal_tap)
    _pending_rotation_reopen[id] = {
        instance_cfg = instance_cfg,
        on_qa_tap    = on_qa_tap,
        on_goal_tap  = on_goal_tap,
    }
end

-- Returns the pending list and clears it. Called once per setupLayout.
function M.takePendingRotationReopens()
    local pending = _pending_rotation_reopen
    _pending_rotation_reopen = {}
    return pending
end

-- ---------------------------------------------------------------------------
-- Content area dimensions
-- ---------------------------------------------------------------------------

-- Height of the band reserved at the top of every screen. It is reserved
-- whether or not the status bar is shown, so content keeps the same top limit
-- when the bar is toggled. It follows the status bar size setting.
function M.getTopInset()
    return _TB().TOTAL_TOP_H()
end

-- Top edge of the content area.
function M.getContentTop()
    return M.getTopInset()
end

-- Height of the content area: between the top inset and the bottom bar.
function M.getContentHeight()
    return Screen:getHeight() - _BB().TOTAL_H() - M.getTopInset()
end

-- Sizes a widget (or its constructor attrs) to the content area and marks it
-- as sized, so it is not reduced a second time.
function M.fitToContentArea(target)
    target.height                 = M.getContentHeight()
    target.y                      = M.getContentTop()
    target._navbar_height_reduced = true
end

-- ---------------------------------------------------------------------------
-- Topbar replacement inside OverlapGroup
-- ---------------------------------------------------------------------------

function M.replaceTopbar(widget, new_topbar)
    local container = widget._navbar_container
    if not container then return end
    if not widget._navbar_topbar then return end
    local idx = widget._navbar_topbar_idx
    if idx and container[idx] == widget._navbar_topbar then
        new_topbar.overlap_offset = container[idx].overlap_offset or { 0, 0 }
        container[idx]        = new_topbar
        widget._navbar_topbar = new_topbar
        return
    end
    for i, child in ipairs(container) do
        if child == widget._navbar_topbar then
            new_topbar.overlap_offset = child.overlap_offset or { 0, 0 }
            container[i]              = new_topbar
            widget._navbar_topbar     = new_topbar
            widget._navbar_topbar_idx = i
            return
        end
    end
    logger.warn("simpleui: replaceTopbar could not find topbar in container — skipping")
end

-- ---------------------------------------------------------------------------
-- Wraps an inner widget with the navbar layout (topbar + content + bottombar)
-- ---------------------------------------------------------------------------

function M.wrapWithNavbar(inner_widget, active_action_id, tabs, force_no_arrows)
    local Topbar    = _TB()
    local Bottombar = _BB()
    local screen_w  = Screen:getWidth()
    local screen_h  = Screen:getHeight()
    -- Read both settings once — used multiple times below.
    local topbar_on = SUISettings:nilOrTrue("simpleui_topbar_enabled")
    local navbar_on = SUISettings:nilOrTrue("simpleui_bar_enabled")
    local topbar_top = M.getTopInset()
    local navbar_h   = Bottombar.TOTAL_H()
    local content_h  = screen_h - topbar_top - navbar_h

    local bar
    if navbar_on then
        bar = Bottombar.buildBarWidget(active_action_id, tabs)
    end
    -- Build topbar only once — wrapWithNavbar is the single point of construction.
    -- Callers must NOT call buildTopbarWidget() again after wrapWithNavbar returns.
    local topbar = topbar_on and Topbar.buildTopbarWidget() or nil

    inner_widget.overlap_offset = { 0, topbar_top }
    if inner_widget.dimen then
        inner_widget.dimen.h = content_h
        inner_widget.dimen.w = screen_w
    else
        inner_widget.dimen = Geom():new{ w = screen_w, h = content_h }
    end

    local bar_idx
    local overlap_items = {
        dimen = Geom():new{ w = screen_w, h = screen_h },
        inner_widget,
    }

    if navbar_on then
        local bar_y = screen_h - navbar_h

        bar.overlap_offset      = { 0, bar_y }

        overlap_items[2] = bar
        bar_idx = 2
    end

    if topbar_on then
        topbar.overlap_offset = { 0, 0 }
        overlap_items[#overlap_items + 1] = topbar
    end

    local topbar_idx       = topbar_on and #overlap_items or nil
    local navbar_container = OverlapGroup():new(overlap_items)
    local is_bare_bar = SUISettings:readSetting("simpleui_bar_style") == "bare"
    local wrapper_bg = (SUISettings:isTrue("simpleui_navbar_transparent") or SUISettings:isTrue("simpleui_statusbar_transparent") or is_bare_bar) and nil or SUIStyle.COLOR.surface

    return navbar_container,
           FrameContainer():new{
               bordersize = 0, padding = 0, margin = 0,
               background = wrapper_bg,
               navbar_container,
           },
           bar, topbar, bar_idx, topbar_on, topbar_idx
end

-- ---------------------------------------------------------------------------
-- Applies all navbar state fields to a widget in one call (RF2).
-- Eliminates the repeated 9-field block scattered across patches/bottombar.
-- ---------------------------------------------------------------------------

function M.applyNavbarState(widget, container, bar, topbar, bar_idx, topbar_on, topbar_idx, tabs)
    widget._navbar_container         = container
    widget._navbar_bar               = bar
    widget._navbar_topbar            = topbar
    widget._navbar_topbar_idx        = topbar_idx
    widget._navbar_tabs              = tabs
    widget._navbar_bar_idx           = bar_idx
    widget._navbar_bar_idx_topbar_on = topbar_on
    widget._navbar_content_h         = M.getContentHeight()
end

-- ---------------------------------------------------------------------------
-- Gesture priority for navbar touch zones (InputContainer)
--
-- KOReader dispatches Gesture such that WidgetContainer:handleEvent runs
-- children first; only then does the parent's onGesture run (where
-- registerTouchZones handlers live). Content below the bottom bar can therefore
-- steal taps. Run InputContainer.onGesture (zones + ges_events) before
-- propagating to children. See doc: WidgetContainer:handleEvent / Events.md.
-- ---------------------------------------------------------------------------

local function _resolveInheritedHandleEvent(target)
    local own = rawget(target, "handleEvent")
    if type(own) == "function" then return own end
    local idx = getmetatable(target) and getmetatable(target).__index
    while type(idx) == "table" do
        local fn = rawget(idx, "handleEvent")
        if type(fn) == "function" then return fn end
        idx = getmetatable(idx) and getmetatable(idx).__index
    end
    return require("ui/widget/container/widgetcontainer").handleEvent
end

--- Call on any InputContainer that uses registerTouchZones for the navbar (FM
--- class, Homescreen instance, or UIManager-injected fullscreen widgets).
function M.applyGesturePriorityHandleEvent(target)
    if not target or target._simpleui_gesture_priority_applied then return end
    local InputContainer  = require("ui/widget/container/inputcontainer")
    local WidgetContainer = require("ui/widget/container/widgetcontainer")
    local inherit         = _resolveInheritedHandleEvent(target)
    target._simpleui_gesture_priority_applied = true
    target.handleEvent = function(self, event)
        if event.handler == "onGesture" then
            local ges = event.args and event.args[1]
            if ges and InputContainer.onGesture(self, ges) then
                return true
            end
            return inherit(self, event)
        end
        return inherit(self, event)
    end
end

function M.unapplyGesturePriorityHandleEvent(target)
    if not target or not target._simpleui_gesture_priority_applied then return end
    target.handleEvent = nil
    target._simpleui_gesture_priority_applied = nil
end

-- ---------------------------------------------------------------------------
-- Safe access to the UIManager window stack
-- ---------------------------------------------------------------------------

function M.getWindowStack()
    local UIManager = require("ui/uimanager")
    if type(UIManager._window_stack) ~= "table" then
        logger.warn("simpleui: UIManager._window_stack not available — internal API changed?")
        return {}
    end
    return UIManager._window_stack
end

-- ---------------------------------------------------------------------------
-- Shared settings menu (#4)
-- Eliminates the near-identical showSettingsMenu closures in bottombar.lua and
-- topbar.lua. Both now delegate here.
--
-- title         : menu title string
-- item_table_fn : zero-arg function returning the raw item table
-- top_offset    : pixels to push the menu down (topbar height, or 0)
-- screen_h      : Screen:getHeight() — passed in to avoid re-querying
-- bottombar_h   : Bottombar.TOTAL_H() — passed in to avoid circular require
-- ---------------------------------------------------------------------------

function M.showSettingsMenu(title, item_table_fn, top_offset, screen_h, bottombar_h)
    local logger = require("logger")
    if not item_table_fn then return end
    top_offset = top_offset or 0
    local Menu      = require("ui/widget/menu")
    local UIManager = require("ui/uimanager")
    local menu_h    = screen_h - bottombar_h - top_offset

    -- Tracks whether any item callback ran while the menu was open.
    -- Used by onCloseWidget to trigger an immediate screen refresh on close,
    -- bypassing the 0.15s debounce that would otherwise fire after the paint.
    local _had_changes = false

    local menu
    menu = Menu:new{
        title      = title,
        item_table = M.resolveMenuItems(item_table_fn()),
        height     = menu_h,
        width      = Screen:getWidth(),
        is_popout  = false,
        onMenuSelect = function(self_menu, item)
            if item.sub_item_table or item._sui_lazy_fn then
                -- Resolve lazy sub-table on first navigation into this item.
                if item._sui_lazy_fn then
                    item.sub_item_table = M.resolveMenuItems(item._sui_lazy_fn())
                    item._sui_lazy_fn   = nil
                end
                self_menu.item_table.title = self_menu.title
                self_menu.item_table_stack[#self_menu.item_table_stack + 1] = self_menu.item_table
                self_menu:switchItemTable(item.text, M.resolveMenuItems(item.sub_item_table))
            elseif item.callback then
                local _suppress = false
                local function suppress_refresh() _suppress = true end
                item.callback(self_menu, suppress_refresh)
                if item.keep_menu_open then
                    -- Stay open: just redraw the item list to reflect the change.
                    self_menu:updateItems()
                else
                    if not _suppress then _had_changes = true end
                    -- Close the menu; onCloseWidget will fire the screen refresh.
                    UIManager:close(self_menu)
                end
            end
            return true
        end,
        -- When the menu closes (by any means — back button, item without
        -- keep_menu_open, or tapping outside), immediately refresh whichever
        -- screen (Homescreen or Custom Screen) is open, if any item callback
        -- ran. This fires synchronously in the same UIManager cycle as the
        -- close, so the screen is rebuilt before the next paint — eliminating
        -- the stale-state flash that occurred when the 0.15s debounce timer
        -- fired after the menu had already closed and the screen been painted.
        onCloseWidget = function()
            if not _had_changes then return end
            _had_changes = false
            -- Call _refreshImmediate directly (synchronous, no scheduleIn).
            -- scheduleIn(0) was tried but the UIManager processes pending repaints
            -- before executing scheduled callbacks — so the HS was painted with
            -- the stale tree before the rebuild ran. The synchronous call ensures
            -- the widget tree is replaced before any paint is flushed.
            -- Whichever screen is open (Homescreen or Custom Screen) — both
            -- have their own bottombar/topbar that can open this menu.
            local ok, ScreenEngine = pcall(require, "engines/sui_screen_engine")
            if not (ok and ScreenEngine) then return end
            ScreenEngine.refreshAllLiveImmediate(false)
        end,
    }
    if top_offset > 0 then
        local orig_paintTo = menu.paintTo
        menu.paintTo = function(self_m, bb, x, y)
            orig_paintTo(self_m, bb, x, y + top_offset)
        end
        menu.dimen.y = top_offset
    end
    UIManager:show(menu)
end

-- ---------------------------------------------------------------------------
-- Shared helper to paint a widget with perfect alpha transparency over wallpapers
-- ---------------------------------------------------------------------------
function M.paintWithAlphaMask(widget, target_bb, x, y, w, h, fgcolor, custom_paint_fn, tmp_bb)
    -- widget can be nil if it was already freed (e.g. a widget shared with
    -- a tree that got torn down elsewhere via a CloseWidget cascade) while
    -- this wrapper is still reachable from a live paint pass. Skip the
    -- paint rather than crash the whole repaint pipeline.
    if not widget then return end

    local own_bb = false
    if not tmp_bb then
        tmp_bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
        own_bb = true
    end
    tmp_bb:fill(SUIStyle.COLOR.surface)
    if custom_paint_fn then
        custom_paint_fn(widget, tmp_bb, 0, 0)
    else
        widget:paintTo(tmp_bb, 0, 0)
    end
    tmp_bb:invertRect(0, 0, w, h)
    target_bb:colorblitFromRGB32(tmp_bb, x, y, 0, 0, w, h, fgcolor)
    if own_bb then tmp_bb:free() end
end

-- Shared lazy loader used by makeAlphaMaskWidget and its callers below.
local _WidgetContainer
local function _WC()
    _WidgetContainer = _WidgetContainer or require("ui/widget/container/widgetcontainer")
    return _WidgetContainer
end

-- ---------------------------------------------------------------------------
-- makeAlphaMaskWidget — generic WidgetContainer wrapper that paints `inner`
-- through paintWithAlphaMask, recolored to `fgcolor`, with a cached scratch
-- Blitbuffer sized to the widget's own dimen.
--
-- This is the shared shape behind makeColoredText, makeAlphaTextBox, and
-- wrapDimmable below (each just builds a different `inner` and picks a
-- `fgcolor`) — kept as a single factory instead of three near-identical
-- WidgetContainer definitions, and reused by other engines that need the
-- same alpha-mask-recolored-widget technique.
--
-- `dimen` defaults to `inner:getSize()`. Pass it explicitly when the wrapper
-- needs to report a size independent of the inner widget (e.g. a fixed
-- icon-cell size).
-- ---------------------------------------------------------------------------
function M.makeAlphaMaskWidget(inner, fgcolor, dimen)
    local widget = _WC():new{}
    widget.dimen  = dimen or inner:getSize()
    widget._inner = inner
    widget._fg    = fgcolor

    function widget:getSize()
        return self.dimen
    end

    function widget:paintTo(bb, x, y)
        self.dimen.x, self.dimen.y = x, y
        local w = self.dimen.w
        local h = self.dimen.h
        if w <= 0 or h <= 0 then return end

        if not self._tmp_bb or self._tmp_bb:getWidth() ~= w or self._tmp_bb:getHeight() ~= h then
            if self._tmp_bb then self._tmp_bb:free() end
            self._tmp_bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
        end
        M.paintWithAlphaMask(self._inner, bb, x, y, w, h, self._fg, nil, self._tmp_bb)
    end

    function widget:onCloseWidget()
        self:free()
    end

    function widget:free()
        if self._inner then
            self._inner:free()
            self._inner = nil
        end
        if self._tmp_bb then
            self._tmp_bb:free()
            self._tmp_bb = nil
        end
    end

    function widget:onToggleNightMode() require("ui/uimanager"):setDirty(self) end
    function widget:onSetNightMode()    require("ui/uimanager"):setDirty(self) end
    function widget:onApplyTheme()      require("ui/uimanager"):setDirty(self) end

    return widget
end

-- ---------------------------------------------------------------------------
-- makeColoredText — TextWidget wrapper that actually honours fgcolor.
--
-- KOReader's TextWidget silently ignores the `fgcolor` parameter on many
-- device builds (it was not wired through to RenderText in older versions).
-- TextBoxWidget does honour fgcolor, but TextWidget is preferred for single-
-- line text because it auto-sizes and supports truncation / max_width.
--
-- This helper:
--   1. Creates an inner TextWidget with all the caller-supplied params.
--   2. If fgcolor is nil (caller wants the device default), returns the inner
--      TextWidget directly — zero overhead, no change in behaviour.
--   3. Otherwise wraps it in a WidgetContainer whose paintTo() renders the
--      text into a temporary 8-bit buffer and composites the result onto the
--      target framebuffer using colorblitFromRGB32, which correctly applies
--      arbitrary Blitbuffer colours on all KOReader builds.
--
-- Drop-in for TextWidget:new when you need fgcolor to work:
--   local w = UI.makeColoredText{
--       text    = "hello",
--       face    = Font:getFace("cfont", SUIStyle.FS_CAPTION),
--       bold    = true,
--       fgcolor = SUIStyle.COLOR.text_primary,  -- any colour
--       width   = 200,                     -- optional, as with TextWidget
--   }
-- ---------------------------------------------------------------------------
-- Shared lazy loader for makeColoredText and makeAlphaTextBox.
local _TextWidget
local function _TW()
    _TextWidget = _TextWidget or require("ui/widget/textwidget")
    return _TextWidget
end

function M.makeColoredText(opts)
    local fgcolor = opts.fgcolor

    -- If no custom colour is requested, return the TextWidget as-is.
    if not fgcolor then return _TW():new(opts) end

    -- Force the inner TextWidget to draw in BLACK. Since we use paintWithAlphaMask
    -- which renders onto a white buffer and inverts it, drawing white text on a
    -- white buffer would produce an empty mask (invisible text).
    local inner_opts = {}
    for k, v in pairs(opts) do inner_opts[k] = v end
    inner_opts.fgcolor = SUIStyle.COLOR.text_primary

    local inner = _TW():new(inner_opts)
    return M.makeAlphaMaskWidget(inner, fgcolor)
end

-- ---------------------------------------------------------------------------
-- updateColoredText(wgt, txt, fg) — mutates a widget previously returned by
-- makeColoredText() (or any plain TextWidget with a setText method) in place,
-- without rebuilding it. Same technique module_currently.lua's own local
-- _updateColoredText helper already used privately; promoted here so other
-- in-place "updateStats"-style refreshes (e.g. GridRenderer's row/grid
-- modules) can reuse it instead of duplicating the branching logic.
-- Purely additive: module_currently.lua's own private copy is untouched.
-- ---------------------------------------------------------------------------
function M.updateColoredText(wgt, txt, fg)
    -- Note: fg is a Blitbuffer color (ffi cdata) when present. Its __eq
    -- metamethod assumes both sides of a comparison are color objects, so
    -- comparing it against nil with ==/~= crashes. A truthiness check avoids
    -- invoking the metamethod at all.
    if wgt._inner and wgt._inner.setText then
        wgt._inner:setText(txt)
        if fg then wgt._fg = fg end
        wgt.dimen = wgt._inner:getSize()
    elseif wgt.setText then
        wgt:setText(txt)
        if fg then wgt.fgcolor = fg end
    end
end

-- ---------------------------------------------------------------------------
-- makeAlphaTextBox — transparent-background TextBoxWidget replacement.
--
-- Builds a WidgetContainer that renders a TextBoxWidget using Blitbuffer's
-- colorblitFromRGB32 so the text composites over whatever is already on the
-- framebuffer (i.e. a wallpaper) rather than painting an opaque white rect.
--
-- The implementation is self-contained: it does NOT depend on lib/setting,
-- lib/common, or ui/font_color (all of which are external to SimpleUI).
-- fgcolor is used directly — the caller supplies it from its own colour logic.
--
-- Usage (drop-in for TextBoxWidget:new when has_wallpaper is true):
--   local w = UI.makeAlphaTextBox{
--       text      = "...",
--       face      = face,
--       bold      = true,
--       width     = tw,
--       alignment = "center",
--       fgcolor   = SUIStyle.COLOR.text_primary,
--       max_lines = 2,     -- optional, passed through to inner TextBoxWidget
--   }
-- ---------------------------------------------------------------------------
local _TextBoxWidget
local function _TBW()
    _TextBoxWidget = _TextBoxWidget or require("ui/widget/textboxwidget")
    return _TextBoxWidget
end

function M.makeAlphaTextBox(opts)
    local fgcolor = opts.fgcolor or SUIStyle.COLOR.text_primary

    local inner = _TBW():new{
        text        = opts.text,
        face        = opts.face,
        bold        = opts.bold,
        width       = opts.width,
        height      = opts.height,
        alignment   = opts.alignment   or "left",
        justified   = opts.justified   or false,
        line_height = opts.line_height or 0.3,
        max_lines   = opts.max_lines,
        height_adjust = opts.height_adjust,
        height_overflow_show_ellipsis = opts.height_overflow_show_ellipsis,
        fgcolor     = SUIStyle.COLOR.text_primary,
        bgcolor     = SUIStyle.COLOR.surface,
        alpha       = true,
    }

    return M.makeAlphaMaskWidget(inner, fgcolor)
end

-- ---------------------------------------------------------------------------
-- wrapDimmable — wraps any already-built widget so it paints dimmed.
--
-- Generalises the alpha-recolour technique above (and the one used by
-- Bottombar.patchDimmedIcon for the pagination chevrons) to arbitrary
-- widgets: an icon's on/off, enabled/disabled state is expressed by dimming
-- the SAME widget rather than swapping in a visually distinct asset.
--
-- Pass-through when dim is false, so callers can wrap unconditionally:
--   icon_widget = UI.wrapDimmable(icon_widget, entry.dim)
-- ---------------------------------------------------------------------------
function M.wrapDimmable(inner, dim, fgcolor)
    if not dim or not inner then return inner end
    return M.makeAlphaMaskWidget(inner, fgcolor or SUIStyle.COLOR.text_dim)
end

-- ---------------------------------------------------------------------------
-- Shared Progress Bar
-- ---------------------------------------------------------------------------
function M.progressBar(w, pct, bar_h, fg_color, bg_color)
    bar_h = bar_h or Screen:scaleBySize(4)
    
    local ok, SUIStyle = pcall(require, "features/sui_style")
    local style = SUISettings:get("simpleui_style_progress_bar_type") or "flat"

    local bg = bg_color or SUIStyle.COLOR.track
    local fg = fg_color or SUIStyle.COLOR.gray
    
    if style == "framed" then
        local border = ok and SUIStyle.BADGE_BORDER_SZ or 1
        local border_color = SUIStyle.COLOR.text_primary
        local inner_w = math.max(0, w - 2 * border)
        local inner_h = math.max(0, bar_h - 2 * border)
        local fw = math.max(0, math.floor(inner_w * math.min(pct or 0, 1.0)))

        local bg_frame = FrameContainer():new{
            bordersize = border,
            color      = border_color,
            background = SUIStyle.COLOR.surface,
            padding    = 0, margin = 0,
            LineWidget():new{ dimen = Geom():new{ w = inner_w, h = inner_h }, background = SUIStyle.COLOR.surface }
        }

        if fw <= 0 then
            return bg_frame
        end

        local fg_bar = LineWidget():new{ dimen = Geom():new{ w = fw, h = inner_h }, background = fg }
        fg_bar.overlap_offset = { border, border }

        return OverlapGroup():new{
            dimen = Geom():new{ w = w, h = bar_h },
            bg_frame,
            fg_bar,
        }
    else
        local fw = math.max(0, math.floor(w * math.min(pct or 0, 1.0)))
        if fw <= 0 then
            return LineWidget():new{ dimen = Geom():new{ w = w, h = bar_h }, background = bg }
        end
        return OverlapGroup():new{
            dimen = Geom():new{ w = w, h = bar_h },
            LineWidget():new{ dimen = Geom():new{ w = w,  h = bar_h }, background = bg },
            LineWidget():new{ dimen = Geom():new{ w = fw, h = bar_h }, background = fg },
        }
    end
end

-- ---------------------------------------------------------------------------
-- Bar Injection API
-- ---------------------------------------------------------------------------
M.BarInjection = {}
local _bi_registry       = {}
local _bi_registry_order = {}

local function _validateBI(desc)
    if type(desc) ~= "table" then return "descriptor must be a table" end
    if type(desc.id) ~= "string" or desc.id == "" then return "descriptor.id must be a non-empty string" end
    if desc.widget_name == nil and type(desc.match) ~= "function" then return "descriptor must provide widget_name (string) or match (function)" end
    if desc.widget_name ~= nil and type(desc.widget_name) ~= "string" then return "descriptor.widget_name must be a string" end
    if desc.active_action_id ~= nil and type(desc.active_action_id) ~= "string" then return "descriptor.active_action_id must be a string when provided" end
    if desc.get_active_action ~= nil and type(desc.get_active_action) ~= "function" then return "descriptor.get_active_action must be a function when provided" end
    if desc.is_pageable ~= nil and type(desc.is_pageable) ~= "boolean" and type(desc.is_pageable) ~= "function" then return "descriptor.is_pageable must be boolean or nil" end
    if desc.on_inject ~= nil and type(desc.on_inject) ~= "function" then return "descriptor.on_inject must be a function when provided" end
    if desc.on_close ~= nil and type(desc.on_close) ~= "function" then return "descriptor.on_close must be a function when provided" end
    return nil
end

function M.BarInjection.register(desc)
    local err = _validateBI(desc)
    if err then
        logger.warn("sui_core: BarInjection.register() rejected:", err, "(id=", tostring(desc and desc.id), ")")
        return
    end
    local id = desc.id
    if not _bi_registry[id] then
        _bi_registry_order[#_bi_registry_order + 1] = id
        logger.dbg("sui_core: BarInjection registered descriptor id=", id)
    else
        logger.dbg("sui_core: BarInjection replaced descriptor id=", id)
    end
    _bi_registry[id] = desc
end

function M.BarInjection.unregister(id)
    if not _bi_registry[id] then return end
    _bi_registry[id] = nil
    for i = #_bi_registry_order, 1, -1 do
        if _bi_registry_order[i] == id then
            table.remove(_bi_registry_order, i)
            break
        end
    end
    logger.dbg("sui_core: BarInjection unregistered id=", id)
end

function M.BarInjection.matchWidget(widget)
    if not widget then return nil end
    for _, id in ipairs(_bi_registry_order) do
        local desc = _bi_registry[id]
        if desc then
            local matched = false
            if type(desc.match) == "function" then
                local ok, result = pcall(desc.match, widget)
                matched = ok and result == true
            elseif desc.widget_name ~= nil then
                matched = (widget.name == desc.widget_name)
            end
            if matched then return desc end
        end
    end
    return nil
end

function M.BarInjection.allIds()
    local result = {}
    for i, id in ipairs(_bi_registry_order) do
        result[i] = id
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Notify — shared InfoMessage helpers.
--
-- Central place for the two notice behaviours used across Simple UI:
--
--   toast   — auto-dismiss feedback (errors, validation, success).
--             Default timeout is 3 seconds; pass a longer value when the
--             message needs more reading time (e.g. backup paths, errors).
--   sticky  — stays until closed or timeout=0 tick; optional forceRePaint
--             so the message is visible on e-ink before blocking work.
--   close   — safe dismiss for a sticky held by the caller.
--
-- Callers keep translated strings at the call site. This module only owns
-- the show/close/repaint mechanics so timeouts and e-ink flush stay consistent.
--
-- Convention: this is the only entry point for one-off notices anywhere in
-- Simple UI. Call sites should not require("ui/widget/infomessage") and
-- show it directly — go through Notify.toast/sticky instead, even for a
-- single, simple message, so timeout defaults and e-ink repaint behaviour
-- stay uniform across the plugin.
--
-- Higher-level helpers built on Notify:
--   applyPresetWithNotice  — sticky "Applying preset…" around a work fn
--   StatsWindows.showLoadingNotice — sticky loading toast (setting-gated)
-- ---------------------------------------------------------------------------

M.Notify = {}

local function _uim()
    return require("ui/uimanager")
end

local function _infoMessage()
    return require("ui/widget/infomessage")
end

--- Auto-dismiss toast.
-- @param text string  Already-translated message.
-- @param timeout number|nil  Seconds visible (default 3).
-- @return widget  The InfoMessage instance (rarely needed).
function M.Notify.toast(text, timeout)
    local notice = _infoMessage():new{
        text    = text,
        timeout = timeout or 3,
    }
    _uim():show(notice)
    return notice
end

--- Sticky notice (timeout 0 by default). Optional compact width and repaint.
--
-- opts:
--   timeout  number   dismiss delay; 0 / 0.0 means next-tick auto-close
--                     (InfoMessage default sticky behaviour). Default 0.
--   repaint  boolean  call forceRePaint after show so e-ink shows the
--                     notice before the caller blocks. Default true.
--   compact  boolean  shrink width to the text plus padding (power-style).
--   width    number   explicit width; ignored when compact is true.
-- @return widget  The InfoMessage (hold this to close later via Notify.close).
function M.Notify.sticky(text, opts)
    opts = opts or {}
    local UIManager = _uim()
    local params = {
        text    = text,
        timeout = opts.timeout ~= nil and opts.timeout or 0,
    }

    if opts.compact then
        local Font       = require("ui/font")
        local Size       = require("ui/size")
        local RenderText = require("ui/rendertext")
        local face       = Font:getFace("infofont")
        local text_w     = RenderText:sizeUtf8Text(
            0, Screen:getWidth(), face, text, true, 0, true).x
        params.width = math.ceil(text_w + Size.padding.large * 4)
    elseif opts.width then
        params.width = opts.width
    end

    local notice = _infoMessage():new(params)
    UIManager:show(notice)
    if opts.repaint ~= false then
        UIManager:forceRePaint()
    end
    return notice
end

--- Close a notice returned by toast/sticky. Safe if notice is nil or already gone.
function M.Notify.close(notice)
    if not notice then return end
    pcall(function() _uim():close(notice) end)
end

-- ---------------------------------------------------------------------------
-- Shared "Applying preset…" blocking notice.
--
-- Single implementation for any preset-apply flow (Homescreen presets,
-- Icon presets, and any future preset type) that needs visible feedback
-- while it runs: shows a notice, flushes it to the e-ink screen
-- immediately so it's visible before apply_fn runs, then closes it once
-- any deferred follow-up work has finished.
-- ---------------------------------------------------------------------------

--- Runs apply_fn under a blocking "Applying preset…" notice.
---
--- apply_fn must return a truthy value on success; on failure the notice
--- is closed immediately and false is returned so the caller can show its
--- own error dialog. sync_repaint (optional) runs right after a
--- successful apply_fn, before on_applied — for callers that need to
--- repaint their own preset list (e.g. a radio checkmark) immediately
--- rather than waiting a tick. on_applied (optional) is deferred via
--- nextTick alongside closing the notice, so any screen rebuild it
--- triggers has a chance to finish before the notice disappears.
function M.applyPresetWithNotice(apply_fn, on_applied, sync_repaint)
    local UIManager = _uim()
    local _ = require("infra/sui_i18n").translate

    local notice = M.Notify.sticky(_("Applying preset…"))

    if not apply_fn() then
        M.Notify.close(notice)
        return false
    end
    if sync_repaint then sync_repaint() end
    UIManager:nextTick(function()
        if on_applied then on_applied() end
        M.Notify.close(notice)
    end)
    return true
end

return M
