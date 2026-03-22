-- folio_readingtoolbar.lua — Folio
-- Bottom-edge swipe-up toolbar in Reader: brightness, font size, night-mode toggle.

local Device          = require("device")
local Event           = require("ui/event")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local ProgressWidget  = require("ui/widget/progresswidget")
local Screen          = Device.screen
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("gettext")

local FolioTheme = require("folio_theme")
local Theme    = FolioTheme.Theme

local M = {}

-- Active toolbar instance (at most one).
local _toolbar = nil
local _reader  = nil

-- ---------------------------------------------------------------------------
-- Touch zone id (unregister on teardown)
-- ---------------------------------------------------------------------------
local ZONE_ID = "folio_reading_toolbar_swipe_up"

-- ---------------------------------------------------------------------------
-- ReaderUI reference (for touch zone registration)
-- ---------------------------------------------------------------------------

local function registerBottomSwipeZone(reader_ui)
    if not reader_ui or not reader_ui.registerTouchZones then return end
    reader_ui:registerTouchZones({
        {
            id          = ZONE_ID,
            ges         = "swipe",
            screen_zone = {
                ratio_x = 0,
                ratio_y = 0.85,
                ratio_w = 1,
                ratio_h = 0.15,
            },
            overrides = {
                "rolling_swipe",
                "paging_swipe",
                "readermenu_swipe",
                "readermenu_ext_swipe",
            },
            handler = function(ges)
                if ges and ges.direction == "north" then
                    M.show(reader_ui)
                    return true
                end
            end,
        },
    })
end

-- ---------------------------------------------------------------------------
-- Brightness / frontlight (PowerD — not Device:setScreenBrightness on e-ink)
-- ---------------------------------------------------------------------------

local function getFlPercent(powerd)
    if not powerd or not Device:hasFrontlight() then return nil end
    local cur = powerd:frontlightIntensity()
    local fl_min, fl_max = powerd.fl_min, powerd.fl_max
    if fl_max <= fl_min then return 100 end
    return math.floor(100 * (cur - fl_min) / (fl_max - fl_min) + 0.5)
end

local function setFlFromPercent(powerd, percent)
    if not powerd or not Device:hasFrontlight() then return end
    percent = math.max(0, math.min(100, percent))
    local fl_min, fl_max = powerd.fl_min, powerd.fl_max
    local n = math.floor(fl_min + (fl_max - fl_min) * (percent / 100) + 0.5)
    if n <= fl_min then
        powerd:turnOffFrontlight()
    else
        powerd:setIntensity(n)
    end
    powerd:updateResumeFrontlightState()
end

-- ---------------------------------------------------------------------------
-- Font size (ReaderFont:onSetFontSize / onChangeSize)
-- ---------------------------------------------------------------------------

local function getFontSize(reader_ui)
    local f = reader_ui.font
    if f and f.configurable and f.configurable.font_size then
        return f.configurable.font_size
    end
    local cfg = reader_ui.document and reader_ui.document.configurable
    if cfg and cfg.font_size then return cfg.font_size end
    return nil
end

local function changeFontSize(reader_ui, delta)
    local f = reader_ui.font
    if f and f.onChangeSize then
        return f:onChangeSize(delta)
    end
    if f and f.configurable and f.configurable.font_size and f.onSetFontSize then
        return f:onSetFontSize(f.configurable.font_size + delta)
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Night mode (DeviceListener:onToggleNightMode via event)
-- ---------------------------------------------------------------------------

local function isNightMode()
    return G_reader_settings:isTrue("night_mode")
end

local function setNightMode(want_dark, reader_ui)
    local now = isNightMode()
    if want_dark == now then return end
    reader_ui:handleEvent(Event:new("ToggleNightMode"))
end

-- ---------------------------------------------------------------------------
-- ReadingToolbarWidget
-- ---------------------------------------------------------------------------

local ReadingToolbarWidget = InputContainer:extend{
    name = "folio_reading_toolbar",
}

