-- sui_foldercovers.lua — Simple UI
-- Folder cover art and book cover overlays for the CoverBrowser mosaic view.
--
-- Folder covers:
--   - Vertical spine lines on the left (module_collections style)
--   - Folder name overlay at bottom with padding
--   - Book count badge at top-right, black circle
--   - Hide selection underline option
--
-- Book cover overlays:
--   - Pages badge ("123 p.") — white rect at bottom-left of book covers
--   - Series index badge ("#N") — white rect at top-left of book covers
--
-- Series grouping:
--   - Virtual folders for multi-book series in the mosaic view
--   - Back button / titlebar fully integrated with SimpleUI navigation
--
-- Item cache:
--   - 2 000-entry LRU for FileChooser:getListItem()
--
-- Settings keys:
--   simpleui_fc_enabled          — folder covers master toggle (default false)
--   simpleui_fc_show_name        — show folder name overlay (default true)
--   simpleui_fc_hide_underline   — hide focus underline (default true)
--   simpleui_fc_overlay_pages    — pages badge on book covers (default true)
--   simpleui_fc_overlay_series   — series index badge on book covers (default false)
--   simpleui_fc_series_grouping  — group books by series into virtual folders (default false)
--   simpleui_fc_item_cache       — 2 000-entry item cache (default true)

local _ = require("gettext")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

-- ---------------------------------------------------------------------------
-- Widget requires — at module level so require() cache lookup happens once,
-- not on every cell render.
-- ---------------------------------------------------------------------------

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
local OverlapGroup    = require("ui/widget/overlapgroup")
local RightContainer  = require("ui/widget/container/rightcontainer")
local Screen          = require("device").screen
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local TopContainer    = require("ui/widget/container/topcontainer")

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

local SK = {
    enabled          = "simpleui_fc_enabled",
    show_name        = "simpleui_fc_show_name",
    hide_underline   = "simpleui_fc_hide_underline",
    label_style      = "simpleui_fc_label_style",
    label_position   = "simpleui_fc_label_position",
    badge_position   = "simpleui_fc_badge_position",
    badge_hidden     = "simpleui_fc_badge_hidden",
    cover_mode       = "simpleui_fc_cover_mode",
    label_mode       = "simpleui_fc_label_mode",
    -- Pages badge
    overlay_pages    = "simpleui_fc_overlay_pages",
    -- Series index badge
    overlay_series   = "simpleui_fc_overlay_series",
    -- Series grouping into virtual folders
    series_grouping  = "simpleui_fc_series_grouping",
    -- Item cache
    item_cache       = "simpleui_fc_item_cache",
    -- Subfolder / bookless-folder covers
    subfolder_cover  = "simpleui_fc_subfolder_cover",
    recursive_cover  = "simpleui_fc_recursive_cover",
    -- Folder name text scale (integer %, default 100)
    label_scale      = "simpleui_fc_label_scale",
}

local M = {}

-- Forward-declare series-grouping state so all functions in this file
-- (including _openSeriesGroupCoverPicker and _installFileDialogButton,
-- which are defined before the series-grouping section) can reference
-- these as upvalues rather than globals.
local _sg_current     = nil   -- active virtual folder state (or nil)
local _sg_items_cache = {}    -- virtual_path → {series_items}

function M.isEnabled()    return G_reader_settings:isTrue(SK.enabled)  end
function M.setEnabled(v)  G_reader_settings:saveSetting(SK.enabled, v) end

local function _getFlag(key)
    return G_reader_settings:readSetting(key) ~= false
end
local function _setFlag(key, v) G_reader_settings:saveSetting(key, v) end

function M.getShowName()       return _getFlag(SK.show_name)      end
function M.setShowName(v)      _setFlag(SK.show_name, v)          end
function M.getHideUnderline()  return _getFlag(SK.hide_underline) end
function M.setHideUnderline(v) _setFlag(SK.hide_underline, v)     end

-- "alpha" (default) = semitransparent white overlay
-- "frame" = solid grey frame matching the cover border style
function M.getLabelStyle()
    return G_reader_settings:readSetting(SK.label_style) or "alpha"
end
function M.setLabelStyle(v) G_reader_settings:saveSetting(SK.label_style, v) end

-- "bottom" (default) = anchored to bottom of cover
-- "center" = vertically centred on cover
-- "top"    = anchored to top of cover
function M.getLabelPosition()
    return G_reader_settings:readSetting(SK.label_position) or "bottom"
end
function M.setLabelPosition(v) G_reader_settings:saveSetting(SK.label_position, v) end

-- "top" (default) = badge at top-right
-- "bottom"        = badge at bottom-right
function M.getBadgePosition()
    return G_reader_settings:readSetting(SK.badge_position) or "top"
end
function M.setBadgePosition(v) G_reader_settings:saveSetting(SK.badge_position, v) end

-- true = badge hidden entirely
function M.getBadgeHidden() return G_reader_settings:isTrue(SK.badge_hidden) end
function M.setBadgeHidden(v) G_reader_settings:saveSetting(SK.badge_hidden, v) end

-- "default" = proportional scale-to-fit
-- "2_3"     = force 2:3 aspect ratio with stretch_limit 50
function M.getCoverMode()
    return G_reader_settings:readSetting(SK.cover_mode) or "default"
end
function M.setCoverMode(v) G_reader_settings:saveSetting(SK.cover_mode, v) end

-- "overlay" (default) = folder name overlaid on the cover image
-- "hidden"            = no label at all
function M.getLabelMode()
    return G_reader_settings:readSetting(SK.label_mode) or "overlay"
end
function M.setLabelMode(v) G_reader_settings:saveSetting(SK.label_mode, v) end

-- Folder name text scale: integer % stored in SK.label_scale, default 100.
-- Returns a float multiplier (e.g. 1.0, 1.2) for use in _buildLabel.
local _FC_SCALE_MIN = 50
local _FC_SCALE_MAX = 200
local _FC_SCALE_DEF = 100
local _FC_SCALE_STEP = 10
M.FC_LABEL_SCALE_MIN  = _FC_SCALE_MIN
M.FC_LABEL_SCALE_MAX  = _FC_SCALE_MAX
M.FC_LABEL_SCALE_DEF  = _FC_SCALE_DEF
M.FC_LABEL_SCALE_STEP = _FC_SCALE_STEP

local function _clampFCScale(n)
    return math.max(_FC_SCALE_MIN, math.min(_FC_SCALE_MAX, math.floor(n)))
end

function M.getLabelScalePct()
    local v = G_reader_settings:readSetting(SK.label_scale)
    local n = tonumber(v)
    if not n then return _FC_SCALE_DEF end
    return _clampFCScale(n)
end

function M.getLabelScale()
    return M.getLabelScalePct() / 100
end

function M.setLabelScale(pct)
    G_reader_settings:saveSetting(SK.label_scale, _clampFCScale(pct))
end

-- Pages badge getter / setter (default true)
function M.getOverlayPages() return G_reader_settings:readSetting(SK.overlay_pages) ~= false end
function M.setOverlayPages(v) _setFlag(SK.overlay_pages, v) end

-- Series index badge getter / setter (default false)
function M.getOverlaySeries() return G_reader_settings:isTrue(SK.overlay_series) end
function M.setOverlaySeries(v) _setFlag(SK.overlay_series, v) end

