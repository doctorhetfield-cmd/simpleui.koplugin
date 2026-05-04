-- module_tbr.lua — Simple UI
-- Module: To Be Read (TBR).
-- Shows up to 5 books marked by the user as "to be read".
--
-- Persistence: the TBR list is mirrored as a KOReader collection named
-- TBR_COLL_NAME ("To Be Read").  ReadCollection is the source of truth;
-- G_reader_settings["sui_tbr_list"] is kept in sync as a legacy fallback
-- and for modules that read it directly.  On first run the old
-- G_reader_settings list is migrated into the collection automatically.
--
-- Entry points for marking books:
--   • Hold on a book in the Library (single-file dialog)  → via main.lua
--
-- Public API used by main.lua / sui_patches.lua:
--   M.TBR_COLL_NAME                                      → string
--   M.getTBRList()                                       → { fp, ... }
--   M.getTBRCount()                                      → number
--   M.isTBR(filepath)                                    → bool
--   M.addTBR(filepath)                                   → bool
--   M.removeTBR(filepath)
--   M.genTBRButton(file, close_cb)                       → button table

local Blitbuffer      = require("ffi/blitbuffer")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local CenterContainer = require("ui/widget/container/centercontainer")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local UIManager       = require("ui/uimanager")
local lfs             = require("libs/libkoreader-lfs")
local _ = require("sui_i18n").translate

local logger = require("logger")
local _SH    = nil
local function getSH()
    if not _SH then
        local ok, m = pcall(require, "desktop_modules/module_books_shared")
        if ok and m then _SH = m
        else logger.warn("simpleui: module_tbr: cannot load module_books_shared: " .. tostring(m)) end
    end
    return _SH
end

local Config = require("sui_config")
local UI     = require("sui_core")
local PAD    = UI.PAD
local Screen = require("device").screen

local CLR_TEXT_SUB    = UI.CLR_TEXT_SUB
local _BASE_RB_PCT_FS = Screen:scaleBySize(8)  -- "XX% Read" label font size — base value

local TBR_MAX       = 5
local TBR_SETTING   = "sui_tbr_list"    -- G_reader_settings key (kept in sync)
local TBR_COLL_NAME = "To Be Read"      -- KOReader collection name for the TBR list

-- Settings keys (prefixed with ctx.pfx at runtime)
local SETTING_PROGRESS = "tbr_show_progress"  -- default OFF
local SETTING_TEXT     = "tbr_show_text"       -- default OFF
local SETTING_OVERLAY  = "tbr_show_overlay"    -- default OFF

local function showProgress(pfx)
    return G_reader_settings:readSetting(pfx .. SETTING_PROGRESS) == true
end
local function showText(pfx)
    return G_reader_settings:readSetting(pfx .. SETTING_TEXT) == true
end
local function showOverlay(pfx)
    return G_reader_settings:readSetting(pfx .. SETTING_OVERLAY) == true
end

-- ---------------------------------------------------------------------------
-- ReadCollection accessor (lazy — RC singleton may not exist at require time)
-- ---------------------------------------------------------------------------

local function getRC()
    local ok, rc = pcall(require, "readcollection")
    return ok and rc or nil
end

-- ---------------------------------------------------------------------------
-- Migration: promote old G_reader_settings list into ReadCollection.
-- Called once at module load.  No-ops if collection already has entries.
-- ---------------------------------------------------------------------------

local function _migrate()
    local RC = getRC()
    if not RC then return end
    RC:_read()
    if not RC.coll[TBR_COLL_NAME] then
        RC:addCollection(TBR_COLL_NAME)
    end
    -- If already populated, nothing to migrate.
    if next(RC.coll[TBR_COLL_NAME]) then return end
    local raw = G_reader_settings:readSetting(TBR_SETTING)
    if type(raw) ~= "table" or #raw == 0 then return end
    local added = 0
    for _, fp in ipairs(raw) do
        if type(fp) == "string" and lfs.attributes(fp, "mode") == "file" then
            RC:addItem(fp, TBR_COLL_NAME)
            added = added + 1
        end
    end
    if added > 0 then
        RC:write({ [TBR_COLL_NAME] = true })
        logger.dbg("simpleui: module_tbr: migrated", added, "entries to ReadCollection")
    end
end

pcall(_migrate)

