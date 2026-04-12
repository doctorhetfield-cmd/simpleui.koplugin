-- module_collections.lua — Simple UI
-- Módulo: Collections.
-- Substitui collectionswidget.lua — contém todo o código de widget.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local UIManager       = require("ui/uimanager")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local ImageWidget     = require("ui/widget/imagewidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local logger          = require("logger")
local lfs             = require("libs/libkoreader-lfs")
local _               = require("gettext")
local Config          = require("sui_config")

local UI           = require("sui_core")
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB
local PAD     = UI.PAD
local PAD2    = UI.PAD2
local MOD_GAP = UI.MOD_GAP

-- Base dimensions at 100% scale — never modified at runtime.
local _BASE_COLL_W       = Screen:scaleBySize(75)
local _BASE_COLL_H       = Screen:scaleBySize(112)
local _BASE_ACCENT_H     = Screen:scaleBySize(4)
local _BASE_LABEL_LINE_H = Screen:scaleBySize(14)
local _BASE_LABEL_GAP    = Screen:scaleBySize(4)   -- gap between cover and label
local _BASE_BADGE_SZ       = Screen:scaleBySize(16)
local _BASE_BADGE_MARGIN   = Screen:scaleBySize(4)  -- right margin
local _BASE_BADGE_MARGIN_T = Screen:scaleBySize(8)  -- top margin
local _BASE_EDGE_THICK   = Screen:scaleBySize(3)
local _BASE_EDGE_MARGIN  = Screen:scaleBySize(1)
local _BASE_PH_COVER_FS  = Screen:scaleBySize(12)  -- placeholder initials font
local _BASE_COLL_LBL_FS  = Screen:scaleBySize(8)   -- collection name label font
local _BASE_BADGE_FS     = Screen:scaleBySize(6)    -- badge font (~0.375 x badge_sz)
local _BASE_EMPTY_H      = Screen:scaleBySize(36)
local _BASE_EMPTY_FS     = Screen:scaleBySize(10)

local EDGE_COLOR = Blitbuffer.gray(0.70)
local EDGE_H1    = 0.97   -- inner line height fraction of COLL_H
local EDGE_H2    = 0.94   -- outer line height fraction

local _CLR_COVER_BORDER = Blitbuffer.COLOR_BLACK
local _CLR_COVER_BG     = Blitbuffer.gray(0.88)

local LABEL_H = UI.LABEL_H  -- kept for any external callers; getHeight() uses getScaledLabelH()

-- getDims(scale, thumb_scale)
-- scale:       overall module scale — affects all dimensions.
-- thumb_scale: independent thumbnail scale — affects cover/badge/edge dims only.
--              Label text and gaps follow `scale` only.
local function getDims(scale, thumb_scale)
    scale       = scale       or 1.0
    thumb_scale = thumb_scale or 1.0
    -- Combined scale for cover-related dimensions only.
    local cs = scale * thumb_scale
    local coll_w       = math.floor(_BASE_COLL_W       * cs)
    local coll_h       = math.floor(_BASE_COLL_H       * cs)
    local accent_h     = math.max(1, math.floor(_BASE_ACCENT_H     * cs))
    local badge_sz       = math.max(6, math.floor(_BASE_BADGE_SZ       * cs))
    local badge_margin   = math.max(1, math.floor(_BASE_BADGE_MARGIN   * cs))
    local badge_margin_t = math.max(1, math.floor(_BASE_BADGE_MARGIN_T * cs))
    local edge_thick   = math.max(1, math.floor(_BASE_EDGE_THICK   * cs))
    local edge_margin  = math.max(1, math.floor(_BASE_EDGE_MARGIN  * cs))
    -- Label text and gaps scale only with `scale`, not thumb_scale.
    local label_gap    = math.max(1, math.floor(_BASE_LABEL_GAP    * scale))
    local stack_extra  = 2 * edge_thick + 2 * edge_margin
    -- Font size for collection label — computed here so coll_cell_h can use the
    -- same line-height formula as TextBoxWidget (1.3 × font_size), keeping the
    -- reserved cell height perfectly in sync with the widget's actual height.
    local coll_lbl_fs  = math.max(6, math.floor(_BASE_COLL_LBL_FS * scale))
    -- TextBoxWidget internal line_height_px = math.floor(1.3 * font_size + 0.5).
    -- We must use this exact formula for both the widget height and coll_cell_h.
    local tbw_line_h   = math.floor(1.3 * coll_lbl_fs + 0.5)
    return {
        coll_w       = coll_w,
        coll_h       = coll_h,
        accent_h     = accent_h,
        tbw_line_h   = tbw_line_h,
        label_gap    = label_gap,
        badge_sz       = badge_sz,
        badge_margin   = badge_margin,
        badge_margin_t = badge_margin_t,
        edge_thick   = edge_thick,
        edge_margin  = edge_margin,
        stack_extra  = stack_extra,
        stack_cell_w = coll_w + stack_extra,
        cell_h       = coll_h + accent_h,
        coll_cell_h  = coll_h + accent_h + label_gap + 2 * tbw_line_h,
        ph_cover_fs  = math.max(7, math.floor(_BASE_PH_COVER_FS * cs)),
        coll_lbl_fs  = coll_lbl_fs,
        badge_fs     = math.floor(badge_sz * (_BASE_BADGE_FS / _BASE_BADGE_SZ)),
        empty_h      = math.max(16, math.floor(_BASE_EMPTY_H    * scale)),
        empty_fs     = math.max(7,  math.floor(_BASE_EMPTY_FS   * scale)),
    }
end

-- ---------------------------------------------------------------------------
-- Settings keys
-- ---------------------------------------------------------------------------
local SETTINGS_KEY       = "navbar_collections_list"
local COVER_OVERRIDE_KEY = "navbar_collections_covers"
local BADGE_POSITION_KEY = "navbar_collections_badge_position"

local function getBadgePosition()
    return G_reader_settings:readSetting(BADGE_POSITION_KEY) or "top"
end
local function saveBadgePosition(v)
    G_reader_settings:saveSetting(BADGE_POSITION_KEY, v)
end

local function getSelectedCollections()
    return G_reader_settings:readSetting(SETTINGS_KEY) or {}
end
local function saveSelectedCollections(list)
    G_reader_settings:saveSetting(SETTINGS_KEY, list)
end
local function getCoverOverrides()
    return G_reader_settings:readSetting(COVER_OVERRIDE_KEY) or {}
end
local function saveCoverOverrides(t)
    G_reader_settings:saveSetting(COVER_OVERRIDE_KEY, t)
end

-- ---------------------------------------------------------------------------
-- ReadCollection helpers
-- ---------------------------------------------------------------------------
local function getCollectionFilesFromRC(rc, coll_name)
    local coll = rc.coll and rc.coll[coll_name]
    if not coll then return {} end
    local entries = {}
    local i = 1
    for fp, info in pairs(coll) do
        entries[i] = { filepath = fp, order = (type(info) == "table" and info.order) or 9999 }
        i = i + 1
    end
    table.sort(entries, function(a, b) return a.order < b.order end)
    local files = {}
    for j = 1, #entries do files[j] = entries[j].filepath end
    return files
end

-- ---------------------------------------------------------------------------
-- Cover loading
-- ---------------------------------------------------------------------------
local function getBookCover(filepath, w, h)
    local bb = Config.getCoverBB(filepath, w, h, nil, 0.10)
    if not bb then return nil end
    local ok, img = pcall(function()
        return ImageWidget:new{
            image            = bb,
            image_disposable = false,  -- bb is owned by the cover cache; must not be freed here
            width            = w,
            height           = h,
            scale_factor     = 1,
        }
    end)
    return ok and img or nil
end

-- ---------------------------------------------------------------------------
-- Cover cell
-- ---------------------------------------------------------------------------
local function buildCoverCell(files, cover_override, coll_name, count, d)
    local front_fp = cover_override
    if front_fp and lfs.attributes(front_fp, "mode") ~= "file" then front_fp = nil end
    if not front_fp and #files > 0 then front_fp = files[1] end

    -- Main cover (or placeholder).
    local cover
    if front_fp and lfs.attributes(front_fp, "mode") == "file" then
        local raw = getBookCover(front_fp, d.coll_w, d.coll_h)
        if raw then
            cover = FrameContainer:new{
                bordersize = 1, color = _CLR_COVER_BORDER,
                padding    = 0, margin = 0,
                dimen      = Geom:new{ w = d.coll_w, h = d.coll_h },
                raw,
            }
        end
    end
    if not cover then
        cover = FrameContainer:new{
            bordersize = 1, color = _CLR_COVER_BORDER,
            background = _CLR_COVER_BG, padding = 0,
            dimen      = Geom:new{ w = d.coll_w, h = d.coll_h },
            CenterContainer:new{
                dimen = Geom:new{ w = d.coll_w, h = d.coll_h },
                TextWidget:new{
                    text = (coll_name or "?"):sub(1, 2):upper(),
                    face = Font:getFace("smallinfofont", d.ph_cover_fs),
                },
            },
        }
    end

    local h1 = math.floor(d.coll_h * EDGE_H1)
    local h2 = math.floor(d.coll_h * EDGE_H2)
    local y1 = math.floor((d.coll_h - h1) / 2)
    local y2 = math.floor((d.coll_h - h2) / 2)

    local function edgeLine(h, y_off)
        local line = LineWidget:new{
            dimen      = Geom:new{ w = d.edge_thick, h = h },
            background = EDGE_COLOR,
        }
        line.overlap_offset = { 0, y_off }
        return OverlapGroup:new{
            dimen = Geom:new{ w = d.edge_thick, h = d.coll_h },
            line,
        }
    end

    local stack = HorizontalGroup:new{
        align = "top",
        edgeLine(h2, y2),
        HorizontalSpan:new{ width = d.edge_margin },
        edgeLine(h1, y1),
        HorizontalSpan:new{ width = d.edge_margin },
        cover,
    }

    local accent = FrameContainer:new{
        bordersize = 0, padding = 0,
        background = Blitbuffer.COLOR_BLACK,
        dimen      = Geom:new{ w = d.coll_w, h = d.accent_h },
        VerticalSpan:new{ width = 0 },
    }

    local base = VerticalGroup:new{ align = "left", stack, accent }

    local badge_inner = CenterContainer:new{
        dimen = Geom:new{ w = d.badge_sz, h = d.badge_sz },
        TextWidget:new{
            text    = tostring(math.min(count, 99)),
            face    = Font:getFace("cfont", d.badge_fs),
            fgcolor = Blitbuffer.COLOR_WHITE,
            bold    = true,
        },
    }
    local badge = FrameContainer:new{
        bordersize = 0,
        background = Blitbuffer.COLOR_BLACK,
        radius     = math.floor(d.badge_sz / 2),
        padding    = 0,
        dimen      = Geom:new{ w = d.badge_sz, h = d.badge_sz },
        badge_inner,
    }
    badge.overlap_offset = {
        d.stack_extra + d.coll_w - d.badge_sz - d.badge_margin,
        getBadgePosition() == "bottom"
            and (d.coll_h + d.accent_h - d.badge_sz - d.badge_margin_t)
            or  d.badge_margin_t,
    }

    return OverlapGroup:new{
        dimen = Geom:new{ w = d.stack_cell_w, h = d.cell_h },
        base, badge,
    }
end

-- ---------------------------------------------------------------------------
-- openCollection
-- ---------------------------------------------------------------------------
local function openCollection(coll_name)
    -- patchUIManagerShow (patches.lua) automatically closes any homescreen widget
    -- when a covers_fullscreen widget is shown — so we must NOT call close_fn here.
    -- Calling it would produce a double-close and run onCloseWidget twice.
    local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
    if not ok_fm or not FM or not FM.instance then return end
    local fm = FM.instance
    if fm.collections and type(fm.collections.onShowColl) == "function" then
        pcall(function() fm.collections:onShowColl(coll_name) end)
    elseif fm.collections and type(fm.collections.onShowCollList) == "function" then
        pcall(function() fm.collections:onShowCollList() end)
    end
end

-- ---------------------------------------------------------------------------
-- Module API
-- ---------------------------------------------------------------------------
local M = {}

M.id          = "collections"
M.name        = _("Collections")
M.label       = _("Collections")
M.enabled_key = "collections"
M.default_on  = true

function M.setEnabled(pfx, on)
    G_reader_settings:saveSetting(pfx .. "collections", on)
end

local MAX_COLL = 5

function M.getCountLabel(_pfx)
    local n   = #M.getSelected()
    local rem = MAX_COLL - n
    if n == 0   then return nil end
    if rem <= 0 then return string.format("(%d/%d — at limit)", n, MAX_COLL) end
    return string.format("(%d/%d — %d left)", n, MAX_COLL, rem)
end

function M.build(w, ctx)
    Config.applyLabelToggle(M, _("Collections"))
    local scale       = Config.getModuleScale("collections", ctx.pfx)
    local thumb_scale = Config.getThumbScale("collections", ctx.pfx)
    local lbl_scale   = Config.getItemLabelScale("collections", ctx.pfx)
    local d           = getDims(scale, thumb_scale)
    -- Apply independent label text scale on top of module scale, then
    -- recalculate tbw_line_h and coll_cell_h so they stay in sync with the
    -- actual font size used by the TextBoxWidget.
    if lbl_scale ~= 1.0 then
        d.coll_lbl_fs = math.max(6, math.floor(d.coll_lbl_fs * lbl_scale))
        d.tbw_line_h  = math.floor(1.3 * d.coll_lbl_fs + 0.5)
        d.coll_cell_h = d.coll_h + d.accent_h + d.label_gap + 2 * d.tbw_line_h
    end
    local selected_raw = getSelectedCollections()
    -- -----------------------------------------------------------------------
    -- Sync with native KoReader collections (Problem 2).
    -- Filter out any collection that no longer exists in rc.coll (renamed or
    -- deleted). If the persisted list differs from the live one, save the
    -- cleaned version so future loads are also correct.
    -- -----------------------------------------------------------------------
    local _rc_sync
    local _ok_rc_sync, _rc_or_err_sync = pcall(require, "readcollection")
    if _ok_rc_sync and _rc_or_err_sync then
        _rc_sync = _rc_or_err_sync
        if _rc_sync._read then pcall(function() _rc_sync:_read() end) end
    end
    local synced_raw = {}
    if _rc_sync and _rc_sync.coll then
        for _, n in ipairs(selected_raw) do
            if _rc_sync.coll[n] then
                synced_raw[#synced_raw + 1] = n
            end
        end
    else
        -- readcollection unavailable — keep list as-is
        synced_raw = selected_raw
    end
    -- Persist the cleaned list if anything was removed.
    if #synced_raw ~= #selected_raw then
        saveSelectedCollections(synced_raw)
    end
    -- Hide the TBR collection when it is empty so it does not occupy a slot.
    local selected = {}
    do
        local TBR = package.loaded["desktop_modules/module_tbr"]
        for _, n in ipairs(synced_raw) do
            if TBR and n == TBR.TBR_COLL_NAME then
                if TBR.getTBRCount() > 0 then
                    selected[#selected + 1] = n
                end
            else
                selected[#selected + 1] = n
            end
        end
    end

    if #selected == 0 then
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = d.empty_h },
            TextWidget:new{
                text    = _("No collections selected"),
                face    = Font:getFace("cfont", d.empty_fs),
                fgcolor = CLR_TEXT_SUB,
                width   = w - PAD * 2,
            },
        }
    end

    local inner_w   = w - PAD * 2
    local cols      = math.min(#selected, 5)
    local overrides = getCoverOverrides()

    local rc
    local ok_rc, rc_or_err = pcall(require, "readcollection")
    if ok_rc and rc_or_err then
        rc = rc_or_err
        if rc._read then pcall(function() rc:_read() end) end
    end

    -- Always distribute across 5 slots so spacing is consistent regardless
    -- of how many collections are selected.
    local gap = math.floor((inner_w - 5 * d.stack_cell_w) / 4)
    local row = HorizontalGroup:new{ align = "top" }

    for i = 1, cols do
        local coll_name = selected[i]
        local files     = rc and getCollectionFilesFromRC(rc, coll_name) or {}
        local count     = #files
        local thumb     = buildCoverCell(files, overrides[coll_name], coll_name, count, d)

        -- Label centred over the cover thumbnail only, not the full stack_cell_w
        -- (which includes the spine on the left). A leading HorizontalSpan
        -- of stack_extra pushes the label to start at the thumbnail left edge.
        local display_name = coll_name
        do
            local TBR = package.loaded["desktop_modules/module_tbr"]
            if TBR and coll_name == TBR.TBR_COLL_NAME then
                display_name = TBR.getDisplayName()
            end
        end
        -- d.tbw_line_h mirrors TextBoxWidget's internal line_height_px formula
        -- (math.floor(1.3 * font_size + 0.5)), calculated once in getDims so that
        -- coll_cell_h and the widget height are always in sync.
        local label_w = TextBoxWidget:new{
            text      = display_name,
            face      = Font:getFace("cfont", d.coll_lbl_fs),
            fgcolor   = CLR_TEXT_SUB,
            width     = d.coll_w,
            height    = d.tbw_line_h * 2,
            alignment = "center",
            height_overflow_show_ellipsis = true,
        }
        local label_aligned = HorizontalGroup:new{
            HorizontalSpan:new{ width = d.stack_extra },
            label_w,
        }

        local cell_vg = VerticalGroup:new{
            align = "center",
            thumb,
            VerticalSpan:new{ width = d.label_gap },
            label_aligned,
        }

        local tappable = InputContainer:new{
            dimen      = Geom:new{ w = d.stack_cell_w, h = d.coll_cell_h },
            [1]        = cell_vg,
            _coll_name = coll_name,
        }
        tappable.ges_events = {
            TapColl = {
                GestureRange:new{
                    ges   = "tap",
                    range = function() return tappable.dimen end,
                },
            },
        }
        function tappable:onTapColl()
            openCollection(self._coll_name)
            return true
        end

        row[#row + 1] = FrameContainer:new{
            bordersize   = 0, padding = 0,
            padding_left = (i > 1) and gap or 0,
            tappable,
        }
    end

    return FrameContainer:new{
        bordersize = 0, padding = PAD, padding_top = 0, padding_bottom = 0,
        row,
    }
end

function M.getHeight(_ctx)
    local d = getDims(Config.getModuleScale("collections", _ctx and _ctx.pfx),
                      Config.getThumbScale("collections", _ctx and _ctx.pfx))
    if #getSelectedCollections() == 0 then
        return Config.getScaledLabelH() + d.empty_h
    end
    return Config.getScaledLabelH() + d.coll_cell_h
end

-- Settings API (usados por getMenuItems e externamente pelo menu.lua legado)
function M.getSelected()       return getSelectedCollections() end
function M.saveSelected(list)  saveSelectedCollections(list) end
function M.getCoverOverrides() return getCoverOverrides() end
function M.saveCoverOverrides(t) saveCoverOverrides(t) end
function M.saveCoverOverride(coll_name, filepath)
    local t = getCoverOverrides(); t[coll_name] = filepath; saveCoverOverrides(t)
end
function M.getBadgePosition()      return getBadgePosition() end
function M.saveBadgePosition(v)    saveBadgePosition(v) end




local function _makeScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size."),
        get          = function() return Config.getModuleScalePct("collections", pfx) end,
        set          = function(v) Config.setModuleScale(v, "collections", pfx) end,
        refresh      = ctx_menu.refresh,
    })
end

local function _makeItemLabelScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func = function() return _lc("Text Size") end,
        title     = _lc("Text Size"),
        info      = _lc("Scale for the collection name text.\n100% is the default size."),
        get       = function() return Config.getItemLabelScalePct("collections", pfx) end,
        set       = function(v) Config.setItemLabelScale(v, "collections", pfx) end,
        refresh   = ctx_menu.refresh,
    })