-- Series grouping into virtual folders (default false)
function M.getSeriesGrouping() return G_reader_settings:isTrue(SK.series_grouping) end
function M.setSeriesGrouping(v) _setFlag(SK.series_grouping, v) end

-- Item cache (default on)
function M.getItemCache() return G_reader_settings:readSetting(SK.item_cache) ~= false end
function M.setItemCache(v) _setFlag(SK.item_cache, v) end

-- Placeholder cover for bookless folders (default off).
-- When enabled, folders with no direct ebooks display a generic folder icon
-- instead of being left blank in the mosaic view.
function M.getSubfolderCover() return G_reader_settings:isTrue(SK.subfolder_cover) end
function M.setSubfolderCover(v) _setFlag(SK.subfolder_cover, v) end

-- Recursive cover search (default off). Requires subfolder_cover to be on.
-- When enabled, SimpleUI scans up to 3 levels of subfolders for a cached
-- book cover to use as the folder's representative image.
function M.getRecursiveCover() return G_reader_settings:isTrue(SK.recursive_cover) end
function M.setRecursiveCover(v) _setFlag(SK.recursive_cover, v) end

-- ---------------------------------------------------------------------------
-- Cover file discovery — identical to original patch
-- ---------------------------------------------------------------------------

local _COVER_EXTS = { ".jpg", ".jpeg", ".png", ".webp", ".gif" }

local function findCover(dir_path)
    local base = dir_path .. "/.cover"
    for i = 1, #_COVER_EXTS do
        local fname = base .. _COVER_EXTS[i]
        if lfs.attributes(fname, "mode") == "file" then return fname end
    end
end

-- ---------------------------------------------------------------------------
-- Constants — computed once at load time from device DPI.
-- Scaled at render time by a factor derived from actual cover height,
-- mirroring the pattern used in module_collections / module_books_shared.
-- ---------------------------------------------------------------------------

local _BASE_COVER_H = math.floor(Screen:scaleBySize(96))  -- reference cover height (mosaic cell)
local _BASE_NB_SIZE = Screen:scaleBySize(10)  -- badge circle diameter
local _BASE_NB_FS   = Screen:scaleBySize(4)   -- badge font size
local _BASE_DIR_FS  = Screen:scaleBySize(5)   -- folder name max font size

-- Spine constants — duas linhas verticais, ambas do mesmo cinza escuro.
local _EDGE_THICK  = math.max(1, Screen:scaleBySize(3))
local _EDGE_MARGIN = math.max(1, Screen:scaleBySize(1))
local _SPINE_W     = _EDGE_THICK * 2 + _EDGE_MARGIN * 2
local _SPINE_COLOR = Blitbuffer.gray(0.70)

-- Padding constants — computed once.
local _LATERAL_PAD        = Screen:scaleBySize(10)
local _VERTICAL_PAD       = Screen:scaleBySize(4)
local _BADGE_MARGIN_BASE  = Screen:scaleBySize(8)
local _BADGE_MARGIN_R_BASE = Screen:scaleBySize(4)

local _LABEL_ALPHA = 0.75

-- ---------------------------------------------------------------------------
-- Patch helpers
-- ---------------------------------------------------------------------------

-- Returns MosaicMenuItem and userpatch, or nil, nil on failure.
local function _getMosaicMenuItemAndPatch()
    local ok_mm, MosaicMenu = pcall(require, "mosaicmenu")
    if not ok_mm or not MosaicMenu then return nil, nil end
    local ok_up, userpatch = pcall(require, "userpatch")
    if not ok_up or not userpatch then return nil, nil end
    return userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem"), userpatch
end

-- ---------------------------------------------------------------------------
-- Build helpers — each responsible for one visual layer of the cover widget.
-- ---------------------------------------------------------------------------

-- Builds two vertical spine lines on the left of the cover, mesma cor.
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
        return OverlapGroup:new{
            dimen = Geom:new{ w = _EDGE_THICK, h = img_h },
            line,
        }
    end

    return HorizontalGroup:new{
        align = "center",
        spineLine(h2, y2),
        HorizontalSpan:new{ width = _EDGE_MARGIN },
        spineLine(h1, y1),
        HorizontalSpan:new{ width = _EDGE_MARGIN },
    }
end

-- Builds the folder-name label overlay (OverlapGroup over the image area).
-- Returns nil when label mode is not "overlay" or show_name is disabled.
local function _buildLabel(item, available_w, size, border, cv_scale)
    if M.getLabelMode() ~= "overlay" then return nil end
    if not M.getShowName() then return nil end

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
    if M.getLabelStyle() == "alpha" then
        label_inner = AlphaContainer:new{ alpha = _LABEL_ALPHA, frame }
    else
        label_inner = frame
    end

    local name_og = OverlapGroup:new{ dimen = img_dimen }
    local pos = M.getLabelPosition()
    if pos == "center" then
        name_og[1] = CenterContainer:new{
            dimen         = img_only,
            label_inner,
            overlap_align = "center",
        }
    elseif pos == "top" then
        -- Shift up by border so the label's bottom border overlaps the
        -- book frame's top border — no visible gap or double line.
        name_og[1] = TopContainer:new{
            dimen         = img_dimen,
            label_inner,
            overlap_align = "center",
        }
    else  -- "bottom" (default)
        -- Shift down by border so the label's top border overlaps the
        -- book frame's bottom border — no visible gap or double line.
        name_og[1] = BottomContainer:new{
            dimen         = img_dimen,
            label_inner,
            overlap_align = "center",
        }
    end
    name_og.overlap_offset = { _SPINE_W, 0 }
    return name_og
end

-- Builds the book-count badge (circular, top- or bottom-right of cover).
-- Returns nil when there is no count to display or the badge is hidden.
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
    else  -- "top" (default)
        return TopContainer:new{
            dimen         = cover_dimen,
            padding_top   = badge_margin,
            inner,
            overlap_align = "center",
        }
    end
end

-- ---------------------------------------------------------------------------
-- Cover override — settings-based, identical pattern to module_collections.
-- Key: "simpleui_fc_covers" → table { [dir_path] = book_filepath }
-- ---------------------------------------------------------------------------

local _FC_COVERS_KEY = "simpleui_fc_covers"

local function _getCoverOverrides()
    return G_reader_settings:readSetting(_FC_COVERS_KEY) or {}
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

-- Forces re-render of the folder item by clearing the processed flag.
local function _invalidateFolderItem(menu, dir_path)
    if not menu or not menu.layout then return end
    for _, row in ipairs(menu.layout) do
        for _, item in ipairs(row) do
            if item._foldercover_processed
                and item.entry and item.entry.path == dir_path then
                item._foldercover_processed = false
            end
        end
    end
    menu:updateItems(1, true)
end

