-- sui_window.lua — SimpleUI ▸ SUI Window System
--
-- Reusable modal window system for SimpleUI.
-- Organised in four logical layers:
--
--   SUIWindow        — public API: new, show, close
--   SUIWindow (priv) — internal engine: navigation, repaint, pagination, dot bar
--   SUIWindow.Input  — input helpers: tapable, iconButton
--   SUIWindow.*      — UI components (flat namespace, no C. sub-table):
--                        ListRow, Button, Section, MenuTable, ActionMenu
--                        Card (base), PageCard, ModuleCard, ArrangeCard
--                        ArrangeList, TwoButtonFooter, CenteredButtonFooter
--
-- Minimal usage:
--
--   local SUI = require("engines/sui_window")
--   SUI:new{
--       title    = "Title",
--       screens  = {
--           __root__ = function(ctx) return { SUI.ListRow{...} } end,
--       },
--   }:show()
--
-- Build context (ctx):
--   ctx.inner_w          — available content width
--   ctx.page_h           — tallest content one page can hold when the screen
--                          paginates (title bar and dot bar already deducted)
--   ctx.pad              — modal padding
--   ctx.current()        — current navigation stack frame { id, params }
--   ctx.push(id, params) — navigate to a screen registered in opts.screens
--   ctx.pop()            — go back to the previous screen
--   ctx.repaint()        — rebuild the current screen
--   ctx.close()          — close the window
--   ctx.withOverlay(fn)  — run fn() while blocking onTapOutside; safe even if fn throws
--
-- screens map:
--   The __root__ key is the entry screen.  All other keys are sub-screens
--   reachable via ctx.push(id).  There is no separate `build` parameter.
--
-- screen_titles:
--   Optional map<screen_id, string | function(ctx)→string> for declarative titles.
--   When provided, the title for each screen is taken from this map.
--   Dynamic screens (nested_menu, arrange) can still use a title function.
--   If absent, a single `title` function/string/table is used for all screens.
--
-- screen_headers:
--   Optional map<screen_id, function(ctx)→widget> for per-screen fixed headers.
--   A header stays below the title bar on every page of its screen.
--
-- screen_footers:
--   Optional map<screen_id, function(ctx)→widget> for per-screen fixed footers.
--
-- Component selection guide:
--   ListRow   — menu/navigation item (tap → push or action)
--   PageCard  — top-level entity with identity (e.g. a page); tap navigates, delete optional
--   ModuleCard— editable entity with action menu (move, edit); delete optional
--   ArrangeCard / ArrangeList — reorder-only mode, move up/down arrows
--
-- ── Reproducing a KOReader menu inside a SUIWindow ───────────────────────────
--
-- The canonical way to surface any existing KOReader menu section inside a
-- SUIWindow is via SUI.MenuTable.  The pattern has two parts:
--
-- 1. The module that OWNS the menu exports a function that returns a plain table
--    of KOReader menu items (text/text_func, callback, sub_item_table_func, …).
--    Callbacks that need to refresh UI accept an opts table with hooks:
--
--      function MyModule.makeMenuItems(opts)
--          opts = opts or {}
--          local on_change = opts.on_change or function() end
--          local items = {}
--          items[#items+1] = {
--              text     = _("Do something"),
--              callback = function() doSomething(); on_change() end,
--          }
--          return items
--      end
--
-- 2. The SUIWindow screen builder calls that function and wraps the result
--    with SUI.MenuTable, passing push_stack and on_close for sub-menu navigation:
--
--      local function buildMyScreen(ctx)
--          local items = MyModule.makeMenuItems{
--              on_change = function() ctx.repaint() end,
--          }
--          return SUI.MenuTable{
--              inner_w    = ctx.inner_w,
--              items      = items,
--              repaint    = function() ctx.repaint() end,
--              push_stack = function(_, params)
--                  ctx.push("nested_menu", params)
--              end,
--              on_close   = function() end,
--          }
--      end
--
-- Icon reference: SUIStyle.icon("name") — never raw codepoints.

local Blitbuffer      = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local ButtonDialog    = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local RightContainer  = require("ui/widget/container/rightcontainer")
local Size            = require("ui/size")
local T               = require("ffi/util").template
local _               = require("infra/sui_i18n").translate
local BD              = require("ui/bidi")
local TextWidget      = require("ui/widget/textwidget")
local TitleBar        = require("ui/widget/titlebar")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local logger          = require("logger")

local SUIStyle  = require("features/sui_style")
local UI        = require("infra/sui_core")
local DateNames = require("infra/sui_datenames")

-- Landscape-aware size multiplier — the counterpart, inside SUIWindow, of the
-- home screen's Config-scale patch. In portrait _sui_scale is 1 (no-op); in
-- landscape it is UI.getLandscapeFactor(), the same factor the home screen
-- uses to fit its two-column spread. Every pixel/font size computed in this
-- file should be wrapped in SZ(...) so the whole window — chrome, rows,
-- buttons, text — shrinks together, proportionally, instead of just the
-- outer modal box.
--
-- Set once per window, at the top of SUIWindow:show() and SUIWindow:_repaint()
-- (self._scale is frozen at construction time in SUIWindow:new(), same as
-- _modal_w/_modal_h). Safe as a shared upvalue because window content is
-- always built synchronously, start to finish, before any other window's
-- build can begin.
local _sui_scale = 1
local function SZ(n) return math.floor(n * _sui_scale) end

