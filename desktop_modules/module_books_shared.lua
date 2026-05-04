-- module_books_shared.lua — Simple UI
-- Helpers shared by the Currently Reading and Recent Books modules:
-- cover loading, book data, progress bar, prefetch, formatTimeLeft.
-- Not a module — no id or build(). Pure shared utilities.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local lfs             = require("libs/libkoreader-lfs")
local Config          = require("sui_config")

local SH = {}

-- ---------------------------------------------------------------------------
-- applyCustomProps — overlay custom_metadata.lua overrides onto doc_props.
--
-- KOReader stores user-edited title/author in a *separate* file called
-- custom_metadata.lua (next to the main metadata.*.lua sidecar).  The
-- structure inside it is:
--   custom_props = { title = "...", authors = "..." }   <- user overrides
--   doc_props    = { title = "...", authors = "..." }   <- original copy
--
-- DS.open() only reads the main sidecar, so ds:readSetting("doc_props")
-- always returns the original (unedited) values.  We must open
-- custom_metadata.lua separately and let its custom_props win.
--
-- This mirrors what BookInfo.extendProps() does in KOReader core, which is
-- why History and the library show the correct custom values while SimpleUI
-- homescreen modules (Currently Reading, Recent) showed the originals.
-- ---------------------------------------------------------------------------
local _DS_for_custom = nil
local function _getDS()
    if not _DS_for_custom then
        local ok, ds = pcall(require, "docsettings")
        if ok then _DS_for_custom = ds end
    end
    return _DS_for_custom
end

local function applyCustomProps(fp, title, authors)
    local DS = _getDS()
    if not DS then return title, authors end
    -- findCustomMetadataFile is an instance method (:), so pass DS as self + fp as arg.
    local ok, custom_file = pcall(DS.findCustomMetadataFile, DS, fp)
    if not ok or not custom_file then return title, authors end
    -- openSettingsFile is a STATIC function (.), not an instance method.
    -- Correct call: DS.openSettingsFile(custom_file) — do NOT pass DS as first arg.
    local ok2, cs = pcall(DS.openSettingsFile, custom_file)
    if not ok2 or not cs then return title, authors end
    local custom_props = cs:readSetting("custom_props") or {}
    return custom_props.title   or title,
           custom_props.authors or authors
end

-- ---------------------------------------------------------------------------
-- Base dimensions — computed once at load time from device DPI.
-- These are the 100%-scale reference values; never modify them at runtime.
-- ---------------------------------------------------------------------------
local _BASE_COVER_W  = Screen:scaleBySize(122)
local _BASE_COVER_H  = math.floor(Screen:scaleBySize(122) * 3 / 2)
local _BASE_RECENT_W = Screen:scaleBySize(75)
local _BASE_RECENT_H = Screen:scaleBySize(112)
local _BASE_RB_GAP1    = Screen:scaleBySize(4)
local _BASE_RB_BAR_H   = Screen:scaleBySize(5)
local _BASE_RB_GAP2    = Screen:scaleBySize(3)
local _BASE_RB_LABEL_H = Screen:scaleBySize(14)

-- Flat aliases kept for any call-site that reads SH.COVER_W etc. directly
-- without going through getDims(). These always reflect 100% scale and are
-- present only for backward-compat — new code should use getDims().
SH.COVER_W       = _BASE_COVER_W
SH.COVER_H       = _BASE_COVER_H
SH.RECENT_W      = _BASE_RECENT_W
SH.RECENT_H      = _BASE_RECENT_H
SH.RB_GAP1       = _BASE_RB_GAP1
SH.RB_BAR_H      = _BASE_RB_BAR_H
SH.RB_GAP2       = _BASE_RB_GAP2
SH.RECENT_CELL_H = _BASE_RECENT_H + _BASE_RB_GAP1 + _BASE_RB_BAR_H
                   + _BASE_RB_GAP2 + _BASE_RB_LABEL_H