-- ---------------------------------------------------------------------------
-- Recursive cover search helper.
-- Scans dir_path up to max_depth levels looking for a cached book cover.
-- Returns a cover table { data, w, h } on success, or nil if nothing found.
-- BookInfoManager is passed in to avoid a module-level require.
-- ---------------------------------------------------------------------------
local function _findCoverRecursive(menu, dir_path, depth, max_depth, BookInfoManager)
    if depth > max_depth then return nil end

    -- Temporarily clear the status filter so that books filtered out by the
    -- user's "show only new/reading" setting are still visible for cover lookup.
    -- The filter governs what is *displayed*, not what can supply cover art.
    local FileChooser    = require("ui/widget/filechooser")
    local saved_filter   = FileChooser.show_filter
    FileChooser.show_filter = {}
    menu._dummy = true
    local entries = menu:genItemTableFromPath(dir_path)
    menu._dummy = false
    FileChooser.show_filter = saved_filter
    if not entries then return nil end

    -- First pass: try files at this level.
    for _, entry in ipairs(entries) do
        if entry.is_file or entry.file then
            local bookinfo = BookInfoManager:getBookInfo(entry.path, true)
            if bookinfo
                and bookinfo.cover_bb
                and bookinfo.has_cover
                and bookinfo.cover_fetched
                and not bookinfo.ignore_cover
                and not BookInfoManager.isCachedCoverInvalid(bookinfo, menu.cover_specs)
            then
                return { data = bookinfo.cover_bb, w = bookinfo.cover_w, h = bookinfo.cover_h }
            end
        end
    end

    -- Second pass: recurse into subfolders.
    for _, entry in ipairs(entries) do
        if not entry.is_file and not entry.file then
            local found = _findCoverRecursive(menu, entry.path, depth + 1, max_depth, BookInfoManager)
            if found then return found end
        end
    end

    return nil
end

-- Opens a ButtonDialog listing the books inside dir_path so the user can
-- pick which one's cover to use.

-- Collects all book entries under dir_path, optionally recursing into
-- subfolders up to max_depth levels when recursive cover scan is enabled.
local function _collectBooks(menu, dir_path, depth, max_depth, out)
    -- Strip status filter so finished/on-hold books are included as cover candidates
    -- even when the browser is set to show only new/reading books.
    local FileChooser    = require("ui/widget/filechooser")
    local saved_filter   = FileChooser.show_filter
    FileChooser.show_filter = {}
    menu._dummy = true
    local entries = menu:genItemTableFromPath(dir_path)
    menu._dummy = false
    FileChooser.show_filter = saved_filter
    if not entries then return end
    for _, entry in ipairs(entries) do
        if entry.is_file or entry.file then
            out[#out + 1] = entry
        elseif depth < max_depth and not entry.is_file and not entry.file then
            _collectBooks(menu, entry.path, depth + 1, max_depth, out)
        end
    end
end

-- Opens the cover picker for a virtual series group.
-- Uses the cached series_items directly instead of scanning the (non-existent)
-- virtual directory on disk.
local function _openSeriesGroupCoverPicker(vpath, menu, BookInfoManager)
    local UIManager    = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage  = require("ui/widget/infomessage")

    local series_items = _sg_items_cache[vpath]
    if not series_items or #series_items == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No books found in this series."), timeout = 2 })
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
            -- Invalidate so the mosaic re-fetches the auto cover.
            _invalidateFolderItem(menu, vpath)
        end,
    }}

    for _, item in ipairs(series_items) do
        local fp = item.path
        if fp then
            local bookinfo = BookInfoManager:getBookInfo(fp, false)
            local title = (bookinfo and bookinfo.title and bookinfo.title ~= "")
                and bookinfo.title
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

    picker = ButtonDialog:new{
        title   = _("Series cover"),
        buttons = buttons,
    }
    UIManager:show(picker)
end

local function _openFolderCoverPicker(dir_path, menu, BookInfoManager)
    local UIManager    = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage  = require("ui/widget/infomessage")

    -- When recursive cover scan is enabled, collect books from subfolders too
    -- (same max_depth=3 used by the automatic scan), so the user can pick from
    -- the same set of covers that the auto-scan finds.
    local books = {}
    local max_depth = M.getRecursiveCover() and 3 or 1
    _collectBooks(menu, dir_path, 1, max_depth, books)

    if #books == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No books found in this folder."), timeout = 2 })
        return
    end

    local overrides = _getCoverOverrides()
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
        local fp = entry.path
        local bookinfo = BookInfoManager:getBookInfo(fp, false)
        local title = (bookinfo and bookinfo.title and bookinfo.title ~= "")
            and bookinfo.title
            or (fp:match("([^/]+)%.[^%.]+$") or fp)
        -- When the book is in a subfolder, append the relative path so the
        -- user can tell apart books with the same title in different subfolders.
        local rel = fp:sub(#dir_path + 2) -- strip "dir_path/" prefix
        local subfolder = rel:match("^(.+)/[^/]+$") -- everything before the filename
        local label = subfolder and (title .. "  [" .. subfolder .. "]") or title
        local _fp = fp
        buttons[#buttons + 1] = {{
            text = ((cur_override == _fp) and "✓ " or "  ") .. label,
            callback = function()
                UIManager:close(picker)
                _saveCoverOverride(dir_path, _fp)
                _invalidateFolderItem(menu, dir_path)
            end,
        }}
    end

    buttons[#buttons + 1] = {{
        text = _("Cancel"),
        callback = function() UIManager:close(picker) end,
    }}

    picker = ButtonDialog:new{
        title   = _("Folder cover"),
        buttons = buttons,
    }
    UIManager:show(picker)
end

