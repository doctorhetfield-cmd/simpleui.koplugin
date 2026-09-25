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

local Blitbuffer       = require("ffi/blitbuffer")
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
local N_               = require("infra/sui_i18n").ngettext
local T                = require("ffi/util").template
local Config           = require("infra/sui_config")
local Registry         = require("modules/moduleregistry")
local SUISettings = require("infra/sui_store")
local Event            = require("ui/event")
local Screen           = Device.screen
local UI               = require("infra/sui_core")
local Bottombar        = require("screens/sui_bottombar")
local SUIStyle         = require("features/sui_style")
local ImageWidget      = require("ui/widget/imagewidget")
local lfs              = require("libs/libkoreader-lfs")
local SUIWallpaper     = require("features/sui_wallpaper")

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

-- Reusable candidate buffer for _fmGestureAction.
-- Avoids allocating a new table on every gesture event.
-- Entries 1..n are valid after a call; the rest are nil-cleared before returning.
local _candidates = {}


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
local PAD                = UI.PAD
local MOD_GAP            = UI.MOD_GAP
local SIDE_PAD           = UI.SIDE_PAD

-- Static color defaults.

local function _getTextMid()
    return SUIStyle.COLOR.text_dim
end

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
}

function DotWidget:getSize()
    return Geom:new{ w = self.total_pages * self.touch_w, h = self.bar_h }
end

function DotWidget:paintTo(bb, x, y)
    local dot_r = math.floor(self.dot_size / 2)
    local cy    = y + math.floor(self.bar_h / 2)
    local tw    = self.touch_w
    for i = 1, self.total_pages do
        local cx = x + (i - 1) * tw + math.floor(tw / 2)
        if i == self.current_page then
            bb:paintCircle(cx, cy, dot_r, SUIStyle.COLOR.text_primary)
        else
            bb:paintCircle(cx, cy, dot_r, _getDotInactive())
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
-- Internal-only kill switch — NOT a persisted SUISettings value and NOT
-- exposed in any menu. When true, ScreenWidget:onShowingReader keeps the
-- Homescreen's widget tree, bitmaps and cached state alive, hidden
-- underneath the reader, instead of tearing it all down and rebuilding
-- cold on every reader round-trip (see ScreenWidget:onShowingReader
-- below and _raiseParkedScreen in infra/sui_patches.lua). Default is
-- false (cold close); flip to true to enable soft-park.
ScreenEngine.SOFT_PARK_ENABLED = false

-- When true (default) and SOFT_PARK_ENABLED is also true, a soft-parked
-- Homescreen is left alive under the system ScreenSaver instead of being
-- closed by the UIManager.show fullscreen-widget guard. On wakeup the
-- parked instance is still under the Reader and the normal raise path
-- works on book close. Flip to false to restore the pre-existing behaviour
-- (HS closed on every suspend, cold rebuild on the next book close).
-- Code-only; not exposed in any menu.
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
local _EMPTY_TITLE_H  = Screen:scaleBySize(30)
local _EMPTY_GAP        = Screen:scaleBySize(12)
local _face_empty_title = Font:getFace(SUIStyle.FACE_REGULAR,    SUIStyle.FS_TITLE)     -- FS_TITLE (22)
local _face_empty_sub   = Font:getFace(SUIStyle.FACE_REGULAR,  SUIStyle.FS_SUBTITLE)  -- FS_SUBTITLE (20)

-- Section label widget cache — keyed by "text|inner_w|scale_pct", plus
-- "mod_id|page|npages" for a paginated row's header (see sectionLabel's
-- page_nav parameter below). That extra key segment tracks pagination
-- STATE, not the identity of the ScreenWidget whose chevrons a cached
-- widget's tap handler closes over — so anything that can change a
-- paginated row's page/npages without necessarily replacing this module's
-- own local widget cache must also invalidate this one, or a stale cached
-- header can end up wired to a dead closure (chevrons that silently do
-- nothing on tap).
--
-- Invalidated via invalidateLabelCache() from:
--   • main.lua's onCloseDocument — reader-return path, every document close.
--   • infra/sui_core.lua's invalidateDimCache — screen resize/rotation.
--   • engines/sui_book_grid.lua's GridRenderer.clearRowCaches — every place
--     a row module's file-list cache is cleared (status changes, TBR/
--     collection add-remove, the debounced background refresh, ...), since
--     that is precisely when a paginated row's page/npages can shift.
--     Centralised there instead of at each clearRowCaches() call site so
--     future callers get this for free.
local _label_cache = {}

local function invalidateLabelCache()
    _label_cache = {}
end

-- page_nav (optional): { mod_id, page, npages, turnPageFn } — see
-- pageNavFor below. When present, a pair of chevrons is drawn flanking
-- right_text, tappable to move to the previous/next page. mod_id is folded
-- into the cache key below: unlike plain display text, a chevron's tap
-- closure is bound to one specific module, so two modules that happen to
-- render the same text/width/page can no longer share the cached widget —
-- doing so would wire the wrong module's pagination to the tap.
-- landscape_factor (optional): scale multiplier for the label; defaults to 1.
local function sectionLabel(text, w, right_text, page_nav, landscape_factor)
    local scale = Config.getLabelScale() * (landscape_factor or 1)
    local fs = math.max(8, math.floor(SUIStyle.FS_BODY * scale))

    local key = text .. "|" .. w .. "|" .. tostring(scale) .. "|" .. tostring(right_text)
    if page_nav then
        -- has_wallpaper is folded in too: it changes how the chevrons are
        -- built (see GridRenderer.buildPageNavButtons), so toggling the
        -- wallpaper must not reuse a cached widget built for the other state.
        key = key .. "|" .. page_nav.mod_id .. "|" .. tostring(page_nav.page) .. "|" .. tostring(page_nav.npages)
            .. "|" .. tostring(page_nav.has_wallpaper)
    end
    if not _label_cache[key] then
        local face = Font:getFace(SUIStyle.FACE_REGULAR, fs)
        local avail_w  = w - PAD * 2
        local content

        if right_text then
            -- Page indicator ("1/2"): same line as the title, pushed
            -- to the right of the line — distinguished from the title (bold, larger) without
            -- needing extra vertical space.
            --
            -- One level below on the named size scale (FS_BODY ->
            -- FS_DETAIL), not the same `fs` as the title.
            local fs_right = math.max(8, math.floor(SUIStyle.FS_DETAIL * scale))
            local face_right = Font:getFace(SUIStyle.FACE_REGULAR, fs_right)
            local right_widget = UI.makeColoredText{
                text    = right_text,
                face    = face_right,
                bold    = false,
            }
            local gap = PAD
            local title_widget = UI.makeColoredText{
                text    = text,
                face    = face,
                bold    = true,
            }
            -- Shared row height so title, "1/2", and chevrons centre on one line.
            local title_h = title_widget:getSize().h
            local right_h = right_widget:getSize().h
            local row_h   = math.max(title_h, right_h)

            -- Chevrons, one on each side of right_widget. Built lazily
            -- (same require-on-first-use pattern as elsewhere in this file)
            -- to avoid a hard dependency from this generic label helper on
            -- the book-grid engine when no module actually needs paging.
            local prev_button, next_button
            local nav_w = 0
            if page_nav then
                local ok_gr, GridRenderer = pcall(require, "engines/sui_book_grid")
                if ok_gr and GridRenderer then
                    prev_button, next_button = GridRenderer.buildPageNavButtons(
                        page_nav.page, page_nav.npages, row_h, page_nav.turnPageFn, page_nav.has_wallpaper)
                    if prev_button then
                        nav_w = prev_button:getSize().w + next_button:getSize().w + gap * 2
                    end
                end
            end

            local right_w  = right_widget:getSize().w + nav_w
            local title_w  = math.max(1, avail_w - right_w - gap)
            -- LeftContainer gives the title a real title_w-wide slot so the
            -- page indicator stays at the row's right edge (TextWidget's
            -- getSize() only reports glyph width, never pads to max_width).
            local title_slot = LeftContainer:new{
                dimen = Geom:new{ w = title_w, h = row_h },
                title_widget,
            }
            local right_slot = CenterContainer:new{
                dimen = Geom:new{ w = right_widget:getSize().w, h = row_h },
                right_widget,
            }
            content = HorizontalGroup:new{ align = "center" }
            table.insert(content, title_slot)
            table.insert(content, HorizontalSpan:new{ width = gap })
            if prev_button then
                table.insert(content, prev_button)
                table.insert(content, HorizontalSpan:new{ width = gap })
            end
            table.insert(content, right_slot)
            if next_button then
                table.insert(content, HorizontalSpan:new{ width = gap })
                table.insert(content, next_button)
            end
        else
            content = UI.makeColoredText{
                    text    = text,
                face    = face,
                bold    = true,
                width   = avail_w,
            }
        end

        _label_cache[key] = FrameContainer:new{
            bordersize = 0, padding = 0,
            padding_left = PAD, padding_right = PAD,
            padding_bottom = UI.LABEL_PAD_BOT,
            content,
        }
    end
    return _label_cache[key]
end

-- Page indicator ("1/2") for paginated "cover row" modules
-- (sui_book_grid.lua): reads the pagination state that GridRenderer.build stores
-- in ctx (per module, scoped to the session) and returns nil when there's no
-- active pagination (a single page) or the module isn't of that type.
local function pageIndicatorFor(mod, ctx)
    if not ctx then return nil end
    local npages = ctx["_row_npages_" .. mod.id]
    if not npages or npages <= 1 then return nil end
    local page = ctx["_row_page_" .. mod.id] or 1
    return string.format("%d/%d", page, npages)
end

-- Right-side section-label text for a module: a module-supplied
-- M.label_right_func(ctx) (e.g. the active heatmap type) takes priority
-- over the page indicator, falling back to pageIndicatorFor when the
-- module doesn't define one. The two are mutually exclusive in practice —
-- no module currently uses both — so no attempt is made to combine them.
local function labelRightTextFor(mod, ctx)
    if type(mod.label_right_func) == "function" then
        return mod.label_right_func(ctx)
    end
    return pageIndicatorFor(mod, ctx)
end

