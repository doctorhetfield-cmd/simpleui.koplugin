-- sui_foldercovers.lua — Simple UI
-- Folder cover art and book cover overlays for the CoverBrowser mosaic/list views.

local _        = require("sui_i18n").translate
local lfs      = require("libs/libkoreader-lfs")
local logger   = require("logger")

-- Widget requires at module level so the require() cache is hit once,
-- not on every cell render.
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
-- Settings keys
-- ---------------------------------------------------------------------------

local SK = {
    enabled         = "simpleui_fc_enabled",
    show_name       = "simpleui_fc_show_name",
    hide_underline  = "simpleui_fc_hide_underline",
    label_style     = "simpleui_fc_label_style",
    label_position  = "simpleui_fc_label_position",
    badge_position  = "simpleui_fc_badge_position",
    badge_hidden    = "simpleui_fc_badge_hidden",
    cover_mode      = "simpleui_fc_cover_mode",
    label_mode      = "simpleui_fc_label_mode",
    overlay_pages   = "simpleui_fc_overlay_pages",
    overlay_series  = "simpleui_fc_overlay_series",
    series_grouping = "simpleui_fc_series_grouping",
    subfolder_cover = "simpleui_fc_subfolder_cover",
    recursive_cover = "simpleui_fc_recursive_cover",
    label_scale     = "simpleui_fc_label_scale",
}

-- ---------------------------------------------------------------------------
-- Module table and forward declarations
-- ---------------------------------------------------------------------------

local M = {}

-- Series-grouping state — forward-declared so all functions can close over them.
local _sg_current           = nil
local _sg_items_cache       = {}
local _sg_last_evicted_path = nil

-- ---------------------------------------------------------------------------
-- Settings API
-- ---------------------------------------------------------------------------

function M.isEnabled()   return G_reader_settings:isTrue(SK.enabled)          end
function M.setEnabled(v) G_reader_settings:saveSetting(SK.enabled, v)         end

local function _getFlag(key)      return G_reader_settings:readSetting(key) ~= false end
local function _setFlag(key, v)   G_reader_settings:saveSetting(key, v)              end

function M.getShowName()       return _getFlag(SK.show_name)      end
function M.setShowName(v)      _setFlag(SK.show_name, v)          end
function M.getHideUnderline()  return _getFlag(SK.hide_underline) end
function M.setHideUnderline(v) _setFlag(SK.hide_underline, v)     end

-- "alpha" (default) = semitransparent white overlay; "frame" = solid grey border.
function M.getLabelStyle()    return G_reader_settings:readSetting(SK.label_style)    or "alpha"   end
function M.setLabelStyle(v)   G_reader_settings:saveSetting(SK.label_style, v)                     end

-- "bottom" (default) | "center" | "top"
function M.getLabelPosition()  return G_reader_settings:readSetting(SK.label_position) or "bottom" end
function M.setLabelPosition(v) G_reader_settings:saveSetting(SK.label_position, v)                 end

-- "top" (default) | "bottom"
function M.getBadgePosition()  return G_reader_settings:readSetting(SK.badge_position) or "top"   end
function M.setBadgePosition(v) G_reader_settings:saveSetting(SK.badge_position, v)                 end

function M.getBadgeHidden()  return G_reader_settings:isTrue(SK.badge_hidden)                      end
function M.setBadgeHidden(v) G_reader_settings:saveSetting(SK.badge_hidden, v)                     end

-- "default" = scale-to-fit; "2_3" = force 2:3 aspect ratio.
function M.getCoverMode()    return G_reader_settings:readSetting(SK.cover_mode) or "default"      end
function M.setCoverMode(v)   G_reader_settings:saveSetting(SK.cover_mode, v)                       end

-- "overlay" (default) = folder name on cover; "hidden" = no label.
function M.getLabelMode()    return G_reader_settings:readSetting(SK.label_mode) or "overlay"      end
function M.setLabelMode(v)   G_reader_settings:saveSetting(SK.label_mode, v)                       end

-- Pages badge on book covers (default on).
function M.getOverlayPages()  return G_reader_settings:readSetting(SK.overlay_pages) ~= false      end
function M.setOverlayPages(v) _setFlag(SK.overlay_pages, v)                                        end

-- Series index badge on book covers (default off).
function M.getOverlaySeries()  return G_reader_settings:isTrue(SK.overlay_series)                  end
function M.setOverlaySeries(v) _setFlag(SK.overlay_series, v)                                      end

-- Virtual series folders in the mosaic (default off).
function M.getSeriesGrouping()  return G_reader_settings:isTrue(SK.series_grouping)                end
function M.setSeriesGrouping(v) _setFlag(SK.series_grouping, v)                                    end

-- Placeholder cover for folders with no direct ebooks (default off).
function M.getSubfolderCover()  return G_reader_settings:isTrue(SK.subfolder_cover)                end
function M.setSubfolderCover(v) _setFlag(SK.subfolder_cover, v)                                    end

-- Scan up to 3 subfolder levels for a cached cover (default off).
function M.getRecursiveCover()  return G_reader_settings:isTrue(SK.recursive_cover)                end
function M.setRecursiveCover(v) _setFlag(SK.recursive_cover, v)                                    end

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
    local n = tonumber(G_reader_settings:readSetting(SK.label_scale))
    if not n then return _FC_SCALE_DEF end
    return _clampFCScale(n)
end
function M.getLabelScale()    return M.getLabelScalePct() / 100 end
function M.setLabelScale(pct) G_reader_settings:saveSetting(SK.label_scale, _clampFCScale(pct)) end

-- ---------------------------------------------------------------------------
-- Module-level constants — computed once from device DPI.
-- ---------------------------------------------------------------------------

local _BASE_COVER_H = math.floor(Screen:scaleBySize(96))
local _BASE_NB_SIZE = Screen:scaleBySize(10)
local _BASE_NB_FS   = Screen:scaleBySize(4)
local _BASE_DIR_FS  = Screen:scaleBySize(5)

local _EDGE_THICK  = math.max(1, Screen:scaleBySize(3))
local _EDGE_MARGIN = math.max(1, Screen:scaleBySize(1))
local _SPINE_W     = _EDGE_THICK * 2 + _EDGE_MARGIN * 2
local _SPINE_COLOR = Blitbuffer.gray(0.70)

local _LATERAL_PAD        = Screen:scaleBySize(10)
local _VERTICAL_PAD       = Screen:scaleBySize(4)
local _BADGE_MARGIN_BASE  = Screen:scaleBySize(8)
local _BADGE_MARGIN_R_BASE = Screen:scaleBySize(4)

local _LABEL_ALPHA = 0.75

-- Badge geometry — pre-computed so paintTo() never calls scaleBySize per frame.
local _BADGE_FONT_SZ  = Screen:scaleBySize(5)
local _BADGE_PAD_H    = Screen:scaleBySize(2)
local _BADGE_PAD_V    = Screen:scaleBySize(1)
local _BADGE_INSET    = Screen:scaleBySize(3)
local _BADGE_CORNER   = Screen:scaleBySize(2)
local _BADGE_BAR_H    = Screen:scaleBySize(8)   -- progress-bar height (badge Y anchor)
local _BADGE_BAR_GAP  = Screen:scaleBySize(4)   -- gap between pages badge and progress bar

