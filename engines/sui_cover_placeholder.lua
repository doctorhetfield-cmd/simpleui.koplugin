-- sui_cover_placeholder.lua — Simple UI
-- Generated cover for books without a cover image: a thin frame, the title,
-- and, when the author is known, a small divider and the author, centred.
--
--   Placeholder.build(w, h, title, authors)               → widget of exactly w × h
--   Placeholder.buildCropped(w, h, title, authors, align) → a w × h slice of the
--       full 2:3 cover, cut from its "left" or "right" edge
--   Placeholder.fitSize(max_w, max_h)                     → w, h of the largest
--       2:3 box that fits the given bounds

local BD              = require("ui/bidi")
local Blitbuffer      = require("ffi/blitbuffer")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local ImageWidget     = require("ui/widget/imagewidget")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local RenderText      = require("ui/rendertext")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local SUIStyle        = require("features/sui_style")
local _               = require("infra/sui_i18n").translate

local math_floor = math.floor
local math_max   = math.max

local Placeholder = {}

local COVER_ASPECT = 1.5

-- Layout, as fractions of the inner cover size.
local FRAME_INSET    = 0.05
local FRAME_THICK    = 0.006   -- of the width
local TITLE_TOP      = 0.18
local TITLE_HEIGHT   = 0.34
local DIVIDER_Y      = 0.575
local DIVIDER_LEN    = 0.14    -- of the width, each side
local DIVIDER_GAP    = 0.03    -- of the width, between a rule and the dot
local DIVIDER_DOT    = 0.018   -- of the width
local RULE_THICK     = 0.004   -- of the height
local AUTHOR_TOP     = 0.64
local AUTHOR_HEIGHT  = 0.16
local TEXT_MARGIN    = 0.14    -- horizontal margin of the text

-- Font sizes (px, before the global font scale); text shrinks to fit.
local TITLE_SIZE_MAX,  TITLE_SIZE_MIN  = 24, 10
local AUTHOR_SIZE_MAX, AUTHOR_SIZE_MIN = 16, 6

-- ---------------------------------------------------------------------------
-- Building blocks
-- ---------------------------------------------------------------------------

-- Solid rectangle placed at (x, y) inside an OverlapGroup.
local function newBlock(x, y, w, h)
    local block = LineWidget:new{
        dimen      = Geom:new{ w = math_max(1, w), h = math_max(1, h) },
        background = SUIStyle.COLOR.text_primary,
    }
    block.overlap_offset = { x, y }
    return block
end

