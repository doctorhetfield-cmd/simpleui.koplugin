-- module_clock.lua — Folio
-- Clock module: clock always visible, with optional date.

local CenterContainer = require("ui/widget/container/centercontainer")
local datetime        = require("datetime")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Device          = require("device")
local Screen          = Device.screen
local _               = require("gettext")

local UI           = require("folio_core")
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
local _BASE_BOT_PAD_EXTRA = Screen:scaleBySize(4)

-- ---------------------------------------------------------------------------
-- Settings keys
-- ---------------------------------------------------------------------------

local SETTING_ON      = "clock_enabled"   -- pfx .. "clock_enabled"
local SETTING_DATE    = "clock_date"      -- pfx .. "clock_date"    (default ON)

local function isDateEnabled(pfx)
    local v = G_reader_settings:readSetting(pfx .. SETTING_DATE)
    return v ~= false   -- default ON
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
    local bot_pad_extra = math.floor(_BASE_BOT_PAD_EXTRA * scale)

    local show_date = isDateEnabled(pfx)
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

    local h_base      = clock_w + PAD * 2 + PAD2
    local show_date   = isDateEnabled(ctx.pfx)
    local h = h_base
    if show_date then h = h + date_gap + date_h end
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
        _makeScaleItem(ctx_menu),
    }
end

return M