-- Injects "Set folder cover…" into the long-press file dialog for directories.
local function _installFileDialogButton(BookInfoManager)
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok_fm or not FileManager then return end

    -- addFileDialogButtons must be called on the class (it stores on the class table,
    -- which is then checked by every instance's showFileDialog). KOReader's API
    -- expects the method called as FileManager:addFileDialogButtons(...).
    FileManager:addFileDialogButtons("simpleui_fc_cover",
        function(file, is_file, _book_props)
            if is_file then return nil end
            if not M.isEnabled() then return nil end
            -- Check if this is a virtual series-group folder.
            -- Virtual paths are not on disk, so we use the cached series_items
            -- instead of scanning the directory.
            local is_virtual_series = _sg_items_cache[file] ~= nil
            return {{
                text = is_virtual_series and _("Set series cover…") or _("Set folder cover…"),
                callback = function()
                    local UIManager = require("ui/uimanager")
                    local fc = FileManager.instance and FileManager.instance.file_chooser
                    if fc and fc.file_dialog then
                        UIManager:close(fc.file_dialog)
                    end
                    if fc then
                        if is_virtual_series then
                            _openSeriesGroupCoverPicker(file, fc, BookInfoManager)
                        else
                            _openFolderCoverPicker(file, fc, BookInfoManager)
                        end
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
-- Item cache — 2 000-entry LRU for FileChooser:getListItem()
-- Avoids redundant item rebuilds while scrolling a large library.
-- Installed/uninstalled independently of the folder-covers feature toggle.
-- ---------------------------------------------------------------------------

local _cache       = {}
local _cache_count = 0
local _CACHE_MAX   = 1000
local _orig_getListItem = FileChooser.getListItem

local function _installItemCache()
    if FileChooser._simpleui_fc_cache_patched then return end
    FileChooser._simpleui_fc_cache_patched = true
    FileChooser.getListItem = function(fc, dirpath, f, fullpath, attributes, collate)
        if not M.getItemCache() then
            return _orig_getListItem(fc, dirpath, f, fullpath, attributes, collate)
        end
        local filter_raw = fc.show_filter and fc.show_filter.status or ""
        local filter
        if type(filter_raw) == "table" then
            -- Newer KOReader stores active status filters as a set table.
            -- Sort keys so equivalent filter states produce the same cache key.
            local parts = {}
            for k, v in pairs(filter_raw) do
                if v then
                    parts[#parts + 1] = tostring(k)
                end
            end
            table.sort(parts)
            filter = table.concat(parts, "\1")
        else
            filter = tostring(filter_raw)
        end
        local collate_id = (collate and (collate.id or collate.text)) or ""
        local key = tostring(dirpath) .. "\0" .. tostring(f) .. "\0"
                 .. tostring(fullpath) .. "\0" .. filter .. "\0"
                 .. tostring(collate_id)
        if not _cache[key] then
            if _cache_count >= _CACHE_MAX then
                _cache = {}
                _cache_count = 0
            end
            _cache[key] = _orig_getListItem(fc, dirpath, f, fullpath, attributes, collate)
            _cache_count = _cache_count + 1
        end
        return _cache[key]
    end
end

local function _uninstallItemCache()
    if not FileChooser._simpleui_fc_cache_patched then return end
    FileChooser.getListItem = _orig_getListItem
    FileChooser._simpleui_fc_cache_patched = nil
    _cache = {}
    _cache_count = 0
end

-- Invalidate cache (called after settings changes that affect item appearance).
function M.invalidateCache()
    _cache = {}
    _cache_count = 0
end

-- ---------------------------------------------------------------------------
-- Series grouping — virtual folders for multi-book series
-- ---------------------------------------------------------------------------
--
-- State persisted across refreshes. All access is from the main UI thread.
-- _sg_current holds the active virtual folder state while browsing a series;
-- nil means we are in a real filesystem folder.
--
-- Fields of _sg_current:
--   series_name      (string)  — name of the series being browsed
--   parent_path      (string)  — real filesystem path the user navigated from
--   should_restore   (bool)    — true after exiting the virtual folder,
--                                signals updateItems to restore focus
-- ---------------------------------------------------------------------------

-- _sg_current and _sg_items_cache are forward-declared above near 'local M = {}'.

-- ---------------------------------------------------------------------------
-- _sgProcessItemTable: group series books into virtual folder items.
-- Modifies item_table in place. Returns immediately when grouping is not
-- applicable (disabled, dialog chooser, view already grouped, etc.).
-- ---------------------------------------------------------------------------
local function _sgProcessItemTable(item_table, file_chooser)
    if not M.getSeriesGrouping() then return end
    if not file_chooser or not item_table then return end
    -- Never re-group inside a virtual series view.
    if item_table._sg_is_series_view then return end
    -- Skip folder-chooser dialogs (show_current_dir_for_hold is set).
    if file_chooser.show_current_dir_for_hold then return end

    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok_bim or not BookInfoManager then return end

    local series_map   = {}   -- series_name → group_item
    local processed    = {}   -- final flat list (goes-up + dirs + files)
    local book_count   = 0
    local no_series_count = 0

    for _, item in ipairs(item_table) do
        if item.is_go_up then
            table.insert(processed, item)
        else
            -- Ensure safe sort keys for all items.
            if not item.sort_percent     then item.sort_percent     = 0     end
            if not item.percent_finished then item.percent_finished = 0     end
            if not item.opened           then item.opened           = false end

            local handled = false

            if (item.is_file or item.file) and item.path then
                book_count = book_count + 1
                local doc_props = item.doc_props
                    or BookInfoManager:getDocProps(item.path)
                -- Filter sentinel value used by series collate for nil.
                local sname = doc_props and doc_props.series
                if sname and sname ~= "\u{FFFF}" then
                    item._sg_series_index = doc_props.series_index or 0
                    if not series_map[sname] then
                        -- Create the virtual folder item.
                        local base_path = item.path:match("(.*/)") or ""
                        local group_attr = {}
                        if item.attr then
                            for k, v in pairs(item.attr) do
                                group_attr[k] = v
                            end
                        end
                        group_attr.mode = "directory"
                        local vpath = base_path .. sname
                        local group_item = {
                            text          = sname,
                            is_file       = false,
                            is_directory  = true,
                            is_series_group = true,
                            path          = vpath,
                            series_items  = { item },
                            attr          = group_attr,
                            mode          = "directory",
                            sort_percent  = item.sort_percent,
                            percent_finished = item.percent_finished,
                            opened        = item.opened,
                            doc_props     = item.doc_props or {
                                series       = sname,
                                series_index = 0,
                                display_title = sname,
                            },
                            suffix        = item.suffix,
                        }
                        series_map[sname]    = group_item
                        group_item._sg_list_index = #processed + 1
                        table.insert(processed, group_item)
                    else
                        table.insert(series_map[sname].series_items, item)
                    end
                    handled = true
                else
                    no_series_count = no_series_count + 1
                end
            end

            if not handled then
                table.insert(processed, item)
            end
        end
    end

    -- Count distinct series (short-circuit after 2).
    local series_count = 0
    for _ in pairs(series_map) do
        series_count = series_count + 1
        if series_count > 1 then break end
    end

    -- If every book is from the same single series the folder is already
    -- organized — skip grouping to avoid wrapping it in a redundant layer.
    if series_count == 1 and no_series_count == 0 and book_count > 0 then
        return
    end

    -- Post-process: ungroup singletons, finalize multi-book groups.
    for sname, group in pairs(series_map) do
        local items = group.series_items
        if #items == 1 then
            -- Replace the virtual folder with the single book in-place.
            local idx = group._sg_list_index
            if idx and processed[idx] == group then
                processed[idx] = items[1]
            end
        else
            -- Sort books by series index.
            table.sort(items, function(a, b)
                return (a._sg_series_index or 0) < (b._sg_series_index or 0)
            end)
            group.mandatory = tostring(#items) .. " \u{F016}"
            -- Cache items so cover lookup and re-entry can find them.
            _sg_items_cache[group.path] = items
        end
    end

    -- Re-sort the full processed list using the FileChooser sort function,
    -- so virtual folder items slot into the correct position among real dirs.
    local ok_collate, collate = pcall(function()
        return file_chooser:getCollate()
    end)
    local collate_obj = ok_collate and collate or nil
    local reverse     = G_reader_settings:isTrue("reverse_collate")
    local sort_func
    local ok_sf = pcall(function()
        sort_func = file_chooser:getSortingFunction(collate_obj, reverse)
    end)
    local mixed = G_reader_settings:isTrue("collate_mixed")
        and collate_obj and collate_obj.can_collate_mixed

    local final = {}

    if mixed then
        -- Mixed mode: single sorted pass (dirs and files together).
        local up_item
        local to_sort = {}
        for _, item in ipairs(processed) do
            if item.is_go_up then up_item = item
            else table.insert(to_sort, item) end
        end
        if sort_func then
            pcall(table.sort, to_sort, sort_func)
        end
        if up_item then table.insert(final, up_item) end
        for _, item in ipairs(to_sort) do table.insert(final, item) end
    else
        -- Non-mixed: dirs first, then files.
        local up_item
        local dirs  = {}
        local files = {}
        for _, item in ipairs(processed) do
            if item.is_go_up then
                up_item = item
            elseif item.is_directory or item.is_series_group
                or (item.attr and item.attr.mode == "directory")
                or item.mode == "directory"
            then
                table.insert(dirs, item)
            else
                table.insert(files, item)
            end
        end
        if sort_func then
            pcall(table.sort, dirs, sort_func)
        end
        if up_item then table.insert(final, up_item) end
        for _, d in ipairs(dirs)  do table.insert(final, d) end
        for _, f in ipairs(files) do table.insert(final, f) end
    end

    -- Update item_table in place.
    for k in pairs(item_table) do item_table[k] = nil end
    for i, v in ipairs(final)  do item_table[i] = v    end
end

-- ---------------------------------------------------------------------------
-- _sgOpenGroup: switch the view into a virtual series folder.
-- ---------------------------------------------------------------------------
local function _sgOpenGroup(file_chooser, group_item)
    if not file_chooser then return end

    local parent_path = file_chooser.path
    local items       = group_item.series_items

    -- Persist state so refreshPath / updateItems can restore the view.
    _sg_current = {
        series_name    = group_item.text,
        parent_path    = parent_path,
        should_restore = false,
    }

    -- Tag the list so switchItemTable and updateItems skip re-grouping.
    items._sg_is_series_view = true
    items._sg_parent_path    = parent_path

    -- Notify the SimpleUI titlebar system that we are one level deep,
    -- so the back button appears and calls onFolderUp correctly.
    file_chooser._simpleui_has_go_up = true

    file_chooser:switchItemTable(nil, items, nil, nil, group_item.text)

    -- Notify the subtitle system about the virtual folder name so the
    -- title-bar subtitle shows the series name (and optionally page X of Y)
    -- even though no real updateTitleBarPath is fired for virtual folders.
    local ok_p, Patches = pcall(require, "sui_patches")
    if ok_p and Patches and Patches.setFMPathBase then
        local fm = require("apps/filemanager/filemanager").instance
        Patches.setFMPathBase(group_item.text, fm)
    end

    -- After switching to the virtual item table, force the titlebar to
    -- re-evaluate the up-button state for page 1. The genItemTable hook
    -- is not called for virtual folders (no real FS scan), so we trigger
    -- onGotoPage(1) explicitly. _simpleui_has_go_up is already true so
    -- the lock_home_folder branch in onGotoPage will show the button.
    if file_chooser.onGotoPage then
        pcall(function() file_chooser:onGotoPage(1) end)
    end
end

-- ---------------------------------------------------------------------------
-- Install / uninstall the FileChooser hooks for series grouping.
-- Called from M.install / M.uninstall — guards prevent double-patching.
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

    -- switchItemTable: process items BEFORE KOReader calculates itemmatch,
    -- so the grouped list is the one that the page/focus logic sees.
    FileChooser.switchItemTable = function(fc, new_title, new_item_table,
                                           itemnumber, itemmatch, new_subtitle)
        if new_item_table and not new_item_table._sg_is_series_view then
            _sgProcessItemTable(new_item_table, fc)
        end
        return _sg_orig_switchItemTable(fc, new_title, new_item_table,
                                        itemnumber, itemmatch, new_subtitle)
    end

    -- onMenuSelect: intercept taps on virtual folder items.
    FileChooser.onMenuSelect = function(fc, item)
        if item and item.is_series_group and M.getSeriesGrouping() then
            _sgOpenGroup(fc, item)
            return true
        end
        return _sg_orig_onMenuSelect(fc, item)
    end

    -- onMenuHold: intercept long-press on virtual series folder items.
    -- Shows only the cover picker since rename/delete/move don't apply
    -- to virtual paths that don't exist on disk.
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

    -- onFolderUp: exit the virtual folder instead of going up the real FS.
    FileChooser.onFolderUp = function(fc)
        if fc.item_table and fc.item_table._sg_is_series_view then
            local parent = fc.item_table._sg_parent_path
            if _sg_current then
                _sg_current.should_restore = true
            end
            -- Reset the flag before changeToPath so the changeToPath hook
            -- knows we are leaving a virtual folder intentionally.
            fc.item_table._sg_is_series_view = false
            if parent then
                fc:changeToPath(parent)
            end
            return true
        end
        return _sg_orig_onFolderUp(fc)
    end

    -- changeToPath: clear virtual-folder state when navigating to real paths.
    FileChooser.changeToPath = function(fc, path, ...)
        if fc.item_table and fc.item_table._sg_is_series_view then
            -- Leaving a virtual folder via changeToPath.
            local parent = fc.item_table._sg_parent_path
            if parent and path and (path:match("/%.%.") or path:match("^%.%.")) then
                -- Redirect relative ".." paths to the real parent.
                path = parent
            end
            fc.item_table._sg_is_series_view = false
            if path == parent then
                -- Navigating back to the real parent (back button / onFolderUp):
                -- keep _sg_current so updateItems can restore focus on the group.
                if _sg_current then
                    _sg_current.should_restore = true
                end
            else
                -- Navigating somewhere else entirely (Library tab → home, goHome,
                -- breadcrumb, etc.): discard series state completely so refreshPath
                -- does not try to re-enter the virtual folder.
                _sg_current = nil
            end
        else
            -- Normal filesystem navigation: clear series state entirely.
            _sg_current = nil
        end
        return _sg_orig_changeToPath(fc, path, ...)
    end

    -- refreshPath: re-enter the virtual folder after a reload (e.g. after
    -- closing a book and returning to the library).
    FileChooser.refreshPath = function(fc)
        -- Always flush the item cache before rebuilding the list so that
        -- status changes (long-press dialog, book close, etc.) are reflected
        -- immediately — the cache key does not encode per-book status/percent,
        -- so stale entries would otherwise survive until restart.
        _cache = {}
        _cache_count = 0
        _sg_orig_refreshPath(fc)
        if not M.getSeriesGrouping() then return end
        if not _sg_current then return end
        -- The item_table was rebuilt by refreshPath; find the matching group.
        local sname = _sg_current.series_name
        for _, item in ipairs(fc.item_table or {}) do
            if item.is_series_group and item.text == sname then
                _sgOpenGroup(fc, item)
                return
            end
        end
        -- Series group not found (e.g. the book was removed); clear state.
        _sg_current = nil
    end

    -- updateItems: restore focus to the series group item when returning from
    -- a virtual folder.
    FileChooser.updateItems = function(fc, ...)
        if not M.getSeriesGrouping() then
            _sg_current = nil
            return _sg_orig_updateItems(fc, ...)
        end

        -- Skip focus restoration while inside a virtual folder.
        if fc.item_table and fc.item_table._sg_is_series_view then
            return _sg_orig_updateItems(fc, ...)
        end

        if _sg_current and _sg_current.should_restore
            and fc.item_table and #fc.item_table > 0
        then
            local sname = _sg_current.series_name
            for idx, item in ipairs(fc.item_table) do
                if item.is_series_group and item.text == sname then
                    local page         = math.ceil(idx / fc.perpage)
                    local select_num   = ((idx - 1) % fc.perpage) + 1
                    fc.page            = page
                    if fc.path_items and fc.path then
                        fc.path_items[fc.path] = idx
                    end
                    _sg_current = nil
                    -- Tell the SimpleUI titlebar we are back at a real folder.
                    fc._simpleui_has_go_up = (fc.item_table[1] and
                        (fc.item_table[1].is_go_up or false)) or false
                    return _sg_orig_updateItems(fc, select_num)
                end
            end
            -- Group disappeared; just render normally.
            _sg_current = nil
        end

        return _sg_orig_updateItems(fc, ...)
    end
end

local function _uninstallSeriesGrouping()
    if not FileChooser._simpleui_sg_patched then return end
    if _sg_orig_switchItemTable then
        FileChooser.switchItemTable = _sg_orig_switchItemTable
        _sg_orig_switchItemTable = nil
    end
    if _sg_orig_onMenuSelect then
        FileChooser.onMenuSelect = _sg_orig_onMenuSelect
        _sg_orig_onMenuSelect = nil
    end
    if _sg_orig_onMenuHold then
        FileChooser.onMenuHold = _sg_orig_onMenuHold
        _sg_orig_onMenuHold = nil
    end
    if _sg_orig_onFolderUp then
        FileChooser.onFolderUp = _sg_orig_onFolderUp
        _sg_orig_onFolderUp = nil
    end
    if _sg_orig_changeToPath then
        FileChooser.changeToPath = _sg_orig_changeToPath
        _sg_orig_changeToPath = nil
    end
    if _sg_orig_refreshPath then
        FileChooser.refreshPath = _sg_orig_refreshPath
        _sg_orig_refreshPath = nil
    end
    if _sg_orig_updateItems then
        FileChooser.updateItems = _sg_orig_updateItems
        _sg_orig_updateItems = nil
    end
    FileChooser._simpleui_sg_patched = nil
    _sg_current     = nil
    _sg_items_cache = {}
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

    -- max_img_w/max_img_h are captured in MosaicMenuItem.init before each
    -- render and used by StretchingImageWidget to enforce the 2:3 ratio on
    -- every book cover — exactly the same pattern as 2--visual-overhaul.lua.
    local max_img_w, max_img_h

    if not MosaicMenuItem._simpleui_fc_iw_n then
        local local_ImageWidget
        local n = 1
        while true do
            local name, value = debug.getupvalue(MosaicMenuItem.update, n)
            if not name then break end
            if name == "ImageWidget" then
                local_ImageWidget = value
                break
            end
            n = n + 1
        end

        if local_ImageWidget then
            local StretchingImageWidget = local_ImageWidget:extend({})
            StretchingImageWidget.init = function(self)
                if local_ImageWidget.init then local_ImageWidget.init(self) end
                if M.getCoverMode() ~= "2_3" then return end
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

    -- Override init to capture cell dimensions before each render.
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

        -- Capture pages count and series index for badges (from BookList cache — no extra I/O).
        if not self.is_directory and not self.file_deleted and self.filepath then
            self._fc_pages = nil
            self._fc_series_index = nil
            local bi_pages = self.menu and self.menu.getBookInfo
                             and self.menu.getBookInfo(self.filepath)
            if bi_pages and bi_pages.pages then
                self._fc_pages = bi_pages.pages
            end
            if bi_pages and bi_pages.series and bi_pages.series_index then
                self._fc_series_index = bi_pages.series_index
            end
        end

        if self._foldercover_processed    then return end
        if self.menu.no_refresh_covers    then return end
        if not self.do_cover_image        then return end
        if not M.isEnabled()              then return end
        if self.entry.is_file or self.entry.file or not self.mandatory then return end

        local dir_path = self.entry and self.entry.path
        if not dir_path then return end

        -- ── Series group cover: use first available book cover from the group ──
        if self.entry.is_series_group then
            if self._foldercover_processed then return end

            -- Check for a user-chosen cover override first.
            local sg_overrides = _getCoverOverrides()
            local sg_override_fp = sg_overrides[dir_path]
            if sg_override_fp then
                local bookinfo = BookInfoManager:getBookInfo(sg_override_fp, true)
                if bookinfo
                    and bookinfo.cover_bb
                    and bookinfo.has_cover
                    and bookinfo.cover_fetched
                    and not bookinfo.ignore_cover
                    and not BookInfoManager.isCachedCoverInvalid(bookinfo, self.menu.cover_specs)
                then
                    self:_setFolderCover{
                        data = bookinfo.cover_bb,
                        w    = bookinfo.cover_w,
                        h    = bookinfo.cover_h,
                    }
                    return
                end
            end

            -- No override: use first available book cover from the group.
            local items = self.entry.series_items
                or _sg_items_cache[dir_path]
            if items then
                for _, book_entry in ipairs(items) do
                    if book_entry.path then
                        local bookinfo = BookInfoManager:getBookInfo(book_entry.path, true)
                        if bookinfo
                            and bookinfo.cover_bb
                            and bookinfo.has_cover
                            and bookinfo.cover_fetched
                            and not bookinfo.ignore_cover
                            and not BookInfoManager.isCachedCoverInvalid(
                                    bookinfo, self.menu.cover_specs)
                        then
                            self:_setFolderCover{
                                data = bookinfo.cover_bb,
                                w    = bookinfo.cover_w,
                                h    = bookinfo.cover_h,
                            }
                            return
                        end
                    end
                end
            end
            -- No cover found yet; leave _foldercover_processed unset so
            -- updateItems retries once BookInfoManager finishes fetching.
            return
        end
        -- It is only set inside _setFolderCover, after a cover is successfully
        -- applied. This allows BookInfoManager's async fetch to complete and
        -- trigger updateItems again — at which point the cover will be available
        -- and _setFolderCover will be called. If we set the flag here, the folder
        -- would be permanently skipped on the first open before covers are cached.

        -- Check for a user-chosen cover override.
        local overrides = _getCoverOverrides()
        local override_fp = overrides[dir_path]
        if override_fp then
            local bookinfo = BookInfoManager:getBookInfo(override_fp, true)
            if bookinfo
                and bookinfo.cover_bb
                and bookinfo.has_cover
                and bookinfo.cover_fetched
                and not bookinfo.ignore_cover
                and not BookInfoManager.isCachedCoverInvalid(bookinfo, self.menu.cover_specs)
            then
                self:_setFolderCover{ data = bookinfo.cover_bb, w = bookinfo.cover_w, h = bookinfo.cover_h }
                return
            end
        end

        -- Check for a .cover.* image file placed manually in the folder.
        -- Static files are always available — mark as processed immediately.
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
                self:_setFolderCover{ file = cover_file, w = w, h = h }
                return
            end
        end

        -- Strip status filter so finished/on-hold books can still supply cover art
        -- even when the browser is configured to show only new/reading books.
        local FileChooser_fc  = require("ui/widget/filechooser")
        local saved_filter_fc = FileChooser_fc.show_filter
        FileChooser_fc.show_filter = {}
        self.menu._dummy = true
        local entries = self.menu:genItemTableFromPath(dir_path)
        self.menu._dummy = false
        FileChooser_fc.show_filter = saved_filter_fc
        if not entries then return end

        -- Track whether this folder has direct ebooks or only subfolders,
        -- so we can decide whether to show a placeholder cover.
        local has_files      = false
        local has_subfolders = false

        for _, entry in ipairs(entries) do
            if entry.is_file or entry.file then
                has_files = true
                local bookinfo = BookInfoManager:getBookInfo(entry.path, true)
                if bookinfo
                    and bookinfo.cover_bb
                    and bookinfo.has_cover
                    and bookinfo.cover_fetched
                    and not bookinfo.ignore_cover
                    and not BookInfoManager.isCachedCoverInvalid(bookinfo, self.menu.cover_specs)
                then
                    self:_setFolderCover{ data = bookinfo.cover_bb, w = bookinfo.cover_w, h = bookinfo.cover_h }
                    return
                end
            else
                has_subfolders = true
            end
        end

        -- No direct ebook cover found. For bookless folders (only subfolders or
        -- completely empty) optionally search subfolders recursively, then fall
        -- back to the generic placeholder cover.
        if not has_files then
            if has_subfolders and M.getSubfolderCover() and M.getRecursiveCover() then
                local cover = _findCoverRecursive(self.menu, dir_path, 1, 3, BookInfoManager)
                if cover then
                    self:_setFolderCover(cover)
                    return
                end
            end
            if M.getSubfolderCover() then
                self:_setEmptyFolderCover()
            end
        end
    end

    function MosaicMenuItem:_setFolderCover(img)
        -- Mark as processed here — only reached when a cover is actually available.
        -- This lets updateItems retry (after async BookInfoManager fetch) without
        -- being blocked by an early flag set before the cover data was ready.
        self._foldercover_processed = true
        local border    = Size.border.thin
        local max_img_w = self.width  - _SPINE_W - border * 2
        local max_img_h = self.height - border * 2

        local img_options = {}
        if img.file then img_options.file  = img.file  end
        if img.data then img_options.image = img.data  end

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

        local spine       = _buildSpine(size.h)
        local cover_group = HorizontalGroup:new{ align = "center", spine, image_widget }

        local cover_w     = _SPINE_W + size.w + border * 2
        local cover_h     = size.h + border * 2
        local cover_dimen = Geom:new{ w = cover_w, h = cover_h }
        local cell_dimen  = Geom:new{ w = self.width, h = self.height }
        local cv_scale    = math.max(0.1, (math.floor((cover_h / _BASE_COVER_H) * 10) / 10))

        local label_w            = size.w - _LATERAL_PAD * 2
        local folder_name_widget = _buildLabel(self, label_w, size, border, cv_scale)
        local nbitems_widget     = _buildBadge(self.mandatory, cover_dimen, cv_scale)

        local overlap = OverlapGroup:new{ dimen = cover_dimen, cover_group }
        if folder_name_widget then overlap[#overlap + 1] = folder_name_widget end
        if nbitems_widget     then overlap[#overlap + 1] = nbitems_widget     end

        -- Centre the cover in the cell, then shift left by half the spine
        -- width so the visible image edge aligns with regular book covers.
        local x_center = math.floor((self.width  - cover_w) / 2)
        local y_center = math.floor((self.height - cover_h) / 2)
        local spine_offset = -math.floor(_SPINE_W / 2)
        overlap.overlap_offset = { x_center + spine_offset, y_center }
        local widget = OverlapGroup:new{ dimen = cell_dimen, overlap }

        if self._underline_container[1] then
            self._underline_container[1]:free()
        end
        self._underline_container[1] = widget
    end

    -- ---------------------------------------------------------------------------
    -- Builds and displays a placeholder cover for bookless folders (no direct
    -- ebooks — only subfolders, or completely empty). Creates a white blitbuffer,
    -- draws a folder icon SVG in the centre, adds the spine, the folder-name
    -- label, and the item-count badge, then positions the group in the cell.
    -- The method mirrors _setFolderCover's layout so both paths are visually
    -- consistent (spine + FrameContainer border + OverlapGroup centring).
    -- ---------------------------------------------------------------------------
    function MosaicMenuItem:_setEmptyFolderCover()
        self._foldercover_processed = true
        local border    = Size.border.thin
        local max_img_w = self.width  - _SPINE_W - border * 2
        local max_img_h = self.height - border * 2

        -- Compute cover dimensions — honour the 2:3 mode if active.
        local img_w, img_h
        if M.getCoverMode() == "2_3" then
            local ratio = 2 / 3
            if max_img_w / max_img_h > ratio then
                img_h = max_img_h
                img_w = math.floor(max_img_h * ratio)
            else
                img_w = max_img_w
                img_h = math.floor(max_img_w / ratio)
            end
        else
            img_w = max_img_w
            img_h = max_img_h
        end

        -- Try to load the plugin's custom SVG icon; fall back gracefully if absent.
        local _plugin_dir = debug.getinfo(1, "S").source:match("^@(.+/)[^/]+$") or "./"
        local icon_path   = _plugin_dir .. "icons/custom.svg"
        local icon_size   = math.floor(math.min(img_w, img_h) * 0.5)

        local icon_widget
        if lfs.attributes(icon_path, "mode") == "file" then
            local ok_iw, iw = pcall(function()
                return CenterContainer:new{
                    dimen = Geom:new{ w = img_w, h = img_h },
                    ImageWidget:new{
                        file    = icon_path,
                        width   = icon_size,
                        height  = icon_size,
                        alpha   = true,
                        is_icon = true,
                    },
                }
            end)
            if ok_iw then icon_widget = iw end
        end

        -- White background canvas for the cover image area.
        local bg_canvas = FrameContainer:new{
            padding    = 0,
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
            dimen      = Geom:new{ w = img_w, h = img_h },
            icon_widget,
        }

        local size         = Geom:new{ w = img_w, h = img_h }
        local image_widget = FrameContainer:new{ padding = 0, bordersize = border, bg_canvas }

        local spine       = _buildSpine(size.h)
        local cover_group = HorizontalGroup:new{ align = "center", spine, image_widget }

        local cover_w     = _SPINE_W + size.w + border * 2
        local cover_h     = size.h  + border * 2
        local cover_dimen = Geom:new{ w = cover_w, h = cover_h }
        local cell_dimen  = Geom:new{ w = self.width, h = self.height }
        local cv_scale    = math.max(0.1, (math.floor((cover_h / _BASE_COVER_H) * 10) / 10))

        local label_w            = size.w - _LATERAL_PAD * 2
        local folder_name_widget = _buildLabel(self, label_w, size, border, cv_scale)
        local nbitems_widget     = _buildBadge(self.mandatory, cover_dimen, cv_scale)

        local overlap = OverlapGroup:new{ dimen = cover_dimen, cover_group }
        if folder_name_widget then overlap[#overlap + 1] = folder_name_widget end
        if nbitems_widget     then overlap[#overlap + 1] = nbitems_widget     end

        local x_center     = math.floor((self.width  - cover_w) / 2)
        local y_center     = math.floor((self.height - cover_h) / 2)
        local spine_offset = -math.floor(_SPINE_W / 2)
        overlap.overlap_offset = { x_center + spine_offset, y_center }
        local widget = OverlapGroup:new{ dimen = cell_dimen, overlap }

        if self._underline_container[1] then
            self._underline_container[1]:free()
        end
        self._underline_container[1] = widget
    end

    function MosaicMenuItem:_getFolderNameWidget(available_w, dir_max_font_size)
        if not self._fc_display_text then
            local text = self.text
            if text:match("/$") then text = text:sub(1, -2) end
            text = text:gsub("(%S+)", function(w)
                return w:sub(1,1):upper() .. w:sub(2)
            end)
            self._fc_display_text = BD.directory(text)
        end
        local text = self._fc_display_text

        local longest_word = ""
        for word in text:gmatch("%S+") do
            if #word > #longest_word then longest_word = word end
        end

        local dir_font_size = dir_max_font_size or _BASE_DIR_FS

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

        local lo, hi = 8, dir_font_size
        while lo < hi do
            local mid = math.floor((lo + hi + 1) / 2)
            local tbw = TextBoxWidget:new{
                text      = text,
                face      = Font:getFace("cfont", mid),
                width     = available_w,
                alignment = "center",
                bold      = true,
            }
            local fits = tbw:getSize().h <= tbw:getLineHeight() * 2.2
            tbw:free(true)
            if fits then lo = mid else hi = mid - 1 end
        end
        dir_font_size = lo

        return TextBoxWidget:new{
            text      = text,
            face      = Font:getFace("cfont", dir_font_size),
            width     = available_w,
            alignment = "center",
            bold      = true,
        }
    end

    -- onFocus: hide the underline when the setting is on (default on).
    MosaicMenuItem._simpleui_fc_orig_onFocus = MosaicMenuItem.onFocus
    function MosaicMenuItem:onFocus()
        self._underline_container.color = M.getHideUnderline()
            and Blitbuffer.COLOR_WHITE
            or  Blitbuffer.COLOR_BLACK
        return true
    end

    -- paintTo: draw book cover overlays after the original painting.
    -- Folder covers are handled entirely through widget replacement in update/
    -- _setFolderCover, so paintTo only needs to act on book items.
    local orig_paintTo = MosaicMenuItem.paintTo
    MosaicMenuItem._simpleui_fc_orig_paintTo = orig_paintTo

    local function _round(v) return math.floor(v + 0.5) end

    function MosaicMenuItem:paintTo(bb, x, y)
        local x = math.floor(x)
        local y = math.floor(y)
        if self._simpleui_fc_orig_paintTo then
            self._simpleui_fc_orig_paintTo(self, bb, x, y)
        end

        -- Only act on book items (not dirs, not deleted).
        if self.is_directory or self.file_deleted then return end

        -- Locate the cover frame placed by the original paintTo.
        -- MosaicMenuItem widget tree: self[1] = _underline_container,
        -- [1][1] = CenterContainer, [1][1][1] = FrameContainer (the cover).
        local target = self._cover_frame
            or (self[1] and self[1][1] and self[1][1][1])
        if not target or not target.dimen then return end

        local fw = target.dimen.w
        local fh = target.dimen.h
        local fx = x + _round((self.width  - fw) / 2)
        local fy = y + _round((self.height - fh) / 2)

        -- ── Pages badge (bottom-left, white rounded rect, frame border) ──
        if M.getOverlayPages() and self.status ~= "complete" then
            local page_count = self._fc_pages
            if not page_count and self.filepath then
                local bi = BookInfoManager:getBookInfo(self.filepath, false)
                if bi and bi.pages then page_count = bi.pages end
            end
            if page_count then
                local font_sz   = Screen:scaleBySize(5)
                local pad_h     = Screen:scaleBySize(2)
                local pad_v     = Screen:scaleBySize(1)
                local inset     = Screen:scaleBySize(3)
                local ptw = TextWidget:new{
                    text    = page_count .. " p.",
                    face    = Font:getFace("cfont", font_sz),
                    bold    = false,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }
                local tsz    = ptw:getSize()
                local rect_w = tsz.w + pad_h * 2
                local rect_h = tsz.h + pad_v * 2
                local corner  = Screen:scaleBySize(2)
                local badge_widget = FrameContainer:new{
                    dimen      = Geom:new{ w = rect_w, h = rect_h },
                    bordersize = Size.border.thin,
                    color      = Blitbuffer.COLOR_DARK_GRAY,
                    background = Blitbuffer.COLOR_WHITE,
                    radius     = corner,
                    padding    = 0,
                    CenterContainer:new{
                        dimen = Geom:new{ w = rect_w, h = rect_h },
                        ptw,
                    },
                }
                -- Replicate the native bar geometry to anchor badge position.
                -- mosaicmenu bar pos_y = y + self.height - ceil((self.height-target.height)/2)
                --                        - corner_sz + bar_margin
                -- In paintTo context fy = y + ceil((self.height - fh)/2), so:
                --   bar_top = fy + fh - corner_sz + bar_margin
                local bar_height = Screen:scaleBySize(8)
                local corner_sz  = math.floor(math.min(self.width, self.height) / 8)
                local bar_margin = math.floor((corner_sz - bar_height) / 2)

                -- X: badge left edge matches bar left edge
                local badge_x = fx + math.max(bar_margin, inset)

                -- Y: when bar hidden, centre badge on bar's Y; when bar shown, place badge above it.
                local bar_top    = fy + fh - corner_sz + bar_margin
                local bar_centre = bar_top + math.floor(bar_height / 2)
                local badge_y
                if self.show_progress_bar then
                    local bar_gap = Screen:scaleBySize(4)
                    badge_y = bar_top - bar_gap - rect_h
                else
                    -- shift badge up by the same amount used as left padding
                    local bottom_pad = math.max(bar_margin, inset)
                    badge_y = bar_centre - math.floor(rect_h / 2) - bottom_pad
                end
                badge_widget:paintTo(bb, badge_x, badge_y)
                badge_widget:free()
            end
        end

        -- ── Series index badge (top-left, same style as pages badge) ──
        if M.getOverlaySeries() and self.status ~= "complete" then
            local series_index = self._fc_series_index
            if not series_index and self.filepath then
                local bi = BookInfoManager:getBookInfo(self.filepath, false)
                if bi and bi.series and bi.series_index then
                    series_index = bi.series_index
                end
            end
            if series_index then
                local font_sz  = Screen:scaleBySize(5)
                local pad_h    = Screen:scaleBySize(2)
                local pad_v    = Screen:scaleBySize(1)
                local inset    = Screen:scaleBySize(3)
                local stw = TextWidget:new{
                    text    = "#" .. series_index,
                    face    = Font:getFace("cfont", font_sz),
                    bold    = false,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }
                local tsz    = stw:getSize()
                local rect_w = tsz.w + pad_h * 2
                local rect_h = tsz.h + pad_v * 2
                local corner = Screen:scaleBySize(2)
                local corner_sz  = math.floor(math.min(self.width, self.height) / 8)
                local bar_margin = math.floor(
                    (corner_sz - Screen:scaleBySize(8)) / 2)
                local sbadge = FrameContainer:new{
                    dimen      = Geom:new{ w = rect_w, h = rect_h },
                    bordersize = Size.border.thin,
                    color      = Blitbuffer.COLOR_DARK_GRAY,
                    background = Blitbuffer.COLOR_WHITE,
                    radius     = corner,
                    padding    = 0,
                    CenterContainer:new{
                        dimen = Geom:new{ w = rect_w, h = rect_h },
                        stw,
                    },
                }
                local badge_x
                if BD.mirroredUILayout() then
                    badge_x = fx + fw - math.max(bar_margin, inset) - rect_w
                else
                    badge_x = fx + math.max(bar_margin, inset)
                end
                local badge_y = fy + math.max(bar_margin, inset)
                sbadge:paintTo(bb, badge_x, badge_y)
                sbadge:free()
            end
        end
    end

    -- free: nothing extra to release (pages TextWidget freed inline in paintTo).
    local orig_free = MosaicMenuItem.free
    MosaicMenuItem._simpleui_fc_orig_free = orig_free
    function MosaicMenuItem:free()
        if orig_free then orig_free(self) end
    end

    -- Install the item cache (always active when FC is on).
    _installItemCache()

    -- Install the series grouping hooks.
    _installSeriesGrouping()

    _installFileDialogButton(BookInfoManager)
end

function M.uninstall()
    local MosaicMenuItem, _ = _getMosaicMenuItemAndPatch()
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
end

return M