-- ---------------------------------------------------------------------------
-- getDims(scale) — returns a table of scaled dimensions for one render pass.
-- Called at the top of build() / getHeight() in module_currently and
-- module_recent.  Keeps all math in one place; modules stay declarative.
--
-- scale: float from Config.getModuleScale() — e.g. 0.75, 1.0, 1.25.
-- Returns a plain table (no metatable overhead); keys mirror SH flat names.
-- ---------------------------------------------------------------------------
-- getDims(scale, thumb_scale)
-- scale:       overall module scale (affects everything)
-- thumb_scale: independent cover/thumbnail scale multiplier (affects cover dims only).
--              Text, progress bar and gaps follow only `scale`.
--              Pass nil or 1.0 to apply no thumb adjustment.
function SH.getDims(scale, thumb_scale)
    scale       = scale       or 1.0
    thumb_scale = thumb_scale or 1.0
    -- Combined scale applied to cover dimensions only.
    local cs = scale * thumb_scale
    if scale == 1.0 and thumb_scale == 1.0 then
        -- Fast path: return the pre-computed base values without any math.
        return {
            COVER_W       = _BASE_COVER_W,
            COVER_H       = _BASE_COVER_H,
            RECENT_W      = _BASE_RECENT_W,
            RECENT_H      = _BASE_RECENT_H,
            RB_GAP1       = _BASE_RB_GAP1,
            RB_BAR_H      = _BASE_RB_BAR_H,
            RB_GAP2       = _BASE_RB_GAP2,
            RB_LABEL_H    = _BASE_RB_LABEL_H,
            RECENT_CELL_H = SH.RECENT_CELL_H,
        }
    end
    -- Text/bar/gap dims scale with `scale` only — unaffected by thumb_scale.
    local g1  = math.max(1, math.floor(_BASE_RB_GAP1    * scale))
    local bh  = math.max(1, math.floor(_BASE_RB_BAR_H   * scale))
    local g2  = math.max(1, math.floor(_BASE_RB_GAP2    * scale))
    local lh  = math.max(1, math.floor(_BASE_RB_LABEL_H * scale))
    -- Cover dims scale with the combined scale (scale × thumb_scale).
    local rh  = math.floor(_BASE_RECENT_H * cs)
    -- RECENT_CELL_H = cover height + bar + gaps + label — each part scaled independently.
    return {
        COVER_W       = math.floor(_BASE_COVER_W  * cs),
        COVER_H       = math.floor(_BASE_COVER_H  * cs),
        RECENT_W      = math.floor(_BASE_RECENT_W * cs),
        RECENT_H      = rh,
        RB_GAP1       = g1,
        RB_BAR_H      = bh,
        RB_GAP2       = g2,
        RB_LABEL_H    = lh,
        RECENT_CELL_H = rh + g1 + bh + g2 + lh,
    }
end

local _CLR_COVER_BORDER = Blitbuffer.COLOR_BLACK
local _CLR_COVER_BG     = Blitbuffer.gray(0.88)
local _CLR_BAR_BG       = Blitbuffer.gray(0.15)
local _CLR_BAR_FG       = Blitbuffer.gray(0.75)

-- ---------------------------------------------------------------------------
-- vspan pool helper
-- ---------------------------------------------------------------------------
function SH.vspan(px, pool)
    if pool then
        if not pool[px] then pool[px] = VerticalSpan:new{ width = px } end
        return pool[px]
    end
    return VerticalSpan:new{ width = px }
end

-- ---------------------------------------------------------------------------
-- pctStr — canonical percentage formatter for book-progress values.
--
-- Uses string.format("%.0f", …) which delegates rounding to the C runtime
-- (round-half-away-from-zero on all platforms KOReader targets).  This is
-- correct for progress values such as 0.995 → "100%", 0.994 → "99%".
--
-- Always use this instead of math.floor(pct * 100) to avoid truncation bugs
-- (e.g. 0.569 stored as 0.5689999… truncates to 56 instead of rounding to 57).
-- ---------------------------------------------------------------------------
function SH.pctStr(pct)
    return string.format("%.0f%%", (pct or 0) * 100)
