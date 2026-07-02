-- module_quick_actions.lua — Simple UI
-- Módulo: Quick Actions Row (instâncias dinâmicas).
-- Substitui quickactionswidget.lua — contém todo o código de widget.
-- Expõe M.instanciable = true e M.makeInstance(id) para o registry.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local UIManager       = require("ui/uimanager")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local ImageWidget     = require("ui/widget/imagewidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local _ = require("sui_i18n").translate
local N_ = require("sui_i18n").ngettext
local Config          = require("sui_config")
local QA              = require("sui_quickactions")

local UI  = require("sui_core")
local SUISettings = require("sui_store")
local SUIStyle    = require("sui_style")
local PAD = UI.PAD
local LABEL_H = UI.LABEL_H
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

local _BASE_PH_FS = SUIStyle.FS_BODY    -- 18: placeholder text

local _CLR_BAR_FG  = Blitbuffer.gray(0.75)
local _CLR_FLAT_BG = Blitbuffer.gray(0.08)

local _BASE_ICON_SZ   = Screen:scaleBySize(52)
local _BASE_FRAME_PAD = Screen:scaleBySize(18)
local _BASE_CORNER_R  = Screen:scaleBySize(22)
local _BASE_LBL_SP    = Screen:scaleBySize(7)
local _BASE_LBL_H     = Screen:scaleBySize(20)
local _BASE_LBL_FS    = SUIStyle.FS_DETAIL  -- 15: quick-action label text

local function _getQADims(scale)
    scale = scale or 1.0
    local icon_sz   = math.max(16, math.floor(_BASE_ICON_SZ   * scale))
    local frame_pad = math.max(4,  math.floor(_BASE_FRAME_PAD * scale))
    local lbl_sp    = math.max(1,  math.floor(_BASE_LBL_SP    * scale))
    local lbl_h     = math.max(8,  math.floor(_BASE_LBL_H     * scale))
    return {
        icon_sz   = icon_sz,
        frame_pad = frame_pad,
        frame_sz  = icon_sz + frame_pad * 2,
        corner_r  = math.max(4, math.floor(_BASE_CORNER_R * scale)),
        lbl_sp    = lbl_sp,
        lbl_h     = lbl_h,
        lbl_fs    = math.max(6, math.floor(_BASE_LBL_FS * scale)),
    }
end

-- ---------------------------------------------------------------------------
-- Action entry resolution and QA validity cache
-- Delegated to sui_quickactions (single source of truth).
-- ---------------------------------------------------------------------------

local function getEntry(action_id)
    return QA.getEntry(action_id)
end

local function getCustomQAValid()
    return QA.getCustomQAValid()
end

local function invalidateCustomQACache()
    QA.invalidateCustomQACache()
end

-- ---------------------------------------------------------------------------
-- Core widget builder (shared by all slots)
-- ---------------------------------------------------------------------------
local function buildQAWidget(w, action_ids, show_labels, on_tap_fn, d, shape, bg, colors)
    local clr_blk = colors and colors.blk or Blitbuffer.COLOR_BLACK
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

    local valid_ids = {}
    local cqa_valid = getCustomQAValid()
    for _, aid in ipairs(action_ids) do
        if aid:match("^custom_qa_%d+$") then
            if cqa_valid[aid] then valid_ids[#valid_ids + 1] = aid end
        elseif QA.isBuiltin(aid) then
            valid_ids[#valid_ids + 1] = aid
        end
        -- unknown IDs (neither a live custom QA nor a known built-in) are silently dropped
    end
    if #valid_ids == 0 then return _placeholder() end
    local n        = #valid_ids
    local inner_w  = w - PAD * 2
    local lbl_h    = show_labels and d.lbl_h or 0
    local lbl_sp   = show_labels and d.lbl_sp or 0
    local gap      = n <= 1 and 0 or math.floor((inner_w - n * d.frame_sz) / (n - 1))
    local left_off = n == 1 and math.floor((inner_w - d.frame_sz) / 2) or 0

    local row = HorizontalGroup:new{ align = "top" }

    for i = 1, n do
        local aid   = valid_ids[i]
        local entry = getEntry(aid)

        local icon_sz_used = d.icon_sz

        local icon_widget
        local nerd_char = Config.nerdIconChar(entry.icon)
        if nerd_char then
            icon_widget = CenterContainer:new{
                dimen = Geom:new{ w = icon_sz_used, h = icon_sz_used },
                TextWidget:new{
                    text    = nerd_char,
                    face    = Font:getFace(SUIStyle.FACE_ICONS, math.floor(icon_sz_used * 0.6)),
                    fgcolor = clr_blk,
                    padding = 0,
                },
            }
        else
                local iw = ImageWidget:new{
                file    = entry.icon,
                width   = icon_sz_used,
                height  = icon_sz_used,
                is_icon = true,
                alpha   = true,
            }
                if pcall(function() iw:_render() end) then
                    icon_widget = iw
                else
                    iw:free()
                    icon_widget = CenterContainer:new{
                        dimen = Geom:new{ w = icon_sz_used, h = icon_sz_used },
                        TextWidget:new{
                            text    = (entry.label and entry.label:sub(1,1):upper() or "?"),
                            face    = Font:getFace("cfont", math.floor(icon_sz_used * 0.55)),
                            fgcolor = clr_blk,
                        },
                    }
                end
        end

        local is_bare = (shape == "bare")
        local corner_r = is_bare and 0 or ((shape == "round") and math.floor(d.frame_sz / 2) or d.corner_r)
        local current_border = (not is_bare and (bg == "solid" or bg == "transparent")) and SUIStyle.BORDER_SZ or 0
        local bg_color = nil
        if not is_bare then
            if bg == "flat" then bg_color = _CLR_FLAT_BG
            elseif bg == "solid" then bg_color = Blitbuffer.COLOR_WHITE end
        end

        local icon_frame = FrameContainer:new{
            bordersize = current_border,
            color      = current_border > 0 and _CLR_BAR_FG or nil,
            background = bg_color,
            radius     = corner_r,
            padding    = is_bare and 0 or d.frame_pad,
            icon_widget,
        }

        local col = VerticalGroup:new{ align = "center" }
        col[#col + 1] = icon_frame
        if show_labels then
            col[#col + 1] = VerticalSpan:new{ width = lbl_sp }
            col[#col + 1] = CenterContainer:new{
                dimen = Geom:new{ w = d.frame_sz, h = lbl_h },
                TextWidget:new{
                    text    = entry.label,
                    face    = Font:getFace(SUIStyle.FACE_REGULAR, d.lbl_fs),
                    fgcolor = clr_blk,
                    max_width = d.frame_sz,
                    truncate_with_ellipsis = true,
                },
            }
        end

        local col_h    = d.frame_sz + lbl_sp + lbl_h
        local tappable = InputContainer:new{
            dimen      = Geom:new{ w = d.frame_sz, h = col_h },
            [1]        = col,
            _on_tap_fn = on_tap_fn,
            _action_id = aid,
        }
        tappable.ges_events = {
            TapQA = {
                GestureRange:new{
                    ges   = "tap",
                    range = function() return tappable.dimen end,
                },
            },
        }
        function tappable:onTapQA()
            if self._on_tap_fn then self._on_tap_fn(self._action_id) end
            return true
        end

        if i > 1 then
            row[#row + 1] = HorizontalSpan:new{ width = gap }
        end
        row[#row + 1] = tappable
    end

    return FrameContainer:new{
        bordersize   = 0, padding = 0,
        padding_left = PAD + left_off,
        row,
    }
end

-- ---------------------------------------------------------------------------
-- Slot factory — creates one module descriptor per slot
-- ---------------------------------------------------------------------------
local function makeInstance(inst_id)
    -- Keys built at call-time using ctx.pfx — works for any page prefix.
    local slot_suffix = inst_id
    local SHAPE_KEY   = slot_suffix .. "_shape"
    local BG_KEY      = slot_suffix .. "_bg"

    local function getShape(pfx)
        return SUISettings:readSetting(pfx .. SHAPE_KEY) or "rounded_square"
    end

    local function getBg(pfx)
        return SUISettings:readSetting(pfx .. BG_KEY) or "solid"
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

    local MAX_QA = 6

    local _has_fl = nil
    local function actionAvailable(id)
        if id == "frontlight" then
            if _has_fl == nil then
                local ok, v = pcall(function() return Device:hasFrontlight() end)
                _has_fl = ok and v == true
            end
            return _has_fl
        end
        if id == "browse_authors" or id == "browse_series" then
            local ok_bm, BM = pcall(require, "sui_browsemeta")
            return ok_bm and BM and BM.isEnabled()
        end
        return true
    end

    local function getQAPool()
        local available = {}
        for desc in QA.iterBuiltin() do
            if actionAvailable(desc.id) then
                available[#available + 1] = {
                    id    = desc.id,
                    label = desc.id == "home" and Config.homeLabel() or QA.getEntry(desc.id).label,
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
                    local InfoMessage = ctx_menu.InfoMessage or require("ui/widget/infomessage")
                    local uim = ctx_menu.UIManager or UIManager
                    uim:show(InfoMessage:new{
                        text    = string.format(N_("The maximum of %d action per module has been reached. Remove one first.",
                                  "The maximum of %d actions per module has been reached. Remove one first.", MAX_QA), MAX_QA),
                        timeout = 2,
                    })
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
                    local InfoMessage = ctx_menu.InfoMessage or require("ui/widget/infomessage")
                    local uim = ctx_menu.UIManager or UIManager
                    uim:show(InfoMessage:new{ text = _("Add at least 2 actions to arrange."), timeout = 2 })
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
                    local SUIWindow = require("sui_window")
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
                                                        local InfoMessage = ctx_menu.InfoMessage or require("ui/widget/infomessage")
                                                        local uim = ctx_menu.UIManager or require("ui/uimanager")
                                                        local N_ = ctx_menu.N_ or require("sui_i18n").ngettext
                                                        uim:show(InfoMessage:new{
                                                            text = string.format(N_("The maximum of %d action per module has been reached. Remove one first.",
                                                                   "The maximum of %d actions per module has been reached. Remove one first.", MAX_QA), MAX_QA), timeout = 2,
                                                        })
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
        local d           = _getQADims(Config.getModuleScale(S.id, ctx.pfx))
        -- Apply independent label text scale.
        local lbl_scale = Config.getItemLabelScale(S.id, ctx.pfx)
        d.lbl_fs = math.max(6, math.floor(d.lbl_fs * lbl_scale))
        local ok_ss, SUIStyle  = pcall(require, "sui_style")
        local _theme_fg        = ok_ss and SUIStyle and SUIStyle.getThemeColor("fg")
        local _theme_secondary = ok_ss and SUIStyle and SUIStyle.getThemeColor("text_secondary")
        local colors = (_theme_fg or _theme_secondary) and {
            blk = _theme_fg or Blitbuffer.COLOR_BLACK,
            sub = _theme_secondary or _theme_fg or CLR_TEXT_SUB,
        } or nil
        return buildQAWidget(w, qa_ids, show_labels, ctx.on_qa_tap, d, getShape(ctx.pfx), getBg(ctx.pfx), colors)
    end

    function S.getHeight(ctx)
        local qa_pfx      = ctx.pfx_qa or ctx.pfx
        local labels_key  = qa_pfx .. slot_suffix .. "_labels"
        local show_labels = SUISettings:nilOrTrue(labels_key)
        local d           = _getQADims(Config.getModuleScale(S.id, ctx.pfx))
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
        }

        items[#items + 1] = {
            text = _lc("Button Background"),
            enabled_func = function() return getShape(pfx) ~= "bare" end,
            sub_item_table = {
                {
                    text           = _lc("Transparent"),
                    radio          = true,
                    checked_func   = function() return getBg(pfx) == "transparent" end,
                    keep_menu_open = true,
                    callback       = function()
                        SUISettings:saveSetting(pfx .. BG_KEY, "transparent")
                        refresh()
                    end,
                },
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
