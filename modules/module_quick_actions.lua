-- module_quick_actions.lua — Simple UI
-- Module: Quick Actions Row (dynamic instances).
-- Exposes M.instanciable = true and M.makeInstance(id) for the registry.

local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local TextWidget      = require("ui/widget/textwidget")
local Screen          = Device.screen
local T               = require("ffi/util").template
local _ = require("infra/sui_i18n").translate
local N_ = require("infra/sui_i18n").ngettext
local Config          = require("infra/sui_config")
local Arrange         = require("features/sui_arrange")
local QA              = require("features/sui_quickactions")
local QARenderer      = require("engines/sui_quickactions_render")

local UI  = require("infra/sui_core")
local SUISettings = require("infra/sui_store")
local Backdrop    = require("infra/sui_backdrop")
local SUIWallpaper = require("features/sui_wallpaper")
local SUIStyle    = require("features/sui_style")
local PAD = UI.PAD
local LABEL_H = UI.LABEL_H
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

local _BASE_PH_FS = SUIStyle.FS_BODY    -- 18: placeholder text


local _BASE_FRAME_SZ  = Screen:scaleBySize(88)
local _BASE_LBL_SP    = Screen:scaleBySize(7)
local _BASE_LBL_H     = Screen:scaleBySize(20)
local _BASE_LBL_FS    = SUIStyle.FS_DETAIL  -- 15: quick-action label text
-- Fixed inter-icon gap used by the "Left"/"Right" alignment modes (packed
-- layout). Scales with the same module scale as everything else so
-- alignment changes never touch icon/frame sizing — only where the row of
-- icons (as a whole) sits within the module's width.
local _BASE_ICON_GAP  = Screen:scaleBySize(24)
-- Vertical gap between the rows of the grid layout.
local _BASE_ROW_GAP   = Screen:scaleBySize(12)

-- Hard cap on how many actions a single Quick Actions row can hold. It is the
-- "add action" limit of the row layout (see _maxItems) so the row's item sizing
-- always leaves room for a fully-populated row, whatever alignment mode is chosen.
local MAX_QA_ITEMS = 6

-- Grid layout: columns x rows of square buttons, whose size is capped by the
-- module's Scale and shrinks only when a column is narrower than that.
local GRID_MAX_COLS     = 7
local GRID_MAX_ROWS     = 4
local GRID_DEFAULT_COLS = 4
local GRID_DEFAULT_ROWS = 2
local LAYOUT_VALUES     = { "row", "grid" }

-- Smallest gap we're willing to fall back to between icons when the "nice"
-- packed gap (_BASE_ICON_GAP, scaled) doesn't leave enough room for
-- MAX_QA_ITEMS icons at their current size — keeps icons from ever touching
-- or overlapping in Left/Right mode, or from being pushed flush together
-- with zero space in the default (justified) mode.
local _MIN_ICON_GAP = Screen:scaleBySize(4)

-- Naive ("100%", unconstrained) baseline dims, before any per-width fit
-- adjustment.
local function _naiveBaseDims()
    return {
        frame_sz = _BASE_FRAME_SZ,
        icon_gap = _BASE_ICON_GAP,
    }
end

-- Re-anchors what "Scale = 100%" means for a row of this inner_w: shrinks
-- the naive baseline (frame size and — as a last resort — the gap) just
-- enough that MAX_QA_ITEMS icons fit inside inner_w at the module's nice gap.
-- On anything roomy enough already, this is a no-op and the naive baseline is
-- returned unchanged.
-- Deliberately re-anchors the *baseline* rather than clamping the final,
-- already-scaled dims: clamping after scaling would make every Scale value
-- collapse to the same on-screen size once a full row stopped fitting,
-- silently turning the Scale setting into a no-op. Anchoring the baseline
-- instead means Scale = 100% guarantees a full row fits, while Scale > 100%
-- still visibly grows icons from there (even if that means a fully-populated
-- row no longer fits — that's now an intentional result of the user raising
-- Scale, not something happening by default).
local _fit_baseline_cache = {}
local function _getFitBaseline(inner_w)
    if not inner_w or inner_w <= 0 then return _naiveBaseDims() end
    local cached = _fit_baseline_cache[inner_w]
    if cached then return cached end

    local base = _naiveBaseDims()
    local gap = base.icon_gap
    local max_frame = math.floor((inner_w - (MAX_QA_ITEMS - 1) * gap) / MAX_QA_ITEMS)
    if max_frame < base.frame_sz then
        if max_frame < 16 then
            -- Even a minimal icon wouldn't leave room for the nice gap —
            -- shrink the gap itself before shrinking icons any further.
            gap = _MIN_ICON_GAP
            max_frame = math.floor((inner_w - (MAX_QA_ITEMS - 1) * gap) / MAX_QA_ITEMS)
        end
        max_frame = math.max(16, max_frame)
        base.frame_sz = max_frame
        base.icon_gap = gap
    end
    _fit_baseline_cache[inner_w] = base
    return base
