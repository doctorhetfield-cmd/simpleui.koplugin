-- module_quick_actions.lua — Simple UI
-- Module: Quick Actions Row (dynamic instances).
-- Exposes M.instanciable = true and M.makeInstance(id) for the registry.

local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local UIManager       = require("ui/uimanager")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local TextWidget      = require("ui/widget/textwidget")
local Screen          = Device.screen
local _ = require("infra/sui_i18n").translate
local N_ = require("infra/sui_i18n").ngettext
local Config          = require("infra/sui_config")
local QA              = require("features/sui_quickactions")
local QARenderer      = require("engines/sui_quickactions_render")

local UI  = require("infra/sui_core")
local SUISettings = require("infra/sui_store")
local SUIStyle    = require("features/sui_style")
local PAD = UI.PAD
local LABEL_H = UI.LABEL_H
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

local _BASE_PH_FS = SUIStyle.FS_BODY    -- 18: placeholder text


local _BASE_ICON_SZ   = Screen:scaleBySize(52)
local _BASE_FRAME_PAD = Screen:scaleBySize(18)
local _BASE_CORNER_R  = Screen:scaleBySize(22)
local _BASE_LBL_SP    = Screen:scaleBySize(7)
local _BASE_LBL_H     = Screen:scaleBySize(20)
local _BASE_LBL_FS    = SUIStyle.FS_DETAIL  -- 15: quick-action label text
-- Fixed inter-icon gap used by the "Left"/"Right" alignment modes (packed
-- layout). Scales with the same module scale as everything else so
-- alignment changes never touch icon/frame sizing — only where the row of
-- icons (as a whole) sits within the module's width.
local _BASE_ICON_GAP  = Screen:scaleBySize(24)

-- Hard cap on how many actions a single Quick Actions row can hold. Kept in
-- sync with makeInstance's own MAX_QA (the "add action" limit shown in the
-- module's settings menu) so the row's item sizing always leaves room for a
-- fully-populated row, whatever alignment mode is chosen.
local MAX_QA_ITEMS = 6

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
        icon_sz   = _BASE_ICON_SZ,
        frame_pad = _BASE_FRAME_PAD,
        corner_r  = _BASE_CORNER_R,
        icon_gap  = _BASE_ICON_GAP,
    }
end

-- Re-anchors what "Scale = 100%" means for a row of this inner_w: shrinks
-- the naive baseline (icon size, padding, corner radius, and — as a last
-- resort — the gap) just enough that MAX_QA_ITEMS icons fit inside inner_w
-- at the module's nice gap. On anything roomy enough already, this is a
-- no-op and the naive baseline is returned unchanged.
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
    local base_frame_sz = base.icon_sz + base.frame_pad * 2
    local gap = base.icon_gap
    local max_frame = math.floor((inner_w - (MAX_QA_ITEMS - 1) * gap) / MAX_QA_ITEMS)
    if max_frame < base_frame_sz then
        if max_frame < 16 then
            -- Even a minimal icon wouldn't leave room for the nice gap —
            -- shrink the gap itself before shrinking icons any further.
            gap = _MIN_ICON_GAP
            max_frame = math.floor((inner_w - (MAX_QA_ITEMS - 1) * gap) / MAX_QA_ITEMS)
        end
        max_frame = math.max(16, max_frame)
        local ratio = max_frame / base_frame_sz
        base.icon_sz   = math.max(16, math.floor(base.icon_sz   * ratio))
        base.frame_pad = math.max(4,  math.floor(base.frame_pad * ratio))
        base.corner_r  = math.max(4,  math.floor(base.corner_r  * ratio))
        base.icon_gap  = gap
    end
    _fit_baseline_cache[inner_w] = base
    return base
end

