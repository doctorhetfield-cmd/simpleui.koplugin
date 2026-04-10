-- module_currently.lua — Simple UI
-- Currently Reading module: cover + title + author + progress bar + percentage.

-- External dependencies
local Device  = require("device")
local Screen  = Device.screen
local _       = require("gettext")
local logger  = require("logger")

local Blitbuffer      = require("ffi/blitbuffer")
local Font            = require("ui/font")
local CenterContainer = require("ui/widget/container/centercontainer")
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

-- Internal dependencies
local Config       = require("sui_config")
local UI           = require("sui_core")
local PAD          = UI.PAD
local LABEL_H      = UI.LABEL_H
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

-- Lazy-loaded shared book helpers (cover, progress bar, book data).
local _SH = nil
local function getSH()
    if not _SH then
        local ok, m = pcall(require, "desktop_modules/module_books_shared")
        if ok and m then _SH = m
        else logger.warn("simpleui: module_currently: cannot load module_books_shared: " .. tostring(m)) end
    end
    return _SH
end

-- Colours
local _CLR_DARK   = Blitbuffer.COLOR_BLACK
local _CLR_BAR_BG = Blitbuffer.gray(0.15)
local _CLR_BAR_FG = Blitbuffer.gray(0.75)

-- Vertical gaps between elements (base values at 100% scale; scaled in build()).
local _BASE_COVER_GAP  = Screen:scaleBySize(16)  -- between cover and text column
local _BASE_TITLE_GAP  = Screen:scaleBySize(4)   -- before title
local _BASE_AUTHOR_GAP = Screen:scaleBySize(6)   -- before author
-- Vertical gaps around the progress bar.
-- The bar (LineWidget) has no internal padding — it starts and ends at exact pixels.
-- TextWidget includes ascender/descender space inside its reported height, which
-- the eye reads as part of the gap. To look balanced:
--   before the bar: slightly smaller because the author text's descender space
--                   adds ~2px of visual gap "for free" from inside the widget.
--   after the bar:  larger to compensate for the ascender space of the next text
--                   being consumed from the gap, making it look narrower.
local _BASE_BAR_GAP_BEFORE = Screen:scaleBySize(6)   -- gap above the progress bar
local _BASE_BAR_GAP_AFTER  = Screen:scaleBySize(10)  -- gap below the progress bar
local _BASE_PCT_GAP    = Screen:scaleBySize(3)   -- before percent / stats rows

-- Progress bar dimensions
local _BASE_BAR_H       = Screen:scaleBySize(7)   -- bar height (matches module_reading_goals)
local _BASE_BAR_PCT_GAP = Screen:scaleBySize(6)   -- horizontal gap between bar and inline pct label
local _BASE_STATS_SEP_W = Screen:scaleBySize(8)   -- horizontal gap between inline stats items
local _BASE_PCT_W       = Screen:scaleBySize(32)  -- width reserved for inline pct label (e.g. "100%")

-- Font sizes (base values at 100% scale; scaled by both scale and lbl_scale in build()).
local _BASE_TITLE_FS     = Screen:scaleBySize(11)
local _BASE_AUTHOR_FS    = Screen:scaleBySize(10)
local _BASE_PCT_FS       = Screen:scaleBySize(8)
local _BASE_STATS_FS     = Screen:scaleBySize(8)
local _BASE_INLINEPCT_FS = Screen:scaleBySize(11)  -- pct label inside the bar (with_pct style)

-- Setting key for progress bar style: "simple" (default) or "with_pct"
local BAR_STYLE_KEY = "currently_bar_style"

local function getBarStyle(pfx)
    return G_reader_settings:readSetting(pfx .. BAR_STYLE_KEY) or "with_pct"
end

-- Setting key for stats layout: "default" (one line per stat) or "compact" (single row with · separator + ETA)
local STATS_STYLE_KEY = "currently_stats_style"

local function getStatsStyle(pfx)
    return G_reader_settings:readSetting(pfx .. STATS_STYLE_KEY) or "default"