-- Module-level font-size cache for _getFolderNameWidget.
-- Key: display_text .. "\0" .. available_w .. "\0" .. max_font_size
-- Survives MosaicMenuItem recycling across scrolls, unlike a per-item cache.
-- Two-generation design (same as the item cache): each generation holds at most
-- _FS_CACHE_MAX entries; when full the current gen is demoted and a fresh one
-- starts. Effective capacity is 2 × _FS_CACHE_MAX with smooth eviction.
local _FS_CACHE_MAX   = 200
local _fs_cache_a     = {}
local _fs_cache_b     = {}
local _fs_cache_a_cnt = 0

local function _fsCacheGet(key)
    return _fs_cache_a[key] or _fs_cache_b[key]
end

local function _fsCacheSet(key, value)
    if _fs_cache_a_cnt >= _FS_CACHE_MAX then
        _fs_cache_b   = _fs_cache_a
        _fs_cache_a   = {}
        _fs_cache_a_cnt = 0
    end
    _fs_cache_a[key] = value
    _fs_cache_a_cnt  = _fs_cache_a_cnt + 1
end

local _PLUGIN_DIR  = debug.getinfo(1, "S").source:match("^@(.+/)[^/]+$") or "./"
local _ICON_PATH   = _PLUGIN_DIR .. "icons/custom.svg"
local _ICON_EXISTS = lfs.attributes(_ICON_PATH, "mode") == "file"

-- ---------------------------------------------------------------------------
-- Cover-file discovery
-- ---------------------------------------------------------------------------

local _COVER_EXTS = { ".jpg", ".jpeg", ".png", ".webp", ".gif" }

-- Per-directory cache for .cover.* lookups.
-- Values: filepath string on hit, false on confirmed miss.
-- Invalidated in refreshPath when the library was visited (files may have changed).
-- Capped at _DIR_CACHE_MAX entries (two-generation) to bound memory use.
local _DIR_CACHE_MAX    = 300
local _cover_file_cache = {}
local _cfc_b            = {}
local _cfc_cnt          = 0

local function _cfcGet(key)   return _cover_file_cache[key] or _cfc_b[key] end
local function _cfcSet(key, v)
    if _cfc_cnt >= _DIR_CACHE_MAX then
        _cfc_b            = _cover_file_cache
        _cover_file_cache = {}
        _cfc_cnt          = 0
    end
    _cover_file_cache[key] = v
    _cfc_cnt = _cfc_cnt + 1
end

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

-- Per-directory cache for the ListMenuItem lfs.dir cover scan.
-- Same invalidation rules as _cover_file_cache.
-- Capped at _DIR_CACHE_MAX entries (two-generation).
local _lm_dir_cover_cache = {}
local _lmc_b              = {}
local _lmc_cnt            = 0

local function _lmcGet(key)   return _lm_dir_cover_cache[key] or _lmc_b[key] end
local function _lmcSet(key, v)
    if _lmc_cnt >= _DIR_CACHE_MAX then
        _lmc_b            = _lm_dir_cover_cache
        _lm_dir_cover_cache = {}
        _lmc_cnt          = 0
    end
    _lm_dir_cover_cache[key] = v
    _lmc_cnt = _lmc_cnt + 1
end

-- ---------------------------------------------------------------------------
-- Patch helpers
-- ---------------------------------------------------------------------------

local function _getMosaicMenuItemAndPatch()
    local ok_mm, MosaicMenu = pcall(require, "mosaicmenu")
    if not ok_mm or not MosaicMenu then return nil, nil end
    local ok_up, userpatch = pcall(require, "userpatch")
    if not ok_up or not userpatch then return nil, nil end
    return userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem"), userpatch
end

local function _getListMenuItem()
    local ok_lm, ListMenu = pcall(require, "listmenu")
    if not ok_lm or not ListMenu then return nil end
    local ok_up, userpatch = pcall(require, "userpatch")
    if not ok_up or not userpatch then return nil end
    return userpatch.getUpValue(ListMenu._updateItemsBuildUI, "ListMenuItem")
end

-- ---------------------------------------------------------------------------
-- Cover-override settings
-- Stored in G_reader_settings under "simpleui_fc_covers": { [dir_path] = book_path }
-- ---------------------------------------------------------------------------

local _FC_COVERS_KEY = "simpleui_fc_covers"

-- Lazy-loaded, mutated in-place — never goes stale during a session.
local _overrides_cache = nil

local function _getCoverOverrides()
    if not _overrides_cache then
        _overrides_cache = G_reader_settings:readSetting(_FC_COVERS_KEY) or {}
    end
    return _overrides_cache
end

local function _saveCoverOverride(dir_path, book_path)
    local t = _getCoverOverrides()
    t[dir_path] = book_path
    G_reader_settings:saveSetting(_FC_COVERS_KEY, t)
end

local function _clearCoverOverride(dir_path)
    local t = _getCoverOverrides()
    t[dir_path] = nil
    G_reader_settings:saveSetting(_FC_COVERS_KEY, t)
end

-- ---------------------------------------------------------------------------
-- Shared helper: run genItemTableFromPath with the status filter suppressed.
-- Folders with "show only new/reading" active would otherwise hide books that
-- can still supply cover art. Returns the entries table or nil.
-- ---------------------------------------------------------------------------
local function _entriesWithNoFilter(menu, dir_path)
    local saved = FileChooser.show_filter
    FileChooser.show_filter = {}
    menu._dummy = true
    local entries = menu:genItemTableFromPath(dir_path)
    menu._dummy = false
    FileChooser.show_filter = saved
    return entries
end

