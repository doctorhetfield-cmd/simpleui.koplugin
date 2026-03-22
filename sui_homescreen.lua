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
--     _cached_books_state, _vspan_pool, _clock_timer, _cover_poll_timer,
--     _on_qa_tap, _on_goal_tap
-- • The cover LRU cache (Config.getCoverBB) is already per-filepath+size and
--   shared safely between pages; no extra work needed here.
-- • _vspan_pool is allocated on show() and nilled on close() so it doesn't
--   linger in memory when the page is not visible.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextWidget      = require("ui/widget/textwidget")
local TitleBar        = require("ui/widget/titlebar")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local logger          = require("logger")
local _               = require("gettext")
local Config          = require("sui_config")
local Registry        = require("desktop_modules/moduleregistry")
local Screen          = Device.screen
local UI              = require("sui_core")

-- ---------------------------------------------------------------------------
-- Layout constants — sourced from ui.lua (single source of truth).
-- ---------------------------------------------------------------------------
local PAD              = UI.PAD
local MOD_GAP          = UI.MOD_GAP
local SIDE_PAD         = UI.SIDE_PAD
local LABEL_H          = UI.LABEL_H
local SECTION_LABEL_SIZE = 13
local _CLR_TEXT_MID      = Blitbuffer.gray(0.45)

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
    local scale     = require("sui_config").getLabelScale()
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

local function openBook(filepath)
    -- Do NOT close the Homescreen before opening the reader.
    -- ReaderUI:showReader() broadcasts a "ShowingReader" event that closes all
    -- widgets atomically (FileManager, Homescreen, etc.) before the first reader
    -- paint — eliminating the flash of the FileChooser that occurs when we close
    -- the Homescreen first and then schedule the reader open with a delay.
    -- The 0.1s scheduleIn is also removed: showReader() is safe to call directly.
    -- ReaderUI is a core KOReader module — always present. Use package.loaded
    -- fast path to avoid pcall overhead; fall back to require on first call.
    local ReaderUI = package.loaded["apps/reader/readerui"]
        or require("apps/reader/readerui")
    ReaderUI:showReader(filepath)
end

-- ---------------------------------------------------------------------------
-- HomescreenWidget
-- ---------------------------------------------------------------------------

local HomescreenWidget = InputContainer:extend{
    name              = "homescreen",
    covers_fullscreen = true,
    -- Set by patches.lua after navbar injection:
    _on_qa_tap        = nil,
    -- Set by menu.lua goal dialog wiring:
    _on_goal_tap      = nil,
}

