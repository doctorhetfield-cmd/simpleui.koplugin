-- module_action_list.lua — Simple UI
-- Module: Action List (single module).
-- Presents the quick actions as a vertical list of tappable rows,
-- with an icon on the left and text on the right (app-launcher style).
--

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen

local _  = require("infra/sui_i18n").translate
local N_ = require("infra/sui_i18n").ngettext
local Config = require("infra/sui_config")
local Arrange     = require("features/sui_arrange")
local QA          = require("features/sui_quickactions")
local QARenderer  = require("engines/sui_quickactions_render")
local UI          = require("infra/sui_core")
local SUISettings = require("infra/sui_store")
local SUIStyle    = require("features/sui_style")
local PAD         = UI.PAD
local Chrome       = require("features/sui_module_chrome")

local _BASE_PH_FS = SUIStyle.FS_BODY    -- 18: placeholder text

-- ---------------------------------------------------------------------------
-- Base dimensions (at 100% scale)
-- ---------------------------------------------------------------------------
local _BASE_ROW_H    = Screen:scaleBySize(42)   -- height of each row
local _BASE_ICON_SZ  = Screen:scaleBySize(32)   -- icon square size
local _BASE_FS       = SUIStyle.FS_TITLE         -- 22: label font size
local _BASE_ICON_GAP = Screen:scaleBySize(16)   -- gap between icon and text
local _BASE_ROW_GAP  = Screen:scaleBySize(0)    -- vertical gap between rows

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
-- Alignment setting
-- ---------------------------------------------------------------------------
local function alignKey(pfx, suffix)
    return pfx .. suffix .. "_align"
end

local function getAlignment(pfx, suffix)
    return Config.getAlignment(alignKey(pfx, suffix))
end

-- ---------------------------------------------------------------------------
-- Icon visibility helper
-- ---------------------------------------------------------------------------
local function isIconHidden(pfx, suffix)
    return SUISettings:readSetting(pfx .. suffix .. "_hide_icon") == true
end

