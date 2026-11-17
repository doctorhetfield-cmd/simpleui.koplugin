-- sui_book_rows.lua — Simple UI
-- Book rows of the detailed list views: cover, title over series and authors,
-- and the reading progress over the file info on the right.
--
-- Public API:
--   BookRows.progressText(book_info, pages, settings)   -- "4 %", "Finished – 3 pages", nil
--   BookRows.barFraction(book_info)                     -- 0..1 reading fraction
--   BookRows.barText(book_info, pages, settings)        -- "10%", "On hold", "Finished", ...
--   BookRows.dotsFilled(fraction, count)                -- read dots of a dotted bar
--   BookRows.fileInfoText(filetype, size, annotated, no_provider)
--   BookRows.seriesLine(series, index)                  -- "NAME - 2"
--   BookRows.authorsLine(authors)                       -- authors on one line
--   BookRows.build(item, dimen, opts)                   -- the row widget, or nil to keep the native row

local _ = require("infra/sui_i18n").translate
local N_ = require("infra/sui_i18n").ngettext
local T = require("ffi/util").template

local M = {}

local function _round(x) return math.floor(x + 0.5) end

-- Dots of a dotted progress bar.
M.DOT_COUNT = 16

-- Reading fraction of a book, clamped to 0..1: a finished book is full and
-- one never opened is empty.
function M.barFraction(book_info)
    if book_info.status == "complete" then return 1 end
    return math.max(0, math.min(1, book_info.percent_finished or 0))
end

-- Short progress text shown next to the bar: "10%" (also "0%" for a book never
-- opened), "On hold" or "Finished". `settings` ({ pages_read, pages_left },
-- optional) follows the file browser: pages read ("50/503") replace the
-- percentage and follow "On hold" ("On hold · 50/503"); pages left
-- (", 453 to read") are appended.
function M.barText(book_info, pages, settings)
    local status = book_info.status
    if status == "complete" then return _("Finished") end
    settings = settings or {}
    local fraction = M.barFraction(book_info)
    local read = pages and _round(fraction * pages)
    local position = pages and (read .. "/" .. pages)
    local held = status == "abandoned"
    local text = held and _("On hold") or string.format("%d%%", math.floor(fraction * 100 + 0.5))
    if settings.pages_read and position then
        text = held and (text .. " · " .. position) or position
    end
    if pages and settings.pages_left then text = T(_("%1, %2 to read"), text, pages - read) end
    return text
end

-- Number of read dots out of `count` for `fraction`.
function M.dotsFilled(fraction, count)
    return math.max(0, math.min(count, math.floor(fraction * count)))
end

-- Same texts as the file browser's detailed list. `settings`:
-- { pages_read = bool, pages_left = bool }.
function M.progressText(book_info, pages, settings)
    local status, percent = book_info.status, book_info.percent_finished
    if status == "complete" or status == "abandoned" then
        local done = status == "complete"
        if not pages then return done and _("Finished") or _("On hold") end
        if done then return T(N_("Finished – 1 page", "Finished – %1 pages", pages), pages) end
        return T(N_("On hold – 1 page", "On hold – %1 pages", pages), pages)
    end
    if percent then
        if not pages then return string.format("%d %%", math.floor(100 * percent)) end
        local text
        if settings.pages_read then
            text = T(_("Page %1 of %2"), _round(percent * pages), pages)
        else
            text = T(N_("%1 % of 1 page", "%1 % of %2 pages", pages), math.floor(100 * percent), pages)
        end
        if settings.pages_left then
            text = T(_("%1, %2 to read"), text, _round(pages - percent * pages))
        end
        return text
    end
    if pages then return T(N_("1 page", "%1 pages", pages), pages) end
    return nil
end

