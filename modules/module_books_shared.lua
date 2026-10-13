-- module_books_shared.lua — Simple UI
-- Helpers shared by the Currently Reading and Recent Books modules:
-- cover loading, book data, progress bar, prefetch, formatTimeLeft.
-- Not a module — no id or build(). Pure shared utilities.

local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local lfs             = require("libs/libkoreader-lfs")
local util            = require("util")
local Config          = require("infra/sui_config")
local SUIStyle        = require("features/sui_style")
local CoverPlaceholder = require("engines/sui_cover_placeholder")

local math_floor = math.floor
local math_max   = math.max
local math_min   = math.min

-- Returns the KOBO_VIRTUAL:// path for a real kepub filepath when the
-- kobo.koplugin is active, or the original filepath otherwise.
-- This ensures that covers and sidecars are looked up via the virtual path
-- (which the kobo.koplugin's BookInfoManager patch understands), and that
-- openBook always passes a virtual path to DocumentRegistry so DRM
-- decryption is triggered correctly.
local function _koboVirtualPath(fp)
    local ok, PluginLoader = pcall(require, "pluginloader")
    if not ok or not PluginLoader then return fp end
    local kobo = PluginLoader:getPluginInstance("kobo_plugin")
    if not kobo or not kobo.virtual_library then return fp end
    local vl = kobo.virtual_library
    if vl:isVirtualPath(fp) then return fp end
    if not next(vl.virtual_to_real) then
        pcall(function() vl:buildPathMappings() end)
    end
    return vl:getVirtualPath(fp) or fp
end

local SH = {}

-- ---------------------------------------------------------------------------
-- Lazy loaders for KOReader modules that are only needed once books are read.
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
-- Base dimensions — computed once at load time from device DPI.
-- These are the 100%-scale reference values; never modify them at runtime.
-- ---------------------------------------------------------------------------
local _BASE_COVER_W  = Screen:scaleBySize(122)
local _BASE_COVER_H  = math_floor(Screen:scaleBySize(122) * 3 / 2)
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
    local g1  = math_max(1, math_floor(_BASE_RB_GAP1    * scale))
    local bh  = math_max(1, math_floor(_BASE_RB_BAR_H   * scale))
    local g2  = math_max(1, math_floor(_BASE_RB_GAP2    * scale))
    local lh  = math_max(1, math_floor(_BASE_RB_LABEL_H * scale))
    -- Cover dims scale with the combined scale (scale × thumb_scale).
    local rh  = math_floor(_BASE_RECENT_H * cs)
    -- RECENT_CELL_H = cover height + bar + gaps + label — each part scaled independently.
    return {
        COVER_W       = math_floor(_BASE_COVER_W  * cs),
        COVER_H       = math_floor(_BASE_COVER_H  * cs),
        RECENT_W      = math_floor(_BASE_RECENT_W * cs),
        RECENT_H      = rh,
        RB_GAP1       = g1,
        RB_BAR_H      = bh,
        RB_GAP2       = g2,
        RB_LABEL_H    = lh,
        RECENT_CELL_H = rh + g1 + bh + g2 + lh,
    }
end


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

local _CoverWidgets = nil
local function getCoverWidgets()
    if not _CoverWidgets then
        local ok, m = pcall(require, "features/library/sui_cover_widgets")
        if ok and m then _CoverWidgets = m end
    end
    return _CoverWidgets
end

-- ---------------------------------------------------------------------------
-- Cover shadow
--
-- Every cover builder below draws its card in a w × h slot. With the cover
-- shadow enabled the card shrinks by the shadow's depth and the shadow takes
-- the room that frees up on the right and bottom, so the slot — and every
-- layout computed from it — keeps its size.
--
-- Builders take a trailing `layered` flag. When set, the card is built without
-- its shadow and the caller places SH.buildOverlapShadow() right beneath it, so
-- the shadow falls on the covers it overlaps.

-- buildShadow(w, h) → shadow widget for a single cover slot of w × h, or nil
-- while the cover shadow is disabled. Place it at the slot's top-left corner.
local function buildShadow(w, h)
    local inset = SUIStyle.coverShadowOffset(SUIStyle.SHADOW_MODULES)
    return getCoverWidgets().buildShadow(w - inset, h - inset, inset)
end

-- buildOverlapShadow(x, y, w, h) → shadow widget for the cover slot of w × h at
-- (x, y), or nil while the cover shadow is disabled. The widget carries its own
-- overlap_offset.
function SH.buildOverlapShadow(x, y, w, h)
    local shadow = buildShadow(w, h)
    if shadow then shadow.overlap_offset = { x, y } end
    return shadow
end

-- withShadow(w, h, layered, build, ...) → widget of size w × h, or nil when
-- build() fails. build(card_w, card_h, ...) returns the card widget.
local function withShadow(w, h, layered, build, ...)
    local inset = SUIStyle.coverShadowOffset(SUIStyle.SHADOW_MODULES)
    if inset == 0 then return build(w, h, ...) end
    local card = build(w - inset, h - inset, ...)
    if not card then return nil end
    local slot = OverlapGroup:new{ dimen = Geom:new{ w = w, h = h } }
    if not layered then slot[#slot + 1] = buildShadow(w, h) end
    slot[#slot + 1] = card
    return slot
end

-- ---------------------------------------------------------------------------
-- coverPlaceholder
-- ---------------------------------------------------------------------------
-- Generated cover for books without a cover image (see
-- engines/sui_cover_placeholder.lua).
--
-- title   : book title string
-- authors : book authors string (or nil)
-- w, h    : exact pixel dimensions of the cell
-- align   : "left" | "right" for a narrow slot that shows a slice of the full
--           cover from that edge (see SH.getCroppedBookCover); nil otherwise
function SH.coverPlaceholder(title, authors, w, h, layered, align)
    -- Backwards-compat: old call sites used (title, w, h) with 3 args.
    -- Detect by checking whether `authors` is a number (the old w slot).
    if type(authors) == "number" then
        h = w; w = authors; authors = nil
    end
    local build = align and CoverPlaceholder.buildCropped or CoverPlaceholder.build
    return withShadow(tonumber(w) or 100, tonumber(h) or 150, layered, build, title, authors, align)
end

-- ---------------------------------------------------------------------------
-- getBookCover
-- ---------------------------------------------------------------------------
local function buildBookCover(w, h, filepath)
    -- Reserve 1px on each side for the border: request a bb that is 2px smaller.
    local inner_w = math_max(1, w - 2)
    local inner_h = math_max(1, h - 2)
    local bb = Config.getStretchedCoverBB(filepath, inner_w, inner_h)
    if not bb then return nil end
    local ok, img = pcall(function()
        return require("ui/widget/imagewidget"):new{
            image            = bb,
            image_disposable = false,  -- bb is owned by the cover cache; must not be freed here
            width            = inner_w,
            height           = inner_h,
            -- bb may be LARGER than inner_w x inner_h: the cache keeps one
            -- entry per book, sized to the largest request seen this
            -- session (infra/sui_cover_cache.lua). Every caller of this
            -- function targets the same fixed 3:2 shape, so a bigger bb is
            -- the same shape at a bigger size, never a different crop —
            -- no scale_factor is set here, so ImageWidget resizes to
            -- inner_w x inner_h at paint time, which is a plain uniform
            -- downscale in that case (or a no-op blit when the cache
            -- already holds our exact size).
        }
    end)
    if not (ok and img) then return nil end
    -- padding=0 + bordersize=1: the FrameContainer outer size is inner_w+2 × inner_h+2 = w×h.
    return FrameContainer:new{
        bordersize = SUIStyle.BADGE_BORDER_SZ, color = SUIStyle.COLOR.text_primary,
        padding    = 0, margin = 0,
        dimen      = Geom:new{ w = w, h = h },
        img,
    }
end

function SH.getBookCover(filepath, w, h, layered)
    return withShadow(w, h, layered, buildBookCover, filepath)
end

-- ---------------------------------------------------------------------------
-- getCroppedBookCover — for callers whose target box is NOT the plugin's
-- fixed 3:2 shape and needs to be filled edge-to-edge with no distortion
-- (crop-to-fill, not stretch). Currently: CoverDeck's near/far "peek"
-- slots, deliberately narrower-than-3:2 slivers meant to look like a book
-- partly hidden behind the centre cover — see module_coverdeck.lua's
-- side_w/h and far_w/h. Do NOT use this for anything that's actually 3:2;
-- use SH.getBookCover for that (shared, session-max-sized cache — see its
-- comment above for why that's both cheaper and correct there).
-- ---------------------------------------------------------------------------
local function buildCroppedBookCover(w, h, filepath, align)
    local inner_w = math_max(1, w - 2)
    local inner_h = math_max(1, h - 2)
    local bb = Config.getCroppedCoverBB(filepath, inner_w, inner_h, align)
    if not bb then return nil end
    local ok, img = pcall(function()
        return require("ui/widget/imagewidget"):new{
            image            = bb,
            image_disposable = false,  -- bb is owned by the cover cache; must not be freed here
            width            = inner_w,
            height           = inner_h,
            -- getCroppedCoverBB always returns a bb at exactly inner_w x
            -- inner_h (crop-to-fill, unlike the stretch-only cache above) —
            -- safe to pin scale_factor=1 here, there is never a resize to
            -- do at paint time.
            scale_factor     = 1,
        }
    end)
    if not (ok and img) then return nil end
    return FrameContainer:new{
        bordersize = SUIStyle.BADGE_BORDER_SZ, color = SUIStyle.COLOR.text_primary,
        padding    = 0, margin = 0,
        dimen      = Geom:new{ w = w, h = h },
        img,
    }
end

function SH.getCroppedBookCover(filepath, w, h, align, layered)
    return withShadow(w, h, layered, buildCroppedBookCover, filepath, align)
end

-- ---------------------------------------------------------------------------
-- Progress badge helpers — single drawing path for the progress pentagon.
-- Used by single-cover modules (Currently Reading, Coverdeck) and by the
-- book-grid engine so the badge looks identical everywhere.
--
-- buildProgressBadgeWidget(bd, eff_size, color) → widget|nil
--   Pure builder. color is "dark"|"light"|nil (nil follows Library).
--   Book-grid callers place the widget into their multi-badge OverlapGroup.
--
-- applyProgressBadge(cover_widget, bd, cw, ch, color, ref_w, ref_h, scale_pct)
--   Convenience for single-cover modules: computes size/margin, builds
--   the badge, wraps in OverlapGroup. ref_w/ref_h keep size consistent
--   on narrower peeks. scale_pct (default 100) scales the badge only; its
--   edge margin stays fixed.
-- ---------------------------------------------------------------------------
local _FC = nil
local function getFC()
    if not _FC then
        local ok, m = pcall(require, "features/library/sui_foldercovers")
        if ok and m then _FC = m end
    end
    return _FC
end

local function _resolveProgressBadgeDark(color)
    local resolved = color
    if not resolved then
        local fc = getFC()
        resolved = (fc and fc.getBadgeColorProgress and fc.getBadgeColorProgress()) or "dark"
    end
    return resolved == "dark"
end

-- Builds the progress pentagon widget (or nil). Callers that compose
-- multiple badges (book grid) place it themselves; single-cover callers
-- use applyProgressBadge instead.
function SH.buildProgressBadgeWidget(bd, eff_size, color)
    local has_progress = (bd.percent or 0) > 0 or bd.status == "complete" or bd.status == "abandoned"
    if not has_progress then return nil end
    local CW = getCoverWidgets()
    if not CW then return nil end
    local dark = _resolveProgressBadgeDark(color)
    local desc = CW.buildProgressBadgeDesc(eff_size, bd.status, bd.percent, SUIStyle.BADGE_BORDER_SZ, dark)
    return CW.buildProgressBadgeWidget(desc)
end

function SH.applyProgressBadge(cover_widget, bd, cw, ch, color, ref_w, ref_h, scale_pct)
    local base_min, fit = math_min(cw, ch), 1
    if ref_h and ref_h > 0 and ref_w and ref_w > 0 then
        base_min, fit = math_min(ref_w, ref_h), ch / ref_h
    end
    local edge_margin = math_max(1, math_floor(base_min * 0.08 * fit))
    local eff_size    = math_max(8, math_floor(base_min * 0.14 * fit * ((scale_pct or 100) / 100)))

    local wg = SH.buildProgressBadgeWidget(bd, eff_size, color)
    if not wg then return cover_widget end

    local sz = wg:getSize()
    -- The badge sits on the card, not on the room its shadow takes.
    wg.overlap_offset = { cw - SUIStyle.coverShadowOffset(SUIStyle.SHADOW_MODULES) - sz.w - edge_margin, 0 }

    local overlap = OverlapGroup:new{ dimen = Geom:new{ w = cw, h = ch }, cover_widget }
    overlap[#overlap + 1] = wg
    return overlap
end

-- ---------------------------------------------------------------------------
-- formatTimeLeft
-- ---------------------------------------------------------------------------
function SH.formatTimeLeft(pct, pages, avg_time)
    if not avg_time or avg_time <= 0 or not pct or pct < 0 or not pages then return nil end
    local remaining = math_floor(pages * (1.0 - pct))
    if remaining <= 0 then return nil end
    local secs = math_floor(remaining * avg_time)
    if secs <= 0 then return nil end
    local h = math_floor(secs / 3600)
    local m = math_floor((secs % 3600) / 60)
    if h > 0 and m > 0 then return string.format("%dh %dm", h, m)
    elseif h > 0        then return string.format("%dh", h)
    else                     return string.format("%dm", m) end
end

-- ---------------------------------------------------------------------------
-- getBookData
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Sidecar data cache — validated on every read, lives for the process lifetime.
--
-- Each entry: { sidecar_path, mtime, preferred_loc, custom_path, custom_mtime,
-- data }. `data` holds the fields read from the sidecar: percent, title,
-- authors, doc_pages, partial_md5_checksum, stat_pages, stat_total_time and
-- summary. Title and authors already carry the custom_metadata.lua overrides.
-- A book without a sidecar is cached too, with no sidecar_path and default
-- data, and stays valid until a sidecar shows up.
--
-- A hit costs two stats (sidecar and custom metadata; a few more for a book
-- without either) instead of the ~15 syscalls and the parse of a
-- DocSettings.open.
-- ---------------------------------------------------------------------------
local _sidecar_cache = {}
local _bim_fields    = {}   -- fp -> fields resolved from its BookInfoManager record

-- Returns the preferred_location string used as part of cache validation.
-- Reading G_reader_settings is a table lookup — no IO.
local function _prefLoc()
    return G_reader_settings:readSetting("document_metadata_folder", "doc")
end

-- True when a lookup of `finder` (a DocSettings method taking the book path)
-- finds a file for fp.
local function _docSettingsFinds(finder, fp)
    local DS = getDocSettings()
    if not DS then return false end
    local ok, path = pcall(DS[finder], DS, fp)
    return (ok and path) and true or false
end

-- True when the sidecar state recorded in `entry` no longer matches the disk:
-- the file changed or moved, or one appeared for a book that had none.
local function _sidecarChanged(entry, fp)
    if entry.sidecar_path then
        return lfs.attributes(entry.sidecar_path, "modification") ~= entry.mtime
    end
    return _docSettingsFinds("findSidecarFile", fp)
end

-- Same for the custom metadata file.
local function _customMetadataChanged(entry, fp)
    if entry.custom_path then
        return lfs.attributes(entry.custom_path, "modification") ~= entry.custom_mtime
    end
    return _docSettingsFinds("findCustomMetadataFile", fp)
end

-- Returns cached data table for fp, or nil on miss / stale entry.
local function _cacheGet(fp)
    local entry = _sidecar_cache[fp]
    if not entry then return nil end
    if entry.preferred_loc ~= _prefLoc()
            or _sidecarChanged(entry, fp)
            or _customMetadataChanged(entry, fp) then
        _sidecar_cache[fp] = nil
        return nil
    end
    return entry.data
end

-- Stores `data` for fp. Title and authors are first overlaid with the user's
-- custom_metadata.lua overrides, so cached data is always ready to display.
-- `source_candidate` is the sidecar path DocSettings.open picked
-- (ds.source_candidate); without one the book has no sidecar yet.
local function _cachePut(fp, source_candidate, data)
    local DS = getDocSettings()
    local custom_path, custom_mtime
    if DS then
        local ok, path = pcall(DS.findCustomMetadataFile, DS, fp)
        if ok and path then
            custom_path  = path
            custom_mtime = lfs.attributes(path, "modification")
            local ok_open, settings = pcall(DS.openSettingsFile, path)
            local props = ok_open and settings and settings:readSetting("custom_props") or {}
            data.title   = props.title   or data.title
            data.authors = props.authors or data.authors
        end
    end
    local mtime = source_candidate and lfs.attributes(source_candidate, "modification")
    _sidecar_cache[fp] = {
        sidecar_path  = mtime and source_candidate or nil,
        mtime         = mtime,
        preferred_loc = _prefLoc(),
        custom_path   = custom_path,
        custom_mtime  = custom_mtime,
        data          = data,
    }
end

-- Reads the sidecar fields of fp and caches them. Returns nil when the
-- sidecar cannot be opened. The handle is only read from and never closed:
-- close() rewrites the whole sidecar file.
local function _loadSidecarData(DS, fp)
    local ok, ds = pcall(DS.open, DS, fp)
    if not (ok and ds) then return nil end
    local props = ds:readSetting("doc_props") or {}
    local stats = ds:readSetting("stats") or {}
    local data = {
        percent              = ds:readSetting("percent_finished") or 0,
        title                = props.title,
        authors              = props.authors,
        doc_pages            = ds:readSetting("doc_pages"),
        partial_md5_checksum = ds:readSetting("partial_md5_checksum"),
        stat_pages           = stats.pages,
        stat_total_time      = stats.total_time_in_sec,
        summary              = ds:readSetting("summary"),
    }
    _cachePut(fp, ds.source_candidate, data)
    return data
end

-- Cached sidecar data of fp, read from disk on a miss. Returns nil when the
-- sidecar cannot be read, or, with `verify_file`, when fp is not a file.
local function _sidecarData(fp, verify_file)
    local data = _cacheGet(fp)
    if data then return data end
    local DS = getDocSettings()
    if not DS or (verify_file and lfs.attributes(fp, "mode") ~= "file") then return nil end
    return _loadSidecarData(DS, fp)
end

-- Public cache-or-load sidecar accessor, shared with other modules so every
-- consumer reads the same cached record (see _loadSidecarData for its fields).
SH.sidecarData = _sidecarData

-- Whether the book at fp is finished: marked complete or read to the end.
-- Uses the book's prefetched record when there is one, else its cached
-- sidecar data.
function SH.isFinished(fp, prefetched)
    local data = (prefetched and prefetched[fp]) or _sidecarData(fp)
    if not data then return false end
    return (data.percent or 0) >= 1.0
        or (type(data.summary) == "table" and data.summary.status == "complete")
end

-- Cache accessors exposed for modules that manage entries directly.
-- Semi-internal (prefixed _) but stable.
SH._cacheGet = _cacheGet
SH._cacheGetRaw = function(fp)
    local e = _sidecar_cache[fp]
    return e and e.data
end
SH._cachePut = _cachePut

-- Drops everything cached for fp — sidecar data and BookInfoManager fields —
-- or flushes everything (fp == nil).
function SH.invalidateSidecarCache(fp)
    if fp then
        _sidecar_cache[fp], _bim_fields[fp] = nil, nil
    else
        _sidecar_cache, _bim_fields = {}, {}
    end
end

-- "p(<n>)" filename token → page count, e.g. "Caliban's War - p(624).epub".
-- A publisher/preferred page count for books SimpleUI can't page-count yet
-- (unopened reflowable formats with no BookInfoManager entry, pagemap or
-- stats). Matched case-insensitively on the basename only — used ONLY as a
-- last resort, after doc_pages/BookInfoManager, so a real rendered/stable
-- count always wins. Inert (nil) for filenames without the token.
-- Shared with features/library/sui_foldercovers.lua (single source of truth,
-- was previously duplicated there).
function SH.pageCountFromFilename(filepath)
    if type(filepath) ~= "string" then return nil end
    local base = filepath:match("([^/]+)$") or filepath
    local n = base:match("[Pp]%((%d+)%)")
    return n and tonumber(n) or nil
end

-- Live percent/summary for a filepath. Prefers BookList's in-memory
-- DocSettings (the object genStatusButtonsRow mutates on the hold dialog)
-- so a keep_cache homescreen rebuild sees the new status without waiting
-- for a disk re-open. Falls back to DocSettings.open on the sidecar file.
local function _readLiveProgress(filepath)
    local ok_bl, BookList = pcall(require, "ui/widget/booklist")
    if ok_bl and BookList and BookList.getDocSettings then
        local ok_ds, ds = pcall(BookList.getDocSettings, filepath)
        if ok_ds and ds and ds.readSetting then
            return ds:readSetting("percent_finished") or 0, ds:readSetting("summary")
        end
    end
    local DS = getDocSettings()
    if DS and lfs.attributes(filepath, "mode") == "file" then
        local ok2, ds = pcall(DS.open, DS, filepath)
        if ok2 and ds then
            return ds:readSetting("percent_finished") or 0, ds:readSetting("summary")
        end
    end
    return nil, nil
end

-- Fills the percent and summary that were cleared from prefetched `data`
-- (the hold dialog does so after a status change) from the live settings.
local function _refreshLiveProgress(filepath, data)
    if data.percent ~= nil and data.summary ~= nil then return end
    local live_pct, live_sum = _readLiveProgress(filepath)
    if data.percent == nil then data.percent = live_pct end
    if data.summary == nil then data.summary = live_sum end
end

-- Title, authors, page count and plain-text description from the book's
-- BookInfoManager record, or nil while the book is not indexed. The fields are
-- resolved once per book and dropped when the record changes in this process
-- (Config.onBookInfoChanged) or on invalidateSidecarCache. Records written by
-- background extraction are not reported, so the fields also expire.
local _BIM_FIELDS_TTL = 60   -- seconds

Config.onBookInfoChanged(function(fp) _bim_fields[fp] = nil end)

local function _bimFields(fp)
    local fields = _bim_fields[fp]
    if fields and os.time() - fields.resolved_at < _BIM_FIELDS_TTL then return fields end
    local BIM = Config.getBookInfoManager()
    if not BIM then return nil end
    local ok, info = pcall(BIM.getBookInfo, BIM, fp, false)
    if not (ok and info) then return nil end
    local description = info.description
    if description and description ~= "" then
        -- EPUB/OPF descriptions are often HTML.
        description = util.htmlToPlainTextIfHtml(description)
    else
        description = nil
    end
    fields = {
        title = info.title, authors = info.authors, pages = info.pages,
        description = description, resolved_at = os.time(),
    }
    _bim_fields[fp] = fields
    return fields
end

-- Average seconds per page of the book currently open in the reader, or the
-- one derived from its sidecar statistics.
local function _avgPageTime(filepath, data)
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local instance = ReaderUI and ReaderUI.instance
    local ok, live = pcall(function()
        local stats = instance and instance.statistics
        local document = instance and instance.document
        if stats and stats.avg_time and stats.avg_time > 0
                and document and document.file == filepath then
            return stats.avg_time
        end
    end)
    if ok and live then return live end
    if data.stat_pages and data.stat_pages > 0
            and data.stat_total_time and data.stat_total_time > 0 then
        return data.stat_total_time / data.stat_pages
    end
end

-- `prefetched` is the entry prefetchBooks stored for the book: `false` when it
-- could not open the sidecar (defaults apply), nil when the caller did not
-- prefetch (the cached sidecar data is used).
function SH.getBookData(filepath, prefetched)
    local data = prefetched
    if data == nil then
        data = _sidecarData(filepath, true)
    elseif data then
        _refreshLiveProgress(filepath, data)
    end
    data = data or {}

    local bim = _bimFields(filepath)
    local title, authors = data.title, data.authors
    if (not title or title == "") and bim and bim.title and bim.title ~= "" then
        title   = bim.title
        authors = authors and authors ~= "" and authors or bim.authors
    end
    if not title or title == "" then
        title = filepath:match("([^/]+)%.[^%.]+$") or "?"
    end

    -- Page count: the rendered/stable count, then BookInfoManager's, then the
    -- "p(<n>)" filename token.
    local pages = data.doc_pages or (bim and bim.pages) or SH.pageCountFromFilename(filepath)
    local summary = data.summary

    return {
        percent     = data.percent or 0,
        title       = title,
        authors     = authors or "",
        description = bim and bim.description or "",
        pages       = pages,
        avg_time    = _avgPageTime(filepath, data),
        status      = type(summary) == "table" and summary.status or nil, -- "complete" | "abandoned" | nil
    }
end

-- ---------------------------------------------------------------------------
-- getBookSeries — series name + index, memoized by filepath (BookInfoManager
-- lookups are cheap individually but add up over a full-library grid; this
-- cache mirrors the sidecar cache above and is cleared the same way).
-- Returns nil when the book isn't part of a series.
-- ---------------------------------------------------------------------------
local _series_cache = {}

function SH.getBookSeries(filepath)
    local cached = _series_cache[filepath]
    if cached ~= nil then
        if cached == false then return nil end
        return cached
    end
    local BIM = Config.getBookInfoManager()
    local result = false
    if BIM then
        local ok, bi = pcall(BIM.getBookInfo, BIM, filepath, false)
        if ok and bi and bi.series and bi.series_index then
            result = { series = bi.series, series_index = bi.series_index }
        end
    end
    _series_cache[filepath] = result
    if result == false then return nil end
    return result
end

function SH.invalidateSeriesCache(fp)
    if fp then
        _series_cache[fp] = nil
    else
        _series_cache = {}
    end
end

-- ---------------------------------------------------------------------------
-- prefetchBooks — reads history, pre-extracts book metadata.
-- Called once per Homescreen render; result cached per open instance.
-- ---------------------------------------------------------------------------
-- NOTE: _cover_extraction_pending was removed from SH.
-- Use Config.cover_extraction_pending (the single source of truth) instead.

-- ---------------------------------------------------------------------------
-- Stale-data cache — mirrors module_stats_provider.lua's _cache/getStale()
-- pattern. Holds the last successful SH.prefetchBooks() result so callers
-- on the hot reader-return path (onCloseDocument, ScreenWidget:onShow)
-- can render currently/coverdeck/recent with last-known-good data via
-- SH.getStaleBooks() — a plain table reference, zero ReadHistory walk, zero
-- lfs.attributes, zero sidecar cache lookups, zero new work of any kind.
-- The authoritative SH.prefetchBooks() call on the deferred ~50ms tick (see
-- _refresh() in sui_homescreen.lua) always still runs and overwrites this
-- cache with fresh data; getStaleBooks() is purely a synchronous-path
-- optimisation, never a substitute for it.
--
-- Unlike SP._cache (single shared state for the whole-app stats), this is
-- naturally per-(show_currently,show_recent,max_recent) call shape — but in
-- practice the homescreen always calls prefetchBooks with the same
-- (show_c, show_r, 15) triple, so a single last-result slot is sufficient,
-- exactly like SP's single _cache slot.
--
-- ── Cross-process-restart persistence ──────────────────────────────────────
-- _last_books_state is a plain Lua local: it lives only as long as this
-- module stays required, i.e. for the lifetime of the current KOReader
-- process. On a genuine cold start (KOReader just launched, this module's
-- first ever require in this run) it starts nil — exactly like SP._cache,
-- which also starts nil and makes reading_stats show zeros for one frame
-- on the very first onShow(). To avoid that one-time "zeros/placeholder"
-- flash on every fresh KOReader launch (not just on reader-return within an
-- already-running session, which the in-memory cache already covers for
-- free), the last state is ALSO mirrored to disk via sui_store, with two
-- deliberate performance constraints:
--
--   1. WRITE COST: _persistStaleBooks() below calls the underlying
--      LuaSettings:saveSetting() directly (bypassing SUISettings:set()/
--      :saveSetting(), which call :flush() on every write — see
--      sui_store.lua's comment on SUISettings:set()). saveSetting() alone
--      only mutates the in-memory settings table; zero disk I/O. This is
--      called every time prefetchBooks() succeeds, so the in-memory disk
--      mirror is always fresh, but at zero extra I/O cost over what was
--      already happening (none).
--   2. FLUSH COST: the actual fsync-to-disk (:flush()) is intentionally
--      NEVER triggered from this module. It piggy-backs on
--      SimpleUIPlugin:onSuspend() in main.lua, which already calls
--      SUISettings:flush() for the same reason every other plugin setting
--      gets persisted — device suspend is infrequent (not on the hot
--      reader-return path) and KOReader has idle time before sleeping.
--      Worst case if the device loses power before ever suspending: the
--      on-disk copy is simply absent or one session behind, and
--      getStaleBooks() falls back to nil exactly as SP.getStale() does —
--      callers render the same "no data yet" placeholder reading_stats
--      shows in that case, never a correctness issue, only a missed
--      optimisation for that one run.
--
-- Net effect: reading the persisted copy back costs one disk read,
-- performed AT MOST ONCE per process lifetime (lazy, on the first
-- getStaleBooks() call when the in-memory cache is still nil) — small,
-- bounded, and off the hot path entirely after that single read.
-- ---------------------------------------------------------------------------
local _last_books_state       = nil
local _disk_books_load_tried  = false  -- guards the single lazy disk read

local _STALE_BOOKS_SETTING_KEY = "simpleui_stale_books_v1"

-- Lazily resolve sui_store without a hard require at module load time, to
-- avoid any chance of a circular dependency between module_books_shared and
-- sui_store (sui_store has no reverse dependency today, but this keeps the
-- coupling defensive and consistent with the rest of this file's lazy-require
-- style, e.g. getDocSettings()).
local _SUIStore = nil
local function _getSUIStore()
    if not _SUIStore then
        local ok, m = pcall(require, "infra/sui_store")
        if ok then _SUIStore = m end
    end
    return _SUIStore
end

-- Writes _last_books_state into the in-memory settings table only — see the
-- WRITE COST note above. Safe to call unconditionally after every
-- prefetchBooks() success; never performs disk I/O itself.
local function _persistStaleBooks(state)
    local SUIStore = _getSUIStore()
    if not SUIStore or not SUIStore.setNoFlush then return end
    -- prefetched_data values are plain strings/numbers/booleans only
    -- (percent, title, authors, doc_pages, partial_md5_checksum, stat_pages,
    -- stat_total_time, summary — see SH.getBookData()'s shape), so the whole
    -- table is safely serialisable by LuaSettings without any special-casing.
    pcall(SUIStore.setNoFlush, SUIStore, _STALE_BOOKS_SETTING_KEY, state)
end

-- Reads the on-disk mirror back exactly once per process lifetime. Returns
-- nil silently on any failure (missing key, corrupt entry, sui_store
-- unavailable) — callers already treat nil as "no stale data available" and
-- fall back accordingly, so this never needs to raise.
local function _loadStaleBooksFromDisk()
    _disk_books_load_tried = true
    local SUIStore = _getSUIStore()
    if not SUIStore then return nil end
    local ok, v = pcall(SUIStore.readSetting, SUIStore, _STALE_BOOKS_SETTING_KEY)
    if not ok or type(v) ~= "table" then return nil end
    return v
end

-- opts.exclude_current (default true): when Currently and Recent are both
-- active, keep the currently-reading book out of recent_fps. Callers that
-- pass false allow the same book in both modules.
function SH.prefetchBooks(show_currently, show_recent, max_recent, opts)
    max_recent = max_recent or 5
    opts = type(opts) == "table" and opts or {}
    local exclude_current = opts.exclude_current
    if exclude_current == nil then exclude_current = true end

    local state = { current_fp = nil, recent_fps = {}, prefetched_data = {} }
    if not show_currently and not show_recent then return state end

    local ReadHistory = package.loaded["readhistory"] or require("readhistory")
    if not ReadHistory then return state end
    if not ReadHistory.hist or #ReadHistory.hist == 0 then
        pcall(function() ReadHistory:reload() end)
    end

    local DS = getDocSettings()
    -- Walk history in order. Only existing files count:
    -- • show_currently → first existing file becomes current_fp (so a deleted
    --   hist[1] falls through to the next book, same idea as Cover Deck on
    --   the recent source).
    -- • show_recent → fill recent_fps, optionally skipping current_fp.
    local claimed_current = false
    for i = 1, #(ReadHistory.hist or {}) do
        local entry = ReadHistory.hist[i]
        local fp = entry and entry.file
        if fp and lfs.attributes(fp, "mode") == "file" then
            -- A kepub known to an external library plugin is keyed by its
            -- virtual path, so cover extraction, sidecar lookups and opening
            -- all go through that plugin's own handling.
            fp = _koboVirtualPath(fp)
            local is_current = show_currently and not claimed_current
            if is_current then
                claimed_current = true
                state.current_fp = fp
            end
            -- Read/complete filtering is each module's responsibility:
            -- module_recent and module_coverdeck apply their own setting at
            -- render time from the prefetched pct/summary.
            local is_recent = show_recent and #state.recent_fps < max_recent
                and (not is_current or not exclude_current)
            if is_recent then
                state.recent_fps[#state.recent_fps + 1] = fp
            end
            if DS and (is_current or is_recent) then
                -- `false` marks a sidecar that could not be opened, so
                -- getBookData falls back to defaults without retrying.
                state.prefetched_data[fp] = _sidecarData(fp) or false
            end
        end
        local has_current = not show_currently or state.current_fp
        local has_recent  = not show_recent or #state.recent_fps >= max_recent
        if has_current and has_recent then break end
    end

    -- Only cache results that actually resolved something — an early-return
    -- empty state (e.g. both show_currently/show_recent false) would
    -- otherwise poison getStaleBooks() with an empty result on the next
    -- reader-return, even though a perfectly good previous result exists.
    if state.current_fp or #state.recent_fps > 0 then
        _last_books_state = state
        -- Mirror to the in-memory settings table (zero disk I/O — see the
        -- WRITE COST note above _persistStaleBooks). This keeps the on-disk
        -- copy fresh so the NEXT KOReader process launch can skip the
        -- zeros/placeholder flash on its very first onShow(), the same way
        -- SP._cache already avoids it for every reader-return WITHIN a
        -- single running process.
        _persistStaleBooks(state)
    end

    return state
end

-- ---------------------------------------------------------------------------
-- SH.getStaleBooks() — instant, zero-cost return of the last successful
-- SH.prefetchBooks() result. See the _last_books_state comment above the
-- cache declaration for the full rationale; this mirrors
-- module_stats_provider.lua's SP.getStale() exactly, with one addition:
-- a single lazy disk read on cold start (see _loadStaleBooksFromDisk above)
-- so a freshly launched KOReader process can also benefit from the previous
-- run's last-known books, not just reader-returns within the same run.
--
-- Returns nil only when (a) this is a genuinely fresh on-disk state too —
-- e.g. first launch ever after install, or the user cleared SimpleUI
-- settings — or (b) sui_store is unavailable for some reason. Callers must
-- fall back to an empty stub in that case, same as SP.getStale() callers
-- fall back to `{}`.
-- ---------------------------------------------------------------------------
function SH.getStaleBooks()
    if not _last_books_state and not _disk_books_load_tried then
        -- Lazy, at-most-once-per-process disk read. Deliberately NOT done
        -- eagerly at module load time: most processes' first relevant call
        -- to getStaleBooks() happens from ScreenWidget:onShow() on the
        -- very first homescreen paint, which is exactly the latency-
        -- sensitive moment this whole mechanism exists to protect — so the
        -- read only happens if and when it's actually needed, not on every
        -- KOReader startup regardless of whether the homescreen is ever
        -- shown the books modules are even enabled.
        _last_books_state = _loadStaleBooksFromDisk()
    end
    return _last_books_state
end


-- ---------------------------------------------------------------------------
-- Sidecar helpers
-- ---------------------------------------------------------------------------


return SH