-- Per-module chrome: background + optional AA frame (Appearance ▸ Background).
-- Always inset (aligned with section labels). Applied once by the homescreen.

local Device = require("device")
local Screen = Device.screen
local Geom = require("ui/geometry")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local OverlapGroup = require("ui/widget/overlapgroup")

local SUISettings = require("infra/sui_store")
local Backdrop = require("infra/sui_backdrop")
local UI = require("infra/sui_core")
local SUIStyle = require("features/sui_style")
local SUIWallpaper = require("features/sui_wallpaper")

local M = {}
local PAD = UI.PAD
local _ = require("infra/sui_i18n").translate

-- Modules whose design is element-level (cards, buttons, empty space): the
-- module-wide card chrome does not apply. Match base ids and dynamic instances
-- (e.g. quick_actions_row_a1b2c3, spacer_row_...).
function M.skipsModuleChrome(id)
    if not id or id == "" then return false end
    if id == "reading_stats" then return true end
    if id:find("^quick_actions_row", 1, false) then return true end
    if id:find("^spacer_row", 1, false) then return true end
    return false
end

-- Whether the module's frame is switched on (a stored per-module toggle).
function M.isFrameOn(pfx, id)
    return SUISettings:isTrue((pfx or "simpleui_hs_") .. (id or "") .. "_show_frame")
end

function M.setShowFrame(pfx, id, on)
    SUISettings:saveSetting(pfx .. id .. "_show_frame", on and true or false)
end

-- Resolved chrome of a module: backdrop `strength` (0-100) and the frame's
-- `border_sz` in pixels (0 = no frame). Modules that skip chrome resolve to
-- neither.
function M.resolve(pfx, id)
    pfx = pfx or "simpleui_hs_"
    id = id or ""
    local chrome = { strength = 0, border_sz = 0, pfx = pfx, id = id }
    if not M.skipsModuleChrome(id) then
        chrome.strength = SUIWallpaper.getModuleBackdropStrength(pfx, id)
        chrome.border_sz = M.isFrameOn(pfx, id) and SUIStyle.BORDER_SZ or 0
    end
    return chrome
end

function M.setStrength(pfx, id, n)
    SUIWallpaper.setModuleBackdropStrength(n, pfx, id)
end

function M.hasChrome(chrome)
    return chrome.strength > 0 or chrome.border_sz > 0
end

-- Lateral inset matching section labels (padding_left/right = PAD).
-- Always applied so module content lines up with labels whether or not
-- a visual card (fill/frame) is drawn.
function M.outerMargin(_chrome)
    return PAD
end

function M.innerPad(chrome)
    return M.hasChrome(chrome) and PAD or 0
end

-- Size the box adds to its content on each axis: padding and border on both
-- sides.
function M.boxInset(chrome)
    return (M.innerPad(chrome) + chrome.border_sz) * 2
end

function M.radius(chrome, scale)
    if not M.hasChrome(chrome) then return 0 end
    return math.floor(Screen:scaleBySize(12) * (scale or 1))
end

function M.contentWidth(col_w, chrome)
    return math.max(1, col_w - M.outerMargin(chrome) * 2 - M.boxInset(chrome))
end

-- Space left of a box narrower than its column, for the given alignment.
local function leadingGap(free_w, align)
    if align == "right" then return free_w end
    if align == "center" then return math.floor(free_w / 2) end
    return 0
end

