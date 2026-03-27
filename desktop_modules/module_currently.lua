-- module_currently.lua — Simple UI
-- Currently Reading module: cover + title + author + progress bar + percentage.

local Device  = require("device")
local Screen  = Device.screen
local _       = require("gettext")
local logger  = require("logger")

local Blitbuffer      = require("ffi/blitbuffer")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local UIManager       = require("ui/uimanager")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")

local Config       = require("sui_config")
local UI           = require("sui_core")
local PAD          = UI.PAD
local LABEL_H      = UI.LABEL_H
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

-- Shared helpers — lazy-loaded.
local _SH = nil
local function getSH()
    if not _SH then
        local ok, m = pcall(require, "desktop_modules/module_books_shared")
        if ok and m then _SH = m
        else logger.warn("simpleui: module_currently: cannot load module_books_shared: " .. tostring(m)) end
    end
    return _SH
end

-- Internal spacing — base values at 100% scale; scaled at render time.
local _BASE_COVER_GAP  = Screen:scaleBySize(12)
local _BASE_TITLE_GAP  = Screen:scaleBySize(4)
local _BASE_AUTHOR_GAP = Screen:scaleBySize(8)
local _BASE_BAR_H      = Screen:scaleBySize(7)
local _BASE_BAR_GAP    = Screen:scaleBySize(6)
local _BASE_PCT_GAP    = Screen:scaleBySize(3)
local _BASE_TITLE_FS   = Screen:scaleBySize(11)
local _BASE_AUTHOR_FS  = Screen:scaleBySize(10)
local _BASE_PCT_FS     = Screen:scaleBySize(8)

local _CLR_DARK    = Blitbuffer.COLOR_BLACK
local _CLR_BAR_BG  = Blitbuffer.gray(0.15)
local _CLR_BAR_FG  = Blitbuffer.gray(0.75)

local _BASE_STATS_FS    = Screen:scaleBySize(8)
-- Width reserved for the inline percentage label (e.g. "100%")
local _BASE_PCT_W       = Screen:scaleBySize(32)
-- Gap between bar and percentage label
local _BASE_BAR_PCT_GAP = Screen:scaleBySize(6)

-- Setting key for progress bar style: "simple" (default) or "with_pct"
local BAR_STYLE_KEY = "currently_bar_style"

local function getBarStyle(pfx)
    return G_reader_settings:readSetting(pfx .. BAR_STYLE_KEY) or "simple"
end

-- Font size for the inline percentage — matches module_reading_goals row font.
local _BASE_INLINEPCT_FS = Screen:scaleBySize(11)

-- Builds an inline progress bar: [▓▓▓░░░░] XX%
-- Mirrors the logic from module_reading_goals.buildGoalRow to avoid
-- the percentage label overlapping the bar fill.
-- scale and lbl_scale are passed in so PCT_W, GAP and font track the module scale.
local function buildProgressBarWithPct(w, pct, bar_h, bar_gap_w, scale, lbl_scale)
    local fs      = math.max(7, math.floor(_BASE_INLINEPCT_FS * scale * lbl_scale))
    local PCT_W   = math.max(16, math.floor(_BASE_PCT_W       * scale * lbl_scale))
    local GAP     = math.max(2,  math.floor(_BASE_BAR_PCT_GAP * scale))
    local bar_w   = math.max(10, w - GAP - PCT_W)
    local fw      = math.max(0, math.floor(bar_w * math.min(pct, 1.0)))
    local pct_str = string.format("%d%%", math.floor((pct or 0) * 100))

    local bar
    if fw <= 0 then
        bar = LineWidget:new{ dimen = Geom:new{ w = bar_w, h = bar_h }, background = _CLR_BAR_BG }
    else
        bar = OverlapGroup:new{
            dimen = Geom:new{ w = bar_w, h = bar_h },
            LineWidget:new{ dimen = Geom:new{ w = bar_w, h = bar_h }, background = _CLR_BAR_BG },
            LineWidget:new{ dimen = Geom:new{ w = fw,    h = bar_h }, background = _CLR_BAR_FG },
        }
    end

    -- Vertically centre the bar against the text height using an OverlapGroup
    -- so the HorizontalGroup align="center" keeps everything on one baseline.
    local row = HorizontalGroup:new{
        align = "center",
        bar,
        HorizontalSpan:new{ width = GAP },
        TextWidget:new{
            text    = pct_str,
            face    = Font:getFace("smallinfofont", fs),
            bold    = true,
            fgcolor = _CLR_DARK,
            width   = PCT_W,
        },
    }

    return FrameContainer:new{
        bordersize     = 0,
        padding        = 0,
        padding_bottom = bar_gap_w,
        row,
    }