end

-- Maximum title length in UTF-8 characters before truncation.
local TITLE_MAX_LEN = 60

-- Caps per-page duration at 120 s when computing avg reading time,
-- matching KOReader's STATISTICS_SQL_BOOK_CAPPED_TOTALS_QUERY.
local _MAX_SEC = 120

-- Per-book stats cache (md5 → { days, total_secs, avg_time }).
-- Cleared by invalidateCache(), called from main.lua:onCloseDocument.
local _bstats_cache = {}


-- Builds a progress bar with an inline percentage label: [▓▓▓░░░░] XX%
-- Spacing below the bar is handled by gap_before() on the next element,
-- consistent with how every other element in the layout works.
local function buildProgressBarWithPct(w, pct, bar_h, scale, lbl_scale, face_inline)
    local PCT_W   = math.max(16, math.floor(_BASE_PCT_W       * scale * lbl_scale))
    local GAP     = math.max(2,  math.floor(_BASE_BAR_PCT_GAP * scale))
    local bar_w   = math.max(10, w - GAP - PCT_W)
    local fw      = math.max(0, math.floor(bar_w * math.min(pct, 1.0)))
    local pct_str = string.format("%d%%", math.floor((pct or 0) * 100))
    -- face_inline is pre-resolved by build(); fallback for direct calls.
    local _face   = face_inline or Font:getFace("smallinfofont", math.max(7, math.floor(_BASE_INLINEPCT_FS * scale * lbl_scale)))

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

    return HorizontalGroup:new{
        align = "center",
        bar,
        HorizontalSpan:new{ width = GAP },
        TextWidget:new{
            text    = pct_str,
            face    = _face,
            bold    = true,
            fgcolor = _CLR_DARK,
            width   = PCT_W,
        },
    }
end


-- Formats a duration in seconds as "Xh Ym", "Xh", or "Ym".
local function fmtTime(secs)
    secs = math.floor(secs or 0)
    if secs <= 0 then return "0m" end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 and m > 0 then return string.format("%dh %dm", h, m)
    elseif h > 0        then return string.format("%dh", h)
    else                     return string.format("%dm", m) end
end


-- Truncates a UTF-8 title to TITLE_MAX_LEN characters, appending "…" if needed.
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


