-- folio_foldercovers.lua — Folio
-- Folder cover art for the CoverBrowser mosaic view.
--
-- Implements exactly the same logic as 2-browser-folder-cover.lua, minus
-- the horizontal tab lines at the top and the outer border. Adds:
--   - Vertical spine lines on the left (module_collections style)
--   - Folder name overlay at bottom with padding
--   - Book count badge at top-right, black circle
--   - Hide selection underline option
--
-- Settings keys:
--   folio_fc_enabled        — master toggle (default false)
--   folio_fc_show_name      — show folder name overlay (default true)
--   folio_fc_hide_underline — hide focus underline (default true)

local _ = require("gettext")
local lfs = require("libs/libkoreader-lfs")

-- ---------------------------------------------------------------------------
-- Widget requires — at module level so require() cache lookup happens once,
-- not on every cell render.
-- ---------------------------------------------------------------------------

local AlphaContainer  = require("ui/widget/container/alphacontainer")
local BD              = require("ui/bidi")
local Blitbuffer      = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
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

local FolioTheme = require("folio_theme")

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

local SK = {
    enabled        = "folio_fc_enabled",
    show_name      = "folio_fc_show_name",
    hide_underline = "folio_fc_hide_underline",
    label_style    = "folio_fc_label_style",
    label_position = "folio_fc_label_position",
    badge_position = "folio_fc_badge_position",
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

-- Spine constants — computed once, mirror module_collections exactly.
local _EDGE_THICK  = math.max(1, Screen:scaleBySize(3))
local _EDGE_MARGIN = math.max(1, Screen:scaleBySize(1))
local _EDGE_COLOR  = Blitbuffer.gray(0.55)
local _SPINE_W     = _EDGE_THICK * 2 + _EDGE_MARGIN * 2

-- Padding constants — computed once.
local _LATERAL_PAD       = Screen:scaleBySize(10)
local _VERTICAL_PAD      = Screen:scaleBySize(4)
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

-- Builds the two vertical spine lines on the left of the cover.
local function _buildSpine(img_h)
    local h1 = math.floor(img_h * 0.97)
    local h2 = math.floor(img_h * 0.94)
    local y1 = math.floor((img_h - h1) / 2)
    local y2 = math.floor((img_h - h2) / 2)

    local function spineLine(h, y_off)
        local line = LineWidget:new{
            dimen      = Geom:new{ w = _EDGE_THICK, h = h },
            background = _EDGE_COLOR,
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
-- Returns nil when show_name is disabled.
local function _buildLabel(item, available_w, size, border, cv_scale)
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
        bordersize     = 0,
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
        name_og[1] = TopContainer:new{
            dimen         = img_only,
            label_inner,
            overlap_align = "center",
        }
    else  -- "bottom" (default)
        name_og[1] = BottomContainer:new{
            dimen         = img_only,
            label_inner,
            overlap_align = "center",
        }
    end
    name_og.overlap_offset = { _SPINE_W, border }
    return name_og
end

-- Builds the book-count badge (circular, top- or bottom-right of cover).
-- Returns nil when there is no count to display.
local function _buildBadge(mandatory, cover_dimen, cv_scale)
    local nb_text = mandatory and mandatory:match("(%d+) \u{F016}") or ""
    if nb_text == "" or nb_text == "0" then return nil end

    local nb_count       = tonumber(nb_text)  -- already validated non-nil by the guard above
    -- Square badge reads heavier than a circle — slightly reduce footprint.
    local nb_size        = math.max(6, math.floor(_BASE_NB_SIZE * cv_scale * 0.8))
    local nb_font_size   = math.floor(nb_size * (_BASE_NB_FS / _BASE_NB_SIZE))
    local badge_margin   = math.max(1, math.floor(_BADGE_MARGIN_BASE   * cv_scale))
    local badge_margin_r = math.max(1, math.floor(_BADGE_MARGIN_R_BASE * cv_scale))

    local badge_pad_h = math.max(1, Screen:scaleBySize(2))
    local badge = FrameContainer:new{
        padding_left   = badge_pad_h,
        padding_right  = badge_pad_h,
        padding        = 0,
        bordersize     = 0,
        background     = Blitbuffer.COLOR_BLACK,
        radius         = 0,
        dimen          = Geom:new{ w = nb_size, h = nb_size },
        CenterContainer:new{
            dimen = Geom:new{ w = nb_size, h = nb_size },
            TextWidget:new{
                text    = tostring(math.min(nb_count, 99)),
                face    = FolioTheme.faceUI(nb_font_size),
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
-- Key: "folio_fc_covers" → table { [dir_path] = book_filepath }
-- ---------------------------------------------------------------------------

local _FC_COVERS_KEY = "folio_fc_covers"

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
-- menu.layout is a list-of-rows of MosaicMenuItem.
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
-- pick which one's cover to use — same pattern as module_collections.
-- BookInfoManager is passed in from M.install() closure.
local function _openFolderCoverPicker(dir_path, menu, BookInfoManager)
    local UIManager   = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage  = require("ui/widget/infomessage")

    -- Collect book entries from the folder.
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

    -- "Auto" option — clears any override.
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
        -- Use book title from BookInfoManager cache if available, else filename.
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

    FileManager.addFileDialogButtons(FileManager, "folio_fc_cover",
        function(file, is_file, _book_props)
            if is_file then return nil end
            -- Hide the button when Folder Covers is disabled in the menu.
            if not M.isEnabled() then return nil end
            return {{
                text = _("Set folder cover…"),
                callback = function()
                    local UIManager = require("ui/uimanager")
                    -- Fetch file_chooser at callback time, not at dialog-open
                    -- time — the instance may change between the two moments.
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
    FileManager.removeFileDialogButtons(FileManager, "folio_fc_cover")
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.install()
    local MosaicMenuItem, userpatch = _getMosaicMenuItemAndPatch()
    if not MosaicMenuItem then return end
    if MosaicMenuItem._folio_fc_patched then return end

    local BookInfoManager = userpatch.getUpValue(MosaicMenuItem.update, "BookInfoManager")
    if not BookInfoManager then return end

    MosaicMenuItem._folio_fc_patched     = true
    MosaicMenuItem._folio_fc_orig_update = MosaicMenuItem.update

    local original_update = MosaicMenuItem.update

    function MosaicMenuItem:update(...)
        original_update(self, ...)

        if self._foldercover_processed    then return end
        if self.menu.no_refresh_covers    then return end
        if not self.do_cover_image        then return end
        if not M.isEnabled()              then return end
        if self.entry.is_file or self.entry.file or not self.mandatory then return end

        local dir_path = self.entry and self.entry.path
        if not dir_path then return end

        self._foldercover_processed = true

        -- Check for a user-chosen cover override (set via "Set folder cover…").
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
            -- Override book has no cover in cache yet — fall through to auto.
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
        local border   = Size.border.thin
        local max_img_w = self.width  - _SPINE_W - border * 2
        local max_img_h = self.height - border * 2

        -- Scale to fit within the target area while preserving aspect ratio —
        -- identical to BookInfoManager.getCachedCoverSize logic used by the
        -- native mosaic view. No fixed width/height: ImageWidget computes the
        -- final size from scale_factor alone, so proportions are always correct.
        local scale_factor = math.min(max_img_w / img.w, max_img_h / img.h)

        local img_options = { scale_factor = scale_factor }
        if img.file  then img_options.file  = img.file  end
        if img.data  then img_options.image = img.data  end

        local image        = ImageWidget:new(img_options)
        local size         = image:getSize()
        local image_widget = FrameContainer:new{ padding = 0, bordersize = border, image }

        local spine       = _buildSpine(size.h)
        local cover_group = HorizontalGroup:new{ align = "center", spine, image_widget }

        local cover_w    = _SPINE_W + size.w + border * 2
        local cover_h    = size.h + border * 2
        local cover_dimen = Geom:new{ w = cover_w, h = cover_h }
        local cell_dimen  = Geom:new{ w = self.width, h = self.height }
        local cv_scale    = cover_h / _BASE_COVER_H

        local label_w          = size.w - _LATERAL_PAD * 2
        local folder_name_widget = _buildLabel(self, label_w, size, border, cv_scale)
        local nbitems_widget     = _buildBadge(self.mandatory, cover_dimen, cv_scale)

        local overlap = OverlapGroup:new{ dimen = cover_dimen, cover_group }
        if folder_name_widget then overlap[#overlap + 1] = folder_name_widget end
        if nbitems_widget     then overlap[#overlap + 1] = nbitems_widget     end

        local widget = CenterContainer:new{ dimen = cell_dimen, overlap }

        if self._underline_container[1] then
            self._underline_container[1]:free()
        end
        self._underline_container[1] = widget
    end

    function MosaicMenuItem:_getFolderNameWidget(available_w, dir_max_font_size)
        -- Cache the formatted display text — the folder name does not change
        -- between renders of the same item, so title-casing and BD wrapping
        -- only need to happen once.
        if not self._fc_display_text then
            local text = self.text
            if text:match("/$") then text = text:sub(1, -2) end
            text = text:gsub("(%S+)", function(w)
                return w:sub(1,1):upper() .. w:sub(2):lower()
            end)
            self._fc_display_text = BD.directory(text)
        end
        local text = self._fc_display_text

        -- Find the longest word — guarantees it fits on one line before
        -- TextBoxWidget has a chance to break mid-word.
        local longest_word = ""
        for word in text:gmatch("%S+") do
            if #word > #longest_word then longest_word = word end
        end

        local dir_font_size = dir_max_font_size or _BASE_DIR_FS

        -- Binary search: reduce font size until the longest word fits in
        -- available_w. O(log n) widget allocs instead of O(n).
        -- Lower bound matches the floor used by the second search (8px).
        if longest_word ~= "" then
            local lo, hi = 8, dir_font_size
            while lo < hi do
                local mid = math.floor((lo + hi + 1) / 2)
                local tw = TextWidget:new{
                    text = longest_word,
                    face = FolioTheme.faceContent(mid),
                    bold = true,
                }
                local word_w = tw:getWidth()
                tw:free()
                if word_w <= available_w then lo = mid else hi = mid - 1 end
            end
            dir_font_size = lo
        end

        -- Binary search: reduce further until the full text fits in two lines.
        -- Lower bound is 8 (same as before); upper bound is the size found above.
        local lo, hi = 8, dir_font_size
        while lo < hi do
            local mid = math.floor((lo + hi + 1) / 2)
            local tbw = TextBoxWidget:new{
                text      = text,
                face      = FolioTheme.faceContent(mid),
                width     = available_w,
                alignment = "center",
                bold      = true,
            }
            local fits = tbw:getSize().h <= tbw:getLineHeight() * 2.2
            tbw:free(true)
            if fits then lo = mid else hi = mid - 1 end
        end
        dir_font_size = lo

        -- Final widget at the chosen size — caller takes ownership.
        return TextBoxWidget:new{
            text      = text,
            face      = FolioTheme.faceContent(dir_font_size),
            width     = available_w,
            alignment = "center",
            bold      = true,
        }
    end

    -- onFocus: hide the underline when the setting is on (default on).
    MosaicMenuItem._folio_fc_orig_onFocus = MosaicMenuItem.onFocus
    function MosaicMenuItem:onFocus()
        self._underline_container.color = M.getHideUnderline()
            and Blitbuffer.COLOR_WHITE
            or  Blitbuffer.COLOR_BLACK
        return true
    end

    _installFileDialogButton(BookInfoManager)
end

function M.uninstall()
    local MosaicMenuItem, _ = _getMosaicMenuItemAndPatch()
    if not MosaicMenuItem then return end
    if not MosaicMenuItem._folio_fc_patched then return end
    if MosaicMenuItem._folio_fc_orig_update then
        MosaicMenuItem.update = MosaicMenuItem._folio_fc_orig_update
        MosaicMenuItem._folio_fc_orig_update = nil
    end
    if MosaicMenuItem._folio_fc_orig_onFocus then
        MosaicMenuItem.onFocus = MosaicMenuItem._folio_fc_orig_onFocus
        MosaicMenuItem._folio_fc_orig_onFocus = nil
    end
    MosaicMenuItem._setFolderCover      = nil
    MosaicMenuItem._getFolderNameWidget = nil
    MosaicMenuItem._folio_fc_patched = nil
    _uninstallFileDialogButton()
end

return M