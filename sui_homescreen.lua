-- homescreen.lua — Simple UI
-- Fullscreen modular page shown when the "Homescreen" tab is tapped.
-- Shares the same module registry and module files as the Continue page
-- but is completely independent: separate settings prefix (navbar_homescreen_),
-- separate caches, and a different lifecycle (UIManager stack widget vs
-- Continue page's FM-injection approach).
--
-- ARCHITECTURE NOTES (for resource-constrained devices)
-- • This is a standard KOReader fullscreen widget (covers_fullscreen = true).
--   patches.lua injects the navbar automatically on UIManager:show().
-- • The module registry and individual module_*.lua files are shared with
--   Continue page — no duplication of module code.
-- • State that MUST be per-instance:
--     _cached_books_state, _vspan_pool, _wrapper_pool, _cover_poll_timer,
--     _on_qa_tap, _on_goal_tap
-- • The cover LRU cache (Config.getCoverBB) is already per-filepath+size and
--   shared safely between pages; no extra work needed here.
-- • _vspan_pool and _wrapper_pool are allocated on show() and nilled on close()
--   so they don't linger in memory when the page is not visible.

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
local TextWidget       = require("ui/widget/textwidget")
local TitleBar         = require("ui/widget/titlebar")
local UIManager        = require("ui/uimanager")
local HorizontalGroup  = require("ui/widget/horizontalgroup")
local VerticalGroup    = require("ui/widget/verticalgroup")
local VerticalSpan     = require("ui/widget/verticalspan")
local logger           = require("logger")
local _                = require("gettext")
local T                = require("ffi/util").template
local Config           = require("sui_config")
local Registry         = require("desktop_modules/moduleregistry")
local Event            = require("ui/event")
local Screen           = Device.screen

-- Cached module references — loaded once on first use, reused on every render.
-- Avoids a pcall + package.loaded lookup overhead on each _buildCtx call.
local _SH = nil   -- desktop_modules/module_books_shared
local _SP = nil   -- desktop_modules/module_stats_provider
local function _getBookShared()
    if not _SH then
        local ok, m = pcall(require, "desktop_modules/module_books_shared")
        if ok then _SH = m end
    end
    return _SH
end
local function _getStatsProvider()
    if not _SP then
        local ok, m = pcall(require, "desktop_modules/module_stats_provider")
        if ok then _SP = m end
    end
    return _SP
end
local UI               = require("sui_core")
local Bottombar        = require("sui_bottombar")

-- ---------------------------------------------------------------------------
-- Layout constants — sourced from ui.lua (single source of truth).
-- ---------------------------------------------------------------------------
local PAD                = UI.PAD
local MOD_GAP            = UI.MOD_GAP
local SIDE_PAD           = UI.SIDE_PAD
local SECTION_LABEL_SIZE = 11
local _CLR_TEXT_MID      = Blitbuffer.gray(0.45)
local _DOT_COLOR_INACTIVE = Blitbuffer.gray(0.55)  -- precomputed, reused every paint

-- Modules that render cover thumbnails — used by _updatePage to set the
-- dithering hint. Defined at file level: constant, never recreated per page-turn.
local _COVER_MOD_IDS = { collections=true, recent=true, currently=true, new_books=true, coverdeck=true }

-- ---------------------------------------------------------------------------
-- DotWidget — defined once at file level to avoid per-call class allocation.
-- buildDotBar() creates instances; the class itself is never recreated.
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
            bb:paintCircle(cx, cy, dot_r, Blitbuffer.COLOR_BLACK)
        else
            bb:paintCircle(cx, cy, dot_r, _DOT_COLOR_INACTIVE)
        end
    end
end

-- Settings prefix — all homescreen settings are namespaced here,
-- completely independent from "navbar_continue_*".
local PFX    = "navbar_homescreen_"
local PFX_QA = "navbar_homescreen_quick_actions_"

-- Forward declaration — must be before HomescreenWidget so that
-- onCloseWidget() can capture it as an upvalue. Populated at the bottom.
local Homescreen = { _instance = nil }

-- ---------------------------------------------------------------------------
-- Helpers — local to this file
-- ---------------------------------------------------------------------------

-- Returns true when a widget other than HomescreenWidget is on top of the
-- UIManager stack (e.g. a QuickMenu ButtonDialog opened via gesture).
-- Used to avoid intercepting tap events that should reach the modal.
local function _hasModalOnTop(hs_widget)
    local stack = UIManager._window_stack
    if not stack or #stack == 0 then return false end
    local top = stack[#stack]
    return top and top.widget ~= hs_widget
end

-- Pixel constants for empty state — computed once at load time.
local _EMPTY_H        = Screen:scaleBySize(80)
local _EMPTY_TITLE_H  = Screen:scaleBySize(30)
local _EMPTY_TITLE_FS = Screen:scaleBySize(18)
local _EMPTY_GAP      = Screen:scaleBySize(12)
local _EMPTY_SUB_H    = Screen:scaleBySize(20)
local _EMPTY_SUB_FS   = Screen:scaleBySize(13)

local _BASE_SECTION_LABEL_SIZE = Screen:scaleBySize(SECTION_LABEL_SIZE)

-- Section label cache: (text .. "|" .. inner_w .. "|" .. scale_pct) → FrameContainer.
-- The scale_pct component invalidates cached widgets when the user changes
-- label scale, without requiring a full cache wipe on every render.
local _label_cache = {}

local function invalidateLabelCache()
    _label_cache = {}
end

local function sectionLabel(text, w)
    local scale     = Config.getLabelScale()
    local fs        = math.max(8, math.floor(_BASE_SECTION_LABEL_SIZE * scale))
    local label_h   = math.max(8, math.floor(Screen:scaleBySize(16) * scale))
    local scale_pct = math.floor(scale * 100)  -- integer key — avoids float noise
    local key = text .. "|" .. w .. "|" .. scale_pct
    if not _label_cache[key] then
        _label_cache[key] = FrameContainer:new{
            bordersize = 0, padding = 0,
            padding_left = PAD, padding_right = PAD,
            padding_bottom = UI.LABEL_PAD_BOT,
            TextWidget:new{
                text  = text,
                face  = Font:getFace("smallinfofont", fs),
                bold  = true,
                width = w - PAD * 2,
                -- Explicitly set height so the container is sized correctly
                -- even when the font engine rounds differently from label_h.
                -- This keeps getHeight() and the actual render in sync.
                height = label_h,
            },
        }
    end
    return _label_cache[key]
end

local function buildEmptyState(w, h)
    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
        VerticalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = _EMPTY_TITLE_H },
                TextWidget:new{
                    text = _("No books opened yet"),
                    face = Font:getFace("smallinfofont", _EMPTY_TITLE_FS),
                    bold = true,
                },
            },
            VerticalSpan:new{ width = _EMPTY_GAP },
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = _EMPTY_SUB_H },
                TextWidget:new{
                    text    = _("Open a book to get started"),
                    face    = Font:getFace("smallinfofont", _EMPTY_SUB_FS),
                    fgcolor = _CLR_TEXT_MID,
                },
            },
        },
    }
end

-- ---------------------------------------------------------------------------
-- Pagination helpers
-- ---------------------------------------------------------------------------

-- Default and settings key for modules-per-page limit.
local HS_PAGE_BREAK_ID  = "__page_break__"

-- Split a flat module_order list (which may contain __page_break__ sentinels)
-- into a list of pages, each page being a list of module ids.
-- Empty pages are preserved as empty tables so the page count matches the user choice.
local function splitOrderIntoPages(order)
    local pages     = {}
    local cur_page  = {}
    for _, id in ipairs(order) do
        if id == HS_PAGE_BREAK_ID then
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

-- ---------------------------------------------------------------------------
-- Footer helpers — persistent widgets mutated in-place on page turns,
-- mirroring the pattern used by Menu (Collections / History / FileManager).
-- Built once in _initLayout(); updated by _updateFooter() with zero allocs.
-- ---------------------------------------------------------------------------

-- Builds the persistent chevron footer descriptor.
-- goto_fn receives a page number, or the strings "prev"/"next"/"last".
-- The actual navigation is wired via _initLayout so self is in scope.
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
    local page_info = HorizontalGroup:new{
        align = "center",
        btn_first, spacer, btn_prev, spacer,
        btn_text, spacer, btn_next, spacer, btn_last,
    }
    -- Wrap in a plain InputContainer — tap/swipe routing for this area is
    -- handled via registerTouchZones on HomescreenWidget (see _initLayout /
    -- init), which fires before ges_events and therefore before BlockNavbarTap.
    local chev_w    = Screen:getWidth()
    local chev_h    = Bottombar.getPaginationIconSize() + Screen:scaleBySize(8)
    local chev_input = InputContainer:new{
        dimen = Geom:new{ w = chev_w, h = chev_h },
        CenterContainer:new{
            dimen = Geom:new{ w = chev_w, h = chev_h },
            page_info,
        },
    }
    return {
        widget    = chev_input,
        btn_first = btn_first,
        btn_prev  = btn_prev,
        btn_text  = btn_text,
        btn_next  = btn_next,
        btn_last  = btn_last,
    }
end

-- Builds the persistent dot-indicator footer descriptor.
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
        -- Swipe on the dot bar triggers the same page-turn as swiping the body.
        -- Without this, the bar_input InputContainer silently consumes the swipe
        -- and it never reaches HomescreenWidget:onHSSwipe.
        SwipeDot = {
            GestureRange:new{
                ges   = "swipe",
                range = function() return bar_input.dimen end,
            },
        },
    }
    function bar_input:onTapDot(_args, ges)
        if not (ges and ges.pos) then return true end
        -- bar_input lives inside a CenterContainer whose x is set after the
        -- first paint, so dimen.x may be 0 on early taps. Derive the left
        -- edge from the screen centre and the bar's pixel width instead.
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

-- When navpager is active there is no inline bar; instead update the bottom
-- bar arrows so they reflect the homescreen's current page state.
local function _updateNavpagerForHS(current_page, total_pages)
    if not Config.isNavpagerEnabled() then return end
    local tgt = Homescreen._instance
    if not tgt then return end
    local has_prev = current_page > 1
    local has_next = current_page < total_pages
    if not Bottombar.updateNavpagerArrows(tgt, has_prev, has_next) then
        local tabs    = Config.loadTabConfig()
        local mode    = Config.getNavbarMode()
        local new_bar = Bottombar.buildBarWidgetWithArrows(
            "homescreen", tabs, mode, has_prev, has_next)
        Bottombar.replaceBar(tgt, new_bar, tabs)
    end
    UIManager:setDirty(tgt, "ui")
end