-- ---------------------------------------------------------------------------
-- Action validity — QA.filterValidIds is the single source of truth,
-- shared with module_quick_actions and QA.showQAFolderDialog.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Core widget builder
-- ---------------------------------------------------------------------------
-- `on_stops(stops)`, when given, receives the rows as { id, widget } D-pad
-- focus stops, top to bottom (each one is a focus row of its own).
local function buildListWidget(w, action_ids, show_icons, align, on_tap_fn, d, ink, on_stops)
    -- Placeholder: no actions configured at all
    if not action_ids or #action_ids == 0 then
        local ph_fs   = math.max(8, math.floor(_BASE_PH_FS * (d.row_h / _BASE_ROW_H)))
        local hold_on = SUISettings:nilOrTrue("simpleui_hs_settings_on_hold")
        local ph_text = hold_on and _("No actions configured  —  long press to configure")
                                 or _("No actions configured")
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = d.row_h },
            UI.makeColoredText{
                text    = ph_text,
                face    = Font:getFace(SUIStyle.FACE_REGULAR, ph_fs),
                fgcolor = ink.sub,
                width   = w - PAD * 2,
            },
        }
    end

    -- Filter valid IDs
    local valid_ids = QA.filterValidIds(action_ids)
    -- Placeholder: actions were saved but none are valid anymore
    if #valid_ids == 0 then
        local ph_fs   = math.max(8, math.floor(_BASE_PH_FS * (d.row_h / _BASE_ROW_H)))
        local hold_on = SUISettings:nilOrTrue("simpleui_hs_settings_on_hold")
        local ph_text = hold_on and _("No actions configured  —  long press to configure")
                                 or _("No actions configured")
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = d.row_h },
            UI.makeColoredText{
                text    = ph_text,
                face    = Font:getFace(SUIStyle.FACE_REGULAR, ph_fs),
                fgcolor = ink.sub,
                width   = w - PAD * 2,
            },
        }
    end

    local n = #valid_ids

    -- Rows keep their natural width and are aligned against each other inside
    -- the group, whose width is that of its widest row.
    local vg = VerticalGroup:new{ align = align }

    -- icon_opts covers this row layout's one remaining structural
    -- difference from the other QA consumers: the icon sits beside a label
    -- rather than above it, so it's centered in a taller container (row
    -- height, not icon size) to give it a full-row-height hitbox.
    local icon_opts = {
        container_h             = d.row_h,
        wrap_image_in_container  = true,
        -- Icons take the ink colour over a tinted fill.
        tint                    = ink ~= Chrome.PLAIN_INK or nil,
    }

    local stops = {}
    for i = 1, n do
        local aid = valid_ids[i]
        local row_content = QARenderer.buildListRow(aid, {
            inner_w        = w,
            row_h          = d.row_h,
            show_icon      = show_icons,
            icon_sz        = d.icon_sz,
            icon_gap       = d.icon_gap,
            lbl_face       = d.lbl_face,
            lbl_bold       = d.lbl_bold,
            fgcolor        = ink.blk,
            icon_opts      = icon_opts,
            on_tap_fn      = on_tap_fn,
            tap_event_name = "TapAL",
            focusable      = on_stops ~= nil,
        })
        stops[i] = { id = i, widget = row_content }

        if i > 1 and d.row_gap > 0 then
            vg[#vg + 1] = VerticalSpan:new{ width = d.row_gap }
        end
        vg[#vg + 1] = row_content
    end
    if on_stops then on_stops(stops) end

    -- `fit_align` makes the module chrome hug the list and position it within
    -- the column (see ModuleChrome.wrap). Horizontal insets come from the chrome.
    return FrameContainer:new{
        bordersize = 0, padding = 0,
        fit_align = align,
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
    if QA.getBrowseMode(id) then
        local ok_bm, BM = pcall(require, "features/library/sui_library_browse")
        return ok_bm and BM and BM.isEnabled()
    end
    return true
end

local function getALPool()
    local available = {}
    -- QA.allIds() — NOT QA.iterBuiltin() — so externally registered actions
    -- (e.g. a Custom Screen's "open_custom_screen:<id>" QA, see
    -- infra/sui_custom_screens.lua) are selectable here too. Same fix as
    -- module_quick_actions.lua's getQAPool().
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
M.category   = "shortcuts"
M.label      = nil
M.default_on = false
M.text_elems = { "label" }

function M.isEnabled(pfx)
    return SUISettings:readSetting(pfx .. MOD_SUFFIX .. "_enabled") == true
end

function M.setEnabled(pfx, on)
    SUISettings:saveSetting(pfx .. MOD_SUFFIX .. "_enabled", on)
end

-- Layout-editor summary: the labels of the configured actions.
function M.getSummary(_id, pfx)
    local labels = {}
    for _i, entry in ipairs(getALPool()) do labels[entry.id] = entry.label end
    local names = {}
    for _i, id in ipairs(SUISettings:readSetting(pfx .. ITEMS_KEY) or {}) do
        names[#names + 1] = labels[id] or id
    end
    return #names > 0 and table.concat(names, "  ·  ") or nil
end

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

function M.build(w, ctx)
    if not M.isEnabled(ctx.pfx) then return nil end
    local qa_ids    = SUISettings:readSetting(ctx.pfx .. ITEMS_KEY) or {}
    local show_icons = not isIconHidden(ctx.pfx, MOD_SUFFIX)
    local align     = getAlignment(ctx.pfx, MOD_SUFFIX)
    local lf        = ctx.landscape_factor or 1
    local d         = _getDims(Config.getModuleScale(MOD_ID, ctx.pfx) * lf)
    _migrateLabelScale(MOD_ID, ctx.pfx)
    local styles = Config.resolveTextStyles(ctx, MOD_ID, M.text_elems)
    d.fs = math.max(8, math.floor(d.fs * lf * (styles.label.scale or 1)))
    d.lbl_face, d.lbl_bold = SUIStyle.getTextFace(styles.label, d.fs)
    return buildListWidget(w, qa_ids, show_icons, align, ctx.on_qa_tap, d, ctx.ink or Chrome.PLAIN_INK,
        ctx.kbStops and function(stops)
            for i, stop in ipairs(stops) do ctx.kbStops(MOD_ID .. ":" .. i, { stop }) end
        end)
end

function M.getHeight(ctx)
    local qa_ids = SUISettings:readSetting(ctx.pfx .. ITEMS_KEY) or {}
    local d      = _getDims(Config.getModuleScale(MOD_ID, ctx.pfx) * (ctx.landscape_factor or 1))
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
    local items = {
        Arrange.makeListItem{
            ctx_menu = ctx_menu,
            title    = _lc("Quick Actions"),
            labels   = {
                action  = string.format(_lc("Arrange %s"), M.name),
                empty   = _lc("No items selected."),
                too_few = _lc("Add at least 2 actions to arrange."),
                full    = function(max)
                    return string.format(N_("The maximum of %d action per module has been reached. Remove one first.",
                        "The maximum of %d actions per module has been reached. Remove one first.", max), max)
                end,
            },
            max    = MAX_AL,
            pool   = getALPool,
            getIds = function() return SUISettings:readSetting(pfx .. ITEMS_KEY) or {} end,
            setIds = function(ids) SUISettings:saveSetting(pfx .. ITEMS_KEY, ids) end,
        },
    }

    items[#items + 1] = {
        text_func      = function() return _lc("Size") end,
        sub_item_table = {
            Config.makeScaleItem({
                text_func    = function() return _lc("Scale") end,
                enabled_func = function() return not Config.isScaleLinked() end,
                title        = _lc("Scale"),
                info         = _lc("Scale for this module.\n100% is the default size."),
                get          = function() return Config.getModuleScalePct(MOD_ID, pfx) end,
                set          = function(v) Config.setModuleScale(v, MOD_ID, pfx) end,
                refresh      = refresh,
            }),
        },
    }

    items[#items + 1] = {
        text           = _lc("Show Icon"),
        checked_func   = function() return not isIconHidden(pfx, MOD_SUFFIX) end,
        keep_menu_open = true,
        callback       = function()
            SUISettings:saveSetting(pfx .. HIDE_ICON_KEY, not isIconHidden(pfx, MOD_SUFFIX))
            refresh()
        end,
    }
    items[#items + 1] = Config.makeAlignmentItem{
        key     = alignKey(pfx, MOD_SUFFIX),
        refresh = refresh,
        _lc     = _lc,
    }

    -- Partition into canonical sections (Items already first in `items`).
    local item_rows, size_rows, extra_rows = {}, {}, {}
    for _, row in ipairs(items) do
        local label = row.text or (row.text_func and row.text_func()) or ""
        if label == _lc("Size") or (row.text_func and row.text_func() == _lc("Size")) then
            if row.sub_item_table then
                for _, s in ipairs(row.sub_item_table) do size_rows[#size_rows+1] = s end
            else
                size_rows[#size_rows+1] = row
            end
        elseif label == _lc("Label") then
            -- Typography lives in appearance.text (not duplicated here).
        elseif label == _lc("Show Icon") or label == _lc("Alignment") or (row.text_func and row.text_func() == _lc("Alignment")) then
            extra_rows[#extra_rows+1] = row
        else
            item_rows[#item_rows+1] = row
        end
    end
    return Config.buildModuleMenu({
        items = item_rows,
        appearance = {
            size  = #size_rows > 0 and size_rows or nil,
            text  = {
                mod_id  = MOD_ID,
                elems   = M.text_elems,
                labels  = { label = _lc("Label") },
                info    = _lc("Size of this text.\n100% is the default size."),
                pfx     = pfx,
                refresh = refresh,
                _lc     = _lc,
            },
            extra = extra_rows,
        },
    }, ctx_menu)
end

M.invalidateCustomQACache = QA.invalidateCustomQACache

return M