-- Fetches reading stats for a book from SQLite (days read, total time, avg time per page).
-- Results are cached by md5 for the duration of the homescreen session.
-- Cache is cleared by invalidateCache() (called from onCloseDocument) before
-- each post-reading rebuild, so data is always fresh when it matters.
-- Uses shared_conn when available to avoid opening a second DB connection.
-- ctx is optional: when provided and a fatal DB error occurs on the shared_conn,
-- ctx.db_conn_fatal is set to true so the homescreen can discard the connection.
local function fetchBookStats(md5, shared_conn, ctx)
    if not md5 then return nil end

    if _bstats_cache[md5] then
        return _bstats_cache[md5]
    end

    local conn     = shared_conn or Config.openStatsDB()
    local own_conn = not shared_conn
    if not conn then return nil end

    local result = nil
    local ok, err = pcall(function()
        -- ps_agg accumulates per-page totals; the outer SELECT aggregates them.
        -- sum(page_dur) replaces a correlated subquery that caused a second
        -- full scan of page_stat on every call.
        -- Relies on idx_simpleui_book_md5 / idx_simpleui_pagestat_book indexes
        -- created by openStatsDB() for O(log n) lookup instead of full-table scan.
        local row = conn:exec(string.format([[
            WITH b AS (
                SELECT id FROM book WHERE md5 = %q LIMIT 1
            ),
            ps_agg AS (
                SELECT ps.page,
                       sum(ps.duration)   AS page_dur,
                       min(ps.start_time) AS first_start
                FROM page_stat ps
                WHERE ps.id_book = (SELECT id FROM b)
                GROUP BY ps.page
            )
            SELECT
                count(DISTINCT date(first_start, 'unixepoch', 'localtime')),
                sum(page_dur),
                count(*),
                sum(min(page_dur, %d))
            FROM ps_agg;
        ]], md5, _MAX_SEC))

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
        -- Signal to the homescreen that the shared connection is unusable so it
        -- can be discarded and reopened on the next render.
        if shared_conn and ctx and Config.isFatalDbError(err) then
            ctx.db_conn_fatal = true
        end
    end
    if own_conn then pcall(function() conn:close() end) end
    if result then _bstats_cache[md5] = result end
    return result
end


-- Returns true if the element with the given key is visible (default on).
local function _showElem(pfx, key)
    return G_reader_settings:nilOrTrue(pfx .. "currently_show_" .. key)
end

-- Toggles the visibility of an element.
local function _toggleElem(pfx, key)
    local cur = G_reader_settings:nilOrTrue(pfx .. "currently_show_" .. key)
    G_reader_settings:saveSetting(pfx .. "currently_show_" .. key, not cur)
end


-- Element order and labels used by build() and the Arrange Items SortWidget.
local ELEM_ORDER_KEY = "currently_elem_order"

local _ELEM_DEFAULT_ORDER = {
    "title", "author", "progress", "percent",
    "book_days", "book_time", "book_remaining",
}

local _ELEM_LABELS = {
    title          = _("Title"),
    author         = _("Author"),
    progress       = _("Progress bar"),
    percent        = _("Percentage read"),
    book_days      = _("Days of reading"),
    book_time      = _("Time read"),
    book_remaining = _("Time remaining"),
}

-- Returns the user-saved element order, falling back to the default.
-- Unknown keys are dropped; new keys are appended at the tail.
local function _getElemOrder(pfx)
    local saved = G_reader_settings:readSetting(pfx .. ELEM_ORDER_KEY)
    if type(saved) ~= "table" or #saved == 0 then
        return _ELEM_DEFAULT_ORDER
    end
    local seen, result = {}, {}
    for _, v in ipairs(saved) do
        if _ELEM_LABELS[v] then seen[v] = true; result[#result+1] = v end
    end
    for _, v in ipairs(_ELEM_DEFAULT_ORDER) do
        if not seen[v] then result[#result+1] = v end
    end
    return result
end


-- Module API
local M = {}

M.id          = "currently"
M.name        = _("Currently Reading")
M.label       = _("Currently Reading")
M.enabled_key = "currently"
M.default_on  = true


-- ---------------------------------------------------------------------------
-- _computeContentH — shared height calculation used by build() and getHeight()
-- ---------------------------------------------------------------------------
-- Returns the pixel height of the text column (right side), taking the cover
-- height as a minimum.  All parameters mirror the local vars already resolved
-- in build(); getHeight() reconstructs them independently.
--
-- params fields:
--   scale, lbl_scale  — module and text scale factors
--   D                 — dims table from SH.getDims()
--   show              — visibility flags table (title/author/progress/percent/days/time/remain)
--   stats_style       — "default" or "compact"
--   bstats            — result of fetchBookStats, or nil (conservative fallback)
--   bd                — book-data table; only .authors, .avg_time, .pages, .percent used
local function _computeContentH(params)
    local scale       = params.scale
    local lbl_scale   = params.lbl_scale
    local D           = params.D
    local show        = params.show
    local stats_style = params.stats_style
    local bstats      = params.bstats
    local bd          = params.bd or {}
    local bar_style   = params.bar_style or getBarStyle(params.pfx)

    -- Scaled dimensions (same formulas as build()).
    local title_line_h  = math.max(8, math.floor(_BASE_TITLE_FS       * scale * lbl_scale))
    local author_line_h = math.max(8, math.floor(_BASE_AUTHOR_FS      * scale * lbl_scale))
    local pct_line_h    = math.max(8, math.floor(_BASE_PCT_FS         * scale * lbl_scale))
    local stats_line_h  = math.max(7, math.floor(_BASE_STATS_FS       * scale * lbl_scale))
    local bar_h         = math.max(1, math.floor(_BASE_BAR_H          * scale))
    local title_gap     = math.max(1, math.floor(_BASE_TITLE_GAP      * scale))
    local author_gap    = math.max(1, math.floor(_BASE_AUTHOR_GAP     * scale))
    local bar_gap_b     = math.max(1, math.floor(_BASE_BAR_GAP_BEFORE * scale))
    local bar_gap_a     = math.max(1, math.floor(_BASE_BAR_GAP_AFTER  * scale))
    local pct_gap       = math.max(1, math.floor(_BASE_PCT_GAP        * scale))

    -- Accumulate height element by element, mirroring build()'s gap_before logic.
    -- Each entry is { gap, line_h } in render order.
    local elems = {}

    if show.title then
        elems[#elems+1] = { title_gap, title_line_h }
    end
    if show.author and bd.authors and bd.authors ~= "" then
        elems[#elems+1] = { author_gap, author_line_h }
    end
    if show.progress then
        -- bar uses bar_gap_before before it and bar_gap_after after it.
        elems[#elems+1] = { bar_gap_b, bar_h + bar_gap_a }
    end
    if show.percent and bar_style ~= "with_pct" then
        elems[#elems+1] = { pct_gap, pct_line_h }
    end

    -- Stats: when bstats is nil (getHeight conservative path) assume all
    -- active stats have data.  When bstats is real (build path) check actuals.
    local function statsHasData(key)
        if bstats == nil then return show[key] end
        if key == "days"   then return show.days   and bstats.days and bstats.days > 0 end
        if key == "time"   then return show.time   and bstats.total_secs and bstats.total_secs > 0 end
        if key == "remain" then
            local avg_t = (bstats.avg_time and bstats.avg_time > 0) and bstats.avg_time
                          or bd.avg_time
            return show.remain and avg_t and avg_t > 0
                   and bd.pages and bd.pages > 0
        end
        return false
    end

    if stats_style == "compact" then
        if statsHasData("days") or statsHasData("time") or statsHasData("remain") then
            elems[#elems+1] = { pct_gap, stats_line_h }
        end
    else
        if statsHasData("days")   then elems[#elems+1] = { pct_gap, stats_line_h } end
        if statsHasData("time")   then elems[#elems+1] = { pct_gap, stats_line_h } end
        if statsHasData("remain") then elems[#elems+1] = { pct_gap, stats_line_h } end
    end

    -- Sum up: first element has no leading gap (mirrors gap_before guard).
    local h = 0
    for i, e in ipairs(elems) do
        if i > 1 then h = h + e[1] end  -- gap (skipped for first element)
        h = h + e[2]                     -- line height
    end

    return math.max(D.COVER_H, h)
end


-- Clears the stats cache (called from main.lua:onCloseDocument before rebuild).
function M.invalidateCache()
    _bstats_cache = {}
end


-- Builds the module widget: cover on the left, text column on the right.
-- Elements in the text column are rendered in user-configured order.
function M.build(w, ctx)
    Config.applyLabelToggle(M, _("Currently Reading"))
    if not ctx.current_fp then return nil end

    local SH = getSH()
    if not SH then return nil end

    local scale       = Config.getModuleScale("currently", ctx.pfx)
    local thumb_scale = Config.getThumbScale("currently", ctx.pfx)
    local lbl_scale   = Config.getItemLabelScale("currently", ctx.pfx)
    local D           = SH.getDims(scale, thumb_scale)

    -- Scale gaps (layout scale only).
    local cover_gap      = math.max(1, math.floor(_BASE_COVER_GAP      * scale))
    local title_gap      = math.max(1, math.floor(_BASE_TITLE_GAP      * scale))
    local author_gap     = math.max(1, math.floor(_BASE_AUTHOR_GAP     * scale))
    local bar_gap_before = math.max(1, math.floor(_BASE_BAR_GAP_BEFORE * scale))
    local bar_gap_after  = math.max(1, math.floor(_BASE_BAR_GAP_AFTER  * scale))
    local pct_gap        = math.max(1, math.floor(_BASE_PCT_GAP        * scale))
    local bar_h          = math.max(1, math.floor(_BASE_BAR_H          * scale))

    -- Scale font sizes (layout scale × text scale).
    local title_fs   = math.max(8, math.floor(_BASE_TITLE_FS   * scale * lbl_scale))
    local author_fs  = math.max(8, math.floor(_BASE_AUTHOR_FS  * scale * lbl_scale))
    local pct_fs     = math.max(8, math.floor(_BASE_PCT_FS     * scale * lbl_scale))
    local stats_fs   = math.max(7, math.floor(_BASE_STATS_FS   * scale * lbl_scale))

    -- Resolve font faces once so they are not re-created per element.
    local face_title  = Font:getFace("smallinfofont", title_fs)
    local face_author = Font:getFace("smallinfofont", author_fs)
    local face_pct    = Font:getFace("smallinfofont", pct_fs)
    local face_s      = Font:getFace("smallinfofont", stats_fs)

    -- Read all visibility flags up-front to avoid repeated settings lookups.
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

    -- Use prefetched book data. After onCloseDocument, _cached_books_state is
    -- cleared and prefetchBooks() re-reads the sidecar, so this is always fresh.
    local prefetched_entry = ctx.prefetched and ctx.prefetched[ctx.current_fp]
    local bd    = SH.getBookData(ctx.current_fp, prefetched_entry)
    local cover = SH.getBookCover(ctx.current_fp, D.COVER_W, D.COVER_H, nil, 0.10)
                  or SH.coverPlaceholder(bd.title, D.COVER_W, D.COVER_H)

    -- Text column width: full width minus both PADs, cover, and cover gap.
    local tw = w - PAD - D.COVER_W - cover_gap - PAD

    local meta = VerticalGroup:new{ align = "left" }

    -- Fetch stats once if any stats element is active.
    local bstats
    if show.days or show.time or show.remain then
        local book_md5 = prefetched_entry and prefetched_entry.partial_md5_checksum
        bstats = fetchBookStats(book_md5, ctx.db_conn, ctx)
    end

    local bar_style   = getBarStyle(pfx)
    local stats_style = getStatsStyle(pfx)

    -- Pre-resolve the inline-pct font face once for buildProgressBarWithPct.
    local face_inlinepct = Font:getFace("smallinfofont",
        math.max(7, math.floor(_BASE_INLINEPCT_FS * scale * lbl_scale)))

    -- Capture element order once; reused by both the main loop and compact inner loop.
    local elem_order = _getElemOrder(pfx)

    -- Flag to ensure the compact stats row is rendered only once,
    -- at the position of the first visible stats element in the Arrange order.
    local _compact_stats_rendered = false

    -- Adds a vertical gap before the next element, but not before the first one.
    -- _next_gap overrides the default size for exactly one call (used after the
    -- progress bar, where bar_gap_after compensates for font metric asymmetry).
    local meta_has_content = false
    local _next_gap        = nil
    local function gap_before(size)
        if meta_has_content then
            meta[#meta+1] = VerticalSpan:new{ width = _next_gap or size }
        end
        _next_gap = nil
    end

    -- Append each visible element to meta in user-configured order.
    for _i, elem in ipairs(elem_order) do
        if elem == "title" and show.title then
            gap_before(title_gap)
            meta[#meta+1] = TextWidget:new{
                text            = bd.title or "?",
                face            = face_title,
                bold            = true,
                width           = tw,
                max_width       = tw,
                truncation_char = "â¦",  -- "…" UTF-8
            }
            meta_has_content = true

        elseif elem == "author" and show.author and bd.authors and bd.authors ~= "" then
            gap_before(author_gap)
            meta[#meta+1] = TextWidget:new{
                text            = bd.authors,
                face            = face_author,
                fgcolor         = CLR_TEXT_SUB,
                width           = tw,
                max_width       = tw,
                truncation_char = "â¦",  -- "…" UTF-8
            }
            meta_has_content = true

        elseif elem == "progress" and show.progress then
            gap_before(bar_gap_before)
            if bar_style == "with_pct" then
                meta[#meta+1] = buildProgressBarWithPct(tw, bd.percent, bar_h, scale, lbl_scale, face_inlinepct)
            else
                meta[#meta+1] = SH.progressBar(tw, bd.percent, bar_h)
            end
            meta_has_content = true
            _next_gap = bar_gap_after  -- next element uses the larger post-bar gap

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

        elseif elem == "book_days" and show.days and bstats and bstats.days > 0
               and stats_style == "default" then
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

        elseif elem == "book_time" and show.time and bstats and bstats.total_secs > 0
               and stats_style == "default" then
            gap_before(pct_gap)
            meta[#meta+1] = TextWidget:new{
                text    = string.format(_("%s read"), fmtTime(bstats.total_secs)),
                face    = face_s,
                fgcolor = CLR_TEXT_SUB,
                width   = tw,
            }
            meta_has_content = true

        elseif elem == "book_remaining" and show.remain
               and stats_style == "default" then
            -- Prefer the capped avg_time from fetchBookStats to avoid over-estimating
            -- remaining time when pages had long idle pauses.
            local avg_t = (bstats and bstats.avg_time and bstats.avg_time > 0)
                          and bstats.avg_time or bd.avg_time
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

        elseif (elem == "book_days" or elem == "book_time" or elem == "book_remaining")
               and stats_style == "compact" then
            -- Compact mode: single row following the Arrange Items order.
            -- Fires on the first visible stats element encountered; the others are
            -- consumed here so they don't produce a second row when the loop reaches them.
            if not _compact_stats_rendered then
                _compact_stats_rendered = true

                -- Compute secs_left once (shared by "remain" and ETA).
                local secs_left
                local avg_t = (bstats and bstats.avg_time and bstats.avg_time > 0)
                              and bstats.avg_time or bd.avg_time
                if avg_t and avg_t > 0 and bd.pages and bd.pages > 0 then
                    local pages_left = bd.pages * (1 - (bd.percent or 0))
                    local sl = math.floor(avg_t * pages_left)
                    if sl > 0 then secs_left = sl end
                end

                -- Build parts in Arrange Items order, walking the full element order.
                local parts = {}
                for _i, e in ipairs(elem_order) do
                    if e == "book_time" and show.time and bstats and bstats.total_secs > 0 then
                        parts[#parts+1] = string.format(_("%s read"), fmtTime(bstats.total_secs))
                    elseif e == "book_remaining" and show.remain and secs_left then
                        parts[#parts+1] = string.format(_("%s left"), fmtTime(secs_left))
                    elseif e == "book_days" and show.days and bstats and bstats.days > 0 then
                        parts[#parts+1] = bstats.days == 1
                            and _("1 day of reading")
                            or  string.format(_("%d days of reading"), bstats.days)
                    end
                end

                if #parts > 0 then
                    gap_before(pct_gap)
                    local stats_row = HorizontalGroup:new{ align = "center" }
                    for i, part in ipairs(parts) do
                        if i > 1 then
                            stats_row[#stats_row+1] = TextWidget:new{
                                text    = " · ",
                                face    = face_s,
                                fgcolor = CLR_TEXT_SUB,
                            }
                        end
                        stats_row[#stats_row+1] = TextWidget:new{
                            text    = part,
                            face    = face_s,
                            fgcolor = CLR_TEXT_SUB,
                        }
                    end
                    meta[#meta+1] = stats_row
                    meta_has_content = true
                end
            end
        end
    end

    -- Measure the real height of the text column by asking the VerticalGroup
    -- itself — this is the only reliable way since TextWidget line heights
    -- depend on the font metrics, not just the font size number.
    local meta_h = meta:getSize().h
    local content_h = math.max(D.COVER_H, meta_h)

    -- Layout: cover on left, text column on right.
    -- The cover is wrapped in a CenterContainer sized to content_h so it
    -- stays vertically centred when the text column is taller than the cover.
    local cover_centered = CenterContainer:new{
        dimen = Geom:new{ w = D.COVER_W + cover_gap, h = content_h },
        FrameContainer:new{
            bordersize    = 0, padding = 0,
            padding_right = cover_gap,
            cover,
        },
    }

    local meta_centered = CenterContainer:new{
        dimen = Geom:new{ w = tw, h = content_h },
        meta,
    }

    local row = HorizontalGroup:new{
        align = "top",
        cover_centered,
        meta_centered,
    }
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

    -- Keyboard focus: overlay a black rectangular border on the tappable when
    -- this book is the currently selected keyboard-navigation item.
    if ctx.kb_currently_focused then
        local bw = Screen:scaleBySize(3)
        local tw = w
        local th = content_h
        return OverlapGroup:new{
            dimen = Geom:new{ w = tw, h = th },
            tappable,
            LineWidget:new{ dimen = Geom:new{ w = tw, h = bw },    background = Blitbuffer.COLOR_BLACK },
            LineWidget:new{ dimen = Geom:new{ w = tw, h = bw },    background = Blitbuffer.COLOR_BLACK, overlap_offset = {0, th - bw} },
            LineWidget:new{ dimen = Geom:new{ w = bw, h = th },    background = Blitbuffer.COLOR_BLACK },
            LineWidget:new{ dimen = Geom:new{ w = bw, h = th },    background = Blitbuffer.COLOR_BLACK, overlap_offset = {tw - bw, 0} },
        }
    end

    return tappable
end


-- Returns the total pixel height of the module including the section label.
-- Measures real font line heights via Font:getFace() so the estimate matches
-- what build() actually renders.  This prevents the homescreen from
-- under-allocating space and causing overlap with the module below.
function M.getHeight(_ctx)
    local SH = getSH()
    if not SH then return Config.getScaledLabelH() end
    local pfx         = _ctx and _ctx.pfx
    local scale       = Config.getModuleScale("currently", pfx)
    local lbl_scale   = Config.getItemLabelScale("currently", pfx)
    local D           = SH.getDims(scale, Config.getThumbScale("currently", pfx))
    local stats_style = getStatsStyle(pfx)
    local bar_style   = getBarStyle(pfx)

    local show = {
        title    = _showElem(pfx, "title"),
        author   = _showElem(pfx, "author"),
        progress = _showElem(pfx, "progress"),
        percent  = _showElem(pfx, "percent"),
        days     = _showElem(pfx, "book_days"),
        time     = _showElem(pfx, "book_time"),
        remain   = _showElem(pfx, "book_remaining"),
    }

    -- Measure real line heights using the same font faces as build().
    local title_fs  = math.max(8, math.floor(_BASE_TITLE_FS  * scale * lbl_scale))
    local author_fs = math.max(8, math.floor(_BASE_AUTHOR_FS * scale * lbl_scale))
    local pct_fs    = math.max(8, math.floor(_BASE_PCT_FS    * scale * lbl_scale))
    local stats_fs  = math.max(7, math.floor(_BASE_STATS_FS  * scale * lbl_scale))
    local bar_h     = math.max(1, math.floor(_BASE_BAR_H          * scale))
    local bar_gap_b = math.max(1, math.floor(_BASE_BAR_GAP_BEFORE * scale))
    local bar_gap_a = math.max(1, math.floor(_BASE_BAR_GAP_AFTER  * scale))
    local title_gap = math.max(1, math.floor(_BASE_TITLE_GAP      * scale))
    local author_gap= math.max(1, math.floor(_BASE_AUTHOR_GAP     * scale))
    local pct_gap   = math.max(1, math.floor(_BASE_PCT_GAP        * scale))

    -- Ask the font engine for the real line height (includes ascender+descender).
    local function faceH(fs)
        local ok, face = pcall(Font.getFace, Font, "smallinfofont", fs)
        if ok and face and face.size and face.size.height then
            return face.size.height
        end
        -- fallback: font size * 1.8 approximates typical line height
        return math.ceil(fs * 1.8)
    end

    local title_lh  = faceH(title_fs)
    local author_lh = faceH(author_fs)
    local pct_lh    = faceH(pct_fs)
    local stats_lh  = faceH(stats_fs)

    -- Build the same element list as _computeContentH but with real line heights.
    local elems = {}
    if show.title then
        elems[#elems+1] = { title_gap, title_lh }
    end
    if show.author then
        elems[#elems+1] = { author_gap, author_lh }
    end
    if show.progress then
        elems[#elems+1] = { bar_gap_b, bar_h + bar_gap_a }
    end
    if show.percent and bar_style ~= "with_pct" then
        elems[#elems+1] = { pct_gap, pct_lh }
    end
    -- Stats: conservative — assume all active stats have data.
    local n_stats = (show.days and 1 or 0) + (show.time and 1 or 0) + (show.remain and 1 or 0)
    if n_stats > 0 then
        local lines = stats_style == "compact" and 1 or n_stats
        for _ = 1, lines do
            elems[#elems+1] = { pct_gap, stats_lh }
        end
    end

    local text_h = 0
    for i, e in ipairs(elems) do
        if i > 1 then text_h = text_h + e[1] end
        text_h = text_h + e[2]
    end

    return Config.getScaledLabelH() + math.max(D.COVER_H, text_h)
end


-- Settings menu helpers (scale, text size, cover size).
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


-- Returns the settings menu items for this module.
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

    local thumb = _makeThumbScaleItem(ctx_menu)
    thumb.separator = true

    local items_submenu = {
        -- Arrange Items: drag-to-reorder the visible elements. Disabled when fewer than 2 are active.
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
                        local new_order = {}
                        for _, item in ipairs(sort_items) do
                            new_order[#new_order+1] = item.orig_item
                        end
                        -- Append inactive elements at the tail so their position is stable.
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
        -- Visibility toggles (alphabetical order).
        toggle_item("Author",          "author"),
        toggle_item("Days of reading", "book_days"),
        {
            text_func      = function() return _lc("Percentage read") end,
            -- Greyed out when with_pct bar style is active (percentage is already in the bar).
            enabled_func   = function() return getBarStyle(pfx) == "simple" end,
            checked_func   = function() return _showElem(pfx, "percent") end,
            keep_menu_open = true,
            callback       = function()
                _toggleElem(pfx, "percent")
                refresh()
            end,
        },
        toggle_item("Progress bar", "progress"),
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
        toggle_item("Time read",      "book_time"),
        toggle_item("Time remaining", "book_remaining"),
        toggle_item("Title",          "title"),
        {
            text = _lc("Stats layout"),
            sub_item_table = {
                {
                    text           = _lc("Default"),
                    radio          = true,
                    keep_menu_open = true,
                    checked_func   = function() return getStatsStyle(pfx) == "default" end,
                    callback       = function()
                        G_reader_settings:saveSetting(pfx .. STATS_STYLE_KEY, "default")
                        refresh()
                    end,
                },
                {
                    text           = _lc("Compact"),
                    radio          = true,
                    keep_menu_open = true,
                    checked_func   = function() return getStatsStyle(pfx) == "compact" end,
                    callback       = function()
                        G_reader_settings:saveSetting(pfx .. STATS_STYLE_KEY, "compact")
                        refresh()
                    end,
                },
            },
        },
    }

    return {
        _makeScaleItem(ctx_menu),
        _makeTextScaleItem(ctx_menu),
        thumb,
        Config.makeLabelToggleItem("currently", _("Currently Reading"), refresh, _lc),
        {
            text           = _lc("Items"),
            sub_item_table = items_submenu,
        },
    }
end

return M