-- Dotted bar: `filled` large dots followed by small ones, `pitch` apart and
-- centred on the widget height. Created on first use.
local _Dots
local function _dotsBar(w, h, filled, big, pitch)
    if not _Dots then
        local Widget = require("ui/widget/widget")
        _Dots = Widget:extend{}
        function _Dots:paintTo(bb, x, y)
            local AAPaint  = require("infra/sui_aa_paint")
            local SUIStyle = require("features/sui_style")
            self.dimen.x, self.dimen.y = x, y
            local small = math.max(1, math.floor(self.big / 2))
            local ink = SUIStyle.COLOR.text_primary
            local read, unread = SUIStyle.accent(ink), ink
            for i = 1, M.DOT_COUNT do
                local d = i <= self.filled and self.big or small
                AAPaint.fillPill(bb, x + (i - 1) * self.pitch + math.floor((self.big - d) / 2),
                    y + math.floor((self.dimen.h - d) / 2), d, d,
                    i <= self.filled and read or unread, 255)
            end
        end
    end
    local Geom = require("ui/geometry")
    return _Dots:new{ dimen = Geom:new{ w = w, h = h }, filled = filled, big = big, pitch = pitch }
end

-- "EPUB  4.5 MB", with a shade mark for a book that has annotations.
function M.fileInfoText(filetype, size, annotated, no_provider)
    if no_provider then return size end
    local text = (annotated and "\u{2592}  " or "") .. filetype
    return size and (text .. "  " .. size) or text
end

function M.seriesLine(series, index)
    local text = series:upper()
    if index then
        local n = tonumber(index)
        text = text .. " - " .. ((n and n == math.floor(n)) and tostring(math.floor(n)) or tostring(index))
    end
    return text
end

function M.authorsLine(authors)
    if not authors or authors == "" then return nil end
    return (authors:gsub("\n", ", "))
end