end

-- ---------------------------------------------------------------------------
-- progressBar
-- ---------------------------------------------------------------------------
function SH.progressBar(w, pct, bh)
    bh = bh or Screen:scaleBySize(4)
    local fw = math.max(0, math.floor(w * math.min(pct or 0, 1.0)))
    if fw <= 0 then
        return LineWidget:new{ dimen = Geom:new{ w = w, h = bh }, background = _CLR_BAR_BG }
    end
    return OverlapGroup:new{
        dimen = Geom:new{ w = w, h = bh },
        LineWidget:new{ dimen = Geom:new{ w = w,  h = bh }, background = _CLR_BAR_BG },
        LineWidget:new{ dimen = Geom:new{ w = fw, h = bh }, background = _CLR_BAR_FG },
    }
end

-- ---------------------------------------------------------------------------
-- coverPlaceholder
-- ---------------------------------------------------------------------------
-- Helper function to safely extract first n UTF-8 characters for placeholder text
local function safeFirstChars(s, n)
    if not s or n <= 0 then return "" end
    local chars = {}
    local i = 1
    local count = 0
    while i <= #s and count < n do
        local byte = s:byte(i)
        -- Calculate the byte length of the current UTF-8 character
        local charLen = 1
        if byte >= 240 then
            charLen = 4
        elseif byte >= 224 then
            charLen = 3
        elseif byte >= 192 then
            charLen = 2
        end
        chars[#chars + 1] = s:sub(i, i + charLen - 1)
        count = count + 1
        i = i + charLen
    end
    return table.concat(chars)
end

function SH.coverPlaceholder(title, w, h)
    return FrameContainer:new{
        bordersize = 1, color = _CLR_COVER_BORDER,
        background = _CLR_COVER_BG, padding = 0,
        dimen      = Geom:new{ w = w, h = h },
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            TextWidget:new{
                text = safeFirstChars(title or "?", 2):upper(),
                face = Font:getFace("smallinfofont", Screen:scaleBySize(18)),
                bold = true,
            },
        },
    }
end

-- ---------------------------------------------------------------------------
-- getBookCover
-- ---------------------------------------------------------------------------
function SH.getBookCover(filepath, w, h, align, stretch_limit)
    -- Reserve 1px on each side for the border: request a bb that is 2px smaller.
    local inner_w = math.max(1, w - 2)
    local inner_h = math.max(1, h - 2)
    local bb = Config.getCoverBB(filepath, inner_w, inner_h, align, stretch_limit)
    if not bb then return nil end
    local ok, img = pcall(function()
        return require("ui/widget/imagewidget"):new{
            image            = bb,
            image_disposable = false,  -- bb is owned by the cover cache; must not be freed here
            width            = inner_w,
            height           = inner_h,
            -- bb is already scaled to exactly inner_w×inner_h by getCoverBB.
            scale_factor     = 1,
        }
    end)
    if not (ok and img) then return nil end
    -- padding=0 + bordersize=1: the FrameContainer outer size is inner_w+2 × inner_h+2 = w×h.
    return FrameContainer:new{
        bordersize = 1, color = _CLR_COVER_BORDER,
        padding    = 0, margin = 0,
        dimen      = Geom:new{ w = w, h = h },
        img,
    }
end

-- ---------------------------------------------------------------------------
-- formatTimeLeft
-- ---------------------------------------------------------------------------
function SH.formatTimeLeft(pct, pages, avg_time)
    if not avg_time or avg_time <= 0 or not pct or pct < 0 or not pages then return nil end
    local remaining = math.floor(pages * (1.0 - pct))
    if remaining <= 0 then return nil end
    local secs = math.floor(remaining * avg_time)
    if secs <= 0 then return nil end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 and m > 0 then return string.format("%dh %dm", h, m)
    elseif h > 0        then return string.format("%dh", h)
    else                     return string.format("%dm", m) end
end