local function addFrame(content, inner_w, inner_h)
    local inset = math_floor(inner_w * FRAME_INSET)
    local t     = math_max(1, math_floor(inner_w * FRAME_THICK))
    local w, h  = inner_w - 2 * inset, inner_h - 2 * inset
    content[#content + 1] = newBlock(inset,         inset,         w, t)
    content[#content + 1] = newBlock(inset,         inset + h - t, w, t)
    content[#content + 1] = newBlock(inset,         inset,         t, h)
    content[#content + 1] = newBlock(inset + w - t, inset,         t, h)
end

local function addDivider(content, inner_w, inner_h)
    local cx   = math_floor(inner_w / 2)
    local y    = math_floor(inner_h * DIVIDER_Y)
    local t    = math_max(1, math_floor(inner_h * RULE_THICK))
    local len  = math_floor(inner_w * DIVIDER_LEN)
    local gap  = math_floor(inner_w * DIVIDER_GAP)
    local dot  = math_max(2, math_floor(inner_w * DIVIDER_DOT))
    local half = math_floor(dot / 2)
    content[#content + 1] = newBlock(cx - half - gap - len, y, len, t)
    content[#content + 1] = newBlock(cx + dot - half + gap, y, len, t)
    content[#content + 1] = newBlock(cx - half, y - math_floor((dot - t) / 2), dot, dot)
end

local function newTextBox(text, size, width, max_h)
    return TextBoxWidget:new{
        text      = text,
        face      = Font:getFace(SUIStyle.FACE_REGULAR, size),
        width     = width,
        alignment = "center",
        fgcolor   = SUIStyle.COLOR.text_primary,
        bgcolor   = nil,
        alpha     = true,
        -- Height-limited boxes truncate with an ellipsis instead of growing.
        height                        = max_h,
        height_adjust                 = max_h ~= nil,
        height_overflow_show_ellipsis = max_h ~= nil,
    }
end

-- Returns a text box no taller than max_h: the largest font size in
-- [min_size, max_size] that fits, else an ellipsised box at min_size.
local function fitText(text, width, max_h, max_size, min_size)
    for size = max_size, min_size, -1 do
        local box = newTextBox(text, size, width)
        if box:getSize().h <= max_h then return box end
        box:free(true)
    end
    local face = Font:getFace(SUIStyle.FACE_REGULAR, min_size)
    local fits_ellipsis = width > RenderText:getEllipsisWidth(face)
    return newTextBox(text, min_size, width, fits_ellipsis and max_h or nil)
end

-- Centres `box` horizontally and vertically within the area starting at
-- `top` that is `area_h` tall.
local function placeCentered(box, inner_w, top, area_h)
    local size = box:getSize()
    box.overlap_offset = {
        math_max(0, math_floor((inner_w - size.w) / 2)),
        top + math_floor((area_h - size.h) / 2),
    }
    return box
end

local function firstLine(text)
    return text:match("^([^\n]+)") or text
end

-- ---------------------------------------------------------------------------
-- Public
-- ---------------------------------------------------------------------------

function Placeholder.fitSize(max_w, max_h)
    local w = math_floor(max_h / COVER_ASPECT)
    if w <= max_w then return w, max_h end
    return max_w, math_floor(max_w * COVER_ASPECT)
end

function Placeholder.build(w, h, title, authors)
    local border  = SUIStyle.BADGE_BORDER_SZ
    local inner_w = w - 2 * border
    local inner_h = h - 2 * border

    local has_author = authors ~= nil and authors ~= ""
    title   = (title and title ~= "") and title or _("Unknown")
    authors = has_author and firstLine(authors) or nil

    local text_w   = inner_w - 2 * math_floor(inner_w * TEXT_MARGIN)
    local title_top = math_floor(inner_h * TITLE_TOP)
    local title_h   = math_floor(inner_h * TITLE_HEIGHT)
    local author_h  = math_floor(inner_h * AUTHOR_HEIGHT)
    -- Without an author the title is centred over the whole text area.
    if not has_author then
        title_h = math_floor(inner_h * (AUTHOR_TOP + AUTHOR_HEIGHT)) - title_top
    end

    local content = OverlapGroup:new{ dimen = Geom:new{ w = inner_w, h = inner_h } }
    addFrame(content, inner_w, inner_h)
    if text_w >= 1 and title_h >= 1 and author_h >= 1 then
        content[#content + 1] = placeCentered(
            fitText(BD.auto(title), text_w, title_h, TITLE_SIZE_MAX, TITLE_SIZE_MIN),
            inner_w, title_top, title_h)
        if has_author then
            addDivider(content, inner_w, inner_h)
            content[#content + 1] = placeCentered(
                fitText(BD.auto(authors), text_w, author_h, AUTHOR_SIZE_MAX, AUTHOR_SIZE_MIN),
                inner_w, math_floor(inner_h * AUTHOR_TOP), author_h)
        end
    end

    return FrameContainer:new{
        width      = w,
        height     = h,
        bordersize = border,
        margin     = 0,
        padding    = 0,
        color      = SUIStyle.COLOR.text_primary,
        background = SUIStyle.COLOR.surface,
        content,
    }
end

function Placeholder.buildCropped(w, h, title, authors, align)
    local full_w = Placeholder.fitSize(math.huge, h)
    if full_w <= w then return Placeholder.build(w, h, title, authors) end

    -- Render the whole cover off-screen, then keep only the requested slice.
    local cover = Placeholder.build(full_w, h, title, authors)
    local sheet = Blitbuffer.new(full_w, h, Blitbuffer.TYPE_BBRGB32)
    sheet:fill(Blitbuffer.COLOR_WHITE)
    cover:paintTo(sheet, 0, 0)
    cover:free()

    local slice = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
    slice:blitFrom(sheet, 0, 0, align == "right" and (full_w - w) or 0, 0, w, h)
    sheet:free()

    return ImageWidget:new{
        image            = slice,
        image_disposable = true,
        width            = w,
        height           = h,
        scale_factor     = 1,
    }
end

return Placeholder
