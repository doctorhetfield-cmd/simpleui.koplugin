-- folio_theme.lua — Folio
-- Editorial E-Ink design tokens (DESIGN.md). All UI colors/fonts resolve here.

local Blitbuffer = require("ffi/blitbuffer")
local Font       = require("ui/font")
local Device     = require("device")
local Screen     = Device.screen

local M = {}

-- Luminance → KOReader grayscale (0 = black, 1 = white)
local function _lum(r, g, b)
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255
end

local function _gray(r, g, b)
    return Blitbuffer.gray(_lum(r, g, b))
end

-- ---------------------------------------------------------------------------
-- Surfaces & ink — DESIGN.md palette (no raw Blitbuffer in feature modules)
-- ---------------------------------------------------------------------------
M.Theme = {
    BG           = _gray(249, 249, 249),
    SURFACE_LOW  = _gray(243, 243, 244),
    SURFACE      = _gray(238, 238, 238),
    SURFACE_HIGH = _gray(232, 232, 232),
    SURFACE_TOP  = _gray(226, 226, 226),

    PRIMARY      = Blitbuffer.COLOR_BLACK,
    ON_PRIMARY   = _gray(226, 226, 226),
    TEXT         = _gray(26, 28, 28),
    TEXT_MUTED   = _gray(100, 100, 100),
    GHOST_LINE   = _gray(198, 198, 198),

    CORNER_RADIUS = 0,
    BORDER_CARD   = 2,
}

-- ---------------------------------------------------------------------------
-- Spacing — base px at reference DPI; use scaled() in layouts
-- ---------------------------------------------------------------------------
M.Spacing = {
    XS  = 8,
    SM  = 16,
    MD  = 24,
    LG  = 32,
    XL  = 48,
    XXL = 64,
}

function M.scaled(n)
    return Screen:scaleBySize(n)
end

-- Pre-scaled spacing token sizes (DESIGN.md rhythm). Prefer these over ad-hoc
-- Screen:scaleBySize(8|16|24|32|48|64) at call sites.
M.SP = {
    XS  = Screen:scaleBySize(M.Spacing.XS),
    SM  = Screen:scaleBySize(M.Spacing.SM),
    MD  = Screen:scaleBySize(M.Spacing.MD),
    LG  = Screen:scaleBySize(M.Spacing.LG),
    XL  = Screen:scaleBySize(M.Spacing.XL),
    XXL = Screen:scaleBySize(M.Spacing.XXL),
}

-- ---------------------------------------------------------------------------
-- Font roles — ordered fallbacks (KOReader font id strings)
-- ---------------------------------------------------------------------------
local _CONTENT_FACES = { "newsreader", "Noto Serif", "urw", "smallinfofont" }
local _UI_FACES      = { "publicsans", "Noto Sans", "cfont" }

local function _firstWorkingFace(candidates, size)
    for _, name in ipairs(candidates) do
        local ok, face = pcall(Font.getFace, Font, name, size)
        if ok and face then return face, name end
    end
    return Font:getFace("cfont", size), "cfont"
end

--- Content typography (serif / book-like)
function M.faceContent(size)
    return _firstWorkingFace(_CONTENT_FACES, size)
end

--- UI / tool typography (sans)
function M.faceUI(size)
    return _firstWorkingFace(_UI_FACES, size)
end

-- Preset sizes (px, scaled for DPI)
function M.sizeDisplay()   return math.max(24, Screen:scaleBySize(52)) end
function M.sizeTitleLg() return math.max(14, Screen:scaleBySize(28)) end
function M.sizeTitleMd() return math.max(12, Screen:scaleBySize(22)) end
function M.sizeBody()    return math.max(12, Screen:scaleBySize(18)) end
function M.sizeLabelLg() return math.max(10, Screen:scaleBySize(16)) end
function M.sizeLabelSm() return math.max(9,  Screen:scaleBySize(13)) end
function M.sizeMicro()   return math.max(8,  Screen:scaleBySize(11)) end

return M
