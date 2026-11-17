-- sui_list_rows.lua — Simple UI
-- Text rows of the detailed list views: a name over an info line, with an
-- optional trailing glyph. Shared by the folder rows and the collection rows.
--
-- Public API:
--   ListRows.fontSize(dimen_h, nominal, max)            -- font size scaled with the row height
--   ListRows.fitLines(avail_h, name_h, line_hs, gap)    -- how many secondary lines fit under the name
--   ListRows.countText(books, dirs)                     -- "12 books", "3 folders · 12 books"
--   ListRows.lines(name, info, dimen, main_w, opts)     -- name and info line stacked in main_w
--   ListRows.glyphWidget(dimen, glyph)                  -- trailing glyph and the width it reserves
--   ListRows.trailingRow(dimen, glyph, build)           -- lines from build(main_w) plus a trailing glyph
--   ListRows.setContent(item, widget)                   -- swaps the content of a list row

local _ = require("infra/sui_i18n").translate
local N_ = require("infra/sui_i18n").ngettext
local T = require("ffi/util").template

local M = {}

-- Gap between the lines and side padding of a row, in scaled px.
local function _gap() return math.max(1, require("device").screen:scaleBySize(1)) * 2 end
local function _pad() return require("device").screen:scaleBySize(10) end

-- Same ratio the stock list uses to convert a nominal (64px-reference) font
-- size into a scaled one, so row text matches the book rows.
function M.fontSize(dimen_h, nominal, max)
    local scale = require("device").screen:scaleBySize(1000000) * (1/1000000)
    local font_size = math.floor(nominal * dimen_h * (1/64) / scale)
    if max and font_size >= max then return max end
    return font_size
end

-- Number of secondary lines (`line_hs`, in display order) that fit under a
-- name of height `name_h` in `avail_h`; the last ones are dropped first.
function M.fitLines(avail_h, name_h, line_hs, gap)
    local used, fit = name_h, 0
    for i, h in ipairs(line_hs) do
        used = used + gap + h
        if used > avail_h then break end
        fit = i
    end
    return fit
end

function M.countText(books, dirs)
    local text = T(N_("%1 book", "%1 books", books), books)
    if dirs > 0 then
        text = T(_("%1 · %2"), T(N_("%1 folder", "%1 folders", dirs), dirs), text)
    end
    return text
end

-- Name and info line stacked and left aligned in `main_w`, in fixed font
-- sizes. The lines that do not fit the row are dropped, the info first and
-- then the author; the name takes the room the others leave and is cut with
-- an ellipsis. `info` is a string, or nil to show `opts.fallback` in the mono
-- face. `opts`: author (line under the name), fallback.
function M.lines(name, info, dimen, main_w, opts)
    opts = opts or {}
    local Font            = require("ui/font")
    local Geom            = require("ui/geometry")
    local LeftContainer   = require("ui/widget/container/leftcontainer")
    local TextBoxWidget   = require("ui/widget/textboxwidget")
    local TextWidget      = require("ui/widget/textwidget")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local VerticalSpan    = require("ui/widget/verticalspan")
    local UI              = require("infra/sui_core")
    local SUIStyle        = require("features/sui_style")

    local title_face = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY)
    local info_face  = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_DETAIL)
    local function infoLine(text)
        return UI.makeColoredText{
            text      = text,
            face      = info_face,
            fgcolor   = SUIStyle.COLOR.text,
            max_width = main_w,
        }
    end

    local winfo = info and infoLine(info) or TextWidget:new{
        text = opts.fallback or "",
        face = Font:getFace(SUIStyle.FACE_MONO, SUIStyle.FS_DETAIL),
    }
    local wauthor = opts.author and infoLine(opts.author)

    local gap  = _gap()
    local probe = TextWidget:new{ text = "Ag", face = title_face }
    local line_h = probe:getSize().h
    probe:free()

    -- Secondary lines in display order; the ones past `fit` are dropped.
    local extras, heights = {}, {}
    if wauthor then extras[#extras + 1] = wauthor end
    extras[#extras + 1] = winfo
    for i, w in ipairs(extras) do heights[i] = w:getSize().h end
    local avail = dimen.h
    local fit = M.fitLines(avail, line_h, heights, gap)
    local kept_h = 0
    for i = #extras, fit + 1, -1 do extras[i]:free() end
    for i = 1, fit do kept_h = kept_h + gap + heights[i] end
    local show_author = wauthor and fit >= 1
    local show_info   = fit == #extras

    local wname = TextBoxWidget:new{
        text                          = name,
        face                          = title_face,
        width                         = main_w,
        alignment                     = "left",
        height                        = math.max(line_h, avail - kept_h),
        height_adjust                 = true,
        height_overflow_show_ellipsis = true,
    }

    local lines = VerticalGroup:new{ align = "left", wname }
    if show_author then
        lines[#lines + 1] = VerticalSpan:new{ width = gap }
        lines[#lines + 1] = wauthor
    end
    if show_info then
        lines[#lines + 1] = VerticalSpan:new{ width = gap }
        lines[#lines + 1] = winfo
    end
    return LeftContainer:new{ dimen = Geom:new{ w = main_w, h = dimen.h }, lines }
end

-- Trailing glyph of a row of `dimen`, and the width it takes from the text
-- (glyph plus the gap before it).
function M.glyphWidget(dimen, glyph)
    local UI       = require("infra/sui_core")
    local SUIStyle = require("features/sui_style")
    local wglyph = UI.makeColoredText{
        text    = glyph,
        face    = SUIStyle.glyphFace(math.floor(dimen.h * 0.3)),
        fgcolor = SUIStyle.COLOR.text,
    }
    return wglyph, wglyph:getSize().w + _pad()
end

-- Row of `build(main_w)` followed by a trailing `glyph` at the end of the row.
function M.trailingRow(dimen, glyph, build)
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")

    local wglyph, reserved = M.glyphWidget(dimen, glyph)
    return HorizontalGroup:new{
        align = "center",
        build(dimen.w - reserved),
        HorizontalSpan:new{ width = _pad() },
        wglyph,
    }
end

-- Puts `widget` inside the row's underline container, below its top line.
function M.setContent(item, widget)
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan  = require("ui/widget/verticalspan")
    local underline_h = item.underline_h or 1
    if item._underline_container[1] then item._underline_container[1]:free() end
    item._underline_container[1] = VerticalGroup:new{
        VerticalSpan:new{ width = underline_h },
        widget,
    }
end

return M
