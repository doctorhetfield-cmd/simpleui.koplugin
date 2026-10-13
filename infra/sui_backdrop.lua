-- sui_backdrop.lua — Simple UI
-- Translucent surface painting shared by every bar, card and label that can
-- sit over a background image.
--
-- A backdrop's strength is one 0–100 scale:
--   0    transparent — nothing is painted
--   1–99 scrim — the surface colour blended over what is already there
--   100  solid surface
--
-- This module provides:
--   * the strength scale: clamping, persistence, menu label and the semantic
--     default of every surface;
--   * the painters: paintBackdrop (anti-aliased fill) and paintFrame
--     (anti-aliased border);
--   * BackdropFill, a background-layer widget built on both painters.
--
-- It knows nothing about the wallpaper itself. Deciding whether a backdrop
-- applies (for instance, only while a wallpaper is active) is left to callers.

local Device      = require("device")
local Geom        = require("ui/geometry")
local Widget      = require("ui/widget/widget")
local AA          = require("infra/sui_aa_paint")
local SUISettings = require("infra/sui_store")
local translate   = require("infra/sui_i18n").translate

local M = {}

-- ---------------------------------------------------------------------------
-- Strength scale
-- ---------------------------------------------------------------------------

local STRENGTH_MIN, STRENGTH_MAX = 0, 100
M.STRENGTH_MIN, M.STRENGTH_MAX = STRENGTH_MIN, STRENGTH_MAX

-- Semantic default strength of every surface. Bars keep the solid look of a
-- plain UI; cards, buttons and the cover strip start solid; modules start
-- transparent over the wallpaper.
M.BACKDROP_DEFAULT = {
    statusbar    = 100,
    navbar       = 100,
    pagination   = 100,
    titlebar     = 100,
    module       = 0,
    cover_strip  = 100,
    folder_label = 75,
    card         = 100,
    button       = 100,
}

-- Rounds and clamps n to the strength scale; nil when n is not a number.
local function _clampBackdrop(n)
    n = tonumber(n)
    if not n then return nil end
    return math.max(STRENGTH_MIN, math.min(STRENGTH_MAX, math.floor(n + 0.5)))
end
M.clampBackdropStrength = _clampBackdrop

-- Reads a strength setting; `default` applies when it is unset or invalid.
function M.readBackdropStrength(key, default)
    return _clampBackdrop(SUISettings:readSetting(key)) or default
end

-- Stores a strength setting and returns the stored value. Invalid input is
-- ignored and returns nil.
function M.saveBackdropStrength(key, n)
    local v = _clampBackdrop(n)
    if v then SUISettings:saveSetting(key, v) end
    return v
end

-- Human-readable strength label for menus: Transparent / N% / Solid.
-- `tr` overrides the translator for callers that carry their own.
function M.formatBackdropStrength(s, tr)
    tr = tr or translate
    s = tonumber(s) or 0
    if s <= STRENGTH_MIN then return tr("Transparent") end
    if s >= STRENGTH_MAX then return tr("Solid") end
    return tostring(s) .. "%"
end

-- ---------------------------------------------------------------------------
-- Painters
-- ---------------------------------------------------------------------------

-- The style catalogue lives in a higher layer, so it is resolved on first use
-- rather than at load time.
local function _style()
    return require("features/sui_style")
end

