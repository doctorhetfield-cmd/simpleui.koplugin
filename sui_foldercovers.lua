-- sui_foldercovers.lua — Simple UI
-- Folder cover art and book cover overlays for the CoverBrowser mosaic/list views.

-- ---------------------------------------------------------------------------
-- 1. Requires
-- ---------------------------------------------------------------------------

local _           = require("sui_i18n").translate
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")
local SUISettings = require("sui_store")
local SUIStyle    = require("sui_style")

-- Cached at module level so require() hits the cache on every cell render.
local AlphaContainer  = require("ui/widget/container/alphacontainer")
local BD              = require("ui/bidi")
local Blitbuffer      = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FileChooser     = require("ui/widget/filechooser")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local ImageWidget     = require("ui/widget/imagewidget")
local LineWidget      = require("ui/widget/linewidget")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local RightContainer  = require("ui/widget/container/rightcontainer")
local Screen          = require("device").screen
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local TopContainer    = require("ui/widget/container/topcontainer")

-- ---------------------------------------------------------------------------
-- 2. Settings keys
-- ---------------------------------------------------------------------------

local SK = {
    enabled           = "simpleui_fc_enabled",
    show_name         = "simpleui_fc_show_name",
    hide_underline    = "simpleui_fc_hide_underline",
    label_style       = "simpleui_fc_label_style",
    label_position    = "simpleui_fc_label_position",
    label_color       = "simpleui_fc_label_color",
    badge_position    = "simpleui_fc_badge_position",
    badge_hidden      = "simpleui_fc_badge_hidden",
    cover_mode        = "simpleui_fc_cover_mode",
    label_mode        = "simpleui_fc_label_mode",
    overlay_pages     = "simpleui_fc_overlay_pages",
    overlay_series    = "simpleui_fc_overlay_series",
    overlay_progress  = "simpleui_fc_overlay_progress",
    progress_mode     = "simpleui_fc_progress_mode",
    overlay_new       = "simpleui_fc_overlay_new",
    series_grouping   = "simpleui_fc_series_grouping",
    subfolder_cover   = "simpleui_fc_subfolder_cover",
    recursive_cover   = "simpleui_fc_recursive_cover",
    label_scale       = "simpleui_fc_label_scale",
    folder_style      = "simpleui_fc_folder_style",
    hide_spine        = "simpleui_fc_hide_spine",
    show_title_strip  = "simpleui_fc_show_title_strip",
    show_author_strip = "simpleui_fc_show_author_strip",
    badge_color_pages    = "simpleui_fc_badge_color_pages",
    badge_color_series   = "simpleui_fc_badge_color_series",
    badge_color_progress = "simpleui_fc_badge_color_progress",
    badge_color_new      = "simpleui_fc_badge_color_new",
    new_mode             = "simpleui_fc_new_mode",
    badge_color_folder   = "simpleui_fc_badge_color_folder",
    badge_scale          = "simpleui_fc_badge_scale",
    fade_finished        = "simpleui_fc_fade_finished",
    fade_amount          = "simpleui_fc_fade_amount",
}

-- ---------------------------------------------------------------------------
-- 3. Settings API
-- ---------------------------------------------------------------------------

local M = {}

local function _getFlag(key)    return SUISettings:readSetting(key) ~= false end
local function _setFlag(key, v) SUISettings:saveSetting(key, v)              end

function M.isEnabled()   return SUISettings:isTrue(SK.enabled)  end
function M.setEnabled(v) SUISettings:saveSetting(SK.enabled, v) end

function M.getShowName()       return _getFlag(SK.show_name)      end
function M.setShowName(v)      _setFlag(SK.show_name, v)          end
function M.getHideUnderline()  return _getFlag(SK.hide_underline) end
function M.setHideUnderline(v) _setFlag(SK.hide_underline, v)     end

-- "alpha" = semitransparent white overlay; "frame" = solid grey border.
function M.getLabelStyle()    return SUISettings:readSetting(SK.label_style)    or "alpha"   end
function M.setLabelStyle(v)   SUISettings:saveSetting(SK.label_style, v)                     end

-- "bottom" (default) | "center" | "top"
function M.getLabelPosition()  return SUISettings:readSetting(SK.label_position) or "bottom" end
function M.setLabelPosition(v) SUISettings:saveSetting(SK.label_position, v)                 end

-- "light" (default, white background / black text) | "dark" (black background / white text)
function M.getLabelColor()  return SUISettings:readSetting(SK.label_color) or "light" end
function M.setLabelColor(v) SUISettings:saveSetting(SK.label_color, v)                end

-- "top" (default) | "bottom"
function M.getBadgePosition()  return SUISettings:readSetting(SK.badge_position) or "top"   end
function M.setBadgePosition(v) SUISettings:saveSetting(SK.badge_position, v)                 end

function M.getBadgeHidden()  return SUISettings:isTrue(SK.badge_hidden)  end
function M.setBadgeHidden(v) SUISettings:saveSetting(SK.badge_hidden, v) end

-- "default" = scale-to-fit; "2_3" = force 2:3 aspect ratio.
function M.getCoverMode()  return SUISettings:readSetting(SK.cover_mode) or "default" end
function M.setCoverMode(v) SUISettings:saveSetting(SK.cover_mode, v)                  end

-- "overlay" (default) = folder name on cover; "hidden" = no label.
function M.getLabelMode()  return SUISettings:readSetting(SK.label_mode) or "overlay" end
function M.setLabelMode(v) SUISettings:saveSetting(SK.label_mode, v)                  end

-- Pages badge: default on; hidden for completed books.
function M.getOverlayPages()  return SUISettings:readSetting(SK.overlay_pages) ~= false end
function M.setOverlayPages(v) _setFlag(SK.overlay_pages, v)                              end

-- Series index badge: default off.
function M.getOverlaySeries()  return SUISettings:isTrue(SK.overlay_series) end
function M.setOverlaySeries(v) _setFlag(SK.overlay_series, v)               end

-- Progress pentagon badge: default on.
-- "banner" = pentagon overlay; "native" = KOReader native marks; "none" = no marks.
-- Setting this also keeps the legacy overlay_progress flag in sync and manages
-- the native collection mark (collection_show_mark in G_reader_settings):
--   banner → disabled here, redrawn at bottom-right by paintTo.
--   native/none → restored so KOReader draws the star at top-right normally.
function M.getOverlayProgress()  return SUISettings:readSetting(SK.overlay_progress) ~= false end
function M.setOverlayProgress(v) _setFlag(SK.overlay_progress, v)                              end

function M.getProgressMode() return SUISettings:readSetting(SK.progress_mode) or "banner" end
function M.setProgressMode(v)
    SUISettings:saveSetting(SK.progress_mode, v)
    _setFlag(SK.overlay_progress, v == "banner")
    if v == "banner" then
        G_reader_settings:saveSetting("collection_show_mark", false)
    elseif v == "native" or v == "none" then
        G_reader_settings:saveSetting("collection_show_mark", true)
    end
end

-- "New" badge for unread books (percent_finished nil, status not complete/abandoned).
-- Mode: "badge" (rounded rectangle, default), "ribbon" (diagonal corner ribbon), "none".
-- For backwards-compatibility the legacy bool SK.overlay_new is preserved as the source
-- of truth for "enabled/disabled"; SK.new_mode stores the style when enabled.
function M.getNewMode()
    local stored = SUISettings:readSetting(SK.new_mode)
    if stored == "ribbon" or stored == "badge" or stored == "none" then return stored end
    -- Migrate from legacy bool: if the old key was explicitly false → "none".
    if SUISettings:readSetting(SK.overlay_new) == false then return "none" end
    return "ribbon"
end
function M.setNewMode(v)
    SUISettings:saveSetting(SK.new_mode, v)
    _setFlag(SK.overlay_new, v ~= "none")
end
-- Kept for external callers (module_new_books etc.) that only need on/off.
function M.getOverlayNew()  return M.getNewMode() ~= "none" end
function M.setOverlayNew(v) M.setNewMode(v and "badge" or "none") end

-- Virtual series folders in the mosaic.
function M.getSeriesGrouping()  return SUISettings:isTrue(SK.series_grouping) end
function M.setSeriesGrouping(v) _setFlag(SK.series_grouping, v)               end

-- Placeholder cover for folders with no direct ebooks.
function M.getSubfolderCover()  return SUISettings:isTrue(SK.subfolder_cover) end
function M.setSubfolderCover(v) _setFlag(SK.subfolder_cover, v)               end

-- Scan up to 3 subfolder levels for a cached cover.
function M.getRecursiveCover()  return SUISettings:isTrue(SK.recursive_cover) end
function M.setRecursiveCover(v) _setFlag(SK.recursive_cover, v)               end

-- "single" (default) | "quad" (2×2 grid) | "auto" (single <4 books, quad ≥4).
function M.getFolderStyle()  return SUISettings:readSetting(SK.folder_style) or "single" end
function M.setFolderStyle(v) SUISettings:saveSetting(SK.folder_style, v)                 end

-- Hide the book spine decoration on folder covers.
function M.getHideSpine()  return SUISettings:isTrue(SK.hide_spine)  end
function M.setHideSpine(v) SUISettings:saveSetting(SK.hide_spine, v) end

-- Title/author strip below mosaic covers. Requires restart to take effect.
function M.getShowTitleStrip()   return SUISettings:isTrue(SK.show_title_strip)   end
function M.setShowTitleStrip(v)  SUISettings:saveSetting(SK.show_title_strip, v)  end
function M.getShowAuthorStrip()  return SUISettings:isTrue(SK.show_author_strip)  end
function M.setShowAuthorStrip(v) SUISettings:saveSetting(SK.show_author_strip, v) end

-- Per-badge color: "dark" = black bg / white text; "light" = white bg / black text.
function M.getBadgeColorPages()     return SUISettings:readSetting(SK.badge_color_pages)    or "light" end
function M.setBadgeColorPages(v)    SUISettings:saveSetting(SK.badge_color_pages, v)                   end
function M.getBadgeColorSeries()    return SUISettings:readSetting(SK.badge_color_series)   or "light" end
function M.setBadgeColorSeries(v)   SUISettings:saveSetting(SK.badge_color_series, v)                  end
function M.getBadgeColorProgress()  return SUISettings:readSetting(SK.badge_color_progress) or "dark"  end
function M.setBadgeColorProgress(v) SUISettings:saveSetting(SK.badge_color_progress, v)                end
function M.getBadgeColorNew()       return SUISettings:readSetting(SK.badge_color_new)      or "dark"  end
function M.setBadgeColorNew(v)      SUISettings:saveSetting(SK.badge_color_new, v)                     end
function M.getBadgeColorFolder()    return SUISettings:readSetting(SK.badge_color_folder)   or "dark"  end
function M.setBadgeColorFolder(v)   SUISettings:saveSetting(SK.badge_color_folder, v)                  end

-- Fade finished books: dim the cover of completed books in mosaic view.
-- Default ON — consistent with "~= false" pattern used by other default-true flags.
function M.getFadeFinished()  return SUISettings:readSetting(SK.fade_finished) ~= false end
function M.setFadeFinished(v) SUISettings:saveSetting(SK.fade_finished, v) end

-- Fade intensity: integer percentage 10–90, default 50.
-- Stored and exposed as an integer % so SpinWidget needs no unit conversion.
local _FADE_AMOUNT_MIN = 10
local _FADE_AMOUNT_MAX = 90
local _FADE_AMOUNT_DEF = 50
local _FADE_AMOUNT_STEP = 5
M.FADE_AMOUNT_MIN  = _FADE_AMOUNT_MIN
M.FADE_AMOUNT_MAX  = _FADE_AMOUNT_MAX
M.FADE_AMOUNT_DEF  = _FADE_AMOUNT_DEF
M.FADE_AMOUNT_STEP = _FADE_AMOUNT_STEP

function M.getFadeAmountPct()
    local v = SUISettings:readSetting(SK.fade_amount)
    return (v and tonumber(v)) or _FADE_AMOUNT_DEF
end
function M.setFadeAmountPct(v)
    v = math.max(_FADE_AMOUNT_MIN, math.min(_FADE_AMOUNT_MAX, math.floor(tonumber(v) or _FADE_AMOUNT_DEF)))
    SUISettings:saveSetting(SK.fade_amount, v)
end
-- lightenRect expects a 0.0–1.0 float.
function M.getFadeAmount() return M.getFadeAmountPct() / 100 end

-- Folder label text scale: integer %, clamped to [50, 200], default 100.
local _FC_SCALE_MIN  = 50
local _FC_SCALE_MAX  = 200
local _FC_SCALE_DEF  = 100
local _FC_SCALE_STEP = 10
M.FC_LABEL_SCALE_MIN  = _FC_SCALE_MIN
M.FC_LABEL_SCALE_MAX  = _FC_SCALE_MAX
M.FC_LABEL_SCALE_DEF  = _FC_SCALE_DEF
M.FC_LABEL_SCALE_STEP = _FC_SCALE_STEP

local function _clampFCScale(n)
    return math.max(_FC_SCALE_MIN, math.min(_FC_SCALE_MAX, math.floor(n)))
end

function M.getLabelScalePct()
    local n = tonumber(SUISettings:readSetting(SK.label_scale))
    if not n then return _FC_SCALE_DEF end
    return _clampFCScale(n)
end
function M.getLabelScale()    return M.getLabelScalePct() / 100         end
function M.setLabelScale(pct) SUISettings:saveSetting(SK.label_scale, _clampFCScale(pct)) end

-- Folder covers badge scale
local _FC_BADGE_SCALE_MIN  = 50
local _FC_BADGE_SCALE_MAX  = 200
local _FC_BADGE_SCALE_DEF  = 100
local _FC_BADGE_SCALE_STEP = 10
M.FC_BADGE_SCALE_MIN  = _FC_BADGE_SCALE_MIN
M.FC_BADGE_SCALE_MAX  = _FC_BADGE_SCALE_MAX
M.FC_BADGE_SCALE_DEF  = _FC_BADGE_SCALE_DEF
M.FC_BADGE_SCALE_STEP = _FC_BADGE_SCALE_STEP

local function _clampFCBadgeScale(n)
    return math.max(_FC_BADGE_SCALE_MIN, math.min(_FC_BADGE_SCALE_MAX, math.floor(n)))
end

function M.getBadgeScalePct()
    local n = tonumber(SUISettings:readSetting(SK.badge_scale))
    if not n then return _FC_BADGE_SCALE_DEF end
    return _clampFCBadgeScale(n)
end
function M.getBadgeScale()    return M.getBadgeScalePct() / 100         end
function M.setBadgeScale(pct) SUISettings:saveSetting(SK.badge_scale, _clampFCBadgeScale(pct)) end

-- Menu items for the progress badge sub-menu (banner / native / none).
-- Triggers a full redraw on change so the mosaic updates immediately.
function M.getProgressModeMenuItems()
    local function _set(mode)
        M.setProgressMode(mode)
        local ok_ui, UIManager = pcall(require, "ui/uimanager")
        if ok_ui and UIManager then
            local ok_fm, fm_mod = pcall(require, "apps/filemanager/filemanager")
            if ok_fm and fm_mod and fm_mod.instance then
                fm_mod.instance.file_chooser:updateItems()
            end
        end
    end
    return {
        {
            text_func    = function() return _("Banner") end,
            checked_func = function() return M.getProgressMode() == "banner" end,
            callback     = function() _set("banner") end,
        },
        {
            text_func    = function() return _("Native") end,
            checked_func = function() return M.getProgressMode() == "native" end,
            callback     = function() _set("native") end,
        },
        {
            text_func    = function() return _("None") end,
            checked_func = function() return M.getProgressMode() == "none" end,
            callback     = function() _set("none") end,
        },
    }
end

-- ---------------------------------------------------------------------------
-- 4. Constants
-- ---------------------------------------------------------------------------

-- Base sizes computed once from device DPI at startup.
local _BASE_COVER_H = math.floor(Screen:scaleBySize(96))
local _BASE_NB_SIZE = Screen:scaleBySize(10)
local _BASE_NB_FS   = SUIStyle.FS_DETAIL  -- 15: folder-count number badge overlay
local _BASE_DIR_FS  = SUIStyle.FS_SUBTITLE -- 20: directory name label ceiling for binary-search

local _EDGE_THICK  = math.max(1, Screen:scaleBySize(3))
local _EDGE_MARGIN = math.max(1, Screen:scaleBySize(1))
local _SPINE_W     = _EDGE_THICK * 2 + _EDGE_MARGIN * 2
local _SPINE_COLOR = Blitbuffer.gray(0.70)

local _LATERAL_PAD        = Screen:scaleBySize(10)
local _VERTICAL_PAD       = Screen:scaleBySize(4)
local _BADGE_MARGIN_BASE  = Screen:scaleBySize(8)
local _BADGE_MARGIN_R_BASE = Screen:scaleBySize(4)

local _LABEL_ALPHA = 0.75

-- Set by M.install() to the strip height for this session; 0 when both
-- title and author strips are disabled.  Read by _computeCellGeometry.
local _module_strip_h = 0