end

local TITLE_MAX_LEN = 60

-- ---------------------------------------------------------------------------
-- Per-book stats (reading days, total time read, time remaining)
-- ---------------------------------------------------------------------------
local function fmtTime(secs)
    secs = math.floor(secs or 0)
    if secs <= 0 then return "0m" end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 and m > 0 then return string.format("%dh %dm", h, m)
    elseif h > 0        then return string.format("%dh", h)
    else                     return string.format("%dm", m) end
end

-- ---------------------------------------------------------------------------
-- FIX 1: fetchBookStats and fetchAvgTime merged into a single DB query.
--
-- Previously two separate functions opened (potentially) two connections and
-- ran two queries on every render when stats were enabled. The second query
-- (fetchAvgTime) contained a GROUP BY subquery over page_stat — the most
-- expensive operation on a slow eMMC e-reader.
--
-- This single function returns { days, total_secs, avg_time } in one pass,
-- using one connection and one round-trip to SQLite.
--
-- FIX 2: force_fresh no longer forces a new connection open when shared_conn
-- is already available. The fresh flag's only purpose is to bypass the
-- prefetch cache (handled in build()); the shared connection — if present —
-- already reflects committed data because the host reopened it after the
-- reading session ended. Opening a second private connection in parallel
-- added ~100–300 ms of unnecessary I/O on each return to the homescreen.
-- ---------------------------------------------------------------------------
local _MAX_SEC = 120 -- mirrors ReaderStatistics DEFAULT_MAX_READ_SEC

-- Per-book stats cache — keyed by md5, mirrors the day-keyed cache pattern
-- used in module_reading_stats. Avoids re-running the GROUP BY subquery on
-- every render; invalidated by onBookClosed() when the reading session ends.
local _bstats_cache = {}   -- md5 → { days, total_secs, avg_time }

local function fetchBookStats(md5, shared_conn, force_fresh)
    if not md5 then return nil end

    -- Cache hit: return immediately without touching SQLite.
    -- force_fresh is set when returning from a reading session; in that case
    -- the cached value is stale and must be discarded (same as invalidateCache
    -- in module_reading_stats).
    if not force_fresh and _bstats_cache[md5] then
        return _bstats_cache[md5]
    end

    -- FIX 2: reuse shared_conn even when force_fresh — only bypass the
    -- prefetch cache (done in build()), not the connection itself.
    local conn     = shared_conn or Config.openStatsDB()
    local own_conn = not shared_conn
    if not conn then return nil end

    local result = nil
    local ok, err = pcall(function()
        -- FIX 1: single query returns days, total time, and capped avg_time.
        -- The capped-average subquery (min per-page sum, max _MAX_SEC) mirrors
        -- STATISTICS_SQL_BOOK_CAPPED_TOTALS_QUERY from ReaderStatistics so the
        -- "time remaining" estimate is consistent with the Statistics plugin.
        local row = conn:exec(string.format([[
            SELECT
                count(DISTINCT date(ps.start_time, 'unixepoch', 'localtime')),
                sum(ps.duration),
                count(DISTINCT capped.page),
                sum(capped.min_dur)
            FROM page_stat ps
            JOIN book ON book.id = ps.id_book
            JOIN (
                SELECT ps2.page, min(sum(ps2.duration), %d) AS min_dur
                FROM page_stat ps2
                JOIN book b2 ON b2.id = ps2.id_book
                WHERE b2.md5 = %q
                GROUP BY ps2.page
            ) capped ON capped.page = ps.page
            WHERE book.md5 = %q;
        ]], _MAX_SEC, md5, md5))

        if row and row[1] and row[1][1] then
            local days   = tonumber(row[1][1]) or 0
            local secs   = tonumber(row[2] and row[2][1]) or 0
            local pages  = tonumber(row[3] and row[3][1]) or 0
            local capped = tonumber(row[4] and row[4][1]) or 0
            result = {
                days       = days,
                total_secs = secs,
                avg_time   = (pages > 0 and capped > 0) and (capped / pages) or nil,
            }
        end
    end)
    if not ok then
        logger.warn("simpleui: module_currently: fetchBookStats failed: " .. tostring(err))
    end
    if own_conn then pcall(function() conn:close() end) end
    -- Populate cache (even on partial/nil result to avoid hammering the DB on
    -- repeated renders when the book has no stats yet).
    if result then _bstats_cache[md5] = result end
    return result