local function openBook(filepath, pos0, page)
    -- Do NOT close the Homescreen before opening the reader.
    -- ReaderUI:showReader() broadcasts a "ShowingReader" event that closes all
    -- widgets atomically (FileManager, Homescreen, etc.) before the first reader
    -- paint — eliminating the flash of the FileChooser that occurs when we close
    -- the Homescreen first and then schedule the reader open with a delay.
    -- The 0.1s scheduleIn is also removed: showReader() is safe to call directly.
    -- ReaderUI is a core KOReader module — always present. Use package.loaded
    -- fast path to avoid pcall overhead; fall back to require on first call.
    local doOpen = function()
        local ReaderUI = package.loaded["apps/reader/readerui"]
            or require("apps/reader/readerui")
        ReaderUI:showReader(filepath)
        -- Jump to the highlight position once the reader has initialised.
        -- showReader() is async — schedule the jump so ReaderUI.instance is ready.
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
    -- Respect the native KOReader "Ask before opening file" setting.
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
-- HomescreenWidget
-- ---------------------------------------------------------------------------

local HomescreenWidget = InputContainer:extend{
    name                = "homescreen",
    covers_fullscreen   = true,
    disable_double_tap  = true,
    -- Set by patches.lua after navbar injection:
    _on_qa_tap        = nil,
    -- Set by menu.lua goal dialog wiring:
    _on_goal_tap      = nil,
}