-- Badge geometry. _BADGE_FONT_SZ drives the folder-count circle badge.
-- Text badges (pages, series, "New") derive geometry from eff_size instead.
local _BADGE_FONT_SZ     = Screen:scaleBySize(5)
local _BADGE_TOP_INSET   = Screen:scaleBySize(0)
local _BADGE_RIGHT_INSET = Screen:scaleBySize(8)
local _BADGE_BAR_H       = Screen:scaleBySize(8)
local _BADGE_BAR_GAP     = Screen:scaleBySize(4)

-- Plugin directory and optional custom icon path.
local _PLUGIN_DIR  = debug.getinfo(1, "S").source:match("^@(.+/)[^/]+$") or "./"
local _ICON_PATH   = _PLUGIN_DIR .. "icons/custom.svg"
local _ICON_EXISTS = lfs.attributes(_ICON_PATH, "mode") == "file"

-- ---------------------------------------------------------------------------
-- 5. Caches
-- ---------------------------------------------------------------------------

-- Two-generation LRU cache pattern used throughout:
--   generation A is the active table; B is the previous one.
--   On overflow: B = A, A = {}, counter reset.
--   Lookup hits A first, falls back to B (effective capacity 2×MAX).

-- Font-size cache for _getFolderNameWidget.
-- Key: display_text .. "\0" .. available_w .. "\0" .. max_font_size
local _FS_CACHE_MAX   = 200
local _fs_cache_a     = {}
local _fs_cache_b     = {}
local _fs_cache_a_cnt = 0

local function _fsCacheGet(key) return _fs_cache_a[key] or _fs_cache_b[key] end
local function _fsCacheSet(key, value)
    if _fs_cache_a_cnt >= _FS_CACHE_MAX then
        _fs_cache_b     = _fs_cache_a
        _fs_cache_a     = {}
        _fs_cache_a_cnt = 0
    end
    _fs_cache_a[key] = value
    _fs_cache_a_cnt  = _fs_cache_a_cnt + 1
end

-- Cover-file cache (.cover.* lookups per directory).
-- Values: filepath string on hit, false on confirmed miss.
local _DIR_CACHE_MAX    = 300
local _cover_file_cache = {}
local _cfc_b            = {}
local _cfc_cnt          = 0

local function _cfcGet(key) return _cover_file_cache[key] or _cfc_b[key] end
local function _cfcSet(key, v)
    if _cfc_cnt >= _DIR_CACHE_MAX then
        _cfc_b            = _cover_file_cache
        _cover_file_cache = {}
        _cfc_cnt          = 0
    end
    _cover_file_cache[key] = v
    _cfc_cnt = _cfc_cnt + 1
end

-- ListMenuItem directory cover cache (avoids repeated lfs.dir scans).
local _lm_dir_cover_cache = {}
local _lmc_b              = {}
local _lmc_cnt            = 0

local function _lmcGet(key) return _lm_dir_cover_cache[key] or _lmc_b[key] end
local function _lmcSet(key, v)
    if _lmc_cnt >= _DIR_CACHE_MAX then
        _lmc_b              = _lm_dir_cover_cache
        _lm_dir_cover_cache = {}
        _lmc_cnt            = 0
    end
    _lm_dir_cover_cache[key] = v
    _lmc_cnt = _lmc_cnt + 1
end

-- Single-entry item-table cache for FileChooser:genItemTableFromPath.
-- Encodes path + mtime + collate settings in the key so stale entries are
-- evicted automatically when anything that affects the list changes.
-- Disabled for access-time collate (directory mtime never reflects reads).
local _itc = nil

-- Blitbuffer cache for pre-rendered diagonal ribbon banners (keyed by
-- dimensions + label + colors). Flushed in M.invalidateCache().
local _ribbon_bb_cache = {}
local _orig_setBookInfoCacheProperty = nil
local _orig_genItemTableFromPath     = nil

local function _itc_invalidate() _itc = nil end