end

-- ---------------------------------------------------------------------------
-- Title truncation — single UTF-8 pass (replaces the previous two-pass
-- utf8CharCount + utf8Sub approach to halve the number of iterations).
-- ---------------------------------------------------------------------------
local function truncateTitle(title)
    if not title then return title end
    local count, i = 0, 1
    while i <= #title do
        local byte    = title:byte(i)
        local charLen = byte >= 240 and 4 or byte >= 224 and 3 or byte >= 192 and 2 or 1
        count = count + 1
        if count > TITLE_MAX_LEN then
            return title:sub(1, i - 1) .. "…"
        end
        i = i + charLen
    end
    return title
end

-- ---------------------------------------------------------------------------
-- Visibility helpers — each element can be toggled independently.
-- Keys stored in G_reader_settings under pfx .. "currently_show_<elem>".
-- Default: all visible (nilOrTrue).
-- ---------------------------------------------------------------------------
local function _showElem(pfx, key)
    return G_reader_settings:nilOrTrue(pfx .. "currently_show_" .. key)
end
local function _toggleElem(pfx, key)
    local cur = G_reader_settings:nilOrTrue(pfx .. "currently_show_" .. key)
    G_reader_settings:saveSetting(pfx .. "currently_show_" .. key, not cur)
end

-- ---------------------------------------------------------------------------
-- Element order — defines both the default render order and the labels shown
-- in the Arrange Items SortWidget.
-- Keys match the `show` booleans and the keys used in build().
-- ---------------------------------------------------------------------------
local ELEM_ORDER_KEY = "currently_elem_order"

-- Canonical default order (also used as the full element pool for labels).
local _ELEM_DEFAULT_ORDER = {
    "title", "author", "progress", "percent",
    "book_days", "book_time", "book_remaining",
}

-- Human-readable labels for the SortWidget — keyed by element id.
-- Defined once at module load so getMenuItems() has no string-construction cost.
local _ELEM_LABELS = {
    title          = _("Title"),
    author         = _("Author"),
    progress       = _("Progress bar"),
    percent        = _("Percentage read"),
    book_days      = _("Days of reading"),
    book_time      = _("Time read"),
    book_remaining = _("Time remaining"),
}