-- inner_w is optional: pass it whenever it's known (build()/getHeight()) so
-- Scale = 100% guarantees MAX_QA_ITEMS icons fit; omit it (e.g. the Quick
-- Actions folder-grid preview in sui_quickactions.lua, which sizes its own
-- rows explicitly per chunk) to get the plain, unconstrained baseline.
local function _getQADims(scale, inner_w)
    scale = scale or 1.0
    local base      = _getFitBaseline(inner_w)
    local icon_sz   = math.max(16, math.floor(base.icon_sz   * scale))
    local frame_pad = math.max(4,  math.floor(base.frame_pad * scale))
    local lbl_sp    = math.max(1,  math.floor(_BASE_LBL_SP    * scale))
    local lbl_h     = math.max(8,  math.floor(_BASE_LBL_H     * scale))
    return {
        icon_sz   = icon_sz,
        frame_pad = frame_pad,
        frame_sz  = icon_sz + frame_pad * 2,
        corner_r  = math.max(4, math.floor(base.corner_r * scale)),
        lbl_sp    = lbl_sp,
        lbl_h     = lbl_h,
        lbl_fs    = math.max(6, math.floor(_BASE_LBL_FS * scale)),
        icon_gap  = math.max(4, math.floor(base.icon_gap * scale)),
    }
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
local function buildQAWidget(w, action_ids, show_labels, on_tap_fn, d, shape, bg, colors, align, strength)
    local clr_blk = colors and colors.blk or SUIStyle.COLOR.text_primary
    local clr_sub = colors and colors.sub or CLR_TEXT_SUB
    local ph_fs = math.max(8, math.floor(_BASE_PH_FS * (d.frame_sz / (_BASE_ICON_SZ + _BASE_FRAME_PAD * 2))))
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

    local row = HorizontalGroup:new{ align = "top" }

    for i = 1, n do
        local aid = valid_ids[i]
        local tappable = QARenderer.buildCell(aid, {
            icon_sz        = d.icon_sz,
            frame_sz       = d.frame_sz,
            frame_pad      = d.frame_pad,
            corner_r       = d.corner_r,
            shape          = shape,
            bg             = bg,
            strength       = strength,
            fgcolor        = clr_blk,
            show_label     = show_labels,
            lbl_sp         = lbl_sp,
            lbl_h          = lbl_h,
            lbl_fs         = d.lbl_fs,
            lbl_max_width  = d.frame_sz,
            lbl_truncate   = true,
            on_tap_fn      = on_tap_fn,
            tap_event_name = "TapQA",
        })

        if i > 1 then
            row[#row + 1] = HorizontalSpan:new{ width = gap }
        end
        row[#row + 1] = tappable
    end

    return FrameContainer:new{
        bordersize   = 0, padding = 0,
        padding_left = left_off,
        row,
    }
end

-- ---------------------------------------------------------------------------
-- Slot factory — creates one module descriptor per slot
-- ---------------------------------------------------------------------------
local function makeInstance(inst_id)
    -- Keys built at call-time using ctx.pfx — works for any page prefix.
    local slot_suffix = inst_id
    local SHAPE_KEY    = slot_suffix .. "_shape"
    local BG_KEY       = slot_suffix .. "_bg"
    local ALIGN_KEY    = slot_suffix .. "_align"
    local STRENGTH_KEY = slot_suffix .. "_btn_strength"

    local function getShape(pfx)
        return SUISettings:readSetting(pfx .. SHAPE_KEY) or "rounded_square"
    end

    -- Color style: solid | flat (transparent folds into strength 0).
    local function getBg(pfx)
        local v = SUISettings:readSetting(pfx .. BG_KEY) or "solid"
        if v == "transparent" then return "solid" end
        return v
    end

    local function getBtnStrength(pfx)
        local WP = require("features/sui_wallpaper")
        local v = WP.readBackdropStrength(pfx .. STRENGTH_KEY)
        if v ~= nil then return v end
        if SUISettings:readSetting(pfx .. BG_KEY) == "transparent" then
            return 0
        end
        return 100
    end

    local function setBtnStrength(pfx, n)
        require("features/sui_wallpaper").saveBackdropStrength(pfx .. STRENGTH_KEY, n)
    end

    -- "current" (default) = existing behaviour, icons spread across the full
    -- module width. "left"/"right" pack them (same sizes, fixed gap —
    -- see buildQAWidget) against one edge instead.
    local function getAlign(pfx)
        local v = SUISettings:readSetting(pfx .. ALIGN_KEY)
        if v == "left" or v == "right" then return v end
        return "current"
    end

    local S = {}
    S.id         = inst_id
    S.name       = _("Quick Actions Row")
    S.label      = nil
    S.default_on = false

    function S.isEnabled(pfx)
        return SUISettings:readSetting(pfx .. slot_suffix .. "_enabled") == true
    end

    function S.setEnabled(pfx, on)
        SUISettings:saveSetting(pfx .. slot_suffix .. "_enabled", on)
    end

    local MAX_QA = MAX_QA_ITEMS

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
                    label = id == "home" and Config.homeLabel() or QA.getEntry(id).label,
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
        local function getItems() return SUISettings:readSetting(items_key) or {} end
        local function isSelected(id)
            for _i, v in ipairs(getItems()) do if v == id then return true end end
            return false
        end
        local function toggleItem(id)
            local items = getItems()
            local new_items = {}
            local found = false
            for _i, v in ipairs(items) do
                if v == id then found = true else new_items[#new_items + 1] = v end
            end
            if not found then
                if #items >= MAX_QA then
                    UI.Notify.toast(string.format(N_("The maximum of %d action per module has been reached. Remove one first.", "The maximum of %d actions per module has been reached. Remove one first.", MAX_QA), MAX_QA), 2)
                    return
                end
                new_items[#new_items + 1] = id
            end
            SUISettings:saveSetting(items_key, new_items)
            ctx_menu.refresh()
        end

        local items_sub = {}
        local sorted_pool = {}
        for _i, a in ipairs(getQAPool()) do sorted_pool[#sorted_pool + 1] = a end
        table.sort(sorted_pool, function(a, b) return a.label:lower() < b.label:lower() end)
        items_sub[#items_sub + 1] = {
            text           = _("Arrange Items"),
            keep_menu_open = true,
            separator      = true,
            enabled_func   = function() return #getItems() >= 2 end,
            callback       = function()
                local qa_ids = getItems()
                if #qa_ids < 2 then
                    UI.Notify.toast(_("Add at least 2 actions to arrange."), 2)
                    return
                end
                local pool_labels = {}
                for _i, a in ipairs(getQAPool()) do pool_labels[a.id] = a.label end
                local sort_items = {}
                for _i, id in ipairs(qa_ids) do
                    sort_items[#sort_items + 1] = { text = pool_labels[id] or id, orig_item = id }
                end
                local function on_save()
                    local new_order = {}
                    for _i, item in ipairs(sort_items) do new_order[#new_order + 1] = item.orig_item end
                    SUISettings:saveSetting(items_key, new_order)
                    ctx_menu.refresh()
                end
                local SortWidget = ctx_menu.SortWidget or require("ui/widget/sortwidget")
                local uim = ctx_menu.UIManager or UIManager
                uim:show(SortWidget:new{
                    title             = string.format(_("Arrange %s"), slot_label),
                    covers_fullscreen = true,
                    item_table        = sort_items,
                    callback          = on_save,
                })
            end,
        }
        for _i, a in ipairs(sorted_pool) do
            local aid = a.id
            local _lbl = a.label
            items_sub[#items_sub + 1] = {
                text_func = function()
                    if isSelected(aid) then return _lbl end
                    local rem = MAX_QA - #getItems()
                    if rem <= 2 then return _lbl .. string.format(N_("  (%d left)", "  (%d left)", rem), rem) end
                    return _lbl
                end,
                checked_func   = function() return isSelected(aid) end,
                keep_menu_open = true,
                callback       = function() toggleItem(aid) end,
            }
        end
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
            {
                text                = _("Quick Actions"),
                sub_item_table_func = function() return items_sub end,
                sui_build = ctx_menu.is_sui and function(ctx, _item)
                    local SUIWindow = require("engines/sui_window")
                    return SUIWindow.ListRow{
                        title        = _("Quick Actions"),
                        subtitle     = function()
                            local qa_ids = getItems()
                            if #qa_ids == 0 then return _("No items selected.") end
                            local pool_labels = {}
                            for _, a in ipairs(getQAPool()) do pool_labels[a.id] = a.label end
                            local names = {}
                            for _, id in ipairs(qa_ids) do
                                names[#names + 1] = pool_labels[id] or id
                            end
                            return table.concat(names, "  ·  ")
                        end,
                        inner_w      = ctx.inner_w,
                        item_count   = function() return #getItems() end,
                        max_items    = MAX_QA,
                        show_chevron = true,
                        on_tap       = function()
                            local qa_ids = getItems()
                            local pool_labels = {}
                            for _, a in ipairs(getQAPool()) do pool_labels[a.id] = a.label end
                            local sort_items = {}
                            for _, id in ipairs(qa_ids) do
                                sort_items[#sort_items + 1] = { text = pool_labels[id] or id, orig_item = id }
                            end
                            
                            ctx.push("arrange", {
                                title = _("Quick Actions"),
                                items = sort_items,
                                empty_text = _("No items selected."),
                                item_count = function() return #getItems() end,
                                max_items  = MAX_QA,
                                on_delete = function(item) end,
                                on_change = function(items_to_save)
                                    local new_order = {}
                                    for _, it in ipairs(items_to_save) do new_order[#new_order + 1] = it.orig_item end
                                    SUISettings:saveSetting(items_key, new_order)
                                    ctx_menu.refresh()
                                end,
                                footer_text = _("Add Item"),
                                footer_action = function(ctx2)
                                    local picker_items = {}
                                    local sorted_pool2 = {}
                                    for _, a in ipairs(getQAPool()) do sorted_pool2[#sorted_pool2 + 1] = a end
                                    table.sort(sorted_pool2, function(a, b) return a.label:lower() < b.label:lower() end)

                                    for _, a in ipairs(sorted_pool2) do
                                        if not isSelected(a.id) then
                                            local _id = a.id
                                            local _label = a.label
                                            picker_items[#picker_items + 1] = {
                                                text   = _label,
                                                on_tap = function(picker_ctx)
                                                    local cur = getItems()
                                                    if #cur >= MAX_QA then
                                                        UI.Notify.toast(string.format(N_("The maximum of %d action per module has been reached. Remove one first.", "The maximum of %d actions per module has been reached. Remove one first.", MAX_QA), MAX_QA), 2)
                                                        return
                                                    end
                                                    cur[#cur + 1] = _id
                                                    SUISettings:saveSetting(items_key, cur)
                                                    table.insert(sort_items, { text = _label, orig_item = _id })
                                                    ctx_menu.refresh()
                                                    picker_ctx.pop()
                                                    ctx2.repaint()
                                                end,
                                            }
                                        end
                                    end
                                    ctx2.push("item_picker", {
                                        title = _("Add Item"),
                                        items = picker_items,
                                    })
                                end
                            })
                        end
                    }
                end or nil,
            },
        }
    end

    function S.getCountLabel(pfx)
        local n   = #(SUISettings:readSetting(pfx .. slot_suffix .. "_items") or {})
        local rem = MAX_QA - n
        if n == 0   then return nil end
        if rem <= 0 then return string.format(_("(%d/%d — at limit)"), n, MAX_QA) end
        return string.format(N_("(%d/%d — %d left)", "(%d/%d — %d left)", rem), n, MAX_QA, rem)
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
        local d           = _getQADims(Config.getModuleScaleRaw(S.id, ctx.pfx), w)
        local lbl_scale = Config.getItemLabelScale(S.id, ctx.pfx) * lf
        d.lbl_fs = math.max(6, math.floor(d.lbl_fs * lbl_scale))
        return buildQAWidget(w, qa_ids, show_labels, ctx.on_qa_tap, d, getShape(ctx.pfx), getBg(ctx.pfx), nil, getAlign(ctx.pfx), getBtnStrength(ctx.pfx))
    end

    function S.getHeight(ctx)
        local qa_pfx      = ctx.pfx_qa or ctx.pfx
        local labels_key  = qa_pfx .. slot_suffix .. "_labels"
        local show_labels = SUISettings:nilOrTrue(labels_key)
        -- Estimate content width the same way chrome contentWidth does for a
        -- full column (outer margin = PAD each side).
        local col_w = ctx.col_w or ctx.inner_w or (Screen:getWidth() - UI.SIDE_PAD * 2)
        local content_w = math.max(1, col_w - PAD * 2)
        local d = _getQADims(Config.getModuleScaleRaw(S.id, ctx.pfx), content_w)
        return (show_labels and (d.frame_sz + d.lbl_sp + d.lbl_h) or d.frame_sz)
    end

    function S.getMenuItems(ctx_menu)
        local pfx     = ctx_menu.pfx
        local refresh = ctx_menu.refresh
        local _lc     = ctx_menu._
        local items = {}
        local fn = (type(ctx_menu.makeQAMenu) == "function") and ctx_menu.makeQAMenu or makeQAMenuFallback
        local qa = fn(ctx_menu, inst_id) or {}

        local items_node = nil
        local hide_text_node = nil
        for _, v in ipairs(qa) do
            if v.text == _lc("Quick Actions") then items_node = v end
            if v.text == _lc("Hide Label") then hide_text_node = v end
        end
        if items_node then items[#items + 1] = items_node end

        items[#items + 1] = Config.makeScaleItem({
            text_func    = function() return _lc("Scale") end,
            enabled_func = function() return not Config.isScaleLinked() end,
            title        = _lc("Scale"),
            info         = _lc("Scale for this module.\n100% is the default size."),
            get          = function() return Config.getModuleScalePct(S.id, pfx) end,
            set          = function(v) Config.setModuleScale(v, S.id, pfx) end,
            refresh      = refresh,
        })

        if hide_text_node then hide_text_node.separator = nil end

        items[#items + 1] = {
            text = _lc("Label"),
            sub_item_table = {
                Config.makeScaleItem({
                    text_func    = function() return _lc("Size") end,
                    title        = _lc("Size"),
                    info         = _lc("Scale for the button label text.\n100% is the default size."),
                    get          = function() return Config.getItemLabelScalePct(S.id, pfx) end,
                    set          = function(v) Config.setItemLabelScale(v, S.id, pfx) end,
                    refresh      = refresh,
                }),
                hide_text_node
            }
        }

        items[#items + 1] = {
            text_func      = function() return _lc("Appearance") end,
            sub_item_table = {
                {
                    text = _lc("Button Type"),
                    sub_item_table = {
                        {
                            text           = _lc("Round"),
                            radio          = true,
                            checked_func   = function() return getShape(pfx) == "round" end,
                            keep_menu_open = true,
                            callback       = function()
                                SUISettings:saveSetting(pfx .. SHAPE_KEY, "round")
                                refresh()
                            end,
                        },
                        {
                            text           = _lc("Rounded Square"),
                            radio          = true,
                            checked_func   = function() return getShape(pfx) == "rounded_square" end,
                            keep_menu_open = true,
                            callback       = function()
                                SUISettings:saveSetting(pfx .. SHAPE_KEY, "rounded_square")
                                refresh()
                            end,
                        },
                        {
                            text           = _lc("Bare"),
                            radio          = true,
                            checked_func   = function() return getShape(pfx) == "bare" end,
                            keep_menu_open = true,
                            callback       = function()
                                SUISettings:saveSetting(pfx .. SHAPE_KEY, "bare")
                                refresh()
                            end,
                        },
                    },
                },
                {
                    text = _lc("Button Style"),
                    enabled_func = function() return getShape(pfx) ~= "bare" end,
                    sub_item_table = {
                        {
                            text           = _lc("Solid"),
                            radio          = true,
                            checked_func   = function() return getBg(pfx) == "solid" end,
                            keep_menu_open = true,
                            callback       = function()
                                SUISettings:saveSetting(pfx .. BG_KEY, "solid")
                                refresh()
                            end,
                        },
                        {
                            text           = _lc("Flat"),
                            radio          = true,
                            checked_func   = function() return getBg(pfx) == "flat" end,
                            keep_menu_open = true,
                            callback       = function()
                                SUISettings:saveSetting(pfx .. BG_KEY, "flat")
                                refresh()
                            end,
                        },
                    },
                },
                Config.makeBackdropStrengthItem({
                    title         = _lc("Button Opacity"),
                    enabled_func  = function() return getShape(pfx) ~= "bare" end,
                    get           = function() return getBtnStrength(pfx) end,
                    set           = function(v) setBtnStrength(pfx, v) end,
                    refresh       = refresh,
                    default_value = 100,
                    _lc           = _lc,
                }),
                {
                    text = _lc("Alignment"),
                    sub_item_table = {
                        {
                            text           = _lc("Justified"),
                            radio          = true,
                            checked_func   = function() return getAlign(pfx) == "current" end,
                            keep_menu_open = true,
                            callback       = function()
                                SUISettings:saveSetting(pfx .. ALIGN_KEY, "current")
                                refresh()
                            end,
                        },
                        {
                            text           = _lc("Left"),
                            radio          = true,
                            checked_func   = function() return getAlign(pfx) == "left" end,
                            keep_menu_open = true,
                            callback       = function()
                                SUISettings:saveSetting(pfx .. ALIGN_KEY, "left")
                                refresh()
                            end,
                        },
                        {
                            text           = _lc("Right"),
                            radio          = true,
                            checked_func   = function() return getAlign(pfx) == "right" end,
                            keep_menu_open = true,
                            callback       = function()
                                SUISettings:saveSetting(pfx .. ALIGN_KEY, "right")
                                refresh()
                            end,
                        },
                    },
                },
            },
        }
        return items
    end

    return S
end

-- ---------------------------------------------------------------------------
-- Export
-- ---------------------------------------------------------------------------
local M = {}
M.id           = "quick_actions_row"
M.name         = _("Quick Actions Row")
M.instanciable = true
M.makeInstance = makeInstance

-- Expose base frame size for menu.lua (MAX_QA_ITEMS referenced there).
-- Returns the 100%-scale value; callers that need the current scaled value
-- should call _getQADims(Config.getModuleScale(...)).frame_sz directly.
M.FRAME_SZ             = _BASE_ICON_SZ + _BASE_FRAME_PAD * 2
-- Expose the shared icon-tile row builder and its sizing helper so other
-- modules (the QA "Group" popup) can render tiles identical to the
-- Quick Actions Row widget instead of duplicating the icon/label logic.
M.buildQAWidget = buildQAWidget
M.getQADims     = _getQADims

M.invalidateCustomQACache = QA.invalidateCustomQACache

return M