-- Insets `content` to the label column and draws the module chrome around it.
-- The box spans the column unless `content.fit_align` ("left" | "center" |
-- "right") is set: the box is then sized to the content and placed in the
-- column according to that alignment.
function M.wrap(content, chrome, col_w, scale)
    if not content then return content end

    local outer_m = M.outerMargin(chrome)
    local frame_pad = M.innerPad(chrome) + chrome.border_sz
    local col_box_w = math.max(1, col_w - outer_m * 2)

    local box_w = col_box_w
    if content.fit_align then
        box_w = math.min(col_box_w, content:getSize().w + M.boxInset(chrome))
    end
    local free_w = col_box_w - box_w
    local lead_w = leadingGap(free_w, content.fit_align)

    -- Outer inset matching section labels. Cap the content width so a
    -- wide child (e.g. heatmap grid) cannot paint past the label column.
    local function withOuter(widget)
        if outer_m <= 0 then return widget end
        if widget and widget.dimen then
            local sz = widget.getSize and widget:getSize()
            local wh = (sz and sz.h) or 0
            widget.dimen = Geom:new{ w = box_w, h = widget.dimen.h or wh }
        end
        return HorizontalGroup:new{
            align = "top",
            HorizontalSpan:new{ width = outer_m + lead_w },
            widget,
            HorizontalSpan:new{ width = outer_m + free_w - lead_w },
        }
    end

    -- No card: only lateral inset so content lines up with section labels.
    if not M.hasChrome(chrome) then
        return withOuter(content)
    end

    local radius = M.radius(chrome, scale)

    -- Content inset; fill/frame drawn by a sibling under it in OverlapGroup.
    local fc = FrameContainer:new{
        bordersize = 0,
        radius = 0,
        padding = frame_pad,
        background = nil,
        content,
    }
    local sz = fc:getSize()
    local box_h = math.max(1, sz.h)

    local bg = Backdrop.BackdropFill:new{
        width = box_w,
        height = box_h,
        strength = chrome.strength,
        radius = radius,
        border_sz = chrome.border_sz,
    }

    fc.dimen = Geom:new{ w = box_w, h = box_h }
    bg.dimen = Geom:new{ w = box_w, h = box_h }

    local box = OverlapGroup:new{
        dimen = Geom:new{ w = box_w, h = box_h },
        bg,
        fc,
    }

    return withOuter(box)
end

-- "Background" submenu: Frame toggle and Background Opacity. The opacity item
-- is listed only while a wallpaper is active, since it has no effect
-- otherwise. Returns nil for modules that skip module-wide chrome.
function M.makeBackgroundItem(pfx, id, refresh, _lc)
    _lc = _lc or _
    if M.skipsModuleChrome(id) then return nil end
    local Config = require("infra/sui_config")
    local items = {
        {
            text = _lc("Frame"),
            checked_func = function() return M.isFrameOn(pfx, id) end,
            keep_menu_open = true,
            callback = function()
                M.setShowFrame(pfx, id, not M.isFrameOn(pfx, id))
                if refresh then refresh() end
            end,
        },
    }
    if SUIWallpaper.isWallpaperActive() then
        items[#items + 1] = Config.makeBackdropStrengthItem({
            title         = _lc("Background Opacity"),
            get           = function() return M.resolve(pfx, id).strength end,
            set           = function(v) M.setStrength(pfx, id, v) end,
            refresh       = function() if refresh then refresh() end end,
            default_value = Backdrop.BACKDROP_DEFAULT.module,
            _lc           = _lc,
        })
    end
    return { text = _lc("Background"), sub_item_table = items }
end

local function isAppearance(entry, _lc)
    local label = entry.text
    if type(entry.text_func) == "function" then
        local ok, s = pcall(entry.text_func)
        if ok then label = s end
    end
    return label == _lc("Appearance")
end

-- Adds the Background submenu first in the module's Appearance submenu,
-- creating that submenu when the module has none.
function M.mergeAppearanceIntoItems(items, pfx, id, refresh, _lc)
    _lc = _lc or _
    local background = M.makeBackgroundItem(pfx, id, refresh, _lc)
    if type(items) ~= "table" or not background then return items end

    for _, entry in ipairs(items) do
        if isAppearance(entry, _lc) then
            if type(entry.sub_item_table) == "table" then
                table.insert(entry.sub_item_table, 1, background)
            else
                entry.sub_item_table = { background }
            end
            return items
        end
    end

    items[#items + 1] = { text = _lc("Appearance"), sub_item_table = { background } }
    return items
end

return M
