-- module_tbr.lua — Simple UI
-- Module: To Be Read (TBR).
-- Shows up to 5 books marked by the user as "to be read".
--
-- Persistence: the TBR list is mirrored as a KOReader collection named
-- TBR_COLL_NAME ("To Be Read").  ReadCollection is the source of truth;
-- G_reader_settings["simpleui_tbr_list"] is kept in sync as a legacy fallback
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
local Size            = require("ui/size")

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

local Config      = require("sui_config")
local UI          = require("sui_core")
local SUISettings = require("sui_store")
local SUIStyle    = require("sui_style")
local PAD    = UI.PAD
local Screen = require("device").screen

local CLR_TEXT_SUB    = UI.CLR_TEXT_SUB
local _BASE_RB_PCT_FS = SUIStyle.FS_DETAIL  -- 15: "XX% Read" label font size

local TBR_MAX       = 5
local TBR_SETTING   = "simpleui_tbr_list"    -- G_reader_settings key (kept in sync)
local TBR_COLL_NAME = "To Be Read"      -- KOReader collection name for the TBR list

-- Settings keys (prefixed with ctx.pfx at runtime)
local SETTING_PROGRESS = "tbr_show_progress"  -- default OFF
local SETTING_TEXT     = "tbr_show_text"       -- default OFF
local SETTING_OVERLAY  = "tbr_show_overlay"    -- default OFF

local function showProgress(pfx)
    return SUISettings:readSetting(pfx .. SETTING_PROGRESS) == true
end
local function showText(pfx)
    return SUISettings:readSetting(pfx .. SETTING_TEXT) == true
end
local function showOverlay(pfx)
    return SUISettings:readSetting(pfx .. SETTING_OVERLAY) == true
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
    -- Not calling RC:_read() — readcollection.lua already reads collection.lua
    -- once at require() time, so the singleton returned by getRC() is already
    -- populated. Calling _read() again is redundant and, worse, destructively
    -- reloads rc.coll/rc.coll_settings from disk, which can wipe in-memory
    -- collection changes the native Collections UI hasn't flushed yet.
    if not (RC.coll and RC.coll[TBR_COLL_NAME]) then
        RC:addCollection(TBR_COLL_NAME)
    end
    -- If already populated, nothing to migrate.
    if RC.coll and RC.coll[TBR_COLL_NAME] and next(RC.coll[TBR_COLL_NAME]) then return end
    local raw = SUISettings:readSetting(TBR_SETTING)
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
        -- Not calling RC:_read() — it destructively reloads rc.coll from
        -- disk and can wipe an in-memory-only collection (e.g. one just
        -- created via the native Collections UI but not yet saved). This
        -- function runs on nearly every repaint, so a single stray write to
        -- collection.lua elsewhere (e.g. a TBR sync) was enough to trigger
        -- the wipe on the very next call.
        local coll = RC.coll and RC.coll[TBR_COLL_NAME]
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
    local raw = SUISettings:readSetting(TBR_SETTING)
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
    SUISettings:saveSetting(TBR_SETTING, list)
end

local function getTBRCount()
    return #getTBRList()
end