-- Chevron pair descriptor for the same paginated module, passed to
-- sectionLabel as page_nav. Mirrors pageIndicatorFor's nil case exactly (a
-- single page or a non-paginated module gets neither the text nor the
-- chevrons) — `self` is threaded through explicitly since this is a plain
-- local function, not a ScreenWidget method, called from inside one.
local function pageNavFor(self, mod, ctx)
    if not ctx then return nil end
    local npages = ctx["_row_npages_" .. mod.id]
    if not npages or npages <= 1 then return nil end
    local page = ctx["_row_page_" .. mod.id] or 1
    return {
        mod_id        = mod.id,
        page          = page,
        npages        = npages,
        turnPageFn    = function(delta) self:_turnBookModPage(mod.id, delta) end,
        has_wallpaper = ctx.has_wallpaper,
    }
end

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
                    fgcolor = _getTextMid(),
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
    local btn_text = Button:new{
        text = " ", text_font_bold = false, text_font_size = font_size,
        bordersize = 0, enabled = false,
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
    local chev_input = InputContainer:new{
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

    local dot_widget = DotWidget:new{
        current_page = 1, total_pages = 1,
        dot_size = DOT_SIZE, bar_h = BAR_H, touch_w = TOUCH_W,
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
    local has_prev = current_page > 1
    local has_next = current_page < total_pages
    if not Bottombar.updateNavpagerArrows(tgt, has_prev, has_next) then
        local tabs    = Config.loadTabConfig()
        local mode    = Config.getNavbarMode()
        local new_bar = Bottombar.buildBarWidgetWithArrows(
            _bottombarActionIdFor(tgt), tabs, mode, has_prev, has_next)
        Bottombar.replaceBar(tgt, new_bar, tabs)
    end
    UIManager:setDirty(tgt, "ui")
end

-- Normalises a filepath for use with the kobo.koplugin's patched
-- DocumentRegistry.openDocument, which handles DRM decryption and provider
-- selection only for KOBO_VIRTUAL:// paths.
--
-- Two cases are handled:
--   • KOBO_VIRTUAL:// paths  — returned unchanged so DocumentRegistry's patch
--     can perform decryption and route to the correct provider.
--   • Real kepub paths (e.g. /mnt/onboard/.kobo/kepub/<id>) that were saved
--     into ReadHistory by KOReader after the kobo.koplugin resolved a virtual
--     path — converted back to KOBO_VIRTUAL:// so the same patch fires.
--
-- Any other path is returned unchanged.
-- Falls back gracefully (returns filepath as-is) when kobo.koplugin is absent.
local function _normalizeKoboPath(filepath)
    if not filepath then return filepath end
    local ok, PluginLoader = pcall(require, "pluginloader")
    if not ok or not PluginLoader then return filepath end
    local kobo = PluginLoader:getPluginInstance("kobo_plugin")
    if not kobo or not kobo.virtual_library then return filepath end
    local vl = kobo.virtual_library
    -- Ensure path mappings are populated (lazy-built on first access).
    if not next(vl.virtual_to_real) then
        local ok2, err = pcall(function() vl:buildPathMappings() end)
        if not ok2 then
            logger.warn("sui_homescreen: kobo buildPathMappings failed:", err)
            return filepath
        end
    end
    -- Already a virtual path — DocumentRegistry's patch will handle it.
    if vl:isVirtualPath(filepath) then return filepath end
    -- Real path from ReadHistory → convert back to virtual so decryption fires.
    local virtual = vl:getVirtualPath(filepath)
    return virtual or filepath
end

local function openBook(filepath, pos0, page)
    -- ReaderUI:showReader() broadcasts ShowingReader before its first paint,
    -- closing FM/current screen atomically — no need to close it first here.
    local doOpen = function()
        local ReaderUI = package.loaded["apps/reader/readerui"]
            or require("apps/reader/readerui")
        ReaderUI:showReader(_normalizeKoboPath(filepath))
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
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = _("Open this file?") .. "\n\n" .. BD.filename(filepath:match("([^/]+)$")),
            ok_text = _("Open"),
            ok_callback = doOpen,
        })
    else
        doOpen()
    end
end

-- ---------------------------------------------------------------------------
-- _deferredFreeOldTree(old_tree) — releases a discarded widget subtree
-- (module covers, badges, wallpaper widgets, etc.) without risking a
-- use-after-free, and nudges LuaJIT's GC to actually reclaim the underlying
-- blitbuffers in reasonable time.
--
-- Why deferred: calling :free() synchronously, right when the new tree is
-- being swapped in, can tear down an ImageWidget's bb while a paint that
-- was already scheduled against the OLD tree is still in flight, producing
-- a native segfault. UIManager:nextTick lets the current event handler
-- (and any paint it triggered) finish before we reap the old tree.
--
-- Why collectgarbage at all: LuaJIT's incremental GC step size is tuned for
-- steady-state allocation, not the burst of many blitbuffers created and
-- dropped on every screen rebuild (rotation, settings change, page swipe
-- across pages with different module sets). Left alone, freed-but-not-yet-
-- collected bbs accumulate and RSS climbs with every rebuild even though
-- nothing is actually leaked. A cheap incremental "step" after every
-- rebuild, plus an occasional full "collect", keeps actual RSS close to
-- live-object size without a visible pause.
local _screen_rebuild_count = 0
local function _deferredFreeOldTree(old_tree)
    if not (old_tree and old_tree.free) then return end
    UIManager:nextTick(function()
        local ok, err = pcall(function() old_tree:free() end)
        if not ok then
            logger.warn("simpleui[screen_engine]: old tree free failed:", err)
        end
        collectgarbage("step", 200)
        _screen_rebuild_count = _screen_rebuild_count + 1
        if _screen_rebuild_count >= 4 then
            _screen_rebuild_count = 0
            collectgarbage("collect")
        end
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
    local stack = UIManager._window_stack
    if not stack or #stack == 0 then return false end
    local top = stack[#stack]
    return top and top.widget ~= screen_widget
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

    -- Computed at hit-test time so a soft-parked instance raised after an
    -- orientation change still blocks the bar correctly (init-time bar_y
    -- would stay frozen at the pre-reader height).
    local function _in_bar(ges)
        if not (ges and ges.pos) then return false end
        return ges.pos.y >= Screen:getHeight() - Bottombar.TOTAL_H()
    end

    self.ges_events = {
        BlockNavbarTap = {
            GestureRange:new{ ges = "tap",            range = function() return self.dimen end },
        },
        BlockNavbarHold = {
            GestureRange:new{ ges = "hold",           range = function() return self.dimen end },
        },
        ScreenSwipe = {
            GestureRange:new{ ges = "swipe",          range = function() return self.dimen end },
        },
        ScreenDoubleTap = {
            GestureRange:new{ ges = "double_tap",     range = function() return self.dimen end },
        },
        ScreenTwoFingerTap = {
            GestureRange:new{ ges = "two_finger_tap", range = function() return self.dimen end },
        },
        ScreenTwoFingerSwipe = {
            GestureRange:new{ ges = "two_finger_swipe", range = function() return self.dimen end },
        },
        ScreenMultiswipe = {
            GestureRange:new{ ges = "multiswipe",     range = function() return self.dimen end },
        },
        ScreenHold = {
            GestureRange:new{ ges = "hold",           range = function() return self.dimen end },
        },
        ScreenSpread = {
            GestureRange:new{ ges = "spread",         range = function() return self.dimen end },
        },
        ScreenPinch = {
            GestureRange:new{ ges = "pinch",          range = function() return self.dimen end },
        },
        ScreenRotate = {
            GestureRange:new{ ges = "rotate",         range = function() return self.dimen end },
        },
    }

    -- Zone data from G_defaults is immutable during a session — read once here
    -- and reused on every gesture event to avoid per-call table allocations.
    local function _readZone(key)
        local d = G_defaults:readSetting(key)
        if not d then return nil end
        return { ratio_x = d.x, ratio_y = d.y, ratio_w = d.w, ratio_h = d.h }
    end
    local _gz_top_left   = _readZone("DTAP_ZONE_TOP_LEFT")
    local _gz_top_right  = _readZone("DTAP_ZONE_TOP_RIGHT")
    local _gz_bot_left   = _readZone("DTAP_ZONE_BOTTOM_LEFT")
    local _gz_bot_right  = _readZone("DTAP_ZONE_BOTTOM_RIGHT")
    local _gz_left_edge  = _readZone("DSWIPE_ZONE_LEFT_EDGE")
    local _gz_right_edge = _readZone("DSWIPE_ZONE_RIGHT_EDGE")
    local _gz_top_edge   = _readZone("DSWIPE_ZONE_TOP_EDGE")
    local _gz_bot_edge   = _readZone("DSWIPE_ZONE_BOTTOM_EDGE")
    local _gz_left_side  = _readZone("DDOUBLE_TAP_ZONE_PREV_CHAPTER")
    local _gz_right_side = _readZone("DDOUBLE_TAP_ZONE_NEXT_CHAPTER")

    -- Dispatches a gesture event to the FM gestures plugin (same gesture set
    -- as docless file-manager mode). sendEvent is temporarily redirected to
    -- broadcastEvent so UIManager events reach all listeners.
    local function _fmGestureAction(ges_event)
        local FileManager = require("apps/filemanager/filemanager")
        local g = FileManager.instance and FileManager.instance.gestures
        if not g then return end

        local sw = Screen:getWidth()
        local sh = Screen:getHeight()
        local pos = ges_event.pos
        if not pos then return end
        local x, y = pos.x, pos.y
        local gt  = ges_event.ges
        local dir = ges_event.direction

        -- Use the module-level reusable buffer; reset it for this call.
        local n = 0

        if gt == "swipe" then
            local is_diag = dir == "northeast" or dir == "northwest"
                         or dir == "southeast" or dir == "southwest"
            if is_diag then
                local short_thresh = Screen:scaleBySize(300)
                if ges_event.distance and ges_event.distance <= short_thresh then
                    n = n + 1; _candidates[n] = "short_diagonal_swipe"
                end
            elseif _inZone(_gz_left_edge, x, y, sw, sh) then
                if     dir == "south" then n = n + 1; _candidates[n] = "one_finger_swipe_left_edge_down"
                elseif dir == "north" then n = n + 1; _candidates[n] = "one_finger_swipe_left_edge_up"
                end
            elseif _inZone(_gz_right_edge, x, y, sw, sh) then
                if     dir == "south" then n = n + 1; _candidates[n] = "one_finger_swipe_right_edge_down"
                elseif dir == "north" then n = n + 1; _candidates[n] = "one_finger_swipe_right_edge_up"
                end
            elseif _inZone(_gz_top_edge, x, y, sw, sh) then
                if     dir == "east" then n = n + 1; _candidates[n] = "one_finger_swipe_top_edge_right"
                elseif dir == "west" then n = n + 1; _candidates[n] = "one_finger_swipe_top_edge_left"
                end
            elseif _inZone(_gz_bot_edge, x, y, sw, sh) then
                if     dir == "east" then n = n + 1; _candidates[n] = "one_finger_swipe_bottom_edge_right"
                elseif dir == "west" then n = n + 1; _candidates[n] = "one_finger_swipe_bottom_edge_left"
                end
            end

        elseif gt == "tap" then
            if     _inZone(_gz_top_left,  x, y, sw, sh) then n = n + 1; _candidates[n] = "tap_top_left_corner"
            elseif _inZone(_gz_top_right, x, y, sw, sh) then n = n + 1; _candidates[n] = "tap_top_right_corner"
            elseif _inZone(_gz_bot_left,  x, y, sw, sh) then n = n + 1; _candidates[n] = "tap_left_bottom_corner"
            elseif _inZone(_gz_bot_right, x, y, sw, sh) then n = n + 1; _candidates[n] = "tap_right_bottom_corner"
            end

        elseif gt == "hold" then
            if     _inZone(_gz_top_left,  x, y, sw, sh) then n = n + 1; _candidates[n] = "hold_top_left_corner"
            elseif _inZone(_gz_top_right, x, y, sw, sh) then n = n + 1; _candidates[n] = "hold_top_right_corner"
            elseif _inZone(_gz_bot_left,  x, y, sw, sh) then n = n + 1; _candidates[n] = "hold_bottom_left_corner"
            elseif _inZone(_gz_bot_right, x, y, sw, sh) then n = n + 1; _candidates[n] = "hold_bottom_right_corner"
            end

        elseif gt == "double_tap" then
            if     _inZone(_gz_left_side,  x, y, sw, sh) then n = n + 1; _candidates[n] = "double_tap_left_side"
            elseif _inZone(_gz_right_side, x, y, sw, sh) then n = n + 1; _candidates[n] = "double_tap_right_side"
            elseif _inZone(_gz_top_left,   x, y, sw, sh) then n = n + 1; _candidates[n] = "double_tap_top_left_corner"
            elseif _inZone(_gz_top_right,  x, y, sw, sh) then n = n + 1; _candidates[n] = "double_tap_top_right_corner"
            elseif _inZone(_gz_bot_left,   x, y, sw, sh) then n = n + 1; _candidates[n] = "double_tap_bottom_left_corner"
            elseif _inZone(_gz_bot_right,  x, y, sw, sh) then n = n + 1; _candidates[n] = "double_tap_bottom_right_corner"
            end

        elseif gt == "two_finger_tap" then
            if     _inZone(_gz_top_left,  x, y, sw, sh) then n = n + 1; _candidates[n] = "two_finger_tap_top_left_corner"
            elseif _inZone(_gz_top_right, x, y, sw, sh) then n = n + 1; _candidates[n] = "two_finger_tap_top_right_corner"
            elseif _inZone(_gz_bot_left,  x, y, sw, sh) then n = n + 1; _candidates[n] = "two_finger_tap_bottom_left_corner"
            elseif _inZone(_gz_bot_right, x, y, sw, sh) then n = n + 1; _candidates[n] = "two_finger_tap_bottom_right_corner"
            end

        elseif gt == "two_finger_swipe" then
            local map = {
                east = "two_finger_swipe_east",   west  = "two_finger_swipe_west",
                north = "two_finger_swipe_north",  south = "two_finger_swipe_south",
                northeast = "two_finger_swipe_northeast", northwest = "two_finger_swipe_northwest",
                southeast = "two_finger_swipe_southeast", southwest = "two_finger_swipe_southwest",
            }
            if map[dir] then n = n + 1; _candidates[n] = map[dir] end

        elseif gt == "multiswipe" then
            local orig_sendEvent = UIManager.sendEvent
            UIManager.sendEvent = function(um, ev) return UIManager:broadcastEvent(ev) end
            local ok, err = pcall(g.multiswipeAction, g, ges_event.multiswipe_directions, ges_event)
            UIManager.sendEvent = orig_sendEvent
            if not ok then logger.warn("simpleui screen gesture multiswipe:", err) end
            return true

        elseif gt == "spread" then
            n = n + 1; _candidates[n] = "spread_gesture"
        elseif gt == "pinch" then
            n = n + 1; _candidates[n] = "pinch_gesture"
        elseif gt == "rotate" then
            if     dir == "cw"  then n = n + 1; _candidates[n] = "rotate_cw"
            elseif dir == "ccw" then n = n + 1; _candidates[n] = "rotate_ccw"
            end
        end

        if n == 0 then return end

        local gestures_fm = g.gestures
        local ges_name
        for i = 1, n do
            local name = _candidates[i]
            if gestures_fm and gestures_fm[name] ~= nil then
                ges_name = name
                break
            end
        end
        -- Fall back to the first candidate; gestureAction() is a no-op when
        -- no action is configured, preserving future default-action support.
        if not ges_name then
            ges_name = _candidates[1]
        end

        -- Clear the reusable buffer so stale entries never leak into the next call.
        for i = 1, n do _candidates[i] = nil end

        if ges_name then
            local orig_sendEvent = UIManager.sendEvent
            UIManager.sendEvent = function(um, ev) return UIManager:broadcastEvent(ev) end
            local ok, err = pcall(g.gestureAction, g, ges_name, ges_event)
            UIManager.sendEvent = orig_sendEvent
            if not ok then
                logger.warn("simpleui screen gesture:", ges_name, err)
            end
            if gestures_fm and gestures_fm[ges_name] ~= nil then
                return true
            end
        end
    end

    -- Returns true when the gesture originates from a side-edge zone.
    local function _isSideEdge(ges)
        if not ges or not ges.pos then return false end
        local x  = ges.pos.x
        local sw = Screen:getWidth()
        local function _in(z)
            if not z then return false end
            return x >= z.ratio_x * sw and x < (z.ratio_x + z.ratio_w) * sw
        end
        return _in(_gz_left_edge) or _in(_gz_right_edge)
    end

    -- Depth-first search for the first descendant (or self) exposing its own
    -- onSwipe(self, ges) handler. Used to locate the tappable/paged widget
    -- nested inside a book_mod's built widget tree (coverdeck's carousel,
    -- Featured Collection's paginated swipe_area, ...) without needing to know
    -- that module's internal widget structure ahead of time.
    local function _findSwipeWidget(w, maxdepth)
        if not w or maxdepth <= 0 or type(w) ~= "table" then return nil end
        if type(w.onSwipe) == "function" then return w end
        for i = 1, #w do
            local found = _findSwipeWidget(w[i], maxdepth - 1)
            if found then return found end
        end
        return nil
    end

    function self:onScreenSwipe(_args, ges)
        if ges then
            local dir = ges.direction
            if (dir == "west" or dir == "east") and not _isSideEdge(ges) then
                -- Delegate horizontal swipes that land inside a currently
                -- visible is_book_mod widget's area (coverdeck's carousel,
                -- a paginated Featured Collection, ...) to that widget's own
                -- onSwipe, instead of turning the homescreen page. Generic
                -- over mod.id via _book_mod_slots — not hardcoded to any
                -- single module.
                if ges.pos and self._book_mod_slots then
                    local on_current_page
                    do
                        local pom = self._enabled_mods_cache and self._enabled_mods_cache.pages_of_mods
                        local cur = self._current_page or 1
                        local is_ls = _isLandscape()
                        local pages_to_check = { pom and pom[cur] }
                        if is_ls and pom and pom[cur + 1] then
                            pages_to_check[2] = pom[cur + 1]
                        end
                        on_current_page = {}
                        for _, cur_mods in ipairs(pages_to_check) do
                            if cur_mods then
                                for _, m in ipairs(cur_mods) do on_current_page[m.id] = true end
                            end
                        end
                    end
                    for mod_id, slot in pairs(self._book_mod_slots) do
                        if on_current_page[mod_id] then
                            -- Hit-test against the layout wrapper when present: the raw
                            -- build() result sits inside wrapBox (FrameContainer /
                            -- HorizontalGroup for the module frame & background) and
                            -- may not carry absolute screen dimen. The pooled wrapper
                            -- always does — it is what the body lays out and paints.
                            local hit_dimen
                            if slot.has_menu and self._wrapper_pool then
                                local wrap = self._wrapper_pool[mod_id]
                                hit_dimen = wrap and wrap.dimen
                            end
                            if not hit_dimen then
                                hit_dimen = slot.widget and slot.widget.dimen
                            end
                            if hit_dimen and ges.pos:intersectWith(hit_dimen) then
                                local sw = _findSwipeWidget(slot.widget, 8)
                                if sw and sw:onSwipe(nil, ges) then
                                    return true
                                end
                                break  -- touch point belongs to this widget; don't test siblings
                            end
                        end
                    end
                end

                local cur   = self._current_page or 1
                local total = self._total_pages  or 1
                local new_page = _resolveSwipeNav(cur, total, dir)
                if new_page ~= cur or total == 1 then
                    self._current_page = new_page
                    self.page          = new_page
                    self:_refresh(true)
                end
                return true
            end
        end
        return _fmGestureAction(ges)
    end
    function self:onScreenTwoFingerSwipe(_args, ges) return _fmGestureAction(ges) end
    function self:onScreenDoubleTap(_args, ges)    return _fmGestureAction(ges) end
    function self:onScreenTwoFingerTap(_args, ges) return _fmGestureAction(ges) end
    function self:onScreenMultiswipe(_args, ges)   return _fmGestureAction(ges) end
    function self:onScreenSpread(_args, ges)       return _fmGestureAction(ges) end
    function self:onScreenPinch(_args, ges)        return _fmGestureAction(ges) end
    function self:onScreenRotate(_args, ges)       return _fmGestureAction(ges) end

    -- Physical D-pad navigation (Kindle and similar devices).
    self.key_events = {}
    if Device:hasDPad() then
        self.key_events.ScreenFocusUp    = { { "Up"    } }
        self.key_events.ScreenFocusDown  = { { "Down"  } }
        self.key_events.ScreenFocusLeft  = { { "Left"  } }
        self.key_events.ScreenFocusRight = { { "Right" } }
        self.key_events.ScreenKbPress    = { { "Press" } }
    end
    if Device:hasKeys() then
        self.key_events.ScreenOpenMenu = { { "Menu"  } }
        self.key_events.PrevPage   = { { Device.input.group.PgBack } }
        self.key_events.NextPage   = { { Device.input.group.PgFwd } }
    end

    function self:onScreenOpenMenu()
        local FileManager = require("apps/filemanager/filemanager")
        local fm = FileManager.instance
        if fm and fm.menu then fm.menu:onTapShowMenu() end
        return true
    end

    local self_ref = self

    function self:onScreenFocusUp()
        local books = self._kb_book_items_fp
        if not books or #books == 0 then return end
        local frec = self._kb_first_rec_idx
        if self._kb_focus_idx == nil then
            self._kb_focus_idx = frec or 1
        elseif frec and self._kb_focus_idx >= frec then
            self._kb_focus_idx = 1
        else
            self._kb_focus_idx = frec or 1
        end
        self:_refresh(true)
        return true
    end

    function self:onScreenFocusDown()
        local books = self._kb_book_items_fp
        local frec  = self._kb_first_rec_idx
        local on_recent = frec and self._kb_focus_idx and self._kb_focus_idx >= frec
        if on_recent then
            self._kb_focus_idx = nil
            self:_refresh(true)
            local Patches = require("infra/sui_patches")
            Patches.enterNavbarKbFocus(function()
                self_ref._kb_focus_idx = frec
                self_ref:_refresh(true)
            end)
            return true
        end
        if self._kb_focus_idx == nil then
            self._kb_focus_idx = 1
        elseif frec then
            self._kb_focus_idx = frec
        else
            self._kb_focus_idx = nil
            self:_refresh(true)
            local Patches = require("infra/sui_patches")
            Patches.enterNavbarKbFocus(function()
                self_ref._kb_focus_idx = 1
                self_ref:_refresh(true)
            end)
            return true
        end
        self:_refresh(true)
        return true
    end

    function self:onScreenFocusLeft()
        local frec = self._kb_first_rec_idx
        if not frec or not self._kb_focus_idx then return end
        if self._kb_focus_idx < frec then return end
        if self._kb_focus_idx > frec then
            self._kb_focus_idx = self._kb_focus_idx - 1
            self:_refresh(true)
        end
        return true
    end

    function self:onScreenFocusRight()
        local frec  = self._kb_first_rec_idx
        local books = self._kb_book_items_fp
        if not frec or not self._kb_focus_idx or not books then return end
        if self._kb_focus_idx < frec then return end
        if self._kb_focus_idx < #books then
            self._kb_focus_idx = self._kb_focus_idx + 1
            self:_refresh(true)
        end
        return true
    end

    function self:onScreenKbPress()
        if self._kb_focus_idx == nil then return end
        local books = self._kb_book_items_fp
        if not books then return end
        local fp = books[self._kb_focus_idx]
        if fp then
            self._kb_focus_idx = nil
            local open_fn = self._ctx_cache and self._ctx_cache.open_fn
            if open_fn then open_fn(fp) end
        end
        return true
    end

    -- Navpager compatibility — sui_bottombar looks for these methods and the
    -- page/page_num fields on the topmost pageable widget.
    function self:onPrevPage()
        local cur   = self._current_page or 1
        local total = self._total_pages  or 1
        local new_page = _resolvePageNav(cur, total, "prev")
        if new_page ~= cur then
            self._current_page = new_page
            self.page          = new_page
            self:_refresh(true)
        end
        return true
    end

    function self:onNextPage()
        local cur   = self._current_page or 1
        local total = self._total_pages  or 1
        local new_page = _resolvePageNav(cur, total, "next")
        if new_page ~= cur then
            self._current_page = new_page
            self.page          = new_page
            self:_refresh(true)
        end
        return true
    end

    function self:onGotoPage(page)
        local total = self._total_pages or 1
        local new_page = _resolvePageNav(1, total, page)  -- page is a spread index
        self._current_page = new_page
        self.page          = new_page
        self:_refresh(true)
        return true
    end

    -- Tap forwarding: FM corner gestures have priority over the navbar guard.
    function self:onBlockNavbarTap(_args, ges)
        if _hasModalOnTop(self) then return false end
        if _fmGestureAction(ges) then return true end
        if ges and ges.pos then
            local x, y = ges.pos.x, ges.pos.y
            local sw = Screen:getWidth()
            local sh = Screen:getHeight()
            local function _inRaw(z)
                if not z then return false end
                return x >= z.ratio_x * sw and x < (z.ratio_x + z.ratio_w) * sw
                   and y >= z.ratio_y * sh and y < (z.ratio_y + z.ratio_h) * sh
            end
            if _inRaw(_gz_bot_left) or _inRaw(_gz_bot_right) then
                return  -- let it through
            end
        end
        if _in_bar(ges) then return true end
    end
    function self:onScreenHold(_args, ges)
        if _hasModalOnTop(self) then return false end
        if _in_bar(ges) then return true end
        return _fmGestureAction(ges)
    end
    function self:onBlockNavbarHold(_args, ges)
        if _hasModalOnTop(self) then return false end
        if _in_bar(ges) then return true end
    end

    -- title/left_icon are optional instance_cfg fields (see the contract
    -- comment above ScreenWidget:init()): a Custom Screen supplies its
    -- own name/icon so its title bar — including the text the KOReader
    -- screen reader announces on open — matches what the user actually
    -- opened, instead of always reading "Home Screen"/house icon. The
    -- fallbacks below preserve the exact previous behaviour for the
    -- built-in Homescreen, which relies on them rather than passing the
    -- fields explicitly.
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
    self._kb_focus_idx       = nil
    self._kb_first_rec_idx   = nil
    self._kb_book_items_fp   = nil
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
    self._overflow_warn_key  = nil

    -- Minimal placeholder so patches.lua can call wrapWithNavbar safely.
    -- Real content is built in onShow() once _navbar_content_h is set.
    self[1] = FrameContainer:new{
        bordersize = 0, padding = 0,
        dimen      = Geom:new{ w = sw, h = sh },
        VerticalSpan:new{ width = sh },
    }

    -- Register top-of-screen tap/swipe zones to open the KOReader main menu,
    -- mirroring what FileManagerMenu:initGesListener does for the library.
    local DTAP_ZONE_MENU     = G_defaults:readSetting("DTAP_ZONE_MENU")
    local DTAP_ZONE_MENU_EXT = G_defaults:readSetting("DTAP_ZONE_MENU_EXT")
    if DTAP_ZONE_MENU and DTAP_ZONE_MENU_EXT then
        local function _fmMenu()
            local FM = package.loaded["apps/filemanager/filemanager"]
            local inst = FM and FM.instance
            if inst and inst.menu then return inst.menu end
            return nil
        end

        local topbar_on  = SUISettings:nilOrTrue("simpleui_topbar_enabled")
        local zone_ratio_h
        if topbar_on then
            local ok_tb, Topbar   = pcall(require, "screens/sui_topbar")
            local ok_ui, UI_core  = pcall(require, "infra/sui_core")
            if ok_tb and ok_ui then
                zone_ratio_h = (Topbar.TOTAL_TOP_H() + UI_core.MOD_GAP) / sh
            else
                zone_ratio_h = DTAP_ZONE_MENU.h
            end
        else
            zone_ratio_h = DTAP_ZONE_MENU.h
        end

        self:registerTouchZones({
            {
                id          = self._pfx .. "menu_tap",
                ges         = "tap",
                screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = zone_ratio_h },
                handler = function(ges)
                    if _hasModalOnTop(self) then return false end
                    local m = _fmMenu()
                    if m then return m:onTapShowMenu(ges) end
                end,
            },
            {
                id          = self._pfx .. "menu_swipe",
                ges         = "swipe",
                screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = zone_ratio_h },
                handler = function(ges)
                    if _hasModalOnTop(self) then return false end
                    local m = _fmMenu()
                    if m and m:onSwipeShowMenu(ges) then return true end
                    return _fmGestureAction(ges)
                end,
            },
        })
    end

    -- Footer touch zones override BlockNavbarTap/ScreenSwipe for gestures landing
    -- in the combined navbar + pagination footer strip.
    local pag_footer_h   = Bottombar.getPaginationIconSize() + Screen:scaleBySize(8)
    local combined_h     = Bottombar.TOTAL_H() + pag_footer_h
    local footer_ratio_y = (sh - combined_h) / sh
    local footer_ratio_h = combined_h / sh
    local self_ref_fc    = self

    self:registerTouchZones({
        {
            id          = self._pfx .. "footer_tap",
            ges         = "tap",
            screen_zone = { ratio_x = 0, ratio_y = footer_ratio_y, ratio_w = 1, ratio_h = footer_ratio_h },
            overrides = { "BlockNavbarTap" },
            handler = function(ges)
                if _hasModalOnTop(self_ref_fc) then return false end
                if _fmGestureAction(ges) then return true end

                local footer_bc = self_ref_fc._footer_bc
                if not footer_bc or footer_bc.dimen.h == 0 then return false end

                local navpager_on  = Config.isNavpagerEnabled()
                local dot_pager_on = Config.isDotPagerEnabled()
                if navpager_on or dot_pager_on then
                    local fd = self_ref_fc._footer_dot
                    if fd and fd.bar_input then
                        return fd.bar_input:handleEvent(Event:new("Gesture", ges))
                    end
                    return false
                end

                local fc = self_ref_fc._footer_chevron
                if fc then
                    local buttons = { fc.btn_first, fc.btn_prev, fc.btn_next, fc.btn_last }
                    for _, btn in ipairs(buttons) do
                        local d = btn.dimen
                        if d and ges.pos and ges.pos:intersectWith(d) then
                            if btn.enabled ~= false then btn.callback() end
                            return true
                        end
                    end
                end
                return false
            end,
        },
        {
            id          = self._pfx .. "footer_swipe",
            ges         = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = footer_ratio_y, ratio_w = 1, ratio_h = footer_ratio_h },
            overrides = { "ScreenSwipe" },
            handler = function(ges)
                if _hasModalOnTop(self_ref_fc) then return false end
                if _fmGestureAction(ges) then return true end

                local footer_bc = self_ref_fc._footer_bc
                if not footer_bc or footer_bc.dimen.h == 0 then return false end

                local dir   = ges and ges.direction
                local cur   = self_ref_fc._current_page or 1
                local total = self_ref_fc._total_pages  or 1
                if total <= 1 then return false end
                if dir ~= "west" and dir ~= "east" then return false end

                local new_page = _resolveSwipeNav(cur, total, dir)
                if new_page ~= cur then
                    self_ref_fc._current_page = new_page
                    self_ref_fc.page          = new_page
                    self_ref_fc:_refresh(true)
                end
                return true
            end,
        },
    })

    -- Priority gesture zones for top and bottom strips — these fire before
    -- the fullscreen ges_events handlers for double-tap, two-finger, etc.
    local top_ratio_h    = (DTAP_ZONE_MENU and DTAP_ZONE_MENU.h) or 0.1
    local _gesture_types = {
        { ges = "double_tap",       id_suffix = "double_tap",        override = "ScreenDoubleTap"      },
        { ges = "two_finger_tap",   id_suffix = "two_finger_tap",    override = "ScreenTwoFingerTap"   },
        { ges = "two_finger_swipe", id_suffix = "two_finger_swipe",  override = "ScreenTwoFingerSwipe" },
        { ges = "multiswipe",       id_suffix = "multiswipe",        override = "ScreenMultiswipe"     },
        { ges = "spread",           id_suffix = "spread",            override = "ScreenSpread"         },
        { ges = "pinch",            id_suffix = "pinch",             override = "ScreenPinch"          },
        { ges = "rotate",           id_suffix = "rotate",            override = "ScreenRotate"         },
        { ges = "hold",             id_suffix = "hold",              override = "ScreenHold"           },
    }

    local priority_zones = {}
    for _, gt in ipairs(_gesture_types) do
        priority_zones[#priority_zones + 1] = {
            id          = self._pfx .. "top_" .. gt.id_suffix,
            ges         = gt.ges,
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = top_ratio_h },
            overrides = { gt.override },
            handler   = function(ges) return _hasModalOnTop(self) and false or _fmGestureAction(ges) end,
        }
        priority_zones[#priority_zones + 1] = {
            id          = self._pfx .. "bottom_" .. gt.id_suffix,
            ges         = gt.ges,
            screen_zone = { ratio_x = 0, ratio_y = footer_ratio_y, ratio_w = 1, ratio_h = footer_ratio_h },
            overrides = { gt.override },
            handler   = function(ges) return _hasModalOnTop(self) and false or _fmGestureAction(ges) end,
        }
    end
    self:registerTouchZones(priority_zones)
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
    local sh        = Screen:getHeight()
    -- Defensive fallback: UI.getContentHeight() (infra/sui_core.lua) is the
    -- same bar-aware value UI.applyNavbarState() would set into
    -- self._navbar_content_h during navbar injection. Using it here instead
    -- of the raw, bar-covering Screen height means that if injection is ever
    -- skipped or runs late for some reason, content still stops above the
    -- bar instead of silently extending underneath it.
    local content_h = self._navbar_content_h or UI.getContentHeight()
    local side_off  = SIDE_PAD
    local inner_w   = sw - side_off * 2

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

    -- SUIWallpaper.styleGetBgWidget() already creates the ImageWidget with
    -- height=sh (full screen), so when bars_transparent is active the
    -- wallpaper automatically bleeds behind the topbar and bottombar with no
    -- extra work needed here.  We just paint it at (x, y) as usual.
    if _lf_bg then
        local _orig_paintTo = content_widget.paintTo
        local _bg           = _lf_bg
        function content_widget:paintTo(bb, x, y)
            -- Always paint from y=0 so the wallpaper is anchored at the top
            -- and covers the full screen area.
            _bg:paintTo(bb, x, 0)
            -- Opacity: 0 = fully opaque (no lighten), 1-99 = fade toward white.
            -- lightenRect is a cheap in-place blitbuffer op — safe on e-ink.
            local opacity = SUIWallpaper.styleGetWallpaperOpacityValue()
            if opacity and opacity > 0 then
                bb:lightenRect(x, 0, Screen:getWidth(), Screen:getHeight(), opacity / 100)
            end
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

