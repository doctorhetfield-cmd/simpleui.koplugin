-- module_coverdeck.lua
-- Displays recent or TBR books as a cover-flow carousel.

local Blitbuffer       = require("ffi/blitbuffer")
local BD               = require("ui/bidi")
local Device           = require("device")
local Font             = require("ui/font")
local CenterContainer  = require("ui/widget/container/centercontainer")
local FrameContainer   = require("ui/widget/container/framecontainer")
local Geom             = require("ui/geometry")
local GestureRange     = require("ui/gesturerange")
local InputContainer   = require("ui/widget/container/inputcontainer")
local OverlapGroup     = require("ui/widget/overlapgroup")
local TextBoxWidget    = require("ui/widget/textboxwidget")
local VerticalGroup    = require("ui/widget/verticalgroup")
local Screen           = Device.screen
local _ = require("infra/sui_i18n").translate
local N_ = require("infra/sui_i18n").ngettext
local logger         = require("logger")

local Config       = require("infra/sui_config")
local UI           = require("infra/sui_core")
local SUISettings  = require("infra/sui_store")
local SUIStyle     = require("features/sui_style")
local PAD          = UI.PAD
local PAD2         = UI.PAD2
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local MAX_RECENT_FPS   = 10
local MAX_SEC_PER_PAGE = 120  -- matches KOReader statistics query cap
local BSTATS_CACHE_MAX = 20   -- max md5 entries kept in the stats LRU cache
local DESC_LINES       = 3    -- fixed line count for the description block

-- ---------------------------------------------------------------------------
-- Base carousel size, expressed as a percentage of inner_w rather than a
-- fixed pixel size: 100% = fitted to a reference full-width single column,
-- so narrower columns (multi-column Custom Screens, landscape spread)
-- scale down proportionally.
-- ---------------------------------------------------------------------------
local _REF_INNER_W   = Screen:getWidth() - UI.SIDE_PAD * 2 - PAD * 2
local _CENTER_W_PCT  = Screen:scaleBySize(140) / _REF_INNER_W
local _CENTER_W_MIN  = Screen:scaleBySize(60)  -- floor so covers never collapse to unreadable size

-- ---------------------------------------------------------------------------
-- Carousel label truncation
-- ---------------------------------------------------------------------------
-- Title/author text is constrained to covers_block_w (full carousel
-- footprint including side peeks). Stats use a separate budget (95% of
-- the module page width) so the line can run wider than the covers.
-- build() reruns on every carousel swipe (see
-- ScreenWidget:_refreshBookModSlot), so this truncates by an estimated
-- character budget rather than TextWidget's max_width +
-- truncate_with_ellipsis, which remeasures glyph-by-glyph against the
-- font on every call. Counts Unicode codepoints, not bytes, so
-- CJK/Arabic text truncates correctly.
local _AVG_CHAR_WIDTH_RATIO = 0.55  -- rough glyph-advance-to-font-size ratio

local function truncateToWidth(s, face, max_px)
    if not s or s == "" then return s end
    local max_chars = math.max(1, math.floor(max_px / (face.size * _AVG_CHAR_WIDTH_RATIO)))
    local count = 0
    local i = 1
    local last_safe = 0  -- byte offset of the last complete codepoint boundary
    while i <= #s do
        local byte = s:byte(i)
        local char_len
        if     byte >= 240 then char_len = 4
        elseif byte >= 224 then char_len = 3
        elseif byte >= 192 then char_len = 2
        else                     char_len = 1
        end
        count = count + 1
        if count == max_chars then
            last_safe = i + char_len - 1
        end
        if count > max_chars then
            return s:sub(1, last_safe) .. "…"
        end
        i = i + char_len
    end
    return s  -- fits within max_chars
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

-- ---------------------------------------------------------------------------
-- Settings keys
-- ---------------------------------------------------------------------------

local SETTING_SOURCE        = "coverdeck_source"          -- pfx .. this; "recent"|"tbr"
local SETTING_SHOW_FINISHED = "coverdeck_show_finished"   -- pfx .. this; default OFF
local ELEM_ORDER_KEY        = "coverdeck_stats_order"     -- pfx .. this
local MAIN_ORDER_KEY        = "coverdeck_main_order"      -- pfx .. this

