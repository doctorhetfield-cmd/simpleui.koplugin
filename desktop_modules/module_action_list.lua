-- module_action_list.lua — Simple UI
-- Módulo: Action List (módulo único).
-- Apresenta as quick actions como lista vertical de linhas tocáveis,
-- com ícone à esquerda e texto à direita (estilo launcher de apps).
--
-- Diferenças face ao module_quick_actions:
--   • Layout em lista (linhas) em vez de botões numa grelha.
--   • Alinhamento do conjunto: esquerda / centro / direita (default: centro).
--   • Opção de ocultar o ícone (em vez de ocultar o texto).
--   • Sem estilo "flat" — o ícone não tem moldura, o visual é limpo.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local ImageWidget     = require("ui/widget/imagewidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local RightContainer  = require("ui/widget/container/rightcontainer")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen

local _  = require("sui_i18n").translate
local N_ = require("sui_i18n").ngettext
local Config = require("sui_config")
local QA     = require("sui_quickactions")
local UI          = require("sui_core")
local PAD         = UI.PAD
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

local _BASE_PH_FS = Screen:scaleBySize(11)

-- ---------------------------------------------------------------------------
-- Base dimensions (at 100% scale)
-- ---------------------------------------------------------------------------
local _BASE_ROW_H    = Screen:scaleBySize(52)   -- height of each row
local _BASE_ICON_SZ  = Screen:scaleBySize(32)   -- icon square size
local _BASE_FS       = Screen:scaleBySize(18)   -- label font size
local _BASE_ICON_GAP = Screen:scaleBySize(16)   -- gap between icon and text
local _BASE_ROW_GAP  = Screen:scaleBySize(4)    -- vertical gap between rows

local function _getDims(scale)
    scale = scale or 1.0
    return {
        row_h    = math.max(32, math.floor(_BASE_ROW_H    * scale)),
        icon_sz  = math.max(14, math.floor(_BASE_ICON_SZ  * scale)),
        fs       = math.max(8,  math.floor(_BASE_FS       * scale)),
        icon_gap = math.max(6,  math.floor(_BASE_ICON_GAP * scale)),
        row_gap  = math.max(0,  math.floor(_BASE_ROW_GAP  * scale)),
    }
end

-- ---------------------------------------------------------------------------
-- Alignment setting helpers
-- ---------------------------------------------------------------------------
local ALIGN_VALUES = { "left", "center", "right" }

local function getAlignment(pfx, suffix)
    local v = G_reader_settings:readSetting(pfx .. suffix .. "_align")
    for _, a in ipairs(ALIGN_VALUES) do if a == v then return v end end
    return "center"  -- default
end

local function setAlignment(pfx, suffix, val)
    G_reader_settings:saveSetting(pfx .. suffix .. "_align", val)
end

local function alignLabel(align)
    if align == "left"  then return _("Left")  end
    if align == "right" then return _("Right") end
    return _("Center")
end

-- ---------------------------------------------------------------------------
-- Icon visibility helper
-- ---------------------------------------------------------------------------
local function isIconHidden(pfx, suffix)
    return G_reader_settings:readSetting(pfx .. suffix .. "_hide_icon") == true
end

-- ---------------------------------------------------------------------------
-- Action validity (mirrors module_quick_actions)
-- ---------------------------------------------------------------------------
local function getEntry(action_id)
    return QA.getEntry(action_id)
end

local function getCustomQAValid()
    return QA.getCustomQAValid()
end

-- ---------------------------------------------------------------------------
-- Core widget builder
-- ---------------------------------------------------------------------------
local function buildListWidget(w, action_ids, show_icons, align, on_tap_fn, d)
    -- Placeholder: no actions configured at all
    if not action_ids or #action_ids == 0 then
        local ph_fs = math.max(8, math.floor(_BASE_PH_FS * (d.row_h / _BASE_ROW_H)))
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = d.row_h },
            TextWidget:new{
                text    = _("No actions configured"),
                face    = Font:getFace("smallinfofont", ph_fs),
                fgcolor = CLR_TEXT_SUB,
                width   = w - PAD * 2,
            },
        }
    end

    -- Filter valid IDs
    local valid_ids = {}
    local cqa_valid = getCustomQAValid()
    for _, aid in ipairs(action_ids) do
        if aid:match("^custom_qa_%d+$") then
            if cqa_valid[aid] then valid_ids[#valid_ids + 1] = aid end
        elseif Config.ACTION_BY_ID[aid] then
            valid_ids[#valid_ids + 1] = aid
        end
    end
    -- Placeholder: actions were saved but none are valid anymore
    if #valid_ids == 0 then
        local ph_fs = math.max(8, math.floor(_BASE_PH_FS * (d.row_h / _BASE_ROW_H)))
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = d.row_h },
            TextWidget:new{
                text    = _("No actions configured"),
                face    = Font:getFace("smallinfofont", ph_fs),
                fgcolor = CLR_TEXT_SUB,
                width   = w - PAD * 2,
            },
        }
    end

    local inner_w = w - PAD * 2
    local n       = #valid_ids

    -- Width available for text (when icon is shown: subtract icon + gap)
    local text_w = show_icons and (inner_w - d.icon_sz - d.icon_gap) or inner_w

    local vg = VerticalGroup:new{ align = "center" }

    for i = 1, n do
        local aid   = valid_ids[i]
        local entry = getEntry(aid)

        -- ── Icon ──────────────────────────────────────────────────────────
        local icon_widget
        if show_icons then
            local nerd_char = Config.nerdIconChar(entry.icon)
            if nerd_char then
                icon_widget = CenterContainer:new{
                    dimen = Geom:new{ w = d.icon_sz, h = d.row_h },
                    TextWidget:new{
                        text    = nerd_char,
                        face    = Font:getFace("symbols", math.floor(d.icon_sz * 0.85)),
                        fgcolor = Blitbuffer.COLOR_BLACK,
                        padding = 0,
                    },
                }
            else
                icon_widget = CenterContainer:new{
                    dimen = Geom:new{ w = d.icon_sz, h = d.row_h },
                    ImageWidget:new{
                        file    = entry.icon,
                        width   = d.icon_sz,
                        height  = d.icon_sz,
                        is_icon = true,
                        alpha   = true,
                    },
                }
            end
        end

        -- ── Label ─────────────────────────────────────────────────────────
        local label_tw = TextWidget:new{
            text    = entry.label,
            face    = Font:getFace("cfont", d.fs),
            fgcolor = Blitbuffer.COLOR_BLACK,
            width   = text_w,
            padding = 0,
        }

        -- ── Row: icon + label, aligned as requested ────────────────────────
        -- We build the content HorizontalGroup (icon+gap+text) and then
        -- place it inside a full-width container with the chosen alignment.
        local content_w = show_icons
            and (d.icon_sz + d.icon_gap + label_tw:getSize().w)
            or  label_tw:getSize().w

        local hg = HorizontalGroup:new{ align = "center" }
        if show_icons then
            hg[#hg + 1] = icon_widget
            hg[#hg + 1] = HorizontalSpan:new{ width = d.icon_gap }
        end
        hg[#hg + 1] = CenterContainer:new{
            dimen = Geom:new{ w = label_tw:getSize().w, h = d.row_h },
            label_tw,
        }

        -- Cap content_w to inner_w
        content_w = math.min(content_w, inner_w)

        local row_content
        if align == "left" then
            row_content = LeftContainer:new{
                dimen = Geom:new{ w = inner_w, h = d.row_h },
                hg,
            }
        elseif align == "right" then
            row_content = RightContainer:new{
                dimen = Geom:new{ w = inner_w, h = d.row_h },
                hg,
            }
        else  -- center
            row_content = CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = d.row_h },
                hg,
            }
        end

        -- ── Tappable wrapper ───────────────────────────────────────────────
        local tappable = InputContainer:new{
            dimen      = Geom:new{ w = inner_w, h = d.row_h },
            [1]        = row_content,
            _on_tap_fn = on_tap_fn,
            _action_id = aid,
        }
        tappable.ges_events = {
            TapAL = {
                GestureRange:new{
                    ges   = "tap",
                    range = function() return tappable.dimen end,
                },
            },
        }
        function tappable:onTapAL()
            if self._on_tap_fn then self._on_tap_fn(self._action_id) end
            return true
        end

        if i > 1 and d.row_gap > 0 then
            vg[#vg + 1] = VerticalSpan:new{ width = d.row_gap }
        end
        vg[#vg + 1] = tappable
    end

    return FrameContainer:new{
        bordersize = 0, padding = PAD, padding_top = 0, padding_bottom = 0,
        vg,
    }
end

-- ---------------------------------------------------------------------------
-- Module descriptor
-- ---------------------------------------------------------------------------
local MOD_ID      = "action_list"
local MOD_SUFFIX  = "action_list"
local ITEMS_KEY   = MOD_SUFFIX .. "_items"
local HIDE_ICON_KEY = MOD_SUFFIX .. "_hide_icon"
local MAX_AL      = 12

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

local function getALPool()
    local available = {}
    for _, a in ipairs(Config.ALL_ACTIONS) do
        if actionAvailable(a.id) then
            available[#available + 1] = {
                id    = a.id,
                label = a.id == "home" and Config.homeLabel() or a.label,
            }
        end
    end
    for _, qa_id in ipairs(Config.getCustomQAList()) do
        local _qid = qa_id
        available[#available + 1] = {
            id    = _qid,
            label = Config.getCustomQAConfig(_qid).label,
        }
    end
    return available
end

local M = {}
M.id         = MOD_ID
M.name       = _("Action List")
M.label      = nil
M.default_on = false

function M.isEnabled(pfx)
    return G_reader_settings:readSetting(pfx .. MOD_SUFFIX .. "_enabled") == true
end

function M.setEnabled(pfx, on)
    G_reader_settings:saveSetting(pfx .. MOD_SUFFIX .. "_enabled", on)
end

function M.build(w, ctx)
    if not M.isEnabled(ctx.pfx) then return nil end
    local qa_ids    = G_reader_settings:readSetting(ctx.pfx .. ITEMS_KEY) or {}
    local show_icons = not isIconHidden(ctx.pfx, MOD_SUFFIX)
    local align     = getAlignment(ctx.pfx, MOD_SUFFIX)
    local d         = _getDims(Config.getModuleScale(MOD_ID, ctx.pfx))
    local lbl_scale = Config.getItemLabelScale(MOD_ID, ctx.pfx)
    d.fs = math.max(8, math.floor(d.fs * lbl_scale))
    return buildListWidget(w, qa_ids, show_icons, align, ctx.on_qa_tap, d)
end

function M.getHeight(ctx)
    local qa_ids = G_reader_settings:readSetting(ctx.pfx .. ITEMS_KEY) or {}
    local d      = _getDims(Config.getModuleScale(MOD_ID, ctx.pfx))
    local n      = #qa_ids
    -- When empty, getHeight must match the placeholder widget height
    if n == 0 then return d.row_h end
    n = math.min(n, MAX_AL)
    return n * d.row_h + math.max(0, n - 1) * d.row_gap + PAD * 2
end

function M.getMenuItems(ctx_menu)
    local pfx     = ctx_menu.pfx
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._
    local items   = {}

    -- Scale
    items[#items + 1] = Config.makeScaleItem({
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size."),
        get          = function() return Config.getModuleScalePct(MOD_ID, pfx) end,
        set          = function(v) Config.setModuleScale(v, MOD_ID, pfx) end,
        refresh      = refresh,
    })

    -- Text Size
    items[#items + 1] = Config.makeScaleItem({
        text_func    = function() return _lc("Text Size") end,
        separator    = true,
        title        = _lc("Text Size"),
        info         = _lc("Scale for the label text.\n100% is the default size."),
        get          = function() return Config.getItemLabelScalePct(MOD_ID, pfx) end,
        set          = function(v) Config.setItemLabelScale(v, MOD_ID, pfx) end,
        refresh      = refresh,
    })

    -- Hide Icon toggle
    items[#items + 1] = {
        text           = _lc("Hide Icon"),
        checked_func   = function() return isIconHidden(pfx, MOD_SUFFIX) end,
        keep_menu_open = true,
        callback       = function()
            G_reader_settings:saveSetting(pfx .. HIDE_ICON_KEY, not isIconHidden(pfx, MOD_SUFFIX))
            refresh()
        end,
    }

    -- Alignment submenu
    items[#items + 1] = {
        text_func = function()
            return _lc("Alignment") .. " — " .. alignLabel(getAlignment(pfx, MOD_SUFFIX))
        end,
        separator      = true,
        sub_item_table = {
            {
                text           = _lc("Left"),
                checked_func   = function() return getAlignment(pfx, MOD_SUFFIX) == "left" end,
                keep_menu_open = true,
                callback       = function() setAlignment(pfx, MOD_SUFFIX, "left");   refresh() end,
            },
            {
                text           = _lc("Center"),
                checked_func   = function() return getAlignment(pfx, MOD_SUFFIX) == "center" end,
                keep_menu_open = true,
                callback       = function() setAlignment(pfx, MOD_SUFFIX, "center"); refresh() end,
            },
            {
                text           = _lc("Right"),
                checked_func   = function() return getAlignment(pfx, MOD_SUFFIX) == "right" end,
                keep_menu_open = true,
                callback       = function() setAlignment(pfx, MOD_SUFFIX, "right");  refresh() end,
            },
        },
    }

    -- Items submenu (add/remove/arrange)
    local function getItems()
        return G_reader_settings:readSetting(pfx .. ITEMS_KEY) or {}
    end
    local function isSelected(id)
        for _, v in ipairs(getItems()) do if v == id then return true end end
        return false
    end
    local function toggleItem(id)
        local cur = getItems()
        local new = {}
        local found = false
        for _, v in ipairs(cur) do
            if v == id then found = true else new[#new + 1] = v end
        end
        if not found then
            if #cur >= MAX_AL then
                local InfoMessage = ctx_menu.InfoMessage or require("ui/widget/infomessage")
                local uim = ctx_menu.UIManager or require("ui/uimanager")
                uim:show(InfoMessage:new{
                    text    = string.format(
                        N_("The maximum of %d action per module has been reached. Remove one first.",
                           "The maximum of %d actions per module has been reached. Remove one first.",
                           MAX_AL), MAX_AL),
                    timeout = 2,
                })
                return
            end
            new[#new + 1] = id
        end
        G_reader_settings:saveSetting(pfx .. ITEMS_KEY, new)
        refresh()
    end

    local pool = {}
    for _, a in ipairs(getALPool()) do pool[#pool + 1] = a end
    table.sort(pool, function(a, b) return a.label:lower() < b.label:lower() end)

    local items_sub = {}
    items_sub[#items_sub + 1] = {
        text           = _lc("Arrange Items"),
        keep_menu_open = true,
        separator      = true,
        enabled_func   = function() return #getItems() >= 2 end,
        callback       = function()
            local qa_ids = getItems()
            if #qa_ids < 2 then
                local InfoMessage = ctx_menu.InfoMessage or require("ui/widget/infomessage")
                local uim = ctx_menu.UIManager or require("ui/uimanager")
                uim:show(InfoMessage:new{ text = _lc("Add at least 2 actions to arrange."), timeout = 2 })
                return
            end
            local pool_labels = {}
            for _, a in ipairs(getALPool()) do pool_labels[a.id] = a.label end
            local sort_items = {}
            for _, id in ipairs(qa_ids) do
                sort_items[#sort_items + 1] = { text = pool_labels[id] or id, orig_item = id }
            end
            local SortWidget = ctx_menu.SortWidget or require("ui/widget/sortwidget")
            local uim        = ctx_menu.UIManager  or require("ui/uimanager")
            uim:show(SortWidget:new{
                title             = string.format(_lc("Arrange %s"), M.name),
                covers_fullscreen = true,
                item_table        = sort_items,
                callback          = function()
                    local new_order = {}
                    for _, item in ipairs(sort_items) do
                        new_order[#new_order + 1] = item.orig_item
                    end
                    G_reader_settings:saveSetting(pfx .. ITEMS_KEY, new_order)
                    refresh()
                end,
            })
        end,
    }
    for _, a in ipairs(pool) do
        local aid  = a.id
        local _lbl = a.label
        items_sub[#items_sub + 1] = {
            text_func = function()
                if isSelected(aid) then return _lbl end
                local rem = MAX_AL - #getItems()
                if rem <= 2 then
                    return _lbl .. string.format(N_("  (%d left)", "  (%d left)", rem), rem)
                end
                return _lbl
            end,
            checked_func   = function() return isSelected(aid) end,
            keep_menu_open = true,
            callback       = function() toggleItem(aid) end,
        }
    end

    items[#items + 1] = {
        text                = _lc("Items"),
        sub_item_table_func = function() return items_sub end,
    }

    return items
end

M.invalidateCustomQACache = QA.invalidateCustomQACache

return M