-- Returns the saved order, falling back to the default.
-- Unknown keys in the saved list are silently dropped; new keys from
-- _ELEM_DEFAULT_ORDER are appended at the tail (forward-compatible).
local function _getElemOrder(pfx)
    local saved = G_reader_settings:readSetting(pfx .. ELEM_ORDER_KEY)
    if type(saved) ~= "table" or #saved == 0 then
        return _ELEM_DEFAULT_ORDER
    end
    local seen, result = {}, {}
    for _, v in ipairs(saved) do
        if _ELEM_LABELS[v] then seen[v] = true; result[#result+1] = v end
    end
    -- Append any new elements not yet in the saved list (forward-compatible).
    for _, v in ipairs(_ELEM_DEFAULT_ORDER) do
        if not seen[v] then result[#result+1] = v end
    end
    return result
end

local M = {}

M.id          = "currently"
M.name        = _("Currently Reading")
M.label       = _("Currently Reading")
M.enabled_key = "currently"
M.default_on  = true

-- ---------------------------------------------------------------------------
-- onBookClosed — call this from the host when the reader is closed so that
-- the prefetched entry for the current book is invalidated. This ensures
-- that M.build() reads fresh progress and stats on the next render.
-- ---------------------------------------------------------------------------
function M.onBookClosed(ctx, fp)
    if ctx and ctx.prefetched and fp then
        ctx.prefetched[fp] = nil
    end
    -- Invalidate the bstats cache for the closed book so that the next render
    -- re-fetches updated days/time/remaining from SQLite (force_fresh path).
    -- We don't know the md5 here, so clear the whole cache — it holds at most
    -- one book's data in practice, so this is O(1).
    _bstats_cache = {}
end

function M.build(w, ctx)
    if not ctx.current_fp then return nil end

    local SH = getSH()
    if not SH then return nil end

    local scale       = Config.getModuleScale("currently", ctx.pfx)
    local thumb_scale = Config.getThumbScale("currently", ctx.pfx)
    local lbl_scale   = Config.getItemLabelScale("currently", ctx.pfx)
    local D           = SH.getDims(scale, thumb_scale)

    -- Scale internal spacing proportionally.
    local cover_gap  = math.max(1, math.floor(_BASE_COVER_GAP  * scale))
    local title_gap  = math.max(1, math.floor(_BASE_TITLE_GAP  * scale))
    local author_gap = math.max(1, math.floor(_BASE_AUTHOR_GAP * scale))
    local bar_h      = math.max(1, math.floor(_BASE_BAR_H      * scale))
    local bar_gap    = math.max(1, math.floor(_BASE_BAR_GAP    * scale))
    local pct_gap    = math.max(1, math.floor(_BASE_PCT_GAP    * scale))
    -- Text sizes apply both module scale and independent text scale.
    local title_fs   = math.max(8, math.floor(_BASE_TITLE_FS   * scale * lbl_scale))
    local author_fs  = math.max(8, math.floor(_BASE_AUTHOR_FS  * scale * lbl_scale))
    local pct_fs     = math.max(8, math.floor(_BASE_PCT_FS     * scale * lbl_scale))
    local stats_fs   = math.max(7, math.floor(_BASE_STATS_FS   * scale * lbl_scale))

    -- Pre-resolve all font faces once rather than calling getFace
    -- repeatedly throughout the function with identical arguments.
    local face_title  = Font:getFace("smallinfofont", title_fs)
    local face_author = Font:getFace("smallinfofont", author_fs)
    local face_pct    = Font:getFace("smallinfofont", pct_fs)
    local face_s      = Font:getFace("smallinfofont", stats_fs)

    -- Read all visibility flags up-front in one pass so the rest of
    -- build() works with plain booleans and avoids repeated G_reader_settings
    -- lookups (each call does a table lookup + string concatenation).
    local pfx = ctx.pfx
    local show = {
        title    = _showElem(pfx, "title"),
        author   = _showElem(pfx, "author"),
        progress = _showElem(pfx, "progress"),
        percent  = _showElem(pfx, "percent"),
        days     = _showElem(pfx, "book_days"),
        time     = _showElem(pfx, "book_time"),
        remain   = _showElem(pfx, "book_remaining"),
    }

    -- When ctx.fresh is set (host signals return from reading) skip the
    -- prefetched cache so that updated progress is read from disk/DB directly.
    local prefetched_entry = (not ctx.fresh)
        and ctx.prefetched
        and ctx.prefetched[ctx.current_fp]
    local bd    = SH.getBookData(ctx.current_fp, prefetched_entry, ctx.db_conn)
    local cover = SH.getBookCover(ctx.current_fp, D.COVER_W, D.COVER_H)
                  or SH.coverPlaceholder(bd.title, D.COVER_W, D.COVER_H)

    -- Text column width: total minus both side PADs, cover width, and cover gap.
    local tw = w - PAD - D.COVER_W - cover_gap - PAD

    local meta = VerticalGroup:new{ align = "left" }

    -- Fetch bstats once, only if at least one stats element is active.
    -- Hoisted out of the per-element loop so the DB is queried at most once
    -- regardless of order or how many stats elements are enabled.
    local bstats
    if show.days or show.time or show.remain then
        local book_md5 = prefetched_entry and prefetched_entry.partial_md5_checksum
        bstats = fetchBookStats(book_md5, ctx.db_conn, ctx.fresh)
    end

    local bar_style = getBarStyle(pfx)

    -- Build element widgets in the user-configured order.
    -- Each branch appends its widget(s) to `meta` only when the element is
    -- visible and has content to show.
    -- Gaps are added *before* each element (except the first) so the last
    -- rendered element never leaves a trailing gap at the bottom.
    local meta_has_content = false

    local function gap_before(size)
        if meta_has_content then
            meta[#meta+1] = VerticalSpan:new{ width = size }
        end
    end

    for _i, elem in ipairs(_getElemOrder(pfx)) do
        if elem == "title" and show.title then
            gap_before(title_gap)
            meta[#meta+1] = TextBoxWidget:new{
                text      = truncateTitle(bd.title) or "?",
                face      = face_title,
                bold      = true,
                width     = tw,
                max_lines = 2,
            }
            meta_has_content = true

        elseif elem == "author" and show.author and bd.authors and bd.authors ~= "" then
            gap_before(author_gap)
            meta[#meta+1] = TextWidget:new{
                text    = bd.authors,
                face    = face_author,
                fgcolor = CLR_TEXT_SUB,
                width   = tw,
            }
            meta_has_content = true

        elseif elem == "progress" and show.progress then
            gap_before(bar_gap)
            if bar_style == "with_pct" then
                -- Inline bar+percentage — "percent" element is ignored when this style is active.
                meta[#meta+1] = buildProgressBarWithPct(tw, bd.percent, bar_h, bar_gap, scale, lbl_scale)
            else
                meta[#meta+1] = SH.progressBar(tw, bd.percent, bar_h)
            end
            meta_has_content = true

        elseif elem == "percent" and show.percent and bar_style ~= "with_pct" then
            gap_before(pct_gap)
            meta[#meta+1] = TextWidget:new{
                text    = string.format(_("%d%% Read"), math.floor((bd.percent or 0) * 100)),
                face    = face_pct,
                bold    = true,
                fgcolor = _CLR_DARK,
                width   = tw,
            }
            meta_has_content = true

        elseif elem == "book_days" and show.days and bstats and bstats.days > 0 then
            gap_before(pct_gap)
            local days_label = bstats.days == 1
                and _("1 day of reading")
                or  string.format(_("%d days of reading"), bstats.days)
            meta[#meta+1] = TextWidget:new{
                text    = days_label,
                face    = face_s,
                fgcolor = CLR_TEXT_SUB,
                width   = tw,
            }
            meta_has_content = true

        elseif elem == "book_time" and show.time and bstats and bstats.total_secs > 0 then
            gap_before(pct_gap)
            meta[#meta+1] = TextWidget:new{
                text    = string.format(_("%s read"), fmtTime(bstats.total_secs)),
                face    = face_s,
                fgcolor = CLR_TEXT_SUB,
                width   = tw,
            }
            meta_has_content = true

        elseif elem == "book_remaining" and show.remain then
            local avg_t = bd.avg_time
            if (not avg_t or avg_t <= 0) and bstats and bstats.avg_time then
                avg_t = bstats.avg_time
            end
            if avg_t and avg_t > 0 and bd.pages and bd.pages > 0 then
                local pages_left = bd.pages * (1 - (bd.percent or 0))
                local secs_left  = math.floor(avg_t * pages_left)
                if secs_left > 0 then
                    gap_before(pct_gap)
                    meta[#meta+1] = TextWidget:new{
                        text    = string.format(_("%s remaining"), fmtTime(secs_left)),
                        face    = face_s,
                        fgcolor = CLR_TEXT_SUB,
                        width   = tw,
                    }
                    meta_has_content = true
                end
            end
        end
    end

    local row = HorizontalGroup:new{
        align = "center",
        FrameContainer:new{
            bordersize    = 0, padding = 0,
            padding_right = cover_gap,
            cover,
        },
        meta,
    }

    -- Outer container: horizontal padding only, no fixed vertical height.
    -- We must NOT pin dimen.h to COVER_H here: the meta column can be taller
    -- than COVER_H when the stats rows (days / time / remaining) are enabled,
    -- and KOReader clips any content that exceeds the widget's declared dimen.
    -- The actual height is determined by getHeight(), which accounts for the
    -- same stat rows so the homescreen allocates enough vertical space.
    local content_h = M.getHeight(ctx) - Config.getScaledLabelH()
    local tappable = InputContainer:new{
        dimen    = Geom:new{ w = w, h = content_h },
        _fp      = ctx.current_fp,
        _open_fn = ctx.open_fn,
        [1] = FrameContainer:new{
            bordersize    = 0,
            padding       = 0,
            padding_left  = PAD,
            padding_right = PAD,
            row,
        },
    }
    tappable.ges_events = {
        TapBook = {
            GestureRange:new{
                ges   = "tap",
                range = function() return tappable.dimen end,
            },
        },
    }
    function tappable:onTapBook()
        if self._open_fn then self._open_fn(self._fp) end
        return true
    end

    return tappable
end

function M.getHeight(_ctx)
    local SH = getSH()
    if not SH then return Config.getScaledLabelH() end
    local pfx       = _ctx and _ctx.pfx
    local scale     = Config.getModuleScale("currently", pfx)
    local lbl_scale = Config.getItemLabelScale("currently", pfx)
    local D         = SH.getDims(scale, Config.getThumbScale("currently", pfx))

    local h = D.COVER_H

    -- Reserve a fixed block for stats rows (days / time / remaining).
    -- Height is always the same regardless of how many rows are active,
    -- so the module size never changes when toggling individual elements.
    -- FIX 3: previously used undefined local variables (show_days, show_time,
    -- show_remain) which were always nil, so the stats height block was never
    -- reserved — causing a layout mismatch with build() and potential re-layout.
    local show_days   = _showElem(pfx, "book_days")
    local show_time   = _showElem(pfx, "book_time")
    local show_remain = _showElem(pfx, "book_remaining")

    -- Count only the stats rows that are actually enabled, so that
    -- getHeight() matches what build() really renders and no blank space
    -- appears below the module when fewer than 3 stat rows are active.
    local active_stats = (show_days and 1 or 0)
                       + (show_time  and 1 or 0)
                       + (show_remain and 1 or 0)
    if active_stats > 0 then
        local stats_line_h = math.max(7, math.floor(_BASE_STATS_FS * scale * lbl_scale))
        local gap          = math.max(1, math.floor(_BASE_PCT_GAP  * scale))
        -- gap before the first stats row + one line per active row
        h = h + gap + stats_line_h * active_stats
    end

    return Config.getScaledLabelH() + h
end


local function _makeScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size."),
        get          = function() return Config.getModuleScalePct("currently", pfx) end,
        set          = function(v) Config.setModuleScale(v, "currently", pfx) end,
        refresh      = ctx_menu.refresh,
    })
end

local function _makeThumbScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func = function() return _lc("Cover size") end,
        separator = true,
        title     = _lc("Cover size"),
        info      = _lc("Scale for the cover thumbnail only.\n100% is the default size."),
        get       = function() return Config.getThumbScalePct("currently", pfx) end,
        set       = function(v) Config.setThumbScale(v, "currently", pfx) end,
        refresh   = ctx_menu.refresh,
    })
end

local function _makeTextScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func = function() return _lc("Text Size") end,
        title     = _lc("Text Size"),
        info      = _lc("Scale for all text elements (title, author, progress, time).\n100% is the default size."),
        get       = function() return Config.getItemLabelScalePct("currently", pfx) end,
        set       = function(v) Config.setItemLabelScale(v, "currently", pfx) end,
        refresh   = ctx_menu.refresh,
    })
