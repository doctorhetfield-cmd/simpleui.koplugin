-- sui_foldercovers.lua — Simple UI
-- Folder cover art and book cover overlays for the CoverBrowser mosaic/list views.

-- ---------------------------------------------------------------------------
-- 1. Requires
-- ---------------------------------------------------------------------------

local _           = require("infra/sui_i18n").translate
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")
local SUISettings = require("infra/sui_store")
local SUIStyle    = require("features/sui_style")
local Config      = require("infra/sui_config")

-- Cached at module level so require() hits the cache on every cell render.
local BD              = require("ui/bidi")
local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FileChooser     = require("ui/widget/filechooser")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local ImageWidget     = require("ui/widget/imagewidget")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local Screen          = require("device").screen
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")

local CoverFinder    = require("features/library/sui_cover_finder")
local CoverWidgets   = require("features/library/sui_cover_widgets")
local CoverOverrides = require("features/library/sui_cover_overrides")
local GroupActions   = require("features/library/sui_group_actions")

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
    hide_pile         = "simpleui_fc_hide_spine",
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

-- Filename "p(<n>)" token → page count fallback. Now lives in
-- module_books_shared.lua (SH.pageCountFromFilename) so
-- engines/sui_book_grid.lua's badges can share the exact same logic instead
-- of a second copy. Lazy require to avoid a hard dependency at file scope
-- (this file is loaded very early, before modules/ is guaranteed ready).
local function _pageCountFromFilename(filepath)
    local ok, SH = pcall(require, "modules/module_books_shared")
    if ok and SH and SH.pageCountFromFilename then
        return SH.pageCountFromFilename(filepath)
    end
    if type(filepath) ~= "string" then return nil end
    local base = filepath:match("([^/]+)$") or filepath
    local n = base:match("[Pp]%((%d+)%)")
    return n and tonumber(n) or nil
end

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

-- Hide the book pile behind folder covers.
function M.getHidePile()  return SUISettings:isTrue(SK.hide_pile)  end
function M.setHidePile(v) SUISettings:saveSetting(SK.hide_pile, v) end

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
function M.getBadgeScalePct() return Config.getScalePctByKey(SK.badge_scale) end
function M.getBadgeScale()    return M.getBadgeScalePct() / 100 * SUIStyle.BADGE_SIZE_ADJUST end
function M.setBadgeScale(pct) Config.setScaleByKey(pct, SK.badge_scale) end

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

local _EDGE_MARGIN = math.max(1, Screen:scaleBySize(1))

local _LATERAL_PAD        = Screen:scaleBySize(10)
local _BADGE_MARGIN_BASE  = Screen:scaleBySize(8)
local _BADGE_MARGIN_R_BASE = Screen:scaleBySize(4)

-- Same ratio KOReader's stock listmenu.lua uses to convert a "nominal"
-- (64px-reference) font size into an actual scaled size. Keeping this
-- identical means folder names in the list-with-covers view end up the
-- same size as book titles, matching stock behaviour.
local _LM_SCALE_BY_SIZE = Screen:scaleBySize(1000000) * (1/1000000)
local function _lmFontSize(dimen_h, nominal, max)
    local font_size = math.floor(nominal * dimen_h * (1/64) / _LM_SCALE_BY_SIZE)
    if max and font_size >= max then
        return max
    end
    return font_size
end

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
-- (Depth-independent — see infra/sui_paths.lua for why this can't be the
-- old inline "chop the last two path components" regex.)
local _PLUGIN_DIR  = require("infra/sui_paths").getPluginDir()
local _ICON_PATH   = _PLUGIN_DIR .. "icons/custom.svg"
local _ICON_EXISTS = lfs.attributes(_ICON_PATH, "mode") == "file"

-- ---------------------------------------------------------------------------
-- 5. Caches
-- ---------------------------------------------------------------------------

-- The label metrics cache, the .cover.* file cache and the folder listing
-- caches live in sui_cover_widgets.lua and sui_cover_finder.lua — pure
-- lookup caches with no settings/monkeypatch dependency, so they live with
-- the code that populates them.

-- Single-entry item-table cache for FileChooser:genItemTableFromPath.
-- Encodes path + mtime + collate settings in the key so stale entries are
-- evicted automatically when anything that affects the list changes.
-- Disabled for access-time collate (directory mtime never reflects reads).
local _itc = nil

local _orig_setBookInfoCacheProperty = nil
local _orig_genItemTableFromPath     = nil