-- ---------------------------------------------------------------------------
-- _buildCtx — constructs the module build context for the current render.
-- ---------------------------------------------------------------------------
function ScreenWidget:_buildCtx()
    local inner_w = self._layout_inner_w or (Screen:getWidth() - SIDE_PAD * 2)

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
                bar_style   = SUISettings:readSetting(self._pfx .. "currently_bar_style") or "with_pct",
                stats_style = SUISettings:readSetting(self._pfx .. "currently_stats_style") or "default",
                layout      = SUISettings:readSetting(self._pfx .. "currently_layout") == "dynamic" and "dynamic" or "default",
                elem_order  = SUISettings:readSetting(self._pfx .. "currently_elem_order"),
                show = {
                    title    = SUISettings:nilOrTrue(self._pfx .. "currently_show_title"),
                    author   = SUISettings:nilOrTrue(self._pfx .. "currently_show_author"),
                    progress = SUISettings:nilOrTrue(self._pfx .. "currently_show_progress"),
                    percent  = SUISettings:nilOrTrue(self._pfx .. "currently_show_percent"),
                    days     = SUISettings:nilOrTrue(self._pfx .. "currently_show_book_days"),
                    time     = SUISettings:nilOrTrue(self._pfx .. "currently_show_book_time"),
                    remain   = SUISettings:nilOrTrue(self._pfx .. "currently_show_book_remaining"),
                    series      = SUISettings:nilOrTrue(self._pfx .. "currently_show_series"),
                    description = SUISettings:nilOrTrue(self._pfx .. "currently_show_description"),
                },
            },
            coverdeck = {
                scale         = Config.getModuleScale("coverdeck", self._pfx),
                thumb_scale   = Config.getThumbScale("coverdeck", self._pfx),
                lbl_scale     = Config.getItemLabelScale("coverdeck", self._pfx),
                source        = SUISettings:readSetting(self._pfx .. "coverdeck_source") or "recent",
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
        self._cfg_cache = cfg
    end

    local mod_c  = Registry.get("currently")
    local mod_r  = Registry.get("recent")
    local mod_cd = Registry.get("coverdeck")
    local show_c = mod_c and Registry.isEnabled(mod_c, self._pfx)
    local show_r = (mod_r and Registry.isEnabled(mod_r, self._pfx))
                or (mod_cd and Registry.isEnabled(mod_cd, self._pfx))

    if not self._cached_books_state then
        local SH = _getBookShared()
        if SH then
            if show_c or show_r then
                local max_recent = 15
                -- show_finished is no longer computed here: each module
                -- (module_recent, module_coverdeck) filters finished books
                -- independently at render time using its own setting.
                -- max_recent is set to 15 so that after each module filters
                -- finished books at render time, at least 5 unfinished entries
                -- remain available for display.
                local excl = SUISettings:readSetting(self._pfx .. "recent_exclude_currently")
                if excl == nil then excl = true end
                self._cached_books_state = SH.prefetchBooks(show_c, show_r, max_recent, {
                    exclude_current = excl,
                })
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
    local mod_rs      = Registry.get("reading_stats")
    local wants_stats = (mod_rg and Registry.isEnabled(mod_rg, self._pfx))
        or (mod_rs and mod_rs.isEnabled and mod_rs.isEnabled(self._pfx))

    -- Scan external modules that declare M.needs = { db=true, stats=true, books=true }.
    -- Built-ins have their requirements encoded in the explicit checks below; this
    -- loop only fires for modules not in the MODULES list (zero cost when no
    -- external modules are registered).
    local ext_needs_db    = false
    local ext_needs_stats = false
    local ext_needs_books = false
    for _, mod in ipairs(Registry.list()) do
        if mod.needs and Registry.isEnabled(mod, self._pfx) then
            if mod.needs.db    then ext_needs_db    = true end
            if mod.needs.stats then ext_needs_stats = true end
            if mod.needs.books then ext_needs_books = true end
        end
    end
    if ext_needs_stats then wants_stats = true end

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
    -- The "recent" module (mod_r) shows no DB-backed stats, so it is excluded.
    local wants_db = show_c or coverdeck_needs_db or wants_stats or ext_needs_db

    if wants_db and not self._db_conn and not self._defer_stats then
        -- openStatsDB returns nil while a Statistics cloud sync is in progress.
        self._db_conn = Config.openStatsDB()
    end

    -- Pre-fetch numeric stats via the shared provider (at most 2 DB roundtrips).
    -- needs_books: true only when reading_goals is active, OR reading_stats is
    -- active and "total_books" is among the selected stat items.  When false,
    -- SP.get() skips the sidecar scan (up to 200 DS.open calls) entirely.
    -- External modules that declare M.needs.books = true also trigger this.
    local needs_books = ext_needs_books
    if mod_rg and Registry.isEnabled(mod_rg, self._pfx) then
        needs_books = true
    elseif mod_rs and mod_rs.isEnabled and mod_rs.isEnabled(self._pfx) then
        -- mod_rs.getItems(self._pfx) applies the same default { "total_books",
        -- "today_time", "streak" } fallback module_reading_stats itself uses
        -- when the user has never customized their stat cards, so the check
        -- below reflects the cards actually rendered rather than the raw
        -- "reading_stats_items" setting (nil/{} on a fresh install).
        local rs_items = mod_rs.getItems and mod_rs.getItems(self._pfx) or {}
        for _, id in ipairs(rs_items) do
            if id == "total_books" then needs_books = true; break end
        end
    end

    -- Status counts (unread/reading/finished/abandoned across the whole
    -- library) are a separate, more expensive walk than needs_books above
    -- (sui_library_scan + one sidecar read per book not already cached), so
    -- they get their own gate — only computed when reading_stats actually
    -- has a status_* card selected, same "don't pay for what isn't shown"
    -- principle as needs_books.
    local needs_status = mod_rs and mod_rs.usesStatusCounts and mod_rs.usesStatusCounts(self._pfx)

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
        local c_cfg = cfg and cfg.currently
        local needs_bstats = (c_cfg and (c_cfg.show.days or c_cfg.show.time or c_cfg.show.remain))
            or (not c_cfg and (
                SUISettings:nilOrTrue(self._pfx .. "currently_show_book_days") or
                SUISettings:nilOrTrue(self._pfx .. "currently_show_book_time") or
                SUISettings:nilOrTrue(self._pfx .. "currently_show_book_remaining")))
        if needs_bstats then
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
        year_str               = year_str,   -- cached once per render; re-used by async tick
        landscape_factor       = landscape_factor,
        pfx                    = self._pfx,
        pfx_qa                 = self._pfx_qa,
        close_fn               = function() self_ref:onClose() end,
        open_fn                = function(fp, pos0, page) openBook(fp, pos0, page) end,
        hold_fn                = function(fp, mod_id) self_ref:_showBookHoldDialog(fp, mod_id) end,
        refresh_fn             = function() self_ref:_refreshImmediate(true) end,
        open_settings_fn       = function(mod_id)
            local m = mod_id and Registry.get(mod_id)
            if m then self_ref:_openModuleSettingsFor(m) end
        end,
        on_qa_tap              = function(aid) if self_ref._on_qa_tap then self_ref._on_qa_tap(aid) end end,
        on_goal_tap            = function() if self_ref._on_goal_tap then self_ref._on_goal_tap() end end,
        db_conn                = wants_db and self._db_conn or nil,
        db_conn_fatal          = false,
        stats                  = stats_data,
        status_counts           = status_counts,
        coverdeck_center_stats = coverdeck_center_stats,
        currently_book_stats   = currently_book_stats,
        vspan_pool             = self._vspan_pool,
        prefetched             = bs.prefetched_data,
        current_fp             = bs.current_fp,
        recent_fps             = bs.recent_fps,
        sectionLabel           = sectionLabel,
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
function ScreenWidget:_updateFooter(current_page, total_pages, topbar_on)
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
-- _showBookHoldDialog — opens the per-book action dialog (mirrors KOReader's
-- FM long-press dialog, trimmed to book-only actions) for a single cover
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
        -- "More by <Author>" (sui_browse_author, registered in main.lua)
        -- repaints FM.instance.file_chooser to the virtual author leaf, but
        -- the homescreen is what's actually on screen here, on top of FM —
        -- so that repaint happens invisibly underneath unless we close the
        -- homescreen too, revealing the now-updated FM view. A plain
        -- refresh_fn (repaint the homescreen in place) would just leave the
        -- person looking at the homescreen with nothing having happened.
        navigate_fn      = function() self_ref:onClose() end,
        navigate_row_ids = { sui_browse_author = true },
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
function ScreenWidget:_openModuleSettingsFor(mod)
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

        local function titleFn(ctx)
            local cur = ctx.current()
            local id  = cur and cur.id or "__root__"
            if id == "nested_menu"  then return cur.params.title or "" end
            if id == "arrange"      then return cur.params.title or _("Arrange Items") end
            if id == "item_picker"  then return cur.params and cur.params.title or _("Add Item") end
            return mod.name or mod.id
        end

        local win = SUIWindow:new{
            name           = "sui_win_context",
            title          = titleFn,
            screens        = SUIWindow.makeSettingsScreens(buildRoot),
            navpager_mode  = Config.isNavpagerEnabled(),
            position       = "bottom",
            has_settings_btn = true,
        }
        win:show()
end

-- ---------------------------------------------------------------------------
-- _onHoldModRelease — shared handler for module long-press settings menus.
-- Stored once on ScreenWidget; each wrapper sets wrapper._sui_mod so this
-- single function knows which module was held (no per-module closure needed).
-- ---------------------------------------------------------------------------
function ScreenWidget:_onHoldModRelease(wrapper)
    if not SUISettings:nilOrTrue(self._pfx .. "settings_on_hold") then
        return true
    end
    local mod    = wrapper._sui_mod
    local screen = wrapper._sui_screen
    if not mod or not screen then return true end
    screen:_openModuleSettingsFor(mod)
    return true
end

-- ---------------------------------------------------------------------------
-- _makeModWrapper — returns a pooled InputContainer wrapping a module widget.
-- Wrappers are allocated once per mod.id per Homescreen lifetime and updated
-- in-place on subsequent page turns (zero new allocations).
-- ---------------------------------------------------------------------------
function ScreenWidget:_buildModWidget(mod, col_w, ctx)
    local ModuleChrome = require("features/sui_module_chrome")
    local chrome = ModuleChrome.resolve(self._pfx, mod.id)
    local build_w = ModuleChrome.contentWidth(col_w, chrome)
    -- Expose the full column width so modules that re-wrap later (clock tick)
    -- can recover the same chrome geometry the page build used.
    if ctx then ctx.col_w = col_w end
    local ok_w, widget = pcall(mod.build, build_w, ctx)
    if not ok_w then
        return nil, widget
    end
    if not widget then return nil end
    return ModuleChrome.wrap(widget, chrome, col_w, (ctx and ctx.landscape_factor) or 1)
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

    local inner_w = self._layout_inner_w or (Screen:getWidth() - SIDE_PAD * 2)
    local body    = self._body
    if not body then return end

    -- Module list cache — rebuilt whenever layout changes.
    local layout = SUISettings:readSetting(self._layout_key)
    local raw_order = Registry.loadOrder(self._pfx)
    
    local layout_fingerprint = ""
    local pages_by_id = {}
    
    -- Column widths come from per-module settings (bento grid), not the layout.
    local mod_col_width = {}
    if layout and type(layout.pages) == "table" then
        for _, page in ipairs(layout.pages) do
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
                    local bw = Config.getBentoWidth(mod_id, self._pfx)
                    mod_col_width[mod_id] = bw
                    layout_fingerprint = layout_fingerprint .. mod_id .. ":" .. tostring(bw) .. ","
                end
            end
            layout_fingerprint = layout_fingerprint .. "|"
            table.insert(pages_by_id, page_ids)
        end
    else
        pages_by_id = splitOrderIntoPages(raw_order)
        for _, mod_id in ipairs(raw_order) do
            if mod_id ~= "__page_break__" then
                local bw = Config.getBentoWidth(mod_id, self._pfx)
                mod_col_width[mod_id] = bw
                layout_fingerprint = layout_fingerprint .. mod_id .. ":" .. tostring(bw) .. ","
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
            chosen_pages = #layout.pages
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
                local found = false
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
    local enabled_mods  = self._enabled_mods_cache.mods
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

    local topbar_on = SUISettings:nilOrTrue("simpleui_topbar_enabled")

    self._clock_body_idx    = nil
    self._clock_body_ref    = body
    self._stats_mod_slots   = {}
    self._book_mod_slots    = {}
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

    -- Rebuild keyboard navigation book index.
    local _kb_books = {}
    self._kb_first_rec_idx = nil
    ctx.kb_currently_focused = nil
    ctx.kb_recent_focus_idx  = nil
    if ctx.current_fp then
        _kb_books[#_kb_books + 1] = ctx.current_fp
        ctx.kb_currently_focused = (self._kb_focus_idx == #_kb_books) or nil
    end
    if ctx.recent_fps and #ctx.recent_fps > 0 then
        local first_rec_idx = #_kb_books + 1
        self._kb_first_rec_idx = first_rec_idx
        for ri = 1, #ctx.recent_fps do
            _kb_books[#_kb_books + 1] = ctx.recent_fps[ri]
        end
        if self._kb_focus_idx and self._kb_focus_idx >= first_rec_idx
                and self._kb_focus_idx <= #_kb_books then
            ctx.kb_recent_focus_idx = self._kb_focus_idx - first_rec_idx + 1
        end
    end
    self._kb_book_items_fp = _kb_books

    local cur_page_mods  = pages_of_mods[self._current_page] or {}
    local first_mod      = true
    local page_has_covers = false

    -- Bento packing (portrait and landscape):
    --   • width < 100% → column of that share of the row
    --   • consecutive modules whose widths fit (sum ≤ 100) sit side by side
    --   • when a module no longer fits horizontally, it stacks into an
    --     existing column that has the same width (same % only); otherwise
    --     a new row starts
    --   • 100% (default) always takes a full-width row of its own
    --   • rows whose columns sum to < 100% are centred in the container
    -- In landscape the same rules apply inside each spread column.
    do
        -- Shared horizontal gap: bento columns and landscape page split.
        local H_COL_GAP = 1
        mod_col_width = mod_col_width or {}

        -- Builds label + hold-wrapper cell. Slot registration happens in
        -- _register_cell once the cell's real parent is known.
        local function _emit_mod(mod, col_w)
            if mod.has_covers then page_has_covers = true end
            local widget, err = self:_buildModWidget(mod, col_w, ctx)
            if err and not widget then
                logger.warn("simpleui: screen (" .. tostring(self._id) .. "): build failed for "
                            .. tostring(mod.id) .. ": " .. tostring(err))
                return nil
            end
            if not widget then return nil end

            local cell = VerticalGroup:new{ align = "left" }
            if mod.label then
                local label_text = (type(mod.label_func) == "function" and mod.label_func(ctx)) or mod.label
                cell[#cell+1] = sectionLabel(label_text, col_w, labelRightTextFor(mod, ctx), pageNavFor(self, mod, ctx), ctx.landscape_factor)
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
                self._cover_mod_slots[mod.id] = { mod = mod, widget = widget }
            end
            if type(mod.updateStats) == "function" then
                self._stats_mod_slots[mod.id] = { mod = mod, widget = widget }
            end
            -- Stash for _register_cell (widget + col_w needed by book slots).
            cell._sui_mod = mod
            cell._sui_widget = widget
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
                    parent   = cell,
                    index    = #cell,
                    col_w    = col_w,
                    has_menu = true,
                }
            end
            cell._sui_mod = nil
            cell._sui_widget = nil
            cell._sui_col_w = nil
        end

        -- Packs mods into parent_body. container_w is the full available
        -- width for a 100% module. first is a one-element table toggled so
        -- the first row can apply top-of-page padding.
        local function _pack_bento(mods, parent_body, container_w, first)
            local function _flush_row(row_cols)
                if not row_cols or #row_cols == 0 then return end
                local lead_mod = row_cols[1].mods[1]
                local gap_px = mod_gaps[lead_mod.id] or MOD_GAP
                if first[1] then
                    first[1] = false
                    local initial_pad = topbar_on and gap_px or (gap_px + MOD_GAP)
                    parent_body[#parent_body+1] = self:_vspan(initial_pad)
                else
                    parent_body[#parent_body+1] = self:_vspan(gap_px)
                end

                local n = #row_cols
                local gaps_w = (n - 1) * H_COL_GAP
                local avail = math.max(1, container_w - gaps_w)

                local sum_pct = 0
                for _, col in ipairs(row_cols) do sum_pct = sum_pct + col.width end

                local target = {}
                local allocated = 0
                for i, col in ipairs(row_cols) do
                    if i == n then
                        local row_pixels = math.max(1, math.floor(avail * sum_pct / 100))
                        target[i] = math.max(1, row_pixels - allocated)
                    else
                        target[i] = math.max(1, math.floor(avail * col.width / 100))
                        allocated = allocated + target[i]
                    end
                end

                local h_row = HorizontalGroup:new{ align = "center" }
                for i, col in ipairs(row_cols) do
                    local slot_w = target[i]
                    local v_col = VerticalGroup:new{ align = "left" }
                    for mi, mod in ipairs(col.mods) do
                        if mi > 1 then
                            v_col[#v_col+1] = self:_vspan(mod_gaps[mod.id] or MOD_GAP)
                        end
                        local cell = _emit_mod(mod, slot_w)
                        if cell then
                            _register_cell(cell)
                            v_col[#v_col+1] = cell
                        end
                    end
                    -- Pin the column to the allocated slot width. Without this,
                    -- VerticalGroup reports content width (which can exceed
                    -- slot_w); neighbouring columns then overlap the
                    -- HorizontalSpan and the inter-column gap never changes
                    -- no matter what H_COL_GAP is set to.
                    local col_h = v_col:getSize().h
                    h_row[#h_row+1] = LeftContainer:new{
                        dimen = Geom:new{ w = slot_w, h = col_h },
                        v_col,
                    }
                    if i < n then
                        h_row[#h_row+1] = HorizontalSpan:new{ width = H_COL_GAP }
                    end
                end

                -- Centre when the row does not consume the full container.
                local content_w = gaps_w
                for i = 1, n do content_w = content_w + target[i] end
                local leftover = container_w - content_w
                if leftover > 1 then
                    local left_pad = math.floor(leftover / 2)
                    parent_body[#parent_body+1] = HorizontalGroup:new{
                        align = "center",
                        HorizontalSpan:new{ width = left_pad },
                        h_row,
                        HorizontalSpan:new{ width = leftover - left_pad },
                    }
                else
                    parent_body[#parent_body+1] = h_row
                end
            end

            local row_cols = {}
            local row_sum = 0
            for _, mod in ipairs(mods) do
                -- Width already clamped by Config.getBentoWidth.
                local w = mod_col_width[mod.id] or 100

                if w >= 100 then
                    _flush_row(row_cols)
                    row_cols, row_sum = {}, 0
                    _flush_row({ { width = 100, mods = { mod } } })
                elseif row_sum + w <= 100 then
                    row_cols[#row_cols+1] = { width = w, mods = { mod } }
                    row_sum = row_sum + w
                else
                    -- Stack only onto a column with the same width %.
                    local stacked = false
                    for _, col in ipairs(row_cols) do
                        if col.width == w then
                            col.mods[#col.mods+1] = mod
                            stacked = true
                            break
                        end
                    end
                    if not stacked then
                        _flush_row(row_cols)
                        row_cols = { { width = w, mods = { mod } } }
                        row_sum = w
                    end
                end
            end
            _flush_row(row_cols)
        end

        if is_landscape then
            local col_w = UI.getSpreadColWidth(inner_w)
            local portrait_inner_w = UI.getPortraitInnerW()
            _landscape_factor = (portrait_inner_w > 0) and (col_w / portrait_inner_w) or 1
            ctx.landscape_factor = _landscape_factor
            self._clock_landscape_factor = _landscape_factor

            -- Spread: left = current page, right = next page.
            -- Solo (odd total, last page): split this page's modules in half.
            local right_page_mods = pages_of_mods[self._current_page + 1]
            local left_mods, right_mods
            if right_page_mods then
                left_mods, right_mods = cur_page_mods, right_page_mods
            else
                left_mods, right_mods = {}, {}
                local split_at = math.ceil(#cur_page_mods / 2)
                for i, mod in ipairs(cur_page_mods) do
                    if i <= split_at then
                        left_mods[#left_mods + 1] = mod
                    else
                        right_mods[#right_mods + 1] = mod
                    end
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
                    align = "top",
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
    end

    if empty_widget then
        if first_mod then
            local top_pad = topbar_on and MOD_GAP or (MOD_GAP * 2)
            body[#body+1] = self:_vspan(top_pad)
        end
        body[#body+1] = empty_widget
    end

    -- Dithering hint for e-ink: UIManager checks widget.dithered on setDirty
    -- to trigger a full pixel refresh cycle (avoids ghosting on cover bitmaps).
    self.dithered = page_has_covers or nil

    -- In landscape, footer and navpager reflect spread count rather than raw pages.
    local footer_page, footer_total
    if is_landscape and total_pages > 1 then
        footer_total = math.ceil(total_pages / 2)
        footer_page  = math.ceil(self._current_page / 2)
    else
        footer_total = total_pages
        footer_page  = self._current_page
    end

    self:_updateFooter(footer_page, footer_total, topbar_on)
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

-- ---------------------------------------------------------------------------
-- _refresh — debounced rebuild. Page turns call _updatePage directly.
-- ---------------------------------------------------------------------------
function ScreenWidget:_refresh(keep_cache, books_only, stats_only)
    local defer_async = false
    if not keep_cache and self._body and self._ctx_cache then
        defer_async = true
        keep_cache  = true
    end

    if keep_cache and self._body then
        self:_updatePage(true)
        UIManager:setDirty(self, "ui")

        if defer_async then
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
                local stats_only = self._refresh_pending_stats_only

                if not self._db_conn then
                    self._db_conn = Config.openStatsDB()
                end

                if self._ctx_cache then
                    -- 1. Get new book metadata (prefetchBooks)
                    if not stats_only then
                        local SH = _getBookShared()
                        if SH then
                            local mod_r  = Registry.get("recent")
                            local mod_cd = Registry.get("coverdeck")
                            local show_c = Registry.isEnabled(Registry.get("currently"), self._pfx)
                            local show_r = (mod_r and Registry.isEnabled(mod_r, self._pfx)) or (mod_cd and Registry.isEnabled(mod_cd, self._pfx))
                            -- show_finished removed: each module filters independently at render time.
                            local excl = SUISettings:readSetting(self._pfx .. "recent_exclude_currently")
                            if excl == nil then excl = true end
                            local new_bs = SH.prefetchBooks(show_c, show_r, 15, {
                                exclude_current = excl,
                            })
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
                        local missing_slot = false
                        for _, mod in ipairs(Registry.list()) do
                            if mod.is_book_mod
                               and not self._book_mod_slots[mod.id]
                               and Registry.isEnabled(mod, self._pfx) then
                                missing_slot = true
                                break
                            end
                        end
                        if missing_slot then
                            self:_updatePage(false)
                            UIManager:setDirty(self, "ui")
                        end
                    end

                    -- 2. Get new global stats
                    local SP = _getStatsProvider()
                    if SP then
                        local new_stats = SP.get(self._db_conn, self._ctx_cache.year_str, self._ctx_cache._needs_books)
                        if new_stats then self._ctx_cache.stats = new_stats end
                        if self._ctx_cache._needs_status and SP.getStatusCounts then
                            self._ctx_cache.status_counts = SP.getStatusCounts()
                        end
                    end

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

                    -- 3. Update Book Modules
                    -- Try updateStats in-place first (O(1), zero alloc).
                    -- Only rebuilds the full widget if the module doesn't have updateStats
                    -- (fallback for modules that don't support in-place update).
                    if not stats_only then
                        for id, slot in pairs(self._book_mod_slots or {}) do
                            local updated_in_place = false
                            if type(slot.mod.updateStats) == "function" then
                                local ok, result = pcall(slot.mod.updateStats, slot.widget, self._ctx_cache)
                                updated_in_place = ok and result
                            end

                            if updated_in_place then
                                -- Successful in-place update: setDirty only on the widget's region.
                                local w = slot.widget
                                if w and w.dimen then
                                    UIManager:setDirty(self, function() return "ui", w.dimen end)
                                else
                                    UIManager:setDirty(self, "ui")
                                end
                            else
                                -- Fallback: full rebuild (module has no updateStats,
                                -- or updateStats returned false because the book's
                                -- identity changed — see module_currently/
                                -- module_coverdeck.updateStats).
                                local new_widget = self:_buildModWidget(slot.mod, slot.col_w, self._ctx_cache)
                                if new_widget then
                                    if slot.has_menu then
                                        local wrapper = self._wrapper_pool[id]
                                        if wrapper then
                                            wrapper[1] = new_widget
                                            -- Keep slot.widget pointed at the live widget
                                            -- (mirrors _refreshBookModSlot), so the next
                                            -- updateStats(slot.widget, ctx) operates on the
                                            -- widget actually in the tree.
                                            slot.widget = new_widget
                                            UIManager:setDirty(self, function() return "ui", wrapper.dimen, true end)
                                        end
                                    else
                                        slot.parent[slot.index] = new_widget
                                        slot.widget = new_widget
                                        UIManager:setDirty(self, function() return "ui", new_widget.dimen, true end)
                                    end
                                end
                            end

                            -- Keeps this module's "x/y" page indicator and
                            -- chevrons in sync regardless of which branch
                            -- above ran: an in-place updateStats can shift
                            -- npages without the current page's own slice
                            -- changing (see GridRenderer.updateStats), and a
                            -- full rebuild here — unlike _refreshBookModSlot's
                            -- swipe/chevron path — never touched the header
                            -- widget on its own. Same pattern as
                            -- _refreshBookModSlot; see _syncBookModLabel.
                            self:_syncBookModLabel(id)
                        end
                    end

                    -- 4. Update Stats Modules
                    -- Each slot uses setDirty targeted at its own dimen,
                    -- avoiding a global repaint of the entire screen.
                    -- updateStats() returns false when _changed flags show none of the
                    -- module's fields were re-fetched — skip setDirty entirely in that case.
                    for _, slot in pairs(self._stats_mod_slots or {}) do
                        local updated = slot.mod.updateStats(slot.widget, self._ctx_cache)
                        if updated then
                            -- Surgical repaint: only the stats module's region.
                            -- slot.widget.dimen may be nil if the widget hasn't been
                            -- positioned yet; in that case falls back to the global repaint.
                            if slot.widget and slot.widget.dimen then
                                UIManager:setDirty(self, function()
                                    return "ui", slot.widget.dimen
                                end)
                            else
                                UIManager:setDirty(self, "ui")
                            end
                        end
                    end
                end
            end)
        end
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
        UIManager:setDirty(self, "ui")
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
-- shared by the section-label chevrons (see pageNavFor above) and the
-- swipe gesture on the row/grid itself (engines/sui_book_grid.lua's
-- swipe_area:onSwipe). Clamped (no wraparound — page 1 has no previous,
-- the last page has no next): GridRenderer.turnPage returns nil at either
-- edge, in which case this is a no-op and no repaint is triggered.
function ScreenWidget:_turnBookModPage(mod_id, delta)
    if not self._ctx_cache then return false end
    local ok_gr, GridRenderer = pcall(require, "engines/sui_book_grid")
    if not ok_gr or not GridRenderer then return false end
    local page_key   = "_row_page_" .. mod_id
    local npages_key = "_row_npages_" .. mod_id
    local npages  = self._ctx_cache[npages_key] or 1
    local page    = self._ctx_cache[page_key] or 1
    local new_page = GridRenderer.turnPage(page, npages, delta)
    if not new_page then return false end
    self._ctx_cache[page_key] = new_page
    if self._refreshBookModSlot and self:_refreshBookModSlot(mod_id) then return true end
    if self._refreshImmediate then self:_refreshImmediate(true) end
    return true
end

-- ---------------------------------------------------------------------------
-- _syncBookModLabel(mod_id) — surgical repaint of a paginated book module's
-- section-title header: the "x/y" page indicator and its chevrons.
--
-- A book module's grid content and its header live in separate widgets
-- (see _book_mod_slots vs _book_mod_label_slots) — updating the former never
-- touches the latter. Every caller that changes a paginated module's content
-- (a page turn, a background stats refresh, a status/collection change, ...)
-- must therefore also call this afterwards, or the header keeps showing the
-- page/npages — and, worse, the chevrons keep the enabled/disabled state —
-- from before the change, potentially blocking access to a page that just
-- became reachable.
--
-- Reads ctx fresh (via pageIndicatorFor/pageNavFor) rather than trusting the
-- caller to know the current page/npages, so this is always safe to call
-- speculatively: it's a no-op (no setDirty) when the recomputed label widget
-- is identical to the one already mounted.
-- ---------------------------------------------------------------------------
function ScreenWidget:_syncBookModLabel(mod_id)
    local label_slot = self._book_mod_label_slots and self._book_mod_label_slots[mod_id]
    if not (label_slot and label_slot.parent and label_slot.mod.label) then return end
    local new_label = sectionLabel(label_slot.mod.label, label_slot.col_w,
        pageIndicatorFor(label_slot.mod, self._ctx_cache), pageNavFor(self, label_slot.mod, self._ctx_cache),
        self._ctx_cache and self._ctx_cache.landscape_factor)
    if new_label == label_slot.parent[label_slot.index] then return end
    label_slot.parent[label_slot.index] = new_label
    if new_label.dimen then
        UIManager:setDirty(self, function() return "ui", new_label.dimen, true end)
    else
        UIManager:setDirty(self, "ui")
    end
end

function ScreenWidget:_refreshBookModSlot(mod_id)
    if not self._ctx_cache or not self._book_mod_slots then return false end
    local slot = self._book_mod_slots[mod_id]
    if not slot or not slot.mod or type(slot.mod.build) ~= "function" then return false end

    local new_widget = self:_buildModWidget(slot.mod, slot.col_w, self._ctx_cache)
    if not new_widget then return false end

    if slot.has_menu then
        if not (self._wrapper_pool and self._wrapper_pool[mod_id]) then return false end
        -- Reuses _makeModWrapper (instead of swapping wrapper[1] by hand) so
        -- wrapper.dimen.w/h get resynced with new_widget's real size, just
        -- like a full build — otherwise a taller widget's refresh region
        -- would be too small for UIManager:setDirty to fully clear/repaint.
        local wrapper = self:_makeModWrapper(slot.mod, new_widget, slot.col_w)
        slot.widget = new_widget
        local rtype = self:_bookModRefreshType(mod_id)
        UIManager:setDirty(self, function() return rtype, wrapper.dimen, true end)
    else
        if not slot.parent then return false end
        slot.parent[slot.index] = new_widget
        slot.widget = new_widget
        local rtype = self:_bookModRefreshType(mod_id)
        UIManager:setDirty(self, function() return rtype, new_widget.dimen, true end)
    end
    -- Keep the cover-poll slot pointing at the currently visible widget, so
    -- covers still pending extraction on the newly-shown page get swapped
    -- into it rather than into the old, now-orphaned widget.
    if self._cover_mod_slots and self._cover_mod_slots[mod_id] then
        self._cover_mod_slots[mod_id].widget = new_widget
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

        local any_updated = false
        local any_pending = false

        for mod_id, slot in pairs(slots) do
            if type(slot.mod.updateCovers) == "function" then
                local ok, all_done = pcall(slot.mod.updateCovers, slot.widget, ctx)
                local dimen = slot.widget and slot.widget.dimen
                if ok then
                    if dimen then
                        self_ref.dithered = true
                        UIManager:setDirty(self_ref, function()
                            return "ui", dimen, true
                        end)
                        any_updated = true
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
            -- App startup: fetch the real book state synchronously instead
            -- of seeding from SH.getStaleBooks(). Mirrors the prefetchBooks()
            -- call the deferred tick in _refresh() makes further below in
            -- this file — same show_c/show_r resolution, same count — so the
            -- very first paint already has authoritative data and needs no
            -- follow-up correction.
            local SH = _getBookShared()
            if SH then
                local mod_r  = Registry.get("recent")
                local mod_cd = Registry.get("coverdeck")
                local show_c = Registry.isEnabled(Registry.get("currently"), self._pfx)
                local show_r = (mod_r and Registry.isEnabled(mod_r, self._pfx))
                    or (mod_cd and Registry.isEnabled(mod_cd, self._pfx))
                local excl = SUISettings:readSetting(self._pfx .. "recent_exclude_currently")
                if excl == nil then excl = true end
                self._cached_books_state = SH.prefetchBooks(show_c, show_r, 15, {
                    exclude_current = excl,
                })
            end
            self._cached_books_state = self._cached_books_state
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
                -- KOBO_VIRTUAL:// paths (module_books_shared.lua's
                -- _koboVirtualPath) are skipped: lfs.attributes cannot resolve
                -- them, and there is no exported real-path lookup to reverse the
                -- mapping here, so a real-file check would false-negative every
                -- kepub on Kobo devices instead of only catching deleted books.
                local function _existsOrVirtual(fp)
                    if fp:match("^KOBO_VIRTUAL://") then return true end
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
        
        self:_updatePage(true)
        UIManager:setDirty(self, "ui")
        local ClockMod = Registry.get("clock")
        if ClockMod and Registry.isEnabled(ClockMod, self._pfx) and ClockMod.scheduleRefresh then
            ClockMod.scheduleRefresh(self)
        end
        
        if need_async and not is_app_cold_boot then
            self._defer_stats = false
            self:_refresh(false)
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

function ScreenWidget:onSuspend()
    self._suspended = true
    self:_pauseBackgroundWork()
end

function ScreenWidget:onResume()
    self._suspended = false
    if Device.screen_saver_mode then return end
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
    -- same optimisation applied in onCloseDocument.
    -- stats_only=true keeps _cached_books_state intact (no sidecar I/O needed).
    local SP = package.loaded["modules/module_stats_provider"]
    if SP and SP.invalidateTimeSeries then
        SP.invalidateTimeSeries()
    elseif SP and SP.invalidate then
        SP.invalidate()
    end
    self:_refresh(false, false, true)
    local ClockMod = Registry.get("clock")
    if ClockMod and Registry.isEnabled(ClockMod, self._pfx) and ClockMod.scheduleRefresh then
        ClockMod.scheduleRefresh(self)
    end
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
    self._kb_book_items_fp   = nil
    self._kb_focus_idx       = nil
    self._kb_first_rec_idx   = nil
    self._parked              = nil -- defensive: real close always ends any park

    local ClockMod = Registry.get("clock")
    if ClockMod and ClockMod.cancelRefresh then ClockMod.cancelRefresh() end
    self._clock_body_ref   = nil
    self._clock_body_idx   = nil
    self._clock_is_wrapped = nil
    self._clock_pfx        = nil
    self._clock_inner_w    = nil
    self._overflow_warn_key = nil

    -- Clear cover cache only when the FM file browser was visited since the
    -- last homescreen open (CoverBrowser replaces BIM covers with scaled
    -- thumbnails, making our cached bitmaps stale).
    if ScreenEngine._library_was_visited then
        ScreenEngine._library_was_visited = nil
        Config.clearCoverCache()
    end

    -- Free header module quotes if the header is not in quote mode.
    local ok_mh, MH = pcall(require, "modules/module_header")
    if ok_mh and MH and type(MH.freeQuotesIfUnused) == "function" then
        MH.freeQuotesIfUnused()
    end

    -- Nudge the incremental GC after tearing down the full tree above (see
    -- the self:free() rationale at the top of this handler): without this,
    -- freed-but-uncollected blitbuffers accumulate faster than LuaJIT's
    -- steady-state GC step reclaims them. Deferred to nextTick so it never
    -- delays the reader/homescreen transition itself.
    UIManager:nextTick(function() collectgarbage("step", 200) end)

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
-- Soft-park (ScreenEngine.SOFT_PARK_ENABLED) keeps the screen alive across
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
-- time (e.g. "Return to Book Folder") closes the parked instance for real
-- instead of leaving it dangling with increasingly stale data.
--
-- _navbar_closing_intentionally makes onCloseWidget (above) treat a real
-- close like a tab-switch rather than a dismissal, so _cached_books_state /
-- _current_page / _cfg_cache are preserved in ScreenEngine's per-id storage
-- and the next cold _showHSCold() still gets a warm seed instead of a cold
-- one — unchanged from before, and still what happens whenever soft-park
-- itself doesn't apply (Custom Screens, more than one live screen, or
-- SOFT_PARK_ENABLED = false).
function ScreenWidget:onShowingReader()
    self.dithered = nil

    if ScreenEngine.SOFT_PARK_ENABLED and self._id == _BUILTIN_ID
            and #ScreenEngine.liveScreenIds() == 1 then
        self._parked = true
        self:_pauseBackgroundWork()
        return
    end

    self._navbar_closing_intentionally = true
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

-- Clears the section-label widget cache. Must be called after a screen
-- resize or rotation so labels are rebuilt at the new inner_w.
ScreenEngine.invalidateLabelCache = invalidateLabelCache

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

