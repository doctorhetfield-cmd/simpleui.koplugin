-- module_quick_actions.lua — Simple UI
-- Módulo: Quick Actions (3 slots independentes).
-- Substitui quickactionswidget.lua — contém todo o código de widget.
-- Expõe sub_modules = { slot1, slot2, slot3 } para o registry.

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
local _               = require("gettext")
local Config          = require("sui_config")
local QA              = require("sui_quickactions")

local UI  = require("sui_core")
local PAD = UI.PAD
local LABEL_H = UI.LABEL_H

local _CLR_BAR_FG  = Blitbuffer.gray(0.75)
local _CLR_FLAT_BG = Blitbuffer.gray(0.08)

local _BASE_ICON_SZ   = Screen:scaleBySize(52)
local _BASE_FRAME_PAD = Screen:scaleBySize(18)
local _BASE_CORNER_R  = Screen:scaleBySize(22)
local _BASE_LBL_SP    = Screen:scaleBySize(7)
local _BASE_LBL_H     = Screen:scaleBySize(20)
local _BASE_LBL_FS    = Screen:scaleBySize(9)

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
local function buildQAWidget(w, action_ids, show_labels, on_tap_fn, d, flat)
    if not action_ids or #action_ids == 0 then return nil end

    local valid_ids = {}
    local cqa_valid = getCustomQAValid()
    for _, aid in ipairs(action_ids) do
        if aid:match("^custom_qa_%d+$") then
            if cqa_valid[aid] then valid_ids[#valid_ids + 1] = aid end
        else
            valid_ids[#valid_ids + 1] = aid
        end
    end
    if #valid_ids == 0 then return nil end

    local n        = math.min(#valid_ids, 6)
    local inner_w  = w - PAD * 2
    local lbl_h    = show_labels and d.lbl_h or 0
    local lbl_sp   = show_labels and d.lbl_sp or 0
    local gap      = n <= 1 and 0 or math.floor((inner_w - n * d.frame_sz) / (n - 1))
    local left_off = n == 1 and math.floor((inner_w - d.frame_sz) / 2) or 0

    local row = HorizontalGroup:new{ align = "top" }

    for i = 1, n do
        local aid   = valid_ids[i]
        local entry = getEntry(aid)

        local icon_widget
        local nerd_char = Config.nerdIconChar(entry.icon)
        if nerd_char then
            icon_widget = CenterContainer:new{
                dimen = Geom:new{ w = d.icon_sz, h = d.icon_sz },
                TextWidget:new{
                    text    = nerd_char,
                    face    = Font:getFace("symbols", math.floor(d.icon_sz * 0.6)),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    padding = 0,
                },
            }
        else
            icon_widget = ImageWidget:new{
                file    = entry.icon,
                width   = d.icon_sz,
                height  = d.icon_sz,
                is_icon = true,
                alpha   = true,
            }
        end

        local icon_frame = FrameContainer:new{
            bordersize = flat and 0 or 1,
            color      = flat and nil or _CLR_BAR_FG,
            background = flat and _CLR_FLAT_BG or Blitbuffer.COLOR_WHITE,
            radius     = d.corner_r,
            padding    = d.frame_pad,
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
                    face    = Font:getFace("cfont", d.lbl_fs),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    width   = d.frame_sz,
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
local function makeSlot(slot)
    -- Keys built at call-time using ctx.pfx — works for any page prefix.
    local slot_suffix = "quick_actions_" .. slot
    local TYPE_KEY    = slot_suffix .. "_type"  -- "default" | "flat"

    local function isFlat(pfx)
        return G_reader_settings:readSetting(pfx .. TYPE_KEY) == "flat"
    end

    local S = {}
    S.id         = "quick_actions_" .. slot
    S.name       = string.format(_("Quick Actions %d"), slot)
    S.label      = nil
    S.default_on = false

    function S.isEnabled(pfx)
        return G_reader_settings:readSetting(pfx .. slot_suffix .. "_enabled") == true
    end

    function S.setEnabled(pfx, on)
        G_reader_settings:saveSetting(pfx .. slot_suffix .. "_enabled", on)
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
        return true
    end

    local function getQAPool()
        local available = {}
        for _, a in ipairs(Config.ALL_ACTIONS) do
            if actionAvailable(a.id) then
                available[#available + 1] = {
                    id = a.id,
                    label = a.id == "home" and Config.homeLabel() or a.label,
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
        local slot_label = string.format(_("Quick Actions %d"), slot_n)
        local function getItems() return G_reader_settings:readSetting(items_key) or {} end
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
                        text    = string.format(_("Maximum %d actions per module reached. Remove one first."), MAX_QA),
                        timeout = 2,
                    })
                    return
                end
                new_items[#new_items + 1] = id
            end
            G_reader_settings:saveSetting(items_key, new_items)
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
                local SortWidget = ctx_menu.SortWidget or require("ui/widget/sortwidget")
                local uim = ctx_menu.UIManager or UIManager
                uim:show(SortWidget:new{
                    title             = string.format(_("Arrange %s"), slot_label),
                    covers_fullscreen = true,
                    item_table        = sort_items,
                    callback          = function()
                        local new_order = {}
                        for _i, item in ipairs(sort_items) do new_order[#new_order + 1] = item.orig_item end
                        G_reader_settings:saveSetting(items_key, new_order)
                        ctx_menu.refresh()
                    end,
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
                    if rem <= 0 then return _lbl .. "  (0 left)" end
                    if rem <= 2 then return _lbl .. "  (" .. rem .. " left)" end
                    return _lbl
                end,
                checked_func   = function() return isSelected(aid) end,
                keep_menu_open = true,
                callback       = function() toggleItem(aid) end,
            }
        end
        return {
            {
                text           = _("Hide Text"),
                checked_func   = function() return not G_reader_settings:nilOrTrue(labels_key) end,
                keep_menu_open = true,
                separator      = true,
                callback       = function()
                    G_reader_settings:saveSetting(labels_key, not G_reader_settings:nilOrTrue(labels_key))
                    ctx_menu.refresh()
                end,
            },
            {
                text                = _("Items"),
                sub_item_table_func = function() return items_sub end,
            },
        }
    end

    function S.getCountLabel(pfx)
        local n   = #(G_reader_settings:readSetting(pfx .. slot_suffix .. "_items") or {})
        local rem = MAX_QA - n
        if n == 0   then return nil end
        if rem <= 0 then return string.format("(%d/%d — at limit)", n, MAX_QA) end
        return string.format("(%d/%d — %d left)", n, MAX_QA, rem)
    end

    function S.build(w, ctx)
        if not S.isEnabled(ctx.pfx) then return nil end
        local items_key   = ctx.pfx .. slot_suffix .. "_items"
        local labels_key  = ctx.pfx .. slot_suffix .. "_labels"
        local qa_ids      = G_reader_settings:readSetting(items_key) or {}
        local show_labels = G_reader_settings:nilOrTrue(labels_key)
        local d           = _getQADims(Config.getModuleScale(S.id, ctx.pfx))
        -- Apply independent label text scale.
        local lbl_scale = Config.getItemLabelScale(S.id, ctx.pfx)
        d.lbl_fs = math.max(6, math.floor(d.lbl_fs * lbl_scale))
        return buildQAWidget(w, qa_ids, show_labels, ctx.on_qa_tap, d, isFlat(ctx.pfx))
    end

    function S.getHeight(ctx)
        local labels_key  = ctx.pfx .. slot_suffix .. "_labels"
        local show_labels = G_reader_settings:nilOrTrue(labels_key)
        local d           = _getQADims(Config.getModuleScale(S.id, ctx.pfx))
        return (show_labels and (d.frame_sz + d.lbl_sp + d.lbl_h) or d.frame_sz)
    end

    function S.getMenuItems(ctx_menu)
        local pfx     = ctx_menu.pfx
        local refresh = ctx_menu.refresh
        local _lc     = ctx_menu._
        local items = {}
        -- Scale first, with separator before the QA action items.
        items[#items + 1] = Config.makeScaleItem({
            text_func    = function() return _lc("Scale") end,
            enabled_func = function() return not Config.isScaleLinked() end,
            title        = _lc("Scale"),
            info         = _lc("Scale for this module.\n100% is the default size."),
            get          = function() return Config.getModuleScalePct(S.id, pfx) end,
            set          = function(v) Config.setModuleScale(v, S.id, pfx) end,
            refresh      = refresh,
        })
        local labels_key_local = pfx .. slot_suffix .. "_labels"
        items[#items + 1] = Config.makeScaleItem({
            text_func    = function() return _lc("Text Size") end,
            enabled_func = function() return G_reader_settings:nilOrTrue(labels_key_local) end,
            separator    = true,
            title        = _lc("Text Size"),
            info         = _lc("Scale for the button label text.\n100% is the default size."),
            get          = function() return Config.getItemLabelScalePct(S.id, pfx) end,
            set          = function(v) Config.setItemLabelScale(v, S.id, pfx) end,
            refresh      = refresh,
        })
        items[#items + 1] = {
            text_func = function()
                local t = isFlat(pfx) and _lc("Flat") or _lc("Default")
                return _lc("Type") .. " — " .. t
            end,
            sub_item_table = {
                {
                    text           = _lc("Default"),
                    checked_func   = function() return not isFlat(pfx) end,
                    keep_menu_open = true,
                    callback       = function()
                        G_reader_settings:saveSetting(pfx .. TYPE_KEY, "default")
                        refresh()
                    end,
                },
                {
                    text           = _lc("Flat"),
                    checked_func   = function() return isFlat(pfx) end,
                    keep_menu_open = true,
                    callback       = function()
                        G_reader_settings:saveSetting(pfx .. TYPE_KEY, "flat")
                        refresh()
                    end,
                },
            },
        }
        local fn = (type(ctx_menu.makeQAMenu) == "function") and ctx_menu.makeQAMenu or makeQAMenuFallback
        local qa = fn(ctx_menu, slot) or {}
        for _, v in ipairs(qa) do items[#items + 1] = v end
        return items
    end

    return S
end

-- ---------------------------------------------------------------------------
-- Export
-- ---------------------------------------------------------------------------
local M = {}
M.sub_modules = { makeSlot(1), makeSlot(2), makeSlot(3) }

-- Expose base frame size for menu.lua (MAX_QA_ITEMS referenced there).
-- Returns the 100%-scale value; callers that need the current scaled value
-- should call _getQADims(Config.getModuleScale(...)).frame_sz directly.
M.FRAME_SZ             = _BASE_ICON_SZ + _BASE_FRAME_PAD * 2
M.invalidateCustomQACache = QA.invalidateCustomQACache

return M