-- Resolve realpath once and check RC membership directly (no RC:_read call).
local function isTBR(filepath)
    local RC = getRC()
    if RC then
        -- Not calling RC:_read() — see note in getTBRList() above.
        local coll = RC.coll and RC.coll[TBR_COLL_NAME]
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
        -- Not calling RC:_read() — see note in getTBRList() above.
        if not (RC.coll and RC.coll[TBR_COLL_NAME]) then
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
        -- Not calling RC:_read() — see note in getTBRList() above.
        local coll = RC.coll and RC.coll[TBR_COLL_NAME]
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
M.enabled_key = "tbr_enabled"
M.default_on  = false
M.has_covers  = true   -- activates e-ink dithering and cover poll

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

    local ok_ss, SUIStyle = pcall(require, "sui_style")
    local _theme_fg       = ok_ss and SUIStyle and SUIStyle.getThemeColor("fg")
    local _theme_secondary = ok_ss and SUIStyle and SUIStyle.getThemeColor("text_secondary")
    local _clr_blk        = _theme_fg or Blitbuffer.COLOR_BLACK
    local _clr_sub        = _theme_secondary or _theme_fg or CLR_TEXT_SUB

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
    local pct_face = Font:getFace(SUIStyle.FACE_REGULAR, pct_fs)

    local show_progress = showProgress(ctx.pfx)
    local show_text     = showText(ctx.pfx)
    local use_overlay   = showOverlay(ctx.pfx)

    local draw_progress = show_progress and not use_overlay
    local draw_text     = show_text     and not use_overlay

    local badge_r = math.floor(cw * 0.28)
    local cell_h  = use_overlay and (ch + badge_r) or D.RECENT_CELL_H

    local row = HorizontalGroup:new{ align = "top" }
    local cover_slots = {}
    for i = 1, cols do
        local fp    = tbr_fps[i]
        local bd    = SH.getBookData(fp, ctx.prefetched and ctx.prefetched[fp])
        local cover = SH.getBookCover(fp, cw, ch, nil, 0.10) or SH.coverPlaceholder(bd.title, bd.authors, cw, ch)

        local cover_widget
        if use_overlay then
            local pct_int = math.floor((bd.percent or 0) * 100 + 0.5)
            local badge_d = badge_r * 2
            local border_sz = SUIStyle.BADGE_BORDER_SZ
            local border_color = SUIStyle.BADGE_BORDER_CLR
            local badge = FrameContainer:new{
                bordersize  = border_sz,
                color       = border_color,
                background  = Blitbuffer.gray(0.15),
                padding     = 0,
                dimen       = Geom:new{ w = badge_d, h = badge_d },
                radius      = badge_r,
                CenterContainer:new{
                    dimen = Geom:new{ w = badge_d - 2 * border_sz, h = badge_d - 2 * border_sz },
                    UI.makeColoredText{
                        text    = string.format(_("%d%%"), pct_int),
                        face    = pct_face,
                        bold    = true,
                        fgcolor = _clr_blk,
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
            cell[#cell+1] = UI.progressBar(cw, bd.percent, D.RB_BAR_H)
        end

        if draw_text then
            cell[#cell+1] = SH.vspan(draw_progress and D.RB_GAP2 or D.RB_GAP1, ctx.vspan_pool)
            cell[#cell+1] = UI.makeColoredText{
                text      = string.format(_("%d%% Read"), math.floor((bd.percent or 0) * 100 + 0.5)),
                face      = pct_face,
                bold      = true,
                fgcolor   = _clr_sub,
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

        if use_overlay then
            cover_slots[#cover_slots+1] = { container = cover_widget, idx = 1, fp = fp, w = cw, h = ch, align = nil, stretch = 0.10 }
        else
            cover_slots[#cover_slots+1] = { container = cell, idx = 1, fp = fp, w = cw, h = ch, align = nil, stretch = 0.10 }
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

    local show_frame = SUISettings:isTrue(ctx.pfx .. "tbr_show_frame")
    local solid_bg   = SUISettings:isTrue(ctx.pfx .. "tbr_solid_bg")
    local has_box    = show_frame or solid_bg
    local border_sz  = show_frame and SUIStyle.BORDER_SZ or 0
    local radius     = has_box and math.floor(Screen:scaleBySize(12) * scale) or 0
    local border_color = Blitbuffer.gray(0.72)
    if ok_ss and SUIStyle then
        border_color = SUIStyle.getThemeColor("separator") or border_color
    end
    local bg_color = nil
    if solid_bg then
        bg_color = (ok_ss and SUIStyle and SUIStyle.getThemeColor("bg")) or Blitbuffer.COLOR_WHITE
    end

    local result = FrameContainer:new{
        bordersize = border_sz,
        radius     = radius,
        color      = border_color,
        background = bg_color,
        padding = PAD, padding_top = has_box and PAD or 0, padding_bottom = has_box and PAD or 0,
        row,
    }
    result._cover_slots = cover_slots
    return result
end

function M.updateCovers(widget, _ctx)
    if not widget or not widget._cover_slots then return true end
    local SH = getSH()
    if not SH then return true end
    local all_done = true
    for _, slot in ipairs(widget._cover_slots) do
        local new_cover = SH.getBookCover(slot.fp, slot.w, slot.h, slot.align, slot.stretch)
        if new_cover then
            slot.container[slot.idx] = new_cover
        elseif not Config.isCoverMissing(slot.fp) then
            all_done = false
        end
    end
    return all_done
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
    if SUISettings:isTrue(pfx .. "tbr_show_frame") or SUISettings:isTrue(pfx .. "tbr_solid_bg") then
        h = h + PAD * 2
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

    items[#items + 1] = {
        text = _lc("Arrange"),
        sub_item_table_func = function()
            local sub_items = {}
            
            sub_items[#sub_items + 1] = {
                text         = _lc("Arrange To Be Read List"),
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
                    local function on_save()
                        local new_list = {}
                        for _, item in ipairs(sort_items) do
                            if item.filepath then
                                new_list[#new_list + 1] = item.filepath
                            end
                        end
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
                    end
                    _UIManager:show(SortWidget:new{ title = _lc("Arrange To Be Read List"), item_table = sort_items, covers_fullscreen = true, callback = on_save })
                end,
            }

            sub_items[#sub_items + 1] = { text = _lc("To Be Read Books"), enabled = false, separator = true }

            local list = getTBRList()
            if #list == 0 then
                sub_items[#sub_items + 1] = { text = _lc("No books in To Be Read list."), enabled = false }
            else
                for _, fp in ipairs(list) do
                    local _fp    = fp
                    local _title = _getBookTitle(fp)
                    sub_items[#sub_items + 1] = {
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

            return sub_items
        end,
        sui_build = ctx_menu.is_sui and function(ctx, _item)
            local SUIWindow = require("sui_window")
            return SUIWindow.ListRow{
                title        = _lc("Arrange"),
                subtitle     = function()
                    local list = getTBRList()
                    if #list == 0 then return _lc("No books in To Be Read list.") end
                    local names = {}
                    for _, fp in ipairs(list) do
                        names[#names + 1] = _getBookTitle(fp)
                    end
                    return table.concat(names, "  ·  ")
                end,
                inner_w      = ctx.inner_w,
                show_chevron = true,
                on_tap       = function()
                    local list = getTBRList()
                    local sort_items = {}
                    for _, fp in ipairs(list) do
                        sort_items[#sort_items + 1] = {
                            text      = _getBookTitle(fp),
                            orig_item = fp,
                        }
                    end
                    
                    ctx.push("nested_menu", {
                        title = _lc("Arrange"),
                        items_func = function()
                            return {
                                {
                                    text = "Items List",
                                    sui_build = function(ctx2)
                                        local SUIWindow2 = require("sui_window")
                                        local function save_order(items_to_save)
                                            local new_list = {}
                                            for _, it in ipairs(items_to_save) do
                                                new_list[#new_list + 1] = it.orig_item
                                            end
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
                                        end
                                        
                                        local cards = {}
                                        for i, item in ipairs(sort_items) do
                                            local _i   = i
                                            local _fp  = item.orig_item
                                            cards[#cards + 1] = SUIWindow2.ArrangeCard{
                                                inner_w      = ctx2.inner_w,
                                                title        = item.text,
                                                on_delete    = function()
                                                    table.remove(sort_items, _i)
                                                    removeTBR(_fp)
                                                    ctx_menu.refresh()
                                                    ctx2.repaint()
                                                end,
                                                on_move_up   = (_i > 1) and function()
                                                    sort_items[_i], sort_items[_i-1] = sort_items[_i-1], sort_items[_i]
                                                    save_order(sort_items)
                                                    ctx_menu.refresh()
                                                    ctx2.repaint()
                                                end or nil,
                                                on_move_down = (_i < #sort_items) and function()
                                                    sort_items[_i], sort_items[_i+1] = sort_items[_i+1], sort_items[_i]
                                                    save_order(sort_items)
                                                    ctx_menu.refresh()
                                                    ctx2.repaint()
                                                end or nil,
                                            }
                                        end
                                        
                                        if #cards == 0 then
                                            cards[#cards + 1] = SUIWindow2.ListRow{
                                                title   = _lc("No books in To Be Read list."),
                                                inner_w = ctx2.inner_w,
                                            }
                                        end
                                        return cards
                                    end
                                }
                            }
                        end
                    })
                end
            }
        end or nil,
    }

    items[#items + 1] = _makeScaleItem(ctx_menu)
    items[#items + 1] = Config.makeScaleItem({
        text_func = function() return _lc("Text Size") end,
        title     = _lc("Text Size"),
        info      = _lc("Scale for the percentage read text.\n100% is the default size."),
        get       = function() return Config.getItemLabelScalePct("tbr", pfx) end,
        set       = function(v) Config.setItemLabelScale(v, "tbr", pfx) end,
        refresh   = refresh,
    })
    items[#items + 1] = Config.makeScaleItem({
        text_func = function() return _lc("Cover Size") end,
        separator = true,
        title     = _lc("Cover Size"),
        info      = _lc("Scale for the cover thumbnails only.\nText and progress bar follow the module scale.\n100% is the default size."),
        get       = function() return Config.getThumbScalePct("tbr", pfx) end,
        set       = function(v) Config.setThumbScale(v, "tbr", pfx) end,
        refresh   = refresh,
    })

    items[#items + 1] = Config.makeLabelToggleItem("tbr", _("To Be Read"), refresh, _lc)
    items[#items + 1] = {
        text           = _lc("Frame"),
        checked_func   = function() return SUISettings:isTrue(pfx .. "tbr_show_frame") end,
        keep_menu_open = true,
        callback       = function()
            SUISettings:saveSetting(pfx .. "tbr_show_frame", not SUISettings:isTrue(pfx .. "tbr_show_frame"))
            refresh()
        end,
    }
    items[#items + 1] = {
        text           = _lc("Solid Background"),
        checked_func   = function() return SUISettings:isTrue(pfx .. "tbr_solid_bg") end,
        keep_menu_open = true,
        callback       = function()
            SUISettings:saveSetting(pfx .. "tbr_solid_bg", not SUISettings:isTrue(pfx .. "tbr_solid_bg"))
            refresh()
        end,
    }
    items[#items + 1] = {
        text           = _lc("Progress Bar"),
        checked_func   = function() return showProgress(pfx) end,
        enabled_func   = function() return not showOverlay(pfx) end,
        keep_menu_open = true,
        callback       = function()
            SUISettings:saveSetting(pfx .. SETTING_PROGRESS, not showProgress(pfx))
            refresh()
        end,
    }
    items[#items + 1] = {
        text           = _lc("Percentage Text"),
        checked_func   = function() return showText(pfx) end,
        enabled_func   = function() return not showOverlay(pfx) end,
        keep_menu_open = true,
        callback       = function()
            SUISettings:saveSetting(pfx .. SETTING_TEXT, not showText(pfx))
            refresh()
        end,
    }
    items[#items + 1] = {
        text           = _lc("Percentage Overlay on Cover"),
        checked_func   = function() return showOverlay(pfx) end,
        keep_menu_open = true,
        callback       = function()
            SUISettings:saveSetting(pfx .. SETTING_OVERLAY, not showOverlay(pfx))
            refresh()
        end,
    }

    return items
end

return M
