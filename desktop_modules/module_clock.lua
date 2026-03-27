-- module_clock.lua — Simple UI
-- Clock module: clock always visible, with optional date and battery toggles.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local datetime        = require("datetime")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local _               = require("gettext")

local UI           = require("sui_core")
local UIManager    = require("ui/uimanager")
local Config       = require("sui_config")
local PAD          = UI.PAD
local PAD2         = UI.PAD2
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

-- ---------------------------------------------------------------------------
-- Translated date string
-- os.date("%A, %d %B") always returns English on most eReader locales.
-- We use os.date("*t") for the numeric indices and look up translated names.
-- ---------------------------------------------------------------------------

-- _WEEKDAYS and _MONTHS are intentionally built inside _localDate so that
-- _() is called at render time, after the user's locale has been loaded.
-- Building them at module-load time (file level) would freeze them to the
-- default locale because require() runs before KOReader applies translations.
local function _localDate()
    -- Pass os.time() explicitly: os.date("*t") without argument can return
    -- nil in LuaJIT on some platforms (macOS emulator) when timezone handling
    -- fails. os.date("*t", os.time()) is always safe.
    local now = os.time()
    local t   = os.date("*t", now)
    if not t or not t.mday then
        -- Fallback via the datetime module's locale-aware formatter.
        return datetime.secondsToDate(now, true)
    end
    local weekdays = {
        _("Sunday"), _("Monday"), _("Tuesday"), _("Wednesday"),
        _("Thursday"), _("Friday"), _("Saturday"),
    }
    local months = {
        _("January"), _("February"), _("March"),     _("April"),
        _("May"),     _("June"),     _("July"),       _("August"),
        _("September"), _("October"), _("November"),  _("December"),
    }
    local weekday = weekdays[t.wday] or os.date("%A", now)
    local month   = months[t.month]  or os.date("%B", now)
    return string.format("%s, %d %s", weekday, t.mday, month)
end

-- ---------------------------------------------------------------------------
-- Pixel constants — base values at 100% scale; scaled at render time.
-- ---------------------------------------------------------------------------

local _BASE_CLOCK_W       = Screen:scaleBySize(50)
local _BASE_CLOCK_FS      = Screen:scaleBySize(44)
local _BASE_DATE_H        = Screen:scaleBySize(17)
local _BASE_DATE_GAP      = Screen:scaleBySize(19)
local _BASE_DATE_FS       = Screen:scaleBySize(11)
local _BASE_BATT_FS       = Screen:scaleBySize(10)
local _BASE_BATT_H        = Screen:scaleBySize(15)
local _BASE_BATT_GAP      = Screen:scaleBySize(6)
local _BASE_BOT_PAD_EXTRA = Screen:scaleBySize(4)

-- ---------------------------------------------------------------------------
-- Settings keys
-- ---------------------------------------------------------------------------

local SETTING_ON      = "clock_enabled"   -- pfx .. "clock_enabled"
local SETTING_DATE    = "clock_date"      -- pfx .. "clock_date"    (default ON)
local SETTING_BATTERY = "clock_battery"   -- pfx .. "clock_battery" (default ON)

local function isDateEnabled(pfx)
    local v = G_reader_settings:readSetting(pfx .. SETTING_DATE)
    return v ~= false   -- default ON
end

local function isBattEnabled(pfx)
    local v = G_reader_settings:readSetting(pfx .. SETTING_BATTERY)
    return v ~= false   -- default ON
end

-- ---------------------------------------------------------------------------
-- Battery helpers
-- ---------------------------------------------------------------------------

-- Returns battery level clamped to [0,100] and charging flag.
local function _battInfo()
    local pwr = Device:getPowerDevice()
    if not pwr then return nil, false end
    local lvl, charging = nil, false
    if pwr.getCapacity then
        local ok, v = pcall(pwr.getCapacity, pwr)
        if ok and type(v) == "number" then
            lvl = v < 0 and 0 or v > 100 and 100 or v
        end
    end
    if pwr.isCharging then
        local ok, v = pcall(pwr.isCharging, pwr); if ok then charging = v end
    end
    return lvl, charging
end

-- lvl is always a number in [0,100] or nil (normalised by _battInfo).
-- Battery always uses CLR_TEXT_SUB — same subdued grey as date and author text.

-- Builds the battery display string.
-- Uses ▰/▱ (filled/empty blocks) matching module_header.lua visual style.
-- Charging replaces the first block with ⚡.
local function _battText(lvl, charging)
    if type(lvl) ~= "number" then return "N/A" end
    local bars
    if     lvl >= 90 then bars = "▰▰▰▰"
    elseif lvl >= 60 then bars = "▰▰▰▱"
    elseif lvl >= 40 then bars = "▰▰▱▱"
    elseif lvl >= 20 then bars = "▰▱▱▱"
    else                  bars = "▱▱▱▱" end
    local icon = charging and ("⚡" .. bars:sub(4)) or bars
    return string.format("%s %d%%", icon, lvl)
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