function HomescreenWidget:init()
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }

    -- Block taps/holds that land on the bottom bar area so they are never
    -- consumed by module InputContainers whose dimen extends into that area.
    -- Y threshold must match Bottombar.TOTAL_H() (full reserved strip: separator
    -- + bar + bottom padding), not raw content height — the latter breaks when
    -- the top bar is enabled (wrong band vs. actual navbar row).
    local function _in_bar(ges)
        if not ges or not ges.pos then return false end
        local Bottombar = require("sui_bottombar")
        local bar_y = Screen:getHeight() - Bottombar.TOTAL_H()
        return ges.pos.y >= bar_y
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
    -- Works by replicating the same zone/direction logic that gestures.koplugin
    -- uses in setupGesture(), so the HS honours exactly the same gesture_fm
    -- bindings the user configured in the library — without duplicating settings
    -- or creating a second plugin instance.
    --
    -- Hold events are handled by onBlockNavbarHold (navbar guard) and the module
    -- hold-to-settings wrappers.  Corner hold gestures (hold_top_left_corner,
    -- etc.) are intentionally NOT forwarded here to avoid conflicting with those
    -- existing hold handlers.  The user can still invoke corner-tap/swipe actions.
    -- ---------------------------------------------------------------------------
    local function _fmGestureAction(ges_event)
        local FileManager = require("apps/filemanager/filemanager")
        local g = FileManager.instance and FileManager.instance.gestures
        if not g then return end

        -- G_defaults is a KOReader global (set up in reader.lua before any plugin loads).
        local sw = Screen:getWidth()
        local sh = Screen:getHeight()
        local pos = ges_event.pos
        if not pos then return end
        local x, y = pos.x, pos.y
        local gt    = ges_event.ges
        local dir   = ges_event.direction

        -- Helper: is pos inside a ratio-defined zone?
        local function inZone(z)
            local zx = z.ratio_x * sw
            local zy = z.ratio_y * sh
            local zw = z.ratio_w * sw
            local zh = z.ratio_h * sh
            return x >= zx and x < zx + zw and y >= zy and y < zy + zh
        end

        -- Read zone definitions from G_defaults (same source as gestures plugin).
        local function zone(key)
            local d = G_defaults:readSetting(key)
            return { ratio_x = d.x, ratio_y = d.y, ratio_w = d.w, ratio_h = d.h }
        end

        local z_top_left    = zone("DTAP_ZONE_TOP_LEFT")
        local z_top_right   = zone("DTAP_ZONE_TOP_RIGHT")
        local z_bot_left    = zone("DTAP_ZONE_BOTTOM_LEFT")
        local z_bot_right   = zone("DTAP_ZONE_BOTTOM_RIGHT")
        local z_left_edge   = zone("DSWIPE_ZONE_LEFT_EDGE")
        local z_right_edge  = zone("DSWIPE_ZONE_RIGHT_EDGE")
        local z_top_edge    = zone("DSWIPE_ZONE_TOP_EDGE")
        local z_bot_edge    = zone("DSWIPE_ZONE_BOTTOM_EDGE")
        local z_left_side   = zone("DDOUBLE_TAP_ZONE_PREV_CHAPTER")
        local z_right_side  = zone("DDOUBLE_TAP_ZONE_NEXT_CHAPTER")

        local ges_name

        if gt == "swipe" then
            local is_diag = dir == "northeast" or dir == "northwest"
                         or dir == "southeast" or dir == "southwest"
            if is_diag then
                -- short_diagonal_swipe: only fires when distance is short.
                local short_thresh = Screen:scaleBySize(300)
                if ges_event.distance and ges_event.distance <= short_thresh then
                    ges_name = "short_diagonal_swipe"
                end
            elseif inZone(z_left_edge) then
                if     dir == "south" then ges_name = "one_finger_swipe_left_edge_down"
                elseif dir == "north" then ges_name = "one_finger_swipe_left_edge_up"
                end
            elseif inZone(z_right_edge) then
                if     dir == "south" then ges_name = "one_finger_swipe_right_edge_down"
                elseif dir == "north" then ges_name = "one_finger_swipe_right_edge_up"
                end
            elseif inZone(z_top_edge) then
                if     dir == "east" then ges_name = "one_finger_swipe_top_edge_right"
                elseif dir == "west" then ges_name = "one_finger_swipe_top_edge_left"
                end
            elseif inZone(z_bot_edge) then
                if     dir == "east" then ges_name = "one_finger_swipe_bottom_edge_right"
                elseif dir == "west" then ges_name = "one_finger_swipe_bottom_edge_left"
                end
            end

        elseif gt == "tap" then
            -- Corner taps — only if not in the navbar bar area (already guarded
            -- by onBlockNavbarTap above, but double-check here for clarity).
            if     inZone(z_top_left)  then ges_name = "tap_top_left_corner"
            elseif inZone(z_top_right) then ges_name = "tap_top_right_corner"
            elseif inZone(z_bot_left)  then ges_name = "tap_left_bottom_corner"
            elseif inZone(z_bot_right) then ges_name = "tap_right_bottom_corner"
            end

        elseif gt == "double_tap" then
            if     inZone(z_left_side)  then ges_name = "double_tap_left_side"
            elseif inZone(z_right_side) then ges_name = "double_tap_right_side"
            elseif inZone(z_top_left)   then ges_name = "double_tap_top_left_corner"
            elseif inZone(z_top_right)  then ges_name = "double_tap_top_right_corner"
            elseif inZone(z_bot_left)   then ges_name = "double_tap_bottom_left_corner"
            elseif inZone(z_bot_right)  then ges_name = "double_tap_bottom_right_corner"
            end

        elseif gt == "two_finger_tap" then
            if     inZone(z_top_left)  then ges_name = "two_finger_tap_top_left_corner"
            elseif inZone(z_top_right) then ges_name = "two_finger_tap_top_right_corner"
            elseif inZone(z_bot_left)  then ges_name = "two_finger_tap_bottom_left_corner"
            elseif inZone(z_bot_right) then ges_name = "two_finger_tap_bottom_right_corner"
            end

        elseif gt == "two_finger_swipe" then
            if     dir == "east"      then ges_name = "two_finger_swipe_east"
            elseif dir == "west"      then ges_name = "two_finger_swipe_west"
            elseif dir == "north"     then ges_name = "two_finger_swipe_north"
            elseif dir == "south"     then ges_name = "two_finger_swipe_south"
            elseif dir == "northeast" then ges_name = "two_finger_swipe_northeast"
            elseif dir == "northwest" then ges_name = "two_finger_swipe_northwest"
            elseif dir == "southeast" then ges_name = "two_finger_swipe_southeast"
            elseif dir == "southwest" then ges_name = "two_finger_swipe_southwest"
            end

        elseif gt == "multiswipe" then
            return g:multiswipeAction(ges_event.multiswipe_directions, ges_event)

        elseif gt == "spread" then
            ges_name = "spread_gesture"
        elseif gt == "pinch" then
            ges_name = "pinch_gesture"
        elseif gt == "rotate" then
            if     dir == "cw"  then ges_name = "rotate_cw"
            elseif dir == "ccw" then ges_name = "rotate_ccw"
            end
        end

        if ges_name then
            -- gestureAction internally calls UIManager:sendEvent, which only
            -- delivers to the TOP widget (HomescreenWidget). Since HS doesn't
            -- handle most actions (frontlight, fullrefresh, etc.), the events
            -- would never reach FM's DeviceListener.
            -- Fix: temporarily redirect UIManager.sendEvent → broadcastEvent
            -- so every action event reaches all widgets including FM.
            local orig_sendEvent = UIManager.sendEvent
            UIManager.sendEvent = function(um, event)
                return UIManager:broadcastEvent(event)
            end
            local ok, err = pcall(g.gestureAction, g, ges_name, ges_event)
            UIManager.sendEvent = orig_sendEvent
            if not ok then
                logger.warn("simpleui hs gesture: gestureAction error:", err)
            end
            return true
        end
    end

    -- NOTE: ges_events handlers receive (args, ev) because InputContainer dispatches via
    -- Event:new(eventname, gsseq.args, ev) and EventListener unpacks event.args as positional
    -- parameters: self:handler(gsseq.args, ev).  Since we never set gsseq.args the first
    -- parameter is always nil; the actual gesture table is the second parameter.
    function self:onHSSwipe(_args, ges)        return _fmGestureAction(ges) end
    function self:onHSTwoFingerSwipe(_args, ges) return _fmGestureAction(ges) end
    function self:onHSDoubleTap(_args, ges)    return _fmGestureAction(ges) end
    function self:onHSTwoFingerTap(_args, ges) return _fmGestureAction(ges) end
    function self:onHSMultiswipe(_args, ges)   return _fmGestureAction(ges) end
    function self:onHSSpread(_args, ges)       return _fmGestureAction(ges) end
    function self:onHSPinch(_args, ges)        return _fmGestureAction(ges) end
    function self:onHSRotate(_args, ges)       return _fmGestureAction(ges) end

    -- Tap forwarding: only fires for taps that land in a corner zone AND were
    -- NOT consumed by onBlockNavbarTap (which returns true for navbar taps).
    -- Since onBlockNavbarTap runs first (it is defined first in ges_events) and
    -- returns nil for non-navbar taps, InputContainer will continue dispatching
    -- and reach this handler.  We therefore forward corner taps here; taps that
    -- fall outside all corner zones produce no ges_name and are silently ignored.
    function self:onBlockNavbarTap(_args, ges)
        if _in_bar(ges) then return true end  -- consume navbar taps
        return _fmGestureAction(ges)          -- forward corner taps to FM gestures
    end
    function self:onBlockNavbarHold(_args, ges)
        if _in_bar(ges) then return true end  -- consume navbar holds
        -- Corner holds are intentionally NOT forwarded: the module
        -- hold-to-settings wrappers own holds on their own dimen, and
        -- hold_*_corner gestures would conflict with that UX.
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
    self._cached_books_state = nil
    self._clock_timer        = nil
    self._cover_poll_timer   = nil

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
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self[1] = FrameContainer:new{
        bordersize = 0, padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen      = Geom:new{ w = sw, h = sh },
        VerticalSpan:new{ width = sh },
    }
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
function HomescreenWidget:_buildContent()
    local sw       = Screen:getWidth()
    local sh       = Screen:getHeight()
    local content_h = self._navbar_content_h or sh
    local side_off  = SIDE_PAD
    local inner_w   = sw - side_off * 2

    -- Resolve book module descriptors once — reused for both the prefetch guard
    -- and the has_content check below. Registry.get is a cheap table lookup but
    -- calling it four times for the same two ids is needless noise.
    local mod_c  = Registry.get("currently")
    local mod_r  = Registry.get("recent")
    local show_c = mod_c and Registry.isEnabled(mod_c, PFX)
    local show_r = mod_r and Registry.isEnabled(mod_r, PFX)

    -- Prefetch book data once per show/refresh cycle (cached until invalidated).
    if not self._cached_books_state then
        local ok, SH = pcall(require, "desktop_modules/module_books_shared")
        if ok and SH then
            -- Check via registry whether book modules are actually enabled
            -- before paying the cost of opening history.
            if show_c or show_r then
                self._cached_books_state = SH.prefetchBooks(show_c, show_r)
                if Config.cover_extraction_pending then
                    self:_scheduleCoverPoll()
                end
            else
                self._cached_books_state = { current_fp = nil, recent_fps = {}, prefetched_data = {} }
            end
        else
            logger.warn("simpleui: homescreen: cannot load module_books_shared: " .. tostring(SH))
            self._cached_books_state = { current_fp = nil, recent_fps = {}, prefetched_data = {} }
        end
    end

    local bs = self._cached_books_state
    local has_content   = (bs.current_fp and show_c) or (#bs.recent_fps > 0 and show_r)
    local wants_books   = show_c or show_r

    -- Open one shared DB connection for the entire render cycle.
    -- All modules that query the stats DB (currently, recent, reading_goals,
    -- reading_stats) receive it via ctx.db_conn and must NOT close it.
    -- It is closed once, after the build loop, when every module is done.
    -- We open it whenever any stats-using module is enabled, not just book
    -- modules — reading_goals and reading_stats need it too.
    local mod_rg   = Registry.get("reading_goals")
    local mod_rs   = Registry.get("reading_stats")
    local wants_db = wants_books
        or (mod_rg and Registry.isEnabled(mod_rg, PFX))
        or (mod_rs and mod_rs.isEnabled and mod_rs.isEnabled(PFX))
    local db_conn = wants_db and Config.openStatsDB() or nil

    local self_ref = self
    local ctx = {
        pfx          = PFX,
        pfx_qa       = PFX_QA,
        close_fn     = function() self_ref:onClose() end,
        open_fn      = function(fp) openBook(fp) end,
        on_qa_tap    = function(aid) if self_ref._on_qa_tap then self_ref._on_qa_tap(aid) end end,
        on_goal_tap  = function() if self_ref._on_goal_tap then self_ref._on_goal_tap() end end,
        db_conn      = db_conn,
        vspan_pool   = self._vspan_pool,
        prefetched   = bs.prefetched_data,
        current_fp   = bs.current_fp,
        recent_fps   = bs.recent_fps,
        sectionLabel = sectionLabel,
    }

    -- ── Module loop ──────────────────────────────────────────────────────────
    local module_order = Registry.loadOrder(PFX)
    local enabled_mods = {}
    local has_book_mod = false

    for _, mod_id in ipairs(module_order) do
        local mod = Registry.get(mod_id)
        if mod and Registry.isEnabled(mod, PFX) then
            enabled_mods[#enabled_mods+1] = mod
            if mod_id == "currently" or mod_id == "recent" then
                has_book_mod = true
            end
        end
    end

    -- Empty state when book modules are on but history is empty.
    local empty_widget
    local empty_h = 0
    if wants_books and not has_content and not has_book_mod then
        empty_h      = _EMPTY_H
        empty_widget = buildEmptyState(inner_w, empty_h)
    end

    -- ── Build body ───────────────────────────────────────────────────────────
    local body    = VerticalGroup:new{ align = "left" }
    local topbar_on = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
    local top_pad   = topbar_on and MOD_GAP or (MOD_GAP * 2)
    body[#body+1]   = self:_vspan(top_pad)

    -- Single loop: build each module and add to body immediately.
    -- db_conn is closed AFTER this loop so modules that use ctx.db_conn
    -- (module_currently, module_recent via getBookData) get a live connection.
    -- _header_body_idx records where the header widget lands in the body
    -- VerticalGroup so _clockTick can do a surgical swap without rebuilding
    -- the full page.
    -- ctx_menu for hold-to-settings wrappers — built lazily on first hold,
    -- then reused for the lifetime of this HomescreenWidget instance.
    -- Stored on self so it is freed automatically when onCloseWidget nils state.
    -- makeQAMenu is intentionally absent: module_quick_actions guards with
    -- type(ctx_menu.makeQAMenu) == "function" before calling it.
    local function _getHsCtxMenu(widget_self)
        if widget_self._hs_ctx_menu then return widget_self._hs_ctx_menu end
        local ctx = setmetatable({
            pfx           = PFX,
            pfx_qa        = PFX_QA,
            refresh       = function()
                local HS = package.loaded["sui_homescreen"]
                if HS and HS._instance then HS._instance:_refresh(false) end
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
        widget_self._hs_ctx_menu = ctx
        return ctx
    end

    self._header_body_idx   = nil
    self._header_inner_w    = inner_w
    self._header_body_ref   = body
    self._header_is_wrapped = false
    local _tr = _  -- capture gettext before the loop's _ variable shadows it
    local first_mod = true
    for _, mod in ipairs(enabled_mods) do
        local ok_w, widget = pcall(mod.build, inner_w, ctx)
        if not ok_w then
            logger.warn("simpleui homescreen: build failed for "
                        .. tostring(mod.id) .. ": " .. tostring(widget))
        elseif widget then
            if first_mod then
                first_mod = false
            else
                local gap_px = Config.getModuleGapPx(mod.id, PFX, MOD_GAP)
                body[#body+1] = self:_vspan(gap_px)
            end
            if mod.label then body[#body+1] = sectionLabel(mod.label, inner_w) end
            -- Wrap modules that have settings in a hold-to-open-settings
            -- InputContainer.  Modules without getMenuItems are added unwrapped.
            local has_menu = type(mod.getMenuItems) == "function"
            if mod.id == "header" then
                self._header_body_idx  = #body + 1
                self._header_is_wrapped = has_menu
            end
            if has_menu then
                -- Capture mod in a local so the closure in onHoldModRelease
                -- always refers to this iteration's module, not the loop var.
                local _mod = mod
                local wrapper = InputContainer:new{
                    dimen = Geom:new{ w = inner_w, h = widget:getSize().h },
                    widget,
                }
                wrapper.ges_events = {
                    HoldMod = {
                        GestureRange:new{
                            ges   = "hold",
                            range = function() return wrapper.dimen end,
                        },
                    },
                    HoldModRelease = {
                        GestureRange:new{
                            ges   = "hold_release",
                            range = function() return wrapper.dimen end,
                        },
                    },
                }
                function wrapper:onHoldMod() return true end  -- claim the hold
                local _self = self  -- capture HomescreenWidget for the closure
                function wrapper:onHoldModRelease()
                    local Topbar    = require("sui_topbar")
                    local Bottombar = require("sui_bottombar")
                    local topbar_h  = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
                                      and Topbar.TOTAL_TOP_H() or 0
                    UI.showSettingsMenu(
                        _mod.name or _mod.id,
                        function()
                            local ctx_menu = _getHsCtxMenu(_self)
                            local items    = _mod.getMenuItems(ctx_menu)
                            local gap_item = Config.makeGapItem({
                                text_func = function()
                                    local pct = Config.getModuleGapPct(_mod.id, PFX)
                                    return string.format(_tr("Gap  (%d%%)"), pct)
                                end,
                                title   = _mod.name or _mod.id,
                                info    = _tr("Vertical space above this module.\n100% is the default spacing."),
                                get     = function() return Config.getModuleGapPct(_mod.id, PFX) end,
                                set     = function(v) Config.setModuleGap(v, _mod.id, PFX) end,
                                refresh = ctx_menu.refresh,
                            })
                            table.insert(items, gap_item)
                            return items
                        end,
                        topbar_h,
                        Screen:getHeight(),
                        Bottombar.TOTAL_H()
                    )
                    return true
                end
                body[#body+1] = wrapper
            else
                body[#body+1] = widget
            end
        end
    end

    -- Close the shared DB connection now that all modules have finished building.
    if db_conn then pcall(function() db_conn:close() end) end

    if empty_widget then
        body[#body+1] = empty_widget
    end

    -- The outer FrameContainer has background=COLOR_WHITE and dimen.h=content_h,
    -- so no explicit filler span is needed to avoid visual garbage below modules.

    return FrameContainer:new{
        bordersize    = 0, padding = 0,
        padding_left  = side_off, padding_right = side_off,
        background    = Blitbuffer.COLOR_WHITE,
        dimen         = Geom:new{ w = sw, h = content_h },
        FrameContainer:new{
            bordersize = 0, padding = 0,
            background = Blitbuffer.COLOR_WHITE,
            dimen      = Geom:new{ w = inner_w, h = content_h },
            body,
        },
    }
end

-- ---------------------------------------------------------------------------
-- _refresh — rebuilds content in-place (called by _rebuildHomescreen)
-- ---------------------------------------------------------------------------
function HomescreenWidget:_refresh(keep_cache)
    if not keep_cache then self._cached_books_state = nil end
    if self._refresh_scheduled then return end
    self._refresh_scheduled = true
    local token = {}
    self._pending_refresh_token = token
    UIManager:scheduleIn(0.15, function()
        if self._pending_refresh_token ~= token then return end
        if Homescreen._instance ~= self then return end
        self._refresh_scheduled = false
        if not self._navbar_container then return end
        local old = self._navbar_container[1]
        local new = self:_buildContent()
        if old and old.overlap_offset then
            new.overlap_offset = old.overlap_offset
        end
        self._navbar_container[1] = new
        UIManager:setDirty(self._navbar_container, "ui")
        UIManager:setDirty(self, "ui")
    end)
end

-- Immediate rebuild — bypasses the 0.15s debounce. Cancels any pending
-- debounced refresh so the two don't race. Used by showSettingsMenu's
-- onCloseWidget to ensure the HS reflects changes made via the menu
-- before the next paint cycle, not 150ms later.
function HomescreenWidget:_refreshImmediate(keep_cache)
    -- Cancel any pending debounced refresh.
    self._pending_refresh_token = {}  -- new object — old token never matches
    self._refresh_scheduled     = false
    if not keep_cache then self._cached_books_state = nil end
    if not self._navbar_container then return end
    local old = self._navbar_container[1]
    local new = self:_buildContent()
    if old and old.overlap_offset then
        new.overlap_offset = old.overlap_offset
    end
    self._navbar_container[1] = new
    UIManager:setDirty(self, "ui")
end

-- ---------------------------------------------------------------------------
-- Clock refresh timer — only runs when header mode is clock or clock_date.
-- Performs a surgical swap of only the header widget inside the existing body
-- VerticalGroup, avoiding a full _buildContent() rebuild (no DB queries, no
-- cover loads, no module allocations) just to update two TextWidgets.
-- _header_body_idx and _header_body_ref are set during _buildContent().
-- Falls back to a full rebuild if the index was not recorded (e.g. header
-- disabled, or first tick before any build has run).
-- ---------------------------------------------------------------------------
function HomescreenWidget:_clockTick()
    if not self._navbar_container then return end
    local hdr_mod = Registry.get("header")
    if not hdr_mod or not Registry.isEnabled(hdr_mod, PFX) then return end

    local body = self._header_body_ref
    local idx  = self._header_body_idx

    if body and idx and body[idx] then
        -- Fast path: replace only the header widget in the body VerticalGroup.
        local sw      = Screen:getWidth()
        local inner_w = self._header_inner_w or (sw - SIDE_PAD * 2)
        local ctx_hdr = {
            pfx        = PFX,
            vspan_pool = self._vspan_pool,
        }
        local ok_w, new_hdr = pcall(hdr_mod.build, inner_w, ctx_hdr)
        if ok_w and new_hdr then
            -- When the header was wrapped in a hold-settings InputContainer,
            -- replace the inner slot [1] rather than the wrapper itself, so
            -- the gesture handler stays alive across clock ticks.
            if self._header_is_wrapped then
                body[idx][1] = new_hdr
            else
                body[idx] = new_hdr
            end
            UIManager:setDirty(self._navbar_container, "ui")
            return
        end
        -- If build failed fall through to full rebuild below.
        logger.warn("simpleui: _clockTick: header build failed, falling back to full rebuild")
    end

    -- Slow path fallback: full content rebuild (used on first tick or if header
    -- index was not captured, e.g. header widget returned nil from build()).
    local content    = self._navbar_container[1]
    local old_offset = content and content.overlap_offset
    local new_content = self:_buildContent()
    if old_offset then new_content.overlap_offset = old_offset end
    self._navbar_container[1] = new_content
    UIManager:setDirty(self._navbar_container, "ui")
end

function HomescreenWidget:_scheduleClockRefresh()
    if self._clock_timer then
        UIManager:unschedule(self._clock_timer)
        self._clock_timer = nil
    end
    local hdr  = Registry.get("header")
    local mode = hdr and G_reader_settings:readSetting(PFX .. "header") or "nothing"
    if mode == nil then mode = "clock_date" end
    -- Only schedule the timer for modes that actually show the time.
    if mode ~= "clock" and mode ~= "clock_date" then return end
    local secs = 60 - (os.time() % 60) + 1
    self._clock_timer = function()
        self._clock_timer = nil
        -- If this widget is no longer the live instance, stop the chain.
        if Homescreen._instance ~= self then return end
        -- Skip if a book is open — no need to update a hidden homescreen.
        local RUI = package.loaded["apps/reader/readerui"]
        if RUI and RUI.instance then self:_scheduleClockRefresh(); return end
        self:_clockTick()
        self:_scheduleClockRefresh()
    end
    UIManager:scheduleIn(secs, self._clock_timer)
end

-- ---------------------------------------------------------------------------
-- Cover extraction poll
-- ---------------------------------------------------------------------------
function HomescreenWidget:_scheduleCoverPoll(attempt)
    attempt = (attempt or 0) + 1
    if attempt > 60 then Config.cover_extraction_pending = false; return end
    local bim = Config.getBookInfoManager()
    local self_ref = self
    local timer
    timer = function()
        self_ref._cover_poll_timer = nil
        if not bim or not bim:isExtractingInBackground() then
            Config.cover_extraction_pending = false
            if Homescreen._instance == self_ref then
                self_ref:_refresh(false)
            end
        else
            self_ref:_scheduleCoverPoll(attempt)
        end
    end
    self._cover_poll_timer = timer
    UIManager:scheduleIn(0.5, timer)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function HomescreenWidget:onShow()
    -- Build content here, not in init(), because patches.lua sets _navbar_content_h
    -- on the widget *before* calling onShow — the correct content height is now known.
    --
    -- After navbar injection the widget tree is:
    --   self[1]                   = FrameContainer (wrapped by wrapWithNavbar)
    --   self[1][1]                = navbar_container (OverlapGroup)
    --   self._navbar_container    = navbar_container
    --   self._navbar_container[1] = inner_widget (our placeholder, the _navbar_inner)
    --
    -- We replace the inner slot directly so the navbar (bar, topbar) is untouched.
    if self._navbar_container then
        local old = self._navbar_container[1]
        local new = self:_buildContent()
        -- Preserve the overlap_offset set by wrapWithNavbar so the content
        -- is correctly positioned below the topbar (offset = {0, topbar_h}).
        if old and old.overlap_offset then
            new.overlap_offset = old.overlap_offset
        end
        self._navbar_container[1] = new
    end
    UIManager:setDirty(self, "ui")
    self:_scheduleClockRefresh()
end

function HomescreenWidget:onClose()
    UIManager:close(self)
    return true
end

function HomescreenWidget:onSuspend()
    -- Cancel the clock timer so it doesn't fire unnecessarily during suspend.
    -- _scheduleClockRefresh already deduplicates, so onResume can safely
    -- restart it without checking whether it was running before.
    if self._clock_timer then
        UIManager:unschedule(self._clock_timer)
        self._clock_timer = nil
    end
end

function HomescreenWidget:onResume()
    -- Restart the clock timer. _scheduleClockRefresh recalculates the phase
    -- from os.time(), so the clock is always correct after wakeup regardless
    -- of how long the device was suspended.
    self:_scheduleClockRefresh()
end

function HomescreenWidget:onCloseWidget()
    -- Cancel ALL pending timers and scheduled callbacks immediately.
    -- This is critical: cover-load callbacks and the clock timer can fire
    -- setDirty on this widget after the FM has started initialising, causing
    -- spurious enqueue/collapse cycles in the UIManager refresh queue.
    if self._clock_timer then
        UIManager:unschedule(self._clock_timer)
        self._clock_timer = nil
    end
    if self._cover_poll_timer then
        UIManager:unschedule(self._cover_poll_timer)
        self._cover_poll_timer = nil
    end
    -- Invalidate the _refresh debounce token so the scheduled 0.15s callback
    -- is a no-op if it fires after close (it checks the token before acting).
    self._pending_refresh_token = {}   -- new object → old token never matches
    self._refresh_scheduled     = false
    self._pending_cover_clear   = nil
    -- Free per-instance caches.
    self._vspan_pool         = nil
    self._cached_books_state = nil
    -- Release header swap state so stale body references don't keep the
    -- widget tree alive after close.
    self._header_body_ref  = nil
    self._header_body_idx  = nil
    self._header_inner_w   = nil
    self._header_is_wrapped = nil
    self._hs_ctx_menu       = nil
    -- Free all cached cover bitmaps. We own these scaled copies (not the BIM),
    -- and it is safe to free them here because the widget tree has been torn
    -- down before onCloseWidget fires. On the next open, getCoverBB will
    -- re-scale from the BIM's fresh bitmaps.
    Config.clearCoverCache()
    -- Free quotes if header is not in quote mode.
    pcall(function()
        local ok, MH = pcall(require, "desktop_modules/module_header")
        if ok and MH and type(MH.freeQuotesIfUnused) == "function" then
            MH.freeQuotesIfUnused()
        end
    end)
    -- Clear singleton reference.
    if Homescreen._instance == self then
        Homescreen._instance = nil
    end
end

-- ---------------------------------------------------------------------------
-- Module API
-- ---------------------------------------------------------------------------
-- (Homescreen table was forward-declared at the top of this file)

function Homescreen.show(on_qa_tap, on_goal_tap)
    -- Close any existing instance first to avoid stacking.
    if Homescreen._instance then
        UIManager:close(Homescreen._instance)
        Homescreen._instance = nil
    end
    local w = HomescreenWidget:new{
        _on_qa_tap   = on_qa_tap,
        _on_goal_tap = on_goal_tap,
    }
    Homescreen._instance = w
    UIManager:show(w)
end

function Homescreen.refresh(keep_cache)
    if Homescreen._instance then
        Homescreen._instance:_refresh(keep_cache)
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
end

-- Clears the section-label widget cache.
-- Must be called after a screen resize/rotation so labels are rebuilt at the
-- new inner_w. Wired into UI.invalidateDimCache() in ui.lua.
function Homescreen.invalidateLabelCache()
    invalidateLabelCache()
end

return Homescreen