-- ---------------------------------------------------------------------------
-- Folder-item invalidation: clears _foldercover_processed so the next
-- updateItems re-fetches the cover. Triggers a full redraw of the grid.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- Recursive cover search: scans dir_path up to max_depth levels for any
-- cached book cover. Returns { data, w, h } or nil.
-- ---------------------------------------------------------------------------
local function _findCoverRecursive(menu, dir_path, depth, max_depth, BookInfoManager)
    if depth > max_depth then return nil end

    local entries = _entriesWithNoFilter(menu, dir_path)
    if not entries then return nil end

    -- Single pass: try files immediately, accumulate subdirs for later.
    local subdirs = {}
    for _, entry in ipairs(entries) do
        if entry.is_file or entry.file then
            local bi = BookInfoManager:getBookInfo(entry.path, true)
            if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
                    and not bi.ignore_cover
                    and not BookInfoManager.isCachedCoverInvalid(bi, menu.cover_specs)
            then
                return { data = bi.cover_bb, w = bi.cover_w, h = bi.cover_h }
            end
        else
            subdirs[#subdirs + 1] = entry
        end
    end

    for _, entry in ipairs(subdirs) do
        local found = _findCoverRecursive(menu, entry.path, depth + 1, max_depth, BookInfoManager)
        if found then return found end
    end

    return nil
end

-- ---------------------------------------------------------------------------
-- Book collection for the cover picker dialog.
-- Recursion follows the same max_depth used by the automatic scan.
-- Capped at _COLLECT_MAX entries so the picker dialog stays usable.
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

-- ---------------------------------------------------------------------------
-- Cover picker dialogs
-- ---------------------------------------------------------------------------

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
            local _fp   = fp
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

    picker = ButtonDialog:new{ title = _("Series cover"), buttons = buttons }
    UIManager:show(picker)
end

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

    picker = ButtonDialog:new{ title = _("Folder cover"), buttons = buttons }
    UIManager:show(picker)
end

-- ---------------------------------------------------------------------------
-- Long-press "Set folder cover…" button in the FileManager file dialog.
-- ---------------------------------------------------------------------------

local function _installFileDialogButton(BookInfoManager)
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok_fm or not FileManager then return end

    FileManager:addFileDialogButtons("simpleui_fc_cover",
        function(file, is_file, _book_props)
            if is_file then return nil end
            if not M.isEnabled() then return nil end

            local is_virtual_series = _sg_items_cache[file] ~= nil

            local fc         = FileManager.instance and FileManager.instance.file_chooser
            local item_entry = nil
            if fc and fc.item_table then
                for _, it in ipairs(fc.item_table) do
                    if it.path == file then item_entry = it; break end
                end
            end
            local is_virtual_meta = item_entry and item_entry.is_virtual_meta_leaf

            local label
            if is_virtual_series then
                label = _("Set series cover…")
            elseif is_virtual_meta then
                label = _("Set virtual folder cover…")
            else
                label = _("Set folder cover…")
            end

            return {{
                text = label,
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
end

local function _uninstallFileDialogButton()
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok_fm or not FileManager then return end
    FileManager:removeFileDialogButtons("simpleui_fc_cover")
end

-- ---------------------------------------------------------------------------
-- Item-table cache — single-entry cache for FileChooser:genItemTableFromPath.
--
-- Strategy: cache the complete sorted item table for the current directory.
-- The cache key encodes path + directory mtime + all settings that affect
-- the list (collate, filter, show_hidden). On a cache hit the entire
-- lfs.dir scan, sort, and per-item getListItem() calls are skipped.
--
-- A single lfs.attributes() call per navigation is the only overhead.
-- Memory cost: one table reference — the same object FileChooser already
-- holds, not a copy.
--
-- Invalidation:
--   • Directory changed   → automatic (mtime or path differ in the key).
--   • Closing a book      → _itc_invalidate() in refreshPath.
--   • Status/prop change  → _itc_invalidate() via setBookInfoCacheProperty.
--   • access-time collate → cache disabled (mtime never reflects reads).
--   • _dummy calls        → bypassed (used by cover-collection helpers).
-- ---------------------------------------------------------------------------

-- Single cache entry: {key=string, t=item_table} or nil.
local _itc = nil

local _orig_setBookInfoCacheProperty = nil
local _orig_genItemTableFromPath     = nil

local function _itc_invalidate()
    _itc = nil
end

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

    -- Invalidate on any book status/property change (e.g. marking read).
    -- The sort position depends on percent_finished, so stale items would
    -- appear in the wrong place until the next directory change.
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
        -- Bypass for non-FM instances (PathChooser, dialogs) and for
        -- _dummy=true calls used by cover-collection helpers.
        if fc._dummy or fc.name ~= "filemanager" then
            return _orig_genItemTableFromPath(fc, path)
        end

        -- access-time collate: directory mtime doesn't change when books are
        -- read, so the key would never change. Disable the cache for this mode.
        if (G_reader_settings:readSetting("collate") or "strcoll") == "access" then
            _itc = nil
            return _orig_genItemTableFromPath(fc, path)
        end

        local key = _itc_key(path, fc)
        if _itc and _itc.key == key then
            return _itc.t
        end

        local result = _orig_genItemTableFromPath(fc, path)

        -- Do not cache virtual series-grouping views: their synthetic path
        -- has no reliable mtime, so stale data would never be evicted.
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
    FileChooser.genItemTableFromPath  = _orig_genItemTableFromPath
    _orig_genItemTableFromPath        = nil
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
end

-- ---------------------------------------------------------------------------
-- Series grouping — virtual folders for multi-book series.
--
-- _sg_current:  active virtual-folder state while browsing a series group,
--               nil when in a real filesystem folder.
-- _sg_items_cache: vpath → { series_items }
-- ---------------------------------------------------------------------------

-- Groups series books from item_table into virtual folder items.
-- Modifies item_table in place. No-ops when grouping is not applicable.
local function _sgProcessItemTable(item_table, file_chooser)
    if not M.getSeriesGrouping()                  then return end
    if not file_chooser or not item_table         then return end
    if item_table._sg_is_series_view              then return end
    if file_chooser.show_current_dir_for_hold     then return end

    -- Evict stale _sg_items_cache entries for the current directory.
    -- Without this the cache grows unboundedly across reader→HS cycles.
    -- The guard skips the loop when the path hasn't changed since last eviction.
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
            if not item.sort_percent     then item.sort_percent     = 0     end
            if not item.percent_finished then item.percent_finished = 0     end
            if not item.opened           then item.opened           = false end

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
                        series_map[sname]             = group_item
                        group_item._sg_list_index     = #processed + 1
                        processed[#processed + 1]     = group_item
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

    -- If every book belongs to the same single series the folder is already
    -- organized — skip grouping to avoid a redundant wrapping level.
    local series_count = 0
    for _ in pairs(series_map) do
        series_count = series_count + 1
        if series_count > 1 then break end
    end
    if series_count == 1 and no_series_count == 0 and book_count > 0 then return end

    -- Ungroup singletons; sort and cache multi-book groups.
    for _, group in pairs(series_map) do
        local items = group.series_items
        if #items == 1 then
            local idx = group._sg_list_index
            if idx and processed[idx] == group then processed[idx] = items[1] end
        else
            table.sort(items, function(a, b)
                return (a._sg_series_index or 0) < (b._sg_series_index or 0)
            end)
            group.mandatory           = tostring(#items) .. " \u{F016}"
            _sg_items_cache[group.path] = items
        end
    end

    -- Re-sort the full processed list using FileChooser's sort function.
    -- Read sort settings once — G_reader_settings calls are not free.
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

    -- Write result back into item_table in place.
    -- Use a numeric loop to clear the array part; avoids hash traversal from pairs().
    for i = #item_table, 1, -1 do item_table[i] = nil end
    for i, v in ipairs(final)   do item_table[i] = v   end
end

-- Switches the file_chooser view into a virtual series folder.
local function _sgOpenGroup(file_chooser, group_item)
    if not file_chooser then return end

    local parent_path = file_chooser.path
    local items       = group_item.series_items
    local parent_page = file_chooser.page or 1

    _sg_current = {
        series_name    = group_item.text,
        parent_path    = parent_path,
        parent_page    = parent_page,
        should_restore = false,
    }

    items._sg_is_series_view = true
    items._sg_parent_path    = parent_path
    file_chooser._simpleui_has_go_up = true
    file_chooser:switchItemTable(nil, items, nil, nil, group_item.text)

    -- Update the titlebar subtitle to show the series name.
    local ok_p, Patches = pcall(require, "sui_patches")
    if ok_p and Patches and Patches.setFMPathBase then
        local fm = require("apps/filemanager/filemanager").instance
        Patches.setFMPathBase(group_item.text, fm)
    end

    if file_chooser.onGotoPage then
        pcall(function() file_chooser:onGotoPage(1) end)
    end
end

-- ---------------------------------------------------------------------------
-- Series grouping hooks — installed/uninstalled as a unit.
-- ---------------------------------------------------------------------------

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

    -- Process items before KOReader calculates itemmatch so the grouped list
    -- is what the page/focus logic sees.
    FileChooser.switchItemTable = function(fc, new_title, new_item_table,
                                           itemnumber, itemmatch, new_subtitle)
        if new_item_table and not new_item_table._sg_is_series_view then
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

    -- Long-press on a virtual series folder only shows the cover picker.
    FileChooser.onMenuHold = function(fc, item)
        if item and item.is_series_group and M.getSeriesGrouping() then
            if not M.isEnabled() then return true end
            local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
            if ok_bim and BookInfoManager then
                _openSeriesGroupCoverPicker(item.path, fc, BookInfoManager)
            end
            return true
        end
        return _sg_orig_onMenuHold(fc, item)
    end

    FileChooser.onFolderUp = function(fc)
        if fc.item_table and fc.item_table._sg_is_series_view then
            local parent = fc.item_table._sg_parent_path
            if _sg_current then _sg_current.should_restore = true end
            if parent then fc:changeToPath(parent) end
            return true
        end
        return _sg_orig_onFolderUp(fc)
    end

    FileChooser.changeToPath = function(fc, path, ...)
        if fc.item_table and fc.item_table._sg_is_series_view then
            local parent = fc.item_table._sg_parent_path
            -- Redirect relative ".." paths to the real parent.
            if parent and path and (path:match("/%.%.") or path:match("^%.%.")) then
                path = parent
            end
            fc.item_table._sg_is_series_view = false
            if path == parent then
                -- Back to real parent: keep _sg_current so updateItems can
                -- restore focus on the series group item.
                if _sg_current then
                    _sg_current.should_restore = true
                    local saved_page = _sg_current.parent_page
                    if saved_page and saved_page > 1 then
                        fc.page = saved_page
                    end
                end
            else
                -- Navigating somewhere else entirely: drop series state.
                _sg_current = nil
            end
        else
            _sg_current = nil
        end
        return _sg_orig_changeToPath(fc, path, ...)
    end

    -- After refreshPath (e.g. closing a book) re-enter the virtual folder
    -- if one was active.
    FileChooser.refreshPath = function(fc)
        -- The item table is stale after closing a book (percent_finished,
        -- bold state, sort position may have changed). Drop the cache so
        -- the next genItemTableFromPath rebuilds cleanly.
        _itc_invalidate()

        -- Only flush disk-level cover caches when the library was actually
        -- visited (files may have been added/removed). Preserving them on a
        -- plain reader→HS transition avoids redundant lfs.* calls per folder.
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
        if not M.getSeriesGrouping() then return end
        if not _sg_current then return end

        local sname      = _sg_current.series_name
        local saved_page = _sg_current.parent_page
        for _, item in ipairs(fc.item_table or {}) do
            if item.is_series_group and item.text == sname then
                _sgOpenGroup(fc, item)
                if _sg_current then _sg_current.parent_page = saved_page end
                return
            end
        end
        _sg_current = nil
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
                    fc._simpleui_has_go_up = (fc.item_table[1] and
                        (fc.item_table[1].is_go_up or false)) or false
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

-- ---------------------------------------------------------------------------
-- Visual build helpers — one per overlay layer.
-- ---------------------------------------------------------------------------

-- Two vertical spine lines on the left of the cover (folder-book aesthetic).
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

-- Folder-name label overlaid on the cover image. Returns nil when disabled.
-- label_style, label_position, and show_name are passed in pre-read by the
-- caller (_setFolderCover) so this function makes zero settings reads.
local function _buildLabel(item, available_w, size, border, cv_scale,
                            label_mode, show_name, label_style, label_pos)
    if label_mode ~= "overlay" then return nil end
    if not show_name            then return nil end

    local dir_max_fs = math.max(8, math.floor(_BASE_DIR_FS * cv_scale * M.getLabelScale()))
    local directory  = item:_getFolderNameWidget(available_w, dir_max_fs)
    local img_only   = Geom:new{ w = size.w, h = size.h }
    local img_dimen  = Geom:new{ w = size.w + border * 2, h = size.h + border * 2 }

    local frame = FrameContainer:new{
        padding        = 0,
        padding_top    = _VERTICAL_PAD,
        padding_bottom = _VERTICAL_PAD,
        padding_left   = _LATERAL_PAD,
        padding_right  = _LATERAL_PAD,
        bordersize     = border,
        background     = Blitbuffer.COLOR_WHITE,
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
        name_og[1] = CenterContainer:new{
            dimen = img_only, label_inner, overlap_align = "center",
        }
    elseif label_pos == "top" then
        name_og[1] = TopContainer:new{
            dimen = img_dimen, label_inner, overlap_align = "center",
        }
    else  -- "bottom"
        name_og[1] = BottomContainer:new{
            dimen = img_dimen, label_inner, overlap_align = "center",
        }
    end

    name_og.overlap_offset = { _SPINE_W, 0 }
    return name_og
end

-- Book-count badge (circle, top- or bottom-right). Returns nil when hidden.
local function _buildBadge(mandatory, cover_dimen, cv_scale)
    if M.getBadgeHidden() then return nil end
    local nb_text = mandatory and mandatory:match("(%d+) \u{F016}") or ""
    if nb_text == "" or nb_text == "0" then return nil end

    local nb_count       = tonumber(nb_text)
    local nb_size        = math.floor(_BASE_NB_SIZE * cv_scale)
    local nb_font_size   = math.floor(nb_size * (_BASE_NB_FS / _BASE_NB_SIZE))
    local badge_margin   = math.max(1, math.floor(_BADGE_MARGIN_BASE   * cv_scale))
    local badge_margin_r = math.max(1, math.floor(_BADGE_MARGIN_R_BASE * cv_scale))

    local badge = FrameContainer:new{
        padding    = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_BLACK,
        radius     = math.floor(nb_size / 2),
        dimen      = Geom:new{ w = nb_size, h = nb_size },
        CenterContainer:new{
            dimen = Geom:new{ w = nb_size, h = nb_size },
            TextWidget:new{
                text    = tostring(math.min(nb_count, 99)),
                face    = Font:getFace("cfont", nb_font_size),
                fgcolor = Blitbuffer.COLOR_WHITE,
                bold    = true,
            },
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

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.install()
    local MosaicMenuItem, userpatch = _getMosaicMenuItemAndPatch()
    if not MosaicMenuItem then return end
    if MosaicMenuItem._simpleui_fc_patched then return end

    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok_bim or not BookInfoManager then return end

    -- Capture cell dimensions before each render so the 2:3 StretchingImageWidget
    -- can enforce the correct aspect ratio.
    local max_img_w, max_img_h

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

    local orig_init = MosaicMenuItem.init
    MosaicMenuItem._simpleui_fc_orig_init = orig_init
    function MosaicMenuItem:init()
        if self.width and self.height then
            local border_size = Size.border.thin
            max_img_w = self.width  - 2 * border_size
            max_img_h = self.height - 2 * border_size
        end
        if orig_init then orig_init(self) end
    end

    MosaicMenuItem._simpleui_fc_patched     = true
    MosaicMenuItem._simpleui_fc_orig_update = MosaicMenuItem.update

    local original_update = MosaicMenuItem.update

    function MosaicMenuItem:update(...)
        original_update(self, ...)

        -- Capture pages and series index from the BookList cache (no extra I/O).
        -- Stored on self so paintTo() can use them without a redundant getBookInfo call.
        if not self.is_directory and not self.file_deleted and self.filepath then
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
            -- Pre-compute the underline color once per update so onFocus()
            -- is a plain field assignment rather than a settings read.
            self._fc_underline_color = M.getHideUnderline()
                and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
            -- Pre-read badge visibility flags so paintTo() makes zero settings reads.
            self._fc_overlay_pages  = M.getOverlayPages()
            self._fc_overlay_series = M.getOverlaySeries()

            -- Pre-render badge blitbuffers so paintTo() only calls bb:blitFrom,
            -- never allocates widgets. Free previous bbs to avoid leaks.
            if self._fc_pages_bb  then self._fc_pages_bb:free();  self._fc_pages_bb  = nil end
            if self._fc_series_bb then self._fc_series_bb:free(); self._fc_series_bb = nil end

            if self._fc_overlay_pages and self.status ~= "complete" and self._fc_pages then
                local ptw = TextWidget:new{
                    text    = self._fc_pages .. " p.",
                    face    = Font:getFace("cfont", _BADGE_FONT_SZ),
                    bold    = false,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }
                local tsz    = ptw:getSize()
                local border = Size.border.thin
                -- inner = text + padding; buf includes border on all four sides
                local inner_w = tsz.w + _BADGE_PAD_H * 2
                local inner_h = tsz.h + _BADGE_PAD_V * 2
                local buf_w   = inner_w + border * 2
                local buf_h   = inner_h + border * 2
                local bw = FrameContainer:new{
                    dimen      = Geom:new{ w = buf_w, h = buf_h },
                    bordersize = border,
                    color      = Blitbuffer.COLOR_DARK_GRAY,
                    background = Blitbuffer.COLOR_WHITE,
                    radius     = _BADGE_CORNER,
                    padding    = 0,
                    CenterContainer:new{
                        dimen = Geom:new{ w = inner_w, h = inner_h },
                        ptw,
                    },
                }
                local ok_buf, buf = pcall(Blitbuffer.new, buf_w, buf_h, Blitbuffer.TYPE_BB8A)
                if ok_buf and buf then
                    buf:fill(Blitbuffer.COLOR_WHITE)
                    bw:paintTo(buf, 0, 0)
                    self._fc_pages_bb = buf
                end
                bw:free()
            end

            if self._fc_overlay_series and self._fc_series_index then
                local stw = TextWidget:new{
                    text    = "#" .. self._fc_series_index,
                    face    = Font:getFace("cfont", _BADGE_FONT_SZ),
                    bold    = false,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }
                local tsz    = stw:getSize()
                local border = Size.border.thin
                local inner_w = tsz.w + _BADGE_PAD_H * 2
                local inner_h = tsz.h + _BADGE_PAD_V * 2
                local buf_w   = inner_w + border * 2
                local buf_h   = inner_h + border * 2
                local bw = FrameContainer:new{
                    dimen      = Geom:new{ w = buf_w, h = buf_h },
                    bordersize = border,
                    color      = Blitbuffer.COLOR_DARK_GRAY,
                    background = Blitbuffer.COLOR_WHITE,
                    radius     = _BADGE_CORNER,
                    padding    = 0,
                    CenterContainer:new{
                        dimen = Geom:new{ w = inner_w, h = inner_h },
                        stw,
                    },
                }
                local ok_buf, buf = pcall(Blitbuffer.new, buf_w, buf_h, Blitbuffer.TYPE_BB8A)
                if ok_buf and buf then
                    buf:fill(Blitbuffer.COLOR_WHITE)
                    bw:paintTo(buf, 0, 0)
                    self._fc_series_bb = buf
                end
                bw:free()
            end
        end

        if self._foldercover_processed    then return end
        if self.menu.no_refresh_covers    then return end
        if not self.do_cover_image        then return end
        if not M.isEnabled()              then return end
        if self.entry.is_file or self.entry.file or not self.mandatory then return end

        -- Defer the first folder-cover pass when the homescreen is visible.
        -- The HS has no folder covers so the user sees nothing during this tick;
        -- rendering is scheduled for the next tick so the HS paints first.
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

        -- Read all display settings once here so the build helpers make zero
        -- individual settings reads per cell.
        local label_mode  = M.getLabelMode()
        local show_name   = M.getShowName()
        local label_style = M.getLabelStyle()
        local label_pos   = M.getLabelPosition()

        -- ── Series group cover ────────────────────────────────────────────────
        if self.entry.is_series_group then
            if self._foldercover_processed then return end

            local sg_override_fp = _getCoverOverrides()[dir_path]
            if sg_override_fp then
                local bi = BookInfoManager:getBookInfo(sg_override_fp, true)
                if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
                        and not bi.ignore_cover
                        and not BookInfoManager.isCachedCoverInvalid(bi, self.menu.cover_specs)
                then
                    self:_setFolderCover(
                        { data = bi.cover_bb, w = bi.cover_w, h = bi.cover_h },
                        label_mode, show_name, label_style, label_pos)
                    return
                end
            end

            local items = self.entry.series_items or _sg_items_cache[dir_path]
            if items then
                for _, book_entry in ipairs(items) do
                    if book_entry.path then
                        local bi = BookInfoManager:getBookInfo(book_entry.path, true)
                        if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
                                and not bi.ignore_cover
                                and not BookInfoManager.isCachedCoverInvalid(bi, self.menu.cover_specs)
                        then
                            self:_setFolderCover(
                                { data = bi.cover_bb, w = bi.cover_w, h = bi.cover_h },
                                label_mode, show_name, label_style, label_pos)
                            return
                        end
                    end
                end
            end
            return
        end

        -- ── User-chosen cover override ────────────────────────────────────────
        local override_fp = _getCoverOverrides()[dir_path]
        if override_fp then
            local bi = BookInfoManager:getBookInfo(override_fp, true)
            if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
                    and not bi.ignore_cover
                    and not BookInfoManager.isCachedCoverInvalid(bi, self.menu.cover_specs)
            then
                self:_setFolderCover(
                    { data = bi.cover_bb, w = bi.cover_w, h = bi.cover_h },
                    label_mode, show_name, label_style, label_pos)
                return
            end
        end

        -- ── Static .cover.* image file ────────────────────────────────────────
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
                self:_setFolderCover(
                    { file = cover_file, w = w, h = h },
                    label_mode, show_name, label_style, label_pos)
                return
            end
        end

        -- ── First cached book cover inside the folder ─────────────────────────
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
                            { data = bi.cover_bb, w = bi.cover_w, h = bi.cover_h },
                            label_mode, show_name, label_style, label_pos)
                        return
                    end
                else
                    has_subfolders = true
                end
            end
        end

        -- ── Bookless folder: recursive scan or placeholder ────────────────────
        if not has_files then
            if has_subfolders and M.getSubfolderCover() and M.getRecursiveCover() then
                local cover = _findCoverRecursive(self.menu, dir_path, 1, 3, BookInfoManager)
                if cover then
                    self:_setFolderCover(cover, label_mode, show_name, label_style, label_pos)
                    return
                end
            end
            if M.getSubfolderCover() then
                self:_setEmptyFolderCover(label_mode, show_name, label_style, label_pos)
            end
            return
        end

        -- No cover found yet — register for async retry once BookInfoManager
        -- finishes extracting covers in the background.
        if self.menu and self.menu.items_to_update then
            if not self.menu._fc_pending_set then
                self.menu._fc_pending_set = {}
            end
            if not self.menu._fc_pending_set[self] then
                self.menu._fc_pending_set[self] = true
                table.insert(self.menu.items_to_update, self)
            end
        end
    end

    -- Builds and installs the cover widget into the cell.
    -- Display settings are passed in to avoid per-call settings reads.
    function MosaicMenuItem:_setFolderCover(img, label_mode, show_name, label_style, label_pos)
        self._foldercover_processed = true
        local border    = Size.border.thin
        local max_img_w = self.width  - _SPINE_W - border * 2
        local max_img_h = self.height - border * 2

        local img_options = {}
        if img.file then img_options.file  = img.file end
        if img.data then img_options.image = img.data end

        if M.getCoverMode() == "2_3" then
            local ratio = 2 / 3
            if max_img_w / max_img_h > ratio then
                img_options.height = max_img_h
                img_options.width  = math.floor(max_img_h * ratio)
            else
                img_options.width  = max_img_w
                img_options.height = math.floor(max_img_w / ratio)
            end
            img_options.stretch_limit_percentage = 50
        else
            img_options.scale_factor = math.min(max_img_w / img.w, max_img_h / img.h)
        end

        local image        = ImageWidget:new(img_options)
        local size         = image:getSize()
        local image_widget = FrameContainer:new{ padding = 0, bordersize = border, image }
        local spine        = _buildSpine(size.h)
        local cover_group  = HorizontalGroup:new{ align = "center", spine, image_widget }

        local cover_w    = _SPINE_W + size.w + border * 2
        local cover_h    = size.h  + border * 2
        local cover_dimen = Geom:new{ w = cover_w, h = cover_h }
        local cell_dimen  = Geom:new{ w = self.width, h = self.height }
        local cv_scale    = math.max(0.1, math.floor((cover_h / _BASE_COVER_H) * 10) / 10)

        local folder_name_widget = _buildLabel(self, size.w - _LATERAL_PAD * 2,
            size, border, cv_scale, label_mode, show_name, label_style, label_pos)
        local nbitems_widget = _buildBadge(self.mandatory, cover_dimen, cv_scale)

        local overlap = OverlapGroup:new{ dimen = cover_dimen, cover_group }
        if folder_name_widget then overlap[#overlap + 1] = folder_name_widget end
        if nbitems_widget     then overlap[#overlap + 1] = nbitems_widget     end

        local x_center    = math.floor((self.width  - cover_w) / 2)
        local y_center    = math.floor((self.height - cover_h) / 2)
        overlap.overlap_offset = { x_center - math.floor(_SPINE_W / 2), y_center }

        local widget = OverlapGroup:new{ dimen = cell_dimen, overlap }

        if self._underline_container[1] then self._underline_container[1]:free() end
        self._underline_container[1] = widget
    end

    -- Placeholder cover for bookless folders (only subfolders or empty).
    -- Layout mirrors _setFolderCover for visual consistency.
    function MosaicMenuItem:_setEmptyFolderCover(label_mode, show_name, label_style, label_pos)
        self._foldercover_processed = true
        local border    = Size.border.thin
        local max_img_w = self.width  - _SPINE_W - border * 2
        local max_img_h = self.height - border * 2

        local img_w, img_h
        if M.getCoverMode() == "2_3" then
            local ratio = 2 / 3
            if max_img_w / max_img_h > ratio then
                img_h = max_img_h; img_w = math.floor(max_img_h * ratio)
            else
                img_w = max_img_w; img_h = math.floor(max_img_w / ratio)
            end
        else
            img_w = max_img_w; img_h = max_img_h
        end

        -- _ICON_PATH and _ICON_EXISTS are module-level constants (computed once at load).
        local icon_size   = math.floor(math.min(img_w, img_h) * 0.5)
        local icon_widget = nil
        if _ICON_EXISTS then
            local ok_iw, iw = pcall(function()
                return CenterContainer:new{
                    dimen = Geom:new{ w = img_w, h = img_h },
                    ImageWidget:new{
                        file    = _ICON_PATH,
                        width   = icon_size,
                        height  = icon_size,
                        alpha   = true,
                        is_icon = true,
                    },
                }
            end)
            if ok_iw then icon_widget = iw end
        end

        local bg_canvas = FrameContainer:new{
            padding    = 0,
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
            dimen      = Geom:new{ w = img_w, h = img_h },
            icon_widget,
        }

        local size         = Geom:new{ w = img_w, h = img_h }
        local image_widget = FrameContainer:new{ padding = 0, bordersize = border, bg_canvas }
        local spine        = _buildSpine(size.h)
        local cover_group  = HorizontalGroup:new{ align = "center", spine, image_widget }

        local cover_w     = _SPINE_W + size.w + border * 2
        local cover_h     = size.h  + border * 2
        local cover_dimen = Geom:new{ w = cover_w, h = cover_h }
        local cell_dimen  = Geom:new{ w = self.width, h = self.height }
        local cv_scale    = math.max(0.1, math.floor((cover_h / _BASE_COVER_H) * 10) / 10)

        local folder_name_widget = _buildLabel(self, size.w - _LATERAL_PAD * 2,
            size, border, cv_scale, label_mode, show_name, label_style, label_pos)
        local nbitems_widget = _buildBadge(self.mandatory, cover_dimen, cv_scale)

        local overlap = OverlapGroup:new{ dimen = cover_dimen, cover_group }
        if folder_name_widget then overlap[#overlap + 1] = folder_name_widget end
        if nbitems_widget     then overlap[#overlap + 1] = nbitems_widget     end

        local x_center = math.floor((self.width  - cover_w) / 2)
        local y_center = math.floor((self.height - cover_h) / 2)
        overlap.overlap_offset = { x_center - math.floor(_SPINE_W / 2), y_center }

        local widget = OverlapGroup:new{ dimen = cell_dimen, overlap }
        if self._underline_container[1] then self._underline_container[1]:free() end
        self._underline_container[1] = widget
    end

    -- Binary-search the largest font size that fits the folder name in the
    -- available width without overflowing two lines. Result is cached in the
    -- module-level bounded two-generation cache (keyed by text+width+max_fs) so
    -- repeated renders after scroll/recycle skip all widget allocations.
    -- Capitalises the first letter of each word.
    function MosaicMenuItem:_getFolderNameWidget(available_w, dir_max_font_size)
        if not self._fc_display_text then
            local text = self.text
            if text:match("/$") then text = text:sub(1, -2) end
            text = text:gsub("(%S+)", function(w) return w:sub(1,1):upper() .. w:sub(2) end)
            self._fc_display_text = BD.directory(text)
        end
        local text      = self._fc_display_text
        local max_fs    = dir_max_font_size or _BASE_DIR_FS
        local cache_key = text .. "\0" .. available_w .. "\0" .. max_fs

        local cached_fs = _fsCacheGet(cache_key)
        if cached_fs then
            return TextBoxWidget:new{
                text      = text,
                face      = Font:getFace("cfont", cached_fs),
                width     = available_w,
                alignment = "center",
                bold      = true,
            }
        end

        -- Pass 1: find the largest font where the longest word still fits.
        -- Use font metrics directly (no widget allocation) when available;
        -- fall back to a single TextWidget measurement otherwise.
        local longest_word = ""
        for word in text:gmatch("%S+") do
            if #word > #longest_word then longest_word = word end
        end

        local dir_font_size = max_fs

        if longest_word ~= "" then
            local lo, hi = 8, dir_font_size
            while lo < hi do
                local mid = math.floor((lo + hi + 1) / 2)
                local tw = TextWidget:new{
                    text = longest_word,
                    face = Font:getFace("cfont", mid),
                    bold = true,
                }
                local word_w = tw:getWidth()
                tw:free()
                if word_w <= available_w then lo = mid else hi = mid - 1 end
            end
            dir_font_size = lo
        end

        -- Pass 2: find the largest font where the full text fits in two lines.
        -- A TextBoxWidget allocation here is unavoidable (we need line wrapping),
        -- but we keep the range tight thanks to Pass 1, minimising iterations.
        -- pcall guards against exotic text/font combinations that can raise in TextBoxWidget.
        local lo, hi = 8, dir_font_size
        while lo < hi do
            local mid  = math.floor((lo + hi + 1) / 2)
            local fits = false
            local ok, tbw = pcall(function()
                return TextBoxWidget:new{
                    text      = text,
                    face      = Font:getFace("cfont", mid),
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
            face      = Font:getFace("cfont", dir_font_size),
            width     = available_w,
            alignment = "center",
            bold      = true,
        }
    end

    -- onFocus: apply the pre-computed underline color (no settings read in the hot path).
    MosaicMenuItem._simpleui_fc_orig_onFocus = MosaicMenuItem.onFocus
    function MosaicMenuItem:onFocus()
        self._underline_container.color = self._fc_underline_color
            or (M.getHideUnderline() and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK)
        return true
    end

    -- paintTo: draw book-cover overlays (pages badge, series index badge).
    -- Folder covers are handled via widget replacement in _setFolderCover;
    -- this function only acts on regular book items.
    -- All badge geometry constants are pre-computed at module level.
    local orig_paintTo = MosaicMenuItem.paintTo
    MosaicMenuItem._simpleui_fc_orig_paintTo = orig_paintTo

    local function _round(v) return math.floor(v + 0.5) end

    function MosaicMenuItem:paintTo(bb, x, y)
        x = math.floor(x)
        y = math.floor(y)
        orig_paintTo(self, bb, x, y)

        if self.is_directory or self.file_deleted then return end

        -- Locate the cover FrameContainer in the widget tree.
        local target = self._cover_frame
            or (self[1] and self[1][1] and self[1][1][1])
        if not target or not target.dimen then return end

        local fw = target.dimen.w
        local fh = target.dimen.h
        local fx = x + _round((self.width  - fw) / 2)
        local fy = y + _round((self.height - fh) / 2)

        -- Geometry shared by both badges.
        local corner_sz  = math.floor(math.min(self.width, self.height) / 8)
        local bar_margin = math.floor((corner_sz - _BADGE_BAR_H) / 2)

        -- ── Pages badge (bottom-left) ─────────────────────────────────────────
        if self._fc_overlay_pages and self.status ~= "complete" then
            local page_bb = self._fc_pages_bb
            if page_bb then
                local rect_w = page_bb:getWidth()
                local rect_h = page_bb:getHeight()
                local bar_top    = fy + fh - corner_sz + bar_margin
                local bar_centre = bar_top + math.floor(_BADGE_BAR_H / 2)
                local badge_x    = fx + math.max(bar_margin, _BADGE_INSET)
                local badge_y
                if self.show_progress_bar then
                    badge_y = bar_top - _BADGE_BAR_GAP - rect_h
                else
                    badge_y = bar_centre - math.floor(rect_h / 2)
                            - math.max(bar_margin, _BADGE_INSET)
                end
                bb:blitFrom(page_bb, badge_x, badge_y, 0, 0, rect_w, rect_h)
            end
        end

        -- ── Series index badge (top-left) ─────────────────────────────────────
        if self._fc_overlay_series then
            local series_bb = self._fc_series_bb
            -- Fallback: if the blitbuffer was not pre-rendered (e.g. series_index
            -- was not yet in the BookList cache when update() ran), query
            -- BookInfoManager directly — same behaviour as the previous version.
            if not series_bb and self.filepath then
                local bi = BookInfoManager:getBookInfo(self.filepath, false)
                if bi and bi.series and bi.series_index then
                    local stw = TextWidget:new{
                        text    = "#" .. bi.series_index,
                        face    = Font:getFace("cfont", _BADGE_FONT_SZ),
                        bold    = false,
                        fgcolor = Blitbuffer.COLOR_BLACK,
                    }
                    local tsz    = stw:getSize()
                    local border  = Size.border.thin
                    local inner_w = tsz.w + _BADGE_PAD_H * 2
                    local inner_h = tsz.h + _BADGE_PAD_V * 2
                    local buf_w   = inner_w + border * 2
                    local buf_h   = inner_h + border * 2
                    local bw = FrameContainer:new{
                        dimen      = Geom:new{ w = buf_w, h = buf_h },
                        bordersize = border,
                        color      = Blitbuffer.COLOR_DARK_GRAY,
                        background = Blitbuffer.COLOR_WHITE,
                        radius     = _BADGE_CORNER,
                        padding    = 0,
                        CenterContainer:new{
                            dimen = Geom:new{ w = inner_w, h = inner_h },
                            stw,
                        },
                    }
                    local ok_buf, buf = pcall(Blitbuffer.new, buf_w, buf_h, Blitbuffer.TYPE_BB8A)
                    if ok_buf and buf then
                        buf:fill(Blitbuffer.COLOR_WHITE)
                        bw:paintTo(buf, 0, 0)
                        -- Cache for future paintTo calls and free the widget.
                        self._fc_series_bb = buf
                        series_bb = buf
                    end
                    bw:free()
                end
            end
            if series_bb then
                local rect_w = series_bb:getWidth()
                local rect_h = series_bb:getHeight()
                local badge_x
                if BD.mirroredUILayout() then
                    badge_x = fx + fw - math.max(bar_margin, _BADGE_INSET) - rect_w
                else
                    badge_x = fx + math.max(bar_margin, _BADGE_INSET)
                end
                local badge_y = fy + math.max(bar_margin, _BADGE_INSET)
                bb:blitFrom(series_bb, badge_x, badge_y, 0, 0, rect_w, rect_h)
            end
        end
    end

    local orig_free = MosaicMenuItem.free
    MosaicMenuItem._simpleui_fc_orig_free = orig_free
    function MosaicMenuItem:free()
        if self._fc_pages_bb  then self._fc_pages_bb:free();  self._fc_pages_bb  = nil end
        if self._fc_series_bb then self._fc_series_bb:free(); self._fc_series_bb = nil end
        if orig_free then orig_free(self) end
    end

    _installItemCache()
    _installSeriesGrouping()
    _installFileDialogButton(BookInfoManager)

    -- -----------------------------------------------------------------------
    -- ListMenuItem patch — cover images for virtual folders in list_image_meta.
    -- -----------------------------------------------------------------------

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

            -- ── Virtual meta-leaf (browsemeta) ────────────────────────────────
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

            -- ── Series group ──────────────────────────────────────────────────
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

            -- ── Real folder ───────────────────────────────────────────────────

            -- 1. User-chosen cover override.
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

            -- 3. First cached book cover — result cached per directory to avoid
            --    repeating the lfs.dir + per-file lfs.attributes walk on every
            --    reader→HS cycle.
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
                                    local entry = {
                                        cover_bb      = bi.cover_bb,
                                        cover_w       = bi.cover_w,
                                        cover_h       = bi.cover_h,
                                        has_cover     = true,
                                        cover_fetched = true,
                                    }
                                    _lmcSet(dir_path, entry)
                                    self:_setListFolderCover(entry)
                                    return
                                end
                            end
                        end
                    end
                end
                FileChooser.show_filter = saved_filter
                _lmcSet(dir_path, false)
            end

            -- 4. Nothing yet — register for async retry when BookInfoManager
            --    finishes extracting covers in the background.
            if self.menu and self.menu.items_to_update then
                if not self.menu._fc_pending_set then
                    self.menu._fc_pending_set = {}
                end
                if not self.menu._fc_pending_set[self] then
                    self.menu._fc_pending_set[self] = true
                    table.insert(self.menu.items_to_update, self)
                end
            end
        end

        -- Renders a cover thumbnail on the left, folder name + item count on the right.
        function ListMenuItem:_setListFolderCover(bookinfo)
            self._foldercover_processed = true

            local underline_h = self.underline_h or 1
            local dimen = Geom:new{
                w = self.width,
                h = self.height - 2 * underline_h,
            }

            local border_size = Size.border.thin
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

            local pad       = _LATERAL_PAD  -- already Screen:scaleBySize(10) at module level
            local main_w    = dimen.w - img_size - pad * 2
            local font_size = (self.menu and self.menu.font_size) or 20
            local info_size = math.max(10, font_size - 4)

            local wname = TextBoxWidget:new{
                text                          = BD.directory(self.text),
                face                          = Font:getFace("cfont", font_size),
                width                         = main_w,
                alignment                     = "left",
                bold                          = true,
                height                        = dimen.h,
                height_adjust                 = true,
                height_overflow_show_ellipsis = true,
            }
            local wcount = TextWidget:new{
                text = self.mandatory or "",
                face = Font:getFace("infont", info_size),
            }

            local wmain = LeftContainer:new{
                dimen = Geom:new{ w = main_w, h = dimen.h },
                VerticalGroup:new{
                    wname,
                    VerticalSpan:new{ width = _EDGE_MARGIN * 2 },  -- ~scaleBySize(2)
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
        end
    end
end

-- ---------------------------------------------------------------------------
-- Uninstall — restores all patched methods and releases module-level caches.
-- ---------------------------------------------------------------------------

function M.uninstall()
    local MosaicMenuItem = _getMosaicMenuItemAndPatch()
    if not MosaicMenuItem then return end
    if not MosaicMenuItem._simpleui_fc_patched then return end

    if MosaicMenuItem._simpleui_fc_orig_update then
        MosaicMenuItem.update = MosaicMenuItem._simpleui_fc_orig_update
        MosaicMenuItem._simpleui_fc_orig_update = nil
    end
    if MosaicMenuItem._simpleui_fc_orig_paintTo then
        MosaicMenuItem.paintTo = MosaicMenuItem._simpleui_fc_orig_paintTo
        MosaicMenuItem._simpleui_fc_orig_paintTo = nil
    end
    if MosaicMenuItem._simpleui_fc_orig_free then
        MosaicMenuItem.free = MosaicMenuItem._simpleui_fc_orig_free
        MosaicMenuItem._simpleui_fc_orig_free = nil
    end
    if MosaicMenuItem._simpleui_fc_orig_onFocus then
        MosaicMenuItem.onFocus = MosaicMenuItem._simpleui_fc_orig_onFocus
        MosaicMenuItem._simpleui_fc_orig_onFocus = nil
    end
    if MosaicMenuItem._simpleui_fc_orig_init ~= nil then
        MosaicMenuItem.init = MosaicMenuItem._simpleui_fc_orig_init
        MosaicMenuItem._simpleui_fc_orig_init = nil
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

    _uninstallItemCache()
    _uninstallSeriesGrouping()
    _uninstallFileDialogButton()

    for k in pairs(_cover_file_cache)        do _cover_file_cache[k]        = nil end
    for k in pairs(_cfc_b)                  do _cfc_b[k]                   = nil end
    _cfc_cnt = 0
    for k in pairs(_lm_dir_cover_cache)     do _lm_dir_cover_cache[k]     = nil end
    for k in pairs(_lmc_b)                  do _lmc_b[k]                   = nil end
    _lmc_cnt = 0
    for k in pairs(_fs_cache_a)             do _fs_cache_a[k]              = nil end
    for k in pairs(_fs_cache_b)             do _fs_cache_b[k]              = nil end
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