-- Row of a known book. `opts`:
--   book_info   the file browser's per-book info (status, percent, annotations)
--   bookinfo    the cached metadata (title, authors, series, pages, cover)
--   cover_slot  function(bookinfo, dimen) -> widget, slot width; nil without covers
--   font_size   function(nominal, max) -> size scaled with the row height
--   settings    { hide_page_info, pages_read, pages_left, hide_file_info, series_mode,
--                 progress_bar ("style" | "dots" | nil) }
--   fileinfo    file type and size text, already isolated for bidi
function M.build(item, dimen, opts)
    local Font            = require("ui/font")
    local Geom            = require("ui/geometry")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local LeftContainer   = require("ui/widget/container/leftcontainer")
    local OverlapGroup    = require("ui/widget/overlapgroup")
    local RightContainer  = require("ui/widget/container/rightcontainer")
    local Screen          = require("device").screen
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local VerticalSpan    = require("ui/widget/verticalspan")
    local BD              = require("ui/bidi")
    local SUIStyle        = require("features/sui_style")
    local UI              = require("infra/sui_core")

    local bookinfo, book_info, settings = opts.bookinfo, opts.book_info, opts.settings
    local pad    = Screen:scaleBySize(10)
    local gap    = math.max(1, Screen:scaleBySize(2))
    local color  = SUIStyle.COLOR.text
    local title_size = math.min(SUIStyle.FS_BODY, opts.font_size(20, 24))
    local info_size  = math.max(10, math.min(SUIStyle.FS_DETAIL, title_size - 3))
    local function textHeight(size)
        local probe = require("ui/widget/textwidget"):new{
            text = "Ag", face = Font:getFace(SUIStyle.FACE_REGULAR, size) }
        local h = probe:getSize().h
        probe:free()
        return h
    end
    local function line(text, size, max_width)
        return UI.makeColoredText{
            text      = text,
            face      = Font:getFace(SUIStyle.FACE_REGULAR, size),
            fgcolor   = color,
            max_width = max_width,
        }
    end

    -- Right column: progress over file info.
    local wright, right_w = nil, 0
    local pages = book_info.pages or bookinfo.pages
    local right = VerticalGroup:new{ align = "right" }
    local progress = not settings.hide_page_info and M.progressText(book_info, pages, settings)

    -- With the progress bar on, the progress goes under the title and author
    -- when the row has room for one more line; otherwise it stays on the right.
    local bar_line = false
    if settings.progress_bar and not settings.hide_page_info then
        local heights = {}
        if settings.series_mode and bookinfo.series then
            heights[#heights + 1] = textHeight(math.max(9, info_size - 2))
        end
        if M.authorsLine(bookinfo.authors) then heights[#heights + 1] = textHeight(info_size) end
        heights[#heights + 1] = textHeight(info_size)
        bar_line = require("features/library/sui_list_rows").fitLines(
            dimen.h - 2 * Screen:scaleBySize(4), textHeight(title_size), heights, gap) == #heights
    end
    if progress and not bar_line then right[#right + 1] = line(progress, info_size) end
    if not settings.hide_file_info and opts.fileinfo then
        if #right > 0 then right[#right + 1] = VerticalSpan:new{ width = gap } end
        right[#right + 1] = line(opts.fileinfo, math.max(10, info_size - 1))
    end
    if #right > 0 then
        right_w = right:getSize().w
        wright = right
    end

    local wleft, slot_w = nil, 0
    if opts.cover_slot then wleft, slot_w = opts.cover_slot(bookinfo, dimen) end

    local text_x = slot_w + pad
    local main_w = dimen.w - text_x - pad - (wright and (right_w + pad) or 0)

    -- Title on one line, cut with an ellipsis.
    local series = settings.series_mode and bookinfo.series
        and line(M.seriesLine(bookinfo.series, bookinfo.series_index), math.max(9, info_size - 2), main_w)
    local authors = M.authorsLine(bookinfo.authors)
    local wauthors = authors and line(BD.auto(authors), info_size, main_w)
    local wtitle = UI.makeColoredText{
        text      = BD.auto(bookinfo.title or item.text or ""),
        lang      = bookinfo.language,
        face      = Font:getFace(SUIStyle.FACE_REGULAR, title_size),
        fgcolor   = color,
        max_width = main_w,
    }
    local wmain = VerticalGroup:new{ align = "left", wtitle }
    if series then
        wmain[#wmain + 1] = VerticalSpan:new{ width = gap }
        wmain[#wmain + 1] = series
    end
    if wauthors then
        wmain[#wmain + 1] = VerticalSpan:new{ width = gap }
        wmain[#wmain + 1] = wauthors
    end

    if bar_line then
        local fraction = M.barFraction(book_info)
        local info_h = textHeight(info_size)
        -- The bar fills the title's width left by the text beside it.
        local wbar_text = line(M.barText(book_info, pages, settings), info_size, math.floor(main_w / 2))
        local bar_w = main_w - pad - wbar_text:getSize().w
        local bar
        if settings.progress_bar == "dots" then
            local big = math.max(2, math.floor(info_h * 0.4))
            local pitch = math.max(1, math.min(math.floor(big * 1.6),
                math.floor((bar_w - big) / (M.DOT_COUNT - 1))))
            bar_w = (M.DOT_COUNT - 1) * pitch + big
            bar = _dotsBar(bar_w, info_h, M.dotsFilled(fraction, M.DOT_COUNT), big, pitch)
        else
            bar = UI.progressBar(bar_w, fraction, math.max(2, math.floor(info_h / 3)))
        end
        local progress_row = HorizontalGroup:new{ align = "center", bar }
        progress_row[2] = HorizontalSpan:new{ width = pad }
        progress_row[3] = wbar_text
        wmain[#wmain + 1] = VerticalSpan:new{ width = gap }
        wmain[#wmain + 1] = progress_row
    end

    -- The cover slot stays the first child: the native description hint is
    -- drawn on the border of row[1][1].
    local row = OverlapGroup:new{ dimen = dimen:copy() }
    if wleft then row[#row + 1] = wleft end
    row[#row + 1] = LeftContainer:new{
        dimen = dimen:copy(),
        HorizontalGroup:new{ HorizontalSpan:new{ width = text_x }, wmain },
    }
    if wright then
        row[#row + 1] = RightContainer:new{
            dimen = Geom:new{ w = dimen.w, h = dimen.h },
            wright,
        }
    end
    return row
end

return M