-- ---------------------------------------------------------------------------
-- Physical-key (D-pad) focus navigation — build-time registration
-- ---------------------------------------------------------------------------
-- Every tappable item in every SUIWindow screen passes through
-- SUIWindow.Input.tapable (directly, or via ListRow/Button/iconButton, which
-- all call it). That single choke point is used to auto-register each
-- tappable's on_tap as a keyboard-focusable target, so no individual screen
-- file (sui_menu.lua, sui_quickactions.lua, etc.) needs to know about
-- keyboard navigation at all — it "just works" as a byproduct of already
-- using ListRow/Button/tapable.
--
-- A window's content is always built synchronously, start to finish, before
-- any other window's build can begin (see the _sui_scale comment above), so
-- a simple stack — pushed/popped around the build in SUIWindow:_repaint —
-- is enough to let Input.tapable find "the window currently being built"
-- without every call site threading ctx through by hand. A stack (not a
-- single upvalue) guards against a builder that itself constructs and shows
-- a nested SUIWindow synchronously mid-build.
local _kb_build_stack = {}
local function _kbPush(win) _kb_build_stack[#_kb_build_stack + 1] = win end
local function _kbPop() _kb_build_stack[#_kb_build_stack] = nil end
local function _kbCurrent() return _kb_build_stack[#_kb_build_stack] end

-- ===========================================================================
-- SUIWindow — public API
-- ===========================================================================

local SUIWindow = {}
SUIWindow.__index = SUIWindow

-- Tracks all currently open SUIWindow instances so that getNavpagerState()
-- in sui_config can resolve a wrapper back to its owning object and read the
-- precise _current_page / _total_pages without walking into the widget tree.
SUIWindow._open_instances = {}

--- Creates a new modal window.
---
--- @param opts table
---   screens        table<string, function(ctx)→widget[]>
---                  — screen map; __root__ is the entry screen (required).
---                    Every screen builder receives ctx.SZ(n): the same
---                    landscape scale multiplier already applied to this
---                    window's own chrome (frame/padding/title). Wrap any
---                    raw pixel/font size in ctx.SZ(...) and it shrinks in
---                    landscape automatically — no import, no per-file
---                    "local function SZ(n) ... end" needed.
---   title          string | function(ctx)→string | { text, icon }
---                  — static or dynamic title for all screens (used when
---                    screen_titles is absent or has no entry for the current screen)
---   screen_titles  table<string, string | function(ctx)→string> | nil
---                  — per-screen title overrides (optional)
---   screen_headers table<string, function(ctx)→widget> | nil
---   screen_footers table<string, function(ctx)→widget> | nil
---   on_close       function() | nil
---   on_back        function() | nil — when set, the title bar shows a back
---                                  chevron at the root screen (and the
---                                  physical Back key follows it). Using it
---                                  closes this window, then calls on_back
---                                  to return to whatever opened it.
---   has_settings_btn bool | nil  — bottom-right button opening the Settings window
---   action_btn     { glyph = string, on_tap = function(ctx) } | nil
---                  — bottom-right button running a screen-specific action,
---                    drawn on the root screen only. `glyph` comes from
---                    SUIStyle.icon(). Ignored when has_settings_btn is set.
---   nav_path       { {id, params}, ... } | nil — screens pushed on top of the
---                                  root before the first paint
---   width          number | nil  — px (default: 5/6 of screen)
---   height         number | nil  — px (default: 2/3 of screen)
---   auto_height    bool | nil    — when true, the window shrinks to fit the
---                                  first page's content instead of always
---                                  occupying the full height, on the window's
---                                  very first paint only; later pages/screens
---                                  keep that same fixed height (see the
---                                  comment above o._auto_height below).
---   auto_height_per_page
---                  bool | nil    — when true, extends auto_height so EVERY
---                                  dot-bar page within the same screen gets
---                                  its own fit height, live, as the user
---                                  swipes/taps between them (e.g. a page
---                                  with a tall calendar can be taller than a
---                                  page with just a couple of summary rows).
---                                  Navigating to a *different* screen via
---                                  _navPush/_navPop is unaffected — that
---                                  screen still keeps whatever height was
---                                  last set, same as plain auto_height.
---                                  Implies auto_height; no need to pass both.
---   navpager_mode  bool | nil    — when true, the window registers onPrevPage /
---                                  onNextPage / onGotoPage / page_num on its wrapper
---                                  so the bottom-bar navpager can drive pagination,
---                                  and taps on the bottom-bar area do not close the
---                                  window (the TapOutside range is shrunk to exclude
---                                  the navbar region).
---
--- @return SUIWindow
function SUIWindow:new(opts)
    assert(type(opts.screens) == "table" and type(opts.screens.__root__) == "function",
        "SUIWindow:new — opts.screens.__root__ (function) is required")

    local o = setmetatable({}, SUIWindow)

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    -- In landscape, shrink the modal by the same factor the home screen uses
    -- to fit its two-column spread (single source of truth: UI.getLandscapeFactor),
    -- so a window opened while rotated looks proportionate to one instead of
    -- stretching across almost the entire long axis of the screen.
    --
    -- The base size that factor gets applied to must be the *notional
    -- portrait* size, not the current (possibly rotated) sw/sh: in landscape,
    -- sw is the long axis and sh is the short axis, swapped relative to
    -- portrait. Deriving modal_w/modal_h straight from sw/sh applies the
    -- shrink on top of an already-swapped axis, squashing height instead of
    -- scaling both axes down uniformly. opts.width/opts.height, when passed
    -- explicitly by callers, are likewise expected to be portrait-based.
    local portrait_w, portrait_h = UI.getPortraitDims()
    local landscape_factor = UI.getLandscapeFactor()
    o._scale         = landscape_factor
    o._modal_w       = math.floor((opts.width  or math.floor(portrait_w * 5 / 6))  * landscape_factor)
    o._modal_h       = math.floor((opts.height or math.floor(portrait_h * 23 / 30)) * landscape_factor)
    o._screen_w      = sw
    o._screen_h      = sh
    o._pad_v         = math.floor(Size.padding.large   * landscape_factor)
    o._pad_h         = math.floor(Screen:scaleBySize(20) * landscape_factor)
    o._inner_w       = o._modal_w - 2 * o._pad_h
    o._navpager_mode = opts.navpager_mode == true
    -- When true, the window shrinks to fit page 1's content instead of
    -- always occupying the full opts.height/default height. Only applied on
    -- the window's first paint. When content fits on one page, that's the
    -- final height. When content needs more than one page — either because
    -- it genuinely overflows the max height, or because a widget was marked
    -- force_new_page (see _buildPages) to force page 1 to hold only part of
    -- the content — the window still shrinks to page 1's own content height
    -- (clamped to the max height), and later pages paginate within that
    -- same fixed height via the normal swipe/dot navigation.
    o._auto_height   = opts.auto_height == true
    -- Extends auto_height so re-fit isn't a one-shot, first-paint-only thing:
    -- with this on, every repaint that stays within the SAME screen (i.e. a
    -- dot-bar page swipe/tap, not a _navPush/_navPop to a different screen)
    -- re-measures and re-fits the modal to whatever the now-current page
    -- actually needs — see _last_fit_screen_id / same_screen_as_last_fit in
    -- _rebuildFrame. Screen changes are deliberately excluded from this and
    -- keep the plain auto_height behaviour (frozen after first paint).
    o._auto_height_per_page = opts.auto_height_per_page == true
    if o._auto_height_per_page then o._auto_height = true end
    o._last_fit_screen_id = nil
    o._first_paint_done = false
    -- Position of the modal within the usable area (between topbar and navbar).
    -- "center"  — centred vertically in the usable area (default)
    -- "top"     — flush to the top of the usable area
    -- "bottom"  — flush to the bottom of the usable area (just above navbar)
    o._position      = opts.position or "center"
    o._has_settings_btn = opts.has_settings_btn == true
    o._action_btn    = opts.action_btn
    o._corner_btn_rect = nil
    o._name          = opts.name or "sui_win_unnamed"
    -- When true, _buildTitleBar/_rebuildFrame skip the TitleBar entirely (no
    -- title text, no bottom line, no close-X) and the modal's full height is
    -- given to content. Closing still works via tap-outside (onTapOutside,
    -- already wired unconditionally below) or whatever the content itself
    -- does (e.g. a tap on one of its own items calling ctx.close()).
    o._no_titlebar   = opts.no_titlebar == true

    o._title_opt      = opts.title
    o._screen_titles  = opts.screen_titles  or {}
    o._screens        = opts.screens
    o._on_close       = opts.on_close
    o._on_back        = opts.on_back
    o._screen_headers = opts.screen_headers or {}
    o._screen_footers = opts.screen_footers or {}

    o._nav_stack     = { { id = "__root__", params = {} } }
    for _i, frame in ipairs(opts.nav_path or {}) do
        o._nav_stack[#o._nav_stack + 1] = { id = frame.id, params = frame.params or {} }
    end
    o._current_page  = 1
    o._total_pages   = 1

    o._wrapper      = nil
    o._modal_frame  = nil

    -- Overlay counter: > 0 means a dialog sits on top; onTapOutside is suppressed.
    o._overlay_count = 0

    o._title_bar_h  = nil

    return o
end

--- Assembles and presents the window.
function SUIWindow:show()
    _sui_scale = self._scale
    self._closed = nil
    self._modal_frame = FrameContainer:new{
        radius         = SZ(Size.radius.window),
        bordersize     = SUIStyle.BORDER_SZ,
        padding        = 0,
        padding_left   = self._pad_h,
        padding_right  = self._pad_h,
        padding_bottom = self._pad_v,
        padding_top    = 0,
        background     = SUIStyle.COLOR.surface,
        dimen          = Geom:new{ w = self._modal_w, h = self._modal_h },
        VerticalSpan:new{ width = 0 },
    }

    local mf = self._modal_frame

    -- Compute the usable vertical area between the top inset and the navbar so
    -- the modal is centred in that region and never overlaps either bar.
    local top_h = UI.getTopInset()

    local bot_h = 0
    local ok_bb_early, Bottombar_early = pcall(require, "screens/sui_bottombar")
    if ok_bb_early and Bottombar_early and Bottombar_early.TOTAL_H then
        local has_bar = Bottombar_early.isBarInjectedOnCurrentScreen
        if type(has_bar) == "function" then
            has_bar = has_bar()
        else
            has_bar = true
        end
        if has_bar then
            bot_h = Bottombar_early.TOTAL_H()
        end
    end

    -- Usable region: from top_h to (screen_h - bot_h).
    local usable_h = self._screen_h - top_h - bot_h
    -- Clamp modal height so it always fits within the usable area.
    if self._modal_h > usable_h then
        self._modal_h = usable_h
        mf.dimen.h    = usable_h
    end
    -- Cache the geometry of the usable area and the (clamped) max height so
    -- _rebuildFrame can recompute the modal's position if auto_height later
    -- shrinks or restores self._modal_h.
    self._modal_max_h    = self._modal_h
    self._top_h_cache    = top_h
    self._bot_h_cache    = bot_h
    self._usable_h_cache = usable_h
    local pad       = Size.padding.small
    local modal_x   = math.floor((self._screen_w - self._modal_w) / 2)
    local modal_y
    if self._position == "top" then
        modal_y = top_h + pad
    elseif self._position == "bottom" and bot_h > 0 then
        modal_y = self._screen_h - bot_h - self._modal_h - pad
    else  -- "center" (default)
        modal_y = math.floor((self._screen_h - self._modal_h) / 2)
    end
    -- overlap_offset positions the child relative to the OverlapGroup origin.
    mf.overlap_offset = { modal_x, modal_y }

    self._wrapper = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = self._screen_w, h = self._screen_h },
        OverlapGroup:new{
            dimen = Geom:new{ x = 0, y = 0, w = self._screen_w, h = self._screen_h },
            mf,
        },
    }

    if Device:isTouchDevice() then
        self._wrapper.ges_events = {
            TapOutside = {
                GestureRange:new{
                    ges   = "tap",
                    range = function()
                        return Geom:new{ x = 0, y = 0, w = self._screen_w, h = self._screen_h }
                    end,
                }
            },
        }
        local win = self
        function self._wrapper:onTapOutside(_, ges)
            local stack = UIManager._window_stack
            if stack and #stack > 0 and stack[#stack].widget ~= self then
                return false
            end
            if (win._overlay_count or 0) > 0 then
                return true
            end
            if mf.dimen and not ges.pos:intersectWith(mf.dimen) then
                win:close()
                return true
            end
            return false
        end
    end

    if Device:hasKeys() then
        local win = self
        self._wrapper.key_events = {
            Close    = { { "Back" } },
            NextPage = { { "Right" } },
            PrevPage = { { "Left" } },
        }
        -- Mirrors the title bar's left-chevron/close-X split (see
        -- _buildTitleBar's left_cb): the physical Back key used to always
        -- fully close the window, even mid-navigation, which meant keyboard
        -- users had no way to step back one level the way the chevron lets
        -- touch users do — Back either goes to the previous dot-bar page,
        -- or pops one nav level, and only fully closes at the root, same
        -- priority order as the chevron.
        function self._wrapper:onClose()
            if win._current_page > 1 then
                win._current_page = win._current_page - 1
                win:_repaint()
            elseif #win._nav_stack > 1 then
                win:_navPop()
            elseif win._on_back then
                win:_goBack()
            else
                win:close()
            end
            return true
        end
        -- onPrevPage / onNextPage are defined once below (shared by hasKeys
        -- and navpager_mode so there is no duplication).
    end

    -- D-pad focus navigation: Up/Down moves focus between whatever this
    -- screen registered via Input.tapable (see _kbPush/_kbCurrent), Press
    -- activates the focused item's on_tap. Left/Right stay reserved for
    -- page turning above. No-op (but harmless) on screens with zero
    -- focusable items — Up/Down/Press just return true without moving.
    if Device:hasDPad() then
        local win = self
        -- hasDPad() devices are expected to also hasKeys() (the block above
        -- already created key_events in that case), but guard defensively
        -- so this never indexes a nil table if that assumption ever breaks.
        self._wrapper.key_events = self._wrapper.key_events or {}
        self._wrapper.key_events.KbFocusUp     = { { "Up" } }
        self._wrapper.key_events.KbFocusDown   = { { "Down" } }
        self._wrapper.key_events.KbFocusSelect = { { "Press" } }
        function self._wrapper:onKbFocusUp()
            local n = #win._kb_focusables
            if n > 0 then
                win._kb_focus_idx = ((win._kb_focus_idx or 1) - 2) % n + 1
                win._kb_focus_active = true
                win:_repaint()
            end
            return true
        end
        function self._wrapper:onKbFocusDown()
            local n = #win._kb_focusables
            if n > 0 then
                win._kb_focus_idx = (win._kb_focus_idx or 0) % n + 1
                win._kb_focus_active = true
                win:_repaint()
            end
            return true
        end
        function self._wrapper:onKbFocusSelect()
            local on_tap = win._kb_focusables[win._kb_focus_idx or 1]
            if on_tap then on_tap() end
            return true
        end
    end

    -- Page-navigation handlers shared by physical keys (Right/Left) and the
    -- navpager bottom bar.  Defined unconditionally so hasKeys devices always
    -- get them; navpager_mode additionally registers the page_num sentinel and
    -- onGotoPage so sui_bottombar._callPageFn can discover this window.
    do
        local win = self
        function self._wrapper:onNextPage()
            if win._current_page < win._total_pages then
                win._current_page = win._current_page + 1
                win:_repaint()
            end
            return true
        end
        function self._wrapper:onPrevPage()
            if win._current_page > 1 then
                win._current_page = win._current_page - 1
                win:_repaint()
            end
            return true
        end
    end

    -- Navpager interface: expose page_num + onGotoPage on _wrapper so that
    -- sui_bottombar._callPageFn finds this window when it walks the stack.
    -- page_num is kept in sync with _total_pages inside _repaint().
    --
    -- _sui_window_instance marker lets getNavpagerState() find this window
    -- without covers_fullscreen (which would block FM/HS navbar repaints).
    --
    -- We also register touch zones for the prev/next arrows directly on the
    -- _wrapper so they fire even when the _wrapper sits on top of the stack
    -- (at that point the fm_self touch zones registered by registerTouchZones
    -- are no longer consulted by the KOReader input pipeline).
    if self._navpager_mode then
        local win = self
        self._wrapper.page_num             = self._total_pages
        -- NOTE: covers_fullscreen is intentionally NOT set on _wrapper.
        -- Setting it would make UIManager:_repaint() skip all widgets below
        -- (including the FM/homescreen navbar), so arrow color mutations done
        -- by _updateNavbarArrows would never reach the screen while the window
        -- is open.  Instead we use a dedicated marker (_sui_window_instance)
        -- that getNavpagerState() detects before the covers_fullscreen loop.
        self._wrapper._sui_window_instance = self

        function self._wrapper:onGotoPage(page)
            local p = math.max(1, math.min(page, win._total_pages))
            if p ~= win._current_page then
                win._current_page = p
                win:_repaint()
            end
            return true
        end

        -- Register prev/next touch zones on the _wrapper itself so the arrows
        -- work while this modal is visible.  We compute the geometry the same
        -- way registerTouchZones() does so the hit areas are identical.
        if Device:isTouchDevice() then
            local ok_bb, Bottombar = pcall(require, "screens/sui_bottombar")
            if ok_bb and Bottombar then
                local screen_w = self._screen_w
                local screen_h = self._screen_h
                local nav_h    = Bottombar.TOTAL_H()
                local bar_y    = screen_h - nav_h
                local side_m   = UI.SIDE_M()
                local usable_w = UI.getUsableW(screen_w)
                -- navpager mode always has 4 centre tabs + 2 arrow slots = 6
                local ok_cfg, Config = pcall(require, "infra/sui_config")
                local n_center = (ok_cfg and Config and Config.NAVPAGER_CENTER_TABS) or 4
                local total_slots = n_center + 2
                local widths = Bottombar.getTabWidths(total_slots, usable_w)
                local prev_w = widths[1]
                local next_x = side_m + usable_w - widths[total_slots]
                local next_w = widths[total_slots]

                self._wrapper:registerTouchZones({
                    {
                        id          = "sui_win_navpager_prev",
                        ges         = "tap",
                        screen_zone = {
                            ratio_x = side_m / screen_w,
                            ratio_y = bar_y  / screen_h,
                            ratio_w = prev_w / screen_w,
                            ratio_h = nav_h  / screen_h,
                        },
                        handler = function(_ges)
                            -- In RTL the left physical zone is visually "next".
                            if BD.mirroredUILayout() then
                                if win._current_page < win._total_pages then
                                    win._current_page = win._current_page + 1
                                    win:_repaint()
                                end
                            else
                                if win._current_page > 1 then
                                    win._current_page = win._current_page - 1
                                    win:_repaint()
                                end
                            end
                            return true
                        end,
                    },
                    {
                        id          = "sui_win_navpager_next",
                        ges         = "tap",
                        screen_zone = {
                            ratio_x = next_x / screen_w,
                            ratio_y = bar_y  / screen_h,
                            ratio_w = next_w / screen_w,
                            ratio_h = nav_h  / screen_h,
                        },
                        handler = function(_ges)
                            -- In RTL the right physical zone is visually "prev".
                            if BD.mirroredUILayout() then
                                if win._current_page > 1 then
                                    win._current_page = win._current_page - 1
                                    win:_repaint()
                                end
                            else
                                if win._current_page < win._total_pages then
                                    win._current_page = win._current_page + 1
                                    win:_repaint()
                                end
                            end
                            return true
                        end,
                    },
                })
            end
        end
    end

    self:_repaint()
    -- Track this instance so getNavpagerState() can resolve _current_page.
    local instances = SUIWindow._open_instances
    instances[#instances + 1] = self
    UIManager:show(self._wrapper, "ui")
    -- Update navbar arrows after the wrapper is on the stack so getNavpagerState()
    -- already sees this SUIWindow and the widget tree is fully settled.
    UIManager:nextTick(function() self:_updateNavbarArrows() end)
end

--- Closes the window and returns to whatever opened it (see opts.on_back).
function SUIWindow:_goBack()
    self:close()
    if self._on_back then self._on_back() end
end

--- Closes the window.
function SUIWindow:close()
    self._closed = true
    -- Remove from open-instances tracking.
    local instances = SUIWindow._open_instances
    for i = #instances, 1, -1 do
        if instances[i] == self then table.remove(instances, i); break end
    end
    while #self._nav_stack > 1 do
        local popped = table.remove(self._nav_stack)
        if popped.params and type(popped.params.on_close) == "function" then
            pcall(popped.params.on_close)
        end
    end
    if self._on_close then
        pcall(self._on_close)
    end
    if self._wrapper then
        UIManager:close(self._wrapper)
        self._wrapper._sui_window_instance = nil  -- clear marker
    end

    -- Force a full paint of any underlying homescreen. The automatic
    -- lower-widget refresh after close honours widget.dithered and can
    -- compose from a partial frame that omits paintTo-only fills (module
    -- chrome). Clear the dither hint so this pass runs a complete paintTo;
    -- the next page/layout update will re-set it from cover presence.
    UIManager:nextTick(function()
        local stack = UIManager._window_stack
        if type(stack) ~= "table" then return end
        for i = #stack, 1, -1 do
            local w = stack[i] and stack[i].widget
            if w and w.name == "homescreen" then
                w.dithered = nil
                UIManager:setDirty(w, "ui")
                break
            end
        end
    end)

    -- After closing, restore navbar arrows to reflect the underlying widget's
    -- page state.  Deferred to nextTick so the wrapper is already off the stack
    -- when getNavpagerState() runs (otherwise it would still find this window).
    if self._navpager_mode then
        UIManager:nextTick(function()
            local ok_bb, Bottombar = pcall(require, "screens/sui_bottombar")
            if not ok_bb or not Bottombar then return end
            local ok_cfg, Config2 = pcall(require, "infra/sui_config")
            local has_prev, has_next = false, false
            if ok_cfg and Config2 and Config2.getNavpagerState then
                has_prev, has_next = Config2.getNavpagerState()
            end
            local patches = package.loaded["infra/sui_patches"]
            local target
            if patches and patches._getNavbarTarget then
                local fm_mod  = package.loaded["apps/filemanager/filemanager"]
                local fm_inst = fm_mod and fm_mod.instance
                target = patches._getNavbarTarget(fm_inst)
            else
                local UI = package.loaded["infra/sui_core"]
                local stack = UI and UI.getWindowStack and UI.getWindowStack()
                if stack then
                    for i = #stack, 1, -1 do
                        local w = stack[i] and stack[i].widget
                        if w and w._navbar_container then target = w; break end
                    end
                end
            end
            if not target then return end
            if not Bottombar.updateNavpagerArrows(target, has_prev, has_next) then
                local tabs = target._navbar_tabs or
                    (ok_cfg and Config2 and Config2.loadTabConfig and Config2.loadTabConfig()) or {}
                local mode = (ok_cfg and Config2 and Config2.getNavbarMode and
                    Config2.getNavbarMode()) or "icons"
                local FM = package.loaded["apps/filemanager/filemanager"]
                local plugin = FM and FM.instance and FM.instance._simpleui_plugin
                local active = plugin and plugin.active_action
                local new_bar = Bottombar.buildBarWidgetWithArrows(active, tabs, mode, has_prev, has_next)
                Bottombar.replaceBar(target, new_bar, tabs)
            end
            UIManager:setDirty(target, "ui")
        end)
    end
end

--- Runs fn() while holding an overlay lock so that onTapOutside cannot close
--- the window during a dialog.  Safe even if fn() throws.
--- @param fn function
function SUIWindow:withOverlay(fn)
    self._overlay_count = (self._overlay_count or 0) + 1
    local ok, err = pcall(fn)
    self._overlay_count = math.max(0, (self._overlay_count or 0) - 1)
    if not ok then
        logger.warn("SUIWindow:withOverlay — fn error: " .. tostring(err))
    end
end



-- ===========================================================================
-- SUIWindow — Navigation
-- ===========================================================================

function SUIWindow:_navCurrent()
    return self._nav_stack[#self._nav_stack]
end

function SUIWindow:_navPush(screen_id, params)
    -- Persist the current page so pop can restore it.
    local top = self._nav_stack[#self._nav_stack]
    if top then top._saved_page = self._current_page end
    table.insert(self._nav_stack, { id = screen_id, params = params or {} })
    self._current_page = 1
    self:_repaint()
end

function SUIWindow:_navPop(opts)
    if #self._nav_stack > 1 then
        local popped = table.remove(self._nav_stack)
        if popped.params and type(popped.params.on_close) == "function" then
            pcall(popped.params.on_close)
        end
    end
    -- Restore the page the user was on before they pushed into this sub-screen.
    local top = self._nav_stack[#self._nav_stack]
    self._current_page = (top and top._saved_page) or 1
    if opts and opts.to_last_page then
        self._force_last_page = true
    end
    self:_repaint()
end

-- ===========================================================================
-- SUIWindow — Repaint engine
-- ===========================================================================

-- Height reserved at the bottom of a paginated screen for the dot bar.
local function _dotBarH()
    return SZ(Screen:scaleBySize(28)) + SZ(Screen:scaleBySize(18))
end

--- Builds the TitleBar for the current ctx.
--- Title resolution order:
---   1. screen_titles[current_screen_id]  (per-screen override, string or fn)
---   2. opts.title                        (global fallback, string/fn/table)
--- @return widget, number  titlebar, height
function SUIWindow:_buildTitleBar(ctx)
    if self._no_titlebar then return nil, 0 end

    local frame_id = self:_navCurrent().id

    -- Resolve title value: per-screen override first, then global.
    local raw = self._screen_titles[frame_id] or self._title_opt
    local opt
    if type(raw) == "function" then
        opt = raw(ctx)
    else
        opt = raw
    end

    local title_str, title_icon
    if type(opt) == "table" then
        title_str  = opt.text or ""
        title_icon = opt.icon and SUIStyle.icon(opt.icon) or nil
    else
        title_str = tostring(opt or "")
    end

    local display_title = (title_icon and title_icon ~= "")
        and (title_icon .. "  " .. title_str)
        or  title_str

    local left_icon, left_cb
    local win = self
    if win._current_page > 1 then
        left_icon = "chevron.left"
        left_cb   = function()
            win._current_page = win._current_page - 1
            win:_repaint()
        end
    elseif #self._nav_stack > 1 then
        left_icon = "chevron.left"
        left_cb   = function() win:_navPop() end
    elseif win._on_back then
        left_icon = "chevron.left"
        left_cb   = function() win:_goBack() end
    end

    -- KOReader's TitleBar defaults to a fixed named face (x_smalltfont for
    -- fullscreen = false) when title_face isn't provided — a static point
    -- size that ignores SZ()/landscape_factor entirely, so the title stayed
    -- full-size while the rest of the modal's content shrunk around it in
    -- landscape. Passing an explicit title_face built through SZ() keeps it
    -- in step with everything else. FACE_BOLD/FS_TITLE is the pairing this
    -- codebase already documents for "titles that need weight".
    local tb = TitleBar:new{
        show_parent            = self._wrapper,
        title                  = display_title,
        title_face             = Font:getFace(SUIStyle.FACE_BOLD, SZ(SUIStyle.FS_TITLE)),
        width                  = self._inner_w,
        fullscreen             = false,
        align                  = "center",
        with_bottom_line       = true,
        bottom_line_color      = SUIStyle.COLOR.text_primary,
        left_icon              = left_icon,
        left_icon_tap_callback = left_cb,
        close_callback         = function() win:close() end,
    }

    return tb, tb:getHeight()
end

--- Tallest content one page of a paginated screen can hold: the modal's
--- maximum inner height minus the title bar and the dot bar. The title bar
--- height does not depend on the screen, so it is measured once per window.
--- Headers and footers a screen declares come off this value on top.
--- @return number
function SUIWindow:_maxPageHeight(ctx)
    if not self._title_h then
        local title_bar, title_h = self:_buildTitleBar(ctx)
        self._title_h = title_h
        if title_bar then title_bar:free() end
    end
    return self._modal_max_h - 2 * Size.border.window - self._pad_v
        - self._title_h - _dotBarH()
end

function SUIWindow:_rebuildFrame(ctx, items)
    local border  = Size.border.window
    local dot_h   = _dotBarH()
    local inner_h = self._modal_h - 2 * border - self._pad_v

    local tb, title_h = self:_buildTitleBar(ctx)
    self._title_bar_h = title_h

    local frame_id = self:_navCurrent().id

    -- same_screen_as_last_fit: true when this repaint is a dot-bar page
    -- swipe/tap — or just a content change, e.g. switching the Streak
    -- calendar to a taller month — within the SAME screen we last fit (not
    -- a fresh screen via _navPush/_navPop). This is the condition
    -- auto_height_per_page needs to keep re-fitting live, instead of only
    -- on the very first paint.
    local same_screen_as_last_fit = self._auto_height_per_page
        and self._last_fit_screen_id == frame_id
    self._last_fit_screen_id = frame_id

    local shrink_to_fit = self._auto_height and not self:_hasCornerBtn()
        and (not self._first_paint_done or same_screen_as_last_fit)

    local head_fn  = self._screen_headers[frame_id]
    local header_widget, header_h = nil, 0
    if head_fn then
        local ok, hw = pcall(head_fn, ctx)
        if ok and hw then
            header_widget = hw
            header_h      = hw:getSize().h
        end
    end

    local foot_fn  = self._screen_footers[frame_id]
    local footer_widget, footer_h = nil, 0
    if foot_fn then
        local ok, fw = pcall(foot_fn, ctx)
        if ok and fw then
            footer_widget = fw
            footer_h      = fw:getSize().h
        end
    end

    local cur = self:_navCurrent()
    local params = cur and cur.params or {}

    if not footer_widget and params.footer_action then
        local visible = true
        if type(params.footer_visible) == "function" then
            visible = params.footer_visible()
        elseif params.footer_visible ~= nil then
            visible = params.footer_visible
        end
        local c = type(params.item_count) == "function" and params.item_count() or params.item_count
        local m = type(params.max_items) == "function" and params.max_items() or params.max_items

        local enabled = true
        if type(params.footer_enabled) == "function" then
            enabled = params.footer_enabled()
        elseif params.footer_enabled ~= nil then
            enabled = params.footer_enabled
        elseif c and m then
            enabled = c < m
        end
        if visible then
            local f_text = params.footer_text or _("Add Item")
            if type(f_text) == "function" then f_text = f_text() end
            if c and m then
                f_text = f_text .. string.format("  (%d/%d)", c, m)
            end

            footer_widget = SUIWindow.CenteredButtonFooter(ctx, {
                text    = f_text,
                icon   = params.footer_icon,
                enabled = enabled,
                on_tap = function() params.footer_action(ctx) end,
            })
            footer_h = footer_widget:getSize().h
        end
    end

    -- avail_h is the ceiling _buildPages measures/paginates against. On a
    -- shrink_to_fit repaint we must measure against the window's real max
    -- headroom (_modal_max_h) rather than self._modal_h — self._modal_h may
    -- already be smaller than the max from a PREVIOUS fit (e.g. last
    -- month's shorter 5-row calendar), and measuring new, taller content
    -- against that stale, too-small ceiling makes it false-overflow into an
    -- extra dot-bar page instead of the window growing to fit it. On the
    -- very first fit ever, self._modal_h already equals self._modal_max_h
    -- (set together in :show()), so this changes nothing there.
    local avail_h
    if shrink_to_fit then
        local max_inner_h = self._modal_max_h - 2 * border - self._pad_v
        avail_h = max_inner_h - title_h - header_h - footer_h
    else
        avail_h = inner_h - title_h - header_h - footer_h
    end
    local req_dot_space = false
    -- fit_page_idx: which page (by index within THIS screen's pagination)
    -- gets sized to its natural content height instead of the full avail_h.
    -- Plain auto_height always means page 1 (self._current_page is 1 right
    -- after a fresh screen). auto_height_per_page instead points this at
    -- whichever page is actually about to be shown, so _buildPages sizes
    -- that page — not just page 1 — to its own content.
    local fit_page_idx = self._current_page
    local pages = self:_buildPages(items, avail_h, shrink_to_fit, fit_page_idx)
    local np    = #pages
    if np > 1 or self:_hasCornerBtn() then
        pages = self:_buildPages(items, avail_h - dot_h, shrink_to_fit, fit_page_idx)
        np    = #pages
        req_dot_space = true
    end

    self._total_pages  = np
    if self._force_last_page then
        self._current_page = np
        self._force_last_page = nil
    else
        self._current_page = math.max(1, math.min(self._current_page, np))
    end

    local page_widget  = pages[self._current_page] or VerticalSpan:new{ width = 0 }
    local content_block = VerticalGroup:new{ align = "left" }
    if tb then content_block[#content_block + 1] = tb end
    if header_widget then content_block[#content_block + 1] = header_widget end
    content_block[#content_block + 1] = page_widget

    local final_widget
    if req_dot_space then
        local dot_bar = self:_buildDotBar(np)
        if footer_widget then
            final_widget = VerticalGroup:new{ align = "left", content_block, footer_widget, dot_bar }
        else
            final_widget = VerticalGroup:new{ align = "left", content_block, dot_bar }
        end
    else
        if footer_widget then
            final_widget = VerticalGroup:new{ align = "left", content_block, footer_widget }
        else
            final_widget = content_block
        end
    end

    local corner_btn
    if self._has_settings_btn then
        corner_btn = {
            icon   = "appbar.settings",
            on_tap = function()
                self:close()
                require("screens/sui_settings_window"):show()
            end,
        }
    elseif self:_hasActionBtn() then
        local action = self._action_btn
        corner_btn = {
            glyph  = action.glyph,
            on_tap = function() action.on_tap(ctx) end,
        }
    end
    self._corner_btn_rect = nil
    if corner_btn then
        final_widget = OverlapGroup:new{
            dimen = Geom:new{ w = self._inner_w, h = inner_h },
            final_widget,
            self:_buildCornerButton(corner_btn, inner_h, dot_h),
        }
    end

    if shrink_to_fit then
        -- Shrink to whatever the fit page (fit_page_idx, above) actually
        -- holds — whether that's the ONLY page (np == 1, content fits
        -- within the max height), the first of several (np > 1, either
        -- because content genuinely overflows the max height, in which case
        -- content_h ends up close to avail_h anyway and wanted_h clamps
        -- back to modal_max_h below, or because a widget on that page was
        -- marked force_new_page — see _buildPages — in which case page 1
        -- can be deliberately smaller than the rest, e.g. the Streak
        -- window's calendar-only first page), or — with auto_height_per_page
        -- — whichever page the user has since swiped/tapped to.
        local extra = req_dot_space and dot_h or 0
        local content_h = page_widget:getSize().h
        local wanted_h = 2 * border + self._pad_v + title_h + header_h + footer_h + content_h + extra
        local min_h = title_h + SZ(Screen:scaleBySize(96))
        wanted_h = math.max(min_h, math.min(wanted_h, self._modal_max_h))
        if math.abs(wanted_h - self._modal_h) > 1 then
            local mf = self._modal_frame
            self._modal_h = wanted_h
            mf.dimen.h = wanted_h
            local new_x = mf.overlap_offset and mf.overlap_offset[1] or 0
            local new_y
            if self._position == "top" then
                new_y = self._top_h_cache + Size.padding.small
            elseif self._position == "bottom" and self._bot_h_cache > 0 then
                new_y = self._screen_h - self._bot_h_cache - wanted_h - Size.padding.small
            else
                new_y = math.floor((self._screen_h - wanted_h) / 2)
            end
            mf.overlap_offset = { new_x, new_y }

            -- Flags _repaint to do a full-screen "all"/"partial" refresh
            -- instead of the usual self._wrapper/"ui" one — see the
            -- reasoning in _repaint, right where this flag is read.
            self._pending_resize_dirty_rect = true
        end
    end

    self._modal_frame[1] = final_widget
end

function SUIWindow:_repaint()
    if self._closed then return end
    _sui_scale = self._scale
    local win   = self
    local frame = self:_navCurrent()
    logger.dbg("SUIWindow:_repaint screen='" .. tostring(frame.id) .. "'")

    -- D-pad focus registry: rebuilt fresh every repaint (screens rebuild
    -- their whole widget tree every time, same as everything else here).
    -- The focus index itself only resets when the screen actually changed
    -- (nav push/pop), so it survives a same-screen repaint (e.g. toggling a
    -- checkbox) instead of jumping back to the first row. Generic screen ids
    -- like "row_page" can be pushed more than once in the same nav_stack
    -- (different params at different depths), so id alone isn't a reliable
    -- "did the screen change" signal — pair it with nav_stack depth, which
    -- always changes on push/pop but never on an in-place repaint.
    --
    -- _kb_focus_active mirrors upstream KOReader's FocusManager convention
    -- (FOCUS_ONLY_ON_NT): the focus highlight stays hidden until the user
    -- actually drives the D-pad, so touch input on a hasDPad+touch device
    -- doesn't show a highlight box no one asked for. It resets alongside the
    -- focus index on a real screen change and flips true the first time
    -- onKbFocusUp/onKbFocusDown fires.
    local nav_depth = #self._nav_stack
    if self._kb_last_screen_id ~= frame.id or self._kb_last_nav_depth ~= nav_depth then
        self._kb_focus_idx = 1
        self._kb_focus_active = false
        self._kb_last_screen_id  = frame.id
        self._kb_last_nav_depth  = nav_depth
    end
    self._kb_focus_count = 0
    self._kb_focusables   = {}

    local ctx = {
        inner_w       = self._inner_w,
        pad           = self._pad_h,
        -- Universal landscape-aware size multiplier: same SZ()/_sui_scale
        -- used for this window's own chrome (frame, title bar), handed to
        -- every screen builder for free. Any screen — existing or new —
        -- gets correct-by-construction scaling on ctx.SZ(n) with zero setup:
        -- no require("infra/sui_core"), no per-file "local function SZ(n) ... end"
        -- boilerplate, and no risk of drifting from the chrome's own factor.
        SZ            = SZ,
        current       = function() return win:_navCurrent() end,
        push          = function(id, params) win:_navPush(id, params) end,
        pop           = function(opts)
            local cur_id = win:_navCurrent().id
            if cur_id == "item_picker" or cur_id == "module_picker" then
                opts = opts or {}
                if opts.to_last_page == nil then
                    opts.to_last_page = true
                end
            end
            win:_navPop(opts)
        end,
        repaint       = function() win:_repaint() end,
        close         = function() win:close() end,
        jump_to_last_page = function() win._force_last_page = true end,
        withOverlay   = function(fn) win:withOverlay(fn) end,
        lockOverlay   = function() win._overlay_count = (win._overlay_count or 0) + 1 end,
        unlockOverlay = function() win._overlay_count = math.max(0, (win._overlay_count or 0) - 1) end,
        addSwipe      = function(ic)
            if not Device:isTouchDevice() then return end
            ic.ges_events = ic.ges_events or {}
            ic.ges_events.SwipeFooter = {
                GestureRange:new{
                    ges   = "swipe",
                    range = function() return ic.dimen end,
                }
            }
            function ic:onSwipeFooter(_, ges)
                local dir = ges.direction
                if dir == "west" and win._current_page < win._total_pages then
                    win._current_page = win._current_page + 1
                    win:_repaint()
                    return true
                elseif dir == "east" and win._current_page > 1 then
                    win._current_page = win._current_page - 1
                    win:_repaint()
                    return true
                end
                return false
            end
        end,
    }

    ctx.page_h = self:_maxPageHeight(ctx)

    _kbPush(self)

    local build_fn = self._screens[frame.id]
    local items = {}
    if build_fn then
        local ok, result = pcall(build_fn, ctx)
        if ok and type(result) == "table" then
            items = result
        elseif not ok then
            logger.warn("SUIWindow: builder error [" .. tostring(frame.id) .. "]: " .. tostring(result))
        else
            logger.warn("SUIWindow: builder [" .. tostring(frame.id) .. "] returned " .. type(result))
        end
    else
        logger.warn("SUIWindow: no builder for screen '" .. tostring(frame.id) .. "'")
    end

    -- _rebuildFrame stays inside the build bracket too: it builds the footer
    -- button and title-bar buttons, which also go through Input.tapable and
    -- should be reachable by keyboard focus, not just the screen's own rows.
    self:_rebuildFrame(ctx, items)
    _kbPop()

    if self._kb_focus_idx and #self._kb_focusables > 0 then
        self._kb_focus_idx = math.min(self._kb_focus_idx, #self._kb_focusables)
    end

    self._first_paint_done = true

    -- Keep page_num in sync so _callPageFn sees the correct total.
    if self._navpager_mode and self._wrapper then
        self._wrapper.page_num = self._total_pages
        -- Only update arrow colours on subsequent repaints (page turns).
        -- The initial repaint during show() runs before UIManager:show() adds
        -- the wrapper to the stack, so we defer that first update to nextTick
        -- in show().  Once the wrapper is on the stack we update directly.
        if UIManager._window_stack then
            local on_stack = false
            for i = #UIManager._window_stack, 1, -1 do
                if UIManager._window_stack[i] and
                   UIManager._window_stack[i].widget == self._wrapper then
                    on_stack = true; break
                end
            end
            if on_stack then self:_updateNavbarArrows() end
        end
    end

    if self._wrapper then
        local mf = self._modal_frame
        local did_resize = self._pending_resize_dirty_rect
        self._pending_resize_dirty_rect = nil
        if did_resize then
            -- A resize (auto_height / auto_height_per_page) moves/resizes
            -- the modal by mutating mf.dimen.h and mf.overlap_offset in
            -- place rather than rebuilding the frame from scratch, and the
            -- rounded FrameContainer corner doesn't come out clean from
            -- that — visible as artifacts right at the edge/corner where the
            -- box moved, on top of the plain leftover-pixel gap issue (see
            -- the "all" reasoning below). A full-screen partial refresh
            -- sidesteps both: it's the same one the window's own first
            -- paint already does, just re-triggered on every resize instead
            -- of only once. Targeting "all" (same pattern as sui_style.lua)
            -- rather than just self._wrapper also makes sure whatever sits
            -- underneath (homescreen, or another screen) actually repaints
            -- in the area the modal no longer covers after shrinking —
            -- _wrapper itself is transparent there by design, so its own
            -- repaint never touches it, and UIManager's occlusion check
            -- otherwise assumes that area doesn't need redrawing at all.
            UIManager:setDirty("all", "partial")
        else
            UIManager:setDirty(self._wrapper, function()
                return "ui", mf.dimen
            end)
        end
    end
end

-- ===========================================================================
-- SUIWindow — Pagination
-- ===========================================================================

-- Updates the navpager arrow colours on the underlying fullscreen widget to
-- reflect this window's current page position.  Safe to call at any time
-- after the _wrapper is on the UIManager stack.
function SUIWindow:_updateNavbarArrows()
    if not self._navpager_mode then return end
    local ok_bb, Bottombar = pcall(require, "screens/sui_bottombar")
    if not ok_bb or not Bottombar then return end

    local has_prev = self._current_page > 1
    local has_next = self._current_page < self._total_pages

    -- Find the fullscreen widget that owns the navbar bar.
    -- Use _getNavbarTarget from sui_patches if available (matches existing logic),
    -- otherwise fall back to walking the stack for _navbar_container.
    local target
    local patches = package.loaded["infra/sui_patches"]
    if patches and patches._getNavbarTarget then
        local fm_mod  = package.loaded["apps/filemanager/filemanager"]
        local fm_inst = fm_mod and fm_mod.instance
        target = patches._getNavbarTarget(fm_inst)
    else
        local UI = package.loaded["infra/sui_core"]
        local stack = UI and UI.getWindowStack and UI.getWindowStack()
        if stack then
            for i = #stack, 1, -1 do
                local w = stack[i] and stack[i].widget
                if w and w ~= self._wrapper and w._navbar_container then
                    target = w; break
                end
            end
        end
    end

    if not target then return end

    if not Bottombar.updateNavpagerArrows(target, has_prev, has_next) then
        -- Bar structure unrecognised — full rebuild.
        local ok_cfg, Config2 = pcall(require, "infra/sui_config")
        local tabs = target._navbar_tabs or
            (ok_cfg and Config2 and Config2.loadTabConfig and Config2.loadTabConfig()) or {}
        local mode = (ok_cfg and Config2 and Config2.getNavbarMode and
            Config2.getNavbarMode()) or "icons"
        local new_bar = Bottombar.buildBarWidgetWithArrows(nil, tabs, mode, has_prev, has_next)
        Bottombar.replaceBar(target, new_bar, tabs)
    end
    UIManager:setDirty(target, "ui")
end

function SUIWindow:_buildPages(widgets, avail_h, shrink_to_fit, fit_page_idx)
    fit_page_idx = fit_page_idx or 1
    -- Restores the separators in case the function is called more than once
    -- (e.g. recalculating pagination to accommodate the dots).
    for _, w in ipairs(widgets) do
        if w.is_list_row_with_sep and w._orig_sep then
            w[2] = w._orig_sep
            w._orig_sep = nil
        end
    end

    local pages  = {}
    local page_heights = {}
    local cur_vg = VerticalGroup:new{ align = "left" }
    local cur_h  = 0
    table.insert(pages, cur_vg)

    for _, w in ipairs(widgets) do
        local wh = w:getSize().h
        if w.force_new_page and cur_h > 0 then
            -- Explicit page break: this widget must always start
            -- a new page, regardless of whether it fits in the remaining
            -- space of the current page (e.g. the "Streak" window forces
            -- page 1 to hold only the calendar). Different from the normal
            -- overflow below, which only breaks when the content actually doesn't fit.
            local last_w = cur_vg[#cur_vg]
            if last_w and last_w.is_list_row_with_sep then
                if not last_w._orig_sep then last_w._orig_sep = last_w[2] end
                last_w[2] = VerticalSpan:new{ width = 0 }
            end
            page_heights[#pages] = cur_h
            cur_vg = VerticalGroup:new{ align = "left" }
            table.insert(pages, cur_vg)
            cur_h = 0
        elseif cur_h + wh > avail_h and cur_h > 0 then
            local last_w = cur_vg[#cur_vg]
            -- Prevents a section from being left orphaned at the bottom of the page.
            -- If the last widget inserted was a section, and there are other items
            -- before it on the same page, we move the section to the new page.
            if last_w and last_w.is_section and #cur_vg > 1 then
                table.remove(cur_vg)
                local real_last = cur_vg[#cur_vg]
                if real_last and real_last.is_list_row_with_sep then
                    if not real_last._orig_sep then real_last._orig_sep = real_last[2] end
                    real_last[2] = VerticalSpan:new{ width = 0 }
                end
                page_heights[#pages] = cur_h - last_w:getSize().h
                cur_vg = VerticalGroup:new{ align = "left" }
                table.insert(pages, cur_vg)
                table.insert(cur_vg, last_w)
                cur_h = last_w:getSize().h
            else
                if last_w and last_w.is_list_row_with_sep then
                    if not last_w._orig_sep then last_w._orig_sep = last_w[2] end
                    last_w[2] = VerticalSpan:new{ width = 0 }
                end
                page_heights[#pages] = cur_h
                cur_vg = VerticalGroup:new{ align = "left" }
                table.insert(pages, cur_vg)
                cur_h = 0
            end
        end
        table.insert(cur_vg, w)
        cur_h = cur_h + wh
    end
    page_heights[#pages] = cur_h

    local last_w = cur_vg[#cur_vg]
    if last_w and last_w.is_list_row_with_sep then
        if not last_w._orig_sep then last_w._orig_sep = last_w[2] end
        last_w[2] = VerticalSpan:new{ width = 0 }
    end

    local inner_w = self._inner_w
    local total_p = #pages
    -- When shrink_to_fit is requested, size the fit_page_idx page's tap/paint
    -- area to the content it actually holds (page_heights[fit_page_idx])
    -- instead of the full avail_h, so the caller can shrink the window to
    -- match. fit_page_idx is 1 for plain auto_height (page 1 is the ONLY
    -- page, or just the first of several because a widget was marked
    -- force_new_page — see the loop above), or the currently-shown page for
    -- auto_height_per_page. Every OTHER page still gets the full avail_h:
    -- once the window has shrunk to the fit page's height on the very next
    -- repaint, avail_h itself will already be the right value if/when that
    -- other page becomes the current one.
    for i, vg in ipairs(pages) do
        local area_h
        if shrink_to_fit and i == fit_page_idx then
            area_h = math.min(avail_h, page_heights[fit_page_idx] or avail_h)
        else
            area_h = avail_h
        end
        local area = InputContainer:new{
            dimen = Geom:new{ w = inner_w, h = area_h },
            [1]   = vg,
        }
        area.ges_events = {}
        if total_p > 1 and Device:isTouchDevice() then
            area.ges_events.SwipePage = {
                GestureRange:new{
                    ges   = "swipe",
                    range = function() return area.dimen end,
                }
            }
            local win = self
            function area:onSwipePage(_, ges)
                local dir = ges.direction
                if dir == "west" and win._current_page < win._total_pages then
                    win._current_page = win._current_page + 1
                    win:_repaint()
                    return true
                elseif dir == "east" and win._current_page > 1 then
                    win._current_page = win._current_page - 1
                    win:_repaint()
                    return true
                end
                return false
            end
        end
        pages[i] = area
    end

    return pages
end

-- ===========================================================================
-- SUIWindow — Dot bar
-- ===========================================================================

local _PageDotClass

local function _getPageDotClass()
    if _PageDotClass then return _PageDotClass end
    local BaseWidget = require("ui/widget/widget")
    _PageDotClass = BaseWidget:extend{
        current_page = 1,
        total_pages  = 1,
        dot_size     = SZ(Screen:scaleBySize(7)),
        dot_bar_h    = SZ(Screen:scaleBySize(28)),
        dot_touch_w  = SZ(Screen:scaleBySize(32)),
    }
    function _PageDotClass:getSize()
        return Geom:new{ w = self.total_pages * self.dot_touch_w, h = self.dot_bar_h }
    end
    function _PageDotClass:paintTo(bb, x, y)
        local r       = math.floor(self.dot_size / 2)
        local cy      = y + math.floor(self.dot_bar_h / 2)
        local clr_on  = SUIStyle.COLOR.text_primary
        local clr_off = SUIStyle.COLOR.text_dim
        for i = 1, self.total_pages do
            local cx = x + (i - 1) * self.dot_touch_w + math.floor(self.dot_touch_w / 2)
            bb:paintCircle(cx, cy, r, i == self.current_page and clr_on or clr_off)
        end
    end
    return _PageDotClass
end

-- True when the current screen shows the action button (root screen only).
function SUIWindow:_hasActionBtn()
    return self._action_btn ~= nil and #self._nav_stack == 1
end

-- True when a corner button occupies the page-dot row on the current screen.
function SUIWindow:_hasCornerBtn()
    return self._has_settings_btn or self:_hasActionBtn()
end

-- Corner controls and toolbar buttons share one size and corner radius.
local function _cornerSize()   return SZ(Screen:scaleBySize(40)) end
local function _cornerRadius() return SZ(Screen:scaleBySize(8)) end

--- Bordered square button with an icon-font glyph or an SVG icon. Its tap
--- target extends slightly past the border.
---
--- @param opts table
---   on_tap  function  — required
---   glyph   string    — icon-font text, from SUIStyle.icon()
---   icon    string    — SVG icon name, used when no glyph is given
---
--- @return InputContainer
function SUIWindow.SquareButton(opts)
    local btn_size  = _cornerSize()
    local border_sz = SUIStyle.BORDER_SZ
    local content_w = btn_size - border_sz * 2

    local content
    if opts.glyph then
        content = TextWidget:new{
            text    = opts.glyph,
            face    = Font:getFace(SUIStyle.FACE_ICONS, SZ(SUIStyle.FS_TITLE)),
            fgcolor = SUIStyle.COLOR.text_primary,
        }
    else
        local icon_size = math.floor(btn_size * 0.70)
        content = require("ui/widget/iconwidget"):new{
            icon   = opts.icon,
            width  = icon_size,
            height = icon_size,
        }
    end

    local btn = InputContainer:new{
        dimen = Geom:new{ w = btn_size, h = btn_size },
        [1]   = FrameContainer:new{
            dimen      = Geom:new{ w = btn_size, h = btn_size },
            radius     = _cornerRadius(),
            bordersize = border_sz,
            background = SUIStyle.COLOR.surface,
            color      = SUIStyle.COLOR.gray,
            padding    = 0,
            [1]        = CenterContainer:new{
                dimen = Geom:new{ w = content_w, h = content_w },
                [1]   = content,
            },
        },
    }
    btn.ges_events = {
        TapCorner = {
            GestureRange:new{ ges = "tap", range = function()
                local d = btn.dimen
                local p = SZ(Screen:scaleBySize(20))
                return Geom:new{ x = d.x - p, y = d.y - p, w = d.w + p * 2, h = d.h + p * 2 }
            end },
        },
    }
    function btn:onTapCorner()
        opts.on_tap()
        return true
    end
    return btn
end

-- Anchors a square button to the bottom-right corner of the inner area,
-- vertically centred in the page-dot row. `spec` is a SquareButton spec. The
-- button's horizontal span is recorded so the dot bar lets taps on it through.
function SUIWindow:_buildCornerButton(spec, inner_h, dot_h)
    local btn      = SUIWindow.SquareButton(spec)
    local btn_size = btn.dimen.w
    local offset_x = self._inner_w - btn_size
    local offset_y = inner_h - dot_h + math.floor((dot_h - btn_size) / 2)
    btn.overlap_offset = { offset_x, offset_y }
    self._corner_btn_rect = { x = offset_x, w = btn_size }
    return btn
end

function SUIWindow:_buildDotBar(total_pages)
    local DOT_H   = SZ(Screen:scaleBySize(28))
    local LABEL_H = SZ(Screen:scaleBySize(18))
    local total_h = LABEL_H + DOT_H

    if total_pages <= 1 then
        if self:_hasCornerBtn() then
            return VerticalSpan:new{ width = total_h }
        end
        return VerticalSpan:new{ width = 0 }
    end

    local TOUCH_W = SZ(Screen:scaleBySize(32))

    local label_face = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_CAPTION))
    local label_text = TextWidget:new{
        text    = T(_("Page %1 of %2"), self._current_page, total_pages),
        face    = label_face,
        fgcolor = SUIStyle.COLOR.text_primary,
    }
    local label_centered = CenterContainer:new{
        dimen = Geom:new{ w = self._inner_w, h = LABEL_H },
        [1]   = label_text,
    }

    local dot = _getPageDotClass():new{
        current_page = self._current_page,
        total_pages  = total_pages,
        dot_size     = SZ(Screen:scaleBySize(7)),
        dot_bar_h    = DOT_H,
        dot_touch_w  = TOUCH_W,
    }
    local dot_sz  = dot:getSize()
    dot.dimen     = Geom:new{ w = dot_sz.w, h = dot_sz.h }

    local dot_centered = CenterContainer:new{
        dimen = Geom:new{ w = self._inner_w, h = DOT_H },
        [1]   = FrameContainer:new{
            bordersize = 0, padding = 0,
            dimen      = Geom:new{ w = dot_sz.w, h = dot_sz.h },
            [1]        = dot,
        },
    }

    local total_h = LABEL_H + DOT_H
    local stacked = VerticalGroup:new{
        align = "center",
        dot_centered,
        label_centered,
    }
    stacked.dimen = Geom:new{ w = self._inner_w, h = total_h }

    if not Device:isTouchDevice() then
        return stacked
    end

    local bar = InputContainer:new{
        dimen         = Geom:new{ w = self._inner_w, h = total_h },
        _dot          = dot,
        _dot_sz       = dot_sz,
        _inner_w      = self._inner_w,
        _dot_touch_w  = TOUCH_W,
        _total_pages  = total_pages,
        [1]           = stacked,
    }
    bar.ges_events = {
        TapDot   = { GestureRange:new{ ges = "tap",   range = function() return bar.dimen end } },
        SwipeDot = { GestureRange:new{ ges = "swipe", range = function() return bar.dimen end } },
    }
    local win = self
    function bar:onTapDot(_, ges)
        if not self.dimen then return false end
        if ges.pos.y >= self.dimen.y + DOT_H then return false end
        -- Taps on a corner button belong to the button, not to the dots.
        local rect = win._corner_btn_rect
        if rect then
            local pad   = SZ(Screen:scaleBySize(20))
            local abs_x = self.dimen.x + rect.x
            if ges.pos.x >= abs_x - pad and ges.pos.x <= abs_x + rect.w + pad then
                return false
            end
        end
        local bar_x = self.dimen.x + math.floor((self._inner_w - self._dot_sz.w) / 2)
        local idx   = math.floor((ges.pos.x - bar_x) / self._dot_touch_w) + 1
        idx = math.max(1, math.min(idx, self._total_pages))
        -- In RTL the dots are rendered right-to-left, so mirror the index.
        if BD.mirroredUILayout() then
            idx = self._total_pages - idx + 1
        end
        if idx ~= win._current_page then
            win._current_page = idx
            win:_repaint()
        end
        return true
    end
    function bar:onSwipeDot(_, ges)
        local dir = ges.direction
        -- Mirror swipe direction for RTL layouts.
        if BD.mirroredUILayout() then
            if dir == "west" then dir = "east" elseif dir == "east" then dir = "west" end
        end
        if dir == "west" and win._current_page < win._total_pages then
            win._current_page = win._current_page + 1
            win:_repaint()
            return true
        elseif dir == "east" and win._current_page > 1 then
            win._current_page = win._current_page - 1
            win:_repaint()
            return true
        end
        return false
    end

    return bar
end

-- ===========================================================================
-- SUIWindow.Input — input helpers
-- ===========================================================================

SUIWindow.Input = {}

--- Wraps a widget in an InputContainer with tap and/or hold gestures.
--- @param widget   table     — KOReader widget with :getSize()
--- @param handlers table     — { on_tap: function?, on_hold: function? }
--- @param dimen    Geom|nil
--- @return InputContainer
function SUIWindow.Input.tapable(widget, handlers, dimen)
    dimen = dimen or Geom:new{ w = widget:getSize().w, h = widget:getSize().h }

    -- D-pad focus auto-registration (see _kbPush/_kbCurrent above). Only
    -- tap-driven items participate — matches the existing convention
    -- elsewhere in this file that a disabled row simply has no tap_fn.
    -- on_hold-only items aren't reachable this way yet (v1 scope).
    --
    -- The highlight frame itself only renders once _kb_focus_active is set
    -- (see the _repaint/onKbFocusUp/onKbFocusDown comments), so it stays
    -- hidden until the user actually presses Up/Down — same as upstream
    -- KOReader's FocusManager on touch+D-pad devices.
    if handlers.on_tap and Device:hasDPad() then
        local win = _kbCurrent()
        if win then
            win._kb_focus_count = (win._kb_focus_count or 0) + 1
            local my_idx = win._kb_focus_count
            win._kb_focusables[my_idx] = handlers.on_tap
            if win._kb_focus_idx == my_idx and win._kb_focus_active then
                widget = FrameContainer:new{
                    dimen      = Geom:new{ w = dimen.w, h = dimen.h },
                    bordersize = SUIStyle.BORDER_SZ * 2,
                    radius     = SZ(Screen:scaleBySize(6)),
                    color      = SUIStyle.COLOR.text_primary,
                    padding    = 0,
                    widget,
                }
            end
        end
    end

    local ic = InputContainer:new{ dimen = dimen, [1] = widget }
    ic.ges_events = {}

    if handlers.on_tap then
        ic.ges_events.Tap = {
            GestureRange:new{ ges = "tap", range = function() return ic.dimen end }
        }
        function ic:onTap()
            handlers.on_tap()
            return true
        end
    end

    if handlers.on_hold then
        ic.ges_events.Hold = {
            GestureRange:new{ ges = "hold", range = function() return ic.dimen end }
        }
        function ic:onHold()
            handlers.on_hold()
            return true
        end
    end

    return ic
end

--- Creates a tappable icon button.
--- @param opts table  icon, size, color, on_tap, w, h
--- @return InputContainer
function SUIWindow.Input.iconButton(opts)
    local sz  = opts.size  or SZ(Screen:scaleBySize(SUIStyle.FS_DETAIL))
    local w   = opts.w     or sz * 2
    local h   = opts.h     or sz
    local clr = opts.color or SUIStyle.COLOR.text_primary

    local ic = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
        [1]   = CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            TextWidget:new{
                text    = SUIStyle.icon(opts.icon),
                face    = Font:getFace(SUIStyle.FACE_ICONS, sz),
                fgcolor = clr,
            },
        },
    }
    ic.ges_events = {
        TapIconButton = {
            GestureRange:new{ ges = "tap", range = function() return ic.dimen end }
        },
    }
    function ic:onTapIconButton()
        if opts.on_tap then opts.on_tap() end
        return true
    end

    return ic
end

-- ===========================================================================
-- Component helpers (module-private)
-- ===========================================================================

local function _clrPrimary()   return SUIStyle.COLOR.text_primary end
local function _clrSecondary() return SUIStyle.COLOR.text_dim end
local function _clrSeparator() return SUIStyle.COLOR.gray_strong end

local function _facePrimary()
    return Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_BODY))
end
local function _faceSecondary()
    return Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_CAPTION))
end
local function _faceIcon()
    return Font:getFace(SUIStyle.FACE_ICONS, SZ(SUIStyle.FS_TITLE))
end
local function _faceChevron()
    return Font:getFace(SUIStyle.FACE_ICONS, SZ(SUIStyle.FS_BODY))
end

local function _CHEVRON_W() return SZ(Screen:scaleBySize(20)) end
local function _ITEM_VPAD() return SZ(Screen:scaleBySize(16)) end

-- ===========================================================================
-- SUIWindow.ListRow
-- ===========================================================================

--- List row with title, optional subtitle and icons.
--- Use for menu/navigation items (tap → push or action).
---
--- @param opts table
---   inner_w      number        — required
---   title        string
---   subtitle     string|nil
---   left_icon    string|nil    — SUIStyle icon key
---   left_widget  widget|nil    — custom widget before the title (e.g. an icon
---                                preview); takes precedence over left_icon
---   right_icon   string|nil
---   right_value  string|nil    — current value label before the chevron
---   right_widget widget|nil    — custom widget before the chevron
---   checked      bool|nil      — nil=no checkbox; true/false=check/uncheck
---   show_chevron bool          — default false
---   title_face   Face|nil      — override font face for the title text
---   on_delete    function|nil
---   on_tap       function|nil
---   on_hold      function|nil
---   separator    bool          — separator line below (default true)
---
--- @return VerticalGroup | InputContainer
function SUIWindow.ListRow(opts)
    assert(opts.inner_w, "SUIWindow.ListRow: inner_w is required")

    local c = type(opts.item_count) == "function" and opts.item_count() or opts.item_count
    local m = type(opts.max_items) == "function" and opts.max_items() or opts.max_items
    if c and m then
        opts.right_value = string.format("(%d/%d)", c, m)
    end

    local inner_w    = opts.inner_w
    local has_delete = opts.on_delete ~= nil
    local has_edit   = opts.on_edit ~= nil
    local has_update = opts.on_update ~= nil
    local has_more   = opts.on_more ~= nil or (type(opts.more_items) == "table" and #opts.more_items > 0)
    local has_value  = opts.right_value and opts.right_value ~= ""
    local has_right_widget = opts.right_widget ~= nil
    local has_right  = has_delete or has_edit or has_update or has_more or opts.show_chevron or opts.checked ~= nil or opts.right_icon or has_value or has_right_widget

    local del_w   = has_delete and (_CHEVRON_W() * 2) or 0
    local edit_w  = has_edit and (_CHEVRON_W() * 2) or 0
    local upd_w   = has_update and (_CHEVRON_W() * 2) or 0
    local more_w  = has_more   and (_CHEVRON_W() * 2) or 0
    local val_w   = has_value and SZ(Screen:scaleBySize(120)) or 0
    local widget_w = 0
    if has_right_widget then
        local sz = type(opts.right_widget.getSize) == "function" and opts.right_widget:getSize() or opts.right_widget.dimen
        widget_w = sz and sz.w or 0
    end
    local extra_w = (opts.show_chevron or opts.checked ~= nil or opts.right_icon) and _CHEVRON_W() or 0
    local left_w  = math.max(1, inner_w - del_w - edit_w - upd_w - more_w - val_w - widget_w - extra_w)

    local left_vg = VerticalGroup:new{ align = "left" }
    local is_disabled = (opts.enabled == false) or (opts.dim == true)
    -- dim_only: purely visual muting (e.g. "excluded from goals" rows in
    -- Year in Review) — unlike dim/enabled=false, it must NOT strip on_tap,
    -- since the row still needs to be tappable (e.g. to reach the toggle
    -- that excluded it in the first place). Kept as a separate flag rather
    -- than reusing `dim` so existing "genuinely disabled" callers elsewhere
    -- (e.g. MenuTable's grayed-out/unavailable items) keep their current,
    -- correct behaviour untouched.
    local is_dim_visual = is_disabled or (opts.dim_only == true)
    local fg_color = is_dim_visual and _clrSecondary() or _clrPrimary()

    -- opts.title_face overrides the default UI font (used e.g. by font-picker
    -- entries to render each row in the font it represents).
    local title_face = opts.title_face or _facePrimary()

    local title_widget
    if opts.left_widget then
        local lw_sz = type(opts.left_widget.getSize) == "function" and opts.left_widget:getSize() or opts.left_widget.dimen
        local lw_w  = (lw_sz and lw_sz.w) or 0
        local lw_gap = SZ(Screen:scaleBySize(8))
        title_widget = HorizontalGroup:new{ align = "center",
            opts.left_widget,
            HorizontalSpan:new{ width = lw_gap },
            TextWidget:new{
                text      = opts.title,
                face      = title_face,
                fgcolor   = fg_color,
                bold      = true,
                max_width = math.max(1, left_w - lw_w - lw_gap),
            },
        }
    elseif opts.left_icon and opts.left_icon ~= "" then
        title_widget = HorizontalGroup:new{ align = "center",
            TextWidget:new{
                text    = SUIStyle.icon(opts.left_icon),
                face    = _faceIcon(),
                fgcolor = _clrSecondary(),
            },
            TextWidget:new{ text = "  ", face = _facePrimary() },
            TextWidget:new{
                text      = opts.title,
                face      = title_face,
                fgcolor   = fg_color,
                bold      = true,
                max_width = left_w,
            },
        }
    else
        title_widget = TextWidget:new{
            text      = opts.title,
            face      = title_face,
            fgcolor   = fg_color,
            bold      = true,
            max_width = left_w,
        }
    end
    table.insert(left_vg, title_widget)

    local sub = type(opts.subtitle) == "function" and opts.subtitle() or opts.subtitle
    if sub and sub ~= "" then
        table.insert(left_vg, VerticalSpan:new{ width = SZ(Screen:scaleBySize(4)) })
        table.insert(left_vg, TextWidget:new{
            text                   = sub,
            face                   = _faceSecondary(),
            fgcolor                = fg_color,
            max_width              = left_w,
            truncate_with_ellipsis = true,
        })
    end

    local left_h = left_vg:getSize().h

    local row_hg = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{
            dimen = Geom:new{ w = left_w, h = left_h },
            left_vg,
        },
    }

    if has_right then
        local right_hg = HorizontalGroup:new{ align = "center" }

        if has_update then
            table.insert(right_hg, SUIWindow.Input.iconButton{
                icon   = "update",
                w      = _CHEVRON_W() * 2,
                h      = left_h,
                on_tap = opts.on_update,
            })
        end

        if has_edit then
            table.insert(right_hg, SUIWindow.Input.iconButton{
                icon   = "edit",
                w      = _CHEVRON_W() * 2,
                h      = left_h,
                on_tap = opts.on_edit,
            })
        end

        if has_delete then
            table.insert(right_hg, SUIWindow.Input.iconButton{
                icon   = "delete",
                w      = _CHEVRON_W() * 2,
                h      = left_h,
                on_tap = opts.on_delete,
            })
        end

        if has_more then
            local more_ic
            more_ic = InputContainer:new{
                dimen = Geom:new{ w = _CHEVRON_W() * 2, h = left_h },
                [1]   = CenterContainer:new{
                    dimen = Geom:new{ w = _CHEVRON_W() * 2, h = left_h },
                    TextWidget:new{
                        text    = SUIStyle.icon("more"),
                        face    = Font:getFace(SUIStyle.FACE_ICONS, SZ(Screen:scaleBySize(SUIStyle.FS_DETAIL))),
                        fgcolor = _clrPrimary(),
                    },
                },
            }
            more_ic.ges_events = {
                TapMore = {
                    GestureRange:new{ ges = "tap", range = function() return more_ic.dimen end }
                },
            }
            local _on_more = opts.on_more
            if not _on_more and type(opts.more_items) == "table" then
                _on_more = function(anchor_dimen)
                    SUIWindow.ActionMenu{
                        anchor = anchor_dimen,
                        items  = opts.more_items,
                    }
                end
            end
            function more_ic:onTapMore()
                _on_more(self.dimen)
                return true
            end
            table.insert(right_hg, more_ic)
        end

        if has_value then
            table.insert(right_hg, RightContainer:new{
                dimen = Geom:new{ w = val_w, h = left_h },
                TextWidget:new{
                    text                   = opts.right_value,
                    face                   = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_DETAIL)),
                    fgcolor                = _clrPrimary(),
                    max_width              = val_w,
                    alignment              = "right",
                    truncate_with_ellipsis = true,
                },
            })
        end

        if has_right_widget then
            table.insert(right_hg, CenterContainer:new{
                dimen = Geom:new{ w = widget_w, h = left_h },
                [1]   = opts.right_widget,
            })
        end

        if opts.checked ~= nil then
            table.insert(right_hg, RightContainer:new{
                dimen = Geom:new{ w = _CHEVRON_W(), h = left_h },
                TextWidget:new{
                    text      = SUIStyle.icon(opts.checked and "check" or "uncheck"),
                    face      = _faceIcon(),
                    fgcolor   = _clrPrimary(),
                    alignment = "right",
                },
            })
        elseif opts.right_icon and opts.right_icon ~= "" then
            table.insert(right_hg, RightContainer:new{
                dimen = Geom:new{ w = _CHEVRON_W(), h = left_h },
                TextWidget:new{
                    text      = SUIStyle.icon(opts.right_icon),
                    face      = _faceIcon(),
                    fgcolor   = _clrSecondary(),
                    alignment = "right",
                },
            })
        elseif opts.show_chevron then
            table.insert(right_hg, RightContainer:new{
                dimen = Geom:new{ w = _CHEVRON_W(), h = left_h },
                HorizontalGroup:new{ align = "center",
                    HorizontalSpan:new{ width = SZ(Screen:scaleBySize(6)) },
                    TextWidget:new{
                        text      = SUIStyle.icon("chevron"),
                        face      = _faceChevron(),
                        fgcolor   = _clrPrimary(),
                        alignment = "right",
                    },
                },
            })
        end

        table.insert(row_hg, right_hg)
    end

    local row_padded = FrameContainer:new{
        bordersize     = 0,
        padding        = 0,
        padding_top    = _ITEM_VPAD(),
        padding_bottom = _ITEM_VPAD(),
        row_hg,
    }

    local item_widget
    local on_hold = opts.on_hold
    if not on_hold and opts.show_hold_menu then
        local hold_items = {}
        if opts.on_tap then
            table.insert(hold_items, { text = _("Select"), icon = "check", on_tap = opts.on_tap })
        end
        if type(opts.more_items) == "table" then
            for _, item in ipairs(opts.more_items) do
                table.insert(hold_items, item)
            end
        end
        if opts.on_update then
            table.insert(hold_items, { text = _("Update"), icon = "update", on_tap = opts.on_update })
        end
        if opts.on_edit then
            table.insert(hold_items, { text = _("Rename"), icon = "edit", on_tap = opts.on_edit })
        end
        if opts.on_delete then
            table.insert(hold_items, { text = _("Delete"), icon = "delete", on_tap = opts.on_delete })
        end
        
        if #hold_items > 0 then
            on_hold = function()
                local buttons = {}
                local dialog
                for _, item in ipairs(hold_items) do
                    local label = item.text or ""
                    if item.icon and item.icon ~= "" then
                        local glyph = SUIStyle.icon(item.icon)
                        if glyph ~= "" then label = glyph .. "  " .. label end
                    end
                    table.insert(buttons, {{
                        text      = label,
                        align     = "left",
                        font_face = SUIStyle.FACE_REGULAR,
                        font_size = SZ(SUIStyle.FS_BODY),
                        font_bold = true,
                        dim       = item.dim,
                        callback  = function()
                            UIManager:close(dialog)
                            if item.on_tap then item.on_tap() end
                        end,
                    }})
                end
                local dialog_w = SZ(math.floor(Screen:getWidth() * 0.42))
                dialog = ButtonDialog:new{
                    title              = opts.title,
                    width              = dialog_w,
                    buttons            = buttons,
                    tap_close_callback = function() UIManager:close(dialog) end,
                }
                UIManager:show(dialog)
            end
        end
    end

    local tap_fn = not is_disabled and opts.on_tap or nil
    local hold_fn = not is_disabled and on_hold or nil

    if tap_fn or hold_fn then
        item_widget = SUIWindow.Input.tapable(
            row_padded,
            { on_tap = tap_fn, on_hold = hold_fn },
            Geom:new{ w = inner_w, h = row_padded:getSize().h }
        )
    else
        item_widget = row_padded
    end

    if opts.separator == false then
        return item_widget
    end
    local vg = VerticalGroup:new{
        align = "left",
        item_widget,
        LineWidget:new{
            dimen      = Geom:new{ w = inner_w, h = Size.line.thin },
            background = _clrSeparator(),
        },
    }
    vg.is_list_row_with_sep = true
    return vg
end

-- ===========================================================================
-- SUIWindow.Button
-- ===========================================================================

--- Button with centred text and optional icon.
---
--- @param opts table
---   inner_w    number      — required
---   text       string
---   icon       string|nil
---   on_tap     function
---   width      number|nil  — overrides inner_w
---   align      string|nil  — "left", "center" (default), "right"
---   margin_top bool        — VerticalSpan above (default true)
---
--- @return VerticalGroup | InputContainer
function SUIWindow.Button(opts)
    assert(opts.inner_w, "SUIWindow.Button: inner_w is required")

    local btn_w     = opts.width or opts.inner_w
    local face      = _facePrimary()
    local prefix    = opts.icon and (SUIStyle.icon(opts.icon) .. "  ") or ""
    local align     = opts.align or "center"
    local pad_left  = (align == "left")  and 0 or _ITEM_VPAD()
    local pad_right = (align == "right") and 0 or _ITEM_VPAD()
    local text_max_w = btn_w - pad_left - pad_right
    local is_disabled = opts.enabled == false

    local text_w = TextWidget:new{
        text                   = prefix .. (opts.text or ""),
        face                   = face,
        fgcolor                = is_disabled and _clrSecondary() or _clrPrimary(),
        bold                   = true,
        max_width              = text_max_w,
        alignment              = align,
        truncate_with_ellipsis = true,
    }

    local container_dimen = Geom:new{ w = text_max_w, h = face.size }
    local aligned_text
    if align == "left" then
        aligned_text = LeftContainer:new{ dimen = container_dimen, text_w }
    elseif align == "right" then
        aligned_text = RightContainer:new{ dimen = container_dimen, text_w }
    else
        aligned_text = CenterContainer:new{
            dimen = Geom:new{ w = btn_w, h = face.size },
            text_w,
        }
    end

    local frame = FrameContainer:new{
        bordersize     = 0,
        padding        = 0,
        padding_top    = _ITEM_VPAD(),
        padding_bottom = _ITEM_VPAD(),
        padding_left   = pad_left,
        padding_right  = pad_right,
        dimen          = Geom:new{ w = btn_w, h = face.size + _ITEM_VPAD() * 2 },
        aligned_text,
    }

    local tappable
    if not is_disabled and opts.on_tap then
        tappable = SUIWindow.Input.tapable(
            frame,
            { on_tap = opts.on_tap },
            Geom:new{ w = btn_w, h = frame.dimen.h }
        )
    else
        tappable = frame
    end

    if opts.width then return tappable end
    if opts.margin_top == false then return tappable end
    return VerticalGroup:new{
        VerticalSpan:new{ width = _ITEM_VPAD() },
        tappable,
    }
end

-- ===========================================================================
-- SUIWindow.Section
-- ===========================================================================

--- Section header widget.  Children are optional — Section can be used as a
--- standalone label or as a grouping container.
---
--- @param opts table
---   inner_w   number    — required
---   title     string
---   children  widget[]  — optional
---
--- @return VerticalGroup
function SUIWindow.Section(opts)
    assert(opts.inner_w, "SUIWindow.Section: inner_w is required")

    local vg = VerticalGroup:new{ align = "left" }
    vg.is_section = true

    if opts.title and opts.title ~= "" then
        table.insert(vg, VerticalSpan:new{ width = SZ(Screen:scaleBySize(16)) })
        table.insert(vg, TextWidget:new{
            text      = opts.title:upper(),
            face      = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_DETAIL)),
            fgcolor   = _clrSecondary(),
            bold      = true,
            max_width = opts.inner_w,
        })
        table.insert(vg, VerticalSpan:new{ width = SZ(Screen:scaleBySize(8)) })
    end

    for _, child in ipairs(opts.children or {}) do
        table.insert(vg, child)
    end

    return vg
end

function SUIWindow.SectionLabel(opts)
    opts.title = opts.title or opts.text
    return SUIWindow.Section(opts)
end

-- ===========================================================================
-- SUIWindow.PeriodHeader
-- ===========================================================================

--- Period selector: a centred label with a chevron on each side, next to it.
--- Chevrons of a disabled direction are dimmed and inert.
---
--- @param opts table
---   inner_w       number    — required
---   label         string    — required, the current period
---   prev_enabled  bool
---   next_enabled  bool
---   on_prev       function()
---   on_next       function()
---   compact       bool      — smaller label and chevrons, for selectors that
---                             sit above other content
---
--- @return CenterContainer
function SUIWindow.PeriodHeader(opts)
    assert(opts.inner_w and opts.label, "SUIWindow.PeriodHeader: inner_w and label are required")

    local compact   = opts.compact == true
    local btn_w     = SZ(Screen:scaleBySize(compact and 44 or 60))
    local gap       = SZ(Screen:scaleBySize(8))
    local CLR_BLACK = SUIStyle.COLOR.text_primary
    local face      = Font:getFace(SUIStyle.FACE_REGULAR,
        SZ(compact and SUIStyle.FS_BODY or SUIStyle.FS_SUBTITLE))
    local face_chev = Font:getFace(SUIStyle.FACE_ICONS,
        math.floor(SZ(SUIStyle.FS_TITLE * (compact and 1.3 or 1.8))))

    local label = TextWidget:new{
        text      = opts.label,
        face      = face,
        fgcolor   = CLR_BLACK,
        bold      = true,
        padding   = 0,
        max_width = opts.inner_w - 2 * (btn_w + gap),
    }
    local row_h = label:getSize().h

    -- The glyph sits against the label-facing edge of its touch area.
    local function navBtn(glyph, enabled, cb, Align)
        local btn = InputContainer:new{
            dimen = Geom:new{ w = btn_w, h = row_h },
            Align:new{
                dimen = Geom:new{ w = btn_w, h = row_h },
                TextWidget:new{
                    text    = glyph,
                    face    = face_chev,
                    fgcolor = enabled and CLR_BLACK or SUIStyle.COLOR.disabled,
                    padding = 0,
                },
            },
        }
        if enabled then
            btn.ges_events = {
                Tap = { GestureRange:new{ ges = "tap",
                    range = function() return btn.dimen end } },
            }
            function btn:onTap() cb(); return true end
        end
        return btn
    end

    return CenterContainer:new{
        dimen = Geom:new{ w = opts.inner_w, h = row_h },
        HorizontalGroup:new{ align = "center",
            navBtn("\u{E840}", opts.prev_enabled, opts.on_prev, RightContainer),
            HorizontalSpan:new{ width = gap },
            label,
            HorizontalSpan:new{ width = gap },
            navBtn("\u{E841}", opts.next_enabled, opts.on_next, LeftContainer),
        },
    }
end

-- ===========================================================================
-- SUIWindow.PeriodDropdown
-- ===========================================================================

--- Period selector shown as a pill (icon, current label, chevron). Tapping it
--- lists the options next to the pill, the current one marked, or hands the
--- pill's rect to `on_open` for a custom popup. With a single option and no
--- `on_open` the pill is static.
---
--- Either `options` + `selected` or `label` + `on_open` must be given.
---
--- @param opts table
---   options    table[]   — { value, text } in display order
---   selected   any       — `value` of the current option
---   on_select  function(value) — called when a different option is picked
---   label      string    — pill text; defaults to the selected option's text
---   on_open    function(anchor) — replaces the option list; receives the
---                          pill's Geom
---   icon       string    — SUIStyle icon key (default "calendar_select")
---   inner_w    number    — row width to centre the pill in; without it the
---                          pill is returned on its own
---   compact    bool      — gives the pill the height and corner radius of a
---                          SquareButton, for use beside one in a ToolbarRow
---
--- @return CenterContainer | InputContainer | FrameContainer
function SUIWindow.PeriodDropdown(opts)
    assert((opts.options and opts.selected ~= nil) or (opts.label and opts.on_open),
        "SUIWindow.PeriodDropdown: options + selected, or label + on_open, are required")

    local options    = opts.options or {}
    local selectable = opts.on_open ~= nil or #options > 1
    local color      = SUIStyle.COLOR.text_primary
    local face       = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_SUBTITLE))
    local face_icon  = Font:getFace(SUIStyle.FACE_ICONS, SZ(SUIStyle.FS_SUBTITLE))
    local gap        = SZ(Screen:scaleBySize(10))
    local pad_v      = SZ(Screen:scaleBySize(8))
    local pad_h      = SZ(Screen:scaleBySize(16))

    local label = opts.label
    if not label then
        label = tostring(opts.selected)
        for _, option in ipairs(options) do
            if option.value == opts.selected then
                label = option.text
                break
            end
        end
    end

    local function iconWidget(name)
        return TextWidget:new{
            text    = SUIStyle.icon(name),
            face    = face_icon,
            fgcolor = color,
            padding = 0,
        }
    end

    local content = HorizontalGroup:new{ align = "center",
        iconWidget(opts.icon or "calendar_select"),
        HorizontalSpan:new{ width = gap },
        TextWidget:new{ text = label, face = face, fgcolor = color, bold = true, padding = 0 },
    }
    if selectable then
        table.insert(content, HorizontalSpan:new{ width = gap })
        table.insert(content, iconWidget("chevron_down"))
    end

    -- A compact pill spreads the spare height evenly above and below the content.
    local pad_top, pad_bottom = pad_v, pad_v
    if opts.compact then
        local spare = math.max(0, _cornerSize() - 2 * SUIStyle.BORDER_SZ - content:getSize().h)
        pad_top    = math.floor(spare / 2)
        pad_bottom = spare - pad_top
    end

    local pill = FrameContainer:new{
        bordersize     = SUIStyle.BORDER_SZ,
        color          = SUIStyle.COLOR.gray,
        background     = SUIStyle.COLOR.surface,
        radius         = opts.compact and _cornerRadius() or SZ(Screen:scaleBySize(12)),
        padding        = 0,
        padding_top    = pad_top,
        padding_bottom = pad_bottom,
        padding_left   = pad_h,
        padding_right  = pad_h,
        content,
    }

    local trigger = pill
    if selectable then
        local function openMenu()
            if opts.on_open then
                opts.on_open(trigger.dimen)
                return
            end
            local items = {}
            for _, option in ipairs(options) do
                items[#items + 1] = {
                    text    = option.text,
                    checked = option.value == opts.selected,
                    on_tap  = function()
                        if option.value ~= opts.selected then opts.on_select(option.value) end
                    end,
                }
            end
            local anchor = trigger.dimen
            SUIWindow.ActionMenu{
                anchor = anchor,
                items  = items,
                align  = "center",
                width  = anchor.w,
            }
        end
        trigger = SUIWindow.Input.tapable(pill, { on_tap = openMenu })
    end

    if not opts.inner_w then return trigger end
    return CenterContainer:new{
        dimen = Geom:new{ w = opts.inner_w, h = pill:getSize().h },
        trigger,
    }
end

-- ===========================================================================
-- SUIWindow.MonthPicker
-- ===========================================================================

local MONTH_PICKER_COLS = 3

local function _monthOrdinal(ym) return ym.year * 12 + ym.month end

--- Floating month chooser hung below a trigger: a year header with a chevron
--- on each side, over a grid of month names. The selected month is inverted;
--- months outside [first, last] are dimmed and inert. Years are browsed in
--- place. A tap outside the panel, or the Back key, dismisses it.
---
--- @param opts table
---   anchor     Geom                    — rect of the trigger; the panel is
---                                        centred under it, or above it when
---                                        there is no room below
---   selected   { year, month }         — current month; its year opens first
---   first      { year, month }         — earliest selectable month
---   last       { year, month }         — latest selectable month
---   on_select  function(year, month)   — called when a different month is picked
function SUIWindow.MonthPicker(opts)
    local anchor, selected = opts.anchor, opts.selected
    local first_ord, last_ord = _monthOrdinal(opts.first), _monthOrdinal(opts.last)
    local month_names = DateNames.monthShort()
    local shown_year  = selected.year

    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local margin   = SZ(Screen:scaleBySize(8))
    local gap      = SZ(Screen:scaleBySize(4))
    local pad      = SZ(Screen:scaleBySize(8))
    local border   = SUIStyle.BORDER_SZ
    local cell_h   = SZ(Screen:scaleBySize(44))
    local inset    = SZ(Screen:scaleBySize(3))
    local panel_w  = math.min(screen_w - 2 * margin,
        math.max(anchor.w, SZ(Screen:scaleBySize(280))))
    local cell_w   = math.floor((panel_w - 2 * (pad + border)) / MONTH_PICKER_COLS)
    local face     = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_BODY))
    local face_nav = Font:getFace(SUIStyle.FACE_ICONS, SZ(SUIStyle.FS_SUBTITLE))

    local popup = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h },
    }

    -- Wraps `widget` in a tap target when `on_tap` is given; a nil handler
    -- leaves the widget inert.
    local function target(widget, on_tap)
        if not on_tap then return widget end
        return SUIWindow.Input.tapable(widget, { on_tap = on_tap })
    end

    local function navButton(glyph, on_tap)
        return target(CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = cell_h },
            TextWidget:new{
                text    = SUIStyle.icon(glyph),
                face    = face_nav,
                fgcolor = on_tap and SUIStyle.COLOR.text_primary or SUIStyle.COLOR.disabled,
                padding = 0,
            },
        }, on_tap)
    end

    local function monthCell(month)
        local ordinal    = shown_year * 12 + month
        local enabled    = ordinal >= first_ord and ordinal <= last_ord
        local is_current = shown_year == selected.year and month == selected.month

        local fgcolor = SUIStyle.COLOR.text_primary
        if is_current then fgcolor = SUIStyle.COLOR.surface
        elseif not enabled then fgcolor = SUIStyle.COLOR.disabled end

        local pill = FrameContainer:new{
            bordersize = 0,
            background = is_current and SUIStyle.COLOR.text_primary or nil,
            radius     = SZ(Screen:scaleBySize(8)),
            padding    = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = cell_w - 2 * inset, h = cell_h - 2 * inset },
                TextWidget:new{
                    text = month_names[month], face = face, fgcolor = fgcolor,
                    bold = is_current, padding = 0,
                },
            },
        }
        local cell = CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = cell_h },
            pill,
        }
        return target(cell, enabled and function()
            UIManager:close(popup)
            if not is_current then opts.on_select(shown_year, month) end
        end or nil)
    end

    local build   -- forward-declared: year navigation rebuilds the panel

    local function showYear(year)
        shown_year = year
        build()
    end

    local function buildPanel()
        local header = HorizontalGroup:new{ align = "center",
            navButton("chevron_left", shown_year > opts.first.year and function()
                showYear(shown_year - 1)
            end or nil),
            CenterContainer:new{
                dimen = Geom:new{ w = (MONTH_PICKER_COLS - 2) * cell_w, h = cell_h },
                TextWidget:new{
                    text = tostring(shown_year), face = face,
                    fgcolor = SUIStyle.COLOR.text_primary, bold = true, padding = 0,
                },
            },
            navButton("chevron", shown_year < opts.last.year and function()
                showYear(shown_year + 1)
            end or nil),
        }

        local grid = VerticalGroup:new{ align = "left", header }
        for row_start = 1, 12, MONTH_PICKER_COLS do
            local row = HorizontalGroup:new{ align = "center" }
            for month = row_start, row_start + MONTH_PICKER_COLS - 1 do
                table.insert(row, monthCell(month))
            end
            table.insert(grid, row)
        end

        return FrameContainer:new{
            bordersize = border,
            color      = SUIStyle.COLOR.gray,
            background = SUIStyle.COLOR.surface,
            radius     = SZ(Screen:scaleBySize(12)),
            padding    = pad,
            margin     = 0,
            grid,
        }
    end

    -- Positions the panel against the anchor and swaps it into the popup.
    function build()
        local panel = buildPanel()
        local size  = panel:getSize()
        local x = math.max(margin, math.min(screen_w - size.w - margin,
            anchor.x + math.floor((anchor.w - size.w) / 2)))
        local y = anchor.y + anchor.h + gap
        if y + size.h > screen_h - margin then
            y = math.max(margin, anchor.y - gap - size.h)
        end

        local previous = popup[1]
        popup.panel_rect = Geom:new{ x = x, y = y, w = size.w, h = size.h }
        popup[1] = VerticalGroup:new{ align = "left",
            VerticalSpan:new{ width = y },
            HorizontalGroup:new{ HorizontalSpan:new{ width = x }, panel },
        }
        if previous then
            previous:free()
            UIManager:setDirty(popup, function() return "ui", popup.panel_rect end)
        end
    end

    popup.ges_events = {
        TapClose = { GestureRange:new{ ges = "tap", range = popup.dimen } },
    }
    -- Taps inside the panel that miss a month are swallowed; everything else
    -- dismisses it. The popup always consumes the tap so nothing underneath
    -- reacts.
    function popup:onTapClose(_, ges)
        if not ges.pos:intersectWith(self.panel_rect) then UIManager:close(self) end
        return true
    end

    if Device:hasKeys() then
        popup.key_events = { Close = { { "Back" } } }
        function popup:onClose()
            UIManager:close(self)
            return true
        end
    end

    function popup:onShow()
        UIManager:setDirty(self, function() return "ui", self.panel_rect end)
    end

    function popup:onCloseWidget()
        UIManager:setDirty(nil, function() return "ui", self.panel_rect end)
    end

    build()
    UIManager:show(popup)