-- ---------------------------------------------------------------------------
-- getBookData
-- ---------------------------------------------------------------------------
local _DocSettings = nil
local function getDocSettings()
    if not _DocSettings then
        local ok, ds = pcall(require, "docsettings")
        if ok then _DocSettings = ds end
    end
    return _DocSettings
end

-- ---------------------------------------------------------------------------
-- Sidecar metadata cache — invalidated by mtime, lives for the process lifetime.
--
-- Each entry: { sidecar_path, mtime, preferred_loc, data={...} }
-- where data holds all keys extracted by prefetchBooks + summary for countMarkedRead.
--
-- Cost per cache hit: 1 lfs.attributes("modification") instead of ~15 syscalls
-- + 1 dofile. Cache miss falls through to the normal DS.open path.
-- ---------------------------------------------------------------------------
local _sidecar_cache = {}

-- Returns the preferred_location string used as part of cache validation.
-- Reading G_reader_settings is a table lookup — no IO.
local function _prefLoc()
    return G_reader_settings:readSetting("document_metadata_folder", "doc")
end

-- Returns cached data table for fp, or nil on miss / stale entry.
local function _cacheGet(fp)
    local e = _sidecar_cache[fp]
    if not e then return nil end
    -- Invalidate if the user changed metadata location between sessions.
    if e.preferred_loc ~= _prefLoc() then
        _sidecar_cache[fp] = nil
        return nil
    end
    -- 1 syscall: stat the sidecar file we recorded on last DS.open.
    local mtime = lfs.attributes(e.sidecar_path, "modification")
    if mtime ~= e.mtime then
        _sidecar_cache[fp] = nil
        return nil
    end
    -- Also invalidate when custom_metadata.lua has changed (user edited title/author).
    -- custom_mtime is nil when no custom_metadata.lua existed at cache-fill time;
    -- a new non-nil mtime means the file was just created → invalidate.
    if e.custom_mtime ~= lfs.attributes(e.custom_path or "", "modification") then
        _sidecar_cache[fp] = nil
        return nil
    end
    return e.data
end

-- Stores a cache entry after a successful DS.open.
-- source_candidate is ds.source_candidate (the winning sidecar path chosen by DS.open).
local function _cachePut(fp, source_candidate, data)
    if not source_candidate then return end
    local mtime = lfs.attributes(source_candidate, "modification")
    if not mtime then return end
    -- Also record the custom_metadata.lua path and mtime so _cacheGet can
    -- detect when the user edits title/author via "Book information".
    local DS_c = _getDS()
    local custom_path, custom_mtime
    if DS_c then
        local ok, cp = pcall(DS_c.findCustomMetadataFile, DS_c, fp)
        if ok and cp then
            custom_path  = cp
            custom_mtime = lfs.attributes(cp, "modification")
        end
    end
    _sidecar_cache[fp] = {
        sidecar_path  = source_candidate,
        mtime         = mtime,
        preferred_loc = _prefLoc(),
        custom_path   = custom_path,
        custom_mtime  = custom_mtime,
        data          = data,
    }
end

-- Expose the sidecar cache accessors as part of the module API so that
-- module_stats_provider can share the same cache in countMarkedReadBoth
-- without creating a circular dependency or reaching into internals.
-- These are considered semi-internal (prefix _) but are stable across versions.
SH._cacheGet = _cacheGet
SH._cachePut = _cachePut

-- Invalidate one entry (call before prefetchBooks for the just-closed book)
-- or flush everything (fp == nil).
function SH.invalidateSidecarCache(fp)
    if fp then
        _sidecar_cache[fp] = nil
    else
        _sidecar_cache = {}
    end
end

