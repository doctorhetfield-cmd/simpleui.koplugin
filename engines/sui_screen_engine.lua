-- engines/sui_screen_engine.lua — SimpleUI generic screen rendering engine.
--
-- Renders any homescreen-like screen: the built-in Homescreen (self._id ==
-- "hs") and any number of user-created Custom Screens
-- (infra/sui_custom_screens.lua), each opened on demand via its own
-- auto-generated Quick Action. Every screen is fully independent — own
-- settings prefix (self._pfx), own layout key (self._layout_key), separate
-- caches, own lifecycle — set once in ScreenWidget:init() from
-- self.instance (see that function for the full contract). Shares module
-- registry and module files with the Continue page.
--
-- This file is screen-agnostic: every screen is opened via
-- ScreenEngine._open(instance_cfg, ...), and instance_cfg (id/pfx/layout_key,
-- plus optional title/left_icon for the title bar and an optional
-- on_after_open hook) is always supplied by the caller. Cross-family
-- rotation handling (ScreenWidget:onSetRotationMode) is generic and needs
-- no hook from instance_cfg. screens/sui_homescreen.lua owns the
-- built-in Homescreen's identity (id "hs" and its settings prefix/layout
-- key) and overrides ScreenEngine.show() to pass it in. The one exception is
-- _BUILTIN_ID (below), needed by _sget/_sset's legacy flat-state dispatch.
--
-- screens/sui_homescreen.lua re-exports this file's module table (mutating
-- it, not wrapping it — see that file's header) for every existing
-- require("screens/sui_homescreen") elsewhere in the codebase.

local BD               = require("ui/bidi")
local BottomContainer  = require("ui/widget/container/bottomcontainer")
local Button           = require("ui/widget/button")
local CenterContainer  = require("ui/widget/container/centercontainer")
local OverlapGroup     = require("ui/widget/overlapgroup")
local Device           = require("device")
local Font             = require("ui/font")
local FrameContainer   = require("ui/widget/container/framecontainer")
local Geom             = require("ui/geometry")
local GestureRange     = require("ui/gesturerange")
local HorizontalSpan   = require("ui/widget/horizontalspan")
local InputContainer   = require("ui/widget/container/inputcontainer")
local LeftContainer    = require("ui/widget/container/leftcontainer")
local TextWidget       = require("ui/widget/textwidget")
local TitleBar         = require("ui/widget/titlebar")
local UIManager        = require("ui/uimanager")
local HorizontalGroup  = require("ui/widget/horizontalgroup")
local VerticalGroup    = require("ui/widget/verticalgroup")
local VerticalSpan     = require("ui/widget/verticalspan")
local logger           = require("logger")
local _                = require("infra/sui_i18n").translate
local T                = require("ffi/util").template
local Config           = require("infra/sui_config")
local Bento            = require("infra/sui_bento")
local Memory           = require("infra/sui_memory")
local Perf             = require("infra/sui_perf")
local Registry         = require("modules/moduleregistry")
local SUISettings = require("infra/sui_store")
local Event            = require("ui/event")
local Screen           = Device.screen
local UI               = require("infra/sui_core")
local Bottombar        = require("screens/sui_bottombar")
local SUIStyle         = require("features/sui_style")
local SectionLabel     = require("engines/sui_section_label")
local lfs              = require("libs/libkoreader-lfs")
local VirtualPaths     = require("infra/sui_virtual_paths")
local SUIWallpaper     = require("features/sui_wallpaper")
local Backdrop         = require("infra/sui_backdrop")

-- ---------------------------------------------------------------------------
-- Wallpaper background override — state and logic now live in
-- features/sui_wallpaper.lua (see that file's header for the full list of
-- consumers). This engine only calls the module's public API from
-- _initLayout() (paints the cached bg widget) and from the rotation/preset
-- rebuild paths (frees the cache before rebuilding).
-- ---------------------------------------------------------------------------

-- Pure helper: tests whether (x, y) falls inside a ratio-defined zone.
-- Defined at module level so it is created once and never re-allocated per
-- gesture event (unlike a closure defined inside _fmGestureAction).
local function _inZone(z, x, y, sw, sh)
    if not z then return false end
    return x >= z.ratio_x * sw and x < (z.ratio_x + z.ratio_w) * sw
       and y >= z.ratio_y * sh and y < (z.ratio_y + z.ratio_h) * sh
end


-- Lazy-loaded module references — loaded once on first use.
local _SH = nil
local _SP = nil
local function _getBookShared()
    if not _SH then
        local ok, m = pcall(require, "modules/module_books_shared")
        if ok then _SH = m end
    end
    return _SH
end
local function _getStatsProvider()
    if not _SP then
        local ok, m = pcall(require, "modules/module_stats_provider")
        if ok then _SP = m end
    end
    return _SP
end

-- Predicts which book occupies the Cover Deck's centre slot before any
-- carousel navigation happens, so its stats can be pre-fetched off the paint
-- path. Mirrors the ordering rule in module_coverdeck.buildRecentFps(): the
-- active book takes the centre slot when there is one, otherwise the most
-- recently read book takes its place. A guard at read time compares this
-- prediction against the book actually centred in the carousel and falls
-- back to a live query on mismatch, so an incorrect guess here never shows
-- the wrong book's stats — it only costs one extra query on that render.
local function _coverdeckDefaultCenterFp(current_fp, recent_fps)
    return current_fp or (recent_fps and recent_fps[1])
end

-- True until the very first ScreenWidget:onShow() this KOReader process (or
-- plugin hot-reload — this module is evicted from package.loaded on
-- teardown, which naturally resets this local) has consumed it. That one
-- call is allowed to fetch live stats/books data synchronously so every
-- module paints with correct data on its very first frame: a one-off delay
-- at startup is acceptable, unlike the same delay on every reader return.
-- Never re-armed afterwards, regardless of whether the fetch succeeded.
local _cold_boot_pending = true

-- Layout constants sourced from sui_core (single source of truth).
local MOD_GAP            = UI.MOD_GAP

-- Static color defaults.

local function _getDotInactive()
    return SUIStyle.COLOR.text_dim
end

-- Modules that render cover thumbnails declare has_covers = true; the
-- homescreen reads that flag to set the dithering hint.

-- ---------------------------------------------------------------------------
-- DotWidget — defined once at file level; buildDotFooter() creates instances.
-- ---------------------------------------------------------------------------
local _BaseWidget = require("ui/widget/widget")
local DotWidget = _BaseWidget:extend{
    current_page = 1,
    total_pages  = 1,
    dot_size     = 0,
    bar_h        = 0,
    touch_w      = 0,
    pill_h       = 0,
}

function DotWidget:getSize()
    return Geom:new{ w = self.total_pages * self.touch_w, h = self.bar_h }
end

-- Pill behind the dots, in the surface of the pagination bar (tone, opacity and
-- frame), so the dots stay legible over a wallpaper. Each end cap is centred on
-- the first or last dot.
function DotWidget:_paintPill(bb, x, y, surface)
    if surface.strength <= 0 and surface.border_sz <= 0 then return end
    local pill_x = x + math.floor((self.touch_w - self.pill_h) / 2)
    local pill_y = y + math.floor((self.bar_h - self.pill_h) / 2)
    local pill_w = (self.total_pages - 1) * self.touch_w + self.pill_h
    Backdrop.paintSurface(bb, pill_x, pill_y, pill_w, self.pill_h, surface, math.floor(self.pill_h / 2))
end

function DotWidget:paintTo(bb, x, y)
    local surface = SUIWallpaper.resolveBar("pagination")
    self:_paintPill(bb, x, y, surface)
    local active, inactive = Backdrop.contentColors(surface, _getDotInactive())
    active = Backdrop.accentOn(surface) or active
    local dot_r = math.floor(self.dot_size / 2)
    local cy    = y + math.floor(self.bar_h / 2)
    local tw    = self.touch_w
    for i = 1, self.total_pages do
        local cx = x + (i - 1) * tw + math.floor(tw / 2)
        if i == self.current_page then
            bb:paintCircle(cx, cy, dot_r, active)
        else
            bb:paintCircle(cx, cy, dot_r, inactive)
        end
    end
end

-- Forward declaration needed so onCloseWidget() can reference it.
--
-- ScreenEngine is BOTH the module's public API (ScreenEngine.show, style
-- getters/setters, wallpaper, etc. — singleton/global) AND, for the
-- built-in Homescreen only (id == _BUILTIN_ID), the flat-field state store
-- (_instance, _cached_books_state, _current_page, _cfg_cache,
-- _stats_need_refresh, _library_was_visited) that main.lua, sui_patches.lua
-- and several modules already read/write directly via
-- require("screens/sui_homescreen").<field>. Those fields keep their exact
-- names and flat shape here for backward compatibility.
--
-- Custom Screens get the equivalent per-id bookkeeping in
-- ScreenEngine._cs_state[id] instead (see _sget/_sset below) — nothing
-- external depends on that shape, so it's free to be per-id from day one.
local ScreenEngine = { _instance = nil, _cs_state = {} }

-- ---------------------------------------------------------------------------
-- Soft-park (reader round-trip optimisation)
--
-- User setting "Fast Book Closing" (Home Screen > Behaviour > Books). When on,
-- ScreenWidget:onShowingReader keeps the Homescreen's widget tree, bitmaps and
-- cached state alive, hidden underneath the reader, instead of tearing it all
-- down and rebuilding cold on every reader round-trip (see
-- ScreenWidget:onShowingReader below and _raiseParkedScreen in
-- infra/sui_patches.lua). Off by default (cold close).
local KEY_SOFT_PARK = "simpleui_hs_fast_book_close"

function ScreenEngine.isSoftParkEnabled()
    return SUISettings:isTrue(KEY_SOFT_PARK)
end

-- When true (default) and soft-park is enabled, a soft-parked
-- Homescreen is left alive under the system ScreenSaver instead of being
-- closed by the UIManager.show fullscreen-widget guard. On wakeup the
-- parked instance is still under the Reader and the normal raise path
-- works on book close. Flip to false to restore the pre-existing behaviour
-- (HS closed on every suspend, cold rebuild on the next book close).
-- Code-only; not exposed in any menu. Has no effect while "Fast Book Closing" is off.
ScreenEngine.KEEP_PARKED_ACROSS_SUSPEND = true

-- The built-in Homescreen's id — the one place in this file that still
-- "knows" the built-in Homescreen exists, needed because _sget/_sset (below)
-- must decide whether to use the legacy flat-state shape or the per-id
-- ScreenEngine._cs_state[id] shape, a backward-compatibility concern tied to
-- this exact id and not something a Custom Screen's instance_cfg can opt
-- into.
local _BUILTIN_ID = "hs"

-- ---------------------------------------------------------------------------
-- _sget(id, field) / _sset(id, field, value)
--
-- Single dispatch point for every singleton-shaped state field listed above.
-- id == _BUILTIN_ID reads/writes the flat ScreenEngine.<field>, exactly as
-- before, for backward compatibility with external callers. Any other id (a
-- Custom Screen) reads/writes ScreenEngine._cs_state[id].<field> instead,
-- auto-vivifying that per-id table on first write.
-- ---------------------------------------------------------------------------
local function _sget(id, field)
    if id == _BUILTIN_ID or not id then return ScreenEngine[field] end
    local st = ScreenEngine._cs_state[id]
    return st and st[field]
end

local function _sset(id, field, value)
    if id == _BUILTIN_ID or not id then
        ScreenEngine[field] = value
        return
    end
    local st = ScreenEngine._cs_state[id]
    if not st then
        st = {}
        ScreenEngine._cs_state[id] = st
    end
    st[field] = value
end

-- ---------------------------------------------------------------------------
-- Pre-computed empty-state pixel constants (computed once at load time).
-- ---------------------------------------------------------------------------
local _EMPTY_H        = Screen:scaleBySize(80)
local _EMPTY_GAP        = Screen:scaleBySize(12)
local _face_empty_title = Font:getFace(SUIStyle.FACE_REGULAR,    SUIStyle.FS_TITLE)     -- FS_TITLE (22)
local _face_empty_sub   = Font:getFace(SUIStyle.FACE_REGULAR,  SUIStyle.FS_SUBTITLE)  -- FS_SUBTITLE (20)

local function buildEmptyState(w, h)
    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
        VerticalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = w },
                TextWidget:new{
                    text = _("No books opened yet"),
                    face = _face_empty_title,  -- smallinfofont: 22pt
                    bold = true,
                },
            },
            VerticalSpan:new{ width = _EMPTY_GAP },
            CenterContainer:new{
                dimen = Geom:new{ w = w },
                UI.makeColoredText{
                    text    = _("Open a book to get started"),
                    face    = _face_empty_sub,  -- x_smallinfofont: 20pt
                    fgcolor = SUIStyle.COLOR.text_primary,
                },
            },
        },
    }
end

-- ---------------------------------------------------------------------------
-- Pagination helpers
-- ---------------------------------------------------------------------------

local PAGE_BREAK_ID = "__page_break__"