end

--- Month selector shown as a pill labelled "<Month> <Year>" that opens a
--- MonthPicker.
---
--- @param opts table
---   selected   { year, month }         — required, current month
---   first      { year, month }         — required, earliest selectable month
---   last       { year, month }         — required, latest selectable month
---   on_select  function(year, month)   — called when a different month is picked
---   inner_w    number                  — see PeriodDropdown
---   compact    bool                    — see PeriodDropdown
---
--- @return CenterContainer | InputContainer | FrameContainer
function SUIWindow.MonthDropdown(opts)
    local selected = opts.selected
    return SUIWindow.PeriodDropdown{
        inner_w = opts.inner_w,
        compact = opts.compact,
        label   = DateNames.monthFull()[selected.month] .. " " .. selected.year,
        on_open = function(anchor)
            SUIWindow.MonthPicker{
                anchor    = anchor,
                selected  = selected,
                first     = opts.first,
                last      = opts.last,
                on_select = opts.on_select,
            }
        end,
    }
end

-- ===========================================================================
-- SUIWindow.ToolbarRow
-- ===========================================================================

--- Row of controls shown above a list, closed by a separator line. Meant for
--- a screen header: `left` sits flush left and `right` flush right, each
--- centred vertically in the row.
---
--- @param opts table
---   inner_w  number       — required
---   left     widget|nil   — e.g. a compact PeriodDropdown
---   right    widget|nil   — e.g. a SquareButton
---
--- @return VerticalGroup
function SUIWindow.ToolbarRow(opts)
    assert(opts.inner_w, "SUIWindow.ToolbarRow: inner_w is required")

    local row_h = _cornerSize()
    local gap   = SZ(Screen:scaleBySize(10))
    local row   = OverlapGroup:new{ dimen = Geom:new{ w = opts.inner_w, h = row_h } }

    local function place(widget, x_for)
        if not widget then return end
        local size = widget:getSize()
        widget.overlap_offset = { x_for(size.w), math.floor((row_h - size.h) / 2) }
        row[#row + 1] = widget
    end
    place(opts.left,  function() return 0 end)
    place(opts.right, function(w) return opts.inner_w - w end)

    return VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = gap },
        row,
        VerticalSpan:new{ width = gap },
        LineWidget:new{
            dimen      = Geom:new{ w = opts.inner_w, h = Size.line.thin },
            background = _clrSeparator(),
        },
    }