function SH.getBookData(filepath, prefetched)
    local meta = {}
    local percent, pages, md5, stat_pages, stat_total_time = 0, nil, nil, nil, nil

    if prefetched then
        -- Fast path: use data already extracted by prefetchBooks.
        percent         = prefetched.percent or 0
        pages           = prefetched.doc_pages
        md5             = prefetched.partial_md5_checksum
        stat_pages      = prefetched.stat_pages
        stat_total_time = prefetched.stat_total_time
        meta.title      = prefetched.title
        meta.authors    = prefetched.authors
    elseif prefetched ~= false then
        -- prefetched==nil means prefetchBooks was not called (e.g. direct call).
        -- prefetched==false means prefetchBooks tried but DS.open failed — skip
        -- the lfs.attributes syscall and DS.open retry; fall through with defaults.
        local DS = getDocSettings()
        if DS and lfs.attributes(filepath, "mode") == "file" then
            local ok2, ds = pcall(DS.open, DS, filepath)
            if ok2 and ds then
                percent         = ds:readSetting("percent_finished") or 0
                pages           = ds:readSetting("doc_pages")
                md5             = ds:readSetting("partial_md5_checksum")
                local rp        = ds:readSetting("doc_props") or {}
                local rs        = ds:readSetting("stats") or {}
                meta.title, meta.authors = applyCustomProps(filepath, rp.title, rp.authors)
                stat_pages      = rs.pages
                stat_total_time = rs.total_time_in_sec
            end
        end
    end

    if not meta.title then
        meta.title = filepath:match("([^/]+)%.[^%.]+$") or "?"
    end

    local avg_time
    -- Source 1: live ReaderUI session — most accurate when a book is open.
    pcall(function()
        local ReaderUI = package.loaded["apps/reader/readerui"]
        if ReaderUI and ReaderUI.instance then
            local stats = ReaderUI.instance.statistics
            if stats and stats.avg_time and stats.avg_time > 0 then
                -- Only use if this is the same book currently being read.
                local rui_fp = ReaderUI.instance.document
                    and ReaderUI.instance.document.file
                if rui_fp == filepath then
                    avg_time = stats.avg_time
                end
            end
        end
    end)
    -- Source 2: doc settings stats (written by Statistics plugin on close).
    -- The capped avg_time from the stats DB is computed by fetchBookStats()
    -- in module_currently and passed back via bstats — callers that need
    -- the DB-backed value should use that instead of querying here again.
    if not avg_time and stat_pages and stat_pages > 0
            and stat_total_time and stat_total_time > 0 then
        avg_time = stat_total_time / stat_pages
    end

    return {
        percent  = percent,
        title    = meta.title,
        authors  = meta.authors or "",
        pages    = pages,
        avg_time = avg_time,
    }
end

-- ---------------------------------------------------------------------------
-- prefetchBooks — reads history, pre-extracts book metadata.
-- Called once per Homescreen render; result cached per open instance.
-- ---------------------------------------------------------------------------
-- NOTE: _cover_extraction_pending was removed from SH.
-- Use Config.cover_extraction_pending (the single source of truth) instead.