function ReadingToolbarWidget:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ w = sw, h = sh }
    self._reader = self._reader_ui
    self._reader_ui = nil

    local pad = FolioTheme.scaled(FolioTheme.Spacing.MD)
    local tb_h = Screen:scaleBySize(240)
    local row_label = FolioTheme.faceUI(FolioTheme.sizeMicro())
    local face_sz = FolioTheme.faceContent(math.max(16, Screen:scaleBySize(22)))
    local btn_sz = Screen:scaleBySize(44)
    local handle_sz = Screen:scaleBySize(24)
    local track_h = FolioTheme.SP.XS

    local powerd = Device:getPowerDevice()
    local pct = getFlPercent(powerd) or 0

    -- Top dismiss area + swipe down
    local top_h = math.max(0, sh - tb_h)
    local top_dim
    if top_h > 0 then
        top_dim = Geom:new{ w = sw, h = top_h }
    else
        top_dim = Geom:new{ w = sw, h = 1 }
    end

    local top_catcher = InputContainer:new{
        dimen = top_dim,
        ges_events = {
            Tap = {
                GestureRange:new{ ges = "tap", range = function() return top_dim end },
            },
            Swipe = {
                GestureRange:new{ ges = "swipe", range = function() return top_dim end },
            },
        },
    }
    function top_catcher:onTap()
        M._close()
        return true
    end
    function top_catcher:onSwipe(_, ges)
        if ges and ges.direction == "south" then
            M._close()
            return true
        end
    end

    -- Brightness row
    local pct_txt = TextWidget:new{
        text    = string.format("%d%%", pct),
        face    = row_label,
        fgcolor = Theme.TEXT,
    }
    local pw = self:_buildBrightnessSlider(sw - pad * 2, track_h, handle_sz, pad, powerd, pct_txt)

    local row_bright = VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            TextWidget:new{
                text    = _("BRIGHTNESS"),
                face    = row_label,
                fgcolor = Theme.TEXT_MUTED,
            },
            HorizontalSpan:new{ width = pad },
            pct_txt,
        },
        VerticalSpan:new{ width = Screen:scaleBySize(6) },
        pw,
    }

    -- Font row
    local fs = getFontSize(self._reader) or 22
    local size_w = TextWidget:new{
        text    = tostring(fs),
        face    = face_sz,
        bold    = true,
        fgcolor = Theme.TEXT,
    }

    local tb = self
    local function mk_font_btn(label, delta)
        local dim = Geom:new{ w = btn_sz, h = btn_sz }
        local C = InputContainer:new{
            dimen = dim,
            ges_events = {
                Tap = {
                    GestureRange:new{ ges = "tap", range = function() return dim end },
                },
            },
        }
        function C:onTap()
            tb:resetIdleTimer()
            changeFontSize(tb._reader, delta)
            local n = getFontSize(tb._reader)
            if n and size_w then size_w:setText(tostring(n)) end
            UIManager:setDirty(tb, "ui")
            return true
        end
        C[1] = FrameContainer:new{
            bordersize = 0,
            background = Theme.SURFACE,
            width = btn_sz,
            height = btn_sz,
            CenterContainer:new{
                dimen = dim,
                TextWidget:new{
                    text = label,
                    face = face_sz,
                    fgcolor = Theme.TEXT,
                },
            },
        }
        return C
    end

    local row_font = HorizontalGroup:new{
        VerticalGroup:new{
            align = "left",
            TextWidget:new{
                text    = _("FONT SIZE"),
                face    = row_label,
                fgcolor = Theme.TEXT_MUTED,
            },
            VerticalSpan:new{ width = Screen:scaleBySize(6) },
            HorizontalGroup:new{
                mk_font_btn("A−", -1),
                HorizontalSpan:new{ width = pad },
                CenterContainer:new{
                    dimen = Geom:new{ w = sw - 2 * btn_sz - 4 * pad, h = btn_sz },
                    size_w,
                },
                HorizontalSpan:new{ width = pad },
                mk_font_btn("A+", 1),
            },
        },
    }

    -- Mode row
    local light_dim = Geom:new{ w = math.floor((sw - pad * 3) / 2), h = Screen:scaleBySize(44) }
    local dark_dim = Geom:new{ w = sw - pad * 3 - light_dim.w, h = Screen:scaleBySize(44) }

    local btn_light = self:_modeButton("☀ " .. _("LIGHT"), false, light_dim)
    local btn_dark  = self:_modeButton("◑ " .. _("DARK"), true, dark_dim)

    local row_mode = HorizontalGroup:new{
        HorizontalSpan:new{ width = pad },
        btn_light,
        HorizontalSpan:new{ width = pad },
        btn_dark,
    }

    local inner = VerticalGroup:new{
        align = "left",
        row_bright,
        VerticalSpan:new{ width = pad },
        row_font,
        VerticalSpan:new{ width = pad },
        row_mode,
    }

    local line_top = LineWidget:new{
        dimen = Geom:new{ w = sw, h = Screen:scaleBySize(2) },
        background = Theme.PRIMARY,
    }

    local toolbar_body = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Theme.SURFACE_TOP,
        width = sw,
        VerticalGroup:new{
            align = "left",
            line_top,
            FrameContainer:new{
                bordersize = 0,
                padding = pad,
                background = Theme.SURFACE_TOP,
                width = sw,
                inner,
            },
        },
    }

    -- Toolbar: swipe down to dismiss
    local tb_dim = Geom:new{ w = sw, h = tb_h }
    local tb_catcher = InputContainer:new{
        dimen = tb_dim,
        ges_events = {
            Swipe = {
                GestureRange:new{ ges = "swipe", range = function() return tb_dim end },
            },
        },
    }
    function tb_catcher:onSwipe(_, ges)
        if ges and ges.direction == "south" then
            M._close()
            return true
        end
    end
    tb_catcher[1] = toolbar_body

    self._idle_timer = nil
    self._top_catcher = top_catcher
    self._tb_catcher = tb_catcher

    self[1] = VerticalGroup:new{
        align = "left",
        top_catcher,
        tb_catcher,
    }

    self:scheduleIdleReset()
