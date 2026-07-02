-- module_currently.lua — Simple UI
-- Currently Reading module: cover + title + author + progress bar + percentage.

-- External dependencies
local Device  = require("device")
local Screen  = Device.screen
local _ = require("sui_i18n").translate
local N_ = require("sui_i18n").ngettext
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
local Size            = require("ui/size")

-- Internal dependencies
local Config       = require("sui_config")
local UI           = require("sui_core")
local SUISettings  = require("sui_store")
local SUIStyle     = require("sui_style")
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
local _BASE_BAR_H       = Screen:scaleBySize(8)   -- bar height (matches module_reading_goals)
local _BASE_BAR_PCT_GAP = Screen:scaleBySize(6)   -- horizontal gap between bar and inline pct label
local _BASE_STATS_SEP_W = Screen:scaleBySize(8)   -- horizontal gap between inline stats items
local _BASE_PCT_W       = Screen:scaleBySize(32)  -- width reserved for inline pct label (e.g. "100%")

-- Font sizes — derived from the central SUIStyle typographic scale.
-- Modules that have their own user-controlled scale multiply it on top.
local _BASE_TITLE_FS     = SUIStyle.FS_TITLE     -- 22: title text
local _BASE_AUTHOR_FS    = SUIStyle.FS_SUBTITLE   -- 20: author text
local _BASE_PCT_FS       = SUIStyle.FS_DETAIL     -- 15: pct text
local _BASE_STATS_FS     = SUIStyle.FS_DETAIL     -- 15: stats text
local _BASE_INLINEPCT_FS = SUIStyle.FS_DETAIL     -- 15: pct label inside the bar

-- Setting key for progress bar style: "simple" (default) or "with_pct"
local BAR_STYLE_KEY = "currently_bar_style"

local function getBarStyle(pfx)
    return SUISettings:readSetting(pfx .. BAR_STYLE_KEY) or "with_pct"
end

-- Setting key for stats layout: "default" (one line per stat) or "compact" (single row with · separator + ETA)
local STATS_STYLE_KEY = "currently_stats_style"

local function getStatsStyle(pfx)
    return SUISettings:readSetting(pfx .. STATS_STYLE_KEY) or "default"
end

local COVER_GAP_KEY = "currently_cover_gap"

local function getCoverGapPct(pfx)
    local v = SUISettings:readSetting(pfx .. COVER_GAP_KEY)
    local n = tonumber(v)
    return n and math.max(0, math.min(300, math.floor(n))) or 100
end

-- Caps per-page duration at 120 s when computing avg reading time,
-- matching KOReader's STATISTICS_SQL_BOOK_CAPPED_TOTALS_QUERY.
local _MAX_SEC = 120

-- Per-book stats cache (md5 → { days, total_secs, avg_time }).
-- Cleared by invalidateCache(), called from main.lua:onCloseDocument.
local _bstats_cache = {}