function HomescreenWidget:init()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self.dimen = Geom:new{ w = sw, h = sh }

    -- Block taps/holds that land on the bottom bar area so they are never
    -- consumed by module InputContainers whose dimen extends into that area.
    -- Y threshold must match Bottombar.TOTAL_H() (full reserved strip: separator
    -- + bar + bottom padding), not raw content height — the latter breaks when
    -- the top bar is enabled (wrong band vs. actual navbar row).
    -- Computed once at init time; stable for the lifetime of this widget instance
    -- (screen dimensions only change on rotation, which triggers a full rebuild).
    local _bar_y = sh - Bottombar.TOTAL_H()
    local function _in_bar(ges)
        return ges and ges.pos and ges.pos.y >= _bar_y
    end
    self.ges_events = {
        BlockNavbarTap = {
            GestureRange:new{
                ges   = "tap",
                range = function() return self.dimen end,
            },
        },
        BlockNavbarHold = {
            GestureRange:new{
                ges   = "hold",
                range = function() return self.dimen end,
            },
        },
        -- Forward gesture types to the FM gestures plugin so that all
        -- custom gestures configured in the library also work on the homescreen.
        -- Each handler resolves the canonical gesture name (e.g.
        -- "one_finger_swipe_left_edge_down") and delegates to gestureAction().
        HSSwipe = {
            GestureRange:new{
                ges   = "swipe",
                range = function() return self.dimen end,
            },
        },
        HSDoubleTap = {
            GestureRange:new{
                ges   = "double_tap",
                range = function() return self.dimen end,
            },
        },
        HSTwoFingerTap = {
            GestureRange:new{
                ges   = "two_finger_tap",
                range = function() return self.dimen end,
            },
        },
        HSTwoFingerSwipe = {
            GestureRange:new{
                ges   = "two_finger_swipe",
                range = function() return self.dimen end,
            },
        },
        HSMultiswipe = {
            GestureRange:new{
                ges   = "multiswipe",
                range = function() return self.dimen end,
            },
        },
        HSHold = {
            GestureRange:new{
                ges   = "hold",
                range = function() return self.dimen end,
            },
        },
        HSSpread = {
            GestureRange:new{
                ges   = "spread",
                range = function() return self.dimen end,
            },
        },
        HSPinch = {
            GestureRange:new{
                ges   = "pinch",
                range = function() return self.dimen end,
            },
        },
        HSRotate = {
            GestureRange:new{
                ges   = "rotate",
                range = function() return self.dimen end,
            },
        },
    }
    -- ---------------------------------------------------------------------------
    -- _fmGestureAction — resolve gesture name and delegate to FM gestures plugin.
    --
    -- Zone data from G_defaults is immutable during a session — read once at
    -- init time and reuse on every gesture to avoid per-gesture table allocations.
    -- ---------------------------------------------------------------------------
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

    local function _fmGestureAction(ges_event)
        -- ---------------------------------------------------------------------------
        -- Dispatch a gesture event to the FM gestures plugin, covering every
        -- gesture type that the plugin supports in docless (file-manager) mode:
        --   tap corners, hold corners, double-tap sides/corners, two-finger tap
        --   corners, edge swipes, short diagonal swipe, two-finger swipes,
        --   multiswipe, spread, pinch, rotate.
        --
        -- Resolution strategy: map the raw gesture event to a canonical gesture
        -- name (as used in g.gestures["gesture_fm"]) then call g:gestureAction().
        -- gestureAction() is a no-op when no action is configured for that name,
        -- so we always try every candidate — there is no harm in trying.
        --
        -- sendEvent is temporarily redirected to broadcastEvent so that actions
        -- that fire UIManager events (frontlight, full-refresh, wifi toggle, etc.)
        -- reach FM's DeviceListener and other listeners, not only the top widget.
        -- ---------------------------------------------------------------------------
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

        local function inZone(z)
            if not z then return false end
            return x >= z.ratio_x * sw and x < (z.ratio_x + z.ratio_w) * sw
               and y >= z.ratio_y * sh and y < (z.ratio_y + z.ratio_h) * sh
        end

        -- Candidates: ordered list of (ges_name, condition) pairs to try.
        -- The first matching name that has a non-nil action in g.gestures is
        -- executed. For gesture types with a single unambiguous name (two-finger
        -- swipe, rotate, etc.) there is only one candidate.
        local candidates = {}

        if gt == "swipe" then
            local is_diag = dir == "northeast" or dir == "northwest"
                         or dir == "southeast" or dir == "southwest"
            if is_diag then
                local short_thresh = Screen:scaleBySize(300)
                if ges_event.distance and ges_event.distance <= short_thresh then
                    candidates[#candidates+1] = "short_diagonal_swipe"
                end
            elseif inZone(_gz_left_edge) then
                if     dir == "south" then candidates[#candidates+1] = "one_finger_swipe_left_edge_down"
                elseif dir == "north" then candidates[#candidates+1] = "one_finger_swipe_left_edge_up"
                end
            elseif inZone(_gz_right_edge) then
                if     dir == "south" then candidates[#candidates+1] = "one_finger_swipe_right_edge_down"
                elseif dir == "north" then candidates[#candidates+1] = "one_finger_swipe_right_edge_up"
                end
            elseif inZone(_gz_top_edge) then
                if     dir == "east" then candidates[#candidates+1] = "one_finger_swipe_top_edge_right"
                elseif dir == "west" then candidates[#candidates+1] = "one_finger_swipe_top_edge_left"
                end
            elseif inZone(_gz_bot_edge) then
                if     dir == "east" then candidates[#candidates+1] = "one_finger_swipe_bottom_edge_right"
                elseif dir == "west" then candidates[#candidates+1] = "one_finger_swipe_bottom_edge_left"
                end
            end

        elseif gt == "tap" then
            if     inZone(_gz_top_left)  then candidates[#candidates+1] = "tap_top_left_corner"
            elseif inZone(_gz_top_right) then candidates[#candidates+1] = "tap_top_right_corner"
            elseif inZone(_gz_bot_left)  then candidates[#candidates+1] = "tap_left_bottom_corner"
            elseif inZone(_gz_bot_right) then candidates[#candidates+1] = "tap_right_bottom_corner"
            end

        elseif gt == "hold" then
            -- Hold corners: same zones as tap corners.
            if     inZone(_gz_top_left)  then candidates[#candidates+1] = "hold_top_left_corner"
            elseif inZone(_gz_top_right) then candidates[#candidates+1] = "hold_top_right_corner"
            elseif inZone(_gz_bot_left)  then candidates[#candidates+1] = "hold_bottom_left_corner"
            elseif inZone(_gz_bot_right) then candidates[#candidates+1] = "hold_bottom_right_corner"
            end

        elseif gt == "double_tap" then
            if     inZone(_gz_left_side)  then candidates[#candidates+1] = "double_tap_left_side"
            elseif inZone(_gz_right_side) then candidates[#candidates+1] = "double_tap_right_side"
            elseif inZone(_gz_top_left)   then candidates[#candidates+1] = "double_tap_top_left_corner"
            elseif inZone(_gz_top_right)  then candidates[#candidates+1] = "double_tap_top_right_corner"
            elseif inZone(_gz_bot_left)   then candidates[#candidates+1] = "double_tap_bottom_left_corner"
            elseif inZone(_gz_bot_right)  then candidates[#candidates+1] = "double_tap_bottom_right_corner"
            end

        elseif gt == "two_finger_tap" then
            if     inZone(_gz_top_left)  then candidates[#candidates+1] = "two_finger_tap_top_left_corner"
            elseif inZone(_gz_top_right) then candidates[#candidates+1] = "two_finger_tap_top_right_corner"
            elseif inZone(_gz_bot_left)  then candidates[#candidates+1] = "two_finger_tap_bottom_left_corner"
            elseif inZone(_gz_bot_right) then candidates[#candidates+1] = "two_finger_tap_bottom_right_corner"
            end

        elseif gt == "two_finger_swipe" then
            local map = {
                east = "two_finger_swipe_east",   west  = "two_finger_swipe_west",
                north = "two_finger_swipe_north",  south = "two_finger_swipe_south",
                northeast = "two_finger_swipe_northeast", northwest = "two_finger_swipe_northwest",
                southeast = "two_finger_swipe_southeast", southwest = "two_finger_swipe_southwest",
            }
            if map[dir] then candidates[#candidates+1] = map[dir] end

        elseif gt == "multiswipe" then
            -- Delegate directly — multiswipeAction handles name resolution internally.
            local orig_sendEvent = UIManager.sendEvent
            UIManager.sendEvent = function(um, ev) return UIManager:broadcastEvent(ev) end
            local ok, err = pcall(g.multiswipeAction, g, ges_event.multiswipe_directions, ges_event)
            UIManager.sendEvent = orig_sendEvent
            if not ok then logger.warn("simpleui hs gesture multiswipe:", err) end
            return true

        elseif gt == "spread" then
            candidates[#candidates+1] = "spread_gesture"
        elseif gt == "pinch" then
            candidates[#candidates+1] = "pinch_gesture"
        elseif gt == "rotate" then
            if     dir == "cw"  then candidates[#candidates+1] = "rotate_cw"
            elseif dir == "ccw" then candidates[#candidates+1] = "rotate_ccw"
            end
        end

        if #candidates == 0 then return end

        -- Execute the first candidate that has a configured action.
        -- gestureAction() is guarded by an action_list nil-check so it is safe
        -- to call for any name — it simply returns nil when nothing is configured.
        local gestures_fm = g.gestures  -- g.gestures already points to gesture_fm data
        local ges_name
        for _, name in ipairs(candidates) do
            if gestures_fm and gestures_fm[name] ~= nil then
                ges_name = name
                break
            end
        end
        -- If no action is configured, still try the first candidate: gestureAction
        -- handles the nil action_list gracefully (no-op), and this preserves
        -- any future default actions that may be added to the defaults table.
        if not ges_name and #candidates > 0 then
            ges_name = candidates[1]
        end

        if ges_name then
            local orig_sendEvent = UIManager.sendEvent
            UIManager.sendEvent = function(um, ev) return UIManager:broadcastEvent(ev) end
            local ok, err = pcall(g.gestureAction, g, ges_name, ges_event)
            UIManager.sendEvent = orig_sendEvent
            if not ok then
                logger.warn("simpleui hs gesture:", ges_name, err)
            end
            -- Return true only when an action was actually configured, so that
            -- callers (onBlockNavbarTap) can fall through correctly when no
            -- gesture action is set for this position.
            if gestures_fm and gestures_fm[ges_name] ~= nil then
                return true
            end
        end
    end

    -- NOTE: ges_events handlers receive (args, ev) because InputContainer dispatches via
    -- Event:new(eventname, gsseq.args, ev) and EventListener unpacks event.args as positional
    -- parameters: self:handler(gsseq.args, ev).  Since we never set gsseq.args the first
    -- parameter is always nil; the actual gesture table is the second parameter.

    -- Swipe left/right on the body turns pages when there are multiple pages.
    -- Edge-zone swipes are still forwarded to the FM gestures plugin as before.
    -- We only intercept plain left/right body swipes that do not originate from
    -- a recognised edge zone.
    local function _isSideEdge(ges)
        if not ges or not ges.pos then return false end
        local x = ges.pos.x
        local function _in(z)
            if not z then return false end
            return x >= z.ratio_x * sw and x < (z.ratio_x + z.ratio_w) * sw
        end
        return _in(_gz_left_edge) or _in(_gz_right_edge)
    end

    function self:onHSSwipe(_args, ges)
        -- Page turn: intercept horizontal swipes on the body (not edge zones).
        -- Mirrors Menu:onSwipe — cycles pages (last→first, first→last) so the
        -- behaviour matches the library, history and collections screens.
        if ges then
            local dir = ges.direction
            -- Footer swipes are intercepted earlier by the simpleui_hs_footer_swipe
            -- touch zone (registered in init()), which fires before ges_events.
            -- Nothing extra needed here — just handle body swipes normally.
            if (dir == "west" or dir == "east") and not _isSideEdge(ges) then
                -- CoverDeck swipe delegation:
                -- If the swipe originates inside the coverdeck wrapper, forward
                -- it directly to that widget so it can paginate the carousel
                -- without triggering a homescreen page turn.
                --
                -- Widget tree: cd_wrapper[1] → FrameContainer
                --              → [1] → VerticalGroup (final_vg)
                --                      → [N] → tappable InputContainer (has onSwipe)
                -- The tappable is not always at index 1 in the VerticalGroup
                -- (title may appear above it), so we search by type.
                if ges.pos then
                    -- Only delegate to coverdeck if it is visible on the current page.
                    -- The wrapper pool persists across page turns, so cd_wrapper.dimen
                    -- retains the coordinates from the coverdeck's page even when a
                    -- different page is shown — without this guard, swipes on other
                    -- modules at the same Y position are incorrectly captured by coverdeck.
                    local cd_on_current_page = false
                    do
                        local pom = self._enabled_mods_cache and self._enabled_mods_cache.pages_of_mods
                        local cur_mods = pom and pom[self._current_page or 1]
                        if cur_mods then
                            for _, m in ipairs(cur_mods) do
                                if m.id == "coverdeck" then cd_on_current_page = true; break end
                            end
                        end
                    end
                    local cd_wrapper = cd_on_current_page and self._wrapper_pool and self._wrapper_pool["coverdeck"]
                    if cd_wrapper and cd_wrapper.dimen
                            and ges.pos:intersectWith(cd_wrapper.dimen) then
                        local frame    = cd_wrapper[1]
                        local vg       = frame and frame[1]
                        local tappable = nil
                        if vg then
                            for _, child in ipairs(vg) do
                                if type(child.onSwipe) == "function" then
                                    tappable = child
                                    break
                                end
                            end
                        end
                        if tappable then
                            return tappable:onSwipe(nil, ges)
                        end
                    end
                end

                local cur   = self._current_page or 1
                local total = self._total_pages  or 1
                local new_page
                if dir == "west" then
                    -- forward: cycle last → first
                    new_page = cur < total and cur + 1 or 1
                else
                    -- back: cycle first → last
                    new_page = cur > 1 and cur - 1 or total
                end
                if new_page ~= cur or total == 1 then
                    self._current_page = new_page
                    self.page          = new_page
                    self:_refresh(true)  -- keep book cache, only rebuild layout
                end
                return true
            end
        end
        return _fmGestureAction(ges)
    end
    function self:onHSTwoFingerSwipe(_args, ges) return _fmGestureAction(ges) end
    function self:onHSDoubleTap(_args, ges)    return _fmGestureAction(ges) end
    function self:onHSTwoFingerTap(_args, ges) return _fmGestureAction(ges) end
    function self:onHSMultiswipe(_args, ges)   return _fmGestureAction(ges) end
    function self:onHSSpread(_args, ges)       return _fmGestureAction(ges) end
    function self:onHSPinch(_args, ges)        return _fmGestureAction(ges) end
    function self:onHSRotate(_args, ges)       return _fmGestureAction(ges) end

    -- ---------------------------------------------------------------------------
    -- Keyboard navigation (physical D-pad on Kindle and similar devices).
    --
    -- Layout model (3 logical rows):
    --   Row A — "Currently reading"  (single book, index 1 in _kb_book_items_fp)
    --   Row B — "Recent books"       (horizontal strip, indices _kb_first_rec_idx…end)
    --   Row C — Bottom navigation bar (entered via Patches.enterNavbarKbFocus)
    --
    -- Up / Down  → move between rows A, B, C.
    -- Left / Right → move within row B only (no effect on row A).
    -- Press → open focused book.
    -- Menu  → open KOReader main menu.
    -- ---------------------------------------------------------------------------
    -- Create a per-instance key_events table (avoids mutating the class table).
    self.key_events = {}
    if Device:hasDPad() then
        self.key_events.HSFocusUp    = { { "Up"    } }
        self.key_events.HSFocusDown  = { { "Down"  } }
        self.key_events.HSFocusLeft  = { { "Left"  } }
        self.key_events.HSFocusRight = { { "Right" } }
        self.key_events.HSKbPress    = { { "Press" } }
    end
    if Device:hasKeys() then
        self.key_events.HSOpenMenu   = { { "Menu"  } }
        self.key_events.PrevPage     = { { Device.input.group.PgBwd } }
        self.key_events.NextPage     = { { Device.input.group.PgFwd } }
    end

    -- Menu key → open the KOReader top settings menu (same as swipe-from-top).
    function self:onHSOpenMenu()
        local FileManager = require("apps/filemanager/filemanager")
        local fm = FileManager.instance
        if fm and fm.menu then fm.menu:onTapShowMenu() end
        return true
    end

    local self_ref = self  -- stable upvalue for closures below

    -- Up: move to the row above the current focus.
    --   nil          → enter focus at first book of the last content row
    --   on recent    → move to currently-reading row (idx 1)
    --   on currently → wrap: re-enter at first recent book (or stay if no recent)
    function self:onHSFocusUp()
        local books = self._kb_book_items_fp
        if not books or #books == 0 then return end
        local frec = self._kb_first_rec_idx   -- nil when no recent row

        if self._kb_focus_idx == nil then
            -- Enter focus at the first book of the lowest content row.
            self._kb_focus_idx = frec or 1
        elseif frec and self._kb_focus_idx >= frec then
            -- On recent row → move up to currently-reading.
            self._kb_focus_idx = 1
        else
            -- On currently row → wrap to first recent (or stay).
            self._kb_focus_idx = frec or 1
        end
        self:_refresh(true)
        return true
    end

    -- Down: move to the row below the current focus.
    --   nil or currently → move to recent row (or enter navbar if no recent)
    --   on recent        → enter bottom-bar keyboard focus
    function self:onHSFocusDown()
        local books = self._kb_book_items_fp
        local frec  = self._kb_first_rec_idx

        local on_recent = frec and self._kb_focus_idx and self._kb_focus_idx >= frec

        if on_recent then
            -- Bottom of content — enter navbar keyboard focus.
            -- Clear the book focus first so the border disappears after the user
            -- activates a tab (the return callback sets it again on Up/Back).
            local ret_frec = frec
            self._kb_focus_idx = nil
            self:_refresh(true)
            local Patches = require("sui_patches")
            Patches.enterNavbarKbFocus(function()
                -- User pressed Up/Back from the navbar → restore recent-row focus.
                self_ref._kb_focus_idx = ret_frec
                self_ref:_refresh(true)
            end)
            return true
        end

        if self._kb_focus_idx == nil then
            -- Not yet focused: focus the first content row.
            self._kb_focus_idx = 1
        elseif frec then
            self._kb_focus_idx = frec
        else
            -- Only currently-reading row, no recent — enter navbar directly.
            self._kb_focus_idx = nil
            self:_refresh(true)
            local Patches = require("sui_patches")
            Patches.enterNavbarKbFocus(function()
                self_ref._kb_focus_idx = 1
                self_ref:_refresh(true)
            end)
            return true
        end
        self:_refresh(true)
        return true
    end

    -- Left: move one step left within the recent-books row (clamp at first).
    function self:onHSFocusLeft()
        local frec = self._kb_first_rec_idx
        if not frec or not self._kb_focus_idx then return end
        if self._kb_focus_idx < frec then return end  -- on currently row, ignore
        if self._kb_focus_idx > frec then
            self._kb_focus_idx = self._kb_focus_idx - 1
            self:_refresh(true)
        end
        return true
    end

    -- Right: move one step right within the recent-books row (clamp at last).
    function self:onHSFocusRight()
        local frec  = self._kb_first_rec_idx
        local books = self._kb_book_items_fp
        if not frec or not self._kb_focus_idx or not books then return end
        if self._kb_focus_idx < frec then return end  -- on currently row, ignore
        if self._kb_focus_idx < #books then
            self._kb_focus_idx = self._kb_focus_idx + 1
            self:_refresh(true)
        end
        return true
    end

    -- Press: open the currently focused book.
    function self:onHSKbPress()
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

    -- ---------------------------------------------------------------------------
    -- Navpager compatibility — sui_bottombar._callPageFn / _callGotoPage look for
    -- these methods (and the page/page_num fields) on the topmost pageable widget.
    -- Without them the navpager arrows do nothing on the homescreen.
    -- ---------------------------------------------------------------------------
    function self:onPrevPage()
        local cur = self._current_page or 1
        if cur > 1 then
            self._current_page = cur - 1
            self.page          = self._current_page
            self:_refresh(true)
        end
        return true
    end

    function self:onNextPage()
        local cur   = self._current_page or 1
        local total = self._total_pages  or 1
        if cur < total then
            self._current_page = cur + 1
            self.page          = self._current_page
            self:_refresh(true)
        end
        return true
    end

    function self:onGotoPage(page)
        local total = self._total_pages or 1
        local p     = math.max(1, math.min(page, total))
        self._current_page = p
        self.page          = p
        self:_refresh(true)
        return true
    end

    -- Tap forwarding: gesture actions take priority over the navbar guard.
    -- _fmGestureAction is tried first; it only returns true when the tap lands
    -- on a configured corner zone (tap_top_left_corner, tap_left_bottom_corner,
    -- etc.) and the action is executed.  Only if no corner zone matched do we
    -- fall through to the navbar guard.  This ensures that corner gestures
    -- configured in the library (e.g. toggle frontlight on bottom-left corner)
    -- work even when the corner zone overlaps with the bottom navigation bar.
    function self:onBlockNavbarTap(_args, ges)
        if _hasModalOnTop(self) then return false end
        if _fmGestureAction(ges) then return true end
        if ges and ges.pos then
            local x, y = ges.pos.x, ges.pos.y
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
    function self:onHSHold(_args, ges)
        if _hasModalOnTop(self) then return false end
        -- Navbar area: always consume so module InputContainers don't fire.
        if _in_bar(ges) then return true end
        -- Forward hold-corner gestures to the FM gestures plugin.
        -- Module hold-to-settings handlers are registered on their own
        -- (smaller) dimen — if the hold lands inside a module widget it
        -- will be consumed there before reaching this handler.
        return _fmGestureAction(ges)
    end
    function self:onBlockNavbarHold(_args, ges)
        if _hasModalOnTop(self) then return false end
        if _in_bar(ges) then return true end  -- consume navbar holds
        -- Corner holds forwarded via onHSHold above; non-corner holds
        -- are left unconsumed so module widgets can handle them.
    end

    self.title_bar = TitleBar:new{
        show_parent             = self,
        fullscreen              = true,
        title                   = _("Homescreen"),
        left_icon               = "home",
        left_icon_tap_callback  = function() self:onClose() end,
        left_icon_hold_callback = false,
    }

    -- Per-instance caches — freed in onCloseWidget.
    self._vspan_pool         = {}
    self._wrapper_pool       = {}   -- pooled InputContainer wrappers, keyed by mod.id
    self._cached_books_state = self._cached_books_state  -- preserve value passed via new{} if any
    -- Keyboard navigation state — freed in onCloseWidget.
    self._kb_focus_idx       = nil  -- index into _kb_book_items_fp (nil = no focus)
    self._kb_first_rec_idx   = nil  -- index where recent books start (nil = no recent row)
    self._kb_book_items_fp   = nil  -- flat ordered list of book filepaths
    self._db_conn            = nil   -- shared SQLite connection, opened lazily, closed in onCloseWidget
    self._cover_poll_timer   = nil
    -- Cache of {mods, total_pages, pages_of_mods, …} — rebuilt only when module
    -- configuration changes (_refresh(false)), not on every page-turn swipe.
    self._enabled_mods_cache = nil
    -- Build-context cache — reused across page turns (keep_cache=true) so that
    -- Registry lookups and the DB-connection check are not repeated on every swipe.
    self._ctx_cache          = nil
    -- Pagination state — current page index (1-based), preserved across refreshes.
    self._current_page       = self._current_page or 1
    -- Expose page/page_num so that sui_bottombar._callPageFn / _callGotoPage
    -- can drive navpager arrows on the homescreen exactly like FM / Collections.
    -- These are kept in sync with _current_page / _total_pages after every build.
    self.page     = self._current_page
    self.page_num = 1   -- updated after first _updatePage()
    -- Clock module swap state — set during _updatePage, freed in onCloseWidget.
    self._clock_body_ref   = nil
    self._clock_body_idx   = nil
    self._clock_is_wrapped = nil
    self._clock_pfx        = nil
    self._clock_inner_w    = nil

    -- Build a minimal placeholder. The real content is built in onShow() once
    -- patches.lua has injected the navbar and set _navbar_content_h correctly.
    -- Building here would use the wrong height (full screen instead of
    -- screen-minus-navbar) and waste CPU constructing widgets that are
    -- immediately replaced.
    --
    -- The FrameContainer must have a child: patches.lua calls wrapWithNavbar
    -- with widget[1] as _navbar_inner, which calls FrameContainer:getSize(),
    -- which calls self[1]:getSize() — crashing if self[1] is nil.
    -- A zero-height VerticalSpan satisfies this contract at minimal cost.
    self[1] = FrameContainer:new{
        bordersize = 0, padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen      = Geom:new{ w = sw, h = sh },
        VerticalSpan:new{ width = sh },
    }

    -- ---------------------------------------------------------------------------
    -- Register top-of-screen tap/swipe zones to open the KOReader main menu on
    -- the Homescreen, mirroring what patches.lua does for other injected widgets
    -- and what FileManagerMenu:initGesListener does for the library.
    --
    -- When the topbar is enabled the zone is shrunk to the visible topbar strip
    -- (TOTAL_TOP_H + MOD_GAP) so the touch target matches the visual element.
    -- Without this, swiping down from the top of the homescreen does nothing
    -- because HSSwipe forwards to _fmGestureAction which only handles gestures
    -- that are mapped in the FM gestures plugin — a plain south-swipe from the
    -- body of the screen is not one of those unless the user explicitly mapped it.
    -- ---------------------------------------------------------------------------
    local DTAP_ZONE_MENU     = G_defaults:readSetting("DTAP_ZONE_MENU")
    local DTAP_ZONE_MENU_EXT = G_defaults:readSetting("DTAP_ZONE_MENU_EXT")
    if DTAP_ZONE_MENU and DTAP_ZONE_MENU_EXT then
        -- Helper: resolve the live FileManagerMenu at call time, never caching.
        local function _hsMenu()
            local FM = package.loaded["apps/filemanager/filemanager"]
            local inst = FM and FM.instance
            if inst and inst.menu then return inst.menu end
            return nil
        end

        local topbar_on  = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
        local zone_ratio_h
        if topbar_on then
            local ok_tb, Topbar   = pcall(require, "sui_topbar")
            local ok_ui, UI_core  = pcall(require, "sui_core")
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
                id          = "simpleui_hs_menu_tap",
                ges         = "tap",
                screen_zone = {
                    ratio_x = 0, ratio_y = 0,
                    ratio_w = 1, ratio_h = zone_ratio_h,
                },
                handler = function(ges)
                    if _hasModalOnTop(self) then return false end
                    local m = _hsMenu()
                    if m then return m:onTapShowMenu(ges) end
                end,
            },
            {
                id          = "simpleui_hs_menu_swipe",
                ges         = "swipe",
                screen_zone = {
                    ratio_x = 0, ratio_y = 0,
                    ratio_w = 1, ratio_h = zone_ratio_h,
                },
                handler = function(ges)
                    if _hasModalOnTop(self) then return false end
                    local m = _hsMenu()
                    if m and m:onSwipeShowMenu(ges) then return true end
                    -- onSwipeShowMenu only consumes south swipes; east/west fall
                    -- through to FM gestures so top-edge E/W actions still fire.
                    return _fmGestureAction(ges)
                end,
            },
        })
    end

    -- -----------------------------------------------------------------------
    -- Footer (pagination bar) touch zones.
    --
    -- WHY: BlockNavbarTap and HSSwipe live in ges_events and cover the whole
    -- screen, so child widgets (chevron buttons, bar_input) never receive taps
    -- or swipes that originate over the footer strip.
    --
    -- Registering touch zones on HomescreenWidget itself fixes this: touch zones
    -- are checked before ges_events in InputContainer:onGesture(), so these
    -- handlers always win for gestures that land in the footer area.
    --
    --   simpleui_hs_footer_tap   → overrides BlockNavbarTap
    --   simpleui_hs_footer_swipe → overrides HSSwipe
    -- -----------------------------------------------------------------------
    -- The swipe zone must cover BOTH the navbar strip (TOTAL_H) AND the
    -- pagination footer painted above it (chevrons or dots).  The tallest
    -- possible footer is the chevron bar: icon + 8 px padding.  We add the
    -- dot-bar height (28 px) as a safe upper-bound that covers both modes.
    local pag_footer_h   = Bottombar.getPaginationIconSize() + Screen:scaleBySize(8)
    local combined_h     = Bottombar.TOTAL_H() + pag_footer_h
    local footer_ratio_y = (sh - combined_h) / sh
    local footer_ratio_h = combined_h / sh
    local self_ref = self

    self:registerTouchZones({
        {
            id          = "simpleui_hs_footer_tap",
            ges         = "tap",
            screen_zone = {
                ratio_x = 0, ratio_y = footer_ratio_y,
                ratio_w = 1, ratio_h = footer_ratio_h,
            },
            overrides = { "BlockNavbarTap" },
            handler = function(ges)
                if _hasModalOnTop(self_ref) then return false end
                -- Corner FM gestures keep priority (bottom-left/right zones
                -- configured by the user in the gestures plugin).
                if _fmGestureAction(ges) then return true end

                local footer_bc = self_ref._footer_bc
                if not footer_bc or footer_bc.dimen.h == 0 then return false end

                -- Dot mode: bar_input owns onTapDot — forward the gesture.
                local navpager_on  = Config.isNavpagerEnabled()
                local dot_pager_on = Config.isDotPagerEnabled()
                if navpager_on or dot_pager_on then
                    local fd = self_ref._footer_dot
                    if fd and fd.bar_input then
                        return fd.bar_input:handleEvent(Event:new("Gesture", ges))
                    end
                    return false
                end

                -- Chevron mode: hit-test each button by its painted dimen.
                local fc = self_ref._footer_chevron
                if fc then
                    local buttons = { fc.btn_first, fc.btn_prev, fc.btn_next, fc.btn_last }
                    for _, btn in ipairs(buttons) do
                        local d = btn.dimen
                        if d and ges.pos and ges.pos:intersectWith(d) then
                            if btn.enabled ~= false then btn.callback() end
                            return true  -- always consume inside a button area
                        end
                    end
                end
                return false
            end,
        },
        {
            id          = "simpleui_hs_footer_swipe",
            ges         = "swipe",
            screen_zone = {
                ratio_x = 0, ratio_y = footer_ratio_y,
                ratio_w = 1, ratio_h = footer_ratio_h,
            },
            overrides = { "HSSwipe" },
            handler = function(ges)
                if _hasModalOnTop(self_ref) then return false end
                -- Bottom-edge E/W gestures configured in the gestures plugin take
                -- priority over pagination so they behave like in the FM.
                if _fmGestureAction(ges) then return true end

                local footer_bc = self_ref._footer_bc
                if not footer_bc or footer_bc.dimen.h == 0 then return false end

                local dir   = ges and ges.direction
                local cur   = self_ref._current_page or 1
                local total = self_ref._total_pages  or 1
                if total <= 1 then return false end

                local new_page
                if dir == "west" then
                    new_page = cur < total and cur + 1 or 1
                elseif dir == "east" then
                    new_page = cur > 1 and cur - 1 or total
                else
                    return false  -- north/south swipes: do not consume
                end

                if new_page ~= cur then
                    self_ref._current_page = new_page
                    self_ref.page          = new_page
                    self_ref:_refresh(true)
                end
                return true
            end,
        },
    })

    -- -----------------------------------------------------------------------
    -- Priority gesture zones — top and bottom strips.
    --
    -- HSDoubleTap, HSTwoFingerTap, HSTwoFingerSwipe, HSMultiswipe, HSSpread,
    -- HSPinch, HSRotate and HSHold live in ges_events (fullscreen, low
    -- priority).  Registering the same gesture types as touch zones on the
    -- top and bottom strips gives them priority over the fullscreen ges_events
    -- handlers, mirroring how the gestures.koplugin overrides filemanager_tap /
    -- filemanager_swipe in the file manager.
    --
    -- Zone geometry:
    --   top  — same ratio_h as the menu tap zone (DTAP_ZONE_MENU.h), so the
    --           strip aligns with the existing simpleui_hs_menu_tap zone.
    --   bottom — same combined_h already computed for the footer zones above,
    --            so the strip aligns with simpleui_hs_footer_tap / _swipe.
    --
    -- All handlers simply delegate to _fmGestureAction.  The overrides list
    -- names every ges_events handler that covers the same gesture type so that
    -- the touch zone wins inside these strips.
    -- -----------------------------------------------------------------------
    local top_ratio_h    = (DTAP_ZONE_MENU and DTAP_ZONE_MENU.h) or 0.1

    local _gesture_types = {
        { ges = "double_tap",       id_suffix = "double_tap",        override = "HSDoubleTap"      },
        { ges = "two_finger_tap",   id_suffix = "two_finger_tap",    override = "HSTwoFingerTap"   },
        { ges = "two_finger_swipe", id_suffix = "two_finger_swipe",  override = "HSTwoFingerSwipe" },
        { ges = "multiswipe",       id_suffix = "multiswipe",        override = "HSMultiswipe"     },
        { ges = "spread",           id_suffix = "spread",            override = "HSSpread"         },
        { ges = "pinch",            id_suffix = "pinch",             override = "HSPinch"          },
        { ges = "rotate",           id_suffix = "rotate",            override = "HSRotate"         },
        { ges = "hold",             id_suffix = "hold",              override = "HSHold"           },
    }

    local priority_zones = {}
    for _, gt in ipairs(_gesture_types) do
        -- top strip
        priority_zones[#priority_zones + 1] = {
            id          = "simpleui_hs_top_" .. gt.id_suffix,
            ges         = gt.ges,
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = top_ratio_h,
            },
            overrides = { gt.override },
            handler   = function(ges) return _hasModalOnTop(self) and false or _fmGestureAction(ges) end,
        }
        -- bottom strip
        priority_zones[#priority_zones + 1] = {
            id          = "simpleui_hs_bottom_" .. gt.id_suffix,
            ges         = gt.ges,
            screen_zone = {
                ratio_x = 0, ratio_y = footer_ratio_y,
                ratio_w = 1, ratio_h = footer_ratio_h,
            },
            overrides = { gt.override },
            handler   = function(ges) return _hasModalOnTop(self) and false or _fmGestureAction(ges) end,
        }
    end
    self:registerTouchZones(priority_zones)
end

-- ---------------------------------------------------------------------------
-- _vspan — pool helper (per-instance, freed on close)
-- ---------------------------------------------------------------------------
function HomescreenWidget:_vspan(px)
    local pool = self._vspan_pool
    if not pool[px] then pool[px] = VerticalSpan:new{ width = px } end
    return pool[px]
end

-- ---------------------------------------------------------------------------
-- _buildContent — builds page content using module registry
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- _initLayout — builds the persistent widget tree (called once per show).
-- Structure mirrors Menu: fixed OverlapGroup with a persistent body group and
-- a persistent footer (BottomContainer) that are mutated in-place on page turns.
-- ---------------------------------------------------------------------------
function HomescreenWidget:_initLayout()
    local sw        = Screen:getWidth()
    local sh        = Screen:getHeight()
    local content_h = self._navbar_content_h or sh
    local side_off  = SIDE_PAD
    local inner_w   = sw - side_off * 2

    self._layout_sw       = sw
    self._layout_content_h = content_h
    self._layout_inner_w   = inner_w

    -- Persistent body VerticalGroup — cleared and repopulated by _updatePage().
    local body = VerticalGroup:new{ align = "left" }
    self._body = body

    -- Outer frames — fixed, never rebuilt.
    local content_widget = FrameContainer:new{
        bordersize = 0, padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen      = Geom:new{ w = inner_w, h = content_h },
        body,
    }
    local outer = FrameContainer:new{
        bordersize   = 0, padding = 0,
        padding_left = side_off, padding_right = side_off,
        background   = Blitbuffer.COLOR_WHITE,
        dimen        = Geom:new{ w = sw, h = content_h },
        content_widget,
    }

    -- Navigation callback shared by both footer types.
    local self_ref = self
    local function _goto(page)
        local total = self_ref._total_pages or 1
        local target
        if     page == "prev" then target = (self_ref._current_page or 1) - 1
        elseif page == "next" then target = (self_ref._current_page or 1) + 1
        elseif page == "last" then target = total
        else                       target = page
        end
        target = math.max(1, math.min(target, total))
        if target ~= self_ref._current_page then
            self_ref._current_page = target
            self_ref:_refresh(true)  -- calls _updatePage + setDirty, consistent with navpager/swipe
        end
    end

    -- Build footer descriptors — persistent, never recreated.
    self._footer_chevron = buildChevronFooter(_goto)
    self._footer_dot     = buildDotFooter(_goto)
    -- Placeholder used when footer is hidden — allocated once, reused every hide.
    -- This keeps _updateFooter allocation-free on the no-footer path.
    self._footer_hidden_span = VerticalSpan:new{ width = 0 }

    -- Persistent BottomContainer wrapping the active footer widget.
    -- We swap its child [1] in _updateFooter() — zero allocation.
    local footer_bc = BottomContainer:new{
        dimen = Geom:new{ w = sw, h = content_h },
        self._footer_chevron.widget,  -- initial child, replaced as needed
    }
    self._footer_bc = footer_bc

    -- OverlapGroup: outer content + footer overlay.
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
-- _buildCtx — constructs the module build context (shared between
-- _initLayout and _updatePage). Handles book prefetch and DB connection.
-- ---------------------------------------------------------------------------
function HomescreenWidget:_buildCtx()
    local inner_w = self._layout_inner_w or (Screen:getWidth() - SIDE_PAD * 2)

    local mod_c  = Registry.get("currently")
    local mod_r  = Registry.get("recent")
    local mod_cd = Registry.get("coverdeck")
    local show_c = mod_c and Registry.isEnabled(mod_c, PFX)
    local show_r = (mod_r and Registry.isEnabled(mod_r, PFX))
                or (mod_cd and Registry.isEnabled(mod_cd, PFX))

    if not self._cached_books_state then
        local SH = _getBookShared()
        if SH then
            if show_c or show_r then
                -- coverdeck exibe até 5 slots (center + 2 side + 2 far) que podem
                -- mapear para qualquer posição dentro de MAX_RECENT_FPS=10.
                -- Prefetch 10 entradas para que ctx.prefetched cubra todos os slots
                -- e getBookData() nunca caia no slow-path (DS.open síncrono) durante build().
                local max_recent = (mod_cd and Registry.isEnabled(mod_cd, PFX)) and 10 or 5
                self._cached_books_state = SH.prefetchBooks(show_c, show_r, max_recent)
                if Config.cover_extraction_pending then
                    self:_scheduleCoverPoll()
                end
            else
                self._cached_books_state = { current_fp = nil, recent_fps = {}, prefetched_data = {} }
            end
        else
            logger.warn("simpleui: homescreen: cannot load module_books_shared")
            self._cached_books_state = { current_fp = nil, recent_fps = {}, prefetched_data = {} }
        end
    end

    local bs          = self._cached_books_state
    local wants_books = show_c or show_r
    local mod_rg      = Registry.get("reading_goals")
    local mod_rs      = Registry.get("reading_stats")
    local wants_stats = (mod_rg and Registry.isEnabled(mod_rg, PFX))
        or (mod_rs and mod_rs.isEnabled and mod_rs.isEnabled(PFX))
    local wants_db    = wants_books or wants_stats

    if wants_db and not self._db_conn then
        self._db_conn = Config.openStatsDB()
    end

    -- Pre-fetch all numeric stats via the shared provider when any stats
    -- module is enabled. SP.get() runs at most 2 DB roundtrips (time-series
    -- + streak) and one sidecar pass (books_year + books_total), then caches
    -- the result for the rest of the calendar day.
    -- ctx.stats is nil when no stats module is active — consumers must guard.
    local stats_data = nil
    if wants_stats then
        local SP = _getStatsProvider()
        if SP then
            local year_str = os.date("%Y")
            stats_data = SP.get(self._db_conn, year_str)
            -- If the shared connection hit a fatal error inside SP.get(),
            -- propagate the fatal flag and drop the connection so the next
            -- render opens a fresh one.
            if stats_data and stats_data.db_conn_fatal then
                logger.warn("simpleui: homescreen: StatsProvider reported fatal DB error — dropping connection")
                if self._db_conn then
                    pcall(function() self._db_conn:close() end)
                    self._db_conn = nil
                end
                -- Propagate so _updatePage's post-build guard also fires
                -- (covers the module_currently fetchBookStats path too).
                stats_data.db_conn_fatal = true
            end
        end
    end

    -- Pre-compute coverdeck book stats for the current centre cover.
    -- M.build() would otherwise run fetchBookStats() synchronously while
    -- assembling the widget tree, blocking the UI thread.
    -- We do it here, after the DB connection is open, using the md5 that is
    -- already in prefetched_data (zero extra IO).  M.build() checks
    -- ctx.coverdeck_center_stats before falling back to its own query.
    --
    -- We use recent_fps[1] as the best-effort centre approximation; the
    -- coverdeck may adjust curIdx based on the saved SETTING_FP, but in the
    -- common case (first render after closing a book) fps[1] == curIdx==1.
    -- A mismatch is harmless: M.build() will fall back to its own query for
    -- that one render and the result ends up in _bstats_cache for next time.
    local coverdeck_center_stats = nil
    if mod_cd and Registry.isEnabled(mod_cd, PFX) and self._db_conn then
        local center_fp = bs.recent_fps and bs.recent_fps[1]
        local pe = center_fp and bs.prefetched_data and bs.prefetched_data[center_fp]
        local center_md5 = type(pe) == "table" and pe.partial_md5_checksum
        if center_md5 then
            local cd_mod = package.loaded["desktop_modules/module_coverdeck"]
            if cd_mod and cd_mod.fetchBookStatsForCtx then
                coverdeck_center_stats = {
                    fp    = center_fp,
                    stats = cd_mod.fetchBookStatsForCtx(center_md5, self._db_conn),
                }
            end
        end
    end

    local self_ref = self
    return {
        pfx           = PFX,
        pfx_qa        = PFX_QA,
        close_fn      = function() self_ref:onClose() end,
        open_fn       = function(fp, pos0, page) openBook(fp, pos0, page) end,
        on_qa_tap     = function(aid) if self_ref._on_qa_tap then self_ref._on_qa_tap(aid) end end,
        on_goal_tap   = function() if self_ref._on_goal_tap then self_ref._on_goal_tap() end end,
        db_conn       = wants_db and self._db_conn or nil,
        db_conn_fatal = false,
        -- Pre-fetched stats from StatsProvider. Nil when no stats module is active.
        -- reading_stats and reading_goals read ctx.stats.* — no DB logic of their own.
        stats                  = stats_data,
        coverdeck_center_stats = coverdeck_center_stats,
        vspan_pool    = self._vspan_pool,
        prefetched    = bs.prefetched_data,
        current_fp    = bs.current_fp,
        recent_fps    = bs.recent_fps,
        sectionLabel  = sectionLabel,
        _hs_widget    = self,
        -- expose for empty-state check
        _show_c = show_c, _show_r = show_r,
        _has_content = (bs.current_fp and show_c) or (#bs.recent_fps > 0 and show_r),
    }
end

-- ---------------------------------------------------------------------------
-- _updateFooter — mutates the persistent footer in-place (zero allocation).
-- Mirrors Menu:updatePageInfo() exactly.
-- ---------------------------------------------------------------------------
-- topbar_on is passed in from _updatePage (already read there) to avoid a
-- redundant G_reader_settings call on every page turn.
function HomescreenWidget:_updateFooter(current_page, total_pages, topbar_on)
    local footer_bc = self._footer_bc
    if not footer_bc then return end

    local sw        = self._layout_sw or Screen:getWidth()
    local content_h = self._layout_content_h or (self._navbar_content_h or Screen:getHeight())
    -- Visibility rules for the homescreen footer:
    -- • Navpager on          → dot pager always (arrows handled externally)
    -- • Geral = Predefinido  → show footer (dots or koreader chevrons)
    -- • Geral = Oculto + Dot Pager → still show dots (user chose dots explicitly)
    -- • Geral = Oculto + KOReader  → hide footer completely
    local navpager_on   = Config.isNavpagerEnabled()
    local dot_pager_on  = Config.isDotPagerEnabled()  -- navbar_dotpager_always
    local pag_visible   = G_reader_settings:nilOrTrue("navbar_pagination_visible")
    local hs_pag_hidden = G_reader_settings:isTrue("navbar_homescreen_pagination_hidden")

    -- Footer is shown when:
    --   a) navpager is on (dot pager shown alongside navpager arrows), OR
    --   b) general pagination is visible (predefinido), OR
    --   c) general pagination is hidden BUT dot pager is selected (dots survive hide)
    -- In all cases, hidden if the user explicitly hid the bar on the homescreen.
    local show_bar = not hs_pag_hidden
        and total_pages > 1 and (navpager_on or pag_visible or dot_pager_on)
    local use_dots  = show_bar and (navpager_on or dot_pager_on)

    if not show_bar then
        -- Hide footer: BottomContainer requires self[1] to be a valid widget —
        -- setting it to nil causes a paintTo crash ("attempt to index a nil value").
        -- Reuse the pre-allocated zero-height span from _initLayout (zero alloc).
        footer_bc.dimen.h = 0
        footer_bc[1] = self._footer_hidden_span
        return
    end

    -- Restore full height.
    footer_bc.dimen.h = content_h

    if use_dots then
        -- Dot mode: mutate DotWidget fields, resize CenterContainer width.
        local fd = self._footer_dot
        local dw = fd.dot_widget
        local total_w = total_pages * fd.touch_w
        dw.current_page = current_page
        dw.total_pages  = total_pages
        -- Resize bar_input and centred to match new total_pages.
        fd.bar_input.dimen.w  = total_w
        fd.bar_input.dimen.h  = dw.bar_h
        fd.widget.dimen.w     = sw
        footer_bc[1]          = fd.widget
    else
        -- Chevron mode: setText + enableDisable, exactly as Menu does.
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
-- _getHsCtxMenu — lazy-initialised context table for module settings menus.
-- Elevated from a per-_updatePage closure to a widget method so the closure
-- object is not reallocated on every page-turn; the result is cached in
-- self._hs_ctx_menu after the first call.
-- ---------------------------------------------------------------------------
function HomescreenWidget:_getHsCtxMenu()
    if self._hs_ctx_menu then return self._hs_ctx_menu end
    local c = setmetatable({
        pfx           = PFX,
        pfx_qa        = PFX_QA,
        refresh       = function()
            if Homescreen._instance then Homescreen._instance:_refresh(false) end
        end,
        UIManager     = UIManager,
        _             = _,
        MAX_LABEL_LEN = Config.MAX_LABEL_LEN,
        _cover_picker = nil,
    }, {
        __index = function(t, k)
            if k == "InfoMessage" then
                local v = require("ui/widget/infomessage")
                rawset(t, k, v); return v
            elseif k == "SortWidget" then
                local v = require("ui/widget/sortwidget")
                rawset(t, k, v); return v
            end
        end,
    })
    self._hs_ctx_menu = c
    return c
end

-- ---------------------------------------------------------------------------
-- _onHoldModRelease — shared handler for module long-press settings menus.
-- Stored once on HomescreenWidget; each wrapper sets wrapper._sui_mod so this
-- single function knows which module was held, eliminating the per-module
-- per-page-turn closure allocation that the old inline approach caused.
-- ---------------------------------------------------------------------------
function HomescreenWidget:_onHoldModRelease(wrapper)
    -- Honour the "Settings on Long Tap" toggle.
    -- When the setting is explicitly false the hold gesture is silently consumed
    -- (returns true to prevent propagation) without opening the menu.
    if not G_reader_settings:nilOrTrue("navbar_homescreen_settings_on_hold") then
        return true
    end
    local mod      = wrapper._sui_mod   -- set on the wrapper InputContainer
    local hs       = wrapper._sui_hs    -- back-reference to HomescreenWidget
    if not mod or not hs then return true end
    local Topbar   = require("sui_topbar")
    local topbar_h = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
                     and Topbar.TOTAL_TOP_H() or 0
    local _tr = _
    UI.showSettingsMenu(
        mod.name or mod.id,
        function()
            local ctx_menu = hs:_getHsCtxMenu()
            local items    = mod.getMenuItems(ctx_menu)
            local gap_item = Config.makeGapItem({
                text_func = function()
                    local pct = Config.getModuleGapPct(mod.id, PFX)
                    return string.format(_tr("Top Margin  (%d%%)"), pct)
                end,
                title   = mod.name or mod.id,
                info    = _tr("Vertical space above this module.\n100% is the default spacing."),
                get     = function() return Config.getModuleGapPct(mod.id, PFX) end,
                set     = function(v) Config.setModuleGap(v, mod.id, PFX) end,
                refresh = ctx_menu.refresh,
            })
            items[#items + 1] = gap_item
            return items
        end,
        topbar_h,
        Screen:getHeight(),
        Bottombar.TOTAL_H()
    )
    return true
end

-- ---------------------------------------------------------------------------
-- _makeModWrapper — returns a pooled InputContainer that wraps a module widget
-- and handles hold-to-settings. Wrappers are indexed by mod.id in
-- self._wrapper_pool so they are allocated once per visible module per
-- Homescreen lifetime rather than once per page turn.
--
-- The wrapper's child (slot [1]) and dimen.h are updated in-place when the
-- same module appears on a new page turn with a different widget height.
-- _sui_mod and _sui_hs are plain fields — no closures captured.
-- ---------------------------------------------------------------------------
function HomescreenWidget:_makeModWrapper(mod, widget, inner_w)
    local pool = self._wrapper_pool
    local w    = pool[mod.id]
    local h    = widget:getSize().h

    if w then
        -- Reuse: update child and height in-place.
        w[1]       = widget
        w.dimen.w  = inner_w
        w.dimen.h  = h
        w._sui_mod = mod   -- mod table is stable (from Registry), safe to reuse
    else
        w = InputContainer:new{
            dimen    = Geom:new{ w = inner_w, h = h },
            widget,
            _sui_mod = mod,
            _sui_hs  = self,
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
        -- onHoldMod just consumes the event so hold doesn't propagate.
        -- onHoldModRelease delegates to the shared method on HomescreenWidget
        -- via the _sui_hs back-reference — zero new closures per page turn.
        function w:onHoldMod()
            if not G_reader_settings:nilOrTrue("navbar_homescreen_settings_on_hold") then
                return  -- do not consume; hold_release will not fire on this wrapper
            end
            return true
        end
        function w:onHoldModRelease() return self._sui_hs:_onHoldModRelease(self) end
        pool[mod.id] = w
    end
    return w
end

-- ---------------------------------------------------------------------------
-- _updatePage — clears body, repopulates the current page slice, updates
-- footer in-place. Called on every page turn (keep_cache=true) and on full
-- refreshes (keep_cache=false). Zero widget allocation for page turns.
-- ---------------------------------------------------------------------------
-- _updatePage(keep_cache, books_only)
--   keep_cache  = true  → page-turn: nothing is cleared, ctx reused as-is.
--   books_only  = true  → only book data changed; clear _cached_books_state so
--                         _buildCtx() calls prefetchBooks() for fresh data, but
--                         preserve _ctx_cache structure and _enabled_mods_cache
--                         to skip the Registry lookups and module-list scan.
function HomescreenWidget:_updatePage(keep_cache, books_only)
    if not keep_cache then
        self._cached_books_state = nil
        if not books_only then
            -- Full invalidation: module config or layout changed.
            self._enabled_mods_cache = nil
            self._ctx_cache          = nil
        end
        -- books_only: _cached_books_state is cleared above so _buildCtx()
        -- will call prefetchBooks() for fresh sidecar data. _ctx_cache and
        -- _enabled_mods_cache are kept — module set hasn’t changed.
    end

    -- _buildCtx() calls Registry.get/isEnabled and may prefetch books.
    -- On page turns (keep_cache=true) none of that data changes — reuse the
    -- cached ctx to avoid the redundant lookups on every swipe.
    -- On books_only, _ctx_cache is preserved but _cached_books_state is nil,
    -- so _buildCtx() runs to fetch fresh book data while reusing db_conn etc.
    local ctx
    if keep_cache and self._ctx_cache then
        ctx = self._ctx_cache
    else
        ctx = self:_buildCtx()
        self._ctx_cache = ctx
    end
    local inner_w   = self._layout_inner_w or (Screen:getWidth() - SIDE_PAD * 2)
    local body      = self._body
    if not body then return end

    -- Module list cache — rebuilt whenever module_order changes (including page breaks).
    local raw_order = Registry.loadOrder(PFX)
    if not self._enabled_mods_cache
       or self._enabled_mods_cache.raw_order ~= raw_order then
        -- Split raw order into pages using __page_break__ sentinels.
        local pages_by_id = splitOrderIntoPages(raw_order)

        -- Build the flat enabled-mod list and per-page mod lists in one pass.
        local has_book_mod  = false
        local mod_gaps      = {}
        local pages_of_mods = {}   -- list of pages, each a list of mod objects

        for _, page_ids in ipairs(pages_by_id) do
            local page_mods = {}
            for _, mod_id in ipairs(page_ids) do
                local mod = Registry.get(mod_id)
                if mod and Registry.isEnabled(mod, PFX) then
                    page_mods[#page_mods + 1] = mod
                    mod_gaps[mod_id] = Config.getModuleGapPx(mod_id, PFX, MOD_GAP)
                    if mod_id == "currently" or mod_id == "recent" or mod_id == "coverdeck" then
                        has_book_mod = true
                    end
                end
            end
            -- Always add the page, even if empty, to preserve blank pages.
            pages_of_mods[#pages_of_mods + 1] = page_mods
        end
        if #pages_of_mods == 0 then pages_of_mods[1] = {} end

        -- Extend to match the user-chosen number of pages (adds blank pages if needed).
        local chosen_pages = G_reader_settings:readSetting(PFX .. "homescreen_num_pages")
        if chosen_pages and chosen_pages > #pages_of_mods then
            for _ = #pages_of_mods + 1, chosen_pages do
                pages_of_mods[#pages_of_mods + 1] = {}
            end
        end

        -- Safety net: ensure coverdeck is visible when absent from saved order.
        do
            local cd = Registry.get("coverdeck")
            if cd and Registry.isEnabled(cd, PFX) then
                local found = false
                for _, pg in ipairs(pages_of_mods) do
                    for _, m in ipairs(pg) do
                        if m.id == "coverdeck" then found = true; break end
                    end
                    if found then break end
                end
                if not found then
                    -- Insert coverdeck after "recent" or "currently" on page 1.
                    local insert_at = #pages_of_mods[1] + 1
                    for i, m in ipairs(pages_of_mods[1]) do
                        if m.id == "recent"    then insert_at = i + 1; break end
                        if m.id == "currently" then insert_at = i + 1 end
                    end
                    table.insert(pages_of_mods[1], insert_at, cd)
                    mod_gaps["coverdeck"] = Config.getModuleGapPx("coverdeck", PFX, MOD_GAP)
                    has_book_mod = true
                end
            end
        end

        -- Build flat enabled_mods list (needed by existing book-context code).
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
            raw_order     = raw_order,
        }
    end
    local enabled_mods  = self._enabled_mods_cache.mods
    local has_book_mod  = self._enabled_mods_cache.has_book_mod
    local total_pages   = self._enabled_mods_cache.total_pages
    local mod_gaps      = self._enabled_mods_cache.mod_gaps
    local pages_of_mods = self._enabled_mods_cache.pages_of_mods

    -- Clamp page.
    if self._current_page > total_pages then self._current_page = total_pages end
    if self._current_page < 1           then self._current_page = 1           end
    self._total_pages = total_pages
    self.page         = self._current_page
    self.page_num     = total_pages

    -- Empty state widget.
    local empty_widget
    if (ctx._show_c or ctx._show_r) and not ctx._has_content and not has_book_mod then
        empty_widget = buildEmptyState(inner_w, _EMPTY_H)
    end

    -- ── Clear body and repopulate the current page slice ─────────────────────
    -- Mirrors Menu:updateItems() — clear the group, then add new children.
    -- For page turns this is the only allocation: the module widgets themselves.
    body:clear()

    local topbar_on = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
    local top_pad   = topbar_on and MOD_GAP or (MOD_GAP * 2)
    -- topbar_on is passed to _updateFooter to avoid re-reading the same setting.
    body[#body+1] = self:_vspan(top_pad)

    self._header_body_idx   = nil
    self._header_inner_w    = inner_w
    self._header_body_ref   = body
    self._header_is_wrapped = false
    self._clock_body_idx    = nil
    self._clock_body_ref    = body
    self._clock_is_wrapped  = false

    -- ── Keyboard navigation: rebuild the book index and inject focus state ───
    -- Flat ordered list of book filepaths across currently + recent modules.
    -- Built here (once per _updatePage) so onHSFocusUp/Down/Left/Right
    -- have a stable index to increment/decrement against.
    local _kb_books = {}
    self._kb_first_rec_idx = nil

    -- Populate ctx focus flags so modules can render the focus border.
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

    local cur_page_mods = pages_of_mods[self._current_page] or {}
    local first_mod     = true
    local page_has_covers = false

    for _, mod in ipairs(cur_page_mods) do
        -- Detect cover modules in the same pass — avoids a second loop.
        if _COVER_MOD_IDS[mod.id] then page_has_covers = true end
        local ok_w, widget = pcall(mod.build, inner_w, ctx)
        if not ok_w then
            logger.warn("simpleui homescreen: build failed for "
                        .. tostring(mod.id) .. ": " .. tostring(widget))
        elseif widget then
            if first_mod then
                first_mod = false
            else
                local gap_px = mod_gaps[mod.id] or MOD_GAP
                body[#body+1] = self:_vspan(gap_px)
            end
            if mod.label then body[#body+1] = sectionLabel(mod.label, inner_w) end
            local has_menu = type(mod.getMenuItems) == "function"
            if mod.id == "header" then
                self._header_body_idx   = #body + 1
                self._header_is_wrapped = has_menu
            end
            if mod.id == "clock" then
                self._clock_body_idx   = #body + 1
                self._clock_body_ref   = body
                self._clock_is_wrapped = has_menu
            end
            if has_menu then
                -- Pooled wrapper — allocated once per mod.id per Homescreen
                -- lifetime; updated in-place on subsequent page turns.
                body[#body+1] = self:_makeModWrapper(mod, widget, inner_w)
            else
                body[#body+1] = widget
            end
        end
    end

    if ctx.db_conn_fatal and self._db_conn then
        logger.warn("simpleui: homescreen: fatal DB error detected — dropping shared connection")
        pcall(function() self._db_conn:close() end)
        self._db_conn = nil
    end

    if empty_widget then body[#body+1] = empty_widget end

    -- Dithering hint for e-ink displays: UIManager checks widget.dithered on
    -- setDirty to trigger a proper image refresh cycle. Without this, cover
    -- bitmaps get ghosting/artefacts after a swipe because the "ui" refresh
    -- mode does not do a full pixel cycle. Flag was set inside the build loop above.
    self.dithered = page_has_covers or nil

    -- Update footer in-place (zero allocation on page turns).
    self:_updateFooter(self._current_page, total_pages, topbar_on)

    -- Navpager arrows (external to the layout).
    _updateNavpagerForHS(self._current_page, total_pages)

    -- Clock synchronisation after page turn.
    -- When the clock module is on the current page (_clock_body_idx ~= nil),
    -- reschedule the tick timer from this exact moment.  This guarantees that
    -- the next tick fires precisely at the next minute boundary relative to
    -- os.time() *now*, keeping module_clock in phase with the status-bar clock
    -- regardless of which homescreen page the user was on in between.
    -- When the clock is not on the current page (_clock_body_idx == nil) the
    -- existing timer keeps running and will update the widget the next time
    -- _updatePage places it back on screen, so no action is needed there.
    if self._clock_body_idx ~= nil then
        local ClockMod = Registry.get("clock")
        if ClockMod and ClockMod.scheduleRefresh then
            ClockMod.scheduleRefresh(self)
        end
    end
end

-- ---------------------------------------------------------------------------
-- _refresh — page turns call _updatePage directly (synchronous, zero alloc).
-- Config/module changes still debounce at 0.15s to batch rapid menu toggles.
-- ---------------------------------------------------------------------------
-- _refresh(keep_cache, books_only)
--   keep_cache  = true  → page-turn path: in-place _updatePage, no debounce.
--   books_only  = true  → only book data changed (reader closed, stats updated);
--                         preserve _ctx_cache and _enabled_mods_cache so the
--                         Registry lookups and module-list scan are not repeated.
--                         Only _cached_books_state is cleared, forcing a fresh
--                         prefetchBooks() on the next _buildCtx() call.
function HomescreenWidget:_refresh(keep_cache, books_only)
    if keep_cache and self._body then
        -- Page turn: body already exists — mutate in-place immediately.
        -- No debounce needed: same pattern as Menu:onGotoPage → updateItems.
        self:_updatePage(true)
        -- setDirty(self) covers the full screen (self.dimen = screen size) and
        -- recurses into all children including navbar_container and its bar/arrows.
        -- A prior double-dirty (navbar_container + self) was queuing two separate
        -- e-ink refresh cycles; a single setDirty(self) is sufficient.
        UIManager:setDirty(self, "ui")
        return
    end
    -- Config/data change: invalidate caches and debounce to coalesce bursts.
    self._cached_books_state = nil
    -- books_only: preserve the module-list and ctx structure caches — only
    -- the book data (sidecar / prefetchBooks) has changed, not the set of
    -- enabled modules or their configuration.
    if not books_only then
        self._enabled_mods_cache = nil
        self._ctx_cache          = nil
    end
    if self._refresh_scheduled then return end
    self._refresh_scheduled = true
    local token = {}
    self._pending_refresh_token = token
    -- Use scheduleIn(0) to defer to the next event-loop tick rather than a
    -- fixed wall-clock delay. This guarantees that:
    --   (a) any pending UIManager operations from the current tick (FM init,
    --       first setDirty) are enqueued before our _updatePage runs, so we
    --       don’t race with the FM’s first paint;
    --   (b) rapid back-to-back _refresh(false) calls still coalesce — only
    --       the first scheduleIn(0) is registered; subsequent calls return
    --       early on the _refresh_scheduled guard above.
    -- Capture books_only in the closure so _updatePage receives it even
    -- though the debounce fires asynchronously in the next event-loop tick.
    local _books_only = books_only
    UIManager:scheduleIn(0, function()
        if self._pending_refresh_token ~= token then return end
        if Homescreen._instance ~= self then return end
        self._refresh_scheduled = false
        if not self._navbar_container then return end
        self:_updatePage(false, _books_only)
        UIManager:setDirty(self, "ui")
    end)
end

-- Immediate full rebuild — bypasses debounce. Used by showSettingsMenu's
-- onCloseWidget to guarantee the HS reflects changes before the next paint.
function HomescreenWidget:_refreshImmediate(keep_cache)
    self._pending_refresh_token = {}
    self._refresh_scheduled     = false
    if not keep_cache then
        self._cached_books_state = nil
        self._enabled_mods_cache = nil
        self._ctx_cache          = nil
    end
    if not self._navbar_container then return end
    self:_updatePage(keep_cache or false)
    UIManager:setDirty(self, "ui")
end

-- ---------------------------------------------------------------------------
-- Cover extraction poll
-- ---------------------------------------------------------------------------
function HomescreenWidget:_scheduleCoverPoll(attempt)
    attempt = (attempt or 0) + 1
    -- Cap at 20 attempts: with exponential backoff this covers ~60s total
    -- (0.5+1+2+4+5+5+... = well over a minute), vs the old 60×0.5s=30s flat poll.
    if attempt > 20 then Config.cover_extraction_pending = false; return end
    local bim = Config.getBookInfoManager()
    local self_ref = self
    local timer
    timer = function()
        self_ref._cover_poll_timer = nil
        if not bim or not bim:isExtractingInBackground() then
            Config.cover_extraction_pending = false
            if Homescreen._instance == self_ref then
                -- Covers changed but the book list data (DB, file paths) did not.
                -- _refresh(true) keeps the cached book state and does zero DB queries;
                -- _refresh(false) would invalidate everything and re-run all SQL.
                self_ref:_refresh(true)
            end
        else
            self_ref:_scheduleCoverPoll(attempt)
        end
    end
    self._cover_poll_timer = timer
    -- Exponential backoff: 0.5s, 1s, 2s, 4s, then capped at 5s.
    -- Reduces the number of setDirty calls during active cover extraction
    -- compared to the previous fixed 0.5s interval.
    local delay = math.min(0.5 * (2 ^ (attempt - 1)), 5.0)
    UIManager:scheduleIn(delay, timer)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function HomescreenWidget:onShow()
    -- _navbar_content_h is now set by patches.lua before onShow fires,
    -- so we can build the persistent layout tree here for the first time.
    if self._stats_need_refresh or Homescreen._stats_need_refresh then
        self._stats_need_refresh       = nil
        Homescreen._stats_need_refresh = nil
        -- Single invalidation point: StatsProvider owns the shared cache.
        -- Both reading_stats and reading_goals delegate their invalidateCache()
        -- here, so one call covers both.
        local SP = package.loaded["desktop_modules/module_stats_provider"]
        if SP then SP.invalidate() end
    end
    if self._navbar_container then
        -- Build the fixed OverlapGroup tree once and slot it in.
        local overlap = self:_initLayout()
        -- Preserve overlap_offset set by wrapWithNavbar (topbar offset).
        local old = self._navbar_container[1]
        if old and old.overlap_offset then
            overlap.overlap_offset = old.overlap_offset
        end
        self._navbar_container[1] = overlap
        -- Populate the first page.
        self:_updatePage(true)
        UIManager:setDirty(self, "ui")
        -- Start the clock timer only once the layout exists — firing against a nil
        -- _navbar_container would be a no-op at best, a crash at worst.
        -- Only module_clock's chain is started here; _scheduleClockRefresh ran a
        -- parallel chain doing identical work (double refresh per minute, doubled
        -- suspend-race surface) and has been removed.
        local ClockMod = Registry.get("clock")
        if ClockMod and Registry.isEnabled(ClockMod, PFX) and ClockMod.scheduleRefresh then
            ClockMod.scheduleRefresh(self)
        end
    end
end

function HomescreenWidget:onClose()
    UIManager:close(self)
    return true
end

function HomescreenWidget:onSuspend()
    self._suspended = true
    -- Cancel the cover poll timer — cover extraction is paused by the OS
    -- during suspend anyway, so polling serves no purpose.
    if self._cover_poll_timer then
        UIManager:unschedule(self._cover_poll_timer)
        self._cover_poll_timer = nil
    end
    -- Cancel the module_clock timer (the only clock chain remaining after
    -- removing the redundant _scheduleClockRefresh internal chain).
    local ClockMod = Registry.get("clock")
    if ClockMod and ClockMod.cancelRefresh then ClockMod.cancelRefresh() end
end

function HomescreenWidget:onResume()
    self._suspended = false
    -- Cache invalidation and the UI rebuild are handled by main.lua:onResume,
    -- which knows whether the user was reading (via _simpleui_reader_was_active
    -- snapshot taken at suspend time). Calling _refresh(true) here as well would
    -- queue a duplicate _updatePage + 2x setDirty on every wakeup, causing two
    -- back-to-back e-ink refresh cycles. Just restart the clock timer here.
    -- Only module_clock's chain is restarted — _scheduleClockRefresh was the
    -- redundant parallel chain and has been removed (see onShow).
    local ClockMod = Registry.get("clock")
    if ClockMod and Registry.isEnabled(ClockMod, PFX) and ClockMod.scheduleRefresh then
        ClockMod.scheduleRefresh(self)
    end
end

function HomescreenWidget:onCloseWidget()
    -- Cancel ALL pending timers and scheduled callbacks immediately.
    -- This is critical: cover-load callbacks and the clock timer can fire
    -- setDirty on this widget after the FM has started initialising, causing
    -- spurious enqueue/collapse cycles in the UIManager refresh queue.
    if self._cover_poll_timer then
        UIManager:unschedule(self._cover_poll_timer)
        self._cover_poll_timer = nil
    end
    -- Invalidate the _refresh debounce token so the scheduled 0.15s callback
    -- is a no-op if it fires after close (it checks the token before acting).
    self._pending_refresh_token = {}   -- new object → old token never matches
    self._refresh_scheduled     = false
    self._pending_cover_clear   = nil

    -- Promote the cached book state to the Homescreen module table before
    -- freeing per-instance state. This lets the next Homescreen.show() pass
    -- it straight into the new widget, skipping the expensive prefetchBooks()
    -- IO (5-6 DocSettings.open calls) on every tab-switch.
    -- On a real close (FM exit, quit) we clear it so stale data is never used
    -- after a session boundary.
    if self._navbar_closing_intentionally then
        -- Tab-switch: preserve book data and current page for the next open.
        Homescreen._cached_books_state = self._cached_books_state
        Homescreen._current_page       = self._current_page
    else
        -- Real close: discard stale data.
        Homescreen._cached_books_state = nil
        Homescreen._current_page       = nil
    end

    -- Always free per-instance widget state — the widget is always destroyed,
    -- never reused, so keeping these references alive would be a memory leak.
    if self._db_conn then
        pcall(function() self._db_conn:close() end)
        self._db_conn = nil
    end
    self._vspan_pool         = nil
    self._wrapper_pool       = nil
    self._cached_books_state = nil
    self._enabled_mods_cache = nil
    self._current_page       = nil
    self._total_pages        = nil
    self.page                = nil
    self.page_num            = nil
    self._header_body_ref    = nil
    self._header_body_idx    = nil
    self._header_inner_w     = nil
    self._header_is_wrapped  = nil
    self._hs_ctx_menu        = nil
    self._ctx_cache          = nil
    self._shown_once         = nil
    self._stats_need_refresh = nil
    -- Persistent layout tree.
    self._body               = nil
    self._overlap            = nil
    self._footer_bc          = nil
    self._footer_chevron     = nil
    self._footer_dot         = nil
    self._footer_hidden_span = nil
    self._layout_sw          = nil
    self._layout_content_h   = nil
    self._layout_inner_w     = nil
    -- Keyboard navigation state.
    self._kb_book_items_fp   = nil
    self._kb_focus_idx       = nil
    self._kb_first_rec_idx   = nil

    -- Cancel the module_clock timer and release clock swap state.
    local ClockMod = Registry.get("clock")
    if ClockMod and ClockMod.cancelRefresh then ClockMod.cancelRefresh() end
    self._clock_body_ref   = nil
    self._clock_body_idx   = nil
    self._clock_is_wrapped = nil
    self._clock_pfx        = nil
    self._clock_inner_w    = nil

    -- Free cached cover bitmaps only when the FM file browser was visited
    -- since the last homescreen open. When CoverBrowser renders the library
    -- mosaic it replaces BookInfoManager's cover_bb entries with scaled-down
    -- thumbnails, making the HS’s cached bitmaps stale.
    -- When returning directly from a book (no FM navigation), the BIM bitmaps
    -- are still native-size and our scaled cache is valid — skipping the clear
    -- saves the 4-5 s re-scale on every book→homescreen transition.
    --
    -- _library_was_visited is set in sui_patches.lua’s onPathChanged hook
    -- (fires on every FM directory navigation) and cleared here after use.
    if Homescreen._library_was_visited then
        Homescreen._library_was_visited = nil
        -- We own these scaled copies (not the BIM); safe to free here because
        -- the widget tree has been torn down before onCloseWidget fires.
        Config.clearCoverCache()
    end
    -- Free quotes if header is not in quote mode.
    pcall(function()
        local ok, MH = pcall(require, "desktop_modules/module_header")
        if ok and MH and type(MH.freeQuotesIfUnused) == "function" then
            MH.freeQuotesIfUnused()
        end
    end)

    -- Always clear the singleton — the widget is always destroyed on close.
    -- Homescreen.show() creates a fresh widget each time, passing in the
    -- promoted _cached_books_state from the Homescreen table.
    if Homescreen._instance == self then
        Homescreen._instance = nil
    end
end

-- ---------------------------------------------------------------------------
-- Module API
-- ---------------------------------------------------------------------------
-- (Homescreen table was forward-declared at the top of this file)

function Homescreen.show(on_qa_tap, on_goal_tap)
    -- Close any existing widget instance first to avoid stacking.
    -- We do NOT keep the widget alive between opens because KOReader frees
    -- native bitmap resources (_bb) on TextBoxWidgets during close, leaving
    -- the Lua widget table alive but its paintTo broken (nil _bb crash).
    if Homescreen._instance then
        UIManager:close(Homescreen._instance)
        Homescreen._instance = nil
    end
    local w = HomescreenWidget:new{
        _on_qa_tap         = on_qa_tap,
        _on_goal_tap       = on_goal_tap,
        -- Transfer the cached book state from the previous instance so
        -- prefetchBooks() (the expensive part: 5-6 DocSettings.open calls)
        -- is skipped. The widget tree is always rebuilt fresh, but from
        -- in-memory data rather than from disk IO.
        _cached_books_state = Homescreen._cached_books_state,
        -- Restore the last active page so tab-switching does not reset to p.1.
        _current_page       = Homescreen._current_page or 1,
    }
    Homescreen._instance = w
    UIManager:show(w)
end

function Homescreen.refresh(keep_cache, books_only)
    if Homescreen._instance then
        Homescreen._instance:_refresh(keep_cache, books_only)
    end
end

-- Immediate refresh — bypasses the debounce. Used by showSettingsMenu
-- onCloseWidget to guarantee the HS is rebuilt before the next paint.
function Homescreen.refreshImmediate(keep_cache)
    if Homescreen._instance then
        Homescreen._instance:_refreshImmediate(keep_cache)
    end
end

function Homescreen.close()
    if Homescreen._instance then
        UIManager:close(Homescreen._instance)
        Homescreen._instance = nil
    end
    -- Discard the promoted book cache on an explicit close (e.g. FM exit).
    Homescreen._cached_books_state = nil
end

-- Clears the section-label widget cache.
-- Must be called after a screen resize/rotation so labels are rebuilt at the
-- new inner_w. Wired into UI.invalidateDimCache() in ui.lua.
function Homescreen.invalidateLabelCache()
    invalidateLabelCache()
end

Homescreen.PAGE_BREAK_ID = HS_PAGE_BREAK_ID

return Homescreen
