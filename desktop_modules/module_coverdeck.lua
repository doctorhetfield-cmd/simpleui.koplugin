-- module_coverdeck.lua
-- Displays recent or TBR books as a cover-flow carousel.

local Device         = require("device")
local Font           = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup   = require("ui/widget/overlapgroup")
local TextWidget     = require("ui/widget/textwidget")
local VerticalGroup  = require("ui/widget/verticalgroup")
local Screen         = Device.screen
local _ = require("sui_i18n").translate
local N_ = require("sui_i18n").ngettext
local logger         = require("logger")

local Config       = require("sui_config")
local UI           = require("sui_core")
local PAD          = UI.PAD
local PAD2         = UI.PAD2
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local MAX_RECENT_FPS   = 10
local MAX_SEC_PER_PAGE = 120  -- matches KOReader statistics query cap
local BSTATS_CACHE_MAX = 20   -- max md5 entries kept in the stats LRU cache

-- ---------------------------------------------------------------------------
-- UTF-8 aware title truncation
-- ---------------------------------------------------------------------------
-- Counts Unicode codepoints (not bytes) so CJK/Arabic titles are handled
-- correctly.  Returns the string unchanged if it is ≤ max_chars codepoints;
-- otherwise returns the first max_chars codepoints followed by "...".
local function truncateTitle(s, max_chars)
    if not s then return "" end
    local count = 0
    local i = 1
    local last_safe = 0   -- byte offset of the last complete codepoint boundary
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
            return s:sub(1, last_safe) .. "..."
        end
        i = i + char_len
    end
    return s  -- fits within max_chars
end

-- ---------------------------------------------------------------------------
-- Settings keys
-- ---------------------------------------------------------------------------

local SETTING_SOURCE        = "flow_recent_source"
local SETTING_TITLE_POS     = "coverdeck_title_pos"
local SETTING_SHOW_FINISHED = "coverdeck_show_finished"  -- pfx .. this; default OFF
local ELEM_ORDER_KEY    = "flow_stats_order"

local _ELEM_DEFAULT_ORDER = { "percent", "book_days", "book_time", "book_remaining" }
local _ELEM_LABELS = {
    percent        = _("Percentage read"),
    book_days      = _("Days of reading"),
    book_time      = _("Time read"),
    book_remaining = _("Time remaining"),
}

-- ---------------------------------------------------------------------------
-- Settings accessors
-- ---------------------------------------------------------------------------

local function getSource(pfx)
    return G_reader_settings:readSetting(pfx .. SETTING_SOURCE) or "recent"
end

local function getTitlePos(pfx)
    return G_reader_settings:readSetting(pfx .. SETTING_TITLE_POS) or "below"
end

local function showFinished(pfx)
    return G_reader_settings:readSetting(pfx .. SETTING_SHOW_FINISHED) == true
end

local function _showElem(pfx, key)
    return G_reader_settings:nilOrTrue(pfx .. "flow_show_" .. key)
end

local function _toggleElem(pfx, key)
    G_reader_settings:saveSetting(pfx .. "flow_show_" .. key, not _showElem(pfx, key))
end