end

-- ===========================================================================
-- SUIWindow.MenuTable
-- ===========================================================================

--- Converts KOReader-style menu items into SUIWindow ListRow widgets.
---
--- ── Standard KOReader item fields consumed ──────────────────────────────────
---   text / text_func        string | () → string   — row label
---   enabled / enabled_func  bool   | () → bool     — false = hide row completely in SUIWindow
---   sui_hidden              bool   | () → bool     — dynamic hide (re-evaluated on each build)
---   font_func               (size) → Face | nil    — custom font face for the title (e.g. font-picker rows)
---   checked_func            () → bool              — checkbox state
---   dim                     bool                   — true = show row but grayed out (inactive)
---   value_func              () → string            — right-side value label
---   sub_item_table          table[]                — static sub-menu
---   sub_item_table_func     () → table[]           — dynamic sub-menu
---   callback                function               — tap action
---   keep_menu_open          bool                   — don't close after callback
---   separator               bool                   — visual separator hint
---                                                    (ignored here, KOReader only)
---
--- ── Row title vs. right-side value ───────────────────────────────────────────
--- A row's text/text_func is its LABEL and must stay static (e.g. "Sort",
--- "Grid size", "Long Press") — it must never be built by concatenating the
--- current choice into it (e.g. "Sort: Title (A–Z)", "Grid: 4 × 1"). A
--- dynamic choice belongs only on the right side of the row, via:
---
---   1. value_func        () → string   — SUIWindow's right-side value.
---                                        ALWAYS wins when present, no
---                                        matter what the row's
---                                        sub_item_table(_func) looks like
---                                        (plain radios, plain callbacks, or
---                                        none at all). Prior to a fix, this
---                                        was silently ignored whenever the
---                                        row had a sub-menu that wasn't
---                                        made of direct `radio = true`
---                                        children (e.g.
---                                        Config.makeCoverHoldModeItem's
---                                        "Long Press" row, whose two-option
---                                        sub-menu uses plain checked_func
---                                        without radio=true) — always set
---                                        value_func explicitly rather than
---                                        relying on inference (2) whenever
---                                        the sub-menu isn't literally a flat
---                                        radio list.
---
---   2. Automatic inference (SUIWindow only, no code needed) — if a row has
---                                        no value_func and its
---                                        sub_item_table(_func) is made of
---                                        plain `radio = true` children with
---                                        `checked_func`, SUIWindow reads the
---                                        checked child's label and shows it
---                                        on the right automatically.
---
---   3. mandatory_func    () → string   — the native (non-SUIWindow)
---                                        KOReader Menu's right-side value.
---                                        SUIWindow does not read this field
---                                        at all — set it alongside
---                                        value_func (same computation) on
---                                        any row that must also look right
---                                        outside a SUIWindow context.
---
--- This applies everywhere a settings row shows a persisted/selected value
--- — sort modes, styles, sizes, etc. — in every place items built this way
--- are rendered: the native KOReader settings menu (screens/sui_menu.lua),
--- the SUI Settings Window screens (screens/sui_settings_window.lua), and a
--- module's long-press settings (ScreenWidget:_openModuleSettingsFor, which
--- builds from the exact same mod.getMenuItems() and renders through this
--- same SUIWindow.MenuTable) — since all three share one item table, fixing
--- a row here fixes it in all three places at once.
---
--- ── SUIWindow extension fields ───────────────────────────────────────────────
--- These two fields are only meaningful when the item is being rendered inside
--- a SUIWindow.  They are invisible to the native KOReader menu system, which
--- simply ignores unknown keys.
---
---   sui_hidden   bool | () → bool
---       When true (or when the function returns true) the item is completely
---       omitted from the SUIWindow list.  It still appears in the native menu.
---       Use this to hide items that are redundant, not yet adapted, or that
---       only make sense in the full KOReader menu context.
---
---       Example — hide a "Restart KOReader" shortcut that is redundant inside
---       the settings window:
---
---           {
---               text     = _("Restart"),
---               callback = function() UIManager:restartKOReader() end,
---               sui_hidden = true,   -- shown in native menu, hidden in SUIWindow
---           }
---
---       Example — hide conditionally:
---
---           {
---               text       = _("Advanced option"),
---               callback   = function() ... end,
---               sui_hidden = function() return not developer_mode end,
---           }
---
---   sui_build   (ctx, item) → widget | widget[]
---       Custom renderer for this item inside a SUIWindow.  Receives the
---       SUIWindow build context (ctx.inner_w, ctx.push, ctx.repaint, …) and
---       the raw item table, and must return either a single widget or an array
---       of widgets.  When present, the default ListRow rendering is completely
---       bypassed.  The native KOReader menu is unaffected.
---
---       The ctx argument is the MenuTable build context table, which contains:
---           ctx.inner_w        number   — available width in px
---           ctx.push(id,params)         — navigate to a named screen
---           ctx.repaint()               — redraw the window
---           ctx.lockOverlay()           — suppress onTapOutside (use before
---           ctx.unlockOverlay()           showing a dialog over the window)
---
---       Example — replace a boring sub-menu of radio items with an inline
---       toggle row, without touching the native menu:
---
---           {
---               text           = _("Font weight"),
---               sub_item_table = { ... radio items ... },   -- native menu
---               sui_build = function(ctx, item)
---                   return SUIWindow.ListRow{
---                       inner_w     = ctx.inner_w,
---                       title       = _("Font weight"),
---                       right_value = Config.getFontWeight(),
---                       on_tap      = function()
---                           Config.cycleFontWeight()
---                           ctx.repaint()
---                       end,
---                   }
---               end,
---           }
---
---       Example — replace a sub-menu with an inline arrange list:
---
---           {
---               text                = _("Tab order"),
---               sub_item_table_func = function() return buildTabItems() end,
---               sui_build = function(ctx, item)
---                   local items = buildTabItems()
---                   return SUIWindow.ArrangeList{
---                       inner_w   = ctx.inner_w,
---                       items     = items,
---                       on_change = function() saveTabOrder(items) ctx.repaint() end,
---                   }
---               end,
---           }
---
---       Example — flatten a sub-menu directly into the parent list (no push):
---
---           {
---               text           = _("Quick toggles"),   -- native: opens sub-menu
---               sub_item_table = { toggle_a, toggle_b, toggle_c },
---               sui_build = function(ctx, item)
---                   -- render the children inline, no navigation needed
---                   return SUIWindow.MenuTable{
---                       inner_w    = ctx.inner_w,
---                       items      = item.sub_item_table,
---                       push_stack = ctx.push_stack,
---                       repaint    = ctx.repaint,
---                   }
---               end,
---           }
---
--- ── How to use the extension fields in practice ───────────────────────────
--- Menu-builder functions (makeNavbarMenu, makeTopbarMenu, …) already receive
--- a ctx_menu table.  When called from a SUIWindow, ctx_menu.is_sui == true.
--- Branch on that flag to attach sui_build / sui_hidden only when needed:
---
---   local function makeNavbarMenu(ctx_menu)
---       return {
---           {
---               text     = _("Size"),
---               value_func = function() return Config.getBarSizePct().."%"  end,
---               callback = function() showSpinWidget() end,   -- native spinner
---               -- in SUIWindow, show an inline slider row instead:
---               sui_build = ctx_menu.is_sui and function(ctx, item)
---                   return SUIWindow.ListRow{
---                       inner_w     = ctx.inner_w,
---                       title       = _("Size"),
---                       right_value = Config.getBarSizePct().."%",
---                       on_tap      = function() showSpinWidget(); ctx.repaint() end,
---                   }
---               end or nil,
---           },
---           {
---               text       = _("Advanced"),
---               sub_item_table = { ... },
---               -- too complex for SUIWindow, hide it there:
---               sui_hidden = ctx_menu.is_sui or nil,
---           },
---       }
---   end
---
--- @param opts table
---   inner_w        number
---   items          table[]
---   on_close       function|nil
---   push_stack     function|nil   — (_, {title, items, items_func}) for sub-menu nav
---   repaint        function|nil
---   lock_overlay   function|nil
---   unlock_overlay function|nil
---
--- @return widget[]
function SUIWindow.MenuTable(opts)
    assert(opts.inner_w, "SUIWindow.MenuTable: inner_w is required")

    local inner_w  = opts.inner_w
    local push     = opts.push_stack
    local repaint  = opts.repaint  or function() end
    local on_close = opts.on_close or function() end
    local result   = {}

    -- Build context passed to sui_build callbacks so they have everything
    -- they need without depending on the outer closure directly.
    local build_ctx = {
        inner_w        = inner_w,
        SZ             = SZ,  -- same universal scale multiplier as the outer screen ctx
        push           = push        or function() end,
        push_stack     = push        or function() end,   -- alias
        repaint        = repaint,
        lockOverlay    = opts.lock_overlay   or function() end,
        unlockOverlay  = opts.unlock_overlay or function() end,
    }

    for _, item in ipairs(opts.items or {}) do

        -- ── sui_hidden: skip this item entirely in SUIWindow ──────────────
        local hidden = item.sui_hidden
        if type(hidden) == "function" then
            local ok, v = pcall(hidden)
            hidden = ok and v
        end
        if hidden then goto continue end

        -- ── Standard visibility / enabled checks ──────────────────────────
        local title = type(item.text_func) == "function" and item.text_func() or item.text
        if not title or title == "" then goto continue end

        if type(item.enabled_func) == "function" and not item.enabled_func() then
            goto continue
        end

        -- ── sui_build: fully custom widget for this item ──────────────────
        if type(item.sui_build) == "function" then
            local ok, widget = pcall(item.sui_build, build_ctx, item)
            if ok and widget then
                -- Arrays of widgets returned by ArrangeList or other builders
                -- are plain tables without a getSize method, while standard
                -- WidgetContainers (like VerticalGroup) expose getSize.
                if type(widget) == "table" and type(widget.getSize) ~= "function" then
                    for _, w in ipairs(widget) do
                        table.insert(result, w)
                    end
                else
                    table.insert(result, widget)
                end
            end
            goto continue
        end

        -- ── is_title: render as Section header instead of ListRow ─────────
    if item.is_title or item.is_divider then
            local title_clean = title:gsub("──%s*", ""):gsub("%s*──", "")
            table.insert(result, SUIWindow.Section{
                title   = title_clean,
                inner_w = inner_w,
            })
            goto continue
        end

        -- In SUIWindow, items that are explicitly disabled (`enabled = false`)
        -- are hidden completely. To show an inactive/grayed-out item, use `dim = true`.
        if item.enabled == false then
            goto continue
        end

        -- ── Default rendering: ListRow ────────────────────────────────────
        local is_disabled = (item.dim == true)

        local checked
        if type(item.checked_func) == "function" then
            -- NOTE: intentionally a truthy check, not `== true`.
            -- Some upstream KOReader plugins (e.g. CoverBrowser's
            -- BookInfoManager) persist settings in a SQLite-backed
            -- config table where booleans are round-tripped through
            -- TEXT columns, so checked_func() can return the *string*
            -- "true" instead of the boolean `true` (native KOReader's
            -- TouchMenu just does `self.item.checked_func()` and relies
            -- on truthiness, which is why the toggle "works" there).
            -- A strict `== true` comparison silently fails for any
            -- such truthy-but-not-boolean value, leaving the checkbox
            -- visually unchecked even though the setting is actually on.
            local ok, chk = pcall(item.checked_func)
            checked = (ok and chk) and true or false
        end

        local show_chevron = not is_disabled
                          and (item.sub_item_table or item.sub_item_table_func) ~= nil

        local right_value
        if type(item.value_func) == "function" then
            -- An explicit value_func always wins, regardless of whether the
            -- row also has a sub_item_table(_func) and regardless of what
            -- that sub-menu looks like (radio or plain callback items) — a
            -- developer who wrote value_func always meant for it to be
            -- shown. (Previously gated behind `sub == nil or
            -- _hasDirectRadios()`, which silently dropped value_func for
            -- any row whose sub-menu wasn't made of direct `radio = true`
            -- children — e.g. Config.makeCoverHoldModeItem's "Long Press"
            -- row, whose two-option sub-menu uses plain checked_func
            -- without radio=true.)
            local ok, v = pcall(item.value_func)
            if ok and v then right_value = tostring(v) end
        elseif item.sub_item_table_func ~= nil or item.sub_item_table ~= nil then
            -- Inferred from the sub-menu; built only here so rows with an
            -- explicit value_func never evaluate their sub_item_table_func
            -- while the list is rendered.
            local sub
            if type(item.sub_item_table_func) == "function" then
                local ok, s = pcall(item.sub_item_table_func)
                if ok then sub = s end
            else
                sub = item.sub_item_table
            end
            if type(sub) == "table" then
                for _, child in ipairs(sub) do
                    if child.radio == true
                       and child.sub_item_table == nil
                       and child.sub_item_table_func == nil
                       and type(child.checked_func) == "function" then
                        local ok, chk = pcall(child.checked_func)
                        if ok and chk then
                            local ct = type(child.text_func) == "function" and child.text_func() or child.text
                            if ct and ct ~= "" then right_value = ct end
                            break
                        end
                    end
                end
            end
        end

        local tap_fn = nil
        if not is_disabled then
            local _item  = item
            local _title = title
            tap_fn = function()
                if _item.sub_item_table or _item.sub_item_table_func then
                    local s = type(_item.sub_item_table_func) == "function"
                              and _item.sub_item_table_func()
                               or _item.sub_item_table
                    if push then
                        push(nil, { items = s, title = _title, items_func = _item.sub_item_table_func })
                    end
                elseif _item.callback then
                    pcall(_item.callback)
                    if not _item.keep_menu_open then
                        on_close()
                    end
                    repaint()
                end
            end
        end

        -- Resolve the per-item font face if font_func is provided.
        -- font_func(size) must return a Face object (same contract as KOReader's
        -- native TouchMenu).  We call it with FS_BODY so the row matches the
        -- default text size.  Any error is silently ignored.
        local title_face
        if type(item.font_func) == "function" then
            local ok_f, face = pcall(item.font_func, SZ(SUIStyle.FS_BODY))
            if ok_f and face then title_face = face end
        end

        table.insert(result, SUIWindow.ListRow{
            title        = title,
            inner_w      = inner_w,
            on_tap       = tap_fn,
            show_chevron = show_chevron,
            checked      = checked,
            right_value  = right_value,
            dim          = item.dim,
            title_face   = title_face,
        })

        ::continue::
    end

    if #result == 0 then
        table.insert(result, SUIWindow.ListRow{
            title   = _("No items available."),
            inner_w = inner_w,
        })
    end

    return result
