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
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local logger          = require("logger")
local lfs             = require("libs/libkoreader-lfs")
local _ = require("sui_i18n").translate
local N_ = require("sui_i18n").ngettext
local Config          = require("sui_config")

local UI           = require("sui_core")
local SUISettings  = require("sui_store")
local SUIStyle     = require("sui_style")
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
local _BASE_PH_COVER_FS  = SUIStyle.FS_TITLE    -- 22: placeholder initials font
local _BASE_COLL_LBL_FS  = SUIStyle.FS_DETAIL   -- 15: collection name label font
local _BASE_BADGE_FS     = 8   -- badge font (~0.375 x badge_sz) — proportional overlay, bypasses type scale
local _BASE_EMPTY_H      = Screen:scaleBySize(36)
local _BASE_EMPTY_FS     = SUIStyle.FS_BODY     -- 18: empty state

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
local SETTINGS_KEY       = "simpleui_coll_list"
local COVER_OVERRIDE_KEY = "simpleui_coll_covers"
local BADGE_POSITION_KEY = "simpleui_coll_badge_position"
local BADGE_COLOR_KEY    = "simpleui_coll_badge_color"
local BADGE_HIDDEN_KEY   = "simpleui_coll_badge_hidden"

local function getBadgePosition()
    return SUISettings:readSetting(BADGE_POSITION_KEY) or "top"
end
local function saveBadgePosition(v)
    SUISettings:saveSetting(BADGE_POSITION_KEY, v)
end

-- "dark"  = black background, white text, gray border.
-- "light" = white background, black text, gray border.
local function getBadgeColor()
    return SUISettings:readSetting(BADGE_COLOR_KEY) or "dark"
end
local function saveBadgeColor(v)
    SUISettings:saveSetting(BADGE_COLOR_KEY, v)
end

local function getBadgeHidden()
    return SUISettings:readSetting(BADGE_HIDDEN_KEY) or false
end
local function saveBadgeHidden(v)
    SUISettings:saveSetting(BADGE_HIDDEN_KEY, v)
end

local function getSelectedCollections()
    return SUISettings:readSetting(SETTINGS_KEY) or {}
end
local function saveSelectedCollections(list)
    SUISettings:saveSetting(SETTINGS_KEY, list)
end
local function getCoverOverrides()
    return SUISettings:readSetting(COVER_OVERRIDE_KEY) or {}