-- ---------------------------------------------------------------------------
-- Internal helpers — read/write RC directly, never through the hooked methods
-- so there is no re-entrancy between addTBR/removeTBR and the sui_patches hooks.
-- ---------------------------------------------------------------------------

-- Returns an ordered array of filepaths from RC (or G_reader_settings fallback).
local function getTBRList()
    local RC = getRC()
    if RC then
        RC:_read()
        local coll = RC.coll[TBR_COLL_NAME]
        if not coll then return {} end
        local items = {}
        for _, item in pairs(coll) do
            if lfs.attributes(item.file, "mode") == "file" then
                items[#items + 1] = item
            end
        end
        table.sort(items, function(a, b) return (a.order or 0) < (b.order or 0) end)
        local fps = {}
        for _, item in ipairs(items) do fps[#fps + 1] = item.file end
        return fps
    end
    -- Fallback
    local raw = G_reader_settings:readSetting(TBR_SETTING)
    if type(raw) ~= "table" then return {} end
    local clean = {}
    for _, fp in ipairs(raw) do
        if type(fp) == "string" and lfs.attributes(fp, "mode") == "file" then
            clean[#clean + 1] = fp
        end
    end
    return clean
end

-- Sync the canonical list into G_reader_settings for other modules.
local function _syncSettings(list)
    G_reader_settings:saveSetting(TBR_SETTING, list)
end

local function getTBRCount()
    return #getTBRList()
end

-- Resolve realpath once and check RC membership directly (no RC:_read call).
local function isTBR(filepath)
    local RC = getRC()
    if RC then
        RC:_read()
        local coll = RC.coll[TBR_COLL_NAME]
        if not coll then return false end
        local ok_fu, ffiUtil = pcall(require, "ffi/util")
        local real = ok_fu and ffiUtil.realpath(filepath) or filepath
        return (real and coll[real] ~= nil) or coll[filepath] ~= nil
    end
    -- Fallback
    for _, fp in ipairs(getTBRList()) do
        if fp == filepath then return true end
    end
    return false
end

--- Adds a book to the TBR list.
--- Writes directly to RC internals (bypassing the hooked RC.addItem) to avoid
--- re-entrancy; then syncs G_reader_settings.
--- Returns true on success, false if already at TBR_MAX.
local function addTBR(filepath)
    if isTBR(filepath) then return true end
    local list = getTBRList()
    if #list >= TBR_MAX then return false end

    local RC = getRC()
    if RC then
        RC:_read()
        if not RC.coll[TBR_COLL_NAME] then
            RC:addCollection(TBR_COLL_NAME)
        end
        -- Call the *original* (un-hooked) addItem by going through the metatable
        -- directly — we stored the original in plugin._orig_rc_additem, but we
        -- don't have access to plugin here.  Instead we build the entry manually,
        -- matching what buildEntry / addItem would do.
        local ffiUtil = require("ffi/util")
        local lfs2    = require("libs/libkoreader-lfs")
        local real    = ffiUtil.realpath(filepath) or filepath
        if real and lfs2.attributes(real, "mode") == "file" then
            -- Compute next order manually (same logic as RC:getCollectionNextOrder).
            local max_order = 0
            for _, item in pairs(RC.coll[TBR_COLL_NAME]) do
                if (item.order or 0) > max_order then max_order = item.order end
            end
            local attr = lfs2.attributes(real)
            RC.coll[TBR_COLL_NAME][real] = {
                file  = real,
                text  = real:gsub(".*/", ""),
                order = max_order + 1,
                attr  = attr,
            }
            RC:write({ [TBR_COLL_NAME] = true })
        end
    end

    -- Re-read the authoritative list after the RC write and sync settings.
    _syncSettings(getTBRList())
    return true
end

--- Removes a book from the TBR list.
--- Writes directly to RC internals (bypassing the hooked RC.removeItem).
local function removeTBR(filepath)
    local RC = getRC()
    if RC then
        RC:_read()
        local coll = RC.coll[TBR_COLL_NAME]
        if coll then
            local ffiUtil = require("ffi/util")
            local real    = ffiUtil.realpath(filepath) or filepath
            if real and coll[real] then
                coll[real] = nil
                RC:write({ [TBR_COLL_NAME] = true })
            elseif coll[filepath] then
                coll[filepath] = nil
                RC:write({ [TBR_COLL_NAME] = true })
            end
        end
    end
    -- Re-read and sync after RC write.
    _syncSettings(getTBRList())
end

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

local M = {}

M.id          = "tbr"
M.name        = _("To Be Read")
M.label       = _("To Be Read")
M.enabled_key = "tbr"
M.default_on  = false

function M.reset() _SH = nil end

-- Public constants
M.TBR_COLL_NAME = TBR_COLL_NAME
M.TBR_MAX       = TBR_MAX

-- Returns the localised display name for the TBR collection.
-- Use this wherever the name is shown to the user; keep TBR_COLL_NAME
-- for all RC / settings key lookups.
function M.getDisplayName()
    return _("To Be Read")
end

-- Public API
M.getTBRList  = getTBRList
M.getTBRCount = getTBRCount
M.isTBR       = isTBR
M.addTBR      = addTBR
M.removeTBR   = removeTBR

-- ---------------------------------------------------------------------------
-- genTBRButton — button for the single-book hold dialog.
-- Follows the same pattern as filemanagerutil.genStatusButtonsRow buttons.
-- ---------------------------------------------------------------------------
function M.genTBRButton(file, close_cb)
    local in_tbr    = isTBR(file)
    local count     = getTBRCount()
    local indicator = string.format("(%d/%d)", count, TBR_MAX)
    local full      = (not in_tbr) and (count >= TBR_MAX)

    return {
        text    = (in_tbr and _("Remove from To Be Read") or _("Add to To Be Read"))
                  .. "  " .. indicator,
        enabled = not full,
        callback = function()
            if in_tbr then removeTBR(file) else addTBR(file) end
            if close_cb then close_cb() end
        end,
    }
end

-- ---------------------------------------------------------------------------
-- build
-- ---------------------------------------------------------------------------

function M.build(w, ctx)
    Config.applyLabelToggle(M, _("To Be Read"))

    local tbr_fps = ctx._tbr_fps
    if not tbr_fps then
        tbr_fps = getTBRList()
        ctx._tbr_fps = tbr_fps
    end

    if #tbr_fps == 0 then return nil end

    local SH          = getSH()
    local scale       = Config.getModuleScale("tbr", ctx.pfx)
    local thumb_scale = Config.getThumbScale("tbr", ctx.pfx)
    local lbl_scale   = Config.getItemLabelScale("tbr", ctx.pfx)
    local D           = SH.getDims(scale, thumb_scale)
    local pct_fs      = math.max(8, math.floor(_BASE_RB_PCT_FS * scale * lbl_scale))

    local cols    = math.min(#tbr_fps, 5)
    local cw      = D.RECENT_W
    local ch      = D.RECENT_H
    local inner_w = w - PAD * 2
    local gap     = math.floor((inner_w - 5 * cw) / 4)
    local pct_face = Font:getFace("smallinfofont", pct_fs)

    local show_progress = showProgress(ctx.pfx)
    local show_text     = showText(ctx.pfx)
    local use_overlay   = showOverlay(ctx.pfx)

    local draw_progress = show_progress and not use_overlay
    local draw_text     = show_text     and not use_overlay

    local badge_r = math.floor(cw * 0.28)
    local cell_h  = use_overlay and (ch + badge_r) or D.RECENT_CELL_H

    local row = HorizontalGroup:new{ align = "top" }
    for i = 1, cols do
        local fp    = tbr_fps[i]
        local bd    = SH.getBookData(fp, ctx.prefetched and ctx.prefetched[fp])
        local cover = SH.getBookCover(fp, cw, ch, nil, 0.10) or SH.coverPlaceholder(bd.title, cw, ch)

        local cover_widget
        if use_overlay then
            local pct_int = math.floor((bd.percent or 0) * 100 + 0.5)
            local badge_d = badge_r * 2
            local badge = FrameContainer:new{
                bordersize  = 0,
                background  = Blitbuffer.gray(0.15),
                padding     = 0,
                dimen       = Geom:new{ w = badge_d, h = badge_d },
                radius      = badge_r,
                CenterContainer:new{
                    dimen = Geom:new{ w = badge_d, h = badge_d },
                    TextWidget:new{
                        text    = string.format(_("%d%%"), pct_int),
                        face    = pct_face,
                        bold    = true,
                        fgcolor = Blitbuffer.COLOR_BLACK,
                    },
                },
            }
            badge.overlap_offset = {
                math.floor((cw - badge_d) / 2),
                ch - badge_r,
            }
            cover_widget = OverlapGroup:new{
                dimen = Geom:new{ w = cw, h = ch + badge_r },
                cover,
                badge,
            }
        else
            cover_widget = cover
        end

        local cell = VerticalGroup:new{ align = "center", cover_widget }

        if draw_progress then
            cell[#cell+1] = SH.vspan(D.RB_GAP1, ctx.vspan_pool)
            cell[#cell+1] = SH.progressBar(cw, bd.percent, D.RB_BAR_H)
        end

        if draw_text then
            cell[#cell+1] = SH.vspan(draw_progress and D.RB_GAP2 or D.RB_GAP1, ctx.vspan_pool)
            cell[#cell+1] = TextWidget:new{
                text      = string.format(_("%d%% Read"), math.floor((bd.percent or 0) * 100 + 0.5)),
                face      = pct_face,
                bold      = true,
                fgcolor   = CLR_TEXT_SUB,
                width     = cw,
                alignment = "center",
            }
        end

        local tappable = InputContainer:new{
            dimen    = Geom:new{ w = cw, h = cell_h },
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

        local cell_widget = tappable
        if ctx.kb_recent_focus_idx == i then
            local bw = Screen:scaleBySize(3)
            cell_widget = OverlapGroup:new{
                dimen = Geom:new{ w = cw, h = cell_h },
                tappable,
                LineWidget:new{ dimen = Geom:new{ w = cw, h = bw },    background = Blitbuffer.COLOR_BLACK },
                LineWidget:new{ dimen = Geom:new{ w = cw, h = bw },    background = Blitbuffer.COLOR_BLACK, overlap_offset = {0, cell_h - bw} },
                LineWidget:new{ dimen = Geom:new{ w = bw, h = cell_h }, background = Blitbuffer.COLOR_BLACK },
                LineWidget:new{ dimen = Geom:new{ w = bw, h = cell_h }, background = Blitbuffer.COLOR_BLACK, overlap_offset = {cw - bw, 0} },
            }
        end

        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = cell_widget
    end

    return FrameContainer:new{
        bordersize = 0, padding = PAD, padding_top = 0, padding_bottom = 0,
        row,
    }
end

-- ---------------------------------------------------------------------------
-- getHeight
-- ---------------------------------------------------------------------------

function M.getHeight(_ctx)
    local SH  = getSH()
    local pfx = _ctx and _ctx.pfx or ""
    local D   = SH.getDims(Config.getModuleScale("tbr", pfx),
                            Config.getThumbScale("tbr", pfx))
    local use_overlay = showOverlay(pfx)
    local h = D.RECENT_H
    if use_overlay then
        local badge_r = math.floor(D.RECENT_W * 0.28)
        h = h + badge_r
    else
        if showProgress(pfx) then
            h = h + D.RB_GAP1 + D.RB_BAR_H
            if showText(pfx) then h = h + D.RB_GAP2 end
        end
        if showText(pfx) then
            if not showProgress(pfx) then h = h + D.RB_GAP1 end
            h = h + D.RB_LABEL_H
        end
    end
    return require("sui_config").getScaledLabelH() + h
end

-- ---------------------------------------------------------------------------
-- getMenuItems
-- ---------------------------------------------------------------------------

local function _makeScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size."),
        get          = function() return Config.getModuleScalePct("tbr", pfx) end,
        set          = function(v) Config.setModuleScale(v, "tbr", pfx) end,
        refresh      = ctx_menu.refresh,
    })
end

-- Returns a short display title for a filepath.
local function _getBookTitle(fp)
    local title = fp:match("([^/]+)%.[^%.]+$") or fp
    pcall(function()
        local DS = require("docsettings")
        local ok2, ds = pcall(DS.open, DS, fp)
        if ok2 and ds then
            local rp = ds:readSetting("doc_props") or {}
            if rp.title and rp.title ~= "" then title = rp.title end
            pcall(function() ds:close() end)
        end
    end)
    if #title > 48 then title = title:sub(1, 45) .. "…" end
    return title
end

function M.getMenuItems(ctx_menu)
    local _lc      = ctx_menu._
    local refresh  = ctx_menu.refresh
    local pfx      = ctx_menu.pfx
    local SortWidget = ctx_menu.SortWidget
    local _UIManager = ctx_menu.UIManager
    local InfoMessage = ctx_menu.InfoMessage

    local items = {}

    items[#items + 1] = _makeScaleItem(ctx_menu)
    items[#items + 1] = Config.makeScaleItem({
        text_func = function() return _lc("Text Size") end,
        title     = _lc("Text Size"),
        info      = _lc("Scale for the percentage read text.\n100% is the default size."),
        get       = function() return Config.getItemLabelScalePct("tbr", pfx) end,
        set       = function(v) Config.setItemLabelScale(v, "tbr", pfx) end,
        refresh   = refresh,
    })
    items[#items + 1] = Config.makeLabelToggleItem("tbr", _("To Be Read"), refresh, _lc)
    items[#items + 1] = Config.makeScaleItem({
        text_func = function() return _lc("Cover size") end,
        separator = true,
        title     = _lc("Cover size"),
        info      = _lc("Scale for the cover thumbnails only.\nText and progress bar follow the module scale.\n100% is the default size."),
        get       = function() return Config.getThumbScalePct("tbr", pfx) end,
        set       = function(v) Config.setThumbScale(v, "tbr", pfx) end,
        refresh   = refresh,
    })
    items[#items + 1] = {
        text           = _lc("Progress bar"),
        checked_func   = function() return showProgress(pfx) end,
        enabled_func   = function() return not showOverlay(pfx) end,
        keep_menu_open = true,
        callback       = function()
            G_reader_settings:saveSetting(pfx .. SETTING_PROGRESS, not showProgress(pfx))
            refresh()
        end,
    }
    items[#items + 1] = {
        text           = _lc("Percentage text"),
        checked_func   = function() return showText(pfx) end,
        enabled_func   = function() return not showOverlay(pfx) end,
        keep_menu_open = true,
        callback       = function()
            G_reader_settings:saveSetting(pfx .. SETTING_TEXT, not showText(pfx))
            refresh()
        end,
    }
    items[#items + 1] = {
        text           = _lc("Percentage overlay on cover"),
        checked_func   = function() return showOverlay(pfx) end,
        keep_menu_open = true,
        callback       = function()
            G_reader_settings:saveSetting(pfx .. SETTING_OVERLAY, not showOverlay(pfx))
            refresh()
        end,
    }

    -- Arrange TBR list — SortWidget with covers_fullscreen, same as Collections.
    items[#items + 1] = {
        text         = _lc("Arrange To Be Read list"),
        enabled_func = function() return getTBRCount() > 1 end,
        keep_menu_open = true,
        callback = function()
            local list = getTBRList()
            if #list < 2 then
                _UIManager:show(InfoMessage:new{
                    text = _lc("Add at least 2 books to arrange."), timeout = 2 })
                return
            end
            local sort_items = {}
            for _, fp in ipairs(list) do
                sort_items[#sort_items + 1] = {
                    text     = _getBookTitle(fp),
                    filepath = fp,
                    mandatory = "",
                }
            end
            _UIManager:show(SortWidget:new{
                title             = _lc("Arrange To Be Read list"),
                item_table        = sort_items,
                covers_fullscreen = true,
                callback          = function()
                    local new_list = {}
                    for _, item in ipairs(sort_items) do
                        if item.filepath then
                            new_list[#new_list + 1] = item.filepath
                        end
                    end
                    -- Persist new order into ReadCollection.
                    local RC2 = getRC()
                    if RC2 and RC2.coll[TBR_COLL_NAME] then
                        local ordered = {}
                        for _, fp in ipairs(new_list) do
                            local entry = RC2.coll[TBR_COLL_NAME][fp]
                            if entry then ordered[#ordered + 1] = entry end
                        end
                        RC2:updateCollectionOrder(TBR_COLL_NAME, ordered)
                        RC2:write({ [TBR_COLL_NAME] = true })
                    end
                    _syncSettings(new_list)
                    refresh()
                end,
            })
        end,
    }

    -- Separator before book list (same visual pattern as Collections).
    items[#items + 1] = { text = _lc("To Be Read books"), enabled = false, separator = true }

    -- One checkbox entry per book in the TBR list.
    local list = getTBRList()
    if #list == 0 then
        items[#items + 1] = { text = _lc("No books in To Be Read list."), enabled = false }
    else
        for _, fp in ipairs(list) do
            local _fp    = fp
            local _title = _getBookTitle(fp)
            items[#items + 1] = {
                text           = _title,
                checked_func   = function() return isTBR(_fp) end,
                keep_menu_open = true,
                callback       = function()
                    removeTBR(_fp)
                    refresh()
                end,
            }
        end
    end

    return items
end

return M