end

function M.getMenuItems(ctx_menu)
    local pfx     = ctx_menu.pfx
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._

    local function toggle_item(label, key)
        return {
            text_func    = function() return _lc(label) end,
            checked_func = function() return _showElem(pfx, key) end,
            keep_menu_open = true,
            callback     = function()
                _toggleElem(pfx, key)
                refresh()
            end,
        }
    end

    local _UIManager  = ctx_menu.UIManager
    local InfoMessage = ctx_menu.InfoMessage
    local SortWidget  = ctx_menu.SortWidget

    -- Scale items (no separator between them), then separator before Items submenu.
    local thumb = _makeThumbScaleItem(ctx_menu)
    thumb.separator = true

    -- Items submenu — Arrange Items at the top, then a separator, then
    -- the visibility toggles in alphabetical order.
    local items_submenu = {
        -- Arrange Items — only the active (visible) elements appear in the
        -- SortWidget, mirroring the pattern used in module_reading_stats and
        -- module_collections. Disabled when fewer than 2 elements are active.
        {
            text           = _lc("Arrange Items"),
            keep_menu_open = true,
            separator      = true,
            enabled_func   = function()
                local active = 0
                for _, key in ipairs(_ELEM_DEFAULT_ORDER) do
                    if _showElem(pfx, key) then
                        active = active + 1
                        if active >= 2 then return true end
                    end
                end
                return false
            end,
            callback = function()
                local sort_items = {}
                for _, key in ipairs(_getElemOrder(pfx)) do
                    if _showElem(pfx, key) then
                        sort_items[#sort_items+1] = {
                            text      = _lc(_ELEM_LABELS[key]),
                            orig_item = key,
                        }
                    end
                end
                _UIManager:show(SortWidget:new{
                    title             = _lc("Arrange Items"),
                    item_table        = sort_items,
                    covers_fullscreen = true,
                    callback          = function()
                        -- Save only the active order; inactive elements will be
                        -- appended at the tail by _getElemOrder() when re-enabled.
                        local new_order = {}
                        for _, item in ipairs(sort_items) do
                            new_order[#new_order+1] = item.orig_item
                        end
                        -- Append inactive elements at the tail so they have a
                        -- stable position when toggled back on later.
                        local active_set = {}
                        for _, k in ipairs(new_order) do active_set[k] = true end
                        for _, k in ipairs(_getElemOrder(pfx)) do
                            if not active_set[k] then new_order[#new_order+1] = k end
                        end
                        G_reader_settings:saveSetting(pfx .. ELEM_ORDER_KEY, new_order)
                        refresh()
                    end,
                })
            end,
        },
        -- Visibility toggles — alphabetical order, separated from Arrange Items above.
        toggle_item("Author",          "author"),
        toggle_item("Days of reading", "book_days"),
        {
            text_func      = function() return _lc("Percentage read") end,
            -- Greyed out (not interactive) when the inline bar style is active,
            -- because the percentage is already shown inside the bar row.
            enabled_func   = function() return getBarStyle(pfx) == "simple" end,
            checked_func   = function() return _showElem(pfx, "percent") end,
            keep_menu_open = true,
            callback       = function()
                _toggleElem(pfx, "percent")
                refresh()
            end,
        },
        toggle_item("Progress bar",    "progress"),
        {
            text = _lc("Progress bar style"),
            sub_item_table = {
                {
                    text           = _lc("Simple"),
                    radio          = true,
                    keep_menu_open = true,
                    checked_func   = function() return getBarStyle(pfx) == "simple" end,
                    callback       = function()
                        G_reader_settings:saveSetting(pfx .. BAR_STYLE_KEY, "simple")
                        refresh()
                    end,
                },
                {
                    text           = _lc("With percentage"),
                    radio          = true,
                    keep_menu_open = true,
                    checked_func   = function() return getBarStyle(pfx) == "with_pct" end,
                    callback       = function()
                        G_reader_settings:saveSetting(pfx .. BAR_STYLE_KEY, "with_pct")
                        refresh()
                    end,
                },
            },
        },
        toggle_item("Time read",       "book_time"),
        toggle_item("Time remaining",  "book_remaining"),
        toggle_item("Title",           "title"),
    }

    return {
        _makeScaleItem(ctx_menu),
        _makeTextScaleItem(ctx_menu),
        thumb,
        {
            text           = _lc("Items"),
            sub_item_table = items_submenu,
        },
    }
end

return M