local function _getElemOrder(pfx)
    local saved = G_reader_settings:readSetting(pfx .. ELEM_ORDER_KEY)
    if type(saved) ~= "table" or #saved == 0 then return _ELEM_DEFAULT_ORDER end
    local seen, result = {}, {}
    for _i, v in ipairs(saved) do
        if _ELEM_LABELS[v] then seen[v] = true; result[#result+1] = v end
    end
    for _i, v in ipairs(_ELEM_DEFAULT_ORDER) do
        if not seen[v] then result[#result+1] = v end
    end
    return result
end

-- ---------------------------------------------------------------------------
-- getVisibleElements — single source of truth for what is visible.
-- Returns a plain table consumed by both build() and getHeight() so that
-- any visibility change only needs to be made in one place.
-- ---------------------------------------------------------------------------
local function getVisibleElements(pfx)
    local stats_order = _getElemOrder(pfx)
    local has_stat    = false
    for _i, key in ipairs(stats_order) do
        if _showElem(pfx, key) then has_stat = true; break end
    end
    return {
        title       = _showElem(pfx, "title"),
        progress    = _showElem(pfx, "progress"),
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
        local ok, m = pcall(require, "desktop_modules/module_books_shared")
        if ok and m then
            _SH = m
        else
            logger.warn("coverdeck: cannot load module_books_shared: " .. tostring(m))
        end
    end
    return _SH
end

-- ---------------------------------------------------------------------------
-- Stats cache — LRU capped at BSTATS_CACHE_MAX entries.
-- Each entry: { result = <table>, t = <os.time()> }
-- Eviction scans the (small) table for the oldest entry, identical to the
-- pattern used by Config._bim_cover_cache.  Keeps RAM bounded even when the
-- user browses a large TBR list across a long session.
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

local function fetchBookStats(md5, shared_conn, ctx)
    if not md5 then return nil end
    local cached = _bstats_cache[md5]
    if cached then
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
        ]], md5, MAX_SEC_PER_PAGE))

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

local function buildRecentFps(ctx)
    local fps = {}
    if ctx.current_fp then
        fps[1] = ctx.current_fp
    end
    if ctx.recent_fps then
        local seen = {}
        if ctx.current_fp then seen[ctx.current_fp] = true end
        for _i, fp in ipairs(ctx.recent_fps) do
            if not seen[fp] then
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
        local tbr = require("desktop_modules/module_tbr")
        ctx._tbr_fps = tbr.getTBRList()
    end
    return ctx._tbr_fps
end

local function getFps(source, ctx)
    local fps = source == "tbr" and buildTBRFps(ctx) or buildRecentFps(ctx)
    -- Fallback: if chosen source is empty, try the other.
    if not fps or #fps == 0 then
        fps = source == "tbr" and buildRecentFps(ctx) or buildTBRFps(ctx)
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
M.enabled_key = "coverdeck"
M.default_on  = false

function M.reset()
    _SH                 = nil
    _bstats_cache       = {}
    _bstats_cache_count = 0
end

function M.invalidateCache()
    _bstats_cache       = {}
    _bstats_cache_count = 0
end

-- Removes only the cache entry for the given md5, leaving all other books
-- intact.  Called from onCloseDocument so the centre cover's stats are
-- refreshed after reading without discarding stats for every other book.
function M.invalidateCacheForMd5(md5)
    if not md5 then return end
    if _bstats_cache[md5] then
        _bstats_cache[md5] = nil
        _bstats_cache_count = _bstats_cache_count - 1
    end
end

-- Exposed for pre-computation in _buildCtx (sui_homescreen.lua).
-- Identical to the local fetchBookStats but callable from outside the module.
-- Returns the stats table or nil; does NOT set ctx.db_conn_fatal (no ctx here).
function M.fetchBookStatsForCtx(md5, db_conn)
    return fetchBookStats(md5, db_conn, nil)
end