-- Splits a flat module order list (with __page_break__ sentinels) into pages.
local function splitOrderIntoPages(order)
    local pages    = {}
    local cur_page = {}
    for _, id in ipairs(order) do
        if id == PAGE_BREAK_ID then
            pages[#pages + 1] = cur_page
            cur_page = {}
        else
            cur_page[#cur_page + 1] = id
        end
    end
    pages[#pages + 1] = cur_page
    if #pages == 0 then pages[1] = {} end
    return pages
end

-- Returns true when the screen is in landscape orientation.
local function _isLandscape()
    return UI.isLandscape()
end

-- Computes a landscape page step (2 in landscape spread mode, 1 in portrait).
local function _pageStep(total)
    return (_isLandscape() and total > 1) and 2 or 1
end

-- Clamps raw page index to valid range and ensures it lands on an odd index
-- in landscape mode (first page of a spread).
local function _clampPage(raw, total, step)
    local p = math.max(1, math.min(raw, total))
    if step == 2 and p % 2 == 0 then p = p - 1 end
    return p
end

-- Computes the last-page raw index for the given step/total combination.
local function _lastRawPage(total, step)
    if step == 2 then
        return (total % 2 == 0) and (total - 1) or total
    end
    return total
end

-- Core page-navigation logic shared by swipe, footer, chevrons, and _goto.
-- dir: "prev" | "next" | "first" | "last" | spread_number (integer).
-- Returns the new raw page index, or cur if no change.
local function _resolvePageNav(cur, total, dir)
    local step = _pageStep(total)
    local raw
    if dir == "prev" then
        raw = cur - step
        if raw < 1 then raw = 1 end
    elseif dir == "next" then
        raw = cur + step
        if raw > total then raw = total end
    elseif dir == "first" then
        raw = 1
    elseif dir == "last" then
        raw = _lastRawPage(total, step)
    else
        -- dir is a spread number; convert to raw page index.
        raw = (step == 2) and ((dir - 1) * 2 + 1) or dir
    end
    return _clampPage(raw, total, step)
end

-- Cyclic version used by swipe gestures (wraps last→first and first→last).
local function _resolveSwipeNav(cur, total, swipe_dir)
    local step = _pageStep(total)
    local raw
    -- In RTL layouts the user swipes in the opposite physical direction to
    -- move forward, so we invert west/east before acting.
    local dir = swipe_dir
    if BD.mirroredUILayout() then
        if dir == "west" then dir = "east" elseif dir == "east" then dir = "west" end
    end
    if dir == "west" then
        raw = cur + step
        if raw > total then raw = 1 end
    else -- "east"
        raw = cur - step
        if raw < 1 then raw = _lastRawPage(total, step) end
    end
    return _clampPage(raw, total, step)
end

-- ---------------------------------------------------------------------------
-- Footer helpers
-- ---------------------------------------------------------------------------

-- Page bar of the KOReader style: the chevrons and page label over the
-- pagination bar surface.
local ChevronBar = InputContainer:extend{}

function ChevronBar:paintTo(bb, x, y)
    SUIWallpaper.paintPaginationBar(bb, y, self.dimen.h)
    InputContainer.paintTo(self, bb, x, y)
end

local function buildChevronFooter(goto_fn)
    local icon_size  = Bottombar.getPaginationIconSize()
    local font_size  = Bottombar.getPaginationFontSize()
    local spacer     = HorizontalSpan:new{ width = Screen:scaleBySize(32) }

    local chev_left  = BD.mirroredUILayout() and "chevron.right" or "chevron.left"
    local chev_right = BD.mirroredUILayout() and "chevron.left"  or "chevron.right"
    local chev_first = BD.mirroredUILayout() and "chevron.last"  or "chevron.first"
    local chev_last  = BD.mirroredUILayout() and "chevron.first" or "chevron.last"

    local btn_first = Button:new{
        icon = chev_first, icon_width = icon_size, icon_height = icon_size,
        callback = function() goto_fn(1) end, bordersize = 0,
    }
    local btn_prev = Button:new{
        icon = chev_left, icon_width = icon_size, icon_height = icon_size,
        callback = function() goto_fn("prev") end, bordersize = 0,
    }
    local btn_next = Button:new{
        icon = chev_right, icon_width = icon_size, icon_height = icon_size,
        callback = function() goto_fn("next") end, bordersize = 0,
    }
    local btn_last = Button:new{
        icon = chev_last, icon_width = icon_size, icon_height = icon_size,
        callback = function() goto_fn("last") end, bordersize = 0,
    }
    -- Page label: stays enabled (regular text color) and inert, as it has no callback.
    local btn_text = Button:new{
        text = " ", text_font_bold = false, text_font_size = font_size,
        bordersize = 0,
    }

    Bottombar.patchDimmedIcon(btn_first)
    Bottombar.patchDimmedIcon(btn_prev)
    Bottombar.patchDimmedIcon(btn_next)
    Bottombar.patchDimmedIcon(btn_last)

    local page_info = HorizontalGroup:new{
        align = "center",
        btn_first, spacer, btn_prev, spacer,
        btn_text, spacer, btn_next, spacer, btn_last,
    }
    local chev_w    = Screen:getWidth()
    local chev_h    = Bottombar.getPaginationIconSize() + Screen:scaleBySize(8)
    local chev_input = ChevronBar:new{
        dimen = Geom:new{ w = chev_w, h = chev_h },
        CenterContainer:new{
            dimen = Geom:new{ w = chev_w, h = chev_h },
            page_info,
        },
    }
    -- Apply user-defined icon overrides for pagination chevrons.
    -- Since these are SimpleUI-created Buttons (not IconButtons), we use
    -- applyPaginationIcons which calls SS.applyIconToBtn (btn.icon + :init() path).
    pcall(function()
        local ok_ss, SS = pcall(require, "features/sui_style")
        if not (ok_ss and SS and SS.applyPaginationIcons) then return end
        -- Build a pseudo-widget with the four named fields that applyPaginationIcons expects.
        local pseudo = {
            page_info_first_chev = btn_first,
            page_info_left_chev  = btn_prev,
            page_info_right_chev = btn_next,
            page_info_last_chev  = btn_last,
        }
        SS.applyPaginationIcons(pseudo)
    end)
    return {
        widget    = chev_input,
        btn_first = btn_first,
        btn_prev  = btn_prev,
        btn_text  = btn_text,
        btn_next  = btn_next,
        btn_last  = btn_last,
    }
end

local function buildDotFooter(goto_fn)
    local DOT_SIZE = Screen:scaleBySize(7)
    local BAR_H    = Screen:scaleBySize(28)
    local TOUCH_W  = Screen:scaleBySize(32)
    local PILL_H   = Screen:scaleBySize(18)

    local dot_widget = DotWidget:new{
        current_page = 1, total_pages = 1,
        dot_size = DOT_SIZE, bar_h = BAR_H, touch_w = TOUCH_W, pill_h = PILL_H,
    }
    local dot_sz    = dot_widget:getSize()
    local bar_input = InputContainer:new{
        dimen = Geom:new{ w = dot_sz.w, h = dot_sz.h },
        dot_widget,
    }
    bar_input.ges_events = {
        TapDot = {
            GestureRange:new{
                ges   = "tap",
                range = function() return bar_input.dimen end,
            },
        },
        -- Swipe on the dot bar propagates page-turns identically to body swipes.
        SwipeDot = {
            GestureRange:new{
                ges   = "swipe",
                range = function() return bar_input.dimen end,
            },
        },
    }
    function bar_input:onTapDot(_args, ges)
        if not (ges and ges.pos) then return true end
        local total_w  = dot_widget.total_pages * TOUCH_W
        local bar_left = math.floor((Screen:getWidth() - total_w) / 2)
        local tapped   = math.floor((ges.pos.x - bar_left) / TOUCH_W) + 1
        tapped = math.max(1, math.min(tapped, dot_widget.total_pages))
        goto_fn(tapped)
        return true
    end
    function bar_input:onSwipeDot(_args, ges)
        if not ges then return true end
        local dir = ges.direction
        -- Mirror swipe direction for RTL layouts.
        if BD.mirroredUILayout() then
            if dir == "west" then dir = "east" elseif dir == "east" then dir = "west" end
        end
        local cur = dot_widget.current_page
        local tot = dot_widget.total_pages
        if dir == "west" then
            goto_fn(cur < tot and cur + 1 or 1)
        elseif dir == "east" then
            goto_fn(cur > 1 and cur - 1 or tot)
        end
        return true
    end
    local centred = CenterContainer:new{
        dimen = Geom:new{ w = 0, h = BAR_H },  -- w patched in _updateFooter
        bar_input,
    }
    return {
        widget     = centred,
        dot_widget = dot_widget,
        bar_input  = bar_input,
        touch_w    = TOUCH_W,
    }
end

-- Returns the bottombar action id that should be active for `tgt`. Every
-- ScreenWidget instance shares name="homescreen" (see ScreenWidget:init()
-- above), but only the built-in instance (tgt._id == "hs") maps to the
-- "homescreen" tab -- a Custom Screen instance must map to its own
-- "open_custom_screen:<id>" Quick Action id instead (infra/sui_custom_screens.qaId),
-- which is what actually sits on the bar if the user placed that QA there.
local function _bottombarActionIdFor(tgt)
    local id = tgt and tgt._id
    if not id or id == _BUILTIN_ID then return "homescreen" end
    local ok, CustomScreens = pcall(require, "infra/sui_custom_screens")
    if ok and CustomScreens and CustomScreens.qaId then
        return CustomScreens.qaId(id)
    end
    return "homescreen"
end

-- Updates the navpager bottom-bar arrows to reflect the current spread position.
-- `tgt` is the widget instance to update — passed explicitly (rather than
-- read from a singleton) so this works for any ScreenWidget instance,
-- built-in or Custom Screen.
local function _updateNavpager(tgt, current_page, total_pages)
    if not Config.isNavpagerEnabled() then return end
    if not tgt then return end
    Bottombar.syncNavpagerArrows(tgt, _bottombarActionIdFor(tgt),
        current_page > 1, current_page < total_pages)
end


local function openBook(filepath, pos0, page)
    -- ReaderUI:showReader() broadcasts ShowingReader before its first paint,
    -- closing FM/current screen atomically — no need to close it first here.
    local doOpen = function()
        local ReaderUI = package.loaded["apps/reader/readerui"]
            or require("apps/reader/readerui")
        ReaderUI:showReader(VirtualPaths.toVirtual(filepath))
        if pos0 or page then
            UIManager:scheduleIn(0.5, function()
                local rui = package.loaded["apps/reader/readerui"]
                if not (rui and rui.instance) then return end
                if pos0 then
                    rui.instance:handleEvent(
                        require("ui/event"):new("GotoXPointer", pos0, pos0))
                elseif page then
                    rui.instance:handleEvent(
                        require("ui/event"):new("GotoPage", page))
                end
            end)
        end
    end
    if G_reader_settings:isTrue("file_ask_to_open") then
        local Dialogs = require("features/dialogs/sui_dialogs")
        Dialogs.confirm{
            text = _("Open this file?") .. "\n\n" .. BD.filename(filepath:match("([^/]+)$")),
            ok_text = _("Open"),
            ok_callback = doOpen,
        }
    else
        doOpen()
    end
end

-- ---------------------------------------------------------------------------
-- _deferredFreeOldTree(old_tree) — releases a discarded widget subtree
-- (module covers, badges, wallpaper widgets, etc.) without risking a
-- use-after-free, then asks for a collection so the underlying blitbuffers
-- are actually reclaimed.
--
-- Why deferred: calling :free() synchronously, right when the new tree is
-- being swapped in, can tear down an ImageWidget's bb while a paint that
-- was already scheduled against the OLD tree is still in flight, producing
-- a native segfault. UIManager:nextTick lets the current event handler
-- (and any paint it triggered) finish before we reap the old tree.
--
-- Why a collection: blitbuffers are C memory the GC cannot size, so the
-- freed-but-uncollected ones would accumulate across rebuilds. Memory runs
-- one collection once the UI is idle.
-- ---------------------------------------------------------------------------
local function _deferredFreeOldTree(old_tree)
    if not (old_tree and old_tree.free) then return end
    UIManager:nextTick(function()
        local ok, err = pcall(function() old_tree:free() end)
        if not ok then
            logger.warn("simpleui[screen_engine]: old tree free failed:", err)
        end
        Memory.requestCollect()
    end)
end

-- ---------------------------------------------------------------------------
-- ScreenWidget
-- ---------------------------------------------------------------------------

local ScreenWidget = InputContainer:extend{
    name                = "homescreen",
    covers_fullscreen   = true,
    disable_double_tap  = true,
    _on_qa_tap          = nil,
    _on_goal_tap        = nil,
}

-- Returns true when another widget (e.g. a modal dialog) sits on top of the
-- UIManager stack, so gesture handlers can fall through correctly.
local function _hasModalOnTop(screen_widget)
    local top = UI.getTopWindow()
    return top ~= nil and top.widget ~= screen_widget
end

-- ---------------------------------------------------------------------------
-- Gesture routing
--
-- Every handler is a shared ScreenWidget method. Per-instance state is limited
-- to the gesture ranges, the touch-zone bindings and the cached gesture zones.
-- ---------------------------------------------------------------------------

-- Full-screen gesture events, in registration order. Entries flagged `strip`
-- are also registered as priority zones over the top and bottom strips.
local SCREEN_GESTURE_EVENTS = {
    { event = "BlockNavbarTap",       ges = "tap"                            },
    { event = "BlockNavbarHold",      ges = "hold"                           },
    { event = "ScreenSwipe",          ges = "swipe"                          },
    { event = "ScreenDoubleTap",      ges = "double_tap",       strip = true },
    { event = "ScreenTwoFingerTap",   ges = "two_finger_tap",   strip = true },
    { event = "ScreenTwoFingerSwipe", ges = "two_finger_swipe", strip = true },
    { event = "ScreenMultiswipe",     ges = "multiswipe",       strip = true },
    { event = "ScreenSpread",         ges = "spread",           strip = true },
    { event = "ScreenPinch",          ges = "pinch",            strip = true },
    { event = "ScreenRotate",         ges = "rotate",           strip = true },
    { event = "ScreenHold",           ges = "hold",             strip = true },
}

-- G_defaults keys of the zones used to map a touch onto a gesture action.
local GESTURE_ZONE_KEYS = {
    top_left     = "DTAP_ZONE_TOP_LEFT",
    top_right    = "DTAP_ZONE_TOP_RIGHT",
    bottom_left  = "DTAP_ZONE_BOTTOM_LEFT",
    bottom_right = "DTAP_ZONE_BOTTOM_RIGHT",
    left_edge    = "DSWIPE_ZONE_LEFT_EDGE",
    right_edge   = "DSWIPE_ZONE_RIGHT_EDGE",
    top_edge     = "DSWIPE_ZONE_TOP_EDGE",
    bottom_edge  = "DSWIPE_ZONE_BOTTOM_EDGE",
    left_side    = "DDOUBLE_TAP_ZONE_PREV_CHAPTER",
    right_side   = "DDOUBLE_TAP_ZONE_NEXT_CHAPTER",
}

-- Gesture-action names per gesture type as { zone, name } pairs. The first
-- zone containing the touch decides the action.
local ZONE_GESTURES = {
    tap = {
        { "top_left",     "tap_top_left_corner"     },
        { "top_right",    "tap_top_right_corner"    },
        { "bottom_left",  "tap_left_bottom_corner"  },
        { "bottom_right", "tap_right_bottom_corner" },
    },
    hold = {
        { "top_left",     "hold_top_left_corner"     },
        { "top_right",    "hold_top_right_corner"    },
        { "bottom_left",  "hold_bottom_left_corner"  },
        { "bottom_right", "hold_bottom_right_corner" },
    },
    double_tap = {
        { "left_side",    "double_tap_left_side"           },
        { "right_side",   "double_tap_right_side"          },
        { "top_left",     "double_tap_top_left_corner"     },
        { "top_right",    "double_tap_top_right_corner"    },
        { "bottom_left",  "double_tap_bottom_left_corner"  },
        { "bottom_right", "double_tap_bottom_right_corner" },
    },
    two_finger_tap = {
        { "top_left",     "two_finger_tap_top_left_corner"     },
        { "top_right",    "two_finger_tap_top_right_corner"    },
        { "bottom_left",  "two_finger_tap_bottom_left_corner"  },
        { "bottom_right", "two_finger_tap_bottom_right_corner" },
    },
}

-- One-finger swipes starting in an edge zone, keyed by swipe direction.
local EDGE_SWIPES = {
    { zone = "left_edge",   south = "one_finger_swipe_left_edge_down",
                            north = "one_finger_swipe_left_edge_up" },
    { zone = "right_edge",  south = "one_finger_swipe_right_edge_down",
                            north = "one_finger_swipe_right_edge_up" },
    { zone = "top_edge",    east  = "one_finger_swipe_top_edge_right",
                            west  = "one_finger_swipe_top_edge_left" },
    { zone = "bottom_edge", east  = "one_finger_swipe_bottom_edge_right",
                            west  = "one_finger_swipe_bottom_edge_left" },
}

local DIAGONAL_DIRECTIONS = {
    northeast = true, northwest = true, southeast = true, southwest = true,
}

local TWO_FINGER_SWIPES = {}
for _, dir in ipairs({ "east", "west", "north", "south",
                       "northeast", "northwest", "southeast", "southwest" }) do
    TWO_FINGER_SWIPES[dir] = "two_finger_swipe_" .. dir
end

local ROTATE_GESTURES = { cw = "rotate_cw", ccw = "rotate_ccw" }

local CHEVRON_BUTTONS = { "btn_first", "btn_prev", "btn_next", "btn_last" }

-- Reads the gesture zones as ratio tables. Missing defaults are omitted.
local function _readGestureZones()
    local zones = {}
    for name, key in pairs(GESTURE_ZONE_KEYS) do
        local d = G_defaults:readSetting(key)
        if d then
            zones[name] = { ratio_x = d.x, ratio_y = d.y, ratio_w = d.w, ratio_h = d.h }
        end
    end
    return zones
end

-- Horizontal-only zone test, used for the side swipe edges.
local function _inXRange(z, x, sw)
    if not z then return false end
    return x >= z.ratio_x * sw and x < (z.ratio_x + z.ratio_w) * sw
end

-- True when the gesture starts inside the bottom navigation bar.
-- Evaluated per event so it follows orientation changes.
local function _inNavbar(ges)
    if not (ges and ges.pos) then return false end
    return ges.pos.y >= Screen:getHeight() - Bottombar.TOTAL_H()
end

-- Maps a gesture onto the name of a file-manager gesture action, or nil.
local function _resolveGestureName(zones, ges)
    local x, y = ges.pos.x, ges.pos.y
    local gt, dir = ges.ges, ges.direction
    local sw, sh = Screen:getWidth(), Screen:getHeight()

    if gt == "swipe" then
        if DIAGONAL_DIRECTIONS[dir] then
            local distance = ges.distance
            if distance and distance <= Screen:scaleBySize(300) then
                return "short_diagonal_swipe"
            end
            return nil
        end
        for _, edge in ipairs(EDGE_SWIPES) do
            if _inZone(zones[edge.zone], x, y, sw, sh) then
                return edge[dir]
            end
        end
        return nil
    end

    local zone_gestures = ZONE_GESTURES[gt]
    if zone_gestures then
        for _, pair in ipairs(zone_gestures) do
            if _inZone(zones[pair[1]], x, y, sw, sh) then
                return pair[2]
            end
        end
        return nil
    end

    if gt == "two_finger_swipe" then return TWO_FINGER_SWIPES[dir] end
    if gt == "spread"           then return "spread_gesture" end
    if gt == "pinch"            then return "pinch_gesture" end
    if gt == "rotate"           then return ROTATE_GESTURES[dir] end
end

local function _broadcastSend(_, event)
    return UIManager:broadcastEvent(event)
end

-- Calls fn(...) in protected mode with UIManager.sendEvent routed through
-- broadcastEvent, so events emitted by a gesture action reach every listener.
local function _pcallBroadcasting(fn, ...)
    local orig_sendEvent = UIManager.sendEvent
    UIManager.sendEvent = _broadcastSend
    local ok, err = pcall(fn, ...)
    UIManager.sendEvent = orig_sendEvent
    return ok, err
end

-- Returns the file manager's top menu, or nil when it is not available.
local function _getFMMenu()
    local FM = package.loaded["apps/filemanager/filemanager"]
    local fm = FM and FM.instance
    return fm and fm.menu or nil
end

-- Depth-first search for the first widget (self included) exposing its own
-- onSwipe handler. Locates the swipeable widget nested inside a book module.
local function _findSwipeWidget(w, maxdepth)
    if not w or maxdepth <= 0 or type(w) ~= "table" then return nil end
    if type(w.onSwipe) == "function" then return w end
    for i = 1, #w do
        local found = _findSwipeWidget(w[i], maxdepth - 1)
        if found then return found end
    end
    return nil
end

local function _pageHasMod(mods, mod_id)
    for _, m in ipairs(mods) do
        if m.id == mod_id then return true end
    end
    return false
end

-- Vertical extent, as screen ratios, of the navbar plus pagination footer.
local function _footerZoneRatios()
    local sh         = Screen:getHeight()
    local combined_h = Bottombar.TOTAL_H()
        + Bottombar.getPaginationIconSize() + Screen:scaleBySize(8)
    return (sh - combined_h) / sh, combined_h / sh
end

-- Height ratio of the top strip that opens the main menu: it spans the top
-- bar when that is enabled, and the default menu zone otherwise.
local function _menuZoneHeightRatio(menu_zone)
    if SUISettings:nilOrTrue("simpleui_topbar_enabled") then
        local ok, Topbar = pcall(require, "screens/sui_topbar")
        if ok then
            return (Topbar.TOTAL_TOP_H() + MOD_GAP) / Screen:getHeight()
        end
    end
    return menu_zone.h
end

-- Physical-key bindings for this device.
local function _buildKeyEvents()
    local keys = {}
    if Device:hasDPad() then
        keys.ScreenFocusUp    = { { "Up"    } }
        keys.ScreenFocusDown  = { { "Down"  } }
        keys.ScreenFocusLeft  = { { "Left"  } }
        keys.ScreenFocusRight = { { "Right" } }
        keys.ScreenKbPress    = { { "Press" } }
    end
    if Device:hasKeys() then
        keys.ScreenOpenMenu = { { "Menu" } }
        keys.PrevPage       = { { Device.input.group.PgBack } }
        keys.NextPage       = { { Device.input.group.PgFwd } }
    end
    return keys
end

function ScreenWidget:init()
    -- ---------------------------------------------------------------------
    -- Instance parametrisation.
    --
    -- self.instance = { id, pfx, layout_key, title?, left_icon?, ... } is
    -- always supplied by the caller of ScreenEngine._open() —
    -- screens/sui_homescreen.lua's own ScreenEngine.show() for the built-in
    -- Homescreen, or ScreenEngine.showCustomScreen(screen_id) (instance comes
    -- from infra/sui_custom_screens) for a Custom Screen. This engine has no
    -- default of its own for id/pfx/layout_key. Every settings read/write
    -- in this file goes through self._pfx / self._pfx_qa / self._layout_key
    -- instead of a module-level constant, so the exact same class renders
    -- any number of independent screens.
    --
    -- title / left_icon are optional: when the caller omits them (as the
    -- built-in Homescreen does), the title bar falls back to _("Home
    -- Screen") and the "home" icon — see the TitleBar construction below.
    -- A Custom Screen's instance_cfg (built in ScreenEngine.showCustomScreen)
    -- always supplies both, so its title bar — and, importantly, what the
    -- KOReader screen reader announces on open — reflects the screen the
    -- user actually opened rather than always announcing the Homescreen.
    -- ---------------------------------------------------------------------
    local inst = self.instance
    assert(inst and inst.id, "ScreenWidget:init(): instance_cfg with an id is required")
    self._id         = inst.id
    self._pfx        = inst.pfx
    self._pfx_qa     = inst.pfx and (inst.pfx .. "qa_")
    self._layout_key = inst.layout_key

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self.dimen = Geom:new{ w = sw, h = sh }

    self.ges_events     = self:_buildGestureEvents()
    self.key_events     = _buildKeyEvents()
    self._gesture_zones = _readGestureZones()

    -- title/left_icon are optional instance_cfg fields (see the contract
    -- comment above): a Custom Screen supplies its own name/icon so its
    -- title bar — including the text the KOReader screen reader announces on
    -- open — matches what the user actually opened. The fallbacks preserve
    -- the built-in Homescreen's identity, which relies on them rather than
    -- passing the fields explicitly.
    self.title_bar = TitleBar:new{
        show_parent             = self,
        fullscreen              = true,
        title                   = inst.title or _("Home Screen"),
        left_icon               = inst.left_icon or "home",
        left_icon_tap_callback  = function() self:onClose() end,
        left_icon_hold_callback = false,
    }

    -- Per-instance state — freed in onCloseWidget.
    self._vspan_pool         = {}
    self._wrapper_pool       = {}
    self._book_mod_refresh_n = {}  -- mod_id -> count of "ui" (non-flashing) refreshes since the last "flashui"; see _refreshBookModSlot
    self._kb_rows            = {}
    self._kb_row_by_key      = {}
    self._kb_stop            = nil
    self._db_conn            = nil
    self._cover_poll_timer   = nil
    self._cover_mod_slots    = nil
    self._enabled_mods_cache = nil
    self._ctx_cache          = nil
    self._current_page       = self._current_page or 1
    self.page                = self._current_page
    self.page_num            = 1
    self._clock_body_ref     = nil
    self._clock_body_idx     = nil
    self._clock_is_wrapped   = nil
    self._clock_pfx          = nil
    self._clock_inner_w      = nil
    self._clock_live         = nil
    self._overflow_warn_key  = nil

    -- Minimal placeholder so patches.lua can call wrapWithNavbar safely.
    -- Real content is built in onShow() once _navbar_content_h is set.
    self[1] = FrameContainer:new{
        bordersize = 0, padding = 0,
        dimen      = Geom:new{ w = sw, h = sh },
        VerticalSpan:new{ width = sh },
    }

    self:_registerMenuZones()
    self:_registerFooterZones()
    self:_registerStripZones()
end

-- ---------------------------------------------------------------------------
-- Gesture events and touch zones
-- ---------------------------------------------------------------------------

-- Builds one full-screen gesture range per SCREEN_GESTURE_EVENTS entry. The
-- range is resolved at match time because the widget's dimen is resized and
-- positioned after construction.
function ScreenWidget:_buildGestureEvents()
    local function fullRange() return self.dimen end
    local events = {}
    for _, def in ipairs(SCREEN_GESTURE_EVENTS) do
        events[def.event] = { GestureRange:new{ ges = def.ges, range = fullRange } }
    end
    return events
end

-- Top strip that opens the KOReader main menu, mirroring what
-- FileManagerMenu:initGesListener does for the library.
function ScreenWidget:_registerMenuZones()
    local menu_zone     = G_defaults:readSetting("DTAP_ZONE_MENU")
    local menu_zone_ext = G_defaults:readSetting("DTAP_ZONE_MENU_EXT")
    if not (menu_zone and menu_zone_ext) then return end

    local screen_zone = {
        ratio_x = 0, ratio_y = 0, ratio_w = 1,
        ratio_h = _menuZoneHeightRatio(menu_zone),
    }
    self:registerTouchZones({
        {
            id          = self._pfx .. "menu_tap",
            ges         = "tap",
            screen_zone = screen_zone,
            handler     = function(ges) return self:_onMenuTap(ges) end,
        },
        {
            id          = self._pfx .. "menu_swipe",
            ges         = "swipe",
            screen_zone = screen_zone,
            handler     = function(ges) return self:_onMenuSwipe(ges) end,
        },
    })
end

-- Combined navbar + pagination footer strip. These zones take precedence over
-- the full-screen tap and swipe events for gestures landing inside it.
function ScreenWidget:_registerFooterZones()
    local ratio_y, ratio_h = _footerZoneRatios()
    local screen_zone = { ratio_x = 0, ratio_y = ratio_y, ratio_w = 1, ratio_h = ratio_h }
    self:registerTouchZones({
        {
            id          = self._pfx .. "footer_tap",
            ges         = "tap",
            screen_zone = screen_zone,
            overrides   = { "BlockNavbarTap" },
            handler     = function(ges) return self:_onFooterTap(ges) end,
        },
        {
            id          = self._pfx .. "footer_swipe",
            ges         = "swipe",
            screen_zone = screen_zone,
            overrides   = { "ScreenSwipe" },
            handler     = function(ges) return self:_onFooterSwipe(ges) end,
        },
    })
end

-- Top and bottom strips that forward multi-touch and hold gestures to the
-- file-manager gesture actions before the full-screen events see them.
function ScreenWidget:_registerStripZones()
    local menu_zone = G_defaults:readSetting("DTAP_ZONE_MENU")
    local footer_y, footer_h = _footerZoneRatios()
    local top_zone    = { ratio_x = 0, ratio_y = 0,        ratio_w = 1,
                          ratio_h = (menu_zone and menu_zone.h) or 0.1 }
    local bottom_zone = { ratio_x = 0, ratio_y = footer_y, ratio_w = 1, ratio_h = footer_h }
    local handler     = function(ges) return self:_fmGestureAction(ges) end

    local zones = {}
    for _, def in ipairs(SCREEN_GESTURE_EVENTS) do
        if def.strip then
            local overrides = { def.event }
            zones[#zones + 1] = {
                id          = self._pfx .. "top_" .. def.ges,
                ges         = def.ges,
                screen_zone = top_zone,
                overrides   = overrides,
                handler     = handler,
            }
            zones[#zones + 1] = {
                id          = self._pfx .. "bottom_" .. def.ges,
                ges         = def.ges,
                screen_zone = bottom_zone,
                overrides   = overrides,
                handler     = handler,
            }
        end
    end
    self:registerTouchZones(zones)
end

function ScreenWidget:_onMenuTap(ges)
    if _hasModalOnTop(self) then return false end
    local menu = _getFMMenu()
    if menu then return menu:onTapShowMenu(ges) end
end

function ScreenWidget:_onMenuSwipe(ges)
    if _hasModalOnTop(self) then return false end
    local menu = _getFMMenu()
    if menu and menu:onSwipeShowMenu(ges) then return true end
    return self:_fmGestureAction(ges)
end

function ScreenWidget:_onFooterTap(ges)
    if _hasModalOnTop(self) then return false end
    if self:_fmGestureAction(ges) then return true end

    local footer_bc = self._footer_bc
    if not footer_bc or footer_bc.dimen.h == 0 then return false end

    if Config.isNavpagerEnabled() or Config.isDotPagerEnabled() then
        local dots = self._footer_dot
        if dots and dots.bar_input then
            return dots.bar_input:handleEvent(Event:new("Gesture", ges))
        end
        return false
    end

    local chevrons = self._footer_chevron
    if chevrons and ges.pos then
        for _, name in ipairs(CHEVRON_BUTTONS) do
            local btn = chevrons[name]
            local d   = btn and btn.dimen
            if d and ges.pos:intersectWith(d) then
                if btn.enabled ~= false then btn.callback() end
                return true
            end
        end
    end
    return false
end

function ScreenWidget:_onFooterSwipe(ges)
    if _hasModalOnTop(self) then return false end
    if self:_fmGestureAction(ges) then return true end

    local footer_bc = self._footer_bc
    if not footer_bc or footer_bc.dimen.h == 0 then return false end

    local dir = ges and ges.direction
    if (self._total_pages or 1) <= 1 then return false end
    if dir ~= "west" and dir ~= "east" then return false end

    self:_swipePage(dir)
    return true
end

-- ---------------------------------------------------------------------------
-- Gesture handlers
-- ---------------------------------------------------------------------------

-- Forwards a gesture to the file-manager gesture actions (the same gesture
-- set as docless file-manager mode). Returns true when an action is bound to
-- the resolved gesture, nil otherwise.
function ScreenWidget:_fmGestureAction(ges)
    local FileManager = require("apps/filemanager/filemanager")
    local fm_gestures = FileManager.instance and FileManager.instance.gestures
    if not fm_gestures then return end
    if not ges.pos then return end

    if ges.ges == "multiswipe" then
        local ok, err = _pcallBroadcasting(
            fm_gestures.multiswipeAction, fm_gestures, ges.multiswipe_directions, ges)
        if not ok then logger.warn("simpleui screen gesture multiswipe:", err) end
        return true
    end

    local name = _resolveGestureName(self._gesture_zones, ges)
    if not name then return end

    -- gestureAction() is a no-op when the gesture has no action configured.
    local configured = fm_gestures.gestures
    local ok, err = _pcallBroadcasting(fm_gestures.gestureAction, fm_gestures, name, ges)
    if not ok then logger.warn("simpleui screen gesture:", name, err) end
    if configured and configured[name] ~= nil then return true end
end

-- True when the gesture starts in the left or right swipe-edge zone.
function ScreenWidget:_isSideEdge(ges)
    if not (ges and ges.pos) then return false end
    local x, sw = ges.pos.x, Screen:getWidth()
    local zones = self._gesture_zones
    return _inXRange(zones.left_edge, x, sw) or _inXRange(zones.right_edge, x, sw)
end

-- True when module `mod_id` is laid out on the visible page (or, in landscape,
-- on either page of the visible spread).
function ScreenWidget:_isModOnVisiblePage(mod_id)
    local pages = self._enabled_mods_cache and self._enabled_mods_cache.pages_of_mods
    local cur   = self._current_page or 1
    local mods  = pages and pages[cur]
    if not mods then return false end
    if _pageHasMod(mods, mod_id) then return true end
    local next_mods = _isLandscape() and pages[cur + 1]
    return next_mods and _pageHasMod(next_mods, mod_id) or false
end

-- Screen-space area a book module occupies. The pooled layout wrapper is
-- preferred when present: the raw build() result sits inside the module chrome
-- and may not carry absolute dimensions, while the wrapper always does.
function ScreenWidget:_bookModHitDimen(mod_id, slot)
    local wrapper = slot.has_menu and self._wrapper_pool and self._wrapper_pool[mod_id]
    return (wrapper and wrapper.dimen) or (slot.widget and slot.widget.dimen)
end

-- Hands a horizontal swipe to the swipeable widget of the visible book module
-- under the touch point (a carousel, a paginated collection, ...) instead of
-- turning the screen page. Returns true when that widget consumed the swipe.
function ScreenWidget:_swipeBookMod(ges)
    local slots = self._book_mod_slots
    if not (ges.pos and slots) then return false end

    for mod_id, slot in pairs(slots) do
        if self:_isModOnVisiblePage(mod_id) then
            local hit_dimen = self:_bookModHitDimen(mod_id, slot)
            if hit_dimen and ges.pos:intersectWith(hit_dimen) then
                local swipe_widget = _findSwipeWidget(slot.widget, 8)
                if swipe_widget and swipe_widget:onSwipe(nil, ges) then
                    return true
                end
                -- The touch belongs to this module; siblings are not tested.
                return false
            end
        end
    end
    return false
end

function ScreenWidget:onScreenSwipe(_args, ges)
    if ges then
        local dir = ges.direction
        if (dir == "west" or dir == "east") and not self:_isSideEdge(ges) then
            if not self:_swipeBookMod(ges) then self:_swipePage(dir) end
            return true
        end
    end
    return self:_fmGestureAction(ges)
end

-- Gestures forwarded verbatim to the file-manager gesture actions.
local function onForwardedGesture(self, _args, ges)
    return self:_fmGestureAction(ges)
end
ScreenWidget.onScreenTwoFingerSwipe = onForwardedGesture
ScreenWidget.onScreenDoubleTap      = onForwardedGesture
ScreenWidget.onScreenTwoFingerTap   = onForwardedGesture
ScreenWidget.onScreenMultiswipe     = onForwardedGesture
ScreenWidget.onScreenSpread         = onForwardedGesture
ScreenWidget.onScreenPinch          = onForwardedGesture
ScreenWidget.onScreenRotate         = onForwardedGesture

-- Forwarded file-manager corner gestures take priority over the navbar guard.
function ScreenWidget:onBlockNavbarTap(_args, ges)
    if _hasModalOnTop(self) then return false end
    if self:_fmGestureAction(ges) then return true end
    if ges and ges.pos then
        local zones  = self._gesture_zones
        local x, y   = ges.pos.x, ges.pos.y
        local sw, sh = Screen:getWidth(), Screen:getHeight()
        if _inZone(zones.bottom_left, x, y, sw, sh)
                or _inZone(zones.bottom_right, x, y, sw, sh) then
            return  -- let the corner tap through
        end
    end
    if _inNavbar(ges) then return true end
end

function ScreenWidget:onScreenHold(_args, ges)
    if _hasModalOnTop(self) then return false end
    if _inNavbar(ges) then return true end
    return self:_fmGestureAction(ges)
end

function ScreenWidget:onBlockNavbarHold(_args, ges)
    if _hasModalOnTop(self) then return false end
    if _inNavbar(ges) then return true end
end

function ScreenWidget:onScreenOpenMenu()
    local menu = _getFMMenu()
    if menu then menu:onTapShowMenu() end
    return true
end

-- ---------------------------------------------------------------------------
-- Physical D-pad navigation (Kindle and similar devices)
-- ---------------------------------------------------------------------------

-- Focus rows, top to bottom: the rows of stops that modules register through
-- ctx.kbStops (a tab strip, a row of quick actions, the cells of a grid row,
-- a page indicator, ...). Inside a row, Left/Right move between its stops and
-- Press runs the stop's action; Up/Down move to the row above or below, at the
-- same column when it has one.

-- Sets the row `key` to `stops`, a list of { id, widget } from left to right
-- whose widgets come from UI.makeFocusable. The row is replaced when it
-- exists (a module rebuilt on its own), else added after the others. A row
-- with no stops keeps its place and is skipped by the navigation, so a module
-- can reserve its position ahead of the rows it fills in later. The stop that
-- holds the focus is framed; when its id is gone the focus moves to the stop
-- at the same position.
function ScreenWidget:_kbSetRow(key, stops)
    local row = self._kb_row_by_key[key]
    if row then
        row.stops = stops
    else
        row = { key = key, stops = stops }
        self._kb_rows[#self._kb_rows + 1] = row
        self._kb_row_by_key[key] = row
    end
    local focus = self._kb_stop
    if not (focus and focus.key == key) then return end
    local col
    for i, stop in ipairs(stops) do
        if stop.id == focus.id then col = i; break end
    end
    col = col or math.min(focus.col, #stops)
    if col < 1 then
        self._kb_stop = nil
        return
    end
    focus.id, focus.col = stops[col].id, col
    stops[col].widget._kb_focused = true
end

-- Returns the row and the stop that hold the stop focus; nil when none does.
function ScreenWidget:_kbFocusedStop()
    local focus = self._kb_stop
    local row   = focus and self._kb_row_by_key[focus.key]
    local stop  = row and row.stops[focus.col]
    if not stop then
        self._kb_stop = nil
        return nil
    end
    return row, stop
end

-- Lists the rows that have stops, top to bottom.
function ScreenWidget:_kbActiveRows()
    local rows = {}
    for _i, row in ipairs(self._kb_rows) do
        if #row.stops > 0 then rows[#rows + 1] = row end
    end
    return rows
end

-- Index in `rows` of the row that holds the focus; nil when none does.
function ScreenWidget:_kbRowIndex(rows)
    local row = self:_kbFocusedStop()
    for i, candidate in ipairs(rows) do
        if candidate == row then return i end
    end
end

-- Moves the stop focus to column `col` of `row`, repainting only the two
-- stops involved.
function ScreenWidget:_kbSetStop(row, col)
    local _, old = self:_kbFocusedStop()
    local new = row.stops[col]
    if old then old.widget:handleEvent(Event:new("Unfocus")) end
    self._kb_stop = { key = row.key, id = new.id, col = col }
    new.widget:handleEvent(Event:new("Focus"))
    if old then UIManager:setDirty(self, "ui", old.widget.dimen) end
    UIManager:setDirty(self, "ui", new.widget.dimen)
end

-- Moves the focus into `row`, at column `col` (clamped).
function ScreenWidget:_kbEnterRow(row, col)
    self:_kbSetStop(row, math.min(col or 1, #row.stops))
    return true
end

-- Drops the stop focus, repainting the stop that held it.
function ScreenWidget:_kbClearStop()
    local _, stop = self:_kbFocusedStop()
    self._kb_stop = nil
    if not stop then return end
    stop.widget:handleEvent(Event:new("Unfocus"))
    UIManager:setDirty(self, "ui", stop.widget.dimen)
end

-- Moves keyboard focus off the screen into the navbar. `restore_stop` is the
-- stop focus re-applied when focus returns from the navbar.
function ScreenWidget:_focusNavbar(restore_stop)
    self:_kbClearStop()
    require("infra/sui_patches").enterNavbarKbFocus(function()
        local row = restore_stop and self._kb_row_by_key[restore_stop.key]
        if row and row.stops[restore_stop.col] then self:_kbSetStop(row, restore_stop.col) end
    end)
    return true
end

function ScreenWidget:onScreenFocusUp()
    local rows = self:_kbActiveRows()
    if #rows == 0 then return end
    local cur = self:_kbRowIndex(rows)
    if not cur then return self:_kbEnterRow(rows[#rows], 1) end
    if cur > 1 then self:_kbEnterRow(rows[cur - 1], self._kb_stop.col) end
    return true
end

function ScreenWidget:onScreenFocusDown()
    local rows = self:_kbActiveRows()
    local cur  = self:_kbRowIndex(rows)
    if not cur then
        if #rows == 0 then return self:_focusNavbar() end
        return self:_kbEnterRow(rows[1], 1)
    end
    if rows[cur + 1] then return self:_kbEnterRow(rows[cur + 1], self._kb_stop.col) end
    return self:_focusNavbar(self._kb_stop)
end

-- Moves the focus `step` stops along its row; stays at either end.
function ScreenWidget:_kbMoveStop(step)
    local row = self:_kbFocusedStop()
    if not row then return end
    local col = self._kb_stop.col + step
    if row.stops[col] then self:_kbSetStop(row, col) end
    return true
end

function ScreenWidget:onScreenFocusLeft()
    return self:_kbMoveStop(-1)
end

function ScreenWidget:onScreenFocusRight()
    return self:_kbMoveStop(1)
end

function ScreenWidget:onScreenKbPress()
    local _, stop = self:_kbFocusedStop()
    if not stop then return end
    stop.widget:onTapSelect()
    return true
end

-- ---------------------------------------------------------------------------
-- Page navigation
--
-- The navbar pager looks for onPrevPage/onNextPage/onGotoPage and the
-- page/page_num fields on the topmost pageable widget.
-- ---------------------------------------------------------------------------

function ScreenWidget:_setPage(page)
    self._current_page = page
    self.page          = page
    self:_refresh(true, nil, nil, true)
end

-- Turns to the previous or next page (or spread) without wrapping.
function ScreenWidget:_stepPage(dir)
    local cur      = self._current_page or 1
    local new_page = _resolvePageNav(cur, self._total_pages or 1, dir)
    if new_page ~= cur then self:_setPage(new_page) end
    return true
end

-- Turns the page for a horizontal swipe, wrapping around at either end.
function ScreenWidget:_swipePage(swipe_dir)
    local cur, total = self._current_page or 1, self._total_pages or 1
    local new_page   = _resolveSwipeNav(cur, total, swipe_dir)
    if new_page ~= cur or total == 1 then self:_setPage(new_page) end
end

function ScreenWidget:onPrevPage() return self:_stepPage("prev") end
function ScreenWidget:onNextPage() return self:_stepPage("next") end

-- `spread` is a spread index, not a raw page number.
function ScreenWidget:onGotoPage(spread)
    self:_setPage(_resolvePageNav(1, self._total_pages or 1, spread))
    return true
end

-- ---------------------------------------------------------------------------
-- _vspan — per-instance VerticalSpan pool; freed on close.
-- ---------------------------------------------------------------------------
function ScreenWidget:_vspan(px)
    local pool = self._vspan_pool
    if not pool[px] then pool[px] = VerticalSpan:new{ width = px } end
    return pool[px]
end

-- ---------------------------------------------------------------------------
-- _initLayout — builds the persistent widget tree (called once per show).
-- ---------------------------------------------------------------------------
function ScreenWidget:_initLayout()
    local sw        = Screen:getWidth()
    -- Defensive fallback: UI.getContentHeight() (infra/sui_core.lua) is the
    -- same bar-aware value UI.applyNavbarState() would set into
    -- self._navbar_content_h during navbar injection. Using it here instead
    -- of the raw, bar-covering Screen height means that if injection is ever
    -- skipped or runs late for some reason, content still stops above the
    -- bar instead of silently extending underneath it.
    local content_h = self._navbar_content_h or UI.getContentHeight()
    local side_off  = UI.SIDE_PAD()
    local inner_w   = UI.getInnerW(sw)

    self._layout_sw        = sw
    self._layout_content_h = content_h
    self._layout_inner_w   = inner_w

    local body = VerticalGroup:new{ align = "left" }
    self._body = body

    -- Reset the VerticalSpan pool (see _vspan): keyed and reused across
    -- _updatePage() calls, so it must not keep spacers shared between the
    -- OLD tree (about to be handed to _deferredFreeOldTree()) and the NEW
    -- one being built here.
    self._vspan_pool = {}

    -- Reset the per-module InputContainer wrapper pool (see _makeModWrapper).
    -- The pool avoids reallocating a wrapper + its GestureRanges on every
    -- _updatePage() call (page turns, stats-only refreshes), which is safe
    -- as long as the wrapper stays inside one single live tree.
    --
    -- _initLayout() builds a brand-new overlap/body that the caller swaps
    -- into self._navbar_container, sending the previous tree to
    -- _deferredFreeOldTree() for a deferred :free(). Clearing the pool here
    -- forces fresh wrappers for the new tree, so old and new trees never
    -- share a node — the deferred free then only ever touches widgets that
    -- truly belong to the tree being discarded.
    self._wrapper_pool = {}

    -- Module widgets are transparent by default (no background field set), so
    -- the device/screen background colour shows through when no wallpaper is
    -- active.  When a wallpaper is set we simply paint it behind the widget
    -- tree via a paintTo override — no conditional background juggling needed.
    local _lf_bg = SUIWallpaper.styleGetBgWidget()

    local content_widget = FrameContainer:new{
        bordersize   = 0, padding = 0,
        padding_left = side_off, padding_right = side_off,
        dimen        = Geom:new{ w = sw, h = content_h },
        body,
    }
    local outer = FrameContainer:new{
        bordersize = 0, padding = 0,
        dimen      = Geom:new{ w = sw, h = content_h },
        content_widget,
    }

    -- The wallpaper raster is screen-sized, so when the bars are transparent
    -- it bleeds behind the topbar and bottombar with no extra work needed here.
    if _lf_bg then
        local _orig_paintTo = content_widget.paintTo
        function content_widget:paintTo(bb, x, y)
            -- Always paint from y=0 so the wallpaper is anchored at the top
            -- and covers the full screen area.
            SUIWallpaper.paintBackground(bb, x)
            _orig_paintTo(self, bb, x, y)
        end
    end

    -- Navigation callback shared by both footer types.
    local self_ref = self
    local function _goto(page)
        local total     = self_ref._total_pages or 1
        local cur_raw   = self_ref._current_page or 1
        local target_raw = _resolvePageNav(cur_raw, total, page)
        target_raw = math.max(1, math.min(target_raw, total))
        if target_raw ~= cur_raw then
            self_ref._current_page = target_raw
            self_ref:_refresh(true)
        end
    end

    self._footer_chevron     = buildChevronFooter(_goto)
    self._footer_dot         = buildDotFooter(_goto)
    self._footer_hidden_span = VerticalSpan:new{ width = 0 }

    local footer_bc = BottomContainer:new{
        dimen = Geom:new{ w = sw, h = content_h },
        self._footer_chevron.widget,
    }
    self._footer_bc = footer_bc

    local overlap = OverlapGroup:new{
        allow_mirroring = false,
        dimen           = Geom:new{ w = sw, h = content_h },
        outer,
        footer_bc,
    }
    self._overlap = overlap
    return overlap
end

-- ---------------------------------------------------------------------------
-- _swapLayoutTree — swaps a freshly-built overlap (from _initLayout) into
-- self._navbar_container, preserving the outgoing tree's overlap_offset,
-- and frees the outgoing tree via _deferredFreeOldTree.
--
-- Also updates self._navbar_inner to point at the new overlap. That field
-- is the reference sui_bottombar.lua's rewrapAllWidgets() (and other
-- rewrap-style callers) read to re-wrap "the current content" with a fresh
-- navbar container — leaving it pointing at the discarded tree would make a
-- later rewrap re-wrap content already handed to _deferredFreeOldTree().
-- ---------------------------------------------------------------------------
function ScreenWidget:_swapLayoutTree(overlap)
    local old = self._navbar_container[1]
    if old and old.overlap_offset then
        overlap.overlap_offset = old.overlap_offset
    end
    self._navbar_container[1] = overlap
    self._navbar_inner        = overlap
    _deferredFreeOldTree(old)
end

-- Resolves the current and recent books for the book modules enabled on this
-- screen. Returns nil when the shared book module is unavailable.
--
-- Show-finished filtering is not applied here: each module filters finished
-- books at render time using its own setting. The number of recent books
-- comes from the enabled modules' M.needs.recent (Registry.getRecentDemand),
-- which leaves headroom for that filtering.
function ScreenWidget:_prefetchBooks()
    local SH = _getBookShared()
    if not SH then return nil end
    local show_c = Registry.isEnabled(Registry.get("currently"), self._pfx)
    local recent_demand = Registry.getRecentDemand(self._pfx)
    return SH.prefetchBooks(show_c, recent_demand > 0, recent_demand,
        { exclude_current = SH.isCurrentExcluded(self._pfx) })
end

-- ---------------------------------------------------------------------------
-- _buildCtx — constructs the module build context for the current render.
-- ---------------------------------------------------------------------------
function ScreenWidget:_buildCtx()
    -- Provisional; _updatePage() overwrites it with the column-width-derived
    -- factor before modules build. 1 in portrait.
    local landscape_factor = UI.isLandscape() and UI.getLandscapeFactor() or 1

    -- Pre-read all per-module settings once so module build() functions never
    -- call Config.get* or G_reader_settings during widget construction.
    -- The bundle is cached cross-instance and only cleared on settings change.
    -- scale/thumb_scale/lbl_scale below are RAW; module_currently.lua and
    -- module_coverdeck.lua apply ctx.landscape_factor at the point of use.
    local cfg = self._cfg_cache
    if not cfg then
        cfg = {
            currently = {
                scale       = Config.getModuleScale("currently", self._pfx),
                thumb_scale = Config.getThumbScale("currently", self._pfx),
                lbl_scale   = Config.getItemLabelScale("currently", self._pfx),
                bar_style   = SUISettings:readSetting(self._pfx .. "currently_bar_style"),
                stats_style = SUISettings:readSetting(self._pfx .. "currently_stats_style"),
                stats_icon  = SUISettings:nilOrTrue(self._pfx .. "currently_stats_icon"),
                layout      = SUISettings:readSetting(self._pfx .. "currently_layout") == "dynamic" and "dynamic" or "default",
                main_order  = SUISettings:readSetting(self._pfx .. "currently_main_order"),
                stats_order = SUISettings:readSetting(self._pfx .. "currently_stats_order"),
                desc_align  = SUISettings:readSetting(self._pfx .. "currently_description_align"),
                show = {
                    title       = SUISettings:nilOrTrue(self._pfx .. "currently_show_title"),
                    author      = SUISettings:nilOrTrue(self._pfx .. "currently_show_author"),
                    series      = SUISettings:nilOrTrue(self._pfx .. "currently_show_series"),
                    description = SUISettings:nilOrTrue(self._pfx .. "currently_show_description"),
                    progress    = SUISettings:nilOrTrue(self._pfx .. "currently_show_progress"),
                    stats       = SUISettings:nilOrTrue(self._pfx .. "currently_show_stats"),
                    percent        = SUISettings:nilOrTrue(self._pfx .. "currently_show_percent"),
                    book_days      = SUISettings:nilOrTrue(self._pfx .. "currently_show_book_days"),
                    book_time      = SUISettings:nilOrTrue(self._pfx .. "currently_show_book_time"),
                    book_remaining = SUISettings:nilOrTrue(self._pfx .. "currently_show_book_remaining"),
                },
            },
            coverdeck = {
                scale         = Config.getModuleScale("coverdeck", self._pfx),
                thumb_scale   = Config.getThumbScale("coverdeck", self._pfx),
                lbl_scale     = Config.getItemLabelScale("coverdeck", self._pfx),
                source        = SUISettings:readSetting(self._pfx .. "coverdeck_source") or "recent",
                style         = SUISettings:readSetting(self._pfx .. "coverdeck_style"),
                show_finished = SUISettings:readSetting(self._pfx .. "coverdeck_show_finished") == true,
                main_order    = SUISettings:readSetting(self._pfx .. "coverdeck_main_order"),
                show = {
                    title    = SUISettings:nilOrTrue(self._pfx .. "coverdeck_show_title"),
                    author   = SUISettings:nilOrTrue(self._pfx .. "coverdeck_show_author"),
                    progress = SUISettings:nilOrTrue(self._pfx .. "coverdeck_show_progress"),
                    stats    = SUISettings:nilOrTrue(self._pfx .. "coverdeck_show_stats"),
                    percent  = SUISettings:nilOrTrue(self._pfx .. "coverdeck_show_percent"),
                    book_days      = SUISettings:nilOrTrue(self._pfx .. "coverdeck_show_book_days"),
                    book_time      = SUISettings:nilOrTrue(self._pfx .. "coverdeck_show_book_time"),
                    book_remaining = SUISettings:nilOrTrue(self._pfx .. "coverdeck_show_book_remaining"),
                },
                elem_order    = SUISettings:readSetting(self._pfx .. "coverdeck_stats_order"),
            },
        }
        -- Text styles of every enabled module that declares user-selectable
        -- text elements (M.text_elems). This cache is dropped together with
        -- the enabled-modules cache.
        for _i, mod in ipairs(Registry.list()) do
            if Registry.isEnabled(mod, self._pfx) and mod.text_elems then
                cfg[mod.id] = cfg[mod.id] or {}
                cfg[mod.id].text = Config.readTextStyles(mod.id, mod.text_elems, self._pfx)
            end
        end
        self._cfg_cache = cfg
    end

    local mod_c  = Registry.get("currently")
    local mod_cd = Registry.get("coverdeck")
    local show_c = mod_c and Registry.isEnabled(mod_c, self._pfx)
    local show_r = Registry.getRecentDemand(self._pfx) > 0

    if not self._cached_books_state then
        local SH = _getBookShared()
        if SH then
            if show_c or show_r then
                self._cached_books_state = self:_prefetchBooks()
                if Config.cover_extraction_pending then
                    self:_scheduleCoverPoll()
                end
            else
                self._cached_books_state = { current_fp = nil, recent_fps = {}, prefetched_data = {} }
            end
        else
            logger.warn("simpleui: screen (" .. tostring(self._id) .. "): cannot load module_books_shared")
            self._cached_books_state = { current_fp = nil, recent_fps = {}, prefetched_data = {} }
        end
    end

    local bs          = self._cached_books_state
    local mod_rg      = Registry.get("reading_goals")
    local rg_active   = mod_rg and Registry.isEnabled(mod_rg, self._pfx)

    -- Data the enabled modules ask for through M.needs (every instance of a
    -- module counts), see Registry.wantsData.
    local needs_db    = Registry.wantsData(self._pfx, "db")
    local wants_stats = rg_active or Registry.wantsData(self._pfx, "stats")

    -- Determine whether the coverdeck needs DB access (i.e. at least one stat
    -- beyond "percent" is visible).  "percent" comes from prefetched metadata
    -- and never requires a DB query.
    local cd_cfg = cfg and cfg.coverdeck
    local coverdeck_needs_db = mod_cd and Registry.isEnabled(mod_cd, self._pfx) and (
        (cd_cfg and cd_cfg.show and cd_cfg.show.stats ~= false and
            (cd_cfg.show.book_days or cd_cfg.show.book_time or cd_cfg.show.book_remaining))
        or (not (cd_cfg and cd_cfg.show) and (
            SUISettings:nilOrTrue(self._pfx .. "coverdeck_show_book_days") or
            SUISettings:nilOrTrue(self._pfx .. "coverdeck_show_book_time") or
            SUISettings:nilOrTrue(self._pfx .. "coverdeck_show_book_remaining"))))

    -- "currently" always needs the DB when active (all its stats are DB-backed).
    -- The "recent" module shows no DB-backed stats, so it is excluded.
    local wants_db = show_c or coverdeck_needs_db or wants_stats or needs_db

    if wants_db and not self._db_conn and not self._defer_stats then
        -- openStatsDB returns nil while a Statistics cloud sync is in progress.
        self._db_conn = Config.openStatsDB()
    end

    -- Pre-fetch numeric stats via the shared provider (a few window-bounded queries).
    -- needs_books: true only when reading_goals is active or a module asks for
    -- the finished-books ledger (e.g. a Reading Stats instance with the
    -- "total_books" stat on its first page).  When false, SP.get() skips the
    -- sidecar scan (up to 200 DS.open calls) entirely.
    local needs_books = rg_active or Registry.wantsData(self._pfx, "books")

    -- Status counts (unread/reading/finished/abandoned across the whole
    -- library) are a separate, more expensive walk than needs_books above
    -- (sui_library_scan + one sidecar read per book not already cached), so
    -- they get their own gate — only computed when a module asks for them,
    -- same "don't pay for what isn't shown" principle as needs_books.
    local needs_status = Registry.wantsData(self._pfx, "status")

    -- Reading-session records (longest/average session, pages per hour,
    -- session count) come from one on-demand query, gated the same way.
    local needs_records = Registry.wantsData(self._pfx, "records")

    -- Year data (seconds read per month): one more on-demand query, gated the
    -- same way.
    local needs_year = Registry.wantsData(self._pfx, "year")

    -- Chart data (this week per day, reading per hour of the day): one more
    -- on-demand query, gated the same way.
    local needs_charts = Registry.wantsData(self._pfx, "charts")

    -- Compute once here; reused by SP.get and stored in ctx so the async
    -- refresh tick (scheduleIn 50ms) does not need a second os.date call.
    local year_str    = os.date("%Y")
    local stats_data  = nil
    if wants_stats then
        local SP = _getStatsProvider()
        if SP then
            if self._defer_stats then
                stats_data = SP.getStale() or {}
            else
                stats_data = SP.get(self._db_conn, year_str, needs_books)
            end
            if stats_data and stats_data.db_conn_fatal then
                logger.warn("simpleui: screen (" .. tostring(self._id) .. "): StatsProvider reported fatal DB error — dropping connection")
                if self._db_conn then
                    pcall(function() self._db_conn:close() end)
                    self._db_conn = nil
                end
            end
        end
    end

    -- Status counts: independent of wants_stats/db_conn (file-based, not
    -- DB-based) and skipped entirely on a deferred/stale render — same
    -- treatment as stats_data above, since the library walk is no lighter
    -- than a DB roundtrip and has no meaning to compute twice in one frame.
    local status_counts = nil
    if needs_status and not self._defer_stats then
        local SP = _getStatsProvider()
        if SP and SP.getStatusCounts then status_counts = SP.getStatusCounts() end
    end

    -- Session records: DB-backed, so skipped on a deferred render as well; the
    -- async refresh tick fills them in.
    local session_records = nil
    if needs_records and not self._defer_stats then
        local SP = _getStatsProvider()
        if SP and SP.getSessionRecords then session_records = SP.getSessionRecords(self._db_conn) end
    end

    local year_data = nil
    if needs_year and not self._defer_stats then
        local SP = _getStatsProvider()
        if SP and SP.getYearData then year_data = SP.getYearData(self._db_conn) end
    end

    local stat_charts = nil
    if needs_charts and not self._defer_stats then
        local SP = _getStatsProvider()
        if SP and SP.getChartData then stat_charts = SP.getChartData(self._db_conn) end
    end

    -- Pre-compute coverdeck book stats for the current centre cover so
    -- module_coverdeck.build() does not run DB queries on the paint path.
    -- coverdeck_needs_db already encodes the "needs DB stats" check, so we
    -- reuse it directly rather than repeating the visibility logic here.
    local coverdeck_center_stats = nil
    if coverdeck_needs_db and self._db_conn then
        local center_fp = _coverdeckDefaultCenterFp(bs.current_fp, bs.recent_fps)
        local pe = center_fp and bs.prefetched_data and bs.prefetched_data[center_fp]
        local center_md5 = type(pe) == "table" and pe.partial_md5_checksum
        if center_md5 then
            local cd_mod = package.loaded["modules/module_coverdeck"]
            if cd_mod and cd_mod.fetchBookStatsForCtx then
                coverdeck_center_stats = {
                    fp    = center_fp,
                    stats = cd_mod.fetchBookStatsForCtx(center_md5, self._db_conn, not self._defer_stats),
                }
            end
        end
    end

    -- Pre-compute Currently Reading book stats to move the DB query off the
    -- hot paint path (md5 is already in prefetched_data — no extra IO).
    local currently_book_stats = nil
    if mod_c and Registry.isEnabled(mod_c, self._pfx) and self._db_conn and bs.current_fp then
        if mod_c.needsDbStats(cfg.currently.show) then
            local pe_c  = bs.prefetched_data and bs.prefetched_data[bs.current_fp]
            local c_md5 = type(pe_c) == "table" and pe_c.partial_md5_checksum
            if c_md5 then
                -- pcall(require) resolves the module even on the very first render,
                -- before build() has had a chance to load it. require() is
                -- idempotent — subsequent calls return the cached module at zero
                -- extra cost.
                local mc_ok, mc_mod = pcall(require, "modules/module_currently")
                if mc_ok and mc_mod and mc_mod.fetchBookStatsForCtx then
                    currently_book_stats = {
                        fp    = bs.current_fp,
                        stats = mc_mod.fetchBookStatsForCtx(c_md5, self._db_conn, not self._defer_stats),
                    }
                end
            end
        end
    end

    local self_ref = self
    return {
        _needs_books           = needs_books,
        _needs_status           = needs_status,
        _needs_records         = needs_records,
        _needs_year            = needs_year,
        _needs_charts          = needs_charts,
        year_str               = year_str,   -- cached once per render; re-used by async tick
        landscape_factor       = landscape_factor,
        pfx                    = self._pfx,
        pfx_qa                 = self._pfx_qa,
        close_fn               = function() self_ref:onClose() end,
        open_fn                = function(fp, pos0, page) openBook(fp, pos0, page) end,
        hold_fn                = function(fp, mod_id) self_ref:_showBookHoldDialog(fp, mod_id) end,
        refresh_fn             = function() self_ref:_refreshImmediate(true) end,
        dirty_region_fn        = function(dimen) UIManager:setDirty(self_ref, function() return "ui", dimen end) end,
        open_settings_fn       = function(mod_id)
            local m = mod_id and Registry.get(mod_id)
            if m then self_ref:_openModuleSettingsFor(m) end
        end,
        on_qa_tap              = function(aid) if self_ref._on_qa_tap then self_ref._on_qa_tap(aid) end end,
        on_goal_tap            = function() if self_ref._on_goal_tap then self_ref._on_goal_tap() end end,
        kbStops                = Device:hasDPad() and function(key, stops) self_ref:_kbSetRow(key, stops) end or nil,
        db_conn                = wants_db and self._db_conn or nil,
        db_conn_fatal          = false,
        stats                  = stats_data,
        stats_stale            = self._defer_stats == true,
        status_counts           = status_counts,
        session_records        = session_records,
        year_data              = year_data,
        stat_charts            = stat_charts,
        coverdeck_center_stats = coverdeck_center_stats,
        currently_book_stats   = currently_book_stats,
        vspan_pool             = self._vspan_pool,
        prefetched             = bs.prefetched_data,
        current_fp             = bs.current_fp,
        recent_fps             = bs.recent_fps,
        _screen_widget         = self,
        _show_c                = show_c,
        _show_r                = show_r,
        _has_content           = (bs.current_fp and show_c) or (#bs.recent_fps > 0 and show_r),
        cfg                    = cfg,
        has_wallpaper          = (SUIWallpaper.styleGetBgWidget() ~= nil),
    }
end

-- ---------------------------------------------------------------------------
-- _updateFooter — mutates the persistent footer in-place (zero allocation).
-- ---------------------------------------------------------------------------
function ScreenWidget:_updateFooter(current_page, total_pages)
    local footer_bc = self._footer_bc
    if not footer_bc then return end

    local sw        = self._layout_sw or Screen:getWidth()
    -- Bar-aware height, same as _initLayout() — never the raw Screen:getHeight().
    local content_h = self._layout_content_h or self._navbar_content_h or UI.getContentHeight()

    local navpager_on   = Config.isNavpagerEnabled()
    local dot_pager_on  = Config.isDotPagerEnabled()
    local pag_visible   = SUISettings:nilOrTrue("simpleui_bar_pagination_visible")
    local pag_hidden = SUISettings:isTrue(self._pfx .. "pagination_hidden")

    local show_bar = not pag_hidden
        and total_pages > 1 and (navpager_on or pag_visible or dot_pager_on)
    local use_dots = show_bar and (navpager_on or dot_pager_on)

    if not show_bar then
        footer_bc.dimen.h = 0
        footer_bc[1] = self._footer_hidden_span
        return
    end

    footer_bc.dimen.h = content_h

    if use_dots then
        local fd      = self._footer_dot
        local dw      = fd.dot_widget
        local total_w = total_pages * fd.touch_w
        dw.current_page       = current_page
        dw.total_pages        = total_pages
        fd.bar_input.dimen.w  = total_w
        fd.bar_input.dimen.h  = dw.bar_h
        fd.widget.dimen.w     = sw
        footer_bc[1]          = fd.widget
    else
        local fc = self._footer_chevron
        fc.btn_text:setText(T(_("Page %1 of %2"), current_page, total_pages))
        fc.btn_first:enableDisable(current_page > 1)
        fc.btn_prev:enableDisable(current_page > 1)
        fc.btn_next:enableDisable(current_page < total_pages)
        fc.btn_last:enableDisable(current_page < total_pages)
        footer_bc[1] = fc.widget
    end
end

-- ---------------------------------------------------------------------------
-- _refreshLiveData — invalidates this screen's cached module/config state
-- and re-renders it. This is the one piece of "refresh" that is specific to
-- ScreenWidget (as opposed to the generic ctx_menu fields SUIWindow.makeCtxMenu
-- already provides) and is passed as extra_refresh into
-- SUIWindow.buildModuleSettingsScreen.
-- ---------------------------------------------------------------------------
function ScreenWidget:_refreshLiveData()
    local live = _sget(self._id, "_instance")
    if live then
        live._enabled_mods_cache = nil
        live._ctx_cache          = nil
        live._cfg_cache          = nil
        _sset(self._id, "_cfg_cache", nil)
        live:_refresh(false)
    end
end

-- ---------------------------------------------------------------------------
-- _showBookHoldDialog — opens the per-book action sheet for a single cover
-- long-pressed inside a module whose "Long press on cover" setting is
-- "book_dialog" (see engines/sui_book_grid.lua's per-cell Hold handling and
-- Config.getCoverHoldMode). Reached via ctx.hold_fn(fp, mod_id).
--
-- mod_id (optional) is whichever module the hold originated in — sui_book_
-- grid.lua's cells, module_coverdeck.lua and module_currently.lua's single
-- widgets, and module_collections.lua's cells all pass their own id. It's
-- used only to look up the module (via Registry) for the dialog's "Open
-- Module Settings" button; the dialog itself works fine without it (that
-- button is simply omitted).
-- ---------------------------------------------------------------------------
function ScreenWidget:_showBookHoldDialog(fp, mod_id)
    if not fp then return end
    local ok, BookHoldDialog = pcall(require, "features/library/sui_book_hold_dialog")
    if not ok or not BookHoldDialog then return end
    local self_ref = self
    local mod = mod_id and Registry.get(mod_id)
    BookHoldDialog.show(fp, {
        -- Most actions here (status, reset, collections, ...) can change
        -- what a module shows or how a cover looks (e.g. status badges),
        -- so re-render on close rather than trying to track exactly which
        -- action fired. This mirrors _navigateRefresh in module_coverdeck.lua.
        refresh_fn = function()
            -- Status change already invalidates the sidecar cache via
            -- patchStatusButtons → _onStatusChanged. Drop the books prefetch
            -- and ctx so the rebuild re-runs prefetchBooks() and picks up the
            -- new percent/summary for Cover Deck + book-grid badges/bars.
            self_ref._cached_books_state = nil
            self_ref._ctx_cache          = nil
            self_ref:_refreshImmediate(true)
        end,
        -- Rows that navigate inside the file browser (e.g. "More by <Author>")
        -- act on the file manager underneath this screen, so the screen
        -- closes to reveal the result.
        navigate_fn      = function() self_ref:onClose() end,
        open_settings_fn = mod and function() self_ref:_openModuleSettingsFor(mod) end or nil,
        -- "Collections…" and "Book information" open a native FM/ReaderUI
        -- sub-screen on top of us; closing that sub-screen should reveal us
        -- again on its own, but can instead resurface FileManager's native
        -- browser. Closing and immediately re-showing ourselves is a cheap,
        -- reliable way to force us back on top regardless of the exact
        -- cause — UIManager:close removes every occurrence of a widget from
        -- the window stack, so this can't create duplicate entries.
        --
        -- A plain UIManager:close(self_ref) here is an "unexpected" close
        -- from onCloseWidget's point of view (see the
        -- _navbar_closing_intentionally branch below in this same file) —
        -- it discards this screen's cached _current_page/_cached_books_state/
        -- _cfg_cache and nils out self_ref's own fields (_current_page,
        -- _enabled_mods_cache, _body, _overlap, ...), leaving self_ref gutted
        -- and unsafe to re-show directly. Mark the close intentional
        -- (caching state via _sset, keyed by this screen's id) and rebuild
        -- through ScreenEngine._open(), which restores that cached page/book
        -- state into a fresh widget, same as the tab-switch and
        -- rotation-reopen paths do.
        reveal_fn = function()
            self_ref._navbar_closing_intentionally = true
            UIManager:close(self_ref)
            self_ref._navbar_closing_intentionally = nil
            ScreenEngine._open(self_ref.instance, self_ref._on_qa_tap, self_ref._on_goal_tap)
        end,
    })
end

-- ---------------------------------------------------------------------------
-- _openModuleSettingsFor — builds and shows a module's settings SUIWindow.
-- Extracted from _onHoldModRelease so both the module-wrapper long-press
-- (settings-on-hold, gated by <pfx>settings_on_hold — e.g. simpleui_hs_
-- settings_on_hold for the built-in Homescreen, simpleui_cs_<id>_settings_
-- on_hold for a Custom Screen) and the book dialog's explicit "Open module
-- settings" button (always available, regardless of that per-screen toggle
-- — it's a deliberate tap, not a hold) can share the exact same settings
-- screen.
-- ---------------------------------------------------------------------------
-- `hold_action`, if given, is what the module's takeHoldAction returned for
-- the long-press that opened the window: a button beside the layout one.
function ScreenWidget:_openModuleSettingsFor(mod, hold_action)
    local screen = self
    if not mod then return end

        local SUIWindow = require("engines/sui_window")

        local function buildRoot(ctx)
            return SUIWindow.buildModuleSettingsScreen(ctx, mod, {
                pfx           = self._pfx,
                pfx_qa        = self._pfx_qa,
                extra_refresh = function() screen:_refreshLiveData() end,
                on_change     = function() screen._enabled_mods_cache = nil end,
            })
        end

        -- The layout sheet only applies to a module placed on a page.
        local Layout = require("infra/sui_layout")
        local placed = Layout.findPage(Layout.load(self._pfx, self._layout_key), mod.id) ~= nil

        local win
        win = SUIWindow:new{
            name           = "sui_win_context",
            title          = SUIWindow.makeSettingsTitle(mod.name or mod.id),
            screens        = SUIWindow.makeSettingsScreens(buildRoot),
            navpager_mode  = Config.isNavpagerEnabled(),
            position       = "bottom",
            has_settings_btn = true,
            left_btn       = placed and {
                glyph  = SUIStyle.icon("layout"),
                label  = function()
                    if Config.isBentoClassic(self._pfx) then
                        return Config.bentoWidthLabel(mod.id, self._pfx)
                    end
                    local span = Config.getBentoSpan(mod.id, self._pfx)
                    return span == Bento.FULL and _("Full Width") or Config.bentoSpanLabel(span)
                end,
                on_tap = function(ctx)
                    screen:_openBentoSheet(mod, function() win:close() end, ctx.repaint)
                end,
            } or nil,
            left_aux_btn   = hold_action and {
                glyph  = SUIStyle.icon(hold_action.icon),
                label  = hold_action.label,
                on_tap = function(ctx)
                    hold_action.on_tap(function()
                        screen:_refreshLiveData()
                        ctx.repaint()
                    end)
                end,
            } or nil,
        }
        win:show()
end

-- ---------------------------------------------------------------------------
-- _openBentoSheet — shows the layout sheet of a module (width and position in
-- the bento grid). Changes are saved and repainted as they are made;
-- close_window closes the window the sheet was opened from, once the module
-- has been removed from its page or the page editor takes over; on_changed
-- runs after every saved change.
-- ---------------------------------------------------------------------------
function ScreenWidget:_openBentoSheet(mod, close_window, on_changed)
    local pfx = self._pfx
    require("features/dialogs/sui_bento_sheet").show{
        mod_id     = mod.id,
        pfx        = pfx,
        on_removed = close_window,
        on_changed = on_changed,
        rows       = function(id)
            return {
                {
                    text = _("Page Editor"), sui_icon = "edit", chevron = true,
                    callback = function()
                        if close_window then close_window() end
                        require("screens/sui_settings_window"):showPageEditor(pfx, id)
                    end,
                },
            }
        end,
    }
end

-- ---------------------------------------------------------------------------
-- _onHoldModRelease — shared handler for module long-press settings menus.
-- Stored once on ScreenWidget; each wrapper sets wrapper._sui_mod so this
-- single function knows which module was held (no per-module closure needed).
-- ---------------------------------------------------------------------------
function ScreenWidget:_onHoldModRelease(wrapper)
    local mod    = wrapper._sui_mod
    -- Taken on every hold so an action never outlives the hold that set it.
    local hold_action = mod and mod.takeHoldAction and mod.takeHoldAction(self._pfx)
    if not SUISettings:nilOrTrue(self._pfx .. "settings_on_hold") then
        return true
    end
    local screen = wrapper._sui_screen
    if not mod or not screen then return true end
    screen:_openModuleSettingsFor(mod, hold_action)
    return true
end

-- ---------------------------------------------------------------------------
-- _makeModWrapper — returns a pooled InputContainer wrapping a module widget.
-- Wrappers are allocated once per mod.id per Homescreen lifetime and updated
-- in-place on subsequent page turns (zero new allocations).
-- ---------------------------------------------------------------------------
-- Returns the chrome-wrapped widget to mount and the module's own widget as
-- returned by mod.build() (the one per-module updaters operate on) and whether
-- the section label sits inside the box (see Config.isLabelOutside); the
-- caller then must not add it above. On a build error returns nil plus the
-- error message. `ctx.ink` carries the content colours over the module fill
-- (see ModuleChrome.ink). A module with `owns_chrome` is built at the full
-- column width and mounted as it is: it draws its own boxes. `min_h` is the
-- least height of the box (the row's tallest column, see _pack_bento).
function ScreenWidget:_buildModWidget(mod, col_w, ctx, min_h)
    local ModuleChrome = require("features/sui_module_chrome")
    local chrome, build_w
    if mod.owns_chrome then
        build_w = col_w
    else
        chrome  = ModuleChrome.resolve(self._pfx, mod.id)
        build_w = ModuleChrome.contentWidth(col_w, chrome)
    end
    -- Expose the full column width so modules that re-wrap later (clock tick)
    -- can recover the same chrome geometry the page build used. `text_alpha`
    -- tells the module whether its text sits over a painted surface (a
    -- wallpaper or a filled module surface) and must not draw its own
    -- background.
    if ctx then
        ctx.col_w      = col_w
        ctx.grow_h     = self._grow_h and self._grow_h[mod.id]
        ctx.text_alpha = ctx.has_wallpaper or (chrome ~= nil and ModuleChrome.hasFill(chrome))
        ctx.ink        = chrome and ModuleChrome.ink(chrome) or nil
        ctx.palette    = ModuleChrome.palette(chrome)
    end
    local ok_w, widget = pcall(mod.build, build_w, ctx)
    if not ok_w then
        return nil, widget
    end
    if not widget then return nil end
    if not chrome then return widget, widget end

    -- The label joins the box content only when a fill or frame is drawn;
    -- without one the two placements look the same.
    local content, label_inside = widget, false
    if ctx and ModuleChrome.hasChrome(chrome) and not Config.isLabelOutside(mod.id) then
        local inside = {
            ink     = chrome.foreground and ctx.ink or nil,
            palette = ModuleChrome.palette(chrome),
        }
        local label  = self:_labelFor(mod, build_w, ctx, inside)
        if label then
            content = VerticalGroup:new{ align = "left", label, widget }
            label_inside = true
            if mod.is_book_mod and self._book_mod_label_slots then
                self._book_mod_label_slots[mod.id] = {
                    parent = content,
                    index  = 1,
                    mod    = mod,
                    col_w  = build_w,
                    inside = inside,
                }
            end
        end
    end
    return ModuleChrome.wrap(content, chrome, col_w, (ctx and ctx.landscape_factor) or 1, widget, min_h),
        widget, label_inside
end

-- True when book module `mod` builds a widget at column width `col_w` with the
-- current ctx. The trial widget is freed and the covers it queued for
-- extraction are dropped: the rebuild that follows queues them again.
function ScreenWidget:_bookModHasItems(mod, col_w)
    local queued = Config._cover_extract_queue and #Config._cover_extract_queue or 0
    local widget = self:_buildModWidget(mod, col_w, self._ctx_cache)
    local queue = Config._cover_extract_queue
    for i = queue and #queue or 0, queued + 1, -1 do
        local fp = table.remove(queue, i)
        Config._cover_extract_pending[fp] = nil
        Config._cover_extract_specs[fp] = nil
    end
    if not widget then return false end
    widget:free()
    return true
end

function ScreenWidget:_makeModWrapper(mod, widget, inner_w)
    local pool = self._wrapper_pool
    local w    = pool[mod.id]
    local h    = widget:getSize().h

    if w then
        w[1]       = widget
        w.dimen.w  = inner_w
        w.dimen.h  = h
        w._sui_mod = mod
    else
        w = InputContainer:new{
            dimen       = Geom:new{ w = inner_w, h = h },
            widget,
            _sui_mod    = mod,
            _sui_screen = self,
        }
        w.ges_events = {
            HoldMod = {
                GestureRange:new{
                    ges   = "hold",
                    range = function() return w.dimen end,
                },
            },
            HoldModRelease = {
                GestureRange:new{
                    ges   = "hold_release",
                    range = function() return w.dimen end,
                },
            },
        }
        function w:onHoldMod()
            if not SUISettings:nilOrTrue(self._sui_screen._pfx .. "settings_on_hold") then
                return
            end
            return true
        end
        function w:onHoldModRelease() return self._sui_screen:_onHoldModRelease(self) end
        pool[mod.id] = w
    end
    return w
end

-- ---------------------------------------------------------------------------
-- _updatePage — clears body and repopulates the current page slice.
-- Called on every page turn (keep_cache=true) and on full refreshes (false).
-- ---------------------------------------------------------------------------
function ScreenWidget:_updatePage(keep_cache, books_only, stats_only)
    if not keep_cache then
        if stats_only then
            self._ctx_cache = nil
        else
            self._cached_books_state = nil
            if not books_only then
                self._enabled_mods_cache = nil
                self._ctx_cache          = nil
            end
        end
    end

    -- The same value is reused further down for layout branching.
    local is_landscape = _isLandscape()

    local ctx
    if keep_cache and self._ctx_cache then
        ctx = self._ctx_cache
    else
        ctx = self:_buildCtx()
        self._ctx_cache = ctx
    end

    -- Landscape scale factor; refined below once the real column width is known.
    local _landscape_factor = ctx.landscape_factor or 1

    local inner_w = self._layout_inner_w or UI.getInnerW()
    local body    = self._body
    if not body then return end

    -- Module list cache — rebuilt whenever layout changes.
    local layout = SUISettings:readSetting(self._layout_key)
    local raw_order = Registry.loadOrder(self._pfx)

    local layout_fingerprint = ""
    local pages_by_id = {}

    -- Column spans (percents in the classic layout) come from per-module
    -- settings, not the layout.
    local classic = Config.isBentoClassic(self._pfx)
    local function _widthOf(mod_id)
        if classic then return Config.getBentoPct(mod_id, self._pfx) end
        return Config.getBentoSpan(mod_id, self._pfx)
    end
    local mod_col_span = {}
    -- Modules placed on hidden pages: kept in the layout, not rendered.
    local hidden_ids = {}
    local visible_pages = 0
    if layout and type(layout.pages) == "table" then
        for _, page in ipairs(layout.pages) do
            if page.hidden then
                for _, entry in ipairs(page.modules) do
                    local mod_id = type(entry) == "table" and entry.id or entry
                    if mod_id then hidden_ids[mod_id] = true end
                end
            else
                visible_pages = visible_pages + 1
                local page_ids = {}
                for _, entry in ipairs(page.modules) do
                    -- Accept legacy { id, width } entries and migrate width to settings.
                    local mod_id
                    if type(entry) == "table" then
                        mod_id = entry.id
                        if type(entry.width) == "number" and mod_id then
                            Config.setBentoWidth(entry.width, mod_id, self._pfx)
                        end
                    else
                        mod_id = entry
                    end
                    if mod_id then
                        table.insert(page_ids, mod_id)
                        local span = _widthOf(mod_id)
                        mod_col_span[mod_id] = span
                        layout_fingerprint = layout_fingerprint .. mod_id .. ":" .. tostring(span) .. ","
                    end
                end
                layout_fingerprint = layout_fingerprint .. "|"
                table.insert(pages_by_id, page_ids)
            end
        end
    else
        pages_by_id = splitOrderIntoPages(raw_order)
        for _, mod_id in ipairs(raw_order) do
            if mod_id ~= "__page_break__" then
                local span = _widthOf(mod_id)
                mod_col_span[mod_id] = span
                layout_fingerprint = layout_fingerprint .. mod_id .. ":" .. tostring(span) .. ","
            else
                layout_fingerprint = layout_fingerprint .. "|"
            end
        end
    end

    if not self._enabled_mods_cache
       or self._enabled_mods_cache.layout_fingerprint ~= layout_fingerprint then
        local has_book_mod  = false
        local mod_gaps      = {}
        local pages_of_mods = {}

        for _, page_ids in ipairs(pages_by_id) do
            local page_mods = {}
            for _, mod_id in ipairs(page_ids) do
                local mod = Registry.get(mod_id)
                if mod and Registry.isEnabled(mod, self._pfx) then
                    page_mods[#page_mods + 1] = mod
                    mod_gaps[mod_id] = Config.getModuleGapPx(mod_id, self._pfx, MOD_GAP)
                    if mod.is_book_mod then
                        has_book_mod = true
                    end
                end
            end
            pages_of_mods[#pages_of_mods + 1] = page_mods
        end
        if #pages_of_mods == 0 then pages_of_mods[1] = {} end

        local chosen_pages = SUISettings:readSetting(self._pfx .. "homescreen_num_pages")
        if layout and type(layout.pages) == "table" then
            chosen_pages = visible_pages
        end
        if chosen_pages and chosen_pages > #pages_of_mods then
            for _ = #pages_of_mods + 1, chosen_pages do
                pages_of_mods[#pages_of_mods + 1] = {}
            end
        end

        -- Safety net: ensure coverdeck appears when absent from the saved order.
        do
            local cd = Registry.get("coverdeck")
            if cd and Registry.isEnabled(cd, self._pfx) then
                local found = hidden_ids["coverdeck"] == true
                for _, pg in ipairs(pages_of_mods) do
                    for _, m in ipairs(pg) do
                        if m.id == "coverdeck" then found = true; break end
                    end
                    if found then break end
                end
                if not found then
                    local insert_at = #pages_of_mods[1] + 1
                    for i, m in ipairs(pages_of_mods[1]) do
                        if m.id == "recent"    then insert_at = i + 1; break end
                        if m.id == "currently" then insert_at = i + 1 end
                    end
                    table.insert(pages_of_mods[1], insert_at, cd)
                    mod_gaps["coverdeck"] = Config.getModuleGapPx("coverdeck", self._pfx, MOD_GAP)
                    if cd.is_book_mod then has_book_mod = true end
                end
            end
        end

        local enabled_mods = {}
        for _, pg in ipairs(pages_of_mods) do
            for _, m in ipairs(pg) do
                enabled_mods[#enabled_mods + 1] = m
            end
        end

        self._enabled_mods_cache = {
            mods          = enabled_mods,
            mod_gaps      = mod_gaps,
            has_book_mod  = has_book_mod,
            total_pages   = #pages_of_mods,
            pages_of_mods = pages_of_mods,
            layout_fingerprint = layout_fingerprint,
        }
    end
    local has_book_mod  = self._enabled_mods_cache.has_book_mod
    local total_pages   = self._enabled_mods_cache.total_pages
    local mod_gaps      = self._enabled_mods_cache.mod_gaps
    local pages_of_mods = self._enabled_mods_cache.pages_of_mods

    -- Clamp current page and normalise to odd index in landscape (spread mode).
    if self._current_page > total_pages then self._current_page = total_pages end
    if self._current_page < 1           then self._current_page = 1           end
    if is_landscape and total_pages > 1 and self._current_page % 2 == 0 then
        self._current_page = self._current_page - 1
    end
    self._total_pages = total_pages
    self.page         = self._current_page
    self.page_num     = total_pages

    local empty_widget
    if (ctx._show_c or ctx._show_r) and not ctx._has_content and not has_book_mod then
        empty_widget = buildEmptyState(inner_w, _EMPTY_H)
    end

    body:clear()

    self._clock_body_idx    = nil
    self._clock_min_h       = nil
    self._grow_h            = {}
    self._clock_live        = nil
    self._clock_body_ref    = body
    self._stats_mod_slots   = {}
    self._book_mod_slots    = {}
    self._book_mod_empty    = {}  -- book mod id -> col_w of a module built with no items
    self._cover_mod_slots   = {}
    self._book_mod_label_slots = {}
    self._clock_is_wrapped  = false

    -- Reset the per-filepath extraction dedup guard at the start of every
    -- render.  The guard is an intra-render dedup (prevents the same filepath
    -- being enqueued twice within one build pass); it must not persist across
    -- renders, or getCoverBB() silently skips re-enqueuing books whose covers
    -- are still missing after a previous poll cycle completed.
    if not self._cover_poll_timer then
        Config._cover_extract_pending = {}
    end

    -- The modules register their rows of focus stops again as they build.
    self._kb_rows       = {}
    self._kb_row_by_key = {}

    local cur_page_mods  = pages_of_mods[self._current_page] or {}
    local first_mod      = true
    local page_has_covers = false

    -- Bento packing (portrait and landscape), see infra/sui_bento:
    --   • a module takes 1/3, 1/2, 2/3 or the full width of the row
    --   • consecutive modules whose spans fit in a row sit side by side
    --   • a full-width module always takes a row of its own
    --   • rows that do not fill the container are centred in it
    -- In landscape the same rules apply inside each spread column.
    do
        -- Horizontal gap of the landscape page split.
        local H_COL_GAP = 1

        local mode = { classic = classic, stack = Config.isBentoStack(self._pfx) }
        local function _pack_rows(ids)
            return Bento.packFor(ids, mod_col_span, mode)
        end

        -- Builds label + hold-wrapper cell. Slot registration happens in
        -- _register_cell once the cell's real parent is known.
        local function _emit_mod(mod, col_w)
            if mod.has_covers then page_has_covers = true end
            -- The page chevrons of the label come before the rows of the
            -- module, but need the page count its build sets.
            if mod.is_book_mod and ctx.kbStops then ctx.kbStops(mod.id .. ":label", {}) end
            local widget, content, label_inside = self:_buildModWidget(mod, col_w, ctx)
            if not widget then
                if content then
                    logger.warn("simpleui: screen (" .. tostring(self._id) .. "): build failed for "
                                .. tostring(mod.id) .. ": " .. tostring(content))
                elseif mod.is_book_mod then
                    self._book_mod_empty[mod.id] = col_w
                end
                return nil
            end

            local cell = VerticalGroup:new{ align = "left" }
            local label = not label_inside and self:_labelFor(mod, col_w, ctx)
            if label then
                cell[#cell+1] = label
                if mod.is_book_mod then
                    self._book_mod_label_slots[mod.id] = {
                        parent = cell,
                        index  = #cell,
                        mod    = mod,
                        col_w  = col_w,
                    }
                end
            end
            cell[#cell+1] = self:_makeModWrapper(mod, widget, col_w)

            if mod.has_covers and type(mod.updateCovers) == "function" then
                self._cover_mod_slots[mod.id] = { mod = mod, widget = content }
            end
            if type(mod.updateStats) == "function" then
                self._stats_mod_slots[mod.id] = { mod = mod, content = content }
            end
            -- Stash for _register_cell (widget, content + col_w needed by book slots).
            cell._sui_mod = mod
            cell._sui_widget = widget
            cell._sui_content = content
            cell._sui_col_w = col_w
            return cell
        end

        -- Records clock / book-mod slots against the cell itself.
        -- Clock tick does body[idx][1] = new_widget with is_wrapped: body must
        -- be the cell VerticalGroup and idx the wrapper index inside it.
        local function _register_cell(cell)
            if not cell or not cell._sui_mod then return end
            local mod = cell._sui_mod
            local widget = cell._sui_widget
            local content = cell._sui_content
            local col_w = cell._sui_col_w
            if mod.id == "clock" then
                self._clock_body_ref   = cell
                self._clock_body_idx   = #cell
                self._clock_is_wrapped = true
            end
            if mod.is_book_mod then
                self._book_mod_slots[mod.id] = {
                    mod      = mod,
                    widget   = widget,
                    content  = content,
                    parent   = cell,
                    index    = #cell,
                    col_w    = col_w,
                    has_menu = true,
                }
            end
            cell._sui_mod = nil
            cell._sui_widget = nil
            cell._sui_content = nil
            cell._sui_col_w = nil
        end

        -- Packs mods into parent_body. container_w is the full available
        -- width for a full-width module. first is a one-element table cleared
        -- once a row has been placed.
        local function _pack_bento(mods, parent_body, container_w, first)
            local ids, by_id = {}, {}
            for i, mod in ipairs(mods) do
                ids[i] = mod.id
                by_id[mod.id] = mod
            end

            -- Boxes of a row sit GUTTER apart. Every column keeps its own
            -- lateral inset (ModuleChrome.outerMargin), but the empty insets
            -- of neighbouring columns overlap, so the full inset only shows at
            -- the ends of the row.
            local ModuleChrome = require("features/sui_module_chrome")
            local inset  = ModuleChrome.outerMargin()
            local gutter = ModuleChrome.GUTTER
            local mirrored = BD.mirroredUILayout()


            -- Stack of the modules of a column, each separated by its top margin.
            local function _assemble(items)
                local v_col = VerticalGroup:new{ align = "left" }
                for k, it in ipairs(items) do
                    if k > 1 then v_col[#v_col+1] = self:_vspan(mod_gaps[it.id] or MOD_GAP) end
                    v_col[#v_col+1] = it.cell
                end
                return v_col
            end

            local function _flush_row(row)
                local n = #row.cols
                local gap_px = mod_gaps[row.ids[1]] or MOD_GAP
                first[1] = false
                parent_body[#parent_body+1] = self:_vspan(gap_px)

                -- Box widths in sixths of the row; the last box takes the
                -- rounding remainder.
                local boxes_w = math.max(1, container_w - 2 * inset - (n - 1) * gutter)
                local box = {}
                local allocated = 0
                for i, col in ipairs(row.cols) do
                    if i == n then
                        local row_pixels = math.max(1, math.floor(boxes_w * row.sum / row.of))
                        box[i] = math.max(1, row_pixels - allocated)
                    else
                        box[i] = math.max(1, math.floor(boxes_w * col.span / row.of))
                        allocated = allocated + box[i]
                    end
                end

                -- A row that does not fill the container is centred in it.
                local row_w = (n - 1) * gutter
                for i = 1, n do row_w = row_w + box[i] end
                local x = math.max(0, math.floor((container_w - 2 * inset - row_w) / 2))

                -- Build columns first: the box of the last module of every
                -- shorter column is then stretched to the tallest one (see
                -- ModuleChrome.stretch); a column without a box is centred
                -- against it.
                local built = {}
                local max_h = 0
                for i, col in ipairs(row.cols) do
                    local slot_w = box[i] + 2 * inset
                    local items = {}
                    for _, id in ipairs(col.ids) do
                        local cell = _emit_mod(by_id[id], slot_w)
                        if cell then
                            items[#items+1] = { id = id, cell = cell, wrapped = cell._sui_widget }
                            _register_cell(cell)
                        end
                    end
                    local v_col = _assemble(items)
                    local col_h = v_col:getSize().h
                    if col_h > max_h then max_h = col_h end
                    built[#built+1] = {
                        v_col = v_col, items = items, slot_w = slot_w, col_h = col_h, x = x,
                    }
                    x = x + box[i] + gutter
                end

                for _, b in ipairs(built) do
                    -- The last module of a column takes up the extra height. One
                    -- that can use it is built again with it.
                    local last = b.items[#b.items]
                    local mod = last and by_id[last.id]
                    if last and last.wrapped and b.col_h < max_h and mod.fills_row_height then
                        self._grow_h[last.id] = max_h - b.col_h
                        local cell = _emit_mod(mod, b.slot_w)
                        if cell then
                            last.cell, last.wrapped = cell, cell._sui_widget
                            _register_cell(cell)
                            b.v_col = _assemble(b.items)
                            b.col_h = b.v_col:getSize().h
                        end
                    end
                    if last and last.wrapped and b.col_h < max_h then
                        local wrapper = last.cell[#last.cell]
                        local box_h = ModuleChrome.stretch(last.wrapped, last.wrapped:getSize().h + max_h - b.col_h)
                        if box_h then
                            wrapper.dimen.h = box_h
                            last.cell:resetLayout()
                            b.v_col:resetLayout()
                            b.col_h = b.v_col:getSize().h
                            local book_slot = self._book_mod_slots[last.id]
                            if book_slot then book_slot.min_h = box_h end
                            if last.id == "clock" then self._clock_min_h = box_h end
                        end
                    end
                end

                -- Offsets are mirrored here rather than by the group, which
                -- rewrites them on every paint.
                local row_group = OverlapGroup:new{
                    dimen           = Geom:new{ w = container_w, h = max_h },
                    allow_mirroring = false,
                }
                for _, b in ipairs(built) do
                    -- Stretch every column to max_h and centre its content.
                    -- LeftContainer pins the slot width so a narrow child does
                    -- not shrink the column.
                    local col = CenterContainer:new{
                        dimen = Geom:new{ w = b.slot_w, h = max_h },
                        LeftContainer:new{
                            dimen = Geom:new{ w = b.slot_w, h = b.col_h },
                            b.v_col,
                        },
                    }
                    local off = mirrored and (container_w - b.slot_w - b.x) or b.x
                    col.overlap_offset = { off, 0 }
                    row_group[#row_group+1] = col
                end
                parent_body[#parent_body+1] = row_group
            end

            for _, row in ipairs(_pack_rows(ids)) do
                _flush_row(row)
            end
        end

        if is_landscape then
            local col_w = UI.getSpreadColWidth(inner_w)
            local portrait_inner_w = UI.getPortraitInnerW()
            _landscape_factor = (portrait_inner_w > 0) and (col_w / portrait_inner_w) or 1
            ctx.landscape_factor = _landscape_factor
            self._clock_landscape_factor = _landscape_factor

            -- Spread: left = current page, right = next page.
            -- Solo (odd total, last page): split this page's bento rows in
            -- half, so a row is never cut between the two columns.
            local right_page_mods = pages_of_mods[self._current_page + 1]
            local left_mods, right_mods
            if right_page_mods then
                left_mods, right_mods = cur_page_mods, right_page_mods
            else
                left_mods, right_mods = {}, {}
                local ids = {}
                for i, mod in ipairs(cur_page_mods) do ids[i] = mod.id end
                local row_of, rows = {}, _pack_rows(ids)
                for r, row in ipairs(rows) do
                    for _, id in ipairs(row.ids) do row_of[id] = r end
                end
                local split_row = math.ceil(#rows / 2)
                for _, mod in ipairs(cur_page_mods) do
                    local side = (row_of[mod.id] <= split_row) and left_mods or right_mods
                    side[#side + 1] = mod
                end
            end

            local left_group  = VerticalGroup:new{ align = "left" }
            local right_group = VerticalGroup:new{ align = "left" }
            local left_first, right_first = { true }, { true }
            _pack_bento(left_mods,  left_group,  col_w, left_first)
            _pack_bento(right_mods, right_group, col_w, right_first)

            if #left_group > 0 or #right_group > 0 then
                first_mod = false
                body[#body+1] = HorizontalGroup:new{
                    align = "center",
                    left_group,
                    HorizontalSpan:new{ width = H_COL_GAP },
                    right_group,
                }
            end
        else
            self._clock_landscape_factor = nil
            local first_state = { true }
            _pack_bento(cur_page_mods, body, inner_w, first_state)
            first_mod = first_state[1]
        end
    end

    if ctx.db_conn_fatal and self._db_conn then
        logger.warn("simpleui: screen (" .. tostring(self._id) .. "): fatal DB error detected — dropping shared connection")
        pcall(function() self._db_conn:close() end)
        self._db_conn = nil
        ctx.db_conn   = nil
    end

    if empty_widget then
        if first_mod then
            body[#body+1] = self:_vspan(MOD_GAP)
        end
        body[#body+1] = empty_widget
    end

    -- Dithering hint for e-ink: UIManager checks widget.dithered on setDirty
    -- to trigger a full pixel refresh cycle (avoids ghosting on cover bitmaps
    -- and wallpaper images).
    self.dithered = (page_has_covers or ctx.has_wallpaper) or nil
    self._page_has_covers = page_has_covers

    -- In landscape, footer and navpager reflect spread count rather than raw pages.
    local footer_page, footer_total
    if is_landscape and total_pages > 1 then
        footer_total = math.ceil(total_pages / 2)
        footer_page  = math.ceil(self._current_page / 2)
    else
        footer_total = total_pages
        footer_page  = self._current_page
    end

    self:_updateFooter(footer_page, footer_total)
    _updateNavpager(self, footer_page, footer_total)

    -- Reschedule the clock tick when the clock module is on the current page,
    -- keeping it in phase with the status-bar clock after a page turn.
    if self._clock_body_idx ~= nil then
        local ClockMod = Registry.get("clock")
        if ClockMod and ClockMod.scheduleRefresh then
            ClockMod.scheduleRefresh(self)
        end
    end

    -- Warn when module heights overflow the visible area (portrait only).
    -- Skipped when the user has disabled the warning in settings.
    if not is_landscape
       and SUISettings:nilOrTrue(self._pfx .. "overflow_warn") then
        local total_body_h = 0
        for i = 1, #body do
            local ok, sz = pcall(function() return body[i]:getSize() end)
            if ok and sz and sz.h then total_body_h = total_body_h + sz.h end
        end
        -- Use the already-computed content height when available; recalculate
        -- from sui_core when _layout_content_h has not been set yet (e.g. the
        -- very first _updatePage call before _initLayout runs), instead of
        -- falling back to Screen:getHeight() which includes the bars.
        local avail_h = self._layout_content_h or UI.getContentHeight()
        if total_body_h > avail_h then
            -- Guard against showing the warning multiple times for the same
            -- overflow within one homescreen session (e.g. after a page turn
            -- back to an already-checked page, or a stats-only refresh).
            local warn_key = tostring(self._current_page) .. ":" .. tostring(total_body_h)
            if self._overflow_warn_key ~= warn_key then
                self._overflow_warn_key = warn_key
                -- Capture current layout dimensions so the deferred callback
                -- can detect a rotation that invalidated them before it fires.
                local snap_sw      = self._layout_sw      or Screen:getWidth()
                local snap_avail_h = avail_h
                local self_ref     = self
                UIManager:scheduleIn(0.5, function()
                    -- Abort if the instance has been replaced or the screen
                    -- has been rotated since the warning was scheduled.
                    if _sget(self_ref._id, "_instance") ~= self_ref then return end
                    if (self_ref._layout_sw or Screen:getWidth()) ~= snap_sw then return end
                    if (self_ref._layout_content_h or UI.getContentHeight()) ~= snap_avail_h then return end
                    UI.Notify.toast(_("Modules exceed the visible area.\nMove some to another page or adjust the scale."), 4)
                end)
            end
        else
            -- Reset the dedup key when the page no longer overflows so that a
            -- subsequent layout change that causes it to overflow again is reported.
            self._overflow_warn_key = nil
        end
    end

    -- Flush all covers enqueued during this render into a single
    -- extractInBackground call. Must run before the poll-timer check so that
    -- the subprocess is already launched when _scheduleCoverPoll fires.
    Config.flushCoverQueue()

    -- Start (or re-arm) the cover-extraction poll if any module's build()
    -- call triggered a background extraction.  This check is intentionally
    -- placed here — after all mod.build() calls — because getCoverBB sets
    -- Config.cover_extraction_pending during build(), not during prefetchBooks.
    -- The earlier check in _buildCtx (after prefetchBooks) handles the rare
    -- case where the flag was already set from a previous render cycle that
    -- did not yet finish polling; this check catches the common first-render
    -- case where covers are encountered for the first time.
    if Config.cover_extraction_pending and not self._cover_poll_timer then
        self:_scheduleCoverPoll()
    end

end

-- Queues a repaint of this screen (`refresh`: a refresh type or function)
-- unless a fullscreen window covers it: a covered screen is not painted and
-- shows its updated widgets once uncovered.
function ScreenWidget:_repaintIfShown(refresh)
    if UI.isUncovered(self) then UIManager:setDirty(self, refresh) end
end

-- Repaints the screen region occupied by a module slot. The pooled wrapper
-- carries the module's absolute region; without one (not laid out yet) the
-- whole screen is repainted.
function ScreenWidget:_setSlotDirty(mod_id, slot)
    local wrapper = self._wrapper_pool and self._wrapper_pool[mod_id]
    local dimen   = (wrapper and wrapper.dimen) or (slot.content and slot.content.dimen)
    if dimen then
        self:_repaintIfShown(function() return "ui", dimen end)
    else
        self:_repaintIfShown("ui")
    end
end

-- ---------------------------------------------------------------------------
-- _scheduleDataRefresh — queues the deferred data pass that follows a paint:
-- authoritative book list, stats and in-place module updates. Calls made
-- while a pass is already queued merge into it, so it runs once.
-- ---------------------------------------------------------------------------
function ScreenWidget:_scheduleDataRefresh(stats_only)
    if self._refresh_scheduled then
        -- A deferred refresh is already queued and will run once,
        -- acting on self._refresh_pending_stats_only. Two call sites
        -- can race for this same slot on device resume
        -- (SimpleUIPlugin:onResume wants the full refresh;
        -- ScreenWidget:onResume wants stats_only) — upgrading the
        -- pending flag in place, only ever from true to false, means
        -- the callback always does at least as much work as the
        -- strongest caller seen before it fires, regardless of
        -- arrival order.
        if not stats_only then
            self._refresh_pending_stats_only = false
        end
        return
    end
    self._refresh_scheduled = true
    self._refresh_pending_stats_only = stats_only
    local token = {}
    self._pending_refresh_token = token

    UIManager:scheduleIn(0.05, function()
        if self._pending_refresh_token ~= token then return end
        if _sget(self._id, "_instance") ~= self then return end
        self._refresh_scheduled = false
        -- Read live rather than the closed-over parameter: a later
        -- caller may have upgraded this pending refresh (see above).
        local pending_stats_only = self._refresh_pending_stats_only

        Perf.mark("data refresh start")
        if not self._db_conn then
            self._db_conn = Config.openStatsDB()
        end
        Perf.mark("data refresh: db opened")

        if self._ctx_cache then
            -- A deferred first paint built the ctx without a connection.
            self._ctx_cache.db_conn = self._db_conn
            -- 1. Get new book metadata (prefetchBooks).
            if not pending_stats_only then
                local new_bs = self:_prefetchBooks()
                if new_bs then
                    self._cached_books_state = new_bs
                    self._ctx_cache.prefetched = new_bs.prefetched_data
                    self._ctx_cache.current_fp = new_bs.current_fp
                    self._ctx_cache.recent_fps = new_bs.recent_fps

                    -- self._ctx_cache is reused (mutated), not
                    -- rebuilt, on this debounced path. GridRenderer.
                    -- build() memoizes each row module's file list
                    -- into ctx[cache_key] on first build() and never
                    -- re-reads getFileList() again for that same ctx
                    -- object, so any row module without its own
                    -- updateStats (Recent Books, New Books, TBR,
                    -- Collections, ...) needs its row cache cleared
                    -- here before the fallback mod.build() call in
                    -- step 3 below, or it would keep serving the file
                    -- list from before this prefetchBooks() pass.
                    -- Currently Reading is unaffected: module_currently
                    -- reads ctx.current_fp directly with no
                    -- intermediate cache. Same treatment as
                    -- _refreshImmediate's keep_cache=true path.
                    -- clearRowCaches() also invalidates the
                    -- section-label header cache (page/npages
                    -- indicator + chevrons) for the same paginated
                    -- rows — see its doc comment in sui_book_grid.lua.
                    local ok_gr, GR = pcall(require, "engines/sui_book_grid")
                    if ok_gr and GR then GR.clearRowCaches(self._ctx_cache) end
                end
            end

            -- onShow() seeds _cached_books_state with a best-effort
            -- stub via SH.getStaleBooks() so the first paint can
            -- already show real covers/titles. That stub can be
            -- incomplete or missing (e.g. the very first run ever),
            -- so an is_book_mod module (currently, coverdeck, recent)
            -- can return nil/empty from build() on that first pass
            -- and never get a slot in _book_mod_slots. Now that the
            -- authoritative prefetchBooks() data has landed above,
            -- check for any such module and force a full rebuild so
            -- build() runs again with complete data — the in-place
            -- updateStats path below only touches slots that already
            -- exist. Cheap to check unconditionally: just an
            -- iteration over the small set of registered modules.
            do
                -- Slots only exist for the modules of the displayed page(s)
                -- (two in a landscape spread), so only those are checked.
                local missing_slot = false
                local pages = self._enabled_mods_cache and self._enabled_mods_cache.pages_of_mods or {}
                local shown = { pages[self._current_page] }
                if _isLandscape() then shown[2] = pages[self._current_page + 1] end
                -- A module that built with no items only forces the rebuild
                -- when the authoritative data now gives it some.
                for _, page_mods in pairs(shown) do
                    for _, mod in ipairs(page_mods) do
                        if mod.is_book_mod and not self._book_mod_slots[mod.id] then
                            local empty_w = self._book_mod_empty and self._book_mod_empty[mod.id]
                            if not empty_w or self:_bookModHasItems(mod, empty_w) then
                                missing_slot = mod.id
                                break
                            end
                        end
                    end
                    if missing_slot then break end
                end
                if missing_slot then
                    Perf.mark("screen data refresh: full rebuild, no slot for " .. missing_slot)
                    self:_updatePage(false)
                    self:_repaintIfShown("ui")
                end
            end

            Perf.mark("data refresh: books resolved")
            -- 2. Get new global stats
            local SP = _getStatsProvider()
            if SP then
                local new_stats = SP.get(self._db_conn, self._ctx_cache.year_str, self._ctx_cache._needs_books)
                if new_stats then self._ctx_cache.stats = new_stats end
                if self._ctx_cache._needs_status and SP.getStatusCounts then
                    self._ctx_cache.status_counts = SP.getStatusCounts()
                end
                Perf.mark("data refresh: status counts done")
                if self._ctx_cache._needs_records and SP.getSessionRecords then
                    self._ctx_cache.session_records = SP.getSessionRecords(self._db_conn)
                end
                Perf.mark("data refresh: session records done")
                if self._ctx_cache._needs_year and SP.getYearData then
                    self._ctx_cache.year_data = SP.getYearData(self._db_conn)
                end
                Perf.mark("data refresh: year data done")
                if self._ctx_cache._needs_charts and SP.getChartData then
                    self._ctx_cache.stat_charts = SP.getChartData(self._db_conn)
                end
                Perf.mark("data refresh: chart data done")
            end

            Perf.mark("data refresh: global stats done")
            local MC = package.loaded["modules/module_currently"]
            if MC and MC.fetchBookStatsForCtx and self._ctx_cache.current_fp then
                local pe = self._ctx_cache.prefetched and self._ctx_cache.prefetched[self._ctx_cache.current_fp]
                local md5 = pe and pe.partial_md5_checksum
                if md5 then
                    self._ctx_cache.currently_book_stats = {
                        fp = self._ctx_cache.current_fp,
                        stats = MC.fetchBookStatsForCtx(md5, self._db_conn, true)
                    }
                end
            end

            local MCD = package.loaded["modules/module_coverdeck"]
            if MCD and MCD.fetchBookStatsForCtx
                    and (self._ctx_cache.current_fp or self._ctx_cache.recent_fps) then
                local center_fp = _coverdeckDefaultCenterFp(
                    self._ctx_cache.current_fp, self._ctx_cache.recent_fps)
                local pe = center_fp and self._ctx_cache.prefetched and self._ctx_cache.prefetched[center_fp]
                local md5 = pe and pe.partial_md5_checksum
                if md5 then
                    self._ctx_cache.coverdeck_center_stats = {
                        fp = center_fp,
                        stats = MCD.fetchBookStatsForCtx(md5, self._db_conn, true)
                    }
                end
            end

            Perf.mark("data refresh: book stats done")
            -- 3. Update Book Modules
            -- Try updateStats in-place first (O(1), zero alloc).
            -- Only rebuilds the full widget if the module doesn't have updateStats
            -- (fallback for modules that don't support in-place update).
            if not pending_stats_only then
                for id, slot in pairs(self._book_mod_slots or {}) do
                    local updated_in_place = false
                    if type(slot.mod.updateStats) == "function" then
                        local ok, result = pcall(slot.mod.updateStats, slot.content, self._ctx_cache)
                        updated_in_place = ok and result
                    end

                    Perf.mark("data refresh: book module " .. id
                        .. (updated_in_place and " updated in place" or " rebuilt"))
                    if updated_in_place then
                        self:_setSlotDirty(id, slot)
                        -- An in-place update can shift npages without the
                        -- current page's own slice changing (see
                        -- GridRenderer.updateStats), so the header follows.
                        self:_syncBookModLabel(id)
                    else
                        -- Full rebuild (module has no updateStats, or it
                        -- returned false because the book's identity changed).
                        -- _refreshBookModSlot is the single path that also
                        -- keeps the cover-poll slot on the mounted widget,
                        -- flushes newly queued covers and syncs the header.
                        self:_refreshBookModSlot(id)
                    end
                end
            end

            Perf.mark("data refresh: book modules done")
            -- 4. Update Stats Modules
            -- Each slot uses setDirty targeted at its own dimen,
            -- avoiding a global repaint of the entire screen.
            -- updateStats() returns false when _changed flags show none of the
            -- module's fields were re-fetched — skip setDirty entirely in that case.
            for id, slot in pairs(self._stats_mod_slots or {}) do
                -- Book modules were already updated above, unless this pass is stats-only.
                if pending_stats_only or not (self._book_mod_slots and self._book_mod_slots[id]) then
                    local ok, changed = pcall(slot.mod.updateStats, slot.content, self._ctx_cache)
                    if not ok then
                        logger.warn("simpleui: updateStats failed for " .. tostring(id) .. ": " .. tostring(changed))
                    elseif changed then
                        self:_setSlotDirty(id, slot)
                    end
                end
            end
            Perf.finish("screen data refresh done")
        end
    end)
end

-- ---------------------------------------------------------------------------
-- _refresh — debounced rebuild. Page turns call _updatePage directly.
-- ---------------------------------------------------------------------------
-- True when the file browser's "flash on cover images" option is enabled.
local function _flashCoverImages()
    local ok, bim = pcall(require, "bookinfomanager")
    return ok and bim:getSetting("flash_ui_cover_images") and true or false
end

-- True when every home screen page turn should flash, covers or not.
local function _flashAllPages()
    return SUISettings:isTrue("simpleui_hs_flash_all_pages")
end

function ScreenWidget:_refresh(keep_cache, books_only, stats_only, page_turn)
    local defer_async = false
    if not keep_cache and self._body and self._ctx_cache then
        defer_async = true
        keep_cache  = true
    end

    if keep_cache and self._body then
        local had_covers = self._page_has_covers
        self:_updatePage(true)
        local flash = page_turn and (_flashAllPages()
            or ((had_covers or self._page_has_covers) and _flashCoverImages()))
        self:_repaintIfShown(flash and "flashui" or "ui")

        if defer_async then self:_scheduleDataRefresh(stats_only) end
        return
    end

    self._cached_books_state = nil
    self._enabled_mods_cache = nil
    self._ctx_cache          = nil
    self._cfg_cache          = nil
    _sset(self._id, "_cfg_cache", nil)

    if self._refresh_scheduled then return end
    self._refresh_scheduled = true
    local token = {}
    self._pending_refresh_token = token
    UIManager:scheduleIn(0, function()
        if self._pending_refresh_token ~= token then return end
        if _sget(self._id, "_instance") ~= self then return end
        self._refresh_scheduled = false
        if not self._navbar_container then return end
        self:_updatePage(false)
        self:_repaintIfShown("ui")
    end)
end

function ScreenWidget:_setCoverdeckIdx(idx)
    if self._ctx_cache then
        self._ctx_cache.coverdeck_cur_idx = idx
    end
end

-- ---------------------------------------------------------------------------
-- _refreshBookModSlot — surgical, single-module repaint for is_book_mod
-- modules (currently, coverdeck, recent) that need an immediate rebuild
-- outside the normal debounced _refresh() cycle — e.g. coverdeck's
-- onTap/onSwipe handlers. Rebuilds just this module's widget via
-- slot.mod.build(), splices it back into its slot (parent[index] or the
-- has_menu wrapper), and calls UIManager:setDirty with the new widget's own
-- `dimen` instead of the whole-screen `self`, so only that widget's region
-- refreshes on the next e-ink update — no other module repaints, no
-- full-screen flash.
--
-- Returns true if the slot was found and repainted, false otherwise (caller
-- should fall back to _refreshImmediate as a safety net — e.g. if the slot
-- doesn't exist yet, build() returned nil, or anything is missing).
-- ---------------------------------------------------------------------------
-- _bookModRefreshType(mod_id) — "ui" | "flashui"
--
-- _refreshBookModSlot always uses a "ui" refresh (non-flashing by design, so
-- there's no flash on every swipe/tap on a book row or the coverdeck). "ui",
-- unlike "partial", is never promoted to flashing by UIManager (that
-- promotion only exists for "partial" via FULL_REFRESH_COUNT). Without a
-- periodic flash, repeated non-flashing refreshes accumulate e-ink ghosting.
--
-- Replicates the same promotion "partial" already has natively, using the
-- same threshold configured by the user (UIManager.FULL_REFRESH_COUNT, 6 by
-- default): every N surgical refreshes of this module, force a "flashui"
-- (clears the accumulated ghosting) and reset the count.
function ScreenWidget:_bookModRefreshType(mod_id)
    local counts = self._book_mod_refresh_n
    if not counts then return "ui" end
    local n = (counts[mod_id] or 0) + 1
    local threshold = UIManager.FULL_REFRESH_COUNT or 6
    if n >= threshold then
        counts[mod_id] = 0
        return "flashui"
    end
    counts[mod_id] = n
    return "ui"
end

-- Single entry point for "move this paginated book module by one page",
-- shared by the section-label chevrons (see _labelFor) and the
-- swipe gesture on the row/grid itself (engines/sui_book_grid.lua's
-- swipe_area:onSwipe). Clamped (no wraparound — page 1 has no previous,
-- the last page has no next): GridRenderer.turnPage returns nil at either
-- edge, in which case this is a no-op and no repaint is triggered.
function ScreenWidget:_turnBookModPage(mod_id, delta)
    if not self._ctx_cache then return false end
    local ok_gr, GridRenderer = pcall(require, "engines/sui_book_grid")
    if not ok_gr or not GridRenderer then return false end
    local page, npages = SectionLabel.PageState.get(self._ctx_cache, mod_id)
    local new_page = GridRenderer.turnPage(page, npages, delta)
    if not new_page then return false end
    SectionLabel.PageState.setPage(self._ctx_cache, mod_id, new_page)
    self:_repaintBookMod(mod_id)
    return true
end

-- Repaints one book module after its state changed (page turn, tab change):
-- the surgical slot repaint, or a full rebuild that keeps the ctx cache when
-- the slot cannot be repainted in place.
function ScreenWidget:_repaintBookMod(mod_id)
    if self._refreshBookModSlot and self:_refreshBookModSlot(mod_id) then return end
    if self._refreshImmediate then self:_refreshImmediate(true) end
end

-- ---------------------------------------------------------------------------
-- Section label
--
-- _labelFor is the single place a module's label widget is produced, for the
-- first paint (_emit_mod) and for surgical updates (_syncBookModLabel) alike,
-- so text, right-hand text, page state and visibility never diverge between
-- the two. The widgets are cached per screen instance (self._label_cache):
-- their chevrons call back into this instance, so they must not outlive it.
-- ---------------------------------------------------------------------------
-- `inside` is nil for a label above the module's box, or the descriptor of
-- one inside it (see SectionLabel.get); `col_w` is the width the label spans.
function ScreenWidget:_labelFor(mod, col_w, ctx, inside)
    local desc = SectionLabel.describe(mod, ctx)
    if not desc then return nil end
    self._label_cache = self._label_cache or {}
    self._turn_page_fn = self._turn_page_fn or function(mod_id, delta)
        return self:_turnBookModPage(mod_id, delta)
    end
    local label, stops = SectionLabel.get(self._label_cache, mod.id, desc, col_w,
        ctx.landscape_factor, self._turn_page_fn, ctx.kbStops ~= nil, inside)
    if mod.is_book_mod and ctx.kbStops then ctx.kbStops(mod.id .. ":label", stops) end
    return label
end

-- Surgical repaint of a paginated book module's section title: the "x/y"
-- page indicator and its chevrons.
--
-- A book module's grid content and its title live in separate widgets (see
-- _book_mod_slots vs _book_mod_label_slots), so every caller that changes a
-- paginated module's content (page turn, background stats refresh, status or
-- collection change, ...) must call this afterwards. The label is recomputed
-- from ctx, so this is always safe to call: it is a no-op (no setDirty) when
-- the label is identical to the one already mounted.
function ScreenWidget:_syncBookModLabel(mod_id)
    local slot = self._book_mod_label_slots and self._book_mod_label_slots[mod_id]
    local ctx  = self._ctx_cache
    if not (slot and slot.parent and ctx) then return end
    local new_label = self:_labelFor(slot.mod, slot.col_w, ctx, slot.inside)
    if not new_label or new_label == slot.parent[slot.index] then return end
    slot.parent[slot.index] = new_label
    if new_label.dimen then
        self:_repaintIfShown(function() return "ui", new_label.dimen, true end)
    else
        self:_repaintIfShown("ui")
    end
end

function ScreenWidget:_refreshBookModSlot(mod_id)
    if not self._ctx_cache or not self._book_mod_slots then return false end
    local slot = self._book_mod_slots[mod_id]
    if not slot or not slot.mod or type(slot.mod.build) ~= "function" then return false end

    local new_widget, new_content = self:_buildModWidget(slot.mod, slot.col_w, self._ctx_cache, slot.min_h)
    if not new_widget then return false end

    if slot.has_menu then
        if not (self._wrapper_pool and self._wrapper_pool[mod_id]) then return false end
        -- Reuses _makeModWrapper (instead of swapping wrapper[1] by hand) so
        -- wrapper.dimen.w/h get resynced with new_widget's real size, just
        -- like a full build — otherwise a taller widget's refresh region
        -- would be too small for UIManager:setDirty to fully clear/repaint.
        local wrapper = self:_makeModWrapper(slot.mod, new_widget, slot.col_w)
        slot.widget  = new_widget
        slot.content = new_content
        local rtype = self:_bookModRefreshType(mod_id)
        self:_repaintIfShown(function() return rtype, wrapper.dimen, true end)
    else
        if not slot.parent then return false end
        slot.parent[slot.index] = new_widget
        slot.widget  = new_widget
        slot.content = new_content
        local rtype = self:_bookModRefreshType(mod_id)
        self:_repaintIfShown(function() return rtype, new_widget.dimen, true end)
    end
    -- The stats updater patches the widget now mounted, not the replaced one.
    local stats_slot = self._stats_mod_slots and self._stats_mod_slots[mod_id]
    if stats_slot then stats_slot.content = new_content end
    -- Point the cover-poll slot at the currently visible widget, so covers
    -- still pending extraction get swapped into it rather than into the old,
    -- now-orphaned widget. The poll drops a slot once its module is resolved,
    -- so the slot is registered again here.
    if self._cover_mod_slots and slot.mod.has_covers
            and type(slot.mod.updateCovers) == "function" then
        self._cover_mod_slots[mod_id] = { mod = slot.mod, widget = new_content }
    end

    -- slot.mod.build() above can have queued brand-new files for cover
    -- extraction (getCoverBB() -> enqueueExtract() for any book not yet in
    -- BIM's cache — see infra/sui_config.lua). _updatePage() flushes that
    -- queue and arms the poll on every full rebuild, but this repaint path
    -- — swipe pagination on a paged=true grid (sui_book_grid.lua's
    -- swipe_area:onSwipe) — bypasses _updatePage entirely, so it must flush
    -- and arm the poll itself here too.
    Config.flushCoverQueue()
    if Config.cover_extraction_pending and not self._cover_poll_timer then
        self:_scheduleCoverPoll()
    end

    -- Surgical repaint of the page indicator ("1/2") and its chevrons in the
    -- section title: slot.mod.build() (above) already updated ctx with the
    -- current page, but the title lives in a sibling widget outside the
    -- tree just replaced, so it needs its own sync call here.
    self:_syncBookModLabel(mod_id)

    return true
end

-- Immediate full rebuild — bypasses debounce. Used by showSettingsMenu's
-- onCloseWidget to guarantee the HS reflects changes before the next paint.
function ScreenWidget:_refreshImmediate(keep_cache)
    self._pending_refresh_token = {}
    self._refresh_scheduled     = false
    if not keep_cache then
        self._cached_books_state = nil
        self._enabled_mods_cache = nil
        self._ctx_cache          = nil
        self._cfg_cache          = nil
        _sset(self._id, "_cfg_cache", nil)
    elseif self._ctx_cache then
        -- keep_cache=true (the book-hold dialog's refresh_fn) deliberately
        -- preserves _ctx_cache/_cached_books_state to avoid re-running the
        -- expensive cover prefetch + config gathering for a small action
        -- (status change, collection toggle, TBR add/remove, ...). But each
        -- row module's own file list is *also* cached, inside that same ctx
        -- (see engines/sui_book_grid.lua, GridRenderer.build's ctx[cache_key])
        -- — set once on first build and never touched again for that ctx's
        -- lifetime. A kept-alive ctx therefore keeps serving the pre-action
        -- list forever: e.g. a book just removed from TBR here still shows
        -- in the TBR row until the Homescreen is fully torn down and rebuilt.
        -- Clear just those (cheap: a ReadCollection/settings lookup, not the
        -- I/O keep_cache is protecting) so the very next build re-fetches
        -- each row's current membership. clearRowCaches() also invalidates
        -- the section-label header cache (page/npages indicator + chevrons)
        -- for the same paginated rows — see its doc comment in
        -- sui_book_grid.lua for why that lives there instead of here.
        local ok_gr, GridRenderer = pcall(require, "engines/sui_book_grid")
        if ok_gr and GridRenderer then GridRenderer.clearRowCaches(self._ctx_cache) end
        -- Hold-dialog actions (status, reset, ...) write the sidecar but
        -- leave ctx.prefetched with the pre-action percent/summary. Clear
        -- just those fields so the next build/getBookData re-reads them
        -- from DocSettings without a full prefetchBooks (titles/covers/md5
        -- stay cached). Progress badges on Cover Deck and book-grid modules
        -- stay accurate after status changes on the homescreen.
        local prefetched = self._ctx_cache.prefetched
        if type(prefetched) == "table" then
            for _, entry in pairs(prefetched) do
                if type(entry) == "table" then
                    entry.percent = nil
                    entry.summary = nil
                end
            end
        end
    end
    if not self._navbar_container then return end
    self:_updatePage(keep_cache or false)
    UIManager:setDirty(self, "ui")
end

-- ---------------------------------------------------------------------------
-- Cover extraction poll
-- ---------------------------------------------------------------------------
-- Polls every 1 second (like the History page). On each tick, for every cover
-- module that still has pending covers, calls mod.updateCovers(widget, ctx)
-- which swaps only the individual ImageWidgets that have now arrived in the
-- DB cache — no full build(), no layout recalculation, no TextWidget creation.
--
-- Each module's updateCovers() returns true when all its covers are resolved
-- (either a bitmap arrived or the file is confirmed to have no cover).
-- The slot is then removed and the poll stops once no slots remain.
--
-- Cover extraction flow within the poll:
--   1. updateCovers() calls getCoverBB() for each missing slot.
--   2. getCoverBB() returns nil for two reasons:
--        a) cover_fetched=false  → file not yet extracted; enqueues the filepath.
--        b) cover_fetched=true, has_cover=false → no cover in file; marks with
--           the NO_COVER sentinel so future calls skip the BIM query entirely.
--   3. After the slot loop, flushCoverQueue() submits newly enqueued files to
--      the BIM as a single extractInBackground call.
--   4. updateCovers() returns true when every slot either has a bitmap or is
--      confirmed missing (isCoverMissing).  The module is then dropped from
--      the poll so we never spin on files that have no cover.
-- ---------------------------------------------------------------------------
function ScreenWidget:_scheduleCoverPoll()
    local self_ref = self
    local timer
    timer = function()
        self_ref._cover_poll_timer = nil
        if _sget(self_ref._id, "_instance") ~= self_ref then return end

        local bim              = Config.getBookInfoManager()
        local is_still_running = bim and bim:isExtractingInBackground()
        local slots            = self_ref._cover_mod_slots
        local ctx              = self_ref._ctx_cache

        if not slots or not ctx then
            Config.cover_extraction_pending = false
            self_ref:_refresh(true)
            return
        end

        local any_pending = false

        for mod_id, slot in pairs(slots) do
            if type(slot.mod.updateCovers) == "function" then
                local ok, all_done, changed = pcall(slot.mod.updateCovers, slot.widget, ctx)
                if ok then
                    local wrapper = self_ref._wrapper_pool and self_ref._wrapper_pool[mod_id]
                    local dimen   = (wrapper and wrapper.dimen) or (slot.widget and slot.widget.dimen)
                    -- Repaint only when a cover was actually patched in.
                    if dimen and changed then
                        self_ref.dithered = true
                        self_ref:_repaintIfShown(function()
                            return "ui", dimen, true
                        end)
                    end
                    if all_done then
                        slots[mod_id] = nil
                    else
                        any_pending = true
                    end
                else
                    logger.warn("simpleui cover poll: updateCovers error for " .. mod_id)
                    slots[mod_id] = nil
                end
            else
                slots[mod_id] = nil
            end
        end

        -- Submit any filepaths that getCoverBB() enqueued during the
        -- updateCovers pass above to the BIM as a single batch call.
        -- Without this, the queue is never flushed inside the poll loop.
        Config.flushCoverQueue()

        if not any_pending then
            Config.cover_extraction_pending = false
            logger.dbg("simpleui cover poll: complete")
            return
        end

        if is_still_running then
            -- BIM subprocess still running — wait for the next tick.
            logger.dbg("simpleui cover poll: BIM running, rescheduling")
            self_ref._cover_poll_timer = timer
            UIManager:scheduleIn(1, timer)
            return
        end

        -- BIM has finished but some slots still returned pending.
        -- Clear the dedup lock so getCoverBB() can re-enqueue on the next tick.
        -- This handles the race where BIM wrote the result just as we polled,
        -- meaning getBookInfo() hadn't yet refreshed its in-memory state.
        -- updateCovers() will see the updated state on the next tick and either
        -- resolve the cover or mark it NO_COVER (which makes all_done = true).
        if Config._cover_extract_pending then
            for fp in pairs(Config._cover_extract_pending) do
                Config._cover_extract_pending[fp] = nil
            end
        end

        logger.dbg("simpleui cover poll: BIM done, one final retry for missing covers")
        self_ref._cover_poll_timer = timer
        UIManager:scheduleIn(1, timer)
    end
    self._cover_poll_timer = timer
    UIManager:scheduleIn(1, timer)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function ScreenWidget:onShow()
    local need_async = false
    if self._stats_need_refresh or _sget(self._id, "_stats_need_refresh") then
        self._stats_need_refresh = nil
        _sset(self._id, "_stats_need_refresh", nil)
        need_async = true
    end

    -- Consumed at most once per process (or per hot-reload): the very first
    -- screen shown is allowed to block below on a live books+stats fetch
    -- instead of taking the stale-then-correct path every other cold-open
    -- uses. Every subsequent onShow() — including every reader return —
    -- falls through to the unchanged behaviour further down.
    local is_app_cold_boot = _cold_boot_pending
    if is_app_cold_boot then
        _cold_boot_pending = false
    end

    if not self._cached_books_state then
        if is_app_cold_boot then
            -- App startup: resolve the book list synchronously so the very
            -- first paint already has authoritative data.
            self._cached_books_state = self:_prefetchBooks()
                or { current_fp = nil, recent_fps = {}, prefetched_data = {} }
        else
            -- Cold-open path: _cached_books_state is nil, so _buildCtx would
            -- otherwise call prefetchBooks() (sidecar I/O for every recent
            -- book) and SP.get() (DB queries) synchronously, blocking the
            -- first paint. Mirrors the pattern already used for
            -- reading_stats (_defer_stats -> SP.getStale()): SH.getStaleBooks()
            -- returns an instant reference to the last successful
            -- SH.prefetchBooks() result, persisted across process restarts
            -- too (see module_books_shared.lua), with no ReadHistory walk
            -- and no sidecar lookups. is_book_mod modules (currently,
            -- coverdeck, recent) render with the exact same data they last
            -- had.
            --
            -- getStaleBooks() returns nil only on a genuinely first-ever run
            -- (no in-memory cache and no on-disk mirror). In that case
            -- is_book_mod modules fall back to their own "no data yet" path
            -- (build() returns nil/empty) for a single harmless frame,
            -- corrected by the deferred refresh moments later.
            --
            -- need_async stays true regardless, so the full, authoritative
            -- prefetchBooks() pass still runs ~50ms later via the deferred
            -- _refresh() and corrects anything the stale data got wrong
            -- (book finished, new book opened since the cache was built,
            -- etc.).
            local SH = _getBookShared()
            local stale = SH and SH.getStaleBooks and SH.getStaleBooks()
            if stale then
                -- Defensive: unlike prefetchBooks()'s live ReadHistory walk, this
                -- persisted cross-process snapshot deliberately skips
                -- lfs.attributes for speed (see the comment above), so it can
                -- carry a filepath for a book that was deleted while KOReader
                -- was closed (e.g. via Calibre over USB). Every other path in
                -- this plugin that touches a book filepath (prefetchBooks,
                -- TBR.getTBRList, Config.getCoverBB) already guards with the
                -- same check; this cache was the one gap. A handful of stat()
                -- calls here is negligible next to the instant-paint goal this
                -- mechanism exists for, and it stops a dangling path from ever
                -- reaching cover extraction / doc-open code further down.
                --
                -- Virtual paths are skipped: lfs.attributes cannot resolve them,
                -- so a real-file check would report every virtual book as
                -- missing instead of only catching deleted ones.
                local function _existsOrVirtual(fp)
                    if VirtualPaths.isVirtual(fp) then return true end
                    return lfs.attributes(fp, "mode") == "file"
                end
                if stale.current_fp and not _existsOrVirtual(stale.current_fp) then
                    stale.current_fp = nil
                end
                if stale.recent_fps then
                    local kept = {}
                    for _, fp in ipairs(stale.recent_fps) do
                        if _existsOrVirtual(fp) then
                            kept[#kept + 1] = fp
                        end
                    end
                    stale.recent_fps = kept
                end
            end
            self._cached_books_state = stale or { current_fp = nil, recent_fps = {}, prefetched_data = {} }
            need_async = true
        end
    end

    if self._navbar_container then
        local overlap = self:_initLayout()
        self:_swapLayoutTree(overlap)

        -- Only the ordinary cold-open enters deferred-stats mode. On the
        -- app-cold-boot pass, _defer_stats stays falsy so _buildCtx() takes
        -- its live branch below: opens the DB connection, calls SP.get()
        -- for real, and computes status_counts / book stats synchronously —
        -- exactly what the async correction tick would do, just inline.
        if need_async and not is_app_cold_boot then
            self._defer_stats = true
        end

        Perf.mark("screen onShow build start")
        self:_updatePage(true)
        UIManager:setDirty(self, "ui")
        Perf.mark("screen first paint queued")
        local ClockMod = Registry.get("clock")
        if ClockMod and Registry.isEnabled(ClockMod, self._pfx) and ClockMod.scheduleRefresh then
            ClockMod.scheduleRefresh(self)
        end

        if need_async and not is_app_cold_boot then
            self._defer_stats = false
            self:_scheduleDataRefresh(false)
        end
    end
end

function ScreenWidget:onClose()
    UIManager:close(self)
    return true
end

-- ---------------------------------------------------------------------------
-- Statistics cloud sync
--
-- ReaderStatistics.onSync merges local / cached / income. An open SimpleUI
-- handle on statistics.sqlite3 can keep WAL frames out of the main file and
-- hide rows from the merge, which then treats them as local deletions.
--
-- prepareForStatsSync closes every live screen connection, blocks new opens
-- via Config.beginStatsSyncGuard, and checkpoints the WAL. finishStatsSync
-- restores opens and refreshes visible screens. Idempotent — both the
-- ScreenWidget event handler and the main.lua ReaderStatistics patch call it.
-- ---------------------------------------------------------------------------
local _stats_sync_finish_scheduled = false

function ScreenEngine.prepareForStatsSync()
    for _, id in ipairs(ScreenEngine.liveScreenIds()) do
        local inst = ScreenEngine.getInstance(id)
        if inst and inst._db_conn then
            pcall(function() inst._db_conn:close() end)
            inst._db_conn = nil
        end
    end
    Config.beginStatsSyncGuard()
    Config.checkpointStatsDB()

    if _stats_sync_finish_scheduled then return end
    _stats_sync_finish_scheduled = true

    local function finish()
        if not _stats_sync_finish_scheduled then return end
        _stats_sync_finish_scheduled = false
        ScreenEngine.finishStatsSync()
    end

    -- SyncService.sync runs on the next tick to completion; two further
    -- ticks are safely after the merge. scheduleIn(10) covers missed ticks.
    UIManager:tickAfterNext(function()
        UIManager:nextTick(finish)
    end)
    UIManager:scheduleIn(10, finish)
end

function ScreenEngine.finishStatsSync()
    Config.endStatsSyncGuard()
    for _, id in ipairs(ScreenEngine.liveScreenIds()) do
        local inst = ScreenEngine.getInstance(id)
        if inst then
            inst._ctx_cache = nil
            if not inst._parked and _sget(inst._id, "_instance") == inst then
                pcall(function() inst:_refresh(false) end)
            end
        end
    end
end

-- Broadcast path when a screen is on the stack. The main.lua patch covers
-- Reader/menu/auto-sync when no screen widget receives the event.
function ScreenWidget:onSyncBookStats()
    ScreenEngine.prepareForStatsSync()
    return false
end

-- Stops background timers so a screen does no wasted work while it cannot
-- be seen — either genuinely suspended (device sleep) or soft-parked
-- (hidden underneath the reader, see onShowingReader below). Shared by
-- both call sites so there is exactly one place this teardown subset lives.
function ScreenWidget:_pauseBackgroundWork()
    if self._cover_poll_timer then
        UIManager:unschedule(self._cover_poll_timer)
        self._cover_poll_timer = nil
    end
    local ClockMod = Registry.get("clock")
    if ClockMod and ClockMod.cancelRefresh then ClockMod.cancelRefresh() end
end

-- Whether the screen is built and in front of the user: not closed, parked
-- beneath the reader or suspended. Deferred background work checks this
-- between its steps.
function ScreenWidget:isActive()
    return self._ctx_cache ~= nil and not (self._parked or self._suspended)
end

function ScreenWidget:onSuspend()
    self._suspended = true
    self._resume_pending = nil
    self:_pauseBackgroundWork()
end

function ScreenWidget:onResume()
    self._suspended = false
    if Device.screen_saver_mode then
        -- A screensaver kept on screen after wakeup: catch up once it closes.
        self._resume_pending = UI.isScreensaverShown() or nil
        return
    end
    -- Parked: the reader owns the screen right now, and nothing here is
    -- visible. Skip the refresh/timer work entirely — _raiseParkedScreen
    -- (infra/sui_patches.lua) already refreshes this same state when the
    -- screen is promoted back to the foreground, so doing it here too
    -- would just be wasted work on a hidden widget.
    if self._parked then return end
    -- Invalidate the time-series portion of the stats cache so that any reading
    -- done before the suspend (or while the device was awake in the reader) is
    -- reflected immediately on wakeup.  We use invalidateTimeSeries rather than
    -- invalidate so that the expensive sidecar-scan (books_year/books_total) is
    -- preserved when the book's completion status has not changed — matching the
    -- same optimisation applied in onCloseDocument. The cache is kept as is
    -- when the statistics database did not change since it was built.
    -- stats_only=true keeps _cached_books_state intact (no sidecar I/O needed).
    local SP = package.loaded["modules/module_stats_provider"]
    if SP and SP.invalidateTimeSeriesIfDbChanged then
        SP.invalidateTimeSeriesIfDbChanged()
    elseif SP and SP.invalidate then
        SP.invalidate()
    end
    self:_refresh(false, false, true)
    local ClockMod = Registry.get("clock")
    if ClockMod and Registry.isEnabled(ClockMod, self._pfx) and ClockMod.scheduleRefresh then
        ClockMod.scheduleRefresh(self)
    end
end

-- Sent while the screensaver is still on the stack: run the deferred wakeup
-- work on the next tick, once it is gone.
function ScreenWidget:onOutOfScreenSaver()
    if not self._resume_pending then return end
    self._resume_pending = nil
    UIManager:nextTick(function()
        if _sget(self._id, "_instance") == self and not self._suspended then self:onResume() end
    end)
end

function ScreenWidget:onSetRotationMode(mode)
    logger.dbg("simpleui[rotation]:", tostring(self._id), "onSetRotationMode",
        "mode=", mode, "current_mode=", Screen:getRotationMode())

    -- Ignore rotation events originating inside an open ReaderUI.
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance then
        logger.dbg("simpleui[rotation]:", tostring(self._id), "ignoring, ReaderUI open")
        return
    end

    -- ScreenWidget is on top of the UIManager stack, so broadcastEvent
    -- delivers SetRotationMode here *before* FileManager:onSetRotationMode runs.
    -- Screen:setRotationMode() has therefore not been called yet -- Screen:getWidth()
    -- and Screen:getHeight() still return the pre-rotation dimensions, so a
    -- size-based guard would always see "no change" and silently skip the
    -- rebuild.
    --
    -- We use the 'mode' argument to detect an orientation change instead.
    -- LinuxFB constants: portraits are even (0, 2), landscapes are odd (1, 3).
    -- A flip in the low bit means layout dimensions will swap -> rebuild needed.
    -- Same-family flips (e.g. 0 <-> 180 portrait inversion) leave dimensions
    -- unchanged, so they don't need a rebuild.
    local current_mode = Screen:getRotationMode()
    if mode == current_mode then
        logger.dbg("simpleui[rotation]:", tostring(self._id), "mode unchanged")
        return
    end

    -- Records that a genuine rotation happened, for the setupLayout guard in
    -- sui_patches.lua (see UI.bumpRotationGeneration / UI.getRotationGeneration
    -- in sui_core.lua).
    UI.bumpRotationGeneration()

    local current_is_landscape = (current_mode % 2) == 1
    local new_is_landscape     = (mode      % 2) == 1

    -- Invalidate every known screen id's _cfg_cache, not just self._id: a
    -- screen left open in the background (e.g. under a Settings Window)
    -- must also pick up settings for the new orientation next time it builds.
    if current_is_landscape ~= new_is_landscape then
        for _, id in ipairs(ScreenEngine.knownScreenIds()) do
            _sset(id, "_cfg_cache", nil)
            -- Also clear the in-memory field on any screen that's currently
            -- live but not on top (e.g. a Custom Screen left open underneath
            -- a Settings Window) -- _buildCtx() reads self._cfg_cache
            -- directly and never re-consults the store above, so a stale
            -- in-memory value would otherwise survive until that instance
            -- happens to close and reopen.
            local live = _sget(id, "_instance")
            if live and live ~= self then
                live._cfg_cache = nil
            end
        end
    end

    if current_is_landscape == new_is_landscape then
        -- FileManager:onSetRotationMode is normally the only place that calls
        -- Screen:setRotationMode() (see the note above), but it never runs
        -- for same-family flips while the Homescreen is in the foreground --
        -- so without this call the Screen's internal rotation state never
        -- changes: we'd repaint everything (a visible flash) but always with
        -- the old orientation. We call it here explicitly, just as
        -- FileManager:onSetRotationMode already does for its own cases.
        Screen:setRotationMode(mode)
        logger.dbg("simpleui[rotation]:", tostring(self._id), "calling Screen:setRotationMode",
            "mode=", mode)

        -- Same-family flip (e.g. upright <-> upside-down). Screen dimensions
        -- are unchanged so no rebuild is needed, but cached visual content
        -- (wallpaper, dim cache) was drawn assuming the old orientation and
        -- is now shown over a framebuffer that has already physically
        -- rotated 180° -- invalidate those caches and force a full repaint
        -- of this widget before returning.
        --
        -- SUIWallpaper.freeCache() frees the background ImageWidget and
        -- BlitBuffer that are still referenced inside the existing widget
        -- tree (self._navbar_container[1] etc., built earlier by
        -- _initLayout()), so it must never be followed by a repaint of that
        -- same tree without rebuilding it first -- every other call-site of
        -- SUIWallpaper.freeCache() in this file follows it with
        -- _rebuildScreenLayout() (see ScreenEngine.rebuildLayout() further
        -- down), which rebuilds the tree with a new background widget before
        -- any repaint. We reproduce the same essential behaviour here via
        -- self:_initLayout() instead of calling the local function directly:
        -- _rebuildScreenLayout() is only declared further down in this file,
        -- after this function, so calling it here would resolve to a
        -- nonexistent global instead of the local upvalue. self:_initLayout()
        -- is a class method, resolved at call time, so it doesn't have this
        -- declaration-order problem.
        SUIWallpaper.freeCache()
        UI.invalidateDimCache()
        if self._navbar_container then
            self._cached_books_state = nil
            self._enabled_mods_cache = nil
            self._ctx_cache          = nil
            self._cfg_cache          = nil
            _sset(self._id, "_cfg_cache", nil)
            local overlap = self:_initLayout()
            self:_swapLayoutTree(overlap)
            self:_updatePage(true)
        end
        UIManager:setDirty(self, "full")
        logger.dbg("simpleui[rotation]:", tostring(self._id), "same-family, skipping rebuild")
        return
    end

    -- Free the wallpaper cache now — it was drawn for the old orientation
    -- and this screen is about to close and reopen at the new one.
    SUIWallpaper.freeCache()
    UI.invalidateDimCache()

    -- Cross-family flip (dimensions actually swap).
    --
    -- We never call Screen:setRotationMode() ourselves here. This widget
    -- sits on top of the window stack and receives SetRotationMode before
    -- FileManager does, so if we rotated the screen now, FileManager's own
    -- rotation guard would see "nothing changed" by the time the event
    -- reaches it further down the stack, and skip its own setupLayout --
    -- the only place that actually rebuilds the FileChooser/content at the
    -- new dimensions. So instead we close this screen, register it for
    -- reopening, and let the event carry on down to FileManager, whose
    -- patched setupLayout (infra/sui_patches.lua) does the real relayout
    -- and then reopens us once it's done.
    --
    -- _navbar_closing_intentionally makes onCloseWidget() treat this like a
    -- tab-switch close rather than a real dismissal, so _cached_books_state
    -- / _current_page carry over to the reopened screen. _cfg_cache is the
    -- one exception -- cleared first -- since it caches orientation-
    -- dependent scale values that must be recomputed for the new dimensions.
    self._cfg_cache = nil
    UI.setPendingRotationReopen(self._id, self.instance, self._on_qa_tap, self._on_goal_tap)

    self._navbar_closing_intentionally = true
    UIManager:close(self)
    self._navbar_closing_intentionally = nil

    logger.dbg("simpleui[rotation]: screen", tostring(self._id),
        "closed for cross-family flip, waiting for FileManager to reopen it")
end

function ScreenWidget:onCloseWidget()
    -- Free the entire built widget tree (self[1]: header/body/footer, every
    -- enabled module's covers, badges, wallpaper elements) before dropping
    -- references below. UIManager:close() only fires the CloseWidget event --
    -- it never calls widget:free() itself, so without this the tree relies
    -- solely on LuaJIT's GC to reclaim it. Blitbuffers are FFI cdata with an
    -- ffi.gc finalizer, so the incremental collector barely "feels" their
    -- real C-side size and doesn't prioritize reclaiming them -- RSS climbs
    -- across repeated open/close cycles even though nothing is unreachable-
    -- forever. Same pattern already used by the SUIWindow alpha-mask widget
    -- (infra/sui_core.lua: onCloseWidget() -> self:free()).
    --
    -- Safe here: every cover ImageWidget built into this tree is either
    -- privately decoded (icons: default image_disposable=true, meant to be
    -- freed) or explicitly image_disposable=false when backed by
    -- SUICoverCache/_bim_ref_cache (SH.getBookCover, SH.getCroppedBookCover,
    -- module_collections's stack/quad builders) -- audited 2026-08-08.
    self:free()

    -- Header chevrons call back into this instance; drop them with it.
    if self._label_cache then SectionLabel.release(self._label_cache) end
    self._label_cache  = nil
    self._turn_page_fn = nil

    if self._cover_poll_timer then
        UIManager:unschedule(self._cover_poll_timer)
        self._cover_poll_timer = nil
    end
    -- Invalidate debounce token so any scheduled callback becomes a no-op.
    self._pending_refresh_token = {}
    self._refresh_scheduled     = false

    -- On tab-switch preserve book state and page for the next open;
    -- on real close discard stale data.
    if self._navbar_closing_intentionally then
        _sset(self._id, "_cached_books_state", self._cached_books_state)
        _sset(self._id, "_current_page", self._current_page)
        _sset(self._id, "_cfg_cache", self._cfg_cache)
    else
        _sset(self._id, "_cached_books_state", nil)
        _sset(self._id, "_current_page", nil)
        _sset(self._id, "_cfg_cache", nil)
    end

    if self._db_conn then
        pcall(function() self._db_conn:close() end)
        self._db_conn = nil
    end
    self._vspan_pool         = nil
    self._wrapper_pool       = nil
    self._book_mod_refresh_n = nil
    self._cover_mod_slots    = nil
    self._cached_books_state = nil
    self._enabled_mods_cache = nil
    self._current_page       = nil
    self._total_pages        = nil
    self.page                = nil
    self.page_num            = nil
    self._ctx_cache          = nil
    self._stats_need_refresh = nil
    self._body               = nil
    self._overlap            = nil
    self._footer_bc          = nil
    self._footer_chevron     = nil
    self._footer_dot         = nil
    self._footer_hidden_span = nil
    self._layout_sw          = nil
    self._layout_content_h   = nil
    self._layout_inner_w     = nil
    self._kb_rows            = {}
    self._kb_row_by_key      = {}
    self._kb_stop            = nil
    self._parked              = nil -- defensive: real close always ends any park

    local ClockMod = Registry.get("clock")
    if ClockMod and ClockMod.cancelRefresh then ClockMod.cancelRefresh() end
    self._clock_body_ref   = nil
    self._clock_body_idx   = nil
    self._clock_is_wrapped = nil
    self._clock_pfx        = nil
    self._clock_inner_w    = nil
    self._clock_live       = nil
    self._overflow_warn_key = nil

    -- Consumes the "file browser visited" marker; the series grouping module
    -- reads it to decide when to flush its folder cover lookups.
    ScreenEngine._library_was_visited = nil

    -- The tree freed above leaves native buffers waiting for the GC; collect
    -- once the UI is idle so the reader/homescreen transition is not delayed.
    Memory.requestCollect()

    if _sget(self._id, "_instance") == self then
        _sset(self._id, "_instance", nil)
    end
end

-- Mirrors native KOReader's FileManager:onShowingReader(): ReaderUI:showReader()
-- broadcasts this event right before its first paint. FileManager listens for
-- it and closes itself atomically so it doesn't linger, hidden, underneath
-- the reader for the whole session — UIManager:show() never closes widgets
-- already on the stack, so without a handler here the opposite happens.
--
-- Without this handler, the screen (grid, covers, badges, the header
-- clock/quote refresh chain) would stay fully resident and hidden for the
-- whole reading session, torn down only once the book closed — receiving
-- broadcast events meant for the reader in the meantime, with no limit on
-- how many hidden screens could pile up at once. Closing here instead means
-- the screen is always torn down before the reader takes over, and rebuilt
-- when the reader gives control back — at the cost of a full rebuild (DB
-- reconnect, cover decode, widget tree) on every reader round-trip.
--
-- Soft-park (ScreenEngine.isSoftParkEnabled) keeps the screen alive across
-- that round-trip without the downsides above: it only ever parks the
-- Homescreen (never a Custom Screen), and only when it is the *sole* live
-- screen at this exact moment — any other live screen is still force-
-- closed by SimpleUIPlugin:onCloseWidget exactly as today, so at most one
-- screen is ever hidden-but-alive at a time. The event handlers a parked
-- screen could still receive (onResume, onSyncBookStats) are guarded to
-- skip their refresh work while self._parked is set — onSetRotationMode
-- already ignores everything while the reader is open, unrelated to this.
-- _raiseParkedScreen (infra/sui_patches.lua) promotes the parked instance
-- back to the foreground with a scoped partial refresh instead of a full
-- rebuild; any reader-close path that will not show the Homescreen this
-- time (e.g. the Library or Book Folder close targets) closes the parked instance for real
-- instead of leaving it dangling with increasingly stale data.
--
-- _navbar_closing_intentionally makes onCloseWidget (above) treat a real
-- close like a tab-switch rather than a dismissal, so _cached_books_state /
-- _current_page / _cfg_cache are preserved in ScreenEngine's per-id storage
-- and the next cold _showHSCold() still gets a warm seed instead of a cold
-- one — unchanged from before, and still what happens whenever soft-park
-- itself doesn't apply (Custom Screens, more than one live screen, or
-- soft-park disabled).
function ScreenWidget:onShowingReader()
    self.dithered = nil

    if ScreenEngine.isSoftParkEnabled() and self._id == _BUILTIN_ID
            and #ScreenEngine.liveScreenIds() == 1 then
        self._parked = true
        self:_pauseBackgroundWork()
        return
    end

    self._navbar_closing_intentionally = true
    -- The file manager beneath closes for the reader too: nothing is exposed.
    self._sui_closing_for_reader = true
    self:onClose()
end
ScreenWidget.onSetupShowReader = ScreenWidget.onShowingReader

-- ---------------------------------------------------------------------------
-- Module API
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- ScreenEngine._open(instance_cfg, on_qa_tap, on_goal_tap)
--
-- Shared factory behind both ScreenEngine.show() (instance_cfg == nil → the
-- built-in Homescreen, id "hs") and ScreenEngine.showCustomScreen(screen_id).
-- Closes any live widget already tracked for this id, builds a fresh one
-- seeded from that id's cached state (_sget), and shows it.
--
-- Declared as a field on the already-existing ScreenEngine table (rather than
-- a separate local function) so earlier code in this file — e.g. reveal_fn
-- inside _showBookHoldDialog — can already call ScreenEngine._open(...) even
-- though it's textually defined before this point: the call only resolves
-- ScreenEngine._open at the time it actually runs (a user tap, long after
-- module load), by which point this assignment has happened.
-- ---------------------------------------------------------------------------
function ScreenEngine._open(instance_cfg, on_qa_tap, on_goal_tap)
    assert(instance_cfg and instance_cfg.id,
        "ScreenEngine._open: instance_cfg with an id is required — " ..
        "screens/sui_homescreen.lua builds the built-in Homescreen's own; " ..
        "there is no implicit default here anymore")
    local id = instance_cfg.id

    local existing = _sget(id, "_instance")
    if existing then
        UIManager:close(existing)
        _sset(id, "_instance", nil)
    end
    local w = ScreenWidget:new{
        instance             = instance_cfg,
        _on_qa_tap           = on_qa_tap,
        _on_goal_tap         = on_goal_tap,
        _cached_books_state  = _sget(id, "_cached_books_state"),
        _current_page        = _sget(id, "_current_page") or 1,
        _cfg_cache           = _sget(id, "_cfg_cache"),
    }
    _sset(id, "_instance", w)
    UIManager:show(w)

    -- Post-open hook: instance_cfg.on_after_open(widget), when present, runs
    -- right after the screen is shown. This is how screen-specific one-off
    -- behaviour (e.g. the built-in Homescreen's first-run onboarding, wired
    -- up in screens/sui_homescreen.lua) plugs into this otherwise-generic
    -- factory without the factory itself having to know what that behaviour
    -- is — the engine only knows "call the hook if there is one".
    if instance_cfg.on_after_open then
        instance_cfg.on_after_open(w)
    end
    return w
end

-- Opens a Custom Screen by id (infra/sui_custom_screens.lua descriptor).
-- This is what engines/sui_screen_engine's own showCustomScreen()
-- wrapper — and, via it, every "open_custom_screen:<id>" Quick Action —
-- ultimately calls.
function ScreenEngine.showCustomScreen(screen_id)
    local ok, CustomScreens = pcall(require, "infra/sui_custom_screens")
    if not ok or not CustomScreens then
        logger.warn("simpleui: ScreenEngine.showCustomScreen: infra/sui_custom_screens unavailable")
        return
    end
    local screen = CustomScreens.get(screen_id)
    if not screen then
        logger.warn("simpleui: ScreenEngine.showCustomScreen: unknown screen", tostring(screen_id))
        return
    end
    -- on_qa_tap/on_goal_tap: shared, generic implementation (infra/sui_core.lua)
    -- — the exact same callbacks the built-in Homescreen gets via
    -- _showHSCold/_makeQaTap in sui_patches.lua, so any Quick Actions/Action
    -- List module placed on a Custom Screen behaves identically to the same
    -- module placed on the Homescreen.
    return ScreenEngine._open({
        id         = screen.id,
        pfx        = screen.pfx,
        layout_key = screen.layout_key,
        -- title/icon feed the generic TitleBar built in
        -- ScreenWidget:init() (see instance_cfg contract there), so a
        -- Custom Screen's title bar — and what the screen reader announces
        -- on open — matches the screen the user actually opened instead of
        -- always showing/announcing the built-in Homescreen's identity.
        title      = screen.name,
        left_icon  = screen.icon or Config.ICON.custom,
    }, UI.makeQaTap(), UI.makeGoalTap())
end

-- Returns the live widget instance for `id` (any screen — "hs" or a Custom
-- Screen), or nil if that screen isn't currently open. ScreenEngine._instance
-- remains the flat, hs-only field external code already reads directly;
-- this is the id-aware equivalent for callers that don't know in advance
-- which screen they're dealing with (e.g. the settings window, after saving
-- a layout that could belong to any screen).
function ScreenEngine.getInstance(id)
    return _sget(id, "_instance")
end

-- Returns the settings-key prefix for `id`, whether or not that screen is
-- currently live. Prefers the live instance's own self._pfx (the single
-- source of truth while the screen exists); falls back to the same
-- deterministic pattern sui_custom_screens.lua uses to build it
-- ("simpleui_hs_" for the built-in Homescreen, "simpleui_cs_<id>_" for a
-- Custom Screen) so callers can still resolve a pfx for a screen that is
-- currently closed. Used by callers (e.g. main.lua's book-lifecycle
-- handlers) that need to check which modules are enabled on a screen
-- without knowing in advance whether it's open right now.
function ScreenEngine.getPfx(id)
    local inst = _sget(id, "_instance")
    if inst then return inst._pfx end
    if id == _BUILTIN_ID or not id then return "simpleui_hs_" end
    return "simpleui_cs_" .. id .. "_"
end

-- Returns every screen id worth considering for cache invalidation: the
-- built-in Homescreen (always — its flat class-level state lives directly
-- on ScreenEngine regardless of whether it has ever been open) plus every
-- Custom Screen id with any tracked state this session (live right now, or
-- previously closed-but-warm via _navbar_closing_intentionally — see
-- ScreenWidget:onCloseWidget). Deliberately does NOT enumerate every Custom
-- Screen the user has ever created (infra/sui_custom_screens.lua's saved
-- list) — only ones actually touched this session, keeping this cheap
-- enough for a hot path like closing a book.
function ScreenEngine.knownScreenIds()
    local ids = { _BUILTIN_ID }
    for id in pairs(ScreenEngine._cs_state) do
        ids[#ids + 1] = id
    end
    return ids
end

-- Gets/sets the flat, id-level _cached_books_state — the same field a live
-- instance preserves into on an intentional close (see
-- ScreenWidget:onCloseWidget's _navbar_closing_intentionally branch) so the
-- next open is warm-seeded instead of fully cold. Callers that invalidate a
-- closed screen's book cache (e.g. after a book closes elsewhere) use these
-- instead of reaching into ScreenEngine._cs_state directly.
function ScreenEngine.getCachedBooksState(id)
    return _sget(id, "_cached_books_state")
end
function ScreenEngine.setCachedBooksState(id, v)
    _sset(id, "_cached_books_state", v)
end

-- Gets/sets the per-screen _cfg_cache (module-settings snapshot used by
-- ScreenWidget:_buildCtx). The store is written for closed screens; when a
-- live instance exists it must be updated too — _buildCtx reads
-- self._cfg_cache and never re-consults the store. Clearing (v == nil) also
-- drops self._ctx_cache: ctx embeds the cfg table, so a kept-alive ctx would
-- keep serving the pre-change main_order / visibility flags after
-- refreshScreen(..., false) promotes to its keep_cache path whenever
-- _body and _ctx_cache are both still set.
function ScreenEngine.setCfgCache(id, v)
    _sset(id, "_cfg_cache", v)
    local inst = _sget(id, "_instance")
    if not inst then return end
    inst._cfg_cache = v
    if v == nil then
        inst._ctx_cache = nil
    end
end

-- Drop cfg (and optionally books state) on every known screen, then rebuild
-- live ones. Call after module settings that the cfg snapshot captures
-- (order, visibility, scales, …). Pass clear_books=true when book metadata
-- must be re-fetched too (e.g. "Update Stats Now").
function ScreenEngine.invalidateAllCfgAndRefresh(clear_books)
    for _, id in ipairs(ScreenEngine.knownScreenIds()) do
        if clear_books then
            ScreenEngine.setCachedBooksState(id, nil)
        end
        ScreenEngine.setCfgCache(id, nil)
        ScreenEngine.refreshScreen(id, false)
    end
end

-- Flags screen `id` for a refresh next time it becomes visible — covers
-- both a currently-live-but-hidden instance and a fully closed one, since
-- ScreenWidget:onShow() checks both self._stats_need_refresh and this flat
-- field (see _sget/_sset dispatch above) before deciding whether to redraw.
function ScreenEngine.setNeedsRefresh(id)
    _sset(id, "_stats_need_refresh", true)
end
function ScreenEngine.needsRefresh(id)
    local inst = _sget(id, "_instance")
    return (inst and inst._stats_need_refresh) or _sget(id, "_stats_need_refresh") or false
end

-- Flags every known screen for a full data rebuild the next time it becomes
-- visible: drops the cached books state (and, on a live instance, the cached
-- ctx) so book progress, statuses and stats are all re-fetched. Call after a
-- change to a book that any screen may display.
function ScreenEngine.markAllStale()
    for _, id in ipairs(ScreenEngine.knownScreenIds()) do
        ScreenEngine.setNeedsRefresh(id)
        local inst = _sget(id, "_instance")
        if inst then
            inst._ctx_cache          = nil
            inst._cached_books_state = nil
        else
            ScreenEngine.setCachedBooksState(id, nil)
        end
    end
end

-- Refreshes whichever screen `id` is currently open, if any. No-op if that
-- screen isn't live — callers don't need to check first.
function ScreenEngine.refreshScreen(id, keep_cache, books_only, stats_only)
    local w = _sget(id, "_instance")
    if w then w:_refresh(keep_cache, books_only, stats_only) end
end

function ScreenEngine.refresh(keep_cache, books_only, stats_only)
    if ScreenEngine._instance then
        ScreenEngine._instance:_refresh(keep_cache, books_only, stats_only)
    end
end

-- Immediately repaints whichever screen(s) are actually live right now —
-- the built-in Homescreen if open, or a Custom Screen if that's what's open
-- instead. This is for callers
-- reacting to state that isn't screen-specific (wifi icon, quick-action
-- icons, style changes, ...) and so must reach whatever screen is currently
-- on screen, not assume it's the Homescreen. No-op if nothing is live.
function ScreenEngine.refreshAllLiveImmediate(keep_cache)
    for _, id in ipairs(ScreenEngine.liveScreenIds()) do
        local w = _sget(id, "_instance")
        if w then w:_refreshImmediate(keep_cache) end
    end
end

-- Closes whichever screen `id` is currently open, if any — no-op if that
-- screen isn't live, callers don't need to check first. See
-- screens/sui_homescreen.lua for the ScreenEngine.close() wrapper that calls
-- this with id = "hs".
function ScreenEngine.closeScreen(id)
    local inst = _sget(id, "_instance")
    if inst then
        UIManager:close(inst)
        _sset(id, "_instance", nil)
    end
    _sset(id, "_cached_books_state", nil)
    _sset(id, "_cfg_cache", nil)
end

ScreenEngine.PAGE_BREAK_ID = PAGE_BREAK_ID

-- ---------------------------------------------------------------------------
-- Look & Feel public API (consumed by sui_menu.lua)
-- ---------------------------------------------------------------------------

-- Rebuild whichever screen `id` currently has an open instance, from scratch
-- (calls _initLayout) so that background transparency and wallpaper take
-- effect immediately. No-op if that screen isn't live.
local function _rebuildScreenLayout(id)
    local inst = _sget(id, "_instance")
    if not inst or not inst._navbar_container then return end

    inst._cached_books_state = nil
    inst._enabled_mods_cache = nil
    inst._ctx_cache          = nil
    inst._cfg_cache          = nil
    _sset(id, "_cfg_cache", nil)

    local overlap = inst:_initLayout()
    inst:_swapLayoutTree(overlap)
    inst:_updatePage(true)
    UIManager:setDirty(inst, "ui")
end

--- Full layout rebuild for screen `id` — frees the wallpaper cache and
--- rebuilds the layout (dimensions, bar overlaps, positioning) before
--- invalidating the screen. For callers that want a single specific screen;
--- see ScreenEngine.rebuildAllLayouts() below for the "every live screen"
--- variant that screens/sui_homescreen.lua's ScreenEngine.rebuildLayout()
--- wrapper calls.
function ScreenEngine.rebuildLayoutFor(id)
    SUIWallpaper.freeCache()
    _rebuildScreenLayout(id)
end

-- Returns every screen id that currently has a live widget instance: the
-- built-in Homescreen (if open) plus every Custom Screen id present in
-- ScreenEngine._cs_state with a non-nil _instance.
--
-- A Custom Screen can be live-but-hidden: SUIWindow-based overlays (the
-- Settings Window, the Menu, wallpaper/style pickers, ...) are shown via
-- plain UIManager:show() on top of whatever screen is currently open,
-- without closing it. So a Custom Screen the user navigated away from —
-- without explicitly closing it — keeps a non-nil _instance for as long as
-- whatever was opened on top of it stays open, and must be reached by a
-- global rebuild too.
local function _liveScreenIds()
    local ids = {}
    if ScreenEngine._instance then
        ids[#ids + 1] = _BUILTIN_ID
    end
    for id, st in pairs(ScreenEngine._cs_state) do
        if st._instance then
            ids[#ids + 1] = id
        end
    end
    return ids
end

ScreenEngine.liveScreenIds = _liveScreenIds

--- Re-fetches stats for every live screen without touching book data.
function ScreenEngine.refreshAllLiveStats()
    for _, id in ipairs(_liveScreenIds()) do
        ScreenEngine.refreshScreen(id, false, false, true)
    end
end

--- Full layout rebuild for every screen that currently has a live widget
--- instance (the built-in Homescreen plus any Custom Screen left open in
--- the background — see _liveScreenIds() above). Frees the wallpaper cache
--- once — it's a shared cache, freeing it per screen would be pointless —
--- then rebuilds each live screen in turn. `opts.keep_wallpaper` skips the
--- free for changes that leave the wallpaper image untouched.
---
--- Called by screens/sui_homescreen.lua's ScreenEngine.rebuildLayout(), so
--- every existing caller (sui_wallpaper, sui_style, sui_onboarding,
--- sui_menu, sui_settings_window) reaches every live screen without
--- needing to know about screen ids.
function ScreenEngine.rebuildAllLayouts(opts)
    if not (opts and opts.keep_wallpaper) then
        SUIWallpaper.freeCache()
    end
    for _, id in ipairs(_liveScreenIds()) do
        _rebuildScreenLayout(id)
    end
end

return ScreenEngine