end

-- inner_w is optional: pass it whenever it's known (build()/getHeight()) so
-- Scale = 100% guarantees MAX_QA_ITEMS icons fit; omit it (e.g. the Quick
-- Actions folder-grid preview in sui_quickactions.lua, which sizes its own
-- rows explicitly per chunk) to get the plain, unconstrained baseline.
-- grid_cols (grid layout): the button is the Scale size, capped by what a
-- column of inner_w leaves room for.
local function _getQADims(scale, inner_w, grid_cols)
    scale = scale or 1.0
    local base      = grid_cols and _naiveBaseDims() or _getFitBaseline(inner_w)
    local frame_sz  = math.max(24, math.floor(base.frame_sz * scale))
    if grid_cols and inner_w and inner_w > 0 then
        frame_sz = math.max(16, math.min(frame_sz, math.floor(inner_w / grid_cols) - _MIN_ICON_GAP))
    end
    local cell      = QARenderer.cellDims(frame_sz)
    local lbl_sp    = math.max(1,  math.floor(_BASE_LBL_SP    * scale))
    local lbl_h     = math.max(8,  math.floor(_BASE_LBL_H     * scale))
    return {
        icon_sz   = cell.icon_sz,
        frame_pad = cell.frame_pad,
        frame_sz  = cell.icon_sz + cell.frame_pad * 2,
        corner_r  = cell.corner_r,
        lbl_sp    = lbl_sp,
        lbl_h     = lbl_h,
        lbl_fs    = math.max(6, math.floor(_BASE_LBL_FS * scale)),
        icon_gap  = math.max(4, math.floor(base.icon_gap * scale)),
        row_gap   = math.max(4, math.floor(_BASE_ROW_GAP * scale)),
    }
end

-- Height of one button with its label.
local function _cellHeight(d, show_labels)
    return show_labels and (d.frame_sz + d.lbl_sp + d.lbl_h) or d.frame_sz
end

-- Height of `rows` rows of buttons in the grid layout.
local function _gridHeight(d, show_labels, rows)
    return rows * _cellHeight(d, show_labels) + math.max(0, rows - 1) * d.row_gap
end

-- Grid of an instance, { cols =, rows = }; nil in the row layout.
local function _readGrid(inst_id, pfx)
    if Config.readChoice(pfx .. inst_id .. "_layout", LAYOUT_VALUES, "row") ~= "grid" then return nil end
    return {
        cols = Config.readClampedInt(pfx .. inst_id .. "_grid_cols", 1, GRID_MAX_COLS, GRID_DEFAULT_COLS),
        rows = Config.readClampedInt(pfx .. inst_id .. "_grid_rows", 1, GRID_MAX_ROWS, GRID_DEFAULT_ROWS),
    }
end

-- Most actions an instance holds: a full grid, else a row.
local function _maxItems(inst_id, pfx)
    local grid = _readGrid(inst_id, pfx)
    return grid and grid.cols * grid.rows or MAX_QA_ITEMS
end

-- ---------------------------------------------------------------------------
-- Action entry resolution and QA validity cache
-- Delegated to sui_quickactions (single source of truth).
-- ---------------------------------------------------------------------------

local function invalidateCustomQACache()
    QA.invalidateCustomQACache()
end

