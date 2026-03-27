-- sui_foldercovers.lua — Simple UI
-- Folder cover art and book cover overlays for the CoverBrowser mosaic view.
--
-- Folder covers:
--   - Vertical spine lines on the left (module_collections style)
--   - Folder name overlay at bottom with padding
--   - Book count badge at top-right, black circle
--   - Hide selection underline option
--
-- Book cover overlay:
--   - Pages badge ("123 p.") — white rect at bottom-left of book covers
--
-- Item cache:
--   - 2 000-entry LRU for FileChooser:getListItem()
--
-- Settings keys:
--   simpleui_fc_enabled          — folder covers master toggle (default false)
--   simpleui_fc_show_name        — show folder name overlay (default true)
--   simpleui_fc_hide_underline   — hide focus underline (default true)
--   simpleui_fc_overlay_pages    — pages badge on book covers (default true)
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
    -- Item cache
    item_cache       = "simpleui_fc_item_cache",
}

local M = {}

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

-- Pages badge getter / setter (default true)
function M.getOverlayPages() return G_reader_settings:readSetting(SK.overlay_pages) ~= false end
function M.setOverlayPages(v) _setFlag(SK.overlay_pages, v) end

-- Item cache (default on)
function M.getItemCache() return G_reader_settings:readSetting(SK.item_cache) ~= false end
function M.setItemCache(v) _setFlag(SK.item_cache, v) end

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

local _BASE_COVER_H = Screen:scaleBySize(96)  -- reference cover height (mosaic cell)
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

    local dir_max_fs = math.max(8, math.floor(_BASE_DIR_FS * cv_scale))
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

-- Opens a ButtonDialog listing the books inside dir_path so the user can
-- pick which one's cover to use.
local function _openFolderCoverPicker(dir_path, menu, BookInfoManager)
    local UIManager    = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage  = require("ui/widget/infomessage")

    menu._dummy = true
    local entries = menu:genItemTableFromPath(dir_path)
    menu._dummy = false

    local books = {}
    if entries then
        for _, entry in ipairs(entries) do
            if entry.is_file or entry.file then
                books[#books + 1] = entry
            end
        end
    end

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
        local label = (bookinfo and bookinfo.title and bookinfo.title ~= "")
            and bookinfo.title
            or (fp:match("([^/]+)%.[^%.]+$") or fp)
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
            return {{
                text = _("Set folder cover…"),
                callback = function()
                    local UIManager = require("ui/uimanager")
                    local fc = FileManager.instance and FileManager.instance.file_chooser
                    if fc and fc.file_dialog then
                        UIManager:close(fc.file_dialog)
                    end
                    if fc then
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
-- Item cache — 2 000-entry LRU for FileChooser:getListItem()
-- Avoids redundant item rebuilds while scrolling a large library.
-- Installed/uninstalled independently of the folder-covers feature toggle.
-- ---------------------------------------------------------------------------

local _cache       = {}
local _cache_count = 0
local _CACHE_MAX   = 2000
local _orig_getListItem = FileChooser.getListItem

local function _installItemCache()
    if FileChooser._simpleui_fc_cache_patched then return end
    FileChooser._simpleui_fc_cache_patched = true
    FileChooser.getListItem = function(fc, dirpath, f, fullpath, attributes, collate)
        if not M.getItemCache() then
            return _orig_getListItem(fc, dirpath, f, fullpath, attributes, collate)
        end
        local filter = fc.show_filter and fc.show_filter.status or ""
        local key = tostring(dirpath) .. "\0" .. tostring(f) .. "\0"
                 .. tostring(fullpath) .. "\0" .. filter
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

        -- Capture pages count for the badge (from BookList cache — no extra I/O).
        if not self.is_directory and not self.file_deleted and self.filepath then
            self._fc_pages = nil
            local bi_pages = self.menu and self.menu.getBookInfo
                             and self.menu.getBookInfo(self.filepath)
            if bi_pages and bi_pages.pages then
                self._fc_pages = bi_pages.pages
            end
        end

        if self._foldercover_processed    then return end
        if self.menu.no_refresh_covers    then return end
        if not self.do_cover_image        then return end
        if not M.isEnabled()              then return end
        if self.entry.is_file or self.entry.file or not self.mandatory then return end

        local dir_path = self.entry and self.entry.path
        if not dir_path then return end

        self._foldercover_processed = true

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

        self.menu._dummy = true
        local entries = self.menu:genItemTableFromPath(dir_path)
        self.menu._dummy = false
        if not entries then return end

        for _, entry in ipairs(entries) do
            if entry.is_file or entry.file then
                local bookinfo = BookInfoManager:getBookInfo(entry.path, true)
                if bookinfo
                    and bookinfo.cover_bb
                    and bookinfo.has_cover
                    and bookinfo.cover_fetched
                    and not bookinfo.ignore_cover
                    and not BookInfoManager.isCachedCoverInvalid(bookinfo, self.menu.cover_specs)
                then
                    self:_setFolderCover{ data = bookinfo.cover_bb, w = bookinfo.cover_w, h = bookinfo.cover_h }
                    break
                end
            end
        end
    end

    function MosaicMenuItem:_setFolderCover(img)
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
        local cv_scale    = cover_h / _BASE_COVER_H

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

    function MosaicMenuItem:_getFolderNameWidget(available_w, dir_max_font_size)
        if not self._fc_display_text then
            local text = self.text
            if text:match("/$") then text = text:sub(1, -2) end
            text = text:gsub("(%S+)", function(w)
                return w:sub(1,1):upper() .. w:sub(2):lower()
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
        orig_paintTo(self, bb, x, y)

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
                badge_widget:paintTo(bb, fx + inset, fy + fh - rect_h - inset)
                badge_widget:free()
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
    _uninstallFileDialogButton()
end

return M