-- Progress badge (pentagon overlay on the centre cover, same drawing
-- primitive as the book-grid modules' progress badge) — off by default,
-- unlike the coverdeck_show_* elements above. Color follows the same
-- "Follow Library / Dark / Light" 3-way choice as the book-grid modules'
-- own per-badge color override (see engines/sui_book_grid.lua's
-- GridRenderer.getBadgeColorOverride) — nil means "Follow Library". Named
-- "Progress Badge" throughout, matching the book-grid/Library terminology
-- for the same badge_key ("progress").
local SETTING_SHOW_PROGRESS_BADGE  = "coverdeck_show_progress_badge"   -- pfx .. this; default OFF
local SETTING_PROGRESS_BADGE_COLOR = "coverdeck_progress_badge_color"  -- pfx .. this; nil|"dark"|"light"
-- When progress badge is on: also paint it on right-hand peeks (true) or
-- only on the centre cover (nil/false). Default off, same opt-in
-- convention as SETTING_SHOW_PROGRESS_BADGE.
local SETTING_PROGRESS_BADGE_ON_PEEKS = "coverdeck_progress_badge_on_peeks"

-- Source values of the form COLLECTION_PREFIX .. collection_name select a
-- user collection as the book source.
local COLLECTION_PREFIX = "collection:"

local _ELEM_DEFAULT_ORDER = { "percent", "book_days", "book_time", "book_remaining" }
local _ELEM_LABELS = {
    percent        = _("Percentage read"),
    book_days      = _("Days of reading"),
    book_time      = _("Time read"),
    book_remaining = _("Time remaining"),
}

-- Main list: the top-level arrangeable elements. "covers" is a fixed anchor
-- (always present, never removable — renders as a divider in the arrange
-- screen); the rest can be freely reordered and toggled around it.
local _MAIN_ELEM_DEFAULT_ORDER = { "covers", "title", "author", "progress", "stats", "description" }
local _MAIN_ELEM_LABELS = {
    covers   = _("Covers"),
    title    = _("Title"),
    author   = _("Author"),
    progress = _("Progress bar"),
    stats    = _("Statistics"),
    description = _("Description"),
}

-- ---------------------------------------------------------------------------
-- Settings accessors
-- ---------------------------------------------------------------------------

local function getSource(pfx)
    return SUISettings:readSetting(pfx .. SETTING_SOURCE) or "recent"
end

local function showFinished(pfx)
    return SUISettings:readSetting(pfx .. SETTING_SHOW_FINISHED) == true
end

-- Same "unset == off" convention as showFinished above — the progress
-- badge is opt-in, unlike the coverdeck_show_* elements below (which
-- default on).
local function showProgressBadge(pfx)
    return SUISettings:readSetting(pfx .. SETTING_SHOW_PROGRESS_BADGE) == true
end

-- Right-hand peeks also show the progress badge (default off). Only
-- meaningful when showProgressBadge is on.
local function showProgressBadgeOnPeeks(pfx)
    return SUISettings:readSetting(pfx .. SETTING_PROGRESS_BADGE_ON_PEEKS) == true
end

-- nil ("Follow Library") / "dark" / "light" — mirrors
-- GridRenderer.getBadgeColorOverride/setBadgeColor's shape, scoped by pfx
-- only since coverdeck is a single-instance module (no per-instance id).
local function getProgressBadgeColorOverride(pfx)
    local v = SUISettings:readSetting(pfx .. SETTING_PROGRESS_BADGE_COLOR)
    if v == "dark" or v == "light" then return v end
    return nil
end
local function setProgressBadgeColor(pfx, v)
    if v ~= "dark" and v ~= "light" then v = nil end -- nil = clear override, follow Library
    SUISettings:saveSetting(pfx .. SETTING_PROGRESS_BADGE_COLOR, v)
end

-- Every coverdeck_show_* key defaults to ON (an unset key reads as true),
-- except SETTING_SHOW_FINISHED above, which is read with `== true` so an
-- unset key defaults to OFF instead.
local function _showElem(pfx, key)
    if key == "description" then
        return SUISettings:readSetting(pfx .. "coverdeck_show_" .. key) == true
    end
    return SUISettings:nilOrTrue(pfx .. "coverdeck_show_" .. key)
end

-- Items show/hide/reorder: rebuild every known screen from fresh settings.
local function _invalidateCfgCache(_pfx)
    local ok, ScreenEngine = pcall(require, "engines/sui_screen_engine")
    if ok and ScreenEngine and ScreenEngine.invalidateAllCfgAndRefresh then
        ScreenEngine.invalidateAllCfgAndRefresh()
    end
end

local function _toggleElem(pfx, key)
    SUISettings:saveSetting(pfx .. "coverdeck_show_" .. key, not _showElem(pfx, key))
    _invalidateCfgCache(pfx)
end

-- Resolves an ordered key list against a set of valid keys: keeps only
-- known keys (deduped, in saved order), then appends any default keys not
-- already present. force_first, when given, is guaranteed to end up at
-- position 1 (used for "covers", which can be reordered but never removed).
local function _resolveOrder(saved, valid_keys, default_order, force_first)
    local seen, result = {}, {}
    if type(saved) == "table" then
        for _i, key in ipairs(saved) do
            if valid_keys[key] and not seen[key] then
                seen[key] = true
                result[#result+1] = key
            end
        end
    end
    for _i, key in ipairs(default_order) do
        if not seen[key] then
            seen[key] = true
            result[#result+1] = key
        end
    end
    if force_first and not seen[force_first] then
        table.insert(result, 1, force_first)
    end
    return result
end

-- bundle (ctx.cfg.coverdeck), when given, supplies elem_order/main_order
-- from the pre-read settings snapshot instead of a fresh SUISettings read.
-- A live read only happens when no bundle at all is given.
local function _getElemOrder(pfx, bundle)
    local saved = bundle and bundle.elem_order
    if not bundle then saved = SUISettings:readSetting(pfx .. ELEM_ORDER_KEY) end
    return _resolveOrder(saved, _ELEM_LABELS, _ELEM_DEFAULT_ORDER)
end

local function _getMainOrder(pfx, bundle)
    local saved = bundle and bundle.main_order
    if not bundle then saved = SUISettings:readSetting(pfx .. MAIN_ORDER_KEY) end
    return _resolveOrder(saved, _MAIN_ELEM_LABELS, _MAIN_ELEM_DEFAULT_ORDER, "covers")
end

-- Resolves a single element's visibility from the pre-read bundle when
-- given, falling back to a live settings read otherwise.
local function _showElemFrom(bundle, pfx, key)
    if bundle and bundle.show and bundle.show[key] ~= nil then
        return bundle.show[key]
    end
    return _showElem(pfx, key)
end

-- ---------------------------------------------------------------------------
-- getVisibleElements — single source of truth for what is visible.
-- Returns a plain table consumed by build() and getHeight() so that any
-- visibility change only needs to be made in one place. bundle is optional
-- (ctx.cfg.coverdeck); when omitted, everything is read live from settings.
-- ---------------------------------------------------------------------------
local function getVisibleElements(pfx, bundle)
    local stats_order = _getElemOrder(pfx, bundle)
    local has_stat     = false
    for _i, key in ipairs(stats_order) do
        if _showElemFrom(bundle, pfx, key) then has_stat = true; break end
    end
    return {
        main_order  = _getMainOrder(pfx, bundle),
        show_title  = _showElemFrom(bundle, pfx, "title"),
        show_author = _showElemFrom(bundle, pfx, "author"),
        progress    = _showElemFrom(bundle, pfx, "progress"),
        show_stats  = _showElemFrom(bundle, pfx, "stats"),
        -- Live read, not _showElemFrom: description is not in the pre-read
        -- bundle, and must stay opt-in even if a bundle entry is added later.
        show_description = _showElem(pfx, "description"),
        has_stat    = has_stat,
        stats_order = stats_order,
    }
end

-- ---------------------------------------------------------------------------
-- Shared module (lazy-loaded)
-- ---------------------------------------------------------------------------

local _SH = nil
local function getSH()
    if not _SH then
        local ok, m = pcall(require, "modules/module_books_shared")
        if ok and m then
            _SH = m
        else
            logger.warn("coverdeck: cannot load module_books_shared: " .. tostring(m))
        end
    end
    return _SH
end

-- ---------------------------------------------------------------------------
-- Progress badge (pentagon) — same drawing primitive as the book-grid
-- modules' progress badge (see engines/sui_book_grid.lua's
-- GridRenderer.applyBadges), so a book's read/complete/abandoned status
-- looks identical everywhere in the app. Coverdeck is a single-instance
-- module (no per-instance id like the grid modules use), so there is no
-- per-instance size override here — only color, via
-- getProgressBadgeColorOverride/setProgressBadgeColor above.
-- ---------------------------------------------------------------------------
local _CoverWidgets = nil
local function getCoverWidgets()
    if not _CoverWidgets then
        local ok, m = pcall(require, "features/library/sui_cover_widgets")
        if ok and m then _CoverWidgets = m end
    end
    return _CoverWidgets
end

local _FC = nil
local function getFC()
    if not _FC then
        local ok, m = pcall(require, "features/library/sui_foldercovers")
        if ok and m then _FC = m end
    end
    return _FC
end

-- Overlays the progress pentagon on `cover_widget` when the book has a
-- status worth showing (in progress, complete, or abandoned). Returns
-- `cover_widget` unchanged otherwise — same "not started" convention as
-- GridRenderer.applyBadges.
-- ref_w/ref_h (optional): centre-cover size. When set (right-hand peeks),
-- badge edge and right inset follow the full-cover formula scaled by
-- ch/ref_h — the same height ratio the peek cover uses vs the centre —
-- so size and margin stay visually consistent instead of shrinking with
-- the narrow crop width.
local function applyProgressBadge(cover_widget, bd, cw, ch, pfx, ref_w, ref_h)
    local has_progress = (bd.percent or 0) > 0 or bd.status == "complete" or bd.status == "abandoned"
    if not has_progress then return cover_widget end

    local CW = getCoverWidgets()
    if not CW then return cover_widget end

    local fc    = getFC()
    local color = getProgressBadgeColorOverride(pfx)
        or (fc and fc.getBadgeColorProgress and fc.getBadgeColorProgress())
        or "dark"
    local dark = color == "dark"

    local edge_margin, eff_size
    if ref_h and ref_h > 0 and ref_w and ref_w > 0 then
        local scale   = ch / ref_h
        local ref_min = math.min(ref_w, ref_h)
        edge_margin   = math.max(1, math.floor(ref_min * 0.08 * scale))
        eff_size      = math.max(8, math.floor(ref_min * 0.14 * scale))
    else
        local cell_min = math.min(cw, ch)
        edge_margin    = math.max(1, math.floor(cell_min * 0.08))
        eff_size       = math.max(8, math.floor(cell_min * 0.14))
    end

    local desc = CW.buildProgressBadgeDesc(eff_size, bd.status, bd.percent, SUIStyle.BADGE_BORDER_SZ, dark)
    local wg   = CW.buildProgressBadgeWidget(desc)
    if not wg then return cover_widget end

    -- Flush with the top edge, inset from the right — matches the corner
    -- badges' placement convention in applyBadges (and the scaled centre
    -- margin when ref_w/ref_h are set).
    local sz = wg:getSize()
    wg.overlap_offset = { cw - sz.w - edge_margin, 0 }

    local overlap = OverlapGroup:new{ dimen = Geom:new{ w = cw, h = ch }, cover_widget }
    overlap[#overlap + 1] = wg
    return overlap
end

-- ---------------------------------------------------------------------------
-- Stats cache — LRU capped at BSTATS_CACHE_MAX entries: { result, t }.
-- Eviction scans the small table for the oldest entry. Keeps RAM bounded
-- even when the user browses a large TBR list across a long session.
-- ---------------------------------------------------------------------------

local _bstats_cache       = {}
local _bstats_cache_count = 0

local function _bstats_evict()
    local oldest_key = nil
    local oldest_t   = math.huge
    for k, entry in pairs(_bstats_cache) do
        if entry.t < oldest_t then
            oldest_t   = entry.t
            oldest_key = k
        end
    end
    if oldest_key then
        _bstats_cache[oldest_key] = nil
        _bstats_cache_count = _bstats_cache_count - 1
    end
end

local function fmtTime(secs)
    secs = math.floor(secs or 0)
    if secs <= 0 then return "0m" end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 and m > 0 then return string.format("%dh %dm", h, m)
    elseif h > 0        then return string.format("%dh", h)
    else                     return string.format("%dm", m) end
end

-- Resolves a book's partial_md5_checksum: prefers the prefetched entry,
-- falling back to opening its docsettings sidecar.
local function _resolveMd5(fp, prefetched_entry)
    local md5 = prefetched_entry and prefetched_entry.partial_md5_checksum
    if md5 then return md5 end
    local DS = require("docsettings")
    local ok_ds, ds = pcall(DS.open, DS, fp)
    if ok_ds and ds then
        md5 = ds:readSetting("partial_md5_checksum")
        pcall(function() ds:close() end)
    end
    return md5
end

local function fetchBookStats(md5, shared_conn, ctx, force)
    if not md5 then return nil end
    local cached = _bstats_cache[md5]
    if not force and cached then
        cached.t = os.time()   -- update LRU access time
        return cached.result
    end

    local conn     = shared_conn or Config.openStatsDB()
    local own_conn = not shared_conn
    if not conn then return nil end

    local result
    local ok, err = pcall(function()
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
        ]], string.format(Config.BOOK_ID_BY_MD5_SQL, md5), MAX_SEC_PER_PAGE))

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
        logger.warn("coverdeck: fetchBookStats failed: " .. tostring(err))
        if shared_conn and ctx and Config.isFatalDbError(err) then
            ctx.db_conn_fatal = true
        end
    end
    if own_conn then pcall(function() conn:close() end) end
    if result then
        if _bstats_cache_count >= BSTATS_CACHE_MAX then _bstats_evict() end
        _bstats_cache[md5] = { result = result, t = os.time() }
        _bstats_cache_count = _bstats_cache_count + 1
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Carousel geometry helpers
-- ---------------------------------------------------------------------------