end
local function saveCoverOverrides(t)
    SUISettings:saveSetting(COVER_OVERRIDE_KEY, t)
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
local function buildCoverCell(files, cover_override, coll_name, count, d, accent_color)
    local front_fp = cover_override
    if front_fp and lfs.attributes(front_fp, "mode") ~= "file" then front_fp = nil end
    if not front_fp and #files > 0 then front_fp = files[1] end

    -- Main cover (or placeholder).
    local cover
    if front_fp and lfs.attributes(front_fp, "mode") == "file" then
        local raw = getBookCover(front_fp, d.coll_w, d.coll_h)
        if raw then
            cover = FrameContainer:new{
                bordersize = SUIStyle.BADGE_BORDER_SZ, color = _CLR_COVER_BORDER,
                padding    = 0, margin = 0,
                dimen      = Geom:new{ w = d.coll_w, h = d.coll_h },
                raw,
            }
        end
    end
    if not cover then
        cover = FrameContainer:new{
            bordersize = SUIStyle.BADGE_BORDER_SZ, color = _CLR_COVER_BORDER,
            background = _CLR_COVER_BG, padding = 0,
            dimen      = Geom:new{ w = d.coll_w, h = d.coll_h },
            CenterContainer:new{
                dimen = Geom:new{ w = d.coll_w, h = d.coll_h },
                TextWidget:new{
                    text = (coll_name or "?"):sub(1, 2):upper(),
                    face = Font:getFace(SUIStyle.FACE_REGULAR, d.ph_cover_fs),
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
        background = accent_color or Blitbuffer.COLOR_BLACK,
        dimen      = Geom:new{ w = d.coll_w, h = d.accent_h },
        VerticalSpan:new{ width = 0 },
    }

    local base = VerticalGroup:new{ align = "left", stack, accent }

    if getBadgeHidden() then
        return OverlapGroup:new{
            dimen = Geom:new{ w = d.stack_cell_w, h = d.cell_h },
            base,
        }, stack, front_fp
    end

    local dark      = getBadgeColor() == "dark"
    local bg_color  = dark and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local fg_color  = dark and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK

    local badge_tw = UI.makeColoredText{
        text    = tostring(math.min(count, 99)),
        face    = Font:getFace(SUIStyle.FACE_REGULAR, d.badge_fs),
        fgcolor = fg_color,
        bold    = true,
    }
    local _orig_pt = badge_tw.paintTo
    badge_tw.paintTo = function(self, bb, x, y)
        _orig_pt(self, bb, x, y + 1) -- HACK: Muda este +1 para +2 ou +3 conforme a tua fonte precisar
    end

    local badge_inner = CenterContainer:new{
        dimen = Geom:new{ w = d.badge_sz, h = d.badge_sz },
        badge_tw,
    }
    local badge = FrameContainer:new{
        bordersize = SUIStyle.BADGE_BORDER_SZ,
        color      = SUIStyle.BADGE_BORDER_CLR,
        background = bg_color,
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
    }, stack, front_fp
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
M.enabled_key = "collections_enabled"
M.default_on  = false
M.has_covers  = true   -- activates e-ink dithering and cover poll

function M.setEnabled(pfx, on)
    SUISettings:saveSetting(pfx .. "collections_enabled", on)
end

local MAX_COLL = 5

function M.getCountLabel(_pfx)
    local n   = #M.getSelected()
    local rem = MAX_COLL - n
    if n == 0   then return nil end
    if rem <= 0 then return string.format(_("(%d/%d — at limit)"), n, MAX_COLL) end
    return string.format(N_("(%d/%d — %d left)", "(%d/%d — %d left)", rem), n, MAX_COLL, rem)
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
    local ok_ss, SUIStyle = pcall(require, "sui_style")
    local _theme_fg        = ok_ss and SUIStyle and SUIStyle.getThemeColor("fg")
    local _theme_secondary = ok_ss and SUIStyle and SUIStyle.getThemeColor("text_secondary")
    local _theme_accent    = ok_ss and SUIStyle and SUIStyle.getThemeColor("accent")
    local CLR_TEXT_SUB_EFF = _theme_secondary or _theme_fg or CLR_TEXT_SUB
    local CLR_ACCENT_EFF   = _theme_accent or Blitbuffer.COLOR_BLACK
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
        -- Do NOT call _rc_sync:_read() here — it destructively reloads
        -- rc.coll/rc.coll_settings from disk and can wipe out an
        -- in-memory-only collection the native Collections UI hasn't
        -- flushed to disk yet. The singleton is already live in-process.
    end
    local synced_raw = {}
    if _rc_sync and (_rc_sync.coll or _rc_sync.coll_folders) then
        local coll_set = {}
        if _rc_sync.coll then for n in pairs(_rc_sync.coll) do coll_set[n] = true end end
        if _rc_sync.coll_folders then for n in pairs(_rc_sync.coll_folders) do coll_set[n] = true end end
        for _, n in ipairs(selected_raw) do
            if coll_set[n] then
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
        local hold_on = SUISettings:nilOrTrue("simpleui_hs_settings_on_hold")
        local ph_text = hold_on and _("No collections selected  —  long press to configure")
                                 or _("No collections selected")
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = d.empty_h },
            UI.makeColoredText{
                text    = ph_text,
                face    = Font:getFace(SUIStyle.FACE_REGULAR, d.empty_fs),
                fgcolor = CLR_TEXT_SUB_EFF,
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
        -- Not calling rc:_read() — see note above; it can wipe uncommitted
        -- collection changes made via the native Collections UI.
    end

    -- Always distribute across 5 slots so spacing is consistent regardless
    -- of how many collections are selected.
    local gap = math.floor((inner_w - 5 * d.stack_cell_w) / 4)
    local row = HorizontalGroup:new{ align = "top" }
    local cover_slots = {}

    for i = 1, cols do
        local coll_name = selected[i]
        local files     = rc and getCollectionFilesFromRC(rc, coll_name) or {}
        local count     = #files
        local thumb, stack, front_fp = buildCoverCell(files, overrides[coll_name], coll_name, count, d, CLR_ACCENT_EFF)

        -- Record cover slot: cover is at stack[5] (after two edgeLine groups and two spans).
        -- Only record if there is a real fp to reload from.
        if stack and front_fp then
            cover_slots[#cover_slots+1] = {
                container = stack,
                idx       = 5,
                fp        = front_fp,
                w         = d.coll_w,
                h         = d.coll_h,
            }
        end

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
   
        local label_args = {
            text      = display_name,
            face      = Font:getFace(SUIStyle.FACE_REGULAR, d.coll_lbl_fs),
            bold      = true,
            fgcolor   = CLR_TEXT_SUB_EFF,
            width     = d.coll_w,
            max_lines = 2,
            alignment = "center",
        }

        local label_w
        if ctx.has_wallpaper then
            local ok_tbx, tbx = pcall(UI.makeAlphaTextBox, label_args)
            if ok_tbx then
                label_w = tbx
            else
                logger.warn("simpleui: module_collections: makeAlphaTextBox failed, falling back: " .. tostring(tbx))
                label_w = TextBoxWidget:new(label_args)
            end
        else
            label_w = TextBoxWidget:new(label_args)
        end

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

    local show_frame = SUISettings:isTrue(ctx.pfx .. "collections_show_frame")
    local solid_bg   = SUISettings:isTrue(ctx.pfx .. "collections_solid_bg")
    local has_box    = show_frame or solid_bg
    local border_sz  = show_frame and SUIStyle.BORDER_SZ or 0
    local radius     = has_box and math.floor(Screen:scaleBySize(12) * scale) or 0
    local border_color = Blitbuffer.gray(0.72)
    local bg_color   = nil
    if ok_ss and SUIStyle then
        border_color = SUIStyle.getThemeColor("separator") or border_color
        if solid_bg then bg_color = SUIStyle.getThemeColor("bg") or Blitbuffer.COLOR_WHITE end
    elseif solid_bg then
        bg_color = Blitbuffer.COLOR_WHITE
    end

    local result = FrameContainer:new{
        bordersize = border_sz,
        radius     = radius,
        color      = border_color,
        background = bg_color,
        padding = PAD, padding_top = has_box and PAD or 0, padding_bottom = has_box and (PAD + PAD2) or 0,
        row,
    }
    result._cover_slots = cover_slots
    return result
end

function M.updateCovers(widget, _ctx)
    if not widget or not widget._cover_slots then return true end
    local all_done = true
    for _, slot in ipairs(widget._cover_slots) do
        local raw = Config.getCoverBB(slot.fp, slot.w, slot.h, nil, 0.10)
        if raw then
            local ok, img = pcall(function()
                return ImageWidget:new{
                    image            = raw,
                    image_disposable = false,
                    width            = slot.w,
                    height           = slot.h,
                    scale_factor     = 1,
                }
            end)
            if ok and img then
                slot.container[slot.idx] = FrameContainer:new{
                    bordersize = SUIStyle.BADGE_BORDER_SZ, color = _CLR_COVER_BORDER,
                    padding    = 0, margin = 0,
                    dimen      = Geom:new{ w = slot.w, h = slot.h },
                    img,
                }
            end
        elseif not Config.isCoverMissing(slot.fp) then
            all_done = false
        end
    end
    return all_done
end

function M.getHeight(ctx)
    local pfx         = ctx and ctx.pfx
    local scale       = Config.getModuleScale("collections", pfx)
    local thumb_scale = Config.getThumbScale("collections", pfx)
    local lbl_scale   = Config.getItemLabelScale("collections", pfx)
    local d = getDims(scale, thumb_scale)
    -- Mirror the lbl_scale adjustment that build() applies so the heights stay in sync
    -- when the user has set a per-module text scale different from 1.0.
    if lbl_scale ~= 1.0 then
        d.coll_lbl_fs = math.max(6, math.floor(d.coll_lbl_fs * lbl_scale))
        d.tbw_line_h  = math.floor(1.3 * d.coll_lbl_fs + 0.5)
        d.coll_cell_h = d.coll_h + d.accent_h + d.label_gap + 2 * d.tbw_line_h
    end
    if #getSelectedCollections() == 0 then
        return Config.getScaledLabelH() + d.empty_h
    end
    local h = d.coll_cell_h
    if SUISettings:isTrue(pfx .. "collections_show_frame") or SUISettings:isTrue(pfx .. "collections_solid_bg") then
        h = h + PAD * 2 + PAD2
    end
    return Config.getScaledLabelH() + h
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
function M.getBadgeColor()         return getBadgeColor() end
function M.saveBadgeColor(v)       saveBadgeColor(v) end
function M.getBadgeHidden()        return getBadgeHidden() end
function M.saveBadgeHidden(v)      saveBadgeHidden(v) end




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
    local N_lc        = ctx_menu.N_

    local ok_rc, rc  = pcall(require, "readcollection")
    local all_colls  = {}
    if ok_rc and rc then
        -- Not calling rc:_read() — see note above; it can wipe uncommitted
        -- collection changes made via the native Collections UI.
        local fav = rc.default_collection_name or "favorites"
        local coll_set = {}
        if rc.coll then for n in pairs(rc.coll) do coll_set[n] = true end end
        if rc.coll_folders then for n in pairs(rc.coll_folders) do coll_set[n] = true end end
        if coll_set[fav] then
            all_colls[#all_colls + 1] = fav
            coll_set[fav] = nil
        end
        local others = {}
        for name in pairs(coll_set) do others[#others + 1] = name end
        table.sort(others, function(a, b) return a:lower() < b:lower() end)
        for _, n in ipairs(others) do all_colls[#all_colls + 1] = n end
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
        -- Not calling rc:_read() — see note above; it can wipe uncommitted
        -- collection changes made via the native Collections UI.
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
    items[#items + 1] = {
        text = _lc("Collections"), keep_menu_open = true,
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
            local function on_save()
                local new_order = {}
                for _loop_, item in ipairs(sort_items) do
                    new_order[#new_order + 1] = item.orig_item
                end
                M.saveSelected(new_order); refresh()
            end
            _UIManager:show(SortWidget:new{
                title             = _lc("Collections"),
                item_table        = sort_items,
                covers_fullscreen = true,
                callback          = on_save,
            })
        end,
        sui_build = ctx_menu.is_sui and function(ctx, _item)
            local SUIWindow = require("sui_window")
            return SUIWindow.ListRow{
                title        = _lc("Collections"),
                    subtitle     = function()
                        local cur_sel = M.getSelected()
                        if #cur_sel == 0 then return _lc("No items selected.") end
                        local names = {}
                        local TBR = package.loaded["desktop_modules/module_tbr"]
                        for _, n in ipairs(cur_sel) do
                            names[#names + 1] = (TBR and n == TBR.TBR_COLL_NAME) and TBR.getDisplayName() or n
                        end
                        return table.concat(names, "  ·  ")
                    end,
                inner_w      = ctx.inner_w,
                    item_count   = function() return #M.getSelected() end,
                    max_items    = MAX_COLL,
                show_chevron = true,
                on_tap       = function()
                    local cur_sel = M.getSelected()
                    local sort_items = {}
                    for _, n in ipairs(cur_sel) do
                        local _display_n = n
                        local TBR = package.loaded["desktop_modules/module_tbr"]
                        if TBR and n == TBR.TBR_COLL_NAME then _display_n = TBR.getDisplayName() end
                        sort_items[#sort_items + 1] = { text = _display_n, orig_item = n }
                    end
                    
                    ctx.push("arrange", {
                        title = _lc("Collections"),
                        items = sort_items,
                        empty_text = _lc("No items selected."),
                            item_count = function() return #M.getSelected() end,
                            max_items  = MAX_COLL,
                        on_delete = function(item) end,
                        on_change = function(items_to_save)
                            local new_order = {}
                            for _, it in ipairs(items_to_save) do new_order[#new_order + 1] = it.orig_item end
                            M.saveSelected(new_order)
                            refresh()
                        end,
                        footer_text = _lc("Add Collection"),
                        footer_action = function(ctx2)
                            local cur = M.getSelected()
                            local picker_items = {}
                            for _, _n in ipairs(all_colls) do
                                local is_sel = false
                                for _, s in ipairs(cur) do if s == _n then is_sel = true break end end
                                if not is_sel then
                                    local _display_n = _n
                                    local TBR = package.loaded["desktop_modules/module_tbr"]
                                    if TBR and _n == TBR.TBR_COLL_NAME then _display_n = TBR.getDisplayName() end
                                    picker_items[#picker_items + 1] = {
                                        text   = _display_n,
                                        on_tap = function(picker_ctx)
                                            local new_sel = M.getSelected()
                                            if #new_sel >= MAX_COLL then
                                                local InfoMessage = ctx_menu.InfoMessage or require("ui/widget/infomessage")
                                                local uim = ctx_menu.UIManager or require("ui/uimanager")
                                                uim:show(InfoMessage:new{
                                                    text = _lc("Maximum 5 collections. Remove one first."), timeout = 2,
                                                })
                                                return
                                            end
                                            new_sel[#new_sel + 1] = _n
                                            M.saveSelected(new_sel)
                                            table.insert(sort_items, { text = _display_n, orig_item = _n })
                                            refresh()
                                            picker_ctx.pop()
                                            ctx2.repaint()
                                        end,
                                    }
                                end
                            end
                            ctx2.push("item_picker", {
                                title = _lc("Add Collection"),
                                items = picker_items,
                            })
                        end
                    })
                end
            }
        end or nil,
    }

    items[#items + 1] = _makeScaleItem(ctx_menu)
    items[#items + 1] = _makeItemLabelScaleItem(ctx_menu)
    items[#items + 1] = Config.makeScaleItem({
        text_func = function() return ctx_menu._("Cover Size") end,
        separator = true,
        title     = ctx_menu._("Cover Size"),
        info      = ctx_menu._("Scale for the collection thumbnails only.\nThe label text follows the module scale.\n100% is the default size."),
        get       = function() return Config.getThumbScalePct("collections", ctx_menu.pfx) end,
        set       = function(v) Config.setThumbScale(v, "collections", ctx_menu.pfx) end,
        refresh   = ctx_menu.refresh,
    })

    items[#items + 1] = Config.makeLabelToggleItem("collections", _("Collections"), refresh, _lc)
    items[#items + 1] = {
        text           = _lc("Frame"),
        checked_func   = function() return SUISettings:isTrue(ctx_menu.pfx .. "collections_show_frame") end,
        keep_menu_open = true,
        callback       = function()
            SUISettings:saveSetting(ctx_menu.pfx .. "collections_show_frame", not SUISettings:isTrue(ctx_menu.pfx .. "collections_show_frame"))
            refresh()
        end,
    }
    items[#items + 1] = {
        text           = _lc("Solid Background"),
        checked_func   = function() return SUISettings:isTrue(ctx_menu.pfx .. "collections_solid_bg") end,
        keep_menu_open = true,
        callback       = function()
            SUISettings:saveSetting(ctx_menu.pfx .. "collections_solid_bg", not SUISettings:isTrue(ctx_menu.pfx .. "collections_solid_bg"))
            refresh()
        end,
    }
    items[#items + 1] = {
        text         = _lc("Badge"),
        sub_item_table = {
            {
                text           = _lc("Hidden"),
                checked_func   = function() return getBadgeHidden() end,
                keep_menu_open = true,
                separator      = true,
                callback       = function()
                    saveBadgeHidden(not getBadgeHidden())
                    refresh()
                end,
            },
            {
                text           = _lc("Top"),
                radio          = true,
                checked_func   = function() return not getBadgeHidden() and getBadgePosition() == "top" end,
                enabled_func   = function() return not getBadgeHidden() end,
                keep_menu_open = true,
                callback       = function() saveBadgePosition("top"); refresh() end,
            },
            {
                text           = _lc("Bottom"),
                radio          = true,
                checked_func   = function() return not getBadgeHidden() and getBadgePosition() == "bottom" end,
                enabled_func   = function() return not getBadgeHidden() end,
                keep_menu_open = true,
                separator      = true,
                callback       = function() saveBadgePosition("bottom"); refresh() end,
            },
            {
                text           = _lc("Dark"),
                radio          = true,
                checked_func   = function() return getBadgeColor() == "dark" end,
                keep_menu_open = true,
                callback       = function() saveBadgeColor("dark"); refresh() end,
            },
            {
                text           = _lc("Light"),
                radio          = true,
                checked_func   = function() return getBadgeColor() == "light" end,
                keep_menu_open = true,
                callback       = function() saveBadgeColor("light"); refresh() end,
            },
        },
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
                sui_hidden = ctx_menu.is_sui or nil,
            }
        end
    end
    return items
end

return M