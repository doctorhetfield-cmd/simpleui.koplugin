-- module_reading_stats.lua — Simple UI
-- Reading Stats module: grid of stat cards (today, averages, totals, streak).
-- Instanciable: the base id "reading_stats" is the first instance, further
-- ones are "reading_stats_<hex>" (see modules/moduleregistry.lua).

local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer    = require("ui/widget/container/leftcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local RightContainer  = require("ui/widget/container/rightcontainer")
local BD              = require("ui/bidi")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local _ = require("infra/sui_i18n").translate
local N_ = require("infra/sui_i18n").ngettext
local T  = require("ffi/util").template
local Arrange         = require("features/sui_arrange")
local Config          = require("infra/sui_config")
local GridRenderer    = require("engines/sui_book_grid")
local PageNav         = require("engines/sui_page_nav")
local PageState       = require("engines/sui_section_label").PageState
local ModuleChrome    = require("features/sui_module_chrome")

local UI      = require("infra/sui_core")
local SUISettings = require("infra/sui_store")
local Backdrop    = require("infra/sui_backdrop")
local SUIWallpaper = require("features/sui_wallpaper")
local SUIStyle    = require("features/sui_style")
local Charts      = require("engines/sui_stats_charts")
local HD          = require("engines/sui_heatmap_data")
local SpanGrid    = require("infra/sui_span_grid")
local DateNames   = require("infra/sui_datenames")
local Catalog     = require("modules/reading_stats/catalog")
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB
local PAD     = UI.PAD
local MOD_GAP = UI.MOD_GAP
local LABEL_H = UI.LABEL_H


local _BASE_RS_CORNER_R = Screen:scaleBySize(12)
local _BASE_RS_GAP      = Screen:scaleBySize(12)
local _BASE_RS_CARD_H   = Screen:scaleBySize(96)
local _BASE_RS_VAL_FS   = SUIStyle.FS_TITLE     -- 22: stat value (large numeric)
local _BASE_RS_LBL_FS   = SUIStyle.FS_DETAIL    -- 15: stat label
local _BASE_RS_SEP_W    = Screen:scaleBySize(1)
local _BASE_RS_PH_FS    = SUIStyle.FS_BODY      -- 18: placeholder text

-- Detailed cards: the title and an icon on top, the value below and the stat's
-- chart (or description) at the bottom. `_BASE_RS_DETAIL_H` is the tallest a
-- card gets; its height follows its content, whose sizes are multiples of the
-- label text height (so they follow the card width, like the text does).
local _BASE_RS_DETAIL_H   = Screen:scaleBySize(150) -- tallest card
local _DETAIL_PAD_L         = 0.8   -- inset of the card content
local _DETAIL_ICON_L        = 1.5   -- icon box size
local _DETAIL_GAP_L         = 0.25  -- gap between the title row and the value
local _DETAIL_BODY_GAP_L    = 0.4   -- gap between the value and the card body
local _DETAIL_DOT_L         = 0.8   -- largest streak dot, and thickness of the share bar
local _DETAIL_CHART_L       = 2.4   -- height of the bars and the heatmap
local _STREAK_DOTS_SHORT    = 7     -- days of the streak dots in a narrow card
local _DETAIL_GLYPH_PCT     = 0.6   -- glyph size inside the icon box, relative to the box
local _DETAIL_VAL_BOOST     = 1.45  -- value size relative to the classic card
local _GROW_MAX_PCT         = 0.5   -- most a grid grows to fill a taller Home Screen row, relative to its height

local RS_DEFAULT_COLS = 3
local RS_MAX_COLS  = 4  -- grid limits of a page — not dimensions, no scaling needed
local RS_MAX_ROWS  = 3

-- ---------------------------------------------------------------------------
-- Card text size, as a percentage of the card's own width (mirrors
-- module_clock.lua / module_coverdeck.lua's convention: 100% scale = sized
-- to what's actually available, not a fixed physical/point constant).
--
-- Value/label text follows the card's real width: narrower when the grid has
-- more columns (up to RS_MAX_COLS) or the row itself is narrower
-- (landscape spread — `w` is already narrowed upstream, see
-- sui_screen_engine.lua), wider when it has fewer. Growth is capped
-- relative to card_h (see textCaps()) so text never
-- outgrows the card when very few cards are selected.
--
-- The percentage is derived once at module load from a reference card: a
-- single-column Homescreen at 100% scale showing the default 3 stat items.
-- ---------------------------------------------------------------------------
local _REF_RS_N        = 3  -- default item count (see Catalog.items)
local _REF_RS_AVAIL_W  = UI.getInnerW() - PAD * 2
local _REF_RS_CARD_W   = math.floor((_REF_RS_AVAIL_W - _BASE_RS_GAP * (_REF_RS_N - 1)) / _REF_RS_N)
local _RS_VAL_FS_PCT   = _BASE_RS_VAL_FS / _REF_RS_CARD_W
local _RS_LBL_FS_PCT   = _BASE_RS_LBL_FS / _REF_RS_CARD_W
local _RS_VAL_FS_MIN   = 8
local _RS_LBL_FS_MIN   = 6
-- Largest value / label text, relative to the card height.
local _RS_VAL_CAP_PCT        = 0.40
local _RS_LBL_CAP_PCT        = 0.20
local _RS_DETAIL_VAL_CAP_PCT = 0.22
local _RS_DETAIL_LBL_CAP_PCT = 0.10

local function _clampFs(v, lo, hi)
    return math.max(lo, math.min(hi, math.floor(v)))
end

-- Font size, as Font:getFace() takes it, whose text is `px` pixels tall: face
-- sizes are scaled by the screen and by the global text size, card sizes are not.
local function _fsForPx(px)
    local unit = Screen:scaleBySize(1000) / 1000 * Config.getFontScalePct() / 100
    return math.floor(px / unit)
end

local BASE_ID          = "reading_stats"   -- id of the first instance and base of the others
local DEFAULT_PFX      = "simpleui_hs_"
-- Setting keys of an instance: pfx .. instance id .. suffix.
local SETTING_ENABLED  = "_enabled"
local SETTING_ITEMS    = "_items"
local SETTING_TYPE     = "_type"            -- style: cards / detailed / list
local SETTING_ALIGN    = "_align"
local SETTING_ROW_ALIGN = "_row_align"      -- placement of a row with fewer cards than columns
local SETTING_CARD_STR = "_card_strength"   -- 0–100 fill opacity
local SETTING_GRID_COLS = "_grid_cols"
local SETTING_GRID_ROWS = "_grid_rows"
local SETTING_SPANS = "_spans"                 -- map stat id -> columns the card spans
local SETTING_HIGHLIGHTS = "_highlights"       -- map stat id -> true for highlighted cards
local SETTING_HIGHLIGHT_TONE = "_highlight_tone"
local SETTING_HIDE_ICONS = "_hide_icons"    -- detailed cards: no icon
local TYPES           = { "cards", "detailed", "list" }

-- Text elements with a user-selectable font family. Their size follows the
-- card width and the module text size. The values are bold until the user
-- picks another variant.
local TEXT_ELEMS    = { "value", "label" }
local TEXT_VARIANTS = { value = "bold" }

-- Style values stored before the card look became a surface, mapped onto the
-- look they stood for (see Backdrop.migrateLook).
local LEGACY_STYLE_LOOKS = { cards_transparent = "transparent" }

local function getType(id, pfx)
    return Config.readChoice(pfx .. id .. SETTING_TYPE, TYPES, "detailed")
end

local function getAlign(id, pfx)
    return Config.getAlignment(pfx .. id .. SETTING_ALIGN)
end

local function getRowAlign(id, pfx)
    return Config.getAlignment(pfx .. id .. SETTING_ROW_ALIGN, nil, "left")
end

-- Unscaled card height of a style.
local function baseCardHeight(mode)
    return mode == "detailed" and _BASE_RS_DETAIL_H or _BASE_RS_CARD_H
end

-- Surface of the stat cards.
local function cardSurface(id, pfx)
    local surface = Backdrop.surface("card", pfx .. id, pfx .. id .. SETTING_CARD_STR)
    Backdrop.migrateLook(surface, pfx .. id .. SETTING_TYPE, LEGACY_STYLE_LOOKS)
    return surface
end

-- Stats whose card is highlighted: the stored map.
local function _getHighlights(id, pfx)
    local saved = SUISettings:readSetting(pfx .. id .. SETTING_HIGHLIGHTS)
    return type(saved) == "table" and saved or {}
end

local function _setHighlight(id, pfx, stat_id, on)
    local map = {}
    for k, v in pairs(_getHighlights(id, pfx)) do map[k] = v end
    map[stat_id] = on or nil
    SUISettings:saveSetting(pfx .. id .. SETTING_HIGHLIGHTS, next(map) and map or nil)
end

-- Tone of the highlighted cards over the card `surface` (a resolved one).
local function highlightTone(id, pfx, surface)
    return Catalog.highlightTone(SUISettings:readSetting(pfx .. id .. SETTING_HIGHLIGHT_TONE), surface.tone, {
        accent    = SUIStyle.paletteChoiceAvailable("accent"),
        secondary = SUIStyle.paletteChoiceAvailable("secondary"),
    })
end

-- Surface of a highlighted card: the card `surface` with a solid fill of the
-- highlight tone and the text colour that reads on it.
local function highlightSurface(id, pfx, surface)
    local COLOR = SUIStyle.COLOR
    local tone  = highlightTone(id, pfx, surface)
    local color, foreground
    if tone == "black" then
        color, foreground = COLOR.text_primary, COLOR.surface
    elseif tone == "gray" then
        color = COLOR.surface_gray
    else
        color, foreground = SUIStyle.resolveColor(tone), SUIStyle.resolveForeground(tone)
    end
    local out = {}
    for k, v in pairs(surface) do out[k] = v end
    out.tone, out.strength, out.color, out.foreground = tone, Backdrop.STRENGTH_MAX, color, foreground
    return out
end

-- Columns each stat spans: the stored map, which SpanGrid.spanOf validates.
local function _getSpans(id, pfx)
    local saved = SUISettings:readSetting((pfx or DEFAULT_PFX) .. id .. SETTING_SPANS)
    return type(saved) == "table" and saved or {}
end

-- Every selected stat id, in order (the default set on a fresh install, none
-- once the list was emptied). A list holding a stat the catalog no longer has is
-- migrated and saved here.
local function _getItems(id, pfx)
    pfx = pfx or DEFAULT_PFX
    local saved = SUISettings:readSetting(pfx .. id .. SETTING_ITEMS)
    local items, spans = Catalog.items(saved, _getSpans(id, pfx))
    if spans then
        SUISettings:setNoFlush(pfx .. id .. SETTING_ITEMS, items)
        SUISettings:setNoFlush(pfx .. id .. SETTING_SPANS, next(spans) and spans or nil)
    end
    return items
end

-- Grid of a page: columns (unset: RS_DEFAULT_COLS), the most rows
-- a page holds (`rows`), the packed rows of cards (see SpanGrid) and the pages
-- they fill, with the rows shared out evenly: `page_rows` is the height, in
-- rows, of the tallest page.
-- The result is kept per instance while the stats, spans and grid size stay the
-- same: it is asked for many times per render. The callers only read it.
local _dims_cache = {}

local function gridDims(id, pfx)
    pfx = pfx or DEFAULT_PFX
    local items = _getItems(id, pfx)
    local spans = _getSpans(id, pfx)
    local total = #items
    local cols = Config.readClampedInt(pfx .. id .. SETTING_GRID_COLS, 1, RS_MAX_COLS, RS_DEFAULT_COLS)
    local rows = Config.readClampedInt(pfx .. id .. SETTING_GRID_ROWS, 1, RS_MAX_ROWS, 1)
    local sig = { cols, rows }
    for _i, stat_id in ipairs(items) do
        sig[#sig + 1] = stat_id .. ":" .. tostring(spans[stat_id])
    end
    sig = table.concat(sig, ",")
    local key = pfx .. id
    local cached = _dims_cache[key]
    if cached and cached.sig == sig then return cached.dims end
    local packed = SpanGrid.pack(items, spans, cols)
    local pages = SpanGrid.pages(packed, rows)
    local dims = { cols = cols, rows = rows, total = total, packed = packed,
                   pages = pages, npages = #pages, page_rows = #pages[1].rows }
    _dims_cache[key] = { sig = sig, dims = dims }
    return dims
end

-- The stat ids of page `page` of instance `id`.
local function _getPageItems(id, pfx, page)
    local pages = gridDims(id, pfx).pages
    return pages[math.min(page, #pages)].ids
end

-- Face of the page indicator, sized like the one of the section labels.
local function pagerFace(lf)
    return PageNav.indicatorFace(Config.getLabelScale() * lf)
end

-- Largest font sizes of the stat value and label of a card `card_h` tall.
local function textCaps(card_h, detailed)
    return math.max(_RS_VAL_FS_MIN, _fsForPx(card_h * (detailed and _RS_DETAIL_VAL_CAP_PCT or _RS_VAL_CAP_PCT))),
           math.max(_RS_LBL_FS_MIN, _fsForPx(card_h * (detailed and _RS_DETAIL_LBL_CAP_PCT or _RS_LBL_CAP_PCT)))
end

-- Font sizes of the value and the label of a card `basis_w` wide: they follow
-- the width, up to the caps of a card `card_h` tall.
local function cardFontSizes(basis_w, raw_scale, styles, card_h, detailed)
    local val_max, lbl_max = textCaps(card_h, detailed)
    local boost = detailed and _DETAIL_VAL_BOOST or 1
    return _clampFs(basis_w * _RS_VAL_FS_PCT * boost * raw_scale * (styles.value.scale or 1), _RS_VAL_FS_MIN, val_max),
           _clampFs(basis_w * _RS_LBL_FS_PCT * raw_scale * (styles.label.scale or 1), _RS_LBL_FS_MIN, lbl_max)
end

-- Height of a line of text at font size `fs`.
local function lineHeight(fs)
    local face = Font:getFace(SUIStyle.FACE_REGULAR, fs)
    local ok, h = pcall(function() return face.ftsize:getHeightAndAscender() end)
    return ok and h and math.ceil(h) or fs
end

-- Sizes of a detailed card `basis_w` wide: the inset of the content, the icon
-- box, the gaps between the card sections, the largest streak dot, the height of
-- the bar and heatmap charts and the text heights.
local function detailMetrics(basis_w, raw_scale, styles, card_h)
    local val_fs, lbl_fs = cardFontSizes(basis_w, raw_scale, styles, card_h, true)
    local lbl_h = lineHeight(lbl_fs)
    local function lines(k) return math.max(2, math.floor(lbl_h * k)) end
    return {
        pad      = lines(_DETAIL_PAD_L),
        icon_d   = lines(_DETAIL_ICON_L),
        gap      = lines(_DETAIL_GAP_L),
        body_gap = lines(_DETAIL_BODY_GAP_L),
        dot_max  = lines(_DETAIL_DOT_L),
        chart_h  = lines(_DETAIL_CHART_L),
        val_h    = lineHeight(val_fs),
        lbl_h    = lbl_h,
    }
end

-- Height a detailed card of `stat_id` needs, at most `card_h`.
local function detailNaturalHeight(stat_id, m, card_h)
    local kind = Catalog.CHART[stat_id]
    local body
    if not kind then
        body = m.lbl_h
    elseif kind == "streak_dots" then
        body = m.dot_max
    elseif kind == "dayparts" then
        body = Charts.shareHeight(m.dot_max, m.lbl_h)
    else
        body = m.chart_h
    end
    local head = math.max(m.icon_d, m.lbl_h)
    return math.min(card_h, 2 * m.pad + head + m.gap + m.val_h + m.body_gap + body)
end

-- Width of the cards of a grid `w` wide that span one column, `cols` columns of
-- the grid and `gap` apart.
local function itemWidth(w, cols, gap)
    return math.max(1, math.floor((w - gap * (cols - 1)) / cols))
end

-- Geometry shared by build() and getHeight(), for a card scale `scale`, a
-- landscape factor `lf` and a grid `w` wide whose text is at `raw_scale` with
-- the text `styles`. `row_h[page][row]` is the height of each grid row: a
-- detailed card row is as tall as its tallest card, any other row is `card_h`.
-- `grow` is the extra height (px) of the Home Screen row the module sits in
-- (see `fills_row_height`): the rows of cards share it, up to `_GROW_MAX_PCT`
-- of their own height, so the grid reaches the bottom of the row.
local function gridMetrics(id, pfx, mode, scale, lf, w, raw_scale, styles, grow)
    local dims = gridDims(id, pfx)
    local paged = dims.npages > 1
    local card_h = math.floor(baseCardHeight(mode) * scale)
    local sep_w  = math.max(1, math.floor(_BASE_RS_SEP_W * scale))
    local gap    = math.max(2, math.floor(_BASE_RS_GAP * scale))
    -- Rows of a list are told apart by a line, those of cards by a gap.
    local row_gap = mode == "list" and sep_w or gap
    local item_w = itemWidth(w, dims.cols, gap)
    local metrics_of = {}
    local function detailOf(span)
        local m = metrics_of[span]
        if not m then
            m = detailMetrics(span * item_w + (span - 1) * gap, raw_scale, styles, card_h)
            metrics_of[span] = m
        end
        return m
    end
    -- Every page takes the height of the tallest one, so a page turn does not
    -- move what sits below it.
    local row_h, grid_h = {}, 0
    for p, page in ipairs(dims.pages) do
        local heights, total = {}, 0
        for r, row in ipairs(page.rows) do
            local h = card_h
            if mode == "detailed" then
                h = 0
                for _, cell in ipairs(row.cells) do
                    h = math.max(h, detailNaturalHeight(cell.id, detailOf(cell.span), card_h))
                end
            end
            heights[r] = h
            total = total + h + (r > 1 and row_gap or 0)
        end
        row_h[p] = heights
        grid_h = math.max(grid_h, total)
    end
    if grid_h == 0 then grid_h = card_h end
    grow = mode == "list" and 0 or math.min(math.floor(tonumber(grow) or 0), math.floor(grid_h * _GROW_MAX_PCT))
    if grow > 0 then
        grid_h = 0
        for _, heights in ipairs(row_h) do
            local n = #heights
            local share = math.floor(grow / n)
            local total = 0
            for r = 1, n do
                heights[r] = heights[r] + share + (r == n and grow - share * n or 0)
                total = total + heights[r] + (r > 1 and row_gap or 0)
            end
            grid_h = math.max(grid_h, total)
        end
    end
    local pager_h = paged and PageNav.rowHeight(pagerFace(lf)) or 0
    return {
        cols = dims.cols, rows = dims.page_rows, pages = dims.pages, npages = dims.npages,
        card_h = card_h, row_h = row_h, sep_w = sep_w, gap = gap, row_gap = row_gap,
        item_w = item_w, grid_h = grid_h, pager_h = pager_h, detailOf = detailOf,
        -- The page indicator sits under the grid, a gap apart.
        height = paged and grid_h + gap + pager_h or grid_h,
    }
end

-- ---------------------------------------------------------------------------
-- Stat map
-- ---------------------------------------------------------------------------
local function fmtTime(secs)
    secs = math.floor(secs or 0)
    if secs <= 0 then return string.format(_("%dm"), 0) end
    local h = math.floor(secs / 3600); local m = math.floor((secs % 3600) / 60)
    if h > 0 and m > 0 then return string.format(_("%dh %dm"), h, m)
    elseif h > 0        then return string.format(_("%dh"), h)
    else                     return string.format(_("%dm"), m) end
end

-- Hour of the day (0-23) as the clock range it covers, following the device's
-- 12/24 h setting.
local function fmtHourRange(hour)
    local nxt = (hour + 1) % 24
    if G_reader_settings:isTrue("twelve_hour_clock") then
        local function h12(h) return h % 12 == 0 and 12 or h % 12 end
        local function meridiem(h) return h < 12 and _("AM") or _("PM") end
        if meridiem(hour) == meridiem(nxt) then
            return string.format("%d–%d %s", h12(hour), h12(nxt), meridiem(hour))
        end
        return string.format("%d %s–%d %s", h12(hour), meridiem(hour), h12(nxt), meridiem(nxt))
    end
    return string.format("%02dh–%02dh", hour, nxt)
end

-- Days of the activity heatmap that the "days read" figure counts (at least the
-- weeks the heatmap shows).
local HEAT_DAYS = 12 * 7

-- Per stat: `display_label` names it in menus; `value` and `label` (or
-- `label_fn`) are the number and its description. Detailed cards also use
-- `title` (card heading), `icon` (a SUIStyle.ICON name) and the optional
-- `unit_fn`, a unit drawn small beside the value, `detail_value`, a value that
-- replaces `value` on detailed cards, and `value_pct`, the size of
-- the value relative to the regular one (for text wider than a number). `detail_title` and
-- `detail_label` override `title` and `label` on detailed cards, where the
-- heading already carries part of the description.
local STAT_MAP = {
    today_time  = { title = _("Today"), icon = "clock", display_label = _("Reading time today"),      value = function(s) return fmtTime(s.today_secs) end,   label = _("of reading today"), detail_label = _("of reading") },
    today_pages = { title = _("Today"), icon = "page", display_label = _("Pages read today"),     value = function(s) return tostring(s.today_pages) end, label = _("pages read today"), detail_label = _("pages read") },
    week_time   = { title = _("This week"), icon = "clock", display_label = _("Reading time this week"),  value = function(s) return fmtTime(s.week_secs) end,    label = _("of reading this week"), detail_label = _("of reading") },
    week_pages  = { title = _("This week"), icon = "page", display_label = _("Pages read this week"), value = function(s) return tostring(s.week_pages) end,  label = _("pages read this week"), detail_label = _("pages read") },
    year_time   = { title = _("This year"), icon = "clock", display_label = _("Reading time this year"), value = function(s) return fmtTime(s.year_secs) end,   label = _("of reading this year"), detail_label = _("of reading") },
    avg_time    = { title = _("Daily average"), icon = "clock", display_label = _("Daily average, last 7 days"),  value = function(s) return fmtTime(s.avg_secs) end,     label = _("daily avg (7 days)"), detail_label = _("last 7 days") },
    avg_pages   = { title = _("Daily average"), icon = "page", display_label = _("Pages per day, last 7 days"), value = function(s) return tostring(s.avg_pages) end,   label = _("pages/day (7 days)"), detail_title = _("Pages per day"), detail_label = _("last 7 days") },
    month_time  = { title = _("This month"), icon = "clock", display_label = _("Reading time this month"), value = function(s) return fmtTime(s.month_secs) end,   label = _("of reading this month"), detail_label = _("of reading") },
    month_pages = { title = _("This month"), icon = "page", display_label = _("Pages read this month"),value = function(s) return tostring(s.month_pages) end, label = _("pages read this month"), detail_label = _("pages read") },
    pages_total = { title = _("Pages turned"), icon = "page", display_label = _("Total pages turned"), value = function(s) return tostring(s.total_turns) end, label = _("total pages turned"),
                    detail_value = function(s) return "+" .. s.today_turns end, unit_fn = function() return _("today") end },
    total_time  = { title = _("All time"), icon = "clock", display_label = _("Total reading time"),   value = function(s) return fmtTime(s.total_secs) end,   label = _("of reading, all time"), detail_label = _("of reading") },
    total_books = { title = _("All time"), icon = "book", display_label = _("Books finished"),  value = function(s) return tostring(s.total_books) end, label = _("books finished") },
    streak      = { title = _("Streak"), icon = "streak", display_label = _("Reading streak"),            value = function(s) return s.streak > 0 and tostring(s.streak) or "—" end,
                    label_fn = function(s)
                        if s.streak == 0 then return _("no streak") end
                        return N_("day streak", "days streak", s.streak)
                    end,
                    unit_fn = function(s) return s.streak > 0 and N_("day", "days", s.streak) or nil end },
    session_longest = { title = _("Records"), icon = "clock", display_label = _("Longest session, 90 days"), label = _("longest session (90 days)"),
                        detail_title = _("Longest session"), detail_label = _("last 90 days"),
                        value = function(s) return s.rec_sessions > 0 and fmtTime(s.rec_longest_secs) or "—" end },
    session_avg     = { title = _("Records"), icon = "clock", display_label = _("Average session, 90 days"), label = _("average session (90 days)"),
                        detail_title = _("Average session"), detail_label = _("last 90 days"),
                        value = function(s) return s.rec_sessions > 0 and fmtTime(s.rec_avg_secs) or "—" end },
    pages_per_hour  = { title = _("Records"), icon = "page", display_label = _("Reading speed, 90 days"),      label = _("pages/hour (90 days)"),
                        detail_title = _("Pages per hour"), detail_label = _("last 90 days"),
                        value = function(s)
                            return s.rec_sessions > 0 and tostring(math.floor(s.rec_pages_hour + 0.5)) or "—"
                        end },
    sessions        = { title = _("Records"), icon = "history", display_label = _("Reading sessions, 90 days"),        label = _("reading sessions (90 days)"),
                        detail_title = _("Reading sessions"), detail_label = _("last 90 days"),
                        value = function(s) return tostring(s.rec_sessions) end },
    hours_chart = { title = _("Peak reading hour"), icon = "clock", display_label = _("Peak reading hour"), label = _("peak reading hour"),
                    value_pct = 0.8,
                    value = function(s) return s.chart_peak and fmtHourRange(s.chart_peak) or "—" end },
    peak_weekday = { title = _("Most-read weekday"), icon = "calendar_select", display_label = _("Most-read weekday"), label = _("most-read weekday"),
                    value_pct = 0.65,
                    value = function(s)
                        -- Weekdays are numbered from Monday here, from Sunday in DateNames.
                        return s.chart_weekday_peak and DateNames.weekdayFull()[s.chart_weekday_peak % 7 + 1] or "—"
                    end },
    activity_map = { title = _("Activity"), icon = "calendar_select", display_label = _("Reading days, 12 weeks"), label = _("days read (12 weeks)"),
                     detail_label = _("last 12 weeks"),
                     value = function(s) return s.chart_days and tostring(s.heat_days_read) or "—" end,
                     unit_fn = function(s) return s.chart_days and N_("day", "days", s.heat_days_read) or nil end },
    week_compare = { title = _("Weekly change"), icon = "clock", display_label = _("Change against last week"), label = _("vs last week"),
                     detail_label = _("vs the same days last week"),
                     value = function(s)
                         local delta = s.week_delta
                         if not delta then return "—" end
                         return delta == 0 and "0%" or string.format("%+d%%", delta)
                     end },
    day_parts   = { title = _("Time of day"), icon = "clock", display_label = _("Most-read time of day"), label = _("most-read time of day"),
                    value_pct = 0.65,
                    value = function(s) return s.chart_part_peak and DateNames.dayParts()[s.chart_part_peak] or "—" end },
    -- No "finished" card among the library statuses: it would near-duplicate
    -- "Books finished" (both count summary.status == "complete") with only
    -- edge-case differences, showing two near-identical numbers with no clear
    -- reason why they'd differ.
    status_unread    = { title = _("Library"), icon = "book", display_label = _("Books not started"),    value = function(s) return tostring(s.status_unread) end,    label = _("unread") },
    status_reading   = { title = _("Library"), icon = "book_open", display_label = _("Books in progress"),   value = function(s) return tostring(s.status_reading) end,   label = _("in progress") },
    status_abandoned = { title = _("Library"), icon = "remove", display_label = _("Books abandoned"), value = function(s) return tostring(s.status_abandoned) end, label = _("abandoned") },
}

-- Chart drawn on the detailed card of a stat.
for sid, kind in pairs(Catalog.CHART) do STAT_MAP[sid].chart = kind end


-- Stat ids backed by SP.getStatusCounts() (a whole-library filesystem walk)
-- instead of the DB/ReadHistory-backed fields above. Kept as its own set so
-- callers can cheaply check "is a status_* card selected" without a table
-- walk of STAT_MAP itself.
local STATUS_STAT_IDS = { status_unread = true, status_reading = true, status_abandoned = true }

-- Stat ids backed by SP.getSessionRecords().
local RECORD_STAT_IDS = { session_longest = true, session_avg = true, pages_per_hour = true, sessions = true }

-- Stat ids backed by the finished-books ledger (SP.get() with needs_books).
local BOOK_STAT_IDS = { total_books = true }

-- True if one of the stat ids `ids` is in `set`.
local function anyIn(ids, set)
    for _, id in ipairs(ids) do
        if set[id] then return true end
    end
    return false
end

-- Does one of the stats `ids` read the data of `set`?
local function usesSet(set)
    return function(ids) return anyIn(ids, set) end
end

-- Does one of the stats `ids` read the chart data (SP.getChartData()) in the
-- card style `mode`?
local function usesChartData(ids, mode)
    for _, id in ipairs(ids) do
        if Catalog.usesCharts(id, mode) then return true end
    end
    return false
end

-- Does one of the stats `ids` read the year data (SP.getYearData()) in the
-- card style `mode`?
local function usesYearData(ids, mode)
    for _, id in ipairs(ids) do
        if Catalog.usesYear(id, mode) then return true end
    end
    return false
end

-- True if a stat of the first page of instance `id`, the one the first paint
-- shows, reads the data `uses` tells.
local function firstPageUses(id, pfx, uses)
    return uses(_getPageItems(id, pfx, 1), getType(id, pfx))
end

-- M.needs of an instance: the screen engine gates each query on the stats the
-- first page shows (see Registry.wantsData). The stats of the other pages are
-- loaded when their page is shown (see ensureData).
local NEED_USES = {
    books   = usesSet(BOOK_STAT_IDS),
    status  = usesSet(STATUS_STAT_IDS),
    records = usesSet(RECORD_STAT_IDS),
    charts  = usesChartData,
    year    = usesYearData,
}

local function makeNeeds(id)
    local needs = { stats = true }
    for kind, uses in pairs(NEED_USES) do
        needs[kind] = function(pfx) return firstPageUses(id, pfx, uses) end
    end
    return needs
end

-- The data each kind of stat reads from the ctx besides the time series: which
-- stats need it, the ctx field holding it, the ctx flag that keeps the
-- screen's refresh fetching it, and how it is fetched.
local DATA_SETS = {
    { uses = NEED_USES.status,  field = "status_counts",   flag = "_needs_status",
      fetch = function(SP) return SP.getStatusCounts() end },
    { uses = NEED_USES.records, field = "session_records", flag = "_needs_records",
      fetch = function(SP, ctx) return SP.getSessionRecords(ctx.db_conn) end },
    { uses = NEED_USES.charts,  field = "stat_charts",     flag = "_needs_charts",
      fetch = function(SP, ctx) return SP.getChartData(ctx.db_conn) end },
    { uses = NEED_USES.year,    field = "year_data",       flag = "_needs_year",
      fetch = function(SP, ctx) return SP.getYearData(ctx.db_conn) end },
}

-- Loads what the stats `ids` need, drawn in the card style `mode`, and the ctx
-- lacks. The first paint fetches only what the first page shows, so a later
-- page can reach more; the flags keep the screen's refresh updating what was
-- loaded here.
local function ensureData(ctx, ids, mode)
    local SP
    for _, set in ipairs(DATA_SETS) do
        if not ctx[set.field] and set.uses(ids, mode) then
            SP = SP or require("modules/module_stats_provider")
            ctx[set.field] = set.fetch(SP, ctx)
            if ctx[set.field] then ctx[set.flag] = true end
        end
    end
    if not ctx._needs_books and anyIn(ids, BOOK_STAT_IDS) then
        SP = SP or require("modules/module_stats_provider")
        ctx.stats        = SP.get(ctx.db_conn, ctx.year_str, true)
        ctx._needs_books = true
    end
end

-- Maps each stat_id to the _changed category it belongs to (from SP.get()),
-- so updateStats() can skip rebuilding cards whose data did not change.
-- Categories: "timeseries" (fetchTimeSeries fields), "streak" (fetchStreak),
-- "books" (sidecar scan), "records" (SP.getSessionRecords) and "charts"
-- (SP.getChartData) and "year" (SP.getYearData), which are not part of SP.get():
-- see updateStats. A stat drawing a chart (see changedCats) also depends on its
-- chart data. Ids not listed here are always rebuilt.
local STAT_CHANGED_CAT = {
    today_time  = "timeseries",
    today_pages = "timeseries",
    week_time   = "timeseries",
    week_pages  = "timeseries",
    avg_time    = "timeseries",
    avg_pages   = "timeseries",
    month_time  = "timeseries",
    month_pages = "timeseries",
    total_time  = "timeseries",
    pages_total = "timeseries",
    year_time   = "timeseries",
    streak      = "streak",
    status_unread    = "status",
    status_reading   = "status",
    status_abandoned = "status",
    total_books = "books",
    session_longest = "records",
    session_avg     = "records",
    pages_per_hour  = "records",
    sessions        = "records",
    hours_chart     = "charts",
    peak_weekday    = "charts",
    activity_map    = "charts",
    week_compare    = "charts",
    day_parts       = "charts",
}

-- The _changed categories a card of `stat_id` drawn in the style `mode`
-- depends on, or nil when it is always rebuilt.
local function changedCats(stat_id, mode)
    local cat = STAT_CHANGED_CAT[stat_id]
    if not cat then return nil end
    local cats = { cat }
    if cat ~= "charts" and Catalog.usesCharts(stat_id, mode) then cats[#cats + 1] = "charts" end
    if Catalog.usesYear(stat_id, mode) then cats[#cats + 1] = "year" end
    return cats
end

-- Pool of the item picker, grouped by what the stats measure, built once at
-- module load, not on every menu open.
local GROUP_TITLES = {
    time   = _("Reading time"),
    pages  = _("Pages read"),
    books  = _("Books"),
    habits = _("Habits"),
}
local _stat_pool = {}
for _, group in ipairs(Catalog.GROUPS) do
    for _, sid in ipairs(group.ids) do
        _stat_pool[#_stat_pool+1] = { id = sid, label = STAT_MAP[sid].display_label, group = GROUP_TITLES[group.key] }
    end
end

-- Stat values derived from the chart data, worked out the first time a card
-- reads them.
local DERIVED = {
    heat_days_read = function(stats)
        if not stats.chart_days then return nil end
        local count = 0
        for _i, secs in ipairs(HD.lastDays(stats.chart_days, HEAT_DAYS, os.time())) do
            if secs > 0 then count = count + 1 end
        end
        return count
    end,
    week_delta = function(stats)
        local days, week = stats.chart_days, stats.chart_week
        if not (days and week) then return nil end
        local now = os.time()
        return HD.weekDelta(HD.weekValues(days, now, 0), HD.weekValues(days, now, -1), week.today)
    end,
}
local DERIVED_META = {
    __index = function(stats, key)
        local derive = DERIVED[key]
        if derive then
            local value = derive(stats)
            rawset(stats, key, value)
            return value
        end
        if key == "chart_parts" or key == "chart_part_peak" then
            if not stats.chart_hours then return nil end
            local parts, peak = HD.dayPartTotals(stats.chart_hours)
            rawset(stats, "chart_parts", parts)
            rawset(stats, "chart_part_peak", peak)
            return rawget(stats, key)
        end
    end,
}

-- The stat values the cards read, gathered from the pre-fetched ctx
-- (StatsProvider fills ctx.stats; the status, record and chart data are
-- present only when a selected card needs them).
local function _collectStats(ctx)
    local sp  = ctx.stats or {}
    local rec = ctx.session_records or {}
    local charts = ctx.stat_charts or {}
    local stats = {
        today_secs  = sp.today_secs  or 0,
        today_pages = sp.today_pages or 0,
        week_secs   = sp.week_secs   or 0,
        week_pages  = sp.week_pages  or 0,
        avg_secs    = sp.avg_secs    or 0,
        avg_pages   = sp.avg_pages   or 0,
        month_secs  = sp.month_secs  or 0,
        month_pages = sp.month_pages or 0,
        total_secs  = sp.total_secs  or 0,
        total_turns = sp.total_turns or 0,
        today_turns = sp.today_turns or 0,
        year_secs   = sp.year_secs   or 0,
        total_books = sp.books_total or 0,
        streak      = sp.streak      or 0,
        streak_week = sp.streak_week,
        status_unread    = (ctx.status_counts and ctx.status_counts.unread)    or 0,
        status_reading   = (ctx.status_counts and ctx.status_counts.reading)   or 0,
        status_abandoned = (ctx.status_counts and ctx.status_counts.abandoned) or 0,
        rec_sessions     = rec.sessions       or 0,
        rec_longest_secs = rec.longest_secs   or 0,
        rec_avg_secs     = rec.avg_secs       or 0,
        rec_pages_hour   = rec.pages_per_hour or 0,
        chart_week       = charts.week,
        chart_hours      = charts.hours,
        chart_peak       = charts.peak_hour,
        chart_weekdays     = charts.weekdays,
        chart_weekday_peak = charts.peak_weekday,
        year_data        = ctx.year_data,
        chart_days       = charts.days,
    }
    return setmetatable(stats, DERIVED_META)
end

-- ---------------------------------------------------------------------------
-- Stat widget builders
-- ---------------------------------------------------------------------------

-- Streak value widget: icon (dark grey, or `clr_icon`) + space + number
-- (black), side by side.
-- To change icon colour: edit SUIStyle.COLOR.gray_strong.
-- To change spacing:     edit _STREAK_ICON_GAP.
local _STREAK_ICON_GAP = 6                   -- pixels between icon and number

local function makeStreakValWidget(val_str, d, clr_blk, clr_icon, max_w)
    local icon = UI.makeColoredText{
        text    = SUIStyle.icon("streak"),
        face    = d.face_icon,
        fgcolor = clr_icon or SUIStyle.COLOR.gray_strong,
    }
    return HorizontalGroup:new{ align = "center",
        icon,
        HorizontalSpan:new{ width = _STREAK_ICON_GAP },
        UI.makeColoredText{
            text    = val_str,
            face    = d.face_val,
            bold    = d.bold_val,
            fgcolor = clr_blk or SUIStyle.COLOR.text_primary,
            max_width = max_w and math.max(1, max_w - icon:getSize().w - _STREAK_ICON_GAP) or nil,
            truncate_with_ellipsis = true,
        },
    }
end

-- Value of a card: the streak comes with its icon from 5 days on, any other
-- stat is its plain value text. Text beyond `max_w` is truncated.
local function _makeValueWidget(stat_id, val_str, stats, d, clr_blk, clr_icon, max_w)
    if stat_id == "streak" and stats.streak >= 5 then
        return makeStreakValWidget(val_str, d, clr_blk, clr_icon, max_w)
    end
    local pct = STAT_MAP[stat_id].value_pct
    local face, bold = d.face_val, d.bold_val
    if pct then face, bold = d.valueFace(pct) end
    return UI.makeColoredText{
        text = val_str,
        face = face,
        bold = bold,
        fgcolor = clr_blk,
        max_width = max_w,
        truncate_with_ellipsis = true,
    }
end

-- Row of the recent days for the streak card: the whole `week` when its dots
-- keep their full size, else its last _STREAK_DOTS_SHORT days. Nil when
-- `free_h` (the card height left by the value and label) or `max_w` cannot
-- hold legible dots.
local function _buildStreakDots(week, d, max_w, free_h, color)
    if not week then return nil end
    local size, gap = Charts.fitDots(#week, max_w, free_h, d.dot_max)
    if size ~= math.min(d.dot_max, free_h) and #week > _STREAK_DOTS_SHORT then
        week = { unpack(week, #week - _STREAK_DOTS_SHORT + 1) }
        size, gap = Charts.fitDots(#week, max_w, free_h, d.dot_max)
    end
    if not size then return nil end
    return Charts.weekDots{ states = week, size = size, gap = gap, color = color }
end

-- Bar chart for a detailed card, or nil when `values` is missing or `max_w` /
-- `free_h` cannot hold a legible chart.
local function _buildBars(values, highlight, d, max_w, free_h, clr_blk)
    if not values then return nil end
    local bar_w, gap = Charts.fitBars(#values, max_w, d.bar_max)
    if not bar_w then return nil end
    return Charts.bars{
        values = values, bar_w = bar_w, gap = gap, avail_h = free_h,
        color = clr_blk, highlight = highlight,
    }
end

-- Bars of the days of the month, today highlighted; the last 14 or 7 days when
-- the month does not fit `max_w`.
local function _buildMonthBars(stats, d, max_w, free_h, clr_blk)
    local days = stats.chart_days
    if not days then return nil end
    local now = os.time()
    local t = os.date("*t", now)
    local month = HD.monthDays(days, t.year, t.month)
    local bar_w, gap = Charts.fitBars(#month, max_w, d.bar_max)
    if bar_w then
        return Charts.bars{ values = month, bar_w = bar_w, gap = gap, avail_h = free_h, color = clr_blk, highlight = t.day }
    end
    for _, count in ipairs{ 14, 7 } do
        bar_w, gap = Charts.fitBars(count, max_w, d.bar_max)
        if bar_w then
            return Charts.bars{ values = HD.lastDays(days, count, now), bar_w = bar_w, gap = gap,
                                avail_h = free_h, color = clr_blk, highlight = count }
        end
    end
end

-- Weeks of days read, one cell per day; a strip of the last 28, 14 or 7 days
-- when seven rows of cells do not fit `free_h`.
local function _buildHeatmap(stats, d, max_w, free_h, clr_blk)
    local days = stats.chart_days
    if not days then return nil end
    local now = os.time()
    local size, gap, cols, gap_x = Charts.fitGrid(7, HD.HEAT_WEEKS, max_w, free_h, d.dot_max, 12)
    if size then
        local grid = HD.heatGrid(days, cols, now)
        return Charts.heatmap{ levels = grid.levels, size = size, gap = gap, gap_x = gap_x, color = clr_blk,
                               today = { grid.today_col, grid.today_row } }
    end
    for _, count in ipairs{ 28, 14, 7 } do
        size, gap, _, gap_x = Charts.fitGrid(1, count, max_w, free_h, d.dot_max, count)
        if size then
            local levels = {}
            for i, level in ipairs(HD.levels(HD.lastDays(days, count, now))) do levels[i] = { level } end
            return Charts.heatmap{ levels = levels, size = size, gap = gap, gap_x = gap_x, color = clr_blk,
                                   today = { count, 1 } }
        end
    end
end

-- Bars of this week, each beside a lighter bar for the same day of the week before.
local function _buildWeekCompare(stats, d, max_w, free_h, clr_blk)
    local days = stats.chart_days
    if not days then return nil end
    local bar_w, gap = Charts.fitBars(7, max_w, d.bar_max, true)
    if not bar_w then return nil end
    local now = os.time()
    return Charts.bars{
        values = HD.weekValues(days, now, 0), ghost = HD.weekValues(days, now, -1),
        bar_w = bar_w, gap = gap, avail_h = free_h, color = clr_blk,
    }
end

-- One bar split by part of the day, the most-read part highlighted, each
-- segment labelled with its share when wide enough.
local function _buildDayParts(stats, d, max_w, free_h, clr_blk, clr_sub)
    local parts = stats.chart_parts
    if not parts then return nil end
    local total = 0
    for _, secs in ipairs(parts) do total = total + secs end
    local labels = {}
    for i, secs in ipairs(parts) do
        labels[i] = total > 0 and string.format("%d%%", math.floor(secs / total * 100 + 0.5)) or ""
    end
    return Charts.share{
        values = parts, w = max_w, avail_h = free_h, bar_h = d.dot_max, color = clr_blk,
        highlight = stats.chart_part_peak, labels = labels, label_face = d.face_lbl, label_color = clr_sub,
    }
end

-- Drums showing the page turns of all time (at least six digits), the last one
-- turning when pages were turned today. The drums take `clr_fill`, the digits the
-- colour that reads on it.
local function _buildOdometer(stats, d, max_w, free_h, clr_fill, on_accent)
    local COLOR = SUIStyle.COLOR
    local digit_color = on_accent and SUIStyle.accentFg()
        or (SUIStyle.isSurface(clr_fill) and COLOR.text_primary or COLOR.surface)
    return Charts.odometer{
        digits = string.format("%06d", stats.total_turns), rolling = stats.today_turns > 0,
        w = max_w, avail_h = free_h, max_w = d.bar_max, color = clr_fill, digit_color = digit_color,
    }
end

-- Chart drawn under the value of a detailed card (the stat's `chart` kind), or
-- nil when the stat has none or it does not fit in `free_h` x `max_w`.
local function _buildCardExtra(stat_id, stats, d, max_w, free_h, clr_blk, clr_sub, on_accent)
    local kind = STAT_MAP[stat_id].chart
    if kind == "month" then
        return _buildMonthBars(stats, d, max_w, free_h, clr_blk)
    elseif kind == "heatmap" then
        return _buildHeatmap(stats, d, max_w, free_h, clr_blk)
    elseif kind == "week_vs" then
        return _buildWeekCompare(stats, d, max_w, free_h, clr_blk)
    elseif kind == "dayparts" then
        return _buildDayParts(stats, d, max_w, free_h, clr_blk, clr_sub)
    elseif kind == "odometer" then
        return _buildOdometer(stats, d, max_w, free_h, clr_blk, on_accent)
    elseif kind == "streak_dots" then
        return _buildStreakDots(stats.streak_week, d, max_w, free_h, clr_blk)
    elseif kind == "week" then
        local week = stats.chart_week
        return week and _buildBars(week.secs, week.today, d, max_w, free_h, clr_blk)
    elseif kind == "hours" then
        return _buildBars(stats.chart_hours, stats.chart_peak and stats.chart_peak + 1, d, max_w, free_h, clr_blk)
    elseif kind == "weekdays" then
        return _buildBars(stats.chart_weekdays, stats.chart_weekday_peak, d, max_w, free_h, clr_blk)
    elseif kind == "year" then
        local year = stats.year_data
        return year and _buildBars(year.months, year.month, d, max_w, free_h, clr_blk)
    end
end

local function _buildCardInner(stat_id, stats, d, align, clr_blk, clr_sub, max_w, clr_icon)
    local entry = STAT_MAP[stat_id]
    if not entry then return VerticalGroup:new{} end
    local val_str = entry.value(stats)
    local lbl_str = entry.label_fn and entry.label_fn(stats) or entry.label
    local actual_max_w = max_w and math.max(1, max_w - Screen:scaleBySize(8)) or nil
    local val_w = _makeValueWidget(stat_id, val_str, stats, d, clr_blk, clr_icon, actual_max_w)
    local lbl_w = UI.makeColoredText{
        text    = lbl_str,
        face    = d.face_lbl,
        bold    = d.bold_lbl,
        fgcolor = clr_sub,
        max_width = actual_max_w,
        truncate_with_ellipsis = true,
    }
    return VerticalGroup:new{ align = align, val_w, lbl_w }
end

-- Space under the baseline of a text widget (the last element of a group,
-- like the streak value), 0 when it cannot be told.
local function _textDescent(widget)
    local text = widget.getBaseline and widget or widget[#widget] or widget
    text = text._inner or text
    if not text.getBaseline then return 0 end
    return text:getSize().h - text:getBaseline()
end

-- Detailed card content: title and icon (unless hidden) on top, the value below (with
-- its unit when it has one), then the stat's chart or, without one, its
-- description. Always `card_h` tall and `card_w` wide, left-aligned. The
-- title, icon and chart are drawn in `clr_accent` when given.
local function _buildDetailedInner(stat_id, stats, d, clr_blk, clr_sub, card_w, card_h, clr_icon, clr_accent)
    local entry = STAT_MAP[stat_id]
    if not entry then return VerticalGroup:new{} end
    local inner_w = math.max(1, card_w - 2 * d.pad)
    local clr_head = clr_accent or clr_blk

    local title = UI.makeColoredText{
        text = entry.detail_title or entry.title, face = d.face_lbl, bold = d.bold_lbl, fgcolor = clr_head,
        max_width = math.max(1, inner_w - (d.hide_icons and 0 or d.icon_d + d.pad)), truncate_with_ellipsis = true,
    }
    local header
    if d.hide_icons then
        header = LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = math.max(title:getSize().h, d.icon_d) },
            title,
        }
    else
        header = HorizontalGroup:new{ align = "center",
            title,
            HorizontalSpan:new{ width = inner_w - title:getSize().w - d.icon_d },
            CenterContainer:new{
                dimen = Geom:new{ w = d.icon_d, h = d.icon_d },
                UI.makeColoredText{
                    text    = SUIStyle.icon(entry.icon),
                    face    = SUIStyle.glyphFace(math.floor(d.icon_d * _DETAIL_GLYPH_PCT)),
                    fgcolor = clr_head,
                    padding = 0,
                },
            },
        }
    end

    local unit = entry.unit_fn and entry.unit_fn(stats)
    local unit_w = unit and UI.makeColoredText{
        text = unit, face = d.face_lbl, bold = d.bold_lbl, fgcolor = clr_sub,
    }
    local val_w = _makeValueWidget(stat_id, (entry.detail_value or entry.value)(stats), stats, d, clr_blk, clr_icon,
        math.max(1, inner_w - (unit_w and unit_w:getSize().w + d.dots_gap or 0)))
    -- The unit shares the value's baseline: its box is raised by the difference
    -- between the descents of the two sizes.
    local value_row = unit_w
        and HorizontalGroup:new{ align = "bottom",
            val_w,
            HorizontalSpan:new{ width = d.dots_gap },
            VerticalGroup:new{
                unit_w,
                VerticalSpan:new{ width = math.max(0, _textDescent(val_w) - _textDescent(unit_w)) },
            },
        }
        or  val_w

    -- The body fills the height left under the value, so the card keeps its
    -- height: the chart sits at the bottom, the description right under the value.
    local body_h = math.max(0, card_h - 2 * d.pad - header:getSize().h - value_row:getSize().h
        - d.dots_gap - d.body_gap)
    local body_content = _buildCardExtra(stat_id, stats, d, inner_w, body_h, clr_head, clr_sub, clr_accent and true or false)
        or UI.makeColoredText{
            text = entry.detail_label or (entry.label_fn and entry.label_fn(stats) or entry.label),
            face = d.face_lbl, bold = d.bold_lbl, fgcolor = clr_sub,
            max_width = inner_w, truncate_with_ellipsis = true,
        }
    -- Height the content leaves over (a taller row, see `fills_row_height`): half
    -- goes under the header, half above the body, which sits at the bottom.
    local spare = math.max(0, body_h - body_content:getSize().h)
    local above = math.floor(spare / 2)
    local body = VerticalGroup:new{ VerticalSpan:new{ width = spare - above }, body_content }

    return FrameContainer:new{
        bordersize = 0, padding = d.pad,
        VerticalGroup:new{ align = "left",
            header,
            VerticalSpan:new{ width = d.dots_gap + above },
            value_row,
            VerticalSpan:new{ width = d.body_gap },
            body,
        },
    }
end

-- Cards mode: a rounded card drawn from the card `surface` (a resolved
-- surface: tone, opacity and optional frame).
-- `d` is the scaled-dims table produced once per build() call.
local function buildStatCardWidget(card_w, card_h, stat_id, stats, d, align, surface)
    local clr_blk = SUIStyle.COLOR.text_primary
    local clr_sub = CLR_TEXT_SUB
    -- On an accent fill, all the card text takes the colour that reads on it.
    local clr_icon = surface and surface.foreground
    if clr_icon then clr_blk, clr_sub = clr_icon, clr_icon end
    local clr_accent = d.detailed and Backdrop.accentOn(surface) or nil
    local function buildInner(card_stats)
        if d.detailed then
            return _buildDetailedInner(stat_id, card_stats, d, clr_blk, clr_sub, card_w, card_h, clr_icon, clr_accent)
        end
        return _buildCardInner(stat_id, card_stats, d, align, clr_blk, clr_sub, card_w, clr_icon)
    end
    local cc = CenterContainer:new{
        dimen = Geom:new{ w = card_w, h = card_h },
        buildInner(stats),
    }
    local fc = FrameContainer:new{
        dimen      = Geom:new{ w = card_w, h = card_h },
        bordersize = 0,
        background = nil,
        padding    = 0,
        cc,
    }
    local fill = Backdrop.BackdropFill:new{
        width   = card_w,
        height  = card_h,
        surface = surface,
        radius  = d.corner_r,
        dimen   = Geom:new{ w = card_w, h = card_h },
    }
    local card = OverlapGroup:new{
        dimen = Geom:new{ w = card_w, h = card_h },
        fill,
        fc,
    }
    local update_fn = function(new_stats)
        local old = cc[1]
        cc[1] = buildInner(new_stats)
        old:free()
    end
    return card, update_fn
end

local function buildStatListCell(cell_w, stat_id, stats, show_sep, d, align)
    local clr_blk = SUIStyle.COLOR.text_primary
    local clr_sub = CLR_TEXT_SUB

    local cc = CenterContainer:new{
        dimen = Geom:new{ w = cell_w, h = d.card_h },
        _buildCardInner(stat_id, stats, d, align, clr_blk, clr_sub, cell_w),
    }
    local card = FrameContainer:new{
        dimen      = Geom:new{ w = cell_w, h = d.card_h },
        bordersize = 0,
        padding    = 0,
        cc,
    }

    local og = OverlapGroup:new{
        dimen = Geom:new{ w = cell_w, h = d.card_h },
        card,
    }
    if show_sep then
        local sep = LineWidget:new{
            dimen      = Geom:new{ w = d.sep_w, h = d.card_h },
            background = SUIStyle.COLOR.gray,
        }
        sep.overlap_offset = { cell_w - d.sep_w, 0 }
        og[#og+1] = sep
    end
    local update_fn = function(new_stats)
        local old = cc[1]
        cc[1] = _buildCardInner(stat_id, new_stats, d, align, clr_blk, clr_sub, cell_w)
        old:free()
    end
    return og, update_fn
end

--- Opens a statistics window by id. Returns false when the windows module
--- is unavailable so the caller can fall back.
local function _openStatsWindow(id)
    return (pcall(require("screens/sui_stats_launcher").open, id))
end

local function openReadingInsights()
    if not _openStatsWindow("insights") then
        UIManager:broadcastEvent(require("ui/event"):new("ShowReaderProgress"))
    end
end

--- Opens the detail window of the stat `sid`, if it has one
--- (total_books -> finished books, streak -> Streak Manager).
--- Shared by both tap handlers in build() below. Returns true if a
--- detail window was opened.
local function _openStatDetail(sid)
    if sid == "total_books" then
        return _openStatsWindow("finished_books")
    elseif sid == "streak" then
        return _openStatsWindow("streak")
    end
    return false
end

-- Opens the edit sheet of the stat `stat_id` of instance `id`: its width, its
-- place in the grid and whether it is highlighted. `on_changed` runs after every
-- saved change.
local function openEditSheet(id, pfx, stat_id, on_changed)
    local items_key = pfx .. id .. SETTING_ITEMS
    local spans_key = pfx .. id .. SETTING_SPANS
    require("modules/reading_stats/width_sheet").show{
        stat_id   = stat_id,
        max       = RS_MAX_COLS,
        label_for = function(other) return STAT_MAP[other] and STAT_MAP[other].display_label or other end,
        icon_for  = function(other) return STAT_MAP[other] and STAT_MAP[other].icon end,
        state     = function()
            return { ids = _getItems(id, pfx), spans = _getSpans(id, pfx), cols = gridDims(id, pfx).cols }
        end,
        set       = function(stat, v)
            local map = {}
            for k, n in pairs(_getSpans(id, pfx)) do map[k] = n end
            map[stat] = v > 1 and v or nil
            SUISettings:saveSetting(spans_key, next(map) and map or nil)
        end,
        move      = function(stat, delta)
            local ids = SpanGrid.shift(_getItems(id, pfx), stat, delta)
            if ids then SUISettings:saveSetting(items_key, ids) end
        end,
        highlight_get = function(stat)
            if getType(id, pfx) == "list" then return nil end
            return _getHighlights(id, pfx)[stat] == true
        end,
        highlight_set = function(stat, on) _setHighlight(id, pfx, stat, on) end,
        on_changed = on_changed,
    }
end

-- Sheet of a tapped card: the window the card opens, and its edit sheet.
local function showCardSheet(id, stat_id, ctx)
    local ActionSheet = require("engines/sui_action_sheet")
    local entry = STAT_MAP[stat_id]
    local open_text, open_icon = _("Reading Insights"), "chart"
    if stat_id == "total_books" then
        open_text, open_icon = _("Finished Books"), "book"
    elseif stat_id == "streak" then
        open_text, open_icon = _("Streak"), "streak"
    end
    local items = {
        {
            text     = open_text,
            sui_icon = open_icon,
            callback = function()
                if not _openStatDetail(stat_id) then openReadingInsights() end
            end,
        },
    }
    if entry then
        items[#items + 1] = {
            text     = _("Edit card"),
            sui_icon = "edit",
            callback = function() openEditSheet(id, ctx.pfx, stat_id, ctx.refresh_fn) end,
        }
    end
    ActionSheet.show{
        name       = "sui_win_stat_card",
        title      = entry and entry.display_label,
        icon       = entry and entry.icon,
        auto_close = true,
        fit_width  = true,
        sections   = { ActionSheet.list(items) },
    }
end

-- Wraps a card in a D-pad focus stop whose Press runs `on_select`. The focus
-- frame follows the wrapper's painted box, so no rebuild is needed to move it.
local function _makeFocusStop(card, w, h, on_select)
    return UI.makeFocusable(InputContainer:new{ dimen = Geom:new{ w = w, h = h }, card }, on_select)
end

-- Page indicator row under a paged grid: "page/pages" between the chevrons,
-- right-aligned in `w` (the chevron icon, not its padding, meets the right
-- edge). Returns the row and its D-pad stops, the chevrons that can turn the
-- page.
local function buildPager(ctx, id, w, page, npages, lf)
    local face  = pagerFace(lf)
    local row_h = PageNav.rowHeight(face)
    local indicator, stops = PageNav.buildPager(page, npages, row_h,
        UI.makeColoredText{ text = string.format("%d/%d", page, npages), face = face, bold = false },
        PAD,
        function(delta) GridRenderer.requestPageTurn(ctx, id, delta) end,
        ctx.kbStops ~= nil)
    return RightContainer:new{ dimen = Geom:new{ w = w + Size.padding.button, h = row_h }, indicator }, stops
end

-- ---------------------------------------------------------------------------
-- Module API
--
-- build, getHeight and getMenuItems live at module level and take the instance
-- id, so each instance descriptor (makeInstance, below) closes over only a few
-- locals.
-- ---------------------------------------------------------------------------
local function isEnabled(id, pfx)
    return SUISettings:readSetting(pfx .. id .. SETTING_ENABLED) == true
end

local function build(id, w, ctx)
    if not isEnabled(id, ctx.pfx) then return nil end
    local styles = Config.resolveTextStyles(ctx, id, TEXT_ELEMS)

    -- Compute all scaled dims once for this render pass.
    --
    -- Two scale bases, same split as module_clock.lua's build(): `scale`
    -- (module scale × lf) drives fixed-pixel dimensions (card height, gaps,
    -- separators). `raw_scale` (module scale only) drives card text size,
    -- since that's derived from item_w, which is already narrowed for
    -- landscape via `w` upstream — applying lf again would narrow it twice.
    local lf        = (ctx and ctx.landscape_factor) or 1
    local scale     = Config.getModuleScale(id, ctx and ctx.pfx) * lf
    local raw_scale = Config.getModuleScaleRaw(id, ctx and ctx.pfx)

    local mode     = getType(id, ctx.pfx)
    local detailed = mode == "detailed"
    local g        = gridMetrics(id, ctx.pfx, mode, scale, lf, w, raw_scale, styles, ctx.grow_h)
    local card_h   = g.card_h

    -- The page on screen: the stats it holds, and the data they read.
    local page = math.min(PageState.get(ctx, id), g.npages)
    PageState.setPage(ctx, id, page)
    PageState.setCount(ctx, id, g.npages)
    local paged    = g.npages > 1
    local stat_ids = g.pages[page].ids
    local page_rows = g.pages[page].rows
    local row_h     = g.row_h[page]
    local n        = #stat_ids
    ensureData(ctx, stat_ids, mode)

    -- Per-card width used as the text-sizing basis. Mirrors the "cards"
    -- layout's own card_w formula (below) regardless of the selected
    -- display type ("list" cells are actually a bit wider, with no gaps
    -- subtracted, so sizing text off the narrower "cards" width is a safe,
    -- conservative basis there too).
    -- `w` is already label-aligned via module chrome outer margin.
    local item_w = g.item_w

    -- Placeholder ("no stats selected") isn't card text — it spans the full
    -- row, so it keeps the old fixed-pixel/lf-scaled sizing.
    local _ph_fs  = math.max(8, math.floor(_BASE_RS_PH_FS  * scale))
    -- Dims shared by every card.
    local d = {
        detailed = detailed,
        card_h   = card_h,
        gap      = g.gap,
        corner_r = math.floor(_BASE_RS_CORNER_R  * scale),
        sep_w    = g.sep_w,
        ph_fs    = _ph_fs,
        -- Detailed cards: whether the icon is left out.
        hide_icons  = SUISettings:isTrue(ctx.pfx .. id .. SETTING_HIDE_ICONS),
        face_ph   = Font:getFace(SUIStyle.FACE_REGULAR, _ph_fs),
    }

    -- Dims of the cards that span `span` columns: `d` plus the sizes that follow
    -- the card width, resolved once per span. Faces are pre-resolved here —
    -- shared by all card builders, avoids repeated face lookups inside the
    -- per-card build loop.
    local span_dims = {}
    local function dimsFor(span)
        local sd = span_dims[span]
        if sd then return sd end
        local basis_w = span * item_w + (span - 1) * g.gap
        local _val_fs, _lbl_fs = cardFontSizes(basis_w, raw_scale, styles, card_h, detailed)
        local face_val, bold_val = SUIStyle.getTextFace(styles.value, _val_fs)
        -- Value face at `pct` of the regular size, resolved once per size.
        local pct_faces = {}
        local function valueFace(pct)
            local pair = pct_faces[pct]
            if not pair then
                local face, bold = SUIStyle.getTextFace(styles.value,
                    _clampFs(_val_fs * pct, _RS_VAL_FS_MIN, _val_fs))
                pair = { face, bold }
                pct_faces[pct] = pair
            end
            return pair[1], pair[2]
        end
        local face_lbl, bold_lbl = SUIStyle.getTextFace(styles.label, _lbl_fs)
        sd = setmetatable({
            bar_max  = basis_w,
            face_val  = face_val,  bold_val = bold_val,
            valueFace = valueFace,
            face_lbl  = face_lbl,  bold_lbl = bold_lbl,
            -- The streak icon is a symbol glyph the chosen family may lack.
            face_icon = Font:getFace(SUIStyle.FACE_REGULAR, _val_fs),
        }, { __index = d })
        if detailed then
            -- The streak card shows the last 7 days as dots under the value;
            -- the same space holds the bars of the stats with a chart, which
            -- grow to the card width.
            local dm = g.detailOf(span)
            sd.pad, sd.icon_d, sd.dots_gap, sd.body_gap, sd.dot_max =
                dm.pad, dm.icon_d, dm.gap, dm.body_gap, dm.dot_max
        end
        span_dims[span] = sd
        return sd
    end

    -- Show a placeholder when enabled but no stats have been selected yet.
    if n == 0 then
        UI.setFocusRows(ctx, id, RS_MAX_ROWS, {})
        if ctx.kbStops then ctx.kbStops(id .. ":pager", {}) end
        local hold_on = SUISettings:nilOrTrue("simpleui_hs_settings_on_hold")
        local ph_text = hold_on and _("No stats selected  —  long press to configure")
                                 or _("No stats selected")
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = d.card_h },
            UI.makeColoredText{
                text    = ph_text,
                face    = d.face_ph,
                fgcolor = CLR_TEXT_SUB,
                width   = w - PAD * 2,
            },
        }
    end

    -- Stats are pre-fetched by StatsProvider (via _buildCtx) and passed in
    -- ctx.stats; ensureData above completes them for a page the first paint
    -- did not show.
    local stats = _collectStats(ctx)
    if ctx.stats and ctx.stats.db_conn_fatal then ctx.db_conn_fatal = true end
    local align     = getAlign(id, ctx.pfx)
    local row_align = getRowAlign(id, ctx.pfx)
    local list      = mode == "list"

    -- Cards and detailed cards are rounded and spaced out, drawn from the card
    -- surface; list cells fill the grid's columns edge to edge, split by lines.
    -- `w` is already label-aligned via module chrome outer margin.
    local cols     = g.cols
    local col_gap  = list and 0 or g.gap
    local cell_w   = math.floor((w - col_gap * (cols - 1)) / cols)
    local row_w    = cols * cell_w + (cols - 1) * col_gap
    local offset_x = list and 0 or math.floor((w - row_w) / 2)
    local surface  = not list and SUIWallpaper.resolveSurface(cardSurface(id, ctx.pfx)) or nil
    local highlights = list and {} or _getHighlights(id, ctx.pfx)
    local highlight_surface
    local function surfaceFor(stat_id)
        if not highlights[stat_id] then return surface end
        highlight_surface = highlight_surface or highlightSurface(id, ctx.pfx, surface)
        return highlight_surface
    end

    local update_funcs = {}
    local row_stops    = {}
    local grid         = VerticalGroup:new{ align = "left" }

    -- Width of a card spanning `span` columns.
    local function cardWidth(span) return span * cell_w + (span - 1) * col_gap end

    -- Left inset of a row: a short row of cards is placed by the row
    -- alignment, list cells keep their columns.
    local function rowInset(row)
        if list or row_align == "left" then return 0 end
        local free = (cols - row.used) * (cell_w + col_gap)
        return row_align == "right" and free or math.floor(free / 2)
    end

    -- Registers the card `cell`, in grid row `r`, as a D-pad stop (Press opens
    -- what a tap on that card opens) and returns the widget to place.
    local function addFocusStop(cell, r, card)
        if not ctx.kbStops then return card end
        local stop = _makeFocusStop(card, cardWidth(cell.span), row_h[r], function()
            showCardSheet(id, cell.id, ctx)
        end)
        local stops = row_stops[r]
        stops[#stops + 1] = { id = cell.id, widget = stop }
        return stop
    end

    for r, row in ipairs(page_rows) do
        if r > 1 then
            grid[#grid + 1] = list
                and LineWidget:new{ dimen = Geom:new{ w = row_w, h = g.row_gap }, background = SUIStyle.COLOR.gray }
                or  VerticalSpan:new{ width = g.row_gap }
        end
        local hrow = HorizontalGroup:new{ align = "center" }
        grid[#grid + 1] = hrow
        local inset = rowInset(row)
        if inset > 0 then hrow[1] = HorizontalSpan:new{ width = inset } end
        row_stops[r] = {}
        for c, cell in ipairs(row.cells) do
            local cd = dimsFor(cell.span)
            local card, update_fn
            if list then
                card, update_fn = buildStatListCell(cardWidth(cell.span), cell.id, stats, c < #row.cells, cd, align)
            else
                card, update_fn = buildStatCardWidget(cardWidth(cell.span), row_h[r], cell.id, stats, cd, align, surfaceFor(cell.id))
            end
            table.insert(update_funcs, { fn = update_fn, cats = changedCats(cell.id, mode) })
            if c > 1 and col_gap > 0 then hrow[#hrow + 1] = HorizontalSpan:new{ width = col_gap } end
            hrow[#hrow + 1] = addFocusStop(cell, r, card)
        end
        -- Pad a short row to the full grid width so the grid keeps its place.
        local trail = list and 0 or (cols - row.used) * (cell_w + col_gap) - inset
        if trail > 0 then hrow[#hrow + 1] = HorizontalSpan:new{ width = trail } end
    end
    UI.setFocusRows(ctx, id, g.rows, row_stops)

    -- Stat id at a point of the grid (relative to its top-left corner), or
    -- nil on the space between cards.
    local function cardAt(dx, dy)
        if dx < 0 or dy < 0 then return nil end
        local col_step = cell_w + col_gap
        local row, top = nil, 0
        for r, h in ipairs(row_h) do
            if dy < top then break end
            if dy < top + h then row = r break end
            top = top + h + g.row_gap
        end
        if not row then return nil end
        dx = dx - rowInset(page_rows[row])
        if dx < 0 then return nil end
        local col = math.floor(dx / col_step) + 1
        if col > cols then return nil end
        local cell = SpanGrid.cellAt(page_rows[row].cells, col)
        if not cell or dx > (cell.col - 1) * col_step + cardWidth(cell.span) then return nil end
        return cell.id
    end

    -- A paged grid fills its whole area on every page: the eraser restores the
    -- background under the cards of a longer page, and the cards stay in their
    -- grid position on a shorter one.
    local inner
    if paged then
        grid.overlap_offset = { offset_x, 0 }
        inner = OverlapGroup:new{
            dimen = Geom:new{ w = w, h = g.grid_h },
            allow_mirroring = false,  -- offset_x is also the tap hit-test origin
            GridRenderer.makeEraser(w, g.grid_h, ModuleChrome.NO_CHROME),
            grid,
        }
    elseif list then
        inner = grid
    else
        inner = CenterContainer:new{ dimen = Geom:new{ w = w, h = g.grid_h }, grid }
    end

    -- Single tappable over the whole grid — all cards open the same sheet,
    -- so one InputContainer + one GestureRange + one handler replaces N of each.
    local tappable = InputContainer:new{
        dimen = Geom:new{ w = w, h = g.grid_h },
        [1]   = FrameContainer:new{
            dimen      = Geom:new{ w = w, h = g.grid_h },
            bordersize = 0, padding = 0,
            inner,
        },
    }
    tappable.ges_events = {
        TapStatCard = { GestureRange:new{ ges = "tap", range = function() return tappable.dimen end } },
    }
    function tappable:onTapStatCard(_, ges)
        local sid
        if ges and ges.pos and self.dimen then
            local dx = ges.pos.x - self.dimen.x - offset_x
            -- The rows of cards are drawn mirrored in an RTL layout.
            if BD.mirroredUILayout() then dx = row_w - dx end
            sid = cardAt(dx, ges.pos.y - self.dimen.y)
        end
        showCardSheet(id, sid, ctx)
        return true
    end

    local result = tappable
    local pager_stops
    if paged then
        -- A swipe turns the page; the screen engine hands it to this handler.
        tappable.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = function() return tappable.dimen end } }
        function tappable:onSwipe(_, ges)
            local delta = PageNav.swipeDelta(ges)
            if not delta then return false end
            GridRenderer.requestPageTurn(ctx, id, delta)
            return true
        end
        local pager
        pager, pager_stops = buildPager(ctx, id, w, page, g.npages, lf)
        result = VerticalGroup:new{ align = "left", tappable, VerticalSpan:new{ width = g.gap }, pager }
        local size = result:getSize()
        result.dimen = Geom:new{ w = size.w, h = size.h }
    end
    -- The chevrons follow the rows of the grid in the D-pad order; the row is
    -- emptied when the grid has a single page.
    if ctx.kbStops then ctx.kbStops(id .. ":pager", pager_stops or {}) end

    result._rs_update_funcs = update_funcs
    result._rs_records = ctx.session_records
    result._rs_status  = ctx.status_counts
    result._rs_charts  = ctx.stat_charts
    result._rs_year    = ctx.year_data
    return result
end

local function updateStats(widget, ctx)
    if not widget or not widget._rs_update_funcs then return false end
    local sp = ctx.stats or {}
    -- _changed tells us which categories were actually re-fetched this cycle.
    -- When absent (e.g. older SP version or SP.invalidate() full reset), treat
    -- everything as changed so we don't silently skip any card.
    local changed = sp._changed  -- may be nil
    -- Session records and chart data come from their own cached queries, not
    -- from SP.get(): the same table instance means they did not change.
    local same = {
        records = widget._rs_records == ctx.session_records,
        status  = widget._rs_status  == ctx.status_counts,
        charts  = widget._rs_charts  == ctx.stat_charts,
        year    = widget._rs_year    == ctx.year_data,
    }
    widget._rs_records = ctx.session_records
    widget._rs_status  = ctx.status_counts
    widget._rs_charts  = ctx.stat_charts
    widget._rs_year    = ctx.year_data
    local stats = _collectStats(ctx)
    -- True when the data of category `cat` is known to be unchanged.
    local function unchanged(cat)
        if same[cat] ~= nil then return same[cat] end
        -- A field preserved from cache holds the identical value.
        return changed ~= nil and changed[cat] == false
    end
    local any_updated = false
    for _, entry in ipairs(widget._rs_update_funcs) do
        -- Skip a card whose data categories all did not change this cycle: no
        -- need to rebuild its TextWidgets or mark it dirty.
        local skip = entry.cats ~= nil
        for _, cat in ipairs(entry.cats or {}) do
            if not unchanged(cat) then skip = false break end
        end
        if not skip then
            entry.fn(stats)
            any_updated = true
        end
    end
    -- Return true only if at least one card was actually updated, so the caller
    -- can skip setDirty entirely when nothing changed.
    return any_updated
end

local function getHeight(id, _ctx)
    local lf = (_ctx and _ctx.landscape_factor) or (UI.isLandscape() and UI.getLandscapeFactor() or 1)
    local pfx = _ctx and _ctx.pfx
    local scale = Config.getModuleScale(id, pfx) * lf
    local w = (_ctx and (_ctx.col_w or _ctx.inner_w)) or UI.getInnerW()
    local styles = Config.resolveTextStyles(_ctx, id, TEXT_ELEMS)
    return gridMetrics(id, pfx or DEFAULT_PFX, getType(id, pfx or DEFAULT_PFX), scale, lf,
        w, Config.getModuleScaleRaw(id, pfx), styles).height
end


local function _makeScaleItem(id, ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size."),
        get          = function() return Config.getModuleScalePct(id, pfx) end,
        set          = function(v) Config.setModuleScale(v, id, pfx) end,
        refresh      = ctx_menu.refresh,
    })
end
local function getMenuItems(id, ctx_menu)
    local pfx         = ctx_menu.pfx
    local refresh     = ctx_menu.refresh
    local _lc         = ctx_menu._
    local items_key   = pfx .. id .. SETTING_ITEMS
    local StatsMenu = require("features/sui_stats_menu")
    local text_opts = {
        mod_id  = id,
        elems   = TEXT_ELEMS,
        labels  = { value = _lc("Value"), label = _lc("Label") },
        info    = _lc("Size of this text.\n100% is the default size."),
        -- Detailed cards size their text from the card, capped by its height.
        family_only = function() return getType(id, pfx) == "detailed" end,
        pfx     = pfx,
        refresh = refresh,
        _lc     = _lc,
    }
    local item_rows = {
        Arrange.makeListItem{
            ctx_menu = ctx_menu,
            title    = _lc("Items"),
            labels   = {
                action  = _lc("Arrange Reading Stats"),
                empty   = _lc("No items selected."),
                too_few = _lc("Add at least 2 stats to arrange."),
                settings = _lc("Edit card"),
            },
            pool   = function() return _stat_pool end,
            getIds = function() return _getItems(id, pfx) end,
            setIds = function(ids) SUISettings:saveSetting(items_key, ids) end,
            detail = function(sid)
                local dims = gridDims(id, pfx)
                local span = 1
                for _r, row in ipairs(dims.packed) do
                    for _c, cell in ipairs(row.cells) do
                        if cell.id == sid then span = cell.span end
                    end
                end
                return require("modules/reading_stats/width_sheet").summary(span, dims.cols, RS_MAX_COLS)
            end,
            onSelect = function(sid) openEditSheet(id, pfx, sid, ctx_menu.refresh) end,
        },
    }
    -- Size of a page: the stats beyond it go on further pages.
    local function gridValue()
        local dims = gridDims(id, pfx)
        return T(_lc("%1 × %2"), dims.cols, dims.rows)
    end
    local size_rows = {
        _makeScaleItem(id, ctx_menu),
        Config.makeDoubleStepperItem{
            text_func      = function() return _lc("Grid size") end,
            value_func     = gridValue,
            mandatory_func = gridValue,
            title          = _lc("Grid size"),
            left = {
                text          = _lc("Columns"),
                get           = function() return gridDims(id, pfx).cols end,
                set           = function(v) Config.saveClampedInt(pfx .. id .. SETTING_GRID_COLS, v, 1, RS_MAX_COLS) end,
                value_min     = 1,
                value_max     = RS_MAX_COLS,
                default_value = RS_DEFAULT_COLS,
            },
            right = {
                text          = _lc("Rows"),
                get           = function() return gridDims(id, pfx).rows end,
                set           = function(v) Config.saveClampedInt(pfx .. id .. SETTING_GRID_ROWS, v, 1, RS_MAX_ROWS) end,
                value_min     = 1,
                value_max     = RS_MAX_ROWS,
                default_value = 1,
            },
            refresh = refresh,
        },
    }
    local function currentHighlight()
        return highlightTone(id, pfx, Backdrop.resolve(cardSurface(id, pfx)))
    end
    local appearance_extra = {
        Config.makeRadioSubmenuItem{
            text    = _lc("Style"),
            options = {
                { value = "cards",    label = _lc("Cards") },
                { value = "detailed", label = _lc("Detailed Cards") },
                { value = "list",     label = _lc("List") },
            },
            get     = function() return getType(id, pfx) end,
            set     = function(v) SUISettings:saveSetting(pfx .. id .. SETTING_TYPE, v) end,
            refresh = refresh,
        },
        Config.makeSurfaceMenu({
            surface      = cardSurface(id, pfx),
            enabled_func = function() return getType(id, pfx) ~= "list" end,
            refresh      = refresh,
            _lc          = _lc,
        }),
        Config.makeRadioSubmenuItem{
            text         = _lc("Highlight color"),
            enabled_func = function() return getType(id, pfx) ~= "list" end,
            options      = function()
                -- The card fill is never offered: a highlight must differ from it.
                local fill = Backdrop.readTone(cardSurface(id, pfx))
                local options = {
                    { value = "black", label = _lc("Black") },
                    { value = "gray",  label = _lc("Gray") },
                }
                for _i, option in ipairs(SUIStyle.paletteOptions(_lc)) do options[#options + 1] = option end
                for i = #options, 1, -1 do
                    if options[i].value == fill then table.remove(options, i) end
                end
                return options
            end,
            get           = currentHighlight,
            current_label = function()
                return ({ black = _lc("Black"), gray = _lc("Gray"), accent = _lc("Accent"), secondary = _lc("Secondary") })[currentHighlight()]
            end,
            set           = function(tone) SUISettings:saveSetting(pfx .. id .. SETTING_HIGHLIGHT_TONE, tone) end,
            refresh       = refresh,
        },
        Config.makeAlignmentItem{
            key          = pfx .. id .. SETTING_ALIGN,
            enabled_func = function() return getType(id, pfx) ~= "detailed" end,
            refresh      = refresh,
            _lc          = _lc,
        },
        Config.makeAlignmentItem{
            text         = _lc("Row alignment"),
            key          = pfx .. id .. SETTING_ROW_ALIGN,
            default      = "left",
            enabled_func = function() return getType(id, pfx) ~= "list" end,
            refresh      = refresh,
            _lc          = _lc,
        },
        {
            text           = _lc("Show icons"),
            enabled_func   = function() return getType(id, pfx) == "detailed" end,
            checked_func   = function() return not SUISettings:isTrue(pfx .. id .. SETTING_HIDE_ICONS) end,
            keep_menu_open = true,
            callback       = function()
                local key = pfx .. id .. SETTING_HIDE_ICONS
                SUISettings:set(key, not SUISettings:isTrue(key) and true or nil)
                refresh()
            end,
        },
    }
    local content_rows = {
        StatsMenu.makeStreakModeItem(refresh),
    }
    local behaviour_rows = {
        {
            text           = _lc("Update Stats Now"),
            separator      = true,
            keep_menu_open = true,
            callback       = function() StatsMenu.updateNow(ctx_menu.refresh or refresh) end,
        },
    }
    return Config.buildModuleMenu({
        items   = item_rows,
        content = content_rows,
        appearance = {
            size  = size_rows,
            text  = text_opts,
            extra = appearance_extra,
        },
        behaviour = behaviour_rows,
    }, ctx_menu)
end

-- ---------------------------------------------------------------------------
-- Instances
-- ---------------------------------------------------------------------------

-- Sub-module descriptor of instance `inst_id` (see modules/moduleregistry.lua).
local function makeInstance(inst_id)
    Config.declareTextVariants(inst_id, TEXT_VARIANTS)
    local S = {
        id          = inst_id,
        name        = _("Reading Stats"),
        label       = nil,   -- no section label; uses own top-padding
        default_on  = false,
        is_book_mod = true,  -- needed for the surgical repaint of a page turn
        text_elems  = TEXT_ELEMS,
        needs       = makeNeeds(inst_id),
        updateStats = updateStats,
        fills_row_height = true,
    }
    function S.isEnabled(pfx) return isEnabled(inst_id, pfx) end
    function S.setEnabled(pfx, on)
        SUISettings:saveSetting(pfx .. inst_id .. SETTING_ENABLED, on)
    end
    function S.build(w, ctx) return build(inst_id, w, ctx) end
    function S.getHeight(ctx) return getHeight(inst_id, ctx) end
    function S.getMenuItems(ctx_menu) return getMenuItems(inst_id, ctx_menu) end
    return S
end

local M = {}
M.id            = BASE_ID
M.name          = _("Reading Stats")
M.category      = "stats"
M.instanciable  = true
M.bare_instance = true   -- BASE_ID is itself the first instance
M.instances_key = "simpleui_reading_stats_instances"
M.makeInstance  = makeInstance
-- Settings of an instance besides the ones every instance has.
M.setting_suffixes = {
    SETTING_TYPE, SETTING_ALIGN, SETTING_ROW_ALIGN, SETTING_CARD_STR,
    SETTING_GRID_COLS, SETTING_GRID_ROWS, SETTING_HIDE_ICONS,
    SETTING_SPANS, SETTING_HIGHLIGHTS, SETTING_HIGHLIGHT_TONE,
}

-- Layout-editor summary of an instance: the stats it shows.
function M.getSummary(inst_id, pfx)
    local names = {}
    for _i, stat_id in ipairs(_getItems(inst_id, pfx)) do
        local entry = STAT_MAP[stat_id]
        names[#names + 1] = entry and entry.display_label or stat_id
    end
    return table.concat(names, "  ·  ")
end

return M