-- ---------------------------------------------------------------------------
-- build
-- ---------------------------------------------------------------------------

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
        logger.warn(string.format("coverdeck: no books found (source=%s)", tostring(source)))
        return nil
    end

    local SH = getSH()
    if not SH then return nil end

    -- Scales
    local scale       = c and c.scale       or Config.getModuleScale("coverdeck", pfx)
    local thumb_scale = c and c.thumb_scale or Config.getThumbScale("coverdeck", pfx)
    local lbl_scale   = c and c.lbl_scale   or Config.getItemLabelScale("coverdeck", pfx)
    local cs          = scale * thumb_scale

    -- Visibility flags (use bundle when available, fall back to direct reads)
    local vis
    if c and c.show then
        -- Build vis from the pre-read bundle, mirroring getVisibleElements().
        local stats_order_saved = c.elem_order
        local stats_order = (type(stats_order_saved) == "table" and #stats_order_saved > 0)
            and (function()
                local seen, result = {}, {}
                for _, v in ipairs(stats_order_saved) do
                    if _ELEM_LABELS[v] then seen[v] = true; result[#result+1] = v end
                end
                for _, v in ipairs(_ELEM_DEFAULT_ORDER) do
                    if not seen[v] then result[#result+1] = v end
                end
                return result
            end)()
            or _ELEM_DEFAULT_ORDER
        local has_stat = false
        for _, key in ipairs(stats_order) do
            if c.show[key] then has_stat = true; break end
        end
        vis = {
            title       = c.show.title,
            progress    = c.show.progress,
            has_stat    = has_stat,
            stats_order = stats_order,
        }
    else
        vis = getVisibleElements(pfx)
    end
    local show_title    = vis.title
    local show_progress = vis.progress
    local stats_order   = vis.stats_order

    -- Carousel dimensions
    local center_w = math.floor(Screen:scaleBySize(140) * cs)
    local center_h = math.floor(center_w * 3 / 2)
    local side_w   = math.floor(center_w * 0.45)
    local side_h   = math.floor(center_h * 0.85)
    local far_w    = math.floor(center_w * 0.35)
    local far_h    = math.floor(center_h * 0.75)

    local inner_w     = w - PAD * 2
    local centerX     = math.floor(inner_w / 2)
    local half_cw     = math.floor(center_w / 2)
    local offset_near = math.floor(center_w * 0.35)
    local offset_far  = math.floor(center_w * 0.60)
    local TOP_CLEAR   = 2
    local centerY     = math.floor(center_h / 2) + TOP_CLEAR

    local count  = #fps
    -- The centre is always fps[1] by default. Swipe navigation is session-scoped:
    -- stored in ctx (which lives for the homescreen session) but not persisted
    -- across sessions in settings.
    local curIdx = ctx.coverdeck_cur_idx or 1
    if curIdx > count then curIdx = 1 end
    ctx.coverdeck_cur_idx = curIdx

    -- Covers
    local function buildCover(fp, cw, ch, align)
        local bd    = SH.getBookData(fp, ctx.prefetched and ctx.prefetched[fp])
        local cover = SH.getBookCover(fp, cw, ch, align, 0.20) or SH.coverPlaceholder(bd.title, cw, ch)
        return cover
    end

    local items = {}
    if count >= 5 then
        items[#items+1] = buildCover(fps[carouselIdx(curIdx, -2, count)], far_w, far_h, "left")
        items[#items].overlap_offset = { math.floor(centerX - half_cw - offset_far),         yTopOf(centerY, far_h) }
        items[#items+1] = buildCover(fps[carouselIdx(curIdx, 2, count)], far_w, far_h, "right")
        items[#items].overlap_offset = { math.floor(centerX + half_cw + offset_far - far_w), yTopOf(centerY, far_h) }
    end
    if count >= 2 then
        items[#items+1] = buildCover(fps[carouselIdx(curIdx, -1, count)], side_w, side_h, "left")
        items[#items].overlap_offset = { math.floor(centerX - half_cw - offset_near),          yTopOf(centerY, side_h) }
    end
    if count >= 3 then
        items[#items+1] = buildCover(fps[carouselIdx(curIdx, 1, count)], side_w, side_h, "right")
        items[#items].overlap_offset = { math.floor(centerX + half_cw + offset_near - side_w), yTopOf(centerY, side_h) }
    end
    items[#items+1] = buildCover(fps[curIdx], center_w, center_h, "center")
    items[#items].overlap_offset = { math.floor(centerX - half_cw), yTopOf(centerY, center_h) }

    -- Tappable carousel container
    local group_h  = center_h + TOP_CLEAR
    local tappable = InputContainer:new{
        dimen    = Geom:new{ w = inner_w, h = group_h },
        [1]      = OverlapGroup:new{ dimen = Geom:new{ w = inner_w, h = group_h }, unpack(items) },
        _hs      = ctx._hs_widget,
        _open_fn = ctx.open_fn,
        _fps     = fps,
        _cur     = curIdx,
        _count   = count,
        _mid     = math.floor(inner_w / 2),
        _half_cw = half_cw,
    }

    function tappable:onTap(_, ges)
        local x = ges.pos.x - self.dimen.x
        if x < self._mid - self._half_cw then
            self._cur = (self._cur - 2 + self._count) % self._count + 1
            if self._hs then
                self._hs:_setCoverdeckIdx(self._cur)
                self._hs:_refreshImmediate(true)
            end
        elseif x > self._mid + self._half_cw then
            self._cur = self._cur % self._count + 1
            if self._hs then
                self._hs:_setCoverdeckIdx(self._cur)
                self._hs:_refreshImmediate(true)
            end
        else
            if self._open_fn then self._open_fn(self._fps[self._cur]) end
        end
        return true
    end

    function tappable:onSwipe(_, ges)
        if ges.direction == "east" then
            self._cur = (self._cur - 2 + self._count) % self._count + 1
            if self._hs then
                self._hs:_setCoverdeckIdx(self._cur)
                self._hs:_refreshImmediate(true)
            end
            return true
        elseif ges.direction == "west" then
            self._cur = self._cur % self._count + 1
            if self._hs then
                self._hs:_setCoverdeckIdx(self._cur)
                self._hs:_refreshImmediate(true)
            end
            return true
        end
        return false
    end

    tappable.ges_events = {
        Tap   = { GestureRange:new{ ges = "tap",   range = function() return tappable.dimen end } },
        Swipe = { GestureRange:new{ ges = "swipe", range = function() return tappable.dimen end } },
    }

    -- Book data for centre cover
    local bd        = SH.getBookData(fps[curIdx], ctx.prefetched and ctx.prefetched[fps[curIdx]])
    local title_fs  = math.floor(Screen:scaleBySize(12) * scale * lbl_scale)
    local info_fs   = math.floor(Screen:scaleBySize(8)  * scale * lbl_scale)
    local bar_h     = math.max(1, math.floor(Screen:scaleBySize(7) * scale))
    local title_pos = c and c.title_pos or getTitlePos(pfx)
    local face_title = Font:getFace("smallinfofont", math.max(8, title_fs))
    local face_info  = Font:getFace("smallinfofont", math.max(7, info_fs))

    -- Title widget
    local title_widget
    if show_title then
        title_widget  = TextWidget:new{
            text      = truncateTitle(bd.title, 30),
            face      = face_title,
            bold      = true,
            width     = inner_w,
            alignment = "center",
        }
    end

    -- Meta block: progress bar + stats line
    local meta = VerticalGroup:new{ align = "center" }

    if show_progress then
        meta[#meta+1] = SH.progressBar(center_w, bd.percent, bar_h)
    end

    -- Stats
    local bstats
    if vis.has_stat then
        -- Fast path: use stats pre-computed by _buildCtx() when the centre cover
        -- matches the pre-fetched entry (common case on first render).
        local pre = ctx.coverdeck_center_stats
        if pre and pre.fp == fps[curIdx] then
            bstats = pre.stats
        else
            -- Slow path: _buildCtx guessed wrong (curIdx != 1) or ctx has no
            -- pre-computed stats.  Run the query now; result lands in
            -- _bstats_cache so subsequent carousel navigations are instant.
            local prefetched_entry = ctx.prefetched and ctx.prefetched[fps[curIdx]]
            local md5 = prefetched_entry and prefetched_entry.partial_md5_checksum
            if not md5 then
                local DS = require("docsettings")
                local ok_ds, ds = pcall(DS.open, DS, fps[curIdx])
                if ok_ds and ds then
                    md5 = ds:readSetting("partial_md5_checksum")
                    pcall(function() ds:close() end)
                end
            end
            if md5 then
                bstats = fetchBookStats(md5, ctx.db_conn, ctx)
            end
        end
    end

    local stats_parts = {}
    for _i, key in ipairs(stats_order) do
        if _showElem(pfx, key) then
            local text
            if key == "percent" then
                text = string.format(_("%d%% Read"), math.floor((bd.percent or 0) * 100 + 0.5))
            elseif bstats then
                if key == "book_days" and bstats.days and bstats.days > 0 then
                    text = string.format(N_("%d day of reading", "%d days of reading", bstats.days), bstats.days)
                elseif key == "book_time" and bstats.total_secs and bstats.total_secs > 0 then
                    text = string.format(_("%s read"), fmtTime(bstats.total_secs))
                elseif key == "book_remaining" then
                    local avg_t = (bstats.avg_time and bstats.avg_time > 0) and bstats.avg_time or bd.avg_time
                    if avg_t and avg_t > 0 and bd.pages and bd.pages > 0 then
                        local secs_left = math.floor(avg_t * bd.pages * (1 - (bd.percent or 0)))
                        if secs_left > 0 then
                            text = string.format(_("%s remaining"), fmtTime(secs_left))
                        end
                    end
                end
            end
            if text then stats_parts[#stats_parts+1] = text end
        end
    end

    if #stats_parts > 0 then
        if #meta > 0 then meta[#meta+1] = SH.vspan(PAD2, ctx.vspan_pool) end
        meta[#meta+1] = TextWidget:new{
            text      = table.concat(stats_parts, " · "),
            face      = face_info,
            fgcolor   = CLR_TEXT_SUB,
            width     = inner_w,
            alignment = "center",
        }
    end

    -- Final layout assembly
    local final_vg = VerticalGroup:new{ align = "center" }
    if title_widget and title_pos == "above" then
        final_vg[#final_vg+1] = title_widget
        final_vg[#final_vg+1] = SH.vspan(PAD2, ctx.vspan_pool)
    end
    final_vg[#final_vg+1] = tappable
    if title_widget and title_pos == "below" then
        final_vg[#final_vg+1] = SH.vspan(PAD2, ctx.vspan_pool)
        final_vg[#final_vg+1] = title_widget
    end
    if #meta > 0 then
        final_vg[#final_vg+1] = SH.vspan(PAD2, ctx.vspan_pool)
        final_vg[#final_vg+1] = meta
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
            -- Only scale if not already cached (getCoverBB returns early on hit).
            Config.getCoverBB(next_fp, warm_w, warm_h, "center", 0.20)
        end)
    end

    return FrameContainer:new{
        bordersize = 0, padding = PAD, padding_top = PAD, padding_bottom = 0,
        final_vg,
    }
end

-- ---------------------------------------------------------------------------
-- getHeight
-- ---------------------------------------------------------------------------

function M.getHeight(ctx)
    local pfx         = ctx and ctx.pfx or ""
    local scale       = Config.getModuleScale("coverdeck", pfx)
    local thumb_scale = Config.getThumbScale("coverdeck", pfx)
    local lbl_scale   = Config.getItemLabelScale("coverdeck", pfx)
    local vis         = getVisibleElements(pfx)

    local center_w = math.floor(Screen:scaleBySize(140) * scale * thumb_scale)
    local center_h = math.floor(center_w * 3 / 2)
    local h        = center_h + 2  -- TOP_CLEAR

    if vis.title then
        h = h + math.floor(Screen:scaleBySize(16) * scale * lbl_scale) + PAD2
    end

    local has_meta = false
    if vis.progress then
        has_meta = true
        h = h + math.floor(Screen:scaleBySize(7) * scale)  -- matches bar_h in build()
    end

    if vis.has_stat then
        if has_meta then h = h + PAD2 end
        h        = h + math.floor(Screen:scaleBySize(14) * scale * lbl_scale)
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

    local function toggle_item(label, key)
        return {
            text           = _lc(label),
            checked_func   = function() return _showElem(pfx, key) end,
            keep_menu_open = true,
            callback       = function() _toggleElem(pfx, key); refresh() end,
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
            text_func = function() return _lc("Cover size") end,
            title     = _lc("Cover size"),
            info      = _lc("Scale for the cover thumbnails only.\n100% is the default size."),
            get       = function() return Config.getThumbScalePct("coverdeck", pfx) end,
            set       = function(v) Config.setThumbScale(v, "coverdeck", pfx) end,
            refresh   = refresh,
        }),
        Config.makeScaleItem({
            text_func = function() return _lc("Text size") end,
            title     = _lc("Text size"),
            info      = _lc("Scale for title and statistics text.\n100% is the default size."),
            get       = function() return Config.getItemLabelScalePct("coverdeck", pfx) end,
            set       = function(v) Config.setItemLabelScale(v, "coverdeck", pfx) end,
            refresh   = refresh,
        }),
    }

    local source_item = {
        text = _lc("Source"),
        sub_item_table = {
            {
                text         = _lc("Recent Books"), radio = true,
                checked_func = function() return getSource(pfx) == "recent" end,
                callback     = function()
                    G_reader_settings:saveSetting(pfx .. SETTING_SOURCE, "recent")
                    refresh()
                end,
            },
            {
                text         = _lc("To Be Read"), radio = true,
                checked_func = function() return getSource(pfx) == "tbr" end,
                callback     = function()
                    G_reader_settings:saveSetting(pfx .. SETTING_SOURCE, "tbr")
                    refresh()
                end,
            },
        },
    }

    local title_pos_item = {
        text = _lc("Title Position"),
        sub_item_table = {
            {
                text         = _lc("Above"), radio = true,
                checked_func = function() return getTitlePos(pfx) == "above" end,
                callback     = function()
                    G_reader_settings:saveSetting(pfx .. SETTING_TITLE_POS, "above")
                    refresh()
                end,
            },
            {
                text         = _lc("Below"), radio = true,
                checked_func = function() return getTitlePos(pfx) == "below" end,
                callback     = function()
                    G_reader_settings:saveSetting(pfx .. SETTING_TITLE_POS, "below")
                    refresh()
                end,
            },
        },
    }

    local items_item = {
        text = _lc("Items"),
        sub_item_table = {
            toggle_item("Title",        "title"),
            toggle_item("Progress bar", "progress"),
            {
                text      = _lc("Arrange Statistics"),
                separator = true,
                callback  = function()
                    local sort_items = {}
                    for _i, key in ipairs(_getElemOrder(pfx)) do
                        if _showElem(pfx, key) then
                            sort_items[#sort_items+1] = {
                                text      = _lc(_ELEM_LABELS[key]),
                                orig_item = key,
                            }
                        end
                    end
                    _UIManager:show(SortWidget:new{
                        title             = _lc("Arrange Statistics"),
                        item_table        = sort_items,
                        covers_fullscreen = true,
                        callback          = function()
                            local new_order = {}
                            for _i, item in ipairs(sort_items) do
                                new_order[#new_order+1] = item.orig_item
                            end
                            local active_set = {}
                            for _i, k in ipairs(new_order) do active_set[k] = true end
                            for _i, k in ipairs(_getElemOrder(pfx)) do
                                if not active_set[k] then new_order[#new_order+1] = k end
                            end
                            G_reader_settings:saveSetting(pfx .. ELEM_ORDER_KEY, new_order)
                            refresh()
                        end,
                    })
                end,
            },
            toggle_item("Percentage read",  "percent"),
            toggle_item("Days of reading",  "book_days"),
            toggle_item("Time read",        "book_time"),
            toggle_item("Time remaining",   "book_remaining"),
        },
    }

    local menu = {}
    for _i, item in ipairs(scale_items) do menu[#menu+1] = item end
    menu[#menu+1] = source_item
    menu[#menu+1] = title_pos_item
    menu[#menu+1] = items_item
    menu[#menu+1] = {
        text           = _lc("Show finished books"),
        checked_func   = function() return showFinished(pfx) end,
        keep_menu_open = true,
        callback       = function()
            G_reader_settings:saveSetting(pfx .. SETTING_SHOW_FINISHED, not showFinished(pfx))
            refresh()
        end,
    }
    return menu
end

return M