end
function M.getMenuItems(ctx_menu)
    local _UIManager  = ctx_menu.UIManager
    local InfoMessage = ctx_menu.InfoMessage
    local SortWidget  = ctx_menu.SortWidget
    local refresh     = ctx_menu.refresh
    local _lc         = ctx_menu._
    local N_lc        = _lc.ngettext

    local ok_rc, rc  = pcall(require, "readcollection")
    local all_colls  = {}
    if ok_rc and rc then
        if rc._read then pcall(function() rc:_read() end) end
        local fav = rc.default_collection_name or "favorites"
        if rc.coll then
            if rc.coll[fav] then
                all_colls[#all_colls + 1] = fav
            end
            local others = {}
            for name in pairs(rc.coll) do
                if name ~= fav then others[#others + 1] = name end
            end
            table.sort(others, function(a, b) return a:lower() < b:lower() end)
            for _, n in ipairs(others) do all_colls[#all_colls + 1] = n end
        end
    end
    -- Hide the TBR collection from the selection list when it is empty.
    do
        local TBR = package.loaded["desktop_modules/module_tbr"]
        if TBR then
            local filtered = {}
            for _, n in ipairs(all_colls) do
                if n == TBR.TBR_COLL_NAME then
                    if TBR.getTBRCount() > 0 then
                        filtered[#filtered + 1] = n
                    end
                else
                    filtered[#filtered + 1] = n
                end
            end
            all_colls = filtered
        end
    end

    local function openCoverPicker(coll_name)
        if not ok_rc then return end
        if rc._read then pcall(function() rc:_read() end) end
        local coll = rc.coll and rc.coll[coll_name]
        if not coll then
            _UIManager:show(InfoMessage:new{ text = _lc("Collection is empty."), timeout = 2 }); return
        end
        local fps = {}
        for fp in pairs(coll) do fps[#fps + 1] = fp end
        table.sort(fps)
        if #fps == 0 then
            _UIManager:show(InfoMessage:new{ text = _lc("Collection is empty."), timeout = 2 }); return
        end
        local overrides     = M.getCoverOverrides()
        local ButtonDialog  = require("ui/widget/buttondialog")
        local cover_buttons = {}
        local _n            = coll_name
        cover_buttons[#cover_buttons + 1] = {{
            text     = (not overrides[_n] and "✓ " or "  ") .. _lc("Auto (first book)"),
            callback = function()
                _UIManager:close(ctx_menu._cover_picker)
                M.clearCoverOverride(_n); refresh()
            end,
        }}
        for _loop_, fp in ipairs(fps) do
            local _fp   = fp
            local fname = fp:match("([^/]+)%.[^%.]+$") or fp
            local title = fname
            local ok_ds, ds = pcall(function()
                return require("docsettings"):open(_fp)
            end)
            if ok_ds and ds then
                local meta = ds:readSetting("doc_props") or {}
                title = meta.title or fname
            end
            cover_buttons[#cover_buttons + 1] = {{
                text     = ((overrides[_n] == _fp) and "✓ " or "  ") .. title,
                callback = function()
                    _UIManager:close(ctx_menu._cover_picker)
                    M.saveCoverOverride(_n, _fp); refresh()
                end,
            }}
        end
        cover_buttons[#cover_buttons + 1] = {{
            text     = _lc("Cancel"),
            callback = function() _UIManager:close(ctx_menu._cover_picker) end,
        }}
        ctx_menu._cover_picker = require("ui/widget/buttondialog"):new{
            title   = string.format(_lc("Cover for \"%s\""), _n),
            buttons = cover_buttons,
        }
        _UIManager:show(ctx_menu._cover_picker)
    end

    local items = {}
    items[#items + 1] = Config.makeLabelToggleItem("collections", _("Collections"), refresh, _lc)
    items[#items + 1] = {
        text = _lc("Arrange Collections"), keep_menu_open = true,
        callback = function()
            local cur_sel = M.getSelected()
            if #cur_sel < 2 then
                _UIManager:show(InfoMessage:new{
                    text = _lc("Select at least 2 collections to arrange."), timeout = 2 })
                return
            end
            local sort_items = {}
            for _loop_, n in ipairs(cur_sel) do
                sort_items[#sort_items + 1] = { text = n, orig_item = n }
            end
            _UIManager:show(SortWidget:new{
                title             = _lc("Arrange Collections"),
                item_table        = sort_items,
                covers_fullscreen = true,
                callback          = function()
                    local new_order = {}
                    for _loop_, item in ipairs(sort_items) do
                        new_order[#new_order + 1] = item.orig_item
                    end
                    M.saveSelected(new_order); refresh()
                end,
            })
        end,
    }
    items[#items + 1] = _makeScaleItem(ctx_menu)
    items[#items + 1] = _makeItemLabelScaleItem(ctx_menu)
    items[#items + 1] = Config.makeScaleItem({
        text_func = function() return ctx_menu._("Cover size") end,
        separator = true,
        title     = ctx_menu._("Cover size"),
        info      = ctx_menu._("Scale for the collection thumbnails only.\nThe label text follows the module scale.\n100% is the default size."),
        get       = function() return Config.getThumbScalePct("collections", ctx_menu.pfx) end,
        set       = function(v) Config.setThumbScale(v, "collections", ctx_menu.pfx) end,
        refresh   = ctx_menu.refresh,
    })
    items[#items + 1] = {
        text_func = function()
            return getBadgePosition() == "bottom"
                and _lc("Badge position: Bottom")
                or  _lc("Badge position: Top")
        end,
        keep_menu_open = true,
        callback = function()
            saveBadgePosition(getBadgePosition() == "bottom" and "top" or "bottom")
            refresh()
        end,
    }

    if #all_colls == 0 then
        items[#items + 1] = { text = _lc("No collections found."), enabled = false }
    else
        for _loop_, coll_name in ipairs(all_colls) do
            local _n = coll_name
            local _display_n = (function()
                local TBR = package.loaded["desktop_modules/module_tbr"]
                if TBR and _n == TBR.TBR_COLL_NAME then
                    return TBR.getDisplayName()
                end
                return _n
            end)()
            items[#items + 1] = {
                text_func = function()
                    local cur = M.getSelected()
                    for _loop_, n in ipairs(cur) do if n == _n then return _display_n end end
                    local rem = 4 - #cur
                    if rem <= 2 then return _display_n .. string.format(N_lc("  (%d left)", "  (%d left)", rem), rem) end
                    return _display_n
                end,
                checked_func = function()
                    for _loop_, n in ipairs(M.getSelected()) do
                        if n == _n then return true end
                    end
                    return false
                end,
                keep_menu_open = true,
                callback       = function()
                    local cur     = M.getSelected()
                    local new_sel = {}
                    local found   = false
                    for _loop_, s in ipairs(cur) do
                        if s == _n then found = true else new_sel[#new_sel + 1] = s end
                    end
                    if not found then
                        if #cur >= 5 then
                            _UIManager:show(InfoMessage:new{
                                text = _lc("Maximum 5 collections. Remove one first."), timeout = 2 })
                            return
                        end
                        new_sel[#new_sel + 1] = _n
                    end
                    M.saveSelected(new_sel); refresh()
                end,
                hold_callback = function() openCoverPicker(_n) end,
            }
        end
    end
    return items
end

return M