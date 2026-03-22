-- module_recent.lua — Folio
-- Módulo: Recent Books.
-- Substitui a parte "recent" de recentbookswidget.lua.

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local UIManager       = require("ui/uimanager")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local Screen          = Device.screen
local _               = require("gettext")

local logger  = require("logger")
local _SH = nil
local function getSH()
    if not _SH then
        local ok, m = pcall(require, "desktop_modules/module_books_shared")
        if ok and m then _SH = m
        else logger.warn("folio: module_recent: cannot load module_books_shared: " .. tostring(m)) end
    end
    return _SH
end

local Config       = require("folio_config")
local FolioTheme     = require("folio_theme")
local UI           = require("folio_core")
local PAD          = UI.PAD
local PAD2         = UI.PAD2
local MOD_GAP      = UI.MOD_GAP
local LABEL_H      = UI.LABEL_H
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

local _BASE_RB_PCT_FS = Screen:scaleBySize(10)  -- "XX% Read" label font size — base value


local M = {}

M.id          = "recent"
M.name        = _("Recent Books")
M.label       = _("Recent Books")
M.enabled_key = "recent"
M.default_on  = true

-- Called by teardown (via _PLUGIN_MODULES flush) to drop the cached reference
-- to module_books_shared so a hot update picks up fresh code on next load.
function M.reset() _SH = nil end

function M.build(w, ctx)
    if not ctx.recent_fps or #ctx.recent_fps == 0 then return nil end

    local SH          = getSH()
    local scale       = Config.getModuleScale("recent", ctx.pfx)
    local thumb_scale = Config.getThumbScale("recent", ctx.pfx)
    local lbl_scale   = Config.getItemLabelScale("recent", ctx.pfx)
    local D           = SH.getDims(scale, thumb_scale)
    local pct_fs = math.max(8, math.floor(_BASE_RB_PCT_FS * scale * lbl_scale))

    local cols    = math.min(#ctx.recent_fps, 5)
    local cw      = D.RECENT_W
    local ch      = D.RECENT_H
    -- Space-between across 5 fixed slots with same lateral padding as other modules (PAD).
    local inner_w = w - PAD * 2
    local gap     = math.floor((inner_w - 5 * cw) / 4)
    -- Hoist the face lookup — same args for every cell, no need to call per iteration.
    local pct_face = FolioTheme.faceUI(pct_fs)

    local row = HorizontalGroup:new{ align = "top" }
    for i = 1, cols do
        local fp    = ctx.recent_fps[i]
        local bd    = SH.getBookData(fp, ctx.prefetched and ctx.prefetched[fp], ctx.db_conn)
        local cover = SH.getBookCover(fp, cw, ch) or SH.coverPlaceholder(bd.title, cw, ch)

        local cell = VerticalGroup:new{
            align = "center",
            cover,
            SH.vspan(D.RB_GAP1, ctx.vspan_pool),
            SH.progressBar(cw, bd.percent, D.RB_BAR_H),
            SH.vspan(D.RB_GAP2, ctx.vspan_pool),
            TextWidget:new{
                -- %d already truncates to integer — math.floor is redundant.
                text      = string.format(_("%d%% Read"), (bd.percent or 0) * 100),
                face      = pct_face,
                bold      = true,
                fgcolor   = CLR_TEXT_SUB,
                width     = cw,
                alignment = "center",
            },
        }

        local tappable = InputContainer:new{
            dimen    = Geom:new{ w = cw, h = D.RECENT_CELL_H },
            [1]      = cell,
            _fp      = fp,
            _open_fn = ctx.open_fn,
        }
        tappable.ges_events = {
            TapBook = {
                GestureRange:new{
                    ges   = "tap",
                    range = function() return tappable.dimen end,
                },
            },
        }
        function tappable:onTapBook()
            if self._open_fn then self._open_fn(self._fp) end
            return true
        end

        -- Use HorizontalSpan for inter-cell spacing instead of a zero-border
        -- FrameContainer — avoids 4 unnecessary widget allocations per render.
        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = tappable
    end

    return FrameContainer:new{
        bordersize = 0, padding = PAD, padding_top = 0, padding_bottom = 0,
        row,
    }
end

function M.getHeight(_ctx)
    local SH = getSH()
    local D  = SH.getDims(Config.getModuleScale("recent", _ctx and _ctx.pfx),
                           Config.getThumbScale("recent", _ctx and _ctx.pfx))
    return require("folio_config").getScaledLabelH() + D.RECENT_CELL_H
end


local function _makeScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size."),
        get          = function() return require("folio_config").getModuleScalePct("recent", pfx) end,
        set          = function(v) require("folio_config").setModuleScale(v, "recent", pfx) end,
        refresh      = ctx_menu.refresh,
    })
end

local function _makeThumbScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func = function() return _lc("Cover size") end,
        separator = true,
        title     = _lc("Cover size"),
        info      = _lc("Scale for the cover thumbnails only.\nText and progress bar follow the module scale.\n100% is the default size."),
        get       = function() return require("folio_config").getThumbScalePct("recent", pfx) end,
        set       = function(v) require("folio_config").setThumbScale(v, "recent", pfx) end,
        refresh   = ctx_menu.refresh,
    })
end

function M.getMenuItems(ctx_menu)
    local pfx     = ctx_menu.pfx
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._
    local label_item = Config.makeScaleItem({
        text_func = function() return _lc("Text Size") end,
        title     = _lc("Text Size"),
        info      = _lc("Scale for the percentage read text.\n100% is the default size."),
        get       = function() return Config.getItemLabelScalePct("recent", pfx) end,
        set       = function(v) Config.setItemLabelScale(v, "recent", pfx) end,
        refresh   = refresh,
    })
    return { _makeScaleItem(ctx_menu), label_item, _makeThumbScaleItem(ctx_menu) }
end

return M
