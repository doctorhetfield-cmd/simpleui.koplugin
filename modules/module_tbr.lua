-- module_tbr.lua — Simple UI
-- Module: To Be Read (TBR).
-- Shows up to 5 books marked by the user as "to be read" (paginates past 5
-- via swipe). Also the homescreen "cover row" module for TBR — see
-- moduleregistry.lua's require_mod for this file.
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
-- Public API used by main.lua / sui_patches.lua / moduleregistry.lua:
--   M.TBR_COLL_NAME                                      → string
--   M.getTBRList()                                       → { fp, ... }
--   M.getTBRCount()                                      → number
--   M.isTBR(filepath)                                    → bool
--   M.addTBR(filepath)                                   → bool, string?
--                                                           (false, "finished"
--                                                           when the book is
--                                                           already marked
--                                                           Finished — TBR
--                                                           holds unstarted
--                                                           books only)
--   M.removeTBR(filepath)
--   M.genTBRButton(file, close_cb)                       → button table
--   M.isAutoRemoveFinishedEnabled()                      → bool (used by
--                                                           infra/sui_patches.lua's
--                                                           status-change hook)
--   M.id/build/getHeight/getMenuItems/reset/...          → GridRenderer
--                                                           module contract
--                                                           (see the
--                                                           makeModule call
--                                                           near the bottom)

local lfs             = require("libs/libkoreader-lfs")
local _ = require("infra/sui_i18n").translate

local logger    = require("logger")
local UIManager = require("ui/uimanager")
local UI = require("infra/sui_core")
local BookList  = require("ui/widget/booklist")

local SUISettings = require("infra/sui_store")
local GridRenderer = require("engines/sui_book_grid")

local TBR_MAX       = 5
local TBR_SETTING   = "simpleui_tbr_list"    -- G_reader_settings key (kept in sync)
local TBR_COLL_NAME = "To Be Read"      -- KOReader collection name for the TBR list
local TBR_SORT_STATE  = "simpleui_tbr_sort_state"  -- last applied Sort mode (see GridRenderer.makeSortMenuItem)