local function _itc_invalidate() _itc = nil end

local function _itc_key(path, fc)
    local mtime = lfs.attributes(path, "modification") or 0
    return path .. "\0" .. mtime .. "\0"
        .. CoverFinder.listingSignature(fc) .. "\0"
        .. CoverFinder.statusFilterSignature(fc)
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
            CoverFinder.clearListings()
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
    -- Ribbon / pentagon scratch buffers live in sui_cover_widgets.lua.
    CoverWidgets.clearRibbonCache()
    CoverWidgets.clearPentagonMaskCache()
end

-- Public wrapper for the FileChooser item-table cache invalidation.
-- Used by sui_series_grouping.lua's refreshPath override (that cache
-- benefits any FM view, not just folder covers, so it stays here rather
-- than moving into the series-grouping module).
function M.invalidateItemTableCache()
    _itc_invalidate()
end

-- Flushes every disk-derived cover cache: the .cover.* file cache, folder
-- listings and cover misses (sui_cover_finder.lua) and the font-size cache
-- (sui_cover_widgets.lua). Called
-- after the library changes on disk (books added/removed) — see
-- sui_series_grouping.lua's refreshPath override.
function M.clearCoverFinderCache()
    CoverFinder.clearCache()
end

-- ---------------------------------------------------------------------------
-- 6. Cover discovery — moved to features/library/sui_cover_finder.lua
-- ---------------------------------------------------------------------------
-- findCover, _entriesWithNoFilter, _collectCovers(Recursive), _findCoverRecursive
-- are now CoverFinder.findDotCover / .entriesWithNoFilter / .collectCovers /
-- .findCoverRecursive. Call sites below updated accordingly.

-- ---------------------------------------------------------------------------
-- 7. Folder logic — overrides, style resolution, pickers, file-dialog button
-- ---------------------------------------------------------------------------

-- Cover overrides now live in features/library/sui_cover_overrides.lua —
-- shared with sui_series_grouping.lua and sui_library_browse.lua instead of
-- three separate copies. CoverOverrides.get/set/clear/invalidateGridItem
-- replace _getCoverOverrides/_saveCoverOverride/_clearCoverOverride/
-- _invalidateFolderItem below.

-- Queues a folder item whose cover is not extracted yet; the menu's periodic
-- update pass calls its update() again.
local function _registerRetry(item)
    local menu = item.menu
    if not (menu and menu.items_to_update) then return end
    menu._fc_pending_set = menu._fc_pending_set or {}
    if not menu._fc_pending_set[item] then
        menu._fc_pending_set[item] = true
        table.insert(menu.items_to_update, item)
    end
end

-- Lazy reference to sui_series_grouping.lua: that module requires THIS one
-- at its own top level (for isEnabled/getSeriesGrouping/resolveStyle/
-- invalidateItemTableCache), so this file must not require it back at the
-- top level too — that would be a load-order-dependent circular require.
-- A pcall(require, ...) inside the function that needs it is resolved once
-- both modules have finished loading (by the time install() actually runs).
local function _seriesGrouping()
    local ok, SG = pcall(require, "features/library/sui_series_grouping")
    if ok then return SG end
    return nil
end

-- Resolve the effective folder style for dir_path.
-- "auto" counts books and returns "quad" (≥4) or "single" (<4).
-- The optional `entry` is used to identify virtual folder types.
local _resolveStyle
_resolveStyle = function(menu, dir_path, entry)
    local style = M.getFolderStyle()
    if style ~= "auto" then return style end
    if not menu or not dir_path then return "single" end

    -- Series-group virtual folders have a synthetic path that can't be scanned
    -- via CoverFinder.getDirSummary, so count directly from the cache.
    local SG = _seriesGrouping()
    local is_sg = (entry and entry.is_series_group) or (SG and SG.hasGroup(dir_path))
    if is_sg then
        local items = (entry and entry.series_items) or (SG and SG.getGroupItems(dir_path))
        if items and #items >= 4 then return "quad" end
        return "single"
    end

    local summary    = CoverFinder.getDirSummary(menu, dir_path)
    local book_count = #summary.books
    if book_count >= 4 then return "quad" end
    if M.getRecursiveCover() then
        local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
        if ok_bim and BookInfoManager then
            for _, sub_path in ipairs(summary.dirs) do
                local sub = CoverFinder._collectCoversRecursive(
                    menu, sub_path, 1, 3, 4 - book_count, BookInfoManager)
                book_count = book_count + #sub
                if book_count >= 4 then return "quad" end
            end
        end
    end
    return "single"