local function carouselIdx(curIdx, offset, count)
    return (curIdx + offset - 1 + count * 2) % count + 1
end

local function yTopOf(centerY, h)
    return math.floor(centerY - h / 2)
end

-- ---------------------------------------------------------------------------
-- File list builders
-- ---------------------------------------------------------------------------

-- A book counts as finished when its cached percent has reached 100%, or
-- its cached summary status is explicitly "complete" (a source may report
-- completion without percent ever reaching exactly 1.0).
local function _isBookDone(ctx, fp)
    local pd  = ctx.prefetched and ctx.prefetched[fp]
    local pct = pd and pd.percent or 0
    return (pct >= 1.0) or
        (type(pd) == "table" and type(pd.summary) == "table" and pd.summary.status == "complete")
end

-- Moves current_fp to the front of fps if present, otherwise returns fps
-- unchanged. Only reorders the coverdeck's own display list, not the
-- underlying source list (recent history, TBR, collection).
local function _prioritizeCurrent(fps, current_fp)
    if not (current_fp and fps and #fps > 0) then return fps end
    local found = false
    for _i, fp in ipairs(fps) do
        if fp == current_fp then found = true; break end
    end
    if not found then return fps end
    local result = { current_fp }
    for _i, fp in ipairs(fps) do
        if fp ~= current_fp then result[#result+1] = fp end
    end
    return result
end

local function buildRecentFps(ctx)
    local fps      = {}
    local show_fin = showFinished(ctx.pfx or "")
    if ctx.current_fp then
        fps[1] = ctx.current_fp
    end
    if ctx.recent_fps then
        local seen = {}
        if ctx.current_fp then seen[ctx.current_fp] = true end
        for _i, fp in ipairs(ctx.recent_fps) do
            if not seen[fp] and (show_fin or not _isBookDone(ctx, fp)) then
                fps[#fps+1] = fp
                seen[fp]    = true
                if #fps >= MAX_RECENT_FPS then break end
            end
        end
    end
    return fps
end

local function buildTBRFps(ctx)
    if not ctx._tbr_fps then
        local tbr = require("modules/module_tbr")
        ctx._tbr_fps = tbr.getTBRList()
    end
    return _prioritizeCurrent(ctx._tbr_fps, ctx.current_fp)
end

local function buildCollectionFps(coll_name, ctx)
    local ok_rc, rc = pcall(require, "readcollection")
    if not (ok_rc and rc) then return {} end
    -- Read the in-process singleton directly, without rc:_read(): that call
    -- reloads collections from disk and can wipe in-memory-only changes the
    -- native Collections UI hasn't flushed yet.
    local coll = rc.coll and rc.coll[coll_name]
    if not coll then return {} end

    local show_fin = showFinished(ctx.pfx or "")
    local list = {}
    local lfs = require("libs/libkoreader-lfs")
    for fp, info in pairs(coll) do
        local ok_attr, attr = pcall(lfs.attributes, fp, "mode")
        local exists = ok_attr and attr == "file"
        if exists and (show_fin or not _isBookDone(ctx, fp)) then
            list[#list + 1] = {
                filepath = fp,
                order = (type(info) == "table" and info.order) or 9999
            }
        end
    end
    table.sort(list, function(a, b) return (a.order or 9999) < (b.order or 9999) end)

    local raw_fps = {}
    for i = 1, #list do
        raw_fps[i] = list[i].filepath
    end
    return _prioritizeCurrent(raw_fps, ctx.current_fp)
end

local function buildFavoritesFps(ctx)
    local ok_rc, rc = pcall(require, "readcollection")
    local fav_name = (ok_rc and rc and rc.default_collection_name) or "favorites"
    return buildCollectionFps(fav_name, ctx)
end

local function getFps(source, ctx)
    local fps
    if source == "tbr" then
        fps = buildTBRFps(ctx)
    elseif source == "favorites" then
        fps = buildFavoritesFps(ctx)
    elseif source:match("^" .. COLLECTION_PREFIX) then
        local coll_name = source:sub(#COLLECTION_PREFIX + 1)
        fps = buildCollectionFps(coll_name, ctx)
    else
        fps = buildRecentFps(ctx)
    end
    -- Fallback: if chosen source is empty, cascade through the others.
    if not fps or #fps == 0 then
        if source ~= "recent" then
            fps = buildRecentFps(ctx)
        end
        if (not fps or #fps == 0) and source ~= "tbr" then
            fps = buildTBRFps(ctx)
        end
        if (not fps or #fps == 0) and source ~= "favorites" then
            fps = buildFavoritesFps(ctx)
        end
    end
    return fps
end

-- ---------------------------------------------------------------------------
-- Module API
-- ---------------------------------------------------------------------------

local M = {}

M.id          = "coverdeck"
M.name        = _("Cover Deck")
M.label       = nil
M.enabled_key = "coverdeck_enabled"
M.default_on  = false
M.has_covers  = true   -- activates e-ink dithering and cover poll
M.is_book_mod = true   -- suppresses empty-state when active

function M.reset()
    _SH                 = nil
    _bstats_cache       = {}
    _bstats_cache_count = 0
end

-- No-op: called from main.lua:onCloseDocument as a fallback when the closed
-- book's md5 could not be resolved (the normal path is
-- invalidateCacheForMd5, below). A full flush isn't needed here — every
-- other book's cached stats are still valid, and the centre book's own
-- entry gets a forced refetch on the very next stats-only refresh via
-- M.updateStats' fetchBookStats(..., true) call. Wiping the whole cache
-- would only force every carousel entry back to SQLite on the next swipe
-- for no correctness gain.
function M.invalidateCache()
end

-- Removes only the cache entry for the given md5, leaving all other books
-- intact. Called after closing a document so the centre cover's stats are
-- fresh without discarding stats cached for every other book.
function M.invalidateCacheForMd5(md5)
    if md5 and _bstats_cache[md5] then
        _bstats_cache[md5] = nil
        _bstats_cache_count = _bstats_cache_count - 1
    end
end

-- Exposed for pre-computation from outside the module (see _buildCtx).
-- Same as the local fetchBookStats; does not set ctx.db_conn_fatal since
-- there is no ctx here.
function M.fetchBookStatsForCtx(md5, db_conn, force)
    return fetchBookStats(md5, db_conn, nil, force)
end

-- ---------------------------------------------------------------------------
-- build
-- ---------------------------------------------------------------------------

-- Empty placeholder when the chosen source has no books (same pattern as
-- Quick Actions / Featured Collection / Collections).
-- Uses a wrapping TextBoxWidget rather than the single-line TextWidget
-- behind makeColoredText, since this message is long enough to need
-- multiple lines at the module's own width; falls back to a plain
-- TextBoxWidget when there's no wallpaper to composite over, mirroring
-- module_currently.lua's own text elements.
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
            logger.warn("simpleui: module_coverdeck: makeAlphaTextBox failed, falling back to TextBoxWidget: " .. tostring(tbx))
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

function M.build(w, ctx)
    local pfx    = ctx.pfx

    -- Use pre-read settings bundle from ctx when available (normal HS path).
    local c = ctx.cfg and ctx.cfg.coverdeck
    local source = c and c.source or getSource(pfx)

    logger.dbg("coverdeck: build source=" .. tostring(source)
        .. " current_fp=" .. tostring(ctx.current_fp)
        .. " recent_fps=" .. tostring(ctx.recent_fps and #ctx.recent_fps or "nil"))

    local fps = getFps(source, ctx)
    if not fps or #fps == 0 then
        logger.dbg(string.format("coverdeck: no books found (source=%s)", tostring(source)))
        return _emptyPlaceholder(w, M.getHeight(ctx), ctx.has_wallpaper)
    end

    local SH = getSH()
    if not SH then
        return _emptyPlaceholder(w, M.getHeight(ctx), ctx.has_wallpaper)
    end

    local CLR_TEXT_EFF     = SUIStyle.COLOR.text_primary
    local CLR_TEXT_SUB_EFF = CLR_TEXT_SUB

    -- Scales: c.scale/c.thumb_scale/c.lbl_scale (from ctx.cfg) are raw
    -- values; ctx.landscape_factor is applied on top here.
    local lf          = ctx.landscape_factor or 1
    local scale       = (c and c.scale       or Config.getModuleScale("coverdeck", pfx)) * lf
    local thumb_scale = (c and c.thumb_scale or Config.getThumbScale("coverdeck", pfx)) * lf
    local lbl_scale   = (c and c.lbl_scale   or Config.getItemLabelScale("coverdeck", pfx)) * lf

    -- Carousel geometry (center_w below) is a percentage of inner_w, which
    -- is already narrowed for landscape upstream. Applying `lf` on top of
    -- that would narrow it twice, so this uses the raw scale instead.
    -- scale/thumb_scale above (with lf) remain for fixed-pixel elements
    -- (fonts, bar height) that aren't width-derived.
    local raw_scale       = c and c.scale       or Config.getModuleScaleRaw("coverdeck", pfx)
    local raw_thumb_scale = c and c.thumb_scale or Config.getThumbScaleRaw("coverdeck", pfx)
    local cs              = raw_scale * raw_thumb_scale

    -- Visibility flags: uses the pre-read bundle when available, otherwise
    -- reads settings directly.
    local vis = getVisibleElements(pfx, c)
    local main_order      = vis.main_order
    local show_title      = vis.show_title
    local show_author     = vis.show_author
    local show_progress   = vis.progress
    local show_stats      = vis.show_stats
    local show_description = vis.show_description
    local stats_order     = vis.stats_order
    local show_progress_badge         = showProgressBadge(pfx)
    local show_progress_badge_on_peeks = showProgressBadgeOnPeeks(pfx)

    -- Carousel dimensions: center_w is a percentage of inner_w (see
    -- _CENTER_W_PCT above), scaled by cs (raw scale * thumb_scale) on top.
    local inner_w  = w - PAD * 2
    local center_w = math.max(_CENTER_W_MIN, math.floor(inner_w * _CENTER_W_PCT * cs))
    local center_h = math.floor(center_w * 3 / 2)
    local side_w   = math.floor(center_w * 0.45)
    local side_h   = math.floor(center_h * 0.85)
    local far_w    = math.floor(center_w * 0.35)
    local far_h    = math.floor(center_h * 0.75)

    local centerX     = math.floor(inner_w / 2)
    local half_cw     = math.floor(center_w / 2)
    local offset_near = math.floor(center_w * 0.35)
    local offset_far  = math.floor(center_w * 0.60)
    -- Full carousel footprint (left far edge to right far edge), clamped to
    -- the overlap group width. Title/author max_width uses this so those
    -- lines stay within the cover block including side peeks.
    local covers_block_w = math.min(inner_w, center_w + 2 * offset_far)
    -- Stats may run wider than the covers; truncate only past 95% of the
    -- module page width.
    local stats_max_w = math.floor(w * 0.95)
    local TOP_CLEAR   = 2
    local centerY     = math.floor(center_h / 2) + TOP_CLEAR

    local count  = #fps
    -- The centre is always fps[1] by default. Swipe navigation is
    -- session-scoped: stored in ctx, not persisted across sessions.
    local curIdx = ctx.coverdeck_cur_idx or 1
    if curIdx > count then curIdx = 1 end
    ctx.coverdeck_cur_idx = curIdx

    -- Covers: only the centre slot is genuinely 3:2 (center_h = center_w *
    -- 3/2). side_w/h and far_w/h are deliberately narrower boxes: slivers
    -- meant to look like the visible edge of a book partly hidden behind
    -- the centre cover. That illusion needs an actual cropped slice of a
    -- full 3:2 cover, not a whole cover squashed into a narrow box — so
    -- the centre uses the stretch-only path (SH.getBookCover) and the
    -- side/far slots use the crop-to-fill path (SH.getCroppedBookCover).
    local function buildCover(fp, cw, ch)
        local bd    = SH.getBookData(fp, ctx.prefetched and ctx.prefetched[fp])
        local cover = SH.getBookCover(fp, cw, ch) or SH.coverPlaceholder(bd.title, bd.authors, cw, ch)
        if show_progress_badge then
            cover = applyProgressBadge(cover, bd, cw, ch, pfx)
        end
        return cover
    end
    local function buildCroppedCover(fp, cw, ch, align)
        local bd    = SH.getBookData(fp, ctx.prefetched and ctx.prefetched[fp])
        local cover = SH.getCroppedBookCover(fp, cw, ch, align) or SH.coverPlaceholder(bd.title, bd.authors, cw, ch)
        -- Right-hand peeks show the cover's right edge — where the progress
        -- badge sits — so paint it there too when enabled (optional setting).
        -- Left peeks crop the left edge (badge would be off-canvas).
        -- Size/margin scale from centre by ch/center_h (side 0.85, far 0.75).
        if show_progress_badge and show_progress_badge_on_peeks and align == "right" then
            cover = applyProgressBadge(cover, bd, cw, ch, pfx, center_w, center_h)
        end
        return cover
    end

    local items = {}
    local cover_slots = {}  -- parallel: {fp, w, h, kind, align} for each items entry
    if count >= 5 then
        items[#items+1] = buildCroppedCover(fps[carouselIdx(curIdx, -2, count)], far_w, far_h, "left")
        items[#items].overlap_offset = { math.floor(centerX - half_cw - offset_far),         yTopOf(centerY, far_h) }
        cover_slots[#cover_slots+1] = { fp = fps[carouselIdx(curIdx, -2, count)], w = far_w,  h = far_h, kind = "crop", align = "left",
                                        overlap_offset = items[#items].overlap_offset }
        items[#items+1] = buildCroppedCover(fps[carouselIdx(curIdx, 2, count)], far_w, far_h, "right")
        items[#items].overlap_offset = { math.floor(centerX + half_cw + offset_far - far_w), yTopOf(centerY, far_h) }
        cover_slots[#cover_slots+1] = { fp = fps[carouselIdx(curIdx, 2, count)],  w = far_w,  h = far_h, kind = "crop", align = "right",
                                        overlap_offset = items[#items].overlap_offset,
                                        ref_w = center_w, ref_h = center_h }
    end
    if count >= 2 then
        items[#items+1] = buildCroppedCover(fps[carouselIdx(curIdx, -1, count)], side_w, side_h, "left")
        items[#items].overlap_offset = { math.floor(centerX - half_cw - offset_near),          yTopOf(centerY, side_h) }
        cover_slots[#cover_slots+1] = { fp = fps[carouselIdx(curIdx, -1, count)], w = side_w, h = side_h, kind = "crop", align = "left",
                                        overlap_offset = items[#items].overlap_offset }
    end
    if count >= 3 then
        items[#items+1] = buildCroppedCover(fps[carouselIdx(curIdx, 1, count)], side_w, side_h, "right")
        items[#items].overlap_offset = { math.floor(centerX + half_cw + offset_near - side_w), yTopOf(centerY, side_h) }
        cover_slots[#cover_slots+1] = { fp = fps[carouselIdx(curIdx, 1, count)],  w = side_w, h = side_h, kind = "crop", align = "right",
                                        overlap_offset = items[#items].overlap_offset,
                                        ref_w = center_w, ref_h = center_h }
    end
    items[#items+1] = buildCover(fps[curIdx], center_w, center_h)
    items[#items].overlap_offset = { math.floor(centerX - half_cw), yTopOf(centerY, center_h) }
    cover_slots[#cover_slots+1] = { fp = fps[curIdx], w = center_w, h = center_h,
                                    overlap_offset = items[#items].overlap_offset }

    -- Tappable carousel container
    local group_h  = center_h + TOP_CLEAR
    local overlap  = OverlapGroup:new{ dimen = Geom:new{ w = inner_w, h = group_h }, unpack(items) }
    -- Annotate each cover_slot with its container+index inside the OverlapGroup.
    for i, slot in ipairs(cover_slots) do
        slot.container = overlap
        slot.idx       = i
    end
    local tappable = InputContainer:new{
        dimen    = Geom:new{ w = inner_w, h = group_h },
        [1]      = overlap,
        _screen  = ctx._screen_widget,
        _open_fn = ctx.open_fn,
        _fps     = fps,
        _cur     = curIdx,
        _count   = count,
        _mid     = math.floor(inner_w / 2),
        _half_cw = half_cw,
    }

    -- Repaints only this coverdeck widget's screen region after tap/swipe
    -- navigation, instead of a full-page rebuild + whole-screen redraw.
    -- Falls back to a full refresh when the surgical path is unavailable.
    local function _navigateRefresh(screen)
        if screen._refreshBookModSlot then
            local ok = screen:_refreshBookModSlot("coverdeck")
            if ok then return end
        end
        screen:_refreshImmediate(true)
    end

    -- Advances self._cur by one step (forward or backward) and repaints.
    local function _navigateStep(self, forward)
        if forward then
            self._cur = self._cur % self._count + 1
        else
            self._cur = (self._cur - 2 + self._count) % self._count + 1
        end
        if self._screen then
            self._screen:_setCoverdeckIdx(self._cur)
            _navigateRefresh(self._screen)
        end
    end

    function tappable:onTap(_, ges)
        local x       = ges.pos.x - self.dimen.x
        local mirrored = BD.mirroredUILayout()
        if x < self._mid - self._half_cw then
            _navigateStep(self, mirrored)   -- left side: previous in LTR, next in RTL
        elseif x > self._mid + self._half_cw then
            _navigateStep(self, not mirrored)  -- right side: next in LTR, previous in RTL
        elseif self._open_fn then
            self._open_fn(self._fps[self._cur])
        end
        return true
    end

    function tappable:onSwipe(_, ges)
        local dir = ges.direction
        if BD.mirroredUILayout() then
            if dir == "west" then dir = "east" elseif dir == "east" then dir = "west" end
        end
        if dir == "east" then
            _navigateStep(self, false)
            return true
        elseif dir == "west" then
            _navigateStep(self, true)
            return true
        end
        return false
    end

    tappable.ges_events = {
        Tap   = { GestureRange:new{ ges = "tap",   range = function() return tappable.dimen end } },
        Swipe = { GestureRange:new{ ges = "swipe", range = function() return tappable.dimen end } },
    }

    -- Long-press on the centre cover opens the per-book dialog only when
    -- enabled via "Long press on cover". Holding on a side cover, or with
    -- the setting left at "settings", falls back to the module wrapper's
    -- own hold handling (settings screen).
    if Config.getCoverHoldMode("coverdeck", ctx.pfx) == "book_dialog" then
        tappable.ges_events.HoldDeck = {
            GestureRange:new{ ges = "hold", range = function() return tappable.dimen end },
        }
        tappable.ges_events.HoldDeckRelease = {
            GestureRange:new{ ges = "hold_release", range = function() return tappable.dimen end },
        }
        function tappable:onHoldDeck(_, ges)
            local x = ges.pos.x - self.dimen.x
            self._hold_on_center = (x >= self._mid - self._half_cw and x <= self._mid + self._half_cw)
            -- Only swallow the gesture (and thus block the settings-menu
            -- fallback) when it actually lands on the centre cover.
            return self._hold_on_center or nil
        end
        function tappable:onHoldDeckRelease()
            if self._hold_on_center and ctx.hold_fn then
                ctx.hold_fn(self._fps[self._cur], "coverdeck")
            end
            return self._hold_on_center or nil
        end
    end

    -- Book data for centre cover
    local bd        = SH.getBookData(fps[curIdx], ctx.prefetched and ctx.prefetched[fps[curIdx]])
    local title_fs  = math.floor(SUIStyle.FS_TITLE  * scale * lbl_scale)
    local info_fs   = math.floor(SUIStyle.FS_DETAIL * scale * lbl_scale)
    local bar_h     = math.max(1, math.floor(Screen:scaleBySize(8) * scale))
    local face_title = Font:getFace(SUIStyle.FACE_REGULAR, math.max(8, title_fs))
    local face_info  = Font:getFace(SUIStyle.FACE_REGULAR, math.max(7, info_fs))

    -- Title widget (capped to full cover block including side peeks)
    local title_widget
    if show_title then
        title_widget  = UI.makeColoredText{
            text      = truncateToWidth(bd.title, face_title, covers_block_w),
            face      = face_title,
            bold      = true,
            fgcolor   = CLR_TEXT_EFF,
            width     = covers_block_w,
            alignment = "center",
        }
    end

    -- Author widget (hidden when no usable name, same as description)
    local author_widget
    if show_author then
        local author_text = _formatAuthors(bd.authors)
        if author_text then
            local author_fs   = math.floor(SUIStyle.FS_SUBTITLE * scale * lbl_scale)
            local face_author = Font:getFace(SUIStyle.FACE_REGULAR, math.max(8, author_fs))
            author_widget = UI.makeColoredText{
                text      = truncateToWidth(author_text, face_author, covers_block_w),
                face      = face_author,
                fgcolor   = CLR_TEXT_SUB_EFF,
                width     = covers_block_w,
                alignment = "center",
            }
        end
    end

    -- Closures used by updateStats for in-place refresh.
    -- _cd_update_funcs: DB-backed stats text (needs bstats).
    -- _cd_bd_only_funcs: progress bar (needs only book data).
    local _cd_update_funcs  = {}
    local _cd_bd_only_funcs = {}
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

    -- Progress bar: wrapped in a single-child container so updateStats can
    -- replace the bar without touching the surrounding VerticalGroup.
    local progress_widget
    if show_progress then
        local _bar_w = center_w
        local _bar_h = bar_h
        local _init_bar = UI.progressBar(_bar_w, bd.percent, _bar_h)
        local bar_container = OverlapGroup:new{
            dimen = _init_bar:getSize(),
            _init_bar,
        }
        local function _update_bar(_nb, nd)
            bar_container[1] = UI.progressBar(_bar_w, (nd and nd.percent or 0), _bar_h)
        end
        table.insert(_cd_bd_only_funcs, _update_bar)
        progress_widget = bar_container
    end

    -- Stats: single compact line rebuilt from the arranged stats order.
    local stats_widget
    local has_any_stats = show_stats and vis.has_stat

    if has_any_stats then
        local bstats
        if vis.has_stat then
            -- Fast path: stats pre-computed by _buildCtx() for this centre book.
            local pre = ctx.coverdeck_center_stats
            if pre and pre.fp == fps[curIdx] then
                bstats = pre.stats
            else
                -- Slow path: query once; result lands in _bstats_cache for
                -- subsequent carousel navigations.
                local prefetched_entry = ctx.prefetched and ctx.prefetched[fps[curIdx]]
                local md5 = _resolveMd5(fps[curIdx], prefetched_entry)
                if md5 then
                    bstats = fetchBookStats(md5, ctx.db_conn, ctx)
                end
            end
        end

        local stats_w = UI.makeColoredText{
            text      = "",
            face      = face_info,
            fgcolor   = CLR_TEXT_SUB_EFF,
            width     = stats_max_w,
            alignment = "center",
        }
        local function _update(nb, nd)
            local stats_parts = {}
            for _i, key in ipairs(stats_order) do
                if _showElemFrom(c, pfx, key) then
                    local text
                    if key == "percent" then
                        text = string.format(_("%d%% Read"), math.floor((nd.percent or 0) * 100 + 0.5))
                    elseif nb then
                        if key == "book_days" and nb.days and nb.days > 0 then
                            text = string.format(N_("%d day of reading", "%d days of reading", nb.days), nb.days)
                        elseif key == "book_time" and nb.total_secs and nb.total_secs > 0 then
                            text = string.format(_("%s read"), fmtTime(nb.total_secs))
                        elseif key == "book_remaining" then
                            local avg_t = (nb.avg_time and nb.avg_time > 0) and nb.avg_time or nd.avg_time
                            if avg_t and avg_t > 0 and nd.pages and nd.pages > 0 then
                                local secs_left = math.floor(avg_t * nd.pages * (1 - (nd.percent or 0)))
                                if secs_left > 0 then
                                    text = string.format(_("%s remaining"), fmtTime(secs_left))
                                end
                            end
                        end
                    end
                    if text then stats_parts[#stats_parts+1] = text end
                end
            end
            local final_text = #stats_parts > 0 and table.concat(stats_parts, " · ") or ""
            _updateColoredText(stats_w, truncateToWidth(final_text, face_info, stats_max_w), CLR_TEXT_SUB_EFF)
        end
        _update(bstats, bd)
        table.insert(_cd_update_funcs, _update)
        stats_widget = stats_w
    end

    -- Description: the centre book's blurb, already HTML-stripped by
    -- SH.getBookData. TextBoxWidget's max_lines does not clamp, so the line
    -- budget is converted to a pixel height (same as module_currently).
    -- Width spans the full inner width; title/author are capped to the
    -- narrower carousel footprint and would wrap a blurb far too early.
    local desc_widget
    if show_description and bd.description and bd.description ~= "" then
        local desc_line_h = math.floor(1.3 * face_info.size + 0.5)
        local desc_args = {
            text      = bd.description,
            face      = face_info,
            width     = inner_w,
            height    = desc_line_h * DESC_LINES,
            height_adjust = true,
            height_overflow_show_ellipsis = true,
            fgcolor   = CLR_TEXT_SUB_EFF,
        }
        if ctx.has_wallpaper then
            local ok_tbx, tbx = pcall(UI.makeAlphaTextBox, desc_args)
            if ok_tbx then
                desc_widget = tbx
            else
                logger.warn("simpleui: module_coverdeck: makeAlphaTextBox failed, "
                    .. "falling back to TextBoxWidget: " .. tostring(tbx))
                desc_widget = TextBoxWidget:new(desc_args)
            end
        else
            desc_widget = TextBoxWidget:new(desc_args)
        end
    end

    -- Final layout assembly — render each visible main-list element in the
    -- user's chosen order ("covers" is the carousel itself; the rest are
    -- optional widgets). A PAD2 vspan separates any two adjacent elements.
    local final_vg = VerticalGroup:new{ align = "center" }
    local _first_elem = true
    local function _appendElem(widget)
        if not widget then return end
        if not _first_elem then final_vg[#final_vg+1] = SH.vspan(PAD2, ctx.vspan_pool) end
        final_vg[#final_vg+1] = widget
        _first_elem = false
    end
    for _i, key in ipairs(main_order) do
        if key == "covers" then
            _appendElem(tappable)
        elseif key == "title" then
            _appendElem(title_widget)
        elseif key == "author" then
            _appendElem(author_widget)
        elseif key == "progress" then
            _appendElem(progress_widget)
        elseif key == "stats" then
            _appendElem(stats_widget)
        elseif key == "description" then
            _appendElem(desc_widget)
        end
    end

    -- Pre-warm the cover of the next book in the carousel at center size.
    -- When the user swipes, that cover will be the new center — having it
    -- already scaled in cache eliminates the blitter stall on the next build.
    -- scheduleIn(0) defers the scale to after the current paint cycle so the
    -- homescreen appears immediately and the work is done during idle time.
    if count > 1 then
        local next_fp      = fps[curIdx % count + 1]
        local warm_w       = center_w
        local warm_h       = center_h
        local UIManager_lz = require("ui/uimanager")
        UIManager_lz:scheduleIn(0, function()
            -- Only stretches fresh if the cache doesn't already hold a bb
            -- at least this size (getStretchedCoverBB returns early on hit
            -- — see infra/sui_cover_cache.lua's prefer-larger get()).
            Config.getStretchedCoverBB(next_fp, warm_w, warm_h)
        end)
    end

    local result = FrameContainer:new{
        bordersize = 0, padding = PAD, padding_top = PAD, padding_bottom = 0,
        final_vg,
    }
    result._cover_slots     = cover_slots
    result._cd_update_funcs = _cd_update_funcs
    result._cd_bd_only_funcs = _cd_bd_only_funcs
    result._center_fp       = fps[curIdx]
    return result
end

function M.updateCovers(widget, ctx)
    if not widget or not widget._cover_slots then return true end
    local SH = getSH()
    if not SH then return true end
    local pfx = (ctx and ctx.pfx) or ""
    local show_badge = showProgressBadge(pfx)
    local all_done = true
    for _, slot in ipairs(widget._cover_slots) do
        -- Crop slots (side/far "peek" covers) carry their left/right
        -- alignment forward, or a reload would re-crop them centred and
        -- lose the "peeking edge" illusion.
        local new_cover = (slot.kind == "crop")
            and SH.getCroppedBookCover(slot.fp, slot.w, slot.h, slot.align)
            or SH.getBookCover(slot.fp, slot.w, slot.h)
        if new_cover then
            -- Re-apply progress badge after a late cover load (build() already
            -- did this for centre + right peeks; the poll would otherwise
            -- strip it).
            local on_peeks = showProgressBadgeOnPeeks(pfx)
            local apply = show_badge and (slot.kind ~= "crop"
                or (on_peeks and slot.align == "right"))
            if apply then
                local bd = SH.getBookData(slot.fp, ctx and ctx.prefetched and ctx.prefetched[slot.fp])
                new_cover = applyProgressBadge(new_cover, bd, slot.w, slot.h, pfx, slot.ref_w, slot.ref_h)
            end
            -- Use the overlap_offset recorded at build() time — the current
            -- widget at slot.idx may be a placeholder with no overlap_offset.
            new_cover.overlap_offset = slot.overlap_offset
            slot.container[slot.idx] = new_cover
        elseif not Config.isCoverMissing(slot.fp) then
            all_done = false
        end
    end
    return all_done
end

function M.updateStats(widget, ctx)
    local actual_widget = (widget._cd_update_funcs or widget._cd_bd_only_funcs) and widget
                          or (widget[1] and (widget[1]._cd_update_funcs or widget[1]._cd_bd_only_funcs) and widget[1])
    if not actual_widget then return false end
    if not actual_widget._cd_update_funcs and not actual_widget._cd_bd_only_funcs then
        return false
    end

    local fp = actual_widget._center_fp
    if not fp then return false end

    -- Widget is bound to the centre book at build time. Recompute the centre
    -- fp build() would produce and bail on mismatch so we never patch the
    -- wrong book's numbers (list/order can change between renders).
    do
        local c        = ctx.cfg and ctx.cfg.coverdeck
        local source   = c and c.source or getSource(ctx.pfx)
        local fps      = getFps(source, ctx)
        local count    = fps and #fps or 0
        local cur_idx  = ctx.coverdeck_cur_idx or 1
        if count > 0 and cur_idx > count then cur_idx = 1 end
        local expected_center_fp = count > 0 and fps[cur_idx] or nil
        if expected_center_fp ~= fp then return false end
    end

    -- Progress badge is composited into the cover widget tree at build time.
    -- Percent/status changes on the badge require a full rebuild — same
    -- contract as GridRenderer.updateStats for progress_style "badge".
    local pfx = (ctx and ctx.pfx) or ""
    if showProgressBadge(pfx) then return false end

    local bstats
    local pre = ctx.coverdeck_center_stats
    if pre and pre.fp == fp then
        bstats = pre.stats
    end

    local prefetched_entry = ctx.prefetched and ctx.prefetched[fp]
    if not bstats then
        local md5 = _resolveMd5(fp, prefetched_entry)
        if md5 then
            bstats = fetchBookStats(md5, ctx.db_conn, ctx, true)
        end
    end

    local SH = getSH()
    if not SH then return true end
    local bd = SH.getBookData(fp, prefetched_entry)

    if bstats and actual_widget._cd_update_funcs then
        for _, fn in ipairs(actual_widget._cd_update_funcs) do
            fn(bstats, bd)
        end
    end
    -- Progress bar only needs bd; update even when there is no SQLite history.
    if actual_widget._cd_bd_only_funcs then
        for _, fn in ipairs(actual_widget._cd_bd_only_funcs) do
            fn(nil, bd)
        end
    end
    return true
end

function M.getHeight(ctx)
    local pfx = ctx and ctx.pfx or ""
    -- Uses the pre-read settings bundle from ctx when available. c.scale
    -- is raw; ctx.landscape_factor is applied on top here.
    local c           = ctx and ctx.cfg and ctx.cfg.coverdeck
    local lf          = (ctx and ctx.landscape_factor) or (UI.isLandscape() and UI.getLandscapeFactor() or 1)
    local scale       = (c and c.scale       or Config.getModuleScale("coverdeck", pfx)) * lf
    local lbl_scale   = (c and c.lbl_scale   or Config.getItemLabelScale("coverdeck", pfx)) * lf

    -- center_w mirrors build(): a percentage of inner_w, using the raw
    -- scale (no `lf`) since ctx.col_w is already narrowed for landscape.
    -- getHeight has no real widget width to work with, so estimate one.
    local raw_scale       = c and c.scale       or Config.getModuleScaleRaw("coverdeck", pfx)
    local raw_thumb_scale = c and c.thumb_scale or Config.getThumbScaleRaw("coverdeck", pfx)
    local w_estimate       = (ctx and (ctx.col_w or ctx.inner_w)) or (Screen:getWidth() - UI.SIDE_PAD * 2)
    local inner_w_estimate = w_estimate - PAD * 2

    -- Visibility flags: uses the pre-read bundle when available, mirroring build().
    local vis = getVisibleElements(pfx, c)
    local show_title  = vis.show_title
    local show_author = vis.show_author

    local center_w = math.max(_CENTER_W_MIN,
        math.floor(inner_w_estimate * _CENTER_W_PCT * raw_scale * raw_thumb_scale))
    local center_h = math.floor(center_w * 3 / 2)
    local h        = center_h + 2  -- TOP_CLEAR

    if show_title then
        -- Must mirror the face size used for title_widget in build(), or
        -- the reserved height undershoots the rendered text and the title
        -- gets clipped by the module's frame.
        local title_fs = math.floor(SUIStyle.FS_TITLE * scale * lbl_scale)
        h = h + math.max(8, title_fs) + PAD2
    end

    if show_author then
        local author_fs = math.floor(SUIStyle.FS_SUBTITLE * scale * lbl_scale)
        h = h + math.max(8, author_fs) + PAD2
    end

    local has_meta = false
    if vis.progress then
        has_meta = true
        h = h + math.floor(Screen:scaleBySize(8) * scale)   -- matches bar_h in build()
    end

    if vis.has_stat and vis.show_stats ~= false then
        if has_meta then h = h + PAD2 end
        h        = h + math.floor(Screen:scaleBySize(14) * scale * lbl_scale)
        has_meta = true
    end

    if vis.show_description then
        -- Re-resolve the face: infra/sui_patches wraps Font.getFace to scale
        -- sizes when global Text Size != 100%, so face.size != the value passed
        -- in. build() reads face_info the same way, keeping both in step.
        local desc_face = Font:getFace(SUIStyle.FACE_REGULAR,
            math.max(7, math.floor(SUIStyle.FS_DETAIL * scale * lbl_scale)))
        local desc_lh   = math.floor(1.3 * desc_face.size + 0.5)  -- matches desc_widget in build()
        if has_meta then h = h + PAD2 end
        h = h + desc_lh * DESC_LINES
        has_meta = true
    end

    if has_meta then h = h + PAD2 end

    return h + PAD
end

-- ---------------------------------------------------------------------------
-- getMenuItems
-- ---------------------------------------------------------------------------

function M.getMenuItems(ctx_menu)
    local pfx        = ctx_menu.pfx
    local refresh    = ctx_menu.refresh
    local _lc        = ctx_menu._
    local _UIManager = ctx_menu.UIManager
    local SortWidget = ctx_menu.SortWidget

    -- hide_in_sui should only be true for items that have an equivalent
    -- control inside items_item.sui_build (currently: the 4 stats). Title
    -- and Progress bar have no SUI-native replacement, so hiding them here
    -- would leave the user with no way to toggle them from the SUI window.
    local function toggle_item(label, key, hide_in_sui)
        return {
            text           = _lc(label),
            checked_func   = function() return _showElem(pfx, key) end,
            keep_menu_open = true,
            callback       = function() _toggleElem(pfx, key); refresh() end,
            sui_hidden     = (hide_in_sui and ctx_menu.is_sui) or nil,
        }
    end

    local scale_items = {
        Config.makeScaleItem({
            text_func    = function() return _lc("Scale") end,
            enabled_func = function() return not Config.isScaleLinked() end,
            title        = _lc("Scale"),
            info         = _lc("Scale for this module."),
            get          = function() return Config.getModuleScalePct("coverdeck", pfx) end,
            set          = function(v) Config.setModuleScale(v, "coverdeck", pfx) end,
            refresh      = refresh,
        }),
        Config.makeScaleItem({
            text_func = function() return _lc("Cover Size") end,
            title     = _lc("Cover Size"),
            info      = _lc("Scale for the cover thumbnails only.\n100% is the default size."),
            get       = function() return Config.getThumbScalePct("coverdeck", pfx) end,
            set       = function(v) Config.setThumbScale(v, "coverdeck", pfx) end,
            refresh   = refresh,
        }),
        Config.makeScaleItem({
            text_func = function() return _lc("Text Size") end,
            title     = _lc("Text Size"),
            info      = _lc("Scale for title and statistics text.\n100% is the default size."),
            get       = function() return Config.getItemLabelScalePct("coverdeck", pfx) end,
            set       = function(v) Config.setItemLabelScale(v, "coverdeck", pfx) end,
            refresh   = refresh,
        }),
    }

    local function makeCollectionsSubMenu()
        local submenu = {}
        local ok_rc, rc = pcall(require, "readcollection")
        if ok_rc and rc then
            -- Not calling rc:_read() — see note above; it can wipe
            -- uncommitted collection changes made via the native
            -- Collections UI.
            local coll_set = {}
            if rc.coll then for n in pairs(rc.coll) do coll_set[n] = true end end
            if rc.coll_folders then for n in pairs(rc.coll_folders) do coll_set[n] = true end end

            -- Remove favorites and TBR from this list as they have dedicated top-level options
            local fav = rc.default_collection_name or "favorites"
            coll_set[fav] = nil
            local TBR = package.loaded["modules/module_tbr"]
            local tbr_name = TBR and TBR.TBR_COLL_NAME or "To Be Read"
            coll_set[tbr_name] = nil

            local coll_names = {}
            for name in pairs(coll_set) do
                coll_names[#coll_names + 1] = name
            end
            table.sort(coll_names, function(a, b) return a:lower() < b:lower() end)

            for _, name in ipairs(coll_names) do
                local c_name = name
                submenu[#submenu + 1] = {
                    text         = c_name, radio = true,
                    checked_func = function() return getSource(pfx) == COLLECTION_PREFIX .. c_name end,
                    keep_menu_open = true,
                    callback     = function()
                        SUISettings:saveSetting(pfx .. SETTING_SOURCE, COLLECTION_PREFIX .. c_name)
                        refresh()
                    end,
                }
            end
        end
        if #submenu == 0 then
            submenu[#submenu + 1] = {
                text         = _lc("No collections found"),
                enabled_func = function() return false end,
            }
        end
        return submenu
    end

    -- A single-choice "source" entry: selecting it saves `value` under
    -- SETTING_SOURCE and refreshes the menu.
    local function _sourceRadioItem(label, value)
        return {
            text         = _lc(label), radio = true,
            checked_func = function() return getSource(pfx) == value end,
            keep_menu_open = true,
            callback     = function()
                SUISettings:saveSetting(pfx .. SETTING_SOURCE, value)
                refresh()
            end,
        }
    end

    local source_item = {
        text_func = function()
            local src = getSource(pfx)
            local display_src
            if src == "recent" then
                display_src = _lc("Recent Books")
            elseif src == "tbr" then
                display_src = _lc("To Be Read")
            elseif src == "favorites" then
                display_src = _lc("Favorites")
            elseif src:match("^" .. COLLECTION_PREFIX) then
                display_src = src:sub(#COLLECTION_PREFIX + 1)
            else
                display_src = src
            end
            return string.format("%s: %s", _lc("Source"), display_src)
        end,
        sub_item_table_func = function()
            local items = {
                _sourceRadioItem("Recent Books", "recent"),
                _sourceRadioItem("To Be Read",   "tbr"),
                _sourceRadioItem("Favorites",    "favorites"),
            }

            local ok_rc, rc = pcall(require, "readcollection")
            if ok_rc and rc then
                items[#items + 1] = {
                    text                = _lc("Collections"),
                    sub_item_table_func = makeCollectionsSubMenu,
                }
            end

            return items
        end,
    }

    -- True if any key in `keys` is currently hidden — used to enable the
    -- "Add Item" footer action only when there's something left to add.
    local function _anyHidden(keys)
        for _, key in ipairs(keys) do
            if not _showElem(pfx, key) then return true end
        end
        return false
    end

    -- Builds "Add Item" picker entries for the hidden keys in `candidate_keys`.
    -- Each entry's on_tap makes the key visible, hands it to `reorder_fn` to
    -- place it in the saved order and persist that, then refreshes the menu
    -- and closes the picker. Reordering differs between the stats list and
    -- the main items list, so it stays the caller's responsibility.
    local function _makeAddItemPicker(candidate_keys, labels, reorder_fn, ctx2)
        local picker_items = {}
        for _, key in ipairs(candidate_keys) do
            if not _showElem(pfx, key) then
                local _key, _label = key, _lc(labels[key])
                picker_items[#picker_items + 1] = {
                    text   = _label,
                    on_tap = function(picker_ctx)
                        _toggleElem(pfx, _key)
                        reorder_fn(_key)
                        refresh()
                        picker_ctx.pop()
                        ctx2.repaint()
                    end,
                }
            end
        end
        return picker_items
    end

    -- Pushes the nested "Statistics" arrange screen (percent / days / time /
    -- remaining), reachable either by tapping the "Statistics" row inside the
    -- main arrange list (SUI) or via the "Statistics" submenu (native).
    local function _pushStatsArrange()
        local function _statsSortItems()
            local sort_items = {}
            for _i, key in ipairs(_getElemOrder(pfx)) do
                if _showElem(pfx, key) then
                    sort_items[#sort_items+1] = { text = _lc(_ELEM_LABELS[key]), orig_item = key }
                end
            end
            return sort_items
        end
        local function _saveStatsOrder(items_to_save)
            local new_order, active_set = {}, {}
            for _i, it in ipairs(items_to_save) do
                new_order[#new_order+1] = it.orig_item
                active_set[it.orig_item] = true
            end
            for _i, k in ipairs(_getElemOrder(pfx)) do
                if not active_set[k] then new_order[#new_order+1] = k end
            end
            SUISettings:saveSetting(pfx .. ELEM_ORDER_KEY, new_order)
            _invalidateCfgCache(pfx)
            refresh()
        end
        if ctx_menu.show_arrange then
            ctx_menu.show_arrange({
                title      = _lc("Statistics"),
                items_func = _statsSortItems,
                empty_text = _lc("No statistics selected."),
                on_delete  = function(item) _toggleElem(pfx, item.orig_item) end,
                on_change  = _saveStatsOrder,
                footer_text = _lc("Add Item"),
                footer_enabled = function() return _anyHidden(_getElemOrder(pfx)) end,
                footer_action = function(ctx2)
                    local items = _makeAddItemPicker(_getElemOrder(pfx), _ELEM_LABELS, function(added_key)
                        -- Reorder: shown keys first (excluding added_key),
                        -- then added_key, then the remaining hidden keys.
                        local new_order, active_set = {}, {}
                        for _i2, k in ipairs(_getElemOrder(pfx)) do
                            if _showElem(pfx, k) and k ~= added_key then
                                new_order[#new_order+1] = k
                                active_set[k] = true
                            end
                        end
                        new_order[#new_order+1] = added_key
                        active_set[added_key] = true
                        for _i2, k in ipairs(_getElemOrder(pfx)) do
                            if not active_set[k] then new_order[#new_order+1] = k end
                        end
                        SUISettings:saveSetting(pfx .. "coverdeck_show_" .. added_key, true)
                        SUISettings:saveSetting(pfx .. ELEM_ORDER_KEY, new_order)
                        _invalidateCfgCache(pfx)
                    end, ctx2)
                    ctx2.push("item_picker", { title = _lc("Add Item"), items = items })
                end,
            })
        else
            local sort_items = _statsSortItems()
            _UIManager:show(SortWidget:new{
                title             = _lc("Statistics"),
                item_table        = sort_items,
                covers_fullscreen = true,
                callback          = function() _saveStatsOrder(sort_items) end,
            })
        end
    end

    -- Main arrange list: "Covers" (fixed anchor, divider — never removable)
    -- plus Title / Author / Progress bar / Statistics, freely reorderable
    -- and toggleable around it. Tapping "Statistics" opens the nested
    -- per-statistic arrange screen above.
    local function _mainSortItems()
        local sort_items = {}
        for _i, key in ipairs(_getMainOrder(pfx)) do
            if key == "covers" then
                sort_items[#sort_items+1] = {
                    text = _lc(_MAIN_ELEM_LABELS.covers):upper(), orig_item = "covers", is_divider = true,
                }
            elseif _showElem(pfx, key) then
                local entry = { text = _lc(_MAIN_ELEM_LABELS[key]), orig_item = key }
                if key == "stats" then
                    entry.show_chevron = true
                    entry.on_tap       = _pushStatsArrange
                end
                sort_items[#sort_items+1] = entry
            end
        end
        return sort_items
    end

    local function _saveMainOrder(items_to_save)
        local new_order, active_set = {}, {}
        for _i, it in ipairs(items_to_save) do
            new_order[#new_order+1] = it.orig_item
            active_set[it.orig_item] = true
        end
        for _i, k in ipairs(_getMainOrder(pfx)) do
            if not active_set[k] then new_order[#new_order+1] = k end
        end
        SUISettings:saveSetting(pfx .. MAIN_ORDER_KEY, new_order)
        _invalidateCfgCache(pfx)
        refresh()
    end

    local items_item = {
        text = _lc("Items"),
        sub_item_table = {
            {
                text      = _lc("Arrange Items"),
                separator = true,
                keep_menu_open = true,
                callback  = function()
                    local sort_items = _mainSortItems()
                    _UIManager:show(SortWidget:new{
                        title             = _lc("Arrange Items"),
                        item_table        = sort_items,
                        covers_fullscreen = true,
                        callback          = function() _saveMainOrder(sort_items) end,
                    })
                end,
            },
            toggle_item("Title",        "title",    true),
            toggle_item("Author",       "author",   true),
            toggle_item("Progress bar", "progress", true),
            toggle_item("Statistics",   "stats",    true),
            toggle_item("Description", "description", true),
            {
                text = _lc("Statistics"),
                sub_item_table = {
                    {
                        text      = _lc("Arrange Statistics"),
                        separator = true,
                        keep_menu_open = true,
                        callback  = _pushStatsArrange,
                    },
                    toggle_item("Percentage read",  "percent",        true),
                    toggle_item("Days of reading",  "book_days",      true),
                    toggle_item("Time read",        "book_time",      true),
                    toggle_item("Time remaining",   "book_remaining", true),
                },
                sui_hidden = ctx_menu.is_sui or nil,
            },
        },
        sui_build = ctx_menu.is_sui and function(ctx, _item)
            local SUIWindow = require("engines/sui_window")
            return SUIWindow.ListRow{
                title        = _lc("Items"),
                subtitle     = function()
                    local names = {}
                    for _, key in ipairs(_getMainOrder(pfx)) do
                        if key ~= "covers" and _showElem(pfx, key) then
                            names[#names + 1] = _lc(_MAIN_ELEM_LABELS[key])
                        end
                    end
                    return #names > 0 and table.concat(names, "  ·  ") or _lc("No items selected.")
                end,
                inner_w      = ctx.inner_w,
                show_chevron = true,
                on_tap       = function()
                    ctx.push("arrange", {
                        title       = _lc("Items"),
                        items_func  = _mainSortItems,
                        empty_text  = _lc("No items selected."),
                        on_delete   = function(item)
                            if item.orig_item ~= "covers" then
                                _toggleElem(pfx, item.orig_item)
                            end
                        end,
                        on_change   = _saveMainOrder,
                        footer_text = _lc("Add Item"),
                        footer_enabled = function()
                            return _anyHidden({ "title", "author", "progress", "stats", "description" })
                        end,
                        footer_action = function(ctx2)
                            local items = _makeAddItemPicker(
                                { "title", "author", "progress", "stats", "description" }, _MAIN_ELEM_LABELS,
                                function(added_key)
                                    local cur = _getMainOrder(pfx)
                                    local new_order = {}
                                    for _, k in ipairs(cur) do
                                        if k ~= added_key then new_order[#new_order + 1] = k end
                                    end
                                    new_order[#new_order + 1] = added_key
                                    SUISettings:saveSetting(pfx .. "coverdeck_show_" .. added_key, true)
                                    SUISettings:saveSetting(pfx .. MAIN_ORDER_KEY, new_order)
                                    _invalidateCfgCache(pfx)
                                end, ctx2)
                            ctx2.push("item_picker", { title = _lc("Add Item"), items = items })
                        end,
                    })
                end,
            }
        end or nil,
    }

    local menu = {}
    menu[#menu+1] = source_item
    menu[#menu+1] = items_item
    menu[#menu+1] = {
        text_func      = function() return _lc("Size") end,
        sub_item_table = scale_items,
    }
    menu[#menu+1] = Config.makeCoverHoldModeItem{
        mod_id  = "coverdeck",
        pfx     = pfx,
        refresh = refresh,
        _lc     = _lc,
    }
    do
        -- Same grouping convention as the book-grid modules' per-badge
        -- submenus (see engines/sui_book_grid.lua's "Pages Badge" /
        -- "Series Badge" groups): a named row showing On/Off, containing
        -- the toggle plus a color override independent from every other
        -- module's badges.
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
            {
                text           = _lc("On side covers too"),
                enabled_func   = function() return showProgressBadge(pfx) end,
                checked_func   = function() return showProgressBadgeOnPeeks(pfx) end,
                keep_menu_open = true,
                callback       = function()
                    SUISettings:saveSetting(pfx .. SETTING_PROGRESS_BADGE_ON_PEEKS,
                        not showProgressBadgeOnPeeks(pfx))
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
        menu[#menu+1] = {
            text_func  = function() return _lc("Progress Badge") end,
            value_func = function()
                return showProgressBadge(pfx) and _lc("On") or _lc("Off")
            end,
            sub_item_table = progress_badge_group,
        }
    end
    menu[#menu+1] = {
        text           = _lc("Show finished books"),
        checked_func   = function() return showFinished(pfx) end,
        keep_menu_open = true,
        callback       = function()
            SUISettings:saveSetting(pfx .. SETTING_SHOW_FINISHED, not showFinished(pfx))
            refresh()
        end,
    }
    menu[#menu+1] = {
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
    return menu
end

return M