local function _itc_key(path, fc)
    local mtime      = lfs.attributes(path, "modification") or 0
    local filter_raw = fc.show_filter and fc.show_filter.status
    local filter_str
    if type(filter_raw) == "table" then
        local parts = {}
        for k, v in pairs(filter_raw) do
            if v then parts[#parts + 1] = tostring(k) end
        end
        table.sort(parts)
        filter_str = table.concat(parts, "\1")
    else
        filter_str = tostring(filter_raw or "")
    end
    return path .. "\0" .. mtime .. "\0"
        .. (G_reader_settings:readSetting("collate") or "strcoll") .. "\0"
        .. tostring(G_reader_settings:isTrue("collate_mixed"))     .. "\0"
        .. tostring(G_reader_settings:isTrue("reverse_collate"))   .. "\0"
        .. tostring(fc.show_hidden or false) .. "\0"
        .. filter_str
end

local function _installItemCache()
    if FileChooser._simpleui_fc_cache_patched then return end
    FileChooser._simpleui_fc_cache_patched = true

    -- Invalidate when a book's status/props change so sort position stays correct.
    local ok_bl, BookList = pcall(require, "ui/widget/booklist")
    if ok_bl and BookList and BookList.setBookInfoCacheProperty then
        _orig_setBookInfoCacheProperty = BookList.setBookInfoCacheProperty
        BookList.setBookInfoCacheProperty = function(file, prop_name, prop_value)
            _itc_invalidate()
            return _orig_setBookInfoCacheProperty(file, prop_name, prop_value)
        end
    end

    _orig_genItemTableFromPath = FileChooser.genItemTableFromPath

    FileChooser.genItemTableFromPath = function(fc, path)
        -- Bypass for non-FM instances and for _dummy=true cover-collection calls.
        if fc._dummy or fc.name ~= "filemanager" then
            return _orig_genItemTableFromPath(fc, path)
        end
        -- access-time collate: mtime never changes on read — disable the cache.
        if (G_reader_settings:readSetting("collate") or "strcoll") == "access" then
            _itc = nil
            return _orig_genItemTableFromPath(fc, path)
        end
        local key = _itc_key(path, fc)
        if _itc and _itc.key == key then return _itc.t end
        local result = _orig_genItemTableFromPath(fc, path)
        -- Don't cache virtual series views: their synthetic path has no reliable mtime.
        if not (result and result._sg_is_series_view) then
            _itc = { key = key, t = result }
        else
            _itc = nil
        end
        return result
    end
end

local function _uninstallItemCache()
    if not FileChooser._simpleui_fc_cache_patched then return end
    FileChooser.genItemTableFromPath       = _orig_genItemTableFromPath
    _orig_genItemTableFromPath             = nil
    FileChooser._simpleui_fc_cache_patched = nil
    if _orig_setBookInfoCacheProperty then
        local ok_bl, BookList = pcall(require, "ui/widget/booklist")
        if ok_bl and BookList then
            BookList.setBookInfoCacheProperty = _orig_setBookInfoCacheProperty
        end
        _orig_setBookInfoCacheProperty = nil
    end
    _itc = nil
end

function M.invalidateCache()
    _itc = nil
    -- Also flush the ribbon Blitbuffer cache so a color/size change takes effect.
    for k, buf in pairs(_ribbon_bb_cache) do
        if buf and buf.free then buf:free() end
        _ribbon_bb_cache[k] = nil
    end
end

-- ---------------------------------------------------------------------------
-- 6. Cover discovery
-- ---------------------------------------------------------------------------

local _COVER_EXTS = { ".jpg", ".jpeg", ".png", ".webp", ".gif" }

-- Returns the path to a .cover.* file in dir_path, or nil.
local function findCover(dir_path)
    local cached = _cfcGet(dir_path)
    if cached ~= nil then return cached or nil end
    local base = dir_path .. "/.cover"
    for i = 1, #_COVER_EXTS do
        local fname = base .. _COVER_EXTS[i]
        if lfs.attributes(fname, "mode") == "file" then
            _cfcSet(dir_path, fname)
            return fname
        end
    end
    _cfcSet(dir_path, false)
    return nil
end

-- Run genItemTableFromPath with the status filter suppressed so books hidden
-- by "show only new/reading" can still supply cover art.
local _EMPTY_FILTER = {}
local function _entriesWithNoFilter(menu, dir_path)
    local saved = FileChooser.show_filter
    FileChooser.show_filter = _EMPTY_FILTER
    menu._dummy = true
    local entries = menu:genItemTableFromPath(dir_path)
    menu._dummy = false
    FileChooser.show_filter = saved
    return entries
end

-- Collect up to `needed` cached covers from dir_path recursively (files first,
-- then subdirs). Returns an array that may be shorter than needed.
local function _collectCoversRecursive(menu, dir_path, depth, max_depth, needed, BookInfoManager)
    if depth > max_depth or needed <= 0 then return {} end
    local entries = _entriesWithNoFilter(menu, dir_path)
    if not entries then return {} end
    local covers  = {}
    local subdirs = {}
    for _, entry in ipairs(entries) do
        if entry.is_file or entry.file then
            local bi = BookInfoManager:getBookInfo(entry.path, true)
            if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
                    and not bi.ignore_cover
                    and not BookInfoManager.isCachedCoverInvalid(bi, menu.cover_specs)
            then
                covers[#covers + 1] = { data = bi.cover_bb, w = bi.cover_w, h = bi.cover_h }
                if #covers >= needed then return covers end
            end
        else
            if not entry.is_go_up then subdirs[#subdirs + 1] = entry end
        end
    end
    for _, entry in ipairs(subdirs) do
        if #covers >= needed then break end
        local sub = _collectCoversRecursive(
            menu, entry.path, depth + 1, max_depth, needed - #covers, BookInfoManager)
        for _, c in ipairs(sub) do
            covers[#covers + 1] = c
            if #covers >= needed then break end
        end
    end
    return covers
end

-- Find exactly one cover recursively (used by the bookless-folder path).
local function _findCoverRecursive(menu, dir_path, depth, max_depth, BookInfoManager)
    local found = _collectCoversRecursive(menu, dir_path, depth, max_depth, 1, BookInfoManager)
    return found[1]
end

-- Collect up to `max_count` covers from dir_path, including subfolders when
-- recursive cover is enabled.
local function _collectCovers(menu, dir_path, max_count, BookInfoManager)
    local covers  = {}
    local entries = _entriesWithNoFilter(menu, dir_path)
    if not entries then return covers end
    for _, entry in ipairs(entries) do
        if entry.is_file or entry.file then
            if #covers >= max_count then break end
            local bi = BookInfoManager:getBookInfo(entry.path, true)
            if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
                    and not bi.ignore_cover
            then
                covers[#covers + 1] = { data = bi.cover_bb, w = bi.cover_w, h = bi.cover_h }
            end
        end
    end
    if #covers < max_count and M.getRecursiveCover() then
        for _, entry in ipairs(entries) do
            if not (entry.is_file or entry.file) and not entry.is_go_up then
                if #covers >= max_count then break end
                local sub = _collectCoversRecursive(
                    menu, entry.path, 1, 3, max_count - #covers, BookInfoManager)
                for _, c in ipairs(sub) do
                    covers[#covers + 1] = c
                    if #covers >= max_count then break end
                end
            end
        end
    end
    return covers
end

-- ---------------------------------------------------------------------------
-- 7. Folder logic — overrides, style resolution, pickers, file-dialog button
-- ---------------------------------------------------------------------------

-- Cover-override table: { [dir_path] = book_path }.
-- Lazy-loaded once and mutated in place; never goes stale during a session.
local _FC_COVERS_KEY  = "simpleui_fc_covers"
local _overrides_cache = nil

local function _getCoverOverrides()
    if not _overrides_cache then
        _overrides_cache = SUISettings:readSetting(_FC_COVERS_KEY) or {}
    end
    return _overrides_cache
end

local function _saveCoverOverride(dir_path, book_path)
    local t = _getCoverOverrides()
    t[dir_path] = book_path
    SUISettings:saveSetting(_FC_COVERS_KEY, t)
end

local function _clearCoverOverride(dir_path)
    local t = _getCoverOverrides()
    t[dir_path] = nil
    SUISettings:saveSetting(_FC_COVERS_KEY, t)
end

-- Clear _foldercover_processed on the matching item and trigger a grid redraw.
local function _invalidateFolderItem(menu, dir_path)
    if not menu then return end
    if menu.layout then
        for _, row in ipairs(menu.layout) do
            for _, item in ipairs(row) do
                if item._foldercover_processed
                        and item.entry and item.entry.path == dir_path then
                    item._foldercover_processed = false
                end
            end
        end
    end
    menu:updateItems(1, true)
end

-- Series-grouping state — forward-declared so _resolveStyle can close over it.
local _sg_items_cache = {}

-- Resolve the effective folder style for dir_path.
-- "auto" counts books and returns "quad" (≥4) or "single" (<4).
-- The optional `entry` is used to identify virtual folder types.
local _resolveStyle
_resolveStyle = function(menu, dir_path, entry)
    local style = M.getFolderStyle()
    if style ~= "auto" then return style end
    if not menu or not dir_path then return "single" end

    -- Series-group virtual folders have a synthetic path that can't be scanned
    -- via _entriesWithNoFilter, so count directly from the cache.
    local is_sg = (entry and entry.is_series_group) or (_sg_items_cache[dir_path] ~= nil)
    if is_sg then
        local items = (entry and entry.series_items) or _sg_items_cache[dir_path]
        if items and #items >= 4 then return "quad" end
        return "single"
    end

    local entries = _entriesWithNoFilter(menu, dir_path)
    if not entries then return "single" end
    local book_count = 0
    for _, e in ipairs(entries) do
        if e.is_file or e.file then
            book_count = book_count + 1
            if book_count >= 4 then return "quad" end
        end
    end
    if book_count < 4 and M.getRecursiveCover() then
        local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
        if ok_bim and BookInfoManager then
            for _, e in ipairs(entries) do
                if not (e.is_file or e.file) and not e.is_go_up then
                    local sub = _collectCoversRecursive(
                        menu, e.path, 1, 3, 4 - book_count, BookInfoManager)
                    book_count = book_count + #sub
                    if book_count >= 4 then return "quad" end
                end
            end
        end
    end
    return "single"
end

-- Public wrapper used by other modules (e.g. sui_browsemeta).
function M.resolveStyle(fc, dir_path, entry) return _resolveStyle(fc, dir_path, entry) end

-- Collect up to _COLLECT_MAX books from dir_path for the cover picker dialog.
local _COLLECT_MAX = 50
local function _collectBooks(menu, dir_path, depth, max_depth, out)
    if #out >= _COLLECT_MAX then return end
    local entries = _entriesWithNoFilter(menu, dir_path)
    if not entries then return end
    for _, entry in ipairs(entries) do
        if entry.is_file or entry.file then
            out[#out + 1] = entry
            if #out >= _COLLECT_MAX then return end
        elseif depth < max_depth then
            _collectBooks(menu, entry.path, depth + 1, max_depth, out)
            if #out >= _COLLECT_MAX then return end
        end
    end
end

-- Create a ReadCollection from the books in a series-group virtual folder.
local function _createCollectionFromSeriesGroup(vpath, series_name)
    local UIManager   = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local InputDialog = require("ui/widget/inputdialog")
    local T           = require("ffi/util").template

    local series_items = _sg_items_cache[vpath]
    if not series_items or #series_items == 0 then
        UIManager:show(InfoMessage:new{ text = _("No books found in this series."), timeout = 2 })
        return
    end

    local RC = require("readcollection")
    local input_dialog
    input_dialog = InputDialog:new{
        title   = _("New collection name"),
        input   = series_name or "",
        buttons = {{
            {
                text = _("Cancel"),
                id   = "close",
                callback = function() UIManager:close(input_dialog) end,
            },
            {
                text = _("Create"),
                callback = function()
                    local name = input_dialog:getInputText()
                    if name == "" then return end
                    UIManager:close(input_dialog)
                    if RC.coll[name] then
                        UIManager:show(InfoMessage:new{
                            text = T(_("Collection already exists: %1"), name),
                        })
                        return
                    end
                    RC:addCollection(name)
                    local count = 0
                    for _, item in ipairs(series_items) do
                        local fp = item.path
                        if fp and not RC.coll[name][fp] then
                            RC:addItem(fp, name)
                            count = count + 1
                        end
                    end
                    RC:write({ [name] = true })
                    UIManager:show(InfoMessage:new{
                        text    = T(_("Collection \"%1\" created with %2 books."), name, count),
                        timeout = 3,
                    })
                end,
            },
        }},
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

-- Cover picker for series-group virtual folders.
local function _openSeriesGroupCoverPicker(vpath, menu, BookInfoManager)
    local UIManager    = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage  = require("ui/widget/infomessage")

    local series_items = _sg_items_cache[vpath]
    if not series_items or #series_items == 0 then
        UIManager:show(InfoMessage:new{ text = _("No books found in this series."), timeout = 2 })
        return
    end

    local overrides    = _getCoverOverrides()
    local cur_override = overrides[vpath]
    local picker
    local buttons = {}

    buttons[#buttons + 1] = {{
        text = (not cur_override and "✓ " or "  ") .. _("Auto (first book)"),
        callback = function()
            UIManager:close(picker)
            _clearCoverOverride(vpath)
            _invalidateFolderItem(menu, vpath)
        end,
    }}

    for _, item in ipairs(series_items) do
        local fp = item.path
        if fp then
            local bi    = BookInfoManager:getBookInfo(fp, false)
            local title = (bi and bi.title and bi.title ~= "")
                and bi.title
                or (fp:match("([^/]+)%.[^%.]+$") or fp)
            local _fp = fp
            buttons[#buttons + 1] = {{
                text = ((cur_override == _fp) and "✓ " or "  ") .. title,
                callback = function()
                    UIManager:close(picker)
                    _saveCoverOverride(vpath, _fp)
                    _invalidateFolderItem(menu, vpath)
                end,
            }}
        end
    end

    buttons[#buttons + 1] = {{
        text = _("Cancel"),
        callback = function() UIManager:close(picker) end,
    }}

    picker = ButtonDialog:new{ title = _("Folder cover"), title_align = "center", buttons = buttons }
    UIManager:show(picker)
end

-- Cover picker for real filesystem folders.
local function _openFolderCoverPicker(dir_path, menu, BookInfoManager)
    local UIManager    = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage  = require("ui/widget/infomessage")

    local books     = {}
    local max_depth = M.getRecursiveCover() and 3 or 1
    _collectBooks(menu, dir_path, 1, max_depth, books)

    if #books == 0 then
        UIManager:show(InfoMessage:new{ text = _("No books found in this folder."), timeout = 2 })
        return
    end

    local overrides    = _getCoverOverrides()
    local cur_override = overrides[dir_path]
    local picker
    local buttons = {}

    buttons[#buttons + 1] = {{
        text = (not cur_override and "✓ " or "  ") .. _("Auto (first book)"),
        callback = function()
            UIManager:close(picker)
            _clearCoverOverride(dir_path)
            _invalidateFolderItem(menu, dir_path)
        end,
    }}

    for _, entry in ipairs(books) do
        local fp      = entry.path
        local bi      = BookInfoManager:getBookInfo(fp, false)
        local title   = (bi and bi.title and bi.title ~= "")
            and bi.title
            or (fp:match("([^/]+)%.[^%.]+$") or fp)
        local rel       = fp:sub(#dir_path + 2)
        local subfolder = rel:match("^(.+)/[^/]+$")
        local label     = subfolder and (title .. "  [" .. subfolder .. "]") or title
        buttons[#buttons + 1] = {{
            text = ((cur_override == fp) and "✓ " or "  ") .. label,
            callback = function()
                UIManager:close(picker)
                _saveCoverOverride(dir_path, fp)
                _invalidateFolderItem(menu, dir_path)
            end,
        }}
    end

    buttons[#buttons + 1] = {{
        text = _("Cancel"),
        callback = function() UIManager:close(picker) end,
    }}

    picker = ButtonDialog:new{ title = _("Folder cover"), title_align = "center", buttons = buttons }
    UIManager:show(picker)
end

-- Adds "Set folder cover" and "Create collection" buttons to the FM file dialog.
local function _installFileDialogButton(BookInfoManager)
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok_fm or not FileManager then return end

    -- "Set folder cover" — hidden in quad mode (auto-selected) and for files.
    FileManager:addFileDialogButtons("simpleui_fc_cover",
        function(file, is_file, _book_props)
            if is_file then return nil end
            if not M.isEnabled() then return nil end

            local fc         = FileManager.instance and FileManager.instance.file_chooser
            local item_entry = nil
            if fc and fc.item_table then
                for _, it in ipairs(fc.item_table) do
                    if it.path == file then item_entry = it; break end
                end
            end

            local is_virtual_series = (item_entry and item_entry.is_series_group)
                                   or (_sg_items_cache[file] ~= nil)
            local is_virtual_meta   = item_entry and item_entry.is_virtual_meta_leaf

            local effective_style = _resolveStyle(fc, file, item_entry)
            local in_list_view    = fc and fc.display_mode_type == "list"
            if effective_style == "quad" and not in_list_view then return nil end

            return {{
                text = _("Set folder cover"),
                callback = function()
                    local UIManager = require("ui/uimanager")
                    if fc and fc.file_dialog then UIManager:close(fc.file_dialog) end
                    if not fc then return end
                    if is_virtual_series then
                        _openSeriesGroupCoverPicker(file, fc, BookInfoManager)
                    elseif is_virtual_meta then
                        local ok_bm, BM = pcall(require, "sui_browsemeta")
                        if ok_bm and BM and BM.openVirtualCoverPicker then
                            BM.openVirtualCoverPicker(file, fc)
                        end
                    else
                        _openFolderCoverPicker(file, fc, BookInfoManager)
                    end
                end,
            }}
        end
    )

    -- "Create collection" — series-group folders only; visible in all view modes.
    FileManager:addFileDialogButtons("simpleui_fc_series_collection",
        function(file, is_file, _book_props)
            if is_file then return nil end
            if not M.isEnabled() then return nil end
            if not M.getSeriesGrouping() then return nil end

            local fc         = FileManager.instance and FileManager.instance.file_chooser
            local item_entry = nil
            if fc and fc.item_table then
                for _, it in ipairs(fc.item_table) do
                    if it.path == file then item_entry = it; break end
                end
            end

            local is_virtual_series = (item_entry and item_entry.is_series_group)
                                   or (_sg_items_cache[file] ~= nil)
            if not is_virtual_series then return nil end

            local series_name = (item_entry and item_entry.text) or ""
            return {{
                text = _("Create collection"),
                callback = function()
                    local UIManager = require("ui/uimanager")
                    if fc and fc.file_dialog then UIManager:close(fc.file_dialog) end
                    _createCollectionFromSeriesGroup(file, series_name)
                end,
            }}
        end
    )
end

local function _uninstallFileDialogButton()
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok_fm or not FileManager then return end
    FileManager:removeFileDialogButtons("simpleui_fc_cover")
    FileManager:removeFileDialogButtons("simpleui_fc_series_collection")
end

-- ---------------------------------------------------------------------------
-- 8. Series grouping — virtual folder items for multi-book series
-- ---------------------------------------------------------------------------

-- _sg_current holds state while the user is inside a virtual series folder:
--   series_name:    used to re-find the group item on return to parent.
--   parent_page:    restores the scroll position in the parent list.
-- nil when in a real filesystem folder.
local _sg_current           = nil
local _sg_last_evicted_path = nil

-- Groups series books into virtual folder items in item_table (in place).
-- Books that share a series name are collapsed into one group item; singletons
-- are left as individual book entries.
local function _sgProcessItemTable(item_table, file_chooser)
    if not M.getSeriesGrouping()              then return end
    if not file_chooser or not item_table     then return end
    if item_table._sg_is_series_view          then return end
    if file_chooser.show_current_dir_for_hold then return end

    -- Evict stale _sg_items_cache entries for the current directory.
    local current_path = file_chooser.path
    if current_path and current_path ~= _sg_last_evicted_path then
        _sg_last_evicted_path = current_path
        local prefix = current_path
        if prefix:sub(-1) ~= "/" then prefix = prefix .. "/" end
        for k in pairs(_sg_items_cache) do
            if k:sub(1, #prefix) == prefix then _sg_items_cache[k] = nil end
        end
    end

    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok_bim or not BookInfoManager then return end

    local series_map      = {}
    local processed       = {}
    local book_count      = 0
    local no_series_count = 0

    for _, item in ipairs(item_table) do
        if item.is_go_up then
            processed[#processed + 1] = item
        else
            if not item.sort_percent     then item.sort_percent     = item.percent_finished or 0 end
            -- Do NOT default percent_finished to 0: nil means "never opened / no sidecar data"
            -- and is the gate used by has_progress and the "New" badge. Collapsing nil→0 here
            -- would make every book look like it has been opened with 0% progress.
            if item.opened == nil        then item.opened           = false end

            local handled = false
            if (item.is_file or item.file) and item.path then
                book_count = book_count + 1
                local doc_props = item.doc_props or BookInfoManager:getDocProps(item.path)
                local sname = doc_props and doc_props.series
                if sname and sname ~= "\u{FFFF}" then
                    item._sg_series_index = doc_props.series_index or 0
                    if not series_map[sname] then
                        local base_path  = item.path:match("(.*/)") or ""
                        local group_attr = {}
                        if item.attr then
                            for k, v in pairs(item.attr) do group_attr[k] = v end
                        end
                        group_attr.mode = "directory"
                        local vpath      = base_path .. sname
                        local group_item = {
                            text             = sname,
                            is_file          = false,
                            is_directory     = true,
                            is_series_group  = true,
                            path             = vpath,
                            series_items     = { item },
                            attr             = group_attr,
                            mode             = "directory",
                            sort_percent     = item.sort_percent,
                            percent_finished = item.percent_finished,
                            opened           = item.opened,
                            doc_props        = item.doc_props or {
                                series        = sname,
                                series_index  = 0,
                                display_title = sname,
                            },
                            suffix = item.suffix,
                        }
                        series_map[sname]         = group_item
                        group_item._sg_list_index = #processed + 1
                        processed[#processed + 1] = group_item
                    else
                        local si = series_map[sname].series_items
                        si[#si + 1] = item
                    end
                    handled = true
                else
                    no_series_count = no_series_count + 1
                end
            end
            if not handled then processed[#processed + 1] = item end
        end
    end

    -- If every book is in the same single series the folder is already
    -- organised — skip grouping to avoid a redundant nesting level.
    local series_count = 0
    for _ in pairs(series_map) do
        series_count = series_count + 1
        if series_count > 1 then break end
    end
    if series_count == 1 and no_series_count == 0 and book_count > 0 then return end

    -- Ungroup singleton series; sort and cache multi-book groups.
    for _, group in pairs(series_map) do
        local items = group.series_items
        if #items == 1 then
            local idx = group._sg_list_index
            if idx and processed[idx] == group then processed[idx] = items[1] end
        else
            table.sort(items, function(a, b)
                return (a._sg_series_index or 0) < (b._sg_series_index or 0)
            end)
            group.mandatory             = tostring(#items) .. " \u{F016}"
            _sg_items_cache[group.path] = items
        end
    end

    -- Re-sort the full list using FileChooser's sort function.
    local ok_collate, collate = pcall(function() return file_chooser:getCollate() end)
    local collate_obj = ok_collate and collate or nil
    local reverse     = G_reader_settings:isTrue("reverse_collate")
    local sort_func
    pcall(function() sort_func = file_chooser:getSortingFunction(collate_obj, reverse) end)
    local mixed = G_reader_settings:isTrue("collate_mixed")
        and collate_obj and collate_obj.can_collate_mixed

    local final   = {}
    local up_item = nil

    if mixed then
        local to_sort = {}
        for _, item in ipairs(processed) do
            if item.is_go_up then up_item = item
            else to_sort[#to_sort + 1] = item end
        end
        if sort_func then pcall(table.sort, to_sort, sort_func) end
        if up_item then final[#final + 1] = up_item end
        for _, item in ipairs(to_sort) do final[#final + 1] = item end
    else
        local dirs  = {}
        local files = {}
        for _, item in ipairs(processed) do
            if item.is_go_up then
                up_item = item
            elseif item.is_directory or item.is_series_group
                or (item.attr and item.attr.mode == "directory")
                or item.mode == "directory"
            then
                dirs[#dirs + 1] = item
            else
                files[#files + 1] = item
            end
        end
        if sort_func then pcall(table.sort, dirs,  sort_func) end
        if sort_func then pcall(table.sort, files, sort_func) end
        if up_item then final[#final + 1] = up_item end
        for _, d in ipairs(dirs)  do final[#final + 1] = d end
        for _, f in ipairs(files) do final[#final + 1] = f end
    end

    -- Replace item_table contents in place.
    for i = #item_table, 1, -1 do item_table[i] = nil end
    for i, v in ipairs(final)   do item_table[i] = v   end
end

-- Switch file_chooser into a virtual series folder view.
local function _sgOpenGroup(file_chooser, group_item)
    if not file_chooser then return end
    local items = group_item.series_items
    _sg_current = {
        series_name = group_item.text,
        parent_page = file_chooser.page or 1,
    }
    items._sg_is_series_view = true
    items._sg_parent_path    = file_chooser.path
    file_chooser:switchItemTable(nil, items, nil, nil, group_item.text)
    local ok_p, Patches = pcall(require, "sui_patches")
    if ok_p and Patches and Patches.setFMPathBase then
        local fm = require("apps/filemanager/filemanager").instance
        Patches.setFMPathBase(group_item.text, fm)
    end
    if file_chooser.onGotoPage then
        pcall(function() file_chooser:onGotoPage(1) end)
    end
end

-- Saved originals for the series-grouping FC hooks.
local _sg_orig_switchItemTable = nil
local _sg_orig_onMenuSelect    = nil
local _sg_orig_onMenuHold      = nil
local _sg_orig_onFolderUp      = nil
local _sg_orig_changeToPath    = nil
local _sg_orig_refreshPath     = nil
local _sg_orig_updateItems     = nil

local function _installSeriesGrouping()
    if FileChooser._simpleui_sg_patched then return end
    FileChooser._simpleui_sg_patched = true

    _sg_orig_switchItemTable = FileChooser.switchItemTable
    _sg_orig_onMenuSelect    = FileChooser.onMenuSelect
    _sg_orig_onMenuHold      = FileChooser.onMenuHold
    _sg_orig_onFolderUp      = FileChooser.onFolderUp
    _sg_orig_changeToPath    = FileChooser.changeToPath
    _sg_orig_refreshPath     = FileChooser.refreshPath
    _sg_orig_updateItems     = FileChooser.updateItems

    -- Process the incoming item_table before KOReader calculates itemmatch.
    -- Also clears _sg_is_series_view on the outgoing table at the last safe
    -- moment — avoids a timing window where the titlebar reads a stale flag.
    FileChooser.switchItemTable = function(fc, new_title, new_item_table,
                                           itemnumber, itemmatch, new_subtitle)
        if new_item_table and not new_item_table._sg_is_series_view then
            if fc.item_table then fc.item_table._sg_is_series_view = false end
            _sgProcessItemTable(new_item_table, fc)
        end
        return _sg_orig_switchItemTable(fc, new_title, new_item_table,
                                        itemnumber, itemmatch, new_subtitle)
    end

    FileChooser.onMenuSelect = function(fc, item)
        if item and item.is_series_group and M.getSeriesGrouping() then
            _sgOpenGroup(fc, item)
            return true
        end
        return _sg_orig_onMenuSelect(fc, item)
    end

    -- Long-press on a series-group shows a dialog with cover picker and
    -- "Create collection". Cover picker is hidden in quad mode.
    FileChooser.onMenuHold = function(fc, item)
        if item and item.is_series_group and M.getSeriesGrouping() then
            if not M.isEnabled() then return true end
            local UIManager    = require("ui/uimanager")
            local ButtonDialog = require("ui/widget/buttondialog")

            local in_list_view    = fc and fc.display_mode_type == "list"
            local cover_available = not (
                _resolveStyle(fc, item.path, item) == "quad" and not in_list_view
            )

            local series_name = (item.text or ""):gsub("/$", "")
            local vpath       = item.path
            local dialog
            local buttons     = {}

            if cover_available then
                buttons[#buttons + 1] = {{
                    text = _("Set folder cover"),
                    callback = function()
                        UIManager:close(dialog)
                        local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
                        if ok_bim and BookInfoManager then
                            _openSeriesGroupCoverPicker(vpath, fc, BookInfoManager)
                        end
                    end,
                }}
            end

            buttons[#buttons + 1] = {{
                text = _("Create collection"),
                callback = function()
                    UIManager:close(dialog)
                    _createCollectionFromSeriesGroup(vpath, series_name)
                end,
            }}

            buttons[#buttons + 1] = {{
                text     = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            }}

            dialog = ButtonDialog:new{
                title       = series_name,
                title_align = "center",
                buttons     = buttons,
            }
            UIManager:show(dialog)
            return true
        end
        return _sg_orig_onMenuHold(fc, item)
    end

    FileChooser.onFolderUp = function(fc)
        if fc.item_table and fc.item_table._sg_is_series_view then
            local parent = fc.item_table._sg_parent_path
            if parent then
                -- Clear the series view flag IMMEDIATELY so _resolveIsSub will work correctly
                fc.item_table._sg_is_series_view = false
                fc:changeToPath(parent)
            end
            return true
        end
        return _sg_orig_onFolderUp(fc)
    end

    FileChooser.changeToPath = function(fc, path, ...)
        if fc.item_table and fc.item_table._sg_is_series_view then
            local parent = fc.item_table._sg_parent_path
            -- Redirect ".." paths to the real parent.
            if parent and path and (path:match("/%.%.") or path:match("^%.%.")) then
                path = parent
            end
            -- _sg_is_series_view is cleared in switchItemTable (not here) to
            -- avoid a timing window between changeToPath and switchItemTable.
            if path == parent then
                if _sg_current then
                    _sg_current.should_restore = true
                    local saved_page = _sg_current.parent_page
                    if saved_page and saved_page > 1 then fc.page = saved_page end
                end
            else
                _sg_current = nil
            end
        else
            _sg_current = nil
        end
        return _sg_orig_changeToPath(fc, path, ...)
    end

    -- After closing a book (refreshPath), re-enter the virtual folder if one
    -- was active.  The depth counter guards against infinite recursion:
    -- _sgOpenGroup → switchItemTable can trigger another refreshPath on some
    -- KOReader versions; a boolean flag would stick on error.
    local _sg_refreshPath_depth = 0
    FileChooser.refreshPath = function(fc)
        if _sg_refreshPath_depth > 0 then return _sg_orig_refreshPath(fc) end
        _sg_refreshPath_depth = _sg_refreshPath_depth + 1

        _itc_invalidate()

        -- Flush disk-level cover caches only when the library was actually
        -- visited (files may have been added/removed).
        local HS = package.loaded["sui_homescreen"]
        if HS and HS._library_was_visited then
            for k in pairs(_cover_file_cache)   do _cover_file_cache[k]   = nil end
            for k in pairs(_cfc_b)              do _cfc_b[k]              = nil end
            _cfc_cnt = 0
            for k in pairs(_lm_dir_cover_cache) do _lm_dir_cover_cache[k] = nil end
            for k in pairs(_lmc_b)              do _lmc_b[k]              = nil end
            _lmc_cnt = 0
        end

        _sg_orig_refreshPath(fc)
        if M.getSeriesGrouping() and _sg_current then
            local sname      = _sg_current.series_name
            local saved_page = _sg_current.parent_page
            for _, item in ipairs(fc.item_table or {}) do
                if item.is_series_group and item.text == sname then
                    _sgOpenGroup(fc, item)
                    if _sg_current then _sg_current.parent_page = saved_page end
                    break
                end
            end
        end

        _sg_refreshPath_depth = _sg_refreshPath_depth - 1
    end

    -- Restore focus to the series group item when returning from a virtual folder.
    FileChooser.updateItems = function(fc, ...)
        if not M.getSeriesGrouping() then
            _sg_current = nil
            return _sg_orig_updateItems(fc, ...)
        end
        if fc.item_table and fc.item_table._sg_is_series_view then
            return _sg_orig_updateItems(fc, ...)
        end
        if _sg_current and _sg_current.should_restore
                and fc.item_table and #fc.item_table > 0 then
            local sname = _sg_current.series_name
            for idx, item in ipairs(fc.item_table) do
                if item.is_series_group and item.text == sname then
                    fc.page = math.ceil(idx / fc.perpage)
                    local select_num = ((idx - 1) % fc.perpage) + 1
                    if fc.path_items and fc.path then fc.path_items[fc.path] = idx end
                    _sg_current = nil
                    return _sg_orig_updateItems(fc, select_num)
                end
            end
            _sg_current = nil
        end
        return _sg_orig_updateItems(fc, ...)
    end
end

local function _uninstallSeriesGrouping()
    if not FileChooser._simpleui_sg_patched then return end
    if _sg_orig_switchItemTable then FileChooser.switchItemTable = _sg_orig_switchItemTable; _sg_orig_switchItemTable = nil end
    if _sg_orig_onMenuSelect    then FileChooser.onMenuSelect    = _sg_orig_onMenuSelect;    _sg_orig_onMenuSelect    = nil end
    if _sg_orig_onMenuHold      then FileChooser.onMenuHold      = _sg_orig_onMenuHold;      _sg_orig_onMenuHold      = nil end
    if _sg_orig_onFolderUp      then FileChooser.onFolderUp      = _sg_orig_onFolderUp;      _sg_orig_onFolderUp      = nil end
    if _sg_orig_changeToPath    then FileChooser.changeToPath    = _sg_orig_changeToPath;    _sg_orig_changeToPath    = nil end
    if _sg_orig_refreshPath     then FileChooser.refreshPath     = _sg_orig_refreshPath;     _sg_orig_refreshPath     = nil end
    if _sg_orig_updateItems     then FileChooser.updateItems     = _sg_orig_updateItems;     _sg_orig_updateItems     = nil end
    FileChooser._simpleui_sg_patched = nil
    _sg_current           = nil
    _sg_items_cache       = {}
    _sg_last_evicted_path = nil
end

-- Public API for other modules that need to query or exit the series view.
function M.isInSeriesView(fc)
    return fc and fc.item_table and fc.item_table._sg_is_series_view == true
end

-- Exits the series view and navigates to the real parent folder.
function M.exitSeriesView(fc)
    if not M.isInSeriesView(fc) then return end
    local parent = fc.item_table._sg_parent_path
    _sg_current = nil
    fc.item_table._sg_is_series_view = false
    if parent then fc:changeToPath(parent) end
end

-- ---------------------------------------------------------------------------
-- 9. Widget builders
-- ---------------------------------------------------------------------------

-- ── Progress pentagon badge ──────────────────────────────────────────────────
-- Drawn directly onto the cover Blitbuffer (no intermediate buffer) so pixels
-- outside the pentagon are never written and the cover art shows through the
-- triangular tip without a white rectangle artefact.
--
-- Shape: downward-pointing pentagon (rectangle body + triangular tip).
-- States: "complete" → checkmark; percent_finished set → "42%"; otherwise bare.

local function _pentagonPaintRect(bb, bx, by, bw, bh, color)
    local rect_h = math.floor(bh * 30 / 42)
    local tip_h  = bh - rect_h
    bb:paintRect(bx, by, bw, rect_h, color)
    for row = 0, tip_h - 1 do
        local frac = (row + 1) / tip_h
        local rw   = math.max(2, math.floor(bw * (1 - frac)))
        local rx   = bx + math.floor((bw - rw) / 2)
        bb:paintRect(rx, by + rect_h + row, rw, 1, color)
    end
end

local function _drawCheckLine(bb, x0, y0, x1, y1, tk, color)
    local steps = math.max(math.abs(x1 - x0), math.abs(y1 - y0))
    if steps == 0 then steps = 1 end
    for i = 0, steps do
        local t = i / steps
        bb:paintRect(
            math.floor(x0 + t * (x1 - x0)),
            math.floor(y0 + t * (y1 - y0)),
            tk, tk, color)
    end
end

local function _pentagonPaintCheck(bb, bx, by, bw, bh, color)
    local tk = math.max(2, math.floor(math.min(bw, bh) / 8))
    local lx0 = bx + math.floor(bw * 0.08); local ly0 = by + math.floor(bh * 0.62)
    local lx1 = bx + math.floor(bw * 0.30); local ly1 = by + math.floor(bh * 0.82)
    local rx1  = bx + math.floor(bw * 0.82); local ry1 = by + math.floor(bh * 0.18)
    _drawCheckLine(bb, lx0, ly0, lx1, ly1, tk, color)
    _drawCheckLine(bb, lx1, ly1, rx1, ry1, tk, color)
end

-- Returns a descriptor table for the progress badge, or nil when too small.
-- No Blitbuffer is allocated here — drawing is deferred to paintTo().
local function _buildProgressBadgeDesc(eff_size, status, percent_finished, border, dark)
    local bw = math.floor(eff_size * 1.3)
    local bh = math.floor(eff_size * 1.4)
    if bw < 4 or bh < 4 then return nil end

    local text_color  = dark and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local text_widget = nil

    if status == "abandoned" then
        local font_sz = math.max(7, math.floor(eff_size * 0.26))
        text_widget = TextWidget:new{
            text    = "\u{EAE3}",
            face    = Font:getFace(SUIStyle.FACE_ICONS, font_sz),
            bold    = false,
            fgcolor = text_color,
            padding = 0,
        }
    elseif percent_finished ~= nil and status ~= "complete" then
        local pct     = math.floor(percent_finished * 100 + 0.5)
        local font_sz = math.max(7, math.floor(eff_size * 0.26))
        text_widget = TextWidget:new{
            text    = pct .. "%",
            face    = Font:getFace(SUIStyle.FACE_REGULAR, font_sz),
            bold    = true,
            fgcolor = text_color,
            padding = 0,
        }
    end

    return {
        bw               = bw,
        bh               = bh,
        border           = border or SUIStyle.BADGE_BORDER_SZ,
        status           = status,
        percent_finished = percent_finished,
        eff_size         = eff_size,
        dark             = dark ~= false,
        text_widget      = text_widget,
    }
end

-- Draw the progress badge described by `desc` directly onto `bb` at (ox, oy).
local function _drawProgressBadge(bb, ox, oy, desc)
    local bw         = desc.bw
    local bh         = desc.bh
    local fr         = desc.border
    local fill_color = desc.dark and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local text_color = desc.dark and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local brd_color  = SUIStyle.BADGE_BORDER_CLR

    _pentagonPaintRect(bb, ox,      oy,      bw + 2 * fr, bh + 2 * fr, brd_color)
    _pentagonPaintRect(bb, ox + fr, oy + fr, bw,          bh,          fill_color)

    local rect_h     = math.floor(bh * 30 / 42)
    local pad_x      = math.floor(bw * 0.12)
    local pad_y      = math.floor(rect_h * 0.25)
    local icon_x     = ox + fr + pad_x
    local icon_y     = oy + fr + pad_y
    local icon_w     = bw - 2 * pad_x
    local icon_h     = rect_h - 2 * pad_y
    -- Shift content downward for visual balance with the triangular tip below.
    local text_y_offset = math.floor(rect_h * 0.15)

    if desc.status == "complete" then
        local sq   = math.min(icon_w, icon_h)
        local sq_x = icon_x + math.floor((icon_w - sq) / 2)
        local sq_y = oy + fr + math.floor((rect_h - sq) / 2) + text_y_offset
        _pentagonPaintCheck(bb, sq_x, sq_y, sq, sq, text_color)
    elseif desc.status == "abandoned" then
        if desc.text_widget then
            local aw_sz = desc.text_widget:getSize()
            desc.text_widget:paintTo(bb,
                ox + fr + math.floor((bw     - aw_sz.w) / 2),
                oy + fr + math.floor((rect_h - aw_sz.h) / 2) + text_y_offset)
        end
    elseif desc.percent_finished ~= nil then
        if desc.text_widget then
            local tw_sz = desc.text_widget:getSize()
            desc.text_widget:paintTo(bb,
                ox + fr + math.floor((bw     - tw_sz.w) / 2),
                oy + fr + math.floor((rect_h - tw_sz.h) / 2) + text_y_offset)
        end
    end
    -- "not started": bare pentagon, no content drawn.
end

-- ── Corner ribbon ("New" style) ───────────────────────────────────────────
-- Paints a diagonal band across the top-right corner of the cover Blitbuffer
-- at 45°, with the label text rotated inside it.
--
-- Strategy: build a temp Blitbuffer (tw × band_thick) in axis-aligned space,
-- render border + fill + text into it once, then use a destination-driven
-- inverse-map loop to blit each screen pixel from the rotated source.
-- The result is cached by (dimensions, label, colors) so the per-pixel loop
-- only runs once per unique configuration, not once per cover.

local function _paintCornerRibbon(bb, cover_left, cover_right, cover_top, cover_h,
                                  span, band_thick, label, font_sz, dark)
    local C = 0.70711  -- cos 45° = sin 45°

    -- Buffer width: (span + 2*band) * √2 so the ribbon ends protrude past both
    -- cover edges; the cover-bounds clipping hides the end-cuts cleanly.
    local tw = math.ceil((span + band_thick * 2) * 1.41422)
    local th = band_thick
    if tw <= 0 or th <= 0 then return end

    local bg  = dark and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local fg  = dark and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local brd = SUIStyle.BADGE_BORDER_CLR

    local cache_key = string.format("%d|%d|%d|%s|%d|%d|%s|%s",
        tw, th, bb:getType(), label, font_sz, dark and 1 or 0, tostring(SUIStyle.BADGE_BORDER_SZ), tostring(brd))
    local tmp = _ribbon_bb_cache[cache_key]

    if not tmp then
        tmp = Blitbuffer.new(tw, th, bb:getType())
        if not tmp then return end

        -- 1-px border on long edges, bg interior.
        local bw = SUIStyle.BADGE_BORDER_SZ
        tmp:paintRect(0, 0, tw, th, brd)
        if bw * 2 < th then
            tmp:paintRect(0, bw, tw, th - bw * 2, bg)
        end

        -- Render label; step font down 1pt at a time until it fits, min 6pt.
        local inner_h = math.max(1, th - bw * 2)
        local max_w   = math.floor(tw * 0.82)
        local lbl, lsz
        local fs = font_sz
        repeat
            if lbl and lbl.free then lbl:free() end
            lbl = TextWidget:new{
                text    = label,
                face    = Font:getFace(SUIStyle.FACE_REGULAR, fs),
                bold    = true,
                fgcolor = fg,
                padding = 0,
            }
            lsz = lbl:getSize()
            if lsz.w <= max_w and lsz.h <= inner_h then break end
            fs = fs - 1
        until fs < 6
        local lx = math.max(0, math.floor((tw - lsz.w) / 2))
        local ly = math.max(0, math.floor((th - lsz.h) / 2))
        lbl:paintTo(tmp, lx, ly)
        if lbl.free then lbl:free() end

        _ribbon_bb_cache[cache_key] = tmp
    end

    -- Destination-driven inverse-map: for each screen pixel in the ribbon's
    -- bounding box, reverse-rotate 45° to find the source pixel in tmp.
    local cx       = cover_right - math.floor(span / 2)
    local cy       = cover_top   + math.floor(span / 2)
    local half_box = math.ceil((tw + th) * C / 2) + 1
    local bb_w     = bb:getWidth()
    local bb_h     = bb:getHeight()
    local tw_half  = tw / 2
    local th_half  = th / 2
    for dy = cy - half_box, cy + half_box do
        if dy >= cover_top and dy < cover_top + cover_h and dy >= 0 and dy < bb_h then
            local dy_rel = dy - cy
            for dx = cx - half_box, cx + half_box do
                if dx >= cover_left and dx < cover_right and dx >= 0 and dx < bb_w then
                    local dx_rel = dx - cx
                    -- Inverse of +45° rotation (top-right "\" band).
                    local sx = math.floor(tw_half + (dx_rel + dy_rel) * C)
                    local sy = math.floor(th_half + (dy_rel - dx_rel) * C)
                    if sx >= 0 and sx < tw and sy >= 0 and sy < th then
                        bb:setPixel(dx, dy, tmp:getPixel(sx, sy))
                    end
                end
            end
        end
    end
end

-- ── Rounded-rectangle badge (pages, series index, "New") ─────────────────────

local function _buildRectBadgeWidget(text, bold, cell_min, dark, new_badge, badge_scale)
    badge_scale = badge_scale or 1.0
    local eff_size = math.max(8, math.floor((cell_min or 40) * 0.15 * badge_scale))
    local font_sz  = math.max(7, math.floor(eff_size * 0.24))
    local pad_h    = math.max(1, math.floor(eff_size * 0.10))
    local pad_v    = math.max(1, math.floor(eff_size * 0.06))
    local corner   = math.max(1, math.floor(eff_size * 0.08))
    local border   = SUIStyle.BADGE_BORDER_SZ

    local bg = dark and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local fg = dark and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local border_color = SUIStyle.BADGE_BORDER_CLR

    local tw = TextWidget:new{
        text    = text,
        face    = Font:getFace(SUIStyle.FACE_REGULAR, font_sz),
        bold    = bold or false,
        fgcolor = fg,
        padding = 0,
    }
    local tsz    = tw:getSize()
    local lateral = pad_h * 4
    local inner_h = tsz.h + pad_v * 2
    -- Enforce a square minimum so short labels like "#1" are not tiny slivers.
    local inner_w = math.max(tsz.w + lateral, inner_h)
    local w = inner_w + border * 2
    local h = inner_h + border * 2
    if w < 4 or h < 4 then tw:free(); return nil end

    return FrameContainer:new{
        dimen      = Geom:new{ w = w, h = h },
        bordersize = border,
        color      = border_color,
        background = bg,
        radius     = corner,
        padding    = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            tw,
        },
    }
end

-- ── Book spine decoration ─────────────────────────────────────────────────────

local function _buildSpine(img_h)
    local h1 = math.floor(img_h * 0.97)
    local h2 = math.floor(img_h * 0.94)
    local y1 = math.floor((img_h - h1) / 2)
    local y2 = math.floor((img_h - h2) / 2)

    local function spineLine(h, y_off)
        local line = LineWidget:new{
            dimen      = Geom:new{ w = _EDGE_THICK, h = h },
            background = _SPINE_COLOR,
        }
        line.overlap_offset = { 0, y_off }
        return OverlapGroup:new{ dimen = Geom:new{ w = _EDGE_THICK, h = img_h }, line }
    end

    return HorizontalGroup:new{
        align = "center",
        spineLine(h2, y2),
        HorizontalSpan:new{ width = _EDGE_MARGIN },
        spineLine(h1, y1),
        HorizontalSpan:new{ width = _EDGE_MARGIN },
    }
end

-- ── Folder-name label overlay ─────────────────────────────────────────────────

-- Returns the overlay label widget, or nil when disabled.
-- `display` is the pre-read settings table { label_mode, show_name, label_style, label_pos, label_color }.
local function _buildLabel(item, available_w, size, border, cv_scale, display, spine_w)
    if display.label_mode ~= "overlay" then return nil end
    if not display.show_name            then return nil end
    local label_style = display.label_style
    local label_pos   = display.label_pos
    local dark        = display.label_color == "dark"
    local bg_color    = dark and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local fg_color    = dark and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK

    local dir_max_fs = math.max(8, math.floor(_BASE_DIR_FS * M.getLabelScale()))
    local directory  = item:_getFolderNameWidget(available_w, dir_max_fs, fg_color, bg_color)
    local img_only   = Geom:new{ w = size.w, h = size.h }
    local img_dimen  = Geom:new{ w = size.w + border * 2, h = size.h + border * 2 }

    local frame = FrameContainer:new{
        padding        = 0,
        padding_top    = _VERTICAL_PAD,
        padding_bottom = _VERTICAL_PAD,
        padding_left   = _LATERAL_PAD,
        padding_right  = _LATERAL_PAD,
        bordersize     = border,
        background     = bg_color,
        directory,
    }

    local label_inner
    if label_style == "alpha" then
        label_inner = AlphaContainer:new{ alpha = _LABEL_ALPHA, frame }
    else
        label_inner = frame
    end

    local name_og = OverlapGroup:new{ dimen = img_dimen }

    if label_pos == "center" then
        name_og[1] = CenterContainer:new{ dimen = img_only, label_inner, overlap_align = "center" }
    elseif label_pos == "top" then
        name_og[1] = TopContainer:new{ dimen = img_dimen, label_inner, overlap_align = "center" }
    else
        name_og[1] = BottomContainer:new{ dimen = img_dimen, label_inner, overlap_align = "center" }
    end

    name_og.overlap_offset = { spine_w or _SPINE_W, 0 }
    return name_og
end

-- ── Folder book-count badge (circle) ─────────────────────────────────────────

-- `cell_dimen` is the full mosaic cell (used for sizing); when absent,
-- cover_dimen is used instead (produces a smaller badge).
local function _buildBadge(mandatory, cover_dimen, cv_scale, cell_dimen)
    if M.getBadgeHidden() then return nil end
    local nb_text = mandatory and mandatory:match("(%d+) \u{F016}") or ""
    if nb_text == "" or nb_text == "0" then return nil end

    local badge_scale    = M.getBadgeScale()
    local nb_count       = tonumber(nb_text)
    local size_dimen     = cell_dimen or cover_dimen
    local cell_min       = math.min(size_dimen.w, size_dimen.h)
    local nb_size        = math.max(8, math.floor(cell_min * 0.13 * badge_scale))
    local nb_font_size   = math.max(7, math.floor(nb_size * 0.28))
    local badge_margin   = math.max(1, math.floor(_BADGE_MARGIN_BASE   * cv_scale))
    local badge_margin_r = math.max(1, math.floor(_BADGE_MARGIN_R_BASE * cv_scale))
    local dark           = M.getBadgeColorFolder() == "dark"
    local bg_color       = dark and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local fg_color       = dark and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local border_color   = SUIStyle.BADGE_BORDER_CLR

    local badge = FrameContainer:new{
        padding    = 0,
        bordersize = SUIStyle.BADGE_BORDER_SZ,
        color      = border_color,
        background = bg_color,
        radius     = math.floor(nb_size / 2),
        dimen      = Geom:new{ w = nb_size, h = nb_size },
        CenterContainer:new{
            dimen = Geom:new{ w = nb_size - 2 * SUIStyle.BADGE_BORDER_SZ, h = nb_size - 2 * SUIStyle.BADGE_BORDER_SZ },
            (function()
                local tw = TextWidget:new{
                    text    = tostring(math.min(nb_count, 99)),
                    face    = Font:getFace(SUIStyle.FACE_REGULAR, nb_font_size),
                    fgcolor = fg_color,
                    bold    = true,
                }
                local _orig_pt = tw.paintTo
                tw.paintTo = function(self, bb, x, y)
                    _orig_pt(self, bb, x, y + 1) -- HACK: Change this +1 to the required value
                end
                return tw
            end)(),
        },
    }

    local inner = RightContainer:new{
        dimen = Geom:new{ w = cover_dimen.w, h = nb_size + badge_margin },
        FrameContainer:new{
            padding       = 0,
            padding_right = badge_margin_r,
            bordersize    = 0,
            badge,
        },
    }

    if M.getBadgePosition() == "bottom" then
        return BottomContainer:new{
            dimen          = cover_dimen,
            padding_bottom = badge_margin,
            inner,
            overlap_align  = "center",
        }
    else
        return TopContainer:new{
            dimen         = cover_dimen,
            padding_top   = badge_margin,
            inner,
            overlap_align = "center",
        }
    end
end

-- ── Shared geometry helper ────────────────────────────────────────────────────

-- Computes the five values every cover-building function needs.
-- self.height is already reduced by _STRIP_H in the update() wrapper before
-- this is called, so _module_strip_h must NOT be subtracted again here.
local function _computeCellGeometry(item)
    local border  = SUIStyle.BADGE_BORDER_SZ
    local spine_w = not M.getHideSpine() and _SPINE_W or 0
    local max_img_w = item.width  - spine_w - border * 2
    local max_img_h = item.height - border * 2
    return border, spine_w, max_img_w, max_img_h
end

-- ── Cover assembly helper ─────────────────────────────────────────────────────

-- Wraps any pre-built content_widget with the spine, centres it in the mosaic
-- cell, and overlays the folder-name label and item-count badge.
-- cv_scale is derived from cover_h here so callers don't have to compute it.
-- Must be defined before _buildQuadCover, which calls it.
local function _assembleCoverWidget(item, content_widget, size, border, spine_w, display)
    local spine       = spine_w > 0 and _buildSpine(size.h) or nil
    local cover_group = spine
        and HorizontalGroup:new{ align = "center", spine, content_widget }
        or  HorizontalGroup:new{ align = "center", content_widget }

    local cover_w     = spine_w + size.w + border * 2
    local cover_h     = size.h  + border * 2
    local cover_dimen = Geom:new{ w = cover_w, h = cover_h }
    local cell_dimen  = Geom:new{ w = item.width, h = item.height }
    local cv_scale    = math.max(0.1, math.floor((cover_h / _BASE_COVER_H) * 10) / 10)

    local folder_name_widget = _buildLabel(item, size.w - _LATERAL_PAD * 2,
        size, border, cv_scale, display, spine_w)
    local nbitems_widget = _buildBadge(item.mandatory, cover_dimen, cv_scale, cell_dimen)

    local overlap = OverlapGroup:new{ dimen = cover_dimen, cover_group }
    if folder_name_widget then overlap[#overlap + 1] = folder_name_widget end
    if nbitems_widget     then overlap[#overlap + 1] = nbitems_widget     end

    local x_center = math.floor((item.width  - cover_w) / 2)
    local y_center = math.floor((item.height - cover_h) / 2)
    overlap.overlap_offset = { x_center - math.floor(spine_w / 2), y_center }

    return OverlapGroup:new{ dimen = cell_dimen, overlap }
end

-- Mark the cell as processed, free the previous widget, and assign the new one.
local function _installWidget(item, widget)
    item._foldercover_processed = true
    if item._underline_container[1] then item._underline_container[1]:free() end
    item._underline_container[1] = widget
end

-- ── 2×2 quad cover ───────────────────────────────────────────────────────────

-- Returns the OverlapGroup widget for the 2×2 grid, or nil when no covers
-- are available.
-- Defined after _assembleCoverWidget (which it calls) and _buildSpine.
local function _buildQuadCover(item, img_list, border, spine_w, max_img_w, max_img_h, display)
    local sep   = math.max(1, Screen:scaleBySize(1))
    local ratio = 2 / 3
    local img_w, img_h
    if max_img_w / max_img_h > ratio then
        img_h = max_img_h; img_w = math.floor(max_img_h * ratio)
    else
        img_w = max_img_w; img_h = math.floor(max_img_w / ratio)
    end

    local half_w  = math.floor((img_w - sep) / 2)
    local half_w2 = img_w - sep - half_w
    local half_h  = math.floor((img_h - sep) / 2)
    local half_h2 = img_h - sep - half_h

    local cells = {}
    for i = 1, 4 do
        local c  = img_list[i]
        local cw = (i == 1 or i == 3) and half_w or half_w2
        local ch = (i == 1 or i == 2) and half_h or half_h2
        if c then
            local img_opts = { width = cw, height = ch }
            if c.file  then img_opts.file  = c.file  end
            if c.data  then img_opts.image = c.data  end
            cells[i] = CenterContainer:new{
                dimen = Geom:new{ w = cw, h = ch },
                ImageWidget:new(img_opts),
            }
        else
            -- Empty slot: white fill keeps separator lines visible.
            -- A child widget is required so FrameContainer:getSize() doesn't crash.
            cells[i] = CenterContainer:new{
                dimen = Geom:new{ w = cw, h = ch },
                VerticalSpan:new{ width = 1 },
            }
        end
    end

    local sep_color = Blitbuffer.COLOR_LIGHT_GRAY
    local grid = FrameContainer:new{
        padding    = 0,
        bordersize = border,
        VerticalGroup:new{
            HorizontalGroup:new{
                cells[1],
                LineWidget:new{ background = sep_color, dimen = Geom:new{ w = sep, h = half_h } },
                cells[2],
            },
            LineWidget:new{ background = sep_color, dimen = Geom:new{ w = img_w, h = sep } },
            HorizontalGroup:new{
                cells[3],
                LineWidget:new{ background = sep_color, dimen = Geom:new{ w = sep, h = half_h2 } },
                cells[4],
            },
        },
    }

    local size = Geom:new{ w = img_w, h = img_h }
    return _assembleCoverWidget(item, grid, size, border, spine_w, display)
end

-- ---------------------------------------------------------------------------
-- 10. Core patches — M.install and M.uninstall
-- ---------------------------------------------------------------------------

-- Helper: retrieve MosaicMenuItem from mosaicmenu via userpatch upvalue lookup.
local function _getMosaicMenuItemAndPatch()
    local ok_mm, MosaicMenu = pcall(require, "mosaicmenu")
    if not ok_mm or not MosaicMenu then return nil, nil end
    local ok_up, userpatch = pcall(require, "userpatch")
    if not ok_up or not userpatch then return nil, nil end
    return userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem"), userpatch
end

-- Helper: retrieve ListMenuItem from listmenu via userpatch upvalue lookup.
local function _getListMenuItem()
    local ok_lm, ListMenu = pcall(require, "listmenu")
    if not ok_lm or not ListMenu then return nil end
    local ok_up, userpatch = pcall(require, "userpatch")
    if not ok_up or not userpatch then return nil end
    return userpatch.getUpValue(ListMenu._updateItemsBuildUI, "ListMenuItem")
end

-- Install the title/author strip paintTo patch.
-- Called from M.install() after the badge paintTo wrap so this wrapper is the
-- outermost layer and calls the badge-patched paintTo as orig_paintTo.
-- Deferred via FileManager.setupLayout so the badge patch is already applied
-- when we capture orig_paintTo.
local function _installStripPatch(MosaicMenuItem, BookInfoManager, _STRIP_H,
                                   _show_title_strip, _show_author_strip)
    local ok_fm_strip, FileManager_strip = pcall(require, "apps/filemanager/filemanager")
    if not ok_fm_strip or not FileManager_strip then return end

    local _strip_orig_setupLayout = FileManager_strip.setupLayout
    local _strip_paintTo_patched  = false

    local function _stripPaintFn(w, tmp_bb, tx, ty)
        tmp_bb:blitFrom(w._simpleui_strip_bb, tx, ty, 0, 0, w.width, _module_strip_h)
    end

    FileManager_strip.setupLayout = function(fm, ...)
        _strip_orig_setupLayout(fm, ...)
        if _strip_paintTo_patched or not fm.coverbrowser then return end
        _strip_paintTo_patched = true

        local Blitbuffer_s  = require("ffi/blitbuffer")
        local Font_s        = require("ui/font")
        local TextWidget_s  = require("ui/widget/textwidget")
        local BD_s          = require("ui/bidi")
        local Screen_s      = require("device").screen
        local UI_core       = require("sui_core")

        local TITLE_FONT_S  = SUIStyle.FS_DETAIL    -- 15: cover title in size-probe context
        local AUTHOR_FONT_S = SUIStyle.FS_CAPTION   -- 12: cover author in size-probe context
        local PAD_S         = Screen_s:scaleBySize(3)
        local GAP_S         = Screen_s:scaleBySize(2)
        local PAD_H_S       = Screen_s:scaleBySize(6)

        local function _mhs(fs, bold)
            local tw = TextWidget_s:new{ text="Ag", face=Font_s:getFace(SUIStyle.FACE_REGULAR,fs),
                bold=bold, padding=0 }
            local h = tw:getSize().h; tw:free(); return h
        end
        local TITLE_LINE_S = _mhs(TITLE_FONT_S, true)

        local orig_strip_paintTo = MosaicMenuItem.paintTo

        function MosaicMenuItem:paintTo(bb, x, y)
            x = math.floor(x); y = math.floor(y)
            -- Temporarily shrink self.height so the badge paintTo chain computes
            -- the cover area as ending above the strip (keeps native progress bar
            -- and dog-ear inside the cover zone).
            if _STRIP_H > 0 and self.height then
                self.height = self.height - _STRIP_H
            end
            orig_strip_paintTo(self, bb, x, y)
            if _STRIP_H > 0 and self.height then
                self.height = self.height + _STRIP_H
            end

            if _STRIP_H <= 0 then return end

            -- Build/use the cached strip blitbuffer.
            if not self._simpleui_strip_bb then

                -- Folders: render the folder name centred in the strip.
                if self.is_directory then
                    local name = self.text and self.text:gsub("/$", "") or ""
                    if name == "" then return end
                    local strip_bb = Blitbuffer_s.new(self.width, _STRIP_H, bb:getType())
                    strip_bb:fill(Blitbuffer_s.COLOR_WHITE)
                    local tw = TextWidget_s:new{
                        text                   = BD_s.auto(name),
                        face                   = Font_s:getFace(SUIStyle.FACE_REGULAR, TITLE_FONT_S),
                        bold                   = true,
                        padding                = 0,
                        fgcolor                = Blitbuffer_s.COLOR_BLACK,
                        max_width              = self.width - 2 * PAD_H_S,
                        truncate_with_ellipsis = true,
                    }
                    local tsz = tw:getSize()
                    tw:paintTo(strip_bb,
                        math.floor((self.width - tsz.w) / 2),
                        math.floor((_STRIP_H  - tsz.h) / 2))
                    tw:free()
                    self._simpleui_strip_bb = strip_bb

                -- Books: render title and/or author.
                else
                    -- Populate metadata on first paint after update().
                    if self._simpleui_strip_data == nil then
                        if not self.bookinfo_found then
                            self._simpleui_strip_data = false
                        else
                            local info    = BookInfoManager:getBookInfo(self.filepath, false)
                            local title   = info and not info.ignore_meta and info.title   or nil
                            local authors = info and not info.ignore_meta and info.authors or nil

                            -- Apply custom metadata overrides when available.
                            pcall(function()
                                local DS = require("docsettings")
                                local custom_file = DS.findCustomMetadataFile(DS, self.filepath)
                                if custom_file and require("libs/libkoreader-lfs").attributes(custom_file, "mode") == "file" then
                                    local cs = DS.openSettingsFile(custom_file)
                                    if cs then
                                        local cprops = cs:readSetting("custom_props")
                                        if cprops then
                                            title   = cprops.title   or title
                                            authors = cprops.authors or authors
                                        end
                                    end
                                end
                            end)

                            -- Use only the first author when multiple are newline-separated.
                            if authors and authors:find("\n") then
                                authors = authors:match("^([^\n]+)")
                            end
                            if title or authors then
                                self._simpleui_strip_data = { title = title, authors = authors }
                            else
                                self._simpleui_strip_data = false
                            end
                        end
                    end
                    if not self._simpleui_strip_data then return end

                    local strip_bb = Blitbuffer_s.new(self.width, _STRIP_H, bb:getType())
                    strip_bb:fill(Blitbuffer_s.COLOR_WHITE)
                    local text_w = self.width - 2 * PAD_H_S
                    local cur_y  = PAD_S

                    if _show_title_strip and self._simpleui_strip_data.title then
                        local tw = TextWidget_s:new{
                            text                   = BD_s.auto(self._simpleui_strip_data.title),
                            face                   = Font_s:getFace(SUIStyle.FACE_REGULAR, TITLE_FONT_S),
                            bold                   = true,
                            padding                = 0,
                            fgcolor                = Blitbuffer_s.COLOR_BLACK,
                            max_width              = text_w,
                            truncate_with_ellipsis = true,
                        }
                        local tsz = tw:getSize()
                        tw:paintTo(strip_bb, math.floor((self.width - tsz.w) / 2), cur_y)
                        tw:free()
                        if _show_author_strip then cur_y = cur_y + TITLE_LINE_S + GAP_S end
                    end

                    if _show_author_strip and self._simpleui_strip_data.authors then
                        local aw = TextWidget_s:new{
                            text                   = BD_s.auto(self._simpleui_strip_data.authors),
                            face                   = Font_s:getFace(SUIStyle.FACE_REGULAR, AUTHOR_FONT_S),
                            bold                   = false,
                            padding                = 0,
                            fgcolor                = Blitbuffer_s.COLOR_BLACK,
                            max_width              = text_w,
                            truncate_with_ellipsis = true,
                        }
                        local asz = aw:getSize()
                        aw:paintTo(strip_bb, math.floor((self.width - asz.w) / 2), cur_y)
                        aw:free()
                    end

                    self._simpleui_strip_bb = strip_bb
                end
            end

            -- Blit the strip immediately below the cover area.
            if self._simpleui_strip_bb then
                local ok_hs, HS_s = pcall(require, "sui_homescreen")
                local wp_active = ok_hs and HS_s
                    and HS_s.styleGetWallpaperShowInFM()
                    and HS_s.styleGetBgWidget() ~= nil

                if wp_active then
                    if not self._simpleui_strip_mask_bb
                            or self._simpleui_strip_mask_bb:getWidth() ~= self.width then
                        if self._simpleui_strip_mask_bb then
                            self._simpleui_strip_mask_bb:free()
                        end
                        self._simpleui_strip_mask_bb =
                            Blitbuffer_s.new(self.width, _STRIP_H, Blitbuffer_s.TYPE_BB8)
                    end
                    UI_core.paintWithAlphaMask(self, bb,
                        x, y + self.height - _STRIP_H, self.width, _STRIP_H,
                        Blitbuffer_s.COLOR_BLACK,
                        _stripPaintFn, self._simpleui_strip_mask_bb)
                else
                    bb:blitFrom(self._simpleui_strip_bb,
                        x, y + self.height - _STRIP_H,
                        0, 0, self.width, _STRIP_H)
                end
            end
        end -- MosaicMenuItem:paintTo (strip wrapper)
    end -- FileManager_strip.setupLayout
end

function M.install()
    local MosaicMenuItem, userpatch = _getMosaicMenuItemAndPatch()
    if not MosaicMenuItem then return end
    if MosaicMenuItem._simpleui_fc_patched then return end

    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok_bim or not BookInfoManager then return end

    local ok_rc, ReadCollection = pcall(require, "readcollection")
    if not ok_rc then ReadCollection = nil end

    -- Lazy cache for collection_mark upvalues from orig_paintTo.
    -- Populated on first banner-mode paint of a book in a collection.
    local _fc_coll_sz, _fc_coll_widget
    local _corner_mark_idx, _collection_mark_idx
    local _upvalues_searched = false

    -- Captured before each render so StretchingImageWidget can enforce 2:3.
    local max_img_w, max_img_h

    -- Replace the upvalue ImageWidget in MosaicMenuItem.update with a subclass
    -- that enforces 2:3 when cover_mode == "2_3".
    if not MosaicMenuItem._simpleui_fc_iw_n then
        local local_ImageWidget
        local n = 1
        while true do
            local name, value = debug.getupvalue(MosaicMenuItem.update, n)
            if not name then break end
            if name == "ImageWidget" then local_ImageWidget = value; break end
            n = n + 1
        end

        if local_ImageWidget then
            local StretchingImageWidget = local_ImageWidget:extend({})
            StretchingImageWidget.init = function(self)
                if local_ImageWidget.init then local_ImageWidget.init(self) end
                if M.getCoverMode() ~= "2_3"   then return end
                if not max_img_w or not max_img_h then return end
                local ratio = 2 / 3
                self.scale_factor = nil
                self.stretch_limit_percentage = 50
                if max_img_w / max_img_h > ratio then
                    self.height = max_img_h
                    self.width  = math.floor(max_img_h * ratio)
                else
                    self.width  = max_img_w
                    self.height = math.floor(max_img_w / ratio)
                end
            end
            debug.setupvalue(MosaicMenuItem.update, n, StretchingImageWidget)
            MosaicMenuItem._simpleui_fc_iw_n         = n
            MosaicMenuItem._simpleui_fc_orig_iw      = local_ImageWidget
            MosaicMenuItem._simpleui_fc_stretched_iw = StretchingImageWidget
        end
    end

    local orig_init    = MosaicMenuItem.init
    local orig_paintTo = MosaicMenuItem.paintTo
    MosaicMenuItem._simpleui_fc_orig_init    = orig_init
    MosaicMenuItem._simpleui_fc_orig_paintTo = orig_paintTo

    -- ── Title/Author strip height (fixed for this session; requires restart) ──
    local _show_title_strip  = M.getShowTitleStrip()
    local _show_author_strip = M.getShowAuthorStrip()
    local _STRIP_H = 0

    if _show_title_strip or _show_author_strip then
        local Screen_     = require("device").screen
        local Font_       = require("ui/font")
        local TextWidget_ = require("ui/widget/textwidget")
        local _PAD = Screen_:scaleBySize(3)
        local _GAP = Screen_:scaleBySize(2)
        local function _mh(fs, bold)
            local tw = TextWidget_:new{ text="Ag", face=Font_:getFace(SUIStyle.FACE_REGULAR,fs),
                bold=bold, padding=0 }
            local h = tw:getSize().h; tw:free(); return h
        end
        local TITLE_LINE  = _mh(SUIStyle.FS_DETAIL, true)
        local AUTHOR_LINE = _mh(SUIStyle.FS_CAPTION, false)
        _STRIP_H = _PAD
        if _show_title_strip  then _STRIP_H = _STRIP_H + TITLE_LINE end
        if _show_title_strip and _show_author_strip then _STRIP_H = _STRIP_H + _GAP end
        if _show_author_strip then _STRIP_H = _STRIP_H + AUTHOR_LINE end
        _STRIP_H = _STRIP_H + _PAD
    end
    _module_strip_h                    = _STRIP_H
    MosaicMenuItem._simpleui_strip_h   = _STRIP_H

    -- Guard flag: prevents the update() wrapper from double-shrinking self.height
    -- when init() calls orig_init (which calls update internally).
    local _in_strip_init = false

    function MosaicMenuItem:init()
        -- Shrink cell height so orig_init lays out the cover within the reduced
        -- space, leaving the strip area free below.
        if _STRIP_H > 0 and self.height then
            self.height = self.height - _STRIP_H
        end
        if self.width and self.height then
            local border_size = Size.border.thin
            max_img_w = self.width  - 2 * border_size
            max_img_h = self.height - 2 * border_size
        end
        _in_strip_init = true
        if orig_init then orig_init(self) end
        _in_strip_init = false
        -- Restore so the cell occupies its full grid slot.
        if _STRIP_H > 0 and self.height then
            self.height = self.height + _STRIP_H
        end
    end

    MosaicMenuItem._simpleui_fc_patched     = true
    MosaicMenuItem._simpleui_fc_orig_update = MosaicMenuItem.update

    local original_update = MosaicMenuItem.update

    function MosaicMenuItem:update(...)
        -- Invalidate the strip cache on every cover reload.
        self._simpleui_strip_data = nil
        if self._simpleui_strip_bb then
            self._simpleui_strip_bb:free(); self._simpleui_strip_bb = nil
        end
        -- Shrink height before calling original_update so cover calculations
        -- stay within the reduced space. Skipped when called from within init()
        -- because init already shrank self.height.
        if not _in_strip_init and _STRIP_H > 0 and self.height then
            self.height = self.height - _STRIP_H
        end
        original_update(self, ...)
        if not _in_strip_init and _STRIP_H > 0 and self.height then
            self.height = self.height + _STRIP_H
            -- KOReader evaluated show_progress_bar with the reduced height and
            -- may have set it to false incorrectly. Re-apply the exact condition
            -- from mosaicmenu.lua; only force true, never false.
            if not self.show_progress_bar and self.percent_finished
                    and self.status ~= "complete"
                    and BookInfoManager:getSetting("show_progress_in_mosaic") then
                self.show_progress_bar = true
            end
        end

        -- Read collection_mark and corner_mark_size upvalues from orig_paintTo
        -- lazily on first update. Indices are stable for the session.
        if not _upvalues_searched then
            _upvalues_searched = true
            local ni = 1
            while true do
                local nm, _ = debug.getupvalue(orig_paintTo, ni)
                if not nm then break end
                if nm == "corner_mark_size" then _corner_mark_idx = ni end
                if nm == "collection_mark"  then _collection_mark_idx = ni end
                if _corner_mark_idx and _collection_mark_idx then break end
                ni = ni + 1
            end
        end
        if _corner_mark_idx then
            local _, vl = debug.getupvalue(orig_paintTo, _corner_mark_idx)
            _fc_coll_sz = vl
        end
        if _collection_mark_idx then
            local _, vl = debug.getupvalue(orig_paintTo, _collection_mark_idx)
            _fc_coll_widget = vl
        end

        -- Pre-compute badge data for books so paintTo() makes zero settings reads.
        if not self.is_directory and not self.file_deleted and self.filepath then
            -- Fallback: BIM's SQLite cache can have NULL for percent_finished even when
            -- the sidecar (.lua) has the real value — this happens when the book was
            -- scanned into the library before it was read, or when the BIM DB is stale.
            -- been_opened in BIM can also be NULL for books read before BIM started
            -- tracking that field. So we use DS.open() + source_candidate as the
            -- authoritative check: source_candidate is non-nil iff a sidecar exists.
            -- DS.open() on a book with no sidecar is a cheap stat-miss; it does NOT
            -- create or write any file (only ds:flush() / dirty close would do that).
            if self.percent_finished == nil and self.filepath then
                pcall(function()
                    local DS = require("docsettings")
                    local ok_ds, ds = pcall(DS.open, DS, self.filepath)
                    if ok_ds and ds then
                        if ds.source_candidate then
                            -- Sidecar confirmed to exist: book has been opened.
                            -- Sync been_opened so has_progress and "New" badge are correct.
                            self.been_opened = true
                            local pf = ds:readSetting("percent_finished")
                            if pf ~= nil then
                                self.percent_finished = pf
                            end
                            if self.status == nil then
                                local summary = ds:readSetting("summary")
                                if type(summary) == "table" and summary.status then
                                    self.status = summary.status
                                end
                            end
                        end
                        pcall(function() ds:close() end)
                    end
                end)
            end

            self._fc_pages        = nil
            self._fc_series_index = nil
            local bi = self.menu and self.menu.getBookInfo
                       and self.menu.getBookInfo(self.filepath)
            if bi then
                if bi.pages then self._fc_pages = bi.pages end
                if bi.series and bi.series_index then
                    self._fc_series_index = bi.series_index
                end
            end

            self._fc_underline_color  = M.getHideUnderline()
                and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
            self._fc_overlay_pages    = M.getOverlayPages()
            self._fc_overlay_series   = M.getOverlaySeries()
            self._fc_overlay_progress = M.getProgressMode() == "banner"
            -- _fc_overlay_new is set per-book below by the new-mode block.

            if self._fc_progress_bb and self._fc_progress_bb.text_widget then
                self._fc_progress_bb.text_widget:free()
            end
            if self._fc_pages_widget  then self._fc_pages_widget:free()  end
            if self._fc_series_widget then self._fc_series_widget:free() end
            if self._fc_new_widget    then self._fc_new_widget:free()    end

            self._fc_progress_bb   = nil
            self._fc_pages_widget  = nil
            self._fc_series_widget = nil
            self._fc_new_widget    = nil

            local badge_scale = M.getBadgeScale()

            if self._fc_overlay_pages and self.status ~= "complete" and self._fc_pages then
                local cell_min = math.min(self.width or 40, self.height or 40)
                local dark = M.getBadgeColorPages() == "dark"
                self._fc_pages_widget = _buildRectBadgeWidget(
                    self._fc_pages .. _(" p."), false, cell_min, dark, false, badge_scale)
            end

            if self._fc_overlay_series and self._fc_series_index then
                local cell_min = math.min(self.width or 40, self.height or 40)
                local dark = M.getBadgeColorSeries() == "dark"
                self._fc_series_widget = _buildRectBadgeWidget(
                    "#" .. self._fc_series_index, false, cell_min, dark, false, badge_scale)
            end

            -- Progress pentagon: only for books that have been opened.
            if self._fc_overlay_progress then
                -- ZenUI criteria: show progress badge whenever percent_finished is
                -- non-nil (even 0%), or status is complete/abandoned.
                -- This correctly handles books opened but not yet advanced past page 1.
                local has_progress = (self.percent_finished ~= nil)
                    or (self.status == "complete") or (self.status == "abandoned")
                if has_progress then
                local eff_size = math.max(8, math.floor(
                    math.min(self.width or 40, self.height or 40) * 0.14 * badge_scale))
                    local dark = M.getBadgeColorProgress() == "dark"
                    local prog_desc = _buildProgressBadgeDesc(
                        eff_size, self.status, self.percent_finished,
                        SUIStyle.BADGE_BORDER_SZ, dark)
                    if prog_desc then self._fc_progress_bb = prog_desc end
                end
            end

            -- "New" badge: unread books (percent_finished nil).
            -- The mode is read once per update and stored on the item so paintTo
            -- doesn't need to call M.getNewMode() on every frame.
            local _new_mode = M.getNewMode()
            self._fc_new_mode = _new_mode
            if _new_mode ~= "none" then
                local is_unread = (self.percent_finished == nil)
                    and (self.status ~= "complete") and (self.status ~= "abandoned")
                if is_unread then
                    if _new_mode == "badge" then
                        local cell_min = math.min(self.width or 40, self.height or 40)
                        local dark = M.getBadgeColorNew() == "dark"
                        self._fc_new_widget =
                            _buildRectBadgeWidget(_("New"), true, cell_min, dark, true, badge_scale)
                    end
                    -- ribbon mode: no widget pre-built; painted directly in paintTo.
                    self._fc_overlay_new = true
                else
                    self._fc_overlay_new = false
                end
            else
                self._fc_overlay_new = false
            end
        end

        -- ── Folder cover rendering ──────────────────────────────────────────

        if self._foldercover_processed    then return end
        if self.menu.no_refresh_covers    then return end
        if not self.do_cover_image        then return end
        if not M.isEnabled()              then return end
        if self.entry.is_file or self.entry.file or not self.mandatory then return end

        -- Defer the first folder-cover pass when the homescreen is visible
        -- so the HS paints first and the user sees no blank frames.
        local HS = package.loaded["sui_homescreen"]
        if HS and HS._instance and not self.menu._fc_hs_deferred then
            self.menu._fc_hs_deferred = true
            local menu_ref = self.menu
            local UIManager = require("ui/uimanager")
            UIManager:nextTick(function()
                menu_ref._fc_hs_deferred = false
                local HS2 = package.loaded["sui_homescreen"]
                if HS2 and HS2._instance then return end
                local fm = package.loaded["apps/filemanager/filemanager"]
                if not fm or not fm.instance or fm.instance.tearing_down then return end
                menu_ref:updateItems()
            end)
            return
        end

        local dir_path = self.entry and self.entry.path
        if not dir_path then return end

        -- Read display settings once; helpers receive them as a single table.
        local display = {
            label_mode  = M.getLabelMode(),
            show_name   = M.getShowName(),
            label_style = M.getLabelStyle(),
            label_pos   = M.getLabelPosition(),
            label_color = M.getLabelColor(),
        }
        -- When the strip is active it already shows the folder name below
        -- the cover — suppress the overlay label to avoid redundancy.
        if _STRIP_H > 0 then display.label_mode = "hidden" end

        local folder_style = _resolveStyle(self.menu, dir_path, self.entry)

        -- ── Series group cover ────────────────────────────────────────────────
        if self.entry.is_series_group then
            if self._foldercover_processed then return end

            -- User-chosen override (single mode only; ignored in quad).
            local sg_override_fp = folder_style ~= "quad" and _getCoverOverrides()[dir_path]
            if sg_override_fp then
                local bi = BookInfoManager:getBookInfo(sg_override_fp, true)
                if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
                        and not bi.ignore_cover
                        and not BookInfoManager.isCachedCoverInvalid(bi, self.menu.cover_specs)
                then
                    self:_setFolderCover(
                        { data = bi.cover_bb, w = bi.cover_w, h = bi.cover_h }, display)
                    return
                end
            end

            local items = self.entry.series_items or _sg_items_cache[dir_path]

            -- Quad: 2×2 grid from series book covers.
            if folder_style == "quad" and items then
                local covers = {}
                for _, book_entry in ipairs(items) do
                    if book_entry.path then
                        local bi = BookInfoManager:getBookInfo(book_entry.path, true)
                        if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
                                and not bi.ignore_cover
                                and not BookInfoManager.isCachedCoverInvalid(bi, self.menu.cover_specs)
                        then
                            covers[#covers + 1] = { data = bi.cover_bb, w = bi.cover_w, h = bi.cover_h }
                            if #covers >= 4 then break end
                        end
                    end
                end
                if #covers > 0 then
                    local border, spine_w, max_img_w, max_img_h = _computeCellGeometry(self)
                    local widget = _buildQuadCover(self, covers, border, spine_w, max_img_w, max_img_h, display)
                    if widget then
                        _installWidget(self, widget)
                        return
                    end
                end
                -- No covers ready — register for async retry.
                if self.menu and self.menu.items_to_update then
                    if not self.menu._fc_pending_set then self.menu._fc_pending_set = {} end
                    if not self.menu._fc_pending_set[self] then
                        self.menu._fc_pending_set[self] = true
                        table.insert(self.menu.items_to_update, self)
                    end
                end
                return
            end

            -- Single: first available cover from the series.
            if items then
                for _, book_entry in ipairs(items) do
                    if book_entry.path then
                        local bi = BookInfoManager:getBookInfo(book_entry.path, true)
                        if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
                                and not bi.ignore_cover
                                and not BookInfoManager.isCachedCoverInvalid(bi, self.menu.cover_specs)
                        then
                            self:_setFolderCover(
                                { data = bi.cover_bb, w = bi.cover_w, h = bi.cover_h }, display)
                            return
                        end
                    end
                end
            end
            return
        end

        -- ── Quad (2×2 grid) mode ──────────────────────────────────────────────
        if folder_style == "quad" then
            -- Static .cover.* file takes precedence even in quad mode.
            local cover_file = findCover(dir_path)
            if cover_file then
                local ok, w, h = pcall(function()
                    local tmp = ImageWidget:new{ file = cover_file, scale_factor = 1 }
                    tmp:_render()
                    local ow = tmp:getOriginalWidth()
                    local oh = tmp:getOriginalHeight()
                    tmp:free()
                    return ow, oh
                end)
                if ok and w and h then
                    self:_setFolderCover({ file = cover_file, w = w, h = h }, display)
                    return
                end
            end

            local covers = _collectCovers(self.menu, dir_path, 4, BookInfoManager)
            if #covers > 0 then
                local border, spine_w, max_img_w, max_img_h = _computeCellGeometry(self)
                local widget = _buildQuadCover(self, covers, border, spine_w, max_img_w, max_img_h, display)
                if widget then
                    _installWidget(self, widget)
                    return
                end
            end
            -- No covers yet — register for async retry.
            if self.menu and self.menu.items_to_update then
                if not self.menu._fc_pending_set then self.menu._fc_pending_set = {} end
                if not self.menu._fc_pending_set[self] then
                    self.menu._fc_pending_set[self] = true
                    table.insert(self.menu.items_to_update, self)
                end
            end
            return
        end

        -- ── Single-cover mode (default) ───────────────────────────────────────

        -- 1. User-chosen override.
        local override_fp = _getCoverOverrides()[dir_path]
        if override_fp then
            local bi = BookInfoManager:getBookInfo(override_fp, true)
            if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
                    and not bi.ignore_cover
                    and not BookInfoManager.isCachedCoverInvalid(bi, self.menu.cover_specs)
            then
                self:_setFolderCover(
                    { data = bi.cover_bb, w = bi.cover_w, h = bi.cover_h }, display)
                return
            end
        end

        -- 2. Static .cover.* image file.
        local cover_file = findCover(dir_path)
        if cover_file then
            local ok, w, h = pcall(function()
                local tmp = ImageWidget:new{ file = cover_file, scale_factor = 1 }
                tmp:_render()
                local ow = tmp:getOriginalWidth()
                local oh = tmp:getOriginalHeight()
                tmp:free()
                return ow, oh
            end)
            if ok and w and h then
                self:_setFolderCover({ file = cover_file, w = w, h = h }, display)
                return
            end
        end

        -- 3. First cached book cover inside the folder.
        local has_files      = false
        local has_subfolders = false

        local entries = _entriesWithNoFilter(self.menu, dir_path)
        if entries then
            for _, entry in ipairs(entries) do
                if entry.is_file or entry.file then
                    has_files = true
                    local bi = BookInfoManager:getBookInfo(entry.path, true)
                    if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
                            and not bi.ignore_cover
                            and not BookInfoManager.isCachedCoverInvalid(bi, self.menu.cover_specs)
                    then
                        self:_setFolderCover(
                            { data = bi.cover_bb, w = bi.cover_w, h = bi.cover_h }, display)
                        return
                    end
                else
                    has_subfolders = true
                end
            end
        end

        -- 4. Bookless folder: recursive scan or placeholder.
        if not has_files then
            if has_subfolders and M.getSubfolderCover() and M.getRecursiveCover() then
                local cover = _findCoverRecursive(self.menu, dir_path, 1, 3, BookInfoManager)
                if cover then
                    self:_setFolderCover(cover, display)
                    return
                end
            end
            if M.getSubfolderCover() then self:_setEmptyFolderCover(display) end
            return
        end

        -- 5. No cover found yet — register for async retry.
        if self.menu and self.menu.items_to_update then
            if not self.menu._fc_pending_set then self.menu._fc_pending_set = {} end
            if not self.menu._fc_pending_set[self] then
                self.menu._fc_pending_set[self] = true
                table.insert(self.menu.items_to_update, self)
            end
        end
    end -- MosaicMenuItem:update

    -- Builds and installs a single-image cover widget.
    -- `img` = { file=path } or { data=blitbuffer, w=n, h=n }
    function MosaicMenuItem:_setFolderCover(img, display)
        -- `display` may be nil when called by third-party patches that pre-date
        -- this parameter (e.g. patches/2-automatic-book-series.lua).  Fall back
        -- to reading the settings directly so the rest of the pipeline never
        -- receives a nil table.
        if not display then
            display = {
                label_mode  = M.getLabelMode(),
                show_name   = M.getShowName(),
                label_style = M.getLabelStyle(),
                label_pos   = M.getLabelPosition(),
                label_color = M.getLabelColor(),
            }
            if _STRIP_H > 0 then display.label_mode = "hidden" end
        end
        self._foldercover_processed = true
        local border, spine_w, max_img_w, max_img_h = _computeCellGeometry(self)

        local img_options = {}
        if img.file then img_options.file  = img.file end
        if img.data then img_options.image = img.data end

        local ratio = 2 / 3
        if max_img_w / max_img_h > ratio then
            img_options.height = max_img_h
            img_options.width  = math.floor(max_img_h * ratio)
        else
            img_options.width  = max_img_w
            img_options.height = math.floor(max_img_w / ratio)
        end
        img_options.stretch_limit_percentage = 50

        local image   = ImageWidget:new(img_options)
        local size    = image:getSize()
        local content = FrameContainer:new{ padding = 0, bordersize = border, image }
        _installWidget(self, _assembleCoverWidget(self, content, size, border, spine_w, display))
    end

    -- Placeholder cover for bookless folders (subfolders only or empty).
    function MosaicMenuItem:_setEmptyFolderCover(display)
        if not display then
            display = {
                label_mode  = M.getLabelMode(),
                show_name   = M.getShowName(),
                label_style = M.getLabelStyle(),
                label_pos   = M.getLabelPosition(),
                label_color = M.getLabelColor(),
            }
            if _STRIP_H > 0 then display.label_mode = "hidden" end
        end
        self._foldercover_processed = true
        local border, spine_w, max_img_w, max_img_h = _computeCellGeometry(self)

        local ratio = 2 / 3
        local img_w, img_h
        if max_img_w / max_img_h > ratio then
            img_h = max_img_h; img_w = math.floor(max_img_h * ratio)
        else
            img_w = max_img_w; img_h = math.floor(max_img_w / ratio)
        end

        local icon_size   = math.floor(math.min(img_w, img_h) * 0.5)
        local icon_widget = nil

        local actual_icon_path = _ICON_PATH
        pcall(function()
            local SUIStyle = require("sui_style")
            local custom = SUIStyle.getIcon("sui_fc_empty")
            if custom then actual_icon_path = custom end
        end)

        local Config    = require("sui_config")
        local nerd_char = Config.nerdIconChar(actual_icon_path)

        if nerd_char then
            local ok_tw, tw = pcall(function()
                return CenterContainer:new{
                    dimen = Geom:new{ w = img_w, h = img_h },
                    TextWidget:new{
                        text    = nerd_char,
                        face    = Font:getFace(SUIStyle.FACE_ICONS, math.floor(icon_size * 0.85)),
                        fgcolor = Blitbuffer.COLOR_BLACK,
                        padding = 0,
                    },
                }
            end)
            if ok_tw then icon_widget = tw end
        else
            local actual_icon_exists = lfs.attributes(actual_icon_path, "mode") == "file"
            if actual_icon_exists then
                local ok_iw, iw = pcall(function()
                    return CenterContainer:new{
                        dimen = Geom:new{ w = img_w, h = img_h },
                        ImageWidget:new{
                            file    = actual_icon_path,
                            width   = icon_size,
                            height  = icon_size,
                            alpha   = true,
                            is_icon = true,
                        },
                    }
                end)
                if ok_iw then icon_widget = iw end
            end
        end

        local bg_canvas = FrameContainer:new{
            padding    = 0,
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
            dimen      = Geom:new{ w = img_w, h = img_h },
            icon_widget,
        }

        local size    = Geom:new{ w = img_w, h = img_h }
        local content = FrameContainer:new{ padding = 0, bordersize = border, bg_canvas }
        _installWidget(self, _assembleCoverWidget(self, content, size, border, spine_w, display))
    end

    -- Binary-search the largest font size where the folder name fits in two
    -- lines within available_w. Result cached by text+width+max_fs.
    -- Capitalises the first letter of each word.
    function MosaicMenuItem:_getFolderNameWidget(available_w, dir_max_font_size, fgcolor, bgcolor)
        if not self._fc_display_text then
            local text = self.text
            if text:match("/$") then text = text:sub(1, -2) end
            text = text:gsub("(%S+)", function(w) return w:sub(1,1):upper() .. w:sub(2) end)
            self._fc_display_text = BD.directory(text)
        end
        local text      = self._fc_display_text
        local max_fs    = dir_max_font_size or _BASE_DIR_FS
        local cache_key = text .. "\0" .. available_w .. "\0" .. max_fs
        local fg        = fgcolor or Blitbuffer.COLOR_BLACK
        local bg        = bgcolor or Blitbuffer.COLOR_WHITE

        local cached_fs = _fsCacheGet(cache_key)
        if cached_fs then
            return TextBoxWidget:new{
                text      = text,
                face      = Font:getFace(SUIStyle.FACE_REGULAR, cached_fs),
                width     = available_w,
                alignment = "center",
                bold      = true,
                fgcolor   = fg,
                bgcolor   = bg,
            }
        end

        -- Pass 1: binary-search largest font where the longest word fits.
        local longest_word = ""
        for word in text:gmatch("%S+") do
            if #word > #longest_word then longest_word = word end
        end

        local dir_font_size = max_fs

        if longest_word ~= "" then
        local lo, hi = 10, dir_font_size
            while lo < hi do
                local mid = math.floor((lo + hi + 1) / 2)
                local tw = TextWidget:new{
                    text = longest_word,
                    face = Font:getFace(SUIStyle.FACE_REGULAR, mid),
                    bold = true,
                }
                local word_w = tw:getWidth()
                tw:free()
                if word_w <= available_w then lo = mid else hi = mid - 1 end
            end
            dir_font_size = lo
        end

        -- Pass 2: binary-search largest font where the full text fits in two lines.
        -- Pass 1 narrows the range, minimising TextBoxWidget allocations.
    local lo, hi = 10, dir_font_size
        while lo < hi do
            local mid  = math.floor((lo + hi + 1) / 2)
            local fits = false
            local ok, tbw = pcall(function()
                return TextBoxWidget:new{
                    text      = text,
                    face      = Font:getFace(SUIStyle.FACE_REGULAR, mid),
                    width     = available_w,
                    alignment = "center",
                    bold      = true,
                }
            end)
            if ok and tbw then
                fits = tbw:getSize().h <= tbw:getLineHeight() * 2.2
                tbw:free(true)
            end
            if fits then lo = mid else hi = mid - 1 end
        end
        dir_font_size = lo

        _fsCacheSet(cache_key, dir_font_size)

        return TextBoxWidget:new{
            text      = text,
            face      = Font:getFace(SUIStyle.FACE_REGULAR, dir_font_size),
            width     = available_w,
            alignment = "center",
            bold      = true,
            fgcolor   = fg,
            bgcolor   = bg,
        }
    end

    -- onFocus: apply the pre-computed underline color (no settings read in the hot path).
    MosaicMenuItem._simpleui_fc_orig_onFocus = MosaicMenuItem.onFocus
    function MosaicMenuItem:onFocus()
        self._underline_container.color = self._fc_underline_color
            or (M.getHideUnderline() and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK)
        return true
    end

    -- paintTo: draw book-cover overlays (badges).
    -- Folder covers are rendered via widget replacement in _setFolderCover;
    -- this function only acts on regular book items.
    local function _round(v) return math.floor(v + 0.5) end

    function MosaicMenuItem:paintTo(bb, x, y)
        x = math.floor(x)
        y = math.floor(y)

        -- In "banner" and "none" modes, suppress native KOReader marks that
        -- would overlap or duplicate plugin-drawn badges:
        --   do_hint_opened  → dog-ear corner mark
        --   shortcut_icon   → collection star (banner only; redrawn at bottom-right below)
        -- Fields are temporarily nil'd before orig_paintTo and restored after.
        local _saved_hint, _saved_icon, _saved_menu_name, _saved_been_opened
        local _progress_mode = M.getProgressMode()
        if (_progress_mode == "banner" or _progress_mode == "none") and not self.is_directory then
            _saved_hint = self.do_hint_opened; self.do_hint_opened = false

            if _progress_mode == "banner" then
                _saved_icon = self.shortcut_icon; self.shortcut_icon = nil
                -- Spoof menu.name so orig_paintTo skips drawing the native
                -- collection mark at top-right (redrawn at bottom-right below).
                if self.menu then
                    _saved_menu_name = self.menu.name
                    self.menu.name   = "collections"
                end
                -- When the collection mark will be redrawn (banner mode, book in a
                -- collection), shrink the native progress bar's right edge by
                -- corner_mark_size — same behaviour as do_hint_opened.
                -- Set do_hint_opened=true for layout but been_opened=false to
                -- prevent the dog-ear from being drawn.
                if self.show_progress_bar
                        and self.filepath
                        and ReadCollection
                        and ReadCollection:isFileInCollections(self.filepath) then
                    _saved_been_opened  = self.been_opened
                    self.do_hint_opened = true
                    self.been_opened    = false
                end
            end
        end

        orig_paintTo(self, bb, x, y)

        if (_progress_mode == "banner" or _progress_mode == "none") and not self.is_directory then
            self.do_hint_opened = _saved_hint
            if _progress_mode == "banner" then
                self.shortcut_icon = _saved_icon
                if self.menu and _saved_menu_name ~= nil then
                    self.menu.name = _saved_menu_name
                end
                if _saved_been_opened ~= nil then
                    self.been_opened = _saved_been_opened
                end
            end
        end

        -- Redraw collection mark at bottom-right (banner mode only).
        -- orig_paintTo was prevented from drawing at top-right (menu.name spoofed).
        if _progress_mode == "banner" and not self.is_directory
                and self.filepath
                and self.menu and _saved_menu_name ~= nil and _saved_menu_name ~= "collections"
                and ReadCollection and ReadCollection:isFileInCollections(self.filepath) then
            local cm_size   = _fc_coll_sz
            local cm_widget = _fc_coll_widget
            if cm_size and cm_widget then
                local tgt = self[1] and self[1][1] and self[1][1][1]
                if tgt and tgt.dimen then
                    local ix
                    if BD.mirroredUILayout() then
                        ix = math.floor((self.width - tgt.dimen.w) / 2)
                    else
                        ix = self.width - math.ceil((self.width - tgt.dimen.w) / 2) - cm_size
                    end
                    local iy        = self.height - math.ceil((self.height - tgt.dimen.h) / 2) - cm_size
                    local rect_size = cm_size - tgt.bordersize
                    bb:paintRect(x + ix, tgt.dimen.y + iy + tgt.bordersize,
                                 rect_size, rect_size, Blitbuffer.COLOR_GRAY)
                    cm_widget:paintTo(bb, x + ix, y + iy)
                end
            end
        end

        if self.is_directory or self.file_deleted then return end

        -- Locate the cover FrameContainer in the widget tree.
        local target = self._cover_frame
            or (self[1] and self[1][1] and self[1][1][1])
        if not target or not target.dimen then return end

        local fw = target.dimen.w
        local fh = target.dimen.h
        -- Prefer absolute coords from orig_paintTo; fall back to manual centring.
        local fx, fy
        if target.dimen.x and target.dimen.x ~= 0 then
            fx = target.dimen.x
            fy = target.dimen.y
        else
            fx = x + _round((self.width  - fw) / 2)
            fy = y + _round((self.height - fh) / 2)
        end

        -- Left margin of the native progress bar (mirrors mosaicmenu.lua logic).
        local _native_bar_left_margin
        if _fc_coll_sz then
            _native_bar_left_margin = math.floor((_fc_coll_sz - _BADGE_BAR_H) / 2)
        else
            _native_bar_left_margin = _BADGE_RIGHT_INSET
        end

        -- Pages badge (bottom-left).
        if self._fc_overlay_pages and self.status ~= "complete" then
            local wg = self._fc_pages_widget
            if wg then
                local badge_x
                if BD.mirroredUILayout() then
                    badge_x = fx + fw - wg.dimen.w - _native_bar_left_margin
                else
                    badge_x = fx + _native_bar_left_margin
                end
                local badge_y
                if self.show_progress_bar then
                    local corner_sz = _fc_coll_sz or math.floor(math.min(self.width, self.height) / 8)
                    local bar_top   = fy + fh - corner_sz + _native_bar_left_margin
                    badge_y = bar_top - _BADGE_BAR_GAP - wg.dimen.h
                else
                    badge_y = fy + fh - wg.dimen.h - _native_bar_left_margin
                end
                wg:paintTo(bb, badge_x, badge_y)
            end
        end

        -- Series index badge (top-left).
        if self._fc_overlay_series then
            local wg = self._fc_series_widget
            if not wg and self.filepath then
                local bi = BookInfoManager:getBookInfo(self.filepath, false)
                if bi and bi.series and bi.series_index then
                    local cell_min = math.min(self.width or fw, self.height or fh)
                    local dark = M.getBadgeColorSeries() == "dark"
                    local new_wg = _buildRectBadgeWidget(
                        "#" .. bi.series_index, false, cell_min, dark, false)
                    if new_wg then self._fc_series_widget = new_wg; wg = new_wg end
                end
            end
            if wg then
                local badge_x
                if BD.mirroredUILayout() then
                    badge_x = fx + fw - wg.dimen.w - _native_bar_left_margin
                else
                    badge_x = fx + _native_bar_left_margin
                end
                wg:paintTo(bb, badge_x, fy + _BADGE_RIGHT_INSET)
            end
        end

        -- Progress pentagon badge (top-right).
        -- Drawn directly onto bb so pixels outside the pentagon are never written.
        -- Offset upward by `border` so the badge top edge sits on the cover border.
        if self._fc_overlay_progress then
            local prog_desc = self._fc_progress_bb
            if prog_desc then
                local fr     = prog_desc.border
                local rect_w = prog_desc.bw + 2 * fr
                local badge_x
                if BD.mirroredUILayout() then
                    badge_x = fx + _BADGE_RIGHT_INSET
                else
                    badge_x = fx + fw - rect_w - _BADGE_RIGHT_INSET
                end
                _drawProgressBadge(bb, badge_x, fy - fr, prog_desc)
            end
        end

        -- "New" badge / ribbon (top-right).
        -- Not shown when the progress pentagon is active for this item.
        if self._fc_overlay_new then
            local has_progress_badge = self._fc_overlay_progress and self._fc_progress_bb
            if not has_progress_badge then
                local mode = self._fc_new_mode or "badge"
                local dark = M.getBadgeColorNew() == "dark"

                if mode == "badge" then
                    -- Rounded-rectangle widget, pre-built in update().
                    local wg = self._fc_new_widget
                    if wg then
                        local badge_x
                        if BD.mirroredUILayout() then
                            badge_x = fx + _BADGE_RIGHT_INSET
                        else
                            badge_x = fx + fw - wg.dimen.w - _BADGE_RIGHT_INSET
                        end
                        wg:paintTo(bb, badge_x, fy + _BADGE_RIGHT_INSET)
                    end

                elseif mode == "ribbon" then
                    -- Diagonal corner ribbon, painted directly onto bb.
                    local badge_scale = M.getBadgeScale()
                    local cell_min   = math.min(fw, fh)
                    local eff_size   = math.max(8, math.floor(cell_min * 0.1694 * badge_scale))
                    local span       = math.floor(eff_size * 2.5)
                    local band_thick = math.floor(span * 0.40)
                    local font_sz    = math.max(7, math.floor(eff_size * 0.26))
                    local cover_left, cover_right
                    if BD.mirroredUILayout() then
                        cover_left  = fx
                        cover_right = fx + fw
                    else
                        cover_left  = fx
                        cover_right = fx + fw
                    end
                    _paintCornerRibbon(bb,
                        cover_left, cover_right, fy, fh,
                        span, band_thick, _("New"), font_sz, dark)
                    -- Repaint cover border over ribbon so it isn't obscured.
                local brd = SUIStyle.BADGE_BORDER_SZ
                    if brd > 0 then
                        local bclr = Blitbuffer.COLOR_BLACK
                        bb:paintRect(cover_left,  fy, fw,  brd,  bclr)  -- top edge
                        bb:paintRect(cover_right - brd, fy, brd, fh, bclr)  -- right edge
                    end
                end
            end
        end

        -- Fade overlay for finished books.
        -- Applied last so it dims everything already painted (cover + badges).
        if M.getFadeFinished() and self.status == "complete" and not self.is_directory then
            local tgt = self._cover_frame or (self[1] and self[1][1] and self[1][1][1])
            if tgt and tgt.dimen then
                local tw2 = tgt.dimen.w
                local th2 = tgt.dimen.h
                local fx2, fy2
                if tgt.dimen.x and tgt.dimen.x ~= 0 then
                    fx2 = tgt.dimen.x
                    fy2 = tgt.dimen.y
                else
                    fx2 = x + _round((self.width  - tw2) / 2)
                    fy2 = y + _round((self.height - th2) / 2)
                end
                bb:lightenRect(fx2, fy2, tw2, th2, M.getFadeAmount())
            end
        end

    end -- MosaicMenuItem:paintTo

    local orig_free = MosaicMenuItem.free
    MosaicMenuItem._simpleui_fc_orig_free = orig_free
    function MosaicMenuItem:free()
        if self._fc_progress_bb and self._fc_progress_bb.text_widget then
            self._fc_progress_bb.text_widget:free()
            self._fc_progress_bb.text_widget = nil
        end
        self._fc_progress_bb = nil
        if self._fc_pages_widget  then self._fc_pages_widget:free();  self._fc_pages_widget  = nil end
        if self._fc_series_widget then self._fc_series_widget:free(); self._fc_series_widget = nil end
        if self._fc_new_widget    then self._fc_new_widget:free();    self._fc_new_widget    = nil end
        self._fc_overlay_new = nil
        if self._simpleui_strip_bb      then self._simpleui_strip_bb:free();      self._simpleui_strip_bb      = nil end
        if self._simpleui_strip_mask_bb then self._simpleui_strip_mask_bb:free(); self._simpleui_strip_mask_bb = nil end
        self._simpleui_strip_data = nil
        if orig_free then orig_free(self) end
    end

    _installItemCache()
    _installSeriesGrouping()
    _installFileDialogButton(BookInfoManager)

    -- Strip paintTo patch — must be outermost so it wraps the badge paintTo.
    if _STRIP_H > 0 then
        _installStripPatch(MosaicMenuItem, BookInfoManager, _STRIP_H,
                           _show_title_strip, _show_author_strip)
    end

    -- ── ListMenuItem patch — folder covers in list_image_meta view ────────────
    local ListMenuItem = _getListMenuItem()
    if ListMenuItem and not ListMenuItem._simpleui_lm_patched then
        ListMenuItem._simpleui_lm_patched     = true
        ListMenuItem._simpleui_lm_orig_update = ListMenuItem.update

        local orig_lm_update = ListMenuItem.update
        function ListMenuItem:update(...)
            orig_lm_update(self, ...)

            if not self.do_cover_image                   then return end
            if not M.isEnabled()                         then return end
            if self.menu and self.menu.no_refresh_covers then return end
            if self._foldercover_processed               then return end

            local entry = self.entry
            if not entry or entry.is_file or entry.file then return end

            local cover_specs = self.menu and self.menu.cover_specs
            local dir_path    = entry.path
            if not dir_path then return end

            -- Virtual meta-leaf (browsemeta).
            if entry.is_virtual_meta_leaf then
                local repr_fp     = entry.representative_filepath
                local override_fp = _getCoverOverrides()[dir_path]
                if override_fp then repr_fp = override_fp end
                if not repr_fp then return end
                local bi = BookInfoManager:getBookInfo(repr_fp, true)
                if not bi then return end
                if not (bi.has_cover and bi.cover_fetched
                        and not bi.ignore_cover and bi.cover_bb) then return end
                if cover_specs and BookInfoManager.isCachedCoverInvalid(bi, cover_specs) then return end
                self:_setListFolderCover(bi)
                return
            end

            -- Series group.
            if entry.is_series_group then
                local sg_override_fp = _getCoverOverrides()[dir_path]
                if sg_override_fp then
                    local bi = BookInfoManager:getBookInfo(sg_override_fp, true)
                    if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
                            and not bi.ignore_cover
                            and not (cover_specs and
                                BookInfoManager.isCachedCoverInvalid(bi, cover_specs))
                    then
                        self:_setListFolderCover(bi)
                        return
                    end
                end
                local items = entry.series_items or _sg_items_cache[dir_path]
                if items then
                    for _, book_entry in ipairs(items) do
                        if book_entry.path then
                            local bi = BookInfoManager:getBookInfo(book_entry.path, true)
                            if bi and bi.has_cover and bi.cover_fetched
                                    and not bi.ignore_cover and bi.cover_bb
                                    and not (cover_specs and
                                        BookInfoManager.isCachedCoverInvalid(bi, cover_specs))
                            then
                                self:_setListFolderCover(bi)
                                return
                            end
                        end
                    end
                end
                return
            end

            -- Real folder.

            -- 1. User-chosen override.
            local override_fp = _getCoverOverrides()[dir_path]
            if override_fp then
                local bi = BookInfoManager:getBookInfo(override_fp, true)
                if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
                        and not bi.ignore_cover
                        and not (cover_specs and BookInfoManager.isCachedCoverInvalid(bi, cover_specs))
                then
                    self:_setListFolderCover(bi)
                    return
                end
            end

            -- 2. Static .cover.* image file.
            local cover_file = findCover(dir_path)
            if cover_file then
                local ok, img = pcall(function()
                    local iw = ImageWidget:new{ file = cover_file, scale_factor = 1 }
                    iw:_render()
                    local bb = iw._bb and iw._bb:copy()
                    local ow = iw:getOriginalWidth()
                    local oh = iw:getOriginalHeight()
                    iw:free()
                    return { cover_bb = bb, cover_w = ow, cover_h = oh,
                             has_cover = true, cover_fetched = true }
                end)
                if ok and img and img.cover_bb then
                    self:_setListFolderCover(img)
                    return
                end
            end

            -- 3. First cached book cover — cached per directory to avoid
            --    repeating the lfs.dir + lfs.attributes walk on every render.
            local cached_lm = _lmcGet(dir_path)
            if cached_lm == false then
                -- confirmed miss — fall through to async retry
            elseif cached_lm ~= nil then
                self:_setListFolderCover(cached_lm)
                return
            else
                local saved_filter = FileChooser.show_filter
                FileChooser.show_filter = {}
                local ok_dir, iter, dir_obj = pcall(lfs.dir, dir_path)
                if ok_dir and iter then
                    for f in iter, dir_obj do
                        if f ~= "." and f ~= ".." then
                            local fp   = dir_path .. "/" .. f
                            local attr = lfs.attributes(fp) or {}
                            if attr.mode == "file"
                                    and not f:match("^%._")
                                    and FileChooser:show_file(f, fp)
                            then
                                local bi = BookInfoManager:getBookInfo(fp, true)
                                if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
                                        and not bi.ignore_cover
                                        and not (cover_specs and
                                            BookInfoManager.isCachedCoverInvalid(bi, cover_specs))
                                then
                                    FileChooser.show_filter = saved_filter
                                    local entry_data = {
                                        cover_bb      = bi.cover_bb,
                                        cover_w       = bi.cover_w,
                                        cover_h       = bi.cover_h,
                                        has_cover     = true,
                                        cover_fetched = true,
                                    }
                                    _lmcSet(dir_path, entry_data)
                                    self:_setListFolderCover(entry_data)
                                    return
                                end
                            end
                        end
                    end
                end
                FileChooser.show_filter = saved_filter
                _lmcSet(dir_path, false)
            end

            -- 4. No cover — register for async retry.
            if self.menu and self.menu.items_to_update then
                if not self.menu._fc_pending_set then
                    self.menu._fc_pending_set = {}
                end
                if not self.menu._fc_pending_set[self] then
                    self.menu._fc_pending_set[self] = true
                    table.insert(self.menu.items_to_update, self)
                end
            end
        end -- ListMenuItem:update

        -- Renders a cover thumbnail on the left, folder name + item count on the right.
        function ListMenuItem:_setListFolderCover(bookinfo)
            self._foldercover_processed = true

            local underline_h = self.underline_h or 1
            local dimen = Geom:new{
                w = self.width,
                h = self.height - 2 * underline_h,
            }

        local border_size = SUIStyle.BADGE_BORDER_SZ
            local img_size    = dimen.h
            local max_img_w   = img_size - 2 * border_size

            local _, _, scale_factor = BookInfoManager.getCachedCoverSize(
                bookinfo.cover_w, bookinfo.cover_h, max_img_w, max_img_w)
            local wimage = ImageWidget:new{
                image        = bookinfo.cover_bb,
                scale_factor = scale_factor,
            }
            wimage:_render()
            local image_size = wimage:getSize()

            local wleft = CenterContainer:new{
                dimen = Geom:new{ w = img_size, h = dimen.h },
                FrameContainer:new{
                    width      = image_size.w + 2 * border_size,
                    height     = image_size.h + 2 * border_size,
                    margin     = 0,
                    padding    = 0,
                    bordersize = border_size,
                    wimage,
                },
            }

            local pad       = _LATERAL_PAD
            local main_w    = dimen.w - img_size - pad * 2
            local font_size = (self.menu and self.menu.font_size) or 20
            local info_size = math.max(10, font_size - 4)

            local wname = TextBoxWidget:new{
                text                          = BD.directory(self.text),
                face                          = Font:getFace(SUIStyle.FACE_REGULAR, font_size),
                width                         = main_w,
                alignment                     = "left",
                bold                          = true,
                height                        = dimen.h,
                height_adjust                 = true,
                height_overflow_show_ellipsis = true,
            }
            local wcount = TextWidget:new{
                text = self.mandatory or "",
                face = Font:getFace(SUIStyle.FACE_MONO, info_size),
            }

            local wmain = LeftContainer:new{
                dimen = Geom:new{ w = main_w, h = dimen.h },
                VerticalGroup:new{
                    wname,
                    VerticalSpan:new{ width = _EDGE_MARGIN * 2 },
                    wcount,
                },
            }

            local widget = OverlapGroup:new{
                dimen = dimen:copy(),
                wleft,
                LeftContainer:new{
                    dimen = dimen:copy(),
                    HorizontalGroup:new{
                        HorizontalSpan:new{ width = img_size + pad },
                        wmain,
                    },
                },
            }

            if self._underline_container[1] then self._underline_container[1]:free() end
            self._underline_container[1] = VerticalGroup:new{
                VerticalSpan:new{ width = underline_h },
                widget,
            }
        end -- ListMenuItem:_setListFolderCover
    end -- ListMenuItem patch
end -- M.install

-- ---------------------------------------------------------------------------
-- 11. Uninstall — restores all patched methods and releases module-level caches.
-- ---------------------------------------------------------------------------

function M.uninstall()
    local MosaicMenuItem = _getMosaicMenuItemAndPatch()
    if not MosaicMenuItem then return end
    if not MosaicMenuItem._simpleui_fc_patched then return end

    if MosaicMenuItem._simpleui_fc_orig_update    then
        MosaicMenuItem.update    = MosaicMenuItem._simpleui_fc_orig_update
        MosaicMenuItem._simpleui_fc_orig_update    = nil
    end
    if MosaicMenuItem._simpleui_fc_orig_paintTo   then
        MosaicMenuItem.paintTo   = MosaicMenuItem._simpleui_fc_orig_paintTo
        MosaicMenuItem._simpleui_fc_orig_paintTo   = nil
    end
    if MosaicMenuItem._simpleui_fc_orig_free      then
        MosaicMenuItem.free      = MosaicMenuItem._simpleui_fc_orig_free
        MosaicMenuItem._simpleui_fc_orig_free      = nil
    end
    if MosaicMenuItem._simpleui_fc_orig_onFocus   then
        MosaicMenuItem.onFocus   = MosaicMenuItem._simpleui_fc_orig_onFocus
        MosaicMenuItem._simpleui_fc_orig_onFocus   = nil
    end
    if MosaicMenuItem._simpleui_fc_orig_init ~= nil then
        MosaicMenuItem.init      = MosaicMenuItem._simpleui_fc_orig_init
        MosaicMenuItem._simpleui_fc_orig_init      = nil
    end
    if MosaicMenuItem._simpleui_fc_iw_n and MosaicMenuItem._simpleui_fc_orig_iw then
        debug.setupvalue(MosaicMenuItem.update, MosaicMenuItem._simpleui_fc_iw_n,
            MosaicMenuItem._simpleui_fc_orig_iw)
        MosaicMenuItem._simpleui_fc_iw_n         = nil
        MosaicMenuItem._simpleui_fc_orig_iw      = nil
        MosaicMenuItem._simpleui_fc_stretched_iw = nil
    end
    MosaicMenuItem._setFolderCover      = nil
    MosaicMenuItem._getFolderNameWidget = nil
    MosaicMenuItem._simpleui_fc_patched = nil
    MosaicMenuItem._simpleui_strip_h    = nil
    _module_strip_h = 0

    _uninstallItemCache()
    _uninstallSeriesGrouping()
    _uninstallFileDialogButton()

    for k in pairs(_cover_file_cache)    do _cover_file_cache[k]    = nil end
    for k in pairs(_cfc_b)              do _cfc_b[k]               = nil end
    _cfc_cnt = 0
    for k in pairs(_lm_dir_cover_cache) do _lm_dir_cover_cache[k]  = nil end
    for k in pairs(_lmc_b)              do _lmc_b[k]               = nil end
    _lmc_cnt = 0
    for k in pairs(_fs_cache_a)         do _fs_cache_a[k]          = nil end
    for k in pairs(_fs_cache_b)         do _fs_cache_b[k]          = nil end
    _fs_cache_a_cnt = 0
    _overrides_cache = nil

    local ListMenuItem = _getListMenuItem()
    if ListMenuItem and ListMenuItem._simpleui_lm_patched then
        if ListMenuItem._simpleui_lm_orig_update then
            ListMenuItem.update = ListMenuItem._simpleui_lm_orig_update
            ListMenuItem._simpleui_lm_orig_update = nil
        end
        ListMenuItem._setListFolderCover  = nil
        ListMenuItem._simpleui_lm_patched = nil
    end
end

return M