-- module_currently.lua — Simple UI
-- Currently Reading module: cover + title + author + progress bar + percentage.

-- External dependencies
local Device  = require("device")
local Screen  = Device.screen
local _ = require("infra/sui_i18n").translate
local N_ = require("infra/sui_i18n").ngettext
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
local Config       = require("infra/sui_config")
local UI           = require("infra/sui_core")
local SUISettings  = require("infra/sui_store")
local SUIStyle     = require("features/sui_style")
local PAD          = UI.PAD
local LABEL_H      = UI.LABEL_H
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

-- Lazy-loaded shared book helpers (cover, progress bar, book data).
local _SH = nil
local function getSH()
    if not _SH then
        local ok, m = pcall(require, "modules/module_books_shared")
        if ok and m then _SH = m
        else logger.warn("simpleui: module_currently: cannot load module_books_shared: " .. tostring(m)) end
    end
    return _SH
end

-- Colours

-- Vertical gaps between elements (base values at 100% scale; scaled in build()).
local _BASE_COVER_GAP  = Screen:scaleBySize(16)  -- between cover and text column
local _BASE_TITLE_GAP  = Screen:scaleBySize(4)   -- before title
local _BASE_AUTHOR_GAP = Screen:scaleBySize(6)   -- before author
local _BASE_SERIES_GAP = Screen:scaleBySize(4)   -- before series (smaller — visually grouped with author)
local _BASE_DESC_GAP   = Screen:scaleBySize(6)   -- before description
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
local _BASE_DESC_FS      = SUIStyle.FS_DETAIL     -- 15: description text
local _BASE_SERIES_FS    = SUIStyle.FS_CAPTION    -- 12: series text (smaller than author)

-- Description is clamped to a fixed number of lines rather than a dynamic
-- "remaining space" layout, because every other element in this module
-- reserves a fixed height; keeping description fixed-height too lets height
-- calculations stay a simple sum. The card itself grows to fit its
-- elements, so a taller fixed value costs no layout risk — just card height.
local DESC_MAX_LINES = 8

-- Setting key for progress bar style: "simple" (default) or "with_pct"
local BAR_STYLE_KEY = "currently_bar_style"

local function getBarStyle(pfx)
    return SUISettings:readSetting(pfx .. BAR_STYLE_KEY) or "with_pct"
end

-- Progress badge (pentagon overlay on the cover) — same drawing primitive
-- and settings shape as the Coverdeck / book-grid progress badge.
-- Opt-in (unset == off). Color override nil means "Follow Library".
local SETTING_SHOW_PROGRESS_BADGE  = "currently_show_progress_badge"
local SETTING_PROGRESS_BADGE_COLOR = "currently_progress_badge_color"

local function showProgressBadge(pfx)
    return SUISettings:readSetting(pfx .. SETTING_SHOW_PROGRESS_BADGE) == true
end

local function getProgressBadgeColorOverride(pfx)
    local v = SUISettings:readSetting(pfx .. SETTING_PROGRESS_BADGE_COLOR)
    if v == "dark" or v == "light" then return v end
    return nil
end

local function setProgressBadgeColor(pfx, v)
    SUISettings:saveSetting(pfx .. SETTING_PROGRESS_BADGE_COLOR, v)
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

-- Setting key for the module's overall layout mode. Both modes share the
-- exact same single-column architecture (one centered VerticalGroup, built
-- by buildMetaColumn — see below); they only differ in how the cover is
-- sized:
--   "default" — cover sized as a percentage of the module's own width
--               (see _COVER_W_PCT); if the text column would end up
--               shorter than the cover, non-elastic content keeps its
--               natural size and the description (the only elastic
--               element) shrinks or is omitted to fit
--   "dynamic" — same as "default", but the cover additionally grows or
--               shrinks to match the text column's height
-- Any other stored value (including legacy/removed modes) falls back to
-- "default", which is also the default for a module never configured.
local LAYOUT_KEY = "currently_layout"

local function getLayout(pfx)
    return SUISettings:readSetting(pfx .. LAYOUT_KEY) == "dynamic" and "dynamic" or "default"
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
    local _fg     = fg_color or SUIStyle.COLOR.text_primary

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
                %s
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
        ]], string.format(Config.BOOK_ID_BY_MD5_SQL, md5), _MAX_SEC))

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


-- Returns true if the element with the given key is visible.
-- nilOrTrue() treats an unset key as true; that's a defensive fallback only —
-- the real shipped default for every currently_show_* key is written
-- explicitly by sui_config.lua's applyFirstRunDefaults() on first run. See
-- the def()/nilOrTrue() contract note there before relying on this fallback.
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
    "title", "author", "series", "description", "progress", "percent",
    "book_days", "book_time", "book_remaining",
}

local _ELEM_LABELS = {
    title          = _("Title"),
    author         = _("Author"),
    series         = _("Series"),
    description    = _("Description"),
    progress       = _("Progress bar"),
    percent        = _("Percentage read"),
    book_days      = _("Days of reading"),
    book_time      = _("Time read"),
    book_remaining = _("Time remaining"),
}

-- Elements folded into the single "Stats" row/group when stats_style is "compact".
local _STATS_ELEM_KEYS = { book_days = true, book_time = true, book_remaining = true }

-- The "percent" element is redundant (and hidden from Items/Arrange lists)
-- whenever the progress bar already shows the percentage inline.
local function _percentHiddenByBar(key, bar_style)
    return key == "percent" and bar_style == "with_pct"
end

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