end

-- Public wrapper used by other modules (sui_library_browse, sui_series_grouping).
function M.resolveStyle(fc, dir_path, entry) return _resolveStyle(fc, dir_path, entry) end

-- Collect up to _COLLECT_MAX books from dir_path for the cover picker dialog.
local _COLLECT_MAX = 50
local function _collectBooks(menu, dir_path, depth, max_depth, out)
    if #out >= _COLLECT_MAX then return end
    local entries = CoverFinder.entriesWithNoFilter(menu, dir_path)
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

-- _createCollectionFromSeriesGroup and _openSeriesGroupCoverPicker are gone —
-- superseded by SeriesGrouping.createCollection / .openCoverPicker, which
-- do the same thing via the shared sui_group_actions.lua dialog instead of
-- a second copy of it.

-- Cover picker for real filesystem folders.
local function _openFolderCoverPicker(dir_path, menu, BookInfoManager)
    local books     = {}
    local max_depth = M.getRecursiveCover() and 3 or 1
    _collectBooks(menu, dir_path, 1, max_depth, books)

    local items = {}
    for _, entry in ipairs(books) do
        local fp    = entry.path
        local bi    = BookInfoManager:getBookInfo(fp, false)
        local title = (bi and bi.title and bi.title ~= "")
            and bi.title
            or (fp:match("([^/]+)%.[^%.]+$") or fp)
        local rel       = fp:sub(#dir_path + 2)
        local subfolder = rel:match("^(.+)/[^/]+$")
        items[#items + 1] = {
            path  = fp,
            title = subfolder and (title .. "  [" .. subfolder .. "]") or title,
        }
    end

    GroupActions.openCoverPicker{
        title         = _("Folder cover"),
        override_key  = dir_path,
        items         = items,
        menu          = menu,
        empty_message = _("No books found in this folder."),
    }
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

            local SG = _seriesGrouping()
            local is_virtual_series = (item_entry and item_entry.is_series_group)
                                   or (SG and SG.hasGroup(file))
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
                        if SG then SG.openCoverPicker(file, fc, BookInfoManager) end
                    elseif is_virtual_meta then
                        local ok_lb, LibraryBrowse = pcall(require, "features/library/sui_library_browse")
                        if ok_lb and LibraryBrowse and LibraryBrowse.openVirtualCoverPicker then
                            LibraryBrowse.openVirtualCoverPicker(file, fc)
                        end
                    else
                        _openFolderCoverPicker(file, fc, BookInfoManager)
                    end
                end,
            }}
        end
    )

    -- "Create collection" — series groups (snapshot) or real folders (connected).
    FileManager:addFileDialogButtons("simpleui_fc_create_collection",
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

            local SG = _seriesGrouping()
            local is_virtual_series = (item_entry and item_entry.is_series_group)
                                   or (SG and SG.hasGroup(file))
            local is_virtual_meta   = item_entry and item_entry.is_virtual_meta_leaf

            -- Virtual author/series/tag leaves use the library-browse hold path.
            if is_virtual_meta then return nil end

            if is_virtual_series then
                if not M.getSeriesGrouping() then return nil end
                local series_name = (item_entry and item_entry.text) or ""
                return {{
                    text = _("Create collection"),
                    callback = function()
                        local UIManager = require("ui/uimanager")
                        if fc and fc.file_dialog then UIManager:close(fc.file_dialog) end
                        if SG then SG.createCollection(file, series_name) end
                    end,
                }}
            end

            -- Real filesystem folder: create a collection linked to this path so
            -- KOReader rescans it (same model as Collections → Connect folders).
            local folder_name = (item_entry and item_entry.text)
                or file:match("([^/]+)/?$")
                or file
            return {{
                text = _("Create collection"),
                callback = function()
                    local UIManager = require("ui/uimanager")
                    if fc and fc.file_dialog then UIManager:close(fc.file_dialog) end
                    GroupActions.createCollection{
                        suggested_name         = folder_name,
                        connect_folder         = file,
                        connect_subfolders     = M.getRecursiveCover(),
                        connect_scan_on_show   = true,
                        empty_message          = _("No books found in this folder."),
                    }
                end,
            }}
        end
    )
end