end

-- ===========================================================================
-- SUIWindow.ActionMenu
-- ===========================================================================

--- Context popup anchored to a widget (typically a ModuleCard's "…" button).
---
--- @param opts table
---   items     table    — list of { text, icon, checked, on_tap, dim, keep_open }
---   get_items function — dynamic alternative to items (called on every build)
---   anchor    Geom     — anchor dimen for popup positioning
---   align     string   — item text alignment: "left" (default) or "center"
---   width     number   — fixed popup width; when absent the popup fits its items
function SUIWindow.ActionMenu(opts)
    local get_items = opts.get_items
        or (opts.items and function() return opts.items end)
        or function() return {} end

    local dialog
    local showDialog

    -- Item label: optional leading icon; a checked item gets a leading tick.
    local function labelFor(item)
        local label = item.text or ""
        local glyph = SUIStyle.icon(item.icon or "")
        if glyph ~= "" then label = glyph .. "  " .. label end
        if item.checked then label = SUIStyle.icon("tick") .. "  " .. label end
        return label
    end

    local function buildButtons()
        local buttons = {}
        for _, item in ipairs(get_items()) do
            table.insert(buttons, {{
                text      = labelFor(item),
                dim       = item.dim,
                enabled   = not (item.dim or item.enabled == false),
                align     = opts.align or "left",
                font_face = SUIStyle.FACE_REGULAR,
                font_size = SZ(SUIStyle.FS_BODY),
                font_bold = true,
                callback  = function()
                    UIManager:close(dialog)
                    if item.on_tap then item.on_tap() end
                    if item.keep_open then UIManager:scheduleIn(0, showDialog) end
                end,
            }})
        end
        return buttons
    end

    function showDialog()
        dialog = ButtonDialog:new{
            shrink_unneeded_width = opts.width == nil,
            width                 = opts.width,
            buttons               = buildButtons(),
            anchor                = opts.anchor and function() return opts.anchor end or nil,
        }
        UIManager:show(dialog)
    end

    showDialog()
end

-- ===========================================================================
-- SUIWindow._CardBase  (private)
-- ===========================================================================
-- Internal builder shared by PageCard, ModuleCard, and ArrangeCard.
-- Not part of the public API — use the specialised constructors below.
--
-- opts:
--   inner_w      number        — required
--   title        string
--   subtitle     string|nil
--   show_chevron bool          — default false
--   on_delete    function|nil
--   on_more      function|nil  — callback(anchor_dimen) for "…" button
--   on_move_up   function|nil
--   on_move_down function|nil
--   arrange_mode bool          — reserve space for both arrows even if one is nil
--   on_tap       function|nil
--   on_hold      function|nil
--   margin_v     number|nil    — vertical gap above (default: 8 px)
--   dim          bool|nil      — visually mutes the whole row (title,
--                                subtitle, frame border, and every icon
--                                button in it), e.g. an item excluded from
--                                a listing; does not disable any action
--   on_toggle    function|nil  — icon button, independent of on_delete; unlike
--                                on_delete, it never implies row removal —
--                                use it for in-place state flips (e.g. a
--                                show/hide eye toggle that keeps the item in
--                                the list, dimmed, instead of dropping it).
--   toggle_icon  string|nil    — SUIStyle icon key for on_toggle; default "hide"
--
-- @return VerticalGroup

local function _CardBase(opts)
    assert(opts.inner_w, "SUIWindow card: inner_w is required")

    local inner_w    = opts.inner_w
    local show_chev  = opts.show_chevron == true
    local has_delete = opts.on_delete ~= nil
    local has_edit   = opts.on_edit ~= nil
    local has_update = opts.on_update ~= nil
    local has_toggle = opts.on_toggle ~= nil
    local has_more   = opts.on_more ~= nil or (type(opts.more_items) == "table" and #opts.more_items > 0)
    local has_move   = opts.on_move_up ~= nil or opts.on_move_down ~= nil or opts.arrange_mode
    local has_move_page = opts.on_move_page ~= nil
    local margin_v   = opts.margin_v or SZ(Screen:scaleBySize(8))
    local h_pad      = SZ(Size.padding.large)
    local v_pad      = SZ(Screen:scaleBySize(12))
    local fg_color   = (opts.dim == true) and SUIStyle.COLOR.text_dim or _clrPrimary()

    local del_w    = has_delete and (_CHEVRON_W() * 2) or 0
    local edit_w   = has_edit and (_CHEVRON_W() * 2) or 0
    local upd_w    = has_update and (_CHEVRON_W() * 2) or 0
    local toggle_w = has_toggle and (_CHEVRON_W() * 2) or 0
    local more_w   = has_more   and (_CHEVRON_W() * 2) or 0
    local chev_w   = show_chev  and _CHEVRON_W() or 0
    local move_w   = has_move   and (_CHEVRON_W() * 4) or 0
    local move_page_w = has_move_page and (_CHEVRON_W() * 2) or 0
    local left_w = math.max(1, inner_w - del_w - edit_w - upd_w - toggle_w - more_w - chev_w - move_w - move_page_w - 2 * h_pad)

    local left_vg = VerticalGroup:new{ align = "left" }
    table.insert(left_vg, TextWidget:new{
        text      = opts.title or "",
        face      = _facePrimary(),
        fgcolor   = fg_color,
        bold      = true,
        max_width = left_w,
    })
    local sub = type(opts.subtitle) == "function" and opts.subtitle() or opts.subtitle
    if sub and sub ~= "" then
        table.insert(left_vg, VerticalSpan:new{ width = SZ(Screen:scaleBySize(4)) })
        table.insert(left_vg, TextWidget:new{
            text                   = sub,
            face                   = _faceSecondary(),
            fgcolor                = fg_color,
            max_width              = left_w,
            truncate_with_ellipsis = true,
        })
    end

    local left_h = left_vg:getSize().h

    local row_hg = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{
            dimen = Geom:new{ w = left_w, h = left_h },
            left_vg,
        },
    }

    if has_delete or has_edit or has_update or has_toggle or has_more or show_chev or has_move or has_move_page then
        local right_hg = HorizontalGroup:new{ align = "center" }

        if opts.on_move_page then
            table.insert(right_hg, SUIWindow.Input.iconButton{
                icon   = "move_page",
                w      = _CHEVRON_W() * 2,
                h      = left_h,
                color  = fg_color,
                on_tap = opts.on_move_page,
            })
        end

        if has_move then
            local WidgetContainer = require("ui/widget/container/widgetcontainer")
            local arrow_count = 0
            if opts.on_move_up then arrow_count = arrow_count + 1 end
            if opts.on_move_down then arrow_count = arrow_count + 1 end
            
            if arrow_count == 1 then
                table.insert(right_hg, WidgetContainer:new{
                    dimen = Geom:new{ w = _CHEVRON_W() * 2, h = left_h }
                })
            elseif arrow_count == 0 and opts.arrange_mode then
                table.insert(right_hg, WidgetContainer:new{
                    dimen = Geom:new{ w = _CHEVRON_W() * 4, h = left_h }
                })
            end

            if opts.on_move_up then
                table.insert(right_hg, SUIWindow.Input.iconButton{
                    icon   = "arrow_up",
                    w      = _CHEVRON_W() * 2,
                    h      = left_h,
                    color  = fg_color,
                    on_tap = opts.on_move_up,
                })
            end
            if opts.on_move_down then
                table.insert(right_hg, SUIWindow.Input.iconButton{
                    icon   = "arrow_down",
                    w      = _CHEVRON_W() * 2,
                    h      = left_h,
                    color  = fg_color,
                    on_tap = opts.on_move_down,
                })
            end
        end

        if has_update then
            table.insert(right_hg, SUIWindow.Input.iconButton{
                icon   = "update",
                w      = _CHEVRON_W() * 2,
                h      = left_h,
                color  = fg_color,
                on_tap = opts.on_update,
            })
        end

        if has_edit then
            table.insert(right_hg, SUIWindow.Input.iconButton{
                icon   = "edit",
                w      = _CHEVRON_W() * 2,
                h      = left_h,
                color  = fg_color,
                on_tap = opts.on_edit,
            })
        end

        if has_toggle then
            table.insert(right_hg, SUIWindow.Input.iconButton{
                icon   = opts.toggle_icon or "hide",
                w      = _CHEVRON_W() * 2,
                h      = left_h,
                color  = fg_color,
                on_tap = opts.on_toggle,
            })
        end

        if has_delete then
            table.insert(right_hg, SUIWindow.Input.iconButton{
                icon   = opts.delete_icon or "delete",
                w      = _CHEVRON_W() * 2,
                h      = left_h,
                color  = fg_color,
                on_tap = opts.on_delete,
            })
        end

        if has_more then
            local more_ic
            more_ic = InputContainer:new{
                dimen = Geom:new{ w = _CHEVRON_W() * 2, h = left_h },
                [1]   = CenterContainer:new{
                    dimen = Geom:new{ w = _CHEVRON_W() * 2, h = left_h },
                    TextWidget:new{
                        text    = SUIStyle.icon("more"),
                        face    = Font:getFace(SUIStyle.FACE_ICONS, SZ(Screen:scaleBySize(SUIStyle.FS_DETAIL))),
                        fgcolor = fg_color,
                    },
                },
            }
            more_ic.ges_events = {
                TapMore = {
                    GestureRange:new{ ges = "tap", range = function() return more_ic.dimen end }
                },
            }
            local _on_more = opts.on_more
            if not _on_more and type(opts.more_items) == "table" then
                _on_more = function(anchor_dimen)
                    SUIWindow.ActionMenu{
                        anchor = anchor_dimen,
                        items  = opts.more_items,
                    }
                end
            end
            function more_ic:onTapMore()
                _on_more(self.dimen)
                return true
            end
            table.insert(right_hg, more_ic)
        end

        if show_chev then
            table.insert(right_hg, RightContainer:new{
                dimen = Geom:new{ w = _CHEVRON_W(), h = left_h },
                HorizontalGroup:new{ align = "center",
                    HorizontalSpan:new{ width = SZ(Screen:scaleBySize(6)) },
                    TextWidget:new{
                        text      = SUIStyle.icon("chevron"),
                        face      = _faceChevron(),
                        fgcolor   = fg_color,
                        alignment = "right",
                    },
                },
            })
        end

        table.insert(row_hg, right_hg)
    end

    local content = FrameContainer:new{
        bordersize     = 0,
        padding        = h_pad,
        padding_top    = v_pad,
        padding_bottom = v_pad,
        row_hg,
    }

    local card_frame = FrameContainer:new{
        radius     = SZ(Screen:scaleBySize(12)),
        bordersize = SUIStyle.BORDER_SZ,
        color      = (opts.dim == true) and SUIStyle.COLOR.text_dim or SUIStyle.COLOR.gray,
        padding    = 0,
        dimen      = Geom:new{ w = inner_w, h = content:getSize().h },
        content,
    }

    local on_hold = opts.on_hold
    if not on_hold and opts.show_hold_menu then
        local hold_items = {}
        if opts.on_tap then
            table.insert(hold_items, { text = _("Select"), icon = "check", on_tap = opts.on_tap })
        end
        if opts.on_move_page then
            table.insert(hold_items, { text = _("Move to page"), icon = "move_page", on_tap = opts.on_move_page })
        end
        if opts.on_move_up then
            table.insert(hold_items, { text = _("Move up"), icon = "arrow_up", on_tap = opts.on_move_up })
        end
        if opts.on_move_down then
            table.insert(hold_items, { text = _("Move down"), icon = "arrow_down", on_tap = opts.on_move_down })
        end
        if opts.on_update then
            table.insert(hold_items, { text = _("Update"), icon = "update", on_tap = opts.on_update })
        end
        if opts.on_edit then
            table.insert(hold_items, { text = _("Rename"), icon = "edit", on_tap = opts.on_edit })
        end
        if opts.on_toggle then
            table.insert(hold_items, { text = opts.toggle_label or _("Toggle"), icon = opts.toggle_icon or "hide", on_tap = opts.on_toggle })
        end
        if type(opts.more_items) == "table" then
            for _, item in ipairs(opts.more_items) do
                table.insert(hold_items, item)
            end
        end
        if opts.on_delete then
            table.insert(hold_items, { text = _("Delete"), icon = "delete", on_tap = opts.on_delete })
        end
        
        if #hold_items > 0 then
            on_hold = function()
                local buttons = {}
                local dialog
                for _, item in ipairs(hold_items) do
                    local label = item.text or ""
                    if item.icon and item.icon ~= "" then
                        local glyph = SUIStyle.icon(item.icon)
                        if glyph ~= "" then label = glyph .. "  " .. label end
                    end
                    table.insert(buttons, {{
                        text      = label,
                        align     = "left",
                        font_face = SUIStyle.FACE_REGULAR,
                        font_size = SZ(SUIStyle.FS_BODY),
                        font_bold = true,
                        dim       = item.dim,
                        callback  = function()
                            UIManager:close(dialog)
                            if item.on_tap then item.on_tap() end
                        end,
                    }})
                end
                local dialog_w = SZ(math.floor(Screen:getWidth() * 0.42))
                dialog = ButtonDialog:new{
                    title              = opts.title,
                    width              = dialog_w,
                    buttons            = buttons,
                    tap_close_callback = function() UIManager:close(dialog) end,
                }
                UIManager:show(dialog)
            end
        end
    end

    local tappable
    if opts.on_tap or on_hold then
        tappable = SUIWindow.Input.tapable(
            card_frame,
            { on_tap = opts.on_tap, on_hold = on_hold },
            Geom:new{ w = inner_w, h = card_frame.dimen.h }
        )
    else
        tappable = card_frame
    end

    return VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = margin_v },
        tappable,
    }
