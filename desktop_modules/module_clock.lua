-- module_clock.lua — Folio
-- Clock module: clock always visible, with optional date and battery toggles.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local datetime        = require("datetime")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local _               = require("gettext")

local UI           = require("folio_core")
local UIManager    = require("ui/uimanager")
local Config       = require("folio_config")
local FolioTheme     = require("folio_theme")
local Theme        = FolioTheme.Theme
local PAD          = UI.PAD
local PAD2         = UI.PAD2
-- ---------------------------------------------------------------------------
-- Pixel constants — base values at 100% scale; scaled at render time.
-- ---------------------------------------------------------------------------

local _BASE_CLOCK_W       = Screen:scaleBySize(50)
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

    -- Scale all dimensions from base values; clock uses Newsreader DISPLAY (DESIGN.md).
    local clock_face_sz = math.max(10, math.floor(FolioTheme.sizeDisplay() * scale))
    local clock_w       = math.max(math.floor(_BASE_CLOCK_W * scale), clock_face_sz + 8)
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
            face = FolioTheme.faceContent(clock_face_sz),
            bold = true,
            fgcolor = Theme.TEXT,
        },
    }

    if show_date then
        vg[#vg+1] = _vspan(date_gap, vspan_pool)
        local date_str = os.date("%A, %B %d")
        vg[#vg+1] = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = date_h },
            TextWidget:new{
                text    = date_str:upper(),
                face    = FolioTheme.faceUI(date_fs),
                fgcolor = Theme.TEXT_MUTED,
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
                face    = FolioTheme.faceUI(batt_fs),
                fgcolor = Theme.TEXT_MUTED,
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

function M.build(w, ctx)
    return build(w, ctx.pfx, ctx.vspan_pool)
end

function M.getHeight(ctx)
    local scale     = Config.getModuleScale("clock", ctx.pfx)
    local clock_face_sz = math.max(10, math.floor(FolioTheme.sizeDisplay() * scale))
    local clock_w   = math.max(math.floor(_BASE_CLOCK_W * scale), clock_face_sz + 8)
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