local function _uninstallFileDialogButton()
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok_fm or not FileManager then return end
    FileManager:removeFileDialogButtons("simpleui_fc_cover")
    FileManager:removeFileDialogButtons("simpleui_fc_create_collection")
    -- Legacy id from earlier builds.
    FileManager:removeFileDialogButtons("simpleui_fc_series_collection")
end


-- ---------------------------------------------------------------------------
-- 8. Series grouping — moved to features/sui_series_grouping.lua
-- ---------------------------------------------------------------------------
-- The FileChooser monkeypatches (switchItemTable/onMenuSelect/onMenuHold/
-- onFolderUp/changeToPath/refreshPath/updateItems) that group series books
-- inline inside a real folder now live in their own module, installed and
-- uninstalled independently by main.lua alongside this one. resolveStyle()
-- and the file-dialog button above reach it via the lazy _seriesGrouping()
-- helper — see the comment on that function for why it must stay lazy.

-- ---------------------------------------------------------------------------
-- 9. Widget builders — moved to features/sui_cover_widgets.lua
-- ---------------------------------------------------------------------------
-- Pentagon progress badge, corner ribbon, rounded-rect badges, book pile,
-- folder-name label, book-count badge, cell geometry, cover assembly, and
-- the 2×2 quad-cover grid are all in sui_cover_widgets.lua now — pure
-- rendering code with no settings reads (this file passes the values in).
-- Call sites below use the CoverWidgets.* names.

-- ---------------------------------------------------------------------------
-- 10. Core patches — M.install and M.uninstall
-- ---------------------------------------------------------------------------

-- The display mode's own item builder, which holds the item class as an
-- upvalue. Layout hooks may wrap the public function and keep it here.
local function _nativeItemsBuilder(DisplayMode)
    return DisplayMode._simpleui_native_build or DisplayMode._updateItemsBuildUI
end

-- Helper: retrieve MosaicMenuItem from mosaicmenu via userpatch upvalue lookup.
local function _getMosaicMenuItemAndPatch()
    local ok_mm, MosaicMenu = pcall(require, "mosaicmenu")
    if not ok_mm or not MosaicMenu then return nil, nil end
    local ok_up, userpatch = pcall(require, "userpatch")
    if not ok_up or not userpatch then return nil, nil end
    return userpatch.getUpValue(_nativeItemsBuilder(MosaicMenu), "MosaicMenuItem"), userpatch
end

-- Helper: retrieve ListMenuItem from listmenu via userpatch upvalue lookup.
local function _getListMenuItem()
    local ok_lm, ListMenu = pcall(require, "listmenu")
    if not ok_lm or not ListMenu then return nil end
    local ok_up, userpatch = pcall(require, "userpatch")
    if not ok_up or not userpatch then return nil end
    return userpatch.getUpValue(_nativeItemsBuilder(ListMenu), "ListMenuItem")
end

-- List rows keep their cover in a square slot, centred by default. Anchors the
-- cover to the slot's left edge so it starts at the row's left margin; the text
-- column keeps its position.
local function _leftAlignListCover(item)
    if not item.do_cover_image then return end
    local group = item._underline_container and item._underline_container[1]
    local row   = group and group[2]
    local slot  = row and row[1]
    if not (slot and slot.dimen and slot[1])
            or slot.paintTo ~= CenterContainer.paintTo then
        return
    end
    row[1] = LeftContainer:new{ dimen = slot.dimen, slot[1] }
end

-- Folder rows show their name without a trailing slash, whether the folder is
-- real or virtual.
local function _stripListFolderSlash(item)
    local entry = item.entry
    if entry and not entry.is_file and not entry.file and not entry.is_go_up and item.text then
        item.text = (item.text:gsub("/$", ""))
    end
end

-- The widget drawn as the cell's cover: the cover frame of a book, the cover
-- group (cover plus pile) of a folder with a generated cover, or the whole
-- frame of a plain folder tile.
local function _coverWidget(item)
    local root = item[1] and item[1][1]
    if not root then return nil end
    if item.is_directory and not item._foldercover_processed then return root end
    return root[1]
end

-- Px a book cover gives up on its right and bottom edges for its drop shadow.
-- Folder covers reserve theirs in CoverWidgets.computeCellGeometry.
local function _bookShadowInset(item)
    local entry = item.entry
    if entry and (entry.is_file or entry.file) then
        return SUIStyle.coverShadowOffset(SUIStyle.SHADOW_LIBRARY)
    end
    return 0
end