end

-- ===========================================================================
-- SUIWindow.ArrangeCard
-- ===========================================================================

--- Card in reorder-only mode: shows up/down arrows; optional delete button
--- (left of arrows) and optional chevron (right of arrows).
--- Used by ArrangeList; can also be used standalone.
---
--- @param opts table
---   inner_w      number        — required
---   title        string
---   subtitle     string|nil
---   on_move_up   function|nil  — nil disables the up arrow (placeholder shown)
---   on_move_down function|nil  — nil disables the down arrow
---   on_delete    function|nil  — when set, shows a delete icon left of the arrows
---   delete_icon  string|nil    — SUIStyle icon key for the on_delete button; default "delete"
---                                (used e.g. when "delete" actually means "hide")
---   on_toggle    function|nil  — icon button that flips an in-place state without
---                                removing the row (unlike on_delete); pair with `dim`
---                                to grey the row out while it stays in the list.
---   toggle_icon  string|nil    — SUIStyle icon key for the on_toggle button; default "hide"
---   dim          bool|nil      — visually mutes the whole row (title,
---                                subtitle, frame border, every icon button)
---   show_chevron bool          — default false; when true shows chevron right of arrows
---   on_tap       function|nil  — tap handler on the card body (used with show_chevron)
---   on_hold      function|nil
---   margin_v     number|nil
---
--- @return VerticalGroup
function SUIWindow.ArrangeCard(opts)
    assert(opts.inner_w, "SUIWindow.ArrangeCard: inner_w is required")
    return _CardBase{
        inner_w      = opts.inner_w,
        title        = opts.title,
        subtitle     = opts.subtitle,
        show_chevron = opts.show_chevron == true,
        arrange_mode = true,
        on_delete    = opts.on_delete,
        delete_icon  = opts.delete_icon,
        on_toggle    = opts.on_toggle,
        toggle_icon  = opts.toggle_icon,
        dim          = opts.dim,
        on_more      = opts.on_more,
        more_items   = opts.more_items,
        on_move_page = opts.on_move_page,
        on_move_up   = opts.on_move_up,
        on_move_down = opts.on_move_down,
        on_tap       = opts.on_tap,
        on_hold      = opts.on_hold,
        margin_v     = opts.margin_v or SZ(Screen:scaleBySize(4)),
    }