-- ---------------------------------------------------------------------------
-- Core widget builder (shared by all slots)
-- ---------------------------------------------------------------------------
-- `on_stops(stops, row)`, when given, receives the buttons as { id, widget }
-- D-pad focus stops, left to right: all of them in the row layout, one grid
-- row at a time (with its number) in the grid layout.
-- `grid` ({ cols =, rows = }) lays the buttons out on a grid instead of a row;
-- `align` does not apply to it.
local function buildQAWidget(w, action_ids, show_labels, on_tap_fn, d, shape, surface, colors, align, on_stops, grid)
    local clr_blk = colors and colors.blk or SUIStyle.COLOR.text_primary
    local clr_sub = colors and colors.sub or CLR_TEXT_SUB
    local ph_fs = math.max(8, math.floor(_BASE_PH_FS * (d.frame_sz / _BASE_FRAME_SZ)))
    local function _placeholder()
        local hold_on = SUISettings:nilOrTrue("simpleui_hs_settings_on_hold")
        local ph_text = hold_on and _("No actions configured  —  long press to configure")
                                 or _("No actions configured")
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = d.frame_sz },
            TextWidget:new{
                text    = ph_text,
                face    = Font:getFace(SUIStyle.FACE_REGULAR, ph_fs),
                fgcolor = clr_sub,
                width   = w - PAD * 2,
            },
        }
    end

    if not action_ids or #action_ids == 0 then return _placeholder() end

    local valid_ids = QA.filterValidIds(action_ids)
    if #valid_ids == 0 then return _placeholder() end
    local n        = #valid_ids
    -- `w` is already label-aligned via module chrome outer margin.
    local inner_w  = w
    local lbl_h    = show_labels and d.lbl_h or 0
    local lbl_sp   = show_labels and d.lbl_sp or 0

    local function buildCell(aid)
        return QARenderer.buildCell(aid, {
            icon_sz        = d.icon_sz,
            frame_sz       = d.frame_sz,
            frame_pad      = d.frame_pad,
            corner_r       = d.corner_r,
            shape          = shape,
            surface        = surface,
            fgcolor        = clr_blk,
            show_label     = show_labels,
            lbl_sp         = lbl_sp,
            lbl_h          = lbl_h,
            lbl_fs         = d.lbl_fs,
            lbl_face       = d.lbl_face,
            lbl_bold       = d.lbl_bold,
            on_tap_fn      = on_tap_fn,
            tap_event_name = "TapQA",
            focusable      = on_stops ~= nil,
        })
    end

    if grid then
        -- Each button is centred in a slot one column wide.
        local slot_w = math.floor(inner_w / grid.cols)
        local count  = math.min(n, grid.cols * grid.rows)
        local rows   = VerticalGroup:new{ align = "left" }
        local row_n  = 0
        for first = 1, count, grid.cols do
            row_n = row_n + 1
            local row, stops = HorizontalGroup:new{ align = "top" }, {}
            for i = first, math.min(first + grid.cols - 1, count) do
                local tappable = buildCell(valid_ids[i])
                row[#row + 1] = CenterContainer:new{
                    dimen = Geom:new{ w = slot_w, h = _cellHeight(d, show_labels) },
                    tappable,
                }
                stops[#stops + 1] = { id = i, widget = tappable }
            end
            if row_n > 1 then rows[#rows + 1] = VerticalSpan:new{ width = d.row_gap } end
            rows[#rows + 1] = row
            if on_stops then on_stops(stops, row_n) end
        end
        return FrameContainer:new{
            bordersize   = 0, padding = 0,
            padding_left = math.floor((inner_w - grid.cols * slot_w) / 2),
            rows,
        }
    end

    align = align or "current"
    local gap, left_off
    if align == "left" or align == "right" then
        -- Packed layout: icons keep their normal size (d.frame_sz, set by
        -- the module's Scale setting — untouched here) but sit next to each
        -- other with a fixed gap, anchored to one edge of the row, instead
        -- of being spread to fill the whole width.
        gap = n <= 1 and 0 or d.icon_gap
        local packed_w = n * d.frame_sz + math.max(0, n - 1) * gap
        left_off = (align == "right") and math.max(0, inner_w - packed_w) or 0
    else
        -- "current" — original behaviour, unchanged: icons spread evenly
        -- across the full row width (n>1), a single icon is centred.
        gap      = n <= 1 and 0 or math.floor((inner_w - n * d.frame_sz) / (n - 1))
        left_off = n == 1 and math.floor((inner_w - d.frame_sz) / 2) or 0
    end

    local row   = HorizontalGroup:new{ align = "top" }
    local stops = {}

    for i = 1, n do
        local tappable = buildCell(valid_ids[i])

        if i > 1 then
            row[#row + 1] = HorizontalSpan:new{ width = gap }
        end
        row[#row + 1] = tappable
        stops[i] = { id = i, widget = tappable }
    end
    if on_stops then on_stops(stops) end

    return FrameContainer:new{
        bordersize   = 0, padding = 0,
        padding_left = left_off,
        row,
    }
end

-- ---------------------------------------------------------------------------
-- Slot factory — creates one module descriptor per slot
-- ---------------------------------------------------------------------------
local _label_scale_migrated = {}

local function _migrateLabelScale(mod_id, pfx)
    pfx = pfx or "simpleui_hs_"
    local tag = pfx .. mod_id
    if _label_scale_migrated[tag] then return end
    _label_scale_migrated[tag] = true
    local text_key = pfx .. mod_id .. "_text_scale_label"
    if SUISettings:get(text_key) == nil then
        local pct = Config.getItemLabelScalePct(mod_id, pfx)
        if pct ~= Config.SCALE_DEF then
            Config.setTextStyleScale(pct, mod_id, "label", pfx)
        end
    end
    SUISettings:del(pfx .. mod_id .. "_item_label_scale")
end

local function makeInstance(inst_id)
    -- Keys built at call-time using ctx.pfx — works for any page prefix.
    local slot_suffix = inst_id
    local SHAPE_KEY    = slot_suffix .. "_shape"
    local LOOK_KEY     = slot_suffix .. "_bg"            -- single-choice look of earlier versions
    local ALIGN_KEY    = slot_suffix .. "_align"
    local SURFACE_KEY  = slot_suffix .. "_btn"
    local STRENGTH_KEY = SURFACE_KEY .. "_strength"

    local function getShape(pfx)
        return SUISettings:readSetting(pfx .. SHAPE_KEY) or "rounded_square"
    end

    -- Surface of the buttons; the look stored by earlier versions is
    -- converted on first use (see Backdrop.migrateLook).
    local function buttonSurface(pfx)
        local surface = Backdrop.surface("button", pfx .. SURFACE_KEY, pfx .. STRENGTH_KEY)
        Backdrop.migrateLook(surface, pfx .. LOOK_KEY)
        return surface
    end

    -- "current" (default) = existing behaviour, icons spread across the full
    -- module width. "left"/"right" pack them (same sizes, fixed gap —
    -- see buildQAWidget) against one edge instead.
    local ALIGN_VALUES = { "current", "left", "right" }
    local function getAlign(pfx)
        return Config.readChoice(pfx .. ALIGN_KEY, ALIGN_VALUES, "current")
    end

    local S = {}
    S.id         = inst_id
    S.name       = _("Quick Actions Row")
    S.label      = nil
    S.default_on = false
    S.text_elems = { "label" }

    function S.isEnabled(pfx)
        return SUISettings:readSetting(pfx .. slot_suffix .. "_enabled") == true
    end

    function S.setEnabled(pfx, on)
        SUISettings:saveSetting(pfx .. slot_suffix .. "_enabled", on)
    end

    local function maxQA(pfx) return _maxItems(inst_id, pfx) end

    local _has_fl = nil
    local function actionAvailable(id)
        if id == "frontlight" then
            if _has_fl == nil then
                local ok, v = pcall(function() return Device:hasFrontlight() end)
                _has_fl = ok and v == true
            end
            return _has_fl
        end
        if QA.getBrowseMode(id) then
            local ok_bm, BM = pcall(require, "features/library/sui_library_browse")
            return ok_bm and BM and BM.isEnabled()
        end
        return true
    end

    local function getQAPool()
        local available = {}
        -- QA.allIds() — NOT QA.iterBuiltin() — so externally registered
        -- actions (e.g. a Custom Screen's "open_custom_screen:<id>" QA, see
        -- infra/sui_custom_screens.lua) show up here too. iterBuiltin() only
        -- covers the fixed built-in descriptor list, which is why Custom
        -- Screens used to be pickable from the Quick Settings bar (built via
        -- QA.allIds()) but not from this Quick Actions Row module.
        for _, id in ipairs(QA.allIds()) do
            if actionAvailable(id) then
                available[#available + 1] = {
                    id    = id,
                    label = id == "home" and Config.homeLabel() or QA.getMenuLabel(id),
                }
            end
        end
        for _, qa_id in ipairs(Config.getCustomQAList()) do
            local _qid = qa_id
            available[#available + 1] = { id = _qid, label = Config.getCustomQAConfig(_qid).label }
        end
        return available
    end

    local function makeQAMenuFallback(ctx_menu, slot_n)
        local items_key  = ctx_menu.pfx_qa .. slot_n .. "_items"
        local labels_key = ctx_menu.pfx_qa .. slot_n .. "_labels"
        local slot_label = _("Quick Actions Row")
        return {
            {
                text           = _("Hide Label"),
                checked_func   = function() return not SUISettings:nilOrTrue(labels_key) end,
                keep_menu_open = true,
                separator      = true,
                callback       = function()
                    SUISettings:saveSetting(labels_key, not SUISettings:nilOrTrue(labels_key))
                    ctx_menu.refresh()
                end,
            },
            Arrange.makeListItem{
                ctx_menu = ctx_menu,
                title    = _("Quick Actions"),
                labels   = {
                    action  = string.format(_("Arrange %s"), slot_label),
                    empty   = _("No items selected."),
                    too_few = _("Add at least 2 actions to arrange."),
                    full    = function(max)
                        return string.format(N_("The maximum of %d action per module has been reached. Remove one first.",
                            "The maximum of %d actions per module has been reached. Remove one first.", max), max)
                    end,
                },
                max    = maxQA(ctx_menu.pfx),
                pool   = getQAPool,
                getIds = function() return SUISettings:readSetting(items_key) or {} end,
                setIds = function(ids) SUISettings:saveSetting(items_key, ids) end,
            },
        }
    end

    function S.getCountLabel(pfx)
        local n   = #(SUISettings:readSetting(pfx .. slot_suffix .. "_items") or {})
        local max = maxQA(pfx)
        local rem = max - n
        if n == 0   then return nil end
        if rem <= 0 then return string.format(_("(%d/%d — at limit)"), n, max) end
        return string.format(N_("(%d/%d — %d left)", "(%d/%d — %d left)", rem), n, max, rem)
    end

    function S.build(w, ctx)
        if not S.isEnabled(ctx.pfx) then return nil end
        -- Items and labels are stored under pfx_qa (the short QA prefix) so
        -- that the menu writers (makeQAMenu / makeQAMenuFallback) and the widget
        -- builder read/write the same settings key.
        local qa_pfx      = ctx.pfx_qa or ctx.pfx
        local items_key   = qa_pfx .. slot_suffix .. "_items"
        local labels_key  = qa_pfx .. slot_suffix .. "_labels"
        local qa_ids      = SUISettings:readSetting(items_key) or {}
        local show_labels = SUISettings:nilOrTrue(labels_key)
        local lf          = ctx.landscape_factor or 1
        -- Uses the RAW module scale: `w` (this column's width) is already
        -- narrowed for landscape upstream, and _getFitBaseline derives the
        -- icon/frame sizing from that same narrowed width — multiplying by
        -- landscape_factor too would narrow it twice (see GridRenderer.build
        -- in sui_book_grid.lua, which avoids the same double-narrowing for
        -- the same reason).
        -- `w` is already chrome contentWidth (label-aligned).
        local grid        = _readGrid(inst_id, ctx.pfx)
        local d           = _getQADims(Config.getModuleScaleRaw(S.id, ctx.pfx), w, grid and grid.cols)
        _migrateLabelScale(S.id, ctx.pfx)
        local styles = Config.resolveTextStyles(ctx, S.id, S.text_elems)
        d.lbl_fs = math.max(6, math.floor(d.lbl_fs * lf * (styles.label.scale or 1)))
        d.lbl_face, d.lbl_bold = SUIStyle.getTextFace(styles.label, d.lbl_fs)
        return buildQAWidget(w, qa_ids, show_labels, ctx.on_qa_tap, d, getShape(ctx.pfx), SUIWallpaper.resolveSurface(buttonSurface(ctx.pfx)), nil, getAlign(ctx.pfx),
            ctx.kbStops and function(stops, row) ctx.kbStops(row and (S.id .. ":r" .. row) or S.id, stops) end,
            grid)
    end

    function S.getHeight(ctx)
        local qa_pfx      = ctx.pfx_qa or ctx.pfx
        local labels_key  = qa_pfx .. slot_suffix .. "_labels"
        local show_labels = SUISettings:nilOrTrue(labels_key)
        -- Estimate content width the same way chrome contentWidth does for a
        -- full column (outer margin = PAD each side).
        local col_w = ctx.col_w or ctx.inner_w or UI.getInnerW()
        local content_w = math.max(1, col_w - PAD * 2)
        local grid = _readGrid(inst_id, ctx.pfx)
        local d = _getQADims(Config.getModuleScaleRaw(S.id, ctx.pfx), content_w, grid and grid.cols)
        if grid then
            -- Only the rows the actions fill take room.
            local n = #QA.filterValidIds(SUISettings:readSetting(qa_pfx .. slot_suffix .. "_items") or {})
            return _gridHeight(d, show_labels, math.max(1, math.min(grid.rows, math.ceil(n / grid.cols))))
        end
        return _cellHeight(d, show_labels)
    end

    function S.getMenuItems(ctx_menu)
        local pfx     = ctx_menu.pfx
        local refresh = ctx_menu.refresh
        local _lc     = ctx_menu._
        local fn = (type(ctx_menu.makeQAMenu) == "function") and ctx_menu.makeQAMenu or makeQAMenuFallback
        local qa = fn(ctx_menu, inst_id) or {}

        local items_node, hide_text_node = nil, nil
        for _, v in ipairs(qa) do
            if v.text == _lc("Quick Actions") then items_node = v end
            if v.text == _lc("Hide Label") then hide_text_node = v end
        end

        local item_rows = {}
        if items_node then item_rows[#item_rows + 1] = items_node end

        local function gridValue()
            local grid = _readGrid(inst_id, pfx)
            return grid and T(_lc("%1 × %2"), grid.cols, grid.rows) or ""
        end
        local grid_item = Config.makeDoubleStepperItem{
            text_func      = function() return _lc("Grid size") end,
            value_func     = gridValue,
            mandatory_func = gridValue,
            title          = _lc("Grid size"),
            left = {
                text          = _lc("Columns"),
                get           = function() return Config.readClampedInt(pfx .. inst_id .. "_grid_cols", 1, GRID_MAX_COLS, GRID_DEFAULT_COLS) end,
                set           = function(v) Config.saveClampedInt(pfx .. inst_id .. "_grid_cols", v, 1, GRID_MAX_COLS) end,
                value_min     = 1,
                value_max     = GRID_MAX_COLS,
                default_value = GRID_DEFAULT_COLS,
            },
            right = {
                text          = _lc("Rows"),
                get           = function() return Config.readClampedInt(pfx .. inst_id .. "_grid_rows", 1, GRID_MAX_ROWS, GRID_DEFAULT_ROWS) end,
                set           = function(v) Config.saveClampedInt(pfx .. inst_id .. "_grid_rows", v, 1, GRID_MAX_ROWS) end,
                value_min     = 1,
                value_max     = GRID_MAX_ROWS,
                default_value = GRID_DEFAULT_ROWS,
            },
            refresh = refresh,
        }
        grid_item.enabled_func = function() return _readGrid(inst_id, pfx) ~= nil end
        local size_rows = {
            Config.makeScaleItem({
                text_func    = function() return _lc("Scale") end,
                enabled_func = function() return not Config.isScaleLinked() end,
                title        = _lc("Scale"),
                info         = _lc("Scale for this module.\n100% is the default size."),
                get          = function() return Config.getModuleScalePct(S.id, pfx) end,
                set          = function(v) Config.setModuleScale(v, S.id, pfx) end,
                refresh      = refresh,
            }),
            grid_item,
        }

        local text_opts = {
            mod_id  = S.id,
            elems   = S.text_elems,
            labels  = { label = _lc("Label") },
            info    = _lc("Size of this text.\n100% is the default size."),
            pfx     = pfx,
            refresh = refresh,
            _lc     = _lc,
        }

        local appearance_extra = {}
        if hide_text_node then
            hide_text_node.separator = nil
            appearance_extra[#appearance_extra + 1] = hide_text_node
        end

        appearance_extra[#appearance_extra + 1] = Config.makeRadioSubmenuItem{
            text    = _lc("Layout"),
            options = {
                { value = "row",  label = _lc("Row") },
                { value = "grid", label = _lc("Grid") },
            },
            get     = function() return Config.readChoice(pfx .. inst_id .. "_layout", LAYOUT_VALUES, "row") end,
            set     = function(v) SUISettings:saveSetting(pfx .. inst_id .. "_layout", v) end,
            refresh = refresh,
        }
        appearance_extra[#appearance_extra + 1] = Config.makeRadioSubmenuItem{
            text    = _lc("Button Type"),
            options = {
                { value = "round",          label = _lc("Round") },
                { value = "rounded_square", label = _lc("Rounded Square") },
                { value = "bare",           label = _lc("Bare") },
            },
            get     = function() return getShape(pfx) end,
            set     = function(v) SUISettings:saveSetting(pfx .. SHAPE_KEY, v) end,
            refresh = refresh,
        }
        appearance_extra[#appearance_extra + 1] = Config.makeSurfaceMenu{
            surface      = buttonSurface(pfx),
            enabled_func = function() return getShape(pfx) ~= "bare" end,
            refresh      = refresh,
            _lc          = _lc,
        }
        appearance_extra[#appearance_extra + 1] = Config.makeRadioSubmenuItem{
            text         = _lc("Alignment"),
            enabled_func = function() return _readGrid(inst_id, pfx) == nil end,
            options = {
                { value = "current", label = _lc("Justified") },
                { value = "left",    label = _lc("Left") },
                { value = "right",   label = _lc("Right") },
            },
            get     = function() return getAlign(pfx) end,
            set     = function(v) SUISettings:saveSetting(pfx .. ALIGN_KEY, v) end,
            refresh = refresh,
        }

        return Config.buildModuleMenu({
            items = item_rows,
            appearance = {
                size  = size_rows,
                text  = text_opts,
                extra = appearance_extra,
            },
        }, ctx_menu)
    end

    return S
end

-- ---------------------------------------------------------------------------
-- Export
-- ---------------------------------------------------------------------------
local M = {}
M.id           = "quick_actions_row"
M.name         = _("Quick Actions Row")
M.category     = "shortcuts"
M.instanciable = true
M.makeInstance = makeInstance
M.menu_group   = "quick_actions"
-- Settings of an instance's buttons: opacity, tone and frame of their surface.
M.setting_suffixes = { "_btn_strength", "_btn_tone", "_btn_show_frame", "_layout" }

-- Most actions the instance `inst_id` holds under settings prefix `pfx`.
M.maxItems = _maxItems

-- Layout-editor summary of an instance: the labels of its configured actions.
function M.getSummary(inst_id, _pfx, pfx_qa)
    local names = {}
    for _, qa_id in ipairs(SUISettings:readSetting(pfx_qa .. inst_id .. "_items") or {}) do
        names[#names + 1] = QA.getMenuLabel(qa_id)
    end
    if #names == 0 then return _("No actions configured") end
    return table.concat(names, "  ·  ")
end

-- Expose base frame size for menu.lua (MAX_QA_ITEMS referenced there).
-- Returns the 100%-scale value; callers that need the current scaled value
-- should call _getQADims(Config.getModuleScale(...)).frame_sz directly.
M.FRAME_SZ             = _BASE_FRAME_SZ
-- Expose the shared icon-tile row builder and its sizing helper so other
-- modules (the QA "Group" popup) can render tiles identical to the
-- Quick Actions Row widget instead of duplicating the icon/label logic.
M.buildQAWidget = buildQAWidget
M.getQADims     = _getQADims

M.invalidateCustomQACache = QA.invalidateCustomQACache

return M