-- Tile a rounded rect into non-overlapping horizontal spans so each pixel is
-- written once (blending corners separately would double-tint them).
local _SQUARE_SPAN = { {} }
local function _roundedSpans(x, y, w, h, r)
    r = math.min(r or 0, math.floor(w / 2), math.floor(h / 2))
    if r <= 0 then
        local sp = _SQUARE_SPAN[1]
        sp.x, sp.y, sp.w, sp.h = x, y, w, h
        return _SQUARE_SPAN
    end
    local spans = {}
    for i = 0, r - 1 do
        local dy = r - i - 0.5
        local inset = math.floor(r - math.sqrt(r * r - dy * dy) + 0.5)
        local sw = w - inset * 2
        if sw > 0 then
            spans[#spans + 1] = { x = x + inset, y = y + i,         w = sw, h = 1 }
            spans[#spans + 1] = { x = x + inset, y = y + h - 1 - i, w = sw, h = 1 }
        end
    end
    local mid_h = h - r * 2
    if mid_h > 0 then
        spans[#spans + 1] = { x = x, y = y + r, w = w, h = mid_h }
    end
    return spans
end

-- Runs fn with the buffer's inverse flag cleared on Android, where night
-- mode may set it: the logical colour is then written exactly once and
-- frame inversion turns it into its night-mode counterpart. Returns pcall's
-- results.
function M.withInverseGuard(bb, fn)
    local suppress = Device:isAndroid() and bb.getInverse and bb:getInverse() == 1
    if suppress then bb:setInverse(0) end
    local ok, result = pcall(fn)
    if suppress then bb:setInverse(1) end
    return ok, result
end

-- Paint a backdrop into bb.
-- strength: 0 no-op, 1–99 scrim (what is underneath shows through), 100 solid
-- surface.
-- radius: optional corner radius, drawn with anti-aliased corners.
-- color: optional fill override (e.g. surface_flat for flat cards/buttons).
--
-- No day/night colour branch: always paint the light-mode surface colour
-- (white by default). Frame inversion turns it black in night mode while
-- preserving the same alpha.
function M.paintBackdrop(bb, x, y, w, h, strength, radius, color)
    strength = _clampBackdrop(strength) or STRENGTH_MIN
    if strength <= STRENGTH_MIN or w <= 0 or h <= 0 then return end
    local alpha = math.floor(255 * strength / STRENGTH_MAX + 0.5)
    local c = color or _style().COLOR.surface
    radius = math.max(0, math.floor(tonumber(radius) or 0))

    local ok, drawn = M.withInverseGuard(bb, function()
        return AA.fillRoundedRect(bb, x, y, w, h, radius, c, alpha)
    end)
    if ok and drawn then return end

    -- Corners without anti-aliasing.
    M.withInverseGuard(bb, function()
        for _, sp in ipairs(_roundedSpans(x, y, w, h, radius)) do
            AA.fillRect(bb, sp.x, sp.y, sp.w, sp.h, c, alpha)
        end
    end)
end

-- Paint an opaque rounded border of `thickness` inside (x, y, w, h), with
-- anti-aliased corners where the radius allows it.
function M.paintFrame(bb, x, y, w, h, thickness, radius, color)
    thickness = math.max(1, math.floor(tonumber(thickness) or 1))
    radius = math.max(0, math.floor(tonumber(radius) or 0))

    local ok, drawn = M.withInverseGuard(bb, function()
        return AA.strokeRoundedRect(bb, x, y, w, h, radius, thickness, color)
    end)
    if ok and drawn then return end

    if type(bb.paintBorderRGB32) == "function" then
        M.withInverseGuard(bb, function()
            bb:paintBorderRGB32(x, y, w, h, thickness, color, radius, true)
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Widget
-- ---------------------------------------------------------------------------

-- Background layer: a backdrop (see paintBackdrop) with an optional frame.
-- Owns its size so painting never depends on a parent having assigned dimen
-- first. Meant to sit under content in an OverlapGroup, so the content
-- stays solid while only the background is translucent.
--   width, height  box size
--   strength       0–100, as paintBackdrop (default 100)
--   radius         corner radius (default 0)
--   color          fill colour override (default: surface)
--   border_sz      border thickness drawn through paintFrame (default 0: none)
--   border_color   border colour (default: gray)
-- Fill and border share the radius, so their rounded corners always match.
M.BackdropFill = Widget:extend{
    width        = 0,
    height       = 0,
    strength     = STRENGTH_MAX,
    radius       = 0,
    color        = nil,
    border_sz    = 0,
    border_color = nil,
}

function M.BackdropFill:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function M.BackdropFill:paintTo(bb, x, y)
    local w, h = self.width, self.height
    if w <= 0 or h <= 0 then return end
    M.paintBackdrop(bb, x, y, w, h, self.strength, self.radius, self.color)
    if self.border_sz > 0 then
        M.paintFrame(bb, x, y, w, h, self.border_sz, self.radius,
            self.border_color or _style().COLOR.gray)
    end
end

return M