end

-- ===========================================================================
-- SUIWindow.ArrangeList
-- ===========================================================================

--- Renders a list of items as ArrangeCards with up/down arrows.
--- Section breaks (items with dim=true or _is_break=true) render as Section headers.
---
--- Items format: { text = string, dim = bool?, _is_break = bool?, dim_row = bool?,
---                  on_toggle = func?, toggle_icon = string? }
--- (dim_row/on_toggle/toggle_icon mirror RowPage's convention — dim_row visually
--- mutes a regular row without turning it into a Section header, unlike `dim`.)
---
--- @param opts table
---   inner_w    number    — required
---   items      table[]
---   ctx        table     — optional, auto-jumps to last page when items are added
---   on_change  function  — called after every move or delete with the mutated items table
---   delete_icon string|nil — SUIStyle icon key for every card's delete button; default "delete".
---                            Per-item override via item.delete_icon also supported.
---   on_repaint function  — called after every mutation so the screen updates visually;
---                          pass ctx.repaint when using ArrangeList directly as a sui_build
---                          (not needed when going through ctx.push("arrange", …) because
---                          buildArrange in sui_settings_window wraps on_change with repaint)
---
--- @return widget[]
function SUIWindow.ArrangeList(opts)
    assert(opts.inner_w, "SUIWindow.ArrangeList: inner_w is required")
    local items   = opts.items or {}
    local repaint = type(opts.on_repaint) == "function" and opts.on_repaint or function() end
    local result  = {}

    if opts.ctx then
        local cur = opts.ctx.current()
        if cur then
            local last_count = cur._arrange_list_count
            if last_count and #items > last_count then
                if opts.ctx.jump_to_last_page then opts.ctx.jump_to_last_page() end
            end
            cur._arrange_list_count = #items
        end
    end

    local function _after_change()
        if opts.on_change then opts.on_change(items) end
        repaint()
    end

    for i, item in ipairs(items) do
        local _i = i
        if item.dim or item._is_break or item.is_divider then
            local title_clean = item.text:gsub("──%s*", ""):gsub("%s*──", "")
            table.insert(result, SUIWindow.Section{
                title   = title_clean,
                inner_w = opts.inner_w,
            })
        else
            local can_move_up = (_i > 1)
            local prev_item   = items[_i - 1]
            if can_move_up and _i == 2 and prev_item and
               (prev_item.dim or prev_item._is_break or prev_item.is_divider) and prev_item.pin_top then
                can_move_up = false
            end

            local _on_delete = nil
            if opts.on_delete then
                _on_delete = function()
                    opts.on_delete(_i, item)
                    repaint()
                end
            elseif item.on_delete then
                _on_delete = item.on_delete
            end

            table.insert(result, SUIWindow.ArrangeCard{
                inner_w      = opts.inner_w,
                title        = item.text,
                subtitle     = item.subtitle,
                show_chevron = item.show_chevron,
                on_more      = item.on_more,
                more_items   = item.more_items,
                on_move_page = item.on_move_page,
                on_tap       = item.on_tap,
                on_delete    = _on_delete,
                delete_icon  = item.delete_icon or opts.delete_icon,
                on_toggle    = item.on_toggle,
                toggle_icon  = item.toggle_icon,
                dim          = item.dim_row,
                on_move_up   = can_move_up and function()
                    items[_i], items[_i - 1] = items[_i - 1], items[_i]
                    _after_change()
                end or nil,
                on_move_down = (_i < #items) and function()
                    items[_i], items[_i + 1] = items[_i + 1], items[_i]
                    _after_change()
                end or nil,
            })
        end
    end

    if #result == 0 then
        table.insert(result, SUIWindow.ListRow{
            title   = opts.empty_text or _("No items selected."),
            inner_w = opts.inner_w,
        })
    end

    return result
end

-- ===========================================================================
-- SUIWindow.RowPage
-- ===========================================================================

--- Renders a list of items as standard ListRows.
--- Section breaks (items with dim=true or _is_break=true) render as Section headers.
---
--- Items format: { text = string, subtitle = string?, right_value = string?, right_icon = string?, show_chevron = bool?, on_tap = func?, on_delete = func?, on_more = func?, ... }
---
--- @param opts table
---   inner_w    number    — required
---   items      table[]
---   ctx        table     — optional, auto-jumps to last page when items are added
---   empty_text string    — optional fallback text
---   on_repaint function  — optional callback
---   on_delete  function  — optional callback(idx, item) for global delete handler
---   on_change  function  — optional callback(items) fired after global delete
---
--- @return widget[]
function SUIWindow.RowPage(opts)
    assert(opts.inner_w, "SUIWindow.RowPage: inner_w is required")
    local items   = opts.items or {}
    local repaint = type(opts.on_repaint) == "function" and opts.on_repaint or function() end
    local result  = {}

    if opts.ctx then
        local cur = opts.ctx.current()
        if cur then
            local last_count = cur._row_page_count
            if last_count and #items > last_count then
                if opts.ctx.jump_to_last_page then opts.ctx.jump_to_last_page() end
            end
            cur._row_page_count = #items
        end
    end

    for i, item in ipairs(items) do
        local _i = i
        if item.dim or item._is_break or item.is_divider then
            local title_clean = item.text:gsub("──%s*", ""):gsub("%s*──", "")
            table.insert(result, SUIWindow.Section{
                title   = title_clean,
                inner_w = opts.inner_w,
            })
        else
            local _on_delete = nil
            if opts.on_delete then
                _on_delete = function()
                    opts.on_delete(_i, item)
                    if opts.on_change then opts.on_change(items) end
                    repaint()
                end
            elseif item.on_delete then
                _on_delete = item.on_delete
            end

            table.insert(result, SUIWindow.ListRow{
                inner_w      = opts.inner_w,
                title        = item.text,
                subtitle     = item.subtitle,
                left_icon    = item.left_icon,
                left_widget  = item.left_widget,
                right_icon   = item.right_icon,
                right_value  = item.right_value,
                right_widget = item.right_widget,
                checked      = item.checked,
                show_chevron = item.show_chevron,
                on_tap       = item.on_tap,
                on_hold      = item.on_hold,
                on_delete    = _on_delete,
                on_edit      = item.on_edit,
                on_update    = item.on_update,
                on_more      = item.on_more,
                more_items   = item.more_items,
                separator    = item.separator,
                dim          = item.dim_row,
            })
        end
    end

    if #result == 0 then
        table.insert(result, SUIWindow.ListRow{
            title   = opts.empty_text or _("No items available."),
            inner_w = opts.inner_w,
        })
    end

    return result
end

-- ===========================================================================
-- SUIWindow.TwoButtonFooter
-- ===========================================================================

--- Footer with two side-by-side buttons.
--- @param ctx       table  — SUIWindow build context
--- @param left_opts table  — Button opts (text, icon, on_tap)
--- @param right_opts table
--- @return InputContainer  — with explicit dimen.h
function SUIWindow.TwoButtonFooter(ctx, left_opts, right_opts)
    local iw      = ctx.inner_w
    local btn_w   = math.floor(iw / 2)
    local top_pad = SZ(Screen:scaleBySize(8))

    left_opts.inner_w  = iw
    left_opts.width    = btn_w
    left_opts.align    = "left"
    right_opts.inner_w = iw
    right_opts.width   = btn_w
    right_opts.align   = "right"

    local left_btn  = SUIWindow.Button(left_opts)
    local right_btn = SUIWindow.Button(right_opts)
    local btn_h     = left_btn:getSize().h
    local total_h   = top_pad + btn_h

    local vg = VerticalGroup:new{
        align = "left",
        dimen = Geom:new{ w = iw, h = total_h },
        VerticalSpan:new{ width = top_pad },
        HorizontalGroup:new{
            align = "center",
            left_btn,
            right_btn,
        },
    }

    local ic = InputContainer:new{
        dimen = Geom:new{ w = iw, h = total_h },
        [1]   = vg,
    }
    if ctx.addSwipe then ctx.addSwipe(ic) end
    return ic
end

-- ===========================================================================
-- SUIWindow.CenteredButtonFooter
-- ===========================================================================

--- Footer with a single centred button.
--- @param ctx  table  — SUIWindow build context
--- @param opts table  — Button opts (text, icon, on_tap, enabled)
--- @return InputContainer  — with explicit dimen.h
function SUIWindow.CenteredButtonFooter(ctx, opts)
    local iw          = ctx.inner_w
    local face        = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_BODY))
    local border_sz   = SUIStyle.BORDER_SZ
    local btn_radius  = SZ(Screen:scaleBySize(8))
    local h_pad       = SZ(Screen:scaleBySize(12))
    local btn_h       = face.size + SZ(Screen:scaleBySize(8)) * 2
    local top_pad     = SZ(Screen:scaleBySize(8))
    local bot_pad     = SZ(Screen:scaleBySize(16))
    local total_h     = top_pad + btn_h + bot_pad
    local is_disabled = opts.enabled == false

    local text_w = TextWidget:new{
        text    = opts.icon and (SUIStyle.icon(opts.icon) .. "  " .. (opts.text or "")) or (opts.text or ""),
        face    = face,
        fgcolor = is_disabled and SUIStyle.COLOR.text_dim or SUIStyle.COLOR.text_primary,
        bold    = true,
    }

    local text_px_w = text_w:getSize().w
    local btn_w     = text_px_w + h_pad * 2

    local btn_frame = FrameContainer:new{
        width          = btn_w,
        height         = btn_h,
        radius         = btn_radius,
        bordersize     = border_sz,
        color          = is_disabled and SUIStyle.COLOR.text_dim or SUIStyle.COLOR.gray,
        background     = nil,
        padding        = 0,
        dimen          = Geom:new{ w = btn_w, h = btn_h },
        CenterContainer:new{
            dimen = Geom:new{ w = btn_w - border_sz * 2, h = btn_h - border_sz * 2 },
            text_w,
        },
    }

    local centered_btn = CenterContainer:new{
        dimen = Geom:new{ w = iw, h = btn_h },
        btn_frame,
    }

    local tappable
    if not is_disabled then
        tappable = SUIWindow.Input.tapable(
            centered_btn,
            { on_tap = opts.on_tap },
            Geom:new{ w = iw, h = btn_h }
        )
    else
        tappable = centered_btn
    end

    local vg = VerticalGroup:new{
        align = "left",
        dimen = Geom:new{ w = iw, h = total_h },
        VerticalSpan:new{ width = top_pad },
        tappable,
        VerticalSpan:new{ width = bot_pad },
    }
    local ic = InputContainer:new{
        dimen = Geom:new{ w = iw, h = total_h },
        [1]   = vg,
    }
    if ctx.addSwipe then ctx.addSwipe(ic) end
    return ic
