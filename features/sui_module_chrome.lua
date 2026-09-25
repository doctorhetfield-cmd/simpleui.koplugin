-- Per-module chrome: background + optional AA frame (Appearance).
-- Always inset (aligned with section labels). Applied once by the homescreen.

local Device = require("device")
local Screen = Device.screen
local Geom = require("ui/geometry")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local OverlapGroup = require("ui/widget/overlapgroup")
local Widget = require("ui/widget/widget")

local SUISettings = require("infra/sui_store")
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

function M.resolve(pfx, id)
    pfx = pfx or "simpleui_hs_"
    id = id or ""
    if M.skipsModuleChrome(id) then
        return {
            strength = 0,
            show_frame = false,
            pfx = pfx,
            id = id,
        }
    end
    return {
        strength = SUIWallpaper.getModuleBackdropStrength(pfx, id),
        show_frame = SUISettings:isTrue(pfx .. id .. "_show_frame"),
        pfx = pfx,
        id = id,
    }
end

function M.setStrength(pfx, id, n)
    SUIWallpaper.setModuleBackdropStrength(n, pfx, id)
end

function M.setShowFrame(pfx, id, on)
    SUISettings:saveSetting(pfx .. id .. "_show_frame", on and true or false)
end

function M.hasChrome(chrome)
    return chrome.strength > 0 or chrome.show_frame
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

function M.borderSz(chrome)
    return chrome.show_frame and SUIStyle.BORDER_SZ or 0
end

function M.radius(chrome, scale)
    if not M.hasChrome(chrome) then return 0 end
    return math.floor(Screen:scaleBySize(12) * (scale or 1))
end

function M.contentWidth(col_w, chrome)
    local o = M.outerMargin(chrome)
    local i = M.innerPad(chrome)
    local b = M.borderSz(chrome)
    return math.max(1, col_w - o * 2 - i * 2 - b * 2)
end

-- Dedicated background layer. Owns its size so paint never depends on a
-- parent having assigned dimen first (the previous FrameContainer paintTo
-- override could be skipped when dimen was unset during some refresh paths).
local ChromeBg = Widget:extend{
    width = 0,
    height = 0,
    strength = 0,
    radius = 0,
    show_frame = false,
}

function ChromeBg:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function ChromeBg:paintTo(bb, x, y)
    local w, h = self.width, self.height
    if w <= 0 or h <= 0 then return end
    if self.strength > 0 then
        SUIWallpaper.paintBackdrop(bb, x, y, w, h, self.strength, self.radius)
    end
    if self.show_frame then
        SUIWallpaper.paintFrame(bb, x, y, w, h, SUIStyle.BORDER_SZ, self.radius, SUIStyle.COLOR.gray)
    end
end

function M.wrap(content, chrome, col_w, scale)
    if not content then return content end

    local outer_m = M.outerMargin(chrome)
    local box_w = math.max(1, col_w - outer_m * 2)

    -- Outer inset matching section labels. Cap the content width so a
    -- wide child (e.g. heatmap grid) cannot paint past the label column.
    local function withOuter(widget)
        if outer_m <= 0 then return widget end
        local inner_w = box_w
        if widget then
            local sz = widget.getSize and widget:getSize()
            local wh = (sz and sz.h) or (widget.dimen and widget.dimen.h) or 0
            if widget.dimen then
                widget.dimen = Geom:new{ w = inner_w, h = widget.dimen.h or wh }
            end
        end
        return HorizontalGroup:new{
            align = "top",
            HorizontalSpan:new{ width = outer_m },
            widget,
            HorizontalSpan:new{ width = outer_m },
        }
    end

    -- No card: only lateral inset so content lines up with section labels.
    if not M.hasChrome(chrome) then
        return withOuter(content)
    end

    local inner_p = M.innerPad(chrome)
    local border = M.borderSz(chrome)
    local radius = M.radius(chrome, scale)

    -- Content inset; fill/frame drawn by a sibling under it in OverlapGroup.
    local fc = FrameContainer:new{
        bordersize = 0,
        radius = 0,
        padding = inner_p + border,
        background = nil,
        content,
    }
    local sz = fc:getSize()
    local box_h = math.max(1, sz.h)

    local bg = ChromeBg:new{
        width = box_w,
        height = box_h,
        strength = chrome.strength,
        radius = radius,
        show_frame = chrome.show_frame,
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

-- Frame + Background only (no full-width option).
-- Returns an empty list for modules that skip module-wide chrome.
function M.makeAppearanceItems(pfx, id, refresh, _lc)
    _lc = _lc or _
    if M.skipsModuleChrome(id) then return {} end
    local Config = require("infra/sui_config")
    return {
        {
            text = _lc("Frame"),
            checked_func = function() return M.resolve(pfx, id).show_frame end,
            keep_menu_open = true,
            callback = function()
                local c = M.resolve(pfx, id)
                M.setShowFrame(pfx, id, not c.show_frame)
                if refresh then refresh() end
            end,
        },
        Config.makeBackdropStrengthItem({
            title         = _lc("Background Opacity"),
            get           = function() return M.resolve(pfx, id).strength end,
            set           = function(v) M.setStrength(pfx, id, v) end,
            refresh       = function() if refresh then refresh() end end,
            default_value = SUIWallpaper.BACKDROP_DEFAULT.module,
            _lc           = _lc,
        }),
    }
end

-- Merge chrome into an existing Appearance submenu, or append one.
function M.mergeAppearanceIntoItems(items, pfx, id, refresh, _lc)
    _lc = _lc or _
    local chrome_items = M.makeAppearanceItems(pfx, id, refresh, _lc)
    if type(items) ~= "table" then return items end
    if #chrome_items == 0 then return items end

    local function is_appearance(entry)
        if not entry then return false end
        local t = entry.text
        if type(t) == "string" and t == _lc("Appearance") then return true end
        if type(entry.text_func) == "function" then
            local ok, s = pcall(entry.text_func)
            if ok and s == _lc("Appearance") then return true end
        end
        return false
    end

    for _, entry in ipairs(items) do
        if is_appearance(entry) then
            local sub = entry.sub_item_table
            if type(sub) ~= "table" then
                entry.sub_item_table = chrome_items
                return items
            end
            -- Prepend Frame + Background if not already present.
            local has_frame, has_bg = false, false
            for _, it in ipairs(sub) do
                local label = it.text
                if type(it.text_func) == "function" then
                    local ok, s = pcall(it.text_func)
                    if ok then label = s end
                end
                if label == _lc("Frame") then has_frame = true end
                if label == _lc("Background Opacity") then has_bg = true end
            end
            local merged = {}
            if not has_frame then merged[#merged + 1] = chrome_items[1] end
            if not has_bg then merged[#merged + 1] = chrome_items[2] end
            for _, it in ipairs(sub) do
                local label = it.text
                if type(it.text_func) == "function" then
                    local ok, s = pcall(it.text_func)
                    if ok then label = s end
                end
                if label ~= _lc("Frame") and label ~= _lc("Background Opacity")
                   and label ~= _lc("Background width")
                   and label ~= _lc("Solid Background") then
                    merged[#merged + 1] = it
                end
            end
            entry.sub_item_table = merged
            return items
        end
    end

    items[#items + 1] = {
        text = _lc("Appearance"),
        sub_item_table = chrome_items,
    }
    return items
end

return M