end

function ReadingToolbarWidget:_modeButton(label, want_dark, dim)
    local self_ref = self
    local C = InputContainer:new{
        dimen = dim,
        ges_events = {
            Tap = {
                GestureRange:new{ ges = "tap", range = function() return dim end },
            },
        },
    }
    function C:onTap()
        if want_dark == isNightMode() then
            return true
        end
        self_ref:resetIdleTimer()
        setNightMode(want_dark, self_ref._reader)
        local r = self_ref._reader
        UIManager:close(self_ref)
        _toolbar = nil
        _reader = nil
        if r then
            UIManager:scheduleIn(0, function()
                M.show(r)
            end)
        end
        return true
    end
    local active = (want_dark and isNightMode()) or (not want_dark and not isNightMode())
    local bg = active and Theme.PRIMARY or Theme.SURFACE
    local fg = active and Theme.ON_PRIMARY or Theme.TEXT
    C[1] = FrameContainer:new{
        bordersize = 0,
        background = bg,
        width = dim.w,
        height = dim.h,
        CenterContainer:new{
            dimen = dim,
            TextWidget:new{
                text    = label,
                face    = FolioTheme.faceContent(math.max(12, Screen:scaleBySize(18))),
                bold    = true,
                fgcolor = fg,
            },
        },
    }
    return C
end