-- Builds a progress bar with an inline percentage label: [▓▓▓░░░░] XX%
-- Spacing below the bar is handled by gap_before() on the next element,
-- consistent with how every other element in the layout works.
local function buildProgressBarWithPct(w, pct, bar_h, scale, lbl_scale, face_inline, fg_color)
    local PCT_W   = math.max(16, math.floor(_BASE_PCT_W       * scale * lbl_scale))
    local GAP     = math.max(2,  math.floor(_BASE_BAR_PCT_GAP * scale))
    local bar_w   = math.max(10, w - GAP - PCT_W)
    local pct_str = string.format("%.0f%%", (pct or 0) * 100)
    -- face_inline is pre-resolved by build(); fallback for direct calls.
    local _face   = face_inline or Font:getFace(SUIStyle.FACE_REGULAR, math.max(7, math.floor(_BASE_INLINEPCT_FS * scale * lbl_scale)))
    local _fg     = fg_color or _CLR_DARK

    local bar = UI.progressBar(bar_w, pct, bar_h)

    return HorizontalGroup:new{
        align = "center",
        bar,
        HorizontalSpan:new{ width = GAP },
        UI.makeColoredText{
            text    = pct_str,
            face    = _face,
            bold    = true,
            fgcolor = _fg,
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


-- Fetches reading stats for a book from SQLite (days read, total time, avg time per page).
-- Results are cached by md5 for the duration of the homescreen session.
-- Cache is cleared by invalidateCache() (called from onCloseDocument) before
-- each post-reading rebuild, so data is always fresh when it matters.
-- Uses shared_conn when available to avoid opening a second DB connection.
-- ctx is optional: when provided and a fatal DB error occurs on the shared_conn,
-- ctx.db_conn_fatal is set to true so the homescreen can discard the connection.
local function fetchBookStats(md5, shared_conn, ctx, force)
    if not md5 then return nil end

    if not force and _bstats_cache[md5] then
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
                SELECT id FROM book WHERE md5 = '%s' LIMIT 1
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
    return SUISettings:nilOrTrue(pfx .. "currently_show_" .. key)
end

-- Toggles the visibility of an element.
local function _toggleElem(pfx, key)
    local cur = SUISettings:nilOrTrue(pfx .. "currently_show_" .. key)
    SUISettings:saveSetting(pfx .. "currently_show_" .. key, not cur)
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
-- _resolveElemOrder accepts an already-read value (from ctx.cfg bundle or
-- a direct G_reader_settings read) so the caller controls when the read happens.
local function _resolveElemOrder(saved)
    if type(saved) ~= "table" or #saved == 0 then
        return _ELEM_DEFAULT_ORDER
    end
    local seen, result = {}, {}
    for _, v in ipairs(saved) do
        if _ELEM_LABELS[v] and not seen[v] then
            seen[v] = true
            result[#result+1] = v
        end
    end
    for _, v in ipairs(_ELEM_DEFAULT_ORDER) do
        if not seen[v] then result[#result+1] = v end
    end
    return result
end

local function _getElemOrder(pfx)
    return _resolveElemOrder(SUISettings:readSetting(pfx .. ELEM_ORDER_KEY))
end


-- Module API
local M = {}

M.id          = "currently"
M.name        = _("Currently Reading")
M.label       = _("Currently Reading")
M.enabled_key = "currently_enabled"
M.default_on  = true
M.has_covers  = true   -- activates e-ink dithering and cover poll
M.is_book_mod = true   -- suppresses empty-state when active


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

    local tbw_title_line_h = math.floor(1.3 * title_line_h + 0.5)

    -- Accumulate height element by element, mirroring build()'s gap_before logic.
    -- Each entry is { gap, line_h } in render order.
    local elems = {}

    if show.title then
        elems[#elems+1] = { title_gap, tbw_title_line_h * 2 }
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

    -- Stats: when conservative=true (getHeight path) assume all active stats
    -- have data so that height is never under-allocated.
    -- When conservative=false (build path, bstats is real) check actual values.
    local conservative = params.conservative
    local function statsHasData(key)
        if conservative then return show[key] end
        if not bstats then return false end
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

    local content_h = math.max(D.COVER_H, h)
    if SUISettings:isTrue(params.pfx .. "currently_show_frame") or SUISettings:isTrue(params.pfx .. "currently_solid_bg") then
        content_h = content_h + PAD * 2
    end
    return content_h
end


-- Clears the stats cache (called from main.lua:onCloseDocument before rebuild).
function M.invalidateCache()
    -- Stale data is intentionally kept for the async UI update.
end

-- Exposed for pre-computation in _buildCtx (sui_homescreen.lua).
-- Mirrors module_coverdeck.fetchBookStatsForCtx.
-- Returns the stats table or nil; does NOT set ctx.db_conn_fatal (no ctx here).
function M.fetchBookStatsForCtx(md5, db_conn, force)
    return fetchBookStats(md5, db_conn, nil, force)
end


-- Builds the module widget: cover on the left, text column on the right.
-- Elements in the text column are rendered in user-configured order.
function M.build(w, ctx)
    Config.applyLabelToggle(M, _("Currently Reading"))
    if not ctx.current_fp then return nil end

    local SH = getSH()
    if not SH then return nil end

    -- Use pre-read settings bundle from ctx when available (normal HS path).
    -- Falls back to direct reads only when called outside the homescreen.
    local c = ctx.cfg and ctx.cfg.currently
    local pfx         = ctx.pfx
    local scale       = c and c.scale       or Config.getModuleScale("currently", pfx)
    local thumb_scale = c and c.thumb_scale or Config.getThumbScale("currently", pfx)
    local lbl_scale   = c and c.lbl_scale   or Config.getItemLabelScale("currently", pfx)
    local bar_style   = c and c.bar_style   or getBarStyle(pfx)
    local stats_style = c and c.stats_style or getStatsStyle(pfx)
    local show        = c and c.show or {
        title    = _showElem(pfx, "title"),
        author   = _showElem(pfx, "author"),
        progress = _showElem(pfx, "progress"),
        percent  = _showElem(pfx, "percent"),
        days     = _showElem(pfx, "book_days"),
        time     = _showElem(pfx, "book_time"),
        remain   = _showElem(pfx, "book_remaining"),
    }
    -- elem_order: use cached raw value from bundle; resolve lazily.
    local elem_order  = _resolveElemOrder(c and c.elem_order or SUISettings:readSetting(pfx .. ELEM_ORDER_KEY))

    local D           = SH.getDims(scale, thumb_scale)

    -- Scale gaps (layout scale only).
    local cover_gap      = math.max(0, math.floor(_BASE_COVER_GAP      * scale * (getCoverGapPct(pfx) / 100)))
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
    local face_title  = Font:getFace(SUIStyle.FACE_REGULAR, title_fs)
    local face_author = Font:getFace(SUIStyle.FACE_REGULAR, author_fs)
    local face_pct    = Font:getFace(SUIStyle.FACE_REGULAR, pct_fs)
    local face_s      = Font:getFace(SUIStyle.FACE_REGULAR, stats_fs)

    -- Use prefetched book data. After onCloseDocument, _cached_books_state is
    -- cleared and prefetchBooks() re-reads the sidecar, so this is always fresh.
    local prefetched_entry = ctx.prefetched and ctx.prefetched[ctx.current_fp]
    local bd    = SH.getBookData(ctx.current_fp, prefetched_entry)
    local cover = SH.getBookCover(ctx.current_fp, D.COVER_W, D.COVER_H, nil, 0.10)
                  or SH.coverPlaceholder(bd.title, bd.authors, D.COVER_W, D.COVER_H)

    -- Text column width: full width minus both PADs, cover, and cover gap.
    local tw = w - PAD - D.COVER_W - cover_gap - PAD

    local meta = VerticalGroup:new{ align = "left" }

    -- Fetch stats once if any stats element is active.
    local bstats
    if show.days or show.time or show.remain then
        local book_md5 = prefetched_entry and prefetched_entry.partial_md5_checksum
        -- Fix 2: log when md5 is absent so the cause is visible in crash.log.
        if not book_md5 then
            logger.dbg("simpleui: module_currently: no md5 for "
                       .. tostring(ctx.current_fp)
                       .. " — stats will not be fetched this render")
        end
        -- Fast path: use stats pre-computed by _buildCtx() (zero extra DB query).
        -- Falls back to a live query when _buildCtx didn't pre-compute them
        -- (e.g. direct call outside the homescreen, or ctx.currently_book_stats absent).
        local pre = ctx.currently_book_stats
        if pre and pre.fp == ctx.current_fp then
            bstats = pre.stats
        else
            bstats = fetchBookStats(book_md5, ctx.db_conn, ctx)
        end
    end

    -- Colour used for placeholder stats text (dimmer than the normal sub-text).
    local CLR_PLACEHOLDER = Blitbuffer.gray(0.55)

    -- Theme: when fg is set use it for all text; otherwise fall back to module defaults.
    local _theme_fg        = SUIStyle.getThemeColor("fg")
    local _theme_secondary = SUIStyle.getThemeColor("text_secondary")
    local _CLR_DARK_EFF    = _theme_fg or _CLR_DARK
    local CLR_TEXT_SUB_EFF = _theme_secondary or _theme_fg or CLR_TEXT_SUB
    local CLR_PH_EFF       = _theme_secondary or _theme_fg or CLR_PLACEHOLDER

    -- Pre-resolve the inline-pct font face once for buildProgressBarWithPct.
    local face_inlinepct = Font:getFace(SUIStyle.FACE_REGULAR,
        math.max(7, math.floor(_BASE_INLINEPCT_FS * scale * lbl_scale)))

    local _cr_update_funcs  = {}
    -- Fix 3: closures that only need bd (no bstats) — progress bar and percent.
    -- Called unconditionally by updateStats, even when there is no SQLite history.
    local _cr_bd_only_funcs = {}
    local function _updateColoredText(wgt, txt, fg)
        if wgt._inner and wgt._inner.setText then
            wgt._inner:setText(txt)
            wgt._fg = fg
            wgt.dimen = wgt._inner:getSize()
        elseif wgt.setText then
            wgt:setText(txt)
            wgt.fgcolor = fg
        end
    end

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

            local tbw_line_h = math.floor(1.3 * face_title.size + 0.5)
            local title_args = {
                text      = bd.title or "?",
                face      = face_title,
                bold      = true,
                width     = tw,
                height    = tbw_line_h * 2,
                height_adjust = true,
                height_overflow_show_ellipsis = true,
                max_lines = 2,
                fgcolor   = _CLR_DARK_EFF,
            }

            local title_w
            if ctx.has_wallpaper then
                local ok_tbx, tbx = pcall(UI.makeAlphaTextBox, title_args)
                if ok_tbx then
                    title_w = tbx
                else
                    logger.warn("simpleui: module_currently: makeAlphaTextBox failed, falling back to TextBoxWidget: " .. tostring(tbx))
                    title_w = TextBoxWidget:new(title_args)
                end
            else
                title_w = TextBoxWidget:new(title_args)
            end

            meta[#meta+1] = title_w
            meta_has_content = true

        elseif elem == "author" and show.author and bd.authors and bd.authors ~= "" then
            gap_before(author_gap)
            meta[#meta+1] = UI.makeColoredText{
                text            = bd.authors,
                face            = face_author,
                fgcolor         = CLR_TEXT_SUB_EFF,
                width           = tw,
                max_width       = tw,
                truncation_char = "â¦",  -- "…" UTF-8
            }
            meta_has_content = true

        elseif elem == "progress" and show.progress then
            gap_before(bar_gap_before)
            if bar_style == "with_pct" then
                -- Fix 3 (in-place update): wrap the bar in a container whose
                -- single child is replaced by _update_bar without touching the
                -- surrounding layout or allocating new VerticalGroup nodes.
                local _bar_w    = tw
                local _bar_h    = bar_h
                local _bar_sc   = scale
                local _bar_lbl  = lbl_scale
                local _bar_face = face_inlinepct
                local _bar_fg   = _CLR_DARK_EFF
                local _init_bar = buildProgressBarWithPct(_bar_w, bd.percent, _bar_h, _bar_sc, _bar_lbl, _bar_face, _bar_fg)
                local bar_container = OverlapGroup:new{
                    dimen = _init_bar:getSize(),
                    _init_bar,
                }
                local function _update_bar(nb, nd)
                    bar_container[1] = buildProgressBarWithPct(
                        _bar_w, (nd and nd.percent or 0), _bar_h, _bar_sc, _bar_lbl, _bar_face, _bar_fg)
                end
                table.insert(_cr_bd_only_funcs, _update_bar)
                meta[#meta+1] = bar_container
            else
                local _bar_w = tw
                local _bar_h = bar_h
            local _init_bar = UI.progressBar(_bar_w, bd.percent, _bar_h)
                local bar_container = OverlapGroup:new{
                    dimen = _init_bar:getSize(),
                    _init_bar,
                }
                local function _update_bar(nb, nd)
                bar_container[1] = UI.progressBar(_bar_w, (nd and nd.percent or 0), _bar_h)
                end
                table.insert(_cr_bd_only_funcs, _update_bar)
                meta[#meta+1] = bar_container
            end
            meta_has_content = true
            _next_gap = bar_gap_after  -- next element uses the larger post-bar gap

        elseif elem == "percent" and show.percent and bar_style ~= "with_pct" then
            gap_before(pct_gap)
            -- Fix 3 (in-place update): makeColoredText supports setText so we
            -- can update just the string without rebuilding the widget tree.
            local pct_w = UI.makeColoredText{
                text    = string.format(_("%d%% Read"), math.floor((bd.percent or 0) * 100 + 0.5)),
                face    = face_pct,
                bold    = true,
                fgcolor = _CLR_DARK_EFF,
                width   = tw,
            }
            local _pct_fg = _CLR_DARK_EFF
            local function _update_pct(nb, nd)
                _updateColoredText(pct_w,
                    string.format(_("%d%% Read"), math.floor((nd and nd.percent or 0) * 100 + 0.5)),
                    _pct_fg)
            end
            table.insert(_cr_bd_only_funcs, _update_pct)
            meta[#meta+1] = pct_w
            meta_has_content = true

        elseif elem == "book_days" and show.days and stats_style == "default" then
            -- Fix 1: show a placeholder when stats are not yet available (no DB,
            -- no md5, or zero days recorded) so the item is always visible once
            -- activated, giving the user clear feedback that it exists.
            local has_data = bstats and bstats.days and bstats.days > 0
            gap_before(pct_gap)
            local days_w = UI.makeColoredText{ text = "", face = face_s, fgcolor = CLR_PH_EFF, width = tw }
            local function _update(nb, nd)
                local has_d = nb and nb.days and nb.days > 0
                local days_lbl = has_d
                    and string.format(N_("%d day of reading", "%d days of reading", nb.days), nb.days)
                    or  string.format(N_("%d day of reading", "%d days of reading", 0), 0)
                _updateColoredText(days_w, days_lbl, has_d and CLR_TEXT_SUB_EFF or CLR_PH_EFF)
            end
            _update(bstats, bd)
            table.insert(_cr_update_funcs, _update)
            meta[#meta+1] = days_w
            meta_has_content = true

        elseif elem == "book_time" and show.time and stats_style == "default" then
            -- Fix 1: placeholder when total time is not yet recorded.
            local has_data = bstats and bstats.total_secs and bstats.total_secs > 0
            gap_before(pct_gap)
            local time_w = UI.makeColoredText{ text = "", face = face_s, fgcolor = CLR_PH_EFF, width = tw }
            local function _update(nb, nd)
                local has_d = nb and nb.total_secs and nb.total_secs > 0
                local text = has_d
                             and string.format(_("%s read"), fmtTime(nb.total_secs))
                             or  string.format(_("%s read"), "—")
                _updateColoredText(time_w, text, has_d and CLR_TEXT_SUB_EFF or CLR_PH_EFF)
            end
            _update(bstats, bd)
            table.insert(_cr_update_funcs, _update)
            meta[#meta+1] = time_w
            meta_has_content = true

        elseif elem == "book_remaining" and show.remain and stats_style == "default" then
            -- Fix 4: explicit, symmetric guard mirroring book_days / book_time.
            -- Prefer the capped avg_time from fetchBookStats to avoid over-estimating
            -- remaining time when pages had long idle pauses.
            local pct_done = bd.percent or 0
            if pct_done < 1.0 then
                gap_before(pct_gap)
                local remain_w = UI.makeColoredText{ text = "", face = face_s, fgcolor = CLR_PH_EFF, width = tw }
                local function _update(nb, nd)
                    local avg_t
                    if nb and nb.avg_time and nb.avg_time > 0 then avg_t = nb.avg_time
                    elseif nd.avg_time and nd.avg_time > 0 then avg_t = nd.avg_time end
                    
                    if not avg_t or not nd.pages or nd.pages <= 0 then
                        _updateColoredText(remain_w, string.format(_("%s remaining"), "—"), CLR_PH_EFF)
                    else
                        local pages_left = nd.pages * (1 - (nd.percent or 0))
                        local secs_left  = math.floor(avg_t * pages_left)
                        if secs_left > 0 then _updateColoredText(remain_w, string.format(_("%s remaining"), fmtTime(secs_left)), CLR_TEXT_SUB_EFF)
                        else _updateColoredText(remain_w, "", CLR_PH_EFF) end
                    end
                end
                _update(bstats, bd)
                table.insert(_cr_update_funcs, _update)
                meta[#meta+1] = remain_w
                meta_has_content = true
            end

        elseif (elem == "book_days" or elem == "book_time" or elem == "book_remaining")
               and stats_style == "compact" then
            -- Compact mode: single row following the Arrange Items order.
            -- Fires on the first visible stats element encountered; the others are
            -- consumed here so they don't produce a second row when the loop reaches them.
            if not _compact_stats_rendered then
                _compact_stats_rendered = true

                local stats_row = HorizontalGroup:new{ align = "center" }
                
                local function _update(nb, nd)
                    local secs_left
                    local avg_t = (nb and nb.avg_time and nb.avg_time > 0) and nb.avg_time or nd.avg_time
                    if avg_t and avg_t > 0 and nd.pages and nd.pages > 0 then
                        local sl = math.floor(avg_t * nd.pages * (1 - (nd.percent or 0)))
                        if sl > 0 then secs_left = sl end
                    end

                    local parts = {}
                    for _i, e in ipairs(elem_order) do
                        if e == "book_time" and show.time and nb and nb.total_secs > 0 then
                            parts[#parts+1] = { text = string.format(_("%s read"), fmtTime(nb.total_secs)), placeholder = false }
                        elseif e == "book_remaining" and show.remain and secs_left then
                            parts[#parts+1] = { text = string.format(_("%s left"), fmtTime(secs_left)), placeholder = false }
                        elseif e == "book_days" and show.days and nb and nb.days > 0 then
                            parts[#parts+1] = { text = string.format(N_("%d day of reading", "%d days of reading", nb.days), nb.days), placeholder = false }
                        end
                    end

                    if #parts == 0 then
                        local any_active = (show.days or show.time or show.remain)
                        if any_active then
                            parts[#parts+1] = { text = string.format(_("%s read"), "—"), placeholder = true }
                        end
                    end

                    for i = #stats_row, 1, -1 do stats_row[i] = nil end
                    
                    for i, part in ipairs(parts) do
                        if i > 1 then
                            stats_row[#stats_row+1] = UI.makeColoredText{
                                text    = " · ",
                                face    = face_s,
                                fgcolor = CLR_TEXT_SUB_EFF,
                            }
                        end
                        stats_row[#stats_row+1] = UI.makeColoredText{
                            text    = part.text,
                            face    = face_s,
                            fgcolor = part.placeholder and CLR_PH_EFF or CLR_TEXT_SUB_EFF,
                        }
                    end
                end

                _update(bstats, bd)
                table.insert(_cr_update_funcs, _update)
                if #stats_row > 0 then
                    gap_before(pct_gap)
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

    local show_frame = SUISettings:isTrue(pfx .. "currently_show_frame")
    local solid_bg   = SUISettings:isTrue(pfx .. "currently_solid_bg")
    local has_box    = show_frame or solid_bg
    local border_sz  = show_frame and SUIStyle.BORDER_SZ or 0
    local radius     = has_box and math.floor(Screen:scaleBySize(12) * scale) or 0
    local border_color = Blitbuffer.gray(0.72)
    border_color = SUIStyle.getThemeColor("separator") or border_color
    local bg_color = nil
    if solid_bg then
        bg_color = SUIStyle.getThemeColor("bg") or Blitbuffer.COLOR_WHITE
    end

    local full_h = content_h
    if has_box then full_h = full_h + PAD * 2 end

    -- Layout: cover on left, text column on right.
    -- The cover is wrapped in a CenterContainer sized to content_h so it
    -- stays vertically centred when the text column is taller than the cover.
    local cover_frame = FrameContainer:new{
            bordersize    = 0, padding = 0,
            padding_right = cover_gap,
            cover,
        }
    local cover_centered = CenterContainer:new{
        dimen = Geom:new{ w = D.COVER_W + cover_gap, h = content_h },
        cover_frame,
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
        dimen    = Geom:new{ w = w, h = full_h },
        _fp      = ctx.current_fp,
        _open_fn = ctx.open_fn,
        [1] = FrameContainer:new{
            bordersize    = border_sz,
            radius        = radius,
            color         = border_color,
            background    = bg_color,
            padding       = 0,
            padding_left  = PAD,
            padding_right = PAD,
            padding_top   = has_box and PAD or 0,
            padding_bottom= has_box and PAD or 0,
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
    tappable._cover_slots = {
        { container = cover_frame, idx = 1, fp = ctx.current_fp,
          w = D.COVER_W, h = D.COVER_H, align = nil, stretch = 0.10 },
    }
    function tappable:onTapBook()
        if self._open_fn then self._open_fn(self._fp) end
        return true
    end

    tappable._cr_update_funcs  = _cr_update_funcs
    tappable._cr_bd_only_funcs = _cr_bd_only_funcs

    -- Keyboard focus: overlay a black rectangular border on the tappable when
    -- this book is the currently selected keyboard-navigation item.
    if ctx.kb_currently_focused then
        local bw = Screen:scaleBySize(3)
        local tw = w
        local th = full_h
        return OverlapGroup:new{
            dimen = Geom:new{ w = tw, h = th },
            tappable,
            LineWidget:new{ dimen = Geom:new{ w = tw, h = bw },    background = _CLR_DARK_EFF },
            LineWidget:new{ dimen = Geom:new{ w = tw, h = bw },    background = _CLR_DARK_EFF, overlap_offset = {0, th - bw} },
            LineWidget:new{ dimen = Geom:new{ w = bw, h = th },    background = _CLR_DARK_EFF },
            LineWidget:new{ dimen = Geom:new{ w = bw, h = th },    background = _CLR_DARK_EFF, overlap_offset = {tw - bw, 0} },
        }
    end

    return tappable
end

-- updateCovers(widget, ctx) — called by the homescreen cover poll instead of
-- a full build(). Swaps only the cover image(s) inside the existing widget
-- tree, leaving all text, layout, and gesture handlers untouched.
-- Returns true if all covers are now resolved, false if some are still missing.
function M.updateCovers(widget, _ctx)
    -- widget is either tappable (normal) or OverlapGroup{tappable,...} (kb focus)
    local tappable = (widget._cover_slots) and widget
                     or (widget[1] and widget[1]._cover_slots and widget[1])
    if not tappable or not tappable._cover_slots then return true end

    local SH = getSH()
    if not SH then return true end

    local all_done = true
    for _, slot in ipairs(tappable._cover_slots) do
        local new_cover = SH.getBookCover(slot.fp, slot.w, slot.h, slot.align, slot.stretch)
        if new_cover then
            slot.container[slot.idx] = new_cover
        elseif not Config.isCoverMissing(slot.fp) then
            all_done = false
        end
    end
    return all_done
end-- Returns the total pixel height of the module including the section label.
-- Measures real font line heights via Font:getFace() so the estimate matches
-- what build() actually renders.  This prevents the homescreen from
-- under-allocating space and causing overlap with the module below.
function M.getHeight(_ctx)
    local SH = getSH()
    if not SH then return Config.getScaledLabelH() end
    local pfx = _ctx and _ctx.pfx
    -- Use pre-read settings bundle from ctx when available (normal HS path).
    -- ctx.cfg.currently.scale was captured while the landscape patch was active,
    -- so it already carries the × 0.65 factor in landscape — giving the correct
    -- height without needing a separate patch here.
    local c           = _ctx and _ctx.cfg and _ctx.cfg.currently
    local scale       = c and c.scale       or Config.getModuleScale("currently", pfx)
    local lbl_scale   = c and c.lbl_scale   or Config.getItemLabelScale("currently", pfx)
    local D           = SH.getDims(scale, c and c.thumb_scale or Config.getThumbScale("currently", pfx))
    local stats_style = c and c.stats_style or getStatsStyle(pfx)
    local bar_style   = c and c.bar_style   or getBarStyle(pfx)

    local show = c and c.show or {
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
        elems[#elems+1] = { title_gap, title_lh * 2 }
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
    -- Stats: conservative — always reserve height for every active stats item
    -- (Fix 3: placeholder rows are rendered when data is absent, so height is
    -- always consumed; under-allocating here would cause overlap below the module).
    -- Exception: book_remaining is suppressed only when the book is 100% done,
    -- but getHeight has no percent data, so we keep the conservative assumption.
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

    local content_h = math.max(D.COVER_H, text_h)
    if SUISettings:isTrue(pfx .. "currently_show_frame") or SUISettings:isTrue(pfx .. "currently_solid_bg") then
        content_h = content_h + PAD * 2
    end
    return Config.getScaledLabelH() + content_h
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


local function _makeCoverGapItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func = function() return _lc("Cover Spacing") end,
        separator = true,
        title     = _lc("Cover Spacing"),
        info      = _lc("Horizontal space between the cover and the text.\n100% is the default spacing."),
        get       = function() return getCoverGapPct(pfx) end,
        set       = function(v) SUISettings:saveSetting(pfx .. COVER_GAP_KEY, v) end,
        refresh   = ctx_menu.refresh,
        value_min = 0,
        value_max = 300,
        value_step = 10,
        default_value = 100,
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

    local gap_item = _makeCoverGapItem(ctx_menu)

    local items_submenu = {
        -- Arrange Items: drag-to-reorder the visible elements. Disabled when fewer than 2 are active.
        {
            text           = _lc("Arrange Items"),
            keep_menu_open = true,
            separator      = true,
            enabled_func   = function()
                local active = 0
                local bar_style = getBarStyle(pfx)
                for _, key in ipairs(_ELEM_DEFAULT_ORDER) do
                    if key == "percent" and bar_style == "with_pct" then
                        -- skip
                    elseif _showElem(pfx, key) then
                        active = active + 1
                        if active >= 2 then return true end
                    end
                end
                return false
            end,
            callback = function()
                local sort_items = {}
                local bar_style = getBarStyle(pfx)
                for _, key in ipairs(_getElemOrder(pfx)) do
                    if key == "percent" and bar_style == "with_pct" then
                        -- skip
                    elseif _showElem(pfx, key) then
                        sort_items[#sort_items+1] = {
                            text      = _lc(_ELEM_LABELS[key]),
                            orig_item = key,
                        }
                    end
                end
                local function on_save()
                    local new_order = {}
                    for _, item in ipairs(sort_items) do
                        new_order[#new_order+1] = item.orig_item
                    end
                    local active_set = {}
                    for _, k in ipairs(new_order) do active_set[k] = true end
                    for _, k in ipairs(_getElemOrder(pfx)) do
                        if not active_set[k] then new_order[#new_order+1] = k end
                    end
                    SUISettings:saveSetting(pfx .. ELEM_ORDER_KEY, new_order)
                    refresh()
                end
                _UIManager:show(SortWidget:new{
                    title = _lc("Arrange Items"), item_table = sort_items,
                    covers_fullscreen = true, callback = on_save,
                })
            end,
            sui_build = ctx_menu.is_sui and function(ctx, _item)
                local sort_items = {}
                for _, key in ipairs(_getElemOrder(pfx)) do
                    if _showElem(pfx, key) then
                        sort_items[#sort_items+1] = {
                            text      = _lc(_ELEM_LABELS[key]),
                            orig_item = key,
                        }
                    end
                end
                local function on_save()
                    local new_order = {}
                    for _, item in ipairs(sort_items) do
                        new_order[#new_order+1] = item.orig_item
                    end
                    local active_set = {}
                    for _, k in ipairs(new_order) do active_set[k] = true end
                    for _, k in ipairs(_getElemOrder(pfx)) do
                        if not active_set[k] then new_order[#new_order+1] = k end
                    end
                    SUISettings:saveSetting(pfx .. ELEM_ORDER_KEY, new_order)
                    refresh()
                end
                local SUIWindow = require("sui_window")
                return SUIWindow.ArrangeList{ inner_w = ctx.inner_w, items = sort_items, on_change = on_save }
            end or nil,
        },
        -- Visibility toggles (alphabetical order).
        toggle_item("Author",          "author"),
        toggle_item("Days of reading", "book_days"),
        {
            text_func      = function() return _lc("Percentage read") end,
            -- Greyed out when with_pct bar style is active (percentage is already in the bar).
            enabled_func   = function() return getBarStyle(pfx) == "simple" end,
            checked_func   = function() return _showElem(pfx, "percent") end,
            sui_hidden     = function() return getBarStyle(pfx) == "with_pct" end,
            keep_menu_open = true,
            callback       = function()
                _toggleElem(pfx, "percent")
                refresh()
            end,
        },
        toggle_item("Progress bar", "progress"),
        toggle_item("Time read",      "book_time"),
        toggle_item("Time remaining", "book_remaining"),
        toggle_item("Title",          "title"),
    }

    return {
        {
            text           = _lc("Items"),
            sub_item_table = items_submenu,
            sui_build = ctx_menu.is_sui and function(ctx, _item)
                local SUIWindow = require("sui_window")
                return SUIWindow.ListRow{
                    title        = _lc("Items"),
                    subtitle     = function()
                        local names = {}
                        local bar_style = getBarStyle(pfx)
                        local is_compact = getStatsStyle(pfx) == "compact"
                        local stats_added = false
                        for _, key in ipairs(_getElemOrder(pfx)) do
                            if key == "percent" and bar_style == "with_pct" then
                                -- skip
                            elseif _showElem(pfx, key) then
                                if is_compact and (key == "book_days" or key == "book_time" or key == "book_remaining") then
                                    if not stats_added then names[#names + 1] = _lc("Stats"); stats_added = true end
                                else
                                    names[#names + 1] = _lc(_ELEM_LABELS[key])
                                end
                            end
                        end
                        return #names > 0 and table.concat(names, "  ·  ") or _lc("No items selected.")
                    end,
                    inner_w      = ctx.inner_w,
                    show_chevron = true,
                    on_tap       = function()
                        ctx.push("nested_menu", {
                            title = _lc("Items"),
                            footer_text = _lc("Add Item"),
                    footer_enabled = function()
                                local bar_style = getBarStyle(pfx)
                                for _, key in ipairs(_getElemOrder(pfx)) do
                                    if key == "percent" and bar_style == "with_pct" then
                                        -- skip
                                    elseif not _showElem(pfx, key) then return true end
                                end
                                return false
                            end,
                            footer_action = function(ctx2)
                                local bar_style = getBarStyle(pfx)
                                local picker_items = {}
                                for _, key in ipairs(_getElemOrder(pfx)) do
                                    if key == "percent" and bar_style == "with_pct" then
                                        -- skip
                                    elseif not _showElem(pfx, key) then
                                        local _key   = key
                                        local _label = _lc(_ELEM_LABELS[key])
                                        picker_items[#picker_items + 1] = {
                                            text   = _label,
                                            on_tap = function(picker_ctx)
                                                _toggleElem(pfx, _key)
                                                local new_order = {}
                                                local active_set = {}
                                                for _, k in ipairs(_getElemOrder(pfx)) do
                                                    if _showElem(pfx, k) and k ~= _key then
                                                        new_order[#new_order + 1] = k
                                                        active_set[k] = true
                                                    end
                                                end
                                                new_order[#new_order + 1] = _key
                                                active_set[_key] = true
                                                for _, k in ipairs(_getElemOrder(pfx)) do
                                                    if not active_set[k] then
                                                        new_order[#new_order + 1] = k
                                                    end
                                                end
                                                SUISettings:saveSetting(pfx .. ELEM_ORDER_KEY, new_order)
                                                refresh()
                                                picker_ctx.pop()
                                                ctx2.repaint()
                                            end,
                                        }
                                    end
                                end
                                ctx2.push("item_picker", {
                                    title = _lc("Add Item"),
                                    items = picker_items,
                                })
                            end,
                            items_func = function()
                                return {
                                    {
                                        text = "Items List",
                                        sui_build = function(ctx2)
                                            local SUIWindow = require("sui_window")
                                            local is_compact = getStatsStyle(pfx) == "compact"
                                            local function make_sort_items()
                                                local t = {}
                                                local stats_added = false
                                                local bar_style = getBarStyle(pfx)
                                                for _, key in ipairs(_getElemOrder(pfx)) do
                                                    if key == "percent" and bar_style == "with_pct" then
                                                        -- skip
                                                    elseif _showElem(pfx, key) then
                                                        if is_compact and (key == "book_days" or key == "book_time" or key == "book_remaining") then
                                                            if not stats_added then
                                                                t[#t + 1] = {
                                                                    text = _lc("Stats"),
                                                                    subtitle = function()
                                                                        local names = {}
                                                                        for _, k in ipairs(_getElemOrder(pfx)) do
                                                                            if _showElem(pfx, k) and (k == "book_days" or k == "book_time" or k == "book_remaining") then
                                                                                names[#names + 1] = _lc(_ELEM_LABELS[k])
                                                                            end
                                                                        end
                                                                        return #names > 0 and table.concat(names, "  ·  ") or _lc("No items selected.")
                                                                    end,
                                                                    orig_item = "stats_group",
                                                                    is_stats_group = true
                                                                }
                                                                stats_added = true
                                                            end
                                                        else
                                                            t[#t + 1] = { text = _lc(_ELEM_LABELS[key]), orig_item = key }
                                                        end
                                                    end
                                                end
                                                return t
                                            end
                                            local sort_items = make_sort_items()
                                            local function save_order(items_to_save)
                                                local new_order  = {}
                                                local active_set = {}
                                                local active_stats_in_order = {}
                                                for _, k in ipairs(_getElemOrder(pfx)) do
                                                    if _showElem(pfx, k) and (k == "book_days" or k == "book_time" or k == "book_remaining") then
                                                        table.insert(active_stats_in_order, k)
                                                    end
                                                end
                                                for _, it in ipairs(items_to_save) do
                                                    if it.is_stats_group then
                                                        for _, stat_key in ipairs(active_stats_in_order) do
                                                            new_order[#new_order + 1] = stat_key
                                                            active_set[stat_key] = true
                                                        end
                                                    else
                                                        new_order[#new_order + 1] = it.orig_item
                                                        active_set[it.orig_item]  = true
                                                    end
                                                end
                                                for _, k in ipairs(_getElemOrder(pfx)) do
                                                    if not active_set[k] then new_order[#new_order + 1] = k end
                                                end
                                                SUISettings:saveSetting(pfx .. ELEM_ORDER_KEY, new_order)
                                            end
                                            
                                            local cards = {}
                                            for i, item in ipairs(sort_items) do
                                                local _i   = i
                                                local _key = item.orig_item
                                                local _is_sg = item.is_stats_group == true
                                                cards[#cards + 1] = SUIWindow.ArrangeCard{
                                                    inner_w      = ctx2.inner_w,
                                                    title        = item.text,
                                                subtitle     = item.subtitle,
                                                    show_chevron = _is_sg,
                                                    on_tap       = _is_sg and function()
                                                        ctx.push("nested_menu", {
                                                            title = _lc("Stats"),
                                                            items_func = function()
                                                                return {
                                                                    {
                                                                        text = "Stats Sub-Items List",
                                                                        sui_build = function(ctx3)
                                                                            local SUIWindow2 = require("sui_window")
                                                                            local function make_sub_items()
                                                                                local st = {}
                                                                                for _, k in ipairs(_getElemOrder(pfx)) do
                                                                                    if _showElem(pfx, k) and (k == "book_days" or k == "book_time" or k == "book_remaining") then
                                                                                        st[#st + 1] = { text = _lc(_ELEM_LABELS[k]), orig_item = k }
                                                                                    end
                                                                                end
                                                                                return st
                                                                            end
                                                                            local sub_items = make_sub_items()
                                                                            
                                                                            local function save_sub_order(new_sub)
                                                                                local n_ord = {}
                                                                                local s_idx = 1
                                                                                local active_stats = {}
                                                                                for _, it in ipairs(new_sub) do active_stats[it.orig_item] = true end
                                                                                
                                                                                for _, k in ipairs(_getElemOrder(pfx)) do
                                                                                    if _showElem(pfx, k) and (k == "book_days" or k == "book_time" or k == "book_remaining") then
                                                                                        if new_sub[s_idx] then
                                                                                            table.insert(n_ord, new_sub[s_idx].orig_item)
                                                                                            s_idx = s_idx + 1
                                                                                        end
                                                                                    else
                                                                                        table.insert(n_ord, k)
                                                                                    end
                                                                                end
                                                                                for _, k in ipairs({"book_days", "book_time", "book_remaining"}) do
                                                                                    if not active_stats[k] then
                                                                                        local found = false
                                                                                        for _, x in ipairs(n_ord) do if x == k then found = true; break end end
                                                                                        if not found then table.insert(n_ord, k) end
                                                                                    end
                                                                                end
                                                                                SUISettings:saveSetting(pfx .. ELEM_ORDER_KEY, n_ord)
                                                                            end
                                                                            
                                                                            local scards = {}
                                                                            for si, sitem in ipairs(sub_items) do
                                                                                local _si = si
                                                                                local _skey = sitem.orig_item
                                                                                scards[#scards + 1] = SUIWindow2.ArrangeCard{
                                                                                    inner_w      = ctx3.inner_w,
                                                                                    title        = sitem.text,
                                                                                    on_delete    = function()
                                                                                        _toggleElem(pfx, _skey)
                                                                                        table.remove(sub_items, _si)
                                                                                        save_sub_order(sub_items)
                                                                                        refresh()
                                                                                        if #sub_items == 0 then
                                                                                            ctx.pop()
                                                                                            ctx.repaint()
                                                                                        else
                                                                                            ctx.repaint()
                                                                                        end
                                                                                    end,
                                                                                    on_move_up   = (_si > 1) and function()
                                                                                        sub_items[_si], sub_items[_si-1] = sub_items[_si-1], sub_items[_si]
                                                                                        save_sub_order(sub_items)
                                                                                        refresh()
                                                                                        ctx.repaint()
                                                                                    end or nil,
                                                                                    on_move_down = (_si < #sub_items) and function()
                                                                                        sub_items[_si], sub_items[_si+1] = sub_items[_si+1], sub_items[_si]
                                                                                        save_sub_order(sub_items)
                                                                                        refresh()
                                                                                        ctx.repaint()
                                                                                    end or nil,
                                                                                }
                                                                            end
                                                                    if #scards == 0 then
                                                                        scards[#scards + 1] = SUIWindow2.ListRow{
                                                                            title   = _lc("No items selected."),
                                                                            inner_w = ctx3.inner_w,
                                                                        }
                                                                    end
                                                                            return scards
                                                                        end
                                                                    }
                                                                }
                                                            end
                                                        })
                                                    end or nil,
                                                    on_delete    = function()
                                                        if _is_sg then
                                                            for _, stat_key in ipairs({"book_days", "book_time", "book_remaining"}) do
                                                                if _showElem(pfx, stat_key) then
                                                                    _toggleElem(pfx, stat_key)
                                                                end
                                                            end
                                                        else
                                                            _toggleElem(pfx, _key)
                                                        end
                                                        table.remove(sort_items, _i)
                                                        save_order(sort_items)
                                                        refresh()
                                                        ctx2.repaint()
                                                    end,
                                                    on_move_up   = (_i > 1) and function()
                                                        sort_items[_i], sort_items[_i-1] = sort_items[_i-1], sort_items[_i]
                                                        save_order(sort_items)
                                                        refresh()
                                                        ctx2.repaint()
                                                    end or nil,
                                                    on_move_down = (_i < #sort_items) and function()
                                                        sort_items[_i], sort_items[_i+1] = sort_items[_i+1], sort_items[_i]
                                                        save_order(sort_items)
                                                        refresh()
                                                        ctx2.repaint()
                                                    end or nil,
                                                }
                                            end
                                            
                                            if #cards == 0 then
                                                cards[#cards + 1] = SUIWindow.ListRow{
                                                    title   = _lc("No items selected."),
                                                    inner_w = ctx2.inner_w,
                                                }
                                            end
                                            return cards
                                        end
                                    }
                                }
                            end
                        })
                    end
                }
            end or nil,
        },
        _makeScaleItem(ctx_menu),
        _makeTextScaleItem(ctx_menu),
        thumb,
        gap_item,
        Config.makeLabelToggleItem("currently", _("Currently Reading"), refresh, _lc),
        {
            text           = _lc("Frame"),
            checked_func   = function() return SUISettings:isTrue(pfx .. "currently_show_frame") end,
            keep_menu_open = true,
            callback       = function()
                SUISettings:saveSetting(pfx .. "currently_show_frame", not SUISettings:isTrue(pfx .. "currently_show_frame"))
                refresh()
            end,
        },
        {
            text           = _lc("Solid Background"),
            checked_func   = function() return SUISettings:isTrue(pfx .. "currently_solid_bg") end,
            keep_menu_open = true,
            callback       = function()
                SUISettings:saveSetting(pfx .. "currently_solid_bg", not SUISettings:isTrue(pfx .. "currently_solid_bg"))
                refresh()
            end,
        },
        {
            text = _lc("Progress bar style"),
            sub_item_table = {
                {
                    text           = _lc("Simple"),
                    radio          = true,
                    keep_menu_open = true,
                    checked_func   = function() return getBarStyle(pfx) == "simple" end,
                    callback       = function()
                        SUISettings:saveSetting(pfx .. BAR_STYLE_KEY, "simple")
                        refresh()
                    end,
                },
                {
                    text           = _lc("With percentage"),
                    radio          = true,
                    keep_menu_open = true,
                    checked_func   = function() return getBarStyle(pfx) == "with_pct" end,
                    callback       = function()
                        SUISettings:saveSetting(pfx .. BAR_STYLE_KEY, "with_pct")
                        refresh()
                    end,
                },
            },
        },
        {
            text = _lc("Stats layout"),
            sub_item_table = {
                {
                    text           = _lc("Default"),
                    radio          = true,
                    keep_menu_open = true,
                    checked_func   = function() return getStatsStyle(pfx) == "default" end,
                    callback       = function()
                        SUISettings:saveSetting(pfx .. STATS_STYLE_KEY, "default")
                        refresh()
                    end,
                },
                {
                    text           = _lc("Compact"),
                    radio          = true,
                    keep_menu_open = true,
                    checked_func   = function() return getStatsStyle(pfx) == "compact" end,
                    callback       = function()
                        SUISettings:saveSetting(pfx .. STATS_STYLE_KEY, "compact")
                        refresh()
                    end,
                },
            },
        },
        {
            text           = _lc("Update Stats Now"),
            separator      = true,
            keep_menu_open = true,
            callback       = function()
                local SP = package.loaded["desktop_modules/module_stats_provider"]
                if SP and SP.invalidate then SP.invalidate() end
                local SH = package.loaded["desktop_modules/module_books_shared"]
                if SH and SH.invalidateSidecarCache then SH.invalidateSidecarCache() end
                local MC = package.loaded["desktop_modules/module_currently"]
                if MC and MC.invalidateCache then MC.invalidateCache() end
                local MCD = package.loaded["desktop_modules/module_coverdeck"]
                if MCD and MCD.invalidateCache then MCD.invalidateCache() end
                
                local HS = package.loaded["sui_homescreen"]
                if HS then
                    HS._cached_books_state = nil
                    HS._cfg_cache = nil
                    if HS._instance then
                        HS._instance:_refreshImmediate(false)
                    end
                end
                if ctx_menu and type(ctx_menu.refresh) == "function" then ctx_menu.refresh() elseif refresh then refresh() end
                local InfoMessage = ctx_menu and ctx_menu.InfoMessage or require("ui/widget/infomessage")
                local UIM = ctx_menu and ctx_menu.UIManager or require("ui/uimanager")
                UIM:show(InfoMessage:new{ text = _lc("Stats updated successfully."), timeout = 2 })
            end,
        },
    }
end

function M.updateStats(widget, ctx)
    local actual_widget = (widget._cr_update_funcs) and widget
                          or (widget[1] and widget[1]._cr_update_funcs and widget[1])
    if not actual_widget or not actual_widget._cr_update_funcs then return false end
    
    local fp = actual_widget._fp
    if not fp then return false end

    -- BUGFIX: the widget only carries data for the book it was built with
    -- (_fp). If ctx.current_fp now points to a DIFFERENT book — e.g. the
    -- user closed a book that wasn't already showing in "Currently
    -- Reading" — patching stats in-place would silently refresh the WRONG
    -- book's numbers while leaving the old book's cover/title on screen.
    -- Force a full rebuild (return false) so module_currently.build() runs
    -- again with the new ctx.current_fp and replaces the widget entirely,
    -- mirroring the identity check module_recent.updateStats() already
    -- does for its own fp list.
    if ctx.current_fp ~= fp then return false end

    local bstats
    local pre = ctx.currently_book_stats
    if pre and pre.fp == fp then
        bstats = pre.stats
    end
    
    local prefetched_entry = ctx.prefetched and ctx.prefetched[fp]
    if not bstats then
        local md5 = prefetched_entry and prefetched_entry.partial_md5_checksum
        if not md5 then
            local DS = require("docsettings")
            local ok_ds, ds = pcall(DS.open, DS, fp)
            if ok_ds and ds then
                md5 = ds:readSetting("partial_md5_checksum")
                pcall(function() ds:close() end)
            end
        end
        if md5 then
            bstats = fetchBookStats(md5, ctx.db_conn, ctx, true)
        end
    end
    
    if bstats then
        local SH = getSH()
        local bd = SH.getBookData(fp, prefetched_entry)
        for _, fn in ipairs(actual_widget._cr_update_funcs) do
            fn(bstats, bd)
        end
        -- Fix 3: also update bd-only widgets (progress bar, percent) in the same pass.
        if actual_widget._cr_bd_only_funcs then
            for _, fn in ipairs(actual_widget._cr_bd_only_funcs) do
                fn(nil, bd)
            end
        end
    elseif actual_widget._cr_bd_only_funcs then
        -- Fix 3: progress bar and percent only need bd (no bstats).
        -- Call them even when there are no DB stats yet (new book, no history).
        local SH = getSH()
        if SH then
            local bd = SH.getBookData(fp, prefetched_entry)
            for _, fn in ipairs(actual_widget._cr_bd_only_funcs) do
                fn(nil, bd)
            end
        end
    end
    return true
end

return M