end

-- ===========================================================================
-- Shared helper: SUIWindow.makeSettingsScreens
-- ===========================================================================
--- Builds the standard shared screens used by all three settings windows
--- (bottom bar, top bar, homescreen modules).  Only `__root__` differs per
--- caller — everything else (`nested_menu`, `arrange`) is identical boilerplate.
---
--- Usage:
---   local screens = SUIWindow.makeSettingsScreens(buildRoot)
---   local win = SUIWindow:new{ title = titleFn, screens = screens }
---
--- @param buildRoot function(ctx)→widget  — the entry screen builder
--- @return table           — screens map ready for SUIWindow:new
function SUIWindow.makeSettingsScreens(buildRoot)
    local function makeMenuTable(ctx, items)
        return SUIWindow.MenuTable{
            items          = items,
            inner_w        = ctx.inner_w,
            repaint        = function() ctx.repaint() end,
            lock_overlay   = ctx.lockOverlay,
            unlock_overlay = ctx.unlockOverlay,
            push_stack = function(id, params)
                if type(id) == "string" then ctx.push(id, params) else ctx.push("nested_menu", params) end
            end,
            on_close = function() end,
        }
    end

    local function buildNestedMenu(ctx)
        local cur    = ctx.current()
        local params = cur and cur.params or {}
        local items  = params.items or {}
        if type(params.items_func) == "function" then
            items = params.items_func()
        end
        return makeMenuTable(ctx, items)
    end

    local function buildArrange(ctx)
        local cur    = ctx.current()
        local params = cur and cur.params or {}
        
        local items = params.items
        if not items and type(params.items_func) == "function" then
            items = params.items_func()
        end
        items = items or {}
        
        return SUIWindow.ArrangeList{
            ctx       = ctx,
            items     = items,
            inner_w   = ctx.inner_w,
            empty_text= params.empty_text,
            delete_icon = params.delete_icon,
            on_delete = params.on_delete and function(idx, item)
                table.remove(items, idx)
                if params.items and params.items ~= items then
                    table.remove(params.items, idx)
                end
                params.on_delete(item)
                if params.on_change then params.on_change(items) end
                ctx.repaint()
            end or nil,
            on_change = function(new_items)
                if type(params.on_change) == "function" then params.on_change(new_items) end
                ctx.repaint()
            end,
        }
    end

    local function buildRowPage(ctx)
        local cur    = ctx.current()
        local params = cur and cur.params or {}
        
        local items = params.items
        if not items and type(params.items_func) == "function" then
            items = params.items_func()
        end
        items = items or {}
        
        return SUIWindow.RowPage{
            ctx        = ctx,
            items      = items,
            inner_w    = ctx.inner_w,
            empty_text = params.empty_text,
            on_repaint = function() ctx.repaint() end,
            on_delete  = params.on_delete and function(idx, item)
                table.remove(items, idx)
                if params.items and params.items ~= items then
                    table.remove(params.items, idx)
                end
                params.on_delete(item)
                if params.on_change then params.on_change(items) end
                ctx.repaint()
            end or nil,
            on_change  = function(new_items)
                if type(params.on_change) == "function" then params.on_change(new_items) end
                ctx.repaint()
            end,
        }
    end

    local function buildItemPicker(ctx)
        local cur    = ctx.current()
        local params = cur and cur.params or {}
        local iw     = ctx.inner_w
        local rows   = {}
        local picker_items = type(params.items) == "table" and params.items or {}
        if #picker_items == 0 then
            rows[#rows + 1] = SUIWindow.ListRow{
                title   = _("All items have already been added."),
                inner_w = iw,
            }
        else
            for _, it in ipairs(picker_items) do
                local _it = it
                rows[#rows + 1] = SUIWindow.ListRow{
                    title   = _it.text,
                    inner_w = iw,
                    on_tap  = function() _it.on_tap(ctx) end,
                }
            end
        end
        return rows
    end

    return {
        __root__    = buildRoot,
        nested_menu = buildNestedMenu,
        arrange     = buildArrange,
        row_page    = buildRowPage,
        item_picker = buildItemPicker,
    }
end

--- Wraps a refresh function so it always repaints this SUIWindow screen
--- afterwards, in addition to whatever fn already does (invalidating a
--- cache, saving a layout, etc.).
---
--- A ctx_menu.refresh handed to a menu-item factory (makeGapItem,
--- makeBentoWidthItem, ...) is what runs after a SpinWidget/ConfirmBox
--- callback applies a new value. Inside a SUIWindow, the item's displayed
--- value_func/text_func is only re-evaluated on repaint — refresh alone
--- (e.g. one that just clears a homescreen cache) updates what's behind
--- the window, not the window itself, so the change appears to "not
--- apply" until the window is reopened. This is the single place that
--- ties refresh to repaint, so every SUIWindow ctx_menu builds its
--- refresh through here instead of each call site hand-writing its own
--- `function() ...; ctx.repaint() end` and risking one that forgets to.
---
--- @param ctx table       — SUIWindow screen context (must expose repaint())
--- @param fn  function|nil — optional extra work to run before repainting
--- @return function
function SUIWindow.withRepaint(ctx, fn)
    return function()
        if fn then fn() end
        ctx.repaint()
    end
end

--- Builds the standard ctx_menu table passed to plugin menu-builder functions.
--- Centralises the repeated construction of UIManager, i18n, and overlay refs.
---
--- Callers inside SUIWindow always receive is_sui = true so that menu-builder
--- functions can branch on it to return SUIWindow-optimised items (sui_build,
--- sui_hidden) without affecting the native KOReader menu.
---
--- This is the single shape every SUIWindow hands to a plugin/module's menu
--- builder — windows should extend or override individual fields (pfx,
--- refresh, ...) rather than constructing their own ctx_menu table from
--- scratch, so a menu builder sees the same fields regardless of which
--- window opened it.
---
--- @param ctx table   — SUIWindow screen context
--- @return table
function SUIWindow.makeCtxMenu(ctx)
    return {
        is_sui           = true,          -- signals that we are inside a SUIWindow
        pfx              = "simpleui_hs_",
        pfx_qa           = "simpleui_hs_qa_",
        refresh          = SUIWindow.withRepaint(ctx),
        show_arrange     = function(params) ctx.push("arrange",     params) end,
        show_row_page    = function(params) ctx.push("row_page",    params) end,
        show_item_picker = function(params) ctx.push("item_picker", params) end,
        UIManager        = require("ui/uimanager"),
        _                = require("infra/sui_i18n").translate,
        N_               = require("infra/sui_i18n").ngettext,
        SortWidget       = require("ui/widget/sortwidget"),
        ConfirmBox       = require("ui/widget/confirmbox"),
        MAX_LABEL_LEN    = require("infra/sui_config").MAX_LABEL_LEN,
        lock_overlay     = ctx.lockOverlay,
        unlock_overlay   = ctx.unlockOverlay,
    }
end

--- Builds the full settings screen for one module: its own items
--- (mod.getMenuItems) followed by the shared Top Margin / Column Width
--- chrome (see Config.appendModuleChromeItems), wrapped as a MenuTable
--- ready to return from a screens[] builder.
---
--- This is the single source of truth for "what a module's settings screen
--- contains and how it's built" — every window that can open module
--- settings (long-press on a module, the dedicated Settings ▸ Modules
--- screen, ...) calls this instead of re-deriving its own ctx_menu/item
--- list, so they can't drift apart on either the fields exposed to
--- mod.getMenuItems or the chrome items appended after it.
---
--- @param ctx   table — SUIWindow screen context
--- @param mod   table — module descriptor (id, name, no_top_margin, getMenuItems)
--- @param opts  table|nil — {
---   pfx           — settings-key prefix (default "simpleui_hs_")
---   pfx_qa        — quick-action key prefix (default "simpleui_hs_qa_")
---   extra_refresh — optional extra work to run on refresh, besides
---                   repainting this window (e.g. saving a Custom Screen's
---                   layout, or invalidating a live homescreen's caches)
---   on_change     — optional extra work to run specifically when Top
---                   Margin/Column Width change (e.g. invalidating a
---                   different screen instance's module-list cache)
--- }
--- @return table — SUIWindow.MenuTable widget
function SUIWindow.buildModuleSettingsScreen(ctx, mod, opts)
    opts = opts or {}

    local ctx_menu = SUIWindow.makeCtxMenu(ctx)
    if opts.pfx    then ctx_menu.pfx    = opts.pfx    end
    if opts.pfx_qa then ctx_menu.pfx_qa = opts.pfx_qa end
    ctx_menu.refresh = SUIWindow.withRepaint(ctx, opts.extra_refresh)

    local items = type(mod.getMenuItems) == "function" and mod.getMenuItems(ctx_menu) or {}
    require("infra/sui_config").appendModuleChromeItems(items, {
        mod       = mod,
        pfx       = ctx_menu.pfx,
        refresh   = ctx_menu.refresh,
        on_change = opts.on_change,
    })

    return SUIWindow.MenuTable{
        items          = items,
        inner_w        = ctx.inner_w,
        repaint        = function() ctx.repaint() end,
        lock_overlay   = ctx.lockOverlay   or function() end,
        unlock_overlay = ctx.unlockOverlay or function() end,
        push_stack     = function(id, params)
            if type(id) == "string" then ctx.push(id, params) else ctx.push("nested_menu", params) end
        end,
        on_close       = function() end,
    }
end

-- ===========================================================================

return SUIWindow