function SH.prefetchBooks(show_currently, show_recent, max_recent, show_finished)
    max_recent = max_recent or 5
    local state = { current_fp = nil, recent_fps = {}, prefetched_data = {} }
    if not show_currently and not show_recent then return state end

    local ReadHistory = package.loaded["readhistory"] or require("readhistory")
    if not ReadHistory then return state end
    if not ReadHistory.hist or #ReadHistory.hist == 0 then
        pcall(function() ReadHistory:reload() end)
    end

    local DS = getDocSettings()
    -- hist[1] is the most recently read book.
    -- • show_currently=true  → claim it as current_fp; never add to recent_fps.
    -- • show_currently=false → treat it like any other entry for recent_fps.
    -- Always start at index 1 so hist[1] is never silently dropped.
    for i = 1, #(ReadHistory.hist or {}) do
        local entry = ReadHistory.hist[i]
        local fp = entry and entry.file
        if fp and lfs.attributes(fp, "mode") == "file" then
            if i == 1 and show_currently then
                -- Claim as currently-reading book.
                state.current_fp = fp
                if DS then
                    local cached = _cacheGet(fp)
                    if cached then
                        -- Re-apply custom props on the cache-hit path.
                        -- The cached title/authors may predate a metadata edit
                        -- or predate this fix. applyCustomProps is cheap (stat calls only).
                        local _ct, _ca = applyCustomProps(fp, cached.title, cached.authors)
                        if _ct ~= cached.title or _ca ~= cached.authors then
                            -- Clone only when values differ to avoid mutating the shared cache entry.
                            local patched = {}
                            for k, v in pairs(cached) do patched[k] = v end
                            patched.title   = _ct
                            patched.authors = _ca
                            state.prefetched_data[fp] = patched
                        else
                            state.prefetched_data[fp] = cached
                        end
                    else
                        local ok2, ds = pcall(DS.open, DS, fp)
                        if ok2 and ds then
                            local rp = ds:readSetting("doc_props") or {}
                            local rs = ds:readSetting("stats") or {}
                            local _t, _a = applyCustomProps(fp, rp.title, rp.authors)
                            local data = {
                                percent              = ds:readSetting("percent_finished") or 0,
                                title                = _t,
                                authors              = _a,
                                doc_pages            = ds:readSetting("doc_pages"),
                                partial_md5_checksum = ds:readSetting("partial_md5_checksum"),
                                stat_pages           = rs.pages,
                                stat_total_time      = rs.total_time_in_sec,
                                summary              = ds:readSetting("summary"),
                            }
                            _cachePut(fp, ds.source_candidate, data)
                            pcall(function() ds:close() end)
                            state.prefetched_data[fp] = data
                        else
                            -- Signal that DS.open was attempted but failed — getBookData
                            -- will skip the lfs.attributes syscall and DS.open retry.
                            state.prefetched_data[fp] = false
                        end
                    end
                end
            elseif show_recent and #state.recent_fps < max_recent then
                -- i==1 only reaches here when show_currently==false, so hist[1]
                -- is correctly included in recent rather than being skipped.
                local pct = 0
                local book_summary = nil
                if DS then
                    local cached = _cacheGet(fp)
                    if cached then
                        pct = cached.percent
                        book_summary = cached.summary
                        -- Re-apply custom props on the cache-hit path.
                        local _ct, _ca = applyCustomProps(fp, cached.title, cached.authors)
                        if _ct ~= cached.title or _ca ~= cached.authors then
                            local patched = {}
                            for k, v in pairs(cached) do patched[k] = v end
                            patched.title   = _ct
                            patched.authors = _ca
                            state.prefetched_data[fp] = patched
                        else
                            state.prefetched_data[fp] = cached
                        end
                    else
                        local ok2, ds = pcall(DS.open, DS, fp)
                        if ok2 and ds then
                            pct    = ds:readSetting("percent_finished") or 0
                            book_summary = ds:readSetting("summary")
                            local rp = ds:readSetting("doc_props") or {}
                            local rs = ds:readSetting("stats") or {}
                            local _t, _a = applyCustomProps(fp, rp.title, rp.authors)
                            local data = {
                                percent              = pct,
                                title                = _t,
                                authors              = _a,
                                doc_pages            = ds:readSetting("doc_pages"),
                                partial_md5_checksum = ds:readSetting("partial_md5_checksum"),
                                stat_pages           = rs.pages,
                                stat_total_time      = rs.total_time_in_sec,
                                summary              = book_summary,
                            }
                            _cachePut(fp, ds.source_candidate, data)
                            pcall(function() ds:close() end)
                            state.prefetched_data[fp] = data
                        else
                            state.prefetched_data[fp] = false
                        end
                    end
                end
                -- Exclude books that are 100% read or explicitly marked as complete,
                -- unless the caller has opted in to showing finished books.
                local is_complete = type(book_summary) == "table" and book_summary.status == "complete"
                if show_finished or (pct < 1.0 and not is_complete) then
                    state.recent_fps[#state.recent_fps + 1] = fp
                end
            end
        end
        if not show_recent and state.current_fp then break end
        if state.current_fp and #state.recent_fps >= max_recent then break end
    end
    return state
end


-- ---------------------------------------------------------------------------
-- Sidecar helpers
-- ---------------------------------------------------------------------------


return SH