-- Setting key for the "auto-remove on finish" toggle (see extraMenuItemsAfter
-- below and infra/sui_patches.lua's _onStatusChanged). Defaults to on via
-- SUISettings:nilOrTrue, same pattern as the other module toggles in this
-- plugin (e.g. module_quick_actions.lua's "Hide Label").
local TBR_AUTO_REMOVE_SETTING = "simpleui_tbr_auto_remove_finished"

-- Whether a book should be dropped from the TBR list once its status
-- changes to "complete". Read from infra/sui_patches.lua's status-change
-- hook, which covers the file manager, the reader's end-of-book flow, and
-- the full-screen Book status widget.
local function isAutoRemoveFinishedEnabled()
    return SUISettings:nilOrTrue(TBR_AUTO_REMOVE_SETTING)
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

-- Whether a book's status is "complete" (KOReader's internal name for
-- "Finished"). TBR is meant to hold unstarted books — see addTBR() below.
local function isFinished(filepath)
    return BookList.getBookStatus(filepath) == "complete"
end

--- Adds a book to the TBR list.
--- Writes directly to RC internals (bypassing the hooked RC.addItem) to avoid
--- re-entrancy; then syncs G_reader_settings.
--- Refuses to add a book already marked "Finished" — TBR represents unstarted
--- books, and letting a finished book in here would just have it immediately
--- removed again by the auto-remove-on-finish hook (see infra/sui_patches.lua's
--- _onStatusChanged). Returns false, "finished" in that case; otherwise
--- returns true (no cap on the list itself: the row is paginated, see the
--- makeModule call below).
local function addTBR(filepath)
    if isTBR(filepath) then return true end
    if isFinished(filepath) then return false, "finished" end

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

-- ── Arrange (TBR-specific: uses isTBR/removeTBR, not generic) ─────────
local function arrangeMenuItems(ctx_menu)
    local _lc          = ctx_menu._
    local refresh       = ctx_menu.refresh
    local SortWidget    = ctx_menu.SortWidget
    local _UIManager    = ctx_menu.UIManager
    return {
        GridRenderer.makeSortMenuItem({
            _lc         = _lc,
            refresh     = refresh,
            state_key   = TBR_SORT_STATE,
            getCollName = function() return TBR_COLL_NAME end,
            getCount    = getTBRCount,
            separator   = true,
            -- Keeps the G_reader_settings fallback list in sync with the
            -- freshly-written ReadCollection order.
            onSorted    = function() _syncSettings(getTBRList()) end,
        }),
        {
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
                            UI.Notify.toast(_lc("Add at least 2 books to arrange."), 2)
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
                local SUIWindow = require("engines/sui_window")
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
                                            local SUIWindow2 = require("engines/sui_window")
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
        },
    }
end

-- ── extra_menu_items_after — auto-remove-on-finish toggle ──────────────────
local function extraMenuItemsAfter(ctx_menu)
    local _lc     = ctx_menu._
    local refresh = ctx_menu.refresh

    return {
        {
            text           = _lc("Remove from list when finished"),
            checked_func   = isAutoRemoveFinishedEnabled,
            keep_menu_open = true,
            callback       = function()
                SUISettings:saveSetting(TBR_AUTO_REMOVE_SETTING, not isAutoRemoveFinishedEnabled())
                refresh()
            end,
        },
    }
end

-- M is both the TBR data/API layer AND the "cover row" row module
-- (build/getHeight/menu registration, via GridRenderer.makeModule below,
-- merged onto M near the bottom of this file). Used to be split across
-- module_book_rows.lua (row registration) + this file (data API) — merged
-- back into one file so each book-row module lives in its own file
-- (module_recent.lua, module_new_books.lua, module_tbr.lua). require path
-- ("modules/module_tbr") is unchanged, so every other call site that uses
-- this file as a data API (main.lua, sui_patches.lua, module_coverdeck.lua,
-- module_collections.lua) is unaffected.
local M = {}

-- Public constants
M.TBR_COLL_NAME = TBR_COLL_NAME
-- TBR_MAX is no longer an add-time cap (see addTBR() below and the
-- RC.addItem hook in sui_patches.lua) -- it now only sets the row's
-- items-per-page for pagination (see the makeModule call below), kept
-- here so that value stays defined in one place.
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

-- Read by infra/sui_patches.lua's _onStatusChanged() to decide whether a
-- book that just became "complete" should be dropped from the TBR list.
M.isAutoRemoveFinishedEnabled = isAutoRemoveFinishedEnabled

-- Menu glue for the "tbr" row module's extra_menu_items_before (below) --
-- kept as a named local/export since it's entangled with this file's
-- private helpers (getTBRList, removeTBR, TBR_COLL_NAME, _getBookTitle, ...).
M.arrangeMenuItems = arrangeMenuItems

-- ---------------------------------------------------------------------------
-- genTBRButton — button for the single-book hold dialog.
-- Follows the same pattern as filemanagerutil.genStatusButtonsRow buttons.
-- ---------------------------------------------------------------------------
function M.genTBRButton(file, close_cb)
    local in_tbr    = isTBR(file)
    local count     = getTBRCount()
    local indicator = string.format("(%d)", count)

    return {
        text    = (in_tbr and _("Remove from To Be Read") or _("Add to To Be Read"))
                  .. "  " .. indicator,
        enabled = true,
        callback = function()
            if in_tbr then
                removeTBR(file)
            elseif isFinished(file) then
                -- Blocked — see addTBR()'s doc comment. Close the dialog
                -- (nothing changed, so the caller's refresh is a no-op) and
                -- explain why, instead of silently doing nothing.
                if close_cb then close_cb() end
                UI.Notify.toast(_("This book is marked as Finished, so it can't be added to To Be Read.\nChange its status to Reading or On Hold first."))
                return
            else
                addTBR(file)
            end
            if close_cb then close_cb() end
        end,
    }
end

-- ---------------------------------------------------------------------------
-- "cover row" module registration (id/build/getHeight/getMenuItems/
-- reset) — merged directly onto M below. `paged = true` removes the old
-- 5-book cap: with more than max_items (5) in the list, the row paginates via
-- swipe instead of cutting off the rest, just like Featured Collection. Grid is
-- opt-in (up to 3 rows x 4-5 columns, "Rows"/"Columns" in the module's menu) —
-- default 1x5 replicates the previous behaviour byte-for-byte.
-- ---------------------------------------------------------------------------
local tbr_module = GridRenderer.makeModule{
    id          = "tbr",
    name        = _("To Be Read"),
    label       = _("To Be Read"),
    default_on  = false,
    is_book_mod = true,   -- needed for the surgical repaint of the swipe
    max_items   = 5,
    paged       = true,
    cache_key   = "_tbr_fps",   -- shared with module_coverdeck.lua
    getFileList = getTBRList,
    extra_menu_items_before = arrangeMenuItems,
    extra_menu_items_after  = extraMenuItemsAfter,

    grid          = true,
    default_rows  = 1,
    default_cols  = 5,

    -- TBR books are, by definition, unstarted — no progress to show by
    -- default. Still fully user-editable (e.g. someone half-reading a book
    -- they later moved back onto the pile) — see the "Progress Style"
    -- picker this maps to in engines/sui_book_grid.lua's getMenuItems.
    progress_style = { default = "none" },

    -- Pages/Series available (off by default), same as Recent/New Books.
    -- "New" is locked off here — TBR books are unstarted by definition, so
    -- the badge would just show on all of them (see GridRenderer.applyBadges'
    -- doc comment).
    badges = { pages = "off", series = "off", new = "locked_off" },

    reset = function() GridRenderer.reset() end,
}
-- Merge TBR's data/API functions (getDisplayName, getTBRList, addTBR, ...,
-- all defined above onto the local M) into tbr_module itself, and return
-- tbr_module — not M. tbr_module is the exact table GridRenderer.makeModule
-- built internally, and the functions it generated close over that same
-- table, so the module registry must hold it rather than a copy.
for k, v in pairs(M) do tbr_module[k] = v end

return tbr_module