-- Returns the cover's width and the y offset, from the cell top, of the first
-- row below the cover and its shadow. The cover is centred vertically in
-- `cover_area_h` minus the shadow's room, the part of the cell above the
-- strip. Falls back to the whole cell area when the cover widget cannot be
-- located.
local function _coverMetrics(item, cover_area_h)
    local cover = _coverWidget(item)
    if not cover then return item.width, cover_area_h end
    local inset  = _bookShadowInset(item)
    local area_h = cover_area_h - inset
    local size   = cover:getSize()
    local h      = math.min(size.h, area_h)
    return math.min(size.w, item.width), math.floor((area_h - h) / 2) + h + inset
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
        local UI_core       = require("infra/sui_core")

        local TITLE_FONT_S  = SUIStyle.FS_DETAIL    -- 15: cover title in size-probe context
        local AUTHOR_FONT_S = SUIStyle.FS_CAPTION   -- 12: cover author in size-probe context
        local PAD_S         = Screen_s:scaleBySize(3)
        local GAP_S         = Screen_s:scaleBySize(2)

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
                local text_w
                text_w, self._simpleui_strip_top = _coverMetrics(self, self.height - _STRIP_H)

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
                        max_width              = text_w,
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

            -- Blit the strip directly below the cover.
            if self._simpleui_strip_bb then
                local ok_wp, SUIWallpaper = pcall(require, "features/sui_wallpaper")
                local wp_active = ok_wp and SUIWallpaper
                    and SUIWallpaper.styleGetWallpaperShowInFM()
                    and SUIWallpaper.styleGetBgWidget() ~= nil

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
                        x, y + self._simpleui_strip_top, self.width, _STRIP_H,
                        Blitbuffer_s.COLOR_BLACK,
                        _stripPaintFn, self._simpleui_strip_mask_bb)
                else
                    bb:blitFrom(self._simpleui_strip_bb,
                        x, y + self._simpleui_strip_top,
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

    -- Display settings every folder-cover builder consumes, read in one place.
    local function _readDisplay()
        local display = {
            label_mode  = M.getLabelMode(),
            show_name   = M.getShowName(),
            label_style = M.getLabelStyle(),
            label_pos   = M.getLabelPosition(),
            label_color = M.getLabelColor(),
            label_scale = M.getLabelScale(),
            hide_pile   = M.getHidePile(),
            badge = {
                hidden   = M.getBadgeHidden(),
                scale    = M.getBadgeScale(),
                dark     = M.getBadgeColorFolder() == "dark",
                position = M.getBadgePosition(),
            },
        }
        -- When the strip is active it already shows the folder name below
        -- the cover — suppress the overlay label to avoid redundancy.
        if _STRIP_H > 0 then display.label_mode = "hidden" end
        return display
    end

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
            local inset       = _bookShadowInset(self)
            max_img_w = self.width  - inset - 2 * border_size
            max_img_h = self.height - inset - 2 * border_size
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
        -- Book covers are laid out in the cell minus their shadow's room.
        local inset = _bookShadowInset(self)
        self.width, self.height = self.width - inset, self.height - inset
        original_update(self, ...)
        self.width, self.height = self.width + inset, self.height + inset
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
            -- Last-resort fallback: BIM has no rendered/stable count for this
            -- book (typically an unopened EPUB) — try the "p(<n>)" filename
            -- token before giving up on the badge entirely.
            if not self._fc_pages then
                self._fc_pages = _pageCountFromFilename(self.filepath)
            end

            self._fc_underline_color  = M.getHideUnderline()
                and SUIStyle.COLOR.surface or SUIStyle.COLOR.text_primary
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
                self._fc_pages_widget = CoverWidgets.buildRectBadgeWidget(
                    self._fc_pages .. _(" p."), false, cell_min, dark, false, badge_scale)
            end

            if self._fc_overlay_series and self._fc_series_index then
                local cell_min = math.min(self.width or 40, self.height or 40)
                local dark = M.getBadgeColorSeries() == "dark"
                self._fc_series_widget = CoverWidgets.buildRectBadgeWidget(
                    "#" .. self._fc_series_index, false, cell_min, dark, false, badge_scale)
            end

            -- Progress pentagon: only for books that have been opened.
            if self._fc_overlay_progress then
                -- Show the progress badge whenever percent_finished is non-nil
                -- (even 0%), or status is complete/abandoned. This correctly
                -- handles books opened but not yet advanced past page 1.
                local has_progress = (self.percent_finished ~= nil)
                    or (self.status == "complete") or (self.status == "abandoned")
                if has_progress then
                local eff_size = math.max(8, math.floor(
                    math.min(self.width or 40, self.height or 40) * 0.14 * badge_scale))
                    local dark = M.getBadgeColorProgress() == "dark"
                    local prog_desc = CoverWidgets.buildProgressBadgeDesc(
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
                            CoverWidgets.buildRectBadgeWidget(_("New"), true, cell_min, dark, true, badge_scale)
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

        -- Defer the first folder-cover pass while any SimpleUI screen (the
        -- built-in Homescreen or a Custom Screen) is visible, so it paints
        -- first and the user sees no blank frames. Generic across both via
        -- ScreenEngine.liveScreenIds() rather than the flat HS._instance
        -- field, which is only ever populated for the built-in Homescreen —
        -- a Custom Screen visible at this point would otherwise never
        -- trigger the deferral, risking the same blank-frame flash.
        local ScreenEngine = package.loaded["engines/sui_screen_engine"]
        local any_live = ScreenEngine and #ScreenEngine.liveScreenIds() > 0
        if any_live and not self.menu._fc_hs_deferred then
            self.menu._fc_hs_deferred = true
            local menu_ref = self.menu
            local UIManager = require("ui/uimanager")
            UIManager:nextTick(function()
                menu_ref._fc_hs_deferred = false
                local SE2 = package.loaded["engines/sui_screen_engine"]
                if SE2 and #SE2.liveScreenIds() > 0 then return end
                local fm = package.loaded["apps/filemanager/filemanager"]
                if not fm or not fm.instance or fm.instance.tearing_down then return end
                menu_ref:updateItems()
            end)
            return
        end

        local dir_path = self.entry and self.entry.path
        if not dir_path then return end

        -- Read display settings once; helpers receive them as a single table.
        local display = _readDisplay()

        local folder_style = _resolveStyle(self.menu, dir_path, self.entry)

        -- ── Series group cover ────────────────────────────────────────────────
        if self.entry.is_series_group then
            if self._foldercover_processed then return end

            -- User-chosen override (single mode only; ignored in quad).
            local sg_override_fp = folder_style ~= "quad" and CoverOverrides.get(dir_path)
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

            local SG_ref = _seriesGrouping()
            local items = self.entry.series_items or (SG_ref and SG_ref.getGroupItems(dir_path))

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
                    local border, pile, max_img_w, max_img_h = CoverWidgets.computeCellGeometry(self, M.getHidePile())
                    local widget = CoverWidgets.buildQuadCover(self, covers, border, pile, max_img_w, max_img_h, display)
                    if widget then
                        CoverWidgets.installWidget(self, widget)
                        return
                    end
                end
                -- No covers ready — register for async retry.
                _registerRetry(self)
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
            local cover_file = CoverFinder.findDotCover(dir_path)
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

            local covers = CoverFinder.collectCovers(self.menu, dir_path, 4, BookInfoManager, M.getRecursiveCover())
            if #covers > 0 then
                local border, pile, max_img_w, max_img_h = CoverWidgets.computeCellGeometry(self, M.getHidePile())
                local widget = CoverWidgets.buildQuadCover(self, covers, border, pile, max_img_w, max_img_h, display)
                if widget then
                    CoverWidgets.installWidget(self, widget)
                    return
                end
            end
            -- No covers yet — register for async retry.
            _registerRetry(self)
            return
        end

        -- ── Single-cover mode (default) ───────────────────────────────────────

        -- 1. User-chosen override.
        local override_fp = CoverOverrides.get(dir_path)
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
        local cover_file = CoverFinder.findDotCover(dir_path)
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
        local cover, summary = CoverFinder.findFirstCover(self.menu, dir_path, BookInfoManager)
        if cover then
            self:_setFolderCover(cover, display)
            return
        end
        local has_files      = #summary.books > 0
        local has_subfolders = #summary.dirs  > 0

        -- 4. Bookless folder: recursive scan or placeholder.
        if not has_files then
            if has_subfolders and M.getSubfolderCover() and M.getRecursiveCover() then
                local sub_cover = CoverFinder.findCoverRecursive(self.menu, dir_path, 1, 3, BookInfoManager)
                if sub_cover then
                    self:_setFolderCover(sub_cover, display)
                    return
                end
            end
            if M.getSubfolderCover() then self:_setEmptyFolderCover(display) end
            return
        end

        -- 5. No cover found yet — register for async retry.
        _registerRetry(self)
    end -- MosaicMenuItem:update

    -- Builds and installs a single-image cover widget.
    -- `img` = { file=path } or { data=blitbuffer, w=n, h=n }
    function MosaicMenuItem:_setFolderCover(img, display)
        -- `display` may be nil when called by third-party patches that pre-date
        -- this parameter (e.g. patches/2-automatic-book-series.lua).  Fall back
        -- to reading the settings directly so the rest of the pipeline never
        -- receives a nil table.
        display = display or _readDisplay()
        self._foldercover_processed = true
        local border, pile, max_img_w, max_img_h = CoverWidgets.computeCellGeometry(self, M.getHidePile())

        local img_options = {}
        if img.file then img_options.file  = img.file end
        if img.data then
            img_options.image             = img.data
            -- img.data is always BookInfoManager's own persistent cover_bb
            -- (bi.cover_bb), shared with every other consumer of that book's
            -- cover -- see the _setFolderCover call sites above. Without this,
            -- ImageWidget's default (image_disposable = true) frees BIM's bb
            -- on this item's teardown, corrupting it for the file browser and
            -- any other place that reads bi.cover_bb afterwards.
            img_options.image_disposable  = false
        end

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
        CoverWidgets.installWidget(self, CoverWidgets.assembleCoverWidget(self, content, size, border, pile, display))
    end

    -- Placeholder cover for bookless folders (subfolders only or empty).
    function MosaicMenuItem:_setEmptyFolderCover(display)
        display = display or _readDisplay()
        self._foldercover_processed = true
        local border, pile, max_img_w, max_img_h = CoverWidgets.computeCellGeometry(self, M.getHidePile())

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
            local SUIStyle = require("features/sui_style")
            local custom = SUIStyle.getIcon("sui_fc_empty")
            if custom then actual_icon_path = custom end
        end)

        local nerd_char = Config.nerdIconChar(actual_icon_path)

        if nerd_char then
            local ok_tw, tw = pcall(function()
                return CenterContainer:new{
                    dimen = Geom:new{ w = img_w, h = img_h },
                    TextWidget:new{
                        text    = nerd_char,
                        face    = Font:getFace(SUIStyle.FACE_ICONS, math.floor(icon_size * 0.85)),
                        fgcolor = SUIStyle.COLOR.text_primary,
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

        -- Fallback: if neither the nerd-font glyph nor the icon file resolved
        -- (custom "sui_fc_empty" icon missing/moved, or the pcall above
        -- failed for any other reason), icon_widget would still be nil here.
        -- FrameContainer:getSize() unconditionally calls self[1]:getSize()
        -- (it does NOT short-circuit on self.dimen), so a nil child crashes
        -- the whole mosaic page as soon as it's measured. A blank spacer
        -- keeps bg_canvas paintable with just its white background.
        if not icon_widget then
            icon_widget = CenterContainer:new{
                dimen = Geom:new{ w = img_w, h = img_h },
                VerticalSpan:new{ width = 1 },
            }
        end

        local bg_canvas = FrameContainer:new{
            padding    = 0,
            bordersize = 0,
            background = SUIStyle.COLOR.surface,
            dimen      = Geom:new{ w = img_w, h = img_h },
            icon_widget,
        }

        local size    = Geom:new{ w = img_w, h = img_h }
        local content = FrameContainer:new{ padding = 0, bordersize = border, bg_canvas }
        CoverWidgets.installWidget(self, CoverWidgets.assembleCoverWidget(self, content, size, border, pile, display))
    end

    -- onFocus: apply the pre-computed underline color (no settings read in the hot path).
    MosaicMenuItem._simpleui_fc_orig_onFocus = MosaicMenuItem.onFocus
    function MosaicMenuItem:onFocus()
        self._underline_container.color = self._fc_underline_color
            or (M.getHideUnderline() and SUIStyle.COLOR.surface or SUIStyle.COLOR.text_primary)
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
                    bb:paintRect(x + ix, y + iy + tgt.bordersize,
                                 rect_size, rect_size, SUIStyle.COLOR.gray_soft)
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
                    local new_wg = CoverWidgets.buildRectBadgeWidget(
                        "#" .. bi.series_index, false, cell_min, dark, false, M.getBadgeScale())
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
        -- Top edge flush with the cover FrameContainer top (same as modules).
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
                CoverWidgets.drawProgressBadge(bb, badge_x, fy, prog_desc)
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
                    CoverWidgets.paintCornerRibbon(bb,
                        cover_left, cover_right, fy, fh,
                        span, band_thick, _("New"), font_sz, dark)
                    -- Repaint cover border over ribbon so it isn't obscured.
                local brd = SUIStyle.BADGE_BORDER_SZ
                    if brd > 0 then
                        local bclr = SUIStyle.COLOR.text_primary
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

    -- Repaints the description hint on the cover's right edge over the shadow,
    -- on a solid background so the shadow does not show through it.
    local function paintDescriptionHint(item, bb, cover)
        if not item.has_description or BookInfoManager:getSetting("no_hint_description") then return end
        local w = Screen:scaleBySize(3)
        local h = math.ceil(cover.h / 8)
        local x = BD.mirroredUILayout() and (cover.x - w + 1) or (cover.x + cover.w - 1)
        bb:paintRect(x, cover.y, w, h, Blitbuffer.COLOR_WHITE)
        bb:paintBorder(x, cover.y, w, h, 1)
    end

    -- Book covers are painted in the cell minus their shadow's room, so the
    -- cover and its marks centre on the cover; the shadow is then cast beside it.
    local paint_with_marks = MosaicMenuItem.paintTo
    function MosaicMenuItem:paintTo(bb, x, y)
        local inset = _bookShadowInset(self)
        if inset == 0 then return paint_with_marks(self, bb, x, y) end
        self.width, self.height = self.width - inset, self.height - inset
        paint_with_marks(self, bb, x, y)
        self.width, self.height = self.width + inset, self.height + inset
        local cover = self._cover_frame or (self[1] and self[1][1] and self[1][1][1])
        local dimen = cover and cover.dimen
        if dimen then
            CoverWidgets.paintShadow(bb, dimen.x, dimen.y, dimen.w, dimen.h, inset)
            paintDescriptionHint(self, bb, dimen)
        end
    end

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
    -- Series grouping is installed independently by main.lua now
    -- (features/sui_series_grouping.lua's own install()/uninstall()).
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
        local function updateFolderCover(self, ...)
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
                local override_fp = CoverOverrides.get(dir_path)
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
                local sg_override_fp = CoverOverrides.get(dir_path)
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
                local SG_ref2 = _seriesGrouping()
                local items = entry.series_items or (SG_ref2 and SG_ref2.getGroupItems(dir_path))
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
            local override_fp = CoverOverrides.get(dir_path)
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
            local cover_file = CoverFinder.findDotCover(dir_path)
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

            -- 3. First cached book cover inside the folder.
            local cover = self.menu
                and CoverFinder.findFirstCover(self.menu, dir_path, BookInfoManager)
            if cover then
                self:_setListFolderCover({
                    cover_bb = cover.data, cover_w = cover.w, cover_h = cover.h,
                })
                return
            end

            -- 4. No cover — register for async retry.
            _registerRetry(self)
        end -- updateFolderCover

        function ListMenuItem:update(...)
            _stripListFolderSlash(self)
            updateFolderCover(self, ...)
            _leftAlignListCover(self)
        end

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
                image             = bookinfo.cover_bb,
                scale_factor      = scale_factor,
                -- bookinfo.cover_bb is BookInfoManager's own persistent bb,
                -- shared with every other consumer of this book's cover --
                -- same rationale as the img.data guard in _setFolderCover
                -- above. Without this, ImageWidget's default
                -- (image_disposable = true) frees BIM's bb on this item's
                -- teardown, corrupting it for the file browser and any
                -- other place that reads bookinfo.cover_bb afterwards.
                image_disposable  = false,
            }
            wimage:_render()
            local image_size = wimage:getSize()

            local wleft = LeftContainer:new{
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
            -- Match stock: same formula as book title font size
            -- (listmenu.lua's fontsize_title = _fontSize(20, 24)), so folder
            -- names render at the same size as individual book titles.
            local font_size = _lmFontSize(dimen.h, 20, 24)
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
    MosaicMenuItem._simpleui_fc_patched = nil
    MosaicMenuItem._simpleui_strip_h    = nil
    _module_strip_h = 0

    _uninstallItemCache()
    -- Series grouping is uninstalled independently by main.lua now.
    _uninstallFileDialogButton()

    CoverFinder.clearCache()
    CoverWidgets.clearLabelMetricsCache()
    CoverWidgets.clearRibbonCache()
    CoverWidgets.clearPentagonMaskCache()

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