function ReadingToolbarWidget:_buildBrightnessSlider(total_w, track_h, handle_sz, pad, powerd, pct_txt)
    if not Device:hasFrontlight() then
        return FrameContainer:new{
            bordersize = 0,
            padding = 0,
            TextWidget:new{
                text    = _("Frontlight not available"),
                face    = FolioTheme.faceUI(FolioTheme.sizeMicro()),
                fgcolor = Theme.TEXT_MUTED,
            },
        }
    end

    local sw = total_w
    local track_w = sw - handle_sz - pad
    local powerd_ref = powerd
    local self_ref = self

    local pct = getFlPercent(powerd_ref) or 0
    local perc = pct / 100

    local track = ProgressWidget:new{
        width = track_w,
        height = track_h,
        percentage = perc,
        bgcolor = Theme.SURFACE_HIGH,
        fillcolor = Theme.PRIMARY,
        bordercolor = Theme.SURFACE_HIGH,
        bordersize = 0,
        margin_h = 0,
        margin_v = 0,
        radius = 0,
    }

    local handle = FrameContainer:new{
        bordersize = 0,
        background = Theme.PRIMARY,
        width = handle_sz,
        height = handle_sz,
    }

    local row_h = math.max(track_h, handle_sz)
    local hx = math.floor(perc * math.max(1, track_w - handle_sz))
    local hx_span = HorizontalSpan:new{ width = hx }

    local og = OverlapGroup:new{
        dimen = Geom:new{ w = sw, h = row_h },
    }
    og[1] = LeftContainer:new{
        dimen = Geom:new{ w = sw, h = row_h },
        VerticalGroup:new{
            VerticalSpan:new{ width = math.floor((row_h - track_h) / 2) },
            track,
        },
    }
    og[2] = LeftContainer:new{
        dimen = Geom:new{ w = sw, h = row_h },
        HorizontalGroup:new{
            hx_span,
            CenterContainer:new{
                dimen = Geom:new{ w = handle_sz, h = row_h },
                handle,
            },
        },
    }

    local sl_dim = Geom:new{ w = sw, h = row_h }
    local slider = InputContainer:new{
        dimen = sl_dim,
        ges_events = {
            Tap = {
                GestureRange:new{ ges = "tap", range = function() return sl_dim end },
            },
            Pan = {
                GestureRange:new{ ges = "pan", range = function() return sl_dim end },
            },
        },
    }
    function slider:updateFromPos(pos)
        if not pos or not slider.dimen then return end
        local x = pos.x - slider.dimen.x
        if x < 0 then x = 0 end
        if x > track_w then x = track_w end
        local p = math.floor(100 * x / track_w + 0.5)
        setFlFromPercent(powerd_ref, p)
        p = getFlPercent(powerd_ref) or p
        perc = p / 100
        track:setPercentage(perc)
        pct_txt:setText(string.format("%d%%", p))
        hx_span.width = math.floor(perc * math.max(1, track_w - handle_sz))
        UIManager:setDirty(self_ref, "ui")
    end
    function slider:onTap(_, ges)
        self_ref:resetIdleTimer()
        slider:updateFromPos(ges.pos)
        return true
    end
    function slider:onPan(_, ges)
        self_ref:resetIdleTimer()
        slider:updateFromPos(ges.pos)
        return true
    end
    slider[1] = og
    return slider
end

function ReadingToolbarWidget:resetIdleTimer()
    if self._idle_timer then
        UIManager:unschedule(self._idle_timer)
        self._idle_timer = nil
    end
    self:scheduleIdleReset()
end

function ReadingToolbarWidget:scheduleIdleReset()
    local self_ref = self
    self._idle_timer = function()
        if _toolbar == self_ref then
            M._close()
        end
    end
    UIManager:scheduleIn(8, self._idle_timer)
end

function ReadingToolbarWidget:onCloseWidget()
    if self._idle_timer then
        UIManager:unschedule(self._idle_timer)
        self._idle_timer = nil
    end
    _toolbar = nil
    _reader = nil
end

function M._close()
    if not _toolbar then return end
    UIManager:close(_toolbar)
    _toolbar = nil
    _reader = nil
    UIManager:setDirty(nil, "ui")
end

function M.show(reader_ui)
    if not reader_ui then return end
    if _toolbar then
        UIManager:close(_toolbar)
        _toolbar = nil
    end
    _reader = reader_ui
    local w = ReadingToolbarWidget:new{
        _reader_ui = reader_ui,
    }
    _toolbar = w
    UIManager:show(w)
    UIManager:setDirty(nil, "ui")
end

function M.onReaderReady(reader_ui)
    if not G_reader_settings:nilOrTrue("folio_enabled") then return end
    if reader_ui._folio_reading_toolbar_zones then return end
    reader_ui._folio_reading_toolbar_zones = true
    registerBottomSwipeZone(reader_ui)
end

function M.teardown()
    if _toolbar then
        pcall(function() UIManager:close(_toolbar) end)
        _toolbar = nil
        _reader = nil
    end
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local rui = ReaderUI and ReaderUI.instance
    if rui then
        pcall(function()
            if rui.unRegisterTouchZones then
                rui:unRegisterTouchZones({ { id = ZONE_ID } })
            elseif rui.unregisterTouchZones then
                rui:unregisterTouchZones({ { id = ZONE_ID } })
            end
        end)
    end
end

return M
