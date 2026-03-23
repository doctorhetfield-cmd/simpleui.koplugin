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
-- Surfaces & ink — resolved by refreshThemeForNightMode()
-- ---------------------------------------------------------------------------
M.Theme = {}

local function _applyLightPalette(T)
    T.BG           = _gray(249, 249, 249)
    T.SURFACE_LOW  = _gray(243, 243, 244)
    T.SURFACE      = _gray(238, 238, 238)
    T.SURFACE_HIGH = _gray(232, 232, 232)
    T.SURFACE_TOP  = _gray(226, 226, 226)
    T.PRIMARY      = Blitbuffer.COLOR_BLACK
    T.ON_PRIMARY   = _gray(226, 226, 226)
    T.TEXT         = _gray(26, 28, 28)
    T.TEXT_MUTED   = _gray(100, 100, 100)
    T.GHOST_LINE   = _gray(198, 198, 198)
    T.CORNER_RADIUS = 0
    T.BORDER_CARD   = 2
end

local function _applyDarkPalette(T)
    T.BG           = _gray(26, 26, 26)
    T.SURFACE_LOW  = _gray(34, 34, 36)
    T.SURFACE      = _gray(42, 42, 44)
    T.SURFACE_HIGH = _gray(50, 50, 52)
    T.SURFACE_TOP  = _gray(58, 58, 60)
    T.PRIMARY      = _gray(240, 240, 240)
    T.ON_PRIMARY   = _gray(26, 26, 26)
    T.TEXT         = _gray(224, 224, 224)
    T.TEXT_MUTED   = _gray(150, 150, 150)
    T.GHOST_LINE   = _gray(90, 90, 90)
    T.CORNER_RADIUS = 0
    T.BORDER_CARD   = 2
end

--- Call after night_mode changes and once at load. Mutates M.Theme in place.
function M.refreshThemeForNightMode()
    local night = G_reader_settings:isTrue("night_mode")
    if night then
        _applyDarkPalette(M.Theme)
    else
        _applyLightPalette(M.Theme)
    end
end

_applyLightPalette(M.Theme)

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

M.SP = {
    XS  = Screen:scaleBySize(M.Spacing.XS),
    SM  = Screen:scaleBySize(M.Spacing.SM),
    MD  = Screen:scaleBySize(M.Spacing.MD),
    LG  = Screen:scaleBySize(M.Spacing.LG),
    XL  = Screen:scaleBySize(M.Spacing.XL),
    XXL = Screen:scaleBySize(M.Spacing.XXL),
}

-- ---------------------------------------------------------------------------
-- Font roles — KOReader/Kindle: use names that ship under koreader/fonts/
-- (Noto, Nimbus, Droid, Free*, cfont). Cache resolved family per session.
-- ---------------------------------------------------------------------------
local _CONTENT_FACES = {
    "Noto Serif", "NotoSerif", "FreeSerif", "Nimbus Roman No9 L", "Nimbus Roman",
    "Droid Serif", "urw", "smallinfofont", "newsreader", "cfont",
}
local _UI_FACES = {
    "Noto Sans", "NotoSans", "Droid Sans", "DroidSans", "Nimbus Sans", "NimbusSans",
    "FreeSans", "publicsans", "cfont",
}

local function _firstWorkingFace(candidates, size, cache_ref)
    if cache_ref[1] then
        local ok, face = pcall(Font.getFace, Font, cache_ref[1], size)
        if ok and face then return face end
    end
    for _, name in ipairs(candidates) do
        local ok, face = pcall(Font.getFace, Font, name, size)
        if ok and face then
            cache_ref[1] = name
            return face
        end
    end
    return Font:getFace("cfont", size)
end

local _content_cache = {}
local _ui_cache = {}

function M.faceContent(size)
    return _firstWorkingFace(_CONTENT_FACES, size, _content_cache)
end

function M.faceUI(size)
    return _firstWorkingFace(_UI_FACES, size, _ui_cache)
end

function M.sizeDisplay()   return math.max(24, Screen:scaleBySize(52)) end
function M.sizeTitleLg() return math.max(14, Screen:scaleBySize(28)) end
function M.sizeTitleMd() return math.max(12, Screen:scaleBySize(22)) end
function M.sizeBody()    return math.max(12, Screen:scaleBySize(18)) end
function M.sizeLabelLg() return math.max(10, Screen:scaleBySize(16)) end
function M.sizeLabelSm() return math.max(9,  Screen:scaleBySize(13)) end
function M.sizeMicro()   return math.max(8,  Screen:scaleBySize(11)) end

M.refreshThemeForNightMode()

return M