local function _vspan(px, pool)
    if pool then
        if not pool[px] then pool[px] = VerticalSpan:new{ width = px } end
        return pool[px]
    end
    return VerticalSpan:new{ width = px }
end

local function build(w, pfx, vspan_pool)
    local scale     = Config.getModuleScale("clock", pfx)

    -- Scale all dimensions from base values.
    local clock_w       = math.floor(_BASE_CLOCK_W       * scale)
    local clock_fs      = math.max(10, math.floor(_BASE_CLOCK_FS  * scale))
    local date_h        = math.max(8,  math.floor(_BASE_DATE_H    * scale))
    local date_gap      = math.max(2,  math.floor(_BASE_DATE_GAP  * scale))
    local date_fs       = math.max(8,  math.floor(_BASE_DATE_FS   * scale))
    local batt_fs       = math.max(7,  math.floor(_BASE_BATT_FS   * scale))
    local batt_h        = math.max(7,  math.floor(_BASE_BATT_H    * scale))
    local batt_gap      = math.max(2,  math.floor(_BASE_BATT_GAP  * scale))
    local bot_pad_extra = math.floor(_BASE_BOT_PAD_EXTRA * scale)

    local show_date = isDateEnabled(pfx)
    local show_batt = isBattEnabled(pfx)
    local inner_w   = w - PAD * 2

    local vg = VerticalGroup:new{ align = "center" }

    -- Clock — always shown.
    vg[#vg+1] = CenterContainer:new{
        dimen = Geom:new{ w = inner_w, h = clock_w },
        TextWidget:new{
            text = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")),
            face = Font:getFace("smallinfofont", clock_fs),
            bold = true,
        },
    }

    if show_date then
        vg[#vg+1] = _vspan(date_gap, vspan_pool)
        vg[#vg+1] = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = date_h },
            TextWidget:new{
                text    = _localDate(),
                face    = Font:getFace("smallinfofont", date_fs),
                fgcolor = CLR_TEXT_SUB,
            },
        }
    end

    if show_batt then
        vg[#vg+1] = _vspan(batt_gap, vspan_pool)
        local lvl, charging = _battInfo()
        vg[#vg+1] = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = batt_h },
            TextWidget:new{
                text    = _battText(lvl, charging),
                face    = Font:getFace("smallinfofont", batt_fs),
                fgcolor = CLR_TEXT_SUB,
            },
        }
    end

    return FrameContainer:new{
        bordersize     = 0,
        padding        = PAD,
        padding_bottom = PAD2 + bot_pad_extra,
        vg,
    }
end

-- ---------------------------------------------------------------------------
-- Module API
-- ---------------------------------------------------------------------------

local M = {}

M.id         = "clock"
M.name       = _("Clock")
M.label      = nil
M.default_on = true

function M.isEnabled(pfx)
    local v = G_reader_settings:readSetting(pfx .. SETTING_ON)
    if v ~= nil then return v == true end
    return true
end

function M.setEnabled(pfx, on)
    G_reader_settings:saveSetting(pfx .. SETTING_ON, on)
end

M.getCountLabel = nil

-- ---------------------------------------------------------------------------
-- Surgical clock tick — rebuilds only the clock widget inside the body
-- VerticalGroup, without triggering a full homescreen rebuild.
--
-- The homescreen records _clock_body_ref, _clock_body_idx, and
-- _clock_is_wrapped during _buildContent() (see below).  The tick reads
-- those fields to do a targeted swap, then marks only the navbar container
-- dirty.  Falls back to a full _refresh() if the index was not recorded.
-- ---------------------------------------------------------------------------

local _timer     = nil   -- scheduled function reference (module-level singleton)
local _hs_widget = nil   -- weak reference to the live HomescreenWidget

local function _tick()
    _timer = nil   -- timer has fired; clear before rescheduling

    -- Abort if the homescreen instance has changed or gone away.
    local hs = _hs_widget
    if not hs then return end
    local HS = package.loaded["sui_homescreen"]
    if not HS or HS._instance ~= hs then _hs_widget = nil; return end

    -- Do not update while suspended — some platforms fire pending timers
    -- during the suspend transition before the scheduler pauses.
    if hs._simpleui_suspended or hs._suspended then
        M.scheduleRefresh(hs)   -- reschedule so we resume on wakeup
        return
    end

    -- Do not update while a book is open — the homescreen is hidden anyway.
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance then
        M.scheduleRefresh(hs)
        return
    end

    -- Fast path: swap only the clock widget in the body VerticalGroup.
    local body       = hs._clock_body_ref
    local idx        = hs._clock_body_idx
    local is_wrapped = hs._clock_is_wrapped
    local swapped    = false

    if body and idx and body[idx] and hs._navbar_container then
        local sw      = Screen:getWidth()
        local SIDE_PAD = require("sui_core").SIDE_M()
        local inner_w  = hs._clock_inner_w or (sw - SIDE_PAD * 2)
        local ok_w, new_widget = pcall(build, inner_w, hs._clock_pfx,
                                        hs._vspan_pool)
        if ok_w and new_widget then
            if is_wrapped then
                -- The clock was wrapped in an InputContainer for hold-to-settings.
                -- Replace the inner slot [1] to keep the gesture handler alive.
                body[idx][1] = new_widget
            else
                body[idx] = new_widget
            end
            UIManager:setDirty(hs._navbar_container, "ui")
            swapped = true
        end
    end

    if not swapped then
        -- Slow-path fallback: trigger a full homescreen refresh.
        local ok = pcall(function() hs:_refresh(false) end)
        if not ok then _hs_widget = nil; return end
    end

    M.scheduleRefresh(hs)
end

-- Schedule the next tick, aligned to the next minute boundary.
-- Safe to call repeatedly — cancels any pending timer first.
function M.scheduleRefresh(hs)
    if _timer then
        UIManager:unschedule(_timer)
        _timer = nil
    end
    _hs_widget = hs
    local secs = 60 - (os.time() % 60) + 1
    _timer = _tick
    UIManager:scheduleIn(secs, _timer)
end

-- Cancel any pending timer and release the homescreen reference.
-- Called from onSuspend and onCloseWidget.
function M.cancelRefresh()
    if _timer then
        UIManager:unschedule(_timer)
        _timer = nil
    end
    _hs_widget = nil
end

function M.build(w, ctx)
    -- Record swap coordinates on the homescreen widget so the tick can do a
    -- surgical replacement without rebuilding the entire page.  These fields
    -- are written here (inside build) because build() is called from within
    -- the module loop in _buildContent(), at which point the body index is
    -- not yet known to the homescreen.  The homescreen sets _clock_body_idx
    -- immediately after build() returns (see sui_homescreen.lua).
    if ctx._hs_widget then
        ctx._hs_widget._clock_pfx      = ctx.pfx
        ctx._hs_widget._clock_inner_w  = w
    end
    return build(w, ctx.pfx, ctx.vspan_pool)
end

function M.getHeight(ctx)
    local scale     = Config.getModuleScale("clock", ctx.pfx)
    local clock_w   = math.floor(_BASE_CLOCK_W   * scale)
    local date_h    = math.max(8, math.floor(_BASE_DATE_H   * scale))
    local date_gap  = math.max(2, math.floor(_BASE_DATE_GAP * scale))
    local batt_h    = math.max(7, math.floor(_BASE_BATT_H   * scale))
    local batt_gap  = math.max(2, math.floor(_BASE_BATT_GAP * scale))

    local h_base      = clock_w + PAD * 2 + PAD2
    local show_date   = isDateEnabled(ctx.pfx)
    local show_batt   = isBattEnabled(ctx.pfx)
    local h = h_base
    if show_date then h = h + date_gap + date_h end
    if show_batt then h = h + batt_gap + batt_h end
    return h
end


local function _makeScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size."),
        get          = function() return Config.getModuleScalePct("clock", pfx) end,
        set          = function(v) Config.setModuleScale(v, "clock", pfx) end,
        refresh      = ctx_menu.refresh,
    })
end
function M.getMenuItems(ctx_menu)
    local pfx     = ctx_menu.pfx
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._

    local function toggle(key, current)
        G_reader_settings:saveSetting(pfx .. key, not current)
        refresh()
    end

    return {
        {
            text_func    = function()
                return _lc("Show Date") .. " — " .. (isDateEnabled(pfx) and _lc("On") or _lc("Off"))
            end,
            checked_func   = function() return isDateEnabled(pfx) end,
            keep_menu_open = true,
            callback       = function() toggle(SETTING_DATE, isDateEnabled(pfx)) end,
        },
        {
            text_func    = function()
                return _lc("Show Battery") .. " — " .. (isBattEnabled(pfx) and _lc("On") or _lc("Off"))
            end,
            checked_func   = function() return isBattEnabled(pfx) end,
            keep_menu_open = true,
            callback       = function() toggle(SETTING_BATTERY, isBattEnabled(pfx)) end,
        },
        _makeScaleItem(ctx_menu),
    }
end

return M