-- ---------------------------------------------------------------------------
-- Author list rendering
-- ---------------------------------------------------------------------------
-- Author strings arrive as a single newline-separated string ("A\nB\nC").
-- _formatAuthors returns nil when there is no usable name (caller hides the
-- row, same policy as description), a single name verbatim, or "Name et al."
-- when there are two or more.
local function _splitAuthors(s)
    local parts = {}
    if not s or s == "" then return parts end
    for piece in (s .. "\n"):gmatch("(.-)\r?\n") do
        local trimmed = piece:match("^%s*(.-)%s*$")
        if trimmed and trimmed ~= "" then
            parts[#parts + 1] = trimmed
        end
    end
    return parts
end

local function _formatAuthors(authors_str)
    local parts = _splitAuthors(authors_str)
    if #parts == 0 then return nil end
    if #parts == 1 then return parts[1] end
    return parts[1] .. _(" et al.")
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
-- _scaledLayoutDims — single source of truth for the gap/font-size formulas
-- shared by build() and getHeight(). Both functions need the exact same
-- scaled values (build() to lay out the real widgets, getHeight() to
-- estimate the reserved height before those widgets exist), so computing
-- them in one place means a future change to a base constant or a
-- clamp/floor value can't silently drift between the two call sites.
-- ---------------------------------------------------------------------------
local function _scaledLayoutDims(scale, lbl_scale)
    return {
        title_fs  = math.max(8, math.floor(_BASE_TITLE_FS  * scale * lbl_scale)),
        author_fs = math.max(8, math.floor(_BASE_AUTHOR_FS * scale * lbl_scale)),
        series_fs = math.max(7, math.floor(_BASE_SERIES_FS * scale * lbl_scale)),
        desc_fs   = math.max(8, math.floor(_BASE_DESC_FS   * scale * lbl_scale)),
        pct_fs    = math.max(8, math.floor(_BASE_PCT_FS    * scale * lbl_scale)),
        stats_fs  = math.max(7, math.floor(_BASE_STATS_FS  * scale * lbl_scale)),

        bar_h          = math.max(1, math.floor(_BASE_BAR_H          * scale)),
        title_gap      = math.max(1, math.floor(_BASE_TITLE_GAP      * scale)),
        author_gap     = math.max(1, math.floor(_BASE_AUTHOR_GAP     * scale)),
        series_gap     = math.max(1, math.floor(_BASE_SERIES_GAP     * scale)),
        desc_gap       = math.max(1, math.floor(_BASE_DESC_GAP       * scale)),
        bar_gap_before = math.max(1, math.floor(_BASE_BAR_GAP_BEFORE * scale)),
        bar_gap_after  = math.max(1, math.floor(_BASE_BAR_GAP_AFTER  * scale)),
        pct_gap        = math.max(1, math.floor(_BASE_PCT_GAP        * scale)),
    }
end

-- Cover width as a fraction of the module's own content width — the single
-- source of truth for base cover sizing, used by every layout in both
-- build() and getHeight(). Keeps the cover proportionate to whatever
-- column width this module ends up in (grid vs single column, portrait
-- vs landscape) instead of a device-pixel constant that ignores it.
local _COVER_W_PCT = 0.30

-- _computeCoverDims(w, thumb_scale, ratio) — base cover pixel size for a
-- module of width `w`. `thumb_scale` is the user's "Cover size" multiplier;
-- callers must pass the RAW value (without landscape_factor folded in),
-- since `w` itself is already the module's landscape-reduced column width
-- whenever lf < 1 — applying lf a second time here would compound it.
-- `ratio` is the cover's height/width aspect ratio, taken from SH.getDims
-- so it stays in sync with the rest of SUI's cover artwork without
-- hard-coding a second aspect constant here.
local function _computeCoverDims(w, thumb_scale, ratio)
    local cover_w = math.max(1, math.floor(w * _COVER_W_PCT * thumb_scale))
    local cover_h = math.max(1, math.floor(cover_w * ratio))
    return cover_w, cover_h
end

-- True when frame or module backdrop (>0) needs outer padding.
local function _hasBox(pfx)
    if SUISettings:isTrue(pfx .. "currently_show_frame") then return true end
    local ok, WP = pcall(require, "features/sui_wallpaper")
    if ok and WP and WP.getModuleBackdropStrength then
        return WP.getModuleBackdropStrength(pfx, "currently") > 0
    end
    return SUISettings:isTrue(pfx .. "currently_solid_bg")
end


-- Clears the entire stats cache. Called from main.lua:onCloseDocument as a
-- fallback when the closed book's md5 could not be resolved; safe since
-- fetchBookStats() re-populates entries on demand.
function M.invalidateCache()
    _bstats_cache = {}
end

-- Removes only the cache entry for the given md5, leaving stats cached for
-- every other book intact. Mirrors module_coverdeck.invalidateCacheForMd5;
-- called from main.lua:onCloseDocument so the closed book's stats are fresh
-- on the next render without discarding the rest of the cache.
function M.invalidateCacheForMd5(md5)
    if md5 then _bstats_cache[md5] = nil end
end

-- Exposed for pre-computation in _buildCtx (sui_homescreen.lua).
-- Mirrors module_coverdeck.fetchBookStatsForCtx.
-- Returns the stats table or nil; does NOT set ctx.db_conn_fatal (no ctx here).
function M.fetchBookStatsForCtx(md5, db_conn, force)
    return fetchBookStats(md5, db_conn, nil, force)
end


-- Empty placeholder when history has no existing books (same pattern as
-- Quick Actions / Featured Collection / Collections).
-- Uses a wrapping TextBoxWidget rather than the single-line TextWidget
-- behind makeColoredText, since this message is long enough to need
-- multiple lines at the module's own width; falls back to a plain
-- TextBoxWidget when there's no wallpaper to composite over, same as
-- the title/description elements in M.build below.
local function _emptyPlaceholder(w, h, has_wallpaper)
    local face = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY)
    local line_h = math.floor(1.3 * face.size + 0.5)
    local args = {
        text      = _("No books to show yet — open a book to see it here."),
        face      = face,
        width     = w - PAD * 2,
        height    = math.max(line_h, h - PAD * 2),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "center",
        fgcolor   = CLR_TEXT_SUB,
    }

    local text_w
    if has_wallpaper then
        local ok_tbx, tbx = pcall(UI.makeAlphaTextBox, args)
        if ok_tbx then
            text_w = tbx
        else
            logger.warn("simpleui: module_currently: makeAlphaTextBox failed, falling back to TextBoxWidget: " .. tostring(tbx))
            text_w = TextBoxWidget:new(args)
        end
    else
        text_w = TextBoxWidget:new(args)
    end

    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
        text_w,
    }
end

-- Builds the module widget: cover on the left, text column on the right.
-- Elements in the text column are rendered in user-configured order.
function M.build(w, ctx)
    Config.applyLabelToggle(M, _("Currently Reading"))
    if not ctx.current_fp then
        return _emptyPlaceholder(w, M.getHeight(ctx), ctx.has_wallpaper)
    end

    local SH = getSH()
    if not SH then
        return _emptyPlaceholder(w, M.getHeight(ctx), ctx.has_wallpaper)
    end

    -- Use pre-read settings bundle from ctx when available (normal HS path).
    -- Falls back to direct reads only when called outside the homescreen.
    -- c.scale/c.thumb_scale/c.lbl_scale (from ctx.cfg) are RAW; apply
    -- ctx.landscape_factor here, on both the cached and fallback path.
    -- thumb_scale is the exception: `w` below is already the module's
    -- landscape-reduced column width (col_w, set by the screen engine), so
    -- the cover-size percentage-of-w calculation must use the RAW value —
    -- multiplying by lf again would apply the landscape reduction twice.
    local c = ctx.cfg and ctx.cfg.currently
    local pfx         = ctx.pfx
    local lf          = ctx.landscape_factor or 1
    local raw_scale   = c and c.scale       or Config.getModuleScale("currently", pfx)
    local scale       = raw_scale * lf
    -- Frame border / solid background — same optional box every other
    -- homescreen module offers (module_heatmap.lua, module_reading_goals.lua):
    -- a border, a filled background, or both, each adding PAD to every edge.
    -- Computed up front so tw0 below already reserves room for the border,
    -- keeping the box's real outer width equal to `w`.
    -- Chrome applied by ModuleChrome on the homescreen.
    local box = { inset_h = 0, inset_v = 0, outer_margin = 0 }
    local raw_thumb_scale = c and c.thumb_scale or Config.getThumbScale("currently", pfx)
    local lbl_scale   = (c and c.lbl_scale   or Config.getItemLabelScale("currently", pfx)) * lf
    local bar_style   = c and c.bar_style   or getBarStyle(pfx)
    local stats_style = c and c.stats_style or getStatsStyle(pfx)
    local layout = (c and c.layout) or getLayout(pfx)
    local show        = c and c.show or {
        title       = _showElem(pfx, "title"),
        author      = _showElem(pfx, "author"),
        series      = _showElem(pfx, "series"),
        description = _showElem(pfx, "description"),
        progress    = _showElem(pfx, "progress"),
        percent     = _showElem(pfx, "percent"),
        days        = _showElem(pfx, "book_days"),
        time        = _showElem(pfx, "book_time"),
        remain      = _showElem(pfx, "book_remaining"),
    }
    -- elem_order: use cached raw value from bundle; resolve lazily.
    local elem_order  = _resolveElemOrder(c and c.elem_order or SUISettings:readSetting(pfx .. ELEM_ORDER_KEY))

    -- Base cover size, as a percentage of the module's own width `w` — see
    -- _computeCoverDims. Used as-is by "default"; "dynamic" grows/shrinks
    -- it further below to match the text column's height.
    -- `ratio` (H/W) is taken from the shared book-cover helpers so this
    -- module's covers keep the same proportions as module_recent/book grid.
    local _cover_ratio = SH.getDims(1.0, 1.0).COVER_H / SH.getDims(1.0, 1.0).COVER_W
    local D = {}
    D.COVER_W, D.COVER_H = _computeCoverDims(w, raw_thumb_scale * raw_scale, _cover_ratio)

    -- Scale gaps and font sizes (layout scale × text scale where applicable).
    -- See _scaledLayoutDims for the shared formulas (also used by getHeight()).
    local LD = _scaledLayoutDims(scale, lbl_scale)
    local title_gap, author_gap, series_gap, desc_gap =
        LD.title_gap, LD.author_gap, LD.series_gap, LD.desc_gap
    local bar_gap_before, bar_gap_after, pct_gap, bar_h =
        LD.bar_gap_before, LD.bar_gap_after, LD.pct_gap, LD.bar_h
    local title_fs, author_fs, series_fs, desc_fs, pct_fs, stats_fs =
        LD.title_fs, LD.author_fs, LD.series_fs, LD.desc_fs, LD.pct_fs, LD.stats_fs

    -- cover_gap has no getHeight() counterpart (getHeight doesn't need the
    -- cover/text spacing), so it stays computed directly here.
    local cover_gap = math.max(0, math.floor(_BASE_COVER_GAP * scale * (getCoverGapPct(pfx) / 100)))

    -- Resolve font faces once so they are not re-created per element.
    local face_title  = Font:getFace(SUIStyle.FACE_REGULAR, title_fs)
    local face_author = Font:getFace(SUIStyle.FACE_REGULAR, author_fs)
    local face_series = Font:getFace(SUIStyle.FACE_REGULAR, series_fs)
    local face_desc   = Font:getFace(SUIStyle.FACE_REGULAR, desc_fs)
    local face_pct    = Font:getFace(SUIStyle.FACE_REGULAR, pct_fs)
    local face_s      = Font:getFace(SUIStyle.FACE_REGULAR, stats_fs)

    -- Use prefetched book data. After onCloseDocument, _cached_books_state is
    -- cleared and prefetchBooks() re-reads the sidecar, so this is always fresh.
    -- NOTE: the actual cover image widget (SH.getBookCover) is fetched further
    -- below, once cover_w/cover_h are resolved to their final (possibly
    -- dynamically-grown) size — fetching it here at D.COVER_W/H would waste a
    -- render at the wrong size whenever dynamic cover sizing changes it.
    local prefetched_entry = ctx.prefetched and ctx.prefetched[ctx.current_fp]
    local bd    = SH.getBookData(ctx.current_fp, prefetched_entry)

    -- Series text — SH.getBookSeries is the single shared source (also used
    -- by the book-grid corner badge), memoized per filepath. Only fetched
    -- when the element is visible, to avoid the BookInfoManager lookup on
    -- every render for users who don't use this element.
    local series_text = ""
    if show.series then
        local sd = SH.getBookSeries(ctx.current_fp)
        if sd and sd.series then
            local idx = tonumber(sd.series_index)
            if idx then
                -- Whole numbers print as "#1"; fractional as "#1.5" (split/
                -- omnibus volumes).
                local idx_text = (idx == math.floor(idx))
                    and tostring(math.floor(idx)) or string.format("%.10g", idx)
                series_text = sd.series .. " #" .. idx_text
            else
                series_text = sd.series
            end
        end
    end

    -- Text column width: full width minus the box's insets (padding plus
    -- any active border), cover, and cover gap. This is the BASE width,
    -- computed from the base cover size (D.COVER_W). When dynamic cover
    -- sizing is enabled, the final width used for the text column may
    -- differ — see the two-pass layout below.
    local tw0 = w - D.COVER_W - cover_gap - box.inset_h

    -- Fetch stats once if any stats element is active.
    local bstats
    if show.days or show.time or show.remain then
        local book_md5 = prefetched_entry and prefetched_entry.partial_md5_checksum
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
    local CLR_PLACEHOLDER = SUIStyle.COLOR.text_dim

    local _CLR_DARK_EFF    = SUIStyle.COLOR.text_primary
    local CLR_TEXT_SUB_EFF = CLR_TEXT_SUB
    local CLR_PH_EFF       = CLR_PLACEHOLDER

    -- Pre-resolve the inline-pct font face once for buildProgressBarWithPct.
    local face_inlinepct = Font:getFace(SUIStyle.FACE_REGULAR,
        math.max(7, math.floor(_BASE_INLINEPCT_FS * scale * lbl_scale)))

    -- Builds the text column (title/author/series/description/progress bar/
    -- stats) at the given width `tw`. Every element inside is either
    -- line-clamped (title, description — fixed height regardless of width)
    -- or single-line/truncated (author, series, stats, progress bar — width
    -- only affects wrapping/truncation, never height). This means the
    -- resulting VerticalGroup's height is independent of `tw`, which is what
    -- makes the two-pass dynamic-cover layout below safe: calling this twice
    -- with different widths always yields the same height, so there is no
    -- risk of an oscillating/convergence loop — at most one extra pass.
    --
    -- `opts` (optional) lets the caller shrink or hide the description —
    -- the only element treated as elastic — to keep the text column from
    -- growing past the cover in the "default" layout (see the anchoring
    -- logic below, right after the first buildMetaColumn call):
    --   opts.desc_max_lines     — overrides DESC_MAX_LINES (0 hides it)
    --   opts.suppress_description — omit the description entirely, used to
    --                                measure every OTHER element's height
    --                                (i.e. the fixed budget the description
    --                                must fit whatever is left over from)
    local function buildMetaColumn(tw, opts)
        local desc_max_lines    = (opts and opts.desc_max_lines) or DESC_MAX_LINES
        local suppress_desc     = opts and opts.suppress_description
        local meta = VerticalGroup:new{ align = "left" }
        local _cr_update_funcs  = {}
        -- Closures that only need bd (no bstats) — progress bar and percent.
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

        elseif elem == "author" and show.author then
            local author_text = _formatAuthors(bd.authors)
            if author_text then
                gap_before(author_gap)
                meta[#meta+1] = UI.makeColoredText{
                    text            = author_text,
                    face            = face_author,
                    fgcolor         = CLR_TEXT_SUB_EFF,
                    width           = tw,
                    max_width       = tw,
                    truncation_char = "…",
                }
                meta_has_content = true
            end

        elseif elem == "series" and show.series and series_text ~= "" then
            gap_before(series_gap)
            meta[#meta+1] = UI.makeColoredText{
                text            = series_text,
                face            = face_series,
                fgcolor         = CLR_TEXT_SUB_EFF,
                width           = tw,
                max_width       = tw,
                truncation_char = "…",  -- ellipsis
            }
            meta_has_content = true

        elseif elem == "description" and show.description and bd.description and bd.description ~= ""
               and not suppress_desc and desc_max_lines > 0 then
            gap_before(desc_gap)
            -- TextBoxWidget has no "max_lines" property — it only clamps
            -- via an explicit pixel `height` (see title element above for
            -- the same pattern). height_overflow_show_ellipsis only takes
            -- effect when `height` is set; leaving height nil would make
            -- the widget grow to fit the full text instead of clamping.
            local desc_tbw_line_h = math.floor(1.3 * face_desc.size + 0.5)
            local desc_args = {
                text      = bd.description,
                face      = face_desc,
                width     = tw,
                height    = desc_tbw_line_h * desc_max_lines,
                height_adjust = true,
                height_overflow_show_ellipsis = true,
                fgcolor   = CLR_TEXT_SUB_EFF,
            }

            local desc_w
            if ctx.has_wallpaper then
                local ok_tbx, tbx = pcall(UI.makeAlphaTextBox, desc_args)
                if ok_tbx then
                    desc_w = tbx
                else
                    logger.warn("simpleui: module_currently: makeAlphaTextBox failed, falling back to TextBoxWidget: " .. tostring(tbx))
                    desc_w = TextBoxWidget:new(desc_args)
                end
            else
                desc_w = TextBoxWidget:new(desc_args)
            end

            meta[#meta+1] = desc_w
            meta_has_content = true

        elseif elem == "progress" and show.progress then
            gap_before(bar_gap_before)
            if bar_style == "with_pct" then
                -- The bar is wrapped in a container whose single child is
                -- replaced by _update_bar, so a stats refresh only patches
                -- the bar's pixels without touching the surrounding layout
                -- or allocating new VerticalGroup nodes.
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
            -- makeColoredText supports setText, so a stats refresh updates
            -- just the string without rebuilding the widget tree.
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
            -- Shows a placeholder when stats are not yet available (no DB,
            -- no md5, or zero days recorded) so the item is always visible
            -- once activated, giving the user clear feedback that it exists.
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
            -- Placeholder when total time is not yet recorded.
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
            -- Symmetric guard mirroring book_days / book_time.
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

                -- Rendered as a single TextWidget (not one widget per part +
                -- separators) so the whole row can be capped to `tw` and
                -- truncated with an ellipsis instead of stretching the
                -- layout when the joined parts run long.
                local function _composeText(nb, nd)
                    local secs_left
                    local avg_t = (nb and nb.avg_time and nb.avg_time > 0) and nb.avg_time or nd.avg_time
                    if avg_t and avg_t > 0 and nd.pages and nd.pages > 0 then
                        local sl = math.floor(avg_t * nd.pages * (1 - (nd.percent or 0)))
                        if sl > 0 then secs_left = sl end
                    end

                    local parts = {}
                    for _i, e in ipairs(elem_order) do
                        if e == "book_time" and show.time and nb and nb.total_secs > 0 then
                            parts[#parts+1] = string.format(_("%s read"), fmtTime(nb.total_secs))
                        elseif e == "book_remaining" and show.remain and secs_left then
                            parts[#parts+1] = string.format(_("%s left"), fmtTime(secs_left))
                        elseif e == "book_days" and show.days and nb and nb.days > 0 then
                            parts[#parts+1] = string.format(N_("%d day of reading", "%d days of reading", nb.days), nb.days)
                        end
                    end

                    if #parts > 0 then
                        return table.concat(parts, " · "), CLR_TEXT_SUB_EFF, true
                    end

                    local any_active = (show.days or show.time or show.remain)
                    if any_active then
                        return string.format(_("%s read"), "—"), CLR_PH_EFF, true
                    end
                    return "", CLR_PH_EFF, false
                end

                local text0, fg0, has_content0 = _composeText(bstats, bd)
                local stats_w = UI.makeColoredText{
                    text                    = text0,
                    face                    = face_s,
                    fgcolor                 = fg0,
                    max_width               = tw,
                    truncate_with_ellipsis  = true,
                }

                local function _update(nb, nd)
                    local text, fg = _composeText(nb, nd)
                    _updateColoredText(stats_w, text, fg)
                end
                table.insert(_cr_update_funcs, _update)

                if has_content0 then
                    gap_before(pct_gap)
                    meta[#meta+1] = stats_w
                    meta_has_content = true
                end
            end
        end
        end -- for _i, elem in ipairs(elem_order)

        return meta, _cr_update_funcs, _cr_bd_only_funcs
    end


    -- Both layouts share the exact same single-column build path (see
    -- buildMetaColumn above); the only difference is whether the cover
    -- additionally grows to match the text column, below.
    local cover_w, cover_h = D.COVER_W, D.COVER_H
    local tw               = tw0

    -- Pass 1: build at the base width to measure the text column's natural
    -- height. Measuring by asking the VerticalGroup itself (rather than
    -- summing known element heights) is the only reliable way, since
    -- TextWidget line heights depend on font metrics, not just the font
    -- size number.
    local meta, _cr_update_funcs, _cr_bd_only_funcs = buildMetaColumn(tw0)
    local meta_h = meta:getSize().h

    local dynamic_cover = (layout == "dynamic")

    if dynamic_cover and meta_h > 0 then
        -- Grow (or shrink) the cover so its height matches the text
        -- column's height, preserving the cover's aspect ratio, then apply
        -- the "Cover size" (raw_thumb_scale) setting as a multiplier ON TOP of
        -- that dynamic height. This makes the Cover size stepper still do
        -- something useful while Dynamic Cover Size is on: instead of being
        -- ignored (thumb_scale used to only affect D.COVER_W/H, which this
        -- branch overwrote entirely), each step grows/shrinks the cover
        -- relative to whatever size the dynamic layout would otherwise pick
        -- at that moment. cover_gap is untouched — only the cover's own box
        -- changes size.
        --
        -- IMPORTANT (landscape): meta_h is the measured height of the text
        -- column, which was already built using `scale`/`lbl_scale` — both
        -- of which have `lf` (landscape_factor) folded in. Multiplying
        -- meta_h by the lf-inclusive `thumb_scale` would apply lf a SECOND
        -- time (effectively lf² instead of lf), collapsing the dynamic
        -- cover far more than intended in landscape. Use the RAW thumb
        -- scale (the user's Cover size % on its own) instead — same "RAW
        -- getters, value already narrowed upstream" pattern documented in
        -- sui_book_grid.lua's build() for the same reason.
        --
        -- A floor is applied so the cover can never shrink below its base
        -- 100%-cover-size (the size used when Dynamic Cover Size is off and
        -- Cover size = 100%), no matter how little vertical space the text
        -- column ends up needing. min_cover_h uses the same percentage-of-`w`
        -- formula as the base size, with thumb_scale pinned to 1.0 (100%).
        local ratio        = D.COVER_W / D.COVER_H  -- scale-invariant aspect ratio
        local _, min_cover_h = _computeCoverDims(w, 1.0, _cover_ratio)
        local new_cover_h  = math.max(min_cover_h, math.floor(meta_h * raw_thumb_scale))
        local new_cover_w  = math.max(1, math.floor(new_cover_h * ratio))
        if new_cover_w ~= cover_w or new_cover_h ~= cover_h then
            cover_w, cover_h = new_cover_w, new_cover_h
            tw = math.max(1, w - cover_w - cover_gap - box.inset_h)
            -- Pass 2: rebuild the text column at the corrected width now
            -- that the cover (and thus the space left for text) changed
            -- size. Height cannot change between passes (see comment on
            -- buildMetaColumn above), so meta_h from pass 1 stays valid —
            -- no further passes or re-measuring needed.
            meta, _cr_update_funcs, _cr_bd_only_funcs = buildMetaColumn(tw)
        end

    elseif not dynamic_cover and meta_h > cover_h then
        -- Anchor the text column to the cover's height in "default": the
        -- cover's own size is authoritative and the text column must
        -- never grow taller than it. The description is the sole elastic
        -- element (title/author/series/progress/stats keep their natural
        -- size); it shrinks to whatever room is left, or is omitted
        -- entirely if there isn't enough room for even one line.
        if show.description and bd.description and bd.description ~= "" then
            -- Measure every OTHER element's height first (description
            -- suppressed), so we know exactly how much room is left for it.
            local other_h = buildMetaColumn(tw0, { suppress_description = true }):getSize().h
            local breath  = math.max(1, desc_gap)
            local available = cover_h - other_h - breath
            local desc_line_h = math.floor(1.3 * face_desc.size + 0.5)
            local new_desc_lines = (available >= face_desc.size)
                and math.max(1, math.floor(available / desc_line_h)) or 0
            meta, _cr_update_funcs, _cr_bd_only_funcs =
                buildMetaColumn(tw0, { desc_max_lines = new_desc_lines })
            meta_h = meta:getSize().h
        end
        -- If there's no description to shrink (or it's disabled/empty),
        -- meta_h simply stays as measured — the module falls back to
        -- growing past the cover rather than clipping fixed-size content.
    end

    local content_h = math.max(cover_h, meta_h)

    -- Fetch the actual cover image at its final (possibly dynamically-grown
    -- or -shrunk) size. SH.getBookCover's underlying cache keeps the
    -- largest size requested this session per book and resizes to fit at
    -- paint time, so requesting a larger size here than a previous render
    -- simply grows the cached bitmap — no special-casing needed.
    local cover = SH.getBookCover(ctx.current_fp, cover_w, cover_h)
                  or SH.coverPlaceholder(bd.title, bd.authors, cover_w, cover_h)

    -- Optional progress pentagon on the cover (same primitive as Coverdeck
    -- and the book-grid modules). Applied after the cover is resolved so
    -- late loads in updateCovers can re-apply it the same way.
    if showProgressBadge(pfx) and SH.applyProgressBadge then
        local color = getProgressBadgeColorOverride(pfx)
        cover = SH.applyProgressBadge(cover, bd, cover_w, cover_h, color)
    end

    local full_h = content_h

    -- Layout: cover on left, text column on right.
    -- The cover is wrapped in a CenterContainer sized to content_h so it
    -- stays vertically centred when the text column is taller than the cover.
    local cover_frame = FrameContainer:new{
            bordersize    = 0, padding = 0,
            padding_right = cover_gap,
            cover,
        }
    local cover_centered = CenterContainer:new{
        dimen = Geom:new{ w = cover_w + cover_gap, h = content_h },
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
        [1] = row,
    }
    tappable.ges_events = {
        TapBook = {
            GestureRange:new{
                ges   = "tap",
                range = function() return tappable.dimen end,
            },
        },
    }
    -- align/stretch dropped: SH.getBookCover is stretch-only now.
    tappable._cover_slots = {
        { container = cover_frame, idx = 1, fp = ctx.current_fp,
          w = cover_w, h = cover_h },
    }
    function tappable:onTapBook()
        if self._open_fn then self._open_fn(self._fp) end
        return true
    end

    -- Two long-press zones, mirroring module_coverdeck.lua's onHoldDeck
    -- centre-cover-vs-side-cover split (cover-region vs text-region here,
    -- since there's a single cover rather than a carousel to split
    -- against): holding the COVER respects "Long press on cover" →
    -- Config.getCoverHoldMode as before; holding the title/author/stats
    -- text column always falls through to the module wrapper's
    -- HoldMod/HoldModRelease (settings screen), same as holding a side
    -- cover in coverdeck does today. Registered any time book_dialog mode
    -- is on for this module — previously onHoldBook consumed the ENTIRE
    -- tappable unconditionally, so a hold on the text column also opened
    -- the book dialog instead of settings.
    if Config.getCoverHoldMode("currently", ctx.pfx) == "book_dialog" then
        local _cover_x0 = PAD
        local _cover_x1 = PAD + cover_w + cover_gap
        tappable.ges_events.HoldBook = {
            GestureRange:new{ ges = "hold", range = function() return tappable.dimen end },
        }
        tappable.ges_events.HoldBookRelease = {
            GestureRange:new{ ges = "hold_release", range = function() return tappable.dimen end },
        }
        function tappable:onHoldBook(_, ges)
            local x = ges.pos.x - self.dimen.x
            self._hold_on_cover = (x >= _cover_x0 and x < _cover_x1)
            -- Only swallow the gesture (and thus block the settings-menu
            -- fallback) when it actually lands on the cover.
            return self._hold_on_cover or nil
        end
        function tappable:onHoldBookRelease()
            if self._hold_on_cover and self._fp and ctx.hold_fn then
                ctx.hold_fn(self._fp, "currently")
            end
            return self._hold_on_cover or nil
        end
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

    local pfx = (_ctx and _ctx.pfx) or ""
    local show_badge = showProgressBadge(pfx)
    local all_done = true
    for _, slot in ipairs(tappable._cover_slots) do
        local new_cover = SH.getBookCover(slot.fp, slot.w, slot.h)
        if new_cover then
            if show_badge and SH.applyProgressBadge then
                local bd = SH.getBookData(slot.fp, _ctx and _ctx.prefetched and _ctx.prefetched[slot.fp])
                local color = getProgressBadgeColorOverride(pfx)
                new_cover = SH.applyProgressBadge(new_cover, bd, slot.w, slot.h, color)
            end
            slot.container[slot.idx] = new_cover
        elseif not Config.isCoverMissing(slot.fp) then
            all_done = false
        end
    end
    return all_done
end

-- Returns the total pixel height of the module including the section label.
-- Measures real font line heights via Font:getFace() so the estimate matches
-- what build() actually renders.  This prevents the homescreen from
-- under-allocating space and causing overlap with the module below.
function M.getHeight(_ctx)
    local SH = getSH()
    if not SH then return Config.getScaledLabelH() end
    local pfx = _ctx and _ctx.pfx
    -- Use pre-read settings bundle from ctx when available (normal HS path).
    -- c.scale/c.thumb_scale/c.lbl_scale (from ctx.cfg) are RAW; apply
    -- ctx.landscape_factor here, on both the cached and fallback path.
    -- thumb_scale is the exception: w_estimate below (ctx.col_w) is already
    -- the module's landscape-reduced column width, so the cover-size
    -- percentage-of-w calculation must use the RAW value — multiplying by
    -- lf again would apply the landscape reduction twice.
    local c           = _ctx and _ctx.cfg and _ctx.cfg.currently
    local lf          = (_ctx and _ctx.landscape_factor) or (UI.isLandscape() and UI.getLandscapeFactor() or 1)
    local raw_scale   = c and c.scale       or Config.getModuleScale("currently", pfx)
    local scale       = raw_scale * lf
    local lbl_scale   = (c and c.lbl_scale   or Config.getItemLabelScale("currently", pfx)) * lf
    local raw_thumb_scale = c and c.thumb_scale or Config.getThumbScale("currently", pfx)

    local layout = (c and c.layout) or getLayout(pfx)

    -- Base cover size, mirroring build()'s _computeCoverDims call exactly.
    -- getHeight() has no module width of its own (see moduleregistry's
    -- contract, M.getHeight(ctx)), so it estimates it the same way
    -- module_clock/module_coverdeck/module_quick_actions already do.
    local w_estimate = (_ctx and (_ctx.col_w or _ctx.inner_w))
                        or (Screen:getWidth() - UI.SIDE_PAD * 2)
    local _cover_ratio = SH.getDims(1.0, 1.0).COVER_H / SH.getDims(1.0, 1.0).COVER_W
    local cover_w, cover_h = _computeCoverDims(w_estimate, raw_thumb_scale * raw_scale, _cover_ratio)
    local D = { COVER_W = cover_w, COVER_H = cover_h }

    local stats_style = c and c.stats_style or getStatsStyle(pfx)
    local bar_style    = c and c.bar_style   or getBarStyle(pfx)

    local show = c and c.show or {
        title       = _showElem(pfx, "title"),
        author      = _showElem(pfx, "author"),
        series      = _showElem(pfx, "series"),
        description = _showElem(pfx, "description"),
        progress    = _showElem(pfx, "progress"),
        percent     = _showElem(pfx, "percent"),
        days        = _showElem(pfx, "book_days"),
        time        = _showElem(pfx, "book_time"),
        remain      = _showElem(pfx, "book_remaining"),
    }

    -- Measure real line heights using the same font faces as build().
    -- See _scaledLayoutDims for the shared formulas (also used by build()).
    local LD = _scaledLayoutDims(scale, lbl_scale)
    local title_fs, author_fs, series_fs, desc_fs, pct_fs, stats_fs =
        LD.title_fs, LD.author_fs, LD.series_fs, LD.desc_fs, LD.pct_fs, LD.stats_fs
    local bar_h, bar_gap_b, bar_gap_a, title_gap, author_gap, series_gap, desc_gap, pct_gap =
        LD.bar_h, LD.bar_gap_before, LD.bar_gap_after, LD.title_gap, LD.author_gap, LD.series_gap, LD.desc_gap, LD.pct_gap

    -- Ask the font engine for the real line height (includes ascender+descender).
    -- face.size is just the font's point size (a plain number); the actual
    -- freetype face object is face.ftsize, whose :getHeightAndAscender() is
    -- the real API (see how ui/widget/textwidget.lua's own updateSize()
    -- measures line height).
    local function faceH(fs)
        local ok, face = pcall(Font.getFace, Font, "smallinfofont", fs)
        if ok and face and face.ftsize then
            local ok2, h = pcall(function() return face.ftsize:getHeightAndAscender() end)
            if ok2 and h then return math.ceil(h) end
        end
        -- fallback: font size * 1.8 approximates typical line height
        return math.ceil(fs * 1.8)
    end

    local title_lh  = faceH(title_fs)
    local author_lh = faceH(author_fs)
    local series_lh = faceH(series_fs)
    local desc_lh   = faceH(desc_fs)
    local pct_lh    = faceH(pct_fs)
    local stats_lh  = faceH(stats_fs)

    -- Build the element list using real (measured) line heights, mirroring
    -- build()'s own gap_before ordering. is_desc tags the description entry
    -- so its contribution can be excluded below for non-dynamic layouts
    -- (where build() treats description as elastic, never as something
    -- that grows the module past the cover — see the anchoring branch in
    -- build()).
    local elems = {}
    if show.title then
        elems[#elems+1] = { title_gap, title_lh * 2 }
    end
    if show.author then
        elems[#elems+1] = { author_gap, author_lh }
    end
    if show.series then
        -- Conservative: reserve one line regardless of whether the current
        -- book actually belongs to a series (same policy as author above).
        elems[#elems+1] = { series_gap, series_lh }
    end
    if show.description then
        -- Conservative: reserve full DESC_MAX_LINES height regardless of
        -- whether the current book actually has a description, same policy
        -- as the other elements in this function (avoids under-allocating
        -- and overlapping the module below). Only actually counted toward
        -- content_h for "dynamic" — see is_desc below.
        elems[#elems+1] = { desc_gap, desc_lh * DESC_MAX_LINES, is_desc = true }
    end
    if show.progress then
        elems[#elems+1] = { bar_gap_b, bar_h + bar_gap_a }
    end
    if show.percent and bar_style ~= "with_pct" then
        elems[#elems+1] = { pct_gap, pct_lh }
    end
    -- Stats: conservative — always reserve height for every active stats item
    -- (placeholder rows are rendered when data is absent, so height is always
    -- consumed; under-allocating here would cause overlap below the module).
    -- Exception: book_remaining is suppressed only when the book is 100% done,
    -- but getHeight has no percent data, so we keep the conservative assumption.
    local n_stats = (show.days and 1 or 0) + (show.time and 1 or 0) + (show.remain and 1 or 0)
    if n_stats > 0 then
        local lines = stats_style == "compact" and 1 or n_stats
        for _ = 1, lines do
            elems[#elems+1] = { pct_gap, stats_lh }
        end
    end

    -- Sums the element list; skip_desc=true excludes the description entry
    -- (and its leading gap), giving the height of every OTHER element only.
    local function sumH(skip_desc)
        local h, first = 0, true
        for _, e in ipairs(elems) do
            if not (skip_desc and e.is_desc) then
                if not first then h = h + e[1] end
                h = h + e[2]
                first = false
            end
        end
        return h
    end
    local text_h         = sumH(false)
    local text_h_no_desc = sumH(true)

    local dynamic_cover = (layout == "dynamic")

    -- When dynamic cover sizing is on, build() grows the cover to match the
    -- text column, then applies the Cover size (raw thumb_scale, WITHOUT lf
    -- — see build()'s comment on why lf must not be applied twice) multiplier
    -- on top and floors the result at the base 100%-cover-size. Mirror that
    -- same computation here so the reserved height never falls short of what
    -- build() will actually render (which would overlap the next module).
    -- text_h is already a conservative UPPER BOUND on the real meta_h (see
    -- comments above — it reserves full stats rows etc. regardless of
    -- whether this particular book has data), so this stays a safe
    -- over-estimate, never an under-estimate.
    --
    -- The "default" layout instead ANCHORS the text column to the
    -- cover's height: build() shrinks or hides the
    -- description to fit, so the module's real height is never taller than
    -- max(cover_h, everything-except-description). Using text_h (which
    -- still includes the description's full reserved height) here would
    -- over-allocate space that build() will never actually use — text_h_no_desc
    -- mirrors what build() actually anchors against.
    local content_h
    if dynamic_cover then
        local _, min_cover_h = _computeCoverDims(w_estimate, 1.0, _cover_ratio)
        local dyn_cover_h = math.max(min_cover_h, math.floor(text_h * raw_thumb_scale))
        content_h = math.max(text_h, dyn_cover_h)
    else
        content_h = math.max(D.COVER_H, text_h_no_desc)
    end
    if _hasBox(pfx) then
        -- Mirrors build()'s FrameContainer: bordersize is drawn outside the
        -- padding, so the border itself (not just the padding) grows the
        -- real widget by border_sz * 2 pixels whenever the frame is on.
        content_h = content_h + PAD * 2
        if SUISettings:isTrue(pfx .. "currently_show_frame") then
            content_h = content_h + SUIStyle.BORDER_SZ * 2
        end
    end
    return Config.getScaledLabelH() + content_h
end


-- Builds one radio-button item for a persisted string-valued setting, e.g.
-- one option of "Progress bar style" or "Stats layout". Used to avoid
-- repeating the same checked_func/callback shape for every option of every
-- such setting.
local function _makeStyleRadioItem(text, key, value, get_current, refresh)
    return {
        text           = text,
        radio          = true,
        keep_menu_open = true,
        checked_func   = function() return get_current() == value end,
        callback       = function()
            SUISettings:saveSetting(key, value)
            refresh()
        end,
    }
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
        text_func = function() return _lc("Cover Size") end,
        title     = _lc("Cover Size"),
        info      = _lc("Scale for the cover thumbnail only.\n100% is the default size.\nWhen Dynamic Cover Size is on, this scales the cover relative to its current dynamic size instead, and the cover never shrinks below its 100% size."),
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

-- "Default" sizes the cover as a percentage of the module's width (see
-- _COVER_W_PCT) and anchors the text column to the cover's height,
-- shrinking the description if needed. "Dynamic" additionally grows or
-- shrinks the cover to match the text column's height.
local function _makeLayoutItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return {
        text           = _lc("Layout"),
        separator      = true,
        sub_item_table = {
            _makeStyleRadioItem(_lc("Default"), pfx .. LAYOUT_KEY, "default",
                function() return getLayout(pfx) end, ctx_menu.refresh),
            {
                text           = _lc("Dynamic"),
                radio          = true,
                keep_menu_open = true,
                checked_func   = function() return getLayout(pfx) == "dynamic" end,
                callback       = function()
                    SUISettings:saveSetting(pfx .. LAYOUT_KEY, "dynamic")
                    ctx_menu.refresh()
                end,
                help_text = _lc("Grows or shrinks the cover so its height always matches the text column, keeping the cover's proportions.\nThe spacing between cover and text stays as set above.\nThe Cover size setting still applies on top of this, and the cover never shrinks below its 100% size."),
            },
        },
    }
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
                    if _percentHiddenByBar(key, bar_style) then
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
                    if _percentHiddenByBar(key, bar_style) then
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
                local SUIWindow = require("engines/sui_window")
                return SUIWindow.ArrangeList{ inner_w = ctx.inner_w, items = sort_items, on_change = on_save }
            end or nil,
        },
        -- Visibility toggles (alphabetical order).
        toggle_item("Author",          "author"),
        toggle_item("Days of reading", "book_days"),
        toggle_item("Description",     "description"),
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
        toggle_item("Series",         "series"),
        toggle_item("Time read",      "book_time"),
        toggle_item("Time remaining", "book_remaining"),
        toggle_item("Title",          "title"),
    }

    local items_entry = {
            text           = _lc("Items"),
            sub_item_table = items_submenu,
            sui_build = ctx_menu.is_sui and function(ctx, _item)
                local SUIWindow = require("engines/sui_window")
                return SUIWindow.ListRow{
                    title        = _lc("Items"),
                    subtitle     = function()
                        local names = {}
                        local bar_style = getBarStyle(pfx)
                        local is_compact = getStatsStyle(pfx) == "compact"
                        local stats_added = false
                        for _, key in ipairs(_getElemOrder(pfx)) do
                            if _percentHiddenByBar(key, bar_style) then
                                -- skip
                            elseif _showElem(pfx, key) then
                                if is_compact and (_STATS_ELEM_KEYS[key]) then
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
                                    if _percentHiddenByBar(key, bar_style) then
                                        -- skip
                                    elseif not _showElem(pfx, key) then return true end
                                end
                                return false
                            end,
                            footer_action = function(ctx2)
                                local bar_style = getBarStyle(pfx)
                                local picker_items = {}
                                for _, key in ipairs(_getElemOrder(pfx)) do
                                    if _percentHiddenByBar(key, bar_style) then
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
                                            local SUIWindow = require("engines/sui_window")
                                            local is_compact = getStatsStyle(pfx) == "compact"
                                            local function make_sort_items()
                                                local t = {}
                                                local stats_added = false
                                                local bar_style = getBarStyle(pfx)
                                                for _, key in ipairs(_getElemOrder(pfx)) do
                                                    if _percentHiddenByBar(key, bar_style) then
                                                        -- skip
                                                    elseif _showElem(pfx, key) then
                                                        if is_compact and (_STATS_ELEM_KEYS[key]) then
                                                            if not stats_added then
                                                                t[#t + 1] = {
                                                                    text = _lc("Stats"),
                                                                    subtitle = function()
                                                                        local names = {}
                                                                        for _, k in ipairs(_getElemOrder(pfx)) do
                                                                            if _showElem(pfx, k) and (_STATS_ELEM_KEYS[k]) then
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
                                                    if _showElem(pfx, k) and (_STATS_ELEM_KEYS[k]) then
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
                                                                            local SUIWindow2 = require("engines/sui_window")
                                                                            local function make_sub_items()
                                                                                local st = {}
                                                                                for _, k in ipairs(_getElemOrder(pfx)) do
                                                                                    if _showElem(pfx, k) and (_STATS_ELEM_KEYS[k]) then
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
                                                                                    if _showElem(pfx, k) and (_STATS_ELEM_KEYS[k]) then
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
    }

    local size_entry = {
            text_func      = function() return _lc("Size") end,
            sub_item_table = {
                _makeScaleItem(ctx_menu),
                _makeTextScaleItem(ctx_menu),
                thumb,
                gap_item,
            },
    }

    local appearance_entry = {
            text_func      = function() return _lc("Appearance") end,
            separator      = true,
            sub_item_table = {
                Config.makeLabelToggleItem("currently", _("Currently Reading"), refresh, _lc),
                                            },
    }

    local progress_badge_group = {
        {
            text           = _lc("Progress Badge"),
            checked_func   = function() return showProgressBadge(pfx) end,
            keep_menu_open = true,
            callback       = function()
                SUISettings:saveSetting(pfx .. SETTING_SHOW_PROGRESS_BADGE, not showProgressBadge(pfx))
                refresh()
            end,
        },
        Config.makeRadioSubmenuItem{
            text         = _lc("Progress Badge Color"),
            enabled_func = function() return showProgressBadge(pfx) end,
            options      = {
                { value = nil,     label = _lc("Follow Library") },
                { value = "dark",  label = _lc("Dark") },
                { value = "light", label = _lc("Light") },
            },
            get          = function() return getProgressBadgeColorOverride(pfx) end,
            set          = function(v) setProgressBadgeColor(pfx, v) end,
            refresh      = refresh,
        },
    }

    local progress_stats_entry = {
            text_func      = function() return _lc("Progress and Stats") end,
            sub_item_table = {
                {
                    text = _lc("Progress bar style"),
                    sub_item_table = {
                        _makeStyleRadioItem(_lc("Simple"), pfx .. BAR_STYLE_KEY, "simple",
                            function() return getBarStyle(pfx) end, refresh),
                        _makeStyleRadioItem(_lc("With percentage"), pfx .. BAR_STYLE_KEY, "with_pct",
                            function() return getBarStyle(pfx) end, refresh),
                    },
                },
                {
                    text = _lc("Stats layout"),
                    sub_item_table = {
                        _makeStyleRadioItem(_lc("Default"), pfx .. STATS_STYLE_KEY, "default",
                            function() return getStatsStyle(pfx) end, refresh),
                        _makeStyleRadioItem(_lc("Compact"), pfx .. STATS_STYLE_KEY, "compact",
                            function() return getStatsStyle(pfx) end, refresh),
                    },
                },
                {
                    text_func  = function() return _lc("Progress Badge") end,
                    value_func = function()
                        return showProgressBadge(pfx) and _lc("On") or _lc("Off")
                    end,
                    sub_item_table = progress_badge_group,
                },
            },
    }

    local cover_hold_entry = Config.makeCoverHoldModeItem{
            mod_id  = "currently",
            pfx     = pfx,
            refresh = refresh,
            _lc     = _lc,
    }

    local update_stats_entry = {
            text           = _lc("Update Stats Now"),
            separator      = true,
            keep_menu_open = true,
            callback       = function()
                local SP = package.loaded["modules/module_stats_provider"]
                if SP and SP.invalidate then SP.invalidate() end
                local SH = package.loaded["modules/module_books_shared"]
                if SH and SH.invalidateSidecarCache then SH.invalidateSidecarCache() end
                local MC = package.loaded["modules/module_currently"]
                if MC and MC.invalidateCache then MC.invalidateCache() end
                local MCD = package.loaded["modules/module_coverdeck"]
                if MCD and MCD.invalidateCache then MCD.invalidateCache() end
                
                local ScreenEngine = package.loaded["engines/sui_screen_engine"]
                if ScreenEngine and ScreenEngine.invalidateAllCfgAndRefresh then
                    ScreenEngine.invalidateAllCfgAndRefresh(true)
                end
                if ctx_menu and type(ctx_menu.refresh) == "function" then ctx_menu.refresh() elseif refresh then refresh() end
                UI.Notify.toast(_lc("Stats updated successfully."), 2)
            end,
    }

    local menu = {
        _makeLayoutItem(ctx_menu),
        items_entry,
        size_entry,
        appearance_entry,
        progress_stats_entry,
    }
    menu[#menu+1] = cover_hold_entry
    menu[#menu+1] = update_stats_entry
    return menu
end

function M.updateStats(widget, ctx)
    local actual_widget = (widget._cr_update_funcs) and widget
                          or (widget[1] and widget[1]._cr_update_funcs and widget[1])
    if not actual_widget or not actual_widget._cr_update_funcs then return false end
    
    local fp = actual_widget._fp
    if not fp then return false end

    -- The widget only carries data for the book it was built with (_fp).
    -- If ctx.current_fp now points to a DIFFERENT book — e.g. the user
    -- closed a book that wasn't already showing in "Currently Reading" —
    -- patching stats in-place would silently refresh the WRONG book's
    -- numbers while leaving the old book's cover/title on screen. Force a
    -- full rebuild (return false) so module_currently.build() runs again
    -- with the new ctx.current_fp and replaces the widget entirely,
    -- mirroring the identity check module_recent.updateStats() already
    -- does for its own fp list.
    if ctx.current_fp ~= fp then return false end

    -- Progress badge is composited into the cover widget tree at build time.
    -- Percent/status changes on the badge require a full rebuild.
    local pfx = (ctx and ctx.pfx) or ""
    if showProgressBadge(pfx) then return false end

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
        -- Also update bd-only widgets (progress bar, percent) in the same pass.
        if actual_widget._cr_bd_only_funcs then
            for _, fn in ipairs(actual_widget._cr_bd_only_funcs) do
                fn(nil, bd)
            end
        end
    elseif actual_widget._cr_bd_only_funcs then
        -- Progress bar and percent only need